#!/usr/bin/env zsh
# Test: a seat's standing context record. When a canonical's fleet-record entry declares
# `canonicalContext:` (a path to a record, relative to the KB root), every launch and resume
# fleet-canonicals composes passes `--append-system-prompt-file <absolute path>` to claude; with
# the key absent nothing changes; a record that is not there refuses the launch; a claude that
# does not offer the flag gets the record named in the launch prompt instead, as the handoff is.
#
# Everything is a fixture under one scratch directory: the fleet record, the KB root, the state
# directory, the sessions listing, the transcripts and the `claude` stub, which records what it
# was asked. No session is started and nothing real is read.
set -u
HERE=${0:A:h}
. "$HERE/git-isolate.sh"
command -v jq >/dev/null 2>&1 || { print "FAIL: jq is required"; exit 1 }

_t=${TMPDIR:-/tmp}; _t=${_t%/}
T=$(mktemp -d "$_t/fcctx.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
ln -sf "$HERE/../private_dot_local/bin/executable_fleet-decl" "$T/bin/fleet-decl"
PATH="$T/bin:$PATH"; export PATH
TOOL="$HERE/../private_dot_local/bin/executable_fleet-canonicals"

fail=0
ok()  { print "ok:   $1" }
bad() { print "FAIL: $1"; fail=1 }

host=$(hostname)
KB="$T/kb"; ROOT="$T/root"; STATE="$T/state"
mkdir -p "$KB/seats" "$ROOT" "$STATE" "$T/tmproots" "$T/pids" "$T/proc" "$T/xdg"
print 'the seat alpha is...' > "$KB/seats/alpha.md"
for n in alpha beta gamma delta; do mkdir -p "$ROOT/$n"; done
cat > "$T/rec.yaml" <<YAML
projects:
  alpha:
    scope: alpha
    canonical: alpha-canonical
    canonicalIdentity: "the canonical session for alpha"
    canonicalLaunchDir: alpha
    canonicalLaunchModel: opus
    canonicalContext: seats/alpha.md
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
    canonicalContext: seats/missing.md
    canonicalMachines: [$host]
  delta:
    scope: delta
    canonical: delta-canonical
    canonicalIdentity: "the canonical session for delta"
    canonicalLaunchDir: delta
    canonicalLaunchModel: opus
    canonicalContext: ../outside.md
    canonicalMachines: [$host]
YAML
print 'outside the KB' > "$T/outside.md"

# The stub answers --help like a claude that offers the flag (unless STUB_NOFLAG) and records every
# other call. The sessions listing grows a second row once a launch has been recorded, which is
# what a fork waits for before it closes the old row.
cat > "$T/claude-stub" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--help" ]; then
  echo "  --model <model>"
  if [ -n "${STUB_BRACKET:-}" ]; then
    # The live shape (claude 2.1.322): the flag has no line of its own and is named only inside
    # --bare's description, bracketed with its inline sibling.
    echo "  --append-system-prompt <prompt>       Append a system prompt to the default"
    echo "                                        via: --system-prompt[-file],"
    echo "                                        --append-system-prompt[-file], --add-dir"
  elif [ -z "${STUB_NOFLAG:-}" ]; then
    echo "  --append-system-prompt-file <file>   Append a system prompt from a file"
  else
    echo "  --append-system-prompt <prompt>       Append a system prompt to the default"
  fi
  exit 0
fi
printf '%s\n' "$*" >> "$LAUNCHLOG"
STUB
chmod +x "$T/claude-stub"
cat > "$T/agents-cmd" <<'SH'
#!/bin/sh
[ -n "${FORK_MODE:-}" ] || { echo '[]'; exit 0; }
if [ -s "$LAUNCHLOG" ] && grep -q -- '--resume' "$LAUNCHLOG"; then
  echo '[{"pid":null,"id":"old1","cwd":"'"$FORK_CWD"'","startedAt":1000,"sessionId":"s1","name":"alpha-canonical","state":"stopped"},{"pid":90999,"id":"new2","cwd":"'"$FORK_CWD"'","startedAt":9000,"sessionId":"s2","name":"alpha-canonical","state":"running"}]'
else
  echo '[{"pid":null,"id":"old1","cwd":"'"$FORK_CWD"'","startedAt":1000,"sessionId":"s1","name":"alpha-canonical","state":"stopped"}]'
fi
SH
chmod +x "$T/agents-cmd"
mkdir -p "$T/transcripts/proj"
print '{"type":"user"}' > "$T/transcripts/proj/old1.jsonl"

export LAUNCHLOG="$T/launches.log" FORK_CWD="$ROOT/alpha"
export FLEET_CANONICALS_CONFIG="$T/no-config" FLEET_PID_RECORD_DIR="$T/pids" FLEET_PROC_ROOT="$T/proc"
export FLEET_HANDOFFS_SEARCH="$T"
fc() { FLEET_RECORD="$T/rec.yaml" FLEET_ROOT="$ROOT" FLEET_STATE="$STATE" FLEET_CLAUDE_CMD="$T/claude-stub" \
       FLEET_TMPROOT_PREFIX="$T/tmproots" FLEET_TRANSCRIPT_DIR="$T/transcripts" \
       FLEET_AGENTS_JSON_CMD="$T/agents-cmd" KB_ROOT="${KB_ROOT-$KB}" XDG_CONFIG_HOME="$T/xdg" \
       bash "$TOOL" "$@" 2>&1 }
for n in alpha beta gamma delta; do
  print "handoff for $n" > "$T/$n.md"
  fc handoff "$n-canonical" --set "$T/$n.md" >/dev/null
done
reset() { : > "$LAUNCHLOG" }
FLAG='--append-system-prompt-file'

# ---- up -----------------------------------------------------------------------------------------
reset
out=$(fc up alpha-canonical); rc=$?
(( rc == 0 )) || bad "up alpha failed ($rc): $out"
[[ "$(cat $LAUNCHLOG)" == *"$FLAG $KB/seats/alpha.md"* ]] \
  && ok "up passes the seat record, as an absolute path under the KB root" \
  || bad "up did not pass the flag: $(cat $LAUNCHLOG) / $out"
[[ "$(cat $LAUNCHLOG)" != *"seat record"* ]] \
  && ok "with the flag in use the launch prompt does not also name the record" \
  || bad "prompt names the record although the flag is used"

reset
out=$(fc up beta-canonical)
[[ -s $LAUNCHLOG && "$(cat $LAUNCHLOG)" != *"$FLAG"* ]] \
  && ok "no canonicalContext key: no flag, launch otherwise unchanged" \
  || bad "beta launch wrong: $(cat $LAUNCHLOG) / $out"

reset
out=$(fc up gamma-canonical); rc=$?
(( rc != 0 )) && [[ ! -s $LAUNCHLOG && "$out" == *"REFUSED"*"seats/missing.md"* ]] \
  && ok "a declared record that does not exist refuses the launch, naming the path" \
  || bad "missing record: rc=$rc log=$(cat $LAUNCHLOG) out=$out"

reset
out=$(fc up delta-canonical); rc=$?
(( rc != 0 )) && [[ ! -s $LAUNCHLOG ]] \
  && ok "a record path that climbs out of the KB root is refused" \
  || bad "escaping path launched: rc=$rc $(cat $LAUNCHLOG)"

reset
out=$(KB_ROOT= fc up alpha-canonical); rc=$?
(( rc != 0 )) && [[ ! -s $LAUNCHLOG && "$out" == *"KB root"* ]] \
  && ok "no resolvable KB root refuses rather than launching without the record" \
  || bad "no KB root: rc=$rc $(cat $LAUNCHLOG) $out"

mkdir -p "$T/xdg/kb"; print "root = \"$KB\"" > "$T/xdg/kb/config.toml"
reset
out=$(KB_ROOT= fc up alpha-canonical)
[[ "$(cat $LAUNCHLOG)" == *"$FLAG $KB/seats/alpha.md"* ]] \
  && ok "the KB root also resolves from the kb config file" \
  || bad "config-file root: $(cat $LAUNCHLOG) / $out"
rm -rf "$T/xdg/kb"

reset
out=$(STUB_NOFLAG=1 fc up alpha-canonical)
[[ "$(cat $LAUNCHLOG)" != *"$FLAG"* && "$(cat $LAUNCHLOG)" == *"seat record is at $KB/seats/alpha.md"* ]] \
  && ok "a claude without the flag gets the record named in the launch prompt instead" \
  || bad "fallback: $(cat $LAUNCHLOG) / $out"

reset
out=$(STUB_BRACKET=1 fc up alpha-canonical)
[[ "$(cat $LAUNCHLOG)" == *"$FLAG $KB/seats/alpha.md"* ]] \
  && ok "a claude that names the flag only as --append-system-prompt[-file] (2.1.322) gets the flag" \
  || bad "bracketed help form fell back: $(cat $LAUNCHLOG) / $out"

out=$(fc up --dry-run alpha-canonical)
[[ "$out" == *"$KB/seats/alpha.md"* ]] && ok "up --dry-run shows the seat record" || bad "dry run: $out"

# ---- refresh (not running: falls through to up) ---------------------------------------------------
reset
out=$(fc refresh alpha-canonical)
[[ "$(cat $LAUNCHLOG)" == *"$FLAG $KB/seats/alpha.md"* ]] \
  && ok "refresh launches with the seat record" || bad "refresh: $(cat $LAUNCHLOG) / $out"

reset
out=$(fc refresh --dry-run gamma-canonical); rc=$?
(( rc != 0 )) && [[ "$out" != *"would start"* && ! -s $LAUNCHLOG ]] \
  && ok "refresh refuses a missing record in its pre-flight, before it would stop anything" \
  || bad "refresh pre-flight: rc=$rc $out"

# ---- resume (the fork path is the only one that composes a launch) --------------------------------
reset
out=$(FORK_MODE=1 fc resume alpha-canonical --fork); rc=$?
[[ "$(grep -- '--resume' $LAUNCHLOG)" == *"$FLAG $KB/seats/alpha.md"* ]] \
  && ok "resume --fork passes the seat record" || bad "resume: rc=$rc $(cat $LAUNCHLOG) / $out"

reset
out=$(FORK_MODE=1 STUB_NOFLAG=1 fc resume alpha-canonical --fork)
[[ "$(grep -- '--resume' $LAUNCHLOG)" == *"seat record is at $KB/seats/alpha.md"* ]] \
  && ok "resume --fork names the record in the prompt when the flag is unavailable" \
  || bad "resume fallback: $(cat $LAUNCHLOG) / $out"

# ---- list -----------------------------------------------------------------------------------------
out=$(fc list)
[[ "$out" == *"alpha-canonical"*"seats/alpha.md"* ]] && ok "list shows each seat's record" || bad "list: $out"
[[ "$(print -r -- "$out" | grep beta-canonical)" != *"context"* ]] \
  && ok "list shows no record for a seat that declares none" || bad "list beta: $out"

[[ $fail == 0 ]] && { print "ALL PASS"; exit 0 } || { print "FAILURES"; exit 1 }
