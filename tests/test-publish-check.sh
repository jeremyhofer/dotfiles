#!/usr/bin/env bash
# Test setup/publish-check: every FAIL case is a MANUFACTURED defect in a scratch repository, and
# each is paired with a mutation.
#
# WHY THE MUTATIONS. A gate seen only green is of unknown value: a case that "fails" because some
# other check tripped, or because the scratch setup is wrong, would still read as coverage. So for
# every FAIL case the suite also runs a copy of the tool with that one check disabled (the calls
# that report its failure rewritten to no-ops) against the SAME scratch repository, and requires
# that copy to PASS. The case is therefore red because of that check and no other.
#
# The fixture: a work clone with two bare remotes, `origin` (the primary) and `pub` (the publish
# remote), both holding the base commit. The tool is copied into the clone's setup/ directory,
# because it locates its checkout from its own path. context-lint and the test runner are stubs,
# steered by CL_RC and RUNALL_RC.
#
# Builds throwaway git repositories; no network.
set -u
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/git-isolate.sh"
tool="$here/../setup/publish-check"
tmp=$(mktemp -d "$_TMP/test-publish-check.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
fails=0
n=0

ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

# A stub context-lint whose verdict the case chooses.
mkdir "$tmp/bin"
cat > "$tmp/bin/context-lint" <<'EOF'
#!/bin/sh
[ "${CL_RC:-0}" -eq 0 ] || echo "stub finding"
exit "${CL_RC:-0}"
EOF
chmod +x "$tmp/bin/context-lint"

# cm <dir> <date> <message>: commit everything in <dir> at <date>.
cm() {
  git -C "$1" add -A
  GIT_AUTHOR_DATE="$2T12:00:00" GIT_COMMITTER_DATE="$2T12:00:00" git -C "$1" commit -q -m "$3"
}
put() { # <dir> <path> <content>
  mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"
}

# mk <name> [changelog-head-date]: a scratch work clone `w` and bare origin/pub holding the base commit.
mk() {
  d="$tmp/$1"; w="$d/w"; mkdir -p "$d"
  git init -q --bare -b main "$d/origin.git"; git init -q --bare -b main "$d/pub.git"
  git init -q -b main "$w"
  git -C "$w" config user.name t; git -C "$w" config user.email t@example.invalid
  put "$w" .chezmoiignore 'README.md
docs/
tests/
setup/

{{ if eq .chezmoi.os "darwin" }}
.config/sway
{{ end }}'
  put "$w" CHANGELOG.md "# Changelog

## ${2:-2026-01-01}"
  put "$w" dot_claude/tooling.md 'Tools: `foo`'
  put "$w" private_dot_local/bin/executable_foo '#!/bin/sh'
  put "$w" dot_claude/skills/alpha/SKILL.md 'Read ~/.dotlocal/skills/alpha.md if it exists.'
  put "$w" dot_claude/skills/beta/SKILL.md 'No fragment here.'
  put "$w" docs/reference/private-layer.md '### Skills: `~/.dotlocal/skills/<skill>.md`

Some prose. Currently: `alpha`. Leave one out with `skipSkills`.

### Next'
  put "$w" tests/run-all.sh '[ -z "${RUNALL_OUT:-}" ] || cat "$RUNALL_OUT"
exit "${RUNALL_RC:-0}"'
  put "$w" dot_old 'old'
  mkdir -p "$w/setup"; cp "$tool" "$w/setup/publish-check"
  cm "$w" 2026-01-01 base
  git -C "$w" remote add origin "$d/origin.git"; git -C "$w" remote add pub "$d/pub.git"
  git -C "$w" push -q origin main; git -C "$w" push -q pub main
  git -C "$w" config dotfiles.publishRemote pub
}

# run <script> [args]: run the tool in the current scenario; sets out and rc.
run() {
  s=$1; shift
  out=$(cd "$w" && PATH="$tmp/bin:$PATH" CL_RC="${CL_RC:-0}" RUNALL_RC="${RUNALL_RC:-0}" RUNALL_OUT="${RUNALL_OUT:-}" sh "$s" "$@" 2>&1) && rc=0 || rc=$?
}

# expect <label> <rc> <substring> [args]: the real tool must exit <rc> and print <substring>.
expect() {
  label=$1; want=$2; sub=$3; shift 3
  run "$w/setup/publish-check" "$@"
  n=$((n+1))
  if [ "$rc" -ne "$want" ]; then bad "$label" "exit $rc, wanted $want: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-400)"
  else
    case "$out" in *"$sub"*) ok "$label" ;; *) bad "$label" "missing '$sub' in: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-400)" ;; esac
  fi
}

