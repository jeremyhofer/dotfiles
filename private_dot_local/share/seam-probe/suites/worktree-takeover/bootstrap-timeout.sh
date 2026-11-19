# Case bootstrap-timeout, run by `seam-probe run|red worktree-takeover bootstrap-timeout`.
#
# Whether worktrunk's WorktreeCreate hook, fired by a subagent launched with `isolation: worktree`,
# finishes within its timeout while the repository's dependency install (wt-bootstrap) runs inside
# it, with a cold package cache and with a warm one, and what the session sees when it does not.
#
# The timeout is read at run time from the installed worktrunk plugin's own hook declaration
# (`seam-probe evidence hook worktrunk@worktrunk WorktreeCreate`: installed_plugins.json names the
# install path, whose hooks/hooks.json declares the hook), and recorded in every reason, so a plugin
# update that changes it shows. The plugin as installed when this case was written declares no
# `timeout`, so the tool's default for a command hook applies, which the plant below tests.
#
# The install runs as a worktrunk `pre-start`, which blocks the creation and so runs inside the
# hook, as the fleet's per-project `pre-start.bootstrap = "wt-bootstrap"` entries do (wt-config-gen
# writes them into worktrunk's user config; wt-bootstrap's help: "worktrunk runs this script as a
# blocking pre-start hook"). A `post-start` runs in the background, after the creation returns, so
# no timeout of the hook's could reach it.
#
# The fixture: a repository whose worktrunk project config runs probe-bootstrap.sh as its pre-start.
# That script logs each creation's start and end, with the worktree's path and how many entries the
# package cache held, into <repo>/seam-probe-boot.log, and runs wt-bootstrap. Its lockfile is the
# smallest real one that installs: one npm package with no dependencies, in app/, so the install is
# `wt-bootstrap -C app` (npm ci). npm rather than uv because the real settings set UV_OFFLINE for
# every session, which a cold uv install would fail on before any timeout mattered. The package
# cache is <repo>/seam-probe-npm-cache, new with each fixture, so the first install is cold and the
# next is warm.
#
# One background session (Sonnet: the prompt asks for three Agent calls in order, each with a tool
# parameter set, where Haiku's slips would read INCONCLUSIVE) launches three subagents one at a time,
# each with isolation "worktree", each touching a mark of its own in its worktree:
#   1 the control: wt-bootstrap at the worktree's root, where there is no lockfile, so it installs
#     nothing; the creation must pass, or the case is VOID
#   2 arm cold:  wt-bootstrap -C app with the empty cache
#   3 arm warm:  wt-bootstrap -C app with the cache the cold install filled
# Cold and warm are two arms of one case, not two cases: the warm cache is what the cold install
# leaves, so a separate warm case would run a cold install first anyway, and per-arm verdicts keep
# one arm's fault from being averaged into the other.
#
# Each arm reads: PASS when the creation finished and the subagent ran (its mark is in the worktree
# the log names, or its Agent call returned without error); FAIL when the Agent call returned an
# error, or the install never ended and the subagent never ran, with what the session saw (the
# call's result, read from the transcript); INCONCLUSIVE when the install itself failed, the cache
# was not cold or warm as the arm needs, or nothing can be read. A PASS whose install ran past the
# timeout read says so: the effective limit is then longer than the declaration gives.
# Plants ($SEAM_PROBE_PLANT): install-past-timeout makes the cold creation sleep past the timeout
# instead of installing (arm cold must FAIL); control-fails makes the control's pre-start exit 1
# (the case must be VOID). `minutes` assumes a timeout of at most ten minutes.
set -u
sp=$SEAM_PROBE
plant=${SEAM_PROBE_PLANT:-}
oneline() { printf '%s' "$1" | tr '\n\t' '  ' | cut -c1-300; }
all() { for arm in cold warm; do "$sp" verdict --arm "$arm" "$1" "$2"; done; }
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

git=$(command -v git) || { all SKIPPED "git is not installed"; exit 0; }
command -v wt >/dev/null 2>&1 || { all SKIPPED "worktrunk (wt) is not installed"; exit 0; }

# The hook's timeout, from the plugin's declaration on disk.
hrc=0; hk=$("$sp" evidence hook worktrunk@worktrunk WorktreeCreate) || hrc=$?
case $hrc in
  0) ;;
  1) all SKIPPED "worktrunk's plugin declares no WorktreeCreate command hook"; exit 0 ;;
  *) all SKIPPED "worktrunk's Claude Code plugin is not installed: $(oneline "$hk")"; exit 0 ;;
