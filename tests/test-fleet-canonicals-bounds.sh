#!/usr/bin/env zsh
# run-all: serial
# fleet-canonicals' cases under a wall-clock HANG GUARD, alone. Each runs a verb under a 15 s bound
# (`timeout`, or perl's alarm where macOS has no coreutils) so that a regression in the delay clamp
# fails instead of hanging the suite. A bound is wall-clock, so this suite runs serially (run-all's
# rule: a threshold is never loosened to cope with load). It is its own file so that
# test-fleet-canonicals.sh, which has no other bound, runs in the concurrent batch.
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
set -u
HERE=${0:A:h}
. "$HERE/git-isolate.sh"
_srcbin=$(mktemp -d "$_TMP/srcbin.XXXXXX")
ln -sf "$HERE/../private_dot_local/bin/executable_fleet-decl" "$_srcbin/fleet-decl"
PATH="$_srcbin:$PATH"; export PATH
TOOL="$HERE/../private_dot_local/bin/executable_fleet-canonicals"
[[ -f "$TOOL" ]] || { print "FAIL: tool not found at $TOOL"; exit 1 }
TMPROOT=$(mktemp -d "$_TMP/test-fleet-canonicals-bounds.XXXXXX"); trap 'rm -rf "$TMPROOT" "$_srcbin"' EXIT
# Nothing here reads the machine's own fleet state, config or record.
export FLEET_CANONICALS_CONFIG="$_srcbin/no-config" FLEET_STATE="$TMPROOT/fcstate"
export FLEET_PID_RECORD_DIR="$_srcbin/pids" FLEET_PROC_ROOT="$_srcbin/proc" FLEET_RECORD="$TMPROOT/rec.yaml"
# Handoffs are accepted only inside a known handoff tree, and a launch's scratch root goes under
# this prefix rather than the real /tmp.
export FLEET_HANDOFFS_SEARCH="$TMPROOT" FLEET_TMPROOT_PREFIX="$TMPROOT/tmproots"
mkdir -p "$FLEET_PID_RECORD_DIR" "$FLEET_PROC_ROOT" "$FLEET_STATE"
print 'projects:\n  seed:\n    scope: seed' > "$FLEET_RECORD"

fail=0
ok()  { print "ok:   $1" }
bad() { print "FAIL: $1"; fail=1 }

# A hang guard that exists on both platforms: `timeout` is coreutils, absent on macOS unless
# installed; perl's alarm is the fallback, so the bound stays REAL rather than being skipped.
if   (( $+commands[timeout] ));  then BOUND=(timeout)
elif (( $+commands[gtimeout] )); then BOUND=(gtimeout)
else BOUND=(perl -e 'alarm shift @ARGV; exec @ARGV')
fi

# --- wait-for-reset -------------------------------------------------------------------------
# The in-session half. Unlike resume-at this one CAN be run for real in a test, because a target
# already in the past clamps the delay to zero -- so the whole path executes end to end in no time
# and without launching anything. That clamp is itself the assertion: an unclamped delay would go
# negative and `sleep` would either error or, worse, be interpreted as a huge value.
out=$("${BOUND[@]}" 15 bash "$TOOL" wait-for-reset --at '1970-01-01 00:00:00' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"resume work"* ]] && ok "wait-for-reset with a past target fires at once" \
    || bad "wait-for-reset did not fire on a past target (rc=$rc): $out"

# The PID line is load-bearing, not decoration: the rule this verb exists to serve says never call a
# trigger armed without checking, and that check is only cheap if the pid is printed.
[[ "$out" == *"ARMED pid "* ]] && ok "wait-for-reset prints its pid so arming can be verified" \
    || bad "wait-for-reset printed no pid: $out"

# It must NOT launch anything -- that is the entire difference from resume-at.
[[ "$out" != *canonical* ]] && ok "wait-for-reset launches nothing" \
    || bad "wait-for-reset appears to have launched something: $out"

out=$(bash "$TOOL" wait-for-reset --at 'not-a-time' --dry-run 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"could not parse time"* ]] && ok "wait-for-reset refuses an unparseable time" \
    || bad "wait-for-reset accepted a bad time (rc=$rc): $out"

