#!/bin/sh
# test-alert-digest.sh -- contract tests for alert-digest, against stand-in ntfy-inbox and hc-status
# commands put first on PATH. Each stand-in prints what the files under $w/say/ hold and exits with
# the status they name, and logs its arguments, so a test sets the world and reads the digest.
#
# Run: sh ~/.local/share/chezmoi/tests/test-alert-digest.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
TOOL="$here/../private_dot_local/bin/executable_alert-digest"

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (no '$3' in: $2)"; fi; }
lacks() { if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 ('$3' present)"; else ok "$1"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
[ -f "$TOOL" ] || { echo "FAIL: no tool at $TOOL"; exit 1; }

w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
export HOME="$w/home" XDG_STATE_HOME="$w/state"
mkdir -p "$HOME" "$w/bin" "$w/say"
# The stand-ins: `ntfy-inbox show --new R` prints say/new (then empties it, as a moved cursor would);
# `ntfy-inbox status` exits say/live-rc; `hc-status --problems --json` prints say/hc.json and exits
# say/hc-rc.
cat > "$w/bin/ntfy-inbox" <<'EOF'
#!/bin/sh
echo "ntfy-inbox $*" >> "$SAY/log"
case $1 in
  show) cat "$SAY/new" 2>/dev/null; : > "$SAY/new"; exit "$(cat "$SAY/show-rc" 2>/dev/null || echo 0)" ;;
  status) echo "writing now:       ?"; exit "$(cat "$SAY/live-rc" 2>/dev/null || echo 0)" ;;
esac
exit 9
EOF
cat > "$w/bin/hc-status" <<'EOF'
#!/bin/sh
echo "hc-status $*" >> "$SAY/log"
cat "$SAY/hc.json"
exit "$(cat "$SAY/hc-rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$w/bin/ntfy-inbox" "$w/bin/hc-status"
export SAY="$w/say" PATH="$w/bin:$PATH"
hc() { # hc <json checks array> [errors array]
  printf '{"checks": %s, "errors": %s}\n' "$1" "${2:-[]}" > "$SAY/hc.json"
}
check() { # check <project> <name> <status>
  printf '{"project": "%s", "name": "%s", "slug": "%s", "status": "%s"}' "$1" "$2" "$2" "$3"
}
run() { out=$(python3 "$TOOL" "$@" 2>"$w/err" </dev/null); rc=$?; err=$(cat "$w/err"); }
: > "$SAY/log"

echo "== quiet"
hc '[]'
export ALERT_DIGEST_NOW=1000
run --reader r1 --triage "skill t"
eq "nothing new, nothing wrong: no output" "$out" ""
eq "  exit 0" "$rc" 0
has "  it asked ntfy-inbox for r1's unseen messages" "$(cat "$SAY/log")" "ntfy-inbox show --new r1"

echo "== new ntfy messages"
printf 'line one\nline two\n' > "$SAY/new"
ALERT_DIGEST_NOW=1010 run --reader r1 --triage "skill t"
has "a header naming the reader and the triage pointer" "$out" "[alert-digest] r1: triage with skill t"
has "  the count" "$out" "ntfy, 2 new:"
has "  each message" "$out" "  line two"
ALERT_DIGEST_NOW=1020 run --reader r1 --triage "skill t"
eq "  and once shown, quiet again" "$out" ""
seq 1 14 | sed 's/^/msg /' > "$SAY/new"
ALERT_DIGEST_NOW=1030 run --reader r1 --triage "skill t"
has "a flood is capped" "$out" "ntfy, 14 new:"
lacks "  the 11th line is not printed" "$out" "msg 11"
has "  and the rest are pointed at" "$out" "and 4 more: ntfy-inbox show --since 1d"

