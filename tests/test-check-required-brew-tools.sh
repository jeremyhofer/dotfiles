#!/bin/sh
# Test check-required-brew-tools: refuses (naming the tool and the fix) when a Brewfile formula
# marked REQUIRED cannot be found, is silent and exits 0 once it can, and resolves via PATH first
# then BREW_PREFIXES -- all against fixtures, so this runs on Linux with no real Homebrew involved.
set -eu
# macOS sets TMPDIR WITH a trailing slash, so a naive "$_TMP/x.XXXXXX" yields a
# path containing "//". Harmless for file I/O and fatal the moment such a path is compared
# textually against one a tool reports back normalized. Strip it once, here.
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../setup/check-required-brew-tools"
tmp=$(mktemp -d "$_TMP/test-check-required-brew-tools.XXXXXX"); trap 'rm -rf "$tmp"' EXIT

brewfile="$tmp/Brewfile"
cat > "$brewfile" <<'EOF'
brew "chezmoi"
brew "fakerequiredtool"  # planted for the test. REQUIRED, not optional.
brew "unrelatedtool"
EOF

prefixdir="$tmp/prefix"
mkdir -p "$prefixdir"

# --- missing: fakerequiredtool is nowhere findable -> refuse, naming the tool and the fix ---
out=$(env -i PATH="/usr/bin:/bin" BREW_PREFIXES="$prefixdir" sh "$script" "$brewfile" 2>&1) && rc=0 || rc=$?
echo "-- missing case --"; echo "$out"
[ "$rc" -ne 0 ] || { echo "FAIL: expected non-zero exit when a REQUIRED tool is missing"; exit 1; }
printf '%s\n' "$out" | grep -qF 'fakerequiredtool' || { echo "FAIL: message does not name the missing tool"; exit 1; }
printf '%s\n' "$out" | grep -qF 'brew bundle' || { echo "FAIL: message does not name the fix"; exit 1; }
printf '%s\n' "$out" | grep -qF 'unrelatedtool' && { echo "FAIL: flagged a formula with no REQUIRED marker"; exit 1; } || true
printf '%s\n' "$out" | grep -qF '"chezmoi"' && { echo "FAIL: flagged a formula with no REQUIRED marker"; exit 1; } || true

# --- present via BREW_PREFIXES fallback (deliberately NOT on PATH) -> silent, exit 0 ---
cat > "$prefixdir/fakerequiredtool" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$prefixdir/fakerequiredtool"
out=$(env -i PATH="/usr/bin:/bin" BREW_PREFIXES="$prefixdir" sh "$script" "$brewfile" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: expected exit 0 once the tool is present via BREW_PREFIXES"; echo "$out"; exit 1; }
[ -z "$out" ] || { echo "FAIL: expected silence on success, got: $out"; exit 1; }

# --- present via plain PATH (BREW_PREFIXES pointed elsewhere) -> silent, exit 0 ---
pathdir="$tmp/onpath"; mkdir -p "$pathdir"
cat > "$pathdir/fakerequiredtool" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$pathdir/fakerequiredtool"
out=$(env -i PATH="$pathdir:/usr/bin:/bin" BREW_PREFIXES="$tmp/no-such-prefix" sh "$script" "$brewfile" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: expected exit 0 when the tool resolves via PATH"; echo "$out"; exit 1; }
[ -z "$out" ] || { echo "FAIL: expected silence on success, got: $out"; exit 1; }

# --- no Brewfile at the given path -> precondition error, exit 2 ---
out=$(env -i PATH="/usr/bin:/bin" sh "$script" "$tmp/no-such-Brewfile" 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: expected exit 2 for a missing Brewfile, got rc=$rc"; echo "$out"; exit 1; }

echo PASS
