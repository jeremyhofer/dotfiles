#!/bin/sh
# pre-apply -- run every suite before `chezmoi apply` deploys this source tree; a failure aborts the
# apply, so nothing is written to the machine.
#
# Run by chezmoi as the base's `hooks.apply.pre` (.chezmoi.toml.tmpl). chezmoi aborts the apply when
# a pre hook exits non-zero (measured with chezmoi 2.74: exit 1, no target written). Also runnable
# by hand: `sh tests/pre-apply.sh`.
#
# WHY HERE. The commit gate runs only the suites a commit's staged paths select
# (tests/select-suites.sh), to keep a commit fast. Every suite still has to pass before a change
# reaches a machine, and an apply is that moment. It judges the working tree, not the index,
# because the working tree is what an apply deploys.
#
# SKIPS, loudly and with exit 0, when a tool the suites need is not installed: on a fresh machine's
# first apply the tools arrive with or after that apply, and refusing it would leave the machine
# unable to bootstrap. The line names what is missing, so a machine that stays without it does not
# pass silently.
#
# The CHEZMOI_* variables chezmoi sets for a hook are removed first, so the suites run as they do at
# commit time rather than inside chezmoi's environment.
#
# NOT YET GATING ON macOS. On 2026-11-08 twelve suites failed on the Mac (GNU-only spellings among
# them, such as `sed -i` without a suffix), failures no commit gate ever saw, since commits are made
# on Linux. Aborting every Mac apply on them would block the machine without making it safer than
# it was, so on macOS a failure is reported in full and the apply goes ahead. Remove this once the
# suite set passes there. PRE_APPLY_OS overrides `uname -s`, for the tests.
#
# Exit 0 every suite passed, or skipped (above), or failed on macOS (reported); 1 a suite failed on
# Linux (the apply is aborted).
set -u
here=$(cd "$(dirname "$0")" && pwd)

missing=""
for tool in git python3 uv jq yq gitleaks wt; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  printf 'dotfiles pre-apply: suites SKIPPED, not installed:%s. The apply goes ahead untested;\n' "$missing" >&2
  printf '  install them (the Brewfile, or the distribution packages) and the next apply runs every suite.\n' >&2
  exit 0
fi

for v in $(env | sed -n 's/^\(CHEZMOI[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done

t=${TMPDIR:-/tmp}; t=${t%/}
log=$(mktemp "$t/dotfiles-pre-apply.XXXXXX") || { echo "dotfiles pre-apply: no temp file for the log; apply refused" >&2; exit 1; }
printf 'dotfiles pre-apply: running every suite (tests/run-all.sh) before the apply...\n' >&2
if sh "$here/run-all.sh" > "$log" 2>&1; then
  printf 'dotfiles pre-apply: %s\n' "$(tail -n 1 "$log")" >&2
  rm -f "$log"
  exit 0
fi
os=${PRE_APPLY_OS:-$(uname -s)}
if [ "$os" = Darwin ]; then
  printf '\ndotfiles pre-apply: a suite failed -- NOT gating on macOS until the suite set passes here;\n' >&2
  printf '  the apply goes ahead. Failing suites:\n' >&2
else
  printf '\ndotfiles pre-apply: a suite failed -- apply ABORTED, nothing was deployed:\n' >&2
fi
grep -E '^(FAIL|run-all:)' "$log" | sed 's/^/  /' >&2
printf '\n  why, in full: %s\n' "$log" >&2
for s in $(sed -n 's/^FAIL   \([^ ]*\) .*/\1/p' "$log"); do
  printf '  re-run one:   sh %s/run-all.sh --only %s\n' "$here" "$s" >&2
done
[ "$os" = Darwin ] && exit 0
exit 1
