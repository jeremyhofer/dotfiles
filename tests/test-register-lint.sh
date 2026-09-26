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

# A sentinel wrapped in markdown emphasis must still be a sentinel. An anchored match walks past
# the asterisks, finds nothing, and the entry reads as holding a REAL condition -- so two characters
# silently convert "a decision is owed" into "settled", with every surface green. Found by the third
# migration, whose four entries all used the bolded form because it is the natural markdown.
for form in '**ALIGNMENT REQUIRED.**' '_ALIGNMENT REQUIRED_' '> ALIGNMENT REQUIRED' '`ALIGNMENT REQUIRED`'; do
  r="$tmp/emph$(printf '%s' "$form" | cksum | tr -d ' ')"; mkdir -p "$r/closed"
  entry "$r" "ABC-01" "scoped" "" "$form
The remainder needs a decision nobody has made."
  out=$(run "$r")
  assert_has "decorated sentinel still counts: $form" "[alignment-owed]" "$out"
  assert_lacks "and does not read as a written condition: $form" "[closure-condition]" "$out"
done

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

# A register must be able to carry an auxiliary document — a mapping table, a cookbook, a charter.
# Excluding only README by name made every other file an entry, so each was linted as malformed and
# counted in the census. An entry is identified by frontmatter carrying an id, not by its filename.
r="$tmp/auxdoc"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "The thing is measurably finished."
printf '# Migration map\n\n| old | new |\n| --- | --- |\n| OLD-04 | ABC-13 |\n' > "$r/MIGRATION-MAP.md"
out=$(run "$r")
assert_lacks "an auxiliary document is not linted as an entry" "MIGRATION-MAP" "$out"
python3 "$lint" "$r" 2>&1 | grep -q '1 entries' \
  && ok "and is not counted in the census" || bad "and is not counted in the census"

# But a genuine entry with a WRONG filename must still be caught — which is why the discriminator
# is content and not a filename pattern. A pattern would have skipped this silently.
r="$tmp/auxmisnamed"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "The thing is measurably finished."
mv "$r/ABC-01-a-tracked-thing.md" "$r/notes-about-the-thing.md"
assert_has "a misnamed real entry is still caught" "[filename]" "$(run "$r")"

# TODO and FIXME are absence vocabulary AND ordinary code tokens. An entry whose SUBJECT is those
# markers holds a genuine condition; inline code is MENTION, not use.
r="$tmp/codeident"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" 'Every `it.todo` placeholder is replaced with a real assertion.'
assert_lacks "a code identifier is not read as an absence" "[undeclared-absence]" "$(run "$r")"

# ...but the bare word still is.
r="$tmp/bareword"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "TODO"
assert_has "the bare placeholder is still caught" "[undeclared-absence]" "$(run "$r")"

# --- conditional fields ---------------------------------------------------------------
r="$tmp/gate-missing"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "blocked" "" "The thing is finished."
assert_has "blocked without a gate is reported" "[conditional-field]" "$(run "$r")"

r="$tmp/gate-stray"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "gate: waiting on nothing" "The thing is finished."
assert_has "a stray gate is reported" "[conditional-field]" "$(run "$r")"

# The two rules the contract stated and the lint did not enforce, found by the second migration.
# A stray BLANK conditional field is the case the checks above structurally cannot see: an empty
# value is falsy, so every check that asked "is it set?" said no.
r="$tmp/blankgate"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "gate:" "The thing is measurably finished."
out=$(run "$r")
assert_has "a present-but-EMPTY key is reported" "[empty-field]" "$out"
assert_lacks "and it is not miscategorised as a stray value" "must not carry a 'gate'" "$out"

# A '#' in an unquoted list value starts a YAML comment, so the value truncates silently. The
# frontmatter parser skips list items by design, which is why this check reads the raw block.
# The false positive this check shipped with for ten minutes: a key whose value is a BLOCK list
# on the following lines reads as empty when the key line is looked at alone. That is correct YAML
# and is what the contract's own template shows, so every real register tripped it.
r="$tmp/blockvalue"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "artifacts:
  - repo:somewhere" "The thing is measurably finished."
assert_lacks "a key with a BLOCK value is not empty" "[empty-field]" "$(run "$r")"

# The rule is about the SEPARATOR, not the character. Verified against a real YAML parser
# rather than from memory: `- roadmap:#42` loads as the literal string 'roadmap:#42' and is
# perfectly safe, while `- roadmap: #42` loads as {'roadmap': None}. A check that flagged the
# first was reporting a defect that does not exist -- and the cost of that is an author quoting
# things to satisfy a lint, which is the same failure the absence heuristic was corrected for.
r="$tmp/hashartifact"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "artifacts:
  - roadmap: #42" "The thing is measurably finished."
assert_has "an unquoted # after a space in a list value is reported" "[yaml-truncation]" "$(run "$r")"

r="$tmp/hashnospace"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "artifacts:
  - roadmap:#42" "The thing is measurably finished."
assert_lacks "a # with no space before it is NOT reported" "[yaml-truncation]" "$(run "$r")"

r="$tmp/hashquoted"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "artifacts:
  - 'roadmap: #42'" "The thing is measurably finished."
assert_lacks "a QUOTED # is accepted" "[yaml-truncation]" "$(run "$r")"

# The case this check was extended for: a SCALAR field, where the file stays intact and valid
# and the loss shows up only in whatever reads the value. Two real gate: fields truncated this
# way and every entry check passed on them.
r="$tmp/hashscalar"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "held" "gate: shakedown of the spare boxes (2012 minis / #6 PC) proves viable" "The thing is measurably finished."
assert_has "an unquoted # in a SCALAR value is reported" "[yaml-truncation]" "$(run "$r")"

