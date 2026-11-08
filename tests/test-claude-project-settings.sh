#!/bin/sh
# Test claude-project-settings: each fleet project's settings file, pointed at from the fleet record,
# checked against the closed rules of what may be declared, then merged into the project's
# .claude/settings.local.json by the user-level file's rule (declared keys win, arrays replace,
# every other live key kept), never clobbering a file it cannot parse.
#
# Everything is a fixture under a temp directory: a fleet record, the settings files, project
# directories and their live files. The fleet-decl used is the SOURCE copy.
set -u
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
base=$(cd "$here/.." && pwd)
tool="${CPS_TOOL:-$base/private_dot_local/bin/executable_claude-project-settings}"   # CPS_TOOL: a planted copy
tmp=$(mktemp -d "$_TMP/test-claude-project-settings.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq absent"; exit 1; }
mkdir -p "$tmp/bin"; ln -s "$base/private_dot_local/bin/executable_fleet-decl" "$tmp/bin/fleet-decl"
PATH="$tmp/bin:$PATH"; export PATH
fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

root="$tmp/Devel"; sroot="$tmp/dotlocal"; mkdir -p "$sroot/claude/projects"
mkdir -p "$root/work/a/.claude" "$root/work/fresh" "$root/work/broken/.claude" "$root/work/greedy" "$root/work/plain/.claude"
FLEET_RECORD="$root/mani.yaml"; FLEET_DEVEL_ROOT=$root; CLAUDE_PROJECT_SETTINGS_ROOT=$sroot
export FLEET_RECORD FLEET_DEVEL_ROOT CLAUDE_PROJECT_SETTINGS_ROOT
cat > "$FLEET_RECORD" <<'YAML'
projects:
  a:
    path: work/a
    claudeLocalSettings: claude/projects/a.json
  fresh:
    path: work/fresh
    claudeLocalSettings: claude/projects/fresh.json
  broken:
    path: work/broken
    claudeLocalSettings: claude/projects/broken.json
  greedy:
    path: work/greedy
    claudeLocalSettings: claude/projects/greedy.json
  elsewhere:
    path: work/not-on-this-machine
    claudeLocalSettings: claude/projects/elsewhere.json
  plain:
    path: work/plain
YAML
P="$sroot/claude/projects"
printf '{"sandbox":{"filesystem":{"allowWrite":["~/one","~/two"]}}}\n' > "$P/a.json"
printf '{"sandbox":{"filesystem":{"allowWrite":["~/three"]},"excludedCommands":["ssh *"]}}\n' > "$P/fresh.json"
printf '{"sandbox":{"filesystem":{"allowWrite":["~/x"]}}}\n' > "$P/broken.json"
printf '{"permissions":{"allow":["Bash(rm:*)"]}}\n' > "$P/greedy.json"
printf '{"sandbox":{"filesystem":{"allowWrite":["~/y"]}}}\n' > "$P/elsewhere.json"
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

