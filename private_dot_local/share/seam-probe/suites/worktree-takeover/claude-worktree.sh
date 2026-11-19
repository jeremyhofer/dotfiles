# Case claude-worktree, run by `seam-probe run|red worktree-takeover claude-worktree`.
#
# One background session, launched under the real settings from a fixture repository with
# `claude --bg --worktree sp-own`, and with worktrunk's worktree-path set to the location under test,
# <repo>/.claude/worktrees/<branch>. worktrunk maps each config key to a WORKTRUNK_ variable, which
# wins over a per-project entry in its config (`wt config --help`), so the case sets
# WORKTRUNK_WORKTREE_PATH both in the environment it launches from and in the session's own
# --settings `env`: a background session may be started by a process that never saw the launching
# shell's environment. Whether the value reaches worktrunk's plugin hook is part of what the
# placement arm reads: a value that does not reach it shows as a FAIL on placement, never as a pass.
#
# The session runs four commands, each its own Bash call (the case's `commands`): an empty commit in
# its own worktree, one in a worktree given by --add-dir (the grant control), one in a worktree made
# outside the session and never granted (the refusal control, which must fail with git's
# "Read-only file system"), and a last mark. The commits use `git -c commit.gpgsign=false commit`,
# the spelling a seat's shell wrapper still recognizes, and are read from git, never from the reply.
#
# Three arms, each with its own verdict:
#   placement  the session's worktree is at <repo>/.claude/worktrees/sp-own
#   setup      the fixture's worktrunk post-start hook, which only worktrunk runs, wrote its marker
#              there (Claude Code's own worktree creation also uses .claude/worktrees/, so placement
#              alone cannot tell the plugin from the default)
#   commit     the session's commit in its own worktree is in git
# Plants ($SEAM_PROBE_PLANT): plugin-off disables worktrunk's plugin for the session through its
# --settings `enabledPlugins` (setup must FAIL); grant-withheld drops the --add-dir (the grant
# control fails, so every arm must be VOID).
#
# Preconditions, each SKIPPED with the step that fixes it, the fixture left in place for it: Claude
# Code's trust for the fixture repository (a background session refuses an untrusted workspace), and
# worktrunk's approval of the fixture's project hook (a project hook needs one before it runs).
set -u
sp=$SEAM_PROBE
plant=${SEAM_PROBE_PLANT:-}
name=sp-own
d1_template='{{ repo_path }}/.claude/worktrees/{{ branch | sanitize }}'
session_wait=${SEAM_PROBE_SESSION_WAIT:-300}
setup_wait=${SEAM_PROBE_SETUP_WAIT:-60}

all() { for arm in placement setup commit; do "$sp" verdict --arm "$arm" "$1" "$2"; done; }
oneline() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-300; }

git=$(command -v git) || { all SKIPPED "git is not installed"; exit 0; }
command -v wt >/dev/null 2>&1 || { all SKIPPED "worktrunk (wt) is not installed"; exit 0; }

repo=$("$sp" fixture repo wtc) || { all INCONCLUSIVE "the fixture could not be built"; exit 0; }
mkdir -p "$repo/.config"
printf '# The seam-probe fixture'"'"'s setup marker: only worktrunk runs this.\npost-start = "touch seam-probe-setup-ran"\n' \
  > "$repo/.config/wt.toml"
if ! { "$git" -C "$repo" add .config/wt.toml && "$git" -C "$repo" commit -q -m "worktrunk project hook" \
       && "$git" -C "$repo" push -q origin main; } >/dev/null 2>&1; then
  all INCONCLUSIVE "the fixture's worktrunk project config could not be committed"; exit 0
fi

# Preconditions.
missing=""
trc=0; tout=$("$sp" evidence trusted "$repo") || trc=$?
case $trc in
  0) ;;
  1) missing="Claude Code's trust (from a plain terminal: cd $(printf %q "$repo") && claude, accept the dialog, /exit)" ;;
  *) all INCONCLUSIVE "the trust state cannot be read: $tout"; exit 0 ;;
esac
if ! appr=$(wt -C "$repo" config approvals list 2>&1); then
  all INCONCLUSIVE "wt config approvals list failed: $(oneline "$appr")"; exit 0
fi
case $(printf '%s\n' "$appr" | sed -n '/UNAPPROVED/,$p') in
  *seam-probe-setup-ran*)
    missing="${missing:+$missing; and }worktrunk's approval of the fixture's post-start hook (wt -C $(printf %q "$repo") config approvals add)" ;;
esac
if [ -n "$missing" ]; then
  "$sp" fixture keep "$repo" >/dev/null
  all SKIPPED "the fixture needs $missing; then run the case again"; exit 0
fi

# The controls' worktrees, made with git directly, and the commit every branch starts from.
grant=$("$sp" fixture worktree "$repo" grant) || { all INCONCLUSIVE "the grant worktree could not be made"; exit 0; }
refuse=$("$sp" fixture worktree "$repo" refuse) || { all INCONCLUSIVE "the refusal worktree could not be made"; exit 0; }
base=$("$git" -C "$repo" rev-parse HEAD)

