#!/bin/sh
# Tests for tools/nx/suites.js, the Nx plugin that turns each suite into one cached project, and
# for its agreement with tests/select-suites.sh. Both read tests/coverage.map; this suite holds
# them to the same reach, so the commit tier and the cache cannot disagree about a suite.
#
# Three assertions. (1) Nx lists exactly one project per suite file in tests/, and each suite
# marked `# run-all: serial` gets `parallelism: false`, an unmarked one not. (2) A DIFFERENTIAL:
# for a handful of single paths, the suites Nx says are affected equal what the shell selector
# prints. (3) A map that cannot be trusted (a glob matching nothing, a line naming no suite, a line
# with no globs, a glob outside the translated subset) makes the plugin fail rather than yield a
# partial graph, shown against a scratch map and beside a control run that passes.
#
# WHY `nx show projects --affected --files=<path>` FOR THE NX SIDE. It asks Nx's own task-input
# matching which projects a changed file reaches, with no git base to resolve, so it runs on any
# tree. Matching the resolved globs here in shell or awk would test this suite's matcher, not
# Nx's, and the dialect gap is the thing to catch. A path must be an EXISTING tracked file.
#
# Needs node and node_modules/.bin/nx (an `npm ci` in a checkout); otherwise it SKIPs, since
# applying the base never needs Node.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
sel="$here/select-suites.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node is not installed (Nx is a development-only tool)"; exit 0; }
[ -x "$root/node_modules/.bin/nx" ] || { echo "SKIP: no node_modules/.bin/nx (run npm ci in the checkout)"; exit 0; }
command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { echo "SKIP: not a git checkout"; exit 0; }

