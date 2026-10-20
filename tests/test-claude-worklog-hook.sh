#!/bin/sh
# test-claude-worklog-hook.sh -- contract tests for the Claude Code hook that appends subagent
# dispatches, subagent work notes and turn sources to a local worklog.
#
# The hook is also run as DELIBERATELY BROKEN copies (the hand-back refusal removed; the dispatch
# tool filter removed), each sed target asserted to exist first and `cmp` proving the sed changed
# something, and each broken copy must misbehave in the expected way. A guard never seen to fail is
# of unknown value; keeping the broken-copy runs in the suite means an edit that silently weakens a
# guard fails here.
#
# Run: sh tests/test-claude-worklog-hook.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
HOOK="$here/../private_dot_local/bin/executable_claude-worklog-hook"
[ -x "$HOOK" ] || { echo "FAIL: $HOOK is missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }

TD=${TMPDIR:-/tmp}; TD=${TD%/}
T=$(mktemp -d "$TD/test-worklog-hook.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

W="$T/wl"; export CLAUDE_WORKLOG_DIR="$W"
LOG="$W/worklog.jsonl"
PRIV=SECRET-PROMPT-TEXT-91

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
check() { # <label> <got> <want>
  [ "$2" = "$3" ] && ok "$1" || no "$1 (got '$2', want '$3')"
}

fresh() { rm -rf "$W"; }
lines() { if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else echo 0; fi; }
f() { tail -n 1 "$LOG" | jq -r "$1"; }         # a field of the last record, null printed as "null"
ty() { tail -n 1 "$LOG" | jq -r "($1)|type"; } # the JSON type of a field

decision() { # empty output is how a hook allows
  [ -n "$1" ] || { echo allow; return; }
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow
}

# run <hook> <subcommand> <payload>; output in $out, exit status in $rc
run() { h=$1; s=$2; p=$3; out=$(printf '%s' "$p" | "$h" "$s" 2>"$T/err"); rc=$?; }

# ---- payload builders, shaped after captured live hook input ----
# post_agent <tool> <agent_id or ""> [extra tool_input JSON] [extra tool_response JSON]
post_agent() {
  ti=${3:-'{}'}; tr_=${4:-'{}'}
  jq -cn --arg tool "$1" --arg a "$2" --argjson ti "$ti" --argjson tr "$tr_" --arg s "$PRIV" '
    {session_id: "s1", prompt_id: "p1", cwd: "/work", hook_event_name: "PostToolUse", tool_name: $tool,
     effort: {level: "medium"}, tool_use_id: "toolu_1",
     tool_input: ({description: "Reply with OK", prompt: ("do it " + $s)} + $ti),
     tool_response: ({isAsync: true, status: "async_launched", agentId: "child1", resolvedModel: "claude-haiku-5-5"} + $tr)}
    + (if $a == "" then {} else {agent_id: $a, agent_type: "general-purpose"} end)'
}
start_payload() {
  jq -cn --arg a "$1" '{session_id: "s1", prompt_id: "p1", cwd: "/work", hook_event_name: "SubagentStart", agent_id: $a, agent_type: "Explore"}'
}
# handback_payload <agent_id or ""> <message> [tool_name]
handback_payload() {
  jq -cn --arg a "$1" --arg m "$2" --arg tool "${3:-SubagentHandback}" '
    {session_id: "s1", prompt_id: "p1", cwd: "/work", hook_event_name: "PreToolUse", tool_name: $tool,
     tool_input: {message: $m}}
    + (if $a == "" then {} else {agent_id: $a, agent_type: "general-purpose"} end)'
}
turn_payload() {
  jq -cn --arg p "$1" '{session_id: "s1", prompt_id: "p1", cwd: "/work", hook_event_name: "UserPromptSubmit", prompt: $p}'
}

NL='
'
FULL="Did the thing.${NL}${NL}  WORKNOTE: wrote a hook${NL}COMPLEXITY: low, small${NL}COMMITS: none${NL}MODEL-FIT: right, fine"

echo "dispatch:"
fresh
run "$HOOK" dispatch "$(post_agent Agent "" '{"subagent_type":"Explore","model":"haiku","isolation":"worktree"}')"
check "exit 0" "$rc" 0; check "no stdout" "$out" ""
check "one record" "$(lines)" 1
check "kind" "$(f .kind)" dispatch
check "tool_use_id" "$(f .tool_use_id)" toolu_1
check "child_agent_id" "$(f .child_agent_id)" child1
check "subagent_type" "$(f .subagent_type)" Explore
check "model_requested" "$(f .model_requested)" haiku
check "resolved_model" "$(f .resolved_model)" claude-haiku-5-5
check "dispatcher_effort" "$(f .dispatcher_effort)" medium
check "description" "$(f .description)" "Reply with OK"
check "background" "$(f .background)" true
check "isolation" "$(f .isolation)" worktree
check "prompt_chars is the prompt length" "$(f .prompt_chars)" "$(printf 'do it %s' "$PRIV" | wc -c | tr -d ' ')"
check "session_id" "$(f .session_id)" s1
check "prompt_id" "$(f .prompt_id)" p1
check "cwd" "$(f .cwd)" /work
check "main session agent_id is JSON null" "$(ty .agent_id)" null
check "host is set" "$(f '.host|length>0')" true
case "$(f .ts)" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ok "ts is UTC ISO" ;; *) no "ts is UTC ISO ($(f .ts))" ;; esac
run "$HOOK" dispatch "$(post_agent Agent a77)"
check "inside a subagent: agent_id" "$(f .agent_id)" a77
check "missing subagent_type defaults" "$(f .subagent_type)" general-purpose
check "missing model is null" "$(ty .model_requested)" null
check "missing isolation is null" "$(ty .isolation)" null
run "$HOOK" dispatch "$(post_agent Task "" '{}' '{"isAsync":false,"resolvedModel":null}')"
check "Task is handled like Agent" "$(f .kind)" dispatch
check "isAsync false is kept as false" "$(f .background)" false
check "null resolvedModel is null" "$(ty .resolved_model)" null
n=$(lines)
run "$HOOK" dispatch "$(post_agent Bash "")"
check "another tool is not recorded" "$(lines)" "$n"
long=$(printf 'x%.0s' $(seq 1 1200))
run "$HOOK" dispatch "$(post_agent Agent "" "{\"description\":\"$long\"}")"
check "free text is cut to 1000 characters" "$(f '.description|length')" 1000

echo "subagent-start:"
fresh
run "$HOOK" subagent-start "$(start_payload a1)"
check "exit 0" "$rc" 0
check "output is one valid JSON object" "$(printf '%s' "$out" | jq -c 'type')" '"object"'
check "event name" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" SubagentStart
ctx=$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)
for w in 'WORKNOTE:' 'COMPLEXITY: low|medium|high' 'COMMITS: repo@sha' 'MODEL-FIT: right|over|under' 'refused without the WORKNOTE line'; do
  case "$ctx" in *"$w"*) ok "context carries '$w'" ;; *) no "context carries '$w'" ;; esac
