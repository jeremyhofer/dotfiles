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
rec 1015
eq "own: CPU in the interval, not since birth" "$(last_row 200 own)" "3.0"
eq "reaped: short-lived and ended children, minus what was counted alive" "$(last_row 100 reaped)" "2.5"
eq "comm with a space and parentheses parses" "$(last_row 200 comm)" "node (vitest) x"
eq "session: nearest claude ancestor, with its directory" "$(last_row 200 session)" "100 ~/Devel/proj"
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

# 8) Usage errors are errors.
python3 "$TOOL" bogus >/dev/null 2>&1; eq "unknown command exits non-zero" "$?" 1

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
