#!/usr/bin/env bash
# Tests for `fleet-canonicals place` and `stage`: moving staged handoffs into the handoffs directory.
#
# Handoffs form a supersession chain -- each names the one it replaces -- so placing one moves a
# node in a linked list. The cases that matter are the ones a plain copy gets wrong: a predecessor
# that resolves nowhere must stop the placement rather than be reported as success, a pointer moved
# to the placed copy must keep its ORIGINAL set-at stamp (restamping it would let the freshness gate
# accept a handoff recorded after the session it is meant to describe), and the staging copy is
# never deleted, because for some handoffs it has been the only copy that ever existed.

set -uo pipefail
# No machine-global git config, so none of its commit hooks or signing settings reach the scratch
# repositories below.
. "$(dirname "$0")/git-isolate.sh"

TOOL="$(cd "$(dirname "$0")/.." && pwd)/private_dot_local/bin/executable_fleet-canonicals"
pass=0; fail=0
# Assertions test captured strings through herestrings, never a pipeline into grep -q: under
# pipefail the pipeline's status can report a successful match as a failure, depending on timing.
has() { grep -q -- "$2" <<< "$1"; }
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# Fresh fixture per case: a repository with one committed handoff, a staging dir, a roster.
# The handoffs directory sits one level below the searched tree, the shape a notes repository with
# other document directories beside handoffs/ takes.
setup() {
  rm -rf "$TMP/case"; mkdir -p "$TMP/case"
  R="$TMP/case/notes"; PROG="$R/program"; HO="$PROG/handoffs"
  STATE="$TMP/case/state"; STG="$STATE/handoff-staging"
  mkdir -p "$HO" "$STG" "$TMP/case/nohooks"
  git -C "$TMP/case" init -q notes
  git -C "$R" config user.name test; git -C "$R" config user.email test@example.invalid
  git -C "$R" config commit.gpgsign false; git -C "$R" config core.hooksPath "$TMP/case/nohooks"
  printf '# old\n' > "$HO/2026-09-01-0900-alpha-canonical-park.md"
  git -C "$R" add -A; git -C "$R" commit -q -m base
  printf 'alpha-canonical\nbeta-canonical\n' > "$TMP/case/roster"
  export FLEET_STATE="$STATE" CANONICAL_ROSTER="$TMP/case/roster"
  export FLEET_HANDOFFS_DIR="$HO" FLEET_HANDOFFS_SEARCH="$PROG" FLEET_PLACE_COMMIT=true
  # The machine's own config file must not leak in; the cases that test the file write their own.
  export FLEET_CANONICALS_CONFIG="$TMP/case/no-config"
  unset FLEET_HUB
}
handoff() { # <file> <supersedes or ''>
  { printf '# Park\n\n'; [ -n "$2" ] && printf '**Parked.** Supersedes `%s`.\n' "$2"; printf '\nbody\n'; } > "$1"
}
commits() { git -C "$R" rev-list --count HEAD; }
first_line() { head -n 1 "$1"; }

printf '\n== places a handoff whose predecessor is committed, and repoints with the ORIGINAL stamp ==\n'
setup
A=2026-09-27-1200-alpha-canonical-park.md
handoff "$STG/$A" 2026-09-01-0900-alpha-canonical-park.md
printf '%s\n# set-at 1111111111\n' "$STG/$A" > "$STATE/alpha-canonical.handoff"
# Unrelated work already in the index must not ride along in the placement commit.
printf 'unrelated\n' > "$R/other.md"; git -C "$R" add other.md
out=$(bash "$TOOL" place 2>&1); rc=$?
[ "$rc" -eq 0 ] && cmp -s "$STG/$A" "$HO/$A" \
  && ok "copies the staged file into handoffs/ verbatim" || bad "not placed" "rc=$rc: $out"
git -C "$R" ls-files --error-unmatch "program/handoffs/$A" >/dev/null 2>&1 && [ "$(commits)" = 2 ] \
  && ok "commits the placed file" || bad "no commit of the placed file" "$out"
names=$(git -C "$R" show --name-only --format= HEAD)
has "$names" other.md \
  && bad "committed unrelated staged work" "the placement commit must hold only placed handoffs" \
  || ok "the commit holds only the placed handoff"
[ -f "$STG/$A" ] && ok "keeps the staging copy" || bad "deleted the staging copy" "it may be the only copy that ever existed"
[ "$(first_line "$STATE/alpha-canonical.handoff")" = "$HO/$A" ] \
  && ok "repoints the canonical at the placed copy" || bad "pointer not moved" "$(cat "$STATE/alpha-canonical.handoff")"
