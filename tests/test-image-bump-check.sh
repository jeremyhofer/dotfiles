#!/bin/sh
# Test: `image-bump check` -- resolve, scan, gate, migrations, record, pin rewrite.
#
# Every external command is a stub first on PATH: `skopeo` and `trivy` log their argv to a file and
# answer from fixture files keyed by their arguments; the release API is a tiny stdlib HTTP server
# bound to 127.0.0.1 that serves files from a directory, mapping "<path>?ref=<tag>" to the file
# "<path>@<tag>" (a file:// URL drops the query, so it cannot serve per-tag listings) and answering
# 404 for a file that is absent. Only the loopback is used. Nothing reaches the network. Services and registries are invented.
# Each case asserts the exit status, a specific message, and what the stubs were called with.
#
# Overrides: IMAGE_BUMP_BIN (the executable under test), PYTHON (the interpreter).
# Run: sh tests/test-image-bump-check.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
BIN=${IMAGE_BUMP_BIN:-$here/../private_dot_local/bin/executable_image-bump}
PY=$(command -v "${PYTHON:-python3}") || { echo "FAIL: python3 is required"; exit 1; }
[ -f "$BIN" ] || { echo "FAIL: no image-bump at $BIN"; exit 1; }

t=${TMPDIR:-/tmp}; t=${t%/}
w=$(mktemp -d "$t/image-bump-check.XXXXXX") || exit 1
trap 'rm -rf "${w:?}"' EXIT
HOME="$w/home"; export HOME; mkdir -p "$HOME"
unset IMAGE_BUMP_ROOT IMAGE_BUMP_SOURCE_ROOT IMAGE_BUMP_CODEBERG_API

cat > "$w/api-server.py" <<'PYEOF'
import http.server, os, sys, urllib.parse
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        ref = urllib.parse.parse_qs(u.query).get("ref", [""])[0]
        f = os.path.join(root, u.path.lstrip("/") + "@" + ref)
        if not os.path.isfile(f):
            self.send_response(404); self.end_headers(); return
        body = open(f, "rb").read()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PYEOF
mkdir -p "$w/api"
"$PY" "$w/api-server.py" "$w/api" > "$w/api-port" &
api_pid=$!
trap 'kill $api_pid 2>/dev/null; rm -rf "${w:?}"' EXIT
i=0; while [ ! -s "$w/api-port" ] && [ $i -lt 50 ]; do i=$((i+1)); "$PY" -c 'import time; time.sleep(0.1)'; done
[ -s "$w/api-port" ] || { echo "FAIL: the stub API server did not start"; exit 1; }
IMAGE_BUMP_GITHUB_API="http://127.0.0.1:$(cat "$w/api-port")"; export IMAGE_BUMP_GITHUB_API

fail=0
ok() { printf '  ok    %s\n' "$1"; }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
rc() { cat "$w/rc"; }
# expect <name> <status> [<text expected in stdout or stderr>]
expect() {
  name=$1; want=$2; text=${3:-}
  got=$(rc)
  if [ "$got" != "$want" ]; then no "$name (status $got, wanted $want; stderr: $(cat "$w/err"))"; return; fi
  if [ -n "$text" ] && ! cat "$w/out" "$w/err" | grep -qF -- "$text"; then
    no "$name (no '$text' in output: $(cat "$w/out" "$w/err"))"; return
  fi
  ok "$name"
}
# logged <name> <extended regex>: the stub log has a matching line
logged() { if grep -Eq -- "$2" "$w/log"; then ok "$1"; else no "$1 (no /$2/ in stub log: $(cat "$w/log"))"; fi; }
unlogged() { if grep -Eq -- "$2" "$w/log"; then no "$1 (/$2/ in stub log)"; else ok "$1"; fi; }

# ---------- the stubs ----------
S="$w/stubs"; mkdir -p "$S"
cat > "$S/skopeo" <<'EOF'
#!/bin/sh
echo "skopeo $*" >> "$STUB_LOG"
mode=
for a in "$@"; do case $a in --raw) mode=raw ;; --config) mode=config ;; esac; done
for a in "$@"; do ref=$a; done
key=$(printf '%s' "$ref" | tr '/:@' '___')
[ -f "$FX/skopeo/${mode}__$key" ] || { echo "stub skopeo: no fixture ${mode}__$key" >&2; exit 1; }
cat "$FX/skopeo/${mode}__$key"
EOF
cat > "$S/trivy" <<'EOF'
#!/bin/sh
echo "trivy $*" >> "$STUB_LOG"
case "$1 $2" in
  "image --download-db-only") exit 0 ;;
  "version --format") cat "$FX/trivy-version.json"; exit 0 ;;
