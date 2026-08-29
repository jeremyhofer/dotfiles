#!/bin/sh
# Test: `portability-lint` flags GNU-only shell spellings and, just as importantly, does NOT
# flag correct code.
#
# THE ASSERTIONS THAT MATTER MOST ARE THE NEGATIVE ONES. A linter is only used if it is
# trusted, and it stops being trusted the first time it rejects the right answer. Two
# false-positive classes were found by running the tool against real repos BEFORE shipping
# it, and both are pinned here:
#   - the flag-run bug: `$(date +%Y%m%d) ... $(cut -d' ' ...)` matched date-d, because the
#     pattern let `date` reach across the line into cut's unrelated -d.
#   - the multi-line two-spelling idiom: a GNU attempt on one line with the BSD `date -j -f`
#     fallback in a loop below it is CORRECT code, and was flagged when only the matching
#     line was searched for a counterpart.
#
# Run: `sh tests/test-portability-lint.sh`
#
# portability-lint: disable-file
#
# This file is FULL of deliberately-bad spellings -- they are the fixtures. Note the fix is
# the file-level escape hatch and NOT teaching the linter to skip heredoc bodies: heredocs
# elsewhere in this repo carry code that really does execute (the git hooks written by the
# run_onchange installer), and skipping them would blind the check to exactly that case.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
LINT="$here/../private_dot_local/bin/executable_portability-lint"
[ -f "$LINT" ] || { echo "FAIL: base does not ship portability-lint"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
lint() { python3 "$LINT" "$@"; }

t=${TMPDIR:-/tmp}; t=${t%/}
d=$(mktemp -d "$t/pl.XXXXXX"); trap 'rm -rf "$d"' EXIT

# ---------- every rule fires, one finding each ----------
cat > "$d/dirty.sh" <<'SH'
#!/bin/sh
sed -i 's/a/b/' f
printf '%s' "$x" | sed 's/[ \t]*$//'
stat -c %Y "$f"
date -d @1 +%F
base64 -w0 f
grep -P 'x' f
find . -printf '%p\n'
timeout 5 sleep 1
d=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")
n="$(refs | wc -l)"
SH
lint "$d/dirty.sh" >"$d/out" 2>&1 && { echo "FAIL: dirty fixture should exit 1"; exit 1; }
n=$(grep -c ':[0-9]*: \[' "$d/out" || true)
[ "$n" -eq 10 ] || { echo "FAIL: expected 10 findings, got $n"; cat "$d/out"; exit 1; }
for r in sed-in-place sed-bracket-tab stat-c date-d base64-w grep-P find-printf timeout tmpdir-slash wc-l-quoted; do
  grep -q "\[$r\]" "$d/out" || { echo "FAIL: rule '$r' did not fire"; exit 1; }
done
echo "ok:   all 10 rules fire, one finding each"

# ---------- correct code is silent ----------
cat > "$d/clean.sh" <<'SH'
#!/bin/sh
sed 's/a/b/' f > f.tmp && mv f.tmp f
printf '%s' "$x" | sed 's/[[:blank:]]*$//'
readlink -f "$f"
printf '%s\n' "$a" | xargs -r echo
t=${TMPDIR:-/tmp}; t=${t%/}; d=$(mktemp -d "$t/x.XXXXXX")
n=$(refs | wc -l)
awk 'BEGIN{ if (x ~ /[ \t]/) print }'
SH
lint "$d/clean.sh" >"$d/out" 2>&1 || { echo "FAIL: clean fixture flagged:"; cat "$d/out"; exit 1; }
echo "ok:   correct code produces no findings"
echo "ok:   readlink -f and xargs -r are NOT flagged (both work on modern macOS)"
echo "ok:   awk with [ \\t] is NOT flagged (awk handles the escape; only sed/grep do not)"

# ---------- the two-spelling idiom is the FIX and must never be a finding ----------
cat > "$d/idioms.sh" <<'SH'
#!/bin/sh
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
fmt_epoch()  { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null; }
b64()        { base64 -w0 "$1" 2>/dev/null || base64 "$1" 2>/dev/null; }
pgrep_re()   { grep -P "$1" "$2" 2>/dev/null || grep -E "$1" "$2"; }
SH
lint "$d/idioms.sh" >"$d/out" 2>&1 || { echo "FAIL: two-spelling idioms flagged:"; cat "$d/out"; exit 1; }
echo "ok:   same-line two-spelling idioms are exempt"

# ---------- REGRESSION: multi-line two-spelling idiom ----------
cat > "$d/multiline.sh" <<'SH'
#!/bin/sh
parse_time() {
  at="$1"
  date -d "$at" +%s 2>/dev/null && return 0
  for f in '%Y-%m-%dT%H:%M:%S' '%Y-%m-%d'; do
    date -j -f "$f" "$at" +%s 2>/dev/null && return 0
  done
  return 1
}
SH
lint "$d/multiline.sh" >"$d/out" 2>&1 || { echo "FAIL: multi-line two-spelling idiom flagged:"; cat "$d/out"; exit 1; }
echo "ok:   REGRESSION multi-line two-spelling idiom is exempt"

# ---------- REGRESSION: a flag belonging to a DIFFERENT command on the same line ----------
cat > "$d/flagrun.sh" <<'SH'
#!/bin/sh
echo "$(date +%Y%m%d) $(cut -d' ' -f1-2 < "$f")"
printf '%s' "$(date +%s)" | cut -c 1-4
SH
lint "$d/flagrun.sh" >"$d/out" 2>&1 || { echo "FAIL: cut's -d was attributed to date:"; cat "$d/out"; exit 1; }
echo "ok:   REGRESSION a later command's flag is not attributed to an earlier one"

# ---------- suppression ----------
cat > "$d/sup.sh" <<'SH'
#!/bin/sh
stat -c %Y "$f"   # portability-lint: ignore stat-c
date -d @1 +%F    # portability-lint: ignore
grep -P 'x' f     # portability-lint: ignore stat-c
SH
lint "$d/sup.sh" >"$d/out" 2>&1 && { echo "FAIL: sup fixture should still exit 1 (grep-P)"; exit 1; }
n=$(grep -c ':[0-9]*: \[' "$d/out" || true)
[ "$n" -eq 1 ] || { echo "FAIL: expected exactly 1 unsuppressed finding, got $n"; cat "$d/out"; exit 1; }
grep -q '\[grep-P\]' "$d/out" || { echo "FAIL: naming the WRONG rule must not suppress"; exit 1; }
echo "ok:   suppression is per-rule; naming the wrong rule does not suppress"

# a comment line cannot execute, so it is not a finding
printf '#!/bin/sh\n# stat -c %%Y f\n' > "$d/comment.sh"
lint "$d/comment.sh" >/dev/null 2>&1 || { echo "FAIL: a commented-out GNU-ism was flagged"; exit 1; }
echo "ok:   commented-out code is not flagged"

# ---------- the base's own shipped tools are clean of ERRORS ----------
# Warnings are not gated yet: the ${TMPDIR:-/tmp} idiom is still present in many files and is
# latent rather than broken. Errors are gated, because every one of them is a real break.
lint --errors-only "$here/../private_dot_local/bin" "$here/../setup" >"$d/out" 2>&1 \
  || { echo "FAIL: the base's own shipped tools have portability ERRORS:"; cat "$d/out"; exit 1; }
echo "ok:   the base's shipped tools are free of portability errors"

echo "PASS"
