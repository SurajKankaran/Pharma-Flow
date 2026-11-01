"""All SQL used by the UI, in one place. Business rules live in the PL/SQL, not here."""

PENDING_COUNT = "SELECT COUNT(*) AS n FROM purchase_orders WHERE status = 'PENDING'"

KPI = """
SELECT
  (SELECT COUNT(*) FROM products WHERE is_active = 'Y')                              AS products,
  (SELECT NVL(SUM(quantity_on_hand), 0) FROM stock)                                  AS units,
  (SELECT COUNT(*) FROM (SELECT p.product_id FROM products p
                          LEFT JOIN stock s ON s.product_id = p.product_id
                          WHERE p.is_active = 'Y'
                          GROUP BY p.product_id, p.reorder_threshold
                          HAVING NVL(SUM(s.quantity_on_hand), 0) < p.reorder_threshold)) AS low_count,
  (SELECT COUNT(*) FROM stock WHERE near_expiry_flag = 'Y' AND quantity_on_hand > 0) AS near_expiry,
  (SELECT COUNT(*) FROM purchase_orders WHERE status = 'PENDING')                    AS pending_pos,
  (SELECT NVL(SUM(total_amount), 0) FROM sales WHERE sale_date >= TRUNC(SYSDATE))    AS today_revenue
FROM dual"""

LOW_STOCK = """
SELECT p.product_id, p.product_name, sp.supplier_name, p.reorder_threshold,
       NVL(st.qty, 0) AS stock,
       get_days_of_stock_remaining(p.product_id) AS days_left,
       (SELECT COUNT(*) FROM purchase_order_items poi
          JOIN purchase_orders po ON po.po_id = poi.po_id
         WHERE poi.product_id = p.product_id AND po.status = 'PENDING') AS on_order
FROM products p
JOIN suppliers sp ON sp.supplier_id = p.default_supplier_id
LEFT JOIN (SELECT product_id, SUM(quantity_on_hand) AS qty FROM stock GROUP BY product_id) st
       ON st.product_id = p.product_id
WHERE p.is_active = 'Y' AND NVL(st.qty, 0) < p.reorder_threshold
ORDER BY (p.reorder_threshold - NVL(st.qty, 0)) DESC"""

EXPIRING = """
SELECT p.product_name, s.batch_no, s.quantity_on_hand, s.expiry_date,
       TRUNC(s.expiry_date) - TRUNC(SYSDATE) AS days_left
FROM stock s JOIN products p ON p.product_id = s.product_id
WHERE s.near_expiry_flag = 'Y' AND s.quantity_on_hand > 0
ORDER BY s.expiry_date"""

PENDING_POS = """
SELECT po.po_id, sp.supplier_name, po.total_amount, po.expected_delivery_date,
       (SELECT COUNT(*) FROM purchase_order_items i WHERE i.po_id = po.po_id) AS lines
FROM purchase_orders po JOIN suppliers sp ON sp.supplier_id = po.supplier_id
WHERE po.status = 'PENDING' ORDER BY po.po_id DESC"""

PRODUCT_OPTIONS = """
SELECT p.product_id, p.product_name, p.unit_price,
       NVL((SELECT SUM(s.quantity_on_hand) FROM stock s
             WHERE s.product_id = p.product_id AND s.expiry_date >= TRUNC(SYSDATE)), 0) AS sellable
FROM products p WHERE p.is_active = 'Y' ORDER BY p.product_name"""

PRODUCTS = """
SELECT p.product_id, p.product_name, p.category, p.unit_price, p.reorder_threshold, p.reorder_quantity,
       sp.supplier_name, NVL(st.qty, 0) AS stock, NVL(st.batch_count, 0) AS batch_count, st.next_expiry
FROM products p
JOIN suppliers sp ON sp.supplier_id = p.default_supplier_id
LEFT JOIN (SELECT product_id, SUM(quantity_on_hand) AS qty, COUNT(*) AS batch_count,
                  MIN(CASE WHEN quantity_on_hand > 0 THEN expiry_date END) AS next_expiry
             FROM stock GROUP BY product_id) st ON st.product_id = p.product_id
WHERE p.is_active = 'Y' ORDER BY p.product_name"""

BATCHES = """
SELECT s.stock_id, p.product_name, s.batch_no, s.quantity_on_hand, s.expiry_date,
       TRUNC(s.expiry_date) - TRUNC(SYSDATE) AS days_to_expiry, s.near_expiry_flag,
       s.unit_cost, s.date_received, sp.supplier_name
FROM stock s
JOIN products p  ON p.product_id  = s.product_id
JOIN suppliers sp ON sp.supplier_id = s.supplier_id
ORDER BY s.expiry_date, p.product_name"""

INSERT_BATCH = """
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT product_id, default_supplier_id, :batch_no, :qty, TO_DATE(:expiry, 'YYYY-MM-DD'), SYSDATE, :cost
FROM products WHERE product_id = :pid"""

SALES = """
SELECT sa.sale_id, p.product_name, sa.quantity_sold, sa.unit_price, sa.total_amount,
       sa.sale_date, s.batch_no, sa.stock_id
FROM sales sa
JOIN products p ON p.product_id = sa.product_id
LEFT JOIN stock s ON s.stock_id = sa.stock_id
ORDER BY sa.sale_date DESC, sa.sale_id DESC
FETCH FIRST 30 ROWS ONLY"""

PURCHASE_ORDERS = """
SELECT po.po_id, sp.supplier_name, po.status, po.order_date, po.expected_delivery_date, po.total_amount
FROM purchase_orders po JOIN suppliers sp ON sp.supplier_id = po.supplier_id
ORDER BY po.po_id DESC"""

PO_ITEMS = """
SELECT poi.po_id, p.product_name, poi.quantity_ordered, poi.unit_cost,
       poi.quantity_ordered * poi.unit_cost AS line_total
FROM purchase_order_items poi JOIN products p ON p.product_id = poi.product_id
ORDER BY poi.po_id, p.product_name"""

RECEIVE_PO = """
INSERT INTO stock (product_id, supplier_id, batch_no, quantity_on_hand, expiry_date, date_received, unit_cost)
SELECT poi.product_id, po.supplier_id, 'PO' || po.po_id || '-' || poi.product_id, poi.quantity_ordered,
       ADD_MONTHS(TRUNC(SYSDATE), :months), SYSDATE, poi.unit_cost
FROM purchase_order_items poi JOIN purchase_orders po ON po.po_id = poi.po_id
WHERE po.po_id = :po_id"""
