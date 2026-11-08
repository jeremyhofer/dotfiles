#!/usr/bin/env bash
# test-hc-status.sh -- contract tests for hc-status against a local stub of the Healthchecks API.
#
# The stub (stub-hc-server.py) serves canned list-checks responses shaped from the API docs, one per
# read-only key. Nothing here touches the network beyond loopback or reads a real key.
#
# Clock: HC_STATUS_NOW pins "now" to 2026-11-01T12:00:00Z and TZ is UTC, so times are exact.
#
# Run: sh ~/.local/share/chezmoi/tests/test-hc-status.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
TOOL="$here/../private_dot_local/bin/executable_hc-status"
STUB="$here/stub-hc-server.py"

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (no '$3' in: $2)"; fi; }
lacks() { if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 ('$3' present)"; else ok "$1"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
[ -f "$TOOL" ] || { echo "FAIL: no tool at $TOOL"; exit 1; }

w=$(mktemp -d); trap 'kill "${spid:-0}" 2>/dev/null; rm -rf "$w"' EXIT
fx="$w/fx"; mkdir -p "$fx" "$w/cfg/hc-status"
export XDG_CONFIG_HOME="$w/cfg" HOME="$w/home" TZ=UTC HC_STATUS_NOW=1793534400
mkdir -p "$HOME"

# Fixtures. Key names double as fixture file names; the SECRET words let the leak checks look for them.
mkcheck() { # name slug status last next
  printf '{"name":"%s","slug":"%s","tags":"","desc":"","grace":3600,"n_pings":9,"status":"%s","started":false,"last_ping":%s,"next_ping":%s,"manual_resume":false,"methods":"","badge_url":"x","unique_key":"uk-%s","timeout":86400}' \
    "$1" "$2" "$3" "$4" "$5" "$2"
}
{
  echo 200
  printf '{"checks":['
  mkcheck "Backups" backups up '"2026-11-01T11:00:00+00:00"' '"2026-11-02T11:00:00+00:00"'; printf ','
  mkcheck "Fresh" fresh new null null; printf ','
  mkcheck "Slow" slow grace '"2026-10-31T11:00:00+00:00"' '"2026-11-01T10:00:00+00:00"'; printf ','
  mkcheck "Dead" dead down '"2026-10-30T11:00:00+00:00"' null; printf ','
  mkcheck "Off" off paused '"2026-10-29T11:00:00+00:00"' null
  printf ']}\n'
} > "$fx/SECRETKEYONE"
{ echo 200; printf '{"checks":['; mkcheck "Cloud" cloud up '"2026-11-01T11:30:00+00:00"' '"2026-11-01T12:30:00+00:00"'; printf ']}\n'; } > "$fx/SECRETKEYTWO"
{ echo 200; printf '{"checks":[]}\n'; } > "$fx/SECRETKEYEMPTY"
{ echo 200; printf '{"checks":['; mkcheck "Calm" calm up '"2026-11-01T11:30:00+00:00"' '"2026-11-01T12:30:00+00:00"'; printf ']}\n'; } > "$fx/SECRETKEYCALM"
echo 500 > "$fx/SECRETKEYBROKEN"; echo 'oops' >> "$fx/SECRETKEYBROKEN"

python3 "$STUB" "$w/port" "$fx" & spid=$!
i=0; while [ ! -s "$w/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
[ -s "$w/port" ] || { echo "FAIL: stub did not start"; exit 1; }
export HC_STATUS_BASE_URL="http://127.0.0.1:$(cat "$w/port")"

keys="$w/cfg/hc-status/keys"
write_keys() { cat > "$keys"; chmod 600 "$keys"; }
run() { out=$(python3 "$TOOL" "$@" 2>"$w/err"); rc=$?; err=$(cat "$w/err"); }

echo "== all statuses, human output"
write_keys <<'K'
# home machines
Home Fleet SECRETKEYONE

Cloud Estate SECRETKEYTWO
K
run
eq "exit 1 when a check is down or grace" "$rc" 1
for s in "Backups [backups]" "Fresh [fresh]" "Slow [slow]" "Dead [dead]" "Off [off]" "Cloud [cloud]"; do has "row for $s" "$out" "$s"; done
has "multi-word label kept whole" "$out" "Home Fleet"
has "last ping local time and age" "$out" "2026-11-01 11:00:00 (1h ago)"
has "next expected in the future" "$out" "2026-11-02 11:00:00 (in 23h)"
has "overdue next ping" "$out" "2026-11-01 10:00:00 (2h overdue)"
has "status grace shown" "$out" "grace"
has "status paused shown" "$out" "paused"
lacks "comments are not projects" "$out" "home machines"

echo "== --problems"
run --problems
eq "exit 1 with problems" "$rc" 1
has "problems lists down" "$out" "Dead"
has "problems lists grace" "$out" "Slow"
lacks "problems hides up" "$out" "Backups"
lacks "problems hides new" "$out" "Fresh"
lacks "problems hides paused" "$out" "Off"

echo "== --json"
run --json
eq "json exits 1" "$rc" 1
n=$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["checks"]), d["errors"], sorted({c["project"] for c in d["checks"]}))')
eq "json carries both projects, no errors" "$n" "6 [] ['Cloud Estate', 'Home Fleet']"
has "json keeps unique_key" "$out" "uk-dead"

