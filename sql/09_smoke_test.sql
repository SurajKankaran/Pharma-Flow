-- ============================================================================
-- PHARMACY INVENTORY WITH AUTO-REORDERING -- SMOKE TEST
-- Run this immediately after 08_final_deploy_all.sql. Every check restores
-- what it touched (or was never destructive to begin with), so this file is
-- safe to re-run any number of times -- a clean deployment should always
-- print "5 passed, 0 failed."
-- ============================================================================
SET SERVEROUTPUT ON;

DECLARE
    v_pass_count  NUMBER := 0;
    v_fail_count  NUMBER := 0;

    PROCEDURE report(p_check IN VARCHAR2, p_ok IN BOOLEAN, p_detail IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        IF p_ok THEN
            v_pass_count := v_pass_count + 1;
            DBMS_OUTPUT.PUT_LINE('PASS: ' || p_check || CASE WHEN p_detail IS NOT NULL THEN ' -- ' || p_detail ELSE '' END);
        ELSE
            v_fail_count := v_fail_count + 1;
            DBMS_OUTPUT.PUT_LINE('FAIL: ' || p_check || CASE WHEN p_detail IS NOT NULL THEN ' -- ' || p_detail ELSE '' END);
        END IF;
    END report;

BEGIN
    DBMS_OUTPUT.PUT_LINE('=====================================================');
    DBMS_OUTPUT.PUT_LINE(' SMOKE TEST -- ' || TO_CHAR(SYSDATE,'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('=====================================================');

    -- ------------------------------------------------------------------
    -- CHECK 1 (CO1): the report runs, and the function correctly returns
    -- NULL (not zero, not an error) for a product with no sales history.
    -- ------------------------------------------------------------------
    DECLARE
        v_stock    NUMBER;
        v_days     NUMBER;
        v_insulin  NUMBER;
    BEGIN
        print_low_stock_report;  -- human-readable output, for visual confirmation

        SELECT NVL(SUM(st.quantity_on_hand),0) INTO v_stock
        FROM   stock st JOIN products p ON p.product_id = st.product_id
        WHERE  p.product_name = 'Ranitidine 150mg';

        SELECT product_id INTO v_insulin FROM products WHERE product_name = 'Insulin Glargine Injection';
        v_days := get_days_of_stock_remaining(v_insulin);

        report('CO1 report + estimation function', v_stock = 12 AND v_stock < 20 AND v_days IS NULL,
            'Ranitidine stock=' || v_stock || ' (below its threshold of 20); Insulin days-remaining=' ||
            NVL(TO_CHAR(v_days),'NULL') || ' (expect NULL -- no sales history)');
    EXCEPTION
        WHEN OTHERS THEN
            report('CO1 report + estimation function', FALSE, SQLERRM);
    END;

    -- ------------------------------------------------------------------
    -- CHECK 2 (CO3): a normal sale succeeds and decrements stock exactly.
    -- Undone with void_sale afterward so this check is safe to re-run.
    -- ------------------------------------------------------------------
    DECLARE
        v_pid      NUMBER;
        v_sale_id  NUMBER;
        v_before   NUMBER;
        v_after    NUMBER;
    BEGIN
        SELECT product_id INTO v_pid FROM products WHERE product_name = 'Cetirizine 10mg';
        SELECT quantity_on_hand INTO v_before FROM stock WHERE batch_no = 'B-CETI-1001';

        process_sale(p_product_id => v_pid, p_quantity => 5, p_sale_id => v_sale_id);

        SELECT quantity_on_hand INTO v_after FROM stock WHERE batch_no = 'B-CETI-1001';

        report('CO3 process_sale (success)', v_after = v_before - 5,
            'Cetirizine stock ' || v_before || ' -> ' || v_after || ', sale_id ' || v_sale_id);

        void_sale(v_sale_id);  -- restores stock, removes the sale row
    EXCEPTION
        WHEN OTHERS THEN
            report('CO3 process_sale (success)', FALSE, SQLERRM);
    END;

    -- ------------------------------------------------------------------
    -- CHECK 3 (CO3): a sale that asks for more than exists must fail
    -- cleanly, with stock provably unchanged. Nothing to clean up --
    -- a rejected sale never touches any row.
    -- ------------------------------------------------------------------
    DECLARE
        v_pid       NUMBER;
        v_sale_id   NUMBER;
        v_before    NUMBER;
        v_after     NUMBER;
        v_rejected  BOOLEAN := FALSE;
    BEGIN
        SELECT product_id INTO v_pid FROM products WHERE product_name = 'Insulin Glargine Injection';
        SELECT quantity_on_hand INTO v_before FROM stock WHERE batch_no = 'B-INSUL-1001';

        BEGIN
            process_sale(p_product_id => v_pid, p_quantity => 20, p_sale_id => v_sale_id);
        EXCEPTION
            WHEN OTHERS THEN
                v_rejected := (SQLCODE = -20001);
        END;

        SELECT quantity_on_hand INTO v_after FROM stock WHERE batch_no = 'B-INSUL-1001';

        report('CO3 process_sale (insufficient stock)', v_rejected AND v_after = v_before,
            'Insulin stock unchanged at ' || v_after || ', request correctly rejected with ORA-20001');
    EXCEPTION
        WHEN OTHERS THEN
            report('CO3 process_sale (insufficient stock)', FALSE, SQLERRM);
    END;

    -- ------------------------------------------------------------------
    -- CHECK 4 (CO4): pushing a healthy product below threshold must
    -- auto-create a PENDING PO with no manual procedure call. MedSource
    -- Distributors is used because none of its products were below
    -- threshold after deployment, so it starts this check with 0 pending
    -- POs -- same reasoning as Part 5's own demo. Rolled back after.
    -- ------------------------------------------------------------------
    DECLARE
        v_po_before  NUMBER;
        v_po_after   NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_po_before
        FROM   purchase_orders po JOIN suppliers s ON s.supplier_id = po.supplier_id
        WHERE  s.supplier_name = 'MedSource Distributors' AND po.status = 'PENDING';

        UPDATE stock SET quantity_on_hand = 5 WHERE batch_no = 'B-IBU-1001';
        -- Ibuprofen total is now 5 + 70 = 75 < 80 -- trg_stock_reorder_check should fire

        SELECT COUNT(*) INTO v_po_after
        FROM   purchase_orders po JOIN suppliers s ON s.supplier_id = po.supplier_id
        WHERE  s.supplier_name = 'MedSource Distributors' AND po.status = 'PENDING';

        report('CO4 trigger auto-creates PO', v_po_before = 0 AND v_po_after = 1,
            'MedSource pending POs ' || v_po_before || ' -> ' || v_po_after);

        ROLLBACK;  -- undoes the stock change AND the auto-created PO together
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            report('CO4 trigger auto-creates PO', FALSE, SQLERRM);
    END;

    -- ------------------------------------------------------------------
    -- CHECK 5 (CO5): abbreviated concurrency test. Ciprofloxacin (18
    -- units) is used instead of Part 6's own Ranitidine, so this doesn't
    -- collide with whatever state that file's standalone run may have
    -- left behind if it was run first in the same schema. Two scheduler
    -- jobs each ask for 10 (20 > 18): exactly one must succeed. Stock and
    -- the new sale are reset afterward; the log rows are left in place,
    -- consistent with concurrency_test_log accumulating history.
    -- ------------------------------------------------------------------
    DECLARE
        v_pid          NUMBER;
        v_start_time   TIMESTAMP WITH TIME ZONE;
        v_success_ct   NUMBER;
        v_failed_ct    NUMBER;
        v_final_stock  NUMBER;
    BEGIN
        SELECT product_id INTO v_pid FROM products WHERE product_name = 'Ciprofloxacin 500mg';

        FOR j IN (SELECT job_name FROM user_scheduler_jobs
                  WHERE job_name IN ('SMOKE_CONC_A','SMOKE_CONC_B')) LOOP
            DBMS_SCHEDULER.DROP_JOB(job_name => j.job_name, force => TRUE);
        END LOOP;

        v_start_time := SYSTIMESTAMP + INTERVAL '2' SECOND;

        DBMS_SCHEDULER.CREATE_JOB(job_name => 'SMOKE_CONC_A', job_type => 'PLSQL_BLOCK',
            job_action => 'BEGIN run_concurrent_sale_test(' || v_pid || ', 10, ''Smoke A''); END;',
            start_date => v_start_time, enabled => TRUE, auto_drop => TRUE);
        DBMS_SCHEDULER.CREATE_JOB(job_name => 'SMOKE_CONC_B', job_type => 'PLSQL_BLOCK',
            job_action => 'BEGIN run_concurrent_sale_test(' || v_pid || ', 10, ''Smoke B''); END;',
            start_date => v_start_time, enabled => TRUE, auto_drop => TRUE);

        DBMS_SESSION.SLEEP(6);  -- 2s to start + margin for both to finish

        SELECT COUNT(*) INTO v_success_ct FROM concurrency_test_log
        WHERE session_info LIKE 'Smoke%' AND result = 'SUCCESS' AND log_time >= v_start_time;
        SELECT COUNT(*) INTO v_failed_ct FROM concurrency_test_log
        WHERE session_info LIKE 'Smoke%' AND result = 'FAILED' AND log_time >= v_start_time;
        SELECT NVL(SUM(quantity_on_hand),0) INTO v_final_stock FROM stock WHERE product_id = v_pid;

        report('CO5 concurrency (no overselling)', v_success_ct = 1 AND v_failed_ct = 1 AND v_final_stock = 8,
            'stock=' || v_final_stock || ' (expect 8), successes=' || v_success_ct || ', failures=' || v_failed_ct);

        -- Reset so this check is safe to re-run (log rows are left as history)
        UPDATE stock SET quantity_on_hand = 18 WHERE batch_no = 'B-CIPRO-1001';
        DELETE FROM sales WHERE product_id = v_pid AND sale_date >= TRUNC(SYSDATE);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            report('CO5 concurrency (no overselling)', FALSE, SQLERRM);
    END;

    DBMS_OUTPUT.PUT_LINE('=====================================================');
    DBMS_OUTPUT.PUT_LINE(' ' || v_pass_count || ' passed, ' || v_fail_count || ' failed.');
    DBMS_OUTPUT.PUT_LINE('=====================================================');
END;
/

-- This run's concurrency evidence, for a quick look without re-running anything
SELECT run_id, session_info, attempted_qty, result, message, log_time
FROM   concurrency_test_log
WHERE  session_info LIKE 'Smoke%'
ORDER BY log_time DESC
FETCH FIRST 2 ROWS ONLY;
