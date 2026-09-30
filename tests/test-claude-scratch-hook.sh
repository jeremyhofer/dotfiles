#!/bin/sh
# test-claude-scratch-hook.sh — contract tests for the scratch-cleanup lifecycle hooks.
#
# The hook DELETES DIRECTORIES, so most of what is worth testing here is refusal: that it stays
# inert except for the one shape of path (a "c-*" directory that is a direct child of /tmp) a real
# launcher ever points CLAUDE_CODE_TMPDIR at. Every guard test plants a real directory and proves
# it SURVIVES a session-end call, not merely that the process exited 0 -- a script that no-ops for
# the wrong reason (a crash before it gets that far, say) would also exit 0 and prove nothing.
#
# Several assertions here also run a DELIBERATELY BROKEN copy of the script (one guard line
# removed via sed, verified against the live file text) right next to the real one, and assert the
# broken copy behaves unsafely where the real one does not. That is not decoration: it is how this
# suite itself was verified while it was written -- a check never seen to fail is of unknown value
# -- and it stays in so a future edit that weakens a guard fails loudly here instead of silently.
#
# Root fixtures live directly under /tmp (mktemp -d "/tmp/c-test-XXXXXX"), because the guard under
# test is specifically "direct child of /tmp". A sandboxed environment that denies writes to /tmp
# outside a few pre-approved paths cannot create one; that block SKIPs with a named reason rather
# than silently passing or failing the suite. On an unsandboxed machine -- which is where this
# actually runs -- nothing should skip.
#
# Run: sh ~/.local/share/chezmoi/tests/test-claude-scratch-hook.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
HOOK="$here/../private_dot_local/bin/executable_claude-scratch-hook"

[ -x "$HOOK" ] || { echo "FAIL: $HOOK is missing or not executable"; exit 1; }

