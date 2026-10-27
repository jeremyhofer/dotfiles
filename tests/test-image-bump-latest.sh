#!/bin/sh
# Test: `image-bump latest` -- is a newer release out than the pin, from the release host's API.
#
# The release hosts are one tiny stdlib HTTP server bound to 127.0.0.1 (both hosts' base URLs
# point at it): it serves the file "<url path>@<ref>" of a directory (ref is the `ref` query value,
# empty when there is none), answers the status held in a sibling "<file>.code" when one exists,
# 404 for an absent file, and logs each request line. Only the loopback is used. Services and
# registries are invented. Each case asserts the exit status and a specific line.
#
# Overrides: IMAGE_BUMP_BIN (the executable under test), PYTHON (the interpreter).
# Run: sh tests/test-image-bump-latest.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
BIN=${IMAGE_BUMP_BIN:-$here/../private_dot_local/bin/executable_image-bump}
PY=$(command -v "${PYTHON:-python3}") || { echo "FAIL: python3 is required"; exit 1; }
[ -f "$BIN" ] || { echo "FAIL: no image-bump at $BIN"; exit 1; }

t=${TMPDIR:-/tmp}; t=${t%/}
w=$(mktemp -d "$t/image-bump-latest.XXXXXX") || exit 1
trap 'rm -rf "${w:?}"' EXIT
HOME="$w/home"; export HOME; mkdir -p "$HOME"
unset IMAGE_BUMP_ROOT IMAGE_BUMP_SOURCE_ROOT

cat > "$w/api-server.py" <<'PYEOF'
import http.server, os, sys, urllib.parse
root, log = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(log, "a") as fh:
            fh.write(self.path + "\n")
        u = urllib.parse.urlparse(self.path)
        ref = urllib.parse.parse_qs(u.query).get("ref", [""])[0]
        f = os.path.join(root, u.path.lstrip("/") + "@" + ref)
        code = 200
        if os.path.isfile(f + ".code"):
            code = int(open(f + ".code").read())
        elif not os.path.isfile(f):
            code = 404
        body = open(f, "rb").read() if code == 200 or os.path.isfile(f) else b""
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    log_message = lambda self, *a: None
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PYEOF
mkdir -p "$w/api"; : > "$w/reqlog"
"$PY" "$w/api-server.py" "$w/api" "$w/reqlog" > "$w/api-port" &
api_pid=$!
trap 'kill $api_pid 2>/dev/null; rm -rf "${w:?}"' EXIT
i=0; while [ ! -s "$w/api-port" ] && [ $i -lt 50 ]; do i=$((i+1)); "$PY" -c 'import time; time.sleep(0.1)'; done
[ -s "$w/api-port" ] || { echo "FAIL: the stub API server did not start"; exit 1; }
IMAGE_BUMP_GITHUB_API="http://127.0.0.1:$(cat "$w/api-port")"; export IMAGE_BUMP_GITHUB_API
IMAGE_BUMP_CODEBERG_API=$IMAGE_BUMP_GITHUB_API; export IMAGE_BUMP_CODEBERG_API

fail=0
ok() { printf '  ok    %s\n' "$1"; }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
expect() {
  name=$1; want=$2; text=${3:-}
  got=$(cat "$w/rc")
  if [ "$got" != "$want" ]; then no "$name (status $got, wanted $want; out: $(cat "$w/out"); err: $(cat "$w/err"))"; return; fi
  if [ -n "$text" ] && ! cat "$w/out" "$w/err" | grep -qF -- "$text"; then
    no "$name (no '$text' in output: $(cat "$w/out" "$w/err"))"; return
  fi
  ok "$name"
}

IMG=registry.invalid/acme/widget
D0=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
R="$w/api/repos/acme/widget/releases"

