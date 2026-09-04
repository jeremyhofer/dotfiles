#!/bin/sh
# Test that dot_claude/tooling.md actually lists the tools this repo installs.
#
# WHY A TEST AND NOT A HABIT. An inventory that goes stale is worse than no inventory: a session
# reads it, believes it, and reasons from a wrong premise instead of going and looking. That is not
# hypothetical here -- the always-on worktree-tooling line named a retired script and omitted the
# adopted one, and an agent acting on it twice reported an installed tool as missing. A list nobody
# checks decays the moment a tool is added, and nothing about adding a tool reminds you.
#
# So: every executable shipped in private_dot_local/bin must appear in the inventory, and every tool
# the inventory names must exist. Both directions -- the second catches an entry left behind after a
# tool is retired, which is exactly how the stale line got there.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../private_dot_local/bin"
doc="$here/../dot_claude/tooling.md"
fails=0

[ -f "$doc" ] || { printf '  FAIL  tooling.md missing\n'; exit 1; }

for f in "$bin"/executable_*; do
  [ -e "$f" ] || continue
  name=$(basename "$f" | sed 's/^executable_//')
  if grep -qF "\`$name\`" "$doc"; then
    printf '  ok    %s is documented\n' "$name"
  else
    printf '  FAIL  %s is installed but ABSENT from tooling.md\n' "$name"
    fails=$((fails+1))
  fi
done

# Reverse direction: an entry naming a tool this repo no longer ships.
awk -F'`' '/^\| `/{print $2}' "$doc" | while IFS= read -r listed; do
  [ -n "$listed" ] || continue
  case "$listed" in worktrunk|ripgrep|neovim|fd-find) continue ;; esac   # the name-mismatch table
  [ -e "$bin/executable_$listed" ] || printf '  WARN  tooling.md lists %s, which this repo does not install\n' "$listed"
done

printf '\n'
[ "$fails" -eq 0 ] && printf 'tooling inventory is complete\n' || printf '%s tool(s) undocumented\n' "$fails"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
