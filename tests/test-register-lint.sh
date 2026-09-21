#!/bin/sh
# Tests for register-lint. Every case PLANTS a defect and asserts the tool reports it, or
# plants the near-miss and asserts it does not.
#
# WHY IT IS SHAPED THIS WAY: a check that has only ever been seen green is of unknown
# value. Observing a red once by hand retires that objection for one afternoon; a file of
# plants retires it for every future edit to the rules, which is when a gate is most likely
# to quietly stop working.
#
# GRANULARITY IS THE POINT, not a detail. A gate seen to reject a whole malformed entry is
# not thereby known to reject ONE malformed field inside an otherwise valid one -- and the
# second is the case that actually occurs. So the fixtures below are VALID entries with a
# single planted defect, never scaffolding that is broken all over.
#
# The case that named this tool: a register's own checker tested that the closure-condition
# heading had some text beneath it, so the literal string TODO passed clean. That exact
# string is planted below, because a tool written to prevent a specific failure should be
# able to demonstrate it prevents that failure.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
lint="$here/../private_dot_local/bin/executable_register-lint"
pass=0
fail=0

ok()  { pass=$((pass + 1)); echo "ok:   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

assert_has() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (expected to find: $2)" ;;
  esac
}
assert_lacks() {
  case "$3" in
    *"$2"*) bad "$1 (did NOT expect: $2)" ;;
    *) ok "$1" ;;
  esac
}

