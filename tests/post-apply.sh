#!/bin/sh
# post-apply -- the base's chezmoi `hooks.apply.post` (.chezmoi.toml.tmpl): after an apply, run
# every suite through Nx, uncached, in the background, and alert on a failure. The work, and its
# rules, are in tests/apply-suites.py; this file keeps the path already-generated configs name.
# Also runnable by hand: `sh tests/post-apply.sh` (detaches), `sh tests/post-apply.sh --run`
# (in the foreground).
#
# Its one decision: with no python3 the suites cannot run, and a fresh machine's first apply is
# where that happens, so it skips loudly with exit 0, as apply-suites.py does for its other tools.
here=$(cd "$(dirname "$0")" && pwd)
if ! command -v python3 >/dev/null 2>&1; then
  printf 'dotfiles post-apply: suites SKIPPED, not installed: python3.\n' >&2
  exit 0
fi
exec python3 "$here/apply-suites.py" post "$@"
