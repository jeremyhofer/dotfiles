# Case idle-holders, run by `seam-probe run|red session-lifecycle idle-holders`.
#
# Claude Code's supervisor stops a background session that is finished or waiting for the next
# message and unattached for about an hour, and counts a running subagent, workflow or monitor, or a
# pending session-scoped scheduled task, as working. This case asks what keeps an idle session's
# process running past that stop. Four sessions are launched together from one fixture repository,
# each reaching its first turn's end at about the same time, which is when its idle clock starts:
#   control   no tool, and so no holder: it must be seen to stop, or the idle stop was never observed
#   shell     one background Bash command (`sleep 9000`, about 150 minutes) that outlives the run
#   schedule  one pending one-shot CronCreate job, set for 150 minutes after the launches
#   release   one background Bash command that ends soon (`sleep 900`): is the session stopped about
#             an hour after the command ended, which is when it was notified?
# Each holder is read from the session's transcript (`evidence calls`), never from the session's
# own account. The process is read by `session process`, from Claude Code's pid records and the
# daemon's roster, because the agents listing carries no pid and keeps showing a stopped session
# as done or blocked. Every poll is one line in the run's results directory, so the time series
# survives the run.
#
# A monitor is NOT an arm. The Monitor tool's own schema caps its timeout_ms at 1,800,000 ms (30
# minutes), so a monitor holds a session past the hour only by being re-armed, and each re-arm is a
# turn, which resets the idle clock itself: the measurement would be of the re-arming, not of the
# monitor.
#
# The run polls until the control has stopped, the release arm has stopped (or could not be
# measured) and the margin has passed since the control's stop, or until the cap, whichever is
# first. A shell or schedule session still present then, at least the margin after the control
# stopped, passes. A control never seen to stop by the cap makes every arm VOID: the instrument
# could not see the thing (an attached client such as an open agent view, or a changed idle
# duration).
#
# Times are seconds from SEAM_PROBE_* variables, so a test can shrink them: SEAM_PROBE_SESSION_WAIT
# (first turn, default 300), SEAM_PROBE_IDLE_POLL (60), SEAM_PROBE_IDLE_MARGIN (1800),
# SEAM_PROBE_IDLE_CAP (7200). Date arithmetic is python3's: no spelling of `date` is common to the
# GNU and BSD userlands.
#
# Plants ($SEAM_PROBE_PLANT): holder-dropped makes the shell arm's command `true` (still
# backgrounded, ends at once), so that session must stop and its arm FAIL; schedule-dropped has the
# schedule session delete its job with CronDelete, with the same expectation for its arm;
# control-held gives the control a background `sleep 9000`, so it never stops and every arm is VOID.
#
# Precondition, SKIPPED with the step that fixes it, the fixture left in place for it: Claude Code's
# trust for the fixture repository (a background session refuses an untrusted workspace).
set -u
sp=$SEAM_PROBE
plant=${SEAM_PROBE_PLANT:-}
session_wait=${SEAM_PROBE_SESSION_WAIT:-300}
first_poll=${SEAM_PROBE_POLL:-2}
poll=${SEAM_PROBE_IDLE_POLL:-60}
margin=${SEAM_PROBE_IDLE_MARGIN:-1800}
cap=${SEAM_PROBE_IDLE_CAP:-7200}
arms="control shell schedule release"
unavailable='no (matching )?(deferred )?tools?|no such tool|unknown tool|not found|not available|unavailable'

all() { for a in $arms; do "$sp" verdict --arm "$a" "$1" "$2"; done; }
oneline() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-300; }
getv() { eval "printf '%s' \"\${$1:-}\""; }
setv() { eval "$1=\$2"; }

command -v python3 >/dev/null 2>&1 || { all SKIPPED "python3 is not installed (this case's time arithmetic needs it)"; exit 0; }
now() { python3 -c 'import time; print("%.3f" % time.time())'; }
since() { python3 -c 'import sys; print("%.3f" % (float(sys.argv[1]) - float(sys.argv[2])))' "$1" "$2"; }
minutes() { python3 -c 'import sys; print("%.1f" % (float(sys.argv[1]) / 60))' "$1"; }
atleast() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$1" "$2"; }
# Minutes from the first turn's end of arm $1 to the instant $2.
after_turn() { minutes "$(since "$2" "$(getv end_$1)")"; }

