#!/bin/sh
# Tests for tests/pre-apply.sh, the base's `chezmoi apply` pre hook: every suite runs before an
# apply, a failure aborts it naming the suite and how to see why, and a machine without the tools
# the suites need skips loudly rather than failing its first apply. Also that .chezmoi.toml.tmpl
# renders the hook pointing at this script.
#
# The script is copied beside a stand-in run-all.sh in a scratch tests/ directory, and run under a
# PATH holding stand-ins for the tools it requires, so no suite and no real apply runs.
set -u
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
env | grep '^CHEZMOI' > "$PA_ENV" || true
echo "PASS   test-good.sh"
[ "${RUNALL_RC:-0}" = 0 ] || { echo "FAIL   test-broken.sh (exit 1)"; echo "       | the reason it failed"; }
printf '\n2 suite(s): 1 passed, %s failed\n' "$([ "${RUNALL_RC:-0}" = 0 ] && echo 0 || echo 1)"
exit "${RUNALL_RC:-0}"
EOF
# Utilities the script uses, from this machine; the tools it requires, as stand-ins.
for u in sh env sed grep mktemp tail cat rm dirname; do
  p=$(command -v "$u") || { bad "$u on PATH" "the test needs it"; exit 1; }
  ln -s "$p" "$tmp/bin/$u"; ln -s "$p" "$tmp/nouv/$u"
done
for r in git python3 uv jq yq gitleaks wt; do
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$r"; chmod +x "$tmp/bin/$r"
  [ "$r" = uv ] || ln -s "$tmp/bin/$r" "$tmp/nouv/$r"
done
export PA_MARK="$tmp/ran" PA_ENV="$tmp/env"
run() { # run <PATH dir> [VAR=value ...]: the script's exit code in $rc, its stderr in $tmp/err
  d=$1; shift; rm -f "$PA_MARK"
  env PATH="$d" TMPDIR="$tmp/logs" "$@" sh "$tmp/tests/pre-apply.sh" > "$tmp/out" 2> "$tmp/err"; rc=$?
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

echo "== on macOS a failing suite is reported loudly and does not abort the apply (not yet gating)"
rm -f "$tmp/logs"/*
run "$tmp/bin" RUNALL_RC=1 PRE_APPLY_OS=Darwin
[ "$rc" -eq 0 ] && ok "exit 0 on macOS" || bad "exit 0 on macOS" "rc=$rc $(cat "$tmp/err")"
grep -q 'NOT gating on macOS' "$tmp/err" && ok "says it is not gating, and why" || bad "not gating" "$(cat "$tmp/err")"
grep -q 'FAIL   test-broken.sh' "$tmp/err" && ok "still names the failing suite" || bad "names the suite" "$(cat "$tmp/err")"

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
cp "$tmp/tests/pre-apply.sh" "$tmp/tests/run-all.sh" "$tmp/repo/tests/"
g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$realgit" -C "$tmp/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q && g add -A && g commit -q -m one
ledger="$(cd "$tmp/repo" && GIT_CONFIG_GLOBAL=/dev/null "$realgit" rev-parse --absolute-git-dir)/pre-apply/passed"
lrun() { # lrun [VAR=value ...]: run the repository's copy; rc and $tmp/err as run()
  rm -f "$PA_MARK"
  env PATH="$tmp/gitbin" TMPDIR="$tmp/logs" GIT_CONFIG_GLOBAL=/dev/null "$@" sh "$tmp/repo/tests/pre-apply.sh" > "$tmp/out" 2> "$tmp/err"; rc=$?
}
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
{ [ "$rc" -eq 0 ] && [ -e "$PA_MARK" ]; } && ok "a first run on a clean tree runs the suites" || bad "first run" "rc=$rc $(cat "$tmp/err")"
tree=$(g rev-parse 'HEAD^{tree}')
grep -q "^$tree Linux " "$ledger" 2>/dev/null && ok "a clean passing run records the tree and OS" || bad "pass recorded" "ledger: $(cat "$ledger" 2>&1)"
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
{ [ "$rc" -eq 0 ] && [ ! -e "$PA_MARK" ]; } && ok "the same tree again is skipped, no suite run" || bad "skip same tree" "rc=$rc ran=$([ -e "$PA_MARK" ] && echo yes)"
grep -q 'already passed on Linux at' "$tmp/err" && ok "says it skipped, and when the tree passed" || bad "skip line" "$(cat "$tmp/err")"
echo two > "$tmp/repo/tests/extra.txt"; g add -A; g commit -q -m two
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
[ -e "$PA_MARK" ] && ok "a changed tree runs the suites again" || bad "changed tree runs" "skipped"
echo dirty >> "$tmp/repo/tests/extra.txt"
before=$(wc -l < "$ledger")
lrun RUNALL_RC=0 PRE_APPLY_OS=Linux
{ [ -e "$PA_MARK" ] && [ "$(wc -l < "$ledger")" -eq "$before" ]; } && ok "a dirty tree runs and records nothing" || bad "dirty tree" "ran=$([ -e "$PA_MARK" ] && echo yes) lines $before -> $(wc -l < "$ledger")"
g checkout -q -- tests/extra.txt
echo three > "$tmp/repo/tests/extra.txt"; g add -A; g commit -q -m three
before=$(wc -l < "$ledger")
lrun RUNALL_RC=1 PRE_APPLY_OS=Linux
{ [ "$rc" -ne 0 ] && [ "$(wc -l < "$ledger")" -eq "$before" ]; } && ok "a failing run records nothing" || bad "failing run records nothing" "rc=$rc lines $before -> $(wc -l < "$ledger")"
lrun RUNALL_RC=0 PRE_APPLY_OS=Darwin
lrun RUNALL_RC=0 PRE_APPLY_OS=Darwin
{ [ -e "$PA_MARK" ] && ! grep -q ' Darwin ' "$ledger"; } && ok "macOS, not yet gating, records nothing and always runs" || bad "macOS records nothing" "ran=$([ -e "$PA_MARK" ] && echo yes) $(grep Darwin "$ledger")"

echo "== DOTFILES_SKIP_PRE_APPLY=1 skips, loudly, for an apply the suites themselves depend on"
run "$tmp/bin" RUNALL_RC=1 PRE_APPLY_OS=Linux DOTFILES_SKIP_PRE_APPLY=1
[ "$rc" -eq 0 ] && ok "exit 0 with the skip set" || bad "exit 0 with the skip set" "rc=$rc"
grep -q "SKIPPED by DOTFILES_SKIP_PRE_APPLY" "$tmp/err" && ok "says it was skipped, and by what" || bad "names the skip" "$(cat "$tmp/err")"
[ ! -e "$PA_MARK" ] && ok "runs no suite when skipped" || bad "runs no suite when skipped" "the runner ran"

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
