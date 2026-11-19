#!/bin/sh
# Tests for tools/nx/suites.js, the Nx plugin that turns each suite into one cached project, the way
# every run of the suites reaches them (tests/apply-suites.py).
#
# Six assertions. (1) THE GRAPH: Nx lists exactly one project per suite file in tests/; each target
# runs its suite under the interpreter the suite's shebang names, with git isolated; every target is
# cached and hashes SANDBOX_RUNTIME and RUN_MUTANTS; a whole-tree check hashes the tracked file list
# and a leaf suite does not; a suite marked `# run-all: serial` gets `parallelism: false`, an
# unmarked one not. All read from one `nx graph`. (2) A TASK REALLY RUNS that way: in a scratch copy
# of the tree, a probe suite run through Nx sees the isolated git config, no bytecode and stdin at
# /dev/null. (3) A DIFFERENTIAL: for a handful of paths, the suites Nx says are affected equal the
# suites whose map globs match the path when read in the map's own dialect (the plugin's
# globToRegExp, which the coverage check uses), so the hash and the coverage check cannot disagree
# about a suite's reach. (4) Two suite files naming one project are refused. (5) A map that cannot
# be trusted (a glob matching nothing, a line naming no suite, a line with no globs, a glob outside
# the translated subset) makes the plugin throw rather than yield a partial graph, each tried against
# the plugin directly beside a control that passes, and one through Nx to show that Nx fails with it.
# (6) Every suite's cache key holds the mise binary, and that input is steady across two runs and
# changed by a stand-in mise, measured by the entries Nx writes to a scratch cache directory.
#
# WHY `nx show projects --affected --files=<path>` FOR THE NX SIDE. It asks Nx's own task-input
# matching which projects a changed file reaches, with no git base to resolve, so it runs on any
# tree. A path must be an EXISTING tracked file.
#
# Needs node and node_modules/.bin/nx (an `npm ci` in a checkout); otherwise it SKIPs. Every run of
# the suites goes through Nx, which needs both, so the skip is only for a run of this file by hand.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
plugin="$root/tools/nx/suites.js"

command -v node >/dev/null 2>&1 || { echo "SKIP: node is not installed"; exit 0; }
[ -x "$root/node_modules/.bin/nx" ] || { echo "SKIP: no node_modules/.bin/nx (run npm ci in the checkout)"; exit 0; }
command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { echo "SKIP: not a git checkout"; exit 0; }

