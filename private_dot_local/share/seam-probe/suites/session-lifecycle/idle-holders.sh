# Case idle-holders, run by `seam-probe run|red session-lifecycle idle-holders`.
#
# Claude Code's supervisor stops a background session that is finished or waiting for the next
# message and unattached for about an hour, and counts a running subagent, workflow or monitor, or a
# pending session-scoped scheduled task, as working. This case asks what keeps an idle, unattached
# background session's process running past that stop, and what a delivered completion does: on
# 2.1.330 a background command still running held nothing, and one that had finished, its
# completion delivered as a new turn, held its session at least 105 minutes. Five sessions are
# launched together from one fixture repository, each reaching its first turn's end at about the
# same time, which is when its idle clock starts:
#   control   no tool, and so no holder: it must be seen to stop, or the idle stop was never observed
#   shell     one background Bash command (`sleep 9000`, 150 minutes) still running throughout: it
#             must be stopped about the control's idle duration after its turn, so a running
#             command is not a holder
#   turn      one one-shot CronCreate job, due SEAM_PROBE_TURN_AT after the launches, whose prompt
#             asks for the word FIRED: its firing is a second turn with no background task behind
#             it, and the session must be stopped about the control's idle duration after that turn
#             ends, so a turn alone restarts the idle clock and holds nothing
#   schedule  one one-shot CronCreate job due past the cap, so pending throughout: it must be present
#             at least the margin after the control stopped
#   release   one background Bash command that ends soon (`sleep 900`), the prompt asking for the
#             word RELEASED in reply to its completion: it must be present at least the margin past
#             the control's idle duration after that completion turn ended, so a delivered completion
#             holds the session beyond restarting its clock (the comparison with turn)
# Each holder is read from the session's transcript (`evidence calls`), never from the session's
# own account, and so is each turn: the first turn's DONE and the job's and completion's codewords
# are looked for once a poll round, and each turn's end is the time the transcript itself records
# for that reply (`evidence codeword --at`), never the round that found it and never the launch.
# The rounds start only once all five sessions are up, so on a loaded machine a round can trail an
# earlier arm's turn by the later launches; the round's time stands in only for a transcript that
# records none.
# The process is read by `session process`, from Claude Code's pid records and the daemon's roster.
# Every poll round is one line of the run's record (session-idle-holders[-PLANT]-record.jsonl in
# the results directory), with each arm's reading and each codeword's first sighting, so the time
# series survives the run; every verdict is judged from that record by classify.py, which reads no
# clock. The shared mechanics are in idle-lib.sh; the case declares both as its helpers.
#
# "About the control's idle duration" is within the tolerance (SEAM_PROBE_IDLE_TOLERANCE, default
# 900 s) of the control's own time from its turn's end to its stop. Seen present the margin
# (SEAM_PROBE_IDLE_MARGIN, default 1800 s) past that duration, shell and turn FAIL. Stopped outside
# the tolerance but before the margin, they are INCONCLUSIVE: something held them a while, or stopped
# them early, and this case does not read what. The margin is wider than the tolerance, so no
# reading is both. A stop is timed by the round that first finds the process gone, which is a time
# only if an earlier round found it present: gone at the first look, it stopped at some time before
# then. A control gone at the first look makes every arm INCONCLUSIVE (its idle duration was not
# measured); an arm gone at the first look is INCONCLUSIVE, and reads "sooner" only when even that
# first look is sooner than the control's stop by more than the tolerance. Neither ever PASSes.
#
# A monitor is NOT an arm. The Monitor tool's own schema caps its timeout_ms at 1,800,000 ms (30
# minutes), so a monitor holds a session past the hour only by being re-armed, and each re-arm is a
# turn, which resets the idle clock itself: the measurement would be of the re-arming, not of the
# monitor.
#
# The run polls until every arm is decided (the control stopped; shell and turn stopped, or present
# the margin past the control's idle duration after their reference turn; schedule present the
# margin after the control's stop; release stopped, or present the margin past the control's idle
# duration after its completion turn), or until the cap, whichever is first. A control never seen to
# stop by the cap makes every arm VOID: the instrument could not see the thing (an attached client,
# or a changed idle duration). Under the defaults the slowest arm decides at about 15 + 61 + 30
# minutes, inside the 120-minute cap.
#
# Times are seconds from SEAM_PROBE_* variables, so a test can shrink them: SEAM_PROBE_SESSION_WAIT
# (first turn, default 300), SEAM_PROBE_IDLE_POLL (60), SEAM_PROBE_IDLE_MARGIN (1800),
# SEAM_PROBE_IDLE_TOLERANCE (900), SEAM_PROBE_IDLE_CAP (7200), SEAM_PROBE_TURN_AT (900, the turn
# arm's job, at the start of the minute it falls in). A job past the cap is set for the cap plus 30
# minutes after the launches.
#
# Plants ($SEAM_PROBE_PLANT): control-held gives the control a pending job past the cap, so it never
# stops and every arm is VOID; shell-held gives the shell arm the same job beside its command, so it
# stays and its arm FAILs; schedule-dropped has the schedule session delete its job with CronDelete,
# so it stops and its arm FAILs; completion-withheld makes the release command `sleep 9000`, so no
# completion arrives, the session stops and its arm FAILs.
#
# Precondition, SKIPPED with the step that fixes it, the fixture left in place for it: Claude Code's
# trust for the fixture repository (a background session refuses an untrusted workspace).
set -u
sp=$SEAM_PROBE
plant=${SEAM_PROBE_PLANT:-}
arms="control shell turn schedule release"
session_wait=${SEAM_PROBE_SESSION_WAIT:-300}
first_poll=${SEAM_PROBE_POLL:-2}
poll=${SEAM_PROBE_IDLE_POLL:-60}
margin=${SEAM_PROBE_IDLE_MARGIN:-1800}
tolerance=${SEAM_PROBE_IDLE_TOLERANCE:-900}
cap=${SEAM_PROBE_IDLE_CAP:-7200}
turn_at=${SEAM_PROBE_TURN_AT:-900}
. "$SEAM_PROBE_SUITE_DIR/idle-lib.sh"

