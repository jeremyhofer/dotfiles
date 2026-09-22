#!/bin/sh
# Tests for adr-lint. Every case PLANTS a defect and asserts the tool reports it, or plants the
# NEAR-MISS and asserts it does not.
#
# The near-misses matter as much as the plants here, and two of them were written after this
# tool reported a correct index as drifted on its first real run: an index title containing an
# escaped pipe, and an index qualifying a status ("Resolved (Phase 4.5c)"). A gate that
# manufactures defects gets worked around, and the working-around is silent.
#
# GRANULARITY: every fixture below is a VALID record with ONE planted change. A gate seen to
# reject a wholly malformed record is not thereby known to reject one bad field in a good one,
# and the second is the case that occurs.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
lint="$here/../private_dot_local/bin/executable_adr-lint"
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok:   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
assert_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (expected: $2)" ;; esac; }
assert_lacks() { case "$3" in *"$2"*) bad "$1 (did NOT expect: $2)" ;; *) ok "$1" ;; esac; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A valid BULLET-header record. $1 dir  $2 number  $3 status  $4 header blockquote
#
# $4 lands in the BLOCKQUOTE between the header bullets and the first section, which is where a
# real record carries its "Tracked by" declaration. An earlier version of this fixture put it in
# `## Context` instead, so every tracking case was exercising prose the rule deliberately
# ignores -- the fixture passed and proved nothing about the rule.
bullet() {
  mkdir -p "$1"
  { echo "# ADR-$2: A decision"
    echo "- **Status:** $3"
    echo "- **Date:** 2026-09-22"
    echo "- **Deciders:** Jeremy"
    echo "- **Tags:** test"
    echo ""
    [ -n "${4:-}" ] && { echo "> $4"; echo ""; }
    echo "## Context"
    echo "Something had to be chosen."
  } > "$1/$2-a-decision.md"
}
# A valid FRONTMATTER record. $1 dir  $2 number  $3 status
front() {
  mkdir -p "$1"
  { echo "---"; echo "id: ABC-ADR-$2"; echo "title: A decision"
    echo "status: $3"; echo "date: 2026-09-22"; echo "---"
    echo ""; echo "## Context"; echo "Something had to be chosen."
  } > "$1/ABC-ADR-$2-a-decision.md"
}
index() { printf '| ADR | Title | Status |\n| --- | --- | --- |\n%s\n' "$2" > "$1/README.md"; }
run() { python3 "$lint" "$@" --quiet 2>&1 || true; }

# --- control: without this, every "reports X" case is satisfiable by a tool that always does
r="$tmp/clean"; bullet "$r" 0001 Accepted
assert_lacks "a valid record is clean" "[" "$(run "$r")"
python3 "$lint" "$r" --quiet >/dev/null 2>&1 && ok "valid record exits 0" || bad "valid record exits 0"

# --- schema
r="$tmp/nodate"; bullet "$r" 0001 Accepted; sed -i '/Date:/d' "$r/0001-a-decision.md"
assert_has "a missing header field is reported" "[schema]" "$(run "$r")"
r="$tmp/noh1"; bullet "$r" 0001 Accepted; sed -i '1d' "$r/0001-a-decision.md"
assert_has "a missing H1 is reported" "[schema]" "$(run "$r")"
r="$tmp/frontnostatus"; front "$r" 0001 Accepted; sed -i '/^status:/d' "$r/ABC-ADR-0001-a-decision.md"
assert_lacks "a frontmatter doc with no status is not read as a record at all" "[schema]" "$(run "$r")"

# --- id integrity and filename
r="$tmp/dupe"; bullet "$r" 0001 Accepted; cp "$r/0001-a-decision.md" "$r/0001-another.md"
assert_has "two records sharing a number are reported" "[id-integrity]" "$(run "$r")"
r="$tmp/mismatch"; front "$r" 0001 Accepted
mv "$r/ABC-ADR-0001-a-decision.md" "$r/ABC-ADR-0009-a-decision.md"
assert_has "a filename number disagreeing with the record is reported" "[filename]" "$(run "$r")"

