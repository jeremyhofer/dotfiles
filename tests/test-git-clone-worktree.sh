#!/usr/bin/env bash
# Tests for git-clone-worktree -- the bootstrap of the bare-container layout, alone and as a mani
# project's `clone:` command.
#
# WHAT IS AT RISK. The layout's whole value is that the git data sits in <container>/.bare, so no
# one worktree's deletion orphans the others. The failures worth guarding are the ones that LOOK
# like success: a sync that ticks while producing an ordinary checkout, a manifest path that makes
# the container one directory too high (up to turning the devel root itself into a repository), and
# a default branch assumed rather than read. The mani arms run a real `mani sync` against local
# repositories; they are skipped, and say so, where mani is not installed.

set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$HERE/private_dot_local/bin/executable_git-clone-worktree"

pass=0; fail=0; skip=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

[ -f "$TOOL" ] || { printf 'git-clone-worktree: not found at %s\n' "$TOOL"; exit 1; }

t=${TMPDIR:-/tmp}; t=${t%/}
TMP=$(mktemp -d "$t/test-gcw.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"          # no ~/.dotlocal hook from the real machine
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
git config --global user.name t; git config --global user.email t@t.invalid
git config --global commit.gpgsign false
# The tool under test, by its deployed name, for mani's `clone:` lines.
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexec bash "%s" "$@"\n' "$TOOL" > "$TMP/bin/git-clone-worktree"
chmod +x "$TMP/bin/git-clone-worktree"; export PATH="$TMP/bin:$PATH"; TOOL="$TMP/bin/git-clone-worktree"

# An origin whose default branch is $2, with one other branch.
mkorigin() {  # $1 name  $2 default branch
  git init -q -b "$2" "$TMP/src-$1"
  git -C "$TMP/src-$1" commit -q --allow-empty -m one
  git -C "$TMP/src-$1" branch feature
  git clone -q --bare "$TMP/src-$1" "$TMP/$1.git"
}
mkorigin dev develop
mkorigin mas master

# --- direct mode ---------------------------------------------------------------------------------
cd "$TMP" || exit 1
"$TOOL" "$TMP/dev.git" plain >/dev/null 2>&1; rc=$?
check "direct: exit 0" '[ "$rc" = 0 ]'
check "direct: the git data is in .bare" '[ -f plain/.bare/HEAD ]'
check "direct: .git is a file pointing at it" '[ "$(cat plain/.git)" = "gitdir: ./.bare" ]'
check "direct: the default branch is read from the remote (develop), not assumed" '[ "$(git -C plain/develop branch --show-current)" = develop ]'
check "direct: no main or master worktree is invented" '[ ! -e plain/main ] && [ ! -e plain/master ]'
check "direct: only the default is a local branch; the rest stay remote-tracking" \
  '[ "$(git -C plain/develop for-each-ref --format="%(refname:short)" refs/heads/)" = develop ] && git -C plain/develop rev-parse -q --verify origin/feature >/dev/null'
"$TOOL" "$TMP/dev.git" plain >/dev/null 2>&1; rc=$?
check "direct: a re-run on a complete container exits 0" '[ "$rc" = 0 ]'
rm -rf plain/develop; git -C plain worktree prune
"$TOOL" "$TMP/dev.git" plain >/dev/null 2>&1
check "direct: a re-run re-creates a missing default worktree" '[ -d plain/develop ]'

mkdir -p populated; echo keep > populated/notes.txt
"$TOOL" "$TMP/mas.git" populated > "$TMP/out" 2>&1; rc=$?
check "a non-empty directory that is not a container is refused" '[ "$rc" != 0 ] && [ ! -e populated/.bare ] && [ ! -e populated/.git ]'
check "...naming the likely cause" 'grep -q "path:" "$TMP/out"'

# --- as mani's clone: command --------------------------------------------------------------------
if ! command -v mani >/dev/null 2>&1; then
  printf '  SKIP the mani arms: mani is not installed\n'; skip=1
else
  mkdir -p "$TMP/ws"; cd "$TMP/ws" || exit 1
  cat > mani.yaml <<EOF
projects:
  good:
    path: c1/develop
    url: $TMP/dev.git
    clone: git-clone-worktree --mani-project good
    worktrees:
      - name: feature
        path: ../feature
  noclone:
    path: c2/master
    url: $TMP/mas.git
    worktrees:
      - name: feature
        path: ../feature
  mismatch:
    path: c3/main
    url: $TMP/mas.git
    clone: git-clone-worktree --mani-project mismatch
  toplevel:
    path: c4
    url: $TMP/mas.git
    clone: git-clone-worktree --mani-project toplevel
EOF
  NO_COLOR=1 mani sync good > "$TMP/out" 2>&1
  check "mani: path naming <container>/<default> gives a bare container" '[ "$(cat c1/.git)" = "gitdir: ./.bare" ] && [ -d c1/develop ]'
  check "mani: a declared worktree is a sibling sharing .bare" \
    '[ "$(cd c1/feature && git rev-parse --path-format=absolute --git-common-dir)" = "$(cd c1 && pwd)/.bare" ]'
  rm -rf c1/feature; git -C c1 worktree prune; NO_COLOR=1 mani sync good > "$TMP/out" 2>&1
  check "mani: a re-sync restores a deleted sibling worktree" '[ -d c1/feature ]'

  NO_COLOR=1 mani sync noclone > "$TMP/out" 2>&1
  check "mani, no clone: line: an ORDINARY checkout, siblings' git data inside it (the silent trap)" \
    '[ -d c2/master/.git ] && [ ! -e c2/.bare ]'

  NO_COLOR=1 mani sync mismatch > "$TMP/out" 2>&1
  check "mani, wrong default in path: warned, and the real default is created instead" \
    'grep -q "default branch is master" "$TMP/out" && [ -d c3/master ] && [ ! -e c3/main ]'

  NO_COLOR=1 mani sync toplevel > "$TMP/out" 2>&1
  check "mani, path naming the container: the directory above is NOT made a repository" \
    '[ ! -e "$TMP/ws/.bare" ] && [ ! -e "$TMP/ws/.git" ]'
fi

printf 'passed: %s   failed: %s%s\n' "$pass" "$fail" "$( [ "$skip" = 1 ] && printf '   (mani arms skipped)')"
[ "$fail" -eq 0 ]
