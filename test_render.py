"""Offline check: renders every page with a stubbed database so template/route mistakes show up
without needing Oracle. Run:  python test_render.py"""
import sys, types

class R(dict):                      # any missing column reads as 1 (works for text, numbers and loops)
    def __missing__(self, k): return 1

fake = types.ModuleType("oracledb")
class Error(Exception): pass
fake.Error = Error; fake.DatabaseError = Error
sys.modules["oracledb"] = fake

import db
db.query = lambda sql, **p: [R(po_id=1, supplier_name="S", status="PENDING")]
db.one = lambda sql, **p: R()
import app as A

class V:
    def getvalue(self): return 0          # DBMS_OUTPUT status 0 = a line, so also end the loop below
class FakeConn:
    def cursor(self): return self
    def callproc(self, *a, **k): pass
    def execute(self, *a, **k): pass
    def var(self, t): return V()
db.rows = lambda cur: [R(supplier_name="S")]
db.drain_output = lambda cur: ["line one", "line two"]
db.enable_output = lambda cur: None
class Ctx:
    def __enter__(self): return FakeConn()
    def __exit__(self, *a): return False
db.connect = lambda: Ctx()

c = A.app.test_client()
bad = 0
for url in ["/", "/inventory", "/inventory?tab=batches", "/sales", "/orders", "/reports", "/lab"]:
    r = c.get(url); ok = r.status_code == 200; bad += not ok
    print(("ok  " if ok else "FAIL"), url, r.status_code)
for url in ["/reports/console", "/orders/generate"]:
    r = c.post(url, data={"mode": "dry"}); ok = r.status_code == 200; bad += not ok
    print(("ok  " if ok else "FAIL"), "POST", url, r.status_code)
sys.exit(bad)
