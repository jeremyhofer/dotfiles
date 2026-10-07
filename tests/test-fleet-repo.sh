#!/usr/bin/env bash
# Tests for fleet-repo -- making a repository on disk match its entry in the fleet manifest.
#
# THIS SUITE DRIVES ONLY THE COMMAND LINE. It runs `fleet-repo` as a process, against local
# repositories, and reads the result with plain git and the file system -- never a function of the
# tool -- so it survives a later rewrite of the tool in another language unchanged.
#
# WHAT IS AT RISK. The failures worth guarding look like success: a clone that fetched every one of
# thousands of branches because a declaration was not honoured; a re-run that "reconciled" by
# deleting a local branch or worktree holding unpushed work; a container built in the wrong place
# because the tool resolved `path` against the directory it was run from; a `check` that reports
# clean while the disk has drifted. The arms for those are the ones that matter most.
#
# ISOLATION. HOME is a scratch directory and GIT_CONFIG_GLOBAL an empty file, so none of the
# machine's hooks, signing or identity settings reach a repository made here. Remotes are `file://`
# urls, which behave like a real transport (a plain path would let `--filter` be silently ignored).
# The mani arm runs a real `mani sync`; it is skipped, with a SKIP line, where mani is not installed.

set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$HERE/private_dot_local/bin/executable_fleet-repo"
DECL="$HERE/private_dot_local/bin/executable_fleet-decl"

pass=0; fail=0; skip=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

[ -f "$TOOL" ] || { printf 'fleet-repo: not found at %s\n' "$TOOL"; exit 1; }
command -v yq >/dev/null 2>&1 || { printf 'fleet-repo tests: yq absent, cannot run\n'; exit 1; }

