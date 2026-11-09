#!/bin/sh
# Tests for tests/post-apply.sh, the base's `chezmoi apply` post hook: it returns to chezmoi at once
# while every suite runs detached, one run at a time; a pass is recorded in the ledger pre-apply
# reads, a failure calls the machine's alert hook (when it has one) naming the failing suites, and a
# one-line status file always says how the last run ended. Also that .chezmoi.toml.tmpl renders the
# hook pointing at this script.
#
# The script is copied into a scratch git repository beside a stand-in run-all.sh that waits for a
# release file, so a test can observe the script while the run is still going. Every detached run is
# released and waited for before the test ends: none outlives it.
set -u
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
t=${TMPDIR:-/tmp}; t=${t%/}
tmp=$(mktemp -d "$t/test-post-apply.XXXXXX") || exit 1
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

realgit=$(command -v git)
mkdir -p "$tmp/bin" "$tmp/repo/tests" "$tmp/state" "$tmp/cfg/dotfiles" "$tmp/home"
# Whatever is still running at the end is released and waited for, then the scratch is removed.
cleanup() { : > "$tmp/release" 2>/dev/null; w=0; while [ -d "$tmp/repo/.git/post-apply.lock" ] && [ "$w" -lt 100 ]; do sleep 0.1; w=$((w + 1)); done; rm -rf "$tmp"; }
trap cleanup EXIT

cp "$here/post-apply.sh" "$tmp/repo/tests/post-apply.sh"
# The stand-in runner: counts its starts, waits for $PA_HOLD to be released when asked to hold, then
# prints a suite list and exits as RUNALL_RC says.
cat > "$tmp/repo/tests/run-all.sh" <<'EOT'
#!/bin/sh
echo start >> "$PA_STARTS"
if [ -n "${PA_HOLD:-}" ]; then
  while [ ! -e "$PA_RELEASE" ]; do sleep 0.1; done
fi
echo "PASS   test-good.sh"
if [ "${RUNALL_RC:-0}" != 0 ]; then
  echo "FAIL   test-alpha.sh (exit 1)"; echo "FAIL   test-beta.sh (exit 1)"
fi
printf '\n3 suite(s): 1 passed, %s failed\n' "$([ "${RUNALL_RC:-0}" = 0 ] && echo 0 || echo 2)"
[ "${RUNALL_RC:-0}" = 0 ]
EOT
# The PATH: utilities from this machine, the real git, and stand-ins for the tools that are required.
for u in sh env sed grep tail cat rm dirname date mkdir mv ls nohup sleep tr sort uname head basename; do
  p=$(command -v "$u") && ln -s "$p" "$tmp/bin/$u"
