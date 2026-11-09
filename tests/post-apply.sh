#!/bin/sh
# post-apply -- after `chezmoi apply` has deployed this source tree, run EVERY suite in the
# background, alert on a failure and record a full pass.
#
# Run by chezmoi as the base's `hooks.apply.post` (.chezmoi.toml.tmpl). It returns at once: the
# apply must not wait for minutes of suites that can no longer stop it. Also runnable by hand:
# `sh tests/post-apply.sh` (still detaches), `sh tests/post-apply.sh --run` (runs in the foreground).
#
# WHY THIS EXISTS. tests/pre-apply.sh blocks an apply only on the suites the change reaches, to keep
# the apply fast. The rest of the set must still pass, and this is where it runs: every suite, on
# every OS, after the apply. Its failure cannot undo the apply, so it is made impossible to miss
# instead: the failing suites go to an alert hook, and the last result is always in a status file.
#
# DETACHED, AND PORTABLE. `nohup sh ... &` with every descriptor redirected, because chezmoi waits
# for a hook's output pipes as well as its exit, and macOS has no `setsid`. Stdin is closed so the
# run never reads the terminal the apply came from.
#
# ONE RUN AT A TIME. Two applies close together would otherwise run two full suites at once, and the
# suites contend for the machine (some assert on timing). An atomic `mkdir` takes the lock under the
# git common directory; the holder's pid is written inside it. A second run that finds the lock held
# by a live pid exits without testing anything; a lock whose pid is gone (a crash, a reboot) is
# reclaimed. The first run tests the tree it started with: a change applied meanwhile is picked up by
# the next apply's run, or by pre-apply's selection until then.
#
# WHAT IS RECORDED. The tree tested is HEAD's tree when the source is clean; a dirty tree is tested
# but never recorded or named, since it is not a tree git can answer for. On a full pass the pass is
# appended to the ledger tests/pre-apply.sh reads (`<tree> <os> <utc time>` in <git common dir>/
# pre-apply/passed), only if the source is still clean and still that tree afterwards, which is the
# same rule pre-apply follows. Once recorded, later applies of that tree skip the suites.
#
# WHERE THE RESULT GOES, all under ${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/:
#   post-apply-<utc time>.log   the full output of the run; the newest 5 are kept
#   post-apply.last             one line: time, tree (or `dirty`), `pass` or `FAIL`, log path
#
# THE ALERT HOOK. On a failure, ${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/alert is run, if it exists
# and is executable, with one argument: a line naming the failing suites and the log. This base is
# public and knows no notification service or topic; a machine's private layer supplies the file.
# Without one the failure is still recorded in the status file and the log. A failing hook is
# ignored: the status file already holds the result.
#
# SKIPS, loudly, exactly as pre-apply does: DOTFILES_SKIP_POST_APPLY=1, or a tool the suites need
# not installed (a first apply, where the tools arrive with or after it).
#
# Exit 0 always for the detaching form, so the apply is never affected by this hook; the --run form
# exits 0 on a pass and 1 on a failure.
set -u
here=$(cd "$(dirname "$0")" && pwd)

mode=detach
[ "${1:-}" = --run ] && mode=run

if [ "$mode" = detach ]; then
  if [ "${DOTFILES_SKIP_POST_APPLY:-}" = 1 ]; then
    printf 'dotfiles post-apply: SKIPPED by DOTFILES_SKIP_POST_APPLY=1; the suites do not run after this apply.\n' >&2
    exit 0
  fi
  missing=""
  for tool in git python3 uv jq yq gitleaks wt; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    printf 'dotfiles post-apply: suites SKIPPED, not installed:%s. Install them and the next apply runs the suites.\n' "$missing" >&2
    exit 0
  fi
  printf 'dotfiles post-apply: running every suite in the background; last result in the status file post-apply.last\n' >&2
  nohup sh "$here/post-apply.sh" --run >/dev/null 2>&1 </dev/null &
  exit 0
fi

# --- the detached run -----------------------------------------------------------------------------
for v in $(env | sed -n 's/^\(CHEZMOI[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done

os=${PRE_APPLY_OS:-$(uname -s)}
src=$(cd "$here/.." && pwd)
sd=${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles
mkdir -p "$sd" || exit 1

ledger=""; lockdir="$sd/post-apply.lock"
gdir=$(git -C "$src" rev-parse --git-common-dir 2>/dev/null) || gdir=""
case $gdir in "") ;; /*) ledger="$gdir/pre-apply/passed" ;; *) ledger="$src/$gdir/pre-apply/passed" ;; esac
case $gdir in "") ;; /*) lockdir="$gdir/post-apply.lock" ;; *) lockdir="$src/$gdir/post-apply.lock" ;; esac

clean_tree() { # print HEAD's tree when the source is clean; print nothing otherwise
  [ -z "$(git -C "$src" status --porcelain 2>/dev/null)" ] || return 0
  git -C "$src" rev-parse "HEAD^{tree}" 2>/dev/null || true
}

# The lock. A held lock whose pid is gone is reclaimed once; a pid file not yet written counts as held.
if ! mkdir "$lockdir" 2>/dev/null; then
  holder=$(cat "$lockdir/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$lockdir"
    mkdir "$lockdir" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
echo "$$" > "$lockdir/pid"
trap 'rm -rf "$lockdir"' EXIT
trap 'exit 1' HUP INT TERM

tree=$(clean_tree)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
log="$sd/post-apply-$stamp.log"
sh "$here/run-all.sh" > "$log" 2>&1; rc=$?
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
label=${tree:-dirty}

# Keep the newest 5 logs. The names sort by time, so a plain sort orders them.
n=0
for f in $(ls -1 "$sd"/post-apply-*.log 2>/dev/null | sort -r); do
  n=$((n + 1)); [ "$n" -gt 5 ] && rm -f "$f"
done

if [ "$rc" -eq 0 ]; then
  result=pass
  if [ -n "$tree" ] && [ -n "$ledger" ] \
     && [ -z "$(git -C "$src" status --porcelain 2>/dev/null)" ] \
     && [ "$(git -C "$src" rev-parse "HEAD^{tree}" 2>/dev/null)" = "$tree" ]; then
    mkdir -p "$(dirname "$ledger")" && printf '%s %s %s\n' "$tree" "$os" "$now" >> "$ledger"
  fi
else
  result=FAIL
fi
printf '%s %s %s %s\n' "$now" "$label" "$result" "$log" > "$sd/post-apply.last.$$" \
  && mv -f "$sd/post-apply.last.$$" "$sd/post-apply.last"

if [ "$result" = FAIL ]; then
  failed=$(sed -n 's/^FAIL   \([^ ]*\) .*/\1/p' "$log" | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
  alert=${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/alert
  if [ -x "$alert" ] && [ -f "$alert" ]; then
    "$alert" "dotfiles post-apply: suites failed after the apply: ${failed:-unknown}; log: $log" >/dev/null 2>&1 || true
  fi
  exit 1
fi
exit 0
