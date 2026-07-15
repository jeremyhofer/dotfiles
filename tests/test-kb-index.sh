#!/bin/sh
# Test: `kb index` regenerates <root>/index/sources-of-truth.md (name -> owning file) and
# <root>/index/backlinks.md (every reverse edge, generated from the forward edges). Output
# is deterministic (sorted, byte-stable across runs). Run: `sh tests/test-kb-index.sh`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }
kb() { sh "$KB" "$@"; }

d=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d"' EXIT
mk() { KB_ROOT="$d" KB_DATE=2026-07-15 kb new context "$1" >/dev/null; }
mk a; mk b; mk c
KB_ROOT="$d" kb link a --depends-on b
KB_ROOT="$d" kb link c --supersedes a
KB_ROOT="$d" kb link a --related c

KB_ROOT="$d" kb index || { echo "FAIL: kb index errored"; exit 1; }

bl="$d/index/backlinks.md"
sot="$d/index/sources-of-truth.md"
[ -f "$bl" ]  || { echo "FAIL: backlinks.md not generated"; exit 1; }
[ -f "$sot" ] || { echo "FAIL: sources-of-truth.md not generated"; exit 1; }
echo "ok:   index files generated"

# reverse edge b <- a (depended-on-by), anchored to the exact generated lines
grep -qx '## b' "$bl"               || { echo "FAIL: backlinks missing '## b' section"; exit 1; }
grep -qx 'depended-on-by: a' "$bl"  || { echo "FAIL: exact reverse edge 'depended-on-by: a' missing"; exit 1; }
echo "ok:   depended-on-by reverse edge present"

# reverse edge a <- c (superseded-by) and a's related-by, anchored
grep -qx '## a' "$bl"               || { echo "FAIL: backlinks missing '## a' section"; exit 1; }
grep -qx 'superseded-by: c' "$bl"   || { echo "FAIL: exact 'superseded-by: c' missing"; exit 1; }
grep -qx 'related-by: a' "$bl"      || { echo "FAIL: exact 'related-by: a' missing (c<-a related)"; exit 1; }
echo "ok:   superseded-by and related-by reverse edges present"

# sources-of-truth lists each record name at line start
grep -q '^a\b' "$sot" || { echo "FAIL: sources-of-truth missing a"; exit 1; }
grep -q '^b\b' "$sot" || { echo "FAIL: sources-of-truth missing b"; exit 1; }
grep -q '^c\b' "$sot" || { echo "FAIL: sources-of-truth missing c"; exit 1; }
echo "ok:   sources-of-truth lists all records"

# deterministic: a second run is byte-identical
cp "$bl" "$d/bl.1"; cp "$sot" "$d/sot.1"
KB_ROOT="$d" kb index
cmp -s "$bl" "$d/bl.1"   || { echo "FAIL: backlinks.md not deterministic"; exit 1; }
cmp -s "$sot" "$d/sot.1" || { echo "FAIL: sources-of-truth.md not deterministic"; exit 1; }
echo "ok:   output is deterministic across runs"

# generated index files are not themselves treated as records (lint stays clean)
KB_ROOT="$d" kb lint >/dev/null 2>&1 || { echo "FAIL: KB should lint clean (index excluded)"; exit 1; }
echo "ok:   index excluded from lint"

echo "PASS"