esac
skip=no
for a in "$@"; do [ "$a" = --skip-db-update ] && skip=yes; ref=$a; done
if [ "$skip" = no ]; then echo "stub trivy: a scan would download the database" >&2; exit 1; fi
key=$(printf '%s' "$ref" | tr '/:@' '___')
[ -f "$FX/trivy/$key.json" ] || { echo "stub trivy: no fixture $key" >&2; exit 1; }
cat "$FX/trivy/$key.json"
EOF
chmod +x "$S/skopeo" "$S/trivy"
FX="$w/fx"; STUB_LOG="$w/log"; export FX STUB_LOG
PATH="$S:$PATH"; export PATH

IMG=registry.invalid/acme/widget
D0=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef   # the current pin
DA=sha256:$(printf 'aa%.0s' $(seq 32))   # new arm64 manifest
DB=sha256:$(printf 'bb%.0s' $(seq 32))   # new amd64 manifest
key() { printf '%s' "$1" | tr '/:@' '___'; }

# findings <file> <ID:pkg:fixed>...  -- a trivy JSON document; fixed may be empty
findings() {
  f=$1; shift
  "$PY" - "$f" "$@" <<'PYEOF'
import json, sys
vs = []
for spec in sys.argv[2:]:
    i, pkg, fixed = spec.split(":")
    vs.append({"VulnerabilityID": i, "PkgName": pkg, "InstalledVersion": "1.0",
               "FixedVersion": fixed, "Severity": "HIGH"})
json.dump({"Results": [{"Target": "x", "Vulnerabilities": vs or None}]}, open(sys.argv[1], "w"))
PYEOF
}