# scenario <host> <line> [<pinned tag>]: a fresh descriptor, pin file and empty API directory.
scenario() {
  rm -rf "${w:?}/root" "${w:?}/api"/*; : > "$w/reqlog"
  mkdir -p "$w/root/svc" "$w/api/repos/acme/widget"
  printf '%s:%s@%s\n' "$IMG" "${3:-v15.0.9-rootless}" "$D0" > "$w/root/svc/IMAGE"
  cat > "$w/root/svc/image_bump.py" <<PYEOF
image = "$IMG"
release_line = "$2"
release_api = {"host": "$1", "repo": "acme/widget"}
git_tag = "v{version}"
platform = "linux/arm64"
pin_file = "IMAGE"
scan_dir = "scans"
gate = {"kind": "fixable-count-floor"}
migrations = {"kind": "always"}
volume = "widget-data"
container = "widget"
service = "widget.service"
vm_unit = "/etc/containers/systemd/widget.container"
install = {"kind": "vm-copy", "applied_unit": "/tmp/widget.container"}
checks = [{"name": "health", "command": ["true"], "pass": "exit 0"}]
checklist = ["read the release notes"]
tag_suffix = "-rootless"
PYEOF
}
# releases <tag[:d|:p]>...: the list body; :d marks a draft, :p a pre-release
releases() {
  "$PY" - "$R@" "$@" <<'PYEOF'
import json, sys
out = []
for spec in sys.argv[2:]:
    tag, _, flag = spec.partition(":")
    out.append({"tag_name": tag, "draft": flag == "d", "prerelease": flag == "p"})
json.dump(out, open(sys.argv[1], "w"))
PYEOF
}
# lateststable <tag>: the body of releases/latest
lateststable() { mkdir -p "$R"; printf '{"tag_name": "%s", "draft": false, "prerelease": false}\n' "$1" > "$R/latest@"; }
go() { "$PY" "$BIN" latest svc "$@" --root "$w/root" >"$w/out" 2>"$w/err"; echo $? >"$w/rc"; }
snap() { cat "$w/root/svc/IMAGE"; ls -lA "$w/root/svc"; }

# ---------- patch-of-pinned-major, GitHub ----------
scenario github patch-of-pinned-major
releases v15.0.12 v15.0.10 v14.9.9
go
expect "a newer patch on the pinned major" 7 "newer svc 15.0.9 -> 15.0.12 (v15.0.12)"
grep -q 'releases?per_page=50' "$w/reqlog" && ok "GitHub is asked per_page=50" || no "request log: $(cat "$w/reqlog")"

scenario github patch-of-pinned-major
releases v15.0.10 v15.0.9 v15.0.2
go
expect "numeric ordering: 15.0.10 is newer than 15.0.9" 7 "-> 15.0.10 (v15.0.10)"

scenario github patch-of-pinned-major
releases v16.0.0 v16.1.0 v15.0.9 v15.0.8
go
expect "a newer major only is not an alert" 0 "up to date svc 15.0.9"

scenario github patch-of-pinned-major
releases v15.0.9
go
expect "equal versions are up to date" 0 "up to date svc 15.0.9"

scenario github patch-of-pinned-major
releases v15.0.12:p v15.0.11:d v15.0.9
go
expect "a pre-release or draft newer than current is skipped" 0 "up to date svc 15.0.9"

scenario github patch-of-pinned-major
releases v99.0.0-rc1 nightly v15.0.12-rc1 v15.0.9
go
expect "a non-numeric tag is skipped, never compared" 0 "up to date svc 15.0.9"

scenario github patch-of-pinned-major
releases v15.0.12-rc1 v15.0.11 nightly
go
expect "skipped tags do not hide a real newer one" 7 "-> 15.0.11 (v15.0.11)"

# ---------- patch-of-pinned-major, Codeberg ----------
scenario codeberg patch-of-pinned-major
releases v15.0.12 v15.0.9
go
expect "a newer patch on a Codeberg-hosted repo" 7 "-> 15.0.12 (v15.0.12)"
grep -q 'releases?limit=50' "$w/reqlog" && ok "Codeberg is asked limit=50" || no "request log: $(cat "$w/reqlog")"

# ---------- failures to read are status 2, never "up to date" ----------
for h in github codeberg; do
  scenario $h patch-of-pinned-major
  printf '500\n' > "$R@.code"; releases v15.0.12
  go
  expect "an HTTP 500 on $h" 2 "reading"
done
scenario github patch-of-pinned-major
printf 'this is not json' > "$R@"
go
expect "a non-JSON body" 2 "unreadable JSON"
scenario github patch-of-pinned-major
printf '{"message": "rate limited"}' > "$R@"
go
expect "a non-list releases body" 2 "not a list of releases"
scenario github patch-of-pinned-major
go
expect "a 404" 2 "reading"
scenario github patch-of-pinned-major
IMAGE_BUMP_GITHUB_API=http://127.0.0.1:1 go
expect "a host that does not answer" 2 "reading"
IMAGE_BUMP_GITHUB_API=$IMAGE_BUMP_CODEBERG_API

# ---------- github-latest-stable ----------
scenario github github-latest-stable v1.4.2
lateststable v1.5.0
go
expect "a newer stable release on the latest line" 7 "newer svc 1.4.2 -> 1.5.0 (v1.5.0)"
grep -q '/releases/latest' "$w/reqlog" && ok "the latest endpoint is asked" || no "request log: $(cat "$w/reqlog")"

scenario github github-latest-stable v1.4.2
lateststable v2.0.0
go
expect "a newer major counts on the latest line" 7 "-> 2.0.0"

scenario github github-latest-stable v1.4.2
lateststable v1.4.2
go
expect "latest equal to the pin is up to date" 0 "up to date svc 1.4.2"

scenario github github-latest-stable v1.4.2
lateststable v1.4.10
go
expect "latest line orders numerically" 7 "-> 1.4.10"

scenario github github-latest-stable v1.4.2
lateststable v9.0.0-beta1
go
expect "a non-numeric latest tag cannot be compared" 2 "not a numeric version"

scenario codeberg github-latest-stable v1.4.2
lateststable v1.5.0
go
expect "the latest line on Codeberg" 7 "-> 1.5.0"

scenario github github-latest-stable v1.4.2
lateststable v1.5.0; printf '500\n' > "$R/latest@.code"
go
expect "latest line: an HTTP 500" 2 "reading"
scenario github github-latest-stable v1.4.2
mkdir -p "$R"; printf '[1,2]' > "$R/latest@"
go
expect "latest line: a body that is not a release object" 2 "not a release object"
scenario github github-latest-stable v1.4.2
mkdir -p "$R"; printf 'nope' > "$R/latest@"
go
expect "latest line: a non-JSON body" 2 "unreadable JSON"

# ---------- --pin ----------
scenario github patch-of-pinned-major
releases v15.0.9 v15.0.7
go
expect "pinned at the newest is up to date" 0 "up to date svc 15.0.9"
before=$(snap)
go --pin 15.0.5
expect "--pin older makes a same-major release newer" 7 "newer svc 15.0.5 -> 15.0.9 (v15.0.9)"
[ "$(snap)" = "$before" ] && ok "--pin writes nothing" || no "--pin changed the tree"
go --pin 15.0.x
expect "a non-numeric --pin is an error" 2 "not a numeric"

if [ "$fail" -eq 0 ]; then echo PASS; exit 0; fi
echo "FAIL: $fail case(s)"; exit 1
