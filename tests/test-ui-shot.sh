#!/bin/sh
# Tests for ui-shot.
#
# The refusal and the failure paths are the load-bearing cases. A capture tool that silently
# degrades -- falls back to a global Playwright, or quietly opens a window -- is worse than one
# that is absent, because its output still looks like evidence.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
TOOL="$here/../private_dot_local/bin/executable_ui-shot"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
pass=0

st() { # st <want> <desc> -- run remaining args, compare exit status
  _w=$1; _desc=$2; shift 2
  if "$@" >/dev/null 2>&1; then _g=0; else _g=$?; fi
  [ "$_g" -eq "$_w" ] || { echo "FAIL: $_desc (want exit $_w, got $_g)"; exit 1; }
  echo "ok:   $_desc"; pass=$((pass+1))
}

# There is deliberately no --headed. Asserting the REFUSAL rather than the absence, because a
# silently-ignored flag would leave the caller believing they had a headed run.
st 2 "--headed is refused, not ignored"    sh "$TOOL" "file:///dev/null" --headed
st 2 "--ui is refused"                     sh "$TOOL" "file:///dev/null" --ui
st 2 "--debug is refused"                  sh "$TOOL" "file:///dev/null" --debug
st 2 "a missing URL is an error"           sh "$TOOL"
st 2 "an unknown option is an error"       sh "$TOOL" "file:///dev/null" --nope

out=$(sh "$TOOL" "file:///dev/null" --headed 2>&1 || true)
case "$out" in *"interrupts whoever is at the keyboard"*) ;; *) echo "FAIL: refusal does not say WHY"; exit 1 ;; esac
echo "ok:   the refusal explains the reason, not just the rule"; pass=$((pass+1))

# No project-local Playwright must FAIL, never fall back to a global install: the project's
# version is the one whose browsers are downloaded and whose behaviour matches its tests.
_cwd=$(pwd); cd "$d"
st 1 "no project Playwright fails loudly" sh "$TOOL" "file:///dev/null"
out=$(sh "$TOOL" "file:///dev/null" 2>&1 || true); cd "$_cwd"
case "$out" in *"rather than globally"*) ;; *) echo "FAIL: does not say to install project-locally"; exit 1 ;; esac
echo "ok:   names the fix (install project-locally)"; pass=$((pass+1))

grep -q 'headless' "$TOOL" || { echo "FAIL: no headless guarantee in the tool"; exit 1; }
grep -q 'deviceScaleFactor' "$TOOL" || { echo "FAIL: native-scale capture regressed -- a scaled crop cannot show a 1px border"; exit 1; }
echo "ok:   still captures at native scale (deviceScaleFactor)"; pass=$((pass+1))

# Count what actually ran. A harness that reports a number it did not derive is the same defect
# class as everything this suite is guarding against.
printf '\n%d passed\n' "$pass"
