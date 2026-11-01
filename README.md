# PharmaFlow: Flask front end for the Pharmacy Inventory project

A web interface for the Oracle PL/SQL system (products, batch-level stock, sales, auto-reordering).
The Flask app holds no business rules. Every sale, reorder and void runs through the PL/SQL
procedures and triggers, so the screens show what the database really does.

## Setup

1. **Deploy the database objects** in an Oracle 19c/21c schema: run `sql/08_final_deploy_all.sql`,
   then (optionally) `sql/09_smoke_test.sql` and expect `5 passed, 0 failed`.
2. **Install and configure**
   ```
   python -m venv .venv
   .venv\Scripts\activate          # macOS/Linux: source .venv/bin/activate
   pip install -r requirements.txt
   copy .env.example .env          # macOS/Linux: cp .env.example .env   (then edit it)
   ```
3. **Run:** `python app.py`, then open http://127.0.0.1:5000

`python-oracledb` runs in thin mode, so no Oracle Client is needed. The DSN looks like
`localhost:1521/XEPDB1` (host:port/service_name).

## Screens and what they exercise

| Screen | What it shows | Course outcome |
|---|---|---|
| Dashboard | Low stock with a gauge per product (tick = reorder level), expiring batches, open orders | CO1 |
| Reports | Low stock by supplier via `get_low_stock_report_rc`; a button that runs the explicit-cursor `print_low_stock_report` and shows its console output | CO1 |
| Purchase orders | Preview or run `generate_purchase_order`; receive an order into stock; cancel | CO2 |
| Sales | `process_sale` with FEFO batch selection and friendly errors; `void_sale` | CO3 |
| Inventory | Receive a batch or change a batch quantity: the STOCK triggers fire and the UI shows what they did | CO4 |
| Concurrency lab | Two scheduler jobs sell the same product at once, with a pass/fail verdict | CO5 |

Things worth trying live:
- **Sales:** sell more than is in stock, or type `2.5` or `-3` as the quantity. The database rejects it and nothing changes.
- **Inventory, Batches:** lower a batch quantity under its product's reorder level. An "Automation" message reports the purchase order the trigger raised.
- **Concurrency lab:** two sessions each ask for 7 of something with 12 on hand. One sells, one is turned away.

## Notes

- Currency is shown as rupees (`₹`) in the interface only; the database stores plain numbers.
- The lab needs the `CREATE JOB` privilege. It restores the stock and removes its test sales
  unless you tick "Keep the results". An automatic purchase order raised during the test is not undone.
- "Mark received" on an order inserts one stock batch per line (batch `PO<id>-<product>`) with the
  shelf life you give. That is a UI convenience; the SQL project itself stops at raising the order.
- This is a development server with a default secret key. Set `FLASK_SECRET_KEY` in `.env`, and put
  the app behind a real WSGI server and a login before anything beyond a lab.
- `python test_render.py` renders every page against a stubbed database to catch template mistakes
  without Oracle. It does not test the SQL.
