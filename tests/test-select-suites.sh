#!/bin/sh
# Tests for tests/select-suites.sh, which picks the suites a commit's staged paths can break, and for
# tests/coverage.map, the map it reads.
#
# Two halves. The REAL map: it covers every tracked file (--check), and a leaf tool, a shared-core
# file, an unclaimed path and an exempt path select what they should. A FIXTURE repository: each
# finding --check exists for is planted there and must be refused, so the check is seen to fail on
# the defect it names, not only to pass on a clean tree.
set -u
here=$(cd "$(dirname "$0")" && pwd)
sel="$here/select-suites.sh"
t=${TMPDIR:-/tmp}; t=${t%/}
tmp=$(mktemp -d "$t/test-select-suites.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }
has()  { printf '%s\n' "$2" | grep -qx -- "$3" && ok "$1" || bad "$1" "no line '$3' in: $(printf '%s' "$2" | tr '\n' ' ')"; }
lacks() { printf '%s\n' "$2" | grep -qx -- "$3" && bad "$1" "'$3' was selected" || ok "$1"; }
pick() { printf '%s\n' "$@" | sh "$sel" 2> "$tmp/why"; }
nsuites=$(ls "$here"/test-*.sh "$here"/test-*.py 2>/dev/null | wc -l | tr -d ' ')

echo "== the real map"
if out=$(sh "$sel" --check 2>&1); then ok "--check: the map covers every tracked file"; else bad "--check on this tree" "$out"; fi

out=$(pick private_dot_local/bin/executable_hc-status)
has "a leaf tool selects its suite" "$out" test-hc-status.sh
for w in test-shell-parse.sh test-python39-syntax.sh test-portability-lint.sh test-tooling-inventory.sh test-repo-hygiene.sh test-select-suites.sh; do
  has "a leaf tool selects the whole-tree check $w" "$out" "$w"
done
lacks "a leaf tool does not select an unrelated suite" "$out" test-overlay-doctor.sh
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -lt "$nsuites" ] && ok "a leaf tool selects fewer than every suite" || bad "fewer than all" "$(cat "$tmp/why")"

out=$(pick tests/git-isolate.sh)
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq "$nsuites" ] && ok "a shared-core file selects every suite" || bad "core selects all" "$(cat "$tmp/why")"
grep -q 'shared core' "$tmp/why" && ok "...and says why" || bad "core: why" "$(cat "$tmp/why")"

out=$(pick private_dot_local/bin/executable_hc-status a-path-nothing-claims)
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq "$nsuites" ] && ok "a path no suite claims selects every suite" || bad "unclaimed selects all" "$(cat "$tmp/why")"
grep -q 'a-path-nothing-claims is claimed by no suite' "$tmp/why" && ok "...and names the path" || bad "unclaimed: why" "$(cat "$tmp/why")"

out=$(pick dot_config/sway/config)
has "an exempt path still runs the tree check that reads it" "$out" test-repo-hygiene.sh
lacks "an exempt path selects no suite of its own" "$out" test-hc-status.sh
out=$(pick tests/test-kb.sh)
has "a staged suite selects itself" "$out" test-kb.sh

echo "== the check, on a fixture repository with each defect planted"
r="$tmp/repo"; mkdir -p "$r/tests" "$r/bin" "$r/skip"
cp "$sel" "$r/tests/select-suites.sh"
# The stand-in runner echoes its arguments; given RUN_ALL_PROFILE it also writes the profile run-all
# would (suite, wall, cpu, exit), one line per suite named after --only, exiting RUNALL_RC.
cat > "$r/tests/run-all.sh" <<'EOF'
#!/bin/sh
echo "run-all $*"
rc=${RUNALL_RC:-0}
if [ -n "${RUN_ALL_PROFILE:-}" ]; then
  shift
  for n in "$@"; do printf '%s\t0.1\t0.1\t%s\n' "$n" "$rc"; done > "$RUN_ALL_PROFILE"
