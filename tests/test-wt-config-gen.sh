#!/bin/sh
# Tests for wt-config-gen -- worktrunk's user config, generated from layered sources.
#
# WHAT IS AT RISK. The generated file is worktrunk's ONLY user config, so a bad run does not degrade a
# setting, it removes every setting -- including the leak-guard hook the private layer adds. So the
# arms that matter most are the refusals: a malformed layer, an unknown declaration, and an unreadable
# manifest must each leave the previous config untouched rather than write something smaller.
#
# Every case below is a VALID setup with ONE planted change, so a pass proves the tool noticed that
# change and not merely that it rejected a broken fixture.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tool="$here/../private_dot_local/bin/executable_wt-config-gen"
decl="$here/../private_dot_local/bin/executable_fleet-decl"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok:   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1 -> $2"; }
command -v yq >/dev/null 2>&1 || { echo "wt-config-gen tests: yq absent, cannot run"; exit 1; }
command -v wt >/dev/null 2>&1 || { echo "wt-config-gen tests: wt absent, cannot run"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"; cp "$decl" "$tmp/bin/fleet-decl"; chmod +x "$tmp/bin/fleet-decl"

base() { printf 'worktree-path = "{{ repo_path }}/.worktrees/{{ branch | sanitize }}"\n\n[list]\njson-schema = 2\n' > "$tmp/base.toml"; }
frag() { printf '[pre-start]\nguard = "hook-doctor check --path {{ worktree_path }} --quiet"\n' > "$tmp/frag.toml"; }
record() {  # $1 = the worktrunk block lines for project alpha (may be empty)
  { printf 'projects:\n  alpha:\n    path: internal/alpha/main\n    url: ssh://git@forge.example:3022/team/alpha.git\n'
    [ -n "$1" ] && printf '    worktrunk:\n%s\n' "$1"
    printf '  beta:\n    path: internal/beta\n    url: git@code.example.org:group/sub/beta.git\n'
    printf '    worktrunk:\n      layout: nested\n'
    printf '  gamma:\n    path: internal/gamma\n    url: https://code.example.org/org/gamma.git\n'
  } > "$tmp/mani.yaml"
}
run() {  # prints exit status; output in $tmp/out, $tmp/err
  PATH="$tmp/bin:$PATH" WT_GEN_BASE="$tmp/base.toml" WT_GEN_FRAGMENT="$tmp/frag.toml" \
    WT_GEN_OUT="$tmp/config.toml" FLEET_RECORD="$tmp/mani.yaml" FLEET_DEVEL_ROOT="$tmp" \
    sh "$tool" >"$tmp/out" 2>"$tmp/err"; echo $?
}
seed() { printf '# previous config\n' > "$tmp/config.toml"; }

# 1. the happy path: every layer present
base; frag; record '      layout: bare
      bootstrap: true'; seed
rc=$(run); c=$(cat "$tmp/config.toml")
[ "$rc" = 0 ] && ok "valid layers generate" || bad "valid layers generate" "rc=$rc $(cat "$tmp/err")"
case "$c" in *'[projects."forge.example/team/alpha"]'*) ok "ssh:// url with port -> host/owner/repo";; *) bad "ssh id" "$c";; esac
case "$c" in *'[projects."code.example.org/group/sub/beta"]'*) ok "scp-style url with subgroups -> id";; *) bad "scp id" "$c";; esac
case "$c" in *'code.example.org/org/gamma'*) bad "project without a worktrunk block got an entry" "$c";; *) ok "no worktrunk block -> no entry";; esac
case "$c" in *'{{ repo_path }}/../{{ branch | sanitize }}'*) ok "layout bare -> sibling worktree path";; *) bad "layout bare" "$c";; esac
case "$c" in *'pre-start.bootstrap = "wt-bootstrap"'*) ok "bootstrap true -> blocking pre-start";; *) bad "bootstrap" "$c";; esac
case "$c" in *'guard = "hook-doctor'*) ok "private fragment included";; *) bad "fragment" "$c";; esac
wt --config "$tmp/config.toml" config show >/dev/null 2>&1 && ok "worktrunk parses the result" || bad "wt parse" "$(cat "$tmp/config.toml")"

# 2. no fragment (a machine with no private layer) -> base + projects only
rm -f "$tmp/frag.toml"; seed; rc=$(run)
[ "$rc" = 0 ] && ! grep -q 'hook-doctor' "$tmp/config.toml" && ok "absent fragment is optional" || bad "absent fragment" "rc=$rc"
frag

