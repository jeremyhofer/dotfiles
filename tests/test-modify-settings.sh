#!/bin/sh
# Test the modify_ script that manages ~/.claude/settings.json as a PARTIAL file: the base's own
# defaults, then an optional domain fragment's declared block, merged over whatever the live file
# holds. Pins the contract: live-only keys survive, the fragment wins over the base, declared arrays
# replace wholesale, retired hooks named by the fragment are stripped, and every failure (no jq, a
# broken fragment, unparseable input) changes as little as possible rather than writing something
# broken.
set -u
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../dot_claude/modify_settings.json"
TMP=$(mktemp -d "$_TMP/test-modify-settings.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
fail=0
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }

frag="$TMP/settings-declared"
cat > "$frag" <<'EOF'
#!/usr/bin/env bash
cat <<JSON
{
  "declared": {
    "editorMode": "emacs",
    "sandbox": { "enabled": true, "filesystem": { "allowWrite": ["~/granted"] } },
    "hooks": { "Stop": [ { "hooks": [ { "command": "${HOME}/keep.sh", "type": "command" } ] } ] }
  },
  "retiredHooks": ["old-hook.sh"]
}
JSON
EOF
# The context cap file is pointed at a path that does not exist unless a case sets CAP, so no case
# reads this machine's own ~/.dotlocal/claude/context-cap-percent.
run() { printf '%s' "$1" | CLAUDE_SETTINGS_FRAGMENT="$2" CLAUDE_CONTEXT_CAP_FILE="${CAP:-$TMP/no-cap}" bash "$SCRIPT" 2>"$TMP/err"; }
val() { printf '%s' "$1" | jq -r "$2"; }

# A) no fragment: a fresh machine gets the base defaults only
out=$(run '' "$TMP/absent")
printf '%s' "$out" | jq -e . >/dev/null 2>&1 || { echo "FAIL: empty input must yield valid JSON"; fail=1; }
[ "$(val "$out" '.statusLine.type')" = "command" ] || { echo "FAIL: base must declare the status line"; fail=1; }
[ "$(val "$out" '.editorMode')" = "vim" ] || { echo "FAIL: base default editorMode missing"; fail=1; }
[ "$(val "$out" '.awaySummaryEnabled')" = "false" ] || { echo "FAIL: base must turn the away recap off"; fail=1; }
[ "$(val "$out" '.sandbox')" = "null" ] || { echo "FAIL: base must not declare a sandbox policy"; fail=1; }
# Nx in every Claude Code session runs with no daemon and with plugins in process, so it needs no
# socket at all: a shared NX_SOCKET_DIR let two workspaces' daemons break each other, and newer Nx
# refuses every socket directory inside a sandbox (skill working-with-nx)
[ "$(val "$out" '.env.NX_DAEMON')" = "false" ] && [ "$(val "$out" '.env.NX_ISOLATE_PLUGINS')" = "false" ] \
  || { echo "FAIL: base must set env.NX_DAEMON and env.NX_ISOLATE_PLUGINS to false"; fail=1; }
[ "$(val "$out" '.env.NX_SOCKET_DIR')" = "null" ] || { echo "FAIL: base must not set env.NX_SOCKET_DIR"; fail=1; }
# ...merged into the live env, never replacing it; and a RETIRED key that an earlier apply wrote is
# removed, since the merge alone only adds and the stale value would stay on every applied machine
out=$(run '{"env":{"KEEP_ME":"1","NX_SOCKET_DIR":"/old/s"}}' "$TMP/absent")
[ "$(val "$out" '.env.KEEP_ME')" = "1" ] && [ "$(val "$out" '.env.NX_DAEMON')" = "false" ] \
  || { echo "FAIL: the Nx env must merge into the live env, keeping its other keys"; fail=1; }
[ "$(val "$out" '.env.NX_SOCKET_DIR')" = "null" ] || { echo "FAIL: a live env.NX_SOCKET_DIR must be retired"; fail=1; }
# A live file with no env at all still gets the base's, and a retired key never appears.
out=$(run '{"editorMode":"vim"}' "$TMP/absent")
[ "$(val "$out" '.env | keys | join(",")')" = "NX_DAEMON,NX_ISOLATE_PLUGINS" ] \
  || { echo "FAIL: a live file without env gets exactly the base env: $(val "$out" '.env')"; fail=1; }

