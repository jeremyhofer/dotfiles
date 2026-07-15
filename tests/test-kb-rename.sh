#!/bin/sh
# Test: `kb rename <A> <C>` renames the file + `name` and rewrites EVERY inbound forward
# edge A->C across the KB (no dangling), and `kb retire <A>` sets status:retired and
# removes inbound edges, reporting affected files. Both keep the KB lint-clean and
# regenerate the index. Run: `sh tests/test-kb-rename.sh`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }
kb() { sh "$KB" "$@"; }

# --- rename ---
d=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d"' EXIT
mk() { KB_ROOT="$d" KB_DATE=2026-07-15 kb new context "$1" >/dev/null; }
mk a; mk b
KB_ROOT="$d" kb link a --depends-on b

KB_ROOT="$d" kb rename b bee || { echo "FAIL: rename errored"; exit 1; }
[ -f "$d/context/bee.md" ] || { echo "FAIL: file not renamed to bee.md"; exit 1; }
[ -f "$d/context/b.md" ]   && { echo "FAIL: old file b.md still present"; exit 1; }
grep -q '^name: bee$' "$d/context/bee.md" || { echo "FAIL: name field not updated to bee"; exit 1; }
grep -q '^depends-on: \[bee\]' "$d/context/a.md" || { echo "FAIL: inbound edge not rewritten to bee"; exit 1; }
KB_ROOT="$d" kb lint >/dev/null 2>&1 || { echo "FAIL: KB should lint clean after rename"; exit 1; }
echo "ok:   rename moves file, updates name, rewrites inbound edges, lint clean"

# rename regenerates the index (backlinks now reference bee, not b)
grep -q '^## bee$' "$d/index/backlinks.md" || { echo "FAIL: index not regenerated for bee"; exit 1; }
grep -q '^## b$'   "$d/index/backlinks.md" && { echo "FAIL: stale backlink for old name b"; exit 1; }
echo "ok:   rename regenerates the index"

# rename onto an existing name -> refused
mk c
KB_ROOT="$d" kb rename c bee >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: rename onto existing name should fail"; exit 1; }
# missing source -> refused
KB_ROOT="$d" kb rename ghost x >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: rename of missing source should fail"; exit 1; }
echo "ok:   rename guards collisions and missing source"

# --- retire ---
d2=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d" "$d2"' EXIT
mk2() { KB_ROOT="$d2" KB_DATE=2026-07-15 kb new context "$1" >/dev/null; }
mk2 a; mk2 b
KB_ROOT="$d2" kb link a --depends-on b

KB_ROOT="$d2" kb retire b 2>"$d2/report" || { echo "FAIL: retire errored"; exit 1; }
grep -q '^status: retired$' "$d2/context/b.md" || { echo "FAIL: status not set to retired"; exit 1; }
grep -q '^depends-on: \[\]$' "$d2/context/a.md" || { echo "FAIL: inbound edge to retired record not removed"; exit 1; }
KB_ROOT="$d2" kb lint >/dev/null 2>&1 || { echo "FAIL: KB should lint clean after retire"; exit 1; }
echo "ok:   retire sets status, removes inbound edges, lint clean"

# retire reports the affected file (a) on stderr
grep -q 'a\.md' "$d2/report" || { echo "FAIL: retire did not report the affected file on stderr"; exit 1; }
echo "ok:   retire reports affected files"

# missing source -> refused
KB_ROOT="$d2" kb retire ghost >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: retire of missing source should fail"; exit 1; }
echo "ok:   retire guards missing source"

echo "PASS"