t=${TMPDIR:-/tmp}; t=${t%/}
TMP=$(mktemp -d "$t/test-fr.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
unset FLEET_RECORD FLEET_DEVEL_ROOT XDG_CONFIG_HOME

# The tools under test by their deployed names, for the manifest's `clone:` lines and for mani.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexec bash "%s" "$@"\n' "$TOOL" > "$TMP/bin/fleet-repo"
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$DECL" > "$TMP/bin/fleet-decl"
chmod +x "$TMP/bin/fleet-repo" "$TMP/bin/fleet-decl"; export PATH="$TMP/bin:$PATH"

WS="$TMP/ws"; mkdir -p "$WS"

# --- origins -------------------------------------------------------------------------------------
# A bare repository whose default branch is $2, holding one commit, as file://$TMP/$1.git.
mkorigin() {  # $1 name  $2 default
  git init -q -b "$2" "$TMP/src-$1"
  git -C "$TMP/src-$1" commit -q --allow-empty -m one
  git clone -q --bare "$TMP/src-$1" "$TMP/$1.git"
}
# More branches on a bare origin, all at its default's commit. Written into packed-refs rather than
# created one by one, so a pair differing only in case (Feature/B, feature/b) can exist even on a
# case-insensitive file system, where two loose ref files would be one.
addbranches() {  # $1 name, then branch names
  local n=$1 h; shift
  h=$(git -C "$TMP/$n.git" rev-parse HEAD)
  git -C "$TMP/$n.git" pack-refs --all
  # packed-refs is searched by bisection, so the file must stay sorted by refname.
  { printf '# pack-refs with: peeled fully-peeled sorted \n'
    { grep -v '^#' "$TMP/$n.git/packed-refs"; for b in "$@"; do printf '%s refs/heads/%s\n' "$h" "$b"; done; } \
      | LC_ALL=C sort -k2
  } > "$TMP/$n.git/packed-refs.new" && mv "$TMP/$n.git/packed-refs.new" "$TMP/$n.git/packed-refs"
}
url() { printf 'file://%s/%s.git' "$TMP" "$1"; }

mkorigin oa main;  addbranches oa develop feature release/1        # small: used with `all`
mkorigin ob main;  addbranches ob develop release/1 topic/x Feature/B feature/b   # case pair: never `all`
mkorigin os develop; addbranches os feature

# Readers of the result, in plain git.
rrefs() { git --git-dir="$1/.bare" for-each-ref --format='%(refname)' refs/remotes/origin/ | grep -v '^refs/remotes/origin/HEAD$' | sed 's#^refs/remotes/origin/##' | sort | tr '\n' ' ' | sed 's/ $//'; }
lrefs() { git --git-dir="$1/.bare" for-each-ref --format='%(refname:short)' refs/heads/ | sort | tr '\n' ' ' | sed 's/ $//'; }
fetchspecs() { git --git-dir="$1/.bare" config --get-all remote.origin.fetch | sort | tr '\n' ' ' | sed 's/ $//'; }
upstream() { git -C "$1" rev-parse --abbrev-ref '@{u}' 2>/dev/null; }

FR() { fleet-repo "$@"; }

# --- options -------------------------------------------------------------------------------------
mkdir -p "$TMP/opts"; cd "$TMP/opts" || exit 1
FR --help > "$TMP/out" 2>&1; rc=$?
check "--help: exit 0, its own usage, nothing created" '[ "$rc" = 0 ] && grep -q "fleet-repo clone <project>" "$TMP/out" && [ -z "$(ls -A)" ]'
FR -h > "$TMP/out" 2>&1; rc=$?
check "-h: the same" '[ "$rc" = 0 ] && grep -q "fleet-repo clone <project>" "$TMP/out"'
FR clone --help > "$TMP/out" 2>&1; rc=$?
check "clone --help: the same, nothing created" '[ "$rc" = 0 ] && grep -q "fleet-repo clone <project>" "$TMP/out" && [ -z "$(ls -A)" ]'
FR --bogus > "$TMP/out" 2>&1; rc=$?
check "an unknown option: exit 2, refused, never taken as a url, nothing created" '[ "$rc" = 2 ] && grep -q "unknown option" "$TMP/out" && [ -z "$(ls -A)" ]'
FR frobnicate > "$TMP/out" 2>&1; rc=$?
check "an unknown verb: exit 2, named" '[ "$rc" = 2 ] && grep -q "unknown verb" "$TMP/out"'
FR clone --bogus x > "$TMP/out" 2>&1; rc=$?
check "clone: an unknown option is refused too" '[ "$rc" = 2 ] && grep -q "unknown option" "$TMP/out"'
FR clone --url "$(url os)" --filter= emptyfilter > "$TMP/out" 2>&1; rc=$?
check "--filter= with no spec is refused, nothing created" '[ "$rc" = 2 ] && [ ! -e emptyfilter ]'
FR > "$TMP/out" 2>&1; rc=$?
check "no verb: usage, exit 2" '[ "$rc" = 2 ]'

# --- no manifest ---------------------------------------------------------------------------------
mkdir -p "$TMP/nomani/sub"; cd "$TMP/nomani/sub" || exit 1
FR clone ghost > "$TMP/out" 2>&1; rc=$?
check "clone outside any manifest: exit 2 and says there is no manifest, not 'no such project'" \
  '[ "$rc" = 2 ] && grep -q "no manifest" "$TMP/out" && ! grep -q "no such" "$TMP/out" && [ -z "$(ls -A "$TMP/nomani/sub")" ]'
FR check > "$TMP/out" 2>&1; rc=$?
check "check outside any manifest: exit 2" '[ "$rc" = 2 ] && grep -q "no manifest" "$TMP/out"'
FR update > "$TMP/out" 2>&1; rc=$?
check "update outside any manifest: exit 2" '[ "$rc" = 2 ] && grep -q "no manifest" "$TMP/out"'

# --- direct mode (clone --url) -------------------------------------------------------------------
cd "$TMP" || exit 1
FR clone --url "$(url os)" plain >/dev/null 2>&1; rc=$?
check "direct: exit 0" '[ "$rc" = 0 ]'
check "direct: the git data is in .bare, .git is a file pointing at it" '[ -f plain/.bare/HEAD ] && [ "$(cat plain/.git)" = "gitdir: ./.bare" ]'
check "direct: the default branch is read from the remote (develop), not assumed" '[ "$(git -C plain/develop branch --show-current)" = develop ] && [ ! -e plain/main ] && [ ! -e plain/master ]'
check "direct: every branch is fetched (no declaration) and only the default is a local branch" '[ "$(rrefs plain)" = "develop feature" ] && [ "$(lrefs plain)" = develop ]'
check "direct: the default tracks its remote, so a plain git pull works" '[ "$(upstream plain/develop)" = origin/develop ]'
git -C plain/develop branch --unset-upstream 2>/dev/null
FR clone --url "$(url os)" plain >/dev/null 2>&1; rc=$?
check "direct: a re-run exits 0 and repairs a default branch with no upstream" '[ "$rc" = 0 ] && [ "$(upstream plain/develop)" = origin/develop ]'
rm -rf plain/develop; git -C plain worktree prune
FR clone --url "$(url os)" plain >/dev/null 2>&1
check "direct: a re-run re-creates a missing default worktree" '[ -d plain/develop ]'
git -C plain/develop branch keepme
FR clone --url "$(url os)" plain >/dev/null 2>&1
check "direct: a re-run never deletes a local branch of the user's" 'git --git-dir=plain/.bare rev-parse -q --verify refs/heads/keepme >/dev/null'
mkdir -p populated; echo keep > populated/notes.txt
FR clone --url "$(url oa)" populated > "$TMP/out" 2>&1; rc=$?
check "a non-empty directory that is not a container is refused, naming the likely cause" \
  '[ "$rc" != 0 ] && [ ! -e populated/.bare ] && [ ! -e populated/.git ] && grep -q "path:" "$TMP/out"'
FR clone --url "$(url ob)" --branches=default dflt >/dev/null 2>&1
check "direct --branches=default: only the default branch comes down" '[ "$(rrefs dflt)" = main ]'
FR clone --url "$(url ob)" --branches=develop,topic/x lst >/dev/null 2>&1
check "direct --branches=a,b: the default plus the named branches" '[ "$(rrefs lst)" = "develop main topic/x" ]'

# --- the fetched set, one arm per form of `branches` --------------------------------------------
cd "$WS" || exit 1
cat > mani.yaml <<EOF
projects:
  fall:
    path: fall/main
    url: $(url oa)
    clone: fleet-repo clone fall
    container:
      branches: all
  fnone:
    path: fnone/main
    url: $(url oa)
    clone: fleet-repo clone fnone
  fdef:
    path: fdef/main
    url: $(url ob)
    clone: fleet-repo clone fdef
    container:
      branches: default
  flist:
    path: flist/main
    url: $(url ob)
    clone: fleet-repo clone flist
    container:
      branches: [develop, release/1]
  fcase:
    path: fcase/main
    url: $(url ob)
    clone: fleet-repo clone fcase
    container:
      branches: [feature/b]
  fwt:
    path: fwt/main
    url: $(url ob)
    clone: fleet-repo clone fwt
    container:
      branches: default
    worktrees:
      - name: topic/x
        path: ../topic-x
      - name: develop
        path: ../develop
EOF
for p in fall fnone fdef flist fcase fwt; do FR clone "$p" > "$TMP/out-$p" 2>&1; eval "rc_$p=\$?"; done
check "branches: all: every branch fetched" '[ "$rc_fall" = 0 ] && [ "$(rrefs fall)" = "develop feature main release/1" ]'
check "branches: all: the refspec is the wildcard, and only the default is a local branch" '[ "$(fetchspecs fall)" = "+refs/heads/*:refs/remotes/origin/*" ] && [ "$(lrefs fall)" = main ]'
check "no container block at all: the fleet default is all" '[ "$rc_fnone" = 0 ] && [ "$(rrefs fnone)" = "develop feature main release/1" ]'
check "branches: default: only the default branch is fetched" '[ "$rc_fdef" = 0 ] && [ "$(rrefs fdef)" = main ] && [ "$(fetchspecs fdef)" = "+refs/heads/main:refs/remotes/origin/main" ]'
check "branches: default: the default branch is still checked out with an upstream" '[ "$(git -C fdef/main branch --show-current)" = main ] && [ "$(upstream fdef/main)" = origin/main ]'
check "branches: [list]: the default plus the listed branches, nothing else" '[ "$rc_flist" = 0 ] && [ "$(rrefs flist)" = "develop main release/1" ]'
check "branches: [list]: only the default is a local branch" '[ "$(lrefs flist)" = main ]'
check "case-differing branches: the declared one arrives, its case twin does not" '[ "$(rrefs fcase)" = "feature/b main" ] && ! git --git-dir=fcase/.bare rev-parse -q --verify refs/remotes/origin/Feature/B >/dev/null'
check "case-differing branches: undeclared, neither of the pair is fetched (default)" '! git --git-dir=fdef/.bare rev-parse -q --verify refs/remotes/origin/Feature/B >/dev/null && ! git --git-dir=fdef/.bare rev-parse -q --verify refs/remotes/origin/feature/b >/dev/null'
check "worktrees: a branch named there is fetched although branches is default" '[ "$rc_fwt" = 0 ] && [ "$(rrefs fwt)" = "develop main topic/x" ]'
check "worktrees: each gets a worktree at its declared path, relative to path:" '[ "$(git -C fwt/topic-x branch --show-current)" = topic/x ] && [ "$(git -C fwt/develop branch --show-current)" = develop ]'
check "worktrees: each has an upstream" '[ "$(upstream fwt/topic-x)" = origin/topic/x ] && [ "$(upstream fwt/develop)" = origin/develop ]'
check "worktrees: they share the container's .bare" '[ "$(cd fwt/topic-x && git rev-parse --path-format=absolute --git-common-dir)" = "$(cd fwt && pwd)/.bare" ]'
FR clone fwt > "$TMP/out" 2>&1; rc=$?
check "worktrees: a re-run is idempotent" '[ "$rc" = 0 ] && grep -q "already present" "$TMP/out"'
git -C fwt/topic-x branch --unset-upstream; rm -rf fwt/develop; git -C fwt worktree prune
FR clone fwt > "$TMP/out" 2>&1
check "worktrees: a re-run repairs a missing upstream and re-creates a deleted worktree" '[ "$(upstream fwt/topic-x)" = origin/topic/x ] && [ "$(git -C fwt/develop branch --show-current)" = develop ]'

# A declared worktree whose branch is not on the remote cannot exist: said, and not silent.
cat > mani.yaml <<EOF
projects:
  fghost:
    path: fghost/main
    url: $(url ob)
    clone: fleet-repo clone fghost
    container:
      branches: default
    worktrees:
      - name: nosuchbranch
        path: ../nosuch
EOF
FR clone fghost > "$TMP/out" 2>&1; rc=$?
check "a worktree for a branch missing on the remote: reported, exit 1, the rest still done" \
  '[ "$rc" = 1 ] && grep -q "nosuchbranch" "$TMP/out" && [ -d fghost/main ] && [ ! -e fghost/nosuch ] && [ "$(fetchspecs fghost)" = "+refs/heads/main:refs/remotes/origin/main" ]'

# --- fleet default -------------------------------------------------------------------------------
mkdir -p "$TMP/ws2"; cd "$TMP/ws2" || exit 1
cat > mani.yaml <<EOF
containerDefaults:
  branches: default
projects:
  dnone:
    path: dnone/main
    url: $(url ob)
    clone: fleet-repo clone dnone
  dover:
    path: dover/main
    url: $(url ob)
    clone: fleet-repo clone dover
    container:
      branches: [develop]
EOF
FR clone dnone >/dev/null 2>&1; FR clone dover >/dev/null 2>&1
check "containerDefaults.branches applies to an entry with no container block" '[ "$(rrefs dnone)" = main ]'
check "an entry's own branches overrides the fleet default" '[ "$(rrefs dover)" = "develop main" ]'

# --- reconcile -----------------------------------------------------------------------------------
cd "$WS" || exit 1
rec_manifest() {  # $1 = branches line, $2 = worktrees block (may be empty)
  cat > mani.yaml <<EOF
projects:
  rec:
    path: rec/main
    url: $(url ob)
    clone: fleet-repo clone rec
    container:
      branches: $1
$2
EOF
}
rec_manifest '[develop]' ''
FR clone rec >/dev/null 2>&1
check "reconcile: starting point is the default plus develop" '[ "$(rrefs rec)" = "develop main" ]'
rec_manifest '[develop, release/1, topic/x]' ''
FR clone rec > "$TMP/out" 2>&1; rc=$?
check "reconcile: branches added to the declaration are fetched on the next run" '[ "$rc" = 0 ] && [ "$(rrefs rec)" = "develop main release/1 topic/x" ] && [ "$(fetchspecs rec | tr " " "\n" | grep -c refs/heads)" = 4 ]'
# develop gets a worktree (and with it a local branch), release/1 a local branch with none, and then
# neither is declared any more. Git itself refuses to delete a branch that is checked out, so only
# the second proves the tool does not delete a local branch.
git -C rec worktree add -q ../rec-dev develop 2>/dev/null || git -C rec worktree add -q "$WS/rec/develop" develop
git --git-dir=rec/.bare branch --quiet mine origin/release/1
git --git-dir=rec/.bare branch --quiet release/1 origin/release/1
rec_manifest '[]' ''
FR clone rec > "$TMP/out" 2>&1; rc=$?
check "reconcile: a branch dropped from the declaration loses its refspec and remote-tracking ref" \
  '[ "$rc" = 0 ] && [ "$(rrefs rec)" = main ] && [ "$(fetchspecs rec)" = "+refs/heads/main:refs/remotes/origin/main" ]'
check "reconcile: a local branch and a worktree for a dropped branch are REPORTED" 'grep -q "kept local branch release/1" "$TMP/out" && grep -q "kept local branch develop" "$TMP/out" && grep -q "kept worktree" "$TMP/out"'
check "reconcile: ...and NOT deleted" 'git --git-dir=rec/.bare rev-parse -q --verify refs/heads/release/1 >/dev/null && git --git-dir=rec/.bare rev-parse -q --verify refs/heads/develop >/dev/null && [ -d "$WS/rec/develop" -o -d "$WS/rec-dev" ]'
check "reconcile: an unrelated local branch is untouched" 'git --git-dir=rec/.bare rev-parse -q --verify refs/heads/mine >/dev/null'
rec_manifest 'all' ''
FR clone rec >/dev/null 2>&1
check "reconcile: moving to all replaces the per-branch refspecs with the wildcard and fetches the rest" \
  '[ "$(fetchspecs rec)" = "+refs/heads/*:refs/remotes/origin/*" ] && git --git-dir=rec/.bare rev-parse -q --verify refs/remotes/origin/topic/x >/dev/null'
rec_manifest 'default' ''
FR clone rec >/dev/null 2>&1
check "reconcile: moving from all to default drops every other remote-tracking ref" '[ "$(rrefs rec)" = main ] && [ "$(fetchspecs rec)" = "+refs/heads/main:refs/remotes/origin/main" ]'

# --- filter --------------------------------------------------------------------------------------
# A big file committed long ago and since deleted stays on the server; a blobless clone never
# downloads it, yet the checkout and later pulls still work.
git init -q -b main "$TMP/src-big"
head -c 200000 /dev/urandom > "$TMP/src-big/old.bin"; git -C "$TMP/src-big" add -A; git -C "$TMP/src-big" commit -qm old
git -C "$TMP/src-big" rm -q old.bin; echo current > "$TMP/src-big/now.txt"; git -C "$TMP/src-big" add -A; git -C "$TMP/src-big" commit -qm now
git clone -q --bare "$TMP/src-big" "$TMP/big.git"; git -C "$TMP/big.git" config uploadpack.allowFilter true
cat > mani.yaml <<EOF
projects:
  filt:
    path: filt/main
    url: $(url big)
    clone: fleet-repo clone filt
    container:
      filter: blob:none
  unfilt:
    path: unfilt/main
    url: $(url big)
    clone: fleet-repo clone unfilt
EOF
FR clone filt > "$TMP/out" 2>&1; rc=$?
check "filter: a declared filter on a fresh clone: exit 0, default branch checked out" '[ "$rc" = 0 ] && [ "$(cat filt/main/now.txt 2>/dev/null)" = current ]'
nmissing=$(git -C filt/main rev-list --objects --all --missing=print 2>/dev/null | grep -c '^?' || true)
check "filter: the deleted old file was never downloaded" '[ "${nmissing:-0}" -ge 1 ]'
check "filter: the remote is recorded as the promisor, so git fetches on demand" '[ "$(git --git-dir=filt/.bare config remote.origin.promisor)" = true ]'
echo more > "$TMP/src-big/now.txt"; git -C "$TMP/src-big" commit -qam more; git -C "$TMP/src-big" push -q "$TMP/big.git" main
git -C filt/main pull -q --ff-only > "$TMP/out" 2>&1
check "filter: git pull --ff-only still updates it" '[ "$(cat filt/main/now.txt)" = more ]'
FR clone unfilt >/dev/null 2>&1
cat > mani.yaml <<EOF
projects:
  unfilt:
    path: unfilt/main
    url: $(url big)
    clone: fleet-repo clone unfilt
    container:
      filter: blob:none
EOF
FR clone unfilt > "$TMP/out" 2>&1; rc=$?
check "filter: declared on an EXISTING unfiltered container: reported, not applied, exit 0" \
  '[ "$rc" = 0 ] && grep -q "not applied" "$TMP/out" && [ "$(git --git-dir=unfilt/.bare config remote.origin.promisor 2>/dev/null)" != true ]'
cat > mani.yaml <<EOF
projects:
  over:
    path: over/main
    url: $(url big)
    clone: fleet-repo clone over
EOF
FR clone over --filter=blob:none >/dev/null 2>&1
check "filter: --filter= on the command line applies to a project with none declared" '[ "$(git --git-dir=over/.bare config remote.origin.promisor 2>/dev/null)" = true ]'

# --- where path is resolved ----------------------------------------------------------------------
cat > mani.yaml <<EOF
projects:
  sub:
    path: deep/er/develop
    url: $(url os)
    clone: fleet-repo clone sub
EOF
mkdir -p "$WS/some/subdir"; cd "$WS/some/subdir" || exit 1
FR clone sub > "$TMP/out" 2>&1; rc=$?
check "path is resolved against the manifest's directory, not the current one (run from a subdirectory)" \
  '[ "$rc" = 0 ] && [ -d "$WS/deep/er/.bare" ] && [ -d "$WS/deep/er/develop" ] && [ ! -e "$WS/some/subdir/deep" ] && [ -z "$(ls -A "$WS/some/subdir")" ]'
cd "$TMP" || exit 1
FLEET_RECORD="$WS/mani.yaml" FR clone sub > "$TMP/out" 2>&1; rc=$?
check "FLEET_RECORD names the manifest when no mani.yaml is above the current directory" '[ "$rc" = 0 ] && grep -q "already present" "$TMP/out"'

# A path naming the container: the directory above must not become a repository.
mkdir -p "$TMP/ws3"; echo keep > "$TMP/ws3/notes"; cd "$TMP/ws3" || exit 1
cat > mani.yaml <<EOF
projects:
  toplevel:
    path: c4
    url: $(url oa)
    clone: fleet-repo clone toplevel
EOF
FR clone toplevel > "$TMP/out" 2>&1; rc=$?
check "path naming the container: refused, the directory above is NOT made a repository" '[ "$rc" != 0 ] && [ ! -e "$TMP/ws3/.bare" ] && [ ! -e "$TMP/ws3/.git" ]'
cat > mani.yaml <<EOF
projects:
  mismatch:
    path: c3/main
    url: $(url os)
    clone: fleet-repo clone mismatch
EOF
FR clone mismatch > "$TMP/out" 2>&1
check "wrong default in path: warned, and the real default is created instead" 'grep -q "default branch is develop" "$TMP/out" && [ -d c3/develop ] && [ ! -e c3/main ]'

# --- update --------------------------------------------------------------------------------------
cd "$WS" || exit 1
git init -q -b main "$TMP/src-up"; git -C "$TMP/src-up" commit -q --allow-empty -m one; git -C "$TMP/src-up" branch develop
git clone -q --bare "$TMP/src-up" "$TMP/up.git"
cat > mani.yaml <<EOF
projects:
  up:
    path: up/main
    url: $(url up)
    scope: up
    clone: fleet-repo clone up
    container:
      branches: default
    worktrees:
      - name: develop
        path: ../develop
EOF
FR clone up >/dev/null 2>&1
git clone -q "$TMP/up.git" "$TMP/pusher"
git -C "$TMP/pusher" commit -q --allow-empty -m two-main; git -C "$TMP/pusher" push -q origin main
git -C "$TMP/pusher" checkout -q develop; git -C "$TMP/pusher" commit -q --allow-empty -m two-dev; git -C "$TMP/pusher" push -q origin develop
cd "$WS/up/main" || exit 1
FR update > "$TMP/out" 2>&1; rc=$?
check "update, run inside a repository: both worktrees fast-forwarded, exit 0" \
  '[ "$rc" = 0 ] && [ "$(git -C "$WS/up/main" rev-parse HEAD)" = "$(git -C "$TMP/pusher" rev-parse origin/main)" ] && [ "$(git -C "$WS/up/develop" rev-parse HEAD)" = "$(git -C "$TMP/pusher" rev-parse origin/develop)" ]'
check "update: one line per worktree says what happened" '[ "$(grep -c "fast-forwarded" "$TMP/out")" = 2 ]'
cd "$WS" || exit 1
FR update --project up > "$TMP/out" 2>&1; rc=$?
check "update --project, nothing new: exit 0, says up to date" '[ "$rc" = 0 ] && [ "$(grep -c "already up to date" "$TMP/out")" = 2 ]'
git -C "$WS/up/develop" commit -q --allow-empty -m local-only
git -C "$TMP/pusher" commit -q --allow-empty -m three-dev; git -C "$TMP/pusher" push -q origin develop
git -C "$TMP/pusher" checkout -q main; git -C "$TMP/pusher" commit -q --allow-empty -m three-main; git -C "$TMP/pusher" push -q origin main
before_dev=$(git -C "$WS/up/develop" rev-parse HEAD)
FR update --project up > "$TMP/out" 2>&1; rc=$?
check "update: a worktree that cannot fast-forward is reported by name, and the exit is 1" '[ "$rc" = 1 ] && grep -q "CANNOT fast-forward develop" "$TMP/out"'
check "update: ...it is left as it was, and the other worktree still moved" \
  '[ "$(git -C "$WS/up/develop" rev-parse HEAD)" = "$before_dev" ] && [ "$(git -C "$WS/up/main" rev-parse HEAD)" = "$(git -C "$TMP/pusher" rev-parse origin/main)" ]'
cd "$TMP/nomani" || exit 1
FLEET_RECORD="$WS/mani.yaml" FR update > "$TMP/out" 2>&1; rc=$?
check "update from a directory no entry's scope contains: exit 2, says how to name one" '[ "$rc" = 2 ] && grep -q -- "--project" "$TMP/out"'

# --- check ---------------------------------------------------------------------------------------
cd "$WS" || exit 1
chk_manifest() {  # $1 = the project's url
  cat > mani.yaml <<EOF
projects:
  chk:
    path: chk/main
    url: $1
    clone: fleet-repo clone chk
    container:
      branches: [develop]
    worktrees:
      - name: develop
        path: ../develop
EOF
}
chk_manifest "$(url ob)"
FR clone chk >/dev/null 2>&1
FR check > "$TMP/out" 2>&1; rc=$?
check "check: a container that matches its declaration exits 0" '[ "$rc" = 0 ] && grep -q "match their declarations" "$TMP/out"'
FR check chk > "$TMP/out" 2>&1; rc=$?
check "check <project>: the same, by name" '[ "$rc" = 0 ]'

git -C chk/develop branch --unset-upstream
FR check chk > "$TMP/out" 2>&1; rc=$?
check "check: a missing upstream is drift (exit 1, named)" '[ "$rc" = 1 ] && grep -q "^\[no-upstream\] chk" "$TMP/out"'
FR clone chk >/dev/null 2>&1

mv chk/develop chk/develop.away
FR check chk > "$TMP/out" 2>&1; rc=$?
check "check: a missing worktree is drift" '[ "$rc" = 1 ] && grep -q "^\[missing-worktree\] chk" "$TMP/out"'
mv chk/develop.away chk/develop

git --git-dir=chk/.bare remote set-branches --add origin topic/x
FR check chk > "$TMP/out" 2>&1; rc=$?
check "check: refspecs that differ from the declared set are drift, naming the difference" '[ "$rc" = 1 ] && grep -q "^\[refspec-drift\] chk" "$TMP/out" && grep -q "topic/x" "$TMP/out"'
git --git-dir=chk/.bare config --fixed-value --unset-all remote.origin.fetch "+refs/heads/topic/x:refs/remotes/origin/topic/x"
FR check chk > "$TMP/out" 2>&1; rc=$?
check "check: and clean again once the refspec is removed" '[ "$rc" = 0 ]'

mkdir -p "$HOME/.config/worktrunk"; printf '[projects."other.example/org/else"]\n' > "$HOME/.config/worktrunk/config.toml"
chk_manifest https://code.example.org/org/chk.git
FR check chk > "$TMP/out" 2>&1; rc=$?
check "check: a container the generated worktrunk config has no table for is drift" '[ "$rc" = 1 ] && grep -q "^\[worktrunk-missing\] chk" "$TMP/out"'
printf '[projects."code.example.org/org/chk"]\n' >> "$HOME/.config/worktrunk/config.toml"
FR check chk > "$TMP/out" 2>&1; rc=$?
check "check: ...and clean once wt-config-gen has written one" '[ "$rc" = 0 ]'
rm -rf "$HOME/.config"
chk_manifest "$(url ob)"

mkdir -p plainone/main; git init -q -b main plainone/main
cat > mani.yaml <<EOF
projects:
  nocont:
    path: nocont/main
    url: $(url os)
    clone: fleet-repo clone nocont
  plainone:
    path: plainone/main
    url: $(url os)
    container:
      branches: default
  skipped:
    path: skipped/main
    url: $(url os)
    sync: false
    container:
      branches: default
  notacontainer:
    path: notacontainer
    url: $(url os)
    clone: git clone $(url os) notacontainer
EOF
FR check > "$TMP/out" 2>&1; rc=$?
check "check: nothing on disk where a container is declared is drift" '[ "$rc" = 1 ] && grep -q "^\[no-container\] nocont" "$TMP/out"'
check "check: a plain clone where a container is declared is drift" 'grep -q "^\[plain-clone\] plainone" "$TMP/out"'
check "check: an entry with sync: false is not drift; an entry declaring no container is not examined" '! grep -q skipped "$TMP/out" && ! grep -q notacontainer "$TMP/out"'
printf 'projects: [\n' > mani.yaml
FR check > "$TMP/out" 2>&1; rc=$?
check "check: an unreadable manifest is exit 2, never 'clean'" '[ "$rc" = 2 ] && ! grep -q "match their declarations" "$TMP/out"'
FR clone anything > "$TMP/out" 2>&1; rc=$?
check "clone: an unreadable manifest is exit 2 as well" '[ "$rc" = 2 ]'

# --- as mani's clone: command --------------------------------------------------------------------
if ! command -v mani >/dev/null 2>&1; then
  printf '  SKIP the mani arm: mani is not installed\n'; skip=1
else
  mkdir -p "$TMP/mws"; cd "$TMP/mws" || exit 1
  cat > mani.yaml <<EOF
projects:
  viamani:
    path: m1/develop
    url: $(url os)
    scope: m1
    clone: fleet-repo clone viamani
    container:
      branches: default
    worktrees:
      - name: feature
        path: ../feature
EOF
  NO_COLOR=1 mani sync viamani > "$TMP/out" 2>&1
  check "mani sync: a clone: line calling fleet-repo gives a bare container with the declared worktree" \
    '[ "$(cat m1/.git 2>/dev/null)" = "gitdir: ./.bare" ] && [ -d m1/develop ] && [ "$(git -C m1/feature branch --show-current)" = feature ]'
  check "mani sync: only the declared set was fetched" '[ "$(rrefs m1)" = "develop feature" ]'
  check "mani sync: the worktrees have upstreams" '[ "$(upstream m1/develop)" = origin/develop ] && [ "$(upstream m1/feature)" = origin/feature ]'
  rm -rf m1/feature; git -C m1 worktree prune; NO_COLOR=1 mani sync viamani > "$TMP/out" 2>&1
  check "mani sync: a re-sync restores a deleted worktree" '[ -d m1/feature ]'
  NO_COLOR=1 mani exec --all --parallel 'fleet-repo update' > "$TMP/out" 2>&1
  check "mani exec ... 'fleet-repo update' runs in a project's path and resolves it" 'grep -q "already up to date" "$TMP/out" || grep -q "fast-forwarded" "$TMP/out"'
fi

printf 'passed: %s   failed: %s%s\n' "$pass" "$fail" "$( [ "$skip" = 1 ] && printf '   (mani arm skipped)')"
[ "$fail" -eq 0 ]
