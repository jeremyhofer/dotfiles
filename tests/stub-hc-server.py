#!/usr/bin/env python3
"""Stub of the Healthchecks.io list-checks endpoint, for test-hc-status.sh.

usage: stub-hc-server.py PORT_FILE FIXTURE_DIR

Serves GET /api/v3/checks/ on a loopback port (written to PORT_FILE). The X-Api-Key header picks a
fixture file FIXTURE_DIR/<key>: its first line is the HTTP status code, the rest is the body. An
unknown key gets 401, as the real API does. Every request's path is appended to FIXTURE_DIR/requests.log.
"""
import http.server
import os
import sys

port_file, fixtures = sys.argv[1], sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(os.path.join(fixtures, "requests.log"), "a") as log:
            log.write(self.path + "\n")
        key = self.headers.get("X-Api-Key", "")
        path = os.path.join(fixtures, os.path.basename(key)) if key else ""
        if self.path.split("?")[0] != "/api/v3/checks/" or not os.path.isfile(path):
            code, body = 401, b'{"error": "wrong api key"}'
        else:
            with open(path, "rb") as fh:
                head, _, body = fh.read().partition(b"\n")
            code = int(head)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
