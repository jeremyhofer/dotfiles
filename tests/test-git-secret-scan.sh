#!/bin/sh
# test-git-secret-scan.sh — contract tests for the global secret-scan pre-commit hook.
#
# Every case makes a REAL commit through git's configured-hook machinery, wired exactly as
# ~/.gitconfig wires it. Calling the script directly would pass even if git never ran it, and a
# scan that is never invoked refuses nothing while looking installed.
#
# The caller's own git config is shut out (GIT_CONFIG_GLOBAL=/dev/null) so their hooks and signing
# settings cannot change the result. The fake secrets are assembled at runtime and never appear
# whole in this file, which would otherwise be refused by the hook it tests.
#
# Needs gitleaks on PATH; without it the suite reports a failure rather than skipping, because the
# hook itself refuses every commit on a machine without gitleaks.
#
# Run: sh ~/.local/share/chezmoi/tests/test-git-secret-scan.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$root/private_dot_local/bin/executable_git-secret-scan"
FLOOR="$root/dot_config/gitleaks/floor.toml"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# A fake age identity: the prefix split so this file never holds the whole token, then 58 characters
# from age's bech32 alphabet, which the default rule requires.
alphabet=QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L
FAKE_AGE="AGE-SECRET-K""EY-1${alphabet}LA7UM6ECHK45NJ3S0WDVT2FG8X"

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

command -v gitleaks >/dev/null 2>&1 || { no "gitleaks is on PATH (every other case needs it)"; echo "passed: $pass   failed: $fail"; exit 1; }

cfg=$(mktemp -d)
mkdir -p "$cfg/gitleaks"
cp "$FLOOR" "$cfg/gitleaks/floor.toml"
export XDG_CONFIG_HOME="$cfg"
trap 'rm -rf "$cfg"' EXIT

newrepo() {
  r=$(mktemp -d)
  git -C "$r" init -q .
  git -C "$r" config user.name Tester
  git -C "$r" config user.email tester@example.invalid
  git -C "$r" config commit.gpgsign false
  git -C "$r" config hook.secret-scan.command "sh '$HOOK'"
  git -C "$r" config hook.secret-scan.event pre-commit
  echo "$r"
}
# try REPO FILE CONTENT -- stage CONTENT in FILE and attempt a commit; prints the hook's output.
try() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"; git -C "$1" add -- "$2"
  git -C "$1" commit -q -m probe 2>&1
}
commits() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
refused() {  # refused LABEL REPO BEFORE
  if [ "$(commits "$2")" = "$3" ]; then ok "$1"; else no "$1 (the commit landed)"; fi
}
landed() {   # landed LABEL REPO BEFORE
  if [ "$(commits "$2")" -gt "$3" ]; then ok "$1"; else no "$1 (the commit was refused)"; fi
}
canary_config() {  # a repo config that defines only its own rule, which drops the default rules
  printf '[[rules]]\nid = "custom-canary"\nregex = %s\n' "'''CANARY-[0-9]{6}'''" > "$1/.gitleaks.toml"
}

echo "== clean content commits =="
r=$(newrepo); b=$(commits "$r")
try "$r" a.txt "nothing secret here" >/dev/null
landed "a clean first commit lands" "$r" "$b"
rm -rf "$r"

echo "== a secret is refused, and not printed =="
r=$(newrepo); try "$r" a.txt "hello" >/dev/null; b=$(commits "$r")
out=$(try "$r" b.txt "k=$FAKE_AGE")
refused "a staged age identity is refused" "$r" "$b"
case "$out" in *"$FAKE_AGE"*) no "the secret is redacted from the output" ;; *) ok "the secret is redacted from the output" ;; esac
case "$out" in *age-secret-key*) ok "the refusal names the rule" ;; *) no "the refusal names the rule" ;; esac
rm -rf "$r"

echo "== a repo's own config cannot switch the default rules off =="
r=$(newrepo); canary_config "$r"; try "$r" a.txt "hello" >/dev/null; b=$(commits "$r")
try "$r" b.txt "k=$FAKE_AGE" >/dev/null
refused "an age identity is refused despite a config that drops the defaults" "$r" "$b"
rm -rf "$r"

echo "== a repo's own config adds its rules =="
r=$(newrepo); canary_config "$r"; try "$r" a.txt "hello" >/dev/null; b=$(commits "$r")
try "$r" b.txt "CANARY-123456" >/dev/null
refused "a match for the repo's custom rule is refused" "$r" "$b"
git -C "$r" reset -q
# Git runs hooks from the top of the worktree, so this holds even for a hook that resolved the
# config relatively; it pins the behaviour, and is not evidence for the explicit path.
(cd "$r" && mkdir -p sub && cd sub && printf 'CANARY-654321\n' > c.txt && git add c.txt && git commit -q -m probe >/dev/null 2>&1)
refused "the repo's rules still apply to a commit made from a subdirectory" "$r" "$b"
rm -rf "$r"

echo "== commit -a stages through a temporary index, which is still scanned =="
r=$(newrepo); try "$r" a.txt "hello" >/dev/null; b=$(commits "$r")
printf 'k=%s\n' "$FAKE_AGE" > "$r/a.txt"
git -C "$r" commit -q -a -m probe >/dev/null 2>&1
refused "a secret committed with -a is refused" "$r" "$b"
rm -rf "$r"

echo "== a linked worktree is scanned =="
r=$(newrepo); try "$r" a.txt "hello" >/dev/null
w="$r.wt"; git -C "$r" worktree add -q "$w" 2>/dev/null; b=$(commits "$w")
try "$w" b.txt "k=$FAKE_AGE" >/dev/null
refused "a secret committed in a worktree is refused" "$w" "$b"
git -C "$r" worktree remove --force "$w" 2>/dev/null; rm -rf "$r" "$w"

echo "== the hook refuses rather than skips when it cannot scan =="
r=$(newrepo); try "$r" a.txt "hello" >/dev/null; b=$(commits "$r")
# A PATH holding only git: gitleaks usually lives beside everything else in a system directory, so
# trimming PATH to the system directories would not hide it. Git runs the hook through an absolute
# shell path, so the hook itself still starts.
bin=$(mktemp -d); ln -s "$(command -v git)" "$bin/git"; ln -s "$(command -v sh)" "$bin/sh"
mkdir -p "$r/sub"; printf 'nothing secret\n' > "$r/sub/b.txt"; git -C "$r" add sub/b.txt
out=$(PATH="$bin" "$bin/git" -C "$r" commit -q -m probe 2>&1)
refused "gitleaks missing: the commit is refused" "$r" "$b"
case "$out" in *gitleaks*) ok "the refusal says gitleaks is missing" ;; *) no "the refusal says gitleaks is missing (got: $out)" ;; esac
rm -rf "$bin"
mv "$cfg/gitleaks/floor.toml" "$cfg/gitleaks/floor.toml.off"
try "$r" c.txt "nothing secret" >/dev/null
refused "floor config missing: the commit is refused" "$r" "$b"
mv "$cfg/gitleaks/floor.toml.off" "$cfg/gitleaks/floor.toml"
rm -rf "$r"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
