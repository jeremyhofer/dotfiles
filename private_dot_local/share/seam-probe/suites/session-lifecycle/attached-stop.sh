# Case attached-stop, run by `seam-probe run|red session-lifecycle attached-stop`.
#
# `fleet-canonicals refresh` replaces a long-running background session: SIGTERM to its process, up
# to 5 s for it to end, SIGKILL if it has not, then `claude rm <id>`, then a successor. A session may
# ask for its OWN refresh only once it is shown that Claude Code does not bring the stopped session
# back as a crash-respawn. Unattached sessions have been refreshed this way many times without one;
# what has not been measured is a session that is ATTACHED when it is stopped. Three sessions are
# launched from one fixture repository, each told to reply DONE and use no tool:
#   control    nothing attached: it must stay stopped, or a respawn cannot be laid to attachment
#   terminal   open in a terminal through `claude attach <id>`
#   agentview  selected in the agent view (`claude agents`) with its peek panel open
# Claude Code documents no attached field, so the instrument cannot see an attachment: a person makes
# each one in another terminal and confirms it (`seam-probe manual`). The attached verdicts therefore
# rest on that confirmation, and say so.
#
# Each arm in turn (control, terminal, agentview) is stopped with `seam-probe session term`, which is
# `close_one`'s sequence, and watched for SEAM_PROBE_RESPAWN_WATCH seconds (default 120) for any of
# three signs that it came back, each read every SEAM_PROBE_POLL seconds (default 2):
#   process     `session process` finds a process for its session uuid again
#   transcript  its transcript has more lines than when the stop finished
#   listing     `claude agents --json --all` lists a row with its id or uuid after the `claude rm`
# One line per poll goes to the results directory (session-attached-stop[-PLANT]-watch.txt). After
# each attached arm's watch the person is asked to look at the attached client; what the client's own
# display shows is not read by anything, so it is a prompt for the person, not evidence.
#
# Verdicts: control PASS when none of the signs appeared; if one did, every arm is VOID. Terminal and
# agentview PASS when none appeared, FAIL naming the sign and when. A `session term` that could not
# run (no live pid record, a process that survived SIGKILL, a failed `claude rm`), or a sign that
# could not be read at any poll, leaves that arm INCONCLUSIVE; an arm cannot PASS while the control
# is unmeasured.
#
# Plants ($SEAM_PROBE_PLANT): respawn has the case itself run `seam-probe session resume terminal`
# right after that arm's stop, a flagless resume, which brings the session back, so that arm must
# FAIL; control-respawn does the same to the control, so every arm is VOID. The manual steps run
# under a plant too: a person is at the terminal for `red` as for `run`.
#
# Precondition, SKIPPED with the step that fixes it, the fixture left in place for it: Claude Code's
# trust for the fixture repository (a background session refuses an untrusted workspace).
set -u
sp=$SEAM_PROBE
plant=${SEAM_PROBE_PLANT:-}
session_wait=${SEAM_PROBE_SESSION_WAIT:-300}
watch=${SEAM_PROBE_RESPAWN_WATCH:-120}
poll=${SEAM_PROBE_POLL:-2}
arms="control terminal agentview"
claude_bin=${SEAM_PROBE_CLAUDE:-claude}

all() { for a in $arms; do "$sp" verdict --arm "$a" "$1" "$2"; done; }
oneline() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-300; }
getv() { eval "printf '%s' \"\${$1:-}\""; }
setv() { eval "$1=\$2"; }

command -v python3 >/dev/null 2>&1 || { all SKIPPED "python3 is not installed (this case's time arithmetic needs it)"; exit 0; }
now() { python3 -c 'import time; print("%.3f" % time.time())'; }
since() { python3 -c 'import sys; print("%.1f" % (float(sys.argv[1]) - float(sys.argv[2])))' "$1" "$2"; }
atleast() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$1" "$2"; }

# The display name a session was launched under, read from this run's ledger.
display_of() {
  python3 -c '
import json, sys
for line in open(sys.argv[1]):
    e = json.loads(line)
    if e.get("kind") == "session" and e.get("name") == sys.argv[2] and e.get("display"):
        print(e["display"]); break' "$SEAM_PROBE_RUN" "$1"
}
# Lines in a session's transcript (all matching files), empty when there is none to read.
tlines() {
  local n=0 f found=""
  for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$1".jsonl; do
    [ -f "$f" ] || continue
    found=1; n=$((n + $(wc -l < "$f" | tr -d ' ')))
  done
  [ -n "$found" ] && echo "$n"
}
# 0 a listed row names the id or the uuid, 1 none does, 3 the listing could not be read.
listed() {
  local out rc=0
  out=$("$claude_bin" agents --json --all 2>&1 </dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 3
  printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
def walk(o):
    if isinstance(o, dict):
        if o.get("id") == sys.argv[1] or o.get("sessionId") == sys.argv[2]:
            return True
        return any(walk(v) for v in o.values())
    if isinstance(o, list):
        return any(walk(v) for v in o)
    return False
sys.exit(0 if walk(d) else 1)' "$1" "$2"
}

repo=$("$sp" fixture repo ats) || { all INCONCLUSIVE "the fixture could not be built"; exit 0; }
trc=0; tout=$("$sp" evidence trusted "$repo") || trc=$?
case $trc in
  0) ;;
  1) "$sp" fixture keep "$repo" >/dev/null
     all SKIPPED "the fixture needs Claude Code's trust (from a plain terminal: cd $(printf %q "$repo") && claude, accept the dialog, /exit); then run the case again"
     exit 0 ;;
  *) all INCONCLUSIVE "the trust state cannot be read: $tout"; exit 0 ;;