repo=$("$sp" fixture repo idl) || { all INCONCLUSIVE "the fixture could not be built"; exit 0; }
trc=0; tout=$("$sp" evidence trusted "$repo") || trc=$?
case $trc in
  0) ;;
  1) "$sp" fixture keep "$repo" >/dev/null
     all SKIPPED "the fixture needs Claude Code's trust (from a plain terminal: cd $(printf %q "$repo") && claude, accept the dialog, /exit); then run the case again"
     exit 0 ;;
  *) all INCONCLUSIVE "the trust state cannot be read: $tout"; exit 0 ;;
esac

# The prompts. The shell and release commands are read back from the prompt, so the case never
# restates what suite.toml declares.
shell_key=hold
[ "$plant" = holder-dropped ] && shell_key=dropped
hold_prompt=$("$sp" prompt --background hold) || { all INCONCLUSIVE "the prompt could not be built"; exit 0; }
shell_prompt=$("$sp" prompt --background "$shell_key") || { all INCONCLUSIVE "the prompt could not be built"; exit 0; }
release_prompt=$("$sp" prompt --background release) || { all INCONCLUSIVE "the prompt could not be built"; exit 0; }
first_command() { printf '%s\n' "$1" | sed -n 's/^1\. //p'; }
shell_cmd=$(first_command "$shell_prompt")
release_cmd=$(first_command "$release_prompt")
rel_secs=$(printf '%s' "$release_cmd" | sed -n 's/^sleep \([0-9][0-9]*\)$/\1/p')
[ -n "$rel_secs" ] || { all INCONCLUSIVE "the release command ($release_cmd) is not a sleep of whole seconds, so its end cannot be placed"; exit 0; }

control_prompt="Reply with the single word DONE and nothing else. Do not use any tool."
control_cmd=""
if [ "$plant" = control-held ]; then
  control_prompt=$hold_prompt; control_cmd=$(first_command "$hold_prompt")
fi

# A local wall-clock cron expression, 150 minutes on: past the run's cap, so the job is pending
# throughout and never fires.
cron=$(python3 -c 'from datetime import datetime, timedelta; t = datetime.now() + timedelta(minutes=150); print(t.minute, t.hour, t.day, t.month, "*")') \
  || { all INCONCLUSIVE "the cron expression could not be computed"; exit 0; }
tools="Load the CronCreate tool with ToolSearch (query select:CronCreate)"
steps="Call CronCreate once, with recurring set to false, the cron expression \"$cron\" and the prompt \"Reply DONE.\"."
if [ "$plant" = schedule-dropped ]; then
  tools="Load the CronCreate and CronDelete tools with ToolSearch (query select:CronCreate,CronDelete)"
  steps="$steps Then call CronDelete once, to delete the job CronCreate returned."
fi
schedule_prompt="Do the following in order, and use no other tools. $tools. $steps Then reply with the single word DONE and end your turn."

# Launched in quick succession, so the four idle clocks start together.
t_launch=$(now)
launch() { # NAME PROMPT [RULE...]
  local n=$1 p=$2 r; shift 2
  local args=()
  for r in "$@"; do args+=(--allow "$r"); done
  "$sp" session launch "$n" --regime "$SEAM_PROBE_REGIME" --cwd "$repo" ${args[@]+"${args[@]}"} -- "$p"
}
launch_failed=""
out=$(launch control "$control_prompt" ${control_cmd:+Bash}) || launch_failed="control: $out"
if [ -z "$launch_failed" ]; then out=$(launch shell "$shell_prompt" Bash) || launch_failed="shell: $out"; fi
if [ -z "$launch_failed" ]; then
  if [ "$plant" = schedule-dropped ]; then
    out=$(launch schedule "$schedule_prompt" ToolSearch CronCreate CronDelete) || launch_failed="schedule: $out"
  else
    out=$(launch schedule "$schedule_prompt" ToolSearch CronCreate) || launch_failed="schedule: $out"
  fi