# B) the fragment's declared block wins over the base; live-only keys survive; model is untouched
live='{"model":"opus","permissions":{"allow":["Bash(ls:*)"]},"sandbox":{"filesystem":{"allowWrite":["~/ad-hoc"],"denyRead":["~/secret"]}}}'
out=$(run "$live" "$frag")
[ "$(val "$out" '.editorMode')" = "emacs" ] || { echo "FAIL: fragment must win over the base default"; fail=1; }
[ "$(val "$out" '.model')" = "opus" ] || { echo "FAIL: live model must survive"; fail=1; }
[ "$(val "$out" '.permissions.allow | length')" = "1" ] || { echo "FAIL: live permissions.allow must survive"; fail=1; }
[ "$(val "$out" '.sandbox.filesystem.denyRead[0]')" = "~/secret" ] || { echo "FAIL: live-only nested key must survive"; fail=1; }
# declared arrays REPLACE: the ad-hoc live grant is gone, the declared one present
[ "$(printf '%s' "$out" | jq -c '.sandbox.filesystem.allowWrite')" = '["~/granted"]' ] \
  || { echo "FAIL: a declared array must replace the live one"; fail=1; }
[ "$(val "$out" '.statusLine.type')" = "command" ] || { echo "FAIL: base keys must still apply under a fragment"; fail=1; }

# C) retired hooks named by the fragment are stripped from every event; an emptied event is dropped
live='{"hooks":{"Notification":[{"hooks":[{"command":"/x/old-hook.sh","type":"command"}]}],"Stop":[{"hooks":[{"command":"/x/old-hook.sh","type":"command"}]}]}}'
out=$(run "$live" "$frag")
[ "$(val "$out" '.hooks.Notification')" = "null" ] || { echo "FAIL: an event left empty by retirement must be dropped"; fail=1; }
printf '%s' "$out" | jq -e '[.hooks[][].hooks[].command] | any(test("old-hook"))' >/dev/null \
  && { echo "FAIL: a retired hook survived"; fail=1; }
printf '%s' "$out" | jq -e '[.hooks.Stop[].hooks[].command] | any(endswith("/keep.sh"))' >/dev/null \
  || { echo "FAIL: the fragment's own hook must be present"; fail=1; }

# D) a fragment that fails or prints non-JSON is skipped with a warning; the base still applies
bad="$TMP/bad"; printf '#!/bin/sh\necho not-json\n' > "$bad"
out=$(run '{"keep":1}' "$bad")
[ "$(val "$out" '.keep')" = "1" ] || { echo "FAIL: a broken fragment must not lose live keys"; fail=1; }
[ "$(val "$out" '.editorMode')" = "vim" ] || { echo "FAIL: a broken fragment must not block the base"; fail=1; }
grep -q 'settings fragment' "$TMP/err" || { echo "FAIL: a broken fragment must be reported on stderr"; fail=1; }

# E) unparseable live input starts from an empty object rather than corrupting it
out=$(run '{not json' "$TMP/absent")
printf '%s' "$out" | jq -e . >/dev/null 2>&1 || { echo "FAIL: unparseable input must still yield valid JSON"; fail=1; }

# G) worktree.baseRef is NOT declared: Claude Code's own default applies; a live value is left alone
out=$(run '' "$TMP/absent")
[ "$(val "$out" '.worktree.baseRef // "unset"')" = "unset" ] || { echo "FAIL: the base must not declare worktree.baseRef"; fail=1; }
out=$(run '{"worktree":{"baseRef":"head","bgIsolation":"none"}}' "$TMP/absent")
[ "$(val "$out" '.worktree.baseRef')" = "head" ] || { echo "FAIL: a live worktree.baseRef must survive"; fail=1; }