pass=0; fail=0; skip=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
sk() { printf '  SKIP  %s -- %s\n' "$1" "$2"; skip=$((skip + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

TESTROOT=$(mktemp -d)
trap 'rm -rf "$TESTROOT" "${outside:-}" "${outside2:-}" "${target2:-}" 2>/dev/null' EXIT

# macOS sets TMPDIR WITH a trailing slash, so "${TMPDIR:-/tmp}/x.XXXXXX" yields a path containing
# "//" -- harmless for file I/O, fatal the moment such a path is compared textually elsewhere.
TD=${TMPDIR:-/tmp}; TD=${TD%/}

# 1 MB so a couple of small dd fixtures land cleanly on either side of it and the suite stays fast.
THRESH_MB=1
export CLAUDE_SCRATCH_HOOK_THRESHOLD_MB=$THRESH_MB

counter=0
broken_copy() { # <sed-script> -> path to a broken copy of $HOOK
  counter=$((counter + 1))
  b="$TESTROOT/broken-$counter"
  sed "$1" "$HOOK" > "$b"
  chmod +x "$b"
  printf '%s' "$b"
}

start_payload() { jq -cn --arg id "$1" '{agent_id: $id, agent_type: "t", session_id: "s", cwd: "/x", hook_event_name: "SubagentStart"}'; }
substop_payload() { jq -cn --arg id "$1" --argjson active "$2" '{agent_id: $id, stop_hook_active: $active, session_id: "s", cwd: "/x", hook_event_name: "SubagentStop"}'; }
stop_payload() { jq -cn --argjson active "$1" '{stop_hook_active: $active, session_id: "s", cwd: "/x", hook_event_name: "Stop"}'; }

runhook() { printf '%s' "$3" | "$1" "$2"; }  # <hook-path> <subcommand> <payload-json>

bigfile() { dd if=/dev/zero of="$1" bs=1M count="${2:-2}" 2>/dev/null; }     # over the 1 MB threshold
smallfile() { dd if=/dev/zero of="$1" bs=1k count="${2:-100}" 2>/dev/null; } # under it

echo "== jq missing -> exit 0 silently =="
noJQdir="$TESTROOT/no-jq-path"
mkdir -p "$noJQdir"
for t in /usr/bin /bin; do
  for b in printf touch mkdir rm dirname basename cat find wc awk dd sed sh env; do
    [ -x "$t/$b" ] && ln -sf "$t/$b" "$noJQdir/$b" 2>/dev/null
  done
done
out=$(printf '{}' | env -i PATH="$noJQdir" HOME="$HOME" CLAUDE_CODE_TMPDIR="" "$HOOK" stop 2>&1); rc=$?
eq "real script: exit 0 with jq absent, no root" "$rc" "0"
eq "real script: no output with jq absent, no root" "$out" ""
# The plant for this guard needs a valid root -- jq is never actually called on the no-root path
# above regardless of the guard, so removing the guard there would prove nothing. See the plant
# further down ("jq missing, with a valid root"), inside the valid-root block.

echo "== CLAUDE_CODE_TMPDIR unset / empty -> no action =="
for sub in subagent-start subagent-stop stop session-end; do
  out=$(env -u CLAUDE_CODE_TMPDIR "$HOOK" "$sub" < /dev/null 2>&1); rc=$?
  eq "unset: $sub exits 0" "$rc" "0"
  eq "unset: $sub prints nothing" "$out" ""
  out=$(CLAUDE_CODE_TMPDIR="" "$HOOK" "$sub" < /dev/null 2>&1); rc=$?
  eq "empty: $sub exits 0" "$rc" "0"
  eq "empty: $sub prints nothing" "$out" ""
done

echo "== CLAUDE_CODE_TMPDIR points at a c-* path under /tmp that does not exist -> no action, not created =="
ghost="/tmp/c-test-ghost-$$"
rm -rf "$ghost" 2>/dev/null
out=$(CLAUDE_CODE_TMPDIR="$ghost" runhook "$HOOK" subagent-start "$(start_payload a1)" 2>&1); rc=$?
eq "nonexistent root: exit 0" "$rc" "0"
eq "nonexistent root: no output" "$out" ""
eq "nonexistent root: never created" "$([ -e "$ghost" ] && echo present || echo absent)" "absent"

echo "== CLAUDE_CODE_TMPDIR resolves OUTSIDE /tmp (a c-* dir nested inside the test root, never a direct child of /tmp) =="
outside=$(mktemp -d "$TESTROOT/c-test-outside.XXXXXX")
: > "$outside/sentinel"
out=$(CLAUDE_CODE_TMPDIR="$outside" runhook "$HOOK" session-end "" "" 2>&1); rc=$?
eq "outside /tmp: exit 0" "$rc" "0"
eq "outside /tmp: sentinel dir survives session-end" "$([ -d "$outside" ] && echo present || echo gone)" "present"
eq "outside /tmp: sentinel file survives session-end" "$([ -f "$outside/sentinel" ] && echo present || echo gone)" "present"

# Plant: remove the "-parent must be exactly /tmp" guard and watch the SAME kind of directory get
# deleted. Uses a second fixture so the first one's assertions above stay untouched by the plant.
outside2=$(mktemp -d "$TESTROOT/c-test-outside2.XXXXXX")
: > "$outside2/sentinel"
broken=$(broken_copy '/\[ "\$parent" = "\/tmp" \] || exit 0/d')
CLAUDE_CODE_TMPDIR="$outside2" runhook "$broken" session-end "" "" >/dev/null 2>&1
if [ ! -e "$outside2" ]; then
  ok "plant: removing the /tmp-parent guard lets session-end delete a directory outside /tmp"
else
  no "plant: removing the /tmp-parent guard did not change behaviour -- the guard may not be load-bearing"
fi


echo "session-end: the session's large-scratch folder under ~/.cache/agent-scratch"
# Its own guard, independent of /tmp, so these run anywhere: a fake HOME, and a CLAUDE_CODE_TMPDIR
# naming a /tmp root that need not exist (it may have aged out before the session ended).
H="$TESTROOT/home"; AS="$H/.cache/agent-scratch"; mkdir -p "$AS"
nm="c-cachetest-$$"
mkdir -p "$AS/$nm/deep" "$AS/c-other-$$" "$AS/not-a-session"; : > "$AS/$nm/deep/f"
: > "$AS/c-other-$$/keep"; : > "$AS/not-a-session/keep"
HOME="$H" CLAUDE_CODE_TMPDIR="/tmp/$nm" "$HOOK" session-end </dev/null >/dev/null 2>&1
[ ! -e "$AS/$nm" ] && ok "the session's own folder is removed" || no "the session's own folder is removed"
[ -e "$AS/c-other-$$/keep" ] && ok "another session's folder survives" || no "another session's folder survives"
[ -e "$AS/not-a-session/keep" ] && ok "a folder not named for a session survives" || no "a folder not named for a session survives"
mkdir -p "$AS/named" ; : > "$AS/named/keep"
HOME="$H" CLAUDE_CODE_TMPDIR="/tmp/named" "$HOOK" session-end </dev/null >/dev/null 2>&1
[ -e "$AS/named/keep" ] && ok "a root not named c-* removes nothing" || no "a root not named c-* removes nothing"
outside3="$TESTROOT/outside3"; mkdir -p "$outside3"; : > "$outside3/precious"
ln -s "$outside3" "$AS/c-link-$$"
HOME="$H" CLAUDE_CODE_TMPDIR="/tmp/c-link-$$" "$HOOK" session-end </dev/null >/dev/null 2>&1
[ -e "$outside3/precious" ] && ok "a symlinked folder's target survives" || no "a symlinked folder's target survives"
mkdir -p "$AS/c-stop-$$"; : > "$AS/c-stop-$$/keep"
printf '{}' | HOME="$H" CLAUDE_CODE_TMPDIR="/tmp/c-stop-$$" "$HOOK" stop >/dev/null 2>&1
[ -e "$AS/c-stop-$$/keep" ] && ok "only session-end removes it" || no "only session-end removes it"

echo "== a symlink INSIDE the root pointing outside it is not followed =="
# The remaining tests need a genuine root: a directory whose basename matches c-* and whose parent
# is literally /tmp. A sandbox that denies writes directly under /tmp cannot produce one.
root=$(mktemp -d "/tmp/c-test-XXXXXX" 2>/dev/null)
if [ -z "$root" ] || [ ! -d "$root" ]; then
  sk "valid-root behavioural tests (symlink, threshold, home-glob, newer-than, stop_hook_active, session-end deletion)" \
     "cannot create a directory directly under /tmp in this environment (mktemp -d /tmp/c-test-XXXXXX failed)"
else
  outside_target=$(mktemp -d "$TESTROOT/c-test-symlink-target.XXXXXX")
  echo "do not delete me" > "$outside_target/keepme"
  ln -s "$outside_target" "$root/escape-link"
  CLAUDE_CODE_TMPDIR="$root" runhook "$HOOK" session-end "" "" >/dev/null 2>&1
  eq "real script: root is gone" "$([ -e "$root" ] && echo present || echo gone)" "gone"
  eq "real script: symlink target survives" "$([ -f "$outside_target/keepme" ] && echo present || echo gone)" "present"
  rm -rf "$outside_target"

  # Plant, on the MEASURING half of the same guard rather than the deleting half: adding -L makes
  # `find` follow a symlink member, so an outside file becomes visible to the byte count. (Not
  # tested by executing a "resolve the symlink, then rm -rf it" deleter: that shape of dynamic-path
  # removal is exactly what this machine's own rm safety check refuses to run without a human
  # approving it, for the same reason this guard exists -- so the deleting half is covered by the
  # real-script assertion above, which proves the target survives, plus rm's ordinary behaviour:
  # unlike find, it has no -L-equivalent toggle, so there is no one-line guard on the delete path
  # to remove.)
  root2=$(mktemp -d "/tmp/c-test-XXXXXX")
  target2=$(mktemp -d "$TESTROOT/c-test-symlink-target2.XXXXXX")
  bigfile "$target2/big.bin" 2
  ln -s "$target2" "$root2/escape-link"
  out=$(CLAUDE_CODE_TMPDIR="$root2" runhook "$HOOK" stop "$(stop_payload false)" "" 2>&1)
  eq "real script: symlinked outside data not measured, stays silent" "$out" ""

  broken=$(broken_copy 's/find "\$root" \\( -path/find -L "$root" \\( -path/g')
  out=$(CLAUDE_CODE_TMPDIR="$root2" runhook "$broken" stop "$(stop_payload false)" "" 2>&1)
  if [ -n "$out" ]; then
    ok "plant: find -L pulls the symlinked outside data into the measurement"
  else
    no "plant: find -L did not change behaviour -- check the sed edit landed"
  fi
  rm -rf "$target2" "$root2" 2>/dev/null

  echo "== jq missing, with a valid root -- exit 0 silently rather than leaking a 'command not found' =="
  # Unlike the no-root case earlier, "stop" reads .stop_hook_active via jq immediately after root
  # validation passes, so this is the path that actually exercises the guard.
  jqroot=$(mktemp -d "/tmp/c-test-XXXXXX")
  out=$(printf '{}' | env -i PATH="$noJQdir" HOME="$HOME" CLAUDE_CODE_TMPDIR="$jqroot" "$HOOK" stop 2>&1); rc=$?
  eq "real script: exit 0, jq absent, valid root" "$rc" "0"
  eq "real script: silent, jq absent, valid root" "$out" ""

  # No plant here: without the guard the hook still exits 0 silently, because every jq call below
  # it already discards errors. The guard is defence in depth, so removing it cannot be seen red.
  rm -rf "$jqroot"

  # The session-end test above deleted $root. The agent and stop tests need a live root, named in
  # the environment the way a launched session has it (runhook passes no CLAUDE_CODE_TMPDIR itself).
  root=$(mktemp -d "/tmp/c-test-XXXXXX")
  CLAUDE_CODE_TMPDIR=$root; export CLAUDE_CODE_TMPDIR

  # A file OLDER than agent-a's marker: must be EXCLUDED from agent-a's measurement. Created
  # BEFORE subagent-start, with a sleep to clear filesystems whose mtime resolution is 1s.
  bigfile "$root/pre-existing-old.bin" 2
  sleep 1

  echo "== subagent-start writes a marker; subagent-stop under threshold is silent =="
  runhook "$HOOK" subagent-start "$(start_payload agent-a)" >/dev/null 2>&1
  eq "marker file created" "$([ -f "$root/.scratch-hook/agent-agent-a.start" ] && echo present || echo absent)" "present"
  sleep 1
  smallfile "$root/agent-a-new.bin" 50
  out=$(runhook "$HOOK" subagent-stop "$(substop_payload agent-a false)" 2>&1)
  eq "under threshold: no output" "$out" ""
  eq "marker removed after processing" "$([ -f "$root/.scratch-hook/agent-agent-a.start" ] && echo present || echo gone)" "gone"

  echo "== subagent-stop counts only files newer than the marker, and crosses the threshold when they do =="
  runhook "$HOOK" subagent-start "$(start_payload agent-b)" >/dev/null 2>&1
  sleep 1
  bigfile "$root/agent-b-new.bin" 2
  out=$(runhook "$HOOK" subagent-stop "$(substop_payload agent-b false)" 2>&1)
  printf '%s' "$out" | jq -e . >/dev/null 2>&1
  eq "over threshold: output is valid JSON" "$?" "0"
  eq "over threshold: correct hookEventName" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "SubagentStop"
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
  case "$ctx" in
    *"about "*" MB"*) ok "additionalContext names an MB figure" ;;
    *) no "additionalContext missing an MB figure: $ctx" ;;
  esac
  eq "marker removed after processing" "$([ -f "$root/.scratch-hook/agent-agent-b.start" ] && echo present || echo gone)" "gone"
  # The 2 MB pre-existing file never counted toward either agent's sum on its own: agent-a (50 KB
  # new) stayed silent and agent-b (2 MB new) alone was what crossed the threshold.

  echo "== subagent-stop: stop_hook_active=true is a silent no-op and the marker is kept =="
  runhook "$HOOK" subagent-start "$(start_payload agent-c)" >/dev/null 2>&1
  bigfile "$root/agent-c-new.bin" 2
  out=$(runhook "$HOOK" subagent-stop "$(substop_payload agent-c true)" 2>&1)
  eq "no output" "$out" ""
  eq "marker NOT removed" "$([ -f "$root/.scratch-hook/agent-agent-c.start" ] && echo present || echo gone)" "present"
  rm -f "$root/.scratch-hook/agent-agent-c.start" "$root/agent-c-new.bin"

  echo "== stop: stop_hook_active=true is a silent no-op =="
  out=$(runhook "$HOOK" stop "$(stop_payload true)" 2>&1)
  eq "no output" "$out" ""

  broken=$(broken_copy '/\[ "\$active" = "true" \] && exit 0/d')
  bigfile "$root/for-stop-active-plant.bin" 2
  out=$(runhook "$broken" stop "$(stop_payload true)" 2>&1)
  rm -f "$root/for-stop-active-plant.bin"
  if [ -n "$out" ]; then
    ok "plant: removing the stop_hook_active guard makes stop emit even when active=true"
  else
    no "plant: removing the stop_hook_active guard did not change behaviour -- check the sed edit landed"
  fi

  unset CLAUDE_CODE_TMPDIR

  echo "== stop measures the whole root and excludes claude-*/-home-* =="
  clean=$(mktemp -d "/tmp/c-test-XXXXXX")
  mkdir -p "$clean/claude-9999/-home-someuser"
  bigfile "$clean/claude-9999/-home-someuser/big-task-output.bin" 3
  out=$(CLAUDE_CODE_TMPDIR="$clean" runhook "$HOOK" stop "$(stop_payload false)" "" 2>&1)
  eq "real script: -home-* excluded, stays under threshold" "$out" ""

  broken=$(broken_copy 's/ -o -path "\$home_glob"//g')
  out=$(CLAUDE_CODE_TMPDIR="$clean" runhook "$broken" stop "$(stop_payload false)" "" 2>&1)
  if [ -n "$out" ]; then
    ok "plant: dropping the -home-* exclusion pulls task output into the measurement"
  else
    no "plant: dropping the -home-* exclusion did not change behaviour -- check the sed edit landed"
  fi
  rm -rf "$clean"

  echo "== session-end deletes the root =="
  fresh=$(mktemp -d "/tmp/c-test-XXXXXX")
  : > "$fresh/leftover"
  CLAUDE_CODE_TMPDIR="$fresh" runhook "$HOOK" session-end "" "" >/dev/null 2>&1
  eq "session-end: root is gone" "$([ -e "$fresh" ] && echo present || echo gone)" "gone"

  broken=$(broken_copy 's/rm -rf -- "\$root" 2>\/dev\/null/: no-op/')
  fresh2=$(mktemp -d "/tmp/c-test-XXXXXX")
  CLAUDE_CODE_TMPDIR="$fresh2" runhook "$broken" session-end "" "" >/dev/null 2>&1
  if [ -e "$fresh2" ]; then
    ok "plant: removing the deletion line leaves the root behind"
  else
    no "plant: removing the deletion line did not change behaviour -- check the sed edit landed"
  fi
  rm -rf "$fresh2" 2>/dev/null

  rm -rf "$root"
fi

echo
if [ "$skip" -gt 0 ]; then
  printf '%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"
else
  printf '%s passed, %s failed\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ] && { echo PASS; exit 0; }
exit 1
