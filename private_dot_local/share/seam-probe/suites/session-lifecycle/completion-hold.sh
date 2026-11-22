# Case completion-hold, run by `seam-probe run|red session-lifecycle completion-hold`.
#
# idle-holders found, on Claude Code 2.1.330, that a background session whose background command has
# finished, and whose completion was delivered as a new turn, stays up at least 105 minutes past
# that turn, where a session with nothing to hold it is stopped at about 61. If such a session is
# never stopped, every session that ever ran a background command never idles out, a leak across
# every agent and seat that runs one. This case runs past idle-holders' two-hour cap to learn whether
# such a session is stopped at all, and when. Two sessions are launched together from one fixture
# repository:
#   control   no tool, and so no holder: it must be seen to stop, or the idle stop was never observed
#   release   one background Bash command that ends soon (`sleep 900`), the prompt asking for the
#             word RELEASED in reply to its completion: it must be stopped within the cap, its
#             completion turn read from its transcript first. Still present at the cap is the leak,
#             and FAILs.
# Holders are read from the session's transcript (`evidence calls`), the completion turn from its
# codeword once a poll round, and the process by `session process`, from Claude Code's pid records
# and the daemon's roster. Every poll round is one line of the run's record
# (session-completion-hold[-PLANT]-record.jsonl), and every verdict is judged from it by
# classify.py, which reads no clock. The shared mechanics are in idle-lib.sh; the case declares both
# as its helpers.
#
# The run polls every SEAM_PROBE_IDLE_POLL seconds (default 300) until both sessions have stopped,
# or until the cap (SEAM_PROBE_IDLE_CAP, default 28800: eight hours). A control never seen to stop
# makes every arm VOID. A release session that stopped with no completion turn seen, or is present
# at the cap with none, was never held by a delivered completion, so is INCONCLUSIVE. Also from
# SEAM_PROBE_* variables: SEAM_PROBE_SESSION_WAIT (first turn, default 300). A job past the cap is
# set for the cap plus 30 minutes after the launches.
#
# Plants ($SEAM_PROBE_PLANT): held-past-cap gives the release session a pending job past the cap
# beside its command, so it is still present at the cap and its arm FAILs; control-held gives the
# control the same job, so it never stops and every arm is VOID.
#
# Precondition, SKIPPED with the step that fixes it, the fixture left in place for it: Claude Code's
# trust for the fixture repository (a background session refuses an untrusted workspace).
set -u
sp=$SEAM_PROBE
plant=${SEAM_PROBE_PLANT:-}
arms="control release"
session_wait=${SEAM_PROBE_SESSION_WAIT:-300}
first_poll=${SEAM_PROBE_POLL:-2}
poll=${SEAM_PROBE_IDLE_POLL:-300}
cap=${SEAM_PROBE_IDLE_CAP:-28800}
. "$SEAM_PROBE_SUITE_DIR/idle-lib.sh"

idle_setup cph

release_prompt=$("$sp" prompt --background --notified RELEASED release) || { all INCONCLUSIVE "the prompt could not be built"; exit 0; }
release_cmd=$(first_command "$release_prompt")
late=$(cron_at "$cap" 1800) || { all INCONCLUSIVE "the cron expression could not be computed"; exit 0; }
late_cron=${late%|*}
pending_job="Reply DONE."

control_prompt="Reply with the single word DONE and nothing else. Do not use any tool."
control_cron=""
if [ "$plant" = control-held ]; then control_prompt=$(cron_prompt "$late_cron" "$pending_job"); control_cron=$late_cron; fi
[ "$plant" != held-past-cap ] || release_prompt=$(cron_then "$late_cron" "$pending_job" "$release_prompt")

t_launch=$(now)
launch_failed=""
if [ -n "$control_cron" ]; then out=$(launch control "$control_prompt" ToolSearch CronCreate) || launch_failed="control: $out"
else out=$(launch control "$control_prompt") || launch_failed="control: $out"; fi
if [ -z "$launch_failed" ]; then
  if [ "$plant" = held-past-cap ]; then out=$(launch release "$release_prompt" Bash ToolSearch CronCreate) || launch_failed="release: $out"
  else out=$(launch release "$release_prompt" Bash) || launch_failed="release: $out"; fi
fi
[ -z "$launch_failed" ] || { all INCONCLUSIVE "a launch did not start a session ($(oneline "$launch_failed"))"; exit 0; }

await_first_turns

# The record, in the run's results directory: the header once the holders are read, one line a poll
# round, and every verdict judged from it by classify.py.
case_id=completion-hold
record=$(dirname "$SEAM_PROBE_RUN")/session-completion-hold${plant:+-$plant}-record.jsonl
config="cap=$cap"
watch=""

control_holder "$control_cron"
control_or_exit $config
if [ -z "$(getv res_release)" ]; then
  h=$(bash_holder release "$release_cmd")
  if [ "$h" = OK ] && [ "$plant" = held-past-cap ]; then h=$(cron_holder release "$late_cron"); fi
  set_unless_ok release "$h"
fi

# Poll until both sessions have stopped, or the cap.
watch="control"
[ -n "$(getv res_release)" ] || watch="$watch release"
write_header $config
while :; do
  rargs=()
  t_round=$(now)
  for a in $watch; do poll_process "$a"; done
  case " $watch " in *" release "*) poll_word release RELEASED comp ;; esac
  classify round "$record" --t "$t_round" ${rargs[@]+"${rargs[@]}"}
  if classify decided "$record"; then break; fi
  if atleast "$(since "$(now)" "$t_launch")" "$cap"; then break; fi
  sleep "$poll"
done
classify end "$record" --t "$(now)"
judge