echo "== validate: what may be declared"
v() {  # <name> <json> <expected substring, or "" for valid>
  printf '%s\n' "$2" > "$tmp/v.json"
  out=$(sh "$tool" validate "$tmp/v.json" 2>&1); rc=$?
  if [ -z "$3" ]; then
    [ $rc = 0 ] && ok "valid: $1" || bad "valid: $1" "rc=$rc $out"
  else
    { [ $rc = 1 ] && printf '%s' "$out" | grep -q -- "$3"; } && ok "refused: $1" || bad "refused: $1" "rc=$rc $out"
  fi
}
v "an allowWrite list of home paths" '{"sandbox":{"filesystem":{"allowWrite":["~/Devel/internal/x","~/.local/share/y"]}}}' ""
v "an empty list (how entries are taken away)" '{"sandbox":{"filesystem":{"allowWrite":[]}}}' ""
v "a key outside the allowlist" '{"sandbox":{"enabled":false}}' "key sandbox.enabled may not be declared"
v "permissions" '{"permissions":{"allow":["Bash(rm:*)"]}}' "key permissions may not be declared"
v "allowWrite that is not a list" '{"sandbox":{"filesystem":{"allowWrite":"~/x"}}}' "must be a list"
v "a path not written ~/" '{"sandbox":{"filesystem":{"allowWrite":["/etc"]}}}' "must be written ~/"
v "a glob" '{"sandbox":{"filesystem":{"allowWrite":["~/Devel/**/x"]}}}' "glob"
v "a .. segment" '{"sandbox":{"filesystem":{"allowWrite":["~/Devel/../.ssh"]}}}' ". or .. segment"
v "the whole home directory" '{"sandbox":{"filesystem":{"allowWrite":["~/"]}}}' "whole home"
v "a protected directory" '{"sandbox":{"filesystem":{"allowWrite":["~/.ssh"]}}}' "protected"
v "under a protected directory" '{"sandbox":{"filesystem":{"allowWrite":["~/.claude/settings.json"]}}}' "protected"
v "a sibling of a protected directory is fine" '{"sandbox":{"filesystem":{"allowWrite":["~/.sshfoo"]}}}' ""
v "excludedCommands of the form <command> *" '{"sandbox":{"excludedCommands":["ssh *","mytool *"]}}' ""
v "excludedCommands beside allowWrite" '{"sandbox":{"excludedCommands":["ssh *"],"filesystem":{"allowWrite":["~/x"]}}}' ""
v "excludedCommands that is not a list" '{"sandbox":{"excludedCommands":"ssh *"}}' "must be a list"
v "an excludedCommands entry with no star" '{"sandbox":{"excludedCommands":["ssh"]}}' "one command name followed by"
v "an excludedCommands entry with arguments" '{"sandbox":{"excludedCommands":["git push *"]}}' "one command name followed by"
v "an excludedCommands entry that is a path" '{"sandbox":{"excludedCommands":["/usr/bin/ssh *"]}}' "one command name followed by"
v "an excluded shell" '{"sandbox":{"excludedCommands":["bash *"]}}' "shell, interpreter or wrapper"
v "an excluded wrapper" '{"sandbox":{"excludedCommands":["env *"]}}' "shell, interpreter or wrapper"
v "a sandbox key beside excludedCommands" '{"sandbox":{"excludedCommands":["ssh *"],"network":{"allowAllUnixSockets":true}}}' "key sandbox.network may not be declared"
v "a non-object file" '["~/x"]' "not a JSON object"
v "unparseable JSON" '{ nope' "not valid JSON"

