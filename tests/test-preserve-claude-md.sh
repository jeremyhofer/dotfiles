#!/bin/sh
# Test preserve-claude-md: before the base first writes ~/.claude/CLAUDE.md, a copy it did not write
# (one kept by hand, or rendered by another chezmoi instance) is saved beside it, because chezmoi
# overwrites a file it has never managed without asking. A file already carrying the base's marker
# is left alone, a second run is silent, and an earlier, different copy is never overwritten.
set -eu
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../setup/preserve-claude-md"
tmp=$(mktemp -d "$_TMP/test-preserve-claude-md.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
marker='<!-- dotfiles-base: ~/.claude/CLAUDE.md -->'

run() { env -i PATH="/usr/bin:/bin" HOME="$1" sh "$script" 2>&1; }

# --- no file yet -> nothing to preserve, silent, exit 0 ---
h="$tmp/empty"; mkdir -p "$h"
out=$(run "$h") || { echo "FAIL: expected exit 0 with no CLAUDE.md"; echo "$out"; exit 1; }
[ -z "$out" ] || { echo "FAIL: expected silence with no CLAUDE.md, got: $out"; exit 1; }
[ ! -e "$h/.claude/CLAUDE.md.before-base" ] || { echo "FAIL: made a copy of nothing"; exit 1; }

# --- a hand-kept file -> copied beside it, byte for byte, with a notice naming both paths ---
h="$tmp/hand"; mkdir -p "$h/.claude"
printf 'my own standards\n' > "$h/.claude/CLAUDE.md"
out=$(run "$h") || { echo "FAIL: expected exit 0 after preserving"; echo "$out"; exit 1; }
cmp -s "$h/.claude/CLAUDE.md" "$h/.claude/CLAUDE.md.before-base" \
  || { echo "FAIL: the hand-kept file was not copied byte for byte"; exit 1; }
printf '%s\n' "$out" | grep -qF 'CLAUDE.md.before-base' || { echo "FAIL: notice does not name the copy"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -qF '.dotlocal/claude/CLAUDE.md' || { echo "FAIL: notice does not name the fragment"; echo "$out"; exit 1; }

# --- the same file again -> the copy already holds it, silent ---
out=$(run "$h") || { echo "FAIL: second run did not exit 0"; echo "$out"; exit 1; }
[ -z "$out" ] || { echo "FAIL: expected silence when the copy already holds this file, got: $out"; exit 1; }

# --- a different unmarked file while an earlier copy exists -> refuse, keep both ---
printf 'edited since\n' > "$h/.claude/CLAUDE.md"
out=$(run "$h") && rc=0 || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: expected a refusal rather than overwriting the earlier copy"; exit 1; }
grep -qF 'my own standards' "$h/.claude/CLAUDE.md.before-base" || { echo "FAIL: the earlier copy was overwritten"; exit 1; }
printf '%s\n' "$out" | grep -qF 'CLAUDE.md.before-base' || { echo "FAIL: refusal does not name the copy"; echo "$out"; exit 1; }

# --- the base's own file (marker present) -> nothing to preserve, silent ---
h="$tmp/base"; mkdir -p "$h/.claude"
printf '%s\n# Global operating standards\n' "$marker" > "$h/.claude/CLAUDE.md"
out=$(run "$h") || { echo "FAIL: expected exit 0 for the base's own file"; echo "$out"; exit 1; }
[ -z "$out" ] || { echo "FAIL: expected silence for the base's own file, got: $out"; exit 1; }
[ ! -e "$h/.claude/CLAUDE.md.before-base" ] || { echo "FAIL: copied the base's own file"; exit 1; }

echo PASS
