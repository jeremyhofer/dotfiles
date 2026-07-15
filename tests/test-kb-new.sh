#!/bin/sh
# Test: `kb new <type> <slug>` scaffolds a record with complete, valid frontmatter
# (correct-by-construction): all schema keys present, name == slug, type set, `updated`
# stamped from KB_DATE (injected for determinism). Invalid type -> exit 2; existing slug
# -> non-zero. A `<root>/.templates/<type>.md` override, if present, is honored.
# Run directly: `sh tests/test-kb-new.sh`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }
kb() { sh "$KB" "$@"; }

d=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d"' EXIT

KB_ROOT="$d" KB_DATE=2026-07-15 kb new context sample-fact >/dev/null
f="$d/context/sample-fact.md"
[ -f "$f" ] || { echo "FAIL: record file not created at $f"; exit 1; }
echo "ok:   kb new creates <root>/context/sample-fact.md"

for k in name: description: type: sensitivity: tier: status: related: depends-on: supersedes: updated:; do
  grep -q "^$k" "$f" || { echo "FAIL: scaffolded record missing key '$k'"; exit 1; }
done
echo "ok:   all schema keys present"

grep -q '^name: sample-fact$'    "$f" || { echo "FAIL: name != slug"; exit 1; }
grep -q '^type: context$'        "$f" || { echo "FAIL: type not set to context"; exit 1; }
grep -q '^status: draft$'        "$f" || { echo "FAIL: status not draft"; exit 1; }
grep -q '^updated: 2026-07-15$'  "$f" || { echo "FAIL: updated not stamped from KB_DATE"; exit 1; }
echo "ok:   name/type/status/updated correct"

# invalid type -> exit 2
KB_ROOT="$d" kb new bogus x >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 2 ] || { echo "FAIL: invalid type should exit 2, got ${rc:-0}"; exit 1; }
echo "ok:   invalid type exits 2"

# existing slug -> non-zero (no clobber)
KB_ROOT="$d" KB_DATE=2026-07-15 kb new context sample-fact >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: re-creating an existing slug should fail"; exit 1; }
echo "ok:   existing slug refused"

# instance template override honored
mkdir -p "$d/.templates"
printf '%s\n' '---' 'name: __NAME__' 'type: __TYPE__' 'sensitivity: internal' 'tier: 0' \
  'status: draft' 'updated: __UPDATED__' 'custom-marker: yes' '---' > "$d/.templates/standard.md"
KB_ROOT="$d" KB_DATE=2026-07-15 kb new standard my-std >/dev/null
s="$d/standards/my-std.md"
grep -q '^custom-marker: yes$' "$s" || { echo "FAIL: instance template override not used"; exit 1; }
grep -q '^name: my-std$'       "$s" || { echo "FAIL: override token __NAME__ not substituted"; exit 1; }
grep -q '^updated: 2026-07-15$' "$s" || { echo "FAIL: override token __UPDATED__ not substituted"; exit 1; }
echo "ok:   instance template override honored + tokens substituted"

echo "PASS"
