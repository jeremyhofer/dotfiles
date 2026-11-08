#!/usr/bin/env zsh
# Unit test for fleet-canonicals. The live `claude agents --json` call is injected via
# $FLEET_AGENTS_JSON_CMD so the logic is testable without live sessions.
set -u
HERE=${0:A:h}
# No machine-global git config, so none of its commit hooks or signing settings reach the scratch
# repositories below.
. "$HERE/git-isolate.sh"

# THE fleet-decl UNDER TEST IS THE ONE IN THIS SOURCE TREE, not whatever is deployed.
#
# Found by the commit gate, which is the only place this could surface: the author's shell had the
# source copy on PATH, so the suite passed locally while the gate -- running with a normal PATH --
# reached the DEPLOYED copy, which predated the verbs these cases exercise. A `command -v` check
# cannot see that: the tool is present, just older, so "present" passes and the assertions fail
# with a usage message. Testing source code against a deployed dependency reports on a combination
# that exists on no machine.
_t=${TMPDIR:-/tmp}; _t=${_t%/}
_srcbin=$(mktemp -d "$_t/srcbin.XXXXXX")
_fd="$HERE/../private_dot_local/bin/executable_fleet-decl"
[ -f "$_fd" ] || { echo "FAIL: fleet-decl source not found at $_fd"; exit 1; }
ln -sf "$_fd" "$_srcbin/fleet-decl"
PATH="$_srcbin:$PATH"; export PATH
TOOL="$HERE/../private_dot_local/bin/executable_fleet-canonicals"
# The tool reads a per-machine config file; a machine that has one would otherwise feed its own
# handoffs directory and hub into every case below. Pointed at a path that does not exist, so each
# case starts from the defaults and sets what it needs.
export FLEET_CANONICALS_CONFIG="$_srcbin/no-config"
REAL_TMP_BEFORE=$(find /tmp -maxdepth 1 -name 'c-*' 2>/dev/null | sort)
[[ -f "$TOOL" ]] || { print "FAIL: tool not found at $TOOL"; exit 1 }

# --- fixture pids must not collide with THIS process's ancestry -------------------------------
# fleet-canonicals identifies the session it is running inside by walking $$ upward and matching
# listed pids. That is correct behavior, and it means a fixture pid that happens to be a real
# ancestor makes the tool report a FIXTURE session as "this session" -- so an unrelated assertion
# fails and the message points nowhere near the cause.
#
# It is not hypothetical. The fixtures originally used 111/222/333, and inside a PID namespace the
# suite runner's own pid is small and reachable, so whether the collision happened depended on how
# many processes had been forked before it. A full-suite run refused a commit on it while the same
# tree passed minutes later -- the worst shape of flake, because it reads as a real regression in
# whatever it lands on.
#
# High pids make the collision vanishingly unlikely rather than impossible, so the residual case is
# NAMED here instead of being left to resurface as a mystery.
FIXTURE_PIDS=(90111 90222 90333 90444 90555 90666 90777)
_anc=""; _p=$$
while [[ -n "$_p" && "$_p" -gt 1 ]]; do
  _anc="$_anc $_p"
  _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
done
for _fp in $FIXTURE_PIDS; do
  if [[ " $_anc " == *" $_fp "* ]]; then
    print "FAIL: fixture pid $_fp is a real ancestor of this test process ($_anc)."
    print "      The tool would call that fixture session 'this session'. Raise FIXTURE_PIDS."
    exit 1
  fi
done

fail=0
ok()  { print "ok:   $1" }
bad() { print "FAIL: $1"; fail=1 }

TMPROOT=$(mktemp -d); trap 'rm -rf "$TMPROOT" "$_srcbin"' EXIT
# A launch refuses a handoff outside the staging directory and the configured handoffs trees. The
# fixtures keep their handoffs under TMPROOT, so it is every case's handoffs tree unless a case
# sets its own.
export FLEET_HANDOFFS_SEARCH="$TMPROOT"

# A hang-guard that exists on BOTH platforms. `timeout` is coreutils and is absent on macOS, where
# it ships as `gtimeout` only if coreutils was installed -- which this fleet's Mac bootstrap does
# not do. perl's alarm is the fallback because perl is present on every macOS by default.
#
# The fallback keeps the bound REAL rather than skipping the assertion, and that distinction is the
# point: a skipped hang-guard is how a regression in the delay clamp would hang the suite forever
# instead of failing it -- and a suite that hangs reports the same thing as one that was never run.
if   (( $+commands[timeout] ));  then BOUND=(timeout)
elif (( $+commands[gtimeout] )); then BOUND=(gtimeout)
else BOUND=(perl -e 'alarm shift @ARGV; exec @ARGV')
fi

# A fixture fleet: one healthy, one duplicated (older + newer), one missing entirely.
cat > "$TMPROOT/agents.json" <<'JSON'
[{"pid":90111,"id":"aaa1","cwd":"/x","kind":"background","startedAt":1000,"sessionId":"s1","name":"alpha-canonical","status":"idle","state":"done"},
 {"pid":90222,"id":"bbb2","cwd":"/y","kind":"background","startedAt":1000,"sessionId":"s2","name":"beta-canonical","status":"idle","state":"done"},
 {"pid":90333,"id":"ccc3","cwd":"/y","kind":"background","startedAt":9000,"sessionId":"s3","name":"beta-canonical","status":"busy","state":"running"}]
JSON
print -l 'alpha-canonical' 'beta-canonical' '# a comment' 'gamma-canonical' > "$TMPROOT/roster"

# THE FLEET RECORD is the manifest now: a canonical exists because the record declares it, and
# this machine runs it because the record says so. `gamma-canonical` is deliberately on the roster
# and ABSENT from the record -- that asymmetry is what the "rostered but not declared" refusal
# case below exercises, and it is the real shape of a half-finished migration.
command -v fleet-decl >/dev/null 2>&1 || {
  echo "FAIL: fleet-decl is not on PATH — the tool cannot read the record without it"; exit 1; }
cat > "$TMPROOT/rec.yaml" <<YAML
projects:
  alpha:
    scope: alpha
    canonical: alpha-canonical
    canonicalIdentity: "the canonical session for alpha"
    canonicalLaunchDir: alpha
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  beta:
    scope: beta
    canonical: beta-canonical
    canonicalIdentity: "the canonical session for beta"
    canonicalLaunchDir: beta
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  delta:
    scope: proj
    canonical: delta-canonical
    canonicalIdentity: "the canonical session for delta"
    canonicalLaunchDir: proj
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  epsilon:
    scope: consulting/example.com/repo/branch
    canonical: epsilon-canonical
    canonicalIdentity: "the canonical session for epsilon"
    canonicalLaunchDir: consulting/example.com/repo/branch
    canonicalLaunchModel: opus
    canonicalMachines: [$(hostname)]
  eta:
    scope: eta
    canonical: eta-canonical
    canonicalIdentity: "the canonical session for eta"
    canonicalLaunchDir: eta
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  self:
    scope: self
    canonical: self-canonical
    canonicalIdentity: "the canonical session for self"
    canonicalLaunchDir: self
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  theta:
    scope: theta
    canonical: theta-canonical
    canonicalIdentity: "the canonical session for theta"
    canonicalLaunchDir: theta
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  three:
    scope: three
    canonical: three-canonical
    canonicalIdentity: "the canonical session for three"
    canonicalLaunchDir: three
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  two:
    scope: two
    canonical: two-canonical
    canonicalIdentity: "the canonical session for two"
    canonicalLaunchDir: two
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  zeta:
    scope: zeta
    canonical: zeta-canonical
    canonicalIdentity: "the canonical session for zeta"
    canonicalLaunchDir: zeta
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  self2:
    scope: self2
    canonical: self2-canonical
    canonicalIdentity: "the canonical session for self2"
    canonicalLaunchDir: self2
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  elsewhere:
    scope: other
    canonical: elsewhere-canonical
    canonicalIdentity: "the canonical session for elsewhere"
    canonicalLaunchDir: other
    canonicalLaunchModel: opus
    canonicalMachines: [some-other-host]
YAML
# Exported ONCE rather than added to each invocation. Several cases build their own env line, and
# an invocation that sets FLEET_ROOT but forgets the record silently reads the REAL machine's
# manifest -- which is a test that passes or fails based on the developer's own fleet rather than
# its fixture. Exporting makes the fixture the default and an override deliberate.
export FLEET_RECORD="$TMPROOT/rec.yaml"
# FLEET_STATE is exported too, and that is a test-ISOLATION fix rather than a consequence of this
# migration: several cases never set it, so they read and wrote the developer's REAL handoff-pointer
# directory. A suite whose result depends on the machine it runs on is not a suite.
export FLEET_STATE="$TMPROOT/fcstate"
mkdir -p "$TMPROOT/fcstate"
# FLEET_TMPROOT_PREFIX likewise: several cases launch without setting it, and a launch makes its
# scratch root under the prefix, so they made c-<name>-XXXXXX directories in the REAL /tmp. Inside an
# agent sandbox /tmp is not writable, so the mktemp failed quietly and the leak check below could not
# see it; run from a terminal (the base's pre-apply, 2026-11-08) it left nine. Cases that test the
# prefix itself still set their own.
export FLEET_TMPROOT_PREFIX="$TMPROOT/tmproots"
mkdir -p "$TMPROOT/tmproots"

# A launcher stub. `up` is the one verb whose real effect cannot be exercised, so it is pointed at
# a recorder: every launch appends its full argument list, which lets the cases below assert the
# COMPOSED command -- the working directory, the model tier and the identity sentence. None of that
# was assertable while each repo carried its own kickoff script, because the test could only
# substitute a harmless script and never saw what a real one contained.
cat > "$TMPROOT/claude-stub" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$TMPROOT_LAUNCHLOG"
STUB
chmod +x "$TMPROOT/claude-stub"
export FLEET_CLAUDE_CMD="$TMPROOT/claude-stub" TMPROOT_LAUNCHLOG="$TMPROOT/launches.log"
: > "$TMPROOT_LAUNCHLOG"

# Every declared launch directory must EXIST. The launcher cd's into it and refuses if that fails,
# which is correct -- launching into a directory that is not there would start a session with no
# project -- but it means a fixture that declares a canonical must also create its home.
for _d in $(fleet-decl --canonicals 2>/dev/null); do
  _dir=$(fleet-decl --canonical "$_d" canonicalLaunchDir 2>/dev/null) || continue
  mkdir -p "$TMPROOT/$_dir"
  # And a recorded handoff, because a launch resolves one and refuses without it. That refusal is
  # correct -- a successor with no orientation is the failure the pointer exists to prevent -- and
  # it is what the per-repo scripts did too, since each resolved the handoff under `set -e`.
  # `orphan-canonical` is deliberately skipped: it is the fixture for exactly that refusal.
  mkdir -p "$TMPROOT/fcstate"
  printf 'fixture handoff for %s\n' "$_d" > "$TMPROOT/fcstate/$_d.handoff.md"
  FLEET_STATE="$TMPROOT/fcstate" bash "$TOOL" handoff "$_d" --set "$TMPROOT/fcstate/$_d.handoff.md" >/dev/null 2>&1 || true
done


run() { CANONICAL_ROSTER="$TMPROOT/roster" FLEET_AGENTS_JSON_CMD="cat $TMPROOT/agents.json" \
        FLEET_RECORD="$TMPROOT/rec.yaml" FLEET_ROOT="$TMPROOT" \
        bash "$TOOL" "$@" 2>&1 }

out=$(run status)
[[ "$out" == *"alpha-canonical"*OK* ]]        && ok "single live session reports OK"        || bad "alpha: $out"
[[ "$out" == *"beta-canonical"*DUPLICATE* ]]  && ok "two sessions with one name report DUPLICATE" || bad "beta: $out"
[[ "$out" == *"gamma-canonical"*MISSING* ]]   && ok "rostered but absent reports MISSING"    || bad "gamma: $out"
run status >/dev/null; rc=$?
(( rc == 1 )) && ok "status exits non-zero when the fleet is not healthy" || bad "status exit $rc"

# dedupe must target the OLDER duplicate only, and must never touch a name with one session.
out=$(run dedupe --dry-run)
[[ "$out" == *"90222"* ]] && ok "dedupe targets the older duplicate's pid" || bad "dedupe target: $out"
[[ "$out" != *"90333"* ]] && ok "dedupe spares the newest session"        || bad "dedupe would kill the newest: $out"
[[ "$out" != *"90111"* ]] && ok "dedupe spares an unduplicated session"   || bad "dedupe would kill a lone session: $out"
# Stopping the process is not enough: a TERMed session stays in the `--all` listing as a `done` row,
# so the agents view still has something to click. Reap must name the session ID it will delete.
[[ "$out" == *"id bbb2"* ]] && ok "dedupe names the row id it will delete, not just the pid" \
    || bad "dedupe would stop the process but leave the row: $out"

# `dedupe <name>` scopes to ONE canonical. The load-bearing assertion is the second: asking for a
# name with no duplicate must leave the duplicated name ALONE. A scoping bug that ignored the
# argument would still pass the first assertion, because beta is what unscoped dedupe targets too.
out=$(run dedupe --dry-run beta-canonical)
[[ "$out" == *"90222"* ]] && ok "dedupe <name> targets that canonical's older duplicate" \
    || bad "scoped dedupe missed its target: $out"
out=$(run dedupe --dry-run alpha-canonical)
[[ "$out" != *"90222"* ]] && ok "dedupe <name> leaves every OTHER canonical alone" \
    || bad "scoped dedupe touched a name it was not given: $out"
[[ "$out" == *"0 target(s)"* ]] && ok "dedupe on an already-clean name reports 0 targets" \
    || bad "clean name did not report 0: $out"

# An unknown name must be REFUSED. Reported as "0 target(s)" it is indistinguishable from a clean
# fleet, so a typo would read as a completed dedupe -- the caller cannot tell the two apart.
out=$(run dedupe --dry-run beta-canonicl); rc=$?
(( rc != 0 )) && ok "dedupe refuses a name that is not on the roster" \
    || bad "typo'd name exited 0: $out"