ptr=$(cat "$STATE/alpha-canonical.handoff")
has "$ptr" '^# set-at 1111111111$' \
  && ok "keeps the pointer's original set-at stamp" \
  || bad "restamped the pointer" "a fresh stamp defeats the freshness gate: $ptr"

printf '\n== places a chain staged together ==\n'
setup
B=2026-09-27-1300-alpha-canonical-park.md; C=2026-09-27-1200-alpha-canonical-park.md
handoff "$STG/$C" 2026-09-01-0900-alpha-canonical-park.md
handoff "$STG/$B" "$C"
out=$(bash "$TOOL" place 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -f "$HO/$B" ] && [ -f "$HO/$C" ] \
  && ok "a predecessor placed in the same run resolves the chain" || bad "chain not placed" "rc=$rc: $out"

printf '\n== refuses a broken chain ==\n'
setup
D=2026-09-27-1400-beta-canonical-park.md
handoff "$STG/$D" 2026-09-20-0100-beta-canonical-park.md
printf '%s\n# set-at 2222222222\n' "$STG/$D" > "$STATE/beta-canonical.handoff"
before=$(commits)
out=$(bash "$TOOL" place 2>&1); rc=$?
[ "$rc" -ne 0 ] && has "$out" 'BROKEN-CHAIN.*2026-09-20-0100-beta-canonical-park.md' \
  && ok "names the predecessor that resolves nowhere, and exits non-zero" || bad "broken chain not reported" "rc=$rc: $out"
[ ! -e "$HO/$D" ] && [ "$(commits)" = "$before" ] \
  && ok "places nothing for it" || bad "placed a handoff with a dangling predecessor" "a copy that succeeded is the failure"
[ "$(first_line "$STATE/beta-canonical.handoff")" = "$STG/$D" ] \
  && ok "leaves its pointer on the staged copy" || bad "moved the pointer of an unplaced handoff" ""
out=$(bash "$TOOL" place --accept-broken-chain 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -f "$HO/$D" ] && has "$out" 'BROKEN-CHAIN' \
  && ok "--accept-broken-chain places it and still names the gap" || bad "override did not work" "rc=$rc: $out"

# The successor of a refused handoff must be refused too: its predecessor is staged in this run, so a
# single pass that reaches the successor FIRST counts it resolved and places it, then drops the
# predecessor. The successor's name sorts first here on purpose; in chain order a single pass
# happens to get it right, which is how a test with realistic names passed against a one-pass loop.
printf '\n== a successor of a refused handoff is refused too ==\n'
setup
E=2026-09-27-1300-beta-canonical-park.md
handoff "$STG/$D" 2026-09-20-0100-beta-canonical-park.md
handoff "$STG/$E" "$D"
out=$(bash "$TOOL" place 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$HO/$D" ] && [ ! -e "$HO/$E" ] && has "$out" "BROKEN-CHAIN.*$E" \
  && ok "refuses the whole broken chain, naming each link" || bad "placed a successor whose predecessor was refused" "rc=$rc: $out"

printf '\n== leaves a non-handoff draft for a judgment call ==\n'
setup
handoff "$STG/2026-09-27-notes-memory-placement-pass.md" ''
handoff "$STG/2026-09-27-1500-gamma-unknown-park.md" ''
out=$(bash "$TOOL" place 2>&1); rc=$?
[ "$rc" -ne 0 ] && has "$out" 'NEEDS-JUDGMENT.*notes-memory-placement-pass' && has "$out" 'NEEDS-JUDGMENT.*gamma-unknown' \
  && ok "reports files that are not a declared canonical's dated handoff, exit non-zero" || bad "draft not reported" "rc=$rc: $out"
listing=$(ls "$HO")
[ "$listing" = 2026-09-01-0900-alpha-canonical-park.md ] && ok "places neither" || bad "placed a draft" "$listing"

printf '\n== --dry-run changes nothing ==\n'
setup
handoff "$STG/$A" 2026-09-01-0900-alpha-canonical-park.md
printf '%s\n# set-at 1111111111\n' "$STG/$A" > "$STATE/alpha-canonical.handoff"
before=$(commits); ptr_before=$(cat "$STATE/alpha-canonical.handoff")
out=$(bash "$TOOL" place --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] && has "$out" "would place.*$A" && [ ! -e "$HO/$A" ] && [ "$(commits)" = "$before" ] \
  && [ "$(cat "$STATE/alpha-canonical.handoff")" = "$ptr_before" ] \
  && ok "reports the plan and touches nothing" || bad "dry run acted or was silent" "rc=$rc: $out"

printf '\n== nothing staged ==\n'
setup
out=$(bash "$TOOL" place 2>&1); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'nothing to place' && ok "says so, exit 0" || bad "wrong empty-case report" "rc=$rc: $out"

# ==================================================================================================
# `stage`: the parking canonical supplies content and its own name; the tool picks the path.
printf '\n== stage names the file, records the pointer, and hands off to place ==\n'
setup
SRC="$TMP/case/draft.md"; handoff "$SRC" 2026-09-01-0900-alpha-canonical-park.md
printf '%s\n# set-at 1000000000\n' "$HO/2026-09-01-0900-alpha-canonical-park.md" > "$STATE/alpha-canonical.handoff"
out=$(bash "$TOOL" stage alpha-canonical "$SRC" 2>&1); rc=$?
staged=$(find "$STG" -name '*-alpha-canonical-park.md')
sbase=$(basename "$staged")
case "$sbase" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]-alpha-canonical-park.md) named=1 ;; *) named=0 ;; esac
[ "$rc" -eq 0 ] && [ "$named" -eq 1 ] && cmp -s "$SRC" "$staged" \
  && ok "writes the content into staging under the dated canonical name" || bad "stage did not write the file" "rc=$rc: $out"
