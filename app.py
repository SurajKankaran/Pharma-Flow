"""PharmaFlow: Flask front end for the Pharmacy Inventory with Auto-Reordering PL/SQL project.

The UI only calls the database objects built in sql/08_final_deploy_all.sql
(process_sale, void_sale, generate_purchase_order, get_low_stock_report_rc,
print_low_stock_report, run_concurrent_sale_test). The business rules stay in PL/SQL.
"""
import os
import time
import uuid
from datetime import datetime

import oracledb
from flask import Flask, flash, redirect, render_template, request, url_for

import db
import queries as q

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET_KEY", "dev-only-change-me")


# ---------- template helpers ----------
@app.template_filter("money")
def money(v):
    try:
        return f"₹{float(v):,.2f}"
    except (TypeError, ValueError):
        return "—"


@app.template_filter("fdate")
def fdate(v, fmt="%d %b %Y"):
    if hasattr(v, "strftime"):
        return v.strftime(fmt)
    return "—" if v is None else v


@app.context_processor
def template_globals():
    try:
        pending = db.one(q.PENDING_COUNT).get("n", 0)
    except Exception:  # database down: the page itself will show the real error
        pending = None
    return {"nav_pending": pending, "now": datetime.now()}


@app.errorhandler(oracledb.Error)
def database_error(e):
    return render_template("error.html", message=db.friendly(e), active=None), 500


def num(text):
    """Parse a typed number. Whole values become ints so Oracle receives 7, not 7.0."""
    v = float(text)
    return int(v) if v == int(v) else v


def flash_automation(lines):
    for line in lines:
        if line.strip():
            flash(f"Automation: {line.strip()}", "info")


# ---------- dashboard ----------
@app.route("/")
def dashboard():
    return render_template(
        "dashboard.html", active="dashboard", kpi=db.one(q.KPI),
        low=db.query(q.LOW_STOCK)[:8], expiring=db.query(q.EXPIRING)[:6],
        recent=db.query(q.SALES)[:6], pending=db.query(q.PENDING_POS)[:5],
    )


# ---------- inventory ----------
@app.route("/inventory")
def inventory():
    return render_template(
        "inventory.html", active="inventory", tab=request.args.get("tab", "products"),
        products=db.query(q.PRODUCTS), batches=db.query(q.BATCHES), options=db.query(q.PRODUCT_OPTIONS),
    )


@app.post("/inventory/receive")
def receive_stock():
    f = request.form
    try:
        with db.connect() as conn:
            cur = conn.cursor()
            db.enable_output(cur)
            cur.execute(q.INSERT_BATCH, dict(
                batch_no=f["batch_no"].strip(), qty=int(f["quantity"]), expiry=f["expiry_date"],
                cost=float(f["unit_cost"]), pid=int(f["product_id"])))
            lines = db.drain_output(cur)  # messages from the STOCK triggers
            conn.commit()
        flash(f"Batch {f['batch_no'].strip()} received.", "success")
        flash_automation(lines)
    except ValueError:
        flash("Check the quantity and unit cost: they must be numbers.", "error")
    except oracledb.DatabaseError as e:
        flash(db.friendly(e), "error")
    return redirect(url_for("inventory", tab="batches"))


@app.post("/inventory/adjust")
def adjust_stock():
    f = request.form
    try:
        with db.connect() as conn:
            cur = conn.cursor()
            db.enable_output(cur)
            cur.execute("UPDATE stock SET quantity_on_hand = :q WHERE stock_id = :id",
                        q=int(f["quantity"]), id=int(f["stock_id"]))
            lines = db.drain_output(cur)
            conn.commit()
        flash("Quantity updated.", "success")
        flash_automation(lines)
    except ValueError:
        flash("Enter a whole number for the quantity.", "error")
    except oracledb.DatabaseError as e:
        flash(db.friendly(e), "error")
    return redirect(url_for("inventory", tab="batches"))


# ---------- sales ----------
@app.route("/sales")
def sales():
    return render_template("sales.html", active="sales",
                           options=db.query(q.PRODUCT_OPTIONS), sales=db.query(q.SALES))


