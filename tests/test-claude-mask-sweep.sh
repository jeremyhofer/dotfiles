#!/bin/sh
# test-claude-mask-sweep.sh — contract tests for claude-mask-sweep.
#
# The tool deletes files, so the tests that matter are the ones about what it must NOT delete: a
# mask a running session has mounted, a real settings file, an empty file that is still writable.
# /proc is faked through CLAUDE_MASK_SWEEP_PROC, so the suite runs the same inside and outside a
# sandbox and never reads the real mount table.
#
# Run: sh ~/.local/share/chezmoi/tests/test-claude-mask-sweep.sh
set -u
TOOL="$(cd "$(dirname "$0")/.." && pwd)/private_dot_local/bin/executable_claude-mask-sweep"

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }
gone() { if [ -e "$2" ]; then no "$1 (still there: $2)"; else ok "$1"; fi; }
kept() { if [ -e "$2" ]; then ok "$1"; else no "$1 (deleted: $2)"; fi; }

if [ "$(uname -s)" != Linux ]; then
  out=$(sh "$TOOL" 2>&1); rc=$?
  eq "non-Linux: exits 0" "$rc" 0
  printf '%s\n' "$out" | grep -q 'nothing to do' && ok "non-Linux: says why" || no "non-Linux: says why"
  echo "passed $pass, failed $fail"; [ "$fail" -eq 0 ]; exit
fi

w=$(mktemp -d); trap 'chmod -R u+w "$w" 2>/dev/null; rm -rf "$w"' EXIT
home=$w/home; proj=$w/home/Devel/repo; proc=$w/proc
mkdir -p "$home/.claude" "$proj/.claude" "$proj/.git" "$proc/1" "$proc/4242"
mask() { : > "$1"; chmod 444 "$1"; }
mask "$home/.claude/loop.md"                  # stale, in ~/.claude
mask "$proj/.bashrc"                          # stale, at a project root
mask "$proj/.claude/settings.local.json"      # stale, in a project's .claude/
mask "$proj/.git/config.lock"                 # stale, in .git/
mask "$home/.claude/cowork plugins"           # stale, with a space in the name
mask "$home/.claude/ide"                      # IN USE: mounted by pid 4242 below
: > "$home/.claude/empty-but-writable"        # not a mask: has a write bit
printf '{}\n' > "$home/.claude/settings.json"; chmod 444 "$home/.claude/settings.json"  # not empty
mkdir -p "$proj/sub"; mask "$proj/sub/deep"   # outside where masks are created
echo systemd > "$proc/1/comm"
printf '36 25 0:5 / %s rw - tmpfs tmpfs rw\n' "$home/.claude/ide" > "$proc/4242/mountinfo"
run() { HOME=$home CLAUDE_MASK_SWEEP_PROC=$proc sh "$TOOL" "$@" 2>&1; }

echo "== report only, by default =="
out=$(run); rc=$?
eq "exit 1 when stale masks are found" "$rc" 1
eq "reports exactly the five stale masks" "$(printf '%s\n' "$out" | grep -c '^stale ')" 5
printf '%s\n' "$out" | grep -qxF "in use   $home/.claude/ide" && ok "reports the mounted one as in use" \
  || no "reports the mounted one as in use"
kept "deletes nothing without --remove" "$proj/.bashrc"

echo "== --remove =="
out=$(run --remove); rc=$?
eq "exit 0 once every stale mask is removed" "$rc" 0
gone "removes a mask in ~/.claude" "$home/.claude/loop.md"
gone "removes a mask at a project root" "$proj/.bashrc"
gone "removes a mask in a project's .claude/" "$proj/.claude/settings.local.json"
gone "removes a mask in .git/" "$proj/.git/config.lock"
gone "removes a mask whose name has a space" "$home/.claude/cowork plugins"
kept "keeps a mask a running session has mounted" "$home/.claude/ide"
kept "keeps an empty file that is writable" "$home/.claude/empty-but-writable"
kept "keeps a read-only file that is not empty" "$home/.claude/settings.json"
kept "keeps a file deeper than masks are created" "$proj/sub/deep"

echo "== --under and an explicit root =="
other=$w/elsewhere; mkdir -p "$other/.claude"; mask "$other/.claude/hooks"
out=$(run); eq "an unlisted directory is not scanned" "$(printf '%s\n' "$out" | grep -c "$other")" 0
out=$(run "$other"); printf '%s\n' "$out" | grep -qxF "stale    $other/.claude/hooks" \
  && ok "an explicit root is scanned" || no "an explicit root is scanned"

echo "== refuses inside a sandbox =="
echo bwrap > "$proc/1/comm"
out=$(run --remove "$other"); rc=$?
eq "exit 2 when PID 1 is bwrap" "$rc" 2
kept "deletes nothing when refusing" "$other/.claude/hooks"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
