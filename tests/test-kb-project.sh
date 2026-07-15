#!/bin/sh
# Test: `kb project` reads the KB's Tier-0 records (tier:0 AND status:active) and emits the
# harness-agnostic active-context artifacts — AGENTS.md base, a Claude @AGENTS.md import stub,
# and GEMINI.md (inlined) — into a --out dir (default a staging dir under index/). Output is
# deterministic/idempotent; --check guards drift without writing. Run: `sh tests/test-kb-project.sh`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }
kb() { sh "$KB" "$@"; }

d=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d"' EXIT
mk() { KB_ROOT="$d" KB_DATE=2026-07-15 kb new "$1" "$2" >/dev/null; }   # type slug
set_field() { sed -i "s|^$2:.*|$2: $3|" "$1"; }

# a Tier-0 active rule, a Tier-2 detail, and a Tier-0-but-draft rule
mk standard universal-rule
mk context  some-detail
mk standard draft-rule
set_field "$d/standards/universal-rule.md" tier 0
set_field "$d/standards/universal-rule.md" status active
printf 'Always do the universal thing.\n' >> "$d/standards/universal-rule.md"
set_field "$d/context/some-detail.md" tier 2
set_field "$d/standards/draft-rule.md" tier 0                 # tier 0 but status stays draft
printf 'Draft-only guidance.\n' >> "$d/standards/draft-rule.md"

# --- Task 1: AGENTS.md base ---
KB_ROOT="$d" kb project >/dev/null
a="$d/index/projections/AGENTS.md"
[ -f "$a" ] || { echo "FAIL: AGENTS.md not generated at $a"; exit 1; }
grep -q '^## universal-rule$' "$a" || { echo "FAIL: tier-0 record not in AGENTS.md"; exit 1; }
grep -q 'Always do the universal thing.' "$a" || { echo "FAIL: tier-0 body not included"; exit 1; }
grep -q 'some-detail' "$a" && { echo "FAIL: tier-2 record leaked into AGENTS.md"; exit 1; }
grep -q 'draft-rule' "$a"  && { echo "FAIL: draft tier-0 record leaked into AGENTS.md"; exit 1; }
grep -qi 'do not edit' "$a" || { echo "FAIL: AGENTS.md missing do-not-edit banner"; exit 1; }
echo "ok:   kb project emits AGENTS.md with only active tier-0 records"

echo "PASS"
