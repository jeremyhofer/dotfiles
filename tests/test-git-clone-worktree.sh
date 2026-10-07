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

# --- options -------------------------------------------------------------------------------------
mkdir -p "$TMP/opts"; cd "$TMP/opts" || exit 1
"$TOOL" --help > "$TMP/out" 2>&1; rc=$?
check "--help: exit 0, its own usage, nothing created" '[ "$rc" = 0 ] && grep -q "git-clone-worktree --mani-project" "$TMP/out" && [ -z "$(ls -A)" ]'
"$TOOL" -h > "$TMP/out" 2>&1; rc=$?
check "-h: the same" '[ "$rc" = 0 ] && grep -q "git-clone-worktree --mani-project" "$TMP/out"'
"$TOOL" --bogus > "$TMP/out" 2>&1; rc=$?
check "an unknown option: refused, never taken as a url, nothing created" '[ "$rc" != 0 ] && grep -q "unknown option" "$TMP/out" && [ -z "$(ls -A)" ]'

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
check "direct: the default branch tracks its remote, so a plain git pull works" '[ "$(git -C plain/develop rev-parse --abbrev-ref "@{u}" 2>/dev/null)" = origin/develop ]'
git -C plain/develop branch --unset-upstream 2>/dev/null
"$TOOL" "$TMP/dev.git" plain >/dev/null 2>&1; rc=$?
check "direct: a re-run on a complete container exits 0" '[ "$rc" = 0 ]'
check "direct: a re-run repairs a default branch with no upstream" '[ "$(git -C plain/develop rev-parse --abbrev-ref "@{u}" 2>/dev/null)" = origin/develop ]'
rm -rf plain/develop; git -C plain worktree prune
"$TOOL" "$TMP/dev.git" plain >/dev/null 2>&1
check "direct: a re-run re-creates a missing default worktree" '[ -d plain/develop ]'

mkdir -p populated; echo keep > populated/notes.txt
"$TOOL" "$TMP/mas.git" populated > "$TMP/out" 2>&1; rc=$?
check "a non-empty directory that is not a container is refused" '[ "$rc" != 0 ] && [ ! -e populated/.bare ] && [ ! -e populated/.git ]'
check "...naming the likely cause" 'grep -q "path:" "$TMP/out"'

# --- cost does not grow a git process per branch ----------------------------------------------
# A bare clone creates a local branch for every remote branch, and all but the default are deleted.
# One process per deletion took 8.9 s of a 8.9 s clone at 3000 branches; a batch takes 0.06 s.
# Counted, not timed, so the check is deterministic.
git init -q -b main "$TMP/src-many"; git -C "$TMP/src-many" commit -q --allow-empty -m one
h=$(git -C "$TMP/src-many" rev-parse HEAD)
i=1; while [ $i -le 200 ]; do printf 'create refs/heads/b%s %s\n' $i "$h"; i=$((i + 1)); done \
  | git -C "$TMP/src-many" update-ref --stdin
git clone -q --bare "$TMP/src-many" "$TMP/many.git"
realgit=$(command -v git); mkdir -p "$TMP/countbin"
printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$TMP/gitcalls" "$realgit" > "$TMP/countbin/git"; chmod +x "$TMP/countbin/git"
: > "$TMP/gitcalls"; (cd "$TMP" && PATH="$TMP/countbin:$PATH" "$TOOL" "$TMP/many.git" manybranches >/dev/null 2>&1)
ncalls=$(awk 'END { print NR }' "$TMP/gitcalls")
check "200 branches: git runs a bounded number of times, not once per branch (ran $ncalls)" '[ "$ncalls" -lt 30 ]'
check "a fresh clone fetches once: the clone itself, no second fetch (a network round trip)" '! grep -q " fetch" "$TMP/gitcalls"'
check "...and remote-tracking refs exist for every branch" '[ "$(git -C "$TMP/manybranches/main" for-each-ref refs/remotes/origin/ | wc -l | tr -d " ")" -ge 200 ]'
check "200 branches: only the default is left as a local branch" '[ "$(git -C "$TMP/manybranches/main" for-each-ref refs/heads/ | wc -l | tr -d " ")" = 1 ]'

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
  colonurl:
    path: c5/develop
    url: file://$TMP/dev.git
    clone: git-clone-worktree --mani-project colonurl
  toplevel:
    path: c4
    url: $TMP/mas.git
    clone: git-clone-worktree --mani-project toplevel
EOF
  NO_COLOR=1 mani sync good > "$TMP/out" 2>&1
  check "mani: path naming <container>/<default> gives a bare container" '[ "$(cat c1/.git)" = "gitdir: ./.bare" ] && [ -d c1/develop ]'
  git clone -q "$TMP/dev.git" "$TMP/pusher" && git -C "$TMP/pusher" commit -q --allow-empty -m two \
    && git -C "$TMP/pusher" push -q origin develop
  NO_COLOR=1 mani exec --projects good 'git pull --ff-only' > "$TMP/out" 2>&1
  check "mani exec git pull --ff-only updates a bare container's default branch" \
    '[ "$(git -C c1/develop rev-parse HEAD)" = "$(git -C "$TMP/pusher" rev-parse HEAD)" ]'
  check "mani: a declared worktree is a sibling sharing .bare" \
    '[ "$(cd c1/feature && git rev-parse --path-format=absolute --git-common-dir)" = "$(cd c1 && pwd)/.bare" ]'
  rm -rf c1/feature; git -C c1 worktree prune; NO_COLOR=1 mani sync good > "$TMP/out" 2>&1
  check "mani: a re-sync restores a deleted sibling worktree" '[ -d c1/feature ]'

  NO_COLOR=1 mani sync colonurl > "$TMP/out" 2>&1
  check "mani: a url containing a colon (file://, https://, ssh://) is read whole" '[ "$(cat c5/.git 2>/dev/null)" = "gitdir: ./.bare" ] && [ -d c5/develop ]'

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
