# Shared by the session-lifecycle cases that watch idle background sessions (idle-holders and
# completion-hold), sourced by each case script. Each case declares this file in suite.toml's
# `helpers`, so a change here retires both cases' seen-red records, as a change to their own script
# does.
#
# Before sourcing, the case sets: sp ($SEAM_PROBE), plant, arms (its arm names, the control first),
# session_wait and first_poll (seconds). After idle_setup, `repo` is the fixture repository. Before
# write_header it sets case_id, record (the record's path), watch (the arms still polled) and
# t_launch.
#
# The case decides no verdict: it writes what it sees to a JSONL record, and classify.py, declared
# beside this file in the case's `helpers`, judges every verdict from the record alone, with no clock.
#
# The conventions every function here keeps:
#   - A holder (a background command, a scheduled job) is read from the session's transcript
#     (`evidence calls`), never from the session's own account.
#   - A turn after the first (a job firing, a completion delivered) is read from the transcript too:
#     its prompt asks for a codeword no other turn is asked for, looked for once a poll round, and
#     the turn's end is the time the transcript records for that reply (`evidence codeword --at`).
#   - The process is read by `session process`, from Claude Code's pid records and the daemon's
#     roster, because the agents listing carries no pid and keeps showing a stopped session as done
#     or blocked.
#   - Per-arm state lives in variables named <what>_<arm>, read and set through getv and setv.
#   - Date arithmetic is python3's: no spelling of `date` is common to the GNU and BSD userlands.

unavailable='no (matching )?(deferred )?tools?|no such tool|unknown tool|not found|not available|unavailable'

all() { for a in $arms; do "$sp" verdict --arm "$a" "$1" "$2"; done; }
oneline() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-300; }
getv() { eval "printf '%s' \"\${$1:-}\""; }
setv() { eval "$1=\$2"; }

command -v python3 >/dev/null 2>&1 || { all SKIPPED "python3 is not installed (this case's time arithmetic needs it)"; exit 0; }
now() { python3 -c 'import time; print("%.3f" % time.time())'; }
since() { python3 -c 'import sys; print("%.3f" % (float(sys.argv[1]) - float(sys.argv[2])))' "$1" "$2"; }
atleast() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$1" "$2"; }

# A one-shot job's local wall-clock cron expression for SECONDS (summed) from now, and the epoch at
# which it is due, separated by "|". The expression names the minute that instant falls in, so the
# job is due at that minute's start, up to a minute before the instant.
cron_at() {
  python3 -c '
import sys, time
from datetime import datetime
t = datetime.fromtimestamp(time.time() + sum(float(x) for x in sys.argv[1:])).replace(second=0, microsecond=0)
print("%d %d %d %d *|%.3f" % (t.minute, t.hour, t.day, t.month, t.timestamp()))' "$@"
}

# The fixture and its trust. SKIPPED with the step that fixes it, the fixture left in place for it,
# when Claude Code has not trusted the fixture (a background session refuses an untrusted workspace).
idle_setup() { # FIXTURE
  repo=$("$sp" fixture repo "$1") || { all INCONCLUSIVE "the fixture could not be built"; exit 0; }
  local trc=0 tout
  tout=$("$sp" evidence trusted "$repo") || trc=$?
  case $trc in
    0) ;;
    1) "$sp" fixture keep "$repo" >/dev/null
       all SKIPPED "the fixture needs Claude Code's trust (from a plain terminal: cd $(printf %q "$repo") && claude, accept the dialog, /exit); then run the case again"
       exit 0 ;;
    *) all INCONCLUSIVE "the trust state cannot be read: $tout"; exit 0 ;;
  esac
}

first_command() { printf '%s\n' "$1" | sed -n 's/^1\. //p'; }

# The instructions that make one pending one-shot job: CRON is its expression, JOB its prompt.
cron_steps() { # CRON JOB
  printf '%s' "Load the CronCreate tool with ToolSearch (query select:CronCreate). Call CronCreate once, with recurring set to false, the cron expression \"$1\" and the prompt \"$2\"."
}
# A first turn that makes one job and nothing else; DELETE (non-empty) also deletes it.
cron_prompt() { # CRON JOB [DELETE]
  local steps
  steps=$(cron_steps "$1" "$2")
  if [ -n "${3:-}" ]; then
    steps="Load the CronCreate and CronDelete tools with ToolSearch (query select:CronCreate,CronDelete). ${steps#*). } Then call CronDelete once, to delete the job CronCreate returned."
  fi
  printf '%s' "Do the following in order, and use no other tools. $steps Then reply with the single word DONE and end your turn."
}
# A first turn that makes one job and then starts the background commands of PROMPT.
cron_then() { # CRON JOB PROMPT
  printf '%s\n\n%s' "First, before anything else: $(cron_steps "$1" "$2") Then follow these instructions:" "$3"
}

