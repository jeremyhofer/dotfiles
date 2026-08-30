#!/bin/sh
# Test: the BASE ships chezmoi-overlay as a real SCRIPT (not a zshrc function), it fails loudly
# when no overlay is configured, and the zshrc no longer defines a shadowing function.
#
# The point of the script form is that it works in NON-INTERACTIVE shells (ssh 'zsh -ls'), where
# a .zshrc function does not exist at all. The third check is the one that would fail if someone
# reintroduced the function: two definitions would drift, and the function would win interactively.
set -eu
# macOS sets TMPDIR WITH a trailing slash, so a naive "$_TMP/x.XXXXXX" yields a
# path containing "//". Harmless for file I/O and fatal the moment such a path is compared
# textually against one a tool reports back normalized. Strip it once, here.
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
co="$here/../private_dot_local/bin/executable_chezmoi-overlay"
zshrc="$here/../dot_zshrc.tmpl"

[ -f "$co" ] || { echo "FAIL: base does not ship chezmoi-overlay"; exit 1; }
echo "ok:   base ships chezmoi-overlay"

# 1. No overlay configured -> must FAIL loudly (exit 1), unlike spell-capture's silent no-op.
tmp=$(mktemp -d "$_TMP/test-chezmoi-overlay.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
HOME="$tmp" sh "$co" diff >"$tmp/out" 2>"$tmp/err" && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: expected exit 1 without an overlay, got ${rc:-0}"; exit 1; }
grep -q 'overlay not set up' "$tmp/err" || { echo "FAIL: error text does not explain the cause"; exit 1; }
echo "ok:   fails loudly (exit 1, explained) when no overlay is configured"

# 2. It must not require an interactive shell: run it under plain `sh` with no rc files at all.
#    (Covered by check 1 already running under sh -- asserted explicitly so the intent is legible.)
head -1 "$co" | grep -q '^#!/bin/sh$' || { echo "FAIL: not a POSIX sh script"; exit 1; }
echo "ok:   POSIX sh, so no interactive-shell dependency"

# 3. The zshrc must NOT define a competing function.
if grep -qE '^[[:space:]]*chezmoi-overlay\(\)' "$zshrc"; then
  echo "FAIL: dot_zshrc.tmpl still defines a chezmoi-overlay function — it shadows the script"
  exit 1
fi
echo "ok:   zshrc defines no shadowing function"

# 4. It must not depend on an inherited PATH to find chezmoi ITSELF.
#    This script exists because a shell FUNCTION was unreachable over ssh -- then ran a bare
#    `exec chezmoi`, leaving its DEPENDENCY with the identical problem one level down. On a
#    Homebrew machine chezmoi lives in /opt/homebrew/bin, which .zshenv does not add to a
#    non-interactive PATH, so `ssh <host> chezmoi-overlay diff` died 127 on stderr while stdout
#    stayed empty -- and a caller filtering stdout for diff headers read that as "in sync".
#    Measured 2026-08-30 on the darwin node: reported nothing pending while 3 commits behind.
grep -q 'command -v chezmoi' "$co" \
  || { echo "FAIL: chezmoi-overlay does not resolve the chezmoi binary; a bare exec depends on PATH"; exit 1; }
grep -q '/opt/homebrew/bin/chezmoi' "$co" \
  || { echo "FAIL: no Homebrew prefix in the fallback search; that is the machine that breaks"; exit 1; }
grep -qE 'exec "\$CHEZMOI"' "$co" \
  || { echo "FAIL: still exec'ing chezmoi by bare name rather than the resolved path"; exit 1; }
echo "ok:   resolves the chezmoi binary rather than trusting inherited PATH"

#    ...and when it genuinely cannot find one, it must fail LOUDLY rather than return a silent 0.
ctl="$(mktemp -d)"
sed 's#/opt/homebrew/bin/chezmoi /usr/local/bin/chezmoi "$HOME/.local/bin/chezmoi" /usr/bin/chezmoi#/nope/a /nope/b#' "$co" > "$ctl/co"
mkdir -p "$ctl/emptybin"
# Capture status WITHOUT letting `set -e` abort on the very non-zero exit being asserted.
if out=$(env -i HOME="$HOME" PATH="$ctl/emptybin" /bin/sh "$ctl/co" diff 2>&1); then rc=0; else rc=$?; fi
rm -rf "$ctl"
[ "$rc" -eq 127 ] || { echo "FAIL: chezmoi absent everywhere gave exit $rc, not a loud 127"; exit 1; }
case "$out" in *"not on PATH"*) ;; *) echo "FAIL: silent failure; said: $out"; exit 1 ;; esac
echo "ok:   fails loudly (127, naming the PATH) when chezmoi cannot be found at all"

echo "PASS"
