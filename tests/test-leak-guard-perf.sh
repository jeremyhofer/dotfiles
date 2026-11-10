#!/usr/bin/env bash
# run-all: serial
# Test leak-guard's SPEED on a large added file, alone. The bound below is wall-clock, so this suite
# runs serially (run-all's rule: a threshold is never loosened to cope with load; the suite moves
# off the loaded machine instead). It is its own file so that test-leak-guard.sh, which has no other
# timing assertion, can run in the concurrent batch: a whole suite run alone for one case made every
# selection that reaches leak-guard wait for all of it.
#
# The fixture domain is the same invented vocabulary as test-leak-guard.sh, cut to what this case
# needs: both pattern files (a configured domain missing either fails closed) and a record.
set -eu
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
base=$(cd "$here/.." && pwd)
# The fleet-decl under test is the one in this source tree, not whatever is deployed.
_srcbin=$(mktemp -d "$_TMP/srcbin.XXXXXX")
ln -sf "$base/private_dot_local/bin/executable_fleet-decl" "$_srcbin/fleet-decl"
PATH="$_srcbin:$PATH"; export PATH
guard="$base/private_dot_local/bin/executable_leak-guard"
tmp=$(mktemp -d "$_TMP/test-leak-guard-perf.XXXXXX"); trap 'rm -rf "$tmp" "$_srcbin"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$tmp/.dotlocal"
printf '\\b(ZZP|ZZQ|ZZR)(-ADR)?-[0-9]+\n' > "$tmp/.dotlocal/git-leak-markers"
printf 'hush-term|corp-secret\n' > "$tmp/.dotlocal/git-leak-sensitive"
printf 'private-url=private-host\\.example\nprobe-marker=ZZP-9999\n' > "$tmp/.dotlocal/git-leak-policy"
# A record holding only `projects:` is unusable to fleet-decl, which would make the guard refuse
# for that reason alone; one seed entry makes it usable.
export FLEET_RECORD="$tmp/rec.yaml" FLEET_DEVEL_ROOT="$tmp"
printf 'projects:\n  seed:\n    scope: seed\n' > "$FLEET_RECORD"

# The original scan forked two greps PER INPUT LINE (about 14 s for one 3.3k-line file; minutes
# across a fresh repository's first push, which read as a hang). The batched scan must name the
# token at its real line, within 5 s, on a 4k-line add.
r="$tmp/perf"; mkdir -p "$r"; git -C "$r" init -q
i=0; : > "$r/big.txt"
while [ "$i" -lt 4000 ]; do printf 'clean line %s\n' "$i" >> "$r/big.txt"; i=$((i+1)); done
printf 'and a ZZQ-77 marker at the end\n' >> "$r/big.txt"
git -C "$r" add big.txt
start=$(date +%s)
out=$(HOME="$tmp" sh -c "cd '$r' && sh '$guard' pre-commit" 2>&1 || true)
elapsed=$(( $(date +%s) - start ))
printf '%s' "$out" | grep -qE 'big\.txt:4001:.*ZZQ-77' || { echo "FAIL: the scan should report ZZQ-77 at big.txt line 4001"; echo "$out"; exit 1; }
[ "$elapsed" -le 5 ] || { echo "FAIL: 4k-line scan took ${elapsed}s (>5s) -- per-line fork regression"; exit 1; }
echo PASS
