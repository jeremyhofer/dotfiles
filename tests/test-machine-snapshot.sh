#!/bin/sh
# test-machine-snapshot.sh — contract tests for machine-snapshot.
#
# /proc is faked through MACHINE_SNAPSHOT_PROC and the clock through MACHINE_SNAPSHOT_NOW, so each
# sample is a fixed, hand-built process table and every CPU figure can be checked to the tick. The
# cases that matter are the attribution ones: CPU used by a command too short-lived to be seen
# alive must still reach the session that ran it, and CPU already counted while a child was alive
# must not be counted again when its parent reaps it.
#
# Run: sh ~/.local/share/chezmoi/tests/test-machine-snapshot.sh
set -u
TOOL="$(cd "$(dirname "$0")/.." && pwd)/private_dot_local/bin/executable_machine-snapshot"

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (no '$3' in: $2)"; fi; }
lacks() { if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 ('$3' present)"; else ok "$1"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
tick=$(python3 -c 'import os; print(os.sysconf("SC_CLK_TCK"))')

w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
export MACHINE_SNAPSHOT_PROC="$w/proc" MACHINE_SNAPSHOT_DIR="$w/state" HOME="$w/home"
mkdir -p "$HOME/Devel/proj"

# proc PID PPID STATE CPU_TICKS CHILD_TICKS START COMM CWD [WCHAN] [ARGS]
proc() {
  d="$w/proc/$1"; mkdir -p "$d"
  printf '%s (%s) %s %s 0 0 0 0 0 0 0 0 0 %s 0 %s 0 20 0 1 0 %s 0 256 0\n' \
    "$1" "$7" "$3" "$2" "$4" "$5" "$6" > "$d/stat"
  printf '%s\n' "$7" > "$d/comm"; printf '%s' "${9:-0}" > "$d/wchan"
  printf '%s\0' ${10:-$7} > "$d/cmdline"; rm -f "$d/cwd"; ln -s "$8" "$d/cwd"
}
reset() { rm -rf "$w/proc"; mkdir -p "$w/proc/pressure"; printf '6.50 5.00 4.00 2/900 99\n' > "$w/proc/loadavg"
  printf 'some avg10=30.00 avg60=1 avg300=1 total=1\nfull avg10=25.00 avg60=1 avg300=1 total=1\n' > "$w/proc/pressure/io"
  printf 'some avg10=0.00 avg60=0 avg300=0 total=0\nfull avg10=0.00 avg60=0 avg300=0 total=0\n' > "$w/proc/pressure/cpu"
  proc 1 0 S 0 0 1 systemd /; }
t() { echo $(( $1 * tick )); }   # seconds -> ticks
rec() { MACHINE_SNAPSHOT_NOW=$1 python3 "$TOOL" record; }
last_row() { python3 -c "
import json,sys
s=json.loads(open('$w/state/history.jsonl').read().splitlines()[-1])
for r in s['rows']:
    if r['pid']=='$1': print(r['$2']); break
else: print('absent')"; }

echo "machine-snapshot:"

# 1) Refuses inside a sandbox, where only its own processes are visible, and writes nothing.
reset; proc 1 0 S 0 0 1 bwrap /
out=$(rec 1000 2>&1); rc=$?
eq "sandbox: refuses" "$rc" 1
has "sandbox: says why" "$out" "refusing to record inside a sandbox"
[ ! -e "$w/state/latest.json" ] && ok "sandbox: nothing written" || no "sandbox: nothing written"

# 2) The first sample is a baseline only: no history line, and `now` says so.
reset
proc 100 1 S "$(t 50)" 0 10 claude "$HOME/Devel/proj"
proc 200 100 R "$(t 10)" 0 20 'node (vitest) x' "$HOME/Devel/proj" 0 'node vitest run'
proc 300 100 S "$(t 1)" 0 30 bash "$HOME/Devel/proj"
rec 1000
[ -e "$w/state/latest.json" ] && ok "first: latest written" || no "first: latest written"
[ ! -e "$w/state/history.jsonl" ] && ok "first: no history line" || no "first: no history line"
has "first: now says no interval" "$(MACHINE_SNAPSHOT_NOW=1001 python3 "$TOOL" now)" "no interval"

# 3) Fifteen seconds later. 200 used 3 s of its own; 300 (seen alive with 1 s) has ended and
#    claude's children counters grew by 1.5 s for it plus 2 s for a command never seen alive.
#    Reaped should be 1.5 + 2 - 1 (already counted while 300 was alive) = 2.5. A new D-state task.
reset
proc 100 1 S "$(t 50)" "$(t 7 | awk '{print $1/2}')" 10 claude "$HOME/Devel/proj"
proc 200 100 R "$(t 13)" 0 20 'node (vitest) x' "$HOME/Devel/proj" 0 'node vitest run'
proc 400 2 D 0 0 40 'kworker/u64:9+netns' / cleanup_net
# A background session's process is named after its version; only its command line names it.
proc 500 1 S 0 0 50 2.1.296 "$HOME/Devel/other" 0 'claude bg-spare --bg-spare x.sock'
proc 510 500 R "$(t 2)" 0 51 python3 "$HOME/Devel/other"
rec 1015
eq "own: CPU in the interval, not since birth" "$(last_row 200 own)" "3.0"
eq "reaped: short-lived and ended children, minus what was counted alive" "$(last_row 100 reaped)" "2.5"
eq "comm with a space and parentheses parses" "$(last_row 200 comm)" "node (vitest) x"
eq "session: nearest claude ancestor, with its directory" "$(last_row 200 session)" "100 ~/Devel/proj"
eq "session: matched by command line when the name is a version" "$(last_row 510 session)" "500 ~/Devel/other"
eq "stalled task recorded with its wait channel" "$(last_row 400 wchan)" "cleanup_net"
eq "idle process left out of the history" "$(last_row 1 own)" "absent"
now=$(MACHINE_SNAPSHOT_NOW=1016 python3 "$TOOL" now)
has "now: rate in cores" "$now" "  0.20    3.0    0.0      200  node (vitest) x"
has "now: stalled list" "$now" "kworker/u64:9+netns  waiting in cleanup_net"
has "now: session total" "$now" "0.37  100 ~/Devel/proj"
has "now: pressure in the header" "$now" "io 30% (all stalled 25%)"

# 4) A reused pid (same number, new start time) counts as a new process, not as a delta.
reset
proc 100 1 S "$(t 50)" "$(t 7 | awk '{print $1/2}')" 10 claude "$HOME/Devel/proj"
proc 200 100 R "$(t 4)" 0 99 bash "$HOME/Devel/proj"
rec 1030
eq "reused pid: everything since its birth" "$(last_row 200 own)" "4.0"

# 5) `since` totals the window, by session and by command, and counts stalls by sample.
s=$(MACHINE_SNAPSHOT_NOW=1031 python3 "$TOOL" since 1)
has "since: sample count" "$s" "2 samples"
has "since: session total over both intervals" "$s" "9.5   0.32  100 ~/Devel/proj"
has "since: by command" "$s" "node (vitest) x"
has "since: stall counted" "$s" "1  kworker/u64:9+netns  in cleanup_net"
s=$(MACHINE_SNAPSHOT_NOW=1031 python3 "$TOOL" since 0.2)
has "since: window excludes older samples" "$s" "1 samples"

# 6) A gap longer than the limit is not a baseline: no history line, so no hour lands in one row.
nlines() { awk 'END{print NR}' "$w/state/history.jsonl"; }
lines=$(nlines)
rec 5000
eq "gap: no history line written" "$(nlines)" "$lines"
has "stale: now warns when the timer has stopped" "$(MACHINE_SNAPSHOT_NOW=6000 python3 "$TOOL" now)" "STALE"

# 7) Retention: once the first line is an hour past the window, older lines are dropped; a first
#    line inside that slack is left alone, so the file is not rewritten on every sample. MAX_GAP is
#    raised so these far-apart samples count as intervals and write history lines.
rec 5015
MACHINE_SNAPSHOT_MAX_GAP=99999 MACHINE_SNAPSHOT_KEEP_HOURS=0.5 rec 9000
ts() { python3 -c "import json; print(' '.join(str(json.loads(l)['ts']) for l in open('$w/state/history.jsonl')))"; }
eq "prune: lines older than the window removed" "$(ts)" "9000.0"
ino() { ls -i "$w/state/history.jsonl" | awk '{print $1}'; }
before=$(ino)
MACHINE_SNAPSHOT_MAX_GAP=99999 MACHINE_SNAPSHOT_KEEP_HOURS=0.5 rec 9015
eq "prune: a recent first line keeps every line" "$(ts)" "9000.0 9015.0"
eq "prune: and the file is appended to, not rewritten" "$(ino)" "$before"

# 8) I/O attribution: read_bytes/write_bytes growth per process, like CPU `own`. A process whose io
#    file cannot be read has no figure (not zero); a process born in the interval counts from zero;
#    a process with no CPU but real I/O still lands in the history; one with neither does not.
mb=1048576
pio() { printf 'rchar: 1\nwchar: 1\nsyscr: 1\nsyscw: 1\nread_bytes: %s\nwrite_bytes: %s\ncancelled_write_bytes: 0\n' "$2" "$3" > "$w/proc/$1/io"; }
val() { python3 -c "
import json
s=json.loads(open('$w/state-io/history.jsonl').read().splitlines()[-1])
for r in s['rows']:
    if r['pid']=='$1': print(r.get('$2','none')); break
else: print('absent')"; }
export MACHINE_SNAPSHOT_DIR="$w/state-io" MACHINE_SNAPSHOT_MAX_GAP=120
reset
proc 100 1 S "$(t 50)" 0 10 claude "$HOME/Devel/proj"
proc 200 100 S 0 0 20 writer "$HOME/Devel/proj";   pio 200 $((10*mb)) $((5*mb))
proc 210 100 S 0 0 21 secret "$HOME/Devel/proj"    # no io file: unreadable
proc 220 100 S 0 0 22 idle "$HOME/Devel/proj";     pio 220 $((3*mb)) $((3*mb))
rec 20000
reset
proc 100 1 S "$(t 50)" 0 10 claude "$HOME/Devel/proj"
proc 200 100 S 0 0 20 writer "$HOME/Devel/proj";   pio 200 $((14*mb)) $((8*mb))
proc 210 100 R "$(t 3)" 0 21 secret "$HOME/Devel/proj"
proc 220 100 S 0 0 22 idle "$HOME/Devel/proj";     pio 220 $((3*mb)) $((3*mb))
proc 300 100 S 0 0 99 builder "$HOME/Devel/proj";  pio 300 0 $((2*mb))
rec 20015
eq "io: read delta since the previous sample" "$(val 200 rd)" "$((4*mb))"
eq "io: write delta since the previous sample" "$(val 200 wr)" "$((3*mb))"
eq "io: born in the interval counts from zero" "$(val 300 wr)" "$((2*mb))"
eq "io: unreadable io file means no figure, not zero" "$(val 210 rd)" "none"
eq "io: no CPU, no I/O delta: left out of the history" "$(val 220 rd)" "absent"
# A latest.json from before this field existed (no io on its processes) is no baseline for I/O.
python3 - "$w/state-io/latest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for p in d["procs"].values():
    p.pop("io", None); p.pop("rd", None); p.pop("wr", None)
json.dump(d, open(sys.argv[1], "w"))
PY
reset
proc 100 1 S "$(t 50)" 0 10 claude "$HOME/Devel/proj"
proc 200 100 S 0 0 20 writer "$HOME/Devel/proj";   pio 200 $((40*mb)) $((8*mb))
rec 20030
eq "io: old latest.json without io gives no delta, no crash" "$(val 200 rd)" "absent"
# Windows over those samples: the first record was a baseline, so two history lines.
s=$(MACHINE_SNAPSHOT_NOW=20031 python3 "$TOOL" since 5)
has "since: I/O by session heading" "$s" "I/O by session"
has "since: I/O by command heading" "$s" "I/O by command"
has "since: I/O by session totals" "$s" "     4.0       5.0  100 ~/Devel/proj"
has "since: I/O by command" "$s" "     0.0       2.0  builder"
lacks "since: a process with no I/O delta is not listed" "$s" "idle"
# Old history lines carry none of the new fields; every reader must still work.
printf '{"ts": 20020.0, "interval": 15, "load": ["1","1","1"], "pressure": {"io_full": 5.0}, "rows": [{"pid": "9", "comm": "old", "state": "R", "wchan": "0", "own": 1.0, "reaped": 0.0, "rss_mb": 1, "cwd": "/", "session": "-", "args": "old"}]}\n' >> "$w/state-io/history.jsonl"
s=$(MACHINE_SNAPSHOT_NOW=20031 python3 "$TOOL" since 5); rc=$?
eq "old history line: since does not crash" "$rc" 0
has "old history line: counted" "$s" "3 samples"
has "old history line: missing pressure keys say not recorded" "$s" "memory full  not recorded"

# 9) Pressure thresholds and /tmp, summarised over a fixture history.
export TZ=UTC
export MACHINE_SNAPSHOT_DIR="$w/state-fx"; mkdir -p "$MACHINE_SNAPSHOT_DIR"
day=$(python3 -c 'import calendar; print(calendar.timegm((2026,10,12,0,0,0)))')
# fx HH MM CPU_SOME MEM_FULL IO_FULL TMP_USED_GB : one history line at that time of day
fx() { python3 -c "
import json
g=2**30
print(json.dumps({'ts': $day+$1*3600+$2*60, 'interval': 15, 'load': ['1','1','1'],
  'pressure': {'cpu_some': $3, 'memory_full': $4, 'io_full': $5},
  'tmp': {'used': $6*g, 'size': 10*g}, 'rows': []}))" >> "$MACHINE_SNAPSHOT_DIR/history.jsonl"; }
fx 8 50 99 99 99 9
fx 9 10 10 0 5 1
fx 9 40 60 11 10 2
fx 10 20 80 20 10.5 3
fx 10 40 50 5 30 3
fx 11 50 99 99 99 9
now=$(python3 -c "print($day+12*3600)")
s=$(MACHINE_SNAPSHOT_NOW=$now python3 "$TOOL" between 08:55 11:00)
has "pressure: cpu some mean, max and count over 50" "$s" "cpu some     mean  50.0%  max  80.0%  over 50%: 2 of 4"
has "pressure: memory full over 10" "$s" "memory full  mean   9.0%  max  20.0%  over 10%: 2 of 4"
has "pressure: io full is strictly over 10" "$s" "io full      mean  13.9%  max  30.0%  over 10%: 2 of 4"
has "tmp: min and max used in the window" "$s" "/tmp used: min 1.00 GB, max 3.00 GB of 10.00 GB"

# 10) between: HH:MM is today in local time; dates are accepted; the window is closed at both ends.
n() { printf '%s\n' "$1" | head -n1 | awk '{print $1}'; }
eq "between: today's clock times" "$(n "$(MACHINE_SNAPSHOT_NOW=$now python3 "$TOOL" between 09:00 10:00)")" 2
eq "between: with dates" "$(n "$(MACHINE_SNAPSHOT_NOW=$now python3 "$TOOL" between 2026-10-12 09:00 2026-10-12 10:30)")" 3
eq "between: a date and time as one quoted argument" \
  "$(n "$(MACHINE_SNAPSHOT_NOW=$now python3 "$TOOL" between '2026-10-12 09:00' '2026-10-12 10:30')")" 3
eq "between: bounds are inclusive" "$(n "$(MACHINE_SNAPSHOT_NOW=$now python3 "$TOOL" between 09:10 10:20)")" 3
eq "between: the day before has no samples" \
  "$(MACHINE_SNAPSHOT_NOW=$now python3 "$TOOL" between 2026-10-11 09:00 2026-10-11 10:00 2>&1 >/dev/null | awk '{print $2, $3, $4}')" "no samples from"
out=$(MACHINE_SNAPSHOT_NOW=$now python3 "$TOOL" between 10:00 09:00 2>&1); eq "between: end before start is an error" "$?" 1
has "between: and says why, not 'no samples'" "$out" "END is before START"
MACHINE_SNAPSHOT_NOW=$now python3 "$TOOL" between 9am 10am >/dev/null 2>&1; eq "between: bad time is an error" "$?" 1
MACHINE_SNAPSHOT_NOW=$now python3 "$TOOL" between 09:00 >/dev/null 2>&1; eq "between: one time is an error" "$?" 1

# 11) /tmp usage is recorded per sample; an unreadable /tmp loses the figure, not the sample.
export MACHINE_SNAPSHOT_DIR="$w/state-tmp" MACHINE_SNAPSHOT_TMP="$w"
reset; rec 30000; rec 30015
tmpval() { python3 -c "
import json
s=json.loads(open('$w/state-tmp/history.jsonl').read().splitlines()[-1])
t=s.get('tmp'); print('none' if not t else ('ok' if 0 < t['used'] <= t['size'] else 'bad'))"; }
eq "tmp: used and size recorded, used within size" "$(tmpval)" ok
has "now: shows tmp use" "$(MACHINE_SNAPSHOT_NOW=30016 python3 "$TOOL" now)" "$w used"
MACHINE_SNAPSHOT_TMP="$w/does-not-exist" rec 30030
eq "tmp: missing directory records no figure" "$(tmpval)" none
unset MACHINE_SNAPSHOT_TMP TZ MACHINE_SNAPSHOT_MAX_GAP
export MACHINE_SNAPSHOT_DIR="$w/state"

# 12) Usage errors are errors.
python3 "$TOOL" bogus >/dev/null 2>&1; eq "unknown command exits non-zero" "$?" 1

# 13) A tree that dies inside one interval. The session process (100) and its child (600) both end
#     between samples; the child is orphaned first, so the subreaper (50, systemd --user) reaps it,
#     not the parent it was last seen under. The subreaper's children counters grow by both
#     processes' whole lives (11 s and 101 s), of which 10 s and 100 s were counted while they were
#     alive. Only the 2 s used since the last sample is new; the rest must not be counted twice.
reset
proc 50 1 S 0 0 5 systemd / 0 '/usr/lib/systemd/systemd --user'
proc 100 50 S "$(t 10)" 0 10 claude "$HOME/Devel/proj"
proc 600 100 R "$(t 100)" 0 60 node "$HOME/Devel/proj"
rec 3000
reset
proc 50 1 S 0 "$(t 112)" 5 systemd / 0 '/usr/lib/systemd/systemd --user'
rec 3015
eq "orphans: a subreaper's reaped CPU excludes what was counted alive" "$(last_row 50 reaped)" "2.0"

# 14) The same correction must not take more than was counted: an unrelated short-lived child the
#     subreaper reaped in the same interval (3 s, never seen alive) still counts.
reset
proc 50 1 S 0 0 5 systemd / 0 '/usr/lib/systemd/systemd --user'
proc 100 50 S "$(t 10)" 0 10 claude "$HOME/Devel/proj"
proc 600 100 R "$(t 100)" 0 60 node "$HOME/Devel/proj"
rec 4000
reset
proc 50 1 S 0 "$(t 115)" 5 systemd / 0 '/usr/lib/systemd/systemd --user'
rec 4015
eq "orphans: CPU never seen alive still reaches the subreaper" "$(last_row 50 reaped)" "5.0"

# 15) A window summary checks the attribution against the machine's cores, and says so loudly when
#     a sample accounts for more CPU than exists.
export MACHINE_SNAPSHOT_DIR="$w/state-cores" MACHINE_SNAPSHOT_CORES=4; mkdir -p "$MACHINE_SNAPSHOT_DIR"
cx() { python3 -c "
import json
print(json.dumps({'ts': 50000+$1, 'interval': 10, 'load': ['1','1','1'], 'pressure': {},
  'rows': [{'pid':'9','comm':'x','state':'R','wchan':'','own':$2,'reaped':$3,'rss_mb':1,'cwd':'/','session':'-','args':'x'}]}))" >> "$MACHINE_SNAPSHOT_DIR/history.jsonl"; }
cx 10 20 0; cx 20 30 0
s=$(MACHINE_SNAPSHOT_NOW=50030 python3 "$TOOL" since 5)
has "cores: within the machine is reported plainly" "$s" "CPU accounted: mean 2.5 cores of 4, max 3.0; samples over 4 cores: 0 of 2"
lacks "cores: no warning when within the machine" "$s" "OVERCOUNTED"
cx 30 10 50
s=$(MACHINE_SNAPSHOT_NOW=50040 python3 "$TOOL" since 5)
has "cores: a sample above the machine is counted" "$s" "samples over 4 cores: 1 of 3"
has "cores: and flagged" "$s" "ATTRIBUTION OVERCOUNTED"
unset MACHINE_SNAPSHOT_CORES

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
