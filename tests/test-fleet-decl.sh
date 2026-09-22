#!/usr/bin/env bash
# Tests for fleet-decl -- the single reader of per-repo fleet declarations.
#
# WHAT IS ACTUALLY AT RISK, which is what these weight toward. Two enforcement tools will depend
# on this program's answers, one of them on the commit path. The dangerous outcome is not a wrong
# value -- that is visible -- it is a program that returns "nothing declared" when it actually
# could not read the record, because a guard consuming that answer silently downgrades itself to
# its default for every repo at once. So the exit-2 arms matter more than the happy path, and the
# suite asserts the DISTINCTION between 1 and 2 rather than just non-zero.
#
# The longest-match arm exists because scopes nest, and first-match would make the answer depend
# on the order somebody happened to write the record in.

set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$HERE/private_dot_local/bin/executable_fleet-decl"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[ -x "$TOOL" ] || { printf 'fleet-decl: not executable at %s\n' "$TOOL"; exit 1; }
command -v yq >/dev/null 2>&1 || { printf 'fleet-decl tests: yq absent, cannot run\n'; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/Devel"; mkdir -p "$ROOT"
REC="$TMP/rec.yaml"

# The fixture creates real directories because resolution NORMALISES paths before comparing them,
# and normalising resolves symlinks and `..` against the filesystem. That is not an implementation
# detail to work around: a scope that is not checked out on this machine genuinely cannot contain
# the repo you are standing in, so "skipped" is the right answer and the fixture must be able to
# express both cases.
mkdir -p "$ROOT/internal/alpha/nested/deeper" "$ROOT/internal/alpha/some-worktree" \
         "$ROOT/internal/plain" "$ROOT/somewhere/unknown"
# A scope reached from OUTSIDE the manifest's own directory, which is how the two chezmoi sources
# are addressed. Joined naively this is "<root>/../outside/thing" -- the right location and the
# wrong string, sharing no prefix with the resolved path, so the repo would silently resolve to
# nothing and fall back to the default.
mkdir -p "$TMP/outside/thing/wt"

cat > "$REC" <<'YAML'
projects:
  alpha:
    path: internal/alpha
    scope: internal/alpha
    leakPrefix: ALPHA
    leakPolicy: private
    url: ssh://forge/alpha.git
    env:
      MIRROR_URL: /mirror/alpha.git
  nested:
    path: internal/alpha/nested
    scope: internal/alpha/nested
    leakPolicy: strict
  withcanon:
    scope: internal/withcanon
    leakPolicy: private
    canonical: demo-canonical
    canonicalIdentity: "the canonical session for demo"
    canonicalLaunchDir: internal/withcanon
    canonicalLaunchModel: fable
    canonicalMachines: [hostA, hostB]
  plain:
    path: internal/plain
    scope: internal/plain
    leakPolicy: notes
  outside:
    path: ../outside/thing
    scope: ../outside/thing
    leakPolicy: internal
  upstreamish:
    path: external/thing
    tags: [upstream]
YAML

run() { FLEET_RECORD="$REC" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" "$@"; }

# --- resolution -------------------------------------------------------------------------------
out=$(run "$ROOT/internal/alpha" leakPrefix 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ALPHA" ] && ok "reads a declared value" || bad "reads a declared value" "rc=$rc out=$out"

out=$(run "$ROOT/internal/alpha/some-worktree" leakPolicy 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "private" ] \
  && ok "a worktree beneath the scope resolves to the repo" || bad "worktree resolution" "rc=$rc out=$out"

# THE ARM THAT ORDER-DEPENDENCE WOULD BREAK: nested scopes, longest wins.
out=$(run "$ROOT/internal/alpha/nested" leakPolicy 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "strict" ] \
  && ok "a nested scope wins over its parent (longest match)" || bad "longest match" "rc=$rc out=$out"

out=$(run "$ROOT/internal/alpha/nested/deeper" leakPolicy 2>/dev/null); rc=$?
[ "$out" = "strict" ] && ok "a path under the nested scope still resolves to it" || bad "nested depth" "out=$out"

# A DOTTED KEY reaches a nested declaration. Remote URLs live under env:, and a reader that could
# only see top-level keys would force every consumer back to deriving them.
out=$(run "$ROOT/internal/alpha" env.MIRROR_URL 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "/mirror/alpha.git" ] && ok "a dotted key reads a nested value" || bad "dotted key" "rc=$rc out=$out"

out=$(run "$ROOT/internal/alpha" env.MISSING >/dev/null 2>&1; echo $?)
[ "$out" = "1" ] && ok "an absent nested key is exit 1" || bad "absent nested key" "rc=$out"

# A key is interpolated into the query unquoted so its dots separate a path; anything that is not
# an identifier path is refused rather than reaching the query language.
run "$ROOT/internal/alpha" 'x") | .. | ("y' >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "a non-identifier key is refused" || bad "key validation" "rc=$rc"

# STDOUT MUST BE EMPTY WHEN NOTHING IS DECLARED. The reader prints `null` for an absent key, and
# a caller that trusts stdout would write that word into a real config as though it were a value.
out=$(run "$ROOT/internal/plain" leakPrefix 2>/dev/null || true)
[ -z "$out" ] && ok "an absent key prints NOTHING, not the word null" || bad "absent key polluted stdout" "out=[$out]"

out=$(run --fleet nosuch.key 2>/dev/null || true)
[ -z "$out" ] && ok "an absent fleet key prints NOTHING" || bad "absent fleet key polluted stdout" "out=[$out]"

# CANONICAL-KEYED LOOKUPS: the inverse index. A launcher asks "which project declares this name",
# which is the opposite direction from every other read here.
out=$(run --canonicals 2>/dev/null | tr '\n' ' ')
[ "$out" = "demo-canonical " ] && ok "--canonicals lists declared canonicals" || bad "--canonicals" "out=[$out]"
out=$(run --canonical demo-canonical canonicalLaunchModel 2>/dev/null)
[ "$out" = "fable" ] && ok "--canonical reads a key by canonical name" || bad "--canonical" "out=[$out]"
out=$(run --canonical-list demo-canonical canonicalMachines 2>/dev/null | tr '\n' ' ')
[ "$out" = "hostA hostB " ] && ok "--canonical-list yields one machine per line" || bad "--canonical-list" "out=[$out]"
run --canonical no-such-canonical canonicalLaunchDir >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "an unknown canonical name is exit 1" || bad "unknown canonical" "rc=$rc"

# THE OUT-OF-ROOT ARM: a scope that leaves the manifest's directory must still resolve.
out=$(run "$TMP/outside/thing/wt" leakPolicy 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "internal" ] \
  && ok "a scope OUTSIDE the manifest root resolves" || bad "out-of-root scope" "rc=$rc out=$out"

# A declared scope with no checkout here is skipped rather than matching by string luck.
cat > "$TMP/ghost.yaml" <<YAML
projects:
  ghost:
    scope: internal/never-cloned
    leakPolicy: private
YAML
FLEET_RECORD="$TMP/ghost.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" "$ROOT/internal/alpha" leakPolicy >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "a scope not checked out here is skipped, not matched" || bad "ghost scope" "rc=$rc"

# --- the 1-vs-2 distinction, which is the point -------------------------------------------------
run "$ROOT/somewhere/unknown" leakPolicy >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "an unknown repo is exit 1 (no declaration), not 2" || bad "unknown repo rc" "rc=$rc"

run "$ROOT/internal/plain" leakPrefix >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "a known repo missing the key is exit 1" || bad "missing key rc" "rc=$rc"

FLEET_RECORD="$TMP/does-not-exist.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" "$ROOT/internal/alpha" leakPolicy >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "a MISSING record is exit 2, never 1" || bad "missing record rc" "rc=$rc"

printf 'projects: [this is not a map\n' > "$TMP/broken.yaml"
FLEET_RECORD="$TMP/broken.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" "$ROOT/internal/alpha" leakPolicy >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "an UNPARSEABLE record is exit 2, never 1" || bad "unparseable record rc" "rc=$rc"

# No yq on PATH must also be exit 2. Resolve the interpreter first: emptying PATH hides the `env`
# in the shebang, which fails 127 and looks exactly like the tool not failing closed.
SH_ABS=$(command -v sh)
PATH="$TMP" FLEET_RECORD="$REC" FLEET_DEVEL_ROOT="$ROOT" "$SH_ABS" "$TOOL" "$ROOT/internal/alpha" leakPolicy >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "no yq on PATH is exit 2" || bad "no yq rc" "rc=$rc"

# --- --project --------------------------------------------------------------------------------
out=$(run --project "$ROOT/internal/alpha/some-worktree" 2>/dev/null)
[ "$out" = "alpha" ] && ok "--project names the record key" || bad "--project" "out=$out"

# A caller path that does not exist cannot be resolved, and that is exit 1 rather than 2: it is a
# statement about that path, not about the record. Fail-closed for a guard either way.
run "$ROOT/internal/alpha/no-such-worktree" leakPolicy >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "a non-existent caller path is exit 1" || bad "non-existent caller path" "rc=$rc"

# --- --check ----------------------------------------------------------------------------------
run --check >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "--check is clean on a well-formed record" || bad "--check clean" "rc=$rc"

# An upstream clone is somebody else's repo, mirrored not authored, so it is exempt from the
# policy requirement -- but ONLY via the tag, never by having no declarations at all.
cat > "$TMP/untagged.yaml" <<'YAML'
projects:
  stray:
    path: external/stray
YAML
FLEET_RECORD="$TMP/untagged.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --check >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "an UNTAGGED project still needs a policy" || bad "untagged exemption leaked" "rc=$rc"

cat > "$TMP/missing-policy.yaml" <<'YAML'
projects:
  alpha:
    scope: internal/alpha
YAML
out=$(FLEET_RECORD="$TMP/missing-policy.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --check 2>&1); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"policy-missing"* ]] \
  && ok "--check fails a project with no leakPolicy" || bad "--check policy-missing" "rc=$rc $out"

# THE TYPO ARM. The record silently ignores unknown keys, so a near-miss spelling is invisible to
# every other reader and the guard quietly uses its default. Nothing but this check sees it.
cat > "$TMP/typo.yaml" <<'YAML'
projects:
  alpha:
    scope: internal/alpha
    leakPolicy: private
    leakPolcy: private
YAML
out=$(FLEET_RECORD="$TMP/typo.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --check 2>&1); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"unknown-key"* ]] \
  && ok "--check catches a near-miss key spelling" || bad "--check typo" "rc=$rc $out"

cat > "$TMP/half-canonical.yaml" <<'YAML'
projects:
  alpha:
    scope: internal/alpha
    leakPolicy: private
    canonical: alpha-canonical
YAML
out=$(FLEET_RECORD="$TMP/half-canonical.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --check 2>&1); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"canonical-incomplete"* ]] \
  && ok "--check fails a canonical missing its companions" || bad "--check canonical" "rc=$rc $out"

# --- --projects-with / --entry: the enumeration a GENERATOR needs. Everything above answers a
# question about one path or one canonical; a tool that writes config for every project that
# declares something must ask the inverse, and must still tell "none declare it" (1) from "cannot
# read the record" (2).
cat > "$TMP/wt.yaml" <<'YAML'
projects:
  alpha:
    scope: internal/alpha
    leakPolicy: private
    url: ssh://git@forge.example:3022/team/alpha.git
    worktrunk:
      layout: bare
      bootstrap: true
  beta:
    scope: internal/beta
    leakPolicy: private
YAML
out=$(FLEET_RECORD="$TMP/wt.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --projects-with worktrunk 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "alpha" ] && ok "--projects-with lists only declaring projects" || bad "--projects-with" "rc=$rc out=$out"
out=$(FLEET_RECORD="$TMP/wt.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --projects-with nosuchkey 2>&1); rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] && ok "--projects-with: none declaring is exit 1, empty" || bad "--projects-with none" "rc=$rc out=$out"
out=$(FLEET_RECORD="$TMP/nope.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --projects-with worktrunk 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "--projects-with: unreadable record is exit 2" || bad "--projects-with unreadable" "rc=$rc"
out=$(FLEET_RECORD="$TMP/wt.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --entry alpha worktrunk.layout 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "bare" ] && ok "--entry reads a nested key by project name" || bad "--entry" "rc=$rc out=$out"
out=$(FLEET_RECORD="$TMP/wt.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --entry beta url 2>&1); rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] && ok "--entry: absent key is exit 1 with EMPTY stdout, never 'null'" || bad "--entry absent" "rc=$rc out=$out"
out=$(FLEET_RECORD="$TMP/wt.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --entry nosuch url 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "--entry: unknown project is exit 1" || bad "--entry unknown project" "rc=$rc out=$out"
out=$(FLEET_RECORD="$TMP/wt.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --entry 'alpha"x' url 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "--entry: a project name that could escape the query is refused" || bad "--entry injection" "rc=$rc"
out=$(FLEET_RECORD="$TMP/wt.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --check 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "--check accepts a valid worktrunk block" || bad "--check worktrunk valid" "rc=$rc $out"

# The worktrunk block is read by a GENERATOR, which would otherwise have to decide what to do with a
# value it does not understand. Rejecting it here is the one place it can be caught for every caller.
for bad_block in 'layout: sideways' 'bootstrap: maybe' 'bootsrap: true'; do
  cat > "$TMP/wt-bad.yaml" <<YAML
projects:
  alpha:
    scope: internal/alpha
    leakPolicy: private
    worktrunk:
      $bad_block
YAML
  out=$(FLEET_RECORD="$TMP/wt-bad.yaml" FLEET_DEVEL_ROOT="$ROOT" "$TOOL" --check 2>&1); rc=$?
  [ "$rc" -eq 1 ] && [[ "$out" == *"worktrunk"* ]] && ok "--check rejects worktrunk '$bad_block'" || bad "--check worktrunk '$bad_block'" "rc=$rc $out"
done

printf '\nfleet-decl: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
