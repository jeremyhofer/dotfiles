#!/bin/sh
# Test: `kb project` reads the KB's Tier-0 records (tier:0 AND status:active) and emits the
# harness-agnostic active-context artifacts — AGENTS.md base, a Claude @AGENTS.md import stub,
# and GEMINI.md (inlined) — into a --out dir (default a staging dir under index/). Output is
# deterministic/idempotent; --check guards drift without writing. Run: `sh tests/test-kb-project.sh`.
set -eu
# sedi EXPR FILE -- in-place edit, portably. Deliberately NOT the GNU in-place flag: on
# BSD/macOS that form consumes the EXPRESSION as the backup suffix and then treats the file
# as the script, which is silently destructive rather than merely failing. Temp-file + mv
# behaves identically on both userlands.
sedi() { _e=$1; _f=$2; sed "$_e" "$_f" > "$_f.sedi.$$" && mv "$_f.sedi.$$" "$_f"; }

here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }
kb() { sh "$KB" "$@"; }

d=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d"' EXIT
mk() { KB_ROOT="$d" KB_DATE=2026-07-15 kb new "$1" "$2" >/dev/null; }   # type slug
set_field() { sedi "s|^$2:.*|$2: $3|" "$1"; }

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

# --- Task 2: per-harness derivations ---
c="$d/index/projections/CLAUDE.md"; g="$d/index/projections/GEMINI.md"
[ -f "$c" ] && [ -f "$g" ] || { echo "FAIL: CLAUDE.md/GEMINI.md not generated"; exit 1; }
grep -qx '@AGENTS.md' "$c" || { echo "FAIL: CLAUDE.md missing '@AGENTS.md' import"; exit 1; }
grep -qi 'do not edit' "$c" || { echo "FAIL: CLAUDE.md missing do-not-edit banner"; exit 1; }
grep -qi 'claude-only additions' "$c" || { echo "FAIL: CLAUDE.md missing additions section marker"; exit 1; }
grep -q 'Always do the universal thing.' "$g" || { echo "FAIL: GEMINI.md missing tier-0 content"; exit 1; }
grep -q 'some-detail' "$g" && { echo "FAIL: tier-2 leaked into GEMINI.md"; exit 1; }
echo "ok:   CLAUDE.md is a thin @AGENTS import; GEMINI.md inlines tier-0"

# --- Task 3: idempotence + --check drift guard ---
KB_ROOT="$d" kb project >/dev/null
for base in AGENTS.md CLAUDE.md GEMINI.md; do cp "$d/index/projections/$base" "$d/$base.1"; done
KB_ROOT="$d" kb project >/dev/null
for base in AGENTS.md CLAUDE.md GEMINI.md; do
  cmp -s "$d/index/projections/$base" "$d/$base.1" || { echo "FAIL: $base not deterministic"; exit 1; }
done
echo "ok:   projection output is deterministic across runs"

KB_ROOT="$d" kb project --check >/dev/null 2>&1 || { echo "FAIL: --check should pass when in sync"; exit 1; }
printf 'A new universal rule.\n' >> "$d/standards/universal-rule.md"
KB_ROOT="$d" kb project --check >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: --check should exit 1 on drift, got ${rc:-0}"; exit 1; }
KB_ROOT="$d" kb project --check 2>&1 | grep -q 'AGENTS.md' || { echo "FAIL: --check should name the drifted file"; exit 1; }
grep -q 'A new universal rule.' "$d/index/projections/AGENTS.md" && { echo "FAIL: --check must not write outputs"; exit 1; }
echo "ok:   --check guards projection drift without writing"

# ========== additional coverage (isolated KBs) ==========
d2=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d" "$d2"' EXIT
mk2() { KB_ROOT="$d2" KB_DATE=2026-07-15 kb new "$1" "$2" >/dev/null; }
for s in zzz-rule aaa-rule mmm-rule; do
  mk2 standard "$s"
  set_field "$d2/standards/$s.md" tier 0; set_field "$d2/standards/$s.md" status active
  printf 'Body of %s.\n' "$s" >> "$d2/standards/$s.md"
done
mk2 standard priv-rule
set_field "$d2/standards/priv-rule.md" tier 0; set_field "$d2/standards/priv-rule.md" status active
set_field "$d2/standards/priv-rule.md" sensitivity private
printf 'PRIVATE body.\n' >> "$d2/standards/priv-rule.md"

KB_ROOT="$d2" kb project >/dev/null
a2="$d2/index/projections/AGENTS.md"; g2="$d2/index/projections/GEMINI.md"

