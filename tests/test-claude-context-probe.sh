#!/usr/bin/env bash
# Tests for claude-context-probe, against a fake `claude` so they run without a network or a login.
#
# The probe is only worth running if its verdicts can be believed, so these cases are about the
# classifier more than the happy path: a model that leaks the unreferenced codeword must make the
# run INVALID, a model that answers nothing must make it INCONCLUSIVE rather than "NOT loaded"
# everywhere, and a hook that runs but whose context never arrives must read differently from a
# hook that never ran.

set -u

PROBE="$(cd "$(dirname "$0")/.." && pwd)/private_dot_local/bin/executable_claude-context-probe"
pass=0; fail=0
has() { grep -q -- "$2" <<< "$1"; }
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# The fake answers from what a real session would plausibly see: the CLAUDE.md and AGENTS.md in its
# own directory, plus, when asked, the output of the hooks named in --settings. FAKE_MODE bends it:
#   normal    answer honestly
#   leak      also report the codeword from the file nothing references
#   silent    answer NONE
#   fail      exit non-zero
#   hookdrop  run the hooks but do not report their context
#   nohooks   never run the hooks (as under a policy that blocks them)
#   modelbash invoke the dynamic skill, then also run a shell command itself
#   policy    render the dynamic skill as a policy that disables shell execution would
#   readctx   in the read session, also read a context file directly
#   fewreads  in the read session, read only two of the three data files
#   noinject  in the read session, read the files but receive no context scoped to them
cat > "$TMP/claude" <<'EOF'
#!/usr/bin/env bash
mode=${FAKE_MODE:-normal}
if [ "${1:-}" = --version ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
settings=""
while [ $# -gt 0 ]; do
  case "$1" in
    --settings) settings=$2; shift 2 ;;
    # Under disableSideloadFlags the real client rejects this flag at startup, ending the session.
    --mcp-config) [ -n "${FAKE_REJECT_MCP:-}" ] && { echo "--mcp-config is rejected by managed policy" >&2; exit 2; }; shift ;;
    *) shift ;;
  esac
done
ask=$(cat)
# Record the fixture's shape from where a session is rooted: the bare-container layout's session
# directory is <container>/main, and its parent's .git is what the layout names.
if [ -n "${FAKE_SHAPE_LOG:-}" ] && [ "$(basename "$PWD")" = main ] && [ -e ../CLAUDE.md ]; then
  if [ -d ../.git ] && [ -f ../.git/HEAD ] && [ ! -e ../.bare ]; then echo container-git-is-bare-repo >> "$FAKE_SHAPE_LOG"
  else echo container-other-shape >> "$FAKE_SHAPE_LOG"; fi
