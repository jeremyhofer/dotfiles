#!/bin/sh
# Tests for tests/pre-apply.sh, the base's `chezmoi apply` pre hook: only the suites the change
# reaches run before an apply (every suite when no earlier full pass is known), a failure aborts it
# on every OS naming the suite and how to see why, a selected-only pass records nothing, and a
# machine without the tools the suites need skips loudly rather than failing its first apply. Also
# that .chezmoi.toml.tmpl renders the hook pointing at this script.
#
# The script is copied beside a stand-in run-all.sh and a stand-in select-suites.sh in a scratch
# tests/ directory, and run under a PATH holding stand-ins for the tools it requires, so no suite and
# no real apply runs.
set -u
# The skip switches are the CALLER's: an apply run with one set starts the detached post-apply's
# run-all, and so this suite, with it still exported. Inherited, it would skip the script under test
# and fail every case that expects a run. Cases that test a skip pass it explicitly.
unset DOTFILES_SKIP_PRE_APPLY DOTFILES_SKIP_POST_APPLY
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
t=${TMPDIR:-/tmp}; t=${t%/}
tmp=$(mktemp -d "$t/test-pre-apply.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

mkdir -p "$tmp/tests" "$tmp/bin" "$tmp/nouv" "$tmp/logs"
cp "$here/pre-apply.sh" "$tmp/tests/pre-apply.sh"
# The stand-in runner: records that it ran and what CHEZMOI_* it saw, then exits as RUNALL_RC says.
cat > "$tmp/tests/run-all.sh" <<'EOF'
#!/bin/sh
echo ran > "$PA_MARK"
echo "$*" > "$PA_ARGS"
echo "${RUN_ALL_PROFILE:-}" > "$PA_PROF"
env | grep '^CHEZMOI' > "$PA_ENV" || true
echo "PASS   test-good.sh"
[ "${RUNALL_RC:-0}" = 0 ] || { echo "FAIL   test-broken.sh (exit 1)"; echo "       | the reason it failed"; }
printf '\n2 suite(s): 1 passed, %s failed\n' "$([ "${RUNALL_RC:-0}" = 0 ] && echo 0 || echo 1)"
exit "${RUNALL_RC:-0}"
EOF
# The stand-in selector: paths in, suite names out. a/* reads test-a.sh, b/* test-b.sh, anything
# else no suite; SELECT_RC=1 makes it fail.
cat > "$tmp/tests/select-suites.sh" <<'EOF'
#!/bin/sh
[ "${SELECT_RC:-0}" = 0 ] || { echo "select-suites: broken" >&2; exit 1; }
while read -r p; do
  case $p in a/*) echo test-a.sh ;; b/*) echo test-b.sh ;; esac
done | sort -u
echo "select-suites: stand-in" >&2
EOF
# Utilities the script uses, from this machine; the tools it requires, as stand-ins.
for u in sh env sed grep mktemp tail cat rm dirname sort tr date mkdir; do
  p=$(command -v "$u") || { bad "$u on PATH" "the test needs it"; exit 1; }
  ln -s "$p" "$tmp/bin/$u"; ln -s "$p" "$tmp/nouv/$u"
done
for r in git python3 uv jq yq gitleaks wt; do
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$r"; chmod +x "$tmp/bin/$r"
  [ "$r" = uv ] || ln -s "$tmp/bin/$r" "$tmp/nouv/$r"
done
export PA_MARK="$tmp/ran" PA_ENV="$tmp/env" PA_ARGS="$tmp/args" PA_PROF="$tmp/prof"
# The run record goes under XDG_STATE_HOME: a scratch one for every case, never this machine's.
st="$tmp/state"
run() { # run <PATH dir> [VAR=value ...]: the script's exit code in $rc, its stderr in $tmp/err
  d=$1; shift; rm -f "$PA_MARK"
  env PATH="$d" TMPDIR="$tmp/logs" XDG_STATE_HOME="$st" "$@" sh "$tmp/tests/pre-apply.sh" > "$tmp/out" 2> "$tmp/err"; rc=$?
}

echo "== a failing suite aborts the apply"
run "$tmp/bin" RUNALL_RC=1 CHEZMOI=1 CHEZMOI_SOURCE_DIR=/somewhere PRE_APPLY_OS=Linux
[ "$rc" -ne 0 ] && ok "exit non-zero (chezmoi aborts the apply)" || bad "exit non-zero" "rc=$rc"
grep -q 'apply ABORTED' "$tmp/err" && ok "says the apply was aborted" || bad "says aborted" "$(cat "$tmp/err")"
grep -q 'FAIL   test-broken.sh' "$tmp/err" && ok "names the failing suite" || bad "names the suite" "$(cat "$tmp/err")"
grep -q 'run-all.sh --only test-broken.sh' "$tmp/err" && ok "says how to re-run that suite" || bad "re-run line" "$(cat "$tmp/err")"
logf=$(sed -n 's/^  why, in full: //p' "$tmp/err")
{ [ -n "$logf" ] && grep -q 'the reason it failed' "$logf"; } && ok "keeps the full output in a named log" || bad "full log" "log='$logf'"
grep -q '^the reason' "$tmp/err" && bad "the suite's own output stays in the log" "it was printed" || ok "the suite's own output stays in the log"
[ ! -s "$PA_ENV" ] && ok "the suites run without chezmoi's CHEZMOI_* variables" || bad "CHEZMOI_* removed" "$(cat "$PA_ENV")"

echo "== on macOS a failing suite aborts the apply too: one shape on every OS"
rm -f "$tmp/logs"/*
run "$tmp/bin" RUNALL_RC=1 PRE_APPLY_OS=Darwin
[ "$rc" -ne 0 ] && ok "exit non-zero on macOS" || bad "macOS failure aborts" "rc=$rc $(cat "$tmp/err")"
grep -q 'apply ABORTED' "$tmp/err" && ok "says the apply was aborted" || bad "says aborted on macOS" "$(cat "$tmp/err")"
grep -q 'NOT gating' "$tmp/err" && bad "no report-only clause remains" "$(cat "$tmp/err")" || ok "no report-only clause remains"
grep -q 'FAIL   test-broken.sh' "$tmp/err" && ok "names the failing suite" || bad "names the suite" "$(cat "$tmp/err")"

echo "== every suite passing lets the apply go ahead"
rm -f "$tmp/logs"/*
run "$tmp/bin" RUNALL_RC=0
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit 0" "rc=$rc $(cat "$tmp/err")"
grep -q '1 passed, 0 failed' "$tmp/err" && ok "reports the runner's tally" || bad "tally" "$(cat "$tmp/err")"
[ -z "$(ls "$tmp/logs")" ] && ok "a passing run leaves no log behind" || bad "no log" "$(ls "$tmp/logs")"

echo "== a machine without the suites' tools skips, loudly, and does not fail"
run "$tmp/nouv" RUNALL_RC=1
[ "$rc" -eq 0 ] && ok "exit 0 without uv (a first apply)" || bad "exit 0 without uv" "rc=$rc"
grep -q 'SKIPPED, not installed: uv' "$tmp/err" && ok "names what is missing" || bad "names uv" "$(cat "$tmp/err")"
[ ! -e "$PA_MARK" ] && ok "runs no suite" || bad "runs no suite" "the runner ran"

echo "== the pass ledger: a clean tree that passed every suite on this OS is not run again"
# A real git repository holding the script and the stand-in runner, run under a PATH whose git is
# the real one, so HEAD's tree, a dirty tree and the ledger under the git common directory are real.
realgit=$(command -v git)
mkdir -p "$tmp/gitbin" "$tmp/repo/tests"
for u in sh env sed grep mktemp tail cat rm dirname date mkdir; do
  p=$(command -v "$u") && ln -s "$p" "$tmp/gitbin/$u"
done
ln -s "$realgit" "$tmp/gitbin/git"
for r in python3 uv jq yq gitleaks wt; do ln -s "$tmp/bin/$r" "$tmp/gitbin/$r"; done
for u in sort tr awk wc; do p=$(command -v "$u") && ln -s "$p" "$tmp/gitbin/$u"; done
cp "$tmp/tests/pre-apply.sh" "$tmp/tests/run-all.sh" "$tmp/tests/select-suites.sh" "$tmp/repo/tests/"
mkdir -p "$tmp/repo/a" "$tmp/repo/b" "$tmp/repo/docs"
echo 1 > "$tmp/repo/a/one.txt"; echo 1 > "$tmp/repo/b/one.txt"; echo 1 > "$tmp/repo/docs/note.txt"
g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$realgit" -C "$tmp/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q && g add -A && g commit -q -m one
ledger="$(cd "$tmp/repo" && GIT_CONFIG_GLOBAL=/dev/null "$realgit" rev-parse --absolute-git-dir)/pre-apply/passed"
keep=0 # 1: lrun keeps the run history, so a later run can be credited by an earlier one
lrun() { # lrun [VAR=value ...]: run the repository's copy; rc and $tmp/err as run(); args the runner got in $tmp/args
  rm -f "$PA_MARK" "$PA_ARGS"
  [ "$keep" = 1 ] || rm -f "$st/dotfiles/pre-apply.history"
  env PATH="$tmp/gitbin" TMPDIR="$tmp/logs" XDG_STATE_HOME="$st" GIT_CONFIG_GLOBAL=/dev/null "$@" sh "$tmp/repo/tests/pre-apply.sh" > "$tmp/out" 2> "$tmp/err"; rc=$?
}
lines() { if [ -f "$ledger" ]; then wc -l < "$ledger" | tr -d ' '; else echo 0; fi; }
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
{ [ "$rc" -eq 0 ] && [ -e "$PA_MARK" ]; } && ok "a first run on a clean tree runs the suites" || bad "first run" "rc=$rc $(cat "$tmp/err")"
[ "$(cat "$PA_ARGS")" = "" ] && ok "no ledger entry: every suite runs (no --only)" || bad "no ledger runs every suite" "args: $(cat "$PA_ARGS")"
tree1=$(g rev-parse 'HEAD^{tree}')
grep -q "^$tree1 Linux " "$ledger" 2>/dev/null && ok "a clean full pass records the tree and OS" || bad "pass recorded" "ledger: $(cat "$ledger" 2>&1)"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
{ [ "$rc" -eq 0 ] && [ ! -e "$PA_MARK" ]; } && ok "the same tree again is skipped, no suite run" || bad "skip same tree" "rc=$rc ran=$([ -e "$PA_MARK" ] && echo yes)"
grep -q 'already passed on Linux at' "$tmp/err" && ok "says it skipped, and when the tree passed" || bad "skip line" "$(cat "$tmp/err")"

echo "== a ledger base tree selects only the suites the change touches"
echo 2 > "$tmp/repo/a/one.txt"; g add -A; g commit -q -m two
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
{ [ "$rc" -eq 0 ] && [ "$(cat "$PA_ARGS" 2>/dev/null)" = "--only test-a.sh" ]; } && ok "a change under a/ runs only test-a.sh" || bad "selected suites only" "rc=$rc args='$(cat "$PA_ARGS" 2>&1)' $(cat "$tmp/err")"
[ "$(lines)" -eq 1 ] && ok "a selected-only pass records nothing" || bad "selected-only pass records nothing" "ledger lines: $(lines)"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
[ -e "$PA_MARK" ] && ok "with no run history, the same tree is not skipped after a selected-only pass" || bad "not skipped without history" "skipped"
lrun RUNALL_RC=1 PRE_APPLY_OS=Linux
{ [ "$rc" -ne 0 ] && grep -q 'apply ABORTED' "$tmp/err"; } && ok "a failing selected suite aborts the apply" || bad "selected failure aborts" "rc=$rc"
[ "$(lines)" -eq 1 ] && ok "a failing run records nothing" || bad "failing run records nothing" "ledger lines: $(lines)"

echo "== a clean tree this machine already passed (any suites) is not run again"
hist="$st/dotfiles/pre-apply.history"
tree2=$(g rev-parse 'HEAD^{tree}')
keep=1; rm -f "$hist"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
{ [ -e "$PA_MARK" ] && grep -q "^[^ ]* Linux $tree2 1 [0-9]* 0$" "$hist"; } && ok "a selected-only pass runs, and its history line names the tree" || bad "first selected run" "$(cat "$hist" 2>&1)"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
{ [ "$rc" -eq 0 ] && [ ! -e "$PA_MARK" ]; } && ok "the same clean tree again: skipped, no suite run" || bad "same tree skipped" "rc=$rc ran=$([ -e "$PA_MARK" ] && echo yes) $(cat "$tmp/err")"
grep -q "tree $tree2 already passed on Linux at " "$tmp/err" && ok "the line names the tree and when it passed" || bad "skip line" "$(cat "$tmp/err")"
sed -n '$p' "$hist" | grep -Eq "^[0-9T:Z-]+ Linux $tree2 skip [0-9]+ 0$" && ok "the skipped run is in the history, marked skip" || bad "skip history line" "$(cat "$hist")"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
[ ! -e "$PA_MARK" ] && ok "a skip line is not what a later skip rests on, but the earlier pass still is" || bad "third run" "ran"
lrun RUNALL_RC=0 PRE_APPLY_OS=Darwin
[ -e "$PA_MARK" ] && ok "another OS's pass does not count" || bad "per-OS history" "skipped on Darwin"
grep -v ' Darwin ' "$ledger" > "$tmp/ledger.keep"; cat "$tmp/ledger.keep" > "$ledger" # that full run recorded a Darwin pass
rm -f "$hist"
lrun RUNALL_RC=1 PRE_APPLY_OS=Linux
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
[ -e "$PA_MARK" ] && ok "a FAILED run on the same tree is not a pass: it runs" || bad "failed run credited" "skipped"
rm -f "$hist"
echo dirty >> "$tmp/repo/b/one.txt"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
[ -e "$PA_MARK" ] && ok "a dirty tree is never credited, even after a dirty pass" || bad "dirty credited" "skipped"
g checkout -q -- b/one.txt
rm -f "$hist"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
echo 3 > "$tmp/repo/a/one.txt"; g add -A; g commit -q -m other
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
[ -e "$PA_MARK" ] && ok "a different tree runs" || bad "different tree" "skipped"
g reset -q --hard HEAD~1
keep=0

echo "== the working tree is what is judged: dirty edits and untracked files count"
echo dirty >> "$tmp/repo/b/one.txt"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
{ [ "$(cat "$PA_ARGS" 2>/dev/null)" = "--only test-a.sh test-b.sh" ]; } && ok "a dirty edit under b/ adds test-b.sh" || bad "dirty edit selected" "args='$(cat "$PA_ARGS" 2>&1)'"
g checkout -q -- b/one.txt
echo new > "$tmp/repo/b/new.txt"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
{ [ "$(cat "$PA_ARGS" 2>/dev/null)" = "--only test-a.sh test-b.sh" ]; } && ok "an untracked file under b/ adds test-b.sh" || bad "untracked file selected" "args='$(cat "$PA_ARGS" 2>&1)'"
rm -f "$tmp/repo/b/new.txt"
[ "$(lines)" -eq 1 ] && ok "a dirty tree records nothing" || bad "dirty tree records nothing" "ledger lines: $(lines)"

echo "== a base whose tree is gone is passed over; an unusable ledger runs every suite"
printf '%s Linux 2099-01-01T00:00:00Z\n' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef >> "$ledger"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
[ "$(cat "$PA_ARGS" 2>/dev/null)" = "--only test-a.sh" ] && ok "the newest entry whose tree exists is the base" || bad "skips a gone tree" "args='$(cat "$PA_ARGS" 2>&1)' $(cat "$tmp/err")"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux SELECT_RC=1
{ [ -e "$PA_MARK" ] && [ "$(cat "$PA_ARGS")" = "" ] && grep -q 'selector failed' "$tmp/err"; } && ok "a failing selector runs every suite" || bad "selector failure runs all" "args='$(cat "$PA_ARGS" 2>&1)' $(cat "$tmp/err")"
printf '%s Linux 2000-01-01T00:00:00Z\n' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef > "$ledger"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
{ [ -e "$PA_MARK" ] && [ "$(cat "$PA_ARGS")" = "" ]; } && ok "a ledger with only gone trees runs every suite" || bad "gone trees run all" "args='$(cat "$PA_ARGS" 2>&1)'"

echo "== an empty selection passes without running anything"
g checkout -q -- . 2>/dev/null
printf '%s Linux 2000-01-01T00:00:00Z\n' "$(g rev-parse 'HEAD^{tree}')" > "$ledger"
echo 2 > "$tmp/repo/docs/note.txt"; g add -A; g commit -q -m three
lrun RUNALL_RC=1 PRE_APPLY_OS=Linux
{ [ "$rc" -eq 0 ] && [ ! -e "$PA_MARK" ] && grep -q 'no suite reads the changed paths' "$tmp/err"; } && ok "no suite reads the change: exit 0, nothing run, says so" || bad "empty selection passes" "rc=$rc ran=$([ -e "$PA_MARK" ] && echo yes) $(cat "$tmp/err")"

echo "== macOS shares the ledger shape: a full pass records, the tree is then skipped"
rm -f "$ledger"
lrun RUNALL_RC=0 PRE_APPLY_OS=Darwin
{ [ -e "$PA_MARK" ] && grep -q " Darwin " "$ledger"; } && ok "a macOS full pass records the tree" || bad "macOS records" "ran=$([ -e "$PA_MARK" ] && echo yes) ledger: $(cat "$ledger" 2>&1)"
lrun RUNALL_RC=0 PRE_APPLY_OS=Darwin
{ [ "$rc" -eq 0 ] && [ ! -e "$PA_MARK" ]; } && ok "macOS skips a tree that already passed" || bad "macOS skip" "rc=$rc"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
[ -e "$PA_MARK" ] && ok "a macOS entry does not vouch for Linux" || bad "per-OS ledger" "skipped on Linux"

echo "== DOTFILES_SKIP_PRE_APPLY=1 skips, loudly, for an apply the suites themselves depend on"
run "$tmp/bin" RUNALL_RC=1 PRE_APPLY_OS=Linux DOTFILES_SKIP_PRE_APPLY=1
[ "$rc" -eq 0 ] && ok "exit 0 with the skip set" || bad "exit 0 with the skip set" "rc=$rc"
grep -q "SKIPPED by DOTFILES_SKIP_PRE_APPLY" "$tmp/err" && ok "says it was skipped, and by what" || bad "names the skip" "$(cat "$tmp/err")"
[ ! -e "$PA_MARK" ] && ok "runs no suite when skipped" || bad "runs no suite when skipped" "the runner ran"

echo "== each run is recorded: one history line, and the per-suite profile path handed to run-all"
rm -rf "$st"
run "$tmp/bin" RUNALL_RC=1 PRE_APPLY_OS=Linux
run "$tmp/bin" RUNALL_RC=0 PRE_APPLY_OS=Linux
h="$st/dotfiles/pre-apply.history"
[ "$(wc -l < "$h" 2>/dev/null | tr -d ' ')" = 2 ] && ok "one history line per run" || bad "history lines" "$(cat "$h" 2>/dev/null)"
sed -n 1p "$h" | grep -Eq '^[0-9T:Z-]+ Linux [^ ]+ all [0-9]+ 1$' && ok "a failed run's line: time, OS, tree, all, seconds, exit 1" || bad "failed run line" "$(sed -n 1p "$h")"
sed -n 2p "$h" | grep -Eq ' 0$' && ok "a passing run's line ends in exit 0" || bad "passing run line" "$(sed -n 2p "$h")"
[ "$(cat "$PA_PROF")" = "$st/dotfiles/pre-apply.last-profile.tsv" ] && ok "run-all gets RUN_ALL_PROFILE in the state directory" || bad "profile path" "$(cat "$PA_PROF")"
# A state directory that cannot be written loses the record, never the apply.
: > "$tmp/notadir"
env PATH="$tmp/bin" TMPDIR="$tmp/logs" XDG_STATE_HOME="$tmp/notadir" RUNALL_RC=0 PRE_APPLY_OS=Linux sh "$tmp/tests/pre-apply.sh" > "$tmp/out" 2> "$tmp/err"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$(cat "$PA_PROF")" ]; } && ok "an unwritable state directory: the apply passes, no profile" || bad "unwritable state" "rc=$rc prof=$(cat "$PA_PROF") $(cat "$tmp/err")"

echo "== .chezmoi.toml.tmpl renders the hook"
if command -v chezmoi >/dev/null 2>&1; then
  printf '[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n' > "$tmp/old.toml"
  cfg=$(chezmoi --config "$tmp/old.toml" --source "$src" --persistent-state "$tmp/s.db" \
    execute-template --init --no-tty < "$src/.chezmoi.toml.tmpl" 2>&1)
  printf '%s\n' "$cfg" | grep -qx '\[hooks\.apply\.pre\]' && ok "a [hooks.apply.pre] table" || bad "hook table" "$cfg"
  printf '%s\n' "$cfg" | grep -qx '    command = "sh"' && ok "run with sh" || bad "command sh" "$cfg"
  printf '%s\n' "$cfg" | grep -qxF "    args = [\"$src/tests/pre-apply.sh\"]" && ok "pointing at this source's tests/pre-apply.sh" || bad "args" "$cfg"
else
  echo "  SKIP  chezmoi not installed, the template is not rendered"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