fi
if [ -z "$launch_failed" ]; then out=$(launch release "$release_prompt" Bash) || launch_failed="release: $out"; fi
[ -z "$launch_failed" ] || { all INCONCLUSIVE "a launch did not start a session ($(oneline "$launch_failed"))"; exit 0; }

# Each first turn's end is when it replies DONE. Every pending session is looked at in each round,
# so a late look at one does not move another's time. The wait is bounded by session_wait.
pending=$arms
t_wait=$(now)
while [ -n "$pending" ]; do
  still=""
  for a in $pending; do
    rc=0; "$sp" evidence codeword "$a" DONE >/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then setv end_$a "$(now)"; else still="$still $a"; fi
  done
  pending=${still# }
  [ -z "$pending" ] && break
  if atleast "$(since "$(now)" "$t_wait")" "$session_wait"; then break; fi
  sleep "$first_poll"
done
for a in $pending; do setv res_$a "INCONCLUSIVE|the first turn did not finish within ${session_wait}s (no DONE in its transcript), so its idle clock never started"; done

# What each arm's holder is, read from its transcript; the result is OK or VERDICT|reason.
bash_holder() { # NAME COMMAND
  local rc=0 out
  out=$("$sp" evidence calls "$1" --command "$2") || rc=$?
  case $rc in
    3) echo "INCONCLUSIVE|the transcript cannot be read: $(oneline "$out")"; return ;;
    1) echo "INCONCLUSIVE|the session never ran \"$2\" as a Bash call"; return ;;
  esac
  if printf '%s\n' "$out" | awk -F'\t' -v c="$2 [background]" '$1 == "ok" && $3 == c { f = 1 } END { exit !f }'; then
    echo OK; return
  fi
  if printf '%s\n' "$out" | awk -F'\t' '$1 == "denied" { f = 1 } END { exit !f }'; then
    echo "DENIED|a permission rule stopped the call: $(oneline "$(printf '%s\n' "$out" | head -1 | cut -f4)")"; return
  fi
  echo "INCONCLUSIVE|the command was not an ok background call: $(oneline "$(printf '%s\n' "$out" | head -1 | cut -f1,3)")"
}
cron_holder() {
  local rc=0 out cl
  out=$("$sp" evidence calls schedule --tool CronCreate --tool ToolSearch) || rc=$?
  [ "$rc" -ne 3 ] || { echo "INCONCLUSIVE|the transcript cannot be read: $(oneline "$out")"; return; }
  cl=$(printf '%s\n' "$out" | awk -F'\t' '$2 == "CronCreate"')
  if [ -z "$cl" ]; then
    if printf '%s\n' "$out" | awk -F'\t' '$2 == "ToolSearch"' | grep -qiE "$unavailable"; then
      echo "SKIPPED|no CronCreate tool was available to the session (ToolSearch found none; its result: $(oneline "$(printf '%s\n' "$out" | awk -F'\t' '$2 == "ToolSearch"' | head -1 | cut -f4)"))"
    else
      echo "INCONCLUSIVE|the session never called CronCreate"
    fi
    return
  fi
  if printf '%s\n' "$cl" | awk -F'\t' -v e="\"recurring\":false" -v c="$cron" '$1 == "ok" && index($3, e) && index($3, c) { f = 1 } END { exit !f }'; then
    echo OK; return
  fi
  case $(printf '%s\n' "$cl" | head -1 | cut -f1) in
    denied) echo "DENIED|a permission rule stopped the CronCreate call: $(oneline "$(printf '%s\n' "$cl" | head -1 | cut -f4)")" ;;
    error)
      if printf '%s\n' "$cl" | head -1 | cut -f4 | grep -qiE "$unavailable"; then
        echo "SKIPPED|CronCreate is not available to the session ($(oneline "$(printf '%s\n' "$cl" | head -1 | cut -f4)"))"
      else
        echo "INCONCLUSIVE|the CronCreate call failed: $(oneline "$(printf '%s\n' "$cl" | head -1 | cut -f4)")"
      fi ;;
    *) echo "INCONCLUSIVE|the CronCreate call was not an ok one-shot job for $cron: $(oneline "$(printf '%s\n' "$cl" | head -1 | cut -f1,3)")" ;;
  esac
}

