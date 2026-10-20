#!/bin/sh
# test-claude-dispatch-hook.sh -- contract tests for the Claude Code hook that refuses a subagent
# dispatch which names no model.
#
# The guard is also run as a DELIBERATELY BROKEN copy (its refusal removed by sed, the sed target
# asserted to exist first), and the broken copy must let the dispatch through. A guard never seen to
# fail is of unknown value; keeping the broken-copy run in the suite means an edit that silently
# weakens the guard fails here.
#
# Run: sh tests/test-claude-dispatch-hook.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
HOOK="$here/../private_dot_local/bin/executable_claude-dispatch-hook"
[ -x "$HOOK" ] || { echo "FAIL: $HOOK is missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }

TD=${TMPDIR:-/tmp}; TD=${TD%/}
T=$(mktemp -d "$TD/test-dispatch-hook.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# agent_payload <subagent_type> <model or "-" for absent> [tool_name] [agent_id]
agent_payload() {
  jq -cn --arg t "$1" --arg m "$2" --arg tool "${3:-Agent}" --arg a "${4:-}" '
    {session_id: "s1", hook_event_name: "PreToolUse", tool_name: $tool, cwd: "/x",
     tool_input: ({description: "d", prompt: "p", subagent_type: $t}
                  + (if $m == "-" then {} else {model: $m} end))}
    + (if $a == "" then {} else {agent_id: $a, agent_type: "general-purpose"} end)'
}

decision() { # empty output is how a hook allows
  [ -n "$1" ] || { echo allow; return; }
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow
}

# run <hook> <payload> [args...]
run() { h=$1; p=$2; shift 2; printf '%s' "$p" | "$h" require-model "$@" 2>"$T/err"; }

expect() { # <label> <expected allow|deny> <output> <exit status>
  [ "$4" -eq 0 ] || { no "$1 (exit $4, want 0)"; return; }
  got=$(decision "$3")
  [ "$got" = "$2" ] && ok "$1" || no "$1 (got $got, want $2)"
}

echo "require-model:"
out=$(run "$HOOK" "$(agent_payload general-purpose -)"); expect "no model is refused" deny "$out" $?
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
for w in haiku sonnet opus fork; do
  case "$reason" in *"$w"*) ok "the refusal names $w" ;; *) no "the refusal names $w" ;; esac
done
out=$(run "$HOOK" "$(agent_payload general-purpose '')"); expect "an empty model is refused" deny "$out" $?
out=$(run "$HOOK" "$(agent_payload general-purpose sonnet)"); expect "a named model passes" allow "$out" $?
out=$(run "$HOOK" "$(agent_payload Explore opus)"); expect "a named model passes for any type" allow "$out" $?
out=$(run "$HOOK" "$(agent_payload general-purpose - Agent a123)"); expect "a subagent's own dispatch is refused too" deny "$out" $?
out=$(run "$HOOK" "$(agent_payload general-purpose - Task)"); expect "the older tool name Task is guarded" deny "$out" $?
out=$(run "$HOOK" "$(agent_payload fork -)"); expect "a fork, which always inherits, passes" allow "$out" $?
out=$(run "$HOOK" "$(agent_payload claude-code-guide -)"); expect "an unlisted type without a model is refused" deny "$out" $?
out=$(run "$HOOK" "$(agent_payload claude-code-guide -)" --exempt claude-code-guide,statusline-setup)
expect "--exempt lets a listed type through" allow "$out" $?
out=$(run "$HOOK" "$(agent_payload statusline-setup -)" --exempt claude-code-guide,statusline-setup)
expect "--exempt takes a comma list" allow "$out" $?
out=$(run "$HOOK" "$(agent_payload general-purpose -)" --exempt claude-code-guide)
expect "--exempt does not widen to other types" deny "$out" $?
out=$(run "$HOOK" "$(agent_payload general-purpose - Bash)"); expect "another tool is not acted on" allow "$out" $?

echo "fail open:"
out=$(printf 'not json' | "$HOOK" require-model 2>"$T/err"); expect "unreadable input allows" allow "$out" $?
out=$(printf '' | "$HOOK" require-model 2>"$T/err"); expect "empty input allows" allow "$out" $?
out=$(printf '%s' "$(agent_payload general-purpose -)" | "$HOOK" 2>"$T/err"); expect "no subcommand does nothing" allow "$out" $?
out=$(printf '%s' "$(agent_payload general-purpose -)" | "$HOOK" bogus 2>"$T/err"); expect "an unknown subcommand does nothing" allow "$out" $?
mkdir -p "$T/nojq"   # a PATH with what the hook needs to start, and no jq
for c in bash cat; do ln -s "$(command -v $c)" "$T/nojq/$c"; done
out=$(printf '%s' "$(agent_payload general-purpose -)" | PATH="$T/nojq" "$HOOK" require-model 2>"$T/err")
expect "without jq it allows" allow "$out" $?

echo "broken copy (the guard must be load-bearing):"
grep -q 'deny "' "$HOOK" || no "broken-copy target not found in hook: deny \""
b="$T/broken"; sed 's/^\([[:space:]]*\)deny "/\1: "/' "$HOOK" > "$b"; chmod +x "$b"
cmp -s "$HOOK" "$b" && no "broken copy is identical to the hook (sed matched nothing)"
out=$(run "$b" "$(agent_payload general-purpose -)"); expect "with the refusal removed, no model passes" allow "$out" $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