fi
exit "$rc"
EOF
printf '#!/bin/sh\n# reads bin/a\nexit 0\n' > "$r/tests/test-a.sh"
printf '#!/bin/sh\nexit 0\n' > "$r/tests/test-b.sh"
echo a > "$r/bin/a"; echo b > "$r/bin/b"; echo c > "$r/core.sh"; echo s > "$r/skip/x"
cat > "$r/tests/coverage.map" <<'EOF'
core   core.sh tests/select-suites.sh tests/run-all.sh
test-a.sh  bin/a
test-b.sh  bin/b tests/coverage.map
exempt skip/**
EOF
git init -q "$r" && git -C "$r" add -A
check() { (cd "$r" && sh tests/select-suites.sh --check > "$tmp/out" 2>&1); echo $?; }
[ "$(check)" = 0 ] && ok "fixture: a covered tree passes" || bad "fixture passes" "$(cat "$tmp/out")"

echo new > "$r/bin/new"; git -C "$r" add bin/new
[ "$(check)" = 1 ] && grep -q 'unclaimed: bin/new' "$tmp/out" && ok "plant: a tracked file nothing claims is refused" || bad "unclaimed refused" "$(cat "$tmp/out")"
git -C "$r" rm -q --cached bin/new; rm "$r/bin/new"

printf '#!/bin/sh\nexit 0\n' > "$r/tests/test-c.sh"; git -C "$r" add tests/test-c.sh
[ "$(check)" = 1 ] && grep -q 'no line: test-c.sh' "$tmp/out" && ok "plant: a suite with no line is refused" || bad "no line refused" "$(cat "$tmp/out")"
git -C "$r" rm -q --cached tests/test-c.sh; rm "$r/tests/test-c.sh"

cp "$r/tests/coverage.map" "$tmp/map"
echo 'test-a.sh  bin/renamed-away' >> "$r/tests/coverage.map"
[ "$(check)" = 1 ] && grep -q 'dead glob: .*bin/renamed-away' "$tmp/out" && ok "plant: a glob that matches nothing is refused" || bad "dead glob refused" "$(cat "$tmp/out")"
cp "$tmp/map" "$r/tests/coverage.map"

printf '#!/bin/sh\ncat "$here/../bin/b"\n' >> "$r/tests/test-a.sh"
[ "$(check)" = 1 ] && grep -q 'test-a.sh names bin/b but does not claim it' "$tmp/out" && ok "plant: a suite naming a path it does not claim is refused" || bad "unclaimed read refused" "$(cat "$tmp/out")"
echo 'refs test-a.sh bin/b' >> "$r/tests/coverage.map"
[ "$(check)" = 0 ] && ok "...and a refs line for fixture text clears it" || bad "refs clears it" "$(cat "$tmp/out")"
cp "$tmp/map" "$r/tests/coverage.map"; printf '#!/bin/sh\n# reads bin/a\nexit 0\n' > "$r/tests/test-a.sh"

echo 'test-gone.sh bin/a' >> "$r/tests/coverage.map"
[ "$(check)" = 2 ] && grep -q 'names no suite in tests/: test-gone.sh' "$tmp/out" && ok "a line naming a missing suite is a map error (exit 2)" || bad "missing suite" "$(cat "$tmp/out")"
out=$(printf 'bin/a\n' | (cd "$r" && sh tests/select-suites.sh 2>&1)); rc=$?
[ "$rc" = 2 ] && ok "...and selection refuses rather than guess" || bad "selection on a broken map" "rc=$rc $out"
cp "$tmp/map" "$r/tests/coverage.map"
[ "$(check)" = 0 ] && ok "fixture: clean again after every plant is reverted" || bad "fixture clean again" "$(cat "$tmp/out")"

echo "== globs and --run, on the fixture"
echo 'test-a.sh  one/*' >> "$r/tests/coverage.map"
out=$(printf 'one/x\n' | (cd "$r" && sh tests/select-suites.sh 2>/dev/null))
has "\`*\` matches within a directory" "$out" test-a.sh
out=$(printf 'one/deep/x\n' | (cd "$r" && sh tests/select-suites.sh 2>/dev/null))
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] && ok "\`*\` does not cross a \`/\` (one/deep/x is unclaimed: every suite)" || bad "* crossing /" "$out"
cp "$tmp/map" "$r/tests/coverage.map"
out=$(printf 'bin/a\n' | (cd "$r" && sh tests/select-suites.sh --run 2>/dev/null))
[ "$out" = "run-all --only test-a.sh" ] && ok "--run hands run-all.sh exactly the selection" || bad "--run" "$out"
out=$(printf 'skip/x\n' | (cd "$r" && sh tests/select-suites.sh --run 2>&1)); rc=$?
{ [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q run-all; } && ok "--run with nothing selected runs nothing, exit 0" || bad "--run empty" "rc=$rc $out"

echo "== the commit gate's pass credit: SUITE_CREDIT_RECORD=1 --run records what passed"
# One line per suite that passed, `<tree> <os> <suite> <utc time>`, in a machine-local file under the
# state directory, against the tree git would commit (git write-tree).
st="$tmp/state"; gl="$st/dotfiles/gate-passed"
credrun() { # credrun [VAR=value ...]: select bin/a (test-a.sh) and run it, recording as the commit gate does
  printf 'bin/a\n' | (cd "$r" && env XDG_STATE_HOME="$st" SUITE_CREDIT_OS=Linux "$@" sh tests/select-suites.sh --run > "$tmp/out" 2>&1)
}
tree=$(git -C "$r" write-tree)
credrun
[ ! -e "$gl" ] && ok "without SUITE_CREDIT_RECORD nothing is recorded (a hand run is not the gate)" || bad "hand run recorded" "$(cat "$gl")"
credrun SUITE_CREDIT_RECORD=1 RUNALL_RC=1
[ ! -e "$gl" ] && ok "a FAILED run records nothing" || bad "failed run recorded" "$(cat "$gl")"
credrun SUITE_CREDIT_RECORD=1
grep -Eq "^$tree Linux test-a.sh [0-9T:Z-]+$" "$gl" 2>/dev/null && ok "a passing run records the staged tree, the OS and each suite" || bad "passing run recorded" "$(cat "$gl" 2>&1)"
[ "$(wc -l < "$gl" | tr -d ' ')" = 1 ] && ok "only the suites selected (test-a.sh) are recorded" || bad "only the selection" "$(cat "$gl")"
grep -q '^run-all --only test-a.sh$' "$tmp/out" && ok "the run's output still passes through" || bad "output passes through" "$(cat "$tmp/out")"
mkdir -p "$st/dotfiles"; i=0; while [ "$i" -lt 1100 ]; do printf 'oldtree%s Linux test-a.sh 2000-01-01T00:00:00Z\n' "$i"; i=$((i + 1)); done > "$gl"
credrun SUITE_CREDIT_RECORD=1
n=$(wc -l < "$gl" | tr -d ' ')
{ [ "$n" -le 1000 ] && grep -q "^$tree Linux test-a.sh " "$gl" && ! grep -q '^oldtree0 ' "$gl" && grep -q '^oldtree1099 ' "$gl"; } && ok "the ledger is bounded to its newest 1000 lines" || bad "ledger bound" "lines=$n"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
