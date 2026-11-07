#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for bing-webmaster, against a local stub of the Bing Webmaster Tools JSON API.

The stub serves responses shaped from Microsoft's documented samples (the `d` envelope, `__type`,
`/Date(ms-0700)/` dates). Nothing here touches the network beyond loopback or reads a real key: the
key is a fixture word, SECRETKEY..., so every test can check it never reaches stdout or stderr."""
import http.server
import json
import os
import stat
import subprocess
import sys
import threading
import urllib.parse
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_bing-webmaster"
KEY = "SECRETKEY0123456789abcdef0123456"  # gitleaks:allow (a fixture word, not a key: the tests check it never prints)

QUERY_STATS = {
    "d": [
        {"__type": "QueryStats:#Microsoft.Bing.Webmaster.Api", "AvgClickPosition": 18,
         "AvgImpressionPosition": 14, "Clicks": 2, "Date": "/Date(1316156400000-0700)/",
         "Impressions": 40, "Query": "bass lessons"},
        {"__type": "QueryStats:#Microsoft.Bing.Webmaster.Api", "AvgClickPosition": -1,
         "AvgImpressionPosition": 31, "Clicks": 0, "Date": "/Date(1316761200000-0700)/",
         "Impressions": 7, "Query": "walking bass"},
    ]
}
TRAFFIC = {
    "d": [
        {"__type": "RankAndTrafficStats:#Microsoft.Bing.Webmaster.Api", "Clicks": 3,
         "Date": "/Date(1316156400000)/", "Impressions": 50},
    ]
}
SITES = {
    "d": [
        {"__type": "Site:#Microsoft.Bing.Webmaster.Api", "AuthenticationCode": "ABC",
         "DnsVerificationCode": "XYZ", "IsVerified": True, "Url": "https://example.com/"},
    ]
}


class Stub(http.server.BaseHTTPRequestHandler):
    requests: list = []
    mode = "ok"

    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        method = u.path.rsplit("/", 1)[-1]
        Stub.requests.append({"path": u.path, "method": method, "query": q})
        if Stub.mode == "error":
            # A fault body that echoes the request, key included, as real error pages do.
            body = json.dumps({"ErrorCode": 3, "Message": f"InvalidApiKey: {q.get('apikey')}"})
            self.send_response(400)
        elif q.get("apikey") != KEY:
            body, _ = json.dumps({"ErrorCode": 3, "Message": "InvalidApiKey"}), self.send_response(401)
        else:
            body = json.dumps({"GetQueryStats": QUERY_STATS, "GetPageStats": QUERY_STATS,
                               "GetPageQueryStats": QUERY_STATS, "GetRankAndTrafficStats": TRAFFIC,
                               "GetUserSites": SITES}.get(method, {"d": []}))
            self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(body.encode())


@pytest.fixture
def stub():
    Stub.requests = []
    Stub.mode = "ok"
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}/webmaster/api.svc/json"
    srv.shutdown()


@pytest.fixture
def cfg(tmp_path):
    d = tmp_path / "cfg" / "bing-webmaster"
    d.mkdir(parents=True)
    f = d / "api-key"
    f.write_text(KEY + "\n")
    f.chmod(0o600)
    return tmp_path / "cfg"


def run(cfg, base, *args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("BING_WEBMASTER")}
    env.update({"XDG_CONFIG_HOME": str(cfg), "BING_WEBMASTER_BASE_URL": base,
                "BING_WEBMASTER_TIMEOUT": "5"})
    p = subprocess.run([sys.executable, str(TOOL), *args], env=env, capture_output=True, text=True)
    assert KEY not in p.stdout and KEY not in p.stderr, "the API key was printed"
    return p


def test_queries_calls_the_documented_method_with_site_and_key(cfg, stub):
    p = run(cfg, stub, "queries", "https://example.com/")
    assert p.returncode == 0, p.stderr
    (r,) = Stub.requests
    assert r["path"].endswith("/webmaster/api.svc/json/GetQueryStats")
    assert r["query"] == {"siteUrl": "https://example.com/", "apikey": KEY}


def test_rows_are_normalized_dates_iso_with_offset_type_dropped_newest_first(cfg, stub):
    rows = json.loads(run(cfg, stub, "queries", "https://example.com/").stdout)
    assert [r["Query"] for r in rows] == ["walking bass", "bass lessons"]
    assert rows[1]["Date"] == "2011-09-16T00:00:00-07:00"
    assert all("__type" not in r for r in rows)
    assert rows[1]["Clicks"] == 2 and rows[1]["AvgClickPosition"] == 18


def test_a_date_without_offset_is_utc(cfg, stub):
    rows = json.loads(run(cfg, stub, "traffic", "https://example.com/").stdout)
    assert rows == [{"Clicks": 3, "Date": "2011-09-16T07:00:00+00:00", "Impressions": 50}]
    assert Stub.requests[0]["method"] == "GetRankAndTrafficStats"


def test_since_keeps_buckets_on_or_after_the_day(cfg, stub):
    rows = json.loads(run(cfg, stub, "queries", "https://example.com/", "--since", "2011-09-20").stdout)
    assert [r["Query"] for r in rows] == ["walking bass"]


def test_pages_and_page_queries_and_sites_use_their_methods(cfg, stub):
    assert run(cfg, stub, "pages", "https://example.com/").returncode == 0
    assert run(cfg, stub, "page-queries", "https://example.com/", "https://example.com/a").returncode == 0
    sites = json.loads(run(cfg, stub, "sites").stdout)
    assert [r["method"] for r in Stub.requests] == ["GetPageStats", "GetPageQueryStats", "GetUserSites"]
    assert Stub.requests[1]["query"]["page"] == "https://example.com/a"
    assert Stub.requests[2]["query"] == {"apikey": KEY}
    assert sites == [{"AuthenticationCode": "ABC", "DnsVerificationCode": "XYZ", "IsVerified": True,
                      "Url": "https://example.com/"}]


def test_an_api_error_reports_status_and_body_without_the_key(cfg, stub):
    Stub.mode = "error"
    p = run(cfg, stub, "queries", "https://example.com/")
    assert p.returncode == 2
    assert "400" in p.stderr and "InvalidApiKey" in p.stderr
    assert "Traceback" not in p.stderr


def test_an_unreachable_server_is_exit_2_without_the_key_or_url(cfg):
    p = run(cfg, "http://127.0.0.1:9/webmaster/api.svc/json", "queries", "https://example.com/")
    assert p.returncode == 2
    assert "apikey" not in p.stderr and "Traceback" not in p.stderr


def test_a_missing_key_file_names_the_path(tmp_path, stub):
    p = run(tmp_path / "nothing", stub, "sites")
    assert p.returncode == 2 and "api-key" in p.stderr and "Traceback" not in p.stderr
    assert Stub.requests == []


def test_a_key_file_readable_by_others_is_refused(cfg, stub):
    (cfg / "bing-webmaster" / "api-key").chmod(0o644)
    p = run(cfg, stub, "sites")
    assert p.returncode == 2 and "readable" in p.stderr
    assert Stub.requests == []


def test_an_empty_key_file_is_refused(cfg, stub):
    (cfg / "bing-webmaster" / "api-key").write_text("\n")
    p = run(cfg, stub, "sites")
    assert p.returncode == 2 and "empty" in p.stderr
    assert Stub.requests == []


def test_help_makes_no_request(cfg, stub):
    p = run(cfg, stub, "--help")
    assert p.returncode == 0 and "queries" in p.stdout
    assert Stub.requests == []


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
