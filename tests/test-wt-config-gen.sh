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

# 2. no fragment (the work machine) -> base + projects only
rm -f "$tmp/frag.toml"; seed; rc=$(run)
[ "$rc" = 0 ] && ! grep -q 'hook-doctor' "$tmp/config.toml" && ok "absent fragment is optional" || bad "absent fragment" "rc=$rc"
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
frag; seed; printf 'projects: [\n' > "$tmp/mani.yaml"; refused "unreadable manifest is refused, not treated as empty"
seed; record '      layout: sideways'; refused "unknown worktrunk value is refused"
seed; record '      bootsrap: true'; refused "unknown worktrunk key is refused"
seed; record '      layout: bare'; printf '[list\n' > "$tmp/base.toml"; refused "a result worktrunk cannot parse is refused"
base

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