esac
tmo=$(printf '%s\n' "$hk" | sed -n 's/^timeout: \([0-9][0-9]*\).*/\1/p' | head -1)
tsrc=$(printf '%s\n' "$hk" | sed -n 's/^timeout: [0-9.]* (\(.*\))$/\1/p' | head -1)
hfile=$(printf '%s\n' "$hk" | sed -n 's/^file: //p')
hfile=${hfile##*/plugins/}  # from Claude Code's plugins directory down, so the summary names no home
hver=$(printf '%s\n' "$hk" | sed -n 's/^version: //p')
[ -n "$tmo" ] || { all INCONCLUSIVE "the hook's timeout could not be read: $(oneline "$hk")"; exit 0; }
timeout_is="the ${tmo}s timeout ($tsrc, plugin $hver, $hfile)"
session_wait=${SEAM_PROBE_SESSION_WAIT:-$((tmo + 900))}

repo=$("$sp" fixture repo btm) || { all INCONCLUSIVE "the fixture could not be built"; exit 0; }
log=$repo/seam-probe-boot.log
mkdir -p "$repo/.config" "$repo/app"
printf '# The seam-probe fixture'"'"'s install, blocking the creation: only worktrunk runs this.\npre-start = "sh {{ worktree_path }}/probe-bootstrap.sh"\n' \
  > "$repo/.config/wt.toml"
cat > "$repo/app/package.json" <<'JSON'
{
  "name": "seam-probe-fixture",
  "version": "0.0.0",
  "private": true,
  "dependencies": {
    "is-number": "7.0.0"
  }
}
JSON
cat > "$repo/app/package-lock.json" <<'JSON'
{
  "name": "seam-probe-fixture",
  "version": "0.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "seam-probe-fixture",
      "version": "0.0.0",
      "dependencies": {
        "is-number": "7.0.0"
      }
    },
    "node_modules/is-number": {
      "version": "7.0.0",
      "resolved": "https://registry.npmjs.org/is-number/-/is-number-7.0.0.tgz",
      "integrity": "sha512-41Cifkg6e8TylSpdtTpeLVMqvSBEVzTttHvERD741+pnZ8ANv0004MRL43QKPDlK9cGvNp6NZWZUBlbGXYxxng==",
      "license": "MIT",
      "engines": {
        "node": ">=0.12.0"
      }
    }
  }
}
JSON
{
  printf '#!/bin/sh\n'
  printf 'log=%s\ncache=%s\nplant=%s\nsleep_s=%s\n' "$(sq "$log")" "$(sq "$repo/seam-probe-npm-cache")" \
    "$(sq "$plant")" "$((tmo + 30))"
  cat <<'WRAP'
# The seam-probe fixture's pre-start, which worktrunk runs in each new worktree. Nothing goes to
# stdout: the plugin's WorktreeCreate hook reads worktrunk's JSON from there.
exec 1>&2
cd "$(dirname "$0")" || exit 1
here=$(pwd -P)
n=$(grep -c '^start ' "$log" 2>/dev/null) || n=0
n=$((n + 1))
mkdir -p "$cache"
c=$(ls -A "$cache" | wc -l | tr -d ' ')
echo "start $(date +%s) $n $c $here" >> "$log"
rc=0
case $n in
  1) if [ "$plant" = control-fails ]; then rc=1; else wt-bootstrap || rc=$?; fi ;;
  2) if [ "$plant" = install-past-timeout ]; then sleep "$sleep_s"; else npm_config_cache=$cache wt-bootstrap -C app || rc=$?; fi ;;
  *) npm_config_cache=$cache wt-bootstrap -C app || rc=$? ;;
esac
echo "end $(date +%s) $n $rc $here" >> "$log"
exit "$rc"
WRAP
} > "$repo/probe-bootstrap.sh"
if ! { "$git" -C "$repo" add .config/wt.toml app/package.json app/package-lock.json probe-bootstrap.sh \
       && "$git" -C "$repo" commit -q -m "worktrunk pre-start and a lockfile" \
       && "$git" -C "$repo" push -q origin main; } >/dev/null 2>&1; then
  all INCONCLUSIVE "the fixture's worktrunk project config could not be committed"; exit 0
fi

# Preconditions, each SKIPPED with the step that fixes it, the fixture left in place for it.
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
  *probe-bootstrap.sh*)
    missing="${missing:+$missing; and }worktrunk's approval of the fixture's pre-start hook (wt -C $(printf %q "$repo") config approvals add)" ;;
esac
if [ -n "$missing" ]; then
  "$sp" fixture keep "$repo" >/dev/null
  all SKIPPED "the fixture needs $missing; then run the case again"; exit 0
fi

pc=$("$sp" prompt sub-control) && pd=$("$sp" prompt sub-cold) && pw=$("$sp" prompt sub-warm) \
  && pz=$("$sp" prompt done) || { all INCONCLUSIVE "the prompt could not be built"; exit 0; }
prompt="Use the Agent tool to launch three subagents, ONE AT A TIME, in the order below: launch one, wait for its result, then launch the next. Launch each with the Agent tool's isolation parameter set to \"worktree\", so that each works in a new worktree of its own. If an Agent call fails, do not retry it: go on to the next one. Give each subagent the task under its heading, exactly as written.

=== the first subagent's task ===
$pc
=== the second subagent's task ===
$pd
=== the third subagent's task ===
$pw
=== after all three subagents have returned ===
$pz"

rc=0
out=$("$sp" session launch own --regime "$SEAM_PROBE_REGIME" --cwd "$repo" --model sonnet --allow Bash -- "$prompt") || rc=$?
[ "$rc" -eq 0 ] || { all INCONCLUSIVE "the launch did not start a session: $(oneline "$out")"; exit 0; }
if ! d=$("$sp" wait mark "$repo/seam-probe-mark-done" --seconds "$session_wait" --line done); then
  all INCONCLUSIVE "the session's commands never finished: $d"; exit 0