done
check "one record" "$(lines)" 1
check "kind" "$(f .kind)" start
check "agent_type" "$(f .agent_type)" Explore
check "agent_id" "$(f .agent_id)" a1

echo "handback:"
fresh
run "$HOOK" handback "$(handback_payload a1 "$FULL")"
check "all four lines: allowed" "$(decision "$out")" allow; check "no stdout" "$out" ""
check "kind" "$(f .kind)" note
check "agent_type" "$(f .agent_type)" general-purpose
check "note" "$(f .note)" "wrote a hook"
check "complexity" "$(f .complexity)" "low, small"
check "commits" "$(f .commits)" none
check "model_fit" "$(f .model_fit)" "right, fine"
check "report_chars" "$(f .report_chars)" "$(printf '%s' "$FULL" | wc -m | tr -d ' ')"
check "agent_id" "$(f .agent_id)" a1
run "$HOOK" handback "$(handback_payload a1 "Done.${NL}WORKNOTE: only this")"
check "only WORKNOTE: allowed" "$(decision "$out")" allow
check "note" "$(f .note)" "only this"
check "absent complexity is null" "$(ty .complexity)" null
check "absent commits is null" "$(ty .commits)" null
check "absent model_fit is null" "$(ty .model_fit)" null
n=$(lines)
run "$HOOK" handback "$(handback_payload a1 "Done.${NL}worknote: lower case")"
check "keyword is case-sensitive: refused" "$(decision "$out")" deny
check "refusal writes no record" "$(lines)" "$n"
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
check "refusal event name" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" PreToolUse
for w in 'WORKNOTE:' 'COMPLEXITY:' 'COMMITS:' 'MODEL-FIT:'; do
  case "$reason" in *"$w"*) ok "the refusal restates $w" ;; *) no "the refusal restates $w" ;; esac