plugins=""
[ "$plant" = plugin-off ] && plugins=',"enabledPlugins":{"worktrunk@worktrunk":false}'
settings=$("$sp" fixture settings "$SEAM_PROBE_FIXTURES/wtc-session-settings.json" \
  "{\"env\":{\"WORKTRUNK_WORKTREE_PATH\":\"$d1_template\"}$plugins}") \
  || { all INCONCLUSIVE "the session's settings file could not be written"; exit 0; }
prompt=$("$sp" prompt own grant refuse done "grant=$grant" "refuse=$refuse") \
  || { all INCONCLUSIVE "the prompt could not be built"; exit 0; }

rc=0
if [ "$plant" = grant-withheld ]; then
  out=$(WORKTRUNK_WORKTREE_PATH=$d1_template "$sp" session launch own --regime "$SEAM_PROBE_REGIME" --cwd "$repo" \
    --worktree "$name" --settings "$settings" --allow Bash -- "$prompt") || rc=$?
else
  out=$(WORKTRUNK_WORKTREE_PATH=$d1_template "$sp" session launch own --regime "$SEAM_PROBE_REGIME" --cwd "$repo" \
    --worktree "$name" --add-dir "$grant" --settings "$settings" --allow Bash -- "$prompt") || rc=$?
fi
[ "$rc" -eq 0 ] || { all INCONCLUSIVE "the launch did not start a session: $(oneline "$out")"; exit 0; }

if ! done_mark=$("$sp" wait mark --under "$repo" seam-probe-mark-done --seconds "$session_wait" --line done); then
  all INCONCLUSIVE "the session's commands never finished: $done_mark"; exit 0
fi
here=$(dirname "$done_mark")

# Each command's mark first: a mark that is missing means the command never ran, so a control read
# from it would only be misfiled as unreadable. The run keeps the session's transcript in its
# results directory, under a name this case can state.
for m in own grant refuse; do
  [ -f "$here/seam-probe-mark-$m" ] && continue
  all INCONCLUSIVE "the $m command never ran (skipped by the model, or stopped by a permission rule or the classifier; the session's transcript, kept at <results>/transcript-claude-worktree${plant:+-$plant}-own.jsonl, says which)"
  exit 0
done

# The controls: if either misbehaved, the arms say nothing.
grc=0; g=$("$sp" evidence committed "$grant" "$base" --message seam-probe-grant) || grc=$?
rrc=0; r=$("$sp" evidence committed "$refuse" "$base" --message seam-probe-refuse) || rrc=$?
trc=0; t=$("$sp" evidence refused "$here/seam-probe-mark-refuse") || trc=$?
if [ "$grc" -eq 3 ] || [ "$rrc" -eq 3 ] || [ "$trc" -eq 3 ]; then
  all INCONCLUSIVE "a control could not be read: grant: $g; refusal: $r; $t"; exit 0
fi
if [ "$grc" -ne 0 ]; then
  gm=$(cat "$here/seam-probe-mark-grant")
  all VOID "grant control: the --add-dir worktree's commit did not land ($g; git said: $(oneline "$gm"))"; exit 0
fi
if [ "$rrc" -eq 0 ] || [ "$trc" -ne 0 ]; then
  all VOID "refusal control: the ungranted worktree was not refused with Read-only file system ($r; $t)"; exit 0
fi

# placement
want=$repo/.claude/worktrees/$name
got=$(cd "$here" && pwd -P)
if [ -d "$want" ] && [ "$(cd "$want" && pwd -P)" = "$got" ]; then
  "$sp" verdict --arm placement PASS "the session's worktree is at <repo>/.claude/worktrees/$name"
else
  "$sp" verdict --arm placement FAIL "the session's worktree is at ${got#"$(cd "$repo" && pwd -P)"/}, not .claude/worktrees/$name"
fi

# setup: worktrunk's post-start runs in the background, so its marker may follow the session's work.
if s=$("$sp" wait mark "$here/seam-probe-setup-ran" --seconds "$setup_wait"); then
  "$sp" verdict --arm setup PASS "worktrunk's post-start hook ran in the session's worktree"
else
  "$sp" verdict --arm setup FAIL "no setup marker after ${setup_wait}s: worktrunk's post-start did not run in the session's worktree"
fi

# commit
crc=0; c=$("$sp" evidence committed "$here" "$base" --message seam-probe-own) || crc=$?
case $crc in
  0) "$sp" verdict --arm commit PASS "the session committed in its worktree with git -c commit.gpgsign=false commit ($c)" ;;
  1) cm=$(cat "$here/seam-probe-mark-own")
     "$sp" verdict --arm commit FAIL "no commit in the session's worktree ($c; git said: $(oneline "$cm"))" ;;
  *) "$sp" verdict --arm commit INCONCLUSIVE "the session's worktree could not be read: $c" ;;
esac