fi

# What the session saw: its Agent calls, in order, from the transcript.
ac=0; calls=$("$sp" evidence calls own --tool Agent --tool Task) || ac=$?
[ "$ac" -ne 1 ] || calls=""

line_of() { [ -f "$log" ] && awk -v k="$1" -v n="$2" '$1 == k && $3 == n { print; exit }' "$log"; }
starts=0; [ -f "$log" ] && starts=$(awk '$1 == "start"' "$log" | wc -l | tr -d ' ')
if [ "$starts" -ne 3 ]; then
  marks=$(find "$repo" -name 'sub-ran-*' -type f | wc -l | tr -d ' ')
  if [ "$starts" -eq 0 ] && [ "$marks" -gt 0 ]; then
    all INCONCLUSIVE "a subagent ran in a worktree the fixture's pre-start never touched: worktrunk's WorktreeCreate hook did not make it"
  else
    all INCONCLUSIVE "$starts creations reached the fixture's pre-start, not 3 (a launch missed, retried or made without isolation); Agent calls: $(oneline "$calls")"
  fi
  exit 0
fi
# Each subagent's mark must be in the worktree its creation's log line names, or they ran out of order.
while IFS= read -r m; do
  case ${m##*sub-ran-} in control) k=1 ;; cold) k=2 ;; warm) k=3 ;; *) continue ;; esac
  want=$(line_of start "$k" | cut -d' ' -f5-)
  if [ "$(cd "$(dirname "$m")" && pwd -P)" != "$want" ]; then
    all INCONCLUSIVE "the subagents ran out of order: ${m##*/} is not in creation $k's worktree"; exit 0
  fi
done <<MARKS
$(find "$repo" -name 'sub-ran-*' -type f)
MARKS

judge() { # <arm> <k>: sets V and R for creation k
  s=$(line_of start "$2"); e=$(line_of end "$2")
  if [ -z "$s" ]; then V=INCONCLUSIVE; R="no log line for creation $2"; return; fi
  t0=$(printf '%s\n' "$s" | cut -d' ' -f2); cn=$(printf '%s\n' "$s" | cut -d' ' -f4)
  p=$(printf '%s\n' "$s" | cut -d' ' -f5-)
  if [ -n "$e" ]; then
    erc=$(printf '%s\n' "$e" | cut -d' ' -f4); dur=$(( $(printf '%s\n' "$e" | cut -d' ' -f2) - t0 ))
    ended="ended after ${dur}s"
  else
    erc=0; dur=$(( $(date +%s) - t0 )); ended="had not ended after ${dur}s"
  fi
  call=$(printf '%s\n' "$calls" | sed -n "${2}p")
  cstat=$(printf '%s\n' "$call" | cut -f1); cstat=${cstat:-none}
  [ "$ac" -ne 3 ] || cstat=unread
  saw="the session saw: $cstat $(oneline "$(printf '%s\n' "$call" | cut -f4)")"
  cache="cache entries at the start: $cn"
  if [ "$1" = cold ] && [ "$cn" != 0 ]; then
    V=INCONCLUSIVE; R="the cache was not cold ($cache)"; return
  fi
  if [ "$1" = warm ]; then
    e2=$(line_of end 2)
    if [ "$cn" = 0 ] || { [ -n "$e2" ] && [ "$t0" -lt "$(printf '%s\n' "$e2" | cut -d' ' -f2)" ]; }; then
      V=INCONCLUSIVE; R="the cache was not warm: the cold install had not filled it first ($cache)"; return
    fi
  fi
  if [ -n "$e" ] && [ "$erc" -ne 0 ]; then
    V=INCONCLUSIVE; R="the install itself failed (exit $erc) after ${dur}s, so no timeout stopped it; $saw"
  elif [ -f "$p/sub-ran-$1" ] || [ "$cstat" = ok ]; then
    V=PASS; R="the creation finished and the subagent ran: the install $ended, against $timeout_is; $cache"
    [ "$dur" -lt "$tmo" ] || R="$R; it ran past that timeout, so the effective limit is longer than the timeout read"
  elif [ "$cstat" = denied ]; then
    V=DENIED; R="a permission rule stopped the Agent call: $(oneline "$(printf '%s\n' "$call" | cut -f4)")"
  elif [ "$cstat" = error ] || [ -z "$e" ]; then
    V=FAIL; R="the creation did not finish: the install $ended against $timeout_is, and the subagent never ran; $saw"
  else
    V=INCONCLUSIVE; R="the install ended after ${dur}s, but neither the subagent's mark nor its call's result can be read; $saw"
  fi
}

judge control 1
if [ "$V" != PASS ]; then
  all VOID "control: the creation with no lockfile did not pass ($V: $R)"; exit 0
fi
for a in cold:2 warm:3; do
  judge "${a%:*}" "${a#*:}"
  "$sp" verdict --arm "${a%:*}" "$V" "$R"
done
