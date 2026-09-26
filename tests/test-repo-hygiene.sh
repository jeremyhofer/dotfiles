#!/bin/sh
# Test: structural hygiene of the chezmoi SOURCE tree itself, as opposed to the behaviour of
# anything it ships.
#
# CHECK 1 -- no tracked symlink dangles.
#
# WHY THIS EARNS A TEST. A dangling tracked symlink is not cosmetic here: `chezmoi
# execute-template` and `chezmoi diff` walk the source tree and emit
#   chezmoi: stat <path>: no such file or directory
# on stdout, which silently corrupts the output of any command that captures it. That is how
# this was found on 2026-08-29 -- a generated installer script came out with a chezmoi error
# as its first line and failed with "chezmoi:: command not found".
#
# It is also a textbook stale pointer. The one instance had been dangling since 30b1fb2,
# "Move naming-build-tasks skill to the private layer": the move itself was deliberate and
# correct, and the base's pointer AT the moved thing was simply not updated with it. Nothing
# noticed, because the only symptom was an error line on a command nobody was capturing.
#
# Run: `sh tests/test-repo-hygiene.sh`
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { echo "SKIP: not a git checkout"; exit 0; }

# mode 120000 is git's symlink mode; -s exposes it. Listing what git TRACKS (rather than
# globbing the working tree) is the point: an untracked broken link is local mess, a tracked
# one ships to every machine that clones.
broken=""
for l in $(git -C "$root" ls-files -s | awk '$1=="120000"{print $4}'); do
  [ -e "$root/$l" ] || broken="$broken
  $l -> $(readlink "$root/$l" 2>/dev/null)"
done

if [ -n "$broken" ]; then
  echo "FAIL: tracked symlink(s) dangle:$broken"
  echo "      either restore the target or remove the pointer (git rm)."
  exit 1
fi
echo "ok:   no tracked symlink dangles"

# CHECK 2 -- no source comment in this tree depends on context the tree cannot carry.
#
# This repo ships comment-lint to every other repository and was, until 2026-09-26, the one place
# its own commentary went unchecked. The lint run is the tree's own copy, not whatever this machine
# has applied, so the suite judges what the tree would ship. Whole tree, blocking findings only:
# the tree was at zero blocking when this check was added, so there is no backlog for a ratchet to
# protect. No marker vocabulary is passed: record ids are refused in all added content by the
# publish-boundary guard, and a public tree cannot carry that private list anyway.
lint="$root/private_dot_local/bin/executable_comment-lint"
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not available, so the comment check cannot run"; exit 1; }
if ! out=$(cd "$root" && python3 "$lint" --blocking-only 2>&1); then
  echo "FAIL: a source comment depends on context this tree cannot carry:"
  printf '%s\n' "$out" | grep '^\[' | sed 's/^/      /'
  echo "      full report: python3 private_dot_local/bin/executable_comment-lint"
  exit 1
fi
echo "ok:   no source comment depends on context this tree cannot carry"

echo "PASS"
