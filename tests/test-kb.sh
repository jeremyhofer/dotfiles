#!/bin/sh
# Test: the base ships `kb`, its dispatch shows usage, and an unknown subcommand
# reports "unknown" on stderr and exits 2. Source-only harness (tests/ is never
# deployed); run directly: `sh tests/test-kb.sh`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }
kb() { sh "$KB" "$@"; }

# --version prints something on stdout.
kb --version | grep -q . || { echo "FAIL: --version prints nothing"; exit 1; }
echo "ok:   --version prints a version"

# help prints usage.
kb help | grep -q 'usage: kb' || { echo "FAIL: help missing 'usage: kb'"; exit 1; }
echo "ok:   help shows usage"

# unknown subcommand -> 'unknown' on stderr, nothing spurious on stdout.
kb bogus 2>&1 >/dev/null | grep -qi 'unknown' || { echo "FAIL: unknown subcommand not reported"; exit 1; }
echo "ok:   unknown subcommand reported on stderr"

# unknown subcommand -> exit 2.
kb bogus >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 2 ] || { echo "FAIL: unknown should exit 2, got ${rc:-0}"; exit 1; }
echo "ok:   unknown subcommand exits 2"

echo "PASS"
