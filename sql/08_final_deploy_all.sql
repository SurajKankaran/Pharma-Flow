-- ============================================================================
-- PHARMACY INVENTORY WITH AUTO-REORDERING -- FULL DEPLOYMENT SCRIPT
-- Assembled from Parts 1-6 into one dependency-ordered script. Run this once
-- against a fresh schema, then run 09_smoke_test.sql to confirm everything
-- still works together.
--
-- CONTENTS                                                          CO
-- --------                                                          --
-- Tables: suppliers, products, stock, sales,
--         purchase_orders, purchase_order_items                    Foundation
-- Functions: get_avg_daily_sales, get_days_of_stock_remaining       CO1
-- Procedures: print_low_stock_report, get_low_stock_report_rc      CO1
-- Procedures: generate_purchase_order,
--             generate_purchase_order_for_product                  CO2
-- Procedures: process_sale, void_sale                               CO3
-- Package: stock_config_pkg (near-expiry-days constant)             CO4
-- Triggers: trg_stock_reorder_check, trg_stock_expiry_flag          CO4
-- Seed data: 5 suppliers, 18 products, 25 stock batches,
--            51 historical sales                                   Foundation
-- Table: concurrency_test_log                                      CO5
-- Procedure: run_concurrent_sale_test                                CO5
--
-- ORDERING NOTE: triggers are created BEFORE the seed data loads (per the
-- Part 7 brief), which is the reverse of how Parts 1-6 were built and
-- demonstrated as separate files. The practical effect -- and the biggest
-- judgment call in this assembly -- is explained where the seed data
-- begins, below.
-- ============================================================================


-- ============================================================================
-- SECTION 1: TABLES
-- ============================================================================
BEGIN
   FOR t IN (
      SELECT table_name FROM user_tables
      WHERE table_name IN ('PURCHASE_ORDER_ITEMS','PURCHASE_ORDERS','SALES',
                            'STOCK','PRODUCTS','SUPPLIERS','CONCURRENCY_TEST_LOG')
   ) LOOP
      EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
   END LOOP;
END;
/

CREATE TABLE suppliers (
    supplier_id     NUMBER          GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    supplier_name   VARCHAR2(120)   NOT NULL,
    contact_person  VARCHAR2(100),
    phone           VARCHAR2(20),
    email           VARCHAR2(120),
    lead_time_days  NUMBER(4)       NOT NULL,
    is_active       CHAR(1)         DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_suppliers         PRIMARY KEY (supplier_id),
    CONSTRAINT uq_suppliers_name    UNIQUE (supplier_name),
    CONSTRAINT chk_suppliers_active CHECK (is_active IN ('Y','N')),
    CONSTRAINT chk_suppliers_lead   CHECK (lead_time_days >= 0)
);
-- Oracle 11g (no IDENTITY columns): drop the GENERATED ALWAYS AS IDENTITY
-- clause above and on every other table below, then for each table add
--   CREATE SEQUENCE seq_<table> START WITH 1 INCREMENT BY 1;
--   CREATE OR REPLACE TRIGGER trg_<table>_pk BEFORE INSERT ON <table>
--   FOR EACH ROW WHEN (NEW.<pk_col> IS NULL)
--   BEGIN :NEW.<pk_col> := seq_<table>.NEXTVAL; END;
--   /

CREATE TABLE products (
    product_id          NUMBER          GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    product_name        VARCHAR2(150)   NOT NULL,
    category             VARCHAR2(60)    NOT NULL,
    manufacturer        VARCHAR2(120),
    unit_price          NUMBER(10,2)    NOT NULL,
    reorder_threshold   NUMBER(10)      NOT NULL,
    reorder_quantity    NUMBER(10)      NOT NULL,
    default_supplier_id NUMBER          NOT NULL,
    is_active           CHAR(1)         DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_products           PRIMARY KEY (product_id),
    CONSTRAINT uq_products_name      UNIQUE (product_name),
    CONSTRAINT fk_products_supplier  FOREIGN KEY (default_supplier_id) REFERENCES suppliers(supplier_id),
    CONSTRAINT chk_products_active   CHECK (is_active IN ('Y','N')),
    CONSTRAINT chk_products_price    CHECK (unit_price >= 0),
    CONSTRAINT chk_products_thresh   CHECK (reorder_threshold >= 0),
    CONSTRAINT chk_products_reorder  CHECK (reorder_quantity > 0)
);

-- One row per received BATCH, not per product -- expiry differs per batch.
-- A product's total stock = SUM(quantity_on_hand) across its batches.
CREATE TABLE stock (
    stock_id          NUMBER          GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    product_id        NUMBER          NOT NULL,
    supplier_id       NUMBER          NOT NULL,
    batch_no          VARCHAR2(40)    NOT NULL,
    quantity_on_hand  NUMBER(10)      NOT NULL,
    expiry_date       DATE            NOT NULL,
    date_received     DATE            DEFAULT SYSDATE NOT NULL,
    unit_cost         NUMBER(10,2)    NOT NULL,
    near_expiry_flag  CHAR(1)         DEFAULT 'N' NOT NULL,
    CONSTRAINT pk_stock              PRIMARY KEY (stock_id),
    CONSTRAINT uq_stock_batch        UNIQUE (product_id, batch_no),
    CONSTRAINT fk_stock_product      FOREIGN KEY (product_id) REFERENCES products(product_id),
    CONSTRAINT fk_stock_supplier     FOREIGN KEY (supplier_id) REFERENCES suppliers(supplier_id),
    CONSTRAINT chk_stock_qty_nonneg  CHECK (quantity_on_hand >= 0),  -- CO3's second line of defense
    CONSTRAINT chk_stock_cost        CHECK (unit_cost >= 0),
    CONSTRAINT chk_stock_flag        CHECK (near_expiry_flag IN ('Y','N'))
);

CREATE TABLE sales (
    sale_id        NUMBER          GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    product_id     NUMBER          NOT NULL,
    stock_id       NUMBER,
    quantity_sold  NUMBER(10)      NOT NULL,
    unit_price     NUMBER(10,2)    NOT NULL,
    total_amount   NUMBER(12,2)    NOT NULL,
    sale_date      DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_sales           PRIMARY KEY (sale_id),
    CONSTRAINT fk_sales_product   FOREIGN KEY (product_id) REFERENCES products(product_id),
    CONSTRAINT fk_sales_stock     FOREIGN KEY (stock_id) REFERENCES stock(stock_id),
    CONSTRAINT chk_sales_qty      CHECK (quantity_sold > 0),
    CONSTRAINT chk_sales_price    CHECK (unit_price >= 0)
);