echo "== Healthchecks problems, reported when they change"
hc "[$(check fleet mirror grace)]"
ALERT_DIGEST_NOW=2000 run --reader r1 --triage "skill t"
eq "a grace seen on one read only is not reported (a run a little late)" "$out" ""
hc '[]'
ALERT_DIGEST_NOW=2400 run --reader r1 --triage "skill t"
eq "  and its clearing, never reported, says nothing" "$out" ""
hc "[$(check fleet scrub-framework grace)]"
ALERT_DIGEST_NOW=2800 run --reader r1 --triage "skill t"
eq "  a first sighting of another grace: nothing yet" "$out" ""
ALERT_DIGEST_NOW=3200 run --reader r1 --triage "skill t"
has "a grace on two reads in a row is reported" "$out" "Healthchecks, now in trouble: fleet/scrub-framework grace"
ALERT_DIGEST_NOW=3600 run --reader r1 --triage "skill t"
eq "  the same problem is not repeated" "$out" ""
hc "[$(check fleet scrub-framework down)]"
ALERT_DIGEST_NOW=3700 run --reader r1 --triage "skill t"
eq "  hc-status is not asked again within five minutes" "$out" ""
ALERT_DIGEST_NOW=3901 run --reader r1 --triage "skill t"
has "  a changed state is reported once the interval passes" "$out" "Healthchecks, now in trouble: fleet/scrub-framework down"
hc '[]'
ALERT_DIGEST_NOW=4300 run --reader r1 --triage "skill t"
has "  a cleared problem is reported" "$out" "Healthchecks, cleared: fleet/scrub-framework"
hc "[$(check fleet other down)]"
ALERT_DIGEST_NOW=4400 ALERT_DIGEST_HC_EVERY=60 run --reader r1 --triage "skill t"
has "a down is reported on its first read (and the interval is set by ALERT_DIGEST_HC_EVERY)" "$out" "Healthchecks, now in trouble: fleet/other down"

echo "== session start"
ALERT_DIGEST_NOW=4410 run --reader r1 --triage "skill t" --session-start
has "a session start shows a standing problem again" "$out" "Healthchecks, in trouble now: fleet/other down"
hc '[]'
ALERT_DIGEST_NOW=4420 run --reader r1 --triage "skill t" --session-start
lacks "  and asks hc-status whatever the interval" "$out" "in trouble now"
has "  (so the clearing shows)" "$out" "cleared: fleet/other"
ALERT_DIGEST_NOW=4430 run --reader r1 --triage "skill t" --session-start
eq "  a session start with nothing wrong is quiet" "$out" ""

echo "== readers are independent"
hc "[$(check cloud-test heartbeat down)]"
ALERT_DIGEST_NOW=4000 run --reader r2 --triage "skill t"
has "another reader has its own Healthchecks state" "$out" "cloud-test/heartbeat down"

echo "== the readers themselves failing"
echo 1 > "$SAY/live-rc"
ALERT_DIGEST_NOW=5000 run --reader r1 --triage "skill t"
has "ntfy-inbox not writing is said" "$out" "ntfy-inbox is not writing"
ALERT_DIGEST_NOW=5010 run --reader r1 --triage "skill t"
lacks "  once, not every turn" "$out" "not writing"
echo 0 > "$SAY/live-rc"
ALERT_DIGEST_NOW=5020 run --reader r1 --triage "skill t"
has "  and its return is said" "$out" "ntfy-inbox is writing again"
echo 2 > "$SAY/hc-rc"; hc '[]' '[{"project": "fleet", "error": "HTTP 401"}]'
ALERT_DIGEST_NOW=6000 run --reader r1 --triage "skill t"
has "a project hc-status cannot read is said" "$out" "hc-status could not read fleet: HTTP 401"
eq "  exit 0 all the same" "$rc" 0
echo 0 > "$SAY/hc-rc"; echo 'not json' > "$SAY/hc.json"
ALERT_DIGEST_NOW=7000 run --reader r1 --triage "skill t"
has "unreadable hc-status output is said, not crashed on" "$out" "hc-status gave output that is not JSON"
eq "  exit 0" "$rc" 0
hc '[]'
PATH="$w/nothing:/usr/bin:/bin" ALERT_DIGEST_NOW=8000 run --reader r1 --triage "skill t"
has "a missing reader tool is said" "$out" "ntfy-inbox is not installed"
eq "  exit 0" "$rc" 0

echo "== arguments"
run --triage "skill t"
eq "no reader is exit 2" "$rc" 2
run --reader ../x --triage "skill t"
eq "a reader with a path in it is exit 2" "$rc" 2

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