# --- the index
r="$tmp/notindexed"; bullet "$r" 0001 Accepted; index "$r" "| [0002](0002-other.md) | Other | Accepted |"
assert_has "a record missing from the index is reported" "[index]" "$(run "$r")"
r="$tmp/idxstatus"; bullet "$r" 0001 Accepted
index "$r" "| [0001](0001-a-decision.md) | A decision | Proposed |"
assert_has "an index disagreeing with the record is reported" "[index-status]" "$(run "$r")"
r="$tmp/idxqual"; bullet "$r" 0001 Resolved
index "$r" "| [0001](0001-a-decision.md) | A decision | Resolved (Phase 4.5c, 2026-06-12) |"
assert_lacks "an index QUALIFYING a status is not drift" "[index-status]" "$(run "$r")"
# An escaped pipe in a title breaks a naive split and made this tool report a correct index as
# drifted on its first real run against the fleet.
r="$tmp/idxpipe"; bullet "$r" 0001 Accepted
index "$r" "| [0001](0001-a-decision.md) | A decision about RUSS\\| and pipes | Accepted |"
assert_lacks "an escaped pipe in an index title is not drift" "[index-status]" "$(run "$r")"
# The status column is found by HEADER, not position: two repos have different column counts.
r="$tmp/idx4col"; bullet "$r" 0001 Accepted
printf '| ADR | Title | Status | Date |\n| --- | --- | --- | --- |\n| [0001](0001-a-decision.md) | A decision | Accepted | 2026-09-22 |\n' > "$r/README.md"
assert_lacks "a four-column index is read by header, not position" "[index-status]" "$(run "$r")"

# --- advisories never block
r="$tmp/vocab"; bullet "$r" 0001 Wibble
assert_has "a status outside the vocabulary is reported" "[status-vocabulary]" "$(run "$r")"
python3 "$lint" "$r" --quiet >/dev/null 2>&1 && ok "an odd status does NOT block" || bad "an odd status does NOT block"
r="$tmp/mixed"; bullet "$r" 0001 Accepted; front "$r" 0002 Accepted
assert_has "two header shapes in one directory are reported" "[header-shape]" "$(run "$r")"
python3 "$lint" "$r" --quiet >/dev/null 2>&1 && ok "a shape split does NOT block" || bad "a shape split does NOT block"

# --- the Living contract
r="$tmp/living"; bullet "$r" 0001 Living
assert_has "a Living record with no currency machinery is reported" "[living-contract]" "$(run "$r")"
python3 "$lint" "$r" --quiet >/dev/null 2>&1 && ok "a Living gap does NOT block" || bad "a Living gap does NOT block"

# --- tracking reciprocity, and the failure that started all this
reg="$tmp/reg/docs/register"; mkdir -p "$reg/closed"
{ echo "---"; echo "id: ABC-01"; echo "title: t"; echo "status: active"; echo "owner: j"
  echo "verified: 2026-09-22"; echo "artifacts:"; echo "  - adr:ABC-ADR-0079"; echo "---"
} > "$reg/ABC-01-t.md"
r="$tmp/track"; bullet "$r" 0079 Accepted "Tracked by ABC-01 (the thing)."
assert_lacks "a reciprocal citation is accepted" "[tracking" "$(run "$r" --register "$reg")"
r="$tmp/trackdrift"; bullet "$r" 0080 Accepted "Tracked by ABC-01 (the thing)."
assert_has "a one-way tracking link is reported" "[tracking-drift]" "$(run "$r" --register "$reg")"
r="$tmp/tracknoent"; bullet "$r" 0079 Accepted "Tracked by ABC-99 (nobody)."
assert_has "naming an entry that does not exist is reported" "[tracking-drift]" "$(run "$r" --register "$reg")"
# The failure this tool was rebuilt after: the register moved and the check went dark. It must
# say UNVERIFIED rather than pass, because a silent pass is indistinguishable from a real one.
r="$tmp/tracknoreg"; bullet "$r" 0079 Accepted "Tracked by ABC-01 (the thing)."
assert_has "an unreadable register reports UNVERIFIED, not clean" "UNVERIFIED" "$(run "$r" --register "$tmp/gone")"