fi
[ "$mode" = fail ] && exit 3
if [ "$mode" = silent ]; then echo NONE; exit 0; fi
for f in CLAUDE.md AGENTS.md; do [ -f "$f" ] && grep -o 'CCPROBE-[A-Z]*-[0-9]*' "$f"; done
# A rules file without a paths: scope loads at session start.
for f in .claude/rules/*.md; do [ -f "$f" ] && ! grep -q '^paths:' "$f" && grep -o 'CCPROBE-[A-Z]*-[0-9]*' "$f"; done
case "$ask" in *"Use the Read tool"*)
  files="sub/data.txt pkg/data.txt scoped/data.txt"
  [ "$mode" = fewreads ] && files="sub/data.txt pkg/data.txt"
  [ "$mode" = readctx ] && files="$files pkg/AGENTS.md"
  for f in $files; do printf '{"type":"tool_use","name":"Read","input":{"file_path":"%s/%s"}}\n' "$PWD" "$f"; done
  if [ "$mode" != noinject ]; then
    # What the harness attaches when those files are read: the nested CLAUDE.md, what it imports,
    # and the rules file whose paths: scope matches.
    grep -o 'CCPROBE-[A-Z]*-[0-9]*' sub/CLAUDE.md pkg/AGENTS.md .claude/rules/probe-scoped.md | sed 's/^[^:]*://'
  fi
  ;;
esac
if [ -n "$settings" ] && [ "$mode" != nohooks ]; then
  for cmd in $(grep -o '"command": "[^"]*"' "$settings" | sed 's/"command": "//; s/"$//'); do
    out=$("$cmd")
    [ "$mode" = hookdrop ] || grep -o 'CCPROBE-[A-Z]*-[0-9]*' <<< "$out"
  done
fi
case "$ask" in *probe-dynamic*)
  echo '{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"probe-dynamic"}}'
  cmd=$(sed -n 's/^!`\(.*\)`$/\1/p' .claude/skills/probe-dynamic/SKILL.md)
  if [ "$mode" = policy ]; then echo '[shell command execution disabled by policy]'; else sh -c "$cmd"; fi
  [ "$mode" = modelbash ] && echo '{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls"}}'
  ;;
esac
if [ "$mode" = leak ]; then
  d=$PWD
  while [ "$d" != / ]; do
    [ -f "$d/unreferenced.md" ] && { grep -o 'CCPROBE-[A-Z]*-[0-9]*' "$d/unreferenced.md"; break; }
    d=$(dirname "$d")
  done
fi
exit 0
EOF
chmod +x "$TMP/claude"
export CLAUDE_CONTEXT_PROBE_CLAUDE="$TMP/claude"

run() { FAKE_MODE=$1 bash "$PROBE" 2>/dev/null; }

printf '\n== the container fixture has the current shape ==\n'
: > "$TMP/shape.log"; FAKE_SHAPE_LOG="$TMP/shape.log" FAKE_MODE=normal bash "$PROBE" >/dev/null 2>&1
grep -q container-git-is-bare-repo "$TMP/shape.log" && ! grep -q container-other-shape "$TMP/shape.log" \
  && ok "the container's .git is the bare repository, with no .bare" || bad "container fixture shape" "$(cat "$TMP/shape.log")"

printf '\n== an honest model ==\n'
out=$(run normal); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'bare-container=OK  plain-clone=OK  agents-only=OK  dynamic-skill=OK' \
  && ok "all three sessions are OK and the exit status is 0" || bad "honest run not OK" "rc=$rc: $out"
has "$out" 'repository root (positive control) *loaded' && ok "the positive control reads loaded" || bad "control not loaded" "$out"
has "$out" 'container above a worktree (.git file) *NOT loaded' \
  && ok "a file the model did not report reads NOT loaded" || bad "unreported file not NOT loaded" "$out"
has "$out" 'AGENTS.md alone, with no CLAUDE.md *loaded' && ok "AGENTS.md is read from its own session" || bad "AGENTS.md row wrong" "$out"
has "$out" 'SessionStart hook *ran=yes, delivered=yes' && ok "a hook that ran and was reported: ran=yes, delivered=yes" || bad "hook row wrong" "$out"
has "$out" 'UserPromptSubmit): end *ran=yes, delivered=yes' && ok "the large hook's tail codeword is found" || bad "large hook tail not found" "$out"
has "$out" 'nothing references was not seen' && ok "the negative control reads not seen" || bad "negative control line wrong" "$out"
has "$out" '9.9.9' && ok "the version is reported" || bad "version missing" "$out"
has "$out" "$TMP" && bad "a machine path leaked into the summary" "the summary must carry no paths" \
  || ok "no path from the machine appears in the summary"

has "$out" 'on-demand=OK' && ok "the read session is OK when it read exactly the three data files" || bad "read session not OK" "$out"
has "$out" 'without paths:, at session start *loaded' && ok "an unscoped rules file reads loaded at session start" || bad "unscoped rule row wrong" "$out"
has "$out" 'with paths:, at session start *NOT loaded' && ok "a scoped rules file reads NOT loaded at session start" || bad "scoped rule at start row wrong" "$out"
has "$out" 'importing AGENTS.md, at session start *NOT loaded' && ok "the nested import reads NOT loaded at session start" || bad "nested import at start row wrong" "$out"
has "$out" 'nested CLAUDE.md, after reading a file beside it *loaded' && ok "the nested CLAUDE.md reads loaded after a read" || bad "nested after read row wrong" "$out"
has "$out" 'importing AGENTS.md, after reading beside *loaded' && ok "the nested import reads loaded after a read" || bad "nested import after read row wrong" "$out"
has "$out" 'matching file *loaded' && ok "the scoped rules file reads loaded after a matching read" || bad "scoped rule after read row wrong" "$out"

printf '\n== the read session reads a context file itself ==\n'
out=$(run readctx); rc=$?
[ "$rc" -ne 0 ] && has "$out" 'on-demand=INCONCLUSIVE' && has "$out" 'after reading a file beside it *INCONCLUSIVE' \
  && ok "a codeword the model could have read directly is not counted" || bad "direct read of a context file counted" "rc=$rc: $out"

printf '\n== the read session reads too few files ==\n'
out=$(run fewreads)
has "$out" 'on-demand=INCONCLUSIVE' && ok "a session that skipped a data file is INCONCLUSIVE, not NOT loaded" || bad "missing read not caught" "$out"

printf '\n== the files are read and nothing scoped to them arrives ==\n'
out=$(run noinject)
has "$out" 'on-demand=OK' && has "$out" 'after reading a file beside it *NOT loaded' && has "$out" 'matching file *NOT loaded' \
  && ok "on-demand context that never arrives reads NOT loaded" || bad "missing injection misread" "$out"

printf '\n== a model that reports the unreferenced codeword ==\n'
out=$(run leak); rc=$?
[ "$rc" -ne 0 ] && has "$out" 'bare-container=INVALID' && has "$out" 'SEEN (results invalid)' \
  && ok "the run is INVALID and the exit status is non-zero" || bad "leak not caught" "rc=$rc: $out"
has "$out" 'positive control) *INVALID' && ok "no row claims loaded in an invalid session" || bad "an invalid session still gave verdicts" "$out"

printf '\n== a model that answers nothing ==\n'
out=$(run silent); rc=$?
[ "$rc" -ne 0 ] && has "$out" 'bare-container=INCONCLUSIVE' && ! has "$out" 'NOT loaded' \
  && ok "INCONCLUSIVE, never a wall of NOT loaded" || bad "silent model read as NOT loaded" "rc=$rc: $out"

printf '\n== a session that fails ==\n'
out=$(run fail); rc=$?
[ "$rc" -ne 0 ] && has "$out" 'plain-clone=INCONCLUSIVE' \
  && ok "a non-zero claude exit makes the session INCONCLUSIVE" || bad "failed session not INCONCLUSIVE" "rc=$rc: $out"

printf '\n== hooks that run but whose context never arrives ==\n'
out=$(run hookdrop); rc=$?
has "$out" 'SessionStart hook *ran=yes, delivered=no' \
  && ok "ran=yes, delivered=no, distinct from a hook that never ran" || bad "dropped hook context misread" "$out"

has "$out" 'SKILL.md) *delivered' && ok "a skill's injected command output reads delivered" || bad "dynamic context row wrong" "$out"

printf '\n== the model runs the command itself ==\n'
out=$(run modelbash)
has "$out" 'SKILL.md) *INCONCLUSIVE (the model ran a shell command itself)' \
  && ok "a codeword the model could have fetched itself is not counted as delivered" || bad "model's own shell call counted as delivery" "$out"

printf '\n== a policy that disables skill shell execution ==\n'
out=$(run policy)
has "$out" 'SKILL.md) *NOT delivered (disabled by policy)' \
  && ok "the policy placeholder is named as the cause" || bad "policy-disabled dynamic context misread" "$out"

printf '\n== hooks that never run ==\n'
out=$(run nohooks); rc=$?
has "$out" 'SessionStart hook *ran=no, delivered=no' \
  && ok "ran=no when the hook's marker was never written" || bad "a hook that never ran read as ran" "$out"

# ---- managed policy: rows the policy makes unmeasurable read POLICY, not INCONCLUSIVE ----------------
# The fixture stands in for /etc/claude-code/managed-settings.json; the probe reads the path from
# CLAUDE_CONTEXT_PROBE_MANAGED_SETTINGS so no test depends on a real managed machine.
prun() { # <fixture json> <fake mode> [extra env as VAR=value...]
  local json=$1 mode=$2; shift 2
  printf '%s\n' "$json" > "$TMP/managed.json"
  env CLAUDE_CONTEXT_PROBE_MANAGED_SETTINGS="$TMP/managed.json" FAKE_MODE=$mode "$@" bash "$PROBE" 2>/dev/null
}

printf '\n== no policy keys: no banner, rows as before ==\n'
out=$(prun '{"env":{"X":"1"},"allowManagedHooksOnly":false}' normal)
! has "$out" 'POLICY' && has "$out" 'SessionStart hook *ran=yes, delivered=yes' \
  && ok "a false or absent policy key adds no banner and no POLICY row" || bad "policy output without a policy key" "$out"

printf '\n== allowManagedHooksOnly ==\n'
out=$(prun '{ "allowManagedHooksOnly" : true }' nohooks)
has "$out" 'allowManagedHooksOnly *hooks passed with --settings do not run' \
  && ok "the banner names the key and what it makes unmeasurable" || bad "banner missing or wrong" "$out"
has "$out" '4 rows suppressed as POLICY' && ok "the banner counts the suppressed rows" || bad "row count missing" "$out"
has "$out" 'SessionStart hook *POLICY (allowManagedHooksOnly)' && has "$out" 'hook context (UserPromptSubmit): end *POLICY' \
  && ok "the four hook rows read POLICY, not ran=no" || bad "hook rows not POLICY" "$out"
! has "$out" 'ran=no' && ok "no hook row reads as a failure" || bad "a hook row still reads ran=no" "$out"
bl=$(grep -n 'POLICY: managed settings' <<< "$out" | head -1 | cut -d: -f1); fl=$(grep -n 'Instruction files' <<< "$out" | head -1 | cut -d: -f1)
[ -n "$bl" ] && [ -n "$fl" ] && [ "$bl" -lt "$fl" ] && ok "the banner comes before the first row" || bad "banner not at the top" "banner line ${bl:-none}, rows line ${fl:-none}"
has "$out" 'positive control) *loaded' && has "$out" 'bare-container=OK' \
  && ok "rows the policy does not touch are still measured" || bad "unaffected rows lost" "$out"

printf '\n== disableAllHooks ==\n'
out=$(prun '{"disableAllHooks":true}' nohooks)
has "$out" 'disableAllHooks *hooks passed with --settings' && has "$out" 'UserPromptSubmit hook *POLICY (disableAllHooks)' \
  && ok "disableAllHooks marks the hook rows POLICY too" || bad "disableAllHooks not handled" "$out"

printf '\n== disableSideloadFlags ==\n'
# CONTROL: the fake rejects --mcp-config like the real client does; with no policy file the probe
# passes the flag, session A dies, and the run is a wall of INCONCLUSIVE. This shows the fake can fail.
out=$(prun '{}' normal FAKE_REJECT_MCP=1)
has "$out" 'bare-container=INCONCLUSIVE' && ok "control: a rejected --mcp-config makes the session INCONCLUSIVE" || bad "control did not fail" "$out"
out=$(prun '{"disableSideloadFlags": true}' normal FAKE_REJECT_MCP=1)
has "$out" 'disableSideloadFlags *--mcp-config is rejected at startup' && ok "the banner names disableSideloadFlags" || bad "sideload banner missing" "$out"
has "$out" 'stdio MCP server tool listed (--mcp-config) *POLICY (disableSideloadFlags)' && ok "the MCP row reads POLICY" || bad "MCP row not POLICY" "$out"
has "$out" 'bare-container=OK' && has "$out" '1 rows suppressed as POLICY' \
  && ok "the flag is left off, so the other rows are still measured, and the count is 1" || bad "session A still died or count wrong" "$out"

printf '\n== both, and the exit status ==\n'
out=$(prun '{"allowManagedHooksOnly":true,"disableSideloadFlags":true}' nohooks FAKE_REJECT_MCP=1); rc=$?
has "$out" '5 rows suppressed as POLICY' && [ "$rc" -eq 0 ] \
  && ok "two keys: five rows, and POLICY rows do not fail the run" || bad "combined policy wrong" "rc=$rc: $out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
