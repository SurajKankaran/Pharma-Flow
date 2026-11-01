"""Thin Oracle access layer. python-oracledb runs in thin mode: no Oracle Client install needed."""
import os
import re
from contextlib import contextmanager

import oracledb

try:  # optional: load .env if python-dotenv is installed
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

_pool = None


def pool():
    global _pool
    if _pool is None:
        _pool = oracledb.create_pool(
            user=os.environ.get("ORACLE_USER", "pharmacy"),
            password=os.environ.get("ORACLE_PASSWORD", ""),
            dsn=os.environ.get("ORACLE_DSN", "localhost:1521/XEPDB1"),
            min=1, max=8, increment=1,
        )
    return _pool


@contextmanager
def connect():
    """Borrow a connection. Anything not committed is rolled back on the way out."""
    conn = pool().acquire()
    try:
        yield conn
    finally:
        try:
            conn.rollback()
        finally:
            pool().release(conn)


def rows(cur):
    cols = [d[0].lower() for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def query(sql, **params):
    with connect() as conn:
        cur = conn.cursor()
        cur.execute(sql, params)
        return rows(cur)


def one(sql, **params):
    r = query(sql, **params)
    return r[0] if r else {}


def enable_output(cur):
    """Turn on DBMS_OUTPUT for this session so trigger/procedure messages can be shown in the UI."""
    cur.callproc("dbms_output.enable", [1000000])


def drain_output(cur):
    lines, line, status = [], cur.var(str), cur.var(int)
    while True:
        cur.callproc("dbms_output.get_line", (line, status))
        if status.getvalue() != 0:
            break
        lines.append(line.getvalue() or "")
    return lines


def friendly(err):
    """Reduce an Oracle error to one readable sentence (our own ORA-200xx messages lose the prefix)."""
    msg = str(err).strip().split("\n")[0]
    m = re.search(r"ORA-(\d{5}): (.*)", msg)
    if not m:
        return msg
    code, text = m.groups()
    return text.strip() if code.startswith("200") else f"ORA-{code}: {text.strip()}"
