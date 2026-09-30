#!/usr/bin/env bash
# Tests for `claude-context-probe --fleet`, against a stub `claude` that keeps its "sessions" in a
# state file, so nothing here starts a real background session or needs a login.
#
# The stub simulates: `--bg` (adds a row and writes a transcript under a fake HOME), `agents --json`
# (prints the rows; respawns a resumed session whose pid was killed), `rm`, `attach`, `-p` replies
# and `--version`. FAKE_MODE bends it:
#   normal      everything works
#   bgfail      `--bg` exits non-zero and creates nothing
#   nolist      `--bg` exits 0 but the session never appears in `agents --json`
#   noenv       the session's reply carries TMPDIR but not the settings-injected variable
#   rmkeeps     `rm` exits 0 but leaves the row listed
#   norespawn   a killed session is not brought back
#   bad1m       `-p --model opus[1m]` fails
#   noworkflow  the tool listing omits Workflow
#   exited      every listed row has state "exited"
# FAKE_PID=1 makes `agents --json` rows carry a pid, as on versions that list one.

set -u

PROBE="$(cd "$(dirname "$0")/.." && pwd)/private_dot_local/bin/executable_claude-context-probe"
pass=0; fail=0
has() { grep -q -- "$2" <<< "$1"; }
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

TMP=$(mktemp -d) || exit 1
STATE="$TMP/state"; FHOME="$TMP/home"
cleanup_stub() { [ -f "$STATE/rows" ] && while IFS='|' read -r _ _ pid _; do kill "$pid" 2>/dev/null; done < "$STATE/rows"; rm -rf "$TMP"; }
trap cleanup_stub EXIT

cat > "$TMP/claude" <<'EOF'
#!/usr/bin/env bash
S=$FAKE_STATE; mode=${FAKE_MODE:-normal}
mkdir -p "$S"; touch "$S/rows" "$S/log"
printf '%s\n' "$*" >> "$S/args"
alive() { kill -0 "$1" 2>/dev/null && case $(ps -o stat= -p "$1" 2>/dev/null) in Z*|'') return 1 ;; esac; }
spawn() { sleep 300 </dev/null >/dev/null 2>&1 & echo $!; }
list_rows() {
  local out="" first=1 id name pid sid cwd
  : > "$S/rows.new"
  while IFS='|' read -r id name pid sid cwd; do
    if [ "$mode" != norespawn ] && case $name in *-r) true ;; *) false ;; esac && ! alive "$pid"; then
      pid=$(spawn)
    fi
    printf '%s|%s|%s|%s|%s\n' "$id" "$name" "$pid" "$sid" "$cwd" >> "$S/rows.new"
    [ $first -eq 1 ] || out="$out,"; first=0
    # The default rows carry exactly the keys measured on Claude Code 2.1.285 (no pid); FAKE_PID=1
    # adds one, for versions that list it.
    extra=""; [ "${FAKE_PID:-0}" = 1 ] && extra="\"pid\":$pid,"
    state=working; [ "$mode" = exited ] && state=exited
    out="$out{\"cwd\":\"$cwd\",\"id\":\"$id\",\"kind\":\"background\",${extra}\"name\":\"$name\",\"sessionId\":\"$sid\",\"startedAt\":\"2026-01-01T00:00:00Z\",\"state\":\"$state\"}"
  done < "$S/rows"
  mv "$S/rows.new" "$S/rows"
  printf '[%s]\n' "$out"
}
case "${1:-}" in
  --version) echo "9.9.9 (Claude Code)" ;;
  agents) list_rows ;;
  rm)
    printf 'rm %s\n' "$2" >> "$S/log"
    while IFS='|' read -r id name pid sid cwd; do
      if [ "$id" = "$2" ] || [ "$name" = "$2" ]; then
        kill "$pid" 2>/dev/null
        [ "$mode" = rmkeeps ] && printf '%s|%s|%s|%s|%s\n' "$id" "$name" "$pid" "$sid" "$cwd" >> "$S/rows.new"
      else
        printf '%s|%s|%s|%s|%s\n' "$id" "$name" "$pid" "$sid" "$cwd" >> "$S/rows.new"
      fi
    done < "$S/rows"
    : >> "$S/rows.new"; mv "$S/rows.new" "$S/rows" ;;
  attach) printf 'attach %s\n' "$2" >> "$S/log"; sleep 60 ;;
  --bg)
    [ "$mode" = bgfail ] && { echo "launch failed" >&2; exit 1; }
    name=""; sid=""; settings=""; prompt=""
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=$2; shift 2 ;; --resume) sid=$2; shift 2 ;; --settings) settings=$2; shift 2 ;;
        --model|--allowedTools) shift 2 ;; --) prompt=$2; break ;; *) prompt=$1; shift ;;
      esac
    done
    [ "$mode" = nolist ] && exit 0
    n=$(( $(wc -l < "$S/log") + 1 ))
    id="id$n"; newsid="sid$n"; pid=$(spawn)
    printf '%s|%s|%s|%s|%s\n' "$id" "$name" "$pid" "$newsid" "$PWD" >> "$S/rows"
    printf 'created %s\n' "$id" >> "$S/log"
    sub=projects
    mkdir -p "$FAKE_HOME/.claude/$sub/proj"
    t="$FAKE_HOME/.claude/$sub/proj/$newsid.jsonl"
    printf '{"type":"user","message":"%s"}\n' "$prompt" > "$t"
    case "$prompt" in *printenv*)
      nonce=$(sed -n 's/.*"CCPROBE_ENV":"\([^"]*\)".*/\1/p' <<< "$settings")
      td=$(sed -n 's/.*"CLAUDE_CODE_TMPDIR":"\([^"]*\)".*/\1/p' <<< "$settings")
      if [ "$mode" = noenv ]; then reply="CCPROBE-FLEET: $td/claude-1000"; else reply="CCPROBE-FLEET: $nonce $td/claude-1000"; fi
      printf '{"type":"assistant","message":"%s"}\n' "$reply" >> "$t" ;;
    esac ;;
  -p)
    prompt=""; model=""
    while [ $# -gt 0 ]; do case "$1" in --model) model=$2; shift 2 ;; -p|--no-session-persistence) shift ;; --max-turns) shift 2 ;; *) prompt=$1; shift ;; esac; done
    case "$prompt" in
      *tools*) if [ "$mode" = noworkflow ]; then echo "Bash, Read, Agent, EnterWorktree, SendMessage, ListAgents"; else echo "Bash, Read, Agent, Workflow, EnterWorktree, SendMessage, ListAgents"; fi ;;
      *) [ "$mode" = bad1m ] && [ "$model" = 'opus[1m]' ] && { echo "model unavailable" >&2; exit 1; }; echo OK ;;
    esac ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$TMP/claude"