[[ "$out" != *"target(s)"* ]] && ok "a refused name does not report a target count" \
    || bad "refusal looked like a clean run: $out"
[[ "$out" == *"beta-canonical"* ]] && ok "the refusal lists the valid names" || bad "refusal unhelpful: $out"

out=$(run dedupe --dry-run alpha-canonical beta-canonical); rc=$?
(( rc != 0 )) && ok "dedupe refuses two names at once" || bad "two names accepted: $out"

# Unscoped dedupe still walks the whole roster -- the argument is optional, not required.
out=$(run dedupe --dry-run)
[[ "$out" == *"90222"* ]] && ok "dedupe with no name still sweeps the fleet" || bad "regression: $out"

# Discovery with no roster variable: the FLEET RECORD is the manifest.
#
# This replaced a fixture that wrote a `.claude/canonical-kickoff.sh` and asserted the tool found
# it by globbing. That was an EMERGENT manifest -- existence inferred from a file somebody
# remembered to create -- and it had already drifted in production: a declared model tier and a
# running one diverged with nothing surfacing the difference.
recrun() { FLEET_RECORD="$TMPROOT/rec.yaml" FLEET_ROOT="$TMPROOT" \
           FLEET_AGENTS_JSON_CMD="cat $TMPROOT/agents.json" bash "$TOOL" "$@" 2>&1; }

out=$(recrun status)
[[ "$out" == *"delta-canonical"*MISSING* ]] && ok "discovers canonicals from the fleet record" \
    || bad "record discovery: $out"

# `list`: who exists and what each owns, from the record, FLEET-WIDE (not filtered by machine):
# addressing a peer does not depend on where it runs. This is how a session resolves the roster
# when it needs it, instead of carrying a hard-coded copy that drifts.
lout=$(recrun list); rc=$?
[[ $rc == 0 && "$lout" == *alpha-canonical*"the canonical session for alpha"* && "$lout" == *elsewhere-canonical* ]] \
    && ok "list prints every declared canonical with its identity, fleet-wide" \
    || bad "list (rc=$rc): $lout"
lout=$(FLEET_RECORD="$TMPROOT/does-not-exist.yaml" FLEET_ROOT="$TMPROOT" bash "$TOOL" list 2>&1); rc=$?
[[ $rc == 2 && "$lout" == *unreadable* ]] && ok "list fails closed on an unreadable record (exit 2)" \
    || bad "list on a missing record should exit 2 and say unreadable (rc=$rc): $lout"
lout=$(recrun list extra); rc=$?
[[ $rc == 2 ]] && ok "list refuses arguments" || bad "list with an argument should exit 2 (rc=$rc): $lout"

# A deeply nested launch directory. The old fixture guarded a `find -maxdepth` that could silently
# stop discovering a canonical one level too deep; discovery is now by declaration, so depth cannot
# affect it at all. The assertion is kept because "cannot affect it" is a claim about the current
# implementation, and this is what would notice it regaining a depth limit.
[[ "$out" == *"epsilon-canonical"*MISSING* ]] \
    && ok "a deeply nested launch directory is still discovered" \
    || bad "nested canonical not discovered: $out"

# THE ARM THE OLD MECHANISM COULD NOT HAVE: a canonical declared for a DIFFERENT machine is not
# this machine's to run. Globbing had no way to express that, so every host expected every
# canonical -- and a host that legitimately runs none would report them all MISSING, which is
# actionable in the damaging direction because `up` launches whatever is missing.
[[ "$out" != *"elsewhere-canonical"* ]] \
    && ok "a canonical declared for another machine is not expected here" \
    || bad "another machine's canonical leaked into this roster: $out"

# up starts real, long-lived sessions, so it is exercised through --dry-run. Both directions matter:
# it must name what it WOULD start, and must leave an already-running session alone -- an `up` that
# relaunches a live canonical creates the duplicate that dedupe exists to clean up.
out=$(FLEET_ROOT="$TMPROOT" FLEET_RECORD="$TMPROOT/rec.yaml" FLEET_AGENTS_JSON_CMD="cat $TMPROOT/agents.json" bash "$TOOL" up --dry-run 2>&1)
[[ "$out" == *"would start"*"delta-canonical"* ]] && ok "up --dry-run names the missing session it would start" \
    || bad "up dry-run: $out"

# A rostered name with no kickoff script is a real gap on this machine. It must be reported, not
# papered over by synthesizing a launch command -- the script carries the working directory, handoff
# path and prompt, none of which can be guessed.
out=$(CANONICAL_ROSTER="$TMPROOT/roster" FLEET_ROOT="$TMPROOT" \
      FLEET_AGENTS_JSON_CMD="cat $TMPROOT/agents.json" bash "$TOOL" up --dry-run 2>&1)
[[ "$out" == *REFUSED*gamma-canonical* ]] && ok "up refuses loudly for a rostered name that is not declared" \
    || bad "up refusal: $out"
# Asserted against the ROSTER invocation, where alpha and beta are expected AND already running.
# The same assertion against the discovery invocation cannot fail: alpha is not in that expected set
# at all, so its absence from the output says nothing about whether up skips live sessions. Proven
# by planting the removal of the already-running check -- it was caught here and not there.
[[ "$out" != *alpha-canonical* ]] && ok "up leaves an already-running session alone" \
    || bad "up would relaunch a live session: $out"
[[ "$out" != *beta-canonical* ]] && ok "up leaves a duplicated-but-present name alone" \
    || bad "up touched a name that already has sessions: $out"


# --- claude_bin ---------------------------------------------------------------------------------
# REGRESSION GUARD, and the gap it fills is structural rather than an oversight. `claude_bin` was
# CALLED by cmd_dedupe and DEFINED NOWHERE, so dedupe stopped a session's process and then died
# before deleting its row -- half-performing its only job, in the field, for as long as it existed.
#
# Every dedupe test above runs --dry-run, which returns before reaching that call, so none of them
# could ever have caught it. Testing the real path is not the fix: dedupe sends SIGTERM to the pids
# in the fixture, and those are plausible real pids on the host. So the deliberate compromise is to
# assert the helper RESOLVES, which is the exact failure that occurred, without invoking the path
# that signals anything.
bin_default=$(env -u FLEET_CLAUDE_CMD zsh -c 'eval "$(sed -n "/^claude_bin()/p" "$1")"; claude_bin' _ "$TOOL" 2>&1)
[[ "$bin_default" == "claude" ]] && ok "claude_bin resolves to claude by default" \
    || bad "claude_bin default: $bin_default"

# ONE override for the binary. Launches, row deletion, attach and fork all go through claude_bin,
# so a stub set once intercepts every one of them; two variables for one binary let a test stub the
# launch while `rm` still reached the real CLI.
bin_override=$(FLEET_CLAUDE_CMD=/usr/bin/true zsh -c 'eval "$(sed -n "/^claude_bin()/p" "$1")"; claude_bin' _ "$TOOL" 2>&1)
[[ "$bin_override" == "/usr/bin/true" ]] && ok "claude_bin honors FLEET_CLAUDE_CMD" \
    || bad "claude_bin override: $bin_override"

# --- resume-at ----------------------------------------------------------------------------------
# Only the argument handling is asserted. The verb's whole job is to sleep and then launch, and a
# test that waited for a real reset would take hours while one that did not would launch sessions.
out=$(bash "$TOOL" resume-at --at '1970-01-01 00:00:00' --dry-run 2>&1)
[[ "$out" == *"dry run"* ]] && ok "resume-at --dry-run does not sleep or launch" \
    || bad "resume-at dry run: $out"

out=$(bash "$TOOL" resume-at --at 'not-a-time' --dry-run 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"could not parse time"* ]] && ok "resume-at refuses an unparseable time" \
    || bad "resume-at accepted a bad time (rc=$rc): $out"

out=$(bash "$TOOL" resume-at --bogus 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"unknown argument"* ]] && ok "resume-at refuses an unknown argument" \
    || bad "resume-at accepted an unknown argument (rc=$rc): $out"

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


# ---- handoff pointer --------------------------------------------------------
# The property under test is that this NEVER guesses. Every way of not having a usable handoff
# must fail loudly, because the failure it replaces was silent: a kickoff script with a stale
# path baked in still launches and still looks correct while pointing at yesterday's handoff.
HSTATE="$TMPROOT/hstate"
print "hello" > "$TMPROOT/real-handoff.md"
hoff() { FLEET_STATE="$HSTATE" bash "$TOOL" handoff "$@" 2>&1 }

out=$(hoff alpha-canonical); rc=$?
[[ $rc -ne 0 && "$out" == *"no handoff recorded"* ]] \
    && ok "handoff fails loudly when no pointer exists" \
    || bad "handoff with no pointer (rc=$rc): $out"

out=$(hoff alpha-canonical --set "$TMPROOT/absent.md"); rc=$?
[[ $rc -ne 0 && "$out" == *"no such file"* ]] \
    && ok "handoff --set refuses a pointer to a missing file" \
    || bad "handoff --set missing target (rc=$rc): $out"

out=$(hoff alpha-canonical --set "$TMPROOT/real-handoff.md"); rc=$?
[[ $rc -eq 0 && "$out" == "$TMPROOT/real-handoff.md" ]] \
    && ok "handoff --set records an absolute path and echoes it" \
    || bad "handoff --set (rc=$rc): $out"

out=$(hoff alpha-canonical); rc=$?
[[ $rc -eq 0 && "$out" == "$TMPROOT/real-handoff.md" ]] \
    && ok "handoff resolves a recorded pointer" \
    || bad "handoff resolve (rc=$rc): $out"

# The staleness case the whole design exists for: the pointer survives, its target does not.
rm -f "$TMPROOT/real-handoff.md"
out=$(hoff alpha-canonical); rc=$?
[[ $rc -ne 0 && "$out" == *"points at a missing file"* ]] \
    && ok "handoff fails when the pointer names a file that is gone" \
    || bad "handoff dangling pointer (rc=$rc): $out"

mkdir -p "$HSTATE"; print "" > "$HSTATE/beta-canonical.handoff"
out=$(hoff beta-canonical); rc=$?
[[ $rc -ne 0 && "$out" == *"is empty"* ]] \
    && ok "handoff fails on an empty pointer file" \
    || bad "handoff empty pointer (rc=$rc): $out"

out=$(hoff); rc=$?
[[ $rc -ne 0 && "$out" == *"need a canonical name"* ]] \
    && ok "handoff refuses a missing name" \
    || bad "handoff no name (rc=$rc): $out"

# `up` must refuse an unrecognized argument. Regression: the old parser checked only $1, so a
# stray argument silently disabled --dry-run and launched a real canonical. Observed live on
# 2026-08-28 -- `up foo --dry-run` started a live canonical.
# Since `up` gained positional names, a stray word is refused as an unrecognized NAME rather than
# as an unknown argument -- the message changed, the property did not. What must never regress is
# that an unrecognized word is refused rather than silently treated as "no filter", which is how
# `up foo --dry-run` once launched a live canonical.
out=$(FLEET_ROOT="$TMPROOT" FLEET_RECORD="$TMPROOT/rec.yaml" FLEET_AGENTS_JSON_CMD="cat $TMPROOT/agents.json" bash "$TOOL" up foo --dry-run 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"'foo' is not a canonical declared for this machine"* ]] \
    && ok "up refuses an unrecognized name instead of launching" \
    || bad "up with a stray argument (rc=$rc): $out"
[[ "$out" != *"starting"* ]] && ok "up launches nothing when it refuses" \
    || bad "up launched despite a bad argument: $out"

# ---- named up / down ---------------------------------------------------------
# alpha is rostered with a kickoff script and NOT running; beta is running. That asymmetry is what
# makes the name filter falsifiable -- with both running, every up invocation returns "started 0"
# and the filter is untested.
fc() { FLEET_ROOT="$TMPROOT" FLEET_STATE="$TMPROOT/fcstate" FLEET_RECORD="$TMPROOT/rec.yaml" \
       FLEET_AGENTS_JSON_CMD="cat $TMPROOT/agents.json" bash "$TOOL" "$@" 2>&1 }

out=$(fc up delta-canonical --dry-run)
[[ "$out" == *"would start"*"delta-canonical"* ]] && ok "up <name> starts that canonical" \
    || bad "up <name>: $out"
out=$(fc start delta-canonical --dry-run)
[[ "$out" == *"would start"*"delta-canonical"* ]] && ok "start is an alias for up" \
    || bad "start alias: $out"

# The safety property: an unrecognized name must be REFUSED, never fall through to "no filter".
out=$(fc up delta-canonicl --dry-run); rc=$?
[[ $rc -ne 0 && "$out" == *"not a canonical declared for this machine"* ]] \
    && ok "up refuses a misspelled name instead of starting everything" \
    || bad "up with a typo (rc=$rc): $out"
[[ "$out" != *"would start"* ]] && ok "up starts nothing when a name is refused" \
    || bad "up would have started something despite a bad name: $out"

# down
out=$(fc down); rc=$?
[[ $rc -ne 0 && "$out" == *"need a canonical name"* ]] \
    && ok "down refuses with no name (never closes the fleet by accident)" \
    || bad "bare down (rc=$rc): $out"

out=$(fc down alpha-canonical --all --dry-run); rc=$?
[[ $rc -ne 0 ]] && ok "down refuses names and --all together" || bad "down names+--all (rc=$rc): $out"

mkdir -p "$TMPROOT/fcstate"
print "$TMPROOT/real-handoff-alpha.md" >  "$TMPROOT/fcstate/alpha-canonical.handoff"
print "# set-at $(date +%s)"           >> "$TMPROOT/fcstate/alpha-canonical.handoff"
print "orientation" > "$TMPROOT/real-handoff-alpha.md"
out=$(fc down alpha-canonical --dry-run)
[[ "$out" == *"would stop"*"alpha-canonical"* ]] && ok "down <name> targets that session" \
    || bad "down <name>: $out"

out=$(fc down nosuch-canonical --dry-run)
[[ "$out" == *"not running"* ]] && ok "down reports a name that is not running rather than passing silently" \
    || bad "down of an absent name: $out"
