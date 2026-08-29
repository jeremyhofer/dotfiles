#!/bin/sh
# Run every suite in tests/. Judges each by its EXIT CODE, never by its output.
#
# WHY EXIT CODE, EXPLICITLY. The suites do not share a result convention: most end in a
# literal `PASS` line, and test-git-snapshot.sh ends in `passed 13, failed 0`. An ad-hoc
# runner that greps the last line for `PASS` therefore reports that suite as FAILING while
# it is green -- which is exactly what happened the first time this suite was run as a
# whole, on 2026-08-29. The exit code is the only signal every suite already agrees on, and
# unifying the output convention across 19 files to make grepping safe would be fixing the
# wrong end of it.
#
# Usage:
#   sh tests/run-all.sh            # every suite
#   sh tests/run-all.sh kb         # only suites whose name contains "kb"
#
# Exits 1 if any suite failed, naming each one and replaying its output.
set -u
here=$(cd "$(dirname "$0")" && pwd)
filter=${1:-}

pass=0; fail=0; failed=""
for t in "$here"/test-*.sh; do
  [ -f "$t" ] || continue
  name=$(basename "$t")
  case "$name" in run-all.sh) continue ;; esac
  if [ -n "$filter" ]; then
    case "$name" in *"$filter"*) ;; *) continue ;; esac
  fi
  out=$(sh "$t" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'PASS   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL   %s (exit %s)\n' "$name" "$rc"
    fail=$((fail + 1))
    failed="$failed $name"
    printf '%s\n' "$out" | sed 's/^/       | /'
  fi
done

if [ "$((pass + fail))" -eq 0 ]; then
  echo "run-all: no suites matched${filter:+ filter '$filter'}" >&2
  exit 2
fi

printf '\n%s suite(s): %s passed, %s failed\n' "$((pass + fail))" "$pass" "$fail"
[ "$fail" -eq 0 ] || { printf 'failed:%s\n' "$failed" >&2; exit 1; }
exit 0