export CLAUDE_CONTEXT_PROBE_CLAUDE="$TMP/claude" FAKE_STATE="$STATE" FAKE_HOME="$FHOME"
export CLAUDE_CONTEXT_PROBE_FLEET_WAIT=3 CLAUDE_CONTEXT_PROBE_FLEET_ATTACH_WAIT=1

run() { rm -rf "$STATE" "$FHOME"; mkdir -p "$FHOME"; FAKE_MODE=$1 HOME="$FHOME" bash "$PROBE" --fleet 2>/dev/null; }
# Every session the stub created must have had `rm` called on it.
cleaned() {
  local id
  for id in $(sed -n 's/^created //p' "$STATE/log" 2>/dev/null); do
    grep -qx "rm $id" "$STATE/log" || return 1
  done
  return 0
}
row() { has "$1" "^  $2  *$3"; }

printf '\n== all-green stub (rows carry a pid) ==\n'
out=$(FAKE_PID=1 run normal); rc=$?
[ "$rc" -eq 0 ] && ok "exit status 0" || bad "green run exit status" "rc=$rc: $out"
has "$out" '^claude-context-probe --fleet: Claude Code 9.9.9' && ok "header names the tool, version" || bad "header" "$out"
has "$out" '^run with: claude-context-probe --fleet$' && ok "closing line names the command" || bad "closing line" "$out"
for r in bg-launch agents-json agents-pid agents-state settings-env tmpdir transcript attach resume-bg rm respawn; do
  row "$out" "$r" yes && ok "$r yes" || bad "$r not yes" "$out"
done
for m in haiku sonnet opus 'opus\[1m\]'; do
  row "$out" "model $m" yes && ok "model $m yes" || bad "model $m not yes" "$out"
done
for t in Agent Workflow EnterWorktree SendMessage ListAgents; do
  row "$out" "tool $t" present && ok "tool $t present" || bad "tool $t" "$out"
done
row "$out" 'tool Bash' 'present (run_in_background' && ok "Bash reported as present only" || bad "Bash row" "$out"
nonce=$(sed -n 's/.*"CCPROBE_ENV":"\([^"]*\)".*/\1/p' "$STATE/args" | head -n 1)
[ -n "$nonce" ] && ok "the stub saw a nonce in --settings" || bad "no nonce reached the stub" "$(cat "$STATE/args")"
tdir=$(sed -n 's/.*"CLAUDE_CODE_TMPDIR":"\([^"]*\)".*/\1/p' "$STATE/args" | head -n 1)
{ [ -n "$nonce" ] && has "$out" "$nonce"; } && bad "the nonce leaked into the output" "$out" || ok "no nonce in the output"
{ [ -n "$tdir" ] && has "$out" "$tdir"; } && bad "the tempdir leaked into the output" "$out" || ok "no tempdir in the output"
has "$out" "$TMP" && bad "a machine path leaked into the output" "$out" || ok "no path in the output"
has "$out" 'ccprobe-fleet' && bad "the session name leaked into the output" "$out" || ok "no session name in the output"
cleaned && ok "rm was called for every session created" || bad "a session was not removed" "$(cat "$STATE/log")"
[ -n "$tdir" ] && [ ! -e "$tdir" ] && ok "the temp dir is gone" || bad "temp dir left behind" "$tdir"
grep -q -- '--tools' "$STATE/args" && bad "--fleet ran a context session" || ok "--fleet runs only fleet checks"
grep -q -- '--bg -n ccprobe-fleet-' "$STATE/args" && ok "the session is named ccprobe-fleet-<nonce>" || bad "session name" "$(cat "$STATE/args")"