# 2b. a container declaration implies the bare layout. An entry that declares a bare container (a
# `container:` block, or a `clone:` that runs fleet-repo) says so twice otherwise, and forgetting the
# second is silent: worktrunk's default is the nested layout, so new worktrees land inside the
# default branch's checkout. An explicit worktrunk.layout still wins.
{ printf 'projects:\n'
  printf '  withblock:\n    path: c/withblock/main\n    url: https://code.example.org/org/withblock.git\n    container:\n      branches: default\n'
  printf '  withclone:\n    path: c/withclone/main\n    url: https://code.example.org/org/withclone.git\n    clone: fleet-repo clone withclone\n'
  printf '  withlegacy:\n    path: c/withlegacy/main\n    url: https://code.example.org/org/withlegacy.git\n    clone: git-clone-worktree --mani-project withlegacy\n'
  printf '  override:\n    path: c/override/main\n    url: https://code.example.org/org/override.git\n    container: {}\n    worktrunk:\n      layout: nested\n'
  printf '  plainclone:\n    path: c/plainclone\n    url: https://code.example.org/org/plainclone.git\n    clone: git clone https://code.example.org/org/plainclone.git c/plainclone\n'
  printf '  mentions:\n    path: c/mentions\n    url: https://code.example.org/org/mentions.git\n    clone: echo not-fleet-repo-really\n'
} > "$tmp/mani.yaml"
seed; rc=$(run); c=$(cat "$tmp/config.toml")
[ "$rc" = 0 ] && ok "a manifest of container declarations generates" || bad "container manifest generates" "rc=$rc $(cat "$tmp/err")"
sect() { printf '%s\n' "$c" | awk -v h="[projects.\"$1\"]" 'index($0,h)==1{f=1;next} /^\[/{f=0} f'; }
case "$(sect code.example.org/org/withblock)" in *'/../{{ branch'*) ok "a container: block -> sibling worktree path";; *) bad "container block implies bare" "$c";; esac
case "$(sect code.example.org/org/withclone)" in *'/../{{ branch'*) ok "clone: fleet-repo -> sibling worktree path";; *) bad "fleet-repo clone implies bare" "$c";; esac
case "$(sect code.example.org/org/withlegacy)" in *'/../{{ branch'*) ok "clone: git-clone-worktree (the shim) -> sibling worktree path";; *) bad "legacy clone implies bare" "$c";; esac
case "$(sect code.example.org/org/override)" in *'.worktrees/'*) ok "an explicit worktrunk.layout overrides the implication";; *) bad "explicit layout wins" "$c";; esac
case "$c" in *plainclone*) bad "an ordinary clone: line got an entry" "$c";; *) ok "an ordinary clone: line implies nothing";; esac
case "$c" in *org/mentions*) bad "a clone: line merely containing the word got an entry" "$c";; *) ok "only a command WORD fleet-repo counts, not a substring";; esac
record '      layout: bare
      bootstrap: true'

# 2c. a hook table opened by base AND fragment is merged into one table, not refused: each layer may
# have its own reason to run something at worktree creation.
printf '\n[pre-start]\ncopy-files = "true"\n' >> "$tmp/base.toml"; frag; seed; rc=$(run); c=$(cat "$tmp/config.toml")
[ "$rc" = 0 ] && ok "a hook table shared by base and fragment generates" || bad "shared hook table generates" "rc=$rc $(cat "$tmp/err")"
[ "$(grep -c '^\[pre-start\]' "$tmp/config.toml")" = 1 ] && ok "the shared hook table is opened once" || bad "one [pre-start]" "$c"
pre=$(printf '%s\n' "$c" | awk '/^\[pre-start\]/{f=1;next} /^\[/{f=0} f')
case "$pre" in *'copy-files = "true"'*'guard = "hook-doctor'*) ok "both layers' hooks are inside it";; *) bad "merged hooks" "$pre";; esac
wt --config "$tmp/config.toml" config show >/dev/null 2>&1 && ok "worktrunk parses the merged result" || bad "wt parse merged" "$c"
base

# 2d. END TO END, with the base.toml this repository SHIPS: a new worktree gets the files the default
# worktree lists in .worktreeinclude, and only those; without a list the hook does nothing, silently.
real="$here/../dot_config/worktrunk/base.toml"
rm -f "$tmp/frag.toml"; seed
rc=$(PATH="$tmp/bin:$PATH" WT_GEN_BASE="$real" WT_GEN_FRAGMENT="$tmp/frag.toml" WT_GEN_OUT="$tmp/config.toml" \
  FLEET_RECORD="$tmp/none.yaml" sh "$tool" >"$tmp/out" 2>"$tmp/err"; echo $?)