# sensitivity gate: private tier-0 excluded by default (--max-sensitivity internal)
grep -q 'PRIVATE body.' "$a2" && { echo "FAIL: private tier-0 leaked into default projection"; exit 1; }
grep -q '^## priv-rule$' "$a2" && { echo "FAIL: private tier-0 section leaked"; exit 1; }
echo "ok:   private tier-0 excluded by default"
KB_ROOT="$d2" kb project --max-sensitivity private >/dev/null
grep -q 'PRIVATE body.' "$a2" || { echo "FAIL: --max-sensitivity private should include private"; exit 1; }
echo "ok:   --max-sensitivity private includes private records"
KB_ROOT="$d2" kb project >/dev/null   # restore default ceiling

# deterministic byte-sort by name (not creation order): aaa < mmm < zzz
order=$(grep '^## ' "$a2" | sed 's/^## //' | tr '\n' ' ')
printf '%s' "$order" | grep -q 'aaa-rule mmm-rule zzz-rule' || { echo "FAIL: tier-0 sections not byte-sorted (got: $order)"; exit 1; }
echo "ok:   tier-0 sections byte-sorted by name"

# GEMINI.md byte-identical to AGENTS.md
cmp -s "$a2" "$g2" || { echo "FAIL: GEMINI.md not byte-identical to AGENTS.md"; exit 1; }
echo "ok:   GEMINI.md == AGENTS.md byte-for-byte"

# fresh KB (never projected): --check -> exit 1, names the missing output, writes nothing
d3=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d" "$d2" "$d3"' EXIT
KB_ROOT="$d3" KB_DATE=2026-07-15 kb new standard r >/dev/null
set_field "$d3/standards/r.md" tier 0; set_field "$d3/standards/r.md" status active
KB_ROOT="$d3" kb project --check >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: --check on a never-projected KB should exit 1, got ${rc:-0}"; exit 1; }
KB_ROOT="$d3" kb project --check 2>&1 | grep -q 'AGENTS.md' || { echo "FAIL: --check should name the missing AGENTS.md"; exit 1; }
[ -d "$d3/index/projections" ] && { echo "FAIL: --check must not create the output dir"; exit 1; }
echo "ok:   --check on a fresh KB reports missing outputs without writing"

# --- Provenance is a pointer in the projection, never the full history ---
# A projection is loaded at every session start and per subagent, so history in it is a recurring
# cost forever, so it is kept lean by design. The rule body must survive intact; only the trailing
# `### Provenance` section is replaced by a pointer at the source record.
d4=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d" "$d2" "$d3" "$d4"' EXIT
KB_ROOT="$d4" KB_DATE=2026-07-15 kb new standard prov-rule >/dev/null
set_field "$d4/standards/prov-rule.md" tier 0
set_field "$d4/standards/prov-rule.md" status active
cat >> "$d4/standards/prov-rule.md" <<'BODY'

### The rule

OPERATIVE-RULE-TEXT: always do the thing.

### Provenance

HISTORICAL-DETAIL: adopted 2026-01-01 after a long incident nobody needs at runtime.
BODY
KB_ROOT="$d4" kb project >/dev/null
a4="$d4/index/projections/AGENTS.md"
grep -q 'OPERATIVE-RULE-TEXT' "$a4" || { echo "FAIL: projection dropped the rule body"; exit 1; }
grep -q 'HISTORICAL-DETAIL' "$a4" && { echo "FAIL: projection still carries provenance history"; exit 1; }
grep -q '^### Provenance' "$a4" || { echo "FAIL: projection should keep the Provenance heading as a pointer"; exit 1; }
grep -q 'standards/prov-rule.md' "$a4" || { echo "FAIL: provenance pointer must name the source record"; exit 1; }
echo "ok:   projection keeps the rule, replaces provenance with a pointer to the source"

# The invariant that actually matters: the projection must not grow when history does. Comparing
# a projection against its source record would instead measure the projection's own boilerplate,
# which is why this appends history and re-projects rather than diffing the two artifacts.
before=$(wc -c < "$a4")
i=0; while [ "$i" -lt 100 ]; do
  printf 'MORE-HISTORY line %d, appended to the provenance section.\n' "$i" >> "$d4/standards/prov-rule.md"
  i=$((i+1))
done
KB_ROOT="$d4" kb project >/dev/null
after=$(wc -c < "$a4")
[ "$after" -eq "$before" ] || { echo "FAIL: projection grew with provenance ($before -> $after); history is leaking into the always-on set"; exit 1; }
grep -q 'MORE-HISTORY' "$a4" && { echo "FAIL: appended history reached the projection"; exit 1; }
echo "ok:   projection size is invariant to how much history a record accumulates"

echo "PASS"
