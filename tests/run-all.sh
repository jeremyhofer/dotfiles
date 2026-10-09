#!/bin/sh
# Run every suite in tests/, concurrently. Judges each by its EXIT CODE, never by its output.
#
# WHY EXIT CODE, EXPLICITLY. The suites do not share a result convention: most end in a
# literal `PASS` line, and test-git-snapshot.sh ends in `passed 13, failed 0`. An ad-hoc
# runner that greps the last line for `PASS` therefore reports that suite as FAILING while
# it is green -- which is exactly what happened the first time this suite was run as a
# whole, on 2026-08-29. The exit code is the only signal every suite already agrees on, and
# unifying the output convention across 19 files to make grepping safe would be fixing the
# wrong end of it.
#
# WHY CONCURRENT. The suites are independent, each working in its own scratch directory, so a
# serial run only pays for the sum of their times. Each suite's output goes to its own file and
# is replayed, whole, only when it fails; results print in suite-name order whatever the finish
# order, so two runs of the same tree print the same lines.
#
# Usage:
#   sh tests/run-all.sh            # every suite
#   sh tests/run-all.sh kb         # only suites whose name contains "kb"
#   RUN_ALL_JOBS=1 sh tests/run-all.sh   # one at a time, as before
#
# RUN_ALL_JOBS: suites running at once. Default: the CPU count, at most 8 (each suite keeps
# a scratch tree under $TMPDIR, so more is not worth the disk).
#
# Exits 1 if any suite failed, naming each one and replaying its output; 2 if none matched.
# POSIX sh and BSD userland only: no `wait -n`, no `timeout`, nothing GNU-specific.
set -u
here=$(cd "$(dirname "$0")" && pwd)
filter=${1:-}

# No suite may reach the machine's own global git config, so none can fire its commit hooks.
. "$here/git-isolate.sh"

jobs=${RUN_ALL_JOBS:-}
case "$jobs" in
  ''|*[!0-9]*|0)
    jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    case "$jobs" in ''|*[!0-9]*|0) jobs=4 ;; esac
    [ "$jobs" -le 8 ] || jobs=8 ;;
esac

# macOS sets TMPDIR WITH a trailing slash, so the naive "$TMPDIR/x.XXXXXX" has a doubled one.
t=${TMPDIR:-/tmp}; t=${t%/}
work=$(mktemp -d "$t/run-all.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM HUP
mkdir "$work/out" "$work/rc"

# One suite: run it under the interpreter its shebang names, keep its output and exit code.
cat > "$work/worker.sh" <<'EOF'
#!/bin/sh
# args: <work dir> <suite path> <interpreter>
work=$1; t=$2; interp=$3
name=$(basename "$t")
"$interp" "$t" > "$work/out/$name" 2>&1 < /dev/null
echo "$?" > "$work/rc/$name"
EOF

: > "$work/list"; : > "$work/names"
for t in "$here"/test-*.sh; do
  [ -f "$t" ] || continue
  name=$(basename "$t")
  if [ -n "$filter" ]; then
    case "$name" in *"$filter"*) ;; *) continue ;; esac
  fi
  # The interpreter comes from the shebang (`#!/usr/bin/env X` and `#!/bin/X` both reduce to X):
  # a zsh suite run through `sh` fails on zsh-only syntax, which reads like a broken test rather
  # than a broken runner.
  interp=$(sed -n '1s|^#!.*[/ ]||p' "$t")
  case "$interp" in
    sh|bash|zsh) ;;
    *) printf 'SKIP   %s (unrecognised interpreter: %s)\n' "$name" "${interp:-none}" >&2; continue ;;
  esac
  if ! command -v "$interp" >/dev/null 2>&1; then
    printf 'SKIP   %s (%s not installed)\n' "$name" "$interp" >&2; continue
  fi
  printf '%s %s\n' "$t" "$interp" >> "$work/list"
  printf '%s\n' "$name" >> "$work/names"
done

if [ ! -s "$work/list" ]; then
  echo "run-all: no suites matched${filter:+ filter '$filter'}" >&2
  exit 2
fi

# xargs -P runs the workers. Its own exit status is not the verdict; each suite's rc file is.
# Two words per input line (suite path, interpreter), so the paths must hold no blanks.
xargs -n 2 -P "$jobs" sh "$work/worker.sh" "$work" < "$work/list"

pass=0; fail=0; failed=""
while IFS= read -r name; do
  rc=$(cat "$work/rc/$name" 2>/dev/null)
  if [ "${rc:-x}" = 0 ]; then
    printf 'PASS   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL   %s (exit %s)\n' "$name" "${rc:-no result}"
    fail=$((fail + 1))
    failed="$failed $name"
    sed 's/^/       | /' "$work/out/$name" 2>/dev/null
  fi
done < "$work/names"

printf '\n%s suite(s): %s passed, %s failed\n' "$((pass + fail))" "$pass" "$fail"
[ "$fail" -eq 0 ] || { printf 'failed:%s\n' "$failed" >&2; exit 1; }
exit 0