# --- the wrap, and it is the common case rather than an edge.
# A real header reads "... Tracked by\n> ABC-01 (what it owns)". A pattern needing the id on the
# same line matched NOTHING across a live 78-record corpus while the run reported zero blocking.
r="$tmp/trackwrap"; mkdir -p "$r"
{ echo "# ADR-0080: A decision"
  echo "- **Status:** Accepted"; echo "- **Date:** 2026-09-22"
  echo "- **Deciders:** Jeremy"; echo "- **Tags:** test"; echo ""
  echo "> **What this decides.** Something, and it is Tracked by"
  echo "> ABC-01 (the thing it owns)."; echo ""
  echo "## Context"; echo "Something had to be chosen."
} > "$r/0080-a-decision.md"
assert_has "a WRAPPED tracking declaration is still read" "[tracking-drift]" "$(run "$r" --register "$reg")"

# Two entries in one sentence are legitimate, and EACH is checked.
r="$tmp/tracktwo"; bullet "$r" 0080 Accepted "Tracked by ABC-01 (the standard) and ABC-02 (the rollout)."
out=$(run "$r" --register "$reg")
assert_has "the first of two named entries is checked" "ABC-01" "$out"
assert_has "the second of two named entries is checked" "ABC-02" "$out"

# An id in the NEXT sentence names related work, not a tracker.
r="$tmp/tracknext"; bullet "$r" 0079 Accepted "Tracked by ABC-01 (the thing). See also ABC-99 for context."
assert_lacks "an id in the next sentence is not read as a tracker" "ABC-99" "$(run "$r" --register "$reg")"

# A declaration naming nothing at all is a finding in its own right.
r="$tmp/tracknone"; bullet "$r" 0079 Accepted "Tracked by the usual people."
assert_has "a Tracked by naming no entry is reported" "names no entry" "$(run "$r" --register "$reg")"

# --- the OTHER direction of the tracking link: an entry citing a record that does not exist.
# tracking-drift catches a record pointing at nothing; this catches an entry pointing at
# nothing. Same defect from opposite ends, and only a tool holding both directories sees either.
reg2="$tmp/reg2/docs/register"; mkdir -p "$reg2/closed"
{ echo "---"; echo "id: ABC-02"; echo "title: t"; echo "status: active"; echo "owner: j"
  echo "verified: 2026-09-22"; echo "artifacts:"; echo "  - adr:ABC-ADR-9999"; echo "---"
} > "$reg2/ABC-02-t.md"
r="$tmp/artrec"; bullet "$r" 0001 Accepted
assert_has "an entry citing a record that does not exist is reported" "[artifact-record]" "$(run "$r" --register "$reg2")"

{ echo "---"; echo "id: ABC-03"; echo "title: t"; echo "status: active"; echo "owner: j"
  echo "verified: 2026-09-22"; echo "artifacts:"; echo "  - adr:ABC-ADR-0001"
  echo "  - spec:docs/specs/something.md"; echo "---"
} > "$reg2/ABC-03-t.md"
out=$(run "$r" --register "$reg2")
assert_lacks "an entry citing a record that DOES exist is accepted" "ABC-ADR-0001" "$out"
# A spec or plan pointer resolves as a PATH from the repository root, which is a rule for
# whatever checks the register -- this tool is handed only the decision directory and must not
# pretend to judge it.
assert_lacks "a non-adr artifact pointer is not judged here" "docs/specs/something.md" "$out"

# --- a directory with nothing readable is NOT reported as clean
r="$tmp/empty"; mkdir -p "$r"; echo "# just a note" > "$r/notes.md"
assert_has "a directory with no readable records says so" "not the same as clean" "$(python3 "$lint" "$r" 2>&1)"

# --- --strict: the same findings, promoted. A repo that has adopted the vocabulary gates on it.
r="$tmp/strict"; bullet "$r" 0001 Wibble
python3 "$lint" "$r" --quiet >/dev/null 2>&1 && ok "an odd status is advisory by default" || bad "an odd status is advisory by default"
python3 "$lint" "$r" --quiet --strict >/dev/null 2>&1 && bad "--strict BLOCKS an odd status" || ok "--strict BLOCKS an odd status"
r="$tmp/strictclean"; bullet "$r" 0001 Accepted
python3 "$lint" "$r" --quiet --strict >/dev/null 2>&1 && ok "--strict still passes a valid record" || bad "--strict still passes a valid record"


echo ""
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