esac

prompt="Reply with the single word DONE and nothing else. Do not use any tool."
for a in $arms; do
  out=$("$sp" session launch "$a" --regime "$SEAM_PROBE_REGIME" --cwd "$repo" -- "$prompt") \
    || { all INCONCLUSIVE "a launch did not start a session ($a: $(oneline "$out"))"; exit 0; }
  setv id_$a "$(printf '%s' "$out" | sed -n 's/^id \([^ ]*\) uuid.*/\1/p')"
  setv uuid_$a "$(printf '%s' "$out" | sed -n 's/^id [^ ]* uuid \([^ ]*\).*/\1/p')"
done

# Each first turn ends when it replies DONE; the wait is bounded by session_wait.
pending=$arms
t_wait=$(now)
while [ -n "$pending" ]; do
  still=""
  for a in $pending; do
    rc=0; "$sp" evidence codeword "$a" DONE >/dev/null || rc=$?
    [ "$rc" -eq 0 ] || still="$still $a"
  done
  pending=${still# }
  [ -z "$pending" ] && break
  if atleast "$(since "$(now)" "$t_wait")" "$session_wait"; then break; fi
  sleep "$poll"
done
for a in $pending; do setv res_$a "INCONCLUSIVE|the first turn did not finish within ${session_wait}s (no DONE in its transcript)"; done
for a in $arms; do
  if [ -z "$(getv res_$a)" ] && { [ -z "$(getv id_$a)" ] || [ -z "$(getv uuid_$a)" ]; }; then
    setv res_$a "INCONCLUSIVE|the launch gave no session id and uuid to attach to and look for"
  fi
done

# The attachments, made and confirmed by the person; the instrument cannot see them.
if [ -z "$(getv res_terminal)" ]; then
  "$sp" manual "terminal arm: in another terminal run: claude attach $(getv id_terminal)   Leave it open and in view, and press Enter here once it shows the session." \
    || setv res_terminal "INCONCLUSIVE|the person could not be asked to attach (a manual step needs a terminal)"
fi
if [ -z "$(getv res_agentview)" ]; then
  "$sp" manual "agentview arm: in another terminal run: claude agents   Select the session named $(display_of agentview) and open its peek panel. Leave it open, and press Enter here once it is showing." \
    || setv res_agentview "INCONCLUSIVE|the person could not be asked to open the agent view (a manual step needs a terminal)"
fi

series=$(dirname "$SEAM_PROBE_RUN")/session-attached-stop${plant:+-$plant}-watch.txt
: > "$series"

# Stop an arm as the fleet does, then watch it for signs that it came back. The first time each sign
# was seen, in seconds after the stop, goes in proc_/tr_/row_ARM; a sign never read at any poll in
# noread_ARM.
stop_and_watch() { # ARM
  local a=$1 rc=0 out base t_stop el n lr line pr_rc
  [ -z "$(getv res_$a)" ] || return 0   # already unmeasured: nothing to stop
  out=$("$sp" session term "$a") || rc=$?
  printf '# %s: session term exit %s: %s\n' "$a" "$rc" "$(oneline "$out")" >> "$series"
  case $rc in
    0) ;;
    1) setv res_$a "INCONCLUSIVE|the process ended but \`claude rm\` failed, so a listed row would say nothing: $(oneline "$out")"; return ;;
    *) setv res_$a "INCONCLUSIVE|the session could not be stopped as the fleet stops one: $(oneline "$out")"; return ;;
  esac
  if { [ "$plant" = respawn ] && [ "$a" = terminal ]; } || { [ "$plant" = control-respawn ] && [ "$a" = control ]; }; then
    rrc=0; rout=$("$sp" session resume "$a") || rrc=$?
    printf '# %s: plant %s: session resume exit %s: %s\n' "$a" "$plant" "$rrc" "$(oneline "$rout")" >> "$series"
  fi
  base=$(tlines "$(getv uuid_$a)")
  t_stop=$(now)
  [ -n "$base" ] || setv res_$a "INCONCLUSIVE|the transcript could not be found to count its lines at the stop"
  local seen_p="" seen_t="" seen_r="" ok_p="" ok_t="" ok_r=""
  while :; do
    el=$(since "$(now)" "$t_stop")
    line="+${el}s"
    pr_rc=0; "$sp" session process "$a" >/dev/null || pr_rc=$?
    case $pr_rc in
      0) [ -n "$seen_p" ] || seen_p=$el; ok_p=1; line="$line process=present" ;;
      1) ok_p=1; line="$line process=absent" ;;
      *) line="$line process=unreadable" ;;
    esac
    n=$(tlines "$(getv uuid_$a)")
    if [ -z "$n" ] || [ -z "$base" ]; then line="$line transcript=unreadable"
    else
      ok_t=1; line="$line transcript=$n/$base"
      if [ "$n" -gt "$base" ]; then [ -n "$seen_t" ] || seen_t=$el; fi
    fi
    lr=0; listed "$(getv id_$a)" "$(getv uuid_$a)" || lr=$?
    case $lr in
      0) [ -n "$seen_r" ] || seen_r=$el; ok_r=1; line="$line listed=yes" ;;
      1) ok_r=1; line="$line listed=no" ;;
      *) line="$line listed=unreadable" ;;
    esac
    printf '%s %s\n' "$a" "$line" >> "$series"
    if atleast "$(since "$(now)" "$t_stop")" "$watch"; then break; fi
    sleep "$poll"
  done
  setv proc_$a "$seen_p"; setv tr_$a "$seen_t"; setv row_$a "$seen_r"
  local nr=""
  [ -n "$ok_p" ] || nr="$nr process"
  [ -n "$ok_t" ] || nr="$nr transcript"
  [ -n "$ok_r" ] || nr="$nr listing"
  setv noread_$a "${nr# }"
}
look() { # ARM: the person looks at the attached client
  "$sp" manual "$1: look at the attached $2 now: has it ended, or shown the session running again? Then press Enter. (Nothing reads the client's own display; this is for the person.)" || true
}