echo "== exit 0 when nothing is down or grace"
write_keys <<'K'
Calm SECRETKEYCALM
Empty SECRETKEYEMPTY
K
run
eq "exit 0" "$rc" 0
run --problems
eq "exit 0 with --problems" "$rc" 0
has "says nothing to show" "$out" "no checks to show"

echo "== keys file refused when group or other readable"
chmod 640 "$keys"
run
eq "group-readable refused with exit 2" "$rc" 2
has "tells how to fix" "$err" "chmod 600"
eq "prints no table" "$out" ""
lacks "refusal does not print a key" "$err" "SECRETKEY"
chmod 604 "$keys"
run
eq "other-readable refused with exit 2" "$rc" 2
chmod 600 "$keys"
rm -f "$keys"
run
eq "missing keys file is exit 2" "$rc" 2
has "missing file explains the format" "$err" "<project label> <read-only key>"

echo "== a project that fails does not hide the others"
write_keys <<'K'
Good SECRETKEYONE
Rejected SECRETKEYWRONG
Broken SECRETKEYBROKEN
K
run
eq "exit 2 when a project cannot be read" "$rc" 2
has "other project still printed" "$out" "Backups"
has "401 named by project label" "$err" "project 'Rejected' could not be read: HTTP 401"
has "500 named by project label" "$err" "project 'Broken' could not be read: HTTP 500"
run --json
eq "json also exits 2" "$rc" 2
has "json lists the failed project" "$out" '"project": "Rejected"'

echo "== unreachable server"
write_keys <<'K'
Only SECRETKEYONE
K
HC_STATUS_BASE_URL="http://127.0.0.1:1" run
eq "connection refused is exit 2" "$rc" 2
has "network error names the project" "$err" "project 'Only' could not be read"

echo "== no key anywhere in any output"
write_keys <<'K'
Good SECRETKEYONE
Rejected SECRETKEYWRONG
Broken SECRETKEYBROKEN
K
all=""
for a in "" "--problems" "--json"; do run $a; all="$all$out$err"; done
HC_STATUS_BASE_URL="http://127.0.0.1:1" run; all="$all$out$err"
lacks "no SECRETKEY text in stdout or stderr" "$all" "SECRETKEY"

echo "== a full-access key's ping addresses are dropped from --json"
{ echo 200; printf '{"checks":[{"name":"X","slug":"x","status":"up","uuid":"UUIDPLANT","ping_url":"https://hc-ping.com/UUIDPLANT","last_ping":null,"next_ping":null}]}\n'; } > "$fx/SECRETKEYFULL"
write_keys <<'K'
Full SECRETKEYFULL
K
run --json
lacks "uuid and ping_url removed" "$out" "UUIDPLANT"

echo "== the key is sent as X-Api-Key to the checks endpoint"
: > "$fx/requests.log"
run
eq "one request, v3 checks path" "$(cat "$fx/requests.log")" "/api/v3/checks/"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
