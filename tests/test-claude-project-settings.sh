#!/bin/sh
# Test claude-project-settings: each fleet project's declared Claude settings merged into its
# .claude/settings.local.json, by the same rule as the user-level file (declared keys win, arrays
# replace, every other live key kept), never clobbering a file it cannot parse, and refusing to
# declare the array the app accretes.
#
# Everything is a fixture under a temp directory: a fleet record, project directories, live files.
# The fleet-decl used is the SOURCE copy beside the tool under test.
set -u
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
base=$(cd "$here/.." && pwd)
tool="$base/private_dot_local/bin/executable_claude-project-settings"
tmp=$(mktemp -d "$_TMP/test-claude-project-settings.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq absent"; exit 1; }
mkdir -p "$tmp/bin"; ln -s "$base/private_dot_local/bin/executable_fleet-decl" "$tmp/bin/fleet-decl"
PATH="$tmp/bin:$PATH"; export PATH
fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

root="$tmp/Devel"; mkdir -p "$root/work/a/.claude" "$root/work/fresh" "$root/work/broken/.claude" "$root/work/greedy" "$root/work/plain/.claude"
FLEET_RECORD="$root/mani.yaml"; FLEET_DEVEL_ROOT=$root; export FLEET_RECORD FLEET_DEVEL_ROOT
cat > "$FLEET_RECORD" <<'YAML'
projects:
  a:
    path: work/a
    claudeLocalSettings:
      sandbox:
        filesystem:
          allowWrite: ["~/one", "~/two"]
        enabled: true
  fresh:
    path: work/fresh
    claudeLocalSettings:
      sandbox:
        filesystem:
          allowWrite: ["~/three"]
  broken:
    path: work/broken
    claudeLocalSettings:
      sandbox:
        filesystem:
          allowWrite: ["~/x"]
  greedy:
    path: work/greedy
    claudeLocalSettings:
      permissions:
        allow: ["Bash(rm:*)"]
  elsewhere:
    path: work/not-on-this-machine
    claudeLocalSettings:
      sandbox:
        filesystem:
          allowWrite: ["~/y"]
  plain:
    path: work/plain
YAML
cat > "$root/work/a/.claude/settings.local.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(ls:*)"] },
  "sandbox": { "filesystem": { "allowWrite": ["~/old", "~/one"] } },
  "outputStyle": "kept"
}
JSON
printf '{ not json' > "$root/work/broken/.claude/settings.local.json"
printf '{"untouched": true}\n' > "$root/work/plain/.claude/settings.local.json"
cp "$root/work/plain/.claude/settings.local.json" "$tmp/plain.before"

echo "== claude-project-settings"
sh "$tool" check > "$tmp/out" 2>&1; rc=$?
{ [ $rc = 1 ] && grep -q 'a:' "$tmp/out"; } && ok "check before apply: drift reported, exit 1" || bad "check before apply" "rc=$rc $(cat "$tmp/out")"
[ "$(jq -c .sandbox.filesystem.allowWrite "$root/work/a/.claude/settings.local.json")" = '["~/old","~/one"]' ] \
  && ok "check writes nothing" || bad "check wrote" "$(cat "$root/work/a/.claude/settings.local.json")"

sh "$tool" apply > "$tmp/out" 2>&1; rc=$?
a="$root/work/a/.claude/settings.local.json"
[ "$(jq -c .sandbox.filesystem.allowWrite "$a")" = '["~/one","~/two"]' ] \
  && ok "a declared array REPLACES the live one: an undeclared entry is removed" || bad "array replace" "$(cat "$a")"
[ "$(jq -c .sandbox.enabled "$a")" = true ] && ok "a declared boolean lands as a boolean" || bad "boolean" "$(cat "$a")"
{ [ "$(jq -c .permissions.allow "$a")" = '["Bash(ls:*)"]' ] && [ "$(jq -r .outputStyle "$a")" = kept ]; } \
  && ok "undeclared live keys, the app's permissions.allow among them, are kept" || bad "live keys kept" "$(cat "$a")"
[ "$(jq -c .sandbox.filesystem.allowWrite "$root/work/fresh/.claude/settings.local.json" 2>/dev/null)" = '["~/three"]' ] \
  && ok "a project with no .claude/ gets the directory and the file" || bad "fresh project" "$(ls -la "$root/work/fresh")"
{ [ "$(cat "$root/work/broken/.claude/settings.local.json")" = '{ not json' ] && grep -q 'broken' "$tmp/out"; } \
  && ok "an unparseable live file is left alone and named" || bad "broken left alone" "$(cat "$tmp/out")"
{ [ ! -e "$root/work/greedy/.claude/settings.local.json" ] && grep -q 'permissions.allow' "$tmp/out"; } \
  && ok "declaring permissions.allow is refused" || bad "permissions.allow refused" "$(cat "$tmp/out")"
grep -q 'elsewhere' "$tmp/out" && [ ! -e "$root/work/not-on-this-machine" ] \
  && ok "a project not on this machine is skipped, not created" || bad "elsewhere skipped" "$(cat "$tmp/out")"
cmp -s "$tmp/plain.before" "$root/work/plain/.claude/settings.local.json" \
  && ok "a project that declares nothing is not touched" || bad "plain touched" "$(cat "$root/work/plain/.claude/settings.local.json")"
[ $rc = 1 ] && ok "apply exits 1 when a project could not be written (broken, greedy)" || bad "apply rc" "rc=$rc"

sh "$tool" check a > "$tmp/out" 2>&1; rc=$?
[ $rc = 0 ] && ok "check after apply, one project: current, exit 0" || bad "check after apply" "rc=$rc $(cat "$tmp/out")"
before=$(cat "$a"); sh "$tool" apply a >/dev/null 2>&1
[ "$(cat "$a")" = "$before" ] && ok "a second apply changes nothing" || bad "idempotent" "$(cat "$a")"

FLEET_RECORD="$tmp/nope.yaml" sh "$tool" apply > "$tmp/out" 2>&1; rc=$?
[ $rc = 2 ] && ok "an unreadable record is exit 2, nothing written" || bad "unreadable record" "rc=$rc $(cat "$tmp/out")"

[ "$fails" = 0 ] && { echo PASS; exit 0; }
echo "FAILED: $fails"; exit 1