printf '\n== rows as measured on 2.1.285: no pid ==\n'
out=$(run normal); rc=$?
row "$out" agents-json yes && ok "agents-json yes without a pid" || bad "agents-json needs no pid" "$out"
row "$out" agents-pid no && ok "agents-pid no" || bad "agents-pid" "$out"
row "$out" agents-state yes && ok "agents-state yes" || bad "agents-state" "$out"
row "$out" respawn 'INCONCLUSIVE (no pid to kill on this version)' && ok "respawn INCONCLUSIVE with no pid" || bad "respawn without pid" "$out"
for r in bg-launch settings-env tmpdir transcript attach resume-bg rm; do
  row "$out" "$r" yes && ok "$r yes without a pid" || bad "$r not yes without a pid" "$out"
done
[ "$rc" -ne 0 ] && ok "a row that is not yes makes the exit status non-zero" || bad "exit status" "rc=$rc"
cleaned && ok "cleanup" || bad "cleanup" "$(cat "$STATE/log")"

printf '\n== rows that carry a pid ==\n'
out=$(FAKE_PID=1 run normal)
row "$out" agents-pid yes && row "$out" agents-state yes && ok "agents-pid yes when rows carry a pid" || bad "agents-pid with pid" "$out"

printf '\n== rows whose state says exited ==\n'
out=$(run exited)
row "$out" attach no && row "$out" resume-bg no && ok "an exited state is not live" || bad "exited state read as live" "$out"

printf '\n== --bg fails ==\n'
out=$(run bgfail); rc=$?
[ "$rc" -ne 0 ] && row "$out" bg-launch no && ok "bg-launch no, non-zero exit" || bad "bgfail" "rc=$rc: $out"
for r in agents-json agents-pid agents-state settings-env tmpdir transcript attach resume-bg rm respawn; do
  row "$out" "$r" 'INCONCLUSIVE (' && ok "$r INCONCLUSIVE" || bad "$r not INCONCLUSIVE" "$out"
done
row "$out" 'model haiku' yes && ok "independent rows still run" || bad "model row skipped" "$out"
cleaned && ok "cleanup after a failed launch" || bad "cleanup" "$(cat "$STATE/log")"

printf '\n== the session never lists ==\n'
out=$(run nolist); rc=$?
[ "$rc" -ne 0 ] && row "$out" bg-launch yes && row "$out" agents-json no && ok "agents-json no" || bad "nolist" "rc=$rc: $out"
row "$out" settings-env 'INCONCLUSIVE (' && ok "dependents INCONCLUSIVE" || bad "dependents" "$out"
grep -q '^rm ccprobe-fleet-' "$STATE/log" && ok "an unlisted session is removed by name" || bad "no rm by name" "$(cat "$STATE/log")"

printf '\n== the env is not delivered ==\n'
out=$(run noenv); rc=$?
row "$out" settings-env no && row "$out" tmpdir yes && ok "settings-env no, tmpdir still yes" || bad "noenv" "$out"
cleaned && ok "cleanup" || bad "cleanup" "$(cat "$STATE/log")"

printf '\n== rm leaves the row ==\n'
out=$(run rmkeeps); rc=$?
row "$out" rm no && ok "rm no" || bad "rmkeeps" "$out"

printf '\n== a killed session does not come back ==\n'
out=$(FAKE_PID=1 run norespawn); rc=$?
row "$out" respawn no && row "$out" rm yes && ok "respawn no" || bad "norespawn" "$out"
cleaned && ok "cleanup" || bad "cleanup" "$(cat "$STATE/log")"

printf '\n== one model fails, one tool is missing ==\n'
out=$(run bad1m)
row "$out" 'model opus\[1m\]' no && row "$out" 'model opus' yes && ok "only the failing alias reads no" || bad "bad1m" "$out"
out=$(run noworkflow)
row "$out" 'tool Workflow' absent && row "$out" 'tool Agent' present && ok "an absent tool reads absent" || bad "noworkflow" "$out"

printf '\n== --help and --keep ==\n'
out=$(bash "$PROBE" --help 2>&1)
has "$out" "fleet" && ok "--help documents --fleet" || bad "help" "$out"
rm -rf "$STATE" "$FHOME"; mkdir -p "$FHOME"
out=$(FAKE_MODE=normal HOME="$FHOME" bash "$PROBE" --fleet --keep 2>/dev/null)
kept=$(sed -n 's/^kept: //p' <<< "$out")
[ -n "$kept" ] && [ -d "$kept" ] && ok "--fleet --keep leaves the temp dir and prints it" || bad "keep" "$out"
rm -rf "$kept"
cleaned && ok "sessions are still removed with --keep" || bad "cleanup with --keep" "$(cat "$STATE/log")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
