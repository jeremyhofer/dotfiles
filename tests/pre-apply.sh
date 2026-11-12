#!/bin/sh
# pre-apply -- the base's chezmoi `hooks.apply.pre` (.chezmoi.toml.tmpl): before an apply deploys
# this source tree, run the suites through Nx and abort the apply on a failure. The work, and its
# rules, are in tests/apply-suites.py; this file keeps the path already-generated configs name.
# Also runnable by hand: `sh tests/pre-apply.sh`.
#
# Its one decision: with no python3 the suites cannot run, and a fresh machine's first apply is
# where that happens, so it skips loudly with exit 0, as apply-suites.py does for its other tools.
here=$(cd "$(dirname "$0")" && pwd)
if ! command -v python3 >/dev/null 2>&1; then
  printf 'dotfiles pre-apply: suites SKIPPED, not installed: python3. The apply goes ahead untested.\n' >&2
  exit 0
fi
exec python3 "$here/apply-suites.py" pre