_t=${TMPDIR:-/tmp}; _t=${_t%/}   # macOS sets TMPDIR WITH a trailing slash
tmp=$(mktemp -d "$_t/register-lint-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# A VALID entry, parameterised. Everything planted below is a one-field change to this.
#   $1 dir  $2 id  $3 status  $4 extra frontmatter  $5 closure-condition body
#   $6 verified date (default: today)   $7 next action (default: present; empty to omit)
entry() {
  mkdir -p "$1"
  {
    echo "---"
    echo "id: $2"
    echo "title: A tracked thing"
    echo "status: $3"
    [ -n "$4" ] && echo "$4"
    echo "owner: jeremy"
    echo "verified: ${6:-$(date +%Y-%m-%d)}"
    echo "---"
    echo ""
    echo "# $2 — A tracked thing"
    echo ""
    echo "## Next action"
    [ $# -ge 7 ] && [ -z "$7" ] || echo "${7:-Somebody does the next thing.}"
    echo ""
    echo "## Body"
    echo ""
    echo "### Definition of done"
    echo "$5"
    echo ""
    echo "### Tasks"
    echo "- [ ] a unit of work"
    echo ""
    echo "### Resolution"
    echo ""
    echo "## History"
    echo "### 2026-01-01 — raised"
  } > "$1/$2-a-tracked-thing.md"
}

run() { python3 "$lint" "$1" --quiet 2>&1 || true; }

# --- the control: a wholly valid register reports nothing -----------------------------
# Without this every "reports X" case below is satisfiable by a tool that reports X always.
r="$tmp/clean"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "The thing is measurably finished."
out=$(run "$r")
assert_lacks "a valid register is clean" "[" "$out"
python3 "$lint" "$r" --quiet >/dev/null 2>&1 && ok "valid register exits 0" || bad "valid register exits 0"

# --- closure condition: the three states ---------------------------------------------
r="$tmp/empty"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" ""
assert_has "an EMPTY condition on an open entry is reported" "[closure-condition]" "$(run "$r")"

r="$tmp/todo"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "TODO"
assert_has "the literal TODO does not pass as a condition" "[undeclared-absence]" "$(run "$r")"

r="$tmp/prose"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "*Not recorded in the source register, and deliberately not invented here.*"
assert_has "prose asserting an absence is reported" "[undeclared-absence]" "$(run "$r")"

r="$tmp/declared"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "TRIAGE REQUIRED
Nobody has examined whether one is recoverable."
out=$(run "$r")
assert_lacks "a DECLARED absence does not block" "[closure-condition]" "$out"
assert_lacks "a declared absence is not also an undeclared one" "[undeclared-absence]" "$out"
assert_has "a declared absence is counted as debt" "[triage-debt]" "$out"

# PARTIAL recovery: a real condition, then a sentinel for the remainder. The rule is that
# the entry KEEPS the recovered half, so this must not be read as an absence.
r="$tmp/partial"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "Raw captures stay out of version control. That half is binding.

ALIGNMENT REQUIRED
The rest needs a decision nobody has made."
out=$(run "$r")
assert_lacks "a PARTIALLY recovered condition does not block" "[closure-condition]" "$out"
assert_has "the remainder is counted as owed" "[alignment-owed]" "$out"

# `idea` is the one exempt status, and the exemption is what makes raising a thing cheap.
r="$tmp/idea"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "idea" "" ""
assert_lacks "an empty condition at idea is exempt" "[closure-condition]" "$(run "$r")"

r="$tmp/mismatch"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "NONE REQUIRED"
assert_has "the exempt sentinel off idea is reported" "[sentinel-mismatch]" "$(run "$r")"

# A template that was copied and never filled in must not read as written.
r="$tmp/placeholder"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "<!-- One statement of the closure condition. -->"
assert_has "an unfilled template comment is not a condition" "[closure-condition]" "$(run "$r")"

# REGRESSION GUARD, and it is the reason the heuristic is allowed to exist at all: a phrase in
# it must never appear in a sentence that AFFIRMS a condition. The contract's own idiom is
# "recovered from what is known, not invented here" -- an earlier pattern matched "not invented"
# and fired on exactly that, so a correct entry had to be reworded to get past the gate. A lint
# that degrades the prose it governs is worse than no lint.
r="$tmp/idiom"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "Recovered from decisions already recorded, not invented here: the
runtime is in genuine daily use."
assert_lacks "the contract's own idiom does not trip the heuristic" "[undeclared-absence]" "$(run "$r")"

# The other half of that guard: dropping the branch must not have lost the case it was added for.
r="$tmp/migrated"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "*Not recorded in the source register, and deliberately not invented here.*"
assert_has "the real migrated-absence prose is still caught" "[undeclared-absence]" "$(run "$r")"

# --- conditional fields ---------------------------------------------------------------
r="$tmp/gate-missing"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "blocked" "" "The thing is finished."
assert_has "blocked without a gate is reported" "[conditional-field]" "$(run "$r")"

r="$tmp/gate-stray"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "gate: waiting on nothing" "The thing is finished."
assert_has "a stray gate is reported" "[conditional-field]" "$(run "$r")"

# --- standing: an obligation, not an exemption ----------------------------------------
r="$tmp/standing-nocadence"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "standing" "" "Re-verified continuously."
assert_has "standing without a cadence is reported" "[conditional-field]" "$(run "$r")"

r="$tmp/standing-ok"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "standing" "cadence: quarterly" "Advisories are reviewed and applied."
assert_lacks "standing WITH a cadence is accepted" "[conditional-field]" "$(run "$r")"

# The check that makes the cadence mean something. Without it, declaring one is decorative.
r="$tmp/standing-stale"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "standing" "cadence: weekly" "Advisories are reviewed and applied." "2026-01-01"
assert_has "a standing entry past its own cadence is reported" "[standing-stale]" "$(run "$r")"

# --- location, resolution, next action -------------------------------------------------
r="$tmp/loc"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "done" "" "The thing is finished."
assert_has "a closed status outside closed/ is reported" "[location]" "$(run "$r")"

r="$tmp/res"; mkdir -p "$r/closed"
entry "$r/closed" "ABC-01" "done" "closed: 2026-01-02" "The thing is finished."
assert_has "a closed entry with no resolution is reported" "[resolution]" "$(run "$r")"

r="$tmp/nextaction"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "The thing is finished." "" ""
assert_has "an open entry with no next action is reported" "[next-action]" "$(run "$r")"

# --- identity ---------------------------------------------------------------------------
r="$tmp/fname"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "The thing is finished."
mv "$r/ABC-01-a-tracked-thing.md" "$r/renamed-by-somebody.md"
assert_has "a filename not starting with its id is reported" "[filename]" "$(run "$r")"

r="$tmp/mixed"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "The thing is finished."
entry "$r" "XYZ-02" "active" "" "The other thing is finished."
assert_has "two prefixes in one register are reported" "[id-integrity]" "$(run "$r")"

r="$tmp/badstatus"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "nearly-done" "" "The thing is finished."
assert_has "a status outside the vocabulary is reported" "[status-vocabulary]" "$(run "$r")"

# --- the directory name, and why it is not configurable ---------------------------------
r="$tmp/legacy"; mkdir -p "$r/archive"
entry "$r" "ABC-01" "active" "" "The thing is finished."
out=$(run "$r")
assert_has "the legacy finished-entry name is reported" "[not-renamed]" "$out"
# It is still READ, so a register can be linted before it is renamed -- but the fallback
# can never be mistaken for a permitted spelling, because it reports.
entry "$r/archive" "ABC-02" "done" "closed: 2026-01-02" "The thing is finished."
assert_has "entries in the legacy directory are still checked" "[resolution]" "$(run "$r")"

# --- absent register is not an error ----------------------------------------------------
python3 "$lint" "$tmp/does-not-exist" --quiet >/dev/null 2>&1 \
  && ok "an absent register exits 0" || bad "an absent register exits 0"

echo ""
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