# Launched in quick succession, so the idle clocks start together.
launch() { # NAME PROMPT [RULE...]
  local n=$1 p=$2 r; shift 2
  local args=()
  for r in "$@"; do args+=(--allow "$r"); done
  "$sp" session launch "$n" --regime "$SEAM_PROBE_REGIME" --cwd "$repo" ${args[@]+"${args[@]}"} -- "$p"
}

# When ARM's reply holding WORD was written, from its transcript's own timestamp; FALLBACK (the
# look's time) when the transcript has none. Exit 1 when the word is not there yet. The look is not
# the turn: the arms launch one after another and are looked at only once all are up, so a look's
# time trails the turn by the launches after it, and on a loaded machine that is seconds.
reply_time() { # ARM WORD FALLBACK
  local out t
  out=$("$sp" evidence codeword "$1" "$2" --at) || return 1
  t=$(printf '%s\n' "$out" | sed -n 's/^at: //p')
  printf '%s\n' "${t:-$3}"
}

# Each first turn's end is when it replied DONE: end_<arm>, read by reply_time. Every pending
# session is looked at in each round. Bounded by session_wait; an arm whose turn did not end gets
# res_<arm>, INCONCLUSIVE.
await_first_turns() {
  local pending=$arms still a t t_wait
  t_wait=$(now)
  while [ -n "$pending" ]; do
    still=""
    for a in $pending; do
      if t=$(reply_time "$a" DONE "$(now)"); then setv end_$a "$t"; else still="$still $a"; fi
    done
    pending=${still# }
    [ -z "$pending" ] && break
    if atleast "$(since "$(now)" "$t_wait")" "$session_wait"; then break; fi
    sleep "$first_poll"
  done
  for a in $pending; do setv res_$a "INCONCLUSIVE|the first turn did not finish within ${session_wait}s (no DONE in its transcript), so its idle clock never started"; done
}

# What an arm's holder is, read from its transcript; each prints OK or VERDICT|reason.
bash_holder() { # ARM COMMAND
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
cron_holder() { # ARM CRON [DELETED]: an ok one-shot CronCreate job for CRON; DELETED, then an ok CronDelete
  local rc=0 out cl dc d
  out=$("$sp" evidence calls "$1" --tool CronCreate --tool ToolSearch) || rc=$?
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
  if ! printf '%s\n' "$cl" | awk -F'\t' -v e="\"recurring\":false" -v c="$2" '$1 == "ok" && index($3, e) && index($3, c) { f = 1 } END { exit !f }'; then
    case $(printf '%s\n' "$cl" | head -1 | cut -f1) in
      denied) echo "DENIED|a permission rule stopped the CronCreate call: $(oneline "$(printf '%s\n' "$cl" | head -1 | cut -f4)")" ;;
      error)
        if printf '%s\n' "$cl" | head -1 | cut -f4 | grep -qiE "$unavailable"; then
          echo "SKIPPED|CronCreate is not available to the session ($(oneline "$(printf '%s\n' "$cl" | head -1 | cut -f4)"))"
        else
          echo "INCONCLUSIVE|the CronCreate call failed: $(oneline "$(printf '%s\n' "$cl" | head -1 | cut -f4)")"
        fi ;;
      *) echo "INCONCLUSIVE|the CronCreate call was not an ok one-shot job for $2: $(oneline "$(printf '%s\n' "$cl" | head -1 | cut -f1,3)")" ;;
    esac
    return
  fi
  if [ -n "${3:-}" ]; then
    dc=0; d=$("$sp" evidence calls "$1" --tool CronDelete) || dc=$?
    if [ "$dc" -ne 0 ] || ! printf '%s\n' "$d" | awk -F'\t' '$1 == "ok" { f = 1 } END { exit !f }'; then
      echo "INCONCLUSIVE|the session did not delete its job with an ok CronDelete call, so the plant was not applied"; return
    fi
  fi
  echo OK
}