# mutant <label> <tag> [args]: the tool with check <tag> disabled must PASS this same scenario.
mutant() {
  label=$1; tag=$2; shift 2
  sed "s/bad $tag /: /g" "$w/setup/publish-check" > "$w/setup/pc-mutant"
  if cmp -s "$w/setup/publish-check" "$w/setup/pc-mutant"; then bad "$label (mutation)" "the mutation changed nothing"; return; fi
  run "$w/setup/pc-mutant" "$@"
  rm -f "$w/setup/pc-mutant"
  if [ "$rc" -eq 0 ]; then ok "$label: red because of the '$tag' check (disabled copy passes)"
  else bad "$label (mutation)" "disabled copy still exits $rc: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-400)"; fi
}

D=2026-05-10

echo "clean pass"
mk clean
put "$w" dot_new 'x'; put "$w" CHANGELOG.md "# Changelog

## $D
- new
## 2026-01-01"
cm "$w" $D "add dot_new"; git -C "$w" push -q origin main
git -C "$w" config --unset dotfiles.publishRemote
expect "clean pass via --remote" 0 "git push pub main" --remote pub
expect "no remote configured" 2 "git config dotfiles.publishRemote"
git -C "$w" config dotfiles.publishRemote pub
expect "clean pass via config, tests run" 0 "tests/run-all.sh passes"
expect "tests skipped on request" 0 "tests skipped" --skip-tests

echo "nothing to publish"
mk nothing
expect "nothing to publish" 0 "nothing to publish"

echo "tree"
mk dirty
put "$w" dot_old 'changed'
expect "dirty tracked file" 1 "FAIL  tree" --skip-tests
mutant "dirty tracked file" tree --skip-tests
mk branch
git -C "$w" switch -q -c feature
expect "not on main" 1 "not main" --skip-tests
mutant "not on main" tree --skip-tests

echo "origin and fast-forward"
mk notorigin
put "$w" tests/t 'x'; cm "$w" $D "tests only"
expect "HEAD not on origin" 1 "FAIL  origin" --skip-tests
mutant "HEAD not on origin" origin --skip-tests
mk diverged
git clone -q "$tmp/diverged/pub.git" "$tmp/diverged/w2"
git -C "$tmp/diverged/w2" config user.name t; git -C "$tmp/diverged/w2" config user.email t@example.invalid
put "$tmp/diverged/w2" other 'y'; cm "$tmp/diverged/w2" $D "elsewhere"; git -C "$tmp/diverged/w2" push -q origin HEAD:main 2>/dev/null; git -C "$tmp/diverged/w2" push -q origin main 2>/dev/null
put "$w" tests/t 'x'; cm "$w" $D "tests only"; git -C "$w" push -q origin main
expect "non-fast-forward" 1 "FAIL  fastforward" --skip-tests
mutant "non-fast-forward" fastforward --skip-tests