done
ln -s "$realgit" "$tmp/bin/git"
for r in python3 uv jq yq gitleaks wt; do printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$r"; chmod +x "$tmp/bin/$r"; done
mkdir -p "$tmp/nouv"; for f in "$tmp/bin"/*; do [ "$(basename "$f")" = uv ] || ln -s "$f" "$tmp/nouv/$(basename "$f")"; done

g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$realgit" -C "$tmp/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
echo 1 > "$tmp/repo/file.txt"
g init -q && g add -A && g commit -q -m one
ledger="$tmp/repo/.git/pre-apply/passed"
status="$tmp/state/dotfiles/post-apply.last"
export PA_STARTS="$tmp/starts" PA_RELEASE="$tmp/release"

post() { # post [VAR=value ...]: run the hook as chezmoi would; rc, stdout/stderr in $tmp/out, $tmp/err
  env PATH="$tmp/bin" HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/cfg" GIT_CONFIG_GLOBAL=/dev/null PRE_APPLY_OS=Linux "$@" \
    sh "$tmp/repo/tests/post-apply.sh" > "$tmp/out" 2> "$tmp/err" < /dev/null; rc=$?
}
waitfor() { # waitfor <file> [seconds]: until the file exists
  w=0; lim=$(( ${2:-10} * 10 )); while [ ! -e "$1" ] && [ "$w" -lt "$lim" ]; do sleep 0.1; w=$((w + 1)); done; [ -e "$1" ]
}
waitidle() { # until no run holds the lock
  w=0; while [ -d "$tmp/repo/.git/post-apply.lock" ] && [ "$w" -lt 100 ]; do sleep 0.1; w=$((w + 1)); done
}
reset() { rm -f "$PA_STARTS" "$PA_RELEASE" "$status" "$tmp/alert.out"; rm -rf "$tmp/state/dotfiles"; }

echo "== it returns at once; the run continues detached, and a pass is recorded"
reset
post PA_HOLD=1 RUNALL_RC=0
[ "$rc" -eq 0 ] && ok "exit 0 straight away" || bad "exit 0" "rc=$rc $(cat "$tmp/err")"
waitfor "$PA_STARTS" && ok "the suites started in the background" || bad "run started" "no start"
[ ! -e "$status" ] && ok "the hook returned while the run was still going (no status yet)" || bad "returns before the run ends" "status already: $(cat "$status")"
: > "$PA_RELEASE"
waitfor "$status" && ok "the detached run finished and wrote the status file" || bad "status written" "none"
waitidle
tree=$(g rev-parse 'HEAD^{tree}')
grep -q "^$tree Linux " "$ledger" 2>/dev/null && ok "a full pass on a clean tree records tree and OS in the ledger" || bad "pass recorded" "ledger: $(cat "$ledger" 2>&1)"
grep -q " $tree pass " "$status" && ok "the status file says pass, with the tree" || bad "status line" "$(cat "$status")"
set -- "$tmp"/state/dotfiles/post-apply-*.log
[ -f "$1" ] && grep -q 'PASS   test-good.sh' "$1" && grep -qF "$1" "$status" && ok "the status line names the log, which holds the run" || bad "log named" "status: $(cat "$status") logs: $*"

echo "== a failure calls the alert hook with the failing suites and the log, and still writes the status"
reset; rm -f "$ledger"
cat > "$tmp/cfg/dotfiles/alert" <<EOT
#!/bin/sh
printf '%s\n' "\$1" > "$tmp/alert.out"
EOT
chmod +x "$tmp/cfg/dotfiles/alert"
post RUNALL_RC=1
waitfor "$tmp/alert.out" && ok "the alert hook ran" || bad "alert hook ran" "no alert; status: $(cat "$status" 2>&1)"
waitidle
grep -q 'test-alpha.sh' "$tmp/alert.out" && grep -q 'test-beta.sh' "$tmp/alert.out" && ok "the alert names each failing suite" || bad "alert names suites" "$(cat "$tmp/alert.out" 2>&1)"
logf=$(sed 's/^[^ ]* [^ ]* [^ ]* //' "$status")
grep -qF "$logf" "$tmp/alert.out" && ok "the alert names the log" || bad "alert names log" "alert: $(cat "$tmp/alert.out") log: $logf"
grep -q ' FAIL ' "$status" && ok "the status file says FAIL" || bad "status FAIL" "$(cat "$status" 2>&1)"
[ ! -e "$ledger" ] && ok "a failure records nothing in the ledger" || bad "failure records nothing" "$(cat "$ledger")"

echo "== no alert hook means no error; a non-executable one is not run"
reset; rm -f "$tmp/cfg/dotfiles/alert"
post RUNALL_RC=1
waitfor "$status" && waitidle
{ [ "$rc" -eq 0 ] && grep -q ' FAIL ' "$status"; } && ok "without a hook the failure is still recorded and the hook exits 0" || bad "no hook" "rc=$rc status: $(cat "$status" 2>&1)"
# The detached run's own exit status is not visible through the hook, so run it in the foreground
# (--run): a failure ends 1 by design; any other status means the missing hook was treated as an error.
reset; rm -f "$tmp/cfg/dotfiles/alert"
env PATH="$tmp/bin" HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/cfg" GIT_CONFIG_GLOBAL=/dev/null PRE_APPLY_OS=Linux RUNALL_RC=1 \
  sh "$tmp/repo/tests/post-apply.sh" --run > "$tmp/out" 2> "$tmp/err" < /dev/null; rc=$?
{ [ "$rc" -eq 1 ] && [ ! -s "$tmp/err" ]; } && ok "a failure with no alert hook ends 1 quietly, not on a missing-hook error" || bad "no hook, foreground" "rc=$rc $(cat "$tmp/err")"
printf '#!/bin/sh\necho ran > "%s"\n' "$tmp/alert.out" > "$tmp/cfg/dotfiles/alert"
reset; post RUNALL_RC=1; waitfor "$status" && waitidle
[ ! -e "$tmp/alert.out" ] && ok "a hook file that is not executable is not run" || bad "non-executable hook" "it ran"
rm -f "$tmp/cfg/dotfiles/alert"

echo "== a dirty tree is tested but never recorded"
reset; rm -f "$ledger"
echo dirty >> "$tmp/repo/file.txt"
post RUNALL_RC=0
waitfor "$status" && waitidle
{ [ ! -e "$ledger" ] && grep -q ' dirty pass ' "$status"; } && ok "ran and passed, no ledger entry, status says dirty" || bad "dirty not recorded" "ledger: $(cat "$ledger" 2>&1) status: $(cat "$status" 2>&1)"
g checkout -q -- file.txt

echo "== a second post-apply while one runs does not start a second suite"
reset
post PA_HOLD=1 RUNALL_RC=0
waitfor "$PA_STARTS"
post PA_HOLD=1 RUNALL_RC=0
sleep 1
[ "$(wc -l < "$PA_STARTS" | tr -d ' ')" -eq 1 ] && ok "one run-all start while the first is held" || bad "single run" "starts: $(wc -l < "$PA_STARTS")"
: > "$PA_RELEASE"; waitfor "$status"; waitidle
[ "$(wc -l < "$PA_STARTS" | tr -d ' ')" -eq 1 ] && ok "the refused run never started later either" || bad "still single" "starts: $(wc -l < "$PA_STARTS")"

echo "== a stale lock (its pid gone) is reclaimed"
reset
mkdir "$tmp/repo/.git/post-apply.lock"; echo 999999 > "$tmp/repo/.git/post-apply.lock/pid"
post RUNALL_RC=0
waitfor "$status" && waitidle
[ -f "$PA_STARTS" ] && ok "a dead holder's lock does not block the run" || bad "stale lock reclaimed" "no start"

echo "== it keeps the newest 5 logs"
reset; mkdir -p "$tmp/state/dotfiles"
for i in 1 2 3 4 5 6 7; do : > "$tmp/state/dotfiles/post-apply-2020010${i}T000000Z.log"; done
post RUNALL_RC=0
waitfor "$status" && waitidle
n=$(ls "$tmp"/state/dotfiles/post-apply-*.log | wc -l | tr -d ' ')
{ [ "$n" -eq 5 ] && [ ! -e "$tmp/state/dotfiles/post-apply-20200101T000000Z.log" ]; } && ok "five logs remain, the oldest gone" || bad "prune logs" "$n logs: $(ls "$tmp/state/dotfiles")"

echo "== skips: DOTFILES_SKIP_POST_APPLY=1, and a machine without the suites' tools"
reset
post DOTFILES_SKIP_POST_APPLY=1
{ [ "$rc" -eq 0 ] && grep -q 'SKIPPED by DOTFILES_SKIP_POST_APPLY' "$tmp/err"; } && ok "skipped loudly, exit 0" || bad "skip env" "rc=$rc $(cat "$tmp/err")"
sleep 0.5; [ ! -e "$PA_STARTS" ] && ok "runs no suite when skipped" || bad "skip env runs none" "ran"
post PATH="$tmp/nouv"
{ [ "$rc" -eq 0 ] && grep -q 'SKIPPED, not installed: uv' "$tmp/err"; } && ok "missing tools: names them, exit 0" || bad "missing tool" "rc=$rc $(cat "$tmp/err")"
sleep 0.5; [ ! -e "$PA_STARTS" ] && ok "runs no suite without the tools" || bad "missing tool runs none" "ran"

echo "== .chezmoi.toml.tmpl renders the hook"
if command -v chezmoi >/dev/null 2>&1; then
  printf '[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n' > "$tmp/old.toml"
  cfg=$(chezmoi --config "$tmp/old.toml" --source "$src" --persistent-state "$tmp/s.db" \
    execute-template --init --no-tty < "$src/.chezmoi.toml.tmpl" 2>&1)
  printf '%s\n' "$cfg" | grep -qx '\[hooks\.apply\.post\]' && ok "a [hooks.apply.post] table" || bad "hook table" "$cfg"
  printf '%s\n' "$cfg" | grep -qF "    args = [\"$src/tests/post-apply.sh\"]" && ok "pointing at this source's tests/post-apply.sh" || bad "args" "$cfg"
else
  echo "  SKIP  chezmoi not installed, the template is not rendered"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
