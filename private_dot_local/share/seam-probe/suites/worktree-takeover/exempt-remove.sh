# Case exempt-remove, run by `seam-probe run|red worktree-takeover exempt-remove`.
#
# Whether a session's `wt remove --no-hooks --foreground <name>`, issued as its own Bash call,
# removes a worktree, as the sandbox exemption for exactly that form expects. The exemption and its
# deny rules live in the private layer's declared user settings (the overlay's
# dot_dotlocal/claude/executable_settings-declared: `sandbox.excludedCommands` holds
# "wt remove --no-hooks --foreground *", and `permissions.deny` holds each refused flag both leading
# and trailing, among them "Bash(wt remove * -y*)"), so the case runs under the real settings.
#
# One background session in a fixture repository holding two worktrees made with git, at
# <repo>/.claude/worktrees/<name>. It runs three commands, each its own Bash call (the case's
# `commands`):
#   refuse   the refusal control: `wt remove --foreground` WITH hooks, which the exemption does not
#            match, so it runs sandboxed; the sandbox's placeholder files read to git as untracked,
#            so worktrunk must refuse with "contains modified or untracked files" and leave the
#            worktree. Its output is redirected into a mark: a redirect makes a command run
#            sandboxed, which this command is anyway. (--foreground because the deployed
#            claude-worktree-hook refuses a `wt remove` without it, before the sandbox is reached.)
#   remove   the subject, issued BARE: a redirect, pipe, `;`, `&&` or `$(` would make the exempt
#            command run sandboxed, so nothing is captured from it. Its result is read from git
#            (`git worktree list`) and the disk, and the call itself from the transcript.
#   done     a last mark, written by its own plain command after the other two.
# Plant ($SEAM_PROBE_PLANT): deny-flag issues the exempt form plus -y, which the deny rules refuse,
# so the worktree must stay and the case must FAIL. The plant can show only that the worktree was
# not removed; the reason names whether the transcript shows the call denied. A plant run that
# removes the worktree comes out PASS, read as BLIND: the -y form went through, so the deny rule did
# not stop it. A permission denial of the UNPLANTED command reads DENIED, as the verdict table says.
#
# Telling "never ran" from "ran and was refused", with no mark from the subject itself:
#   no done mark                          INCONCLUSIVE: the session never reached its last command
#   done mark, worktree gone              the remove ran (nothing else in the run removes it): PASS
#   done mark, worktree still listed      the transcript says which: the call never made, or made
#                                         differently from the prompt's text (INCONCLUSIVE); denied
#                                         (DENIED, or FAIL under the plant); made and run (FAIL,
#                                         with its output)
#   git no longer lists it, but the directory is left: a removal that ran sandboxed and stopped half
#   way on the placeholders (FAIL).
# Residual: with no readable transcript, a skipped call and a refused one look the same, so that is
# INCONCLUSIVE rather than FAIL.
set -u
sp=$SEAM_PROBE
plant=${SEAM_PROBE_PLANT:-}
session_wait=${SEAM_PROBE_SESSION_WAIT:-300}
refusal='contains modified or untracked files'
oneline() { printf '%s' "$1" | tr '\n\t' '  ' | cut -c1-300; }

command -v git >/dev/null 2>&1 || { "$sp" verdict SKIPPED "git is not installed"; exit 0; }
command -v wt >/dev/null 2>&1 || { "$sp" verdict SKIPPED "worktrunk (wt) is not installed"; exit 0; }

repo=$("$sp" fixture repo exr) || { "$sp" verdict INCONCLUSIVE "the fixture could not be built"; exit 0; }
trc=0; tout=$("$sp" evidence trusted "$repo") || trc=$?
case $trc in
  0) ;;
  1) "$sp" fixture keep "$repo" >/dev/null
     "$sp" verdict SKIPPED "the fixture needs Claude Code's trust (from a plain terminal: cd $repo && claude, accept the dialog, /exit); then run the case again"
     exit 0 ;;
  *) "$sp" verdict INCONCLUSIVE "the trust state cannot be read: $tout"; exit 0 ;;
