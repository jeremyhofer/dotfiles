#!/bin/sh
# test-ntfy-inbox.sh -- contract tests for ntfy-inbox against a local stub of ntfy's JSON stream.
#
# The stub (stub-ntfy-server.py) replays a scripted list of connections, each streaming `open`,
# `keepalive` and `message` events and then closing or hanging. Nothing here leaves loopback.
#
# Run: sh ~/.local/share/chezmoi/tests/test-ntfy-inbox.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
TOOL="$here/../private_dot_local/bin/executable_ntfy-inbox"
STUB="$here/stub-ntfy-server.py"

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (no '$3' in: $2)"; fi; }
lacks() { if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 ('$3' present)"; else ok "$1"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
[ -f "$TOOL" ] || { echo "FAIL: no tool at $TOOL"; exit 1; }

w=$(mktemp -d); trap 'kill "${spid:-0}" 2>/dev/null; rm -rf "$w"' EXIT
export HOME="$w/home" XDG_CONFIG_HOME="$w/cfg" XDG_STATE_HOME="$w/state" TZ=UTC
export NTFY_INBOX_BACKOFF_MIN=0.05 NTFY_INBOX_BACKOFF_MAX=0.2 NTFY_INBOX_STALL=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME/ntfy-inbox"
cfg="$XDG_CONFIG_HOME/ntfy-inbox"; msgs="$XDG_STATE_HOME/ntfy-inbox/messages.jsonl"
state_file="$XDG_STATE_HOME/ntfy-inbox/state.json"
# A recognizable fake credential, so a leak is found by text search.
PLANTED=tk_SECRETTOKENVALUE

# An ntfy `message` event line, as the server sends it.
M() { # id topic time priority title message
  printf '{"id":"%s","time":%s,"expires":9999999999,"event":"message","topic":"%s","priority":%s,"title":"%s","message":"%s"}' "$1" "$3" "$2" "$4" "$5" "$6"
}
OPEN='{"id":"o1","time":1,"event":"open","topic":"t1,t2"}'
KEEP='{"id":"k1","time":2,"event":"keepalive","topic":"t1,t2"}'

# serve PLAN-JSON: start a fresh stub on the plan and point the tool at it.
serve() {
  [ -n "${spid:-}" ] && kill "$spid" 2>/dev/null
  rm -f "$w/port" "$w/reqs"; : > "$w/reqs"
  printf '%s' "$1" > "$w/plan.json"
  python3 "$STUB" "$w/port" "$w/plan.json" "$w/reqs" & spid=$!
  i=0; while [ ! -s "$w/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  [ -s "$w/port" ] || { echo "FAIL: stub did not start"; exit 1; }
  printf '# test topics\nserver http://127.0.0.1:%s\nt1\nt2\n' "$(cat "$w/port")" > "$cfg/topics"
  rm -rf "$XDG_STATE_HOME"
}
reqq() { python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[int(sys.argv[2])])[sys.argv[3]])' "$w/reqs" "$1" "$2"; }
run() { out=$(python3 "$TOOL" "$@" 2>"$w/err" </dev/null); rc=$?; err=$(cat "$w/err"); }
nlines() { wc -l < "$1" | tr -d ' '; }

echo "== dedup, last id, resume, keepalives"
rm -f "$cfg/token"
plan=$(python3 - <<PY
import json
M = lambda i,t,ts,p,ti,m: json.dumps({"id":i,"time":ts,"event":"message","topic":t,"priority":p,"title":ti,"message":m})
open_ = '$OPEN'; keep = '$KEEP'
print(json.dumps([
  {"lines":[open_, keep, M("m1","t1",1793534000,3,"[LIVE] disk","disk 91%"), keep, M("m2","t2",1793534100,5,"","no title")], "end":"close"},
  {"lines":[open_, M("m2","t2",1793534100,5,"","no title"), M("m3","t1",1793534200,3,"[TEST] x","three")], "end":"close"},
]))
PY
)
serve "$plan"
NTFY_INBOX_MAX_CONNECTS=2 run run
eq "run exits 0" "$rc" 0
eq "three distinct messages stored, the replayed m2 once" "$(nlines "$msgs")" 3
eq "ids in arrival order" "$(python3 -c 'import json,sys; print(",".join(json.loads(l)["id"] for l in open(sys.argv[1])))' "$msgs")" "m1,m2,m3"
lacks "keepalive events are not stored" "$(cat "$msgs")" keepalive
lacks "open events are not stored" "$(cat "$msgs")" '"event": "open"'
eq "last id recorded" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["last_id"])' "$state_file")" m3
eq "first connect asks for the bounded window" "$(reqq 0 query)" "since=12h"
eq "reconnect asks since the last id" "$(reqq 1 query)" "since=m2"
eq "both topics in one subscription" "$(reqq 0 path)" "/t1,t2/json"
has "connect logged" "$err" "connected to"
has "disconnect logged" "$err" "disconnected"

