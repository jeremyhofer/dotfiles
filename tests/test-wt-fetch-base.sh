#!/bin/sh
# test-wt-fetch-base.sh -- a worktree created by worktrunk starts from a freshly fetched base.
#
# Drives the REAL worktrunk with the SHIPPED worktrunk config (dot_config/worktrunk/base.toml), so the
# hook wiring is tested along with the script: a fixture repository whose local branches and
# remote-tracking refs are stale, a "forge" remote and a "mirror" fallback that have both moved on,
# and `wt switch --create` run against it. Then the forge goes away, then the mirror too.
#
# Each guarantee is also run against a DELIBERATELY BROKEN copy of the script, put on PATH in place of
# the real one, and the broken copy must produce the stale or silent result: the fetch removed, the
# fallback removed, the refusal removed.
#
# Needs worktrunk (`wt`); SKIPs without it. Run: sh tests/test-wt-fetch-base.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/git-isolate.sh"
SCRIPT="$here/../private_dot_local/bin/executable_wt-fetch-base"
CONF="$here/../dot_config/worktrunk/base.toml"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable"; exit 1; }
command -v wt >/dev/null 2>&1 || { echo "SKIP: worktrunk (wt) not installed"; exit 0; }

TD=${TMPDIR:-/tmp}; TD=${TD%/}
T=$(mktemp -d "$TD/test-fetch-base.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

mkdir -p "$T/bin"
# `wt config show` runs `claude plugin list --json`, which contacts Anthropic's API and a telemetry
# intake. A stub that fails keeps this suite off the network; worktrunk treats it as no plugin.
printf '#!/bin/sh\nexit 1\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"
use_script() { ln -sf "$1" "$T/bin/wt-fetch-base"; }
use_script "$SCRIPT"
PATH="$T/bin:$PATH"; export PATH

commit() { git -C "$1" commit -q --allow-empty -m "$2"; }

# fixture <dir>: forge.git and mirror.git both one commit ahead on main and rel; the clone's local
# main and rel and its origin/* refs all stale. Opted in, with the mirror as the fallback.
fixture() {
  F=$1; mkdir -p "$F"
  git init -q -b main "$F/seed"; commit "$F/seed" c1
  git -C "$F/seed" branch rel
  git clone -q --bare "$F/seed" "$F/forge.git"
  git clone -q --bare "$F/seed" "$F/mirror.git"
  git clone -q "$F/forge.git" "$F/clone"
  git -C "$F/clone" remote add mirror "$F/mirror.git"
  git -C "$F/clone" fetch -q mirror
  git -C "$F/clone" branch -q rel origin/rel
  git -C "$F/clone" config fetch-base.enabled true
  git -C "$F/clone" config fetch-base.fallback mirror
  # One push reaching both remotes, as a multi-URL remote does: the clone fetches none of it.
  git clone -q "$F/forge.git" "$F/pusher"
  git -C "$F/pusher" remote add mirror "$F/mirror.git"
  commit "$F/pusher" main-c2
  git -C "$F/pusher" checkout -q -b rel origin/rel; commit "$F/pusher" rel-c2
  for r in origin mirror; do git -C "$F/pusher" push -q "$r" main rel 2>/dev/null; done
}
tip() { git --git-dir="$1" rev-parse "refs/heads/$2"; }
at() { git -C "$1" rev-parse "refs/heads/$2" 2>/dev/null; }
create() { # <clone> <branch> [wt switch args...] ; stderr kept in $T/err
  c=$1; b=$2; shift 2
  (cd "$c" && wt -y --config "$CONF" switch --create "$b" --no-cd "$@") >/dev/null 2>"$T/err"
}

echo "== creation fetches the base =="
fixture "$T/a"; C="$T/a/clone"
create "$C" w-default && [ "$(at "$C" w-default)" = "$(tip "$T/a/forge.git" main)" ] \
  && ok "default base: starts at the forge's main" || no "default base stale or failed: $(cat "$T/err")"
create "$C" w-rel --base rel && [ "$(at "$C" w-rel)" = "$(tip "$T/a/forge.git" rel)" ] \
  && ok "non-default local base (stale local rel and origin/rel): starts at the forge's rel" || no "rel base stale: $(cat "$T/err")"
create "$C" w-orel --base origin/rel && [ "$(at "$C" w-orel)" = "$(tip "$T/a/forge.git" rel)" ] \
  && ok "remote-qualified base origin/rel: starts at the forge's rel" || no "origin/rel base stale: $(cat "$T/err")"
[ "$(at "$C" main)" != "$(tip "$T/a/forge.git" main)" ] \
  && ok "the checkout's own main is not touched" || no "the local main was moved"

echo "== forge unreachable: the fallback remote =="
fixture "$T/b"; C="$T/b/clone"
commit "$T/b/pusher" mirror-only; git -C "$T/b/pusher" push -q mirror main 2>/dev/null
mv "$T/b/forge.git" "$T/b/forge.down"
create "$C" w-mirror && [ "$(at "$C" w-mirror)" = "$(tip "$T/b/mirror.git" main)" ] \
  && ok "starts at the mirror's main" || no "fallback not used: $(cat "$T/err")"
grep -q 'fetched from mirror' "$T/err" && ok "says it fell back" || no "fallback not reported: $(cat "$T/err")"

echo "== both unreachable: loud refusal, nothing created =="
mv "$T/b/mirror.git" "$T/b/mirror.down"
if create "$C" w-none; then no "creation succeeded with no remote reachable"; else ok "wt exits non-zero"; fi
grep -q 'refusing to create' "$T/err" && ok "says why" || no "no reason given: $(cat "$T/err")"
git -C "$C" show-ref --verify --quiet refs/heads/w-none && no "branch w-none was created" || ok "no branch created"
[ -e "$C/.worktrees/w-none" ] && no "worktree directory created" || ok "no worktree created"
(cd "$C" && wt -y --config "$CONF" switch rel --no-cd) >/dev/null 2>"$T/err" \
  && ok "an existing branch still switches offline" || no "existing branch refused offline: $(cat "$T/err")"

echo "== not opted in: unchanged behavior =="
git -C "$C" config --unset fetch-base.enabled
create "$C" w-off && [ "$(at "$C" w-off)" = "$(at "$C" main)" ] \
  && ok "without fetch-base.enabled, created from the local base, offline" || no "opt-out not honored: $(cat "$T/err")"

echo "== bases the remote does not have, and a local base ahead of it =="
fixture "$T/c"; C="$T/c/clone"
git -C "$C" branch loc main; commit "$C" local-ahead
create "$C" w-loc --base loc && [ "$(at "$C" w-loc)" = "$(at "$C" loc)" ] \
  && ok "a local-only base is used as given" || no "local-only base mishandled: $(cat "$T/err")"
grep -q "not on origin" "$T/err" && ok "with a note" || no "no note for a local-only base: $(cat "$T/err")"
create "$C" w-ahead && [ "$(at "$C" w-ahead)" = "$(tip "$T/c/forge.git" main)" ] \
  && ok "a local base with unpushed commits: starts at the forge's main" || no "ahead base: $(cat "$T/err")"
grep -q "1 commit(s) not on origin" "$T/err" && ok "and names the commits it lacks" || no "unpushed commits not reported: $(cat "$T/err")"

echo "== Claude Code's WorktreeCreate, through worktrunk's plugin, takes the same path =="
# The plugin's own hook command, run verbatim from its installed hooks.json, as Claude Code runs it.
plugin_hooks=""
for h in "$HOME"/.claude/plugins/cache/worktrunk/worktrunk/*/hooks/hooks.json; do
  [ -f "$h" ] && plugin_hooks=$h
done
if [ -z "$plugin_hooks" ] || ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  worktrunk's Claude Code plugin (or jq) is not installed here"
else
  pcmd=$(jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$plugin_hooks")
  proot=$(dirname "$(dirname "$plugin_hooks")")
  plugin_create() { # <clone> <name>
    printf '{"name":"%s"}' "$2" | CLAUDE_PROJECT_DIR=$1 CLAUDE_PLUGIN_ROOT=$proot \
      WORKTRUNK_CONFIG_PATH=$CONF sh -c "$pcmd" 2>"$T/err"
  }
  fixture "$T/p"; C="$T/p/clone"
  p=$(plugin_create "$C" w-plugin) && [ "$(at "$C" w-plugin)" = "$(tip "$T/p/forge.git" main)" ] \
    && ok "plugin WorktreeCreate: starts at the forge's main ($p)" || no "plugin path stale or failed: $(cat "$T/err")"
  mv "$T/p/forge.git" "$T/p/forge.down"; mv "$T/p/mirror.git" "$T/p/mirror.down"
  plugin_create "$C" w-plugin-none >/dev/null && no "plugin path created with no remote reachable" \
    || ok "plugin WorktreeCreate fails with no remote reachable"
  git -C "$C" show-ref --verify --quiet refs/heads/w-plugin-none && no "plugin path left a branch" || ok "and leaves nothing behind"
fi

echo "== the script missing from PATH =="
fixture "$T/m"; C="$T/m/clone"
rm -f "$T/bin/wt-fetch-base"
# Drop every PATH directory that holds a deployed copy, so "missing" is true on an applied machine too.
saved_path=$PATH
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
  [ -n "$d" ] && [ ! -e "$d/wt-fetch-base" ] && printf '%s:' "$d"; done); PATH=${PATH%:}
create "$C" w-missing && no "opted in, script missing: creation went ahead from the local base" \
  || { grep -q 'not installed' "$T/err" && ok "opted in, script missing: creation refused, saying why" || no "refused without the reason: $(cat "$T/err")"; }
sed 's/; elif \[ \\"$(git config --bool fetch-base.enabled)\\" = true \]; then echo .fetch-base is enabled but wt-fetch-base is not installed. >&2; exit 1//' "$CONF" > "$T/broken.toml"
cmp -s "$CONF" "$T/broken.toml" && no "broken config identical to the shipped one (sed matched nothing)"
(cd "$C" && wt -y --config "$T/broken.toml" switch --create w-missing2 --no-cd) >/dev/null 2>&1 \
  && ok "RED: with the missing-script clause removed, creation goes ahead from the stale base" || no "broken config still refused"
git -C "$C" config --unset fetch-base.enabled
create "$C" w-missing3 && ok "not opted in, script missing: creation unchanged" || no "not opted in, yet refused: $(cat "$T/err")"
PATH=$saved_path
use_script "$SCRIPT"

echo "== the dependency install sees the fetched tree, not the stale one =="
# wt-config-gen wires wt-bootstrap as a PER-PROJECT pre-start hook. Measured on worktrunk 0.79:
# entries of one hook table run concurrently, and a per-project table runs only after the global one
# (which holds fetch-base) has finished. That ordering is what keeps an install off the stale
# lockfile; this pins it, with a stub install that records the lockfile it saw.
GEN="$here/../private_dot_local/bin/executable_wt-config-gen"
grep -qF "printf 'pre-start.bootstrap = \"wt-bootstrap\"\\n'" "$GEN" \
  && ok "wt-config-gen still emits bootstrap as a per-project pre-start entry" \
  || no "wt-config-gen no longer emits bootstrap as assumed here; re-check the ordering"
fixture "$T/o"; C="$T/o/clone"
printf 'fresh\n' > "$T/o/pusher/package-lock.json"
git -C "$T/o/pusher" checkout -q main; git -C "$T/o/pusher" add package-lock.json
git -C "$T/o/pusher" commit -q -m lock; git -C "$T/o/pusher" push -q origin main 2>/dev/null
printf '#!/bin/sh\nb=$(git symbolic-ref --short HEAD)\ncat package-lock.json > "%s/saw-$b" 2>/dev/null || echo none > "%s/saw-$b"\n' "$T" "$T" > "$T/bin/wt-bootstrap"
chmod +x "$T/bin/wt-bootstrap"
id=$(cd "$C" && wt config show 2>/dev/null | sed -n 's/.*Identifier: //p' | head -n 1)
{ cat "$CONF"; printf '\n[projects."%s"]\npre-start.bootstrap = "wt-bootstrap"\n' "$id"; } > "$T/ordered.toml"
(cd "$C" && wt -y --config "$T/ordered.toml" switch --create w-ord --no-cd) >/dev/null 2>"$T/err"
[ "$(cat "$T/saw-w-ord" 2>/dev/null)" = fresh ] && ok "install (per-project hook) saw the fetched lockfile" \
  || no "install saw '$(cat "$T/saw-w-ord" 2>/dev/null)' instead of the fetched lockfile: $(cat "$T/err")"
# RED: the same install moved into the global table, beside fetch-base, races it and loses.
sed '/^fetch-base = "{% if base is defined %}/a\
bootstrap = "wt-bootstrap"' "$CONF" > "$T/unordered.toml"
grep -q '^bootstrap = "wt-bootstrap"' "$T/unordered.toml" || no "red config: insertion failed"
(cd "$C" && wt -y --config "$T/unordered.toml" switch --create w-unord --no-cd) >/dev/null 2>&1
[ "$(cat "$T/saw-w-unord" 2>/dev/null)" = none ] && ok "RED: install in the same table saw the stale tree (no lockfile)" \
  || no "red: install in the same table saw '$(cat "$T/saw-w-unord" 2>/dev/null)'"
rm -f "$T/bin/wt-bootstrap"

counter=0
broken() { # <sed-script> <must-exist-fixed-string>
  counter=$((counter + 1))
  grep -qF -- "$2" "$SCRIPT" || { echo "  FAIL  broken-copy target not found: $2" >&2; fail=$((fail + 1)); }
  sed "$1" "$SCRIPT" > "$T/broken-$counter"; chmod +x "$T/broken-$counter"
  cmp -s "$SCRIPT" "$T/broken-$counter" && no "broken copy is identical to the script (sed matched nothing): $1"
  use_script "$T/broken-$counter"
}

echo "== RED: each guarantee fails when its code is removed =="
fixture "$T/r1"; C="$T/r1/clone"
broken 's/git reset --hard --quiet "\$fetched"/true/' 'git reset --hard --quiet "$fetched"'
create "$C" w --base rel; [ "$(at "$C" w)" != "$(tip "$T/r1/forge.git" rel)" ] \
  && ok "move to the fetched commit removed: the rel base is stale" || no "broken copy still fresh"
fixture "$T/r2"; C="$T/r2/clone"
broken 's/git fetch --quiet "\$r"/true/g' 'git fetch --quiet "$r"'
create "$C" w --base origin/rel; [ "$(at "$C" w)" != "$(tip "$T/r2/forge.git" rel)" ] \
  && ok "fetches removed: the origin/rel base is stale" || no "broken copy still fresh"
fixture "$T/r3"; C="$T/r3/clone"; mv "$T/r3/forge.git" "$T/r3/forge.down"
broken 's/for r in origin \$(git config --get-all fetch-base.fallback 2>\/dev\/null); do/for r in origin; do/' 'for r in origin $(git config --get-all fetch-base.fallback 2>/dev/null); do'
create "$C" w && no "fallback removed, yet creation succeeded with the forge down" || ok "fallback removed: creation fails with the forge down"
fixture "$T/r4"; C="$T/r4/clone"; mv "$T/r4/forge.git" "$T/r4/forge.down"; mv "$T/r4/mirror.git" "$T/r4/mirror.down"
broken 's/^  die "refusing to create.*/  exit 0/' '  die "refusing to create'
create "$C" w; [ "$(at "$C" w)" = "$(at "$C" main)" ] \
  && ok "refusal removed: created silently from the unfetched base" || no "broken copy did not create stale: $(cat "$T/err")"
use_script "$SCRIPT"

printf '\npassed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