_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
tmp=$(mktemp -d "$_TMP/test-nx-suites.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

# Nx's plugin sockets live under a directory whose path must stay short, and its daemon is off so
# no process outlives this run. A private socket directory also keeps this run off other sessions'.
sock=$(mktemp -d "$_TMP/nxs.XXXXXX") || exit 1
trap 'rm -rf "$tmp" "$sock"' EXIT
NX_SOCKET_DIR=$sock; NX_DAEMON=false; export NX_SOCKET_DIR NX_DAEMON

# nxin <dir> <args>: run nx in a workspace; nxq <args>: in this checkout. Both send stdout to $tmp/out, stderr to $tmp/err, return its status.
# The "native module to cache" warning is the sandbox's read-only cache, not a finding.
nxin() { d=$1; shift; (cd "$d" && "$root/node_modules/.bin/nx" "$@") > "$tmp/out" 2> "$tmp/err"; }
nxq() { nxin "$root" "$@"; }
errs() { grep -v '^Warning: Failed to copy native module' "$tmp/err" | head -8; }
# names: the JSON array of project names on stdin, one per line, sorted.
names() { tr -d '[]" ' | tr ',' '\n' | sed '/^$/d' | sort; }

want=$(ls "$here"/test-*.sh "$here"/test-*.py | sed 's|.*/test-||; s|\.sh$||; s|\.py$||; s|^|suite-|' | sort)
nwant=$(printf '%s\n' "$want" | wc -l | tr -d ' ')

echo "== one project per suite"
if nxq show projects; then
  got=$(names < "$tmp/out" | grep '^suite-')
  if [ "$got" = "$want" ]; then ok "Nx lists exactly the $nwant suites in tests/"
  else bad "project names differ from the suites in tests/" "$(printf '%s\n%s\n' "$want" "$got" | sort | uniq -u | tr '\n' ' ')"; fi
else
  bad "nx show projects" "$(errs)"
fi

echo "== a serial suite runs alone under Nx too"
# tests/run-all.sh runs a suite marked `# run-all: serial` alone; under Nx that is the target's
# `parallelism: false`. Found here with the runner's own test, so the two cannot read the marker
# differently. The unmarked control must NOT carry it, or a plugin that marks everything passes.
nserial=0
for t in "$here"/test-*.sh "$here"/test-*.py; do
  sed -n '1,10p' "$t" | grep -qxF '# run-all: serial' || continue
  nserial=$((nserial + 1))
  n=suite-$(basename "$t" | sed 's|^test-||; s|\.sh$||; s|\.py$||')
  if nxq show project "$n" --json; then
    if grep -q '"parallelism":false' "$tmp/out"; then ok "$n is marked serial and runs alone (parallelism false)"
    else bad "$n is marked serial but Nx may run it beside others" "no \"parallelism\":false in its project"; fi
  else bad "nx show project $n" "$(errs)"; fi
done
[ "$nserial" -gt 0 ] || bad "no suite is marked serial" "the check above ran on nothing"
if nxq show project suite-hc-status --json; then
  if grep -q '"parallelism":false' "$tmp/out"; then bad "suite-hc-status (unmarked, the control) runs alone" "it carries \"parallelism\":false"
  else ok "suite-hc-status (unmarked, the control) may run beside others"; fi
else bad "nx show project suite-hc-status" "$(errs)"; fi

echo "== the differential against the shell selector"
# Chosen to cover each way a path can reach a suite: a leaf tool with one suite (plus the
# whole-tree checks), a shared-core file, a tool two suites claim, a path only a `tree` glob
# (and an exemption) matches, a suite file that claims itself, and a dot file.
for p in private_dot_local/bin/executable_hc-status \
         tests/git-isolate.sh \
         private_dot_local/bin/executable_git-clone-worktree \
         setup/chezmoi-safe-apply \
         dot_config/sway/config \
         tests/test-kb.sh \
         .chezmoiignore; do
  expect=$(printf '%s\n' "$p" | sh "$sel" 2>/dev/null | sed 's|^test-||; s|\.sh$||; s|\.py$||; s|^|suite-|' | sort)
  if nxq show projects --affected --files="$p"; then
    have=$(names < "$tmp/out")
    if [ "$have" = "$expect" ]; then ok "$p: Nx and the selector agree ($(printf '%s\n' "$expect" | wc -l | tr -d ' ') suites)"
    else bad "$p: Nx and the selector disagree" "only one side has: $(printf '%s\n%s\n' "$expect" "$have" | sort | uniq -u | tr '\n' ' ')"; fi
  else
    bad "$p: nx show projects --affected" "$(errs)"
  fi
done

# A path nested under a directory that a one-level `*` glob (tests/*.sh) must not reach. No tracked
# file in this tree is both nested there and claimed, so the case runs in a scratch copy of the
# tracked tree with one added file and an exemption for it. Without it a `*` that crossed `/` in
# the plugin would pass every case above.
ws="$tmp/ws"; mkdir -p "$ws"
if (cd "$root" && git ls-files | tar -cf - -T -) | (cd "$ws" && tar -xf -) \
   && ln -s "$root/node_modules" "$ws/node_modules" \
   && mkdir -p "$ws/tests/nested" && : > "$ws/tests/nested/x.sh" \
   && printf 'exempt tests/nested/**\n' >> "$ws/tests/coverage.map" \
   && git -C "$ws" init -q && git -C "$ws" add -A; then
  p=tests/nested/x.sh
  expect=$(printf '%s\n' "$p" | sh "$ws/tests/select-suites.sh" 2>/dev/null | sed 's|^test-||; s|\.sh$||; s|\.py$||; s|^|suite-|' | sort)
  if nxin "$ws" show projects --affected --files="$p"; then
    have=$(names < "$tmp/out")
    if [ "$have" = "$expect" ]; then ok "$p (scratch copy): a one-level * stays one level ($(printf '%s\n' "$expect" | wc -l | tr -d ' ') suites)"
    else bad "$p (scratch copy): Nx and the selector disagree" "only one side has: $(printf '%s\n%s\n' "$expect" "$have" | sort | uniq -u | tr '\n' ' ')"; fi
  else
    bad "$p (scratch copy): nx show projects --affected" "$(errs)"
  fi
else
  bad "building the scratch copy" "tar, ln or git failed"
fi

echo "== a map the plugin cannot trust makes it fail"
# The plugin reads NX_SUITES_MAP_FOR_TESTS in place of the real map, and Nx's project-graph cache
# is off so a cached good graph cannot mask the bad map. The control is the unchanged map through
# the same override: it must pass, or the failures below prove nothing about the defect.
NX_CACHE_PROJECT_GRAPH=false; export NX_CACHE_PROJECT_GRAPH
trymap() { # $1 label, $2 line appended to a copy of the real map ("" for the control), $3 expected message
  cp "$here/coverage.map" "$tmp/map"
  [ -z "$2" ] || printf '%s\n' "$2" >> "$tmp/map"
  (NX_SUITES_MAP_FOR_TESTS="$tmp/map"; export NX_SUITES_MAP_FOR_TESTS; nxq show projects); rc=$?
  if [ -z "$2" ]; then
    [ "$rc" -eq 0 ] && ok "$1" || bad "$1" "$(errs)"
  elif [ "$rc" -eq 0 ]; then
    bad "$1" "nx show projects succeeded on a map with: $2"
  elif grep -qF -- "$3" "$tmp/err"; then ok "$1"
  else bad "$1" "failed, but without '$3': $(errs)"; fi
}
trymap "the unchanged map passes through the override (control)" "" ""
trymap "a glob that matches no tracked file is refused" "test-kb.sh no/such/file" "matches no tracked file"
trymap "a line naming no suite is refused" "test-nope.sh tests/run-all.sh" "names no suite"
trymap "a line with no globs is refused" "test-kb.sh" "a line with no globs"
trymap "a tree line with no globs is refused" "tree test-kb.sh" "a line with no globs"
trymap "a glob outside the translated subset is refused" "test-kb.sh tests/test-k[b].sh" "outside the subset"
trymap "** away from the end of a glob is refused" "test-kb.sh private_dot_local/**/executable_kb" "uses **"

echo
if [ "$fail" -eq 0 ]; then echo "PASS ($pass checks)"; exit 0; fi
echo "FAILED: $fail of $((pass + fail))"
exit 1