idle_setup idl

# The prompts. The shell and release commands are read back from the prompt, so the case never
# restates what suite.toml declares.
release_key=release
[ "$plant" = completion-withheld ] && release_key=hold
shell_prompt=$("$sp" prompt --background hold) || { all INCONCLUSIVE "the prompt could not be built"; exit 0; }
release_prompt=$("$sp" prompt --background --notified RELEASED "$release_key") || { all INCONCLUSIVE "the prompt could not be built"; exit 0; }
shell_cmd=$(first_command "$shell_prompt")
release_cmd=$(first_command "$release_prompt")

late=$(cron_at "$cap" 1800) || { all INCONCLUSIVE "the cron expression could not be computed"; exit 0; }
late_cron=${late%|*}
soon=$(cron_at "$turn_at") || { all INCONCLUSIVE "the cron expression could not be computed"; exit 0; }
turn_cron=${soon%|*}; turn_due=${soon#*|}
pending_job="Reply DONE."
turn_job="Reply with the single word FIRED and nothing else, and use no tools."

control_prompt="Reply with the single word DONE and nothing else. Do not use any tool."
control_cron=""
if [ "$plant" = control-held ]; then control_prompt=$(cron_prompt "$late_cron" "$pending_job"); control_cron=$late_cron; fi
if [ "$plant" = shell-held ]; then shell_prompt=$(cron_then "$late_cron" "$pending_job" "$shell_prompt"); fi
deleted=""
[ "$plant" = schedule-dropped ] && deleted=1

t_launch=$(now)
launch_failed=""
if [ -n "$control_cron" ]; then out=$(launch control "$control_prompt" ToolSearch CronCreate) || launch_failed="control: $out"
else out=$(launch control "$control_prompt") || launch_failed="control: $out"; fi
if [ -z "$launch_failed" ]; then
  if [ "$plant" = shell-held ]; then out=$(launch shell "$shell_prompt" Bash ToolSearch CronCreate) || launch_failed="shell: $out"
  else out=$(launch shell "$shell_prompt" Bash) || launch_failed="shell: $out"; fi
fi
if [ -z "$launch_failed" ]; then out=$(launch turn "$(cron_prompt "$turn_cron" "$turn_job")" ToolSearch CronCreate) || launch_failed="turn: $out"; fi
if [ -z "$launch_failed" ]; then
  if [ -n "$deleted" ]; then out=$(launch schedule "$(cron_prompt "$late_cron" "$pending_job" 1)" ToolSearch CronCreate CronDelete) || launch_failed="schedule: $out"
  else out=$(launch schedule "$(cron_prompt "$late_cron" "$pending_job")" ToolSearch CronCreate) || launch_failed="schedule: $out"; fi
fi
if [ -z "$launch_failed" ]; then out=$(launch release "$release_prompt" Bash) || launch_failed="release: $out"; fi
[ -z "$launch_failed" ] || { all INCONCLUSIVE "a launch did not start a session ($(oneline "$launch_failed"))"; exit 0; }

await_first_turns

# The record, in the run's results directory: the header once the holders are read, one line a poll
# round, and every verdict judged from it by classify.py.
case_id=idle-holders
record=$(dirname "$SEAM_PROBE_RUN")/session-idle-holders${plant:+-$plant}-record.jsonl
config="tolerance=$tolerance margin=$margin cap=$cap turn_due=$turn_due"
watch=""

# The holders, the control's first: with no usable control no arm can be read. One that was not
# made leaves that arm unmeasured, never failed.
control_holder "$control_cron"
control_or_exit $config
if [ -z "$(getv res_shell)" ]; then
  h=$(bash_holder shell "$shell_cmd")
  if [ "$h" = OK ] && [ "$plant" = shell-held ]; then h=$(cron_holder shell "$late_cron"); fi
  set_unless_ok shell "$h"
fi
[ -n "$(getv res_turn)" ] || set_unless_ok turn "$(cron_holder turn "$turn_cron")"
[ -n "$(getv res_schedule)" ] || set_unless_ok schedule "$(cron_holder schedule "$late_cron" "$deleted")"
[ -n "$(getv res_release)" ] || set_unless_ok release "$(bash_holder release "$release_cmd")"

# Poll every watched session once a round until the judge finds every arm decided, or the cap.
watch="control"
for a in shell turn schedule release; do [ -n "$(getv res_$a)" ] || watch="$watch $a"; done
write_header $config
while :; do
  rargs=()
  t_round=$(now)   # every reading of this round is stamped with it, so "seen" never trails a threshold
  for a in $watch; do poll_process "$a"; done
  case " $watch " in *" turn "*) poll_word turn FIRED fired ;; esac
  case " $watch " in *" release "*) poll_word release RELEASED comp ;; esac
  classify round "$record" --t "$t_round" ${rargs[@]+"${rargs[@]}"}
  if classify decided "$record"; then break; fi
  if atleast "$(since "$(now)" "$t_launch")" "$cap"; then break; fi
  sleep "$poll"
done
classify end "$record" --t "$(now)"
judge