# scenario: a fresh descriptor, pin file and fixtures. The variables NEW_ARCH, GATE and MIG tune
# it for one call and are cleared at its end.
scenario() {
  rm -rf "${w:?}/root" "${FX:?}" "${w:?}/api"/*; : > "$STUB_LOG"
  migv=${MIG:-'{"kind": "added-files", "path": "models/migrations"}'}
  mkdir -p "$w/root/svc" "$FX/skopeo" "$FX/trivy" "$w/api/repos/acme/widget/contents/models/migrations"
  printf '%s:v1.2.3-rootless@%s\n' "$IMG" "$D0" > "$w/root/svc/IMAGE"
  cat > "$w/root/svc/image_bump.py" <<PYEOF
image = "$IMG"
release_line = "patch-of-pinned-major"
release_api = {"host": "github", "repo": "acme/widget"}
git_tag = "v{version}"
platform = "linux/arm64"
pin_file = "IMAGE"
scan_dir = "scans"
gate = {"kind": "${GATE:-fixable-count-floor}"}
migrations = $migv
volume = "widget-data"
vm_unit = "/etc/containers/systemd/widget.container"
install = {"kind": "vm-copy", "applied_unit": "/tmp/widget.container"}
checks = [{"name": "health", "command": ["curl", "-f", "http://localhost/health"], "pass": "exit 0"}]
checklist = ["read the release notes", "tell the other sessions"]
tag_suffix = "-rootless"
PYEOF
  tag=v1.3.0-rootless
  cat > "$FX/skopeo/raw__$(key "docker://$IMG:$tag")" <<JEOF
{"schemaVersion": 2, "manifests": [
 {"digest": "$DB", "platform": {"os": "linux", "architecture": "amd64"}},
 {"digest": "$DA", "platform": {"os": "linux", "architecture": "arm64"}}]}
JEOF
  printf '{"architecture": "%s", "os": "linux"}\n' "${NEW_ARCH:-arm64}" \
    > "$FX/skopeo/config__$(key "docker://$IMG@$DA")"
  printf '{"Version": "0.99.0", "VulnerabilityDB": {"UpdatedAt": "2026-10-27T06:00:00.5Z"}}\n' \
    > "$FX/trivy-version.json"
  findings "$FX/trivy/$(key "$IMG@$DA").json"
  findings "$FX/trivy/$(key "$IMG@$D0").json" "CVE-1:libfoo:1.1" "CVE-2:libbar:" "CVE-3:libbaz:2.0"
  listing v1.2.3 a.go b.go
  listing v1.3.0 a.go b.go
  GATE=; NEW_ARCH=; MIG=
}
newfind() { findings "$FX/trivy/$(key "$IMG@$DA").json" "$@"; }
curfind() { findings "$FX/trivy/$(key "$IMG@$D0").json" "$@"; }
# listing <git tag> <file name>...: the migrations directory's listing at a tag, as the contents API
listing() {
  tg=$1; shift
  "$PY" - "$w/api/repos/acme/widget/contents/models/migrations@$tg" "$@" <<'PYEOF'
import json, sys
json.dump([{"name": n, "type": "file"} for n in sys.argv[2:]], open(sys.argv[1], "w"))
PYEOF
}
go() { "$PY" "$BIN" check svc "$@" --root "$w/root" >"$w/out" 2>"$w/err"; echo $? >"$w/rc"; }
pin() { cat "$w/root/svc/IMAGE"; }
record() { ls "$w/root/svc/scans/widget-1.3.0-"*.txt 2>/dev/null | head -1; }
snap() { pin; ls -lA "$w/root/svc/scans" 2>&1; cat "$w/root/svc/scans/"* 2>/dev/null; }
OLDPIN="$IMG:v1.2.3-rootless@$D0"

# ---------- pass: new image clean ----------
scenario
go 1.3.0
expect "clean new image passes" 0 "gate fixable-count-floor: pass"
logged "index resolved with --raw on the new tag" "^skopeo inspect --raw docker://$IMG:v1.3.0-rootless$"
logged "config read on the chosen arm64 digest" "^skopeo inspect --config docker://$IMG@$DA$"
n=$(grep -c '^trivy image --download-db-only$' "$w/log")
[ "$n" = 1 ] && ok "database fetched exactly once" || no "database fetched $n times"
dbline=$(grep -n '^trivy image --download-db-only$' "$w/log" | head -1 | cut -d: -f1)
firstscan=$(grep -n -- '--skip-db-update' "$w/log" | head -1 | cut -d: -f1)
[ -n "$dbline" ] && [ -n "$firstscan" ] && [ "$dbline" -lt "$firstscan" ] && ok "database fetched before the first scan" || no "database fetch order ($dbline, $firstscan)"
logged "version read for the database timestamp" "^trivy version --format json$"
for d in "$DA" "$D0"; do
  logged "scan of $d carries --skip-db-update and --platform" \
    "^trivy image --skip-db-update --scanners vuln --image-src remote --platform linux/arm64 --severity HIGH,CRITICAL --format json $IMG@$d$"
done
[ "$(grep -c -- '--skip-db-update' "$w/log")" = 2 ] && ok "exactly two scans" || no "scan count"
[ "$(pin)" = "$IMG:v1.3.0-rootless@$DA" ] && ok "pin file rewritten" || no "pin file: $(pin)"
r=$(record)
[ -n "$r" ] && ok "record written as <name>-<version>-<date>.txt" || no "no record"
case "$(basename "${r:-x}")" in widget-1.3.0-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].txt) ok "record name has an ISO date";; *) no "record name $r";; esac
grep -qx 'checklist: read the release notes' "$w/out" && ok "checklist printed" || no "checklist missing"

# the record, as written
if [ -n "$r" ]; then
  head -1 "$r" | grep -qx 'widget image CVE scan record' && ok "record title line" || no "title: $(head -1 "$r")"
  for want in "image: $IMG:v1.3.0-rootless" "digest: $DA" "platform: linux/arm64" "replaces: $D0" \
              "scanner: 0.99.0" "database: 2026-10-27T06:00:00.5Z" "gate: fixable-count-floor" \
              "verdict: pass" "migrates: no"; do
    grep -qx -- "$want" "$r" && ok "record has '$want'" || no "record lacks '$want'"
  done
  grep -Eq '^scanned: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+ .+' "$r" && ok "record scanned: date-time with offset and host" || no "scanned line"
  grep -q 'CVE-1  *libfoo' "$r" && grep -q 'CVE-2  *libbar' "$r" && ok "record lists the current pin's findings" || no "record tables"
  cp "$r" "$w/record.keep"
  cat > "$w/rr.py" <<'PYEOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ib", sys.argv[1])
spec = importlib.util.spec_from_loader("ib", loader)
ib = importlib.util.module_from_spec(spec); loader.exec_module(ib)
h = ib.read_record(sys.argv[2])
assert h["replaces"] == sys.argv[3], h
assert h["migrates"] == "no" and h["digest"] == sys.argv[4], h
assert h["verdict"] == "pass" and h["scanned"].count(" ") == 1, h
assert "CVE-1" not in str(h), h
PYEOF
  "$PY" "$w/rr.py" "$BIN" "$r" "$D0" "$DA" 2>"$w/err" && ok "read_record round-trips replaces, migrates, digest" || no "read_record: $(cat "$w/err")"
  # the same version again: refused, and the record left as it was
  printf '%s\n' "$OLDPIN" > "$w/root/svc/IMAGE"
  go 1.3.0
  expect "an existing record is never overwritten" 4 "exists"
  cmp -s "$r" "$w/record.keep" && ok "existing record untouched" || no "record changed"
  [ "$(pin)" = "$OLDPIN" ] && ok "pin untouched on that refusal" || no "pin changed"
fi

# ---------- platform ----------
NEW_ARCH=amd64; scenario
go 1.3.0
expect "index whose arm64 entry's config says amd64 is refused" 4 "built for linux/amd64"
unlogged "no scan after the platform refusal" "--skip-db-update"
[ "$(pin)" = "$OLDPIN" ] && ok "pin untouched" || no "pin changed"
[ -z "$(record)" ] && ok "no record" || no "record written"

scenario
cat > "$FX/skopeo/raw__$(key "docker://$IMG:v1.3.0-rootless")" <<'JEOF'
{"manifests": [{"digest": "sha256:cc", "platform": {"os": "linux", "architecture": "amd64"}}]}
JEOF
go 1.3.0
expect "index with no entry for the platform is refused" 4 "no linux/arm64 entry"

# ---------- single manifest ----------
scenario
rawf="$FX/skopeo/raw__$(key "docker://$IMG:v1.3.0-rootless")"
printf '{"schemaVersion": 2, "config": {"digest": "sha256:feed"}, "layers": []}\n' > "$rawf"
SD=sha256:$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$rawf")
printf '{"architecture": "arm64", "os": "linux"}\n' > "$FX/skopeo/config__$(key "docker://$IMG@$SD")"
findings "$FX/trivy/$(key "$IMG@$SD").json"
go 1.3.0
expect "single-manifest image resolves to the hash of its bytes" 0
[ "$(pin)" = "$IMG:v1.3.0-rootless@$SD" ] && ok "pin is the manifest's own digest" || no "pin: $(pin)"

# ---------- already pinned ----------
# (the same image on both sides: fixable-count-floor would refuse it, so this uses the set rule)
GATE=no-new-findings; scenario
printf '{"manifests": [{"digest": "%s", "platform": {"os": "linux", "architecture": "arm64"}}]}\n' "$D0" > "$FX/skopeo/raw__$(key "docker://$IMG:v1.3.0-rootless")"
printf '{"architecture": "arm64", "os": "linux"}\n' > "$FX/skopeo/config__$(key "docker://$IMG@$D0")"
go 1.3.0
expect "a tag resolving to the current digest is refused" 4 "already pinned"
before=$(snap)
go 1.3.0 --no-write
expect "near miss: --no-write reports it and continues" 0 "already pinned"
logged "scans ran under --no-write" "--skip-db-update"
[ "$before" = "$(snap)" ] && ok "--no-write wrote nothing" || no "--no-write wrote"

# ---------- fixable-count-floor ----------
scenario; newfind "CVE-9:libnew:2.0"; curfind
go 1.3.0
expect "fixable finding with a clean current pin is refused" 4 "not fewer than the current pin's 0"
[ -z "$(record)" ] && [ "$(pin)" = "$OLDPIN" ] && ok "refusal writes nothing" || no "refusal wrote"

scenario; newfind "CVE-1:libfoo:1.1" "CVE-2:libbar:"
go 1.3.0
expect "fewer fixable than the current pin is an exception" 3 "needs the operator's explicit approval"
grep -q '1 fixable HIGH/CRITICAL findings (2 in all); the current pin carries 2 (3 in all)' "$w/out" && ok "approval line carries both counts" || no "approval line: $(cat "$w/out")"
grep -qx 'verdict: exception' "$(record)" && ok "exception recorded" || no "exception record"
[ "$(pin)" = "$IMG:v1.3.0-rootless@$DA" ] && ok "exception writes the pin" || no "pin: $(pin)"

scenario; newfind "CVE-1:libfoo:1.1" "CVE-3:libbaz:2.0" "CVE-4:libqux:3"
go 1.3.0
expect "equal fixable count is refused" 4 "not fewer"
scenario; newfind "CVE-2:libbar:" "CVE-7:libunfixed:"
go 1.3.0
expect "near miss: unfixed findings are not counted, so pass" 0 "gate fixable-count-floor: pass"

# ---------- no-new-findings ----------
GATE=no-new-findings; scenario; newfind "CVE-1:libfoo:1.1" "CVE-8:libnew:"
go 1.3.0
expect "no-new-findings with one new finding is refused" 4 "CVE-8 (libnew)"
GATE=no-new-findings; scenario; newfind "CVE-3:libbaz:2.0" "CVE-1:libfoo:1.1" "CVE-2:libbar:"
go 1.3.0
expect "near miss: an equal finding set passes" 0 "gate no-new-findings: pass"
GATE=no-new-findings; scenario; newfind "CVE-1:libfoo:"
go 1.3.0
expect "a subset of the current findings passes" 0

# ---------- migrations ----------
scenario; listing v1.3.0 a.go b.go v9_add.go
go 1.3.0
expect "a name only in the new listing" 0 "migrates: yes"
grep -qx 'migrates: yes' "$(record)" && ok "record says migrates: yes" || no "record migrates"
scenario
go 1.3.0
expect "near miss: identical listings" 0 "migrates: no"
scenario; listing v1.3.0 a.go
go 1.3.0
expect "near miss: a file only in the OLD listing" 0 "migrates: no"
scenario; listing v1.3.0 a.go b.go sub
"$PY" - "$w/api/repos/acme/widget/contents/models/migrations@v1.3.0" <<'PYEOF'
import json, sys
json.dump([{"name": "a.go", "type": "file"}, {"name": "b.go", "type": "file"}, {"name": "sub", "type": "dir"}], open(sys.argv[1], "w"))
PYEOF
go 1.3.0
expect "near miss: a new directory is not a new file" 0 "migrates: no"
scenario; rm "$w/api/repos/acme/widget/contents/models/migrations@v1.3.0"
go 1.3.0
expect "no listing at the new tag (a 404) is an environment error" 2 "environment: listing"
[ "$(pin)" = "$OLDPIN" ] && ok "nothing written then" || no "pin changed"
scenario; rm "$w/api/repos/acme/widget/contents/models/migrations@v1.2.3"
go 1.3.0
expect "no listing at the old tag is an environment error" 2 "environment: listing"
scenario; echo '{"message": "Not Found"}' > "$w/api/repos/acme/widget/contents/models/migrations@v1.3.0"
go 1.3.0
expect "a non-list response is an environment error" 2 "not a list of files"
MIG='{"kind": "always"}'; scenario
go 1.3.0
expect "migrations kind always" 0 "migrates: yes"

# ---------- --no-write ----------
scenario; newfind "CVE-1:libfoo:1.1"
mkdir -p "$w/root/svc/scans"; echo old > "$w/root/svc/scans/widget-1.0.0-2026-01-01.txt"
before=$(snap)
go 1.3.0 --no-write
expect "--no-write on an exception still reports it" 3 "not written (--no-write)"
[ "$before" = "$(snap)" ] && ok "--no-write leaves pin file and scan dir identical" || no "--no-write changed files"
logged "--no-write still scanned" "--skip-db-update"

# ---------- environment errors and the descriptor ----------
scenario; rm "$FX/trivy-version.json"
go 1.3.0
expect "trivy failing is an environment error" 2 "environment"
scenario; echo 'not json' > "$FX/skopeo/raw__$(key "docker://$IMG:v1.3.0-rootless")"
go 1.3.0
expect "unreadable JSON from skopeo is an environment error" 2 "unreadable JSON"
scenario
mv "$S/skopeo" "$S/skopeo.off"
PATH_SAVE=$PATH; PATH="$S"
go 1.3.0
PATH=$PATH_SAVE
mv "$S/skopeo.off" "$S/skopeo"
expect "a missing skopeo is an environment error" 2 "cannot run skopeo"
scenario; sed 's|^platform = .*|platform = "arm64"|' "$w/root/svc/image_bump.py" > "$w/x" && mv "$w/x" "$w/root/svc/image_bump.py"
go 1.3.0
expect "an invalid descriptor is refused before any command runs" 4 "not of the form os/arch"
[ ! -s "$w/log" ] && ok "no stub was called" || no "stubs called: $(cat "$w/log")"

if [ "$fail" -eq 0 ]; then echo PASS; exit 0; fi
echo "FAIL: $fail case(s)"; exit 1