# The control has nothing to hold it, unless a plant gave it a job (CRON non-empty): read that.
control_holder() { # [CRON]
  [ -z "$(getv res_control)" ] || return 0
  local h cc=0 c
  if [ -n "${1:-}" ]; then
    h=$(cron_holder control "$1")
    [ "$h" = OK ] || setv res_control "INCONCLUSIVE|the control's own holder is missing, so the plant was not applied: ${h#*|}"
    return 0
  fi
  c=$("$sp" evidence calls control) || cc=$?
  case $cc in
    0) setv res_control "VOID|the control made tool calls, so it is not a session with nothing to hold it: $(oneline "$c")" ;;
    3) setv res_control "INCONCLUSIVE|the control's transcript cannot be read: $(oneline "$c")" ;;
  esac
}
# With no usable control no arm can be read.
control_or_exit() {
  local v
  v=$(getv res_control)
  [ -z "$v" ] || { all "${v%%|*}" "control: ${v#*|}"; exit 0; }
}
set_unless_ok() { [ "$2" = OK ] || setv res_$1 "$2"; }

# The record and its judge (classify.py, declared beside this file in each case's `helpers`): the
# case writes what it sees, and every verdict is judged from that record alone, with no clock.
classify() { python3 "$SEAM_PROBE_SUITE_DIR/classify.py" "$@"; }
# Each arm's verdict, judged from the record and recorded; a record that cannot be judged leaves
# every arm INCONCLUSIVE, naming why.
judge() {
  local out rc=0 a v r tab
  tab=$(printf '\t')
  out=$(classify verdicts "$record" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then all INCONCLUSIVE "the record could not be judged: $(oneline "$out")"; return; fi
  printf '%s\n' "$out" | while IFS="$tab" read -r a v r; do "$sp" verdict --arm "$a" "$v" "$r"; done
}
# The record's header, once the first turns and holders are read: each arm's first turn's end and any
# verdict already decided (res_<arm>), the arms still watched, and CONFIG (K=V words) besides the record's
# own name.
write_header() { # CONFIG...
  local a args=()
  for a in $arms; do args+=(--turn-end "$a=$(getv end_$a)" --pre "$a=$(getv res_$a)"); done
  for a in "$@"; do args+=(--config "$a"); done
  : > "$record"
  classify header "$record" --case "$case_id" --plant "$plant" --arms "$arms" --watch "$watch" \
    --t-launch "$t_launch" --config "record=$(basename "$record")" "${args[@]}"
}
# With no usable control no arm can be read: the record says so, and the judge gives every arm the
# control's verdict.
control_or_exit() { # CONFIG...
  [ -n "$(getv res_control)" ] || return 0
  watch=""; write_header "$@"; classify end "$record" --t "$(now)"; judge; exit 0
}
set_unless_ok() { [ "$2" = OK ] || setv res_$1 "$2"; }

# One round's reading of arm A's process, added to the round's record line (rargs). stop_<a> is kept
# so a stopped arm is not looked at again; the judge derives every other state from the rounds.
poll_process() { # ARM
  local a=$1 rc=0 out st
  if [ -n "$(getv stop_$a)" ]; then rargs+=(--read "$a=stopped"); return; fi
  out=$("$sp" session process "$a") || rc=$?
  case $rc in
    0) st=$(printf '%s' "$out" | sed -n 's/.*status \([A-Za-z]*\)$/\1/p'); st=${st:-roster}
       rargs+=(--read "$a=running" --status "$a=$st") ;;
    1) setv stop_$a "$t_round"; rargs+=(--read "$a=stopped") ;;
    *) rargs+=(--read "$a=unreadable" --note "$a=$(oneline "$out")") ;;
  esac
}
# One round's look for WORD in arm A's replies; the first that sees it sets <var>_<a> and adds the
# reply's time by reply_time (this round's when the transcript has none) to the round's line.
poll_word() { # ARM WORD VAR
  local t
  [ -z "$(getv "$3_$1")" ] || return 0
  if t=$(reply_time "$1" "$2" "$t_round"); then setv "$3_$1" "$t"; rargs+=(--word "$1=$2@$t"); fi
}