_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
tmp=$(mktemp -d "$_TMP/test-nx-suites.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

# No daemon, so no process outlives this run, and plugins in process, so Nx opens no socket.
NX_DAEMON=false; NX_ISOLATE_PLUGINS=false; export NX_DAEMON NX_ISOLATE_PLUGINS
# The outer run's cache switches are not this suite's: run under `nx --skip-nx-cache` (the landing
# gate), Nx hands every task NX_SKIP_NX_CACHE=true, and the inner runs below then wrote no cache entry,
# so the mise-input check counted none. Its runs use their own cache directory, so nothing reaches
# the outer cache either way.
unset NX_SKIP_NX_CACHE NX_DISABLE_NX_CACHE

# nxin <dir> <args>: run nx in a workspace; nxq <args>: in this checkout. Both send stdout to $tmp/out, stderr to $tmp/err, return its status.
# The "native module to cache" warning is the sandbox's read-only cache, not a finding.
nxin() { d=$1; shift; (cd "$d" && "$root/node_modules/.bin/nx" "$@") > "$tmp/out" 2> "$tmp/err"; }
nxq() { nxin "$root" "$@"; }
errs() { grep -v '^Warning: Failed to copy native module' "$tmp/err" | head -8; }
# names: the JSON array of project names on stdin, one per line, sorted.
names() { tr -d '[]" ' | tr ',' '\n' | sed '/^$/d' | sort; }
proj() { printf 'suite-%s\n' "$(basename "$1" | sed 's|^test-||; s|\.sh$||; s|\.py$||')"; }

want=$(ls "$here"/test-*.sh "$here"/test-*.py | sed 's|.*/test-||; s|\.sh$||; s|\.py$||; s|^|suite-|' | sort)
nwant=$(printf '%s\n' "$want" | wc -l | tr -d ' ')

echo "== the graph"
nxq graph --file="$tmp/graph.json" || { bad "nx graph" "$(errs)"; echo "FAILED: the graph could not be read"; exit 1; }
# One line per suite target: name, command, cache, parallel, hashed env vars, hashes the file list, env.
node -e '
  const nodes = require(process.argv[1]).graph.nodes;
  for (const [name, p] of Object.entries(nodes)) {
    const t = p.data.targets && p.data.targets.test;
    if (!name.startsWith("suite-") || !t) continue;
    const ins = t.inputs || [];
    const env = ins.filter((i) => i && i.env).map((i) => i.env).sort().join(",");
    const listed = ins.some((i) => i && i.runtime === "git ls-files") ? "listed" : "unlisted";
    const iso = JSON.stringify(t.options.env || {});
    console.log([name, t.options.command, String(t.cache), String(t.parallelism !== false), env, listed, iso].join("\t"));
  }' "$tmp/graph.json" > "$tmp/targets"
row() { awk -F '\t' -v n="$1" '$1 == n' "$tmp/targets"; }
field() { row "$1" | cut -f "$2"; }

got=$(cut -f 1 "$tmp/targets" | sort)
if [ "$got" = "$want" ]; then ok "Nx lists exactly the $nwant suites in tests/"
else bad "project names differ from the suites in tests/" "$(printf '%s\n%s\n' "$want" "$got" | sort | uniq -u | tr '\n' ' ')"; fi
# mise moves with the package manager, so every suite's key holds the mise binary on PATH
# (tools/nx/suites.js, MISE_INPUT); whether the input does its job is held further down.
nmise=$(node -e '
  const want = require(process.argv[2]).MISE_INPUT;
  const nodes = require(process.argv[1]).graph.nodes;
  let n = 0;
  for (const [name, p] of Object.entries(nodes)) {
    const t = p.data.targets && p.data.targets.test;
    if (want && name.startsWith("suite-") && t && (t.inputs || []).some((i) => i && i.runtime === want)) n++;
  }
  console.log(String(n));' "$tmp/graph.json" "$plugin")
[ "$nmise" = "$nwant" ] && ok "all $nwant suite targets hash the mise binary" \
  || bad "suite targets hashing the mise binary" "$nmise of $nwant"

# The interpreter each suite's shebang names, read here independently of the plugin.
nbadcmd=0; ncmd=0
for t in "$here"/test-*.sh "$here"/test-*.py; do
  s=$(basename "$t")
  case $(sed -n 1p "$t") in
    *"uv run --script"*) interp="uv run --script" ;;
    *) interp=$(sed -n '1s|^#!.*[/ ]||p' "$t") ;;
  esac
  ncmd=$((ncmd + 1))
  expect="GIT_CONFIG_GLOBAL=\"\$PWD/tests/git-isolated.gitconfig\" PYTHONPYCACHEPREFIX=\"\${TMPDIR:-/tmp}/suites-no-pycache\" exec $interp tests/$s < /dev/null"
  [ "$(field "$(proj "$t")" 2)" = "$expect" ] || { nbadcmd=$((nbadcmd + 1)); printf '        %s: %s\n' "$s" "$(field "$(proj "$t")" 2)"; }
done
[ "$nbadcmd" = 0 ] && ok "each of $ncmd targets runs its suite under the shebang's interpreter, git isolated" \
  || bad "targets whose command is not the suite under its shebang's interpreter" "$nbadcmd of $ncmd"
for i in sh bash zsh "uv run --script"; do
  grep -q "exec $i tests/" "$tmp/targets" && ok "an interpreter in use: $i" || bad "no target runs under $i" "the check above may be running on nothing"
done

# Every suite is cached but the one no input can describe at all (tools/nx/suites.js, UNCACHED):
# test-mise-installed.py checks this machine's mise and files under $HOME.
nenv=$(awk -F '\t' '$5 == "RUN_MUTANTS,SANDBOX_RUNTIME"' "$tmp/targets" | wc -l | tr -d ' ')
[ "$nenv" = "$nwant" ] && ok "all $nwant suite targets hash SANDBOX_RUNTIME and RUN_MUTANTS" \
  || bad "suite targets hashing both variables" "$nenv of $nwant"