echo "changelog"
# cl <text>: replace CHANGELOG.md with a head holding <text> under a heading.
cl() { put "$w" CHANGELOG.md "# Changelog

## $D
$1
## 2026-01-01"; }
mk addnone
put "$w" dot_new 'x'; cm "$w" $D "add deployed file"; git -C "$w" push -q origin main
expect "deployed add, no entry" 1 "dot_new" --skip-tests
mutant "deployed add, no entry" changelog --skip-tests
mk unrelated 2026-12-31
put "$w" dot_new 'x'; cm "$w" $D "add deployed file"
cl "- something else entirely"; cm "$w" $D "changelog"; git -C "$w" push -q origin main
expect "a recent heading that names something else does not cover it" 1 "token 'new'" --skip-tests
mutant "a recent heading that names something else" changelog --skip-tests
mk twotools
put "$w" private_dot_local/bin/executable_aaa '#!/bin/sh'; put "$w" private_dot_local/bin/executable_bbb '#!/bin/sh'
put "$w" dot_claude/tooling.md 'Tools: `foo` `aaa` `bbb`'; cl '- `aaa` is new'
cm "$w" $D "add two tools"; git -C "$w" push -q origin main
expect "two tools added, entry names only one" 1 "executable_bbb" --skip-tests
case "$out" in *executable_aaa*) bad "only the unnamed tool is listed" "aaa was listed: $out" ;; *) ok "only the unnamed tool is listed" ;; esac
mutant "two tools added, entry names only one" changelog --skip-tests
mk skilldir
put "$w" dot_claude/skills/delta/SKILL.md 'x'; put "$w" dot_claude/skills/delta/extra.md 'x'; cl '- skill delta arrives'
cm "$w" $D "add a skill"; git -C "$w" push -q origin main
expect "one mention covers a whole skill directory" 0 "named in the entries" --skip-tests
mk skillnone
put "$w" dot_claude/skills/delta/SKILL.md 'x'; put "$w" dot_claude/skills/delta/extra.md 'x'
cm "$w" $D "add a skill"; git -C "$w" push -q origin main
expect "skill directory not mentioned" 1 "token 'delta'" --skip-tests
mutant "skill directory not mentioned" changelog --skip-tests
mk tmplname
put "$w" dot_config/systemd/user/ntfy-inbox.service.tmpl 'x'; cl '- ntfy-inbox.service ships'
cm "$w" $D "add a unit"; git -C "$w" push -q origin main
expect "prefixes and .tmpl are stripped from the token" 0 "named in the entries" --skip-tests
mk extless
put "$w" dot_config/thing.conf 'x'; cl '- thing is configured'
cm "$w" $D "add a config"; git -C "$w" push -q origin main
expect "the name without its extension is accepted" 0 "named in the entries" --skip-tests
mk later
put "$w" dot_new 'x'; cm "$w" $D "add deployed file"
cl '- new thing'
cm "$w" 2026-05-11 "changelog"; git -C "$w" push -q origin main
expect "entry added in a later commit" 0 "named in the entries" --skip-tests
mk deleted
git -C "$w" rm -q dot_old; cm "$w" $D "remove a deployed file"; git -C "$w" push -q origin main
expect "deleting a deployed path needs an entry" 1 "dot_old" --skip-tests
mutant "deleting a deployed path" changelog --skip-tests
mk deletedcovered
git -C "$w" rm -q dot_old; cl '- old is removed'; cm "$w" $D "remove a deployed file"; git -C "$w" push -q origin main
expect "a deleted path named in the entry is covered" 0 "named in the entries" --skip-tests
mk renamed
git -C "$w" mv dot_old dot_renamed; cl '- old becomes something'; cm "$w" $D "rename a deployed file"; git -C "$w" push -q origin main
expect "a rename must name the NEW path" 1 "dot_renamed" --skip-tests
mutant "a rename must name the new path" changelog --skip-tests
mk renamedok
git -C "$w" mv dot_old dot_renamed; cl '- renamed is the new name'; cm "$w" $D "rename a deployed file"; git -C "$w" push -q origin main
expect "a rename naming the new path is covered" 0 "named in the entries" --skip-tests
mk modified
put "$w" dot_old 'changed'; cm "$w" $D "edit a deployed file"; git -C "$w" push -q origin main
expect "modifying a deployed path needs no entry" 0 "no commit in the range adds" --skip-tests
mk exempt
put "$w" tests/t 'x'; put "$w" docs/d.md 'x'; put "$w" setup/s 'x'; put "$w" README.md 'x'; put "$w" .gitignore 'x'
cm "$w" $D "tests, docs, setup, root files"; git -C "$w" push -q origin main
expect "tests, docs, setup and ignored root files need no entry" 0 "no commit in the range adds" --skip-tests

echo "inventory"
mk inv
put "$w" private_dot_local/bin/executable_bar '#!/bin/sh'; cl '- bar is new'
cm "$w" $D "add a tool"; git -C "$w" push -q origin main
expect "bin tool missing from tooling.md" 1 "bar" --skip-tests
mutant "bin tool missing from tooling.md" inventory --skip-tests