-- Header. PURCHASE_ORDER_ITEMS below is a 6th table beyond the 5 originally
-- named ones -- see the judgment-calls list for why, and how to flatten it
-- back to 5 if your rubric requires that.
CREATE TABLE purchase_orders (
    po_id                   NUMBER          GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    supplier_id             NUMBER          NOT NULL,
    order_date              DATE            DEFAULT SYSDATE NOT NULL,
    status                  VARCHAR2(20)    DEFAULT 'PENDING' NOT NULL,
    expected_delivery_date  DATE,
    total_amount            NUMBER(12,2)    DEFAULT 0 NOT NULL,
    CONSTRAINT pk_purchase_orders  PRIMARY KEY (po_id),
    CONSTRAINT fk_po_supplier      FOREIGN KEY (supplier_id) REFERENCES suppliers(supplier_id),
    CONSTRAINT chk_po_status       CHECK (status IN ('PENDING','APPROVED','RECEIVED','CANCELLED')),
    CONSTRAINT chk_po_total        CHECK (total_amount >= 0)
);

CREATE TABLE purchase_order_items (
    po_item_id        NUMBER          GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    po_id             NUMBER          NOT NULL,
    product_id        NUMBER          NOT NULL,
    quantity_ordered  NUMBER(10)      NOT NULL,
    unit_cost         NUMBER(10,2)    NOT NULL,
    CONSTRAINT pk_po_items        PRIMARY KEY (po_item_id),
    CONSTRAINT uq_po_items        UNIQUE (po_id, product_id),
    CONSTRAINT fk_poi_po          FOREIGN KEY (po_id) REFERENCES purchase_orders(po_id),
    CONSTRAINT fk_poi_product     FOREIGN KEY (product_id) REFERENCES products(product_id),
    CONSTRAINT chk_poi_qty        CHECK (quantity_ordered > 0),
    CONSTRAINT chk_poi_cost       CHECK (unit_cost >= 0)
);


-- ============================================================================
-- SECTION 2: FUNCTIONS -- CO1
-- ============================================================================
CREATE OR REPLACE FUNCTION get_avg_daily_sales(
    p_product_id     IN NUMBER,
    p_lookback_days  IN NUMBER DEFAULT 30
) RETURN NUMBER
IS
    v_total_qty  NUMBER;
BEGIN
    IF NVL(p_lookback_days, 0) <= 0 THEN
        RETURN 0;
    END IF;

    SELECT NVL(SUM(quantity_sold), 0)
    INTO   v_total_qty
    FROM   sales
    WHERE  product_id = p_product_id
    AND    sale_date  >= TRUNC(SYSDATE) - p_lookback_days;

    IF v_total_qty = 0 THEN
        RETURN 0;
    END IF;

    RETURN v_total_qty / p_lookback_days;
END get_avg_daily_sales;
/

-- NULL means "not enough sales history to estimate", never "infinite stock".
CREATE OR REPLACE FUNCTION get_days_of_stock_remaining(
    p_product_id IN NUMBER
) RETURN NUMBER
IS
    v_total_stock  NUMBER;
    v_avg_daily    NUMBER;
BEGIN
    SELECT NVL(SUM(quantity_on_hand), 0) INTO v_total_stock FROM stock WHERE product_id = p_product_id;
    v_avg_daily := get_avg_daily_sales(p_product_id);

    IF v_avg_daily = 0 THEN
        RETURN NULL;
    END IF;

    RETURN v_total_stock / v_avg_daily;
END get_days_of_stock_remaining;
/


-- ============================================================================
-- SECTION 3: PROCEDURES -- CO1 (reporting)
-- ============================================================================
CREATE OR REPLACE PROCEDURE print_low_stock_report
IS
    -- Explicit cursors (OPEN/FETCH/%NOTFOUND/CLOSE), not cursor-FOR-loops,
    -- to show the full cursor lifecycle.
    CURSOR c_suppliers IS
        SELECT DISTINCT s.supplier_id, s.supplier_name
        FROM   suppliers s
        JOIN   products p ON p.default_supplier_id = s.supplier_id
        JOIN   (SELECT product_id, NVL(SUM(quantity_on_hand),0) AS total_stock
                 FROM stock GROUP BY product_id) st ON st.product_id = p.product_id
        WHERE  st.total_stock < p.reorder_threshold
        AND    p.is_active = 'Y'
        ORDER BY s.supplier_name;

    CURSOR c_products (p_supplier_id IN NUMBER) IS
        SELECT p.product_id, p.product_name, p.reorder_threshold,
               NVL(st.total_stock, 0) AS total_stock
        FROM   products p
        JOIN   (SELECT product_id, NVL(SUM(quantity_on_hand),0) AS total_stock
                 FROM stock GROUP BY product_id) st ON st.product_id = p.product_id
        WHERE  p.default_supplier_id = p_supplier_id
        AND    st.total_stock < p.reorder_threshold
        AND    p.is_active = 'Y'
        ORDER BY (p.reorder_threshold - st.total_stock) DESC;  -- worst first

    v_supplier        c_suppliers%ROWTYPE;
    v_product         c_products%ROWTYPE;
    v_days_left       NUMBER;
    v_supplier_count  NUMBER := 0;
    v_product_count   NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=====================================================');
    DBMS_OUTPUT.PUT_LINE(' LOW STOCK REPORT  (generated ' || TO_CHAR(SYSDATE,'DD-MON-YYYY') || ')');
    DBMS_OUTPUT.PUT_LINE('=====================================================');

    OPEN c_suppliers;
    LOOP
        FETCH c_suppliers INTO v_supplier;
        EXIT WHEN c_suppliers%NOTFOUND;
        v_supplier_count := v_supplier_count + 1;
        DBMS_OUTPUT.PUT_LINE(CHR(10) || 'Supplier: ' || v_supplier.supplier_name);
        DBMS_OUTPUT.PUT_LINE(RPAD('-', 60, '-'));

        OPEN c_products(v_supplier.supplier_id);
        LOOP
            FETCH c_products INTO v_product;
            EXIT WHEN c_products%NOTFOUND;
            v_product_count := v_product_count + 1;
            v_days_left := get_days_of_stock_remaining(v_product.product_id);
            DBMS_OUTPUT.PUT_LINE(
                '  ' || RPAD(v_product.product_name, 32) ||
                'Stock: ' || LPAD(v_product.total_stock, 5) ||
                '  Threshold: ' || LPAD(v_product.reorder_threshold, 5) ||
                '  Days left: ' ||
                CASE WHEN v_days_left IS NULL THEN 'N/A (no sales history)'
                     ELSE TO_CHAR(ROUND(v_days_left, 1)) END
            );
        END LOOP;
        CLOSE c_products;
    END LOOP;
    CLOSE c_suppliers;

    DBMS_OUTPUT.PUT_LINE(CHR(10) || '=====================================================');
    DBMS_OUTPUT.PUT_LINE(' ' || v_supplier_count || ' supplier(s), ' || v_product_count || ' product(s) below threshold.');
    DBMS_OUTPUT.PUT_LINE('=====================================================');
EXCEPTION
    WHEN OTHERS THEN
        IF c_suppliers%ISOPEN THEN CLOSE c_suppliers; END IF;
        IF c_products%ISOPEN THEN CLOSE c_products; END IF;
        DBMS_OUTPUT.PUT_LINE('Error generating low-stock report: ' || SQLERRM);
        RAISE;
END print_low_stock_report;
/