[ "$(field suite-mise-installed 3)" = false ] && ok "suite-mise-installed runs every time (cache false)" \
  || bad "suite-mise-installed is cached" "its verdict depends on the machine's mise and files under HOME"
ncached=$(awk -F '\t' '$3 == "true"' "$tmp/targets" | wc -l | tr -d ' ')
[ "$ncached" = $((nwant - 1)) ] && ok "every other suite target is cached ($ncached)" \
  || bad "cached suite targets" "$ncached of $((nwant - 1))"
niso=$(grep -cF '"GIT_CONFIG_NOSYSTEM":"1","TEST_GIT_ISOLATED":"1","PYTHONDONTWRITEBYTECODE":"1","PYTEST_ADDOPTS":"-p no:cacheprovider","FORCE_COLOR":"0","NO_COLOR":"1","PY_COLORS":"0"' "$tmp/targets")
[ "$niso" = "$nwant" ] && ok "all $nwant suite targets get the isolating environment" || bad "suite targets with the isolating environment" "$niso of $nwant"

for s in suite-repo-hygiene suite-coverage-map suite-nx-suites suite-npm-registry; do
  [ "$(field "$s" 6)" = listed ] && ok "$s hashes the tracked file list" || bad "$s does not hash the tracked file list" "a file added or staged would replay its old verdict"
done
[ "$(field suite-hc-status 6)" = unlisted ] && ok "suite-hc-status (a leaf, the control) does not hash it" \
  || bad "suite-hc-status hashes the tracked file list" "every added file would re-run every suite"

if node -e '
  const n = require(process.argv[1]).graph.nodes.control;
  process.exit(n && n.data.targets.noop && n.data.targets.noop.executor === "nx:noop" ? 0 : 1);' "$tmp/graph.json"; then
  ok "control:noop exists and does nothing (nx:noop), for verify-task-io"
else bad "control has no nx:noop target" "verify-task-io needs one to subtract Nx's own reads"; fi

# A serial suite runs alone: the target's `parallelism: false`. The marker is found here with a
# fixed-string grep of the first 10 lines, so the plugin and this check cannot read it the same wrong
# way. The unmarked control must NOT carry it, or a plugin that marks everything passes.
nserial=0
for t in "$here"/test-*.sh "$here"/test-*.py; do
  sed -n '1,10p' "$t" | grep -qxF '# run-all: serial' || continue
  nserial=$((nserial + 1))
  n=$(proj "$t")
  [ "$(field "$n" 4)" = false ] && ok "$n is marked serial and runs alone (parallelism false)" \
    || bad "$n is marked serial but Nx may run it beside others" "no \"parallelism\":false in its target"
done
[ "$nserial" -gt 0 ] || bad "no suite is marked serial" "the check above ran on nothing"
[ "$(field suite-hc-status 4)" = true ] && ok "suite-hc-status (unmarked, the control) may run beside others" \
  || bad "suite-hc-status (unmarked, the control) runs alone" "it carries \"parallelism\":false"

# A scratch copy of the tracked tree, for what must not touch this checkout. Only the files whose
# CONTENT the plugin or Nx reads are copied: the suites, the map, the plugin, Nx's configuration and
# the core. Every other tracked path is an empty file of the same name, which is all the plugin
# needs of it (that it is tracked), so this suite reads nothing it does not hash.
ws="$tmp/ws"; mkdir -p "$ws"
copied() { case "$1" in tests/test-*|tests/coverage.map|tools/nx/suites.js|nx.json|package.json|package-lock.json|tests/git-isolate.sh|tests/git-isolated.gitconfig) return 0 ;; esac; return 1; }
scratch_ok=1
git -C "$root" ls-files > "$tmp/tracked" || scratch_ok=0
while IFS= read -r f; do
  mkdir -p "$ws/$(dirname "$f")" || scratch_ok=0
  if copied "$f"; then cp "$root/$f" "$ws/$f" || scratch_ok=0; else : > "$ws/$f"; fi