stop_and_watch control
stop_and_watch terminal
[ -n "$(getv res_terminal)" ] || look "terminal arm" "terminal (claude attach)"
stop_and_watch agentview
[ -n "$(getv res_agentview)" ] || look "agentview arm" "agent view and its peek panel"

# What came back, in words: the signs seen and when.
came() { # ARM
  local a=$1 t=""
  [ -z "$(getv proc_$a)" ] || t="$t a process for its session uuid ($(getv proc_$a) s after the stop);"
  [ -z "$(getv tr_$a)" ] || t="$t new lines in its transcript ($(getv tr_$a) s after the stop);"
  [ -z "$(getv row_$a)" ] || t="$t a listed row for its id or uuid ($(getv row_$a) s after the stop);"
  printf '%s' "${t# }"
}
has_sign() { [ -n "$(getv proc_$1)" ] || [ -n "$(getv tr_$1)" ] || [ -n "$(getv row_$1)" ]; }
# A sign set that would show a respawn could not be fully read: not a PASS.
unread() { getv noread_$1; }

control_state=ok
if [ -n "$(getv res_control)" ]; then control_state=unmeasured
elif has_sign control; then control_state=came-back
fi
if [ "$control_state" = came-back ]; then
  all VOID "an unattached session came back after the stop too ($(came control)), so a respawn cannot be laid to attachment"
  exit 0
fi

if [ "$control_state" = unmeasured ]; then
  v=$(getv res_control); "$sp" verdict --arm control "${v%%|*}" "control: ${v#*|}"
elif [ -n "$(unread control)" ]; then
  "$sp" verdict --arm control INCONCLUSIVE "the control's $(unread control) could not be read at any poll during its ${watch}s watch, so a return could not be ruled out ($(basename "$series"))"
  control_state=unmeasured
else
  "$sp" verdict --arm control PASS "nothing came back within ${watch}s of the stop (process, transcript and listing each read): an unattached session stays stopped, as the fleet relies on"
fi

confirmed="the attachment was made and confirmed by the person at the terminal, not observed by the instrument, and the client's own display was not read"
for a in terminal agentview; do
  v=$(getv res_$a)
  if [ -n "$v" ]; then "$sp" verdict --arm "$a" "${v%%|*}" "${v#*|}"; continue; fi
  if [ "$control_state" != ok ]; then
    "$sp" verdict --arm "$a" INCONCLUSIVE "the control could not be measured, so a result here cannot be laid to attachment ($confirmed)"; continue
  fi
  if has_sign "$a"; then
    "$sp" verdict --arm "$a" FAIL "the session came back after the stop: $(came "$a") while the control stayed stopped; $confirmed"
  elif [ -n "$(unread "$a")" ]; then
    "$sp" verdict --arm "$a" INCONCLUSIVE "its $(unread "$a") could not be read at any poll during the ${watch}s watch, so a return could not be ruled out ($(basename "$series"))"
  else
    "$sp" verdict --arm "$a" PASS "nothing came back within ${watch}s of the stop (process, transcript and listing each read), as with the unattached control; $confirmed"
  fi
done