# The control first: with no usable control no arm can be read.
if [ -z "$(getv res_control)" ]; then
  if [ -n "$control_cmd" ]; then
    h=$(bash_holder control "$control_cmd")
    [ "$h" = OK ] || setv res_control "INCONCLUSIVE|the control's own holder is missing, so the plant was not applied: ${h#*|}"
  else
    cc=0; c=$("$sp" evidence calls control) || cc=$?
    case $cc in
      0) setv res_control "VOID|the control made tool calls, so it is not a session with nothing to hold it: $(oneline "$c")" ;;
      3) setv res_control "INCONCLUSIVE|the control's transcript cannot be read: $(oneline "$c")" ;;
    esac
  fi
fi
if [ -n "$(getv res_control)" ]; then
  v=$(getv res_control); all "${v%%|*}" "control: ${v#*|}"; exit 0
fi

# The other arms' holders; one that was not made leaves that arm unmeasured, never failed.
for a in shell release; do
  [ -z "$(getv res_$a)" ] || continue
  if [ "$a" = shell ]; then cmd=$shell_cmd; else cmd=$release_cmd; fi
  h=$(bash_holder "$a" "$cmd")
  [ "$h" = OK ] || setv res_$a "$h"
done
if [ -z "$(getv res_schedule)" ]; then
  h=$(cron_holder)
  if [ "$h" = OK ] && [ "$plant" = schedule-dropped ]; then
    dc=0; d=$("$sp" evidence calls schedule --tool CronDelete) || dc=$?
    if [ "$dc" -ne 0 ] || ! printf '%s\n' "$d" | awk -F'\t' '$1 == "ok" { f = 1 } END { exit !f }'; then
      h="INCONCLUSIVE|the session did not delete its job with an ok CronDelete call, so the plant was not applied"
    fi
  fi
  [ "$h" = OK ] || setv res_schedule "$h"
fi

# Poll the process of every session still believed running, once a round, until the stop rule in
# the header or the cap (both bounded by the clock).
series=$(dirname "$SEAM_PROBE_RUN")/session-idle-holders${plant:+-$plant}-poll-series.txt
: > "$series"
watch="control"
for a in shell schedule release; do [ -n "$(getv res_$a)" ] || watch="$watch $a"; done
while :; do
  line=""
  t_round=$(now)   # every reading of this round is stamped with it, so "seen" never trails the margin test
  for a in $watch; do
    if [ -n "$(getv stop_$a)" ]; then line="$line $a=stopped"; continue; fi
    rc=0; out=$("$sp" session process "$a") || rc=$?
    case $rc in
      0) st=$(printf '%s' "$out" | sed -n 's/.*status \([A-Za-z]*\)$/\1/p'); st=${st:-roster}
         setv seen_$a "$t_round"; setv read_$a 1; setv last_$a running; line="$line $a=running($st)" ;;
      1) setv stop_$a "$(now)"; setv read_$a 1; line="$line $a=stopped" ;;
      *) setv last_$a unreadable; line="$line $a=unreadable"; printf '# %s: %s\n' "$a" "$(oneline "$out")" >> "$series" ;;
    esac
  done
  printf '+%ss%s\n' "$(since "$(now)" "$t_launch")" "$line" >> "$series"
  cs=$(getv stop_control)
  release_done=0
  { [ -n "$(getv res_release)" ] || [ -n "$(getv stop_release)" ]; } && release_done=1
  if [ -n "$cs" ] && [ "$release_done" -eq 1 ] && atleast "$(since "$t_round" "$cs")" "$margin"; then break; fi
  if atleast "$(since "$(now)" "$t_launch")" "$cap"; then break; fi
  sleep "$poll"
done
t_end=$(now)
where="the poll series is at <results>/$(basename "$series")"