done
run "$HOOK" handback "$(handback_payload a1 "Done.${NL}WORKNOTE:   ")"
check "an empty WORKNOTE counts as missing" "$(decision "$out")" deny

fresh
run "$HOOK" handback "$(handback_payload a1 "no note")"; check "refusal 1" "$(decision "$out")" deny
check "refusal count recorded" "$(cat "$W/refusals/a1")" 1
run "$HOOK" handback "$(handback_payload a1 "no note")"; check "refusal 2" "$(decision "$out")" deny
run "$HOOK" handback "$(handback_payload a1 "still no note")"
check "third attempt is allowed" "$(decision "$out")" allow
check "third attempt: no stdout" "$out" ""
check "third attempt logs a missing note" "$(f .kind)/$(f .missing)/$(ty .note)" "note/true/null"
run "$HOOK" handback "$(handback_payload b1 "no note")"
check "agent B is unaffected by A's refusals" "$(decision "$out")" deny
n=$(lines)
run "$HOOK" handback "$(handback_payload "" "no note")"
check "no agent_id: allowed silently" "$rc$out" 0
check "no agent_id: nothing logged" "$(lines)" "$n"
run "$HOOK" handback "$(handback_payload a1 "no note" Bash)"
check "another tool is ignored" "$out" ""
run "$HOOK" handback '{"tool_name":"SubagentHandback","agent_id":"a9","tool_input":{}}'
check "no message at all is refused" "$(decision "$out")" deny
run "$HOOK" handback "$(handback_payload ../../evil "no note")"
check "an agent_id with slashes stays inside the refusals dir" "$(ls "$W/refusals" | grep -c '/')" 0
[ ! -e "$T/evil" ] && [ ! -e "$W/../evil" ] && ok "no file escaped the refusals dir" || no "no file escaped the refusals dir"

echo "turn:"
fresh
run "$HOOK" turn "$(turn_payload "hello there $PRIV")"
check "exit 0 and no stdout" "$rc$out" 0
check "human" "$(f .source)" human
check "human prompt_chars" "$(f .prompt_chars)" "$(printf 'hello there %s' "$PRIV" | wc -c | tr -d ' ')"
check "a human record has no from_agent" "$(f 'has("from_agent")')" false
check "a human record has no tag" "$(f 'has("tag")')" false
check "kind" "$(f .kind)" turn
run "$HOOK" turn "$(turn_payload '<cross-session-message from="x">hi</cross-session-message>')"
check "peer, bare tag" "$(f .source)" peer
run "$HOOK" turn "$(turn_payload "Another Claude session sent a message:${NL}  <cross-session-message from=\"x\">hi")"
check "peer, with the prefix" "$(f .source)" peer
run "$HOOK" turn "$(turn_payload "Another Claude session sent a message: <agent-message from=\"af09\">x")"
check "subagent, with the prefix" "$(f .source)" subagent
check "from_agent, with the prefix" "$(f .from_agent)" af09
run "$HOOK" turn "$(turn_payload "<agent-message from=\"af09f24b3f1dd6f90\">${NL}[Subagent hand-back] $PRIV")"
check "subagent, bare" "$(f .source)" subagent
check "from_agent" "$(f .from_agent)" af09f24b3f1dd6f90
run "$HOOK" turn "$(turn_payload "<task-notification>${NL}done $PRIV")"
check "task" "$(f .source)" task
run "$HOOK" turn "$(turn_payload "<system-reminder>x $PRIV</system-reminder>")"
check "other" "$(f .source)" other
check "other: tag" "$(f .tag)" system-reminder
run "$HOOK" turn "$(turn_payload "Another Claude session sent a message:${NL}${NL}plain words, not a tag")"
check "prefix then plain text is human" "$(f .source)" human
run "$HOOK" turn "$(turn_payload "I think a < b and <3 you")"
check "a < inside or before non-word is human" "$(f .source)" human
run "$HOOK" turn "$(turn_payload "")"
check "empty prompt is human with 0 chars" "$(f .source)/$(f .prompt_chars)" human/0

