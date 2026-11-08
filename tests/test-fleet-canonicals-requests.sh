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
mkdir -p "$T/state" "$T/tmproots" "$T/transcripts/p" "$T/run/claude-usage"
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
case "$1" in
  respawn) jq --arg i "$2" 'map(if .id == $i then .state = "working" | .live = true else . end)' "$AGENTS" > "$AGENTS.n" && mv "$AGENTS.n" "$AGENTS" ;;
  rm)      jq --arg i "$2" 'map(select(.id != $i))' "$AGENTS" > "$AGENTS.n" && mv "$AGENTS.n" "$AGENTS" ;;
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

[[ $fail == 0 ]] && { print "ALL PASS"; exit 0 } || { print "FAILURES"; exit 1 }
