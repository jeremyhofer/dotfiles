#!/usr/bin/env bash
# Tests for claude-trust-check -- which manifest directories still need a Claude Code trust click.
#
# THIS SUITE DRIVES ONLY THE COMMAND LINE. It runs the tool as a process against local repositories
# and fixture state files, and reads the verdict from its output and exit code.
#
# WHAT IS AT RISK. The failures worth guarding look like success: a bare container checked under the
# wrong key (a `.bare` container satisfied by an entry at its parent, so a directory that will be
# refused reads as trusted); an ancestor's trust counted for a repository nested below it; a stale
# older state file overriding the live one; a missing state file reported as "everything untrusted",
# which sends a person to click through a dialog they may already have accepted.
#
# ISOLATION. HOME is a scratch directory with an empty GIT_CONFIG_GLOBAL, and every Claude Code
# state file is a fixture under it (CLAUDE_CONFIG_DIR and $HOME/.claude.json). The real files are
# never read or written. fleet-decl comes through a wrapper on PATH.

set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="${CLAUDE_TRUST_CHECK:-$HERE/private_dot_local/bin/executable_claude-trust-check}"
DECL="$HERE/private_dot_local/bin/executable_fleet-decl"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

[ -f "$TOOL" ] || { printf 'claude-trust-check: not found at %s\n' "$TOOL"; exit 1; }
for need in yq jq git; do
  command -v "$need" >/dev/null 2>&1 || { printf 'claude-trust-check tests: %s absent, cannot run\n' "$need"; exit 1; }
done