echo "privacy and modes:"
fresh
run "$HOOK" turn "$(turn_payload "my private thought $PRIV")"
run "$HOOK" turn "$(turn_payload "<agent-message from=\"a\">report $PRIV")"
run "$HOOK" dispatch "$(post_agent Agent "")"
run "$HOOK" handback "$(handback_payload a1 "body $PRIV${NL}WORKNOTE: n${NL}more body $PRIV")"
run "$HOOK" handback "$(handback_payload a2 "body $PRIV")"
run "$HOOK" subagent-start "$(start_payload a1)"
check "five records written" "$(lines)" 5
if grep -q "$PRIV" "$LOG"; then no "no prompt or report text reaches the log"; else ok "no prompt or report text reaches the log"; fi
check "log mode 0600" "$(ls -l "$LOG" | cut -c1-10)" "-rw-------"
check "dir mode 0700" "$(ls -ld "$W" | cut -c1-10)" "drwx------"
[ "$(jq -c . < "$LOG" | wc -l | tr -d ' ')" = 5 ] && ok "every line is one compact JSON object" || no "every line is one compact JSON object"

echo "fail open:"
fresh
for s in dispatch subagent-start handback turn; do
  out=$(printf 'not json' | "$HOOK" $s 2>"$T/err"); rc=$?
  check "$s: bad JSON, exit 0 and silent" "$rc$out" 0
  out=$(printf '' | "$HOOK" $s 2>"$T/err"); rc=$?
  check "$s: empty input, exit 0 and silent" "$rc$out" 0
done
check "nothing logged for bad input" "$(lines)" 0
mkdir -p "$T/nojq"   # a PATH with what the hook needs to start, and no jq
for c in bash cat; do ln -s "$(command -v $c)" "$T/nojq/$c"; done
for s in dispatch subagent-start handback turn; do
  out=$(printf '%s' "$(handback_payload a1 "no note")" | PATH="$T/nojq" "$HOOK" $s 2>"$T/err"); rc=$?
  check "$s: without jq, exit 0 and silent" "$rc$out" 0
done
: > "$T/afile"
export CLAUDE_WORKLOG_DIR="$T/afile/sub"   # a directory that cannot be created
for s in dispatch turn subagent-start; do
  case $s in dispatch) p=$(post_agent Agent "") ;; turn) p=$(turn_payload hi) ;; *) p=$(start_payload a1) ;; esac
  out=$(printf '%s' "$p" | "$HOOK" $s 2>"$T/err"); rc=$?
  [ "$rc" -eq 0 ] && ok "$s: unwritable log dir, exit 0" || no "$s: unwritable log dir, exit $rc"
  [ ! -s "$T/err" ] && ok "$s: unwritable log dir, no stderr" || no "$s: unwritable log dir, stderr: $(cat "$T/err")"
done
run "$HOOK" handback "$(handback_payload a1 "WORKNOTE: n")"
check "unwritable log dir: a good hand-back is allowed" "$rc$(decision "$out")" 0allow
run "$HOOK" handback "$(handback_payload a1 "no note")"
check "unwritable log dir: a missing WORKNOTE is still refused" "$rc$(decision "$out")" 0deny
run "$HOOK" handback "$(handback_payload a1 "no note")"
run "$HOOK" handback "$(handback_payload a1 "no note")"
check "unwritable refusal counter reads as 0, so it keeps refusing" "$(decision "$out")" deny
export CLAUDE_WORKLOG_DIR="$W"
out=$(printf '%s' "$(turn_payload hi)" | "$HOOK" 2>"$T/err"); rc=$?
check "no subcommand does nothing" "$rc$out" 0
out=$(printf '%s' "$(turn_payload hi)" | "$HOOK" bogus 2>"$T/err"); rc=$?
check "an unknown subcommand does nothing" "$rc$out" 0

echo "broken copies (the guards must be load-bearing):"
fresh
grep -q '^[[:space:]]*deny "' "$HOOK" || no 'broken-copy target not found in hook: deny "'
b="$T/broken-refusal"; sed 's/^\([[:space:]]*\)deny "/\1: "/' "$HOOK" > "$b"; chmod +x "$b"
cmp -s "$HOOK" "$b" && no "refusal-less copy is identical to the hook (sed matched nothing)"
run "$b" handback "$(handback_payload a1 "no note")"
check "with the refusal removed, a report without WORKNOTE passes" "$(decision "$out")" allow

grep -q 'select(.tool_name == "Agent" or .tool_name == "Task")' "$HOOK" || no "broken-copy target not found in hook: the dispatch tool filter"
b="$T/broken-filter"; sed 's/select(\.tool_name == "Agent" or \.tool_name == "Task")/select(true)/' "$HOOK" > "$b"; chmod +x "$b"
cmp -s "$HOOK" "$b" && no "filter-less copy is identical to the hook (sed matched nothing)"
run "$b" dispatch "$(post_agent Bash "")"
check "with the tool filter removed, another tool is recorded" "$(lines)" 1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
