#!/usr/bin/env bash
# test-claude-worktree-hook.sh -- contract tests for the Claude Code hooks that keep a session's
# worktree operations on worktrunk, and that leave the EnterWorktree tool open everywhere.
#
# Every guard is also run as a DELIBERATELY BROKEN copy (its check removed by sed, the sed target
# asserted to exist first) and the broken copy must let the forbidden call through. A guard that is
# never seen to fail is of unknown value; keeping the broken-copy runs in the suite means an edit
# that silently weakens a guard fails here.
#
# The hook is driven with real hook-shaped JSON on stdin, with $CLAUDE_CONFIG_DIR pointed at a
# scratch user settings directory, and with a stub `wt` on PATH (the guard stands down where worktrunk is absent, which is
# itself tested).
#
# Run: sh tests/test-claude-worktree-hook.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/git-isolate.sh"
unset CLAUDE_PROJECT_DIR   # a suite run from inside a session must not read that session's project
HOOK="$here/../private_dot_local/bin/executable_claude-worktree-hook"
[ -x "$HOOK" ] || { echo "FAIL: $HOOK is missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }

TD=${TMPDIR:-/tmp}; TD=${TD%/}
T=$(mktemp -d "$TD/test-wt-hook.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# A stub wt, so the guard believes worktrunk is installed whatever this machine has.
mkdir -p "$T/bin" "$T/nowt"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/wt"; chmod +x "$T/bin/wt"
WITH_WT="$T/bin:$PATH"
# PATH without any wt: every directory of the real PATH except those holding a wt.
NO_WT=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
  [ -n "$d" ] && [ ! -x "$d/wt" ] && printf '%s:' "$d"; done)
NO_WT=${NO_WT%:}

bash_payload() { jq -cn --arg c "$1" '{session_id: "s1", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: "/x"}'; }
enter_payload() { jq -cn --arg s "$1" --arg cwd "$2" '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "EnterWorktree", tool_input: {name: "w"}, cwd: $cwd}'; }
start_payload() { jq -cn --arg s "$1" --arg a "$2" --arg cwd "${3:-/nonexistent}" '{session_id: $s, agent_id: $a, agent_type: "general-purpose", hook_event_name: "SubagentStart", cwd: $cwd}'; }

decision() { # empty output is how a hook allows
  [ -n "$1" ] || { echo allow; return; }
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow
}

# run <hook> <subcommand> <payload> [PATH]
run() { printf '%s' "$3" | PATH="${4:-$WITH_WT}" "$1" "$2" 2>"$T/err"; }

counter=0
broken() { # <sed-script> <must-exist-pattern>; sets $b to the path of a broken copy
  counter=$((counter + 1))
  grep -q -- "$2" "$HOOK" || no "broken-copy target not found in hook: $2"
  b="$T/broken-$counter"
  sed "$1" "$HOOK" > "$b"; chmod +x "$b"
  cmp -s "$HOOK" "$b" && no "broken copy is identical to the hook (sed matched nothing): $1"
}

expect_bash() { # <hook> <want: deny|allow> <command> <label>
  out=$(run "$1" bash "$(bash_payload "$3")")
  got=$(decision "$out")
  if [ "$got" = "$2" ]; then ok "$4"; else no "$4 (wanted $2, got $got) :: $3"; fi
}

echo "== Bash guard: raw git worktree add and move are refused =="
for c in \
  'git worktree add ../x -b x' \
  'git worktree move x y' \
  'git -C /some/repo worktree add .worktrees/x' \
  'git -c core.hooksPath=/dev/null worktree add y' \
  'git --git-dir=/r/.git --work-tree /r worktree add z' \
  '/usr/bin/git worktree add q' \
  'command git worktree add q' \
  'env GIT_TRACE=1 git worktree add q' \
  'cd /r && git worktree add q' \
  'ls | git worktree add q' \
  'echo "$(git worktree add q)"' \
  'x=$(git -C $(pwd) worktree add q)' \
  'bash -c "git worktree add q"' \
  'sh -ec '"'"'git worktree move q r'"'"'' \
  'eval git worktree add q' \
  'git \
  worktree add q'
do
  expect_bash "$HOOK" deny "$c" "refused: $c"
done

echo "== Bash guard: everything else is left alone =="
for c in \
  'git worktree list' \
  'git worktree list --porcelain' \
  'git -C /r worktree prune' \
  'git status' \
  'wt switch --create x' \
  'wt remove --no-hooks --foreground x' \
  'git commit -m "use git worktree add instead"' \
  'echo "git worktree add x"' \
  'rg -n "git worktree remove" docs/' \
  'git log --grep worktree' \
  "cat > f <<'EOF'
git worktree add ../x
EOF" \
  'ls # git worktree add x'
do
  expect_bash "$HOOK" allow "$c" "allowed: $c"
done

echo "== Bash guard: the refusal names the wt command to use =="
out=$(run "$HOOK" bash "$(bash_payload 'git worktree add x')")
printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'wt switch --create' \
  && ok "add names wt switch --create" || no "add reason does not name wt switch --create: $out"

echo "== Bash guard: raw git worktree remove is allowed, with a warning naming wt remove =="
for c in 'git worktree remove x' 'git -C "/path with space" worktree remove x' 'git --no-pager worktree remove z' \
         'true; git worktree remove q' 'sh -ec '"'"'git worktree remove q'"'"''; do
  out=$(run "$HOOK" bash "$(bash_payload "$c")")
  if [ "$(decision "$out")" = allow ] && printf '%s' "$out" | jq -r '.systemMessage, .hookSpecificOutput.additionalContext' | grep -q 'wt remove --no-hooks --foreground'; then
    ok "warned, not refused: $c"
  else no "remove not allowed-with-warning: $c :: $out"; fi
  printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1 \
    && no "the warning must not set a permission decision: $c"
done
out=$(run "$HOOK" bash "$(bash_payload 'git worktree remove a; git worktree add b')")
[ "$(decision "$out")" = deny ] && ok "a line that removes and adds is refused (the add wins)" || no "remove masked an add: $out"

echo "== Bash guard: wt remove without --foreground is refused =="
# A background removal moves the worktree into worktrunk's trash and deletes it from a detached
# process; a session's command ending (a sandboxed one especially) can kill that process, so the
# trash is never emptied. --foreground finishes inside the command.
for c in 'wt remove x' 'wt remove --no-hooks x' 'cd /r && wt remove x' 'bash -c "wt remove x"' \
         'wt -C /r remove x' 'wt remove'; do
  expect_bash "$HOOK" deny "$c" "refused: $c"
done
for c in 'wt remove --foreground x' 'wt -C /r remove --no-hooks --foreground x' 'echo "wt remove x"' \
         'wt list' 'wt switch --create remove'; do
  expect_bash "$HOOK" allow "$c" "allowed: $c"
done
out=$(run "$HOOK" bash "$(bash_payload 'wt remove x')")
printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q -- '--foreground' \
  && ok "the wt remove refusal names --foreground" || no "wt remove reason does not name --foreground: $out"

echo "== Bash guard: stands down where worktrunk is not installed =="
out=$(run "$HOOK" bash "$(bash_payload 'git worktree add x')" "$NO_WT")
[ "$(decision "$out")" = allow ] && ok "no wt on PATH: allowed (no wt command to name)" || no "refused although wt is absent: $out"

echo "== Bash guard RED: with the check removed, the forbidden call goes through =="
broken 's/^        add|move) printf .%s. "\$sub"; exit 0 ;;$/        add|move) ;;/' 'add|move) printf'
expect_bash "$b" allow 'git worktree add x' "broken copy (add/move match removed) allows git worktree add"
expect_bash "$b" allow 'git -C /r worktree move x y' "broken copy allows git -C worktree move"
broken 's/^        wt-remove-bg) printf .%s. "\$sub"; exit 0 ;;$/        wt-remove-bg) ;;/' 'wt-remove-bg) printf'
expect_bash "$b" allow 'wt remove x' "broken copy (wt-remove-bg match removed) allows a background wt remove"
broken 's/\*worktree\* | \*remove\*)/*worktree*)/' '*worktree\* | \*remove\*)'
expect_bash "$b" allow 'wt remove x' "broken copy (fast path without remove) lets wt remove through unscanned"
echo "== Remove RED: making remove refuse again turns the warning test red =="
broken 's/^    remove) warn .*/    remove) how=x ;;/' "    remove) warn '"
expect_bash "$b" deny 'git worktree remove x' "broken copy (warning turned into a refusal) denies git worktree remove"
out=$(run "$b" bash "$(bash_payload 'git -C /r worktree remove x')")
printf '%s' "$out" | jq -r '.systemMessage // empty' | grep -q 'wt remove' \
  && no "broken copy still warned" || ok "and the allowed-with-warning assertion would fail against it"

echo "== EnterWorktree: open everywhere, including where sessions work in place =="
# Until 2026-11-19 an `enter-worktree` subcommand refused the tool wherever the effective
# worktree.bgIsolation was "none". It is retired; a settings file not yet re-applied may still call
# it, and the hook must allow, silently.
CFG="$T/cfg"; mkdir -p "$CFG"; export CLAUDE_CONFIG_DIR="$CFG"   # the user settings file, isolated
printf '{"worktree":{"bgIsolation":"none"}}' > "$CFG/settings.json"
git init -q -b main "$T/inplace"; mkdir -p "$T/inplace/.claude"
printf '{"worktree":{"bgIsolation":"none"}}' > "$T/inplace/.claude/settings.json"
expect_enter() { # <hook> <want> <cwd> <label>
  out=$(run "$1" enter-worktree "$(enter_payload s1 "$3")")
  got=$(decision "$out")
  if [ "$got" = "$2" ] && { [ "$2" = deny ] || [ -z "$out" ]; }; then ok "$4"; else no "$4 (wanted $2, got $got) :: $out"; fi
}
expect_enter "$HOOK" allow "$T/inplace" "bgIsolation none at user and project level: EnterWorktree allowed, nothing printed"
expect_enter "$HOOK" allow "/nonexistent" "no repository at all: allowed"
echo "== EnterWorktree RED: a copy that refuses the tool again is caught =="
broken 's/^  bash | subagent-start) ;;$/  bash | enter-worktree | subagent-start) ;;/; s/^  subagent-start)$/  enter-worktree) deny "refused" ;;\n  subagent-start)/' '^  bash | subagent-start) ;;$'
expect_enter "$b" deny "$T/inplace" "broken copy (refusal restored) denies EnterWorktree, so the allow assertion would fail"

echo "== Bash guard: the add refusal names EnterWorktree, where sessions work in place too =="
bash_payload_at() { jq -cn --arg c "$1" --arg cwd "$2" '{session_id: "s1", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd}'; }
add_reason() { run "$1" bash "$(bash_payload_at 'git worktree add x' "$2")" | jq -r '.hookSpecificOutput.permissionDecisionReason'; }
add_reason "$HOOK" "$T/inplace" | grep -q 'the EnterWorktree tool and a subagent launched with isolation' \
  && ok "work in place: the add refusal names the EnterWorktree tool" || no "the add refusal does not name EnterWorktree: $(add_reason "$HOOK" "$T/inplace")"
add_reason "$HOOK" "$T/inplace" | grep -q 'EnterWorktree is refused' \
  && no "the add refusal still says EnterWorktree is refused" || ok "and does not say EnterWorktree is refused"
broken 's/ In a session, the EnterWorktree tool and a subagent launched with isolation "worktree" create through worktrunk too.//' 'In a session, the EnterWorktree tool and a subagent'
add_reason "$b" "$T/inplace" | grep -q 'the EnterWorktree tool and a subagent launched with isolation' \
  && no "broken copy (EnterWorktree sentence removed) still passes" || ok "RED: a copy without the EnterWorktree route fails the first assertion"

echo "== SubagentStart warns about commits not on any remote =="
command -v git >/dev/null 2>&1 || { echo "SKIP: git not present"; exit 1; }
R="$T/repo"
git init -q --bare "$T/remote.git"
git init -q -b main "$R"
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c1
git -C "$R" remote add origin "$T/remote.git"
git -C "$R" push -q -u origin main 2>/dev/null
out=$(run "$HOOK" subagent-start "$(start_payload s9 a1 "$R")")
[ -z "$out" ] && ok "pushed checkout: quiet" || no "warned on a pushed checkout: $out"
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c2
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c3
out=$(run "$HOOK" subagent-start "$(start_payload s9 a2 "$R")")
printf '%s' "$out" | jq -r '.systemMessage // empty' | grep -q '2 commit' \
  && ok "two unpushed commits: warns, naming the count" || no "no warning for unpushed commits: $out"
printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1 \
  && no "the warning must not block" || ok "the warning does not block"
CLAUDE_PROJECT_DIR="$R" run "$HOOK" subagent-start "$(start_payload s9 a3 /nonexistent)" > "$T/o"
grep -q '2 commit' "$T/o" && ok "reads the project dir when the hook's cwd is elsewhere" || no "project dir not used: $(cat "$T/o")"
git -C "$R" checkout -q -b local-only
out=$(run "$HOOK" subagent-start "$(start_payload s9 a4 "$R")")
[ -z "$out" ] && ok "no upstream: quiet" || no "warned with no upstream: $out"
broken 's/^  git -C "\$dir" rev-parse --abbrev-ref --symbolic-full-name .@{u}. >\/dev\/null 2>&1 || return 0$/  :/' "symbolic-full-name '@{u}'"
out=$(run "$b" subagent-start "$(start_payload s9 a5 "$R")")
[ -n "$out" ] && ok "RED: broken copy (upstream check removed) warns with no upstream" || no "broken copy stayed quiet"
git -C "$R" checkout -q main
broken 's/^  \[ "\$ahead" -gt 0 \] 2>\/dev\/null || return 0$/  return 0/' '\[ "\$ahead" -gt 0 \] 2>/dev/null || return 0'
out=$(run "$b" subagent-start "$(start_payload s9 a6 "$R")")
[ -z "$out" ] && ok "RED: broken copy (count check short-circuited) misses the unpushed commits" || no "broken copy still warned"

echo "== Fail open: no jq means the hook does nothing and never errors =="
mkdir -p "$T/nojq"
for t in sh bash cat printf mkdir rm ls dirname basename tr awk sed grep find wc git date; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$T/nojq/$t"
done
ln -sf "$T/bin/wt" "$T/nojq/wt"
out=$(printf '%s' "$(bash_payload 'git worktree add x')" | PATH="$T/nojq" "$HOOK" bash 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "no jq: exit 0, silent" || no "no jq: rc=$rc out=$out"

printf '\npassed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
