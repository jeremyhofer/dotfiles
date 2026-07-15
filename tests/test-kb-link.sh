#!/bin/sh
# Test: `kb link <A> --<edge> <B>` writes ONE forward edge into A's frontmatter, validates
# that B exists, is idempotent (no duplicate edge), extends a list with a second target,
# and never touches B (reverse is generated, not authored). Run: `sh tests/test-kb-link.sh`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }
kb() { sh "$KB" "$@"; }

d=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d"' EXIT
mk() { KB_ROOT="$d" KB_DATE=2026-07-15 kb new context "$1" >/dev/null; }
mk a; mk b; mk c

# valid forward edge written to A only
KB_ROOT="$d" kb link a --depends-on b || { echo "FAIL: valid link failed"; exit 1; }
grep -q '^depends-on: \[b\]' "$d/context/a.md" || { echo "FAIL: edge not written to A"; exit 1; }
echo "ok:   forward edge written to A"

# reverse must NOT be written to B (B's depends-on stays empty)
grep -q '^depends-on: \[a\]' "$d/context/b.md" && { echo "FAIL: reverse edge written to B"; exit 1; }
grep -q '^depends-on: \[\]' "$d/context/b.md" || { echo "FAIL: B's frontmatter was modified"; exit 1; }
echo "ok:   B untouched (forward-only)"

# idempotent: linking the same edge again does not duplicate
KB_ROOT="$d" kb link a --depends-on b || { echo "FAIL: idempotent re-link errored"; exit 1; }
grep -q '^depends-on: \[b\]$' "$d/context/a.md" || { echo "FAIL: re-link duplicated the edge"; exit 1; }
echo "ok:   idempotent (no duplicate edge)"

# extend the list with a second target
KB_ROOT="$d" kb link a --depends-on c || { echo "FAIL: second link failed"; exit 1; }
grep -q '^depends-on: \[b, c\]$' "$d/context/a.md" || { echo "FAIL: second target not appended (expected [b, c])"; exit 1; }
echo "ok:   second target appended"

# a different edge type is independent
KB_ROOT="$d" kb link a --related b || { echo "FAIL: related link failed"; exit 1; }
grep -q '^related: \[b\]$'       "$d/context/a.md" || { echo "FAIL: related edge not written"; exit 1; }
grep -q '^depends-on: \[b, c\]$' "$d/context/a.md" || { echo "FAIL: related link disturbed depends-on"; exit 1; }
echo "ok:   edge types independent"

# missing target -> exit 1
KB_ROOT="$d" kb link a --depends-on ghost >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: missing target should exit 1, got ${rc:-0}"; exit 1; }
echo "ok:   missing target refused"

# missing source -> exit 1
KB_ROOT="$d" kb link ghost --related b >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: missing source should exit 1, got ${rc:-0}"; exit 1; }
echo "ok:   missing source refused"

# bad edge flag -> exit 2
KB_ROOT="$d" kb link a --bogus b >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 2 ] || { echo "FAIL: bad edge flag should exit 2, got ${rc:-0}"; exit 1; }
echo "ok:   bad edge flag rejected"

# KB stays lint-clean after linking
KB_ROOT="$d" kb lint >/dev/null 2>&1 || { echo "FAIL: KB should lint clean after links"; exit 1; }
echo "ok:   lint clean after links"

echo "PASS"
