#!/bin/sh
# Test: structural hygiene of the chezmoi SOURCE tree itself, as opposed to the behavior of
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

# CHECK 3 -- the Nx development files never deploy.
#
# The base is an Nx workspace for development only: applying it must never need Node, and nothing Nx
# uses may land in $HOME, where a package.json or node_modules would sit as clutter at best and be
# picked up as a workspace by tools run there at worst. .chezmoiignore is what keeps them out, and a
# line dropped from it would fail silently, so this asks chezmoi itself which targets the source
# manages. It runs on a scratch copy without .chezmoiexternal*, whose downloads the question does not
# need, under a scratch config, cache and destination, so nothing of this machine's is read or
# written. Skipped where chezmoi is not installed.
if command -v chezmoi >/dev/null 2>&1; then
  _TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
  hyg=$(mktemp -d "$_TMP/test-repo-hygiene.XXXXXX"); trap 'rm -rf "$hyg"' EXIT
  mkdir -p "$hyg/src" "$hyg/home"
  (cd "$root" && git ls-files -z --cached --others --exclude-standard) \
    | (cd "$root" && xargs -0 sh -c 'd=$1; shift; for f; do [ -e "$f" ] || [ -L "$f" ] || continue; mkdir -p "$d/$(dirname "$f")"; cp -P "$f" "$d/$f"; done' _ "$hyg/src")
  # The files under test exist in a fresh checkout too, but node_modules/ is never tracked: stand one in.
  mkdir -p "$hyg/src/node_modules/x" && : > "$hyg/src/node_modules/x/index.js"
  rm -f "$hyg/src"/.chezmoiexternal*
  printf '[data]\n    domain = "home"\n' > "$hyg/c.toml"
  if ! managed=$(chezmoi --source "$hyg/src" --config "$hyg/c.toml" --destination "$hyg/home" \
       --cache "$hyg/cache" --persistent-state "$hyg/state.boltdb" managed --include files 2>"$hyg/err"); then
    echo "FAIL: chezmoi could not list the managed files: $(head -n 3 "$hyg/err")"; exit 1
  fi
  [ -n "$managed" ] || { echo "FAIL: chezmoi listed no managed files, so this check would see nothing"; exit 1; }
  leaked=$(printf '%s\n' "$managed" | grep -E '^(package\.json|package-lock\.json|nx\.json|\.nvmrc|node_modules/|tools/|\.nx/)' || true)
  if [ -n "$leaked" ]; then
    echo "FAIL: Nx development files would deploy to \$HOME (add them to .chezmoiignore):"
    printf '%s\n' "$leaked" | sed 's/^/      /'
    exit 1
  fi
  echo "ok:   no Nx development file deploys"
else
  echo "skip: chezmoi not installed, so the Nx deploy check did not run"
fi

echo "PASS"