echo "== a restart resumes from the recorded id"
serve "$(python3 -c 'import json; print(json.dumps([{"lines":[json.dumps({"id":"m9","time":1793534000,"event":"message","topic":"t1","message":"body"})],"end":"close"}]))')"
mkdir -p "$XDG_STATE_HOME/ntfy-inbox"
M m9 t1 1793534000 3 t body > "$msgs"; echo >> "$msgs"
printf '{"last_id":"m9"}' > "$state_file"
NTFY_INBOX_MAX_CONNECTS=1 run run
eq "fresh process asks since=m9" "$(reqq 0 query)" "since=m9"
eq "a message already in the file is not stored again after a restart" "$(nlines "$msgs")" 1

echo "== a stalled connection triggers a reconnect"
serve "$(python3 - <<PY
import json
print(json.dumps([
  {"lines":['$OPEN'], "end":"hang"},
  {"lines":['$OPEN', json.dumps({"id":"s1","time":1793534000,"event":"message","topic":"t1","message":"after stall"})], "end":"close"},
]))
PY
)"
NTFY_INBOX_MAX_CONNECTS=2 run run
eq "two connection attempts" "$(nlines "$w/reqs")" 2
has "message after the stall stored" "$(cat "$msgs")" "after stall"
has "stall logged as a disconnect" "$err" "disconnected"

echo "== token: sent as Bearer, never logged"
printf '%s\n' "$PLANTED" > "$cfg/token"; chmod 600 "$cfg/token"
serve '[{"status":401,"lines":[],"end":"close"},{"lines":[],"end":"close"}]'
NTFY_INBOX_MAX_CONNECTS=2 run run
eq "Authorization header carries the credential" "$(reqq 0 auth)" "Bearer $PLANTED"
has "HTTP failure logged" "$err" "HTTP 401"
lacks "credential absent from stderr" "$err" "SECRETTOKEN"
lacks "credential absent from stdout" "$out" "SECRETTOKEN"

echo "== token file permissions"
chmod 640 "$cfg/token"
serve '[]'
NTFY_INBOX_MAX_CONNECTS=1 run run
eq "group-readable token refused with exit 2" "$rc" 2
has "tells how to fix" "$err" "chmod 600"
lacks "refusal does not print the credential" "$err" "SECRETTOKEN"
eq "no connection was made" "$(nlines "$w/reqs")" 0
chmod 604 "$cfg/token"
NTFY_INBOX_MAX_CONNECTS=1 run run
eq "other-readable token refused" "$rc" 2
rm -f "$cfg/token"

echo "== config errors"
rm -f "$cfg/topics"
run run
eq "missing topics file is exit 2" "$rc" 2
has "names the topics file" "$err" "topics"

echo "== show"
serve '[]'
mkdir -p "$XDG_STATE_HOME/ntfy-inbox"
{
  M a1 t1 1793534000 3 "[LIVE] old" "ten hours ago"
  echo
  M a2 t2 1793566000 4 "" "recent other topic"
  echo
  M a3 t1 1793566100 5 "[TEST] new" "recent t1"
  echo
} > "$msgs"
export NTFY_INBOX_NOW=1793567000
run show
eq "show lists all, exit 0" "$rc" 0
eq "three lines" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 3
eq "newest last" "$(printf '%s\n' "$out" | tail -1 | grep -c 'recent t1')" 1
has "time, topic, priority, title, message in a row" "$out" "2026-11-01 20:48:20  t1  p5  [TEST] new  recent t1"
has "missing title shown as dash" "$out" "t2  p4  -  recent other topic"
run show --since 1h
eq "since filters old messages" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 2
lacks "old message gone" "$out" "ten hours ago"
run show --topic t1
eq "topic filter" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 2
lacks "other topic gone" "$out" "other topic"
run show --since 1h --topic t2
eq "filters combine" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1
run show --json
eq "json is an array of all three" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" 3
printf '%s\n' '{"id":"e1","time":1793566200,"event":"message","topic":"t1","priority":3,"message":"evil \u001b[31mred\nsecond"}' >> "$msgs"
run show
lacks "escape characters never reach the terminal" "$out" "$(printf '\033')"
has "newlines in a body collapse to one row" "$out" "evil ?[31mred | second"
rm -f "$msgs"
run show
eq "no file is exit 1" "$rc" 1
unset NTFY_INBOX_NOW

echo "== status"
mkdir -p "$XDG_STATE_HOME/ntfy-inbox"
printf '{"last_id":"x","last_connect":1793566000,"last_event":1793566990,"last_message_time":1793565000}' > "$state_file"
NTFY_INBOX_NOW=1793567000 run status
eq "recent stream event means live, exit 0" "$rc" 0
has "says writing now" "$out" "writing now:       yes"
has "shows last message time" "$out" "2026-11-01 20:30:00"
NTFY_INBOX_NOW=1793570000 run status
eq "a long-silent daemon is not live, exit 1" "$rc" 1
has "says not writing" "$out" "writing now:       no"
rm -f "$state_file"
run status
eq "no state at all is exit 1" "$rc" 1
has "says never" "$out" "never"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
