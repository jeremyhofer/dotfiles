#!/bin/sh
# test-git-ai-coauthor.sh — contract tests for the co-author trailer hook.
#
# Every case makes a REAL commit through git's configured-hook machinery, wired exactly as
# ~/.gitconfig wires it, and then reads the committed message back. Calling the script directly
# would pass even if git never ran it, which is the failure that matters: a hook that is not
# invoked attributes nothing and says nothing.
#
# The caller's own git config is shut out (GIT_CONFIG_GLOBAL=/dev/null) so their hooks, signing
# settings and identity cannot change the result, and CLAUDECODE is set or cleared per case
# because this suite is itself usually run from inside a Claude Code session.
#
# Run: sh ~/.local/share/chezmoi/tests/test-git-ai-coauthor.sh
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/private_dot_local/bin/executable_git-ai-coauthor"
TRAILER='Co-Authored-By: Claude <noreply@anthropic.com>'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

newrepo() {
  r=$(mktemp -d)
  git -C "$r" init -q .
  git -C "$r" config user.name Tester
  git -C "$r" config user.email tester@example.invalid
  git -C "$r" config commit.gpgsign false
  git -C "$r" config hook.ai-coauthor.command "sh '$HOOK'"
  git -C "$r" config hook.ai-coauthor.event prepare-commit-msg
  echo "$r"
}
# commit REPO MESSAGE -- stage a change and commit it with -m, through the hook.
commit() {
  printf '%s\n' "x" >> "$1/f.txt"; git -C "$1" add f.txt
  git -C "$1" commit -q -m "$2"
}
body() { git -C "$1" log -1 --format=%B; }
# count REPO -- Anthropic co-author trailers in the last commit (tr guards against any padding).
count() { body "$1" | grep -ciE '^co-authored-by:.*<noreply@anthropic\.com>' | tr -d '[:space:]'; }

echo "== inside a Claude Code session, a commit gets the trailer =="
r=$(newrepo)
CLAUDECODE=1 commit "$r" "add the widget"
eq "one trailer added" "$(count "$r")" "1"
eq "subject untouched" "$(git -C "$r" log -1 --format=%s)" "add the widget"
eq "trailer is the last line" "$(body "$r" | sed '/^$/d' | tail -1)" "$TRAILER"
rm -rf "$r"

echo "== outside a session, a commit is left alone =="
r=$(newrepo)
(unset CLAUDECODE; commit "$r" "typed by hand")
eq "no trailer" "$(count "$r")" "0"
rm -rf "$r"

echo "== an existing model-specific trailer wins and is not duplicated =="
r=$(newrepo)
CLAUDECODE=1 commit "$r" "fix the thing

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
eq "still exactly one trailer" "$(count "$r")" "1"
eq "the session's own trailer is the one kept" \
  "$(body "$r" | grep -i '^co-authored-by' )" "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
rm -rf "$r"

echo "== amending does not stack a second trailer =="
# git interpret-trailers already declines to repeat an identical trailer, so this case also holds
# without the hook's own duplicate check. It stays because amend is how agents most often re-commit.
r=$(newrepo)
CLAUDECODE=1 commit "$r" "first"
CLAUDECODE=1 git -C "$r" commit -q --amend -m "$(body "$r")"
eq "one trailer after amend" "$(count "$r")" "1"
rm -rf "$r"

echo "== a body keeps its shape, with the trailer in its own paragraph =="
r=$(newrepo)
CLAUDECODE=1 commit "$r" "subject line

A body paragraph explaining the change."
eq "blank line separates body and trailer" \
  "$(body "$r" | sed '/^$/d' | sed -n 2p)" "A body paragraph explaining the change."
eq "trailer follows the body" "$(count "$r")" "1"
rm -rf "$r"

echo "== a repository can opt out =="
r=$(newrepo)
git -C "$r" config ai-coauthor.enabled false
CLAUDECODE=1 commit "$r" "opted out"
eq "no trailer when ai-coauthor.enabled=false" "$(count "$r")" "0"
rm -rf "$r"

echo "== an empty message still aborts =="
r=$(newrepo)
printf 'x\n' > "$r/f.txt"; git -C "$r" add f.txt
if CLAUDECODE=1 git -C "$r" commit -q -m "" >/dev/null 2>&1; then
  no "empty commit message was committed (the trailer alone made it non-empty)"
else
  ok "empty message refused"
fi
rm -rf "$r"

printf '\npassed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