-- Ref-cursor version: prefer this shape whenever the report feeds something
-- other than a console -- a front-end grid, a BI tool, an API response.
CREATE OR REPLACE PROCEDURE get_low_stock_report_rc (
    p_report_cursor OUT SYS_REFCURSOR
)
IS
BEGIN
    OPEN p_report_cursor FOR
        SELECT s.supplier_name, p.product_name, p.reorder_threshold,
               NVL(st.total_stock, 0) AS current_stock,
               get_days_of_stock_remaining(p.product_id) AS days_of_stock_remaining
        FROM   suppliers s
        JOIN   products p ON p.default_supplier_id = s.supplier_id
        JOIN   (SELECT product_id, NVL(SUM(quantity_on_hand),0) AS total_stock
                 FROM stock GROUP BY product_id) st ON st.product_id = p.product_id
        WHERE  st.total_stock < p.reorder_threshold
        AND    p.is_active = 'Y'
        ORDER BY s.supplier_name, (p.reorder_threshold - st.total_stock) DESC;
END get_low_stock_report_rc;
/


-- ============================================================================
-- SECTION 4: PROCEDURES -- CO2 (grouped auto-reorder)
-- ============================================================================
CREATE OR REPLACE PROCEDURE generate_purchase_order (
    p_dry_run IN BOOLEAN DEFAULT FALSE
)
IS
    CURSOR c_suppliers IS
        SELECT DISTINCT s.supplier_id, s.supplier_name, s.lead_time_days
        FROM   suppliers s
        JOIN   products p ON p.default_supplier_id = s.supplier_id
        LEFT JOIN (SELECT product_id, NVL(SUM(quantity_on_hand),0) AS total_stock
                    FROM stock GROUP BY product_id) st ON st.product_id = p.product_id
        WHERE  p.is_active = 'Y'
        AND    NVL(st.total_stock,0) < p.reorder_threshold
        AND    NOT EXISTS (
                   SELECT 1 FROM purchase_order_items poi
                   JOIN   purchase_orders po ON po.po_id = poi.po_id
                   WHERE  poi.product_id = p.product_id
                   AND    po.supplier_id = s.supplier_id
                   AND    po.status = 'PENDING'
               )
        ORDER BY s.supplier_name;

    CURSOR c_products (p_supplier_id IN NUMBER) IS
        SELECT p.product_id, p.product_name, p.reorder_threshold,
               p.reorder_quantity, NVL(st.total_stock,0) AS total_stock
        FROM   products p
        LEFT JOIN (SELECT product_id, NVL(SUM(quantity_on_hand),0) AS total_stock
                    FROM stock GROUP BY product_id) st ON st.product_id = p.product_id
        WHERE  p.default_supplier_id = p_supplier_id
        AND    p.is_active = 'Y'
        AND    NVL(st.total_stock,0) < p.reorder_threshold
        AND    NOT EXISTS (
                   SELECT 1 FROM purchase_order_items poi
                   JOIN   purchase_orders po ON po.po_id = poi.po_id
                   WHERE  poi.product_id = p.product_id
                   AND    po.supplier_id = p_supplier_id
                   AND    po.status = 'PENDING'
               )
        ORDER BY (p.reorder_threshold - NVL(st.total_stock,0)) DESC;

    v_supplier        c_suppliers%ROWTYPE;
    v_product         c_products%ROWTYPE;
    v_po_id           purchase_orders.po_id%TYPE;
    v_unit_cost       NUMBER;
    v_line_total      NUMBER;
    v_po_total        NUMBER;
    v_po_count        NUMBER := 0;
    v_product_count   NUMBER := 0;
    v_skipped_count   NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_skipped_count
    FROM   products p
    LEFT JOIN (SELECT product_id, NVL(SUM(quantity_on_hand),0) AS total_stock
                FROM stock GROUP BY product_id) st ON st.product_id = p.product_id
    WHERE  p.is_active = 'Y'
    AND    NVL(st.total_stock,0) < p.reorder_threshold
    AND    EXISTS (
               SELECT 1 FROM purchase_order_items poi
               JOIN   purchase_orders po ON po.po_id = poi.po_id
               WHERE  poi.product_id = p.product_id
               AND    po.supplier_id = p.default_supplier_id
               AND    po.status = 'PENDING'
           );

    IF p_dry_run THEN
        DBMS_OUTPUT.PUT_LINE('=== DRY RUN -- no rows will be inserted ===');
    END IF;

    OPEN c_suppliers;
    LOOP
        FETCH c_suppliers INTO v_supplier;
        EXIT WHEN c_suppliers%NOTFOUND;

        SAVEPOINT sp_supplier_group;  -- one bad supplier group can't take the others down

        BEGIN
            v_po_total := 0;
            v_po_id    := NULL;

            IF p_dry_run THEN
                DBMS_OUTPUT.PUT_LINE(CHR(10) || '[DRY RUN] Would create PO for supplier: ' || v_supplier.supplier_name);
            ELSE
                INSERT INTO purchase_orders (supplier_id, order_date, status, expected_delivery_date, total_amount)
                VALUES (v_supplier.supplier_id, SYSDATE, 'PENDING', SYSDATE + v_supplier.lead_time_days, 0)
                RETURNING po_id INTO v_po_id;
                DBMS_OUTPUT.PUT_LINE(CHR(10) || 'Creating PO #' || v_po_id || ' for supplier: ' || v_supplier.supplier_name);
            END IF;

            OPEN c_products(v_supplier.supplier_id);
            LOOP
                FETCH c_products INTO v_product;
                EXIT WHEN c_products%NOTFOUND;

                -- Cost basis: the most recently RECEIVED batch's unit_cost,
                -- falling back to PRODUCTS.unit_price only if there's no
                -- STOCK history at all.
                BEGIN
                    SELECT unit_cost INTO v_unit_cost
                    FROM (SELECT unit_cost FROM stock
                          WHERE product_id = v_product.product_id
                          ORDER BY date_received DESC, stock_id DESC)
                    WHERE ROWNUM = 1;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        SELECT unit_price INTO v_unit_cost FROM products WHERE product_id = v_product.product_id;
                END;

                v_line_total := v_product.reorder_quantity * v_unit_cost;
                v_po_total   := v_po_total + v_line_total;

                IF p_dry_run THEN
                    DBMS_OUTPUT.PUT_LINE('    -> ' || RPAD(v_product.product_name,32) ||
                        ' qty ' || v_product.reorder_quantity || ' @ ' || v_unit_cost || ' = ' || v_line_total);
                ELSE
                    INSERT INTO purchase_order_items (po_id, product_id, quantity_ordered, unit_cost)
                    VALUES (v_po_id, v_product.product_id, v_product.reorder_quantity, v_unit_cost);
                    DBMS_OUTPUT.PUT_LINE('    -> ' || RPAD(v_product.product_name,32) ||
                        ' qty ' || v_product.reorder_quantity || ' @ ' || v_unit_cost || ' = ' || v_line_total);
                END IF;
                v_product_count := v_product_count + 1;
            END LOOP;
            CLOSE c_products;

            IF NOT p_dry_run THEN
                UPDATE purchase_orders SET total_amount = v_po_total WHERE po_id = v_po_id;
            END IF;
            v_po_count := v_po_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                IF c_products%ISOPEN THEN CLOSE c_products; END IF;
                ROLLBACK TO sp_supplier_group;
                DBMS_OUTPUT.PUT_LINE('  !! Skipped supplier ' || v_supplier.supplier_name || ' due to error: ' || SQLERRM);
        END;
    END LOOP;
    CLOSE c_suppliers;

    IF NOT p_dry_run THEN
        COMMIT;
    END IF;

    DBMS_OUTPUT.PUT_LINE(CHR(10) || '=====================================================');
    DBMS_OUTPUT.PUT_LINE(
        CASE WHEN p_dry_run THEN '[DRY RUN] ' ELSE '' END || v_po_count ||
        CASE WHEN p_dry_run THEN ' purchase order(s) would be created, ' ELSE ' purchase order(s) created, ' END ||
        v_product_count || ' product(s) covered, ' || v_skipped_count || ' product(s) skipped (already pending).'
    );
    DBMS_OUTPUT.PUT_LINE('=====================================================');