ptr=$(cat "$STATE/alpha-canonical.handoff")
[ "$(first_line "$STATE/alpha-canonical.handoff")" = "$staged" ] && ! has "$ptr" 'set-at 1000000000' \
  && ok "points the canonical at it with a fresh stamp (a genuine new recording)" || bad "pointer not recorded" "$ptr"
stamp=$(sed -n 's/^# set-at //p' "$STATE/alpha-canonical.handoff")
out=$(bash "$TOOL" place 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -f "$HO/$sbase" ] && [ "$(first_line "$STATE/alpha-canonical.handoff")" = "$HO/$sbase" ] \
  && has "$(cat "$STATE/alpha-canonical.handoff")" "set-at $stamp" \
  && ok "place then moves it and keeps the stamp stage recorded" || bad "stage -> place did not chain" "rc=$rc: $out"

printf '\n== stage refuses what would break the chain or the fleet ==\n'
setup
printf '%s\n# set-at 1000000000\n' "$HO/2026-09-01-0900-alpha-canonical-park.md" > "$STATE/alpha-canonical.handoff"
handoff "$TMP/case/nochain.md" ''
out=$(bash "$TOOL" stage alpha-canonical "$TMP/case/nochain.md" 2>&1); rc=$?
staged=$(find "$STG" -name '*.md')
[ "$rc" -ne 0 ] && [ -z "$staged" ] && has "$out" '2026-09-01-0900-alpha-canonical-park.md' \
  && ok "refuses content that does not supersede the current pointer, naming the file to cite" \
  || bad "staged a handoff that breaks the chain" "rc=$rc: $out"
out=$(bash "$TOOL" stage no-such-canonical "$TMP/case/nochain.md" 2>&1); rc=$?
[ "$rc" -ne 0 ] && has "$out" 'no-such-canonical' \
  && ok "refuses a name that is not a declared canonical" || bad "staged for an unknown canonical" "rc=$rc: $out"
