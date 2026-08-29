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

echo "PASS"
