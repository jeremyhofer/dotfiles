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

# --- kb index --check -------------------------------------------------------------------
# The freshness gate. It must be green on a just-generated index, and must go red on the
# SHAPES that actually drifted -- a single changed description (sources-of-truth) and a
# single added edge (backlinks) -- naming the right file each time. A check that only
# fires on a wholly missing index would not establish that it discriminates one stale line,
# which is the claim the pre-commit hook rests on.
KB_ROOT="$d" kb index --check >/dev/null 2>&1 \
  || { echo "FAIL: --check red on a freshly generated index"; exit 1; }
echo "ok:   --check green when the index is current"

# --check must not WRITE anything, or it would launder drift instead of reporting it
cp "$bl" "$d/bl.2"; cp "$sot" "$d/sot.2"
KB_ROOT="$d" kb index --check >/dev/null 2>&1
cmp -s "$bl" "$d/bl.2"   || { echo "FAIL: --check modified backlinks.md"; exit 1; }
cmp -s "$sot" "$d/sot.2" || { echo "FAIL: --check modified sources-of-truth.md"; exit 1; }
echo "ok:   --check writes nothing"

# PLANT 1: one changed description, no regeneration -> red, naming sources-of-truth.md
fa=$(grep -rl '^name: a$' "$d" | head -1)
cp "$fa" "$d/a.bak"
sed 's/^description:.*/description: "planted drift"/' "$d/a.bak" > "$fa"
out=$(KB_ROOT="$d" kb index --check 2>&1)   && { echo "FAIL: --check green with a stale description"; exit 1; }
printf '%s\n' "$out" | grep -q 'sources-of-truth.md' \
  || { echo "FAIL: --check did not name sources-of-truth.md; got: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'backlinks.md' \
  && { echo "FAIL: --check blamed backlinks.md for a description change"; exit 1; }
echo "ok:   --check red on one stale description, naming sources-of-truth.md only"

cp "$d/a.bak" "$fa"
KB_ROOT="$d" kb index --check >/dev/null 2>&1 \
  || { echo "FAIL: --check still red after reverting the plant"; exit 1; }
echo "ok:   --check green again after revert"

# PLANT 2: one added edge, no regeneration -> red, naming backlinks.md
KB_ROOT="$d" kb link b --related c >/dev/null 2>&1
out=$(KB_ROOT="$d" kb index --check 2>&1)   && { echo "FAIL: --check green with a stale backlinks"; exit 1; }
printf '%s\n' "$out" | grep -q 'backlinks.md' \
  || { echo "FAIL: --check did not name backlinks.md; got: $out"; exit 1; }
echo "ok:   --check red on one added edge, naming backlinks.md"

KB_ROOT="$d" kb index
KB_ROOT="$d" kb index --check >/dev/null 2>&1 \
  || { echo "FAIL: --check red after regenerating"; exit 1; }
echo "ok:   --check green after regeneration"

# --check is STRICT about a never-generated index; --if-present downgrades that to a pass.
# Both halves are asserted, because the whole point of the flag is that the two differ: a
# generic hook needs the tolerant form, and a repo that always publishes wants the strict
# one so a DELETED index still goes red.
d2=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d" "$d2"' EXIT
KB_ROOT="$d2" KB_DATE=2026-07-15 kb new context z >/dev/null
KB_ROOT="$d2" kb index --check >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: strict --check on a never-generated index should exit 1, got ${rc:-0}"; exit 1; }
echo "ok:   --check is red on a never-generated index"

KB_ROOT="$d2" kb index --check --if-present >/dev/null 2>&1 \
  || { echo "FAIL: --if-present should pass on a never-generated index"; exit 1; }
echo "ok:   --check --if-present passes on a never-generated index"

[ ! -e "$d2/index/sources-of-truth.md" ] || { echo "FAIL: --check generated an index"; exit 1; }
echo "ok:   neither form generated anything"

# --if-present is a modifier on --check, not a standalone mode
KB_ROOT="$d2" kb index --if-present >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 2 ] || { echo "FAIL: bare --if-present should be a usage error, got ${rc:-0}"; exit 1; }
echo "ok:   --if-present without --check is a usage error"

# half-generated is drift even under --if-present
KB_ROOT="$d2" kb index >/dev/null
rm "$d2/index/backlinks.md"
KB_ROOT="$d2" kb index --check --if-present >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: half-generated index should be drift even with --if-present, got ${rc:-0}"; exit 1; }
echo "ok:   --if-present still red on a half-generated index"

echo "PASS"
