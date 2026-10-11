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
# ---------- a selector that matches nothing must FAIL ----------
# The crop is the entire product. A selector typo is the likeliest single mistake here, and on
# exit 0 it leaves the reviewer holding only the full-page shot -- which is the scaled-down false
# confidence this tool exists to remove. It would fail back INTO the original bug, quietly,
# reporting success. Found validating against real pages, 2026-08-30.
grep -q 'missed > 0' "$TOOL" \
  || { echo "FAIL: a no-match selector no longer fails the run"; exit 1; }
echo "ok:   a --selector matching nothing is a failure, not a note"; pass=$((pass+1))

grep -q 'colorScheme' "$TOOL" \
  || { echo "FAIL: no prefers-color-scheme emulation"; exit 1; }
echo "ok:   can render under a prefers-color-scheme condition"; pass=$((pass+1))

# Functional, against a STUB playwright module rather than a real browser. Source greps above
# cannot show that the exit code actually changes; this can. The stub stands in for Playwright's
# API only: what is under test is ui-shot's own logic (finding the project's install, the
# no-match failure, the options it passes), not Playwright's rendering, which every real use
# exercises. The suite used to borrow the first project install under ~/Devel instead, and failed
# once that was a moved checkout whose browsers Playwright had garbage-collected (2026-10-11).
if command -v node >/dev/null 2>&1; then
  proj="$d/proj"; mkdir -p "$proj/node_modules/playwright"
  cat > "$proj/node_modules/playwright/index.js" <<'STUB'
// Stub: a page holds one element, #row. Each call that matters is appended to $UI_SHOT_STUB_LOG.
const fs = require('fs');
const log = o => fs.appendFileSync(process.env.UI_SHOT_STUB_LOG, JSON.stringify(o) + '\n');
const touch = o => { if (o && o.path) fs.writeFileSync(o.path, 'png'); };
const element = sel => ({
  first: () => element(sel),
  count: async () => (sel === '#row' ? 1 : 0),
  screenshot: async o => touch(o),
  boundingBox: async () => ({ width: 10, height: 1 }),
  waitFor: async () => {},
});
exports.chromium = {
  launch: async opts => {
    log({ launch: opts === undefined ? null : opts });
    return {
      newPage: async opts => {
        log({ newPage: opts });
        return {
          goto: async () => {},
          screenshot: async o => touch(o),
          locator: element,
          evaluate: async () => ({ w: 100, h: 100 }),
        };
      },
      close: async () => {},
    };
  },
};
STUB
  UI_SHOT_STUB_LOG="$d/stub.log"; export UI_SHOT_STUB_LOG
  ( cd "$proj" && sh "$TOOL" "file:///stub" --selector '#row'  --out "$d/o1" >/dev/null 2>&1 ) \
    && { echo "ok:   a matching selector still exits 0"; pass=$((pass+1)); } \
    || { echo "FAIL: over-corrected -- a VALID selector now fails"; exit 1; }
  [ -f "$d/o1/crop-1.png" ] || { echo "FAIL: a matching selector produced no crop"; exit 1; }
  echo "ok:   a matching selector writes its crop"; pass=$((pass+1))
  ( cd "$proj" && sh "$TOOL" "file:///stub" --selector '#nope' --out "$d/o2" >/dev/null 2>&1 ) \
    && { echo "FAIL: a no-match selector still exits 0 -- the crop silently absent"; exit 1; } \
    || { echo "ok:   a no-match selector exits non-zero (functional)"; pass=$((pass+1)); }
  grep -q '"deviceScaleFactor"' "$d/stub.log" \
    || { echo "FAIL: the page is not opened with a deviceScaleFactor"; exit 1; }
  echo "ok:   the page is opened at an explicit scale (functional)"; pass=$((pass+1))
  if grep -q '"headless":false' "$d/stub.log"; then
    echo "FAIL: the browser is launched headed"; exit 1
  fi
  echo "ok:   the browser is not launched headed (functional)"; pass=$((pass+1))
else
  echo "skip: node not installed; functional selector checks not run"
fi

printf '\n%d passed\n' "$pass"