# --- a plan with only the 7-day window ------------------------------------------------------------
# The payload's five_hour is then null, so there is no 5-hour reset to wait for. Both verbs must
# refuse, say why and name the weekly reset, rather than report "nothing cached" as if a retry helps.
# The cache is a runtime dir of per-session files, as claude-usage-state writes them.
UD="$TMPROOT/usage-7d"; mkdir -p "$UD/claude-usage"
print -r -- '{"session_id":"a","five_hour_pct":null,"five_hour_resets_at":null,"seven_day_pct":40,"seven_day_resets_at":1794042000}' \
    > "$UD/claude-usage/a.json"
for verb in wait-for-reset resume-at; do
    out=$(XDG_RUNTIME_DIR="$UD" "${BOUND[@]}" 15 bash "$TOOL" $verb --dry-run 2>&1); rc=$?
    [[ $rc -ne 0 && "$out" == *"no 5-hour window"* && "$out" == *"2026-11-07"* && "$out" == *"not meaningful"* ]] \
        && ok "$verb refuses on a 7-day-only plan, naming the weekly reset" \
        || bad "$verb on a 7-day-only plan (rc=$rc): $out"
    out=$(XDG_RUNTIME_DIR="$UD" USAGE_WINDOW=5h "${BOUND[@]}" 15 bash "$TOOL" $verb --dry-run 2>&1); rc=$?
    [[ $rc -ne 0 && "$out" == *"no reset time cached yet"* && "$out" != *"no 5-hour window"* ]] \
        && ok "$verb with USAGE_WINDOW=5h keeps the plain not-cached message" \
        || bad "$verb with USAGE_WINDOW=5h (rc=$rc): $out"
    out=$(XDG_RUNTIME_DIR="$UD" "${BOUND[@]}" 15 bash "$TOOL" $verb --at '1970-01-01 00:00:00' --dry-run 2>&1); rc=$?
    [[ $rc -eq 0 && "$out" == *"dry run"* ]] && ok "$verb --at still works on a 7-day-only plan" \
        || bad "$verb --at on a 7-day-only plan (rc=$rc): $out"
done
# With a 5-hour reset cached the original path is untouched.
print -r -- '{"session_id":"b","five_hour_pct":40,"five_hour_resets_at":1793466000,"seven_day_pct":40,"seven_day_resets_at":1794042000}' \
    > "$UD/claude-usage/b.json"
out=$(XDG_RUNTIME_DIR="$UD" "${BOUND[@]}" 15 bash "$TOOL" wait-for-reset --dry-run 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"ARMED pid "* ]] && ok "wait-for-reset reads the 5-hour reset when the plan has one" \
    || bad "wait-for-reset with a 5-hour reset (rc=$rc): $out"
# No cache directory at all: nothing cached, not an unparseable time.
for verb in wait-for-reset resume-at; do
    out=$(XDG_RUNTIME_DIR="$TMPROOT/none" "${BOUND[@]}" 15 bash "$TOOL" $verb --dry-run 2>&1); rc=$?
    [[ $rc -ne 0 && "$out" == *"no usage reset time is recorded on this machine"* && "$out" == *"--at"* ]] \
        && ok "$verb with no reset source says so and points at --at" \
        || bad "$verb with no cache dir (rc=$rc): $out"
done


# ---- a time bound that exists on every machine ------------------------------------------------
# `timeout` is GNU coreutils and absent from a stock macOS, where the wake path in `resume` called
# it bare, so on that machine the wake failed before it started. The helper falls back to perl's
# alarm, which every macOS ships. Run with a PATH holding perl and sleep only, so neither timeout
# nor gtimeout can be found and the fallback is what bounds the command.
print "\n== run_bounded: bounds a command without GNU timeout =="
BD="$TMPROOT/bounded-bin"; mkdir -p "$BD"
ln -sf "$(command -v perl)" "$BD/perl"; ln -sf "$(command -v sleep)" "$BD/sleep"
awk '/^run_bounded\(\)/,/^}/' "$TOOL" > "$TMPROOT/run_bounded.sh"
_bash=$(command -v bash)
_t0=$SECONDS
out=$(PATH="$BD" "$_bash" -c '. "$1"; run_bounded 1 sleep 6; echo "rc=$?"' _ "$TMPROOT/run_bounded.sh" 2>&1)
_el=$(( SECONDS - _t0 ))
[[ -s "$TMPROOT/run_bounded.sh" && "$out" == *"rc="* && "$out" != *"rc=0"* && $_el -lt 5 ]] \
    && ok "run_bounded cuts a command off with neither timeout nor gtimeout on PATH" \
    || bad "run_bounded did not bound the command (elapsed ${_el}s): $out"
