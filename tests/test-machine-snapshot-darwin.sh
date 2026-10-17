#!/bin/sh
# Test: machine-snapshot on macOS, against the real kernel (it reads libproc, which cannot be faked
# the way /proc can). Runs on a Mac only; elsewhere it says so and exits 0.
#
# Why live and planted: the macOS reader decodes C structures by layout, and a wrong offset or unit
# does not fail, it yields plausible wrong numbers. So known work is planted and the figures are
# checked against it: a busy process (its own CPU), a parent whose busy child ends between two
# samples (the child's CPU must reach the parent as "reaped"), the process's working directory and
# command line, and `ps`'s independent CPU time for the same process.
set -eu
[ "$(uname -s)" = Darwin ] || { echo "skip: not macOS"; exit 0; }
here=$(cd "$(dirname "$0")" && pwd)
ms=${MACHINE_SNAPSHOT_BIN:-$here/../private_dot_local/bin/executable_machine-snapshot}
py=${PYTHON:-/usr/bin/python3}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-ms-darwin.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export MACHINE_SNAPSHOT_DIR="$tmp/state"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }
burn() { "$py" -c "import time
e = time.time() + $1
while time.time() < e: pass"; }

"$py" "$ms" record
mkdir -p "$tmp/work"
# Own CPU: about 3 s of a busy loop, still alive at the second sample.
(cd "$tmp/work" && exec "$py" -c "import time
e = time.time() + 3.0
while time.time() < e: pass
time.sleep(30)  # ms-darwin-busy-marker") &
busy=$!
# Reaped CPU: a parent shell whose child burns about 2 s and ends before the second sample.
(burn 2.0; sleep 30) &
parent=$!
sleep 5
"$py" "$ms" record
ps_time=$(ps -o time= -p "$busy" | awk -F'[:.]' '{print $1 * 60 + $2 + $3 / 100}')

"$py" - "$MACHINE_SNAPSHOT_DIR/latest.json" "$busy" "$parent" "$ps_time" "$tmp/work" > "$tmp/verdicts" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
busy, parent, ps_time, work = sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5]
p, q = s["procs"].get(busy), s["procs"].get(parent)
def v(ok, msg): print(("ok " if ok else "BAD ") + msg)
v(s.get("interval") and 3 < s["interval"] < 15, f"an interval between samples ({s.get('interval')})")
v(p is not None, "the busy process is in the sample")
if p:
    v(2.4 <= p["own"] <= 3.6, f"busy process own CPU about 3 s (got {p['own']})")
    v(abs(p["own"] - ps_time) <= 0.6, f"own CPU agrees with ps ({p['own']} vs ps {ps_time})")
    v(p["cwd"].endswith("/work"), f"working directory read ({p['cwd']})")
    v("ms-darwin-busy-marker" in p["args"], "command line read")
    v(p["rss_mb"] > 0, f"resident memory read ({p['rss_mb']} MB)")
    v(p["state"] in ("R", "S"), f"state read ({p['state']})")
v(q is not None and 1.5 <= q["reaped"] <= 2.6,
  f"the ended child's CPU reached its parent as reaped (got {q and q['reaped']})")
pr = s["pressure"]
v(pr.get("memory_level") in (1, 2, 4), f"memory pressure level read ({pr.get('memory_level')})")
v("thermal_level" in pr and 0 <= pr["thermal_level"] <= 4, f"thermal level read ({pr.get('thermal_level')})")
v("swap_mb" in pr, "swap read")
v(len(s["load"]) == 3, "load read")
PY
while IFS= read -r line; do
  case "$line" in ok\ *) ok "${line#ok }" ;; *) bad "${line#BAD }" ;; esac
done < "$tmp/verdicts"

"$py" "$ms" now > "$tmp/now" 2>&1 && grep -q "memory pressure level" "$tmp/now" && ok "now prints" || bad "now: $(head -3 "$tmp/now")"
"$py" "$ms" since 5 > "$tmp/since" 2>&1 && grep -q "pressure (mean" "$tmp/since" && ok "since prints" || bad "since: $(head -3 "$tmp/since")"

kill "$busy" "$parent" 2>/dev/null || true
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