# Verdicts.
cs=$(getv stop_control)
if [ -z "$cs" ]; then
  if [ -z "$(getv read_control)" ]; then
    all INCONCLUSIVE "the control's process state could not be read at any poll ($where)"
  elif [ "$(getv last_control)" = unreadable ]; then
    all INCONCLUSIVE "the control's process state was unreadable at the end of the run (last read, still present, $(after_turn control "$(getv seen_control)") min after its turn ended), so a stop could not be seen ($where)"
  else
    all VOID "the control was never stopped, so the idle stop was not observed (an attached client such as an open agent view, or a changed idle duration): its process was still present $(after_turn control "$(getv seen_control)") min after its turn ended, at the end of the ${cap}s cap"
  fi
  exit 0
fi
cmin=$(after_turn control "$cs")
"$sp" verdict --arm control PASS "the idle stop was observed: no process $cmin min after its turn ended"

# A holder's arm: the process is still present at the end, at least the margin after the control stopped.
hold_arm() { # ARM
  local a=$1 v
  v=$(getv res_$a)
  if [ -n "$v" ]; then "$sp" verdict --arm "$a" "${v%%|*}" "${v#*|}"; return; fi
  if [ -n "$(getv stop_$a)" ]; then
    "$sp" verdict --arm "$a" FAIL "the process was gone $(after_turn "$a" "$(getv stop_$a)") min after its first turn ended, before the end of the run ($(after_turn "$a" "$t_end") min), with the control stopped at $cmin min after its own"
    return
  fi
  if [ -z "$(getv read_$a)" ]; then
    "$sp" verdict --arm "$a" INCONCLUSIVE "its process state could not be read at any poll ($where)"; return
  fi
  if ! atleast "$(since "$(getv seen_$a)" "$cs")" "$margin"; then
    "$sp" verdict --arm "$a" INCONCLUSIVE "the run ended too soon to tell: the process was last seen $(minutes "$(since "$(getv seen_$a)" "$cs")") min after the control stopped, less than the ${margin}s margin ($where)"; return
  fi
  "$sp" verdict --arm "$a" PASS "the process was still present $(after_turn "$a" "$(getv seen_$a)") min after its first turn ended, $(minutes "$(since "$(getv seen_$a)" "$cs")") min after the control stopped (at $cmin min after its own turn), a margin of at least $(minutes "$margin") min"
}
hold_arm shell
hold_arm schedule

v=$(getv res_release)
if [ -n "$v" ]; then "$sp" verdict --arm release "${v%%|*}" "${v#*|}"; exit 0; fi
if [ -z "$(getv read_release)" ]; then
  "$sp" verdict --arm release INCONCLUSIVE "its process state could not be read at any poll ($where)"; exit 0
fi
# Its command's end, which is when the session is notified, taken as the first turn's end plus the
# seconds the command sleeps: the transcript's notification time is not read.
cmd_end=$(python3 -c 'import sys; print("%.3f" % (float(sys.argv[1]) + float(sys.argv[2])))' "$(getv end_release)" "$rel_secs")
rs=$(getv stop_release)
if [ -z "$rs" ]; then
  if atleast "$(since "$t_end" "$cmd_end")" 0; then
    "$sp" verdict --arm release FAIL "still running at the end of the run, $(minutes "$(since "$t_end" "$cmd_end")") min after its background command ended (taken as first turn end plus ${rel_secs}s) and $(minutes "$(since "$t_end" "$cs")") min after the control stopped"
  else
    "$sp" verdict --arm release INCONCLUSIVE "the run ended before its background command did (${rel_secs}s after its first turn), so a stop after it could not be seen"
  fi
  exit 0
fi
if atleast "$(since "$rs" "$cmd_end")" 0; then
  "$sp" verdict --arm release PASS "stopped $(minutes "$(since "$rs" "$cmd_end")") min after its background command ended (taken as first turn end plus ${rel_secs}s, not read from the transcript), $(after_turn release "$rs") min after its first turn ended and $(minutes "$(since "$rs" "$cs")") min after the control stopped"
else
  "$sp" verdict --arm release FAIL "stopped $(after_turn release "$rs") min after its first turn ended, while its background command (${rel_secs}s) still ran"
fi