@app.post("/sales/new")
def new_sale():
    f = request.form
    try:
        qty = num(f["quantity"])
        price = num(f["unit_price"]) if f.get("unit_price", "").strip() else None
        with db.connect() as conn:
            cur = conn.cursor()
            db.enable_output(cur)
            sale_id = cur.var(int)
            cur.callproc("process_sale", keyword_parameters={
                "p_product_id": int(f["product_id"]), "p_quantity": qty,
                "p_unit_price": price, "p_sale_id": sale_id})
            lines = db.drain_output(cur)
        sid = int(sale_id.getvalue())
        total = db.one("SELECT total_amount FROM sales WHERE sale_id = :i", i=sid).get("total_amount")
        flash(f"Sale #{sid} recorded: {money(total)}.", "success")
        flash_automation(lines)
    except ValueError:
        flash("Enter the quantity and price as numbers.", "error")
    except oracledb.DatabaseError as e:
        flash(db.friendly(e), "error")
    return redirect(url_for("sales"))


@app.post("/sales/<int:sale_id>/void")
def void_sale(sale_id):
    try:
        with db.connect() as conn:
            conn.cursor().callproc("void_sale", [sale_id])
        flash(f"Sale #{sale_id} voided and its stock restored.", "success")
    except oracledb.DatabaseError as e:
        flash(db.friendly(e), "error")
    return redirect(url_for("sales"))


# ---------- purchase orders ----------
def orders_context(**extra):
    items = {}
    for r in db.query(q.PO_ITEMS):
        items.setdefault(r["po_id"], []).append(r)
    return dict(active="orders", pos=db.query(q.PURCHASE_ORDERS), items=items, **extra)


@app.route("/orders")
def orders():
    return render_template("orders.html", **orders_context(console=None))


@app.post("/orders/generate")
def generate_orders():
    dry = request.form.get("mode") == "dry"
    try:
        with db.connect() as conn:
            cur = conn.cursor()
            db.enable_output(cur)
            cur.execute(f"BEGIN generate_purchase_order(p_dry_run => {'TRUE' if dry else 'FALSE'}); END;")
            lines = db.drain_output(cur)
    except oracledb.DatabaseError as e:
        flash(db.friendly(e), "error")
        return redirect(url_for("orders"))
    title = "Preview: nothing was saved" if dry else "Auto-reorder run"
    return render_template("orders.html", **orders_context(console=lines, console_title=title))


@app.post("/orders/<int:po_id>/receive")
def receive_po(po_id):
    try:
        months = int(request.form.get("shelf_months", 24))
        with db.connect() as conn:
            cur = conn.cursor()
            cur.execute("SELECT status FROM purchase_orders WHERE po_id = :i FOR UPDATE", i=po_id)
            row = cur.fetchone()
            if not row or row[0] not in ("PENDING", "APPROVED"):
                flash("Only pending or approved orders can be received.", "error")
                return redirect(url_for("orders"))
            cur.execute(q.RECEIVE_PO, dict(months=months, po_id=po_id))
            added = cur.rowcount
            cur.execute("UPDATE purchase_orders SET status = 'RECEIVED' WHERE po_id = :i", i=po_id)
            conn.commit()
        flash(f"Order #{po_id} received: {added} batch(es) added to stock.", "success")
    except ValueError:
        flash("Enter the shelf life as a whole number of months.", "error")
    except oracledb.DatabaseError as e:
        flash(db.friendly(e), "error")
    return redirect(url_for("orders"))


@app.post("/orders/<int:po_id>/cancel")
def cancel_po(po_id):
    with db.connect() as conn:
        cur = conn.cursor()
        cur.execute("UPDATE purchase_orders SET status = 'CANCELLED' "
                    "WHERE po_id = :i AND status IN ('PENDING', 'APPROVED')", i=po_id)
        done = cur.rowcount
        conn.commit()
    flash(f"Order #{po_id} cancelled." if done else "That order can no longer be cancelled.",
          "success" if done else "error")
    return redirect(url_for("orders"))