done < "$tmp/tracked"
# Its Nx directories go under its own .nx/, which its git ignores. No `git add -A` here runs after
# Nx has written there today (removing the ignore still passes); it keeps a later one from tracking
# Nx's files, which would change what the plugin sees.
if ! { [ "$scratch_ok" = 1 ] && ln -s "$root/node_modules" "$ws/node_modules" && git -C "$ws" init -q &&
       printf '/.nx/\n' >> "$ws/.git/info/exclude" && git -C "$ws" add -A; }; then
  bad "building the scratch copy" "tar, ln or git failed"
  echo "FAILED: $fail of $((pass + fail))"; exit 1
fi
# The scratch copy is its own workspace, with its own cache: nothing it records reaches this one's.
# Both directories are INSIDE that workspace. From Nx 24.0.6, a configured cache or data directory
# outside the workspace is refused unless every directory above it is owned by you or root, and
# inside an agent sandbox /tmp reads as owned by uid 65534, so a directory beside $ws fails there.
NX_CACHE_DIRECTORY="$ws/.nx/cache"; NX_WORKSPACE_DATA_DIRECTORY="$ws/.nx/data"; export NX_CACHE_DIRECTORY NX_WORKSPACE_DATA_DIRECTORY

echo "== a task runs the way the graph says"
cat > "$ws/tests/test-zz-probe.sh" <<'EOF'
#!/bin/sh
# Fails, naming why, unless it runs as the plugin promises.
here=$(cd "$(dirname "$0")" && pwd)
[ "$GIT_CONFIG_GLOBAL" = "$here/git-isolated.gitconfig" ] || { echo "GIT_CONFIG_GLOBAL=$GIT_CONFIG_GLOBAL"; exit 1; }
[ "$(git config --global user.email)" = test@example.invalid ] || { echo "the isolated config is not read"; exit 1; }
[ "$GIT_CONFIG_NOSYSTEM" = 1 ] && [ "$TEST_GIT_ISOLATED" = 1 ] || { echo "git isolation incomplete"; exit 1; }
[ "$PYTHONDONTWRITEBYTECODE" = 1 ] || { echo "bytecode may be written"; exit 1; }
case "$PYTHONPYCACHEPREFIX" in "$(cd "$here/.." && pwd)"*|'') echo "bytecode is read from the checkout: $PYTHONPYCACHEPREFIX"; exit 1 ;; esac
[ "$FORCE_COLOR" = 0 ] && [ "$PY_COLORS" = 0 ] && [ "$NO_COLOR" = 1 ] || { echo "color is forced: FORCE_COLOR=$FORCE_COLOR"; exit 1; }
[ ! -t 0 ] && [ -z "$(cat)" ] || { echo "stdin is not empty"; exit 1; }
echo probe-ran
EOF
printf 'test-zz-probe.sh tests/git-isolate.sh\n' >> "$ws/tests/coverage.map"
git -C "$ws" add -A
if nxin "$ws" run suite-zz-probe:test --outputStyle=static && grep -q probe-ran "$tmp/out"; then
  ok "a probe suite run through Nx sees isolated git, no bytecode, no color, an empty stdin"
else bad "the probe suite through Nx" "$(grep -v '^$' "$tmp/out" | tail -5) $(errs)"; fi