out=$(PATH="$BD" "$_bash" -c '. "$1"; run_bounded 5 sleep 0; echo "rc=$?"' _ "$TMPROOT/run_bounded.sh" 2>&1)
[[ "$out" == *"rc=0"* ]] && ok "run_bounded passes a command's own success through" \
    || bad "run_bounded broke a command that finished in time: $out"

# ---- resume-at's unnamed-set path, end to end ---------------------------------------------------
# A past --at makes the wait zero, so the whole path runs: it starts every seat that autostarts and
# is missing, and not the one whose canonicalAutostart is false. The launcher is a recording stub.
cat > "$TMPROOT/claude-stub" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$TMPROOT_LAUNCHLOG"
STUB
chmod +x "$TMPROOT/claude-stub"
export FLEET_CLAUDE_CMD="$TMPROOT/claude-stub" TMPROOT_LAUNCHLOG="$TMPROOT/launches.log"
AU="$TMPROOT/autostart"; mkdir -p "$AU/st"
for _n in opt plain crit; do mkdir -p "$AU/$_n"; done
cat > "$AU/rec.yaml" <<YAML
projects:
  opt:
    scope: opt
    canonical: auto-opt-canonical
    canonicalIdentity: "the optional seat"
    canonicalLaunchDir: opt
    canonicalLaunchModel: fable
    canonicalAutostart: false
    canonicalMachines: [$(hostname)]
  plain:
    scope: plain
    canonical: auto-plain-canonical
    canonicalIdentity: "the seat that sets no key"
    canonicalLaunchDir: plain
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  crit:
    scope: crit
    canonical: auto-crit-canonical
    canonicalIdentity: "the critical seat"
    canonicalLaunchDir: crit
    canonicalLaunchModel: fable
    canonicalAutostart: true
    canonicalMachines: [$(hostname)]
YAML
for _n in auto-opt-canonical auto-plain-canonical auto-crit-canonical; do
  printf 'fixture handoff for %s\n' "$_n" > "$AU/st/$_n.handoff.md"
  FLEET_ROOT="$AU" FLEET_RECORD="$AU/rec.yaml" FLEET_STATE="$AU/st" bash "$TOOL" handoff "$_n" --set "$AU/st/$_n.handoff.md" >/dev/null 2>&1
done
echo '[]' > "$AU/none.json"
# (h) the unnamed-set path: resume-at launches whatever is missing after a usage reset. A past --at
# makes the wait zero, so the whole path runs here; the launcher is the recording stub.
: > "$TMPROOT_LAUNCHLOG"
out=$("${BOUND[@]}" 30 env FLEET_ROOT="$AU" FLEET_RECORD="$AU/rec.yaml" FLEET_STATE="$AU/st" \
      FLEET_AGENTS_JSON_CMD="cat $AU/none.json" bash "$TOOL" resume-at --at '1970-01-01 00:00:00' 2>&1); rc=$?
_l=$(cat "$TMPROOT_LAUNCHLOG")
[[ $rc -eq 0 && "$_l" == *"-n auto-plain-canonical "* && "$_l" == *"-n auto-crit-canonical "* ]] \
  && ok "h: resume-at resumes the autostart seats (rc=$rc)" || bad "h: resume-at launched too little (rc=$rc): $_l / $out"
[[ "$_l" != *"-n auto-opt-canonical "* ]] && ok "h: resume-at does not launch a seat with canonicalAutostart: false" \
  || bad "h: resume-at launched an optional seat: $_l"

[[ $fail == 0 ]] && { print "ALL PASS"; exit 0 } || { print "FAILURES"; exit 1 }
