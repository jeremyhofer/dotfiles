#!/usr/bin/env zsh
# Test: `fleet-canonicals request` and `fleet-canonicals serve-requests`, the lifecycle request
# queue. The runner's checks are its containment -- it runs outside every sandbox on a file anyone
# with write access to the queue can write -- so each check gets a planted request it must refuse
# and a control that the same check lets through.
#
# Nothing here reaches a real session or the real state: the fleet record, the state directory,
# the sessions listing, the transcripts, the usage files, the trust check and the `claude` binary
# are all fixtures under one scratch directory, and the `claude` stub records what it was asked.
#
# FLEET_CANONICALS_QUEUE names the queue implementation under test, so a copy with one check
# disabled can be run against this suite to see that check's case fail.
set -u
HERE=${0:A:h}
. "$HERE/git-isolate.sh"
command -v uv >/dev/null 2>&1 || { print "SKIP: uv is not installed; the queue is run by uv run --script"; exit 0 }
command -v jq >/dev/null 2>&1 || { print "FAIL: jq is required"; exit 1 }

_t=${TMPDIR:-/tmp}; _t=${_t%/}
T=$(mktemp -d "$_t/fcq.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
ln -sf "$HERE/../private_dot_local/bin/executable_fleet-decl" "$T/bin/fleet-decl"
PATH="$T/bin:$PATH"; export PATH
TOOL="$HERE/../private_dot_local/bin/executable_fleet-canonicals"
export FLEET_CANONICALS_BIN="bash $TOOL"
[[ -n "${FLEET_CANONICALS_QUEUE:-}" ]] || export FLEET_CANONICALS_QUEUE="$HERE/../private_dot_local/bin/executable_fleet-canonicals-queue"

fail=0
ok()  { print "ok:   $1" }
bad() { print "FAIL: $1"; fail=1 }

host=$(hostname)
cat > "$T/rec.yaml" <<YAML
projects:
  alpha:
    scope: alpha
    canonical: alpha-canonical
    canonicalIdentity: "the canonical session for alpha"
    canonicalLaunchDir: alpha
    canonicalLaunchModel: opus
    canonicalMachines: [$host]
  beta:
    scope: beta
    canonical: beta-canonical
    canonicalIdentity: "the canonical session for beta"
    canonicalLaunchDir: beta
    canonicalLaunchModel: opus
    canonicalMachines: [$host]
  gamma:
    scope: gamma
    canonical: gamma-canonical
    canonicalIdentity: "the canonical session for gamma"
    canonicalLaunchDir: gamma
    canonicalLaunchModel: opus
    canonicalMachines: [$host]
  director:
    scope: director
    canonical: director-canonical
    canonicalIdentity: "the director seat"
    canonicalLaunchDir: director
    canonicalLaunchModel: opus
    canonicalMachines: [$host]
  elsewhere:
    scope: elsewhere
    canonical: elsewhere-canonical
    canonicalIdentity: "a canonical another machine runs"
    canonicalLaunchDir: elsewhere
    canonicalLaunchModel: opus
    canonicalMachines: [some-other-host]
YAML
export FLEET_RECORD="$T/rec.yaml" FLEET_DEVEL_ROOT="$T" FLEET_ROOT="$T"
export FLEET_STATE="$T/state" FLEET_TMPROOT_PREFIX="$T/tmproots" FLEET_HANDOFFS_SEARCH="$T"
export FLEET_TRANSCRIPT_DIR="$T/transcripts" XDG_RUNTIME_DIR="$T/run"
export FLEET_CANONICALS_CONFIG="$T/config" FLEET_RESPAWN_WAIT=4
# Claude Code's per-process records and /proc are fixtures too, so the real ones are never read.
export FLEET_PID_RECORD_DIR="$T/pids" FLEET_PROC_ROOT="$T/proc" FLEET_JOBS_DIR="$T/jobs"
export FLEET_DAEMON_ROSTER="$T/roster.json" ROSTER="$T/roster.json"
mkdir -p "$T/state" "$T/tmproots" "$T/transcripts/p" "$T/run/claude-usage" "$T/pids" "$T/proc"
Q="$T/state/requests"
# The suite itself may run inside a session; its id must not make the fixtures' requester.
unset CLAUDE_CODE_SESSION_ID

# The sessions listing is a file; the claude stub logs every call and, like the real CLI, makes a
# respawned session live again and a removed one disappear.
print '[]' > "$T/agents.json"
export FLEET_AGENTS_JSON_CMD="cat $T/agents.json" CLAUDE_LOG="$T/claude.log" AGENTS="$T/agents.json"
cat > "$T/bin/claude-stub" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CLAUDE_LOG"
printf '%s\n' "$PATH" > "$CLAUDE_LOG.path"
case "$1" in
  respawn) jq --arg i "$2" 'map(if .id == $i then .state = "working" | .live = true else . end)' "$AGENTS" > "$AGENTS.n" && mv "$AGENTS.n" "$AGENTS"
           # A respawned session runs under the daemon, so its roster lists a worker for it, unless
           # the fixture says the respawn brought no process up.
           sid=$(jq -r --arg i "$2" '.[] | select(.id == $i) | .sessionId' "$AGENTS")
           [ -n "${RESPAWN_NO_PROCESS:-}" ] || { jq --arg sid "$sid" '.workers[$sid] = {pid: 1, sessionId: $sid}' "$ROSTER" > "$ROSTER.n" && mv "$ROSTER.n" "$ROSTER"; } ;;
  rm)      # The removed session's process exits too: drop its fixture pid records and /proc entries.
           sid=$(jq -r --arg i "$2" '.[] | select(.id == $i) | .sessionId' "$AGENTS")
           for r in "$FLEET_PID_RECORD_DIR"/*.json; do
             [ -f "$r" ] && [ "$(jq -r .sessionId "$r")" = "$sid" ] && { p=$(jq -r .pid "$r"); rm -f "$r"; rm -f "$FLEET_PROC_ROOT/$p/stat"; }
           done
           jq --arg i "$2" 'map(select(.id != $i))' "$AGENTS" > "$AGENTS.n" && mv "$AGENTS.n" "$AGENTS" ;;
esac
exit 0
STUB
chmod +x "$T/bin/claude-stub"
export FLEET_CLAUDE_CMD="$T/bin/claude-stub"
# The live listing drops stopped rows; --all keeps them. One fixture file, two views.
export FLEET_AGENTS_JSON_CMD="jq -c map(select(.live)) $T/agents.json" FLEET_AGENTS_JSON_ALL_CMD="cat $T/agents.json"
# The trust check prints the untrusted projects and exits 1, or exits 0.
print 0 > "$T/trust.rc"; : > "$T/trust.names"
cat > "$T/bin/trust-stub" <<'STUB'
#!/bin/sh
cat "$TRUST_NAMES"; exit "$(cat "$TRUST_RC")"
STUB
chmod +x "$T/bin/trust-stub"
export FLEET_TRUST_CHECK_CMD="$T/bin/trust-stub" TRUST_NAMES="$T/trust.names" TRUST_RC="$T/trust.rc"

# Every declared canonical gets a launch directory and a recorded handoff, so the verbs the runner
# runs get past their own pre-flight and gate; this suite is about the runner's checks.
for n in alpha beta gamma director; do
  mkdir -p "$T/$n"
  print "handoff for $n" > "$T/$n.handoff.md"
  bash "$TOOL" handoff "$n-canonical" --set "$T/$n.handoff.md" >/dev/null 2>&1
done

fc() { bash "$TOOL" "$@" 2>&1 }
serve() { fc serve-requests }
reset() {
  rm -rf "$Q" "$T/state/requests-audit.jsonl"; : > "$CLAUDE_LOG"; : > "$T/config"
  print '[]' > "$T/agents.json"; rm -f "$T/run/claude-usage/"*(N)
  print 0 > "$T/trust.rc"; : > "$T/trust.names"
  rm -rf "$T/pids" "$T/proc"; mkdir -p "$T/pids" "$T/proc"
  print '{"workers":{}}' > "$T/roster.json"
}
# roster_worker SESSION -- the daemon's roster lists a running worker for the session
roster_worker() {
  jq --arg sid "$1" '.workers[$sid[0:8]] = {pid: 1, sessionId: $sid}' "$T/roster.json" > "$T/roster.n" && mv "$T/roster.n" "$T/roster.json"
}
# pid_record PID NAME PROCSTART -- a Claude Code per-process record naming a canonical
pid_record() {
  jq -n --argjson p "$1" --arg n "$2" --arg s "$3" '{pid:$p, sessionId:"s", kind:"bg", name:$n, procStart:$s, status:"idle"}' \
    > "$T/pids/$1.json"
}
# proc_alive PID STARTTIME -- a /proc/<pid>/stat whose field 22 is STARTTIME
proc_alive() {
  mkdir -p "$T/proc/$1"
  print "$1 (claude) S 1 1 1 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 1 0 $2 1000 100" > "$T/proc/$1/stat"
}
# plant ID VERB NAME REQUESTER [AGE] -- write a request file directly, as a sandboxed writer could,
# bypassing every check `request` makes, so only the runner stands between it and the verb.
plant() {
  mkdir -p "$Q"
  local t=$(( $(date +%s) - ${5:-0} ))
  jq -n --arg id "$1" --argjson t "$t" --arg v "$2" --arg n "$3" --arg r "$4" \
    '{id:$id, time:$t, verb:$v, name:$n, reason:"test", requester:$r}' > "$Q/$1.request.json"
}
result() { jq -r ".$2 // empty" "$Q/$1.result.json" 2>/dev/null }
# expect ID OUTCOME CHECK LABEL
expect() {
  local o=$(result "$1" outcome) c=$(result "$1" check)
  if [[ "$o" == "$2" && "$c" == "$3" ]]; then ok "$4"
  else bad "$4 (outcome '$o', check '$c'; wanted '$2', '$3'): $(cat "$Q/$1.result.json" 2>/dev/null)"; fi
}
live_row() {  # live_row ID NAME STATE SESSION
  jq --arg i "$1" --arg n "$2" --arg s "$3" --arg sid "$4" \
    '. + [{id:$i, name:$n, state:$s, sessionId:$sid, cwd:"/x", kind:"background", startedAt:1000, live:true}]' \
    "$T/agents.json" > "$T/agents.n" && mv "$T/agents.n" "$T/agents.json"
}
stopped_row() {
  jq --arg i "$1" --arg n "$2" '. + [{id:$i, name:$n, state:"done", sessionId:"x", cwd:"/x", kind:"background", startedAt:1000}]' \
    "$T/agents.json" > "$T/agents.n" && mv "$T/agents.n" "$T/agents.json"
}
transcript() {  # transcript SESSION ended|working
  if [[ $2 == ended ]]; then
    print -l '{"type":"user","message":{"role":"user","content":"go"},"timestamp":"2026-11-08T01:00:00Z"}' \
      '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"},"timestamp":"2026-11-08T01:00:05Z"}' \
      '{"type":"system","subtype":"turn_duration","timestamp":"2026-11-08T01:00:06Z"}' \
      '{"type":"last-prompt"}' > "$T/transcripts/p/$1.jsonl"
  else
    print -l '{"type":"user","message":{"role":"user","content":"go"},"timestamp":"2026-11-08T01:00:00Z"}' \
      '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use"},"timestamp":"2026-11-08T01:00:05Z"}' \
      '{"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]},"timestamp":"2026-11-08T01:00:09Z"}' \
      > "$T/transcripts/p/$1.jsonl"
  fi
}

# ===== request: what it refuses before anything lands ===========================================
reset
out=$(fc request up alpha-canonical --reason 'start of day' --as alpha-canonical); rc=$?
f=$(print -l "$Q"/*.request.json(N) | head -1)
[[ $rc -eq 0 && -n "$f" ]] && ok "request queues one file" || bad "request (rc=$rc): $out"
[[ -n "$f" && "$(jq -r '[.verb,.name,.requester,.reason]|join("|")' "$f")" == "up|alpha-canonical|alpha-canonical|start of day" ]] \
  && ok "the request records verb, name, requester and reason" || bad "request content: $(cat "$f" 2>/dev/null)"
[[ -n "$f" ]] && (( $(date +%s) - $(jq .time "$f") < 30 )) && ok "the request records when it was written" \
  || bad "request time missing or wrong"
[[ -z "$(print -l "$Q"/.tmp-*(N))" ]] && ok "request leaves no temp file behind (written then renamed)" \
  || bad "request left a temp file"

reset
for v in dedupe clean place; do
  out=$(fc request $v alpha-canonical --reason x --as alpha-canonical); rc=$?
  [[ $rc -ne 0 && -z "$(print -l "$Q"/*.request.json(N))" ]] && ok "request refuses verb '$v'" || bad "request accepted '$v': $out"
done
for flag in --force --stub; do
  out=$(fc request refresh alpha-canonical --reason x --as alpha-canonical $flag); rc=$?
  [[ $rc -ne 0 && "$out" == *"never accepted"* && -z "$(print -l "$Q"/*.request.json(N))" ]] \
    && ok "request refuses $flag" || bad "request accepted $flag (rc=$rc): $out"
done
out=$(fc request up elsewhere-canonical --reason x --as alpha-canonical); rc=$?
[[ $rc -ne 0 && "$out" == *"not declared for this machine"* ]] && ok "request refuses a canonical declared for another machine" \
  || bad "request accepted another machine's canonical (rc=$rc): $out"
out=$(fc request up nosuch-canonical --reason x --as alpha-canonical); rc=$?
[[ $rc -ne 0 && -z "$(print -l "$Q"/*.request.json(N))" ]] && ok "request refuses an undeclared name" || bad "request accepted an undeclared name: $out"
out=$(fc request up alpha-canonical --as alpha-canonical); rc=$?
[[ $rc -ne 0 && "$out" == *"--reason"* ]] && ok "request requires --reason" || bad "request without a reason (rc=$rc): $out"
out=$(fc request up alpha-canonical --reason x); rc=$?
[[ $rc -ne 0 && "$out" == *"--as"* ]] && ok "request refuses when the requester cannot be told and --as is absent" \
  || bad "request with no requester (rc=$rc): $out"

# never-touch, at request time: the default list names the director seat.
out=$(fc request refresh director-canonical --reason x --as director-canonical); rc=$?
[[ $rc -ne 0 && "$out" == *"never-touch"* && -z "$(print -l "$Q"/*.request.json(N))" ]] \
  && ok "request refuses a never-touch canonical (the default list), and nothing lands" || bad "never-touch at request (rc=$rc): $out"
print 'never-touch = gamma-canonical' > "$T/config"
out=$(fc request up director-canonical --reason x --as director-canonical); rc=$?
[[ $rc -eq 0 ]] && ok "the never-touch list is the config's when the key is set" || bad "configured never-touch (rc=$rc): $out"
out=$(fc request up gamma-canonical --reason x --as director-canonical); rc=$?
[[ $rc -ne 0 && "$out" == *"never-touch"* ]] && ok "request refuses a configured never-touch name" || bad "configured never-touch name (rc=$rc): $out"

# The requester is the calling session when it can be read, and --as cannot contradict it.
reset
sid=11111111-2222-3333-4444-555555555555
print '{"session_id":"'$sid'","session_name":"beta-canonical","seven_day_pct":1}' > "$T/run/claude-usage/$sid.json"
out=$(CLAUDE_CODE_SESSION_ID=$sid fc request down beta-canonical --reason park); rc=$?
f=$(print -l "$Q"/*.request.json(N) | head -1)
[[ $rc -eq 0 && -n "$f" && "$(jq -r .requester "$f")" == beta-canonical ]] \
  && ok "request records the calling session's canonical name as the requester" || bad "derived requester (rc=$rc): $out"
rm -f "$Q"/*.request.json(N)
out=$(CLAUDE_CODE_SESSION_ID=$sid fc request down alpha-canonical --reason x --as director-canonical); rc=$?
[[ $rc -ne 0 && "$out" == *"running inside 'beta-canonical'"* ]] && ok "--as cannot name someone other than the calling session" \
  || bad "--as overrode the calling session (rc=$rc): $out"
# One per canonical, at request time too.
out=$(fc request up gamma-canonical --reason x --as gamma-canonical)
out=$(fc request up gamma-canonical --reason y --as gamma-canonical); rc=$?
[[ $rc -ne 0 && "$out" == *"already queued"* ]] && ok "request refuses a second request for a canonical already queued" \
  || bad "second request queued (rc=$rc): $out"

# ===== serve-requests: each check refuses a planted request, and lets its control through ==========
# The control for each is a request that differs only in what that check reads, and that runs.
reset
plant r-ok up alpha-canonical alpha-canonical
out=$(serve); rc=$?
expect r-ok done "" "a valid up request is served: the verb runs"
[[ "$(cat "$CLAUDE_LOG")" == *"--bg -n alpha-canonical"* ]] && ok "the served up launches through the verb, as declared" \
  || bad "no launch recorded: $(cat "$CLAUDE_LOG") / $out"
[[ -f "$Q/r-ok.served.json" && ! -f "$Q/r-ok.request.json" ]] && ok "a served request leaves the queue" || bad "request not moved out of the queue"
[[ "$(result r-ok output)" == *"fleet-canonicals up alpha-canonical exited 0"* ]] && ok "the result carries the verb's output" \
  || bad "result output: $(result r-ok output)"
a=$(tail -n 1 "$T/state/requests-audit.jsonl" 2>/dev/null)
[[ "$(print -r -- "$a" | jq -r '[.id,.outcome,.verb,.name,.requester]|join("|")' 2>/dev/null)" == "r-ok|done|up|alpha-canonical|alpha-canonical" ]] \
  && ok "an audit line is appended per request" || bad "audit line: $a"
out=$(serve); rc=$?
[[ $rc -eq 0 && "$(wc -l < "$T/state/requests-audit.jsonl" | tr -d ' ')" == 1 ]] && ok "a second pass serves nothing twice" || bad "re-served: $out"

# shape and verb: hand-written files the request verb would never write.
reset
plant r-verb dedupe alpha-canonical alpha-canonical
plant r-flag "refresh --force" alpha-canonical alpha-canonical
plant r-name up --stub alpha-canonical
mkdir -p "$Q"; print '{"id":"r-bad","verb":"up"}' > "$Q/r-bad.request.json"; print 'not json' > "$Q/r-junk.request.json"
serve >/dev/null
expect r-verb refused verb "the runner refuses a verb outside the four"
expect r-flag refused verb "the runner refuses --force smuggled into a verb"
expect r-name refused verb "the runner refuses an option in place of a name"
expect r-bad refused shape "the runner refuses a request missing its fields"
expect r-junk refused shape "the runner refuses a file that is not JSON"
[[ -z "$(cat "$CLAUDE_LOG")" ]] && ok "no refused request reached claude" || bad "a refused request ran: $(cat "$CLAUDE_LOG")"

# paused
reset
mkdir -p "$Q"; : > "$Q/PAUSED"; plant r-p up alpha-canonical alpha-canonical
serve >/dev/null; expect r-p refused paused "a PAUSED file refuses every request"
rm -f "$Q/PAUSED"; plant r-p2 up alpha-canonical alpha-canonical
serve >/dev/null; expect r-p2 done "" "with PAUSED removed the same request runs"

# age
reset
plant r-old up alpha-canonical alpha-canonical 660; plant r-young up beta-canonical beta-canonical 540
serve >/dev/null
expect r-old refused age "a request older than ten minutes is refused as stale"
expect r-young done "" "a request nine minutes old still runs"
reset; print 'request-max-age = 30' > "$T/config"; plant r-cfg up alpha-canonical alpha-canonical 60
serve >/dev/null; expect r-cfg refused age "request-max-age in the config sets the limit"

# never-touch at the runner (a hand-written file never went through request)
reset
plant r-dir refresh director-canonical director-canonical
serve >/dev/null; expect r-dir refused never-touch "the runner refuses the never-touch canonical, whoever asks"
print 'never-touch =' > "$T/config"; plant r-dir2 up director-canonical director-canonical
serve >/dev/null; expect r-dir2 done "" "an empty never-touch list lets it through"

# declared for this machine
reset
plant r-else up elsewhere-canonical elsewhere-canonical; plant r-none up nosuch-canonical nosuch-canonical
serve >/dev/null
expect r-else refused declared "the runner refuses a canonical declared for another machine"
expect r-none refused declared "the runner refuses a name the record does not declare"

# requester
reset
plant r-other up beta-canonical alpha-canonical; plant r-dirq up gamma-canonical director-canonical
serve >/dev/null
expect r-other refused requester "a canonical may not request another canonical's action"
expect r-dirq done "" "the director may request any canonical's action (request-any default)"
print 'request-any = owner' > "$T/config"; plant r-own up beta-canonical owner
serve >/dev/null; expect r-own done "" "request-any in the config names who may act on anyone"

# self-refresh
reset
plant r-self refresh alpha-canonical alpha-canonical
serve >/dev/null; expect r-self refused self-refresh "a canonical's request to refresh itself is refused by default"
print 'allow-self-refresh = true' > "$T/config"; plant r-self2 refresh alpha-canonical alpha-canonical
serve >/dev/null; expect r-self2 done "" "allow-self-refresh = true lets a self-refresh run, for the measurement"
reset; plant r-selfdown down alpha-canonical alpha-canonical
serve >/dev/null; expect r-selfdown done "" "a canonical may still request its own down"

# one per canonical
reset
plant r-a1 up alpha-canonical alpha-canonical; plant r-a2 up alpha-canonical alpha-canonical
serve >/dev/null
expect r-a1 done "" "of two requests for one canonical, the first queued runs"
expect r-a2 refused one-per-canonical "the second request for the same canonical is refused"
reset
mkdir -p "$Q"; plant r-run up alpha-canonical alpha-canonical; mv "$Q/r-run.request.json" "$Q/r-run.running.json"
plant r-b up alpha-canonical alpha-canonical; plant r-c up beta-canonical beta-canonical
serve >/dev/null
expect r-b refused one-per-canonical "a request is refused while one for the same canonical is marked running"
expect r-c done "" "another canonical's request is not held up by it"

# rate limits
reset
now=$(date +%s)
for i in 1 2 3; do print '{"at":'$(( now - 600 ))',"name":"alpha-canonical","outcome":"done"}' >> "$T/state/requests-audit.jsonl"; done
print '{"at":'$(( now - 7200 ))',"name":"beta-canonical","outcome":"done"}' >> "$T/state/requests-audit.jsonl"
for i in 1 2 3; do print '{"at":'$(( now - 600 ))',"name":"beta-canonical","outcome":"refused"}' >> "$T/state/requests-audit.jsonl"; done
mkdir -p "$Q"; plant r-rate up alpha-canonical alpha-canonical; plant r-rate2 up beta-canonical beta-canonical
serve >/dev/null
expect r-rate refused rate "a fourth action for one canonical within the hour is refused"
expect r-rate2 done "" "refused requests and actions over an hour old do not count"
reset
now=$(date +%s)
for n in a b c d e f g h i j; do print '{"at":'$(( now - 300 ))',"name":"'$n'-canonical","outcome":"done"}' >> "$T/state/requests-audit.jsonl"; done
mkdir -p "$Q"; plant r-fleet up gamma-canonical gamma-canonical
serve >/dev/null; expect r-fleet refused rate "an eleventh action for the fleet within the hour is refused"
print 'request-limit-fleet = 20' > "$T/config"; plant r-fleet2 up gamma-canonical gamma-canonical
serve >/dev/null; expect r-fleet2 done "" "request-limit-fleet in the config raises the fleet limit"

# usage
reset
later=$(( $(date +%s) + 86400 )); gone=$(( $(date +%s) - 60 ))
print '{"session_name":"x","seven_day_pct":85,"seven_day_resets_at":'$later'}' > "$T/run/claude-usage/a.json"
print '{"session_name":"y","seven_day_pct":12,"seven_day_resets_at":'$later'}' > "$T/run/claude-usage/b.json"
plant r-u1 up alpha-canonical alpha-canonical; plant r-u2 refresh beta-canonical director-canonical
plant r-u3 down gamma-canonical gamma-canonical
serve >/dev/null
expect r-u1 refused usage "up is refused at 85% of the 7-day window (the highest file wins)"
expect r-u2 refused usage "refresh is refused at the threshold too"
expect r-u3 done "" "down is never refused for usage"
print 'request-usage-exempt = alpha-canonical' > "$T/config"; plant r-u4 up alpha-canonical alpha-canonical
serve >/dev/null; expect r-u4 done "" "a canonical on the exempt list may still be started"
reset
print '{"session_name":"x","seven_day_pct":99,"seven_day_resets_at":'$gone'}' > "$T/run/claude-usage/a.json"
print '{"session_name":"y","seven_day_pct":84,"seven_day_resets_at":'$later'}' > "$T/run/claude-usage/b.json"
plant r-u5 up alpha-canonical alpha-canonical
serve >/dev/null; expect r-u5 done "" "a usage file whose window already reset is not read as current"

# trust
reset
print 1 > "$T/trust.rc"; print -l beta gamma > "$T/trust.names"
plant r-t1 up beta-canonical beta-canonical; plant r-t2 up alpha-canonical alpha-canonical
plant r-t3 down gamma-canonical gamma-canonical
serve >/dev/null
expect r-t1 refused trust "up is refused where claude-trust-check reports the directory untrusted"
expect r-t2 done "" "an untrusted neighbor does not refuse a trusted canonical"
expect r-t3 done "" "down needs no trust"
reset; print 3 > "$T/trust.rc"; plant r-t4 up alpha-canonical alpha-canonical
serve >/dev/null; expect r-t4 refused trust "an unknown trust state refuses up (fail closed)"

# working: busy by the listing, or by an unfinished transcript turn
reset
live_row aaaa1111 alpha-canonical working s-alpha; transcript s-alpha ended
live_row bbbb2222 beta-canonical done s-beta; transcript s-beta working
live_row cccc3333 gamma-canonical done s-gamma; transcript s-gamma ended
plant r-w1 down alpha-canonical alpha-canonical; plant r-w2 refresh beta-canonical director-canonical
plant r-w3 down gamma-canonical gamma-canonical
serve >/dev/null
expect r-w1 waiting working "down waits while the listing reports the session working"
expect r-w2 waiting working "refresh waits while the transcript's last turn has not ended"
[[ -f "$Q/r-w1.request.json" && -f "$Q/r-w2.request.json" && ! -f "$Q/r-w1.served.json" ]] \
  && ok "a waiting request stays queued" || bad "waiting requests consumed: $(ls "$Q")"
expect r-w3 done "" "down of an idle session whose turn ended runs"
[[ "$(cat "$CLAUDE_LOG")" == *"rm cccc3333"* && "$(cat "$CLAUDE_LOG")" != *aaaa1111* && "$(cat "$CLAUDE_LOG")" != *bbbb2222* ]] \
  && ok "only the idle session's row was removed" || bad "claude calls: $(cat "$CLAUDE_LOG")"
# a waiting request is served once the session is idle, and waiting writes no audit line
since=$(result r-w2 since)
[[ ! -s "$T/state/requests-audit.jsonl" ]] || ! jq -e 'select(.outcome == "waiting")' "$T/state/requests-audit.jsonl" >/dev/null 2>&1 \
  && ok "waiting is not in the audit log" || bad "audit: $(cat "$T/state/requests-audit.jsonl")"
sleep 1; serve >/dev/null
[[ "$(result r-w2 since)" == "$since" && -n "$since" ]] && ok "a second waiting pass keeps when the wait began" \
  || bad "since moved: '$since' -> '$(result r-w2 since)'"
transcript s-beta ended; serve >/dev/null
expect r-w2 done "" "a waiting refresh is served once the transcript's turn has ended"
expect r-w1 waiting working "a request for a session still working keeps waiting"
jq --arg i aaaa1111 'map(if .id == $i then .state = "idle" else . end)' "$T/agents.json" > "$T/agents.n" && mv "$T/agents.n" "$T/agents.json"
serve >/dev/null; expect r-w1 done "" "a waiting down is served once the listing reports the session idle"
[[ $(jq -s 'map(select(.id == "r-w1")) | length' "$T/state/requests-audit.jsonl") == 1 ]] \
  && ok "a request that waited gets one audit line, when it is served" || bad "audit: $(cat "$T/state/requests-audit.jsonl")"
# a waiting request that outlives request-max-age is refused as stale, naming the wait
reset
print "allow-self-refresh = true" > "$T/config"
live_row ffff6666 alpha-canonical working s-alpha; transcript s-alpha ended
plant r-w6 refresh alpha-canonical alpha-canonical 590
serve >/dev/null; expect r-w6 waiting working "a self-refresh while working waits"
plant r-w6 refresh alpha-canonical alpha-canonical 700
serve >/dev/null; expect r-w6 refused age "a waiting request past request-max-age is refused stale"
[[ "$(result r-w6 detail)" == *"had waited since"*"is working"* && ! -f "$Q/r-w6.request.json" ]] \
  && ok "the stale refusal names the wait and consumes the request" || bad "stale detail: $(result r-w6 detail)"
reset
live_row dddd4444 alpha-canonical done s-missing
plant r-w4 down alpha-canonical alpha-canonical
serve >/dev/null; expect r-w4 refused working "an unreadable transcript refuses a stop (fail closed)"
reset; export FLEET_AGENTS_JSON_CMD=false
plant r-w5 down alpha-canonical alpha-canonical
serve >/dev/null; expect r-w5 refused working "an unreadable sessions list refuses a stop (fail closed)"
export FLEET_AGENTS_JSON_CMD="jq -c map(select(.live)) $T/agents.json"

# a `blocked` row with no waitingFor still waits, and the reason names the anomaly
reset; live_row bl000001 alpha-canonical blocked s-bl; transcript s-bl ended; roster_worker s-bl
plant r-bl down alpha-canonical alpha-canonical
serve >/dev/null; expect r-bl waiting working "a blocked session's stop waits"
[[ "$(result r-bl detail)" == *"no waitingFor"* ]] && ok "the reason names a blocked state with no waitingFor" \
  || bad "blocked detail: $(result r-bl detail)"

# parked signals: `blocked` with no waitingFor is idle only when the session's own pid record says
# idle AND its handoff was recorded after it started (the setup above recorded each handoff now)
pid_for() {  # pid_for PID NAME SESSION STATUS -- a live pid record for a session
  jq -n --argjson p "$1" --arg n "$2" --arg sid "$3" --arg st "$4" \
    '{pid:$p, sessionId:$sid, kind:"bg", name:$n, procStart:"555", status:$st}' > "$T/pids/$1.json"
  mkdir -p "$T/proc/$1"; print "$1 (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 555 1 1" > "$T/proc/$1/stat"
}
reset; live_row pk000001 alpha-canonical blocked s-pk; transcript s-pk ended; pid_for 5101 alpha-canonical s-pk idle
plant r-pk1 refresh alpha-canonical director-canonical
serve >/dev/null; expect r-pk1 done "" "blocked with no waitingFor, idle by its own record and parked since it started, is served"
reset; live_row pk000002 alpha-canonical blocked s-pk; transcript s-pk ended; pid_for 5102 alpha-canonical s-pk busy
mkdir -p "$T/jobs/pk000002"; jq -n '{state:"blocked", tempo:"blocked", needs:"Decide: footer basis"}' > "$T/jobs/pk000002/state.json"
plant r-pk2 refresh alpha-canonical director-canonical
serve >/dev/null; expect r-pk2 waiting working "the same, but its own record says busy, still waits"
[[ "$(result r-pk2 detail)" == *"not idle"* ]] && ok "...and the reason says the session's record is not idle" || bad "pk2 detail: $(result r-pk2 detail)"
[[ "$(result r-pk2 detail)" == *"asked: Decide: footer basis"* ]] && ok "...and quotes what its last turn asked" || bad "pk2 needs: $(result r-pk2 detail)"
reset; live_row pk000003 alpha-canonical blocked s-un; pid_for 5103 alpha-canonical s-un idle
print -l '{"type":"user","message":{"role":"user","content":"go"},"timestamp":"2099-01-01T00:00:00Z"}' \
  '{"type":"system","subtype":"turn_duration","timestamp":"2099-01-01T00:00:06Z"}' > "$T/transcripts/p/s-un.jsonl"
plant r-pk3 refresh alpha-canonical director-canonical
serve >/dev/null; expect r-pk3 waiting working "idle but not parked since it started (its handoff is older) still waits"
[[ "$(result r-pk3 detail)" == *"before the session started"* ]] && ok "...and the reason says the handoff predates the session" || bad "pk3 detail: $(result r-pk3 detail)"
reset; live_row pk000004 alpha-canonical blocked s-pk; transcript s-pk ended; pid_for 5104 alpha-canonical s-pk idle
jq 'map(if .id == "pk000004" then .waitingFor = "permission prompt" else . end)' "$T/agents.json" > "$T/agents.n" && mv "$T/agents.n" "$T/agents.json"
plant r-pk4 refresh alpha-canonical director-canonical
serve >/dev/null; expect r-pk4 waiting working "a blocked session with a real waitingFor still waits, parked or not"
[[ "$(result r-pk4 detail)" == *"waiting for permission prompt"* ]] && ok "...and the reason quotes its waitingFor" || bad "pk4 detail: $(result r-pk4 detail)"

# stopped and parked: `blocked` with no waitingFor and NO live process (the idle stop leaves the row
# listed) is served only when no live pid record holds the name, the daemon roster lists no worker
# for the session, and its handoff names a placed file recorded after the session started
reset; live_row st000001 alpha-canonical blocked s-st; transcript s-st ended
plant r-st1 refresh alpha-canonical director-canonical
serve >/dev/null; expect r-st1 done "" "blocked, no process, no roster worker, parked since it started: the refresh is served"
reset; live_row st000002 alpha-canonical blocked s-st; transcript s-st ended; roster_worker s-st
plant r-st2 refresh alpha-canonical director-canonical
serve >/dev/null; expect r-st2 waiting working "the same, but the daemon roster lists a worker for it: waits"
[[ "$(result r-st2 detail)" == *"roster lists a running worker"* ]] && ok "...and the reason names the roster worker" || bad "st2 detail: $(result r-st2 detail)"
reset; live_row st000003 alpha-canonical blocked s-st; transcript s-st ended; pid_for 5301 alpha-canonical s-other idle
plant r-st3 refresh alpha-canonical director-canonical
serve >/dev/null; expect r-st3 waiting working "the same, but a live pid record holds the name: waits"
[[ "$(result r-st3 detail)" == *"live process still holds the name"* ]] && ok "...and the reason names the live process" || bad "st3 detail: $(result r-st3 detail)"
reset; live_row st000004 alpha-canonical blocked s-sx
print -l '{"type":"user","message":{"role":"user","content":"go"},"timestamp":"2099-01-01T00:00:00Z"}' \
  '{"type":"system","subtype":"turn_duration","timestamp":"2099-01-01T00:00:06Z"}' > "$T/transcripts/p/s-sx.jsonl"
plant r-st4 refresh alpha-canonical director-canonical
serve >/dev/null; expect r-st4 waiting working "stopped, but its handoff predates the session (never parked): waits"
[[ "$(result r-st4 detail)" == *"before the session started"* ]] && ok "...and the reason says the handoff predates it" || bad "st4 detail: $(result r-st4 detail)"
reset; live_row st000005 alpha-canonical blocked s-st; transcript s-st ended
jq 'map(if .id == "st000005" then .waitingFor = "permission prompt" else . end)' "$T/agents.json" > "$T/agents.n" && mv "$T/agents.n" "$T/agents.json"
plant r-st5 refresh alpha-canonical director-canonical
serve >/dev/null; expect r-st5 waiting working "stopped and parked, but a real waitingFor: waits"
reset; live_row st000006 alpha-canonical blocked s-st; transcript s-st ended; rm -f "$T/roster.json"
plant r-st6 refresh alpha-canonical director-canonical
serve >/dev/null; expect r-st6 waiting working "an unreadable daemon roster waits (fail closed)"
[[ "$(result r-st6 detail)" == *"roster"*"cannot be read"* ]] && ok "...and the reason names the roster" || bad "st6 detail: $(result r-st6 detail)"
outside=$(mktemp "$_t/fcq-outside.XXXXXX"); print "a draft" > "$outside"
bash "$TOOL" handoff alpha-canonical --set "$outside" >/dev/null 2>&1
reset; live_row st000007 alpha-canonical blocked s-st; transcript s-st ended
plant r-st7 refresh alpha-canonical director-canonical
serve >/dev/null; expect r-st7 waiting working "stopped, but the pointer names a file outside the placed handoffs: waits"
[[ "$(result r-st7 detail)" == *"not under the placed handoffs"* ]] && ok "...and the reason says it is not a placed copy" || bad "st7 detail: $(result r-st7 detail)"
rm -f "$outside"; bash "$TOOL" handoff alpha-canonical --set "$T/alpha.handoff.md" >/dev/null 2>&1

# refresh: after the stop, a live process that still holds the name is waited for, then refused
# loudly, rather than handed to a launch that would refuse halfway through
reset; live_row rf000001 alpha-canonical idle s-rf; transcript s-rf ended; pid_for 5201 alpha-canonical s-other idle
plant r-rf refresh alpha-canonical director-canonical
serve >/dev/null; expect r-rf failed "" "a refresh whose name another live process still holds after the stop fails"
[[ "$(result r-rf output)" == *"was stopped but a live process still holds the name"* ]] \
  && ok "...saying the stop took but another process still holds the name" || bad "rf output: $(result r-rf output)"

# live-process: a live process holds the name while the sessions list has no live row for it
reset
pid_record 4242 alpha-canonical 777; proc_alive 4242 777
plant r-lp1 up alpha-canonical alpha-canonical
serve >/dev/null; expect r-lp1 refused live-process "up is refused while a live process holds the name the list omits"
[[ "$(result r-lp1 detail)" == *"pid 4242"* && ! -s "$CLAUDE_LOG" ]] && ok "the refusal names the pid and nothing was launched" \
  || bad "detail '$(result r-lp1 detail)', claude: $(cat "$CLAUDE_LOG")"
reset; stopped_row eeee5555 alpha-canonical
pid_record 4242 alpha-canonical 777; proc_alive 4242 777
plant r-lp2 resume alpha-canonical alpha-canonical
serve >/dev/null; expect r-lp2 refused live-process "resume is refused while a live process holds the name"
reset; pid_record 4242 alpha-canonical 777; proc_alive 4242 999
plant r-lp3 up alpha-canonical alpha-canonical
serve >/dev/null; expect r-lp3 done "" "a reused pid (start time differs) does not refuse up"
reset; pid_record 4242 alpha-canonical 777
plant r-lp4 up alpha-canonical alpha-canonical
serve >/dev/null; expect r-lp4 done "" "a record whose pid is gone does not refuse up"
reset; pid_record 4242 beta-canonical 777; proc_alive 4242 777
plant r-lp5 up alpha-canonical alpha-canonical
serve >/dev/null; expect r-lp5 done "" "a live process under another name does not refuse up"
reset; live_row cccc3333 alpha-canonical idle s-alpha; transcript s-alpha ended
pid_record 4242 alpha-canonical 777; proc_alive 4242 777
plant r-lp6 down alpha-canonical alpha-canonical
serve >/dev/null; expect r-lp6 done "" "a live process the list does show is left to the working check"

# what the runner starts gets the runner's caller's PATH, without uv's environment for the queue
reset; plant r-env up alpha-canonical alpha-canonical
serve >/dev/null; expect r-env done "" "up runs (the PATH case's control)"
[ "$(cat "$CLAUDE_LOG.path")" = "$PATH" ] && ok "a launch inherits exactly the caller's PATH, not the queue's uv environment" \
  || bad "a launch's PATH differs from the caller's: $(cat "$CLAUDE_LOG.path")"

# resume: claude respawn on the newest stopped session; never on a live one
reset
stopped_row eeee5555 alpha-canonical
plant r-r1 resume alpha-canonical alpha-canonical
serve >/dev/null; expect r-r1 done "" "resume of a stopped session runs and the session is live again"
[[ "$(cat "$CLAUDE_LOG")" == "respawn eeee5555" ]] && ok "resume runs claude respawn on the canonical's last session" \
  || bad "resume called: $(cat "$CLAUDE_LOG")"
plant r-r2 resume alpha-canonical alpha-canonical
serve >/dev/null; expect r-r2 refused working "resume is refused while the session is running"
reset; plant r-r3 resume alpha-canonical alpha-canonical
serve >/dev/null; expect r-r3 failed "" "resume with no listed session fails, naming up"

# resume of a LISTED row whose process is provably gone (measured 2026-11-08): the idle stop leaves
# a session listed, often `blocked`, with nothing running it. Served whatever its state once no live
# pid record holds the name and the daemon roster lists no worker; a live process is refused.
for st in blocked idle done; do
  reset; live_row gn-$st alpha-canonical $st s-gn; transcript s-gn ended
  plant r-gn-$st resume alpha-canonical director-canonical
  serve >/dev/null; expect r-gn-$st done "" "resume of a listed '$st' row with no process and no roster worker is served"
done
[[ "$(cat "$CLAUDE_LOG")" == "respawn gn-done" ]] && ok "...and it respawns the listed row" || bad "gone resume called: $(cat "$CLAUDE_LOG")"
[[ "$(result r-gn-done output)" == *"a process holds the session again"* ]] \
  && ok "...and confirms by a process, not by the row it already saw" || bad "gone output: $(result r-gn-done output)"
reset; live_row gb000001 alpha-canonical blocked s-gb; transcript s-gb ended; pid_for 5401 alpha-canonical s-gb idle
plant r-gb1 resume alpha-canonical director-canonical
serve >/dev/null; expect r-gb1 refused working "resume of a listed 'blocked' row is refused while a live pid record holds the name"
[[ "$(result r-gb1 detail)" == *"listed 'blocked'"*"live process still holds the name"* && ! -s "$CLAUDE_LOG" ]] \
  && ok "...naming the process, and nothing was respawned" || bad "gb1 detail '$(result r-gb1 detail)', claude: $(cat "$CLAUDE_LOG")"
reset; live_row gb000002 alpha-canonical blocked s-gb; transcript s-gb ended; roster_worker s-gb
plant r-gb2 resume alpha-canonical director-canonical
serve >/dev/null; expect r-gb2 refused working "resume of a listed 'blocked' row is refused while the daemon roster lists its worker"
[[ "$(result r-gb2 detail)" == *"roster lists a running worker"* ]] && ok "...naming the roster worker" || bad "gb2 detail: $(result r-gb2 detail)"
reset; live_row gb000003 alpha-canonical blocked s-gb; transcript s-gb ended; rm -f "$T/roster.json"
plant r-gb3 resume alpha-canonical director-canonical
serve >/dev/null; expect r-gb3 refused working "resume is refused when the daemon roster cannot be read (fail closed)"
reset; live_row gb000004 alpha-canonical blocked ""; transcript s-gb ended
plant r-gb4 resume alpha-canonical director-canonical
serve >/dev/null; expect r-gb4 refused working "resume is refused for a listed row with no session id to look up"
reset; live_row gf000001 alpha-canonical blocked s-gf; transcript s-gf ended
plant r-gf1 resume alpha-canonical director-canonical
RESPAWN_NO_PROCESS=1 serve >/dev/null
expect r-gf1 failed "" "a respawn that brings no process up fails, though the row was listed all along"
[[ "$(result r-gf1 output)" == *"no process (pid record or daemon roster worker) appeared"* ]] \
  && ok "...saying no process appeared" || bad "gf1 output: $(result r-gf1 output)"

# the lock: a second runner leaves the queue to the first
reset; mkdir -p "$Q"; plant r-l up alpha-canonical alpha-canonical
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(4)' \
  "$Q/.serve.lock" "$T/locked" &
lockpid=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$T/locked" ]] && break; sleep 0.2; done
out=$(serve)
[[ -f "$Q/r-l.request.json" && "$out" == *"another runner"* ]] && ok "a second runner does not serve a queue another holds" \
  || bad "lock not honored: $out"
wait $lockpid
serve >/dev/null; expect r-l done "" "once the lock is free the request is served"

# --loop: one pass, then another every --interval seconds, until SIGTERM/SIGINT; every wait bounded.
# waitfor SECONDS CMD... -- poll CMD every 0.1s for at most SECONDS; true once it succeeds
waitfor() { local n=$(( $1 * 10 )) i; shift; for (( i = 0; i < n; i++ )); do "$@" && return 0; sleep 0.1; done; return 1 }
served_req() { [[ -f "$Q/$1.result.json" ]] }
gone() { ! kill -0 $1 2>/dev/null }
stop_loop() { kill -TERM $1 2>/dev/null; waitfor 8 gone $1 && { wait $1; return $? }; kill -KILL $1 2>/dev/null; wait $1 2>/dev/null; return 99 }

reset; plant l-1 up alpha-canonical alpha-canonical
bash "$TOOL" serve-requests --loop --interval 1 > "$T/loop.out" 2> "$T/loop.err" &
looppid=$!
waitfor 15 served_req l-1 && ok "--loop serves the queue on its first pass" || bad "--loop first pass: $(cat "$T/loop.out" "$T/loop.err")"
plant l-2 up beta-canonical beta-canonical
waitfor 15 served_req l-2 && ok "--loop serves a request that arrives after the first pass (a second pass ran)" \
  || bad "--loop second pass never served l-2: $(cat "$T/loop.out" "$T/loop.err")"
stop_loop $looppid; rc=$?
[[ $rc == 0 ]] && ok "SIGTERM ends --loop with status 0" || bad "SIGTERM exit status $rc (99: had to be killed)"
[[ ! -s "$T/loop.err" ]] && ok "SIGTERM leaves nothing on stderr (no traceback)" || bad "stderr after SIGTERM: $(cat "$T/loop.err")"
[[ "$(grep -c '^done ' "$T/loop.out")" == 2 ]] && ok "--loop's per-pass output is the one-shot output, one line per served request" \
  || bad "loop output: $(cat "$T/loop.out")"

# a pass that fails is reported and does not end the loop: the lock file is a directory, so the
# pass cannot open it; once it is removed the next pass serves.
reset; mkdir -p "$Q/.serve.lock"; plant l-3 up gamma-canonical gamma-canonical
bash "$TOOL" serve-requests --loop --interval 1 > "$T/loop.out" 2> "$T/loop.err" &
looppid=$!
failed_reported() { grep -q 'pass failed' "$T/loop.err" }
waitfor 15 failed_reported && ok "a failing pass is reported on stderr" || bad "no failure report: $(cat "$T/loop.err")"
kill -0 $looppid 2>/dev/null && ok "the loop is still running after a failed pass" || bad "the loop ended with its first failed pass"
rmdir "$Q/.serve.lock"
waitfor 15 served_req l-3 && ok "a later pass serves once the fault clears" || bad "no recovery: $(cat "$T/loop.out" "$T/loop.err")"
stop_loop $looppid; rc=$?
[[ $rc == 0 ]] && ok "SIGTERM after a failed pass still ends the loop with status 0" || bad "exit status $rc"

# usage errors at startup exit as they do today
out=$(fc serve-requests --interval 1); rc=$?
[[ $rc -ne 0 && "$out" == *"--loop"* ]] && ok "--interval without --loop is a usage error" || bad "--interval alone (rc=$rc): $out"
out=$(fc serve-requests --loop --interval 0); rc=$?
[[ $rc -ne 0 ]] && ok "--interval must be positive" || bad "--interval 0 accepted: $out"
out=$(fc serve-requests extra); rc=$?
[[ $rc -ne 0 ]] && ok "serve-requests still takes no other arguments" || bad "extra argument accepted: $out"

[[ $fail == 0 ]] && { print "ALL PASS"; exit 0 } || { print "FAILURES"; exit 1 }
