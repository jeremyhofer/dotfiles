#!/usr/bin/env bash
# test-git-snapshot.sh — contract tests for the git-snapshot safety net.
#
# The point of the tool is that work survives a destructive command, so the tests do the
# destructive thing for real and then assert the content comes BACK. Asserting only that a
# ref was created would pass on a snapshot that captured nothing.
#
# Run: bash ~/.local/share/chezmoi/tests/test-git-snapshot.sh
set -uo pipefail

SNAP="$(cd "$(dirname "$0")/.." && pwd)/private_dot_local/bin/executable_git-snapshot"
pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

newrepo() {
  local r; r=$(mktemp -d)
  git -C "$r" init -q .
  printf 'v1\n' > "$r/a.txt"; git -C "$r" add a.txt
  git -C "$r" -c commit.gpgsign=false commit -qm init
  echo "$r"
}
refs() { git -C "$1" for-each-ref --format='%(refname)' refs/git-snapshot/; }

echo "== tracked changes survive a real discard =="
r=$(newrepo)
printf 'PRECIOUS\n' > "$r/a.txt"
bash "$SNAP" -C "$r" >/dev/null 2>&1
git -C "$r" checkout -- a.txt                       # the destructive command, for real
eq "file was actually discarded" "$(cat "$r/a.txt")" "v1"
ref=$(refs "$r" | head -1)
eq "content is recoverable from the snapshot" "$(git -C "$r" show "$ref":a.txt)" "PRECIOUS"
rm -rf "$r"

echo "== the worktree and index are NOT disturbed by taking a snapshot =="
# `git stash push` would itself revert the tree; `stash create` must not. If this regressed,
# the tool would be causing the very loss it prevents.
r=$(newrepo)
printf 'STILL HERE\n' > "$r/a.txt"
printf 'staged\n' > "$r/b.txt"; git -C "$r" add b.txt
bash "$SNAP" -C "$r" >/dev/null 2>&1
eq "worktree unchanged" "$(cat "$r/a.txt")" "STILL HERE"
eq "index unchanged" "$(git -C "$r" diff --cached --name-only)" "b.txt"
rm -rf "$r"

echo "== clean tree is a silent no-op =="
r=$(newrepo)
out=$(bash "$SNAP" -C "$r" --untracked 2>&1); rc=$?
eq "exit 0" "$rc" "0"
eq "no output" "$out" ""
eq "no ref created" "$(refs "$r" | wc -l)" "0"
rm -rf "$r"

echo "== untracked files survive git clean -fd =="
r=$(newrepo)
printf 'untracked precious\n' > "$r/u.txt"
bash "$SNAP" -C "$r" --untracked >/dev/null 2>&1
git -C "$r" clean -fdq
eq "untracked file was actually removed" "$([ -e "$r/u.txt" ] && echo present || echo gone)" "gone"
arc=$(ls -d "${XDG_STATE_HOME:-$HOME/.local/state}"/git-snapshot/"$(basename "$r")"/*/ 2>/dev/null | tail -1)
eq "recoverable from the archive" "$(tar -xOf "$arc/untracked.tar" u.txt 2>/dev/null)" "untracked precious"
rm -rf "$r" "${XDG_STATE_HOME:-$HOME/.local/state}/git-snapshot/$(basename "$r")"

echo "== untracked files are NOT archived unless asked =="
r=$(newrepo)
printf 'x\n' > "$r/u.txt"
bash "$SNAP" -C "$r" >/dev/null 2>&1
eq "no archive dir" "$([ -d "${XDG_STATE_HOME:-$HOME/.local/state}/git-snapshot/$(basename "$r")" ] && echo yes || echo no)" "no"
rm -rf "$r"

echo "== two snapshots in the same second do not overwrite each other =="
r=$(newrepo)
printf 'first\n' > "$r/a.txt";  bash "$SNAP" -C "$r" >/dev/null 2>&1
printf 'second\n' > "$r/a.txt"; bash "$SNAP" -C "$r" >/dev/null 2>&1
eq "two distinct refs" "$(refs "$r" | wc -l)" "2"
rm -rf "$r"

echo "== escape hatch and non-repo =="
r=$(newrepo)
printf 'dirty\n' > "$r/a.txt"
GIT_SNAPSHOT_SKIP=1 bash "$SNAP" -C "$r" >/dev/null 2>&1
eq "GIT_SNAPSHOT_SKIP=1 makes no ref" "$(refs "$r" | wc -l)" "0"
rm -rf "$r"
d=$(mktemp -d)
bash "$SNAP" -C "$d" >/dev/null 2>&1
eq "outside a repo exits 0" "$?" "0"
rm -rf "$d"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