[ "$rc" = 0 ] && ok "the shipped base.toml generates" || bad "shipped base generates" "rc=$rc $(cat "$tmp/err")"
c2="$tmp/c2"; mkdir -p "$c2"
(
  export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 HOME="$tmp/home"; : > "$GIT_CONFIG_GLOBAL"; mkdir -p "$HOME"
  git init -q -b main "$c2/src" && git -C "$c2/src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  git clone -q --bare "$c2/src" "$c2/box/.bare" && printf 'gitdir: ./.bare\n' > "$c2/box/.git"
  git -C "$c2/box" worktree add -q main main
  printf 'local.properties\n.worktreeinclude\nbuild/\n' >> "$c2/box/.bare/info/exclude"
  printf 'sdk.dir=/opt/sdk\n' > "$c2/box/main/local.properties"; mkdir -p "$c2/box/main/build"; : > "$c2/box/main/build/out"
  cd "$c2/box/main" || exit 1
  # The sibling path wt-config-gen writes for a declared bare container; this fixture declares none.
  wt --config "$tmp/config.toml" --config-set "worktree-path = \"{{ repo_path }}/../{{ branch | sanitize }}\"" -y switch --create quiet --no-cd > "$tmp/e2e-quiet" 2>&1
  printf 'local.properties\n' > .worktreeinclude
  wt --config "$tmp/config.toml" --config-set "worktree-path = \"{{ repo_path }}/../{{ branch | sanitize }}\"" -y switch --create listed --no-cd > "$tmp/e2e-listed" 2>&1
) >/dev/null 2>&1
[ ! -e "$c2/box/quiet/local.properties" ] && [ -d "$c2/box/quiet" ] && ! grep -qi 'nothing copied' "$tmp/e2e-quiet" \
  && ok "without .worktreeinclude: nothing copied, nothing said" || bad "no list -> silent no-op" "$(cat "$tmp/e2e-quiet")"
[ "$(cat "$c2/box/listed/local.properties" 2>/dev/null)" = "sdk.dir=/opt/sdk" ] \
  && ok "with .worktreeinclude: the listed file reaches the new worktree" || bad "listed file copied" "$(cat "$tmp/e2e-listed")"
[ ! -e "$c2/box/listed/build" ] && ok "an ignored file it does not list stays behind" || bad "unlisted not copied" "$(ls -A "$c2/box/listed")"
frag

# 3. no manifest at all -> base + fragment, stated
mv "$tmp/mani.yaml" "$tmp/mani.away"; seed; rc=$(run)
[ "$rc" = 0 ] && grep -q 'no manifest' "$tmp/err" && ok "absent manifest degrades, and says so" || bad "absent manifest" "rc=$rc $(cat "$tmp/err")"
mv "$tmp/mani.away" "$tmp/mani.yaml"

# --- refusals: each must exit non-zero AND leave the previous config untouched
refused() {  # $1 label
  rc=$(run)
  if [ "$rc" != 0 ] && [ "$(cat "$tmp/config.toml")" = "# previous config" ]; then ok "$1"; else bad "$1" "rc=$rc $(cat "$tmp/err")"; fi
}
seed; printf 'stray = 1\n[pre-start]\nx = "y"\n' > "$tmp/frag.toml"; refused "fragment with a top-level key is refused"
frag; seed; printf '[list]\nfull = true\n' > "$tmp/frag.toml"; refused "fragment redefining a base table is refused"
grep -q 'opened by more than one source' "$tmp/err" && grep -q 'frag.toml' "$tmp/err" \
  && ok "the duplicate is named with its source, not left to worktrunk's line number" \
  || bad "duplicate message names the source" "$(cat "$tmp/err")"
frag; seed; printf '[pre-start]\ncopy-files = "other"\n' >> "$tmp/base.toml"; printf '[pre-start]\ncopy-files = "x"\n' > "$tmp/frag.toml"
refused "a hook name defined by two sources is refused"
grep -q 'pre-start.copy-files' "$tmp/err" && ok "the doubly-defined hook is named" || bad "doubly-defined hook named" "$(cat "$tmp/err")"
base
frag; seed; printf 'projects: [\n' > "$tmp/mani.yaml"; refused "unreadable manifest is refused, not treated as empty"
seed; record '      layout: sideways'; refused "unknown worktrunk value is refused"
seed; record '      bootsrap: true'; refused "unknown worktrunk key is refused"
seed; record '      layout: bare'; printf '[list\n' > "$tmp/base.toml"; refused "a result worktrunk cannot parse is refused"
base

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