EXCEPTION
    WHEN OTHERS THEN
        IF c_suppliers%ISOPEN THEN CLOSE c_suppliers; END IF;
        IF c_products%ISOPEN THEN CLOSE c_products; END IF;
        RAISE;
END generate_purchase_order;
/

-- Deliberately NO COMMIT/ROLLBACK in this one -- it is called from the
-- trg_stock_reorder_check trigger below, and Oracle forbids COMMIT/ROLLBACK
-- inside a trigger or anything it calls (ORA-04092). Leaving the boundary
-- to the caller also means a stock change and the reorder it causes commit
-- together as one unit.
CREATE OR REPLACE PROCEDURE generate_purchase_order_for_product (
    p_product_id IN NUMBER
)
IS
    v_product          products%ROWTYPE;
    v_total_stock      NUMBER;
    v_supplier_id      NUMBER;
    v_lead_time        NUMBER;
    v_unit_cost        NUMBER;
    v_po_id            purchase_orders.po_id%TYPE;
    v_already_pending  NUMBER;
BEGIN
    BEGIN
        SELECT * INTO v_product FROM products WHERE product_id = p_product_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20010, 'generate_purchase_order_for_product: no such product_id ' || p_product_id);
    END;

    IF v_product.is_active != 'Y' THEN
        RETURN;
    END IF;

    SELECT NVL(SUM(quantity_on_hand),0) INTO v_total_stock FROM stock WHERE product_id = p_product_id;
    IF v_total_stock >= v_product.reorder_threshold THEN
        RETURN;
    END IF;

    v_supplier_id := v_product.default_supplier_id;

    SELECT COUNT(*) INTO v_already_pending
    FROM   purchase_order_items poi
    JOIN   purchase_orders po ON po.po_id = poi.po_id
    WHERE  poi.product_id = p_product_id
    AND    po.supplier_id = v_supplier_id
    AND    po.status = 'PENDING';

    IF v_already_pending > 0 THEN
        DBMS_OUTPUT.PUT_LINE('generate_purchase_order_for_product: ' || v_product.product_name ||
            ' already has a pending order -- skipped.');
        RETURN;
    END IF;

    BEGIN
        SELECT unit_cost INTO v_unit_cost
        FROM (SELECT unit_cost FROM stock WHERE product_id = p_product_id
              ORDER BY date_received DESC, stock_id DESC)
        WHERE ROWNUM = 1;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            v_unit_cost := v_product.unit_price;
    END;

    -- "Grouped by vendor" still applies here: append to an existing
    -- PENDING PO for this supplier rather than opening a second one.
    BEGIN
        SELECT po_id INTO v_po_id
        FROM   purchase_orders
        WHERE  supplier_id = v_supplier_id AND status = 'PENDING'
        AND    ROWNUM = 1;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            SELECT lead_time_days INTO v_lead_time FROM suppliers WHERE supplier_id = v_supplier_id;
            INSERT INTO purchase_orders (supplier_id, order_date, status, expected_delivery_date, total_amount)
            VALUES (v_supplier_id, SYSDATE, 'PENDING', SYSDATE + v_lead_time, 0)
            RETURNING po_id INTO v_po_id;
    END;

    INSERT INTO purchase_order_items (po_id, product_id, quantity_ordered, unit_cost)
    VALUES (v_po_id, p_product_id, v_product.reorder_quantity, v_unit_cost);

    UPDATE purchase_orders
    SET    total_amount = total_amount + (v_product.reorder_quantity * v_unit_cost)
    WHERE  po_id = v_po_id;

    DBMS_OUTPUT.PUT_LINE('generate_purchase_order_for_product: added ' || v_product.product_name ||
        ' to PO #' || v_po_id || '.');
END generate_purchase_order_for_product;
/


-- ============================================================================
-- SECTION 5: PROCEDURES -- CO3 (atomic, concurrency-safe sale processing)
-- ============================================================================
CREATE OR REPLACE PROCEDURE process_sale (
    p_product_id  IN  NUMBER,
    p_quantity    IN  NUMBER,
    p_unit_price  IN  NUMBER  DEFAULT NULL,
    p_sale_id     OUT NUMBER,
    p_commit      IN  BOOLEAN DEFAULT TRUE
)
IS
    -- FEFO (earliest expiry first) minimizes write-offs; expired batches are
    -- excluded outright. SELECT ... FOR UPDATE locks every sellable batch of
    -- this product BEFORE the availability check, which is what serializes
    -- two concurrent sales instead of letting both read stale "stock
    -- available" numbers (see CO5). CHECK (quantity_on_hand >= 0) on STOCK
    -- is a second line of defense that this procedure's own logic should
    -- make unreachable.
    e_insufficient_stock  EXCEPTION; PRAGMA EXCEPTION_INIT(e_insufficient_stock, -20001);
    e_invalid_quantity    EXCEPTION; PRAGMA EXCEPTION_INIT(e_invalid_quantity,   -20002);
    e_product_not_found   EXCEPTION; PRAGMA EXCEPTION_INIT(e_product_not_found,  -20003);
    e_invalid_price       EXCEPTION; PRAGMA EXCEPTION_INIT(e_invalid_price,      -20004);

    CURSOR c_batches IS
        SELECT stock_id, quantity_on_hand, expiry_date
        FROM   stock
        WHERE  product_id       = p_product_id
        AND    quantity_on_hand > 0
        AND    expiry_date     >= TRUNC(SYSDATE)
        ORDER BY expiry_date ASC, stock_id ASC
        FOR UPDATE;

    TYPE t_batch_tab IS TABLE OF c_batches%ROWTYPE INDEX BY PLS_INTEGER;
    v_batches       t_batch_tab;

    v_product_name  products.product_name%TYPE;
    v_list_price    products.unit_price%TYPE;
    v_price         NUMBER;
    v_available     NUMBER := 0;
    v_remaining     NUMBER;
    v_take          NUMBER;