esac

target=$("$sp" fixture worktree "$repo" sp-remove) || { "$sp" verdict INCONCLUSIVE "the subject's worktree could not be made"; exit 0; }
refuse=$("$sp" fixture worktree "$repo" sp-refuse) || { "$sp" verdict INCONCLUSIVE "the refusal control's worktree could not be made"; exit 0; }

subject=remove
[ "$plant" = deny-flag ] && subject=remove-denied
prompt=$("$sp" prompt refuse "$subject" done) || { "$sp" verdict INCONCLUSIVE "the prompt could not be built"; exit 0; }
# The command exactly as the prompt gives it, to find the call in the transcript.
subject_cmd=$(printf '%s\n' "$prompt" | sed -n 's/^2\. //p')

rc=0
out=$("$sp" session launch own --regime "$SEAM_PROBE_REGIME" --cwd "$repo" --allow Bash -- "$prompt") || rc=$?
[ "$rc" -eq 0 ] || { "$sp" verdict INCONCLUSIVE "the launch did not start a session: $(oneline "$out")"; exit 0; }

if ! d=$("$sp" wait mark "$repo/seam-probe-mark-done" --seconds "$session_wait" --line done); then
  "$sp" verdict INCONCLUSIVE "the session's commands never finished: $d"; exit 0
fi

# The refusal control, read first: if it misbehaved, the subject says nothing.
fc=0; f=$("$sp" evidence refused "$repo/seam-probe-mark-refuse" --text "$refusal") || fc=$?
lc=0; l=$("$sp" evidence worktree "$repo" "$refuse") || lc=$?
if [ "$fc" -eq 3 ] || [ "$lc" -eq 3 ]; then
  "$sp" verdict INCONCLUSIVE "the refusal control could not be read: $f; $l"; exit 0
fi
if [ "$fc" -ne 0 ] || [ "$lc" -ne 0 ]; then
  "$sp" verdict VOID "refusal control: wt remove with hooks was not refused with \"$refusal\" and left in place ($f; $l)"; exit 0
fi

# The subject.
wc=0; w=$("$sp" evidence worktree "$repo" "$target") || wc=$?
[ "$wc" -ne 3 ] || { "$sp" verdict INCONCLUSIVE "the subject's worktree could not be read: $w"; exit 0; }
on_disk=yes; [ -e "$target" ] || on_disk=no
if [ "$wc" -eq 1 ] && [ "$on_disk" = no ]; then
  if [ "$plant" = deny-flag ]; then
    "$sp" verdict PASS "the exempt form with -y removed the worktree: the deny rule did not stop it ($subject_cmd)"
  else
    "$sp" verdict PASS "the bare exempt removal took the worktree off git's list and the disk; the refusal control was refused"
  fi
  exit 0
fi
if [ "$wc" -eq 1 ]; then
  "$sp" verdict FAIL "git no longer lists the worktree but its directory is left: the removal ran sandboxed and stopped half way"
  exit 0
fi

# Still listed: the transcript tells a call never made from one denied or refused.
cc=0; c=$("$sp" evidence calls own --command "$subject_cmd") || cc=$?
case $cc in
  3) "$sp" verdict INCONCLUSIVE "the worktree is still listed and the transcript cannot be read, so a skipped call cannot be told from a refused one: $c"; exit 0 ;;
  1) "$sp" verdict INCONCLUSIVE "the worktree is still listed: the session never issued \"$subject_cmd\" as written"; exit 0 ;;
esac
status=$(printf '%s\n' "$c" | tail -1 | cut -f1)
result=$(printf '%s\n' "$c" | tail -1 | cut -f4)
case $status in
  denied)
    if [ "$plant" = deny-flag ]; then
      "$sp" verdict FAIL "not removed: the call was denied, as the deny rule for -y intends ($(oneline "$result"))"
    else
      "$sp" verdict DENIED "a permission rule stopped the exempt removal itself: $(oneline "$result")"
    fi ;;
  *) "$sp" verdict FAIL "the call was made ($status) and the worktree is still listed: $(oneline "$result")" ;;
esac
