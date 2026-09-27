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
cat > "$TMP/claude" <<'EOF'
#!/usr/bin/env bash
mode=${FAKE_MODE:-normal}
if [ "${1:-}" = --version ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
settings=""
while [ $# -gt 0 ]; do
  case "$1" in --settings) settings=$2; shift 2 ;; *) shift ;; esac
done
cat > /dev/null
[ "$mode" = fail ] && exit 3
if [ "$mode" = silent ]; then echo NONE; exit 0; fi
for f in CLAUDE.md AGENTS.md; do [ -f "$f" ] && grep -o 'CCPROBE-[A-Z]*-[0-9]*' "$f"; done
if [ -n "$settings" ] && [ "$mode" != nohooks ]; then
  for cmd in $(grep -o '"command": "[^"]*"' "$settings" | sed 's/"command": "//; s/"$//'); do
    out=$("$cmd")
    [ "$mode" = hookdrop ] || grep -o 'CCPROBE-[A-Z]*-[0-9]*' <<< "$out"
  done
fi
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

printf '\n== an honest model ==\n'
out=$(run normal); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'bare-container=OK  plain-clone=OK  agents-only=OK' \
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

printf '\n== hooks that never run ==\n'
out=$(run nohooks); rc=$?
has "$out" 'SessionStart hook *ran=no, delivered=no' \
  && ok "ran=no when the hook's marker was never written" || bad "a hook that never ran read as ran" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