BEGIN
    SAVEPOINT sp_process_sale;

    IF p_quantity IS NULL OR p_quantity <= 0 OR p_quantity <> TRUNC(p_quantity) THEN
        RAISE_APPLICATION_ERROR(-20002, 'process_sale: quantity must be a positive whole number (got ' ||
            NVL(TO_CHAR(p_quantity), 'NULL') || ')');
    END IF;
    IF p_unit_price IS NOT NULL AND p_unit_price < 0 THEN
        RAISE_APPLICATION_ERROR(-20004, 'process_sale: unit price cannot be negative (got ' || p_unit_price || ')');
    END IF;

    BEGIN
        SELECT product_name, unit_price INTO v_product_name, v_list_price
        FROM products WHERE product_id = p_product_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20003, 'process_sale: no such product_id ' || p_product_id);
    END;

    v_price := ROUND(NVL(p_unit_price, v_list_price), 2);

    OPEN c_batches;
    FETCH c_batches BULK COLLECT INTO v_batches;
    CLOSE c_batches;

    FOR i IN 1 .. v_batches.COUNT LOOP
        v_available := v_available + v_batches(i).quantity_on_hand;
    END LOOP;

    IF v_available < p_quantity THEN
        RAISE_APPLICATION_ERROR(-20001, 'process_sale: insufficient stock for "' || v_product_name ||
            '": requested ' || p_quantity || ', sellable (non-expired) stock ' || v_available);
    END IF;

    v_remaining := p_quantity;
    FOR i IN 1 .. v_batches.COUNT LOOP
        EXIT WHEN v_remaining = 0;
        v_take := LEAST(v_remaining, v_batches(i).quantity_on_hand);
        UPDATE stock SET quantity_on_hand = quantity_on_hand - v_take WHERE stock_id = v_batches(i).stock_id;
        v_remaining := v_remaining - v_take;
    END LOOP;

    INSERT INTO sales (product_id, stock_id, quantity_sold, unit_price, total_amount, sale_date)
    VALUES (p_product_id, v_batches(1).stock_id, p_quantity, v_price, p_quantity * v_price, SYSDATE)
    RETURNING sale_id INTO p_sale_id;

    IF p_commit THEN
        COMMIT;
    END IF;
EXCEPTION
    WHEN e_insufficient_stock OR e_invalid_quantity OR e_product_not_found OR e_invalid_price THEN
        IF c_batches%ISOPEN THEN CLOSE c_batches; END IF;
        ROLLBACK TO sp_process_sale;
        RAISE;
    WHEN OTHERS THEN
        IF c_batches%ISOPEN THEN CLOSE c_batches; END IF;
        ROLLBACK TO sp_process_sale;
        RAISE;
END process_sale;
/

CREATE OR REPLACE PROCEDURE void_sale (
    p_sale_id IN NUMBER
)
IS
    v_sale  sales%ROWTYPE;
BEGIN
    SAVEPOINT sp_void_sale;
    BEGIN
        SELECT * INTO v_sale FROM sales WHERE sale_id = p_sale_id FOR UPDATE;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20006, 'void_sale: no sale with sale_id ' || p_sale_id);
    END;
    IF v_sale.stock_id IS NULL THEN
        RAISE_APPLICATION_ERROR(-20007, 'void_sale: sale ' || p_sale_id || ' has no batch reference to restore');
    END IF;
    UPDATE stock SET quantity_on_hand = quantity_on_hand + v_sale.quantity_sold WHERE stock_id = v_sale.stock_id;
    DELETE FROM sales WHERE sale_id = p_sale_id;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK TO sp_void_sale;
        RAISE;
END void_sale;
/


-- ============================================================================
-- SECTION 6: PACKAGE + TRIGGERS -- CO4
-- ============================================================================
CREATE OR REPLACE PACKAGE stock_config_pkg IS
    c_near_expiry_days CONSTANT PLS_INTEGER := 90;
END stock_config_pkg;
/

-- COMPOUND TRIGGER: a plain "AFTER UPDATE FOR EACH ROW" trigger that tried
-- to SUM(quantity_on_hand) for a whole product would query the very table
-- it's mid-updating and raise ORA-04091 (table is mutating) the moment a
-- statement touches more than one STOCK row. AFTER EACH ROW here only
-- records which products were touched; AFTER STATEMENT, once the whole
-- statement is done and the table is no longer mutating, does the real
-- SUM(...) and the reorder call. Scoped to "OF quantity_on_hand" so an edit
-- that never touches quantity doesn't fire it at all.
CREATE OR REPLACE TRIGGER trg_stock_reorder_check
FOR INSERT OR UPDATE OF quantity_on_hand ON stock
COMPOUND TRIGGER

    TYPE t_check_needed IS TABLE OF BOOLEAN INDEX BY PLS_INTEGER;
    v_check_needed  t_check_needed;

    AFTER EACH ROW IS
    BEGIN
        IF INSERTING THEN
            v_check_needed(:NEW.product_id) := TRUE;
        ELSIF :NEW.quantity_on_hand < :OLD.quantity_on_hand THEN
            v_check_needed(:NEW.product_id) := TRUE;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_product_id   PLS_INTEGER;
        v_total_stock  NUMBER;
        v_threshold    NUMBER;
        v_is_active    CHAR(1);
    BEGIN
        v_product_id := v_check_needed.FIRST;
        WHILE v_product_id IS NOT NULL LOOP
            BEGIN
                SELECT reorder_threshold, is_active INTO v_threshold, v_is_active
                FROM products WHERE product_id = v_product_id;

                IF v_is_active = 'Y' THEN
                    SELECT NVL(SUM(quantity_on_hand),0) INTO v_total_stock FROM stock WHERE product_id = v_product_id;
                    IF v_total_stock < v_threshold THEN
                        generate_purchase_order_for_product(v_product_id);  -- safe: never commits/rolls back
                    END IF;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    DBMS_OUTPUT.PUT_LINE('trg_stock_reorder_check: could not evaluate product ' ||
                        v_product_id || ': ' || SQLERRM);
            END;
            v_product_id := v_check_needed.NEXT(v_product_id);
        END LOOP;
        v_check_needed.DELETE;
    END AFTER STATEMENT;

END trg_stock_reorder_check;
/
-- Reset-scenario note: reloading seed data after this trigger already
-- exists would fire it once per row. ALTER TRIGGER trg_stock_reorder_check
-- DISABLE first, then ENABLE afterward.

-- BEFORE ROW (not compound): only ever touches :NEW of its own row, never
-- queries STOCK, so there's no mutating-table risk to guard against. Must
-- be BEFORE, not AFTER, since only a BEFORE row trigger may assign :NEW.
-- Fires on quantity_on_hand too, not just expiry_date, so every sale
-- against a batch gives its flag a free re-evaluation against today's date
-- -- otherwise a batch nobody touches again would never have its flag flip
-- from 'N' to 'Y' purely because the calendar advanced.
CREATE OR REPLACE TRIGGER trg_stock_expiry_flag
BEFORE INSERT OR UPDATE OF expiry_date, quantity_on_hand ON stock
FOR EACH ROW
BEGIN
    IF :NEW.expiry_date <= TRUNC(SYSDATE) + stock_config_pkg.c_near_expiry_days THEN
        :NEW.near_expiry_flag := 'Y';
    ELSE
        :NEW.near_expiry_flag := 'N';
    END IF;