t=${TMPDIR:-/tmp}; t=${t%/}
TMP=$(mktemp -d "$t/test-ctc.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
unset FLEET_RECORD FLEET_DEVEL_ROOT XDG_CONFIG_HOME
export CLAUDE_CONFIG_DIR="$HOME/.claude"; mkdir -p "$CLAUDE_CONFIG_DIR"
LIVE="$CLAUDE_CONFIG_DIR/.config.json"
OLD="$HOME/.claude.json"

mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$DECL" > "$TMP/bin/fleet-decl"
chmod +x "$TMP/bin/fleet-decl"; export PATH="$TMP/bin:$PATH"

WS="$TMP/ws"; mkdir -p "$WS"

# --- repositories --------------------------------------------------------------------------------
git init -q -b main "$TMP/src"; git -C "$TMP/src" commit -q --allow-empty -m one

git clone -q "$TMP/src" "$WS/plain"                                  # a plain clone
git clone -q "$TMP/src" "$WS/plain2"

git clone -q --bare "$TMP/src" "$WS/cnew/.git"                        # container, bare repo .git
git --git-dir="$WS/cnew/.git" worktree add -q "$WS/cnew/main" main
git --git-dir="$WS/cnew/.git" worktree add -q -b feat "$WS/cnew/feat" main

git clone -q --bare "$TMP/src" "$WS/cold/.bare"                       # old container, bare repo .bare
printf 'gitdir: ./.bare\n' > "$WS/cold/.git"
git -C "$WS/cold" worktree add -q main main

mkdir -p "$WS/outer"; git clone -q "$TMP/src" "$WS/outer/inner"       # a repo nested in a plain dir
mkdir -p "$WS/notrepo"                                                # exists, no repository

# --- fixtures ------------------------------------------------------------------------------------
# mani NAME=path[:launch] ...: write the manifest ($WS/mani.yaml) with those projects.
mani() {
  { echo 'projects:'
    for a in "$@"; do
      n=${a%%=*}; r=${a#*=}; p=${r%%:*}
      printf '  %s:\n    path: %s\n' "$n" "$p"
      case "$r" in *:*) printf '    canonicalLaunchDir: %s\n' "${r#*:}" ;; esac
    done
  } > "$WS/mani.yaml"
}
# state FILE PATH...: a state file trusting exactly those paths.
state() {
  f=$1; shift
  { printf '{"numStartups":3,"projects":{'
    sep=""
    for p in "$@"; do printf '%s"%s":{"hasTrustDialogAccepted":true}' "$sep" "$p"; sep=","; done
    printf '}}'
  } > "$f"
}
nostate() { rm -f "$LIVE" "$OLD"; }
run() {  # run [args]: OUT and RC
  OUT=$(FLEET_RECORD="$WS/mani.yaml" sh "$TOOL" "$@" 2>&1); RC=$?
}
line() { printf '%s\n' "$OUT" | grep -E "^(trusted|UNTRUSTED|not-a-repo) +$1(:|,| |\$)" | head -1; }
verdict() { line "$1" | awk '{print $1}'; }

# --- plain clone ---------------------------------------------------------------------------------
echo "plain clone"
mani p=plain; nostate; state "$LIVE" "$WS/plain"; run
check "plain clone trusted, exit 0" '[ "$(verdict p)" = trusted ] && [ $RC -eq 0 ]'
state "$LIVE" "$WS/plain2"; run
check "plain clone untrusted, exit 1, names how to fix it" '[ "$(verdict p)" = UNTRUSTED ] && [ $RC -eq 1 ] && printf "%s" "$OUT" | grep -q "accept the trust prompt: cd $WS/plain && claude"'

# --- containers ----------------------------------------------------------------------------------
echo "containers"
mani c=cnew/main; state "$LIVE" "$WS/cnew"; run
check ".git container is keyed at the container root" '[ "$(verdict c)" = trusted ]'
state "$LIVE" "$WS/cnew/.git" "$WS/cnew/main"; run
check ".git container is NOT satisfied by its .git dir or its worktree" '[ "$(verdict c)" = UNTRUSTED ]'

mani o=cold/main; state "$LIVE" "$WS/cold/.bare"; run
check "old .bare container is keyed at <c>/.bare" '[ "$(verdict o)" = trusted ]'
state "$LIVE" "$WS/cold" "$WS/cold/main"; run
check "old .bare container is NOT satisfied by an entry at <c>" '[ "$(verdict o)" = UNTRUSTED ]'

mani w=cnew/feat; state "$LIVE" "$WS/cnew"; run
check "a worktree resolves to its container's root" '[ "$(verdict w)" = trusted ]'

# --- ancestor ------------------------------------------------------------------------------------
echo "ancestor trust"
mani n=outer/inner; state "$LIVE" "$WS/outer" "$WS"; run
check "an ancestor's trust does not cover a nested repository" '[ "$(verdict n)" = UNTRUSTED ]'
state "$LIVE" "$WS/outer/inner"; run
check "the nested repository's own entry does" '[ "$(verdict n)" = trusted ]'

# --- launch dirs, dedupe, skips ------------------------------------------------------------------
echo "enumeration"
mani cn=cnew/main:cnew/feat; state "$LIVE" "$WS/cnew"; run
check "a project and its launch dir in one repository are one line" '[ "$(printf "%s\n" "$OUT" | grep -c "^trusted")" -eq 1 ] && printf "%s" "$OUT" | grep -q "^trusted    cn$" && printf "%s" "$OUT" | grep -q "^1 trust root(s)"'
state "$LIVE" "$WS/plain"; run
check "launch dir is the directory suggested, over the project path" 'printf "%s" "$OUT" | grep -q "cd $WS/cnew/feat && claude" && ! printf "%s" "$OUT" | grep -q "cd $WS/cnew/main && claude"'

mani x=cnew/main y=cnew/feat; state "$LIVE" "$WS/plain"; run
check "projects sharing a root share a line" 'printf "%s" "$OUT" | grep -q "^UNTRUSTED  x, y: "'

mani ghost=nowhere/at/all p=plain; state "$LIVE" "$WS/plain"; run
check "a non-existent path is skipped silently, exit 0" '[ $RC -eq 0 ] && ! printf "%s" "$OUT" | grep -q ghost'

mani nr=notrepo p=plain; state "$LIVE" "$WS/plain"; run
check "a path that is not a repository is reported, exit 1" '[ "$(verdict nr)" = not-a-repo ] && [ $RC -eq 1 ]'

# --- which state file ----------------------------------------------------------------------------
echo "state files"
mani p=plain
nostate; state "$LIVE" "$WS/plain2"; state "$OLD" "$WS/plain"; run
check ".config.json is authoritative over a stale ~/.claude.json that says trusted" '[ "$(verdict p)" = UNTRUSTED ]'
nostate; state "$OLD" "$WS/plain"; run
check "falls back to ~/.claude.json when .config.json is absent" '[ "$(verdict p)" = trusted ] && [ $RC -eq 0 ]'
nostate; printf '{"numStartups":1}' > "$LIVE"; state "$OLD" "$WS/plain"; run
check ".config.json without a projects object does not decide" '[ "$(verdict p)" = trusted ]'
nostate; run
check "neither file: exit 3, no verdicts, names what was looked for" '[ $RC -eq 3 ] && ! printf "%s" "$OUT" | grep -q "UNTRUSTED" && printf "%s" "$OUT" | grep -q "~/.claude/.config.json" && printf "%s" "$OUT" | grep -q "~/.claude.json"'

# --- manifest ------------------------------------------------------------------------------------
echo "manifest"
state "$LIVE" "$WS/plain"
printf 'projects: [unclosed\n  : :\n' > "$WS/mani.yaml"; run
check "an unreadable manifest is exit 2" '[ $RC -eq 2 ]'
OUT=$(FLEET_RECORD="$WS/missing.yaml" sh "$TOOL" 2>&1); RC=$?
check "a FLEET_RECORD that does not exist is exit 2" '[ $RC -eq 2 ]'

# --- --names-only --------------------------------------------------------------------------------
echo "--names-only"
mani p=plain c=cnew/main:cnew/feat o=cold/main; state "$LIVE" "$WS/plain"; run --names-only
check "--names-only prints exactly the untrusted names, no paths" '[ "$OUT" = "c
o" ] && ! printf "%s" "$OUT" | grep -q "/"'
check "--names-only keeps the exit status" '[ $RC -eq 1 ]'
nostate; run --names-only
check "--names-only with no state is exit 3 and prints no names on stdout" '[ $RC -eq 3 ] && [ -z "$(FLEET_RECORD="$WS/mani.yaml" sh "$TOOL" --names-only 2>/dev/null)" ]'
# --- opting out: claudeTrust: false --------------------------------------------------------------
echo "claudeTrust: false"
# An untrusted project opted out is not reported and does not fail the exit; the summary names it.
# A project and its launch directory are both left out; true, or no key, is still checked.
{ echo 'projects:'
  printf '  sec:\n    path: plain2\n    claudeTrust: false\n'
  printf '  c:\n    path: cnew/main\n    canonicalLaunchDir: cnew/feat\n    claudeTrust: false\n'
  printf '  p:\n    path: plain\n    claudeTrust: true\n'
} > "$WS/mani.yaml"
state "$LIVE" "$WS/plain"; run
check "opted-out projects are not reported and do not fail the exit" '[ -z "$(line sec)" ] && [ -z "$(line c)" ] && [ $RC -eq 0 ]'
check "the summary names the opted-out projects" 'printf "%s" "$OUT" | grep -q "^opted out (claudeTrust: false), not checked: sec, c$"'
check "claudeTrust: true is still checked" '[ "$(verdict p)" = trusted ]'
run --names-only
check "--names-only lists no opted-out project" '[ -z "$OUT" ] && [ $RC -eq 0 ]'
nostate; state "$LIVE"
{ echo 'projects:'
  printf '  p:\n    path: plain\n    claudeTrust: true\n'
  printf '  q:\n    path: plain2\n'
} > "$WS/mani.yaml"
run
check "true or no key: an untrusted project is still reported" '[ "$(verdict p)" = UNTRUSTED ] && [ "$(verdict q)" = UNTRUSTED ] && ! printf "%s" "$OUT" | grep -q "opted out"'

run --help
check "--help exits 0" '[ $RC -eq 0 ] && printf "%s" "$OUT" | grep -q "usage\|claude-trust-check"'

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