# H) the base wires its own worktree hooks; hook events are UNIONED across the base and the fragment
# (each layer's entries kept), so a fragment declaring the same event does not drop the base's.
cmds() { printf '%s' "$1" | jq -r --arg e "$2" '[.hooks[$e][]?.hooks[]?.command] | join("\n")'; }
out=$(run '' "$TMP/absent")
for pair in 'PreToolUse:claude-worktree-hook bash' 'SubagentStart:claude-worktree-hook subagent-start'; do
  ev=${pair%%:*}; want=${pair#*:}
  cmds "$out" "$ev" | grep -q "$want\$" || { echo "FAIL: base must wire '$want' on $ev"; fail=1; }
done
for ev in SubagentStop SessionStart; do
  cmds "$out" "$ev" | grep -q 'claude-worktree-hook' && { echo "FAIL: the base must not wire claude-worktree-hook on $ev"; fail=1; }
done
# EnterWorktree and ExitWorktree are open to every session (since 2026-11-19): the base wires no hook on
# either tool, and an apply drops the `enter-worktree` refusal a live file still holds from before,
# because the declared PreToolUse list replaces the live one.
no_enter_hook() { # <settings json> <label>
  n=$(printf '%s' "$1" | jq '[.hooks.PreToolUse[]? | select((.matcher // "" | test("EnterWorktree|ExitWorktree")) or any(.hooks[]?; (.command // "") | endswith("enter-worktree")))] | length')
  [ "$n" = 0 ] || { echo "FAIL: $2: $n PreToolUse entries still guard EnterWorktree or ExitWorktree"; fail=1; }
}
no_enter_hook "$out" "the base's own block"
old_live='{"hooks":{"PreToolUse":[{"matcher":"EnterWorktree","hooks":[{"command":"${HOME}/.local/bin/claude-worktree-hook enter-worktree","type":"command"}]}]}}'
no_enter_hook "$(run "$old_live" "$TMP/absent")" "a live file wired before 2026-11-19, after the apply"
[ "$(printf '%s' "$out" | jq -r '[.hooks.PreToolUse[]? | select(.hooks[0].command | endswith("hook bash")) | .matcher][0]')" = "Bash" ] \
  || { echo "FAIL: the git worktree guard must match the Bash tool"; fail=1; }
union_frag="$TMP/union-frag"
cat > "$union_frag" <<'EOF'
#!/usr/bin/env bash
cat <<JSON
{"declared": {"hooks": {"SubagentStart": [ { "hooks": [ { "command": "/x/domain-start.sh", "type": "command" } ] } ]}}}
JSON
EOF
live='{"hooks":{"SubagentStart":[{"hooks":[{"command":"/x/hand-added.sh","type":"command"}]}],"Elicitation":[{"hooks":[{"command":"/x/live-only.sh","type":"command"}]}]}}'
out=$(run "$live" "$union_frag")
cmds "$out" SubagentStart | grep -q 'claude-worktree-hook subagent-start$' || { echo "FAIL: the fragment's SubagentStart dropped the base's"; fail=1; }
cmds "$out" SubagentStart | grep -q '/x/domain-start.sh' || { echo "FAIL: the fragment's SubagentStart entry missing"; fail=1; }
cmds "$out" SubagentStart | grep -q 'hand-added' && { echo "FAIL: a hand-added entry in a declared event must be replaced"; fail=1; }
cmds "$out" Elicitation | grep -q 'live-only' || { echo "FAIL: a live-only hook event must survive"; fail=1; }
again=$(run "$out" "$union_frag")
[ "$(printf '%s' "$again" | jq -S -c .)" = "$(printf '%s' "$out" | jq -S -c .)" ] || { echo "FAIL: a second apply must change nothing"; fail=1; }
dup_frag="$TMP/dup-frag"
printf '#!/usr/bin/env bash\ncat <<JSON\n{"declared": {"hooks": {"SubagentStart": [ { "hooks": [ { "command": "${HOME}/.local/bin/claude-worktree-hook subagent-start", "type": "command" } ] } ]}}}\nJSON\n' > "$dup_frag"
out=$(run '' "$dup_frag")
[ "$(printf '%s' "$out" | jq '[.hooks.SubagentStart[]?] | length')" = "1" ] || { echo "FAIL: an entry declared by both layers must appear once"; fail=1; }

# G) ensureAllow: each rule missing from permissions.allow is appended; every live grant survives,
#    in order, and a rule already present is not duplicated
ens_frag="$TMP/ens-frag"
printf '#!/usr/bin/env bash\ncat <<JSON\n{"declared": {}, "ensureAllow": ["Bash(tool-a:*)", "Bash(ls:*)"]}\nJSON\n' > "$ens_frag"
live='{"permissions":{"allow":["Bash(ls:*)","Bash(cat:*)"],"deny":["Bash(rm:*)"]}}'
out=$(run "$live" "$ens_frag")
[ "$(printf '%s' "$out" | jq -c '.permissions.allow')" = '["Bash(ls:*)","Bash(cat:*)","Bash(tool-a:*)"]' ] \
  || { echo "FAIL: ensureAllow must append only missing rules and keep live ones in order (got: $(printf '%s' "$out" | jq -c '.permissions.allow'))"; fail=1; }
[ "$(val "$out" '.permissions.deny[0]')" = "Bash(rm:*)" ] || { echo "FAIL: ensureAllow must not touch deny"; fail=1; }
out=$(run '' "$ens_frag")
[ "$(printf '%s' "$out" | jq -c '.permissions.allow')" = '["Bash(tool-a:*)","Bash(ls:*)"]' ] \
  || { echo "FAIL: ensureAllow on a fresh machine must create the list"; fail=1; }
again=$(run "$out" "$ens_frag")
[ "$(printf '%s' "$again" | jq -S -c .)" = "$(printf '%s' "$out" | jq -S -c .)" ] || { echo "FAIL: ensureAllow applied twice must change nothing"; fail=1; }

# G) the context cap: a whole percent from 1 to 100 in the cap file becomes
# env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE (Claude Code compacts main sessions and subagents at that share
# of the auto-compact window); with no file the key is removed, since the base owns it; a malformed
# file changes nothing and says so on stderr
printf ' 50\n' > "$TMP/cap50"
out=$(CAP="$TMP/cap50" run '{"env":{"KEEP_ME":"1"}}' "$TMP/absent")
[ "$(val "$out" '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE')" = "50" ] && [ "$(val "$out" '.env.KEEP_ME')" = "1" ] \
  || { echo "FAIL: a cap file of 50 must set env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE to \"50\", keeping other env: $(val "$out" '.env')"; fail=1; }
out=$(run '{"env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"40","KEEP_ME":"1"}}' "$TMP/absent")
[ "$(val "$out" '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE')" = "null" ] && [ "$(val "$out" '.env.KEEP_ME')" = "1" ] \
  || { echo "FAIL: with no cap file, a live CLAUDE_AUTOCOMPACT_PCT_OVERRIDE must be removed: $(val "$out" '.env')"; fail=1; }
for bad in 0 101 50% abc '' 99999999999999999999; do
  printf '%s\n' "$bad" > "$TMP/capbad"
  out=$(CAP="$TMP/capbad" run '{"env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"40"}}' "$TMP/absent")
  [ "$(val "$out" '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE')" = "40" ] \
    || { echo "FAIL: a malformed cap file ('$bad') must leave the live value alone: $(val "$out" '.env')"; fail=1; }
  grep -q 'context-cap' "$TMP/err" || { echo "FAIL: a malformed cap file ('$bad') must be reported on stderr"; fail=1; }
done

# I) retiredEnv: the fragment names env keys an earlier apply wrote and no layer declares any longer;
# each is removed from the live env, since the merge alone only adds. Others survive, a non-string
# entry is ignored, and a key some layer still declares is kept: retiring is cleanup of stale keys,
# so a fragment cannot strip the base's own env (NX_DAEMON) or the context cap.
renv_frag="$TMP/renv-frag"
cat > "$renv_frag" <<'EOF'
#!/usr/bin/env bash
cat <<JSON
{"declared": {"env": {"STILL_DECLARED": "1"}},
 "retiredEnv": ["OLD_A", "OLD_B", "STILL_DECLARED", "NX_DAEMON", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", 7]}
JSON
EOF
live='{"env":{"OLD_A":"1","OLD_B":"x","KEEP_ME":"1","NX_DAEMON":"true"}}'
out=$(CAP="$TMP/cap50" run "$live" "$renv_frag")
[ "$(val "$out" '.env | keys | join(",")')" = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE,KEEP_ME,NX_DAEMON,NX_ISOLATE_PLUGINS,STILL_DECLARED" ] \
  || { echo "FAIL: retiredEnv must remove exactly the stale keys no layer declares: $(val "$out" '.env')"; fail=1; }
[ "$(val "$out" '.env.NX_DAEMON')" = "false" ] && [ "$(val "$out" '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE')" = "50" ] \
  || { echo "FAIL: a retired key that a layer declares keeps its declared value: $(val "$out" '.env')"; fail=1; }
again=$(CAP="$TMP/cap50" run "$out" "$renv_frag")
[ "$(printf '%s' "$again" | jq -S -c .)" = "$(printf '%s' "$out" | jq -S -c .)" ] || { echo "FAIL: retiredEnv applied twice must change nothing"; fail=1; }
# The base's own retired key is still removed alongside the fragment's.
out=$(run '{"env":{"NX_SOCKET_DIR":"/s","OLD_A":"1"}}' "$renv_frag")
[ "$(val "$out" '.env.NX_SOCKET_DIR // "gone"')" = "gone" ] && [ "$(val "$out" '.env.OLD_A // "gone"')" = "gone" ] \
  || { echo "FAIL: the base's and the fragment's retired keys must both be removed: $(val "$out" '.env')"; fail=1; }
# A fragment with no retiredEnv removes nothing beyond the base's own list.
out=$(run '{"env":{"OLD_A":"1"}}' "$frag")
[ "$(val "$out" '.env.OLD_A')" = "1" ] || { echo "FAIL: without retiredEnv a live key must survive"; fail=1; }

# F) no jq on PATH: byte-identical passthrough
nojq="$TMP/nojq"; mkdir -p "$nojq"
for t in bash cat printf; do p=$(command -v "$t") && ln -s "$p" "$nojq/$t"; done
in='{"a":1}'
out=$(printf '%s' "$in" | PATH="$nojq" CLAUDE_SETTINGS_FRAGMENT="$frag" "$nojq/bash" "$SCRIPT")
[ "$out" = "$in" ] || { echo "FAIL: without jq the input must pass through byte-identical (got: $out)"; fail=1; }

[ "$fail" -eq 0 ] && echo PASS
exit "$fail"