out=$(fc stop alpha-canonical --dry-run 2>&1)
[[ "$out" == *"would stop"*"alpha-canonical"* ]] \
    && ok "stop is an alias for down" \
    || bad "stop alias: $out"

# Must never signal the session it runs in -- a self-kill mid-run is indistinguishable from a crash.
# The env-var path is only one of two: CLAUDE_SESSION_ID is NOT exported into the shell a session
# runs its own commands in, so on the real path the guard resolves the session by walking process
# ancestry instead. Both are asserted, because the env path passing told us nothing about the path
# that actually runs -- that gap left the guard inert in dedupe for its whole life.
# $$ here is the TEST shell, which is an ancestor of the tool process spawned below -- so a fixture
# naming it is exactly the real shape: a listed session that is an ancestor, and no env var.
print "[{\"pid\":$$,\"id\":\"self\",\"name\":\"self-canonical\",\"sessionId\":\"sx\",\"startedAt\":1}]" \
  > "$TMPROOT/self.json"
# --dry-run is MANDATORY here, not caution: the self-protection check runs before the close either
# way, so dry-run still exercises it -- but without it, a REGRESSION makes this test TERM the test
# shell's own pid and the suite dies silently, printing neither a failure nor a pass. That happened
# while writing this: the red run produced no output at all and read as "no failure".
out=$(FLEET_AGENTS_JSON_CMD="cat $TMPROOT/self.json" bash "$TOOL" down self-canonical --dry-run 2>&1)
[[ "$out" == *"is this session"* ]] \
    && ok "down identifies its own session by process ancestry, with no CLAUDE_SESSION_ID" \
    || bad "ancestry-based self-protection did not fire: $out"

out=$(CLAUDE_SESSION_ID=s1 fc down alpha-canonical)
[[ "$out" == *"is this session"* && "$out" == *"0 target"* ]] \
    && ok "down skips the session it is running inside" \
    || bad "down did not protect itself: $out"
# --all resolves through expected_names, so alpha must be rostered for this to reach it.
out=$(CLAUDE_SESSION_ID=s1 CANONICAL_ROSTER="$TMPROOT/roster" fc down --all)
[[ "$out" == *"is this session"* ]] && ok "down --all also skips the running session" \
    || bad "down --all did not protect itself: $out"


# ---- handoff freshness gate + refresh ----------------------------------------
# The gate's property is a COMPARISON, not an age: a handoff recorded BEFORE the session it would
# replace cannot describe that session's work, however recent it is in absolute terms. So every
# fixture below fixes both clocks explicitly rather than relying on wall time.

GSTATE="$TMPROOT/gstate"
NOW=$(date +%s)
# zeta is the only fixture that is BOTH running and has a kickoff script -- refresh needs both, and
# splitting them across two names is what makes each refusal falsifiable on its own.
mkdir -p "$TMPROOT/zeta/.claude"
cat > "$TMPROOT/zeta/.claude/canonical-kickoff.sh" <<'SH'
#!/usr/bin/env bash
cd /somewhere
exec claude --bg -n zeta-canonical --model opus "You are zeta-canonical."
SH
# startedAt in MILLISECONDS, an hour ago -- the units matter, see the to_secs test below.
print "[{\"pid\":90444,\"id\":\"ddd4\",\"name\":\"zeta-canonical\",\"sessionId\":\"sz\",\"startedAt\":$(( (NOW - 3600) * 1000 ))}]" \
  > "$TMPROOT/zeta.json"

zfc() { FLEET_ROOT="$TMPROOT" FLEET_STATE="$GSTATE" \
        FLEET_AGENTS_JSON_CMD="cat $TMPROOT/zeta.json" bash "$TOOL" "$@" 2>&1 }

print "orientation" > "$TMPROOT/zeta-handoff.md"
set_ptr() {  # set_ptr <epoch> -- record a pointer stamped at an arbitrary time
  mkdir -p "$GSTATE"
  print "$TMPROOT/zeta-handoff.md" >  "$GSTATE/zeta-canonical.handoff"
  print "# set-at $1"              >> "$GSTATE/zeta-canonical.handoff"
}

# --- pre-flight: never stop what cannot be started ---
# Asserted on a name that IS running but has no kickoff script. On a name that is merely absent the
# not-running check would fire first, and this assertion would pass without the pre-flight existing.
print "[{\"pid\":90555,\"id\":\"eee5\",\"name\":\"orphan-canonical\",\"sessionId\":\"so\",\"startedAt\":$(( NOW * 1000 ))}]" \
  > "$TMPROOT/orphan.json"
out=$(FLEET_ROOT="$TMPROOT" FLEET_STATE="$GSTATE" \
      FLEET_AGENTS_JSON_CMD="cat $TMPROOT/orphan.json" bash "$TOOL" refresh orphan-canonical --dry-run 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"not a canonical declared for this machine"* && "$out" == *"no way to start again"* ]] \
    && ok "refresh pre-flights the declaration and refuses to stop what it cannot restart" \
    || bad "refresh pre-flight (rc=$rc): $out"
[[ "$out" != *"would refresh"* ]] && ok "refresh stops nothing when the pre-flight refuses" \
    || bad "refresh would have stopped a session it cannot restart: $out"

# --- a name that is NOT running is LAUNCHED, not refused -- but the gate still runs ---
# This pair replaces the old "refresh refuses a stopped name" assertion. That refusal sent the
# operator to `up`, which has no handoff gate at all, so the refusal made the path WEAKER. The two
# assertions have to be read together: the first alone would pass on an implementation that simply
# deleted the branch and called `up`, and that is precisely the regression worth catching.
out=$(zfc refresh delta-canonical --dry-run); rc=$?
[[ $rc -ne 0 && "$out" == *"no handoff is recorded"* ]] \
    && ok "refresh of a NOT-RUNNING name still runs the handoff gate (no handoff -> refused)" \
    || bad "not-running refresh skipped the gate (rc=$rc): $out"

# theta is not running, HAS a kickoff script, and HAS a handoff recorded. It must launch.
mkdir -p "$TMPROOT/theta/.claude"
cat > "$TMPROOT/theta/.claude/canonical-kickoff.sh" <<'SH'
#!/usr/bin/env bash
exec claude --bg -n theta-canonical --model opus "You are theta-canonical."
SH
print '[]' > "$TMPROOT/empty.json"
mkdir -p "$GSTATE"
print "$TMPROOT/zeta-handoff.md"  >  "$GSTATE/theta-canonical.handoff"
print "# set-at $NOW"             >> "$GSTATE/theta-canonical.handoff"
out=$(FLEET_ROOT="$TMPROOT" FLEET_STATE="$GSTATE" \
      FLEET_AGENTS_JSON_CMD="cat $TMPROOT/empty.json" bash "$TOOL" refresh theta-canonical --dry-run 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"not running"* && "$out" == *"would start"*"theta-canonical"* ]] \
    && ok "refresh launches a not-running name instead of making the operator retype it as 'up'" \
    || bad "not-running refresh did not launch (rc=$rc): $out"
[[ "$out" != *"would refresh"* ]] \
    && ok "refresh of a not-running name stops nothing (there is nothing to stop)" \
    || bad "refresh claimed to stop a session that was not running: $out"

# --- a pointer whose handoff file is GONE is refused before anything is stopped or started ---
# The pointer read used to return its target unchecked, so a launch composed "Read <missing file>
# first" and the successor started with no orientation and no error. Refused at the gate, which
# runs before refresh's stop half, and in `up`, which has no gate, on a dry run as well.
print "$TMPROOT/theta-gone.md" >  "$GSTATE/theta-canonical.handoff"
print "# set-at $NOW"          >> "$GSTATE/theta-canonical.handoff"
out=$(FLEET_ROOT="$TMPROOT" FLEET_STATE="$GSTATE" \
      FLEET_AGENTS_JSON_CMD="cat $TMPROOT/empty.json" bash "$TOOL" refresh theta-canonical --dry-run 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"missing file"*"theta-gone.md"* && "$out" != *"would start"* ]] \
    && ok "refresh refuses a pointer whose handoff file is missing" \
    || bad "refresh accepted a missing handoff (rc=$rc): $out"
out=$(FLEET_ROOT="$TMPROOT" FLEET_STATE="$GSTATE" \
      FLEET_AGENTS_JSON_CMD="cat $TMPROOT/empty.json" bash "$TOOL" refresh theta-canonical --force why --dry-run 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"missing file"* && "$out" != *"would start"* ]] \
    && ok "--force does not carry a missing handoff through" \
    || bad "--force launched with a missing handoff (rc=$rc): $out"
out=$(FLEET_ROOT="$TMPROOT" FLEET_STATE="$GSTATE" \
      FLEET_AGENTS_JSON_CMD="cat $TMPROOT/empty.json" bash "$TOOL" up theta-canonical --dry-run 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"REFUSED"*"theta-canonical"*"missing file"* && "$out" != *"would start"* ]] \
    && ok "up --dry-run refuses a missing handoff rather than rehearsing a blind launch" \
    || bad "up rehearsed a launch with a missing handoff (rc=$rc): $out"
rm -f "$GSTATE/theta-canonical.handoff"
out=$(FLEET_ROOT="$TMPROOT" FLEET_STATE="$GSTATE" \
      FLEET_AGENTS_JSON_CMD="cat $TMPROOT/empty.json" bash "$TOOL" up theta-canonical --dry-run 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"REFUSED"*"theta-canonical"*"no handoff recorded"* ]] \
    && ok "up --dry-run refuses a name with no pointer at all" \
    || bad "up rehearsed a launch with no pointer (rc=$rc): $out"
print "$TMPROOT/zeta-handoff.md"  >  "$GSTATE/theta-canonical.handoff"
print "# set-at $NOW"             >> "$GSTATE/theta-canonical.handoff"

out=$(zfc refresh); rc=$?
[[ $rc -ne 0 && "$out" == *"need a canonical name"* ]] \
    && ok "refresh refuses with no name" || bad "bare refresh (rc=$rc): $out"

out=$(zfc refresh zeta-canonical eta-canonical --dry-run); rc=$?
[[ $rc -ne 0 && "$out" == *"one name at a time"* ]] \
    && ok "refresh refuses two names rather than half-refreshing a fleet" \
    || bad "refresh with two names (rc=$rc): $out"

# --- self-refresh stays refused, and the escape hatch stays REMOVED ---
# A temporary --force-self flag existed on 2026-08-29 purely to measure whether the refusal was
# protecting against anything. It was: the verb dies at the stop (it is a descendant of what it
# kills), the relaunch never runs, and the harness respawns the killed worker with --resume -- so
# the same session returns, startedAt rewritten, reporting OK, having refreshed nothing. The flag
# was removed once measured. This asserts it did not creep back, because the next person to want it
# will have the same idea and no longer has the same excuse.
out=$(zfc refresh zeta-canonical --dry-run --force-self); rc=$?
[[ $rc -ne 0 && "$out" == *"unknown option"* ]] \
    && ok "--force-self is gone: the self-refusal has no escape hatch" \
    || bad "--force-self is accepted again (rc=$rc): $out"

# The refusal must still explain itself with the measured consequence rather than a bare no.
print "[{\"pid\":$$,\"id\":\"self1\",\"name\":\"zeta-canonical\",\"sessionId\":\"ss\",\"startedAt\":$(( (NOW - 3600) * 1000 ))}]" \
  > "$TMPROOT/self.json"
sfc() { FLEET_ROOT="$TMPROOT" FLEET_STATE="$GSTATE" \
        FLEET_AGENTS_JSON_CMD="cat $TMPROOT/self.json" bash "$TOOL" "$@" 2>&1 }
set_ptr "$NOW"
out=$(sfc refresh zeta-canonical --dry-run); rc=$?
[[ $rc -ne 0 && "$out" == *"MEASURED"* && "$out" == *"reports OK"* ]] \
    && ok "the self-refusal cites what was measured, not just a refusal" \
    || bad "self-refusal lost its evidence (rc=$rc): $out"

# --- the gate itself ---
rm -rf "$GSTATE"
out=$(zfc refresh zeta-canonical --dry-run); rc=$?
[[ $rc -ne 0 && "$out" == *"no handoff is recorded"* ]] \
    && ok "gate refuses when no handoff is recorded at all" || bad "gate no-handoff (rc=$rc): $out"
[[ "$out" == *"--stub"* ]] && ok "gate names the stub escape hatch in its refusal" \
    || bad "gate refusal does not say how to satisfy it: $out"
[[ "$out" != *"would refresh"* ]] && ok "gate refusal stops nothing" || bad "gate refused but still stopped: $out"

# The case the gate exists for: a pointer that resolves PERFECTLY, to a handoff describing an
# earlier sitting. Nothing else in the tool can see this -- `handoff` itself reports it as healthy.
set_ptr $(( NOW - 7200 ))
out=$(zfc handoff zeta-canonical); rc=$?
[[ $rc -eq 0 ]] && ok "a stale pointer still RESOLVES -- which is why the gate is needed" \
    || bad "fixture wrong, pointer does not resolve: $out"
out=$(zfc refresh zeta-canonical --dry-run); rc=$?
[[ $rc -ne 0 && "$out" == *"PREDATES"* ]] \
    && ok "gate refuses a handoff recorded before the session it would replace" \
    || bad "gate staleness (rc=$rc): $out"

# ...and the other direction, or the gate is just "always refuse".
set_ptr $(( NOW - 60 ))
out=$(zfc refresh zeta-canonical --dry-run); rc=$?
[[ $rc -eq 0 && "$out" == *"would refresh"*"zeta-canonical"* ]] \
    && ok "gate passes a handoff recorded after the session started" || bad "gate pass (rc=$rc): $out"
[[ "$out" == *"would start"*"zeta-canonical"* ]] \
    && ok "refresh --dry-run names both halves: what it would stop and what it would start" \
    || bad "refresh dry-run does not name the start half: $out"
[[ "$out" == *"recorded"*"ago)"* ]] && ok "refresh prints the handoff age it will resume from" \
    || bad "refresh does not report the handoff age: $out"