echo "== the differential: Nx's reach against the map's own dialect"
# Chosen to cover each way a path can reach a suite: a leaf tool with one suite (plus the
# whole-tree checks), a shared-core file, a tool two suites claim, a path only a `tree` glob (and an
# exemption) matches, a suite file that claims itself, a dot file, and a path nested under a
# directory that a one-level `*` glob (tests/*.sh) must not reach, added to the scratch copy.
mkdir -p "$ws/tests/nested" && : > "$ws/tests/nested/x.sh" && printf 'exempt tests/nested/**\n' >> "$ws/tests/coverage.map" && git -C "$ws" add -A
for p in private_dot_local/bin/executable_hc-status \
         tests/git-isolate.sh \
         private_dot_local/bin/executable_git-clone-worktree \
         setup/chezmoi-safe-apply \
         tests/test-kb.sh \
         .chezmoiignore \
         tests/nested/x.sh; do
  expect=$(node -e '
    const pl = require(process.argv[1]); const p = process.argv[3];
    const { suites, entries } = pl.readMap(process.argv[2]);
    const hit = new Set(entries.filter((e) => e.kind === "core" && e.re.test(p)).length ? suites : []);
    for (const e of entries) if ((e.kind === "suite" || e.kind === "tree") && e.re.test(p)) hit.add(e.owner);
    if (suites.includes(p.replace(/^tests\//, ""))) hit.add(p.replace(/^tests\//, ""));
    console.log([...hit].map(pl.projectName).sort().join("\n"));' "$plugin" "$ws" "$p" | sort)
  if nxin "$ws" show projects --affected --files="$p"; then
    have=$(names < "$tmp/out")
    if [ "$have" = "$expect" ]; then ok "$p: Nx and the map agree ($(printf '%s\n' "$expect" | sed '/^$/d' | wc -l | tr -d ' ') suites)"
    else bad "$p: Nx and the map disagree" "only one side has: $(printf '%s\n%s\n' "$expect" "$have" | sort | uniq -u | tr '\n' ' ')"; fi
  else
    bad "$p: nx show projects --affected" "$(errs)"
  fi
done

echo "== two suite files naming one project are refused"
# `test-kb.sh` and `test-kb.py` are both `suite-kb`: the second used to replace the first silently,
# and a port passes through exactly that state.
cp "$ws/tests/coverage.map" "$tmp/map.before"
printf '#!/usr/bin/env -S uv run --script\n' > "$ws/tests/test-kb.py"
printf 'test-kb.py tests/git-isolate.sh\n' >> "$ws/tests/coverage.map"
if node -e 'require(process.argv[1]).buildProjects(process.argv[2])' "$plugin" "$ws" 2> "$tmp/err"; then
  bad "two suite files naming one project are refused" "the plugin accepted test-kb.sh and test-kb.py"
elif grep -qF 'test-kb.py and test-kb.sh both name the project suite-kb' "$tmp/err" \
     || grep -qF 'test-kb.sh and test-kb.py both name the project suite-kb' "$tmp/err"; then
  ok "two suite files naming one project are refused, naming both"
else bad "two suite files naming one project are refused" "failed, but not naming both: $(errs)"; fi
rm -f "$ws/tests/test-kb.py"; cp "$tmp/map.before" "$ws/tests/coverage.map"

echo "== the mise input: steady across runs, changed by another mise"
# Measured where it acts: Nx's cache directory names each entry by its task's hash, so a run that adds
# no entry hashed what the run before it did. A probe suite in the scratch copy runs three times: twice
# under this PATH (one entry between them: the input is steady), then with a stand-in mise first on
# PATH printing another version (a second entry: the input changed). The runs use their own cache
# directory and scratch mise directories, so a mise the input runs writes nothing of the machine's.
# Without mise installed the first two runs still hold; the third then compares a mise against none.
printf '#!/bin/sh\nexit 0\n' > "$ws/tests/test-zz-hash-probe.sh"
printf 'test-zz-hash-probe.sh tests/git-isolate.sh\n' >> "$ws/tests/coverage.map"
git -C "$ws" add -A
mkdir -p "$ws/.nx/hashcache" "$tmp/stub" "$tmp/mise/config" "$tmp/mise/data" "$tmp/mise/state" "$tmp/mise/cache"
printf '#!/bin/sh\necho "1999.1.1 stand-in"\n' > "$tmp/stub/mise"; chmod +x "$tmp/stub/mise"
hashes() { ls "$ws/.nx/hashcache" | grep -E '^[0-9]+$' | sort | tr '\n' ' '; }
hprobe() { # $1: a directory put first on PATH, or ""
  (NX_CACHE_DIRECTORY="$ws/.nx/hashcache" NX_CACHE_PROJECT_GRAPH=false \
   MISE_CONFIG_DIR="$tmp/mise/config" MISE_DATA_DIR="$tmp/mise/data" \
   MISE_STATE_DIR="$tmp/mise/state" MISE_CACHE_DIR="$tmp/mise/cache" \
   PATH="${1:+$1:}$PATH"
   export NX_CACHE_DIRECTORY NX_CACHE_PROJECT_GRAPH MISE_CONFIG_DIR MISE_DATA_DIR MISE_STATE_DIR MISE_CACHE_DIR PATH
   nxin "$ws" run suite-zz-hash-probe:test --outputStyle=static)
}
if hprobe "" && h1=$(hashes) && hprobe "" && h2=$(hashes) && hprobe "$tmp/stub" && h3=$(hashes); then
  n1=$(printf '%s' "$h1" | wc -w | tr -d ' '); n2=$(printf '%s' "$h2" | wc -w | tr -d ' ')
  n3=$(printf '%s' "$h3" | wc -w | tr -d ' ')
  if [ "$n1" = 1 ] && [ "$h2" = "$h1" ]; then ok "two runs under one mise hash alike ($h1)"
  else bad "two runs under one mise hashed differently" "after run 1: $h1; after run 2: $h2"; fi
  if [ "$n3" = $((n2 + 1)) ]; then ok "a stand-in mise printing another version changes the hash"
  else bad "a stand-in mise printing another version did not add one new hash" "after run 2: $h2; after run 3: $h3"; fi
else bad "the hash probe suite ran" "$(errs)"; fi
rm -f "$ws/tests/test-zz-hash-probe.sh"
grep -v '^test-zz-hash-probe.sh ' "$ws/tests/coverage.map" > "$tmp/map.ws" && cp "$tmp/map.ws" "$ws/tests/coverage.map"
git -C "$ws" add -A

echo "== a map the plugin cannot trust makes it throw"
# The plugin reads NX_SUITES_MAP_FOR_TESTS in place of the real map. The control is the unchanged
# map through the same override: it must pass, or the failures below prove nothing about the defect.
trymap() { # $1 label, $2 line appended to a copy of the real map ("" for the control), $3 expected message
  cp "$here/coverage.map" "$tmp/map"
  [ -z "$2" ] || printf '%s\n' "$2" >> "$tmp/map"
  NX_SUITES_MAP_FOR_TESTS="$tmp/map" node -e 'require(process.argv[1]).buildProjects(process.argv[2])' "$plugin" "$root" 2> "$tmp/err"; rc=$?
  if [ -z "$2" ]; then
    [ "$rc" -eq 0 ] && ok "$1" || bad "$1" "$(errs)"
  elif [ "$rc" -eq 0 ]; then
    bad "$1" "the plugin accepted a map with: $2"
  elif grep -qF -- "$3" "$tmp/err"; then ok "$1"
  else bad "$1" "failed, but without '$3': $(errs)"; fi
}
trymap "the unchanged map passes through the override (control)" "" ""
trymap "a glob that matches no tracked file is refused" "test-kb.sh no/such/file" "matches no tracked file"
trymap "a line naming no suite is refused" "test-nope.sh tests/git-isolate.sh" "names no suite"
trymap "a line with no globs is refused" "test-kb.sh" "a line with no globs"
trymap "a tree line with no globs is refused" "tree test-kb.sh" "a line with no globs"
trymap "a glob outside the translated subset is refused" "test-kb.sh tests/test-k[b].sh" "outside the subset"
trymap "** away from the end of a glob is refused" "test-kb.sh private_dot_local/**/executable_kb" "uses **"
# And through Nx, in the scratch copy: the plugin's throw fails the Nx command, with its message,
# rather than leaving a partial graph. Nx's project-graph cache is off so a cached good graph cannot
# mask the bad map.
cp "$ws/tests/coverage.map" "$tmp/map"; printf 'test-kb.sh no/such/file\n' >> "$tmp/map"
if NX_CACHE_PROJECT_GRAPH=false NX_SUITES_MAP_FOR_TESTS="$tmp/map" nxin "$ws" show projects; then
  bad "Nx fails on a map the plugin refuses" "nx show projects succeeded"
elif grep -qF 'matches no tracked file' "$tmp/err"; then ok "Nx fails on a map the plugin refuses, with the plugin's message"
else bad "Nx fails on a map the plugin refuses" "failed, but without the plugin's message: $(errs)"; fi

echo
if [ "$fail" -eq 0 ]; then echo "PASS ($pass checks)"; exit 0; fi
echo "FAILED: $fail of $((pass + fail))"
exit 1
