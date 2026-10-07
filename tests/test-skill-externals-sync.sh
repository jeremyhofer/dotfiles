#!/bin/sh
# Tests for skill-externals-sync: privately declared skills, installed from git at a pinned tag.
# Everything runs against local repositories and a temporary HOME; no network.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tool=${SKILL_EXT_TOOL:-"$here/../private_dot_local/bin/executable_skill-externals-sync"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-skill-ext.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0; failn=0
ok()   { pass=$((pass + 1)); echo "ok:   $1"; }
bad()  { failn=$((failn + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

export HOME="$tmp/home"; mkdir -p "$HOME/.dotlocal" "$HOME/.claude/skills"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
export SKILL_EXTERNALS_STATE="$tmp/state"
list="$HOME/.dotlocal/skill-externals.yaml"
run() { sh "$tool" "$@" > "$tmp/out" 2>&1; echo $? > "$tmp/rc"; }
rc() { cat "$tmp/rc"; }

# A repository with a skill in a subtree, tagged v1.0.0 and v1.1.0.
mkrepo() {  # $1 dir  $2 skill name  $3 subtree
  r="$tmp/$1"; git init -q "$r"; git -C "$r" config user.name t; git -C "$r" config user.email t@t.invalid
  git -C "$r" config commit.gpgsign false; git -C "$r" config tag.gpgsign false
  mkdir -p "$r/$3"
  printf -- '---\nname: %s\nversion: 1.0.0\ndescription: test\n---\n\nbody one\n' "$2" > "$r/$3/SKILL.md"
  git -C "$r" add -A; git -C "$r" commit -qm one; git -C "$r" tag v1.0.0
  printf -- '---\nname: %s\nversion: 1.1.0\ndescription: test\n---\n\nbody two\n' "$2" > "$r/$3/SKILL.md"
  git -C "$r" commit -qam two; git -C "$r" tag v1.1.0
}
mkrepo repo-a alpha skills/alpha
mkrepo repo-b beta ""
mkrepo repo-c gamma skills/gamma

# --- nothing declared, nothing installed: silent no-op -----------------------------------------
run; check "no list and no record: exit 0" '[ "$(rc)" = 0 ]'
check "no list and no record: says nothing" '[ ! -s "$tmp/out" ]'

# --- install ---------------------------------------------------------------------------------
cat > "$list" <<EOF
skill_externals:
  - { name: alpha, url: "file://$tmp/repo-a", version: "1.0.0", subtree: skills/alpha }
  - { name: beta,  url: "file://$tmp/repo-b", ref: v1.1.0, subtree: "" }
EOF
run
check "install: exit 0" '[ "$(rc)" = 0 ]'
check "install: alpha's SKILL.md is at the skill root" 'grep -q "body one" "$HOME/.claude/skills/alpha/SKILL.md"'
check "install: a root subtree installs too" 'grep -q "body two" "$HOME/.claude/skills/beta/SKILL.md"'
check "install: no .git is copied" '[ ! -e "$HOME/.claude/skills/beta/.git" ]'
check "install: both recorded" '[ "$(wc -l < "$tmp/state/installed.tsv")" -eq 2 ]'

# --- up to date: no fetch --------------------------------------------------------------------
mv "$tmp/repo-a" "$tmp/repo-a.away"
run
check "unchanged pin: not fetched again (source moved away, still exit 0)" '[ "$(rc)" = 0 ]'
mv "$tmp/repo-a.away" "$tmp/repo-a"

# --- update ----------------------------------------------------------------------------------
sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$list"
run
check "bumped pin: updated to the new tag" 'grep -q "body two" "$HOME/.claude/skills/alpha/SKILL.md"'

# --- one failure does not stop the others; the previous install is kept -----------------------
cat > "$list" <<EOF
skill_externals:
  - { name: alpha, url: "file://$tmp/repo-a", version: "9.9.9", subtree: skills/alpha }
  - { name: beta,  url: "file://$tmp/repo-b", ref: v1.1.0, subtree: "" }
  - { name: gamma, url: "file://$tmp/repo-c", version: "1.0.0", subtree: skills/gamma }
EOF
run
check "missing tag: exit 1" '[ "$(rc)" = 1 ]'
check "missing tag: reported by name" 'grep -q "alpha: could not fetch v9.9.9" "$tmp/out"'
check "missing tag: the previous alpha is kept" 'grep -q "body two" "$HOME/.claude/skills/alpha/SKILL.md"'
check "missing tag: gamma still installed" '[ -f "$HOME/.claude/skills/gamma/SKILL.md" ]'

# --- refusals ----------------------------------------------------------------------------------
mkdir -p "$HOME/.claude/skills/handmade"; echo keep > "$HOME/.claude/skills/handmade/SKILL.md"
# A VALID source of the same name, so only the ownership guard stands between it and the directory.
mkrepo repo-h handmade skills/handmade
cat > "$list" <<EOF
skill_externals:
  - { name: handmade, url: "file://$tmp/repo-h", version: "1.0.0", subtree: skills/handmade }
  - { name: wrongname, url: "file://$tmp/repo-a", version: "1.0.0", subtree: skills/alpha }
  - { name: nosub, url: "file://$tmp/repo-a", version: "1.0.0", subtree: skills/missing }
  - { name: escape, url: "file://$tmp/repo-a", version: "1.0.0", subtree: ../.. }
  - { name: "Bad Name", url: "file://$tmp/repo-a", version: "1.0.0", subtree: skills/alpha }
  - { name: alpha, url: "file://$tmp/repo-a", version: "1.1.0", subtree: skills/alpha }
EOF
run
check "an existing directory it did not install is left alone" 'grep -q keep "$HOME/.claude/skills/handmade/SKILL.md"'
check "...and reported" 'grep -q "handmade: .* not installed by this tool" "$tmp/out"'
check "a frontmatter name that differs is refused" 'grep -q "wrongname: SKILL.md.s frontmatter name" "$tmp/out" && [ ! -e "$HOME/.claude/skills/wrongname" ]'
check "a subtree with no SKILL.md is refused" 'grep -q "nosub: no SKILL.md" "$tmp/out" && [ ! -e "$HOME/.claude/skills/nosub" ]'
check "a subtree leaving the repository is refused" 'grep -q "escape: subtree" "$tmp/out"'
check "a name that is not a plain skill name is refused" 'grep -q "not a plain skill name" "$tmp/out"'

# A pinned version the fetched SKILL.md contradicts: tag v1.0.0 moved onto the commit declaring 1.1.0.
mkrepo repo-d delta skills/delta
git -C "$tmp/repo-d" tag -f v1.0.0 v1.1.0 >/dev/null 2>&1
cat > "$list" <<EOF
skill_externals:
  - { name: delta, url: "file://$tmp/repo-d", version: "1.0.0", subtree: skills/delta }
EOF
run
check "a frontmatter version that contradicts the pin is refused" 'grep -q "delta: SKILL.md declares version 1.1.0, but 1.0.0 is pinned" "$tmp/out" && [ ! -e "$HOME/.claude/skills/delta" ]'

# --- prune -------------------------------------------------------------------------------------
cat > "$list" <<EOF
skill_externals:
  - { name: beta, url: "file://$tmp/repo-b", ref: v1.1.0, subtree: "" }
EOF
run
check "an entry removed from the list is uninstalled" '[ ! -e "$HOME/.claude/skills/alpha" ] && [ ! -e "$HOME/.claude/skills/gamma" ]'
check "...and the kept one stays" '[ -f "$HOME/.claude/skills/beta/SKILL.md" ]'
check "a directory it never installed is never pruned" '[ -f "$HOME/.claude/skills/handmade/SKILL.md" ]'

# --- an unreadable list changes nothing --------------------------------------------------------
printf 'skill_externals: [ {name: beta\n' > "$list"
run
check "unreadable list: exit 2" '[ "$(rc)" = 2 ]'
check "unreadable list: nothing pruned" '[ -f "$HOME/.claude/skills/beta/SKILL.md" ]'

# --- the whole list removed: everything it installed is uninstalled ----------------------------
rm -f "$list" "$list.bak"
run
check "list removed: its skills are uninstalled" '[ ! -e "$HOME/.claude/skills/beta" ]'
check "list removed: a hand-made skill survives" '[ -f "$HOME/.claude/skills/handmade/SKILL.md" ]'

# --- several skills from one repository and tag: cloned once, not once per skill ----------------
mkrepo repo-m multi-one skills/multi-one
mkdir -p "$tmp/repo-m/skills/multi-two"
printf -- '---\nname: multi-two\ndescription: test\n---\n\nbody multi\n' > "$tmp/repo-m/skills/multi-two/SKILL.md"
git -C "$tmp/repo-m" add -A; git -C "$tmp/repo-m" commit -qm multi; git -C "$tmp/repo-m" tag v2.0.0
# A git on PATH that counts clones, then runs the real one.
realgit=$(command -v git); mkdir -p "$tmp/bin"
printf '#!/bin/sh\ncase " $* " in *" clone "*) echo clone >> "%s";; esac\nexec "%s" "$@"\n' \
  "$tmp/clones" "$realgit" > "$tmp/bin/git"; chmod +x "$tmp/bin/git"
cat > "$list" <<EOF
skill_externals:
  - { name: multi-one, url: "file://$tmp/repo-m", ref: v2.0.0, subtree: skills/multi-one }
  - { name: multi-two, url: "file://$tmp/repo-m", ref: v2.0.0, subtree: skills/multi-two }
  - { name: nosuch-one, url: "file://$tmp/repo-m", ref: v9.0.0, subtree: skills/multi-one }
  - { name: nosuch-two, url: "file://$tmp/repo-m", ref: v9.0.0, subtree: skills/multi-two }
EOF
: > "$tmp/clones"; PATH="$tmp/bin:$PATH" run
check "shared repo and tag: both skills installed" 'grep -q "body multi" "$HOME/.claude/skills/multi-two/SKILL.md" && [ -f "$HOME/.claude/skills/multi-one/SKILL.md" ]'
nclones=$(awk 'END { print NR }' "$tmp/clones")
check "shared repo and tag: one clone per (url, ref), a failed one included" '[ "$nclones" = 2 ]'
check "shared failed fetch: reported for each entry" 'grep -q "nosuch-one: could not fetch v9.0.0" "$tmp/out" && grep -q "nosuch-two: could not fetch v9.0.0" "$tmp/out"'

# --- --force: replace what this tool did not install, reversibly ------------------------------
run --bogus
check "an unknown option: exit 2" '[ "$(rc)" = 2 ]'
mkrepo repo-f forced skills/forced
mkrepo repo-l linked skills/linked
mkrepo repo-k kept skills/kept
mkrepo repo-x chezfake skills/chezfake
mkdir -p "$tmp/oldclone/linked"; echo oldclone > "$tmp/oldclone/linked/SKILL.md"
rm -rf "$HOME/.claude/skills/forced" "$HOME/.claude/skills/linked" "$HOME/.claude/skills/kept"
mkdir -p "$HOME/.claude/skills/forced" "$HOME/.claude/skills/kept" "$HOME/.claude/skills/chezfake"
echo handplaced > "$HOME/.claude/skills/forced/SKILL.md"
echo handkept > "$HOME/.claude/skills/kept/SKILL.md"
echo chezmoi-owned > "$HOME/.claude/skills/chezfake/SKILL.md"
ln -s "$tmp/oldclone/linked" "$HOME/.claude/skills/linked"
# A chezmoi on PATH that claims chezfake, and nothing else.
printf '#!/bin/sh\ncase "$*" in *skills/chezfake*) echo src; exit 0;; esac\necho "not managed" >&2; exit 1\n' > "$tmp/bin/chezmoi"
chmod +x "$tmp/bin/chezmoi"
cat > "$list" <<EOF
skill_externals:
  - { name: forced, url: "file://$tmp/repo-f", version: "1.0.0", subtree: skills/forced }
  - { name: linked, url: "file://$tmp/repo-l", version: "1.0.0", subtree: skills/linked }
  - { name: kept, url: "file://$tmp/repo-k", version: "9.9.9", subtree: skills/kept }
  - { name: chezfake, url: "file://$tmp/repo-x", version: "1.0.0", subtree: skills/chezfake }
EOF
PATH="$tmp/bin:$PATH" run
check "without --force: an existing directory is still refused, with the way out named" 'grep -q "forced: .* not installed by this tool.*--force" "$tmp/out" && grep -q handplaced "$HOME/.claude/skills/forced/SKILL.md"'
PATH="$tmp/bin:$PATH" run --force
check "--force: a hand-placed directory is replaced" 'grep -q "body one" "$HOME/.claude/skills/forced/SKILL.md"'
check "--force: ...and moved aside, not deleted" 'grep -q handplaced "$tmp/state/displaced"/forced.*/SKILL.md'
check "--force: a symlink is replaced by a real install" '[ ! -L "$HOME/.claude/skills/linked" ] && grep -q "body one" "$HOME/.claude/skills/linked/SKILL.md"'
check "--force: ...and the clone it pointed at is untouched" 'grep -q oldclone "$tmp/oldclone/linked/SKILL.md"'
check "--force: a failed fetch leaves the existing directory in place" 'grep -q handkept "$HOME/.claude/skills/kept/SKILL.md"'
check "--force: a name chezmoi manages is refused" 'grep -q "chezfake: .*managed by chezmoi" "$tmp/out" && grep -q chezmoi-owned "$HOME/.claude/skills/chezfake/SKILL.md"'
check "--force: forced installs are recorded, so the next run needs no --force" 'awk -F"\t" "\$1 == \"forced\"" "$tmp/state/installed.tsv" | grep -q forced'

echo "passed: $pass   failed: $failn"
[ "$failn" -eq 0 ]
