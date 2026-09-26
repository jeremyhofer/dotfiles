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
# The model lookup reads Claude Code's transcripts. Point it at an empty stand-in and clear the
# session id, so no case reads the caller's real transcripts unless it builds its own.
CLAUDE_CONFIG_DIR=$(mktemp -d); export CLAUDE_CONFIG_DIR
unset CLAUDE_CODE_SESSION_ID
trap 'rm -rf "$CLAUDE_CONFIG_DIR"' EXIT

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

# transcript SID LINES... -- a stand-in session transcript, one JSON record per argument.
transcript() {
  sid=$1; shift
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/-some-project"
  printf '%s\n' "$@" > "$CLAUDE_CONFIG_DIR/projects/-some-project/$sid.jsonl"
}
cotrailer() { body "$1" | grep -i '^co-authored-by'; }

echo "== the session's model is named when its transcript can be read =="
SID=11111111-2222-3333-4444-555555555555
transcript "$SID" \
  '{"type":"assistant","message":{"model":"claude-sonnet-5","content":[]}}' \
  '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","input":{"model":"haiku"}}]}}' \
  '{"type":"assistant","message":{"model":"<synthetic>","content":[]}}'
r=$(newrepo)
CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=$SID commit "$r" "with a model"
eq "latest real model wins; tool-call and synthetic values ignored" \
  "$(cotrailer "$r")" "Co-Authored-By: Claude (claude-opus-5-5) <noreply@anthropic.com>"
rm -rf "$r"

echo "== no transcript for the session: plain Claude =="
r=$(newrepo)
CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=99999999-0000-0000-0000-000000000000 commit "$r" "no transcript"
eq "falls back" "$(cotrailer "$r")" "$TRAILER"
rm -rf "$r"

echo "== a session id that is not UUID-shaped is never used as a path =="
# A transcript reachable ONLY by climbing out of a project directory. Without the guard the glob
# projects/*/../<id>.jsonl resolves to it and the model leaks into the trailer.
SID3=33333333-2222-3333-4444-555555555555
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5-5"}}' > "$CLAUDE_CONFIG_DIR/projects/$SID3.jsonl"
r=$(newrepo)
CLAUDECODE=1 CLAUDE_CODE_SESSION_ID="../$SID3" commit "$r" "odd id"
eq "falls back rather than reading ../" "$(cotrailer "$r")" "$TRAILER"
rm -rf "$r"

echo "== a model value outside the accepted shape is not copied into the trailer =="
SID2=22222222-2222-3333-4444-555555555555
transcript "$SID2" '{"type":"assistant","message":{"model":"claude-opus<script>","content":[]}}'
r=$(newrepo)
CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=$SID2 commit "$r" "bad model"
eq "falls back" "$(cotrailer "$r")" "$TRAILER"
rm -rf "$r"

printf '\npassed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