END trg_stock_expiry_flag;
/


-- ============================================================================
-- SECTION 7: SEED DATA
--
-- JUDGMENT CALL, READ THIS: both triggers above are now active BEFORE any
-- seed data loads (the ordering this Part 7 brief asks for), which is the
-- REVERSE of Parts 1-6's own build order (seed data first, triggers added
-- in Part 5). Two consequences, both verified by hand:
--   - trg_stock_expiry_flag flags every near-expiry batch correctly AT
--     INSERT TIME, so the one-time backfill UPDATE that Part 5's own file
--     needed (to fix rows that predated the trigger) is not needed here
--     and has been dropped from this assembly.
--   - trg_stock_reorder_check fires on every one of the STOCK inserts
--     below, so the seed load ITSELF automatically raises purchase orders
--     for the products that start below their threshold -- no manual call
--     to generate_purchase_order needed at all. The end state (4 POs: one
--     each for Apex Pharma Supplies, National Drug House and Cureline
--     Healthcare Ltd., and one for Wellness Wholesale Co. covering three
--     products) is IDENTICAL to what Part 3's demo produced by calling the
--     procedure by hand -- I traced it through batch by batch to confirm.
--     If you run Parts 1-6 as separate files in their original order
--     instead of this consolidated script, PURCHASE_ORDERS will already be
--     populated by the time you reach Part 5/6, whereas running just this
--     file against a blank schema produces that same population as a side
--     effect of the INSERTs below, before anything is called by hand.
-- ============================================================================
INSERT INTO suppliers (supplier_name, contact_person, phone, email, lead_time_days, is_active) VALUES
('MedSource Distributors',   'Rohan Mehta',  '9876543210', 'contact@medsource.example',        3, 'Y');
INSERT INTO suppliers (supplier_name, contact_person, phone, email, lead_time_days, is_active) VALUES
('Apex Pharma Supplies',     'Simran Kaur',  '9865321470', 'sales@apexpharma.example',          5, 'Y');
INSERT INTO suppliers (supplier_name, contact_person, phone, email, lead_time_days, is_active) VALUES
('Wellness Wholesale Co.',   'Arjun Nair',   '9911223344', 'orders@wellnesswholesale.example',  7, 'Y');
INSERT INTO suppliers (supplier_name, contact_person, phone, email, lead_time_days, is_active) VALUES
('National Drug House',      'Priya Sharma', '9822334455', 'info@nationaldrughouse.example',    4, 'Y');
INSERT INTO suppliers (supplier_name, contact_person, phone, email, lead_time_days, is_active) VALUES
('Cureline Healthcare Ltd.', 'Karan Verma',  '9900112233', 'procurement@cureline.example',     10, 'Y');

INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Paracetamol 500mg', 'Analgesic', 'Generic Pharma Ltd', 2.50, 100, 300, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'MedSource Distributors';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Ibuprofen 400mg', 'Analgesic', 'Generic Pharma Ltd', 3.00, 80, 250, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'MedSource Distributors';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Aspirin 325mg', 'Analgesic', 'ClearChem Labs', 2.00, 60, 200, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'Apex Pharma Supplies';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Amoxicillin 500mg', 'Antibiotic', 'BioCure Pharmaceuticals', 5.50, 100, 300, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'Apex Pharma Supplies';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Azithromycin 250mg', 'Antibiotic', 'BioCure Pharmaceuticals', 8.00, 50, 150, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'Apex Pharma Supplies';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Ciprofloxacin 500mg', 'Antibiotic', 'MedLife Formulations', 9.50, 30, 100, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'Wellness Wholesale Co.';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Omeprazole 20mg', 'Gastro', 'ClearChem Labs', 4.00, 90, 250, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'MedSource Distributors';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Ranitidine 150mg', 'Gastro', 'MedLife Formulations', 3.50, 20, 60, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'Wellness Wholesale Co.';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Antacid Suspension 200ml', 'Gastro', 'MedLife Formulations', 6.00, 40, 120, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'Wellness Wholesale Co.';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Vitamin C 500mg', 'Vitamins & Supplements', 'NutriWell Labs', 3.20, 100, 300, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'National Drug House';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Multivitamin Daily', 'Vitamins & Supplements', 'NutriWell Labs', 7.50, 60, 180, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'National Drug House';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Vitamin D3 60000IU', 'Vitamins & Supplements', 'NutriWell Labs', 12.00, 25, 80, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'National Drug House';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Amlodipine 5mg', 'Cardiac Care', 'CardioGen Pharma', 4.50, 50, 150, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'Cureline Healthcare Ltd.';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Atorvastatin 10mg', 'Cardiac Care', 'CardioGen Pharma', 6.50, 45, 150, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'Cureline Healthcare Ltd.';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Metformin 500mg', 'Diabetes Care', 'BioCure Pharmaceuticals', 3.80, 100, 300, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'Apex Pharma Supplies';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Insulin Glargine Injection', 'Diabetes Care', 'CardioGen Pharma', 45.00, 15, 40, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'Cureline Healthcare Ltd.';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Cetirizine 10mg', 'Antihistamine', 'Generic Pharma Ltd', 2.80, 90, 250, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'MedSource Distributors';
INSERT INTO products (product_name, category, manufacturer, unit_price, reorder_threshold, reorder_quantity, default_supplier_id, is_active)
SELECT 'Cough Syrup (Dextromethorphan)', 'Cold & Flu', 'MedLife Formulations', 8.50, 35, 100, supplier_id, 'Y' FROM suppliers WHERE supplier_name = 'Wellness Wholesale Co.';

-- STOCK -- 25 batches. The first 6 (all single-batch) start BELOW their
-- product's threshold on purpose, and trg_stock_reorder_check will react to
-- each one as it lands (see the note above this section).
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-RAN-1001', 12, TRUNC(SYSDATE)+40, TRUNC(SYSDATE)-60, 2.10 FROM products WHERE product_name = 'Ranitidine 150mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-CIPRO-1001', 18, TRUNC(SYSDATE)+120, TRUNC(SYSDATE)-45, 6.50 FROM products WHERE product_name = 'Ciprofloxacin 500mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-VITD-1001', 15, TRUNC(SYSDATE)+300, TRUNC(SYSDATE)-30, 8.00 FROM products WHERE product_name = 'Vitamin D3 60000IU';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-INSUL-1001', 8, TRUNC(SYSDATE)+75, TRUNC(SYSDATE)-20, 32.00 FROM products WHERE product_name = 'Insulin Glargine Injection';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-COUGH-1001', 20, TRUNC(SYSDATE)+200, TRUNC(SYSDATE)-15, 5.50 FROM products WHERE product_name = 'Cough Syrup (Dextromethorphan)';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-AZI-1001', 35, TRUNC(SYSDATE)+150, TRUNC(SYSDATE)-25, 5.20 FROM products WHERE product_name = 'Azithromycin 250mg';

INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-PARA-1001', 180, TRUNC(SYSDATE)+250, TRUNC(SYSDATE)-90, 1.60 FROM products WHERE product_name = 'Paracetamol 500mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT p.product_id, s.supplier_id, 'B-PARA-1002', 90, TRUNC(SYSDATE)+60, TRUNC(SYSDATE)-20, 1.65
FROM products p, suppliers s WHERE p.product_name = 'Paracetamol 500mg' AND s.supplier_name = 'Apex Pharma Supplies';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-IBU-1001', 140, TRUNC(SYSDATE)+280, TRUNC(SYSDATE)-70, 1.90 FROM products WHERE product_name = 'Ibuprofen 400mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-IBU-1002', 70, TRUNC(SYSDATE)+100, TRUNC(SYSDATE)-10, 1.95 FROM products WHERE product_name = 'Ibuprofen 400mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-ASP-1001', 150, TRUNC(SYSDATE)+320, TRUNC(SYSDATE)-40, 1.20 FROM products WHERE product_name = 'Aspirin 325mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-AMOX-1001', 160, TRUNC(SYSDATE)+180, TRUNC(SYSDATE)-50, 3.80 FROM products WHERE product_name = 'Amoxicillin 500mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-AMOX-1002', 90, TRUNC(SYSDATE)+85, TRUNC(SYSDATE)-15, 3.90 FROM products WHERE product_name = 'Amoxicillin 500mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-OMEP-1001', 130, TRUNC(SYSDATE)+240, TRUNC(SYSDATE)-60, 2.50 FROM products WHERE product_name = 'Omeprazole 20mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-OMEP-1002', 60, TRUNC(SYSDATE)+400, TRUNC(SYSDATE)-5, 2.55 FROM products WHERE product_name = 'Omeprazole 20mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-ANTAC-1001', 90, TRUNC(SYSDATE)+150, TRUNC(SYSDATE)-35, 3.80 FROM products WHERE product_name = 'Antacid Suspension 200ml';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-VITC-1001', 150, TRUNC(SYSDATE)+300, TRUNC(SYSDATE)-55, 1.80 FROM products WHERE product_name = 'Vitamin C 500mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-VITC-1002', 100, TRUNC(SYSDATE)+500, TRUNC(SYSDATE)-8, 1.75 FROM products WHERE product_name = 'Vitamin C 500mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-MULTI-1001', 120, TRUNC(SYSDATE)+270, TRUNC(SYSDATE)-42, 4.50 FROM products WHERE product_name = 'Multivitamin Daily';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-AMLO-1001', 95, TRUNC(SYSDATE)+330, TRUNC(SYSDATE)-33, 2.60 FROM products WHERE product_name = 'Amlodipine 5mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-ATOR-1001', 80, TRUNC(SYSDATE)+310, TRUNC(SYSDATE)-37, 3.70 FROM products WHERE product_name = 'Atorvastatin 10mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-ATOR-1002', 40, TRUNC(SYSDATE)+70, TRUNC(SYSDATE)-11, 3.75 FROM products WHERE product_name = 'Atorvastatin 10mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-MET-1001', 170, TRUNC(SYSDATE)+260, TRUNC(SYSDATE)-38, 2.10 FROM products WHERE product_name = 'Metformin 500mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-MET-1002', 85, TRUNC(SYSDATE)+95, TRUNC(SYSDATE)-9, 2.15 FROM products WHERE product_name = 'Metformin 500mg';
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, 'B-CETI-1001', 160, TRUNC(SYSDATE)+220, TRUNC(SYSDATE)-31, 1.55 FROM products WHERE product_name = 'Cetirizine 10mg';