# The timestamp is pinned so the overwrite case cannot flake across a minute boundary.
export FLEET_STAGE_STAMP=2026-09-27-1600
rm -f "$STATE/beta-canonical.handoff"; handoff "$TMP/case/first.md" ''
out=$(bash "$TOOL" stage beta-canonical "$TMP/case/first.md" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "a canonical with no pointer yet starts a chain without citing one" || bad "first handoff refused" "rc=$rc: $out"
# The second call cites the first as its predecessor, so the chain check passes and only the
# overwrite guard can refuse it. Without that, the chain check refused it and the case proved nothing.
handoff "$TMP/case/second.md" 2026-09-27-1600-beta-canonical-park.md
out=$(bash "$TOOL" stage beta-canonical "$TMP/case/second.md" 2>&1); rc=$?
n=$(find "$STG" -name '*-beta-canonical-park.md' | wc -l | tr -d '[:space:]')
[ "$rc" -ne 0 ] && [ "$n" = 1 ] && has "$out" 'already exists' \
  && ok "refuses to overwrite a staged handoff with the same name" || bad "overwrote a staged handoff" "rc=$rc n=$n: $out"
unset FLEET_STAGE_STAMP

# ==================================================================================================
# Configuration. The handoffs directory, the searched tree, the hub and whether `place` commits are
# a domain's own values, so they come from a config file the domain's private layer writes, and
# each can be overridden by an environment variable. These cases exercise the file and the switch.

printf '\n== place-commit off: copies and repoints, commits nothing ==\n'
setup
export FLEET_PLACE_COMMIT=false
handoff "$STG/$A" 2026-09-01-0900-alpha-canonical-park.md
printf '%s\n# set-at 1111111111\n' "$STG/$A" > "$STATE/alpha-canonical.handoff"
before=$(commits)
out=$(bash "$TOOL" place 2>&1); rc=$?
[ "$rc" -eq 0 ] && cmp -s "$STG/$A" "$HO/$A" && [ "$(commits)" = "$before" ] \
  && ok "copies the handoff and makes no commit" || bad "commit-off placement wrong" "rc=$rc: $out"
has "$out" 'not committed' && ok "says it did not commit" || bad "silent about the missing commit" "$out"
[ "$(first_line "$STATE/alpha-canonical.handoff")" = "$HO/$A" ] && has "$(cat "$STATE/alpha-canonical.handoff")" '^# set-at 1111111111$' \
  && ok "still repoints, keeping the original stamp" || bad "pointer not moved without a commit" "$(cat "$STATE/alpha-canonical.handoff")"
export FLEET_PLACE_COMMIT=true

printf '\n== the config file supplies every value when no variable is set ==\n'
setup
unset FLEET_HANDOFFS_DIR FLEET_HANDOFFS_SEARCH FLEET_PLACE_COMMIT
CFG="$TMP/case/config"
printf '# a comment\n\nhandoffs = %s\nhandoffs-search = %s\nhub = hub-canonical\nplace-commit = true\n' "$HO" "$PROG" > "$CFG"
export FLEET_CANONICALS_CONFIG="$CFG"
handoff "$STG/$A" 2026-09-01-0900-alpha-canonical-park.md
out=$(bash "$TOOL" place 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -f "$HO/$A" ] && [ "$(commits)" = 2 ] \
  && ok "places into the configured directory and commits as configured" || bad "config file not read by place" "rc=$rc: $out"
SRC="$TMP/case/draft.md"; handoff "$SRC" ''
rm -f "$STATE/beta-canonical.handoff"
out=$(bash "$TOOL" stage beta-canonical "$SRC" 2>&1); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'hub-canonical' \
  && ok "stage names the configured hub as the session that places it" || bad "stage did not name the hub" "rc=$rc: $out"
help=$(bash "$TOOL" --help 2>&1)
has "$help" 'FLEET_CANONICALS_CONFIG' && has "$help" 'FLEET_HANDOFFS_DIR' && has "$help" 'FLEET_CLAUDE_CMD' \
  && ok "the help documents the config file and its overrides" || bad "help omits the configuration" "$help"

printf '\n== a variable overrides the config file ==\n'
setup
mkdir -p "$TMP/case/elsewhere"
printf 'handoffs = %s\nhandoffs-search = %s\nplace-commit = true\n' "$TMP/case/elsewhere" "$TMP/case/elsewhere" > "$TMP/case/config"
export FLEET_CANONICALS_CONFIG="$TMP/case/config"
handoff "$STG/$A" 2026-09-01-0900-alpha-canonical-park.md
out=$(bash "$TOOL" place 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -f "$HO/$A" ] && [ ! -e "$TMP/case/elsewhere/$A" ] \
  && ok "FLEET_HANDOFFS_DIR wins over the file's handoffs" || bad "the file overrode the variable" "rc=$rc: $out"

printf '\n== nothing configured ==\n'
setup
unset FLEET_HANDOFFS_DIR FLEET_HANDOFFS_SEARCH FLEET_PLACE_COMMIT
handoff "$STG/$A" 2026-09-01-0900-alpha-canonical-park.md
out=$(bash "$TOOL" place 2>&1); rc=$?
[ "$rc" -ne 0 ] && has "$out" 'no handoffs directory is configured' && has "$out" 'FLEET_HANDOFFS_DIR' \
  && ok "place refuses, naming how to configure the directory" || bad "unconfigured place did not refuse clearly" "rc=$rc: $out"
SRC="$TMP/case/draft.md"; handoff "$SRC" ''
rm -f "$STATE/beta-canonical.handoff"
out=$(bash "$TOOL" stage beta-canonical "$SRC" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ! has "$out" 'systems canonical' \
  && ok "stage with no hub configured names no hub" || bad "stage named a hub nobody configured" "rc=$rc: $out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
