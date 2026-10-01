#!/bin/sh
# Test run-repo-gates and the configured-hook entries shipped in the base dot_gitconfig.
#
# Every case MANUFACTURES the condition it names and asserts the observable result: whether the
# repository's planted gate ran (it writes a marker file) and the runner's exit status. A runner
# that never runs anything, or runs everything, fails at least one case below.
#
# The last block drives real git: a scratch global config rebuilt from the SHIPPED entries, and
# `git hook run` with core.hooksPath pointed at an empty directory, so only the CONFIGURED hooks can
# answer. That proves the leak-guard entries refuse a planted marker, and that a gate which git
# already runs natively is run once, not twice.
#
# The fleet record and the guard's pattern files are fixtures under a temp $HOME: nothing here reads
# the machine's real ones. Builds throwaway repositories; no network. Needs git 2.54+ for the
# configured-hook cases.
set -u
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
base=$(cd "$here/.." && pwd)
runner="$base/private_dot_local/bin/executable_run-repo-gates"
guard="$base/private_dot_local/bin/executable_leak-guard"
tmp=$(mktemp -d "$_TMP/test-run-repo-gates.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
# Shut out the caller's global git config: its configured hooks would otherwise answer for the
# fixture repositories. Cases that need configured hooks set their own GIT_CONFIG_GLOBAL.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fails=0

ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

# The fleet-decl under test is the SOURCE copy, never a deployed one (which can predate it).
mkdir -p "$tmp/srcbin"
[ -f "$base/private_dot_local/bin/executable_fleet-decl" ] || { bad "fleet-decl source" "missing under $base"; exit 1; }
ln -sf "$base/private_dot_local/bin/executable_fleet-decl" "$tmp/srcbin/fleet-decl"
PATH="$tmp/srcbin:$PATH"; export PATH

# --- fixtures: a manifest and the repositories it names ------------------------------------------
root="$tmp/fleet"; mkdir -p "$root"
FLEET_DEVEL_ROOT=$root; FLEET_RECORD="$tmp/mani.yaml"; export FLEET_DEVEL_ROOT FLEET_RECORD
cat > "$FLEET_RECORD" <<'YAML'
projects:
  ours:
    path: work/ours
    scope: work/ours
    tags: [first-party, active]
  notags:
    path: work/notags
    scope: work/notags
  pkg:
    path: vendor/pkg
    scope: vendor/pkg
    tags: [vendor, packaging]
  up:
    path: vendor/up
    scope: vendor/up
    tags: [vendor, upstream]
  js:
    path: work/js
    scope: work/js
    tags: [first-party]
  husk:
    path: work/husk
    scope: work/husk
    tags: [first-party]
YAML

mkrepo() { # <path under root> -> creates a repo whose .githooks/<event> records that it ran
  d="$root/$1"; mkdir -p "$d/.githooks"; git init -q "$d"
  for e in pre-commit commit-msg pre-push; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/ran"\nwhile IFS= read -r l; do echo "stdin $l" >> "%s/ran"; done\n[ -f "%s/fail" ] && exit 1\nexit 0\n' \
      "$e" "$d" "$d" "$d" > "$d/.githooks/$e"
  done
}
for r in work/ours work/notags vendor/pkg vendor/up work/js; do mkrepo "$r"; done
mkdir -p "$root/work/stranger/.githooks"; git init -q "$root/work/stranger"
printf '#!/bin/sh\ntouch ran\n' > "$root/work/stranger/.githooks/pre-commit"

run() { # <repo dir> <args...> -> sets rc; runs the runner from inside the repo as git does
  d=$1; shift; rm -f "$d/ran"
  (cd "$d" && sh "$runner" "$@" </dev/null >"$tmp/out" 2>&1); rc=$?
}
ran() { [ -f "$1/ran" ]; }

echo "== run-repo-gates"
run "$root/work/ours" pre-commit
{ ran "$root/work/ours" && [ $rc = 0 ]; } && ok "declared repo: gate runs" || bad "declared repo: gate runs" "rc=$rc ran=$(ran "$root/work/ours" && echo y || echo n)"

touch "$root/work/ours/fail"; run "$root/work/ours" pre-commit; rm -f "$root/work/ours/fail"
[ $rc != 0 ] && ok "declared repo: a failing gate refuses (rc=$rc)" || bad "failing gate refuses" "rc=$rc"

run "$root/work/notags" pre-commit
ran "$root/work/notags" && ok "listed repo with no tags: gate runs" || bad "listed repo with no tags: gate runs" "not run; $(cat "$tmp/out")"

run "$root/vendor/pkg" pre-commit
ran "$root/vendor/pkg" && ok "tagged vendor (our packaging): gate runs" || bad "vendor packaging runs" "not run; $(cat "$tmp/out")"

run "$root/vendor/up" pre-commit
{ ! ran "$root/vendor/up" && [ $rc = 0 ] && grep -q upstream "$tmp/out"; } && ok "tagged upstream: not run, says so, rc=0" || bad "upstream not run" "rc=$rc out=$(cat "$tmp/out")"

run "$root/work/stranger" pre-commit
{ [ ! -f "$root/work/stranger/ran" ] && [ $rc = 0 ] && grep -q 'not in the fleet manifest' "$tmp/out"; } && ok "not in manifest: not run, says so" || bad "not in manifest" "rc=$rc out=$(cat "$tmp/out")"

run "$root/work/ours" post-merge
{ [ $rc = 0 ] && [ ! -s "$tmp/out" ]; } && ok "no .githooks/<event>: silent, rc=0" || bad "absent event silent" "rc=$rc out=$(cat "$tmp/out")"

HUSKY=0; export HUSKY; run "$root/work/ours" pre-commit; unset HUSKY
! ran "$root/work/ours" && ok "HUSKY=0: skipped" || bad "HUSKY=0 skipped" "gate ran"

run "$root/work/ours" commit-msg .git/COMMIT_EDITMSG
grep -q 'commit-msg .git/COMMIT_EDITMSG' "$root/work/ours/ran" 2>/dev/null && ok "arguments passed through" || bad "arguments passed" "$(cat "$root/work/ours/ran" 2>/dev/null)"

rm -f "$root/work/ours/ran"
(cd "$root/work/ours" && printf 'refs/heads/x abc refs/heads/x def\n' | sh "$runner" pre-push origin url >/dev/null 2>&1)
grep -q 'stdin refs/heads/x abc' "$root/work/ours/ran" 2>/dev/null && ok "stdin passed through (pre-push)" || bad "stdin passed" "$(cat "$root/work/ours/ran" 2>/dev/null)"

printf '{}\n' > "$root/work/js/package.json"
run "$root/work/js" pre-commit
{ ! ran "$root/work/js" && [ $rc = 0 ] && grep -q node_modules "$tmp/out"; } && ok "package.json without node_modules: warned and skipped" || bad "no node_modules skip" "rc=$rc out=$(cat "$tmp/out")"
mkdir -p "$root/work/js/node_modules/.bin"
printf '#!/bin/sh\necho from-node-bin >> "%s/ran"\n' "$root/work/js" > "$root/work/js/node_modules/.bin/jstool"
chmod +x "$root/work/js/node_modules/.bin/jstool"
printf '#!/bin/sh\njstool\n' > "$root/work/js/.githooks/pre-commit"
run "$root/work/js" pre-commit
grep -q from-node-bin "$root/work/js/ran" 2>/dev/null && ok "node_modules/.bin is on PATH" || bad "node_modules/.bin on PATH" "rc=$rc out=$(cat "$tmp/out")"

# .husky/<event>: the older name for the same contract, used when .githooks/<event> is absent.
h="$root/work/ours"; mv "$h/.githooks" "$h/.githooks.off"; mkdir -p "$h/.husky"
printf '#!/bin/sh\necho husky-ran >> "%s/ran"\n' "$h" > "$h/.husky/pre-commit"
run "$h" pre-commit
grep -q husky-ran "$h/ran" 2>/dev/null && ok ".husky/<event> runs when .githooks/ is absent" || bad ".husky fallback" "rc=$rc out=$(cat "$tmp/out")"
mv "$h/.githooks.off" "$h/.githooks"
run "$h" pre-commit
{ grep -q 'pre-commit' "$h/ran" 2>/dev/null && ! grep -q husky-ran "$h/ran"; } && ok ".githooks/ wins over .husky/" || bad ".githooks wins" "$(cat "$h/ran" 2>/dev/null)"
rm -rf "$h/.husky"

# Interpreter. .githooks/: an executable #! file runs under its interpreter (a bash-only construct
# works); a non-executable one runs under `sh -e`. .husky/: ALWAYS `sh -e`, even executable with #!,
# because husky files were written for that and running one directly drops the -e.
h="$root/work/ours"
printf '#!/usr/bin/env bash\nset -e\narr=(a b); [[ ${#arr[@]} -eq 2 ]] && echo bash-ok >> "%s/ran"\n' "$h" > "$h/.githooks/pre-commit"; chmod +x "$h/.githooks/pre-commit"
run "$h" pre-commit
grep -q bash-ok "$h/ran" 2>/dev/null && ok ".githooks: executable #! file runs under its interpreter" || bad "#! honoured" "rc=$rc out=$(cat "$tmp/out")"
printf '#!/bin/sh\nfalse\necho reached >> "%s/ran"\n' "$h" > "$h/.githooks/pre-commit"; chmod -x "$h/.githooks/pre-commit"
run "$h" pre-commit
{ [ $rc != 0 ] && ! grep -q reached "$h/ran" 2>/dev/null; } && ok ".githooks: non-executable file runs under sh -e" || bad "non-exec sh -e" "rc=$rc ran=$(cat "$h/ran" 2>/dev/null)"
rm -rf "$h/.githooks"; mkdir -p "$h/.husky"
printf '#!/bin/sh\nfalse\necho reached >> "%s/ran"\n' "$h" > "$h/.husky/pre-commit"; chmod +x "$h/.husky/pre-commit"
run "$h" pre-commit
{ [ $rc != 0 ] && ! grep -q reached "$h/ran" 2>/dev/null; } && ok ".husky: executable #! file still runs under sh -e" || bad ".husky sh -e" "rc=$rc ran=$(cat "$h/ran" 2>/dev/null)"
rm -rf "$h/.husky"
mkrepo work/ours

# A bare container root has no work tree: nothing runs and nothing is printed, since this fires on
# every fetch and gc there.
git init -q --bare "$tmp/bare.git"
(cd "$tmp/bare.git" && sh "$runner" pre-commit </dev/null >"$tmp/out" 2>&1); rc=$?
{ [ $rc = 0 ] && [ ! -s "$tmp/out" ]; } && ok "bare container root: inert and silent" || bad "bare root inert" "rc=$rc out=$(cat "$tmp/out")"

cp "$FLEET_RECORD" "$tmp/good.yaml"; printf 'projects: [unclosed\n' > "$FLEET_RECORD"
run "$root/work/ours" pre-commit
{ ! ran "$root/work/ours" && [ $rc != 0 ]; } && ok "manifest unreadable: refuses, does not run (rc=$rc)" || bad "unreadable manifest refuses" "rc=$rc out=$(cat "$tmp/out")"
cp "$tmp/good.yaml" "$FLEET_RECORD"

# --- git already runs it: the runner defers to the repository's own hooks directory -------------
# When core.hooksPath (husky v9 sets .husky/_) is the gate's directory, or its `_` subdirectory, and
# holds an executable file for the event, git runs the gate natively and the runner must not run it
# a second time. Each deference case has a CONTROL arm that changes one thing and must run the gate;
# a runner that defers always (or never) fails one side.
husk="$root/work/husk"; mkdir -p "$husk/.husky/_"; git init -q "$husk"
printf '#!/bin/sh\necho "husky-gate" >> "%s/ran"\n' "$husk" > "$husk/.husky/pre-commit"
printf '#!/bin/sh\nexit 0\n' > "$husk/.husky/_/pre-commit"; chmod +x "$husk/.husky/_/pre-commit"

git -C "$husk" config core.hooksPath .husky/_
run "$husk" pre-commit
{ ! ran "$husk" && [ $rc = 0 ] && [ ! -s "$tmp/out" ]; } && ok "core.hooksPath=.husky/_ with an executable stub: deferred, gate not run, silent" || bad "husky defers" "rc=$rc ran=$(ran "$husk" && echo y || echo n) out=$(cat "$tmp/out")"

chmod -x "$husk/.husky/_/pre-commit"
run "$husk" pre-commit
{ ran "$husk" && [ $rc = 0 ]; } && ok "core.hooksPath=.husky/_ but the stub is not executable: runner runs the gate" || bad "non-executable stub runs gate" "rc=$rc ran=$(ran "$husk" && echo y || echo n)"
chmod +x "$husk/.husky/_/pre-commit"

mv "$husk/.husky/_/pre-commit" "$husk/.husky/_/commit-msg"
run "$husk" pre-commit
{ ran "$husk" && [ $rc = 0 ]; } && ok "hooks directory lacks an executable for THIS event: runner runs the gate" || bad "other-event stub runs gate" "rc=$rc ran=$(ran "$husk" && echo y || echo n)"
mv "$husk/.husky/_/commit-msg" "$husk/.husky/_/pre-commit"

git -C "$husk" config --unset core.hooksPath
run "$husk" pre-commit
{ ran "$husk" && [ $rc = 0 ]; } && ok "no core.hooksPath: the stub is not git's hooks directory, runner runs the gate" || bad "unset hooksPath runs gate" "rc=$rc ran=$(ran "$husk" && echo y || echo n)"

# core.hooksPath=.githooks with an executable gate: git runs it itself.
gh="$root/work/ours"
git -C "$gh" config core.hooksPath .githooks
chmod +x "$gh/.githooks/pre-commit"
run "$gh" pre-commit
{ ! ran "$gh" && [ $rc = 0 ]; } && ok "core.hooksPath=.githooks with an executable gate: deferred" || bad ".githooks defers" "rc=$rc ran=$(ran "$gh" && echo y || echo n)"
chmod -x "$gh/.githooks/pre-commit"
run "$gh" pre-commit
{ ran "$gh" && [ $rc = 0 ]; } && ok "core.hooksPath=.githooks but the gate is not executable (git would skip it): runner runs it" || bad "non-executable .githooks runs" "rc=$rc ran=$(ran "$gh" && echo y || echo n)"

# A hooks directory that is NOT the gate's: its executable hook is somebody else's, so the gate still runs.
mkdir -p "$gh/.other"; printf '#!/bin/sh\nexit 0\n' > "$gh/.other/pre-commit"; chmod +x "$gh/.other/pre-commit"
git -C "$gh" config core.hooksPath .other; chmod +x "$gh/.githooks/pre-commit"
run "$gh" pre-commit
{ ran "$gh" && [ $rc = 0 ]; } && ok "core.hooksPath elsewhere with its own executable hook: runner still runs the gate" || bad "foreign hooksPath runs gate" "rc=$rc ran=$(ran "$gh" && echo y || echo n)"
git -C "$gh" config --unset core.hooksPath; rm -rf "$gh/.other"

# The default hooks directory is not the gate's directory either, however executable its hook.
mkdir -p "$gh/.git/hooks"; printf '#!/bin/sh\nexit 0\n' > "$gh/.git/hooks/pre-commit"; chmod +x "$gh/.git/hooks/pre-commit"
run "$gh" pre-commit
{ ran "$gh" && [ $rc = 0 ]; } && ok "executable .git/hooks/pre-commit does not stand in for a tracked gate" || bad "default hooks dir runs gate" "rc=$rc ran=$(ran "$gh" && echo y || echo n)"
rm -f "$gh/.git/hooks/pre-commit"
mkrepo work/ours

echo "== the shipped configured-hook entries"
shipped="$base/dot_gitconfig"
for e in pre-commit commit-msg pre-push; do
  want="sh \"\$HOME/.local/bin/leak-guard\" $e"
  got=$(git config --file "$shipped" --get "hook.publish-guard-$e.command")
  [ "$got" = "$want" ] && ok "publish-guard-$e reads back intact" || bad "publish-guard-$e command" "got: $got"
  [ "$(git config --file "$shipped" --get-all "hook.publish-guard-$e.event")" = "$e" ] \
    && ok "publish-guard-$e fires on $e" || bad "publish-guard-$e event" "$(git config --file "$shipped" --get-all "hook.publish-guard-$e.event")"
  want="sh \"\$HOME/.local/bin/run-repo-gates\" $e"
  got=$(git config --file "$shipped" --get "hook.repo-gates-$e.command")
  [ "$got" = "$want" ] && ok "repo-gates-$e reads back intact" || bad "repo-gates-$e command" "got: $got"
  [ "$(git config --file "$shipped" --get-all "hook.repo-gates-$e.event")" = "$e" ] \
    && ok "repo-gates-$e fires on $e" || bad "repo-gates-$e event" "$(git config --file "$shipped" --get-all "hook.repo-gates-$e.event")"
done

# Order: every guard entry's `event` line precedes every repo-gates entry's, so the guard runs first.
last_guard=$(grep -n '^\[hook "publish-guard' "$shipped" | tail -1 | cut -d: -f1)
first_gate=$(grep -n '^\[hook "repo-gates' "$shipped" | head -1 | cut -d: -f1)
[ -n "$last_guard" ] && [ -n "$first_gate" ] && [ "$last_guard" -lt "$first_gate" ] \
  && ok "guard entries come before repo-gates entries" || bad "guard first" "last guard line $last_guard, first gate line $first_gate"

echo "== real git: only the configured hooks answer"
case "$(git --version)" in
  "git version 2."[0-4][0-9].*|"git version 2."5[0-3].*|"git version 1."*)
    bad "git 2.54+" "$(git --version) ignores configured hooks; the guard cases cannot run here" ;;
  *)
    # A fixture $HOME: the SOURCE guard and runner under ~/.local/bin, a fixture domain under
    # ~/.dotlocal, and a global config rebuilt from the SHIPPED entries (never the whole base
    # gitconfig, which would pull in its other hooks).
    fh="$tmp/home"; mkdir -p "$fh/.dotlocal" "$fh/.local/bin" "$tmp/nohooks"
    cp "$guard"  "$fh/.local/bin/leak-guard"
    cp "$runner" "$fh/.local/bin/run-repo-gates"
    printf '\\b(ZZP|ZZQ)(-ADR)?-[0-9]+\n' > "$fh/.dotlocal/git-leak-markers"
    printf 'hush-term\n' > "$fh/.dotlocal/git-leak-sensitive"
    printf 'probe-marker=ZZP-9999\n' > "$fh/.dotlocal/git-leak-policy"
    : > "$tmp/gcfg"
    git config --file "$shipped" --get-regexp '^hook\.(publish-guard|repo-gates)-' > "$tmp/shipped-hooks"
    while IFS= read -r line; do git config --file "$tmp/gcfg" --add "${line%% *}" "${line#* }"; done < "$tmp/shipped-hooks"
    g="$root/work/ours"
    probe() { # <msgfile> -> rc of the commit-msg hooks, the repo's own hooks excluded
      (cd "$g" && HOME="$fh" GIT_CONFIG_GLOBAL="$tmp/gcfg" GIT_CONFIG_NOSYSTEM=1 \
        git -c core.hooksPath="$tmp/nohooks" hook run commit-msg -- "$1" </dev/null >"$tmp/out" 2>&1)
    }
    printf 'chore: clean message\n' > "$tmp/clean"
    printf 'chore: planted ZZP-999 marker\n' > "$tmp/plant"
    probe "$tmp/clean"; crc=$?
    probe "$tmp/plant"; prc=$?
    [ $crc = 0 ] && ok "configured guard accepts a clean message" || bad "clean accepted" "rc=$crc $(cat "$tmp/out")"
    [ $prc != 0 ] && grep -q 'leak-guard' "$tmp/out" && ok "configured guard refuses a planted marker (rc=$prc)" \
      || bad "planted refused" "rc=$prc $(cat "$tmp/out")"

    # A gate git runs natively must run ONCE on a real commit. husky's generated stub in `_` runs the
    # project file; the runner, also configured, must leave it to git. The control arm unsets
    # core.hooksPath, so the same gate is reached only through the runner: it must still run.
    hk="$root/work/husk"; : > "$hk/ran"
    printf '#!/bin/sh\nsh -e "%s/.husky/pre-commit"\n' "$hk" > "$hk/.husky/_/pre-commit"; chmod +x "$hk/.husky/_/pre-commit"
    git -C "$hk" config core.hooksPath .husky/_
    printf 'x\n' > "$hk/f.txt"; git -C "$hk" add f.txt
    HOME="$fh" GIT_CONFIG_GLOBAL="$tmp/gcfg" GIT_CONFIG_NOSYSTEM=1 git -C "$hk" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m one >"$tmp/out" 2>&1
    n=$(grep -c husky-gate "$hk/ran")
    [ "$n" = 1 ] && ok "native husky gate on a real commit: ran exactly once" || bad "husky gate ran $n times" "$(cat "$tmp/out")"
    : > "$hk/ran"; git -C "$hk" config --unset core.hooksPath; rm -rf "$hk/.husky/_"
    printf 'y\n' > "$hk/f.txt"; git -C "$hk" add f.txt
    HOME="$fh" GIT_CONFIG_GLOBAL="$tmp/gcfg" GIT_CONFIG_NOSYSTEM=1 git -C "$hk" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m two >"$tmp/out" 2>&1
    n=$(grep -c husky-gate "$hk/ran")
    [ "$n" = 1 ] && ok "same gate without core.hooksPath: run once, by the runner" || bad "runner-only gate ran $n times" "$(cat "$tmp/out")"
    ;;
esac

[ "$fails" = 0 ] && { echo "PASS"; exit 0; }
echo "FAILED: $fails"; exit 1