r="$tmp/hashscalarquoted"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "held" "gate: 'shakedown of the spare boxes (2012 minis / #6 PC) proves viable'" "The thing is measurably finished."
assert_lacks "a QUOTED scalar # is accepted" "[yaml-truncation]" "$(run "$r")"

r="$tmp/hashcomment"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "# a real comment line is not a value" "The thing is measurably finished."
assert_lacks "a comment LINE is not reported as a truncated value" "[yaml-truncation]" "$(run "$r")"

# --- values a real YAML parser rejects outright -----------------------------------------
# Found by a consumer that read a store with a strict parser: four titles passed this lint and
# failed the parse, three opening with a backtick and one containing ': '.
r="$tmp/yamlbacktick"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "held" 'gate: `parseToSrgb` stops clamping' "The thing is measurably finished."
assert_has "a value opening with a backtick is reported" "[yaml-invalid]" "$(run "$r")"

r="$tmp/yamlcolon"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "held" "gate: variance: investigate, then re-ratchet" "The thing is measurably finished."
assert_has "a value containing ': ' is reported" "[yaml-invalid]" "$(run "$r")"

r="$tmp/yamlat"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "artifacts:
  - @scope/package review" "The thing is measurably finished."
assert_has "a LIST value opening with a reserved indicator is reported" "[yaml-invalid]" "$(run "$r")"

r="$tmp/yamlquoted"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "held" "gate: '\`parseToSrgb\` stops clamping: then decide'" "The thing is measurably finished."
assert_lacks "a QUOTED value with both is accepted" "[yaml-invalid]" "$(run "$r")"

r="$tmp/yamlurl"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "held" "gate: the release at 12:30 on https://example.invalid/x lands" "The thing is measurably finished."
assert_lacks "a colon with no space after it is NOT reported" "[yaml-invalid]" "$(run "$r")"


# --- artifact pointers: path-shaped ones must resolve ---------------------------------
# The repository root is found by walking up to `.git`, so these fixtures create one. Without
# it the check is SKIPPED rather than run against a guessed root -- the last case asserts that,
# because a check that silently resolves paths against the wrong base would report every
# pointer in a register as broken.
r="$tmp/repo/docs/register"; mkdir -p "$r/closed" "$tmp/repo/.git" "$tmp/repo/docs/adr"
: > "$tmp/repo/docs/adr/0001-a-decision.md"
entry "$r" "ABC-01" "active" "artifacts:
  - adr:docs/adr/0001-a-decision.md" "The thing is measurably finished."
assert_lacks "a resolving artifact path is accepted" "[artifact-path]" "$(run "$r")"

entry "$r" "ABC-01" "active" "artifacts:
  - adr:docs/adr/9999-not-here.md" "The thing is measurably finished."
assert_has "a path-shaped artifact that does not resolve is reported" "[artifact-path]" "$(run "$r")"

entry "$r" "ABC-01" "active" "artifacts:
  - skill:register-standard" "The thing is measurably finished."
assert_lacks "a bare token artifact is not treated as a path" "[artifact-path]" "$(run "$r")"

r2="$tmp/norepo/docs/register"; mkdir -p "$r2/closed"
entry "$r2" "ABC-01" "active" "artifacts:
  - adr:docs/adr/9999-not-here.md" "The thing is measurably finished."
assert_lacks "outside a repository the path check is SKIPPED, not failed" "[artifact-path]" "$(run "$r2")"

# --- staleness: advisory, and it never blocks -----------------------------------------
run_at() { python3 "$lint" "$1" --quiet --today "$2" 2>&1 || true; }

r="$tmp/stale"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "The thing is measurably finished." "2026-01-01"
assert_has "an active entry past its budget is reported" "[stale-entry]" "$(run_at "$r" 2026-09-22)"
python3 "$lint" "$r" --quiet --today 2026-09-22 >/dev/null 2>&1 \
  && ok "a stale entry does NOT block" || bad "a stale entry does NOT block"

entry "$r" "ABC-01" "active" "" "The thing is measurably finished." "2026-09-15"
assert_lacks "an active entry inside its budget is not reported" "[stale-entry]" "$(run_at "$r" 2026-09-22)"

entry "$r" "ABC-01" "idea" "" "NONE REQUIRED" "2024-01-01"
assert_lacks "an idea is exempt from staleness however old" "[stale-entry]" "$(run_at "$r" 2026-09-22)"

entry "$r" "ABC-01" "active" "" "The thing is measurably finished." "2027-01-01"
assert_has "a verified date in the FUTURE is reported" "[stale-entry]" "$(run_at "$r" 2026-09-22)"

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

r="$tmp/widths"; mkdir -p "$r/closed"
entry "$r" "ABC-0001" "active" "" "The thing is finished."
entry "$r/closed" "ABC-12" "done" "closed: $(date +%Y-%m-%d)" "The thing is finished."
out=$(run "$r")
assert_has "mixed id widths are reported" "mixed width" "$out"
assert_has "mixed width names the odd one out" "ABC-12" "$out"
r="$tmp/onewidth"; mkdir -p "$r/closed"
entry "$r" "ABC-01" "active" "" "The thing is finished."
entry "$r" "ABC-02" "active" "" "The thing is finished."
assert_lacks "a register of one (short) width is not reported" "mixed width" "$(run "$r")"

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
