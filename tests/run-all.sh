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
# SERIAL SUITES. A suite that asserts on CPU time or on a wall-clock bound is starved by its
# neighbors when eight suites share the machine, and then fails with no defect in the code it tests.
# Such a suite declares it with this exact line among its first 10 lines (after the shebang):
#
#   # run-all: serial
#
# The runner finds it with `grep -qxF '# run-all: serial'` (a fixed string, the whole line), runs
# every unmarked suite concurrently first, then each marked one alone, one at a time. A threshold is
# never loosened to cope with load; the suite is moved off the loaded machine state instead.
#
# PROFILE. With RUN_ALL_PROFILE=<file> set, the runner writes one line per suite, in suite-name
# order, as tab-separated `suite wall_s cpu_s exit`: wall-clock seconds, user plus system CPU
# seconds of the suite's process tree (read from the shell's `times`, which counts the children
# it waited for), and the exit code. Unset, nothing is written. Wall time has sub-second resolution
# where `date +%s.%N` works (GNU) and whole seconds on BSD `date`.
#
# A suite is tests/test-*.sh (sh, bash or zsh) or tests/test-*.py whose shebang is
# `#!/usr/bin/env -S uv run --script` (run as `uv run --script`, SKIPped when uv is missing).
#
# Usage:
#   sh tests/run-all.sh            # every suite
#   sh tests/run-all.sh kb         # only suites whose name contains "kb"
#   sh tests/run-all.sh --only test-kb.sh test-hc-status.sh   # exactly these (select-suites.sh)
#   RUN_ALL_JOBS=1 sh tests/run-all.sh   # one at a time, as before
#
# RUN_ALL_JOBS: suites running at once. Default: the CPU count, at most 8 (each suite keeps
# a scratch tree under $TMPDIR, so more is not worth the disk).
#
# Exits 1 if any suite failed, naming each one and replaying its output; 2 if none matched, or
# if --only names a file that is not a suite here (a selector naming a missing suite is a broken
# map, and must not read as a pass).
# POSIX sh and BSD userland only: no `wait -n`, no `timeout`, nothing GNU-specific.
set -u
here=$(cd "$(dirname "$0")" && pwd)
filter=${1:-}
only=""
if [ "$filter" = --only ]; then
  shift
  [ $# -gt 0 ] || { echo "run-all: --only needs suite names" >&2; exit 2; }
  for n in "$@"; do
    case "$n" in test-*.sh|test-*.py) ;; *) printf 'run-all: --only: %s is not a suite name\n' "$n" >&2; exit 2 ;; esac
    [ -f "$here/$n" ] || { printf 'run-all: --only: no suite %s in %s\n' "$n" "$here" >&2; exit 2; }
  done
  only=" $* "; filter=""
fi

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
mkdir "$work/out" "$work/rc" "$work/prof"

# One suite: run it under the interpreter its shebang names, keep its output and exit code.
cat > "$work/worker.sh" <<'EOF'
#!/bin/sh
# args: <work dir> <suite path> <interpreter>
work=$1; t=$2; interp=$3
name=$(basename "$t")
# Seconds since the epoch, with a fraction where `date` has %N (BSD date prints "%N" literally).
now() {
  d=$(date +%s.%N 2>/dev/null)
  case $d in ''|*[!0-9.]*) d=$(date +%s) ;; esac
  echo "$d"
}
t0=$(now)
case "$interp" in
  uv) uv run --script "$t" > "$work/out/$name" 2>&1 < /dev/null ;;
  *)  "$interp" "$t" > "$work/out/$name" 2>&1 < /dev/null ;;
esac
rc=$?
# `times` line 2 is the CPU of this shell's waited-for children: the suite and what it ran. This
# worker runs one suite, so nothing else is counted.
times > "$work/prof/$name.times"
t1=$(now)
echo "$rc" > "$work/rc/$name"
# Fields: wall, then user and system CPU as "XmY.ZZZs" pairs, summed to seconds.
sed -n 2p "$work/prof/$name.times" | awk -v n="$name" -v a="$t0" -v b="$t1" -v rc="$rc" '
  function secs(x,  p) { sub(/s$/, "", x); split(x, p, "m"); return p[1] * 60 + p[2] }
  { cpu = secs($1) + secs($2) }
  END { printf "%s\t%.2f\t%.2f\t%s\n", n, b - a, cpu, rc }' > "$work/prof/$name"
rm -f "$work/prof/$name.times"
EOF

: > "$work/list"; : > "$work/serial"; : > "$work/names"
for t in "$here"/test-*.sh "$here"/test-*.py; do
  [ -f "$t" ] || continue
  name=$(basename "$t")
  if [ -n "$filter" ]; then
    case "$name" in *"$filter"*) ;; *) continue ;; esac
  fi
  if [ -n "$only" ]; then
    case "$only" in *" $name "*) ;; *) continue ;; esac
  fi
  # The interpreter comes from the shebang (`#!/usr/bin/env X` and `#!/bin/X` both reduce to X):
  # a zsh suite run through `sh` fails on zsh-only syntax, which reads like a broken test rather
  # than a broken runner.
  # A `#!/usr/bin/env -S uv run --script` shebang (a PEP 723 suite that declares its own
  # dependencies) names the interpreter `uv`, run as `uv run --script`; a machine without `uv`
  # gets the same visible SKIP as any other missing interpreter.
  case $(sed -n '1p' "$t") in
    *"uv run --script"*) interp=uv ;;
    *) interp=$(sed -n '1s|^#!.*[/ ]||p' "$t") ;;
  esac
  case "$interp" in
    sh|bash|zsh|uv) ;;
    *) printf 'SKIP   %s (unrecognized interpreter: %s)\n' "$name" "${interp:-none}" >&2; continue ;;
  esac
  if ! command -v "$interp" >/dev/null 2>&1; then
    printf 'SKIP   %s (%s not installed)\n' "$name" "$interp" >&2; continue
  fi
  if sed -n '1,10p' "$t" | grep -qxF '# run-all: serial'; then dest=serial; else dest=list; fi
  printf '%s %s\n' "$t" "$interp" >> "$work/$dest"
  printf '%s\n' "$name" >> "$work/names"
done

if [ ! -s "$work/list" ] && [ ! -s "$work/serial" ]; then
  if [ -n "$only" ]; then
    echo "run-all: every suite named by --only was skipped, so nothing was tested" >&2
  else
    echo "run-all: no suites matched${filter:+ filter '$filter'}" >&2
  fi
  exit 2
fi

# xargs -P runs the workers. Its own exit status is not the verdict; each suite's rc file is.
# Two words per input line (suite path, interpreter), so the paths must hold no blanks.
# GNU xargs runs the command once on empty input, so each batch is guarded by -s.
[ ! -s "$work/list" ] || xargs -n 2 -P "$jobs" sh "$work/worker.sh" "$work" < "$work/list"
# Marked suites run only after the concurrent batch has ended, one at a time (-P 1).
[ ! -s "$work/serial" ] || xargs -n 2 -P 1 sh "$work/worker.sh" "$work" < "$work/serial"

if [ -n "${RUN_ALL_PROFILE:-}" ]; then
  : > "$RUN_ALL_PROFILE"
  while IFS= read -r name; do
    [ -f "$work/prof/$name" ] && cat "$work/prof/$name" >> "$RUN_ALL_PROFILE"
  done < "$work/names"
fi

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