# ---------- reports ----------
def reports_context(**extra):
    with db.connect() as conn:
        cur, rc = conn.cursor(), conn.cursor()
        cur.callproc("get_low_stock_report_rc", [rc])  # CO1 ref-cursor report
        low = db.rows(rc)
    grouped = {}
    for r in low:
        grouped.setdefault(r["supplier_name"], []).append(r)
    return dict(active="reports", grouped=grouped, expiring=db.query(q.EXPIRING), **extra)


@app.route("/reports")
def reports():
    return render_template("reports.html", **reports_context(console=None))


@app.post("/reports/console")
def report_console():
    with db.connect() as conn:
        cur = conn.cursor()
        db.enable_output(cur)
        cur.callproc("print_low_stock_report")  # CO1 explicit-cursor report
        lines = db.drain_output(cur)
    return render_template("reports.html", **reports_context(console=lines))


# ---------- concurrency lab (CO5) ----------
def run_lab(f):
    pid, qa, qb = int(f["product_id"]), int(f["qty_a"]), int(f["qty_b"])
    keep = bool(f.get("keep"))
    tag = uuid.uuid4().hex[:6].upper()
    with db.connect() as conn:
        cur = conn.cursor()
        cur.execute("SELECT stock_id, quantity_on_hand FROM stock WHERE product_id = :p", p=pid)
        before = cur.fetchall()
        total_before = sum(r[1] for r in before)
        cur.execute("SELECT SYSDATE FROM dual")
        started = cur.fetchone()[0]

        # Two independent database sessions, scheduled for the same instant.
        cur.execute(
            """DECLARE v_start TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP + INTERVAL '3' SECOND;
               BEGIN
                 DBMS_SCHEDULER.CREATE_JOB(job_name => :ja, job_type => 'PLSQL_BLOCK', job_action => :aa,
                                           start_date => v_start, enabled => TRUE, auto_drop => TRUE);
                 DBMS_SCHEDULER.CREATE_JOB(job_name => :jb, job_type => 'PLSQL_BLOCK', job_action => :ab,
                                           start_date => v_start, enabled => TRUE, auto_drop => TRUE);
               END;""",
            dict(ja=f"LAB_A_{tag}", jb=f"LAB_B_{tag}",
                 aa=f"BEGIN run_concurrent_sale_test({pid}, {qa}, 'Lab A {tag}'); END;",
                 ab=f"BEGIN run_concurrent_sale_test({pid}, {qb}, 'Lab B {tag}'); END;"))

        for _ in range(25):  # wait for both sessions to log their outcome
            time.sleep(1)
            cur.execute("SELECT COUNT(*) FROM concurrency_test_log WHERE session_info LIKE :p", p=f"%{tag}%")
            if cur.fetchone()[0] >= 2:
                break

        cur.execute("""SELECT session_info, attempted_qty, result, message, log_time
                         FROM concurrency_test_log WHERE session_info LIKE :p ORDER BY log_time""", p=f"%{tag}%")
        log = db.rows(cur)
        cur.execute("SELECT NVL(SUM(quantity_on_hand), 0) FROM stock WHERE product_id = :p", p=pid)
        final = cur.fetchone()[0]

        if not keep:  # put stock back and remove the test sales
            for stock_id, qty in before:
                cur.execute("UPDATE stock SET quantity_on_hand = :q WHERE stock_id = :s", q=qty, s=stock_id)
            cur.execute("DELETE FROM sales WHERE product_id = :p AND sale_date >= :t", p=pid, t=started)
            conn.commit()

    sold = sum(r["attempted_qty"] for r in log if r["result"] == "SUCCESS")
    return dict(log=log, before=total_before, final=final, sold=sold, kept=keep, finished=len(log) == 2,
                ok=len(log) == 2 and final >= 0 and final == total_before - sold)


@app.route("/lab", methods=["GET", "POST"])
def lab():
    result = None
    if request.method == "POST":
        try:
            result = run_lab(request.form)
        except ValueError:
            flash("Enter whole numbers for both quantities.", "error")
        except oracledb.DatabaseError as e:
            flash(db.friendly(e) + " (the lab needs the CREATE JOB privilege)", "error")
    return render_template("lab.html", active="lab", options=db.query(q.PRODUCT_OPTIONS), result=result)


if __name__ == "__main__":
    app.run(debug=os.environ.get("FLASK_DEBUG") == "1")
