#!/usr/bin/env python3
"""Stub of ntfy's JSON stream endpoint, for test-ntfy-inbox.sh.

usage: stub-ntfy-server.py PORT_FILE PLAN_FILE REQUEST_LOG

PLAN_FILE is a JSON list, one entry per expected connection, in order:
    {"status": 200, "lines": ["<raw line>", ...], "end": "close" | "hang"}
Each line is sent as written, one per line, flushed at once. "close" ends the stream after the
lines; "hang" keeps it open and silent until the stub is killed (a stalled connection). A
connection beyond the plan gets 503. Each request is appended to REQUEST_LOG as one JSON line
{"path", "query", "auth"}, where auth is the Authorization header as received.
"""
import http.server
import json
import sys
import threading
import time
import urllib.parse

port_file, plan_file, req_log = sys.argv[1:4]
plan = json.load(open(plan_file))
state = {"n": 0}
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # no Content-Length: the stream ends when the socket closes

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        with lock:
            n = state["n"]
            state["n"] += 1
            with open(req_log, "a") as fh:
                fh.write(json.dumps({"path": u.path, "query": u.query,
                                     "auth": self.headers.get("Authorization", "")}) + "\n")
        entry = plan[n] if n < len(plan) else {"status": 503, "lines": [], "end": "close"}
        self.send_response(entry.get("status", 200))
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        for line in entry.get("lines", []):
            self.wfile.write((line + "\n").encode())
            self.wfile.flush()
        if entry.get("end") == "hang":
            time.sleep(3600)

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
srv.daemon_threads = True
with open(port_file, "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
