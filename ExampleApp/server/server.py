#!/usr/bin/env python3
"""Minimal SignalKit demo backend: HTTP + SQLite, no dependencies.

Proves the two contracts SignalKit's README asks a host to honour:
  * health totals upsert by (account, date, type) and reject a stale recordedAt
  * tracking events dedupe by the client-generated UUID, so at-least-once
    delivery cannot double-apply

`/v1/admin/offline` flips the server into 503 mode so the client outbox can be
observed retaining work and replaying it when the server comes back.
"""
import json
import sqlite3
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DB_PATH = Path(__file__).with_name("signalkit_demo.sqlite")
LOCK = threading.Lock()
STATE = {"offline": False}

SCHEMA = """
CREATE TABLE IF NOT EXISTS health_aggregates (
    account     TEXT NOT NULL,
    date        TEXT NOT NULL,
    type        TEXT NOT NULL,
    value       REAL NOT NULL,
    unit        TEXT NOT NULL,
    recorded_at REAL NOT NULL,
    server_at   REAL NOT NULL DEFAULT (strftime('%s','now')),
    revisions   INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (account, date, type)
);
CREATE TABLE IF NOT EXISTS tracking_events (
    id        TEXT PRIMARY KEY,
    account   TEXT NOT NULL,
    kind      TEXT NOT NULL,
    fields    TEXT NOT NULL,
    server_at REAL NOT NULL DEFAULT (strftime('%s','now'))
);
CREATE TABLE IF NOT EXISTS location_samples (
    event_id        TEXT PRIMARY KEY REFERENCES tracking_events(id),
    account         TEXT NOT NULL,
    client_outing_id TEXT,
    ts              REAL NOT NULL,
    lat             REAL NOT NULL,
    lng             REAL NOT NULL,
    accuracy        REAL,
    source          TEXT,
    speed           REAL
);
CREATE TABLE IF NOT EXISTS client_status (
    account   TEXT PRIMARY KEY,
    status    TEXT NOT NULL,
    server_at REAL NOT NULL DEFAULT (strftime('%s','now'))
);
CREATE TABLE IF NOT EXISTS request_log (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    path      TEXT NOT NULL,
    status    INTEGER NOT NULL,
    n         INTEGER NOT NULL,
    server_at REAL NOT NULL DEFAULT (strftime('%s','now'))
);
"""


def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def upsert_health(account, records):
    applied = stale = 0
    with db() as conn:
        for r in records:
            cur = conn.execute(
                "SELECT recorded_at FROM health_aggregates WHERE account=? AND date=? AND type=?",
                (account, r["date"], r["type"]),
            ).fetchone()
            if cur and cur["recorded_at"] > float(r["recordedAt"]):
                stale += 1  # a replay of an older revision must never win
                continue
            conn.execute(
                """INSERT INTO health_aggregates (account,date,type,value,unit,recorded_at)
                   VALUES (?,?,?,?,?,?)
                   ON CONFLICT(account,date,type) DO UPDATE SET
                     value=excluded.value, unit=excluded.unit,
                     recorded_at=excluded.recorded_at,
                     server_at=strftime('%s','now'),
                     revisions=health_aggregates.revisions+1""",
                (account, r["date"], r["type"], float(r["value"]), r["unit"], float(r["recordedAt"])),
            )
            applied += 1
    return {"applied": applied, "rejected_stale": stale}


def insert_events(account, events):
    applied = duplicate = 0
    with db() as conn:
        for e in events:
            cur = conn.execute(
                "INSERT OR IGNORE INTO tracking_events (id,account,kind,fields) VALUES (?,?,?,?)",
                (e["id"], account, e["kind"], json.dumps(e.get("fields") or {})),
            )
            if cur.rowcount == 0:
                duplicate += 1  # at-least-once replay, already applied
                continue
            applied += 1
            s = e.get("sample")
            if s:
                conn.execute(
                    """INSERT OR IGNORE INTO location_samples
                       (event_id,account,client_outing_id,ts,lat,lng,accuracy,source,speed)
                       VALUES (?,?,?,?,?,?,?,?,?)""",
                    (e["id"], account, s.get("clientOutingId"), s["timestamp"], s["lat"],
                     s["lng"], s.get("accuracy"), s.get("source"), s.get("speed")),
                )
    return {"applied": applied, "duplicates_ignored": duplicate}


def stats():
    with db() as conn:
        health = [dict(r) for r in conn.execute(
            "SELECT date,type,value,unit,revisions FROM health_aggregates ORDER BY date DESC, type")]
        kinds = [dict(r) for r in conn.execute(
            "SELECT kind, COUNT(*) n FROM tracking_events GROUP BY kind ORDER BY n DESC")]
        samples = conn.execute("SELECT COUNT(*) n FROM location_samples").fetchone()["n"]
        events = conn.execute("SELECT COUNT(*) n FROM tracking_events").fetchone()["n"]
    return {"offline": STATE["offline"], "health_rows": len(health), "health": health,
            "tracking_events": events, "location_samples": samples, "event_kinds": kinds}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _record(self, path, status, n):
        with db() as conn:
            conn.execute("INSERT INTO request_log (path,status,n) VALUES (?,?,?)", (path, status, n))

    def do_GET(self):
        if self.path.startswith("/v1/stats"):
            self._send(200, stats())
        elif self.path.startswith("/v1/health-check"):
            self._send(200, {"ok": True, "offline": STATE["offline"]})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return self._send(400, {"error": "bad json"})
        path = self.path.split("?")[0]

        if path == "/v1/status":
            # A client-reported health check, so the collection state is
            # observable from the database rather than only on the screen.
            with db() as conn:
                conn.execute("""INSERT INTO client_status (account,status) VALUES (?,?)
                                ON CONFLICT(account) DO UPDATE SET
                                  status=excluded.status, server_at=strftime('%s','now')""",
                             (body.get("account") or "demo", json.dumps(body.get("status") or {})))
            return self._send(200, {"ok": True})

        if path == "/v1/admin/offline":
            STATE["offline"] = bool(body.get("offline"))
            return self._send(200, {"offline": STATE["offline"]})

        if STATE["offline"]:
            self._record(path, 503, 0)
            return self._send(503, {"error": "simulated outage"})

        account = body.get("account") or "demo"
        with LOCK:
            if path == "/v1/health":
                records = body.get("records") or []
                result = upsert_health(account, records)
                self._record(path, 200, len(records))
                return self._send(200, result)
            if path == "/v1/tracking":
                events = body.get("events") or []
                result = insert_events(account, events)
                self._record(path, 200, len(events))
                return self._send(200, result)
        self._send(404, {"error": "not found"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    with db() as conn:
        conn.executescript(SCHEMA)
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    sys.stderr.write("signalkit demo backend on http://0.0.0.0:%d  db=%s\n" % (port, DB_PATH))
    server.serve_forever()


if __name__ == "__main__":
    main()