echo "== validate: write roots outside the home directory, declared by the private layer"
mkdir -p "$tmp/share/music"
shareroot="$tmp/share/music"
aw() { printf '{"sandbox":{"filesystem":{"allowWrite":["%s"]}}}' "$1"; }
v "an absolute path with no roots file" "$(aw "$shareroot/sheets")" "must be written ~/"
printf '# where a project may write outside the home directory\n\n%s/\n' "$shareroot" > "$sroot/claude/write-roots"
v "a declared root itself" "$(aw "$shareroot")" ""
v "a path under a declared root" "$(aw "$shareroot/sheets/2026")" ""
v "a sibling sharing the root's prefix" "$(aw "${shareroot}x")" "must be written ~/"
v "a parent of a declared root" "$(aw "$tmp/share")" "must be written ~/"
v "a .. segment under a declared root" "$(aw "$shareroot/../secret")" ". or .. segment"
v "a glob under a declared root" "$(aw "$shareroot/*")" "glob"
v "home paths still valid beside a roots file" '{"sandbox":{"filesystem":{"allowWrite":["~/x"]}}}' ""
badroot() {  # <name> <root line>: the roots file is refused, failing even a valid declaration
  printf '%s\n' "$2" > "$sroot/claude/write-roots"
  printf '{"sandbox":{"filesystem":{"allowWrite":["~/x"]}}}\n' > "$tmp/v.json"
  out=$(sh "$tool" validate "$tmp/v.json" 2>&1); rc=$?
  { [ $rc = 1 ] && printf '%s' "$out" | grep -q -- "write-roots"; } && ok "refused root: $1" || bad "refused root: $1" "rc=$rc $out"
}
badroot "the filesystem root" "/"
badroot "the home directory" "$HOME"
badroot "a parent of the home directory" "$(dirname "$HOME")"
badroot "a relative path" "share/music"
badroot "a protected directory" "$HOME/.ssh/keys"
badroot "a .. segment" "$shareroot/../x"
badroot "a glob" "$shareroot/*"
rm -f "$sroot/claude/write-roots"

out=$(sh "$tool" validate 2>&1); rc=$?
{ [ $rc = 1 ] && printf '%s' "$out" | grep -q 'greedy: key permissions'; } \
  && ok "validate with no file checks every declared project's file" || bad "validate all" "rc=$rc $out"

echo "== check and apply"
sh "$tool" check > "$tmp/out" 2>&1; rc=$?
{ [ $rc = 1 ] && grep -q 'a:' "$tmp/out"; } && ok "check before apply: drift reported, exit 1" || bad "check before apply" "rc=$rc $(cat "$tmp/out")"
[ "$(jq -c .sandbox.filesystem.allowWrite "$root/work/a/.claude/settings.local.json")" = '["~/old","~/one"]' ] \
  && ok "check writes nothing" || bad "check wrote" "$(cat "$root/work/a/.claude/settings.local.json")"

sh "$tool" apply > "$tmp/out" 2>&1; rc=$?
a="$root/work/a/.claude/settings.local.json"
[ "$(jq -c .sandbox.filesystem.allowWrite "$a")" = '["~/one","~/two"]' ] \
  && ok "a declared array REPLACES the live one: an undeclared entry is removed" || bad "array replace" "$(cat "$a")"
{ [ "$(jq -c .permissions.allow "$a")" = '["Bash(ls:*)"]' ] && [ "$(jq -r .outputStyle "$a")" = kept ]; } \
  && ok "undeclared live keys, the app's permissions.allow among them, are kept" || bad "live keys kept" "$(cat "$a")"
[ "$(jq -c .sandbox.filesystem.allowWrite "$root/work/fresh/.claude/settings.local.json" 2>/dev/null)" = '["~/three"]' ] \
  && ok "a project with no .claude/ gets the directory and the file" || bad "fresh project" "$(ls -la "$root/work/fresh")"
[ "$(jq -c .sandbox.excludedCommands "$root/work/fresh/.claude/settings.local.json" 2>/dev/null)" = '["ssh *"]' ] \
  && ok "a declared excludedCommands is written beside allowWrite" || bad "excludedCommands written" "$(cat "$root/work/fresh/.claude/settings.local.json" 2>/dev/null)"
{ [ "$(cat "$root/work/broken/.claude/settings.local.json")" = '{ not json' ] && grep -q 'broken' "$tmp/out"; } \
  && ok "an unparseable live file is left alone and named" || bad "broken left alone" "$(cat "$tmp/out")"
{ [ ! -e "$root/work/greedy/.claude/settings.local.json" ] && grep -q 'greedy: not written' "$tmp/out"; } \
  && ok "a file that fails validation is not written" || bad "invalid not written" "$(cat "$tmp/out")"
{ grep -q 'elsewhere' "$tmp/out" && [ ! -e "$root/work/not-on-this-machine" ]; } \
  && ok "a project not on this machine is skipped, not created" || bad "elsewhere skipped" "$(cat "$tmp/out")"
cmp -s "$tmp/plain.before" "$root/work/plain/.claude/settings.local.json" \
  && ok "a project that declares nothing is not touched" || bad "plain touched" "$(cat "$root/work/plain/.claude/settings.local.json")"
[ $rc = 1 ] && ok "apply exits 1 when a project could not be written" || bad "apply rc" "rc=$rc"

sh "$tool" check a > "$tmp/out" 2>&1; rc=$?
[ $rc = 0 ] && ok "check after apply, one project: current, exit 0" || bad "check after apply" "rc=$rc $(cat "$tmp/out")"
before=$(cat "$a"); sh "$tool" apply a >/dev/null 2>&1
[ "$(cat "$a")" = "$before" ] && ok "a second apply changes nothing" || bad "idempotent" "$(cat "$a")"

printf '  nofile:\n    path: work/a\n    claudeLocalSettings: claude/projects/missing.json\n' >> "$FLEET_RECORD"
sh "$tool" apply nofile > "$tmp/out" 2>&1; rc=$?
{ [ $rc = 1 ] && grep -q 'does not exist' "$tmp/out"; } && ok "a pointer to a missing file is reported, exit 1" || bad "missing file" "rc=$rc $(cat "$tmp/out")"

FLEET_RECORD="$tmp/nope.yaml" sh "$tool" apply > "$tmp/out" 2>&1; rc=$?
[ $rc = 2 ] && ok "an unreadable record is exit 2, nothing written" || bad "unreadable record" "rc=$rc $(cat "$tmp/out")"

echo "== directories inside a repository: claudeDirSettings"
# A session started in a subdirectory reads .claude/settings.json from that directory only, so each
# declared directory gets its own complete <dir>/.claude/settings.json; the repository root keeps
# claudeLocalSettings and settings.local.json.
rec2="$root/mani-dirs.yaml"
cat > "$rec2" <<'YAML'
projects:
  multi:
    path: work/multi
    claudeLocalSettings: claude/projects/multi.json
    claudeDirSettings:
      seats/one: claude/projects/multi-one.json
      seats/two/: claude/projects/multi-two.json
  dirsonly:
    path: work/dirsonly
    claudeDirSettings:
      sub: claude/projects/dirsonly-sub.json
  badshape:
    path: work/dirsonly
    claudeDirSettings: claude/projects/ok.json
  escapes:
    path: work/escapes
    claudeDirSettings:
      ../outside: claude/projects/ok.json
      /abs: claude/projects/ok.json
      .: claude/projects/ok.json
      a/../b: claude/projects/ok.json
      a//b: claude/projects/ok.json
      linked: claude/projects/ok.json
      linkedclaude: claude/projects/ok.json
      tracked: claude/projects/ok.json
      absent: claude/projects/ok.json
      greedy: claude/projects/greedy.json
YAML
printf '{"sandbox":{"filesystem":{"allowWrite":["~/root"]}}}\n' > "$P/multi.json"
printf '{"sandbox":{"filesystem":{"allowWrite":["~/s1","~/shared"]}}}\n' > "$P/multi-one.json"
printf '{"sandbox":{"filesystem":{"allowWrite":["~/s2","~/shared"]}}}\n' > "$P/multi-two.json"
printf '{"sandbox":{"filesystem":{"allowWrite":["~/sub"]}}}\n' > "$P/dirsonly-sub.json"
printf '{"sandbox":{"filesystem":{"allowWrite":["~/ok"]}}}\n' > "$P/ok.json"
mkdir -p "$root/work/multi/seats/one/.claude" "$root/work/multi/seats/two" "$root/work/dirsonly/sub" \
         "$root/work/escapes/a/b" "$root/work/escapes/tracked/.claude" "$root/work/escapes/greedy" "$tmp/outside"
ln -s "$tmp/outside" "$root/work/escapes/linked"
mkdir -p "$root/work/escapes/linkedclaude" "$tmp/outside2"; ln -s "$tmp/outside2" "$root/work/escapes/linkedclaude/.claude"
cat > "$root/work/multi/seats/one/.claude/settings.json" <<'JSON'
{ "sandbox": { "filesystem": { "allowWrite": ["~/old"] } }, "model": "kept" }
JSON
printf '{"committed": true}\n' > "$root/work/escapes/tracked/.claude/settings.json"
git -C "$root/work/escapes" init -q && git -C "$root/work/escapes" add tracked/.claude/settings.json \
  || { echo "FAIL: git fixture"; exit 1; }
cp "$root/work/escapes/tracked/.claude/settings.json" "$tmp/tracked.before"

FLEET_RECORD=$rec2 sh "$tool" check > "$tmp/out" 2>&1; rc=$?
{ [ $rc = 1 ] && grep -q 'multi:seats/one: .*differs' "$tmp/out"; } \
  && ok "check reports a directory's drift under <project>:<dir>" || bad "dir check drift" "rc=$rc $(cat "$tmp/out")"
[ "$(jq -c .sandbox.filesystem.allowWrite "$root/work/multi/seats/one/.claude/settings.json")" = '["~/old"]' ] \
  && ok "check writes no directory file" || bad "dir check wrote" "$(cat "$root/work/multi/seats/one/.claude/settings.json")"

FLEET_RECORD=$rec2 sh "$tool" apply > "$tmp/out" 2>&1; rc=$?
one="$root/work/multi/seats/one/.claude/settings.json"
[ "$(jq -c .sandbox.filesystem.allowWrite "$one" 2>/dev/null)" = '["~/s1","~/shared"]' ] \
  && ok "a directory's declaration is written to <dir>/.claude/settings.json, its array replacing the live one" || bad "dir written" "$(cat "$one")"
[ "$(jq -r .model "$one" 2>/dev/null)" = kept ] && ok "an undeclared key in a directory's live file is kept" || bad "dir live key" "$(cat "$one")"
[ "$(jq -c .sandbox.filesystem.allowWrite "$root/work/multi/seats/two/.claude/settings.json" 2>/dev/null)" = '["~/s2","~/shared"]' ] \
  && ok "each directory gets only its own declaration (a trailing slash in the key is the same directory)" || bad "dir two" "$(cat "$tmp/out")"
{ [ ! -e "$root/work/multi/seats/one/.claude/settings.local.json" ] && [ ! -e "$root/work/multi/seats/two/.claude/settings.local.json" ]; } \
  && ok "no settings.local.json is written in a directory" || bad "dir local file" "$(ls -a "$root/work/multi/seats/one/.claude")"
{ [ "$(jq -c .sandbox.filesystem.allowWrite "$root/work/multi/.claude/settings.local.json" 2>/dev/null)" = '["~/root"]' ] \
  && [ ! -e "$root/work/multi/.claude/settings.json" ]; } \
  && ok "the repository root still gets claudeLocalSettings in settings.local.json, and no settings.json" || bad "root beside dirs" "$(ls -a "$root/work/multi/.claude" 2>&1)"
[ "$(jq -c .sandbox.filesystem.allowWrite "$root/work/dirsonly/sub/.claude/settings.json" 2>/dev/null)" = '["~/sub"]' ] \
  && ok "a project that declares only claudeDirSettings is written" || bad "dirs only" "$(cat "$tmp/out")"
refused() {  # <name> <dir key> <expected substring>
  grep -F -- "escapes:$2: " "$tmp/out" | grep -q -- "$3" && ok "refused directory: $1" || bad "refused directory: $1" "$(cat "$tmp/out")"
}
grep -q 'badshape: claudeDirSettings must be a map' "$tmp/out" \
  && ok "a claudeDirSettings that is not a map is reported, not ignored" || bad "dir badshape" "$(cat "$tmp/out")"
refused "a .. path out of the repository" "../outside" "relative path inside the repository"
refused "an absolute path" "/abs" "relative path inside the repository"
refused "the root itself, which is claudeLocalSettings" "." "claudeLocalSettings"
refused "a .. segment" "a/../b" "relative path inside the repository"
refused "a doubled slash" "a//b" "relative path inside the repository"
refused "a symlink out of the repository" "linked" "outside the repository"
refused "a .claude that is a symlink" "linkedclaude" "is a symlink"
refused "a file git tracks" "tracked" "tracked by git"
refused "a declaration that fails validation" "greedy" "not written"
{ [ ! -e "$root/work/outside" ] && [ ! -e "$tmp/outside/.claude" ] && [ -z "$(ls -A "$tmp/outside2")" ] && [ ! -e "$root/work/escapes/.claude" ]; } \
  && ok "nothing is written outside the repository or at its root" || bad "escape wrote" "$(ls -a "$tmp/outside" "$root/work" 2>&1)"
cmp -s "$tmp/tracked.before" "$root/work/escapes/tracked/.claude/settings.json" \
  && ok "a tracked settings.json is left unchanged" || bad "tracked changed" "$(cat "$root/work/escapes/tracked/.claude/settings.json")"
{ grep -q 'escapes:absent: .*not on this machine; skipped' "$tmp/out" && [ ! -e "$root/work/escapes/absent" ]; } \
  && ok "a declared directory that does not exist is skipped, not created" || bad "absent dir" "$(cat "$tmp/out")"
[ $rc = 1 ] && ok "apply exits 1 when a directory could not be written" || bad "dir apply rc" "rc=$rc"

FLEET_RECORD=$rec2 sh "$tool" check multi > "$tmp/out" 2>&1; rc=$?
{ [ $rc = 0 ] && grep -q 'multi:seats/one: current' "$tmp/out"; } \
  && ok "check <project> after apply covers its directories: current, exit 0" || bad "dir check after" "rc=$rc $(cat "$tmp/out")"
before=$(cat "$one"); FLEET_RECORD=$rec2 sh "$tool" apply multi >/dev/null 2>&1
[ "$(cat "$one")" = "$before" ] && ok "a second apply changes no directory file" || bad "dir idempotent" "$(cat "$one")"
out=$(FLEET_RECORD=$rec2 sh "$tool" validate 2>&1); rc=$?
{ [ $rc = 1 ] && printf '%s' "$out" | grep -q 'escapes:greedy: key permissions'; } \
  && ok "validate with no file checks every directory's file too" || bad "dir validate all" "rc=$rc $out"

[ "$fails" = 0 ] && { echo PASS; exit 0; }
echo "FAILED: $fails"; exit 1