# UNITS. startedAt is milliseconds, set-at is seconds. Comparing them unconverted makes every
# handoff look ~1000x older than its session, so the gate refuses unconditionally -- which reads as
# "the gate works" on every refusal test above and is caught only by this pass case. Watched red by
# stubbing to_secs to `printf '%s\n' "$1"`: the pass assertion above fails, the refusals do not.
[[ "$out" != *"PREDATES"* ]] && ok "gate converts startedAt ms to seconds before comparing" \
    || bad "gate compared ms against s and refused a fresh handoff: $out"

# --- --stub ---
rm -rf "$GSTATE"
out=$(zfc refresh zeta-canonical --stub 'nothing in flight' --dry-run); rc=$?
[[ $rc -eq 0 && "$out" == *"stub written and recorded"* ]] \
    && ok "--stub satisfies the gate with no prior handoff" || bad "--stub (rc=$rc): $out"
stub=$(print -l "$GSTATE"/stub-handoffs/*-zeta-canonical-stub.md(N) | head -1)
[[ -n "$stub" && -s "$stub" ]] && ok "--stub writes a real, non-empty handoff file" \
    || bad "--stub wrote no file"
[[ "$(<$stub)" == *"nothing in flight"* ]] && ok "--stub records the reason it was given" \
    || bad "--stub dropped the reason: $(<$stub)"
[[ "$(<$stub)" == *"no orientation to inherit"* ]] \
    && ok "--stub tells the successor outright that there is nothing to inherit" \
    || bad "--stub body does not say there is nothing to inherit"
# The point of stub-over-bypass: the pointer now names the stub, so the NEXT run is satisfied by a
# real artifact rather than by a flag having been passed once.
[[ "$(zfc handoff zeta-canonical)" == "$stub" ]] \
    && ok "--stub repoints the handoff pointer at the stub it wrote" \
    || bad "--stub did not record the pointer"

# --- set-at stamping and backward compatibility ---
rm -rf "$GSTATE"
zfc handoff zeta-canonical --set "$TMPROOT/zeta-handoff.md" >/dev/null
[[ "$(<$GSTATE/zeta-canonical.handoff)" == *"# set-at "* ]] \
    && ok "handoff --set stamps when it was recorded" || bad "no set-at stamp written"
[[ "$(zfc handoff zeta-canonical)" == "$TMPROOT/zeta-handoff.md" ]] \
    && ok "the stamp does not break pointer resolution (reader strips #-comments)" \
    || bad "stamp broke resolution: $(zfc handoff zeta-canonical)"

# A pointer written before stamping existed must still work -- there are live ones on this fleet.
mkdir -p "$GSTATE"; print "$TMPROOT/zeta-handoff.md" > "$GSTATE/zeta-canonical.handoff"
touch -d "@$(( NOW - 60 ))" "$GSTATE/zeta-canonical.handoff"
out=$(zfc refresh zeta-canonical --dry-run); rc=$?
[[ $rc -eq 0 ]] && ok "an unstamped legacy pointer falls back to file mtime rather than failing" \
    || bad "legacy pointer rejected (rc=$rc): $out"

# --- gate scope on down: holder yes, --all no, superseded no ---
sfc() { FLEET_STATE="$GSTATE" CANONICAL_ROSTER="$TMPROOT/roster" \
        FLEET_AGENTS_JSON_CMD="cat $TMPROOT/agents.json" bash "$TOOL" "$@" 2>&1 }
rm -rf "$GSTATE"
out=$(sfc down alpha-canonical --dry-run); rc=$?
[[ $rc -ne 0 && "$out" == *"no handoff is recorded"* ]] \
    && ok "down <name> gates the session that holds the name" || bad "down gate (rc=$rc): $out"
[[ "$out" != *"would stop"* ]] && ok "down closes nothing when the gate refuses" \
    || bad "down closed despite the gate: $out"

# --all is the ramp-down path: no successor is coming, so there is nothing to hand over to. If this
# ever starts gating, the fleet's ramp-down wedges.
out=$(sfc down --all --dry-run); rc=$?
[[ $rc -eq 0 && "$out" != *"no handoff is recorded"* ]] \
    && ok "down --all is exempt from the gate (ramp-down, not a handover)" \
    || bad "down --all was gated (rc=$rc): $out"

# beta has two rows; the OLDER one is a superseded duplicate that was already replaced. Demanding a
# handoff from it would wedge the takeover path. Only the holder is gated -- and beta's holder is
# pid 90333, so the gate fires for beta while pid 90222 would have been closable regardless.
out=$(sfc dedupe --dry-run); rc=$?
[[ $rc -eq 0 && "$out" == *"90222"* ]] \
    && ok "dedupe is exempt from the gate (it closes rows that were already superseded)" \
    || bad "dedupe was gated (rc=$rc): $out"

# --- self-refusal ---
# Same shape as the stop self-protection test above: $$ is the test shell, an ancestor of the tool
# process, and no CLAUDE_SESSION_ID is set -- so this exercises the ancestry path that actually runs.
mkdir -p "$TMPROOT/selfproj/.claude"
cat > "$TMPROOT/selfproj/.claude/canonical-kickoff.sh" <<'SH'
#!/usr/bin/env bash
cd /somewhere
exec claude --bg -n self2-canonical --model opus "You are self2-canonical."
SH
print "[{\"pid\":$$,\"id\":\"self2\",\"name\":\"self2-canonical\",\"sessionId\":\"sy\",\"startedAt\":$(( NOW * 1000 ))}]" \
  > "$TMPROOT/self2.json"
# --dry-run is mandatory for the same reason as the stop self-test: if the refusal regresses, the
# tool would TERM the test shell and the suite would die printing neither a pass nor a failure.
out=$(FLEET_ROOT="$TMPROOT" FLEET_STATE="$GSTATE" \
      FLEET_AGENTS_JSON_CMD="cat $TMPROOT/self2.json" bash "$TOOL" refresh self2-canonical --dry-run 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"is the session this is running inside"* ]] \
    && ok "refresh refuses to refresh the session it runs inside" \
    || bad "refresh self-refusal did not fire (rc=$rc): $out"
[[ "$out" != *"would refresh"* ]] && ok "refresh stops nothing when it refuses itself" \
    || bad "refresh would have killed its own session: $out"
# It must refuse BEFORE the gate, or the message names the wrong problem entirely.
[[ "$out" != *"no handoff is recorded"* ]] \
    && ok "self-refusal precedes the handoff gate, so the error names the real problem" \
    || bad "self-refresh reported a handoff problem instead of the self problem: $out"


# ---- portability helpers -----------------------------------------------------
# REGRESSION GUARD for a class a Linux-only run structurally cannot see. `stat -c` and `date -d` are
# GNU spellings that ERROR on BSD/darwin rather than degrading, so they do not print something
# slightly wrong -- they print nothing and the caller silently loses a value. That is exactly how the
# handoff gate's mtime fallback came to refuse every unstamped pointer on a macOS machine while
# every assertion in this file passed on the workstation.
#
# So these RUN the helpers on whatever platform the suite is on, rather than asserting a spelling.
# A test that grepped for `stat -f` would pass on Linux without proving anything works there.
sed -n '/^file_mtime()/p;/^fmt_epoch()/p' "$TOOL" > "$TMPROOT/helpers.sh"
sed -n '/^parse_time()/,/^}/p'                 "$TOOL" >> "$TMPROOT/helpers.sh"

mt=$(bash -c ". '$TMPROOT/helpers.sh'; file_mtime '$TOOL'" 2>&1)
[[ "$mt" == <-> ]] && ok "file_mtime returns an epoch on this platform (GNU or BSD stat)" \
    || bad "file_mtime did not resolve an mtime here: $mt"

fe=$(bash -c ". '$TMPROOT/helpers.sh'; fmt_epoch 1756000000 '%Y-%m-%d'" 2>&1)
[[ "$fe" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ]] \
    && ok "fmt_epoch formats an epoch on this platform (GNU or BSD date)" \
    || bad "fmt_epoch did not format here: $fe"

# parse_time is the one helper whose two branches are NOT equivalent -- GNU takes free-form input,
# BSD needs an explicit format and so accepts a narrower language. Both directions are asserted on
# whatever platform this is: a real time must parse, and junk must still be refused, because a
# greedy BSD format tried too early would accept junk and return a plausible-looking instant.
pt=$(bash -c ". '$TMPROOT/helpers.sh'; parse_time '2026-08-28 14:30'" 2>&1)
[[ "$pt" == <-> ]] && ok "parse_time parses a date-time on this platform (GNU or BSD date)" \
    || bad "parse_time did not parse a real time here: $pt"

pt=$(bash -c ". '$TMPROOT/helpers.sh'; parse_time 'not-a-time'" 2>&1); rc=$?
[[ $rc -ne 0 && -z "$pt" ]] && ok "parse_time still refuses junk on this platform" \
    || bad "parse_time accepted junk (rc=$rc): $pt"


# --- up: stdin isolation ------------------------------------------------------------------------
# PLACED LAST DELIBERATELY: it plants kickoff scripts under FLEET_ROOT, so running it earlier would
# add one-, two- and three-canonical to discovery for every test after it.
#
# `up` launches from inside `while IFS= read -r name; do ... done < <(expected_names)`, so the loop
# body's stdin IS the remaining names stream. `claude` reads stdin when it is not a tty and appends
# it to its prompt argument -- verified 2026-08-29 with markers: `printf 'B' | claude --print 'A'`
# records the user message as "A\nB". Two things follow, and the second is the reason this is a
# defect rather than a cosmetic blemish:
#
#   (a) The new session starts with the leftover roster names appended to its kickoff prompt.
#       Observed on three consecutive sessions of one canonical, each carrying the stray name of
#       the one roster entry sorting after it.
#   (b) The read DRAINS the stream, so the loop hits EOF and every canonical after the one just
#       launched is never started -- while `up` still prints a success count. A fleet that comes up
#       short, reported as a fleet that came up.
#
# The stand-in below reads stdin exactly as `claude` does, reproducing both effects without
# starting a real session. Watched failing before the fix: one.stdin held "three-canonical
# two-canonical", two of three were never started, and `up` reported "started 1".
LEAK="$TMPROOT/leak"
# THE STDIN-DRAIN REGRESSION, re-expressed for a record-driven launcher.
#
# The property is unchanged and is the reason this case exists: `up` loops over a names STREAM, so
# a launched session that inherits stdin gets the REMAINING names -- Claude Code appends piped
# stdin to its prompt argument, so a canonical starts with leftover roster names glued onto its
# first message, AND the read drains the stream so every canonical after it is silently never
# started while `up` still reports success. Observed 2026-08-29.
#
# What changed is only how the fixture intercepts a launch. It used to write a fake kickoff script
# per repo, which doubled as the injection point; the launch is now composed by the tool, so the
# interception moves to the launcher stub -- which is strictly more informative, because the stub
# sees the model tier and prompt the old fake script could never report.
mkdir -p "$LEAK/st"
cat > "$LEAK/rec.yaml" <<YAML
projects:
YAML
for n in one two three; do
  mkdir -p "$LEAK/$n"
  cat >> "$LEAK/rec.yaml" <<YAML
  $n:
    scope: $n
    canonical: $n-canonical
    canonicalIdentity: "the canonical session for $n"
    canonicalLaunchDir: $n
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
YAML
  printf 'handoff for %s\n' "$n" > "$LEAK/st/$n.md"
  FLEET_STATE="$LEAK/st" bash "$TOOL" handoff "$n-canonical" --set "$LEAK/st/$n.md" >/dev/null
done
# The stub records, per launched name, exactly what stdin it was handed and that it ran at all.
cat > "$LEAK/stub" <<'STUB'
#!/bin/sh
name=""
while [ $# -gt 0 ]; do case "$1" in -n) name=$2; shift 2 ;; *) shift ;; esac; done
cat > "$LEAKDIR/$name.stdin"
: > "$LEAKDIR/$name.started"
STUB
chmod +x "$LEAK/stub"
print '[]' > "$LEAK/agents.json"
out=$(FLEET_ROOT="$LEAK" FLEET_RECORD="$LEAK/rec.yaml" FLEET_STATE="$LEAK/st" \
      FLEET_CLAUDE_CMD="$LEAK/stub" LEAKDIR="$LEAK" \
      FLEET_AGENTS_JSON_CMD="cat $LEAK/agents.json" bash "$TOOL" up 2>&1)

leaked=$(cat "$LEAK"/*.stdin 2>/dev/null)
[[ -z "$leaked" ]] && ok "up hands a launched session no stdin to swallow into its prompt" \
    || bad "up leaked roster names into a launched session's stdin: ${leaked//$'\n'/ }"

missing=""
for n in one two three; do [[ -e "$LEAK/$n-canonical.started" ]] || missing="$missing $n"; done
[[ -z "$missing" ]] && ok "up starts every missing canonical, not just the first" \
    || bad "up never started:$missing (stream drained by an earlier launch?) -- $out"

[[ "$out" == *"started 3"* ]] && ok "up's reported count matches what it actually started" \
    || bad "up count disagrees with the launches it performed: $out"

# NEW, and only possible now that the launch is composed rather than delegated: the stub saw the
# whole command line, so the DECLARED model tier and the composed identity sentence are assertable.
# While each repo carried its own script neither was visible to any test, which is how a declared
# tier and a running one diverged in production with nothing surfacing it.
firstline=$(head -n1 "$LEAK/one-canonical.stdin" 2>/dev/null; true)
out2=$(FLEET_ROOT="$LEAK" FLEET_RECORD="$LEAK/rec.yaml" FLEET_STATE="$LEAK/st" \
       FLEET_CLAUDE_CMD="$LEAK/argstub" LEAKDIR="$LEAK" \
       FLEET_AGENTS_JSON_CMD="cat $LEAK/agents.json" bash "$TOOL" up 2>&1)
cat > "$LEAK/argstub" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LEAKDIR/args.log"
STUB
chmod +x "$LEAK/argstub"
: > "$LEAK/args.log"
FLEET_ROOT="$LEAK" FLEET_RECORD="$LEAK/rec.yaml" FLEET_STATE="$LEAK/st" \
  FLEET_CLAUDE_CMD="$LEAK/argstub" LEAKDIR="$LEAK" \
  FLEET_AGENTS_JSON_CMD="cat $LEAK/agents.json" bash "$TOOL" up >/dev/null 2>&1
args=$(cat "$LEAK/args.log" 2>/dev/null)
[[ "$args" == *"--model fable"* ]] \
    && ok "the launch carries the DECLARED model tier" \
    || bad "declared tier absent from the composed launch: $args"
[[ "$args" == *"This session is one-canonical, the canonical session for one. "* ]] \
    && ok "the identity sentence is composed from the declared role" \
    || bad "composed identity sentence wrong: $args"
# The prompt DESCRIBES the session and treats the handoff as a record of work, never as a source of
# commands: a persona line ("You are ...") followed by "read <file> and follow it" is the shape a
# cautious safety filter refuses as an injection, and a work machine's did (2026-11-04).
[[ "$args" == *"The previous session's handoff is at $LEAK/"*": read it first and resume the work it describes. Reply with one line confirming you have resumed, then begin."* ]] \
    && ok "the launch prompt names the handoff as the previous session's record of work" \
    || bad "launch prompt wording wrong: $args"
[[ "$args" != *"You are "* && "$args" != *"follow it"* ]] \
    && ok "the launch prompt carries no persona line and no follow-the-file instruction" \
    || bad "launch prompt still carries the old persona or follow-it wording: $args"

# ---- the handoff a launch may name: inside the handoffs trees, and committed where it is in git ---
# A launch hands its successor one file as the work to resume, so that file must be a handoff the
# fleet's own tooling put there: in the staging directory or a configured handoffs tree, reached
# without a symlink or a `..` out of it, and, where it sits in a git repository, committed with no
# change since, so what is read is what passed that repository's commit gates. A staged copy, which
# nothing has committed yet, gets the location check alone: requiring a commit would stall every
# relaunch on the hub placing it first.
HP="$LEAK/prov"; mkdir -p "$HP/st/handoff-staging" "$HP/one" "$HP/tree/handoffs" "$HP/elsewhere" "$HP/tmproots"
cat > "$HP/rec.yaml" <<YAML
projects:
  one:
    scope: one
    canonical: one-canonical
    canonicalIdentity: "the canonical session for one"
    canonicalLaunchDir: one
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
YAML
# The fixture repository must not run this machine's hooks or sign with its key.
pgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$HP/tree" -c user.name=t \
           -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@" >/dev/null 2>&1 }
# plaunch FILE [noconf] -- record FILE as one-canonical's handoff, run `up`, print "launched" or what
# it said instead. With noconf, no handoffs directory is configured, as on a machine without one.
plaunch() {
  local dir="$HP/tree/handoffs" search="$HP/tree"
  [[ "${2:-}" == noconf ]] && { dir=""; search=""; }
  FLEET_STATE="$HP/st" bash "$TOOL" handoff one-canonical --set "$1" >/dev/null 2>&1
  : > "$HP/args.log"
  pout=$(FLEET_ROOT="$HP" FLEET_RECORD="$HP/rec.yaml" FLEET_STATE="$HP/st" \
    FLEET_HANDOFFS_DIR="$dir" FLEET_HANDOFFS_SEARCH="$search" FLEET_TMPROOT_PREFIX="$HP/tmproots" \
    FLEET_CLAUDE_CMD="$LEAK/argstub" LEAKDIR="$HP" \
    FLEET_AGENTS_JSON_CMD="cat $LEAK/agents.json" bash "$TOOL" up 2>&1)
  [[ -s "$HP/args.log" ]] && print launched || print -r -- "$pout"
}
print staged > "$HP/st/handoff-staging/one-staged.md"
print stray > "$HP/elsewhere/notes.md"
ln -s "$HP/elsewhere/notes.md" "$HP/st/handoff-staging/one-link.md"

r=$(plaunch "$HP/st/handoff-staging/one-staged.md")
[[ "$r" == launched ]] && ok "a staged handoff launches (location check only)" || bad "staged handoff refused: $r"
mkdir -p "$HP/st/stub-handoffs"; print stub > "$HP/st/stub-handoffs/one-stub.md"
r=$(plaunch "$HP/st/stub-handoffs/one-stub.md")
[[ "$r" == launched ]] && ok "a stub handoff written by --stub launches" || bad "stub handoff refused: $r"
r=$(plaunch "$HP/st/handoff-staging/one-staged.md" noconf)
[[ "$r" == launched ]] && ok "a staged handoff launches where no handoffs directory is configured" \
    || bad "staged handoff refused with no handoffs directory configured: $r"
r=$(plaunch "$HP/elsewhere/notes.md")
[[ "$r" != launched && "$r" == *"outside the handoff directories"* ]] \
    && ok "a handoff outside the staging and handoffs trees is refused" || bad "outside handoff: $r"
r=$(plaunch "$HP/st/handoff-staging/../../elsewhere/notes.md")
[[ "$r" != launched && "$r" == *"outside the handoff directories"* ]] \
    && ok "a path that climbs out of staging with .. is refused" || bad ".. escape: $r"
r=$(plaunch "$HP/st/handoff-staging/one-link.md")
[[ "$r" != launched && "$r" == *"symbolic link"* ]] \
    && ok "a symlink in staging is refused, wherever it points" || bad "symlinked handoff: $r"
print placed > "$HP/tree/handoffs/one-placed.md"
r=$(plaunch "$HP/tree/handoffs/one-placed.md" noconf)
[[ "$r" != launched && "$r" == *"outside the handoff directories"* ]] \
    && ok "with no handoffs directory configured, a file in an unconfigured tree is refused" \
    || bad "unconfigured tree accepted: $r"
r=$(plaunch "$HP/tree/handoffs/one-placed.md")
[[ "$r" == launched ]] && ok "a placed handoff outside any git repository launches" || bad "placed, no git: $r"

pgit init -q
r=$(plaunch "$HP/tree/handoffs/one-placed.md")
[[ "$r" != launched && "$r" == *"not committed"* ]] \
    && ok "a placed handoff in a git repository but never committed is refused" || bad "untracked handoff: $r"
pgit add handoffs/one-placed.md
r=$(plaunch "$HP/tree/handoffs/one-placed.md")
[[ "$r" != launched && "$r" == *"not committed"* ]] \
    && ok "a placed handoff staged in git but not committed is refused" || bad "added, uncommitted handoff: $r"
pgit commit -q -m placed
r=$(plaunch "$HP/tree/handoffs/one-placed.md")
[[ "$r" == launched ]] && ok "a committed handoff launches" || bad "committed handoff refused: $r"
print "edited after the commit" >> "$HP/tree/handoffs/one-placed.md"
r=$(plaunch "$HP/tree/handoffs/one-placed.md")
[[ "$r" != launched && "$r" == *"changed since its last commit"* ]] \
    && ok "a committed handoff edited since its commit is refused" || bad "edited handoff: $r"

# --- every launch gets its own temp root, recorded AND passed to the launch via --settings -----
# FLEET_TMPROOT_PREFIX is redirected under $LEAK rather than the real /tmp: this is what lets the
# assertions below check the REAL mkdir + record-write side effects (not just the composed
# argument string) without a production launch's /tmp ever being touched by this suite.
: > "$LEAK/args.log"
LEAKTMPROOTS="$LEAK/tmproots"; rm -rf "$LEAKTMPROOTS"; mkdir -p "$LEAKTMPROOTS"
FLEET_ROOT="$LEAK" FLEET_RECORD="$LEAK/rec.yaml" FLEET_STATE="$LEAK/st" \
  FLEET_CLAUDE_CMD="$LEAK/argstub" LEAKDIR="$LEAK" FLEET_TMPROOT_PREFIX="$LEAKTMPROOTS" \
  FLEET_AGENTS_JSON_CMD="cat $LEAK/agents.json" bash "$TOOL" up >/dev/null 2>&1
args=$(cat "$LEAK/args.log" 2>/dev/null)
[[ "$args" == *"--settings"*"CLAUDE_CODE_TMPDIR"* ]] \
    && ok "up's launch carries --settings with a CLAUDE_CODE_TMPDIR env override" \
    || bad "no --settings/CLAUDE_CODE_TMPDIR in the composed launch: $args"

[[ -f "$LEAK/st/one-canonical.tmproot" ]] \
    && ok "up records the launched session's temp root under FLEET_STATE" \
    || bad "no .tmproot record written for one-canonical"

recorded_root=$(cat "$LEAK/st/one-canonical.tmproot" 2>/dev/null)
[[ "$recorded_root" == "$LEAKTMPROOTS"/c-one-[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9] ]] \
    && ok "the recorded root matches the /tmp/c-<short>-XXXXXX shape (under the test prefix)" \
    || bad "recorded root has the wrong shape: $recorded_root"

[[ -n "$recorded_root" && "$args" == *"\"CLAUDE_CODE_TMPDIR\":\"$recorded_root\""* ]] \
    && ok "the root named in --settings is the SAME root that got recorded" \
    || bad "the launched --settings root and the recorded root disagree: recorded=$recorded_root args=$args"

[[ -n "$recorded_root" && -d "$recorded_root" && ! -L "$recorded_root" ]] \
    && ok "the launch actually created its temp root as a real directory (not a symlink)" \
    || bad "temp root directory was not created on disk: $recorded_root"

# ---------- resume: wake in place, fork only on request ----------
# `claude attach <id>` resumes a background session IN PLACE, including a STOPPED one -- it prints
# "Waking session <id>..." and the session returns with a new pid and its history intact.
# `claude --bg --resume <uuid>` always FORKS: new session id, transcript copied. Measured
# 2026-08-30 with the source session both running and stopped, so `--bg` is the cause, not
# `--resume`. This fleet had accumulated 4 fork groups / ~1.9 MB of duplicated transcript.
#
# Source assertions rather than live-session runs: spawning real sessions in a suite is not worth
# the cost, and these are the three properties that regressed or nearly did while authoring.
print "\n== resume: prefers waking over forking =="

grep -q 'attach "$row_id"' "$TOOL" \
  && ok "wakes an existing session via attach rather than forking it" \
  || bad "no attach path in resume -- every resume would duplicate a transcript"

grep -q 'force_fork' "$TOOL" \
  && ok "forking is opt-in (--fork), not the default" \
  || bad "no --fork opt-in; the lossy path must be chosen deliberately"

# The fork path must read the ALL listing. A stopped session is exactly what --fork branches from,
# and the live listing drops those -- the same blind spot dedupe had, where the command could not
# see the rows it existed to act on. Regressed during authoring; caught by running it.
awk '/^cmd_resume\(\)/,/^\}/' "$TOOL" | grep -q 'json=$(agents_json_all)' \
  && ok "the fork path reads the --all listing, so a stopped session is visible" \
  || bad "fork reads the live-only listing: --fork on a stopped session cannot see it"

# A fork inherits the CALLER's cwd, and cwd selects the project -- its CLAUDE.md, its memory store.
# Forking a canonical from the wrong directory brings it up on another project's context while
# still carrying the right NAME. Measured: a fork run from ~/Devel filed its transcript there.
# Forking a LIVE session is refused outright, not merely discouraged. The copy would be seeded
# from a transcript still being written, so it branches from an arbitrary mid-write moment that
# neither session records. The original code already refused this for the session it ran INSIDE;
# the reason never depended on which live session it was. The operator's call (2026-08-30): there is
# no scenario that wants a live session branched. The escape hatch is stop-then-fork, so nothing is
# prevented -- only made deliberate.
awk '/^cmd_resume\(\)/,/^\}/' "$TOOL" | grep -q 'fork is REFUSED on a live session' \
  && ok "--fork on a LIVE session is refused, with stop-then-fork named as the way through" \
  || bad "--fork would branch a live session from a transcript still being written"

awk '/^cmd_resume\(\)/,/^\}/' "$TOOL" | grep -q 'src_cwd' \
  && ok "the fork launches from the SOURCE session's cwd, not the caller's" \
  || bad "fork ignores the source cwd: right name, wrong project"

# A fork is a real launch too, and the fix this suite exists to guard is EXACTLY that fork was the
# one launch path missed the first time a temp-root pass was written for this file. Source
# assertions, matching every other resume-fork property above: a live fork needs a real transcript
# with a valid sessionId, and the existing tests here already decided that cost is not worth paying
# in this suite.
resume_fork_body=$(awk '/^cmd_resume\(\)/,/^\}/' "$TOOL")
[[ "$resume_fork_body" == *'record_tmproot "$name" "$root"'* ]] \
  && ok "the fork path records its own temp root, same as launch_canonical" \
  || bad "resume's fork path never calls record_tmproot -- a forked session would share/leak a root"

# Both invocations -- the branch that cd's into the source cwd, and the fallback branch -- must
# carry the flag. Counting rather than a single grep -q: a regression that dropped it from only
# ONE of the two branches would still pass a plain grep -q, since the other occurrence matches.
settings_count=$(printf '%s\n' "$resume_fork_body" | grep -c -- '--resume "\$uuid" --settings "\$settings"')
[[ "$settings_count" -eq 2 ]] \
  && ok "BOTH fork invocations (cd-into-src-cwd and the fallback) carry --settings" \
  || bad "expected --settings on both fork invocations, found $settings_count: $resume_fork_body"


# ---- resume-proof freshness gate, and the --force hatch ----------------------
# THE BUG THIS CLOSES (measured 2026-09-07). Opening a parked canonical from the agents view
# RESUMES it, which rewrites `startedAt` to the moment of the click. The freshness gate compared
# the handoff against that value, so a canonical parked correctly the previous evening was refused
# on the next morning's `refresh` -- the gate reporting staleness that did not exist. The
# transcript is the fixed point: a resume APPENDS to the same <sessionId>.jsonl, so its first
# timestamped entry still marks when the session really began.

TDIR="$TMPROOT/transcripts/proj"
mkdir -p "$TDIR"
mkdir -p "$TMPROOT/eta/.claude"
cat > "$TMPROOT/eta/.claude/canonical-kickoff.sh" <<'SH'
#!/usr/bin/env bash
cd /somewhere
exec claude --bg -n eta-canonical --model opus "You are eta-canonical."
SH
# The fixture IS the incident: startedAt is NOW (the resume), the handoff was recorded an hour ago,
# and the transcript says the session really began two hours ago. Under the old comparison this is
# a refusal; under the transcript comparison it is a pass. Both clocks are fixed, never wall time.
print "[{\"pid\":90666,\"id\":\"fff6\",\"name\":\"eta-canonical\",\"sessionId\":\"eta-sess-uuid\",\"startedAt\":$(( NOW * 1000 ))}]" \
  > "$TMPROOT/eta.json"
# Epoch -> ISO, both spellings: GNU takes -d @N, BSD takes -r N. A one-spelling fixture would not
# merely be less portable, it would build an EMPTY timestamp on the Mac and the assertions below
# would then measure the fallback path while claiming to measure the transcript path.
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -r "$1" -u +%Y-%m-%dT%H:%M:%S.000Z }
{ print -r -- "{\"type\":\"summary\",\"summary\":\"no timestamp on this line, deliberately\"}"
  print -r -- "{\"type\":\"user\",\"timestamp\":\"$(iso_at $(( NOW - 7200 )))\"}"
  print -r -- "{\"type\":\"assistant\",\"timestamp\":\"$(iso_at $(( NOW - 3900 )))\"}"
} > "$TDIR/eta-sess-uuid.jsonl"
[[ -s "$TDIR/eta-sess-uuid.jsonl" ]] && grep -q '20[0-9][0-9]-' "$TDIR/eta-sess-uuid.jsonl" \
    && ok "transcript fixture carries a real timestamp on this platform" \
    || bad "transcript fixture has no timestamp -- the tests below would measure the fallback path"

ESTATE="$TMPROOT/estate"
efc() { FLEET_ROOT="$TMPROOT" FLEET_STATE="$ESTATE" FLEET_TRANSCRIPT_DIR="$TMPROOT/transcripts" \
        FLEET_AGENTS_JSON_CMD="cat $TMPROOT/eta.json" bash "$TOOL" "$@" 2>&1 }
print "orientation" > "$TMPROOT/eta-handoff.md"
eset_ptr() { mkdir -p "$ESTATE"
             print "$TMPROOT/eta-handoff.md" >  "$ESTATE/eta-canonical.handoff"
             print "# set-at $1"             >> "$ESTATE/eta-canonical.handoff" }

eset_ptr $(( NOW - 3600 ))
out=$(efc refresh eta-canonical --dry-run); rc=$?
[[ $rc -eq 0 && "$out" == *"would refresh"* ]] \
    && ok "gate reads the session's TRUE start from its transcript, so a resume does not fake staleness" \
    || bad "resumed session still refused (rc=$rc): $out"
[[ "$out" == *"resumed:"*"using the transcript"* ]] \
    && ok "the gate SAYS it substituted the transcript start, naming both times" \
    || bad "gate substituted the start time silently: $out"

# ...and the substitution must not blind the gate. A handoff older than the TRUE start is still
# stale, or this change traded a false refusal for a false pass -- the worse of the two.
eset_ptr $(( NOW - 10800 ))
out=$(efc refresh eta-canonical --dry-run); rc=$?
[[ $rc -ne 0 && "$out" == *"PREDATES"* ]] \
    && ok "a handoff older than the transcript start is still refused" \
    || bad "transcript start made the gate unfalsifiable (rc=$rc): $out"

# With no transcript at all the gate must fall back to startedAt, not break. Same stale pointer,
# same fixture, transcript dir pointed somewhere empty: the refusal must survive.
out=$(FLEET_ROOT="$TMPROOT" FLEET_STATE="$ESTATE" FLEET_TRANSCRIPT_DIR="$TMPROOT/nope" \
      FLEET_AGENTS_JSON_CMD="cat $TMPROOT/eta.json" bash "$TOOL" refresh eta-canonical --dry-run 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"PREDATES"* ]] \
    && ok "an unreadable transcript falls back to startedAt rather than disabling the gate" \
    || bad "missing transcript broke the gate (rc=$rc): $out"

# --- --force: keeps the pointer, unlike --stub ---
eset_ptr $(( NOW - 10800 ))
out=$(efc refresh eta-canonical --force 'clicked in from the agents view' --dry-run); rc=$?
[[ $rc -eq 0 && "$out" == *"FORCED"* && "$out" == *"would refresh"* ]] \
    && ok "--force carries a refusal through" || bad "--force did not pass the gate (rc=$rc): $out"
[[ "$out" == *"clicked in from the agents view"* ]] \
    && ok "--force records the operator's reason in the output" || bad "--force dropped the reason: $out"
[[ "$out" == *"pointer LEFT AS-IS"* ]] \
    && ok "--force leaves the recorded handoff pointer untouched" || bad "--force did not say the pointer survived: $out"
# The property that separates it from --stub, asserted on the STATE rather than the message.
grep -q 'eta-handoff.md' "$ESTATE/eta-canonical.handoff" \
    && ok "--force did not rewrite the pointer to a generated stub" \
    || bad "--force replaced the real handoff: $(cat $ESTATE/eta-canonical.handoff)"

# Giving both is a contradiction about WHICH thing is wrong, so it is refused rather than ordered.
out=$(efc refresh eta-canonical --force x --stub y --dry-run); rc=$?
[[ $rc -ne 0 && "$out" == *"opposites"* ]] \
    && ok "--stub and --force together are refused" || bad "both hatches accepted (rc=$rc): $out"

# A refusal has to TEACH the difference, or the operator reaches for --stub (which destroys a good
# handoff) because it is the only hatch the message names. That is what happened on 2026-09-07.
rm -rf "$ESTATE"
out=$(efc refresh eta-canonical --dry-run); rc=$?
[[ "$out" == *"--force"* && "$out" == *"--stub"* ]] \
    && ok "the gate's refusal names BOTH hatches and what each one does" \
    || bad "refusal still names only one way out: $out"

# --- one canonical name, two declaring projects ---
# The record's version of the abandoned-worktree hazard. Discovery used to be find+sort, so two
# trees claiming one name were resolved by locale collation and the loser was often the live
# checkout; three such pairs existed on this machine when that was written. A record cannot have
# two scripts, but it CAN have two projects declaring the same canonical -- and each entry is
# individually well formed, so nothing but an explicit check sees the collision.
cat > "$TMPROOT/dupe.yaml" <<YAML
projects:
  eta:
    scope: eta
    canonical: eta-canonical
    canonicalIdentity: "the canonical session for eta"
    canonicalLaunchDir: eta
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
  eta_old:
    scope: eta.pre-worktree
    canonical: eta-canonical
    canonicalIdentity: "the canonical session for eta"
    canonicalLaunchDir: eta.pre-worktree
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
YAML
out=$(FLEET_RECORD="$TMPROOT/dupe.yaml" fleet-decl --check 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"canonical-duplicate"* && "$out" == *"eta-canonical"* ]] \
    && ok "one name declared by two projects is reported, not silently tie-broken" \
    || bad "duplicate canonical not caught (rc=$rc): $out"

out=$(FLEET_RECORD="$TMPROOT/dupe.yaml" fleet-decl --canonical eta-canonical canonicalLaunchDir 2>&1); rc=$?
[[ $rc -eq 2 && "$out" == *"not tie-broken"* && "$out" == *"eta eta_old"* ]] \
    && ok "a reader asked about an ambiguous name refuses and names both projects" \
    || bad "ambiguous read did not refuse with both names (rc=$rc): $out"
rm -rf "$TMPROOT/eta.pre-worktree"



# ---- a canonical sitting in a linked worktree --------------------------------
# MEASURED 2026-09-07: a canonical session that never left its worktree could not be closed
# -- the exit path tries to remove a worktree that is locked while a session holds it, and treats
# the removal it cannot perform as a failure of the whole stop. The refresh had already started a
# successor, so the name was left with two live rows. This warns; the prevention is in the parking
# skill. Both directions are asserted, because a warning that always fires teaches nothing.
WTREPO="$TMPROOT/wtrepo"
git init -q "$WTREPO" 2>/dev/null
# -c commit.gpgsign=false is LOAD-BEARING: a machine that sets commit.gpgsign=true globally may sign
# through an agent that prompts for an unlock, so an unqualified commit in a throwaway fixture repo
# blocks on a prompt that will never come and hangs the suite instead of failing it.
git -C "$WTREPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c gpg.format=openpgp \
    commit -q --allow-empty -m init 2>/dev/null
git -C "$WTREPO" worktree add -q -b side "$TMPROOT/wtlinked" 2>/dev/null

wt_json() {  # wt_json <cwd> -- a live eta row parked in the given directory
  print "[{\"pid\":90777,\"id\":\"ggg7\",\"name\":\"eta-canonical\",\"sessionId\":\"eta-sess-uuid\",\"startedAt\":$(( NOW * 1000 )),\"cwd\":\"$1\"}]" \
    > "$TMPROOT/wt.json"
}
wtfc() { FLEET_ROOT="$TMPROOT" FLEET_STATE="$ESTATE" FLEET_TRANSCRIPT_DIR="$TMPROOT/transcripts" \
         FLEET_AGENTS_JSON_CMD="cat $TMPROOT/wt.json" bash "$TOOL" "$@" 2>&1 }
eset_ptr $(( NOW - 3600 ))

if [[ -d "$TMPROOT/wtlinked" ]]; then
  wt_json "$TMPROOT/wtlinked"
  out=$(wtfc refresh eta-canonical --dry-run); rc=$?
  [[ "$out" == *"linked worktree"* ]] \
      && ok "refresh warns when the canonical is sitting in a linked worktree" \
      || bad "no worktree warning (rc=$rc): $out"
  [[ "$out" == *"would refresh"* ]] \
      && ok "the worktree warning does not block the refresh -- it is a warning, not a gate" \
      || bad "worktree warning refused the verb: $out"

  wt_json "$WTREPO"
  out=$(wtfc refresh eta-canonical --dry-run)
  [[ "$out" != *"linked worktree"* ]] \
      && ok "no warning for a canonical in its primary checkout" \
      || bad "worktree warning fires on a primary checkout too: $out"
else
  bad "fixture: could not create a linked worktree, so the warning was never exercised"
fi



# ---------------------------------------------------------------------------------------
# UNPLACED STAGED HANDOFFS. A canonical that cannot write the handoffs repository stages
# its handoff and points at it. Continuity is fine -- the pointer resolves. DURABILITY lags,
# and until this check existed nothing said so.
#
# The "fifteen days" anecdote this comment used to cite was itself a FALSE POSITIVE produced by
# the name-matching defect the fourth case below now covers -- that document had been placed the
# day it was written, under a different name. Corrected 2026-09-21.
#
# The third case is the one that decides whether this check survives contact. One staged file
# is legitimately placed under research/ rather than handoffs/, so a handoffs-only comparison
# reports a false orphan -- and a check that cries wolf gets ignored, which is worse than none.
# ---------------------------------------------------------------------------------------
UPROOT=$(mktemp -d "$_t/fc-unplaced.XXXXXX")
mkdir -p "$UPROOT/state/handoff-staging" "$UPROOT/prog/handoffs" "$UPROOT/prog/research"
ufc() { FLEET_STATE="$UPROOT/state" FLEET_HANDOFFS_DIR="$UPROOT/prog/handoffs" FLEET_HANDOFFS_SEARCH="$UPROOT/prog" \
        FLEET_AGENTS_JSON_CMD="cat $TMPROOT/agents.json" bash "$TOOL" "$@" 2>&1; }

: > "$UPROOT/state/handoff-staging/orphan.md"
out=$(ufc status)
[[ "$out" == *"UNPLACED  orphan.md"* ]] && ok "an unplaced staged handoff is reported" \
    || bad "unplaced handoff not reported: $out"

: > "$UPROOT/prog/handoffs/placed.md"; : > "$UPROOT/state/handoff-staging/placed.md"
out=$(ufc status)
[[ "$out" != *"UNPLACED  placed.md"* ]] && ok "one placed in handoffs/ is not reported" \
    || bad "placed handoff reported as unplaced: $out"

# THE ARM THAT MATTERS: placed ELSEWHERE in the tree must not read as an orphan.
: > "$UPROOT/prog/research/elsewhere.md"; : > "$UPROOT/state/handoff-staging/elsewhere.md"
out=$(ufc status)
[[ "$out" != *"UNPLACED  elsewhere.md"* ]] && ok "one placed outside handoffs/ is not a false orphan" \
    || bad "file placed under research/ reported as unplaced: $out"

# THE ARM THAT THIS CHECK FAILED IN PRODUCTION FOR FIFTEEN DAYS: placed under a DIFFERENT NAME.
# Placement is a judgment, so the hub may rename a staged draft or fold it into a differently-named
# standing document -- and no widening of the search can find it, because there is nothing to match.
# The staged copy instead declares its own disposition in a header, and that declaration is read.
#
# Both spellings are exercised because both are in real use: a placing session writes "PLACED AND
# COMMITTED" into a park handoff's staging copy, and "SUPERSEDED -- PLACED" into a draft's.
printf '# d\n\n> **PLACED AND COMMITTED** elsewhere under another name.\n' \
    > "$UPROOT/state/handoff-staging/renamed.md"
out=$(ufc status)
[[ "$out" != *"UNPLACED  renamed.md"* ]] && ok "a staged file DECLARING it was placed is not an orphan" \
    || bad "declared-placed file reported as unplaced: $out"

printf '# d\n\n> **SUPERSEDED -- PLACED 2026-09-06**, see the runbook.\n' \
    > "$UPROOT/state/handoff-staging/superseded.md"
out=$(ufc status)
[[ "$out" != *"UNPLACED  superseded.md"* ]] && ok "a staged file DECLARING it is superseded is not an orphan" \
    || bad "declared-superseded file reported as unplaced: $out"

# THE COUNTER-ARM, without which the two above prove only that the check went quiet. A marker
# BELOW the header must NOT excuse a file -- otherwise any handoff that merely discusses placing
# some other document silences its own orphan warning, and the check dies in the useful direction.
{ printf '# d\n\n'; for i in $(seq 1 25); do printf 'filler line %s\n' "$i"; done
  printf '> **PLACED** -- but this is line 28, far below the header.\n'; } \
    > "$UPROOT/state/handoff-staging/late-marker.md"
out=$(ufc status)
[[ "$out" == *"UNPLACED  late-marker.md"* ]] && ok "a marker below the header does NOT excuse a file" \
    || bad "late marker wrongly treated as a placement declaration: $out"

# And the count must match the real orphans, not every staged file.
out=$(ufc status)
[[ "$out" == *"2 staged handoff(s)"* ]] && ok "the count reflects real orphans only" \
    || bad "orphan count wrong: $out"

rm -rf "$UPROOT"


# ================================================================================================
# ---- per-launch temp roots: creation, recording, and guarded deletion -------------------------
# ================================================================================================
# Every real filesystem path below is redirected under $TMPROOT (via FLEET_TMPROOT_PREFIX / a
# scratch FLEET_STATE), never the real /tmp a production launch uses -- so this suite is safe to
# run anywhere, including a sandbox that denies writes to bare /tmp.
print "\n== temp roots: rm_tmproot guard (function-level) =="

RMSTATE="$TMPROOT/rm-state"; mkdir -p "$RMSTATE"
RMPREFIX="$TMPROOT/rm-prefix"; mkdir -p "$RMPREFIX"
# Invoke the REAL rm_tmproot in isolation, the same technique the claude_bin regression guard
# above uses: source just that function (and the tmproot_path it calls) out of the tool under
# test, rather than reimplementing the guard logic here where a second copy could drift from it.
rmfn() {  # rmfn NAME -- run the real rm_tmproot against $RMSTATE / $RMPREFIX
  FLEET_STATE="$RMSTATE" FLEET_TMPROOT_PREFIX="$RMPREFIX" bash -c \
    'eval "$(sed -n "/^tmproot_path()/,/^}/p;/^rm_tmproot()/,/^}/p" "$1")"; rm_tmproot "$2"' \
    _ "$TOOL" "$1"
}

# Case A -- a recorded root that matches the exact shape, is a real directory, not a symlink: MUST
# be removed, and its record cleared with it.
mkdir -p "$RMPREFIX/c-alpha-aB3xYz"
printf '%s\n' "$RMPREFIX/c-alpha-aB3xYz" > "$RMSTATE/alpha.tmproot"
rmfn alpha >/dev/null 2>&1
[[ ! -d "$RMPREFIX/c-alpha-aB3xYz" ]] \
    && ok "rm_tmproot removes a recorded root that matches the exact shape" \
    || bad "rm_tmproot left a matching, well-formed root in place"
[[ ! -f "$RMSTATE/alpha.tmproot" ]] \
    && ok "rm_tmproot clears the record once its root is gone" \
    || bad "rm_tmproot left a stale record behind after removing the root"

# Case B -- a sibling directory that is NOT the recorded path must survive. This is the "plant a
# sibling and prove it survives" case: rm_tmproot must act on the exact recorded string, never a
# glob over every /tmp/c-<name>-* directory.
mkdir -p "$RMPREFIX/c-beta-aB3xYz" "$RMPREFIX/c-beta-other"
printf '%s\n' "$RMPREFIX/c-beta-aB3xYz" > "$RMSTATE/beta.tmproot"
rmfn beta >/dev/null 2>&1
[[ ! -d "$RMPREFIX/c-beta-aB3xYz" ]] \
    && ok "rm_tmproot removes the exact recorded root" \
    || bad "the recorded root survived deletion"
[[ -d "$RMPREFIX/c-beta-other" ]] \
    && ok "a sibling directory NOT named in the record survives untouched" \
    || bad "rm_tmproot deleted a sibling it was never told about -- looks like a glob sweep, not an exact match"

# Case C -- a recorded path that does not match the /tmp/c-<short>-XXXXXX shape at all (a
# non-matching path planted in the record) must be refused outright: neither the target nor the
# record itself is touched, so a mismatch stays visible for debugging.
mkdir -p "$RMPREFIX/decoy-dir"
printf '%s\n' "$RMPREFIX/decoy-dir" > "$RMSTATE/gamma.tmproot"
rmfn gamma >/dev/null 2>&1
[[ -d "$RMPREFIX/decoy-dir" ]] \
    && ok "a recorded path outside the expected shape is left untouched" \
    || bad "rm_tmproot deleted something outside the /tmp/c-<short>-XXXXXX shape"
[[ -f "$RMSTATE/gamma.tmproot" ]] \
    && ok "a mismatched record is left in place too, rather than silently cleared" \
    || bad "rm_tmproot cleared a record it refused to act on"

# Case D -- a recorded path that IS a symlink (even to a real, matching-shaped directory) must be
# refused: never follow a symlink into a deletion.
mkdir -p "$RMPREFIX/real-target"
ln -s "$RMPREFIX/real-target" "$RMPREFIX/c-delta-aB3xYz"
printf '%s\n' "$RMPREFIX/c-delta-aB3xYz" > "$RMSTATE/delta.tmproot"
rmfn delta >/dev/null 2>&1
[[ -L "$RMPREFIX/c-delta-aB3xYz" && -d "$RMPREFIX/real-target" ]] \
    && ok "rm_tmproot refuses a recorded path that is a symlink, even to a real directory" \
    || bad "rm_tmproot followed a symlink -- its real target may have been deleted"

# Case E -- a recorded root that matches the shape but never actually exists on disk: no error,
# and the (already-meaningless) record is simply left as-is rather than crashing.
printf '%s\n' "$RMPREFIX/c-epsilon-aB3xYz" > "$RMSTATE/epsilon.tmproot"
out=$(rmfn epsilon 2>&1); rc=$?
[[ $rc -eq 0 ]] \
    && ok "a recorded root that never existed on disk does not error" \
    || bad "rm_tmproot errored on an already-absent root (rc=$rc): $out"

# ---- RED PLANT, observed by hand while authoring these cases (not left in the suite) -----------
# A scratch copy of rm_tmproot with its guard's `[ -d "$root" ]` check deleted (so ANY recorded
# string -- including the decoy path in Case C -- would be treated as safe to delete) turned Case C
# red: "a recorded path outside the expected shape is left untouched" failed because $RMPREFIX/decoy-dir
# was removed. Restoring the guard turned it green again. Reported in full in the handback message.

print "\n== temp roots: down deletes the recorded root (and only the recorded root) =="

STOP_E2E="$TMPROOT/stop-e2e"; mkdir -p "$STOP_E2E"
STOP_STATE="$STOP_E2E/state"; mkdir -p "$STOP_STATE"
STOP_PREFIX="$STOP_E2E/tmproots"; mkdir -p "$STOP_PREFIX"

# `down` gates on a recorded handoff for the name it is closing (see the handoff_gate tests
# earlier in this file); without one it refuses before ever reaching close_one.
print "orientation" > "$STOP_E2E/handoff.md"
FLEET_STATE="$STOP_STATE" bash "$TOOL" handoff stop-canonical --set "$STOP_E2E/handoff.md" >/dev/null

# A REAL, harmless, test-owned background process stands in for the session being stopped -- safe
# to signal (it is this test's own child, not a plausible real host pid), and its actual death is
# what proves the live-rows check that gates tmproot cleanup, not a fixture claiming it died.
sleep 300 & STOP_PID=$!

STOP_ROOT="$STOP_PREFIX/c-stop-aB3xYz"
STOP_SIBLING="$STOP_PREFIX/c-stop-canonical-other"
mkdir -p "$STOP_ROOT" "$STOP_SIBLING"
printf '%s\n' "$STOP_ROOT" > "$STOP_STATE/stop-canonical.tmproot"

# A DYNAMIC agents listing: reports the row only while STOP_PID is actually alive, so `down`'s
# live-rows check (cleanup_tmproot_if_gone) observes a REAL disappearance after close_one signals
# it, exactly as the live tool would see against a real `claude agents --json`.
cat > "$STOP_E2E/agents.sh" <<SH
#!/bin/sh
if kill -0 $STOP_PID 2>/dev/null; then
  printf '[{"pid":%s,"id":"stopid1","name":"stop-canonical","sessionId":"stop-sess","startedAt":1}]' $STOP_PID
else
  printf '[]'
fi
SH
chmod +x "$STOP_E2E/agents.sh"

out=$(FLEET_STATE="$STOP_STATE" FLEET_TMPROOT_PREFIX="$STOP_PREFIX" FLEET_CLAUDE_CMD=/usr/bin/true \
      FLEET_AGENTS_JSON_CMD="$STOP_E2E/agents.sh" \
      bash "$TOOL" down stop-canonical 2>&1); rc=$?

! kill -0 "$STOP_PID" 2>/dev/null \
    && ok "down actually signals the session's process" \
    || bad "down did not terminate the dummy session process (rc=$rc): $out"
[[ ! -d "$STOP_ROOT" ]] \
    && ok "down removes the recorded temp root once the session is gone" \
    || bad "down left the recorded temp root in place: $out"
[[ ! -f "$STOP_STATE/stop-canonical.tmproot" ]] \
    && ok "down clears the .tmproot record along with the root" \
    || bad "down removed the root but left a stale record"
[[ -d "$STOP_SIBLING" ]] \
    && ok "down leaves an unrelated sibling directory alone" \
    || bad "down deleted a sibling it was never told about"

kill "$STOP_PID" 2>/dev/null; true

print "\n== temp roots: dedupe never deletes the survivor's root =="

DEDUPE_E2E="$TMPROOT/dedupe-e2e"; mkdir -p "$DEDUPE_E2E"
DEDUPE_STATE="$DEDUPE_E2E/state"; mkdir -p "$DEDUPE_STATE"
DEDUPE_PREFIX="$DEDUPE_E2E/tmproots"; mkdir -p "$DEDUPE_PREFIX"
print "dd-canonical" > "$DEDUPE_E2E/roster"

sleep 300 & DD_OLD_PID=$!
sleep 300 & DD_NEW_PID=$!

# The record reflects the SURVIVOR's (newer) root, as a real launch through this tool would leave
# it -- there is only ever one record per name, and it is always the most recent launch's.
DD_ROOT="$DEDUPE_PREFIX/c-dd-zZ9qQ9"
mkdir -p "$DD_ROOT"
printf '%s\n' "$DD_ROOT" > "$DEDUPE_STATE/dd-canonical.tmproot"

cat > "$DEDUPE_E2E/agents.sh" <<SH
#!/bin/sh
rows=""
if kill -0 $DD_OLD_PID 2>/dev/null; then
  rows="\$rows{\"pid\":$DD_OLD_PID,\"id\":\"ddold\",\"name\":\"dd-canonical\",\"sessionId\":\"dd-old-sess\",\"startedAt\":1000},"
fi
if kill -0 $DD_NEW_PID 2>/dev/null; then
  rows="\$rows{\"pid\":$DD_NEW_PID,\"id\":\"ddnew\",\"name\":\"dd-canonical\",\"sessionId\":\"dd-new-sess\",\"startedAt\":9000},"
fi
printf '[%s]' "\${rows%,}"
SH
chmod +x "$DEDUPE_E2E/agents.sh"

out=$(CANONICAL_ROSTER="$DEDUPE_E2E/roster" FLEET_STATE="$DEDUPE_STATE" \
      FLEET_TMPROOT_PREFIX="$DEDUPE_PREFIX" FLEET_CLAUDE_CMD=/usr/bin/true \
      FLEET_AGENTS_JSON_CMD="$DEDUPE_E2E/agents.sh" \
      bash "$TOOL" dedupe dd-canonical 2>&1); rc=$?

! kill -0 "$DD_OLD_PID" 2>/dev/null \
    && ok "dedupe signals the OLDER duplicate's process" \
    || bad "dedupe did not terminate the older duplicate (rc=$rc): $out"
kill -0 "$DD_NEW_PID" 2>/dev/null \
    && ok "dedupe leaves the NEWER survivor's process running" \
    || bad "dedupe touched the survivor's process -- it should never be a dedupe target"
[[ -d "$DD_ROOT" ]] \
    && ok "dedupe never deletes the survivor's recorded temp root" \
    || bad "dedupe deleted the SURVIVING session's live temp root -- this would rm -rf a running session's TMPDIR"
grep -qxF "$DD_ROOT" "$DEDUPE_STATE/dd-canonical.tmproot" 2>/dev/null \
    && ok "the record still points at the survivor's root, untouched" \
    || bad "dedupe altered the surviving session's tmproot record"

kill "$DD_NEW_PID" 2>/dev/null; true

print "\n== temp roots: refresh deletes the OLD root only, never the NEW one =="

REFRESH_E2E="$TMPROOT/refresh-e2e"; mkdir -p "$REFRESH_E2E/dir"
REFRESH_STATE="$REFRESH_E2E/state"; mkdir -p "$REFRESH_STATE"
REFRESH_PREFIX="$REFRESH_E2E/tmproots"; mkdir -p "$REFRESH_PREFIX"

cat > "$REFRESH_E2E/rec.yaml" <<YAML
projects:
  rfp:
    scope: rfp
    canonical: rf-canonical
    canonicalIdentity: "the canonical session for rf"
    canonicalLaunchDir: dir
    canonicalLaunchModel: fable
    canonicalMachines: [$(hostname)]
YAML
print "orientation" > "$REFRESH_E2E/handoff.md"
FLEET_STATE="$REFRESH_STATE" bash "$TOOL" handoff rf-canonical --set "$REFRESH_E2E/handoff.md" >/dev/null

sleep 300 & RF_OLD_PID=$!

RF_OLD_ROOT="$REFRESH_PREFIX/c-rf-aB3xYz"
mkdir -p "$RF_OLD_ROOT"
printf '%s\n' "$RF_OLD_ROOT" > "$REFRESH_STATE/rf-canonical.tmproot"

# Dynamic listing, same technique as the stop case above: reports the row only while RF_OLD_PID is
# alive, so refresh's own "wait for the row to actually go" loop observes a real disappearance.
cat > "$REFRESH_E2E/agents.sh" <<SH
#!/bin/sh
if kill -0 $RF_OLD_PID 2>/dev/null; then
  printf '[{"pid":%s,"id":"rfold1","name":"rf-canonical","sessionId":"rf-old-sess","startedAt":1}]' $RF_OLD_PID
else
  printf '[]'
fi
SH
chmod +x "$REFRESH_E2E/agents.sh"

cat > "$REFRESH_E2E/argstub" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$REFRESH_ARGSLOG"
STUB
chmod +x "$REFRESH_E2E/argstub"
: > "$REFRESH_E2E/args.log"

out=$(FLEET_ROOT="$REFRESH_E2E" FLEET_RECORD="$REFRESH_E2E/rec.yaml" FLEET_STATE="$REFRESH_STATE" \
      FLEET_TMPROOT_PREFIX="$REFRESH_PREFIX" FLEET_CLAUDE_CMD="$REFRESH_E2E/argstub" \
      REFRESH_ARGSLOG="$REFRESH_E2E/args.log" FLEET_AGENTS_JSON_CMD="$REFRESH_E2E/agents.sh" \
      bash "$TOOL" refresh rf-canonical 2>&1); rc=$?

[[ $rc -eq 0 ]] && ok "refresh completes successfully end to end" || bad "refresh failed (rc=$rc): $out"
[[ ! -d "$RF_OLD_ROOT" ]] \
    && ok "refresh removes the OLD session's recorded temp root" \
    || bad "refresh left the old temp root in place: $out"

new_recorded_root=$(cat "$REFRESH_STATE/rf-canonical.tmproot" 2>/dev/null)
[[ -n "$new_recorded_root" && "$new_recorded_root" != "$RF_OLD_ROOT" ]] \
    && ok "refresh records a NEW root, distinct from the old one" \
    || bad "refresh did not record a fresh root (or reused the old one): $new_recorded_root"
[[ -n "$new_recorded_root" && -d "$new_recorded_root" && ! -L "$new_recorded_root" ]] \
    && ok "the new root is a real directory on disk" \
    || bad "the newly recorded root was not actually created: $new_recorded_root"

rf_args=$(cat "$REFRESH_E2E/args.log" 2>/dev/null)
[[ -n "$new_recorded_root" && "$rf_args" == *"\"CLAUDE_CODE_TMPDIR\":\"$new_recorded_root\""* ]] \
    && ok "the relaunch's --settings carries the SAME new root that got recorded" \
    || bad "the relaunch's --settings root and the recorded root disagree: root=$new_recorded_root args=$rf_args"

! kill -0 "$RF_OLD_PID" 2>/dev/null \
    && ok "the old session's process was actually terminated by the refresh" \
    || bad "refresh did not terminate the old session's process"

kill "$RF_OLD_PID" 2>/dev/null; true

# Leftover dummy processes are a safety net only -- everything above should have reaped its own.
for _p in "$STOP_PID" "$DD_OLD_PID" "$DD_NEW_PID" "$RF_OLD_PID"; do
  kill "$_p" 2>/dev/null; true
done

# ---- resume: the "handoff is NEWER than the transcript" advisory ----------------------------
# The advisory tells an operator that a session they are about to fork from its transcript had in
# fact parked, so `refresh` would read the handoff it wrote. It read the pointer file whole, and a
# pointer written by `handoff --set` carries a second `# set-at N` line, so the path it tested was
# two lines long, never a file, and the note could not fire. The fixture records the pointer the
# way every real one is recorded, through `handoff --set`.
print "\n== resume --fork: the handoff-newer-than-transcript advisory =="
RS="$TMPROOT/resume-adv"; mkdir -p "$RS/state" "$RS/transcripts/proj" "$RS/cwd"
RS_UUID="r5e5a1e0-0000-4000-8000-000000000001"
# A STOPPED row (no pid): with --fork that takes the fork path without trying to wake anything.
print "[{\"pid\":null,\"id\":\"r5e5a1e0\",\"name\":\"alpha-canonical\",\"sessionId\":\"$RS_UUID\",\"startedAt\":1000,\"cwd\":\"$RS/cwd\"}]" \
    > "$RS/agents.json"
print -r -- '{"type":"user","timestamp":"2026-01-01T00:00:00.000Z"}' > "$RS/transcripts/proj/$RS_UUID.jsonl"
touch -t 202601010000 "$RS/transcripts/proj/$RS_UUID.jsonl"
print "parked" > "$RS/handoff.md"
FLEET_STATE="$RS/state" bash "$TOOL" handoff alpha-canonical --set "$RS/handoff.md" >/dev/null
rsfc() { FLEET_STATE="$RS/state" FLEET_TRANSCRIPT_DIR="$RS/transcripts" \
         FLEET_AGENTS_JSON_CMD="cat $RS/agents.json" bash "$TOOL" "$@" 2>&1 }
out=$(rsfc resume alpha-canonical --fork --dry-run); rc=$?
[[ $rc -eq 0 && "$out" == *"would resume"*"$RS_UUID"* ]] \
    && ok "resume finds the transcript under FLEET_TRANSCRIPT_DIR" \
    || bad "resume did not find the transcript in the configured directory (rc=$rc): $out"
[[ "$out" == *"handoff is NEWER than the transcript"* ]] \
    && ok "the advisory fires for a stamped pointer naming a handoff newer than the transcript" \
    || bad "no advisory for a handoff newer than the transcript: $out"
# The counter-arm: a note that always fires teaches nothing.
touch -t 202501010000 "$RS/handoff.md"
out=$(rsfc resume alpha-canonical --fork --dry-run)
[[ "$out" != *"NEWER than the transcript"* ]] \
    && ok "the advisory stays quiet when the handoff is older than the transcript" \
    || bad "advisory fired for an older handoff: $out"

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

# ---- clean: scratch roots whose session is gone ------------------------------------------------
# Every launch makes a root under the prefix, and `down`/`refresh` remove the recorded one. Roots
# whose record was overwritten (a fork) or whose session ended without either verb are left, and a
# machine with no session-end hook keeps them forever. `clean` removes those and nothing else: it
# must never delete a root a running session may own, and must never act on a path of any other
# shape. Every root is aged past the young-root guard except the one that tests that guard.
print "\n== clean: removes the roots of gone sessions, and only those =="
CL="$TMPROOT/clean"; CLP="$CL/tmp"; CLS="$CL/state"; mkdir -p "$CLP" "$CLS" "$CL/target"
print -l gone-canonical quiet-canonical solo-canonical solo2-canonical twin-canonical > "$CL/roster"
mkroot() { mkdir -p "$CLP/$1/claude-1000"; print x > "$CLP/$1/claude-1000/f"; touch -t 202601010000 "$CLP/$1" }
mkroot c-gone-AAAAAA; mkroot c-gone-BBBBBB
mkroot c-quiet-CCCCCC; print "$CLP/c-quiet-CCCCCC" > "$CLS/quiet-canonical.tmproot"
mkroot c-solo-DDDDDD; print "$CLP/c-solo-DDDDDD" > "$CLS/solo-canonical.tmproot"
touch -t 202601010000 "$CLS/solo-canonical.tmproot"
mkroot c-solo-EEEEEE
mkroot c-solo2-PPPPPP; mkroot c-solo2-QQQQQQ; print "$CLP/c-solo2-PPPPPP" > "$CLS/solo2-canonical.tmproot"
mkroot c-twin-FFFFFF; mkroot c-twin-GGGGGG
mkdir -p "$CLP/c-gone-HHHHHH"                        # young: just made, as a launch in flight
mkroot c-gone-toolong7; mkroot c-gone-abc; mkroot c-stranger-IIIIII
ln -s "$CL/target" "$CLP/c-gone-JJJJJJ"; print keep > "$CL/target/f"
print file > "$CLP/c-gone-KKKKKK"; touch -t 202601010000 "$CLP/c-gone-KKKKKK"
# solo: one running session that started AFTER its root was recorded, so the recorded root is its.
# solo2: one running session that started long BEFORE its record was written, so the record may be
# another launch's and the running session's own root cannot be told apart: keep every one.
# twin: two running sessions under one name, each with a root of its own: keep both.
print "[{\"pid\":90111,\"id\":\"cl1\",\"name\":\"solo-canonical\",\"startedAt\":$(( NOW * 1000 ))},
 {\"pid\":90222,\"id\":\"cl2\",\"name\":\"solo2-canonical\",\"startedAt\":$(( (NOW - 86400) * 1000 ))},
 {\"pid\":90333,\"id\":\"cl3\",\"name\":\"twin-canonical\",\"startedAt\":$(( NOW * 1000 ))},
 {\"pid\":90444,\"id\":\"cl4\",\"name\":\"twin-canonical\",\"startedAt\":$(( NOW * 1000 ))}]" > "$CL/agents.json"
clfc() { CANONICAL_ROSTER="$CL/roster" FLEET_STATE="$CLS" FLEET_TMPROOT_PREFIX="$CLP" \
         FLEET_AGENTS_JSON_CMD="cat $CL/agents.json" bash "$TOOL" clean "$@" 2>&1 }
CL_ALL=(c-gone-AAAAAA c-gone-BBBBBB c-quiet-CCCCCC c-solo-DDDDDD c-solo-EEEEEE c-solo2-PPPPPP
        c-solo2-QQQQQQ c-twin-FFFFFF c-twin-GGGGGG c-gone-HHHHHH c-gone-toolong7 c-gone-abc
        c-stranger-IIIIII c-gone-JJJJJJ c-gone-KKKKKK)
out=$(clfc --dry-run); rc=$?
_missing=""; for r in $CL_ALL; do [[ -e "$CLP/$r" || -L "$CLP/$r" ]] || _missing="$_missing $r"; done
[[ $rc -eq 0 && -z "$_missing" && "$out" == *"would remove"*"c-gone-AAAAAA"* ]] \
    && ok "clean --dry-run names what it would remove and removes nothing" \
    || bad "clean --dry-run (rc=$rc, gone:$_missing): $out"
out=$(clfc); rc=$?
_gone=(c-gone-AAAAAA c-gone-BBBBBB c-quiet-CCCCCC c-solo-EEEEEE)
_kept=(c-solo-DDDDDD c-solo2-PPPPPP c-solo2-QQQQQQ c-twin-FFFFFF c-twin-GGGGGG c-gone-HHHHHH
       c-gone-toolong7 c-gone-abc c-stranger-IIIIII c-gone-JJJJJJ c-gone-KKKKKK)
_left=""; for r in $_gone; do [[ -e "$CLP/$r" ]] && _left="$_left $r"; done
[[ $rc -eq 0 && -z "$_left" ]] && ok "clean removes the roots of names with no running session" \
    || bad "clean left roots of gone sessions (rc=$rc, left:$_left): $out"
[[ ! -f "$CLS/quiet-canonical.tmproot" ]] && ok "clean clears the record of a root it removed" \
    || bad "clean removed a recorded root but left its record"
_lost=""; for r in $_kept; do [[ -e "$CLP/$r" || -L "$CLP/$r" ]] || _lost="$_lost $r"; done
[[ -z "$_lost" ]] && ok "clean keeps every root a running session may own, and every path of another shape" \
    || bad "clean deleted roots it must keep:$_lost -- $out"
[[ -f "$CLP/c-solo-DDDDDD/claude-1000/f" && -f "$CLP/c-twin-FFFFFF/claude-1000/f" ]] \
    && ok "a kept root's contents are untouched" || bad "clean emptied a live session's root"
[[ -f "$CL/target/f" ]] && ok "clean never follows a symlink of the root's shape" \
    || bad "clean deleted through a symlink"
[[ -f "$CLS/solo-canonical.tmproot" && -f "$CLS/solo2-canonical.tmproot" ]] \
    && ok "clean leaves the records of running sessions alone" || bad "clean removed a running session's record"
# Fail closed: a listing that cannot be read is not an empty fleet.
mkroot c-gone-LLLLLL
out=$(CANONICAL_ROSTER="$CL/roster" FLEET_STATE="$CLS" FLEET_TMPROOT_PREFIX="$CLP" \
      FLEET_AGENTS_JSON_CMD="false" bash "$TOOL" clean 2>&1); rc=$?
[[ $rc -eq 2 && -d "$CLP/c-gone-LLLLLL" ]] && ok "clean refuses, removing nothing, when the sessions list cannot be read" \
    || bad "clean on an unreadable listing (rc=$rc): $out"
out=$(clfc --bogus); rc=$?
[[ $rc -ne 0 && -d "$CLP/c-gone-LLLLLL" ]] && ok "clean refuses an unknown argument" \
    || bad "clean accepted an unknown argument (rc=$rc): $out"

# Belt-and-suspenders: this suite never writes under the real /tmp (everything above is redirected
# via FLEET_TMPROOT_PREFIX), so no NEW c-* directory may appear there during the run. Compared
# against a snapshot taken at the start, because live canonical sessions legitimately own roots
# there; the first version flagged a running session's root as a leak. A live canonical can also be
# REFRESHED while the suite runs, making a new root mid-run (2026-10-01: one canonical's, at 21:06, failed
# a commit gate). The real fleet records each live root in its own state, which this suite never
# writes, so a new root recorded there is a session's, not a leak.
real_state=${XDG_STATE_HOME:-$HOME/.local/state}/fleet-canonicals
live_roots=$(cat "$real_state"/*.tmproot 2>/dev/null | sort -u)
leaked_real_tmp=$(comm -13 <(print -r -- "$REAL_TMP_BEFORE") <(find /tmp -maxdepth 1 -name 'c-*' 2>/dev/null | sort) \
    | comm -23 - <(print -r -- "$live_roots"))
[[ -z "$leaked_real_tmp" ]] \
    && ok "no temp-root directories leaked into the real /tmp during this suite" \
    || bad "found real /tmp temp-root leftovers: $leaked_real_tmp"


[[ $fail == 0 ]] && { print "ALL PASS"; exit 0 } || { print "FAILURES"; exit 1 }