-- SALES -- 51 rows over the last ~60 days. Insulin Glargine and Vitamin D3
-- get none at all, on purpose (see Part 2's notes on the resulting NULL
-- days-of-stock-remaining case).
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 25, unit_price, 25*unit_price, TRUNC(SYSDATE)-2  FROM products WHERE product_name='Paracetamol 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 30, unit_price, 30*unit_price, TRUNC(SYSDATE)-9  FROM products WHERE product_name='Paracetamol 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 22, unit_price, 22*unit_price, TRUNC(SYSDATE)-16 FROM products WHERE product_name='Paracetamol 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 28, unit_price, 28*unit_price, TRUNC(SYSDATE)-24 FROM products WHERE product_name='Paracetamol 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 26, unit_price, 26*unit_price, TRUNC(SYSDATE)-33 FROM products WHERE product_name='Paracetamol 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 18, unit_price, 18*unit_price, TRUNC(SYSDATE)-3  FROM products WHERE product_name='Ibuprofen 400mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 20, unit_price, 20*unit_price, TRUNC(SYSDATE)-11 FROM products WHERE product_name='Ibuprofen 400mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 15, unit_price, 15*unit_price, TRUNC(SYSDATE)-19 FROM products WHERE product_name='Ibuprofen 400mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 22, unit_price, 22*unit_price, TRUNC(SYSDATE)-27 FROM products WHERE product_name='Ibuprofen 400mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 17, unit_price, 17*unit_price, TRUNC(SYSDATE)-40 FROM products WHERE product_name='Ibuprofen 400mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 20, unit_price, 20*unit_price, TRUNC(SYSDATE)-1  FROM products WHERE product_name='Amoxicillin 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 24, unit_price, 24*unit_price, TRUNC(SYSDATE)-8  FROM products WHERE product_name='Amoxicillin 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 18, unit_price, 18*unit_price, TRUNC(SYSDATE)-15 FROM products WHERE product_name='Amoxicillin 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 26, unit_price, 26*unit_price, TRUNC(SYSDATE)-22 FROM products WHERE product_name='Amoxicillin 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 21, unit_price, 21*unit_price, TRUNC(SYSDATE)-35 FROM products WHERE product_name='Amoxicillin 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 16, unit_price, 16*unit_price, TRUNC(SYSDATE)-4  FROM products WHERE product_name='Omeprazole 20mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 19, unit_price, 19*unit_price, TRUNC(SYSDATE)-12 FROM products WHERE product_name='Omeprazole 20mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 14, unit_price, 14*unit_price, TRUNC(SYSDATE)-20 FROM products WHERE product_name='Omeprazole 20mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 17, unit_price, 17*unit_price, TRUNC(SYSDATE)-29 FROM products WHERE product_name='Omeprazole 20mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 15, unit_price, 15*unit_price, TRUNC(SYSDATE)-45 FROM products WHERE product_name='Omeprazole 20mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 20, unit_price, 20*unit_price, TRUNC(SYSDATE)-5  FROM products WHERE product_name='Vitamin C 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 24, unit_price, 24*unit_price, TRUNC(SYSDATE)-13 FROM products WHERE product_name='Vitamin C 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 18, unit_price, 18*unit_price, TRUNC(SYSDATE)-21 FROM products WHERE product_name='Vitamin C 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 22, unit_price, 22*unit_price, TRUNC(SYSDATE)-30 FROM products WHERE product_name='Vitamin C 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 19, unit_price, 19*unit_price, TRUNC(SYSDATE)-50 FROM products WHERE product_name='Vitamin C 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 22, unit_price, 22*unit_price, TRUNC(SYSDATE)-2  FROM products WHERE product_name='Metformin 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 25, unit_price, 25*unit_price, TRUNC(SYSDATE)-10 FROM products WHERE product_name='Metformin 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 20, unit_price, 20*unit_price, TRUNC(SYSDATE)-18 FROM products WHERE product_name='Metformin 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 24, unit_price, 24*unit_price, TRUNC(SYSDATE)-26 FROM products WHERE product_name='Metformin 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 21, unit_price, 21*unit_price, TRUNC(SYSDATE)-38 FROM products WHERE product_name='Metformin 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 15, unit_price, 15*unit_price, TRUNC(SYSDATE)-6  FROM products WHERE product_name='Cetirizine 10mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 18, unit_price, 18*unit_price, TRUNC(SYSDATE)-14 FROM products WHERE product_name='Cetirizine 10mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 13, unit_price, 13*unit_price, TRUNC(SYSDATE)-23 FROM products WHERE product_name='Cetirizine 10mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 16, unit_price, 16*unit_price, TRUNC(SYSDATE)-31 FROM products WHERE product_name='Cetirizine 10mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 14, unit_price, 14*unit_price, TRUNC(SYSDATE)-48 FROM products WHERE product_name='Cetirizine 10mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 12, unit_price, 12*unit_price, TRUNC(SYSDATE)-10 FROM products WHERE product_name='Aspirin 325mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 15, unit_price, 15*unit_price, TRUNC(SYSDATE)-35 FROM products WHERE product_name='Aspirin 325mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 8,  unit_price, 8*unit_price,  TRUNC(SYSDATE)-7  FROM products WHERE product_name='Azithromycin 250mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 10, unit_price, 10*unit_price, TRUNC(SYSDATE)-28 FROM products WHERE product_name='Azithromycin 250mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 10, unit_price, 10*unit_price, TRUNC(SYSDATE)-12 FROM products WHERE product_name='Antacid Suspension 200ml';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 9,  unit_price, 9*unit_price,  TRUNC(SYSDATE)-40 FROM products WHERE product_name='Antacid Suspension 200ml';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 12, unit_price, 12*unit_price, TRUNC(SYSDATE)-15 FROM products WHERE product_name='Multivitamin Daily';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 11, unit_price, 11*unit_price, TRUNC(SYSDATE)-42 FROM products WHERE product_name='Multivitamin Daily';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 9,  unit_price, 9*unit_price,  TRUNC(SYSDATE)-9  FROM products WHERE product_name='Amlodipine 5mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 8,  unit_price, 8*unit_price,  TRUNC(SYSDATE)-33 FROM products WHERE product_name='Amlodipine 5mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 7,  unit_price, 7*unit_price,  TRUNC(SYSDATE)-11 FROM products WHERE product_name='Atorvastatin 10mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 9,  unit_price, 9*unit_price,  TRUNC(SYSDATE)-37 FROM products WHERE product_name='Atorvastatin 10mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 10, unit_price, 10*unit_price, TRUNC(SYSDATE)-6  FROM products WHERE product_name='Cough Syrup (Dextromethorphan)';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 8,  unit_price, 8*unit_price,  TRUNC(SYSDATE)-20 FROM products WHERE product_name='Cough Syrup (Dextromethorphan)';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 5, unit_price, 5*unit_price, TRUNC(SYSDATE)-25 FROM products WHERE product_name='Ciprofloxacin 500mg';
INSERT INTO sales (product_id, quantity_sold, unit_price, total_amount, sale_date) SELECT product_id, 3, unit_price, 3*unit_price, TRUNC(SYSDATE)-45 FROM products WHERE product_name='Ranitidine 150mg';

COMMIT;

-- Quick self-check: should show the same 6 products flagged BELOW THRESHOLD
-- as Part 1 (Ranitidine, Ciprofloxacin, Vitamin D3, Insulin Glargine, Cough
-- Syrup, Azithromycin), and PURCHASE_ORDERS (queried further below) should
-- already hold 4 auto-created orders covering exactly those 6 products.
SELECT p.product_name, p.reorder_threshold, NVL(SUM(s.quantity_on_hand),0) AS total_stock,
       CASE WHEN NVL(SUM(s.quantity_on_hand),0) < p.reorder_threshold THEN 'BELOW THRESHOLD' ELSE 'OK' END AS status
FROM   products p LEFT JOIN stock s ON s.product_id = p.product_id
GROUP BY p.product_name, p.reorder_threshold
ORDER BY status DESC, p.product_name;

SELECT po.po_id, s.supplier_name, po.status, po.total_amount
FROM   purchase_orders po JOIN suppliers s ON s.supplier_id = po.supplier_id
ORDER BY po.po_id;


-- ============================================================================
-- SECTION 8: CO5 LOG TABLE AND TEST OBJECTS
-- Dropped and recreated fresh above (with the other tables), unlike Part
-- 6's own standalone file, which preserves history across independent
-- re-runs -- see the judgment-calls note in the chat reply for why.
-- ============================================================================
CREATE TABLE concurrency_test_log (
    run_id         NUMBER GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    session_info   VARCHAR2(128),
    attempted_qty  NUMBER,
    result         VARCHAR2(20),
    message        VARCHAR2(4000),
    log_time       TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT pk_concurrency_test_log PRIMARY KEY (run_id)
);

CREATE OR REPLACE PROCEDURE run_concurrent_sale_test (
    p_product_id    IN NUMBER,
    p_quantity      IN NUMBER,
    p_session_label IN VARCHAR2
)
IS
    v_sale_id  NUMBER;
    v_sid      VARCHAR2(20) := SYS_CONTEXT('USERENV','SID');
BEGIN
    BEGIN
        process_sale(p_product_id => p_product_id, p_quantity => p_quantity, p_sale_id => v_sale_id);
        INSERT INTO concurrency_test_log (session_info, attempted_qty, result, message)
        VALUES (p_session_label || ' (SID ' || v_sid || ')', p_quantity, 'SUCCESS', 'sale_id ' || v_sale_id);
    EXCEPTION
        WHEN OTHERS THEN
            INSERT INTO concurrency_test_log (session_info, attempted_qty, result, message)
            VALUES (p_session_label || ' (SID ' || v_sid || ')', p_quantity, 'FAILED', SQLERRM);
    END;
    COMMIT;  -- this IS an independent scheduler-job session -- no caller transaction to respect
END run_concurrent_sale_test;
/

-- ============================================================================
-- DEPLOYMENT COMPLETE. Run 09_smoke_test.sql next.
-- ============================================================================