echo "fragments"
mk frag1
put "$w" dot_claude/skills/gamma/SKILL.md 'See ~/.dotlocal/skills/gamma.md.'; cl '- gamma is new'
cm "$w" $D "add a skill"; git -C "$w" push -q origin main
expect "fragment-reading skill missing from the list" 1 "skill 'gamma'" --skip-tests
mutant "fragment-reading skill missing from the list" fragments --skip-tests
mk frag2
put "$w" docs/reference/private-layer.md '### Skills: `~/.dotlocal/skills/<skill>.md`

Some prose. Currently: `alpha`, `ghost`. Leave one out with `skipSkills`.

### Next'
cm "$w" $D "docs"; git -C "$w" push -q origin main
expect "listed name with no skill" 1 "'ghost' is in the" --skip-tests
mutant "listed name with no skill" fragments --skip-tests

echo "context-lint and tests"
mk lint
put "$w" tests/t 'x'; cm "$w" $D "tests only"; git -C "$w" push -q origin main
CL_RC=1 expect "context-lint findings" 1 "FAIL  contextlint" --skip-tests
CL_RC=1 mutant "context-lint findings" contextlint --skip-tests
RUNALL_RC=1 expect "failing test suite" 1 "FAIL  tests"
RUNALL_RC=1 mutant "failing test suite" tests
RUNALL_RC=1 expect "failing suite ignored under --skip-tests" 0 "tests skipped" --skip-tests

# The runner replays a failed suite's output after its FAIL header, each line prefixed with
# seven spaces and a bar. The failing case sits ahead of 40 noise lines, so a plain tail misses it.
{ printf 'PASS   test-a.sh\nFAIL   test-b.sh (exit 1)\n       | setup noise\n       |   FAIL  the specific case XYZ\n'
  i=0; while [ $i -lt 40 ]; do printf '       | noise line %s\n' "$i"; i=$((i+1)); done
  printf 'PASS   test-c.sh\n\n3 suite(s): 2 passed, 1 failed\nfailed: test-b.sh\n'; } > "$tmp/runall.out"
RUNALL_OUT="$tmp/runall.out" RUNALL_RC=1 expect "a failing case far above the tail is shown" 1 "the specific case XYZ"
RUNALL_OUT="$tmp/runall.out" RUNALL_RC=1 expect "the failed suite is named" 1 "FAIL   test-b.sh (exit 1)"
RUNALL_OUT="$tmp/runall.out" RUNALL_RC=1 expect "the summary follows" 1 "3 suite(s): 2 passed, 1 failed"
# A huge failure is bounded: 100 FAIL lines show the first 60 and count the rest.
{ printf 'FAIL   test-big.sh (exit 1)\n'
  i=1; while [ $i -le 100 ]; do printf '       |   FAIL  case-%s\n' "$i"; i=$((i+1)); done
  printf '\n1 suite(s): 0 passed, 1 failed\n'; } > "$tmp/big.out"
RUNALL_OUT="$tmp/big.out" RUNALL_RC=1 expect "a huge failure is cut and the cut is counted" 1 "40 more FAIL lines"
RUNALL_OUT="$tmp/big.out" RUNALL_RC=1 expect "the 60th FAIL line is shown" 1 "case-60"
case "$out" in *"case-61"*) bad "the 61st FAIL line is not shown" "case-61 was printed" ;; *) ok "the 61st FAIL line is not shown" ;; esac
# A failed suite whose output has no FAIL line still shows its last lines.
printf 'FAIL   test-odd.sh (exit 2)\n       | Traceback: boom\n\n1 suite(s): 0 passed, 1 failed\n' > "$tmp/odd.out"
RUNALL_OUT="$tmp/odd.out" RUNALL_RC=1 expect "a suite with no FAIL line shows its last lines" 1 "Traceback: boom"

echo "unreachable"
mk unreach
git -C "$w" remote set-url pub "$tmp/does-not-exist.git"
expect "publish remote cannot be fetched" 2 "could not check" --skip-tests
expect "no remote of that name" 2 "no remote named" --remote nope --skip-tests

echo
if [ "$fails" -eq 0 ]; then echo "PASS  ($n cases)"; exit 0; fi
echo "$fails failure(s)"; exit 1
