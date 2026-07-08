#!/bin/sh
# Test: stow-audit reports a stow symlink that chezmoi does NOT manage (exit 1).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../private_dot_local/bin/executable_stow-audit"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Fake a stow source + a $HOME with one symlink into it, and a fake `chezmoi` that
# reports NOTHING managed -> the symlink must be reported as uncovered (exit 1).
mkdir -p "$tmp/stow/.config/app" "$tmp/home/.config"
: > "$tmp/stow/.config/app/conf"
ln -s "$tmp/stow/.config/app/conf" "$tmp/home/.config/app-conf"
printf '#!/bin/sh\necho ""\n' > "$tmp/chezmoi"
chmod +x "$tmp/chezmoi"
out=$(HOME="$tmp/home" PATH="$tmp:$PATH" sh "$script" "$tmp/stow" 2>&1) && rc=0 || rc=$?
echo "$out"
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: expected exit 1 (uncovered), got ${rc:-0}"; exit 1; }
echo "$out" | grep -q "app-conf" || { echo "FAIL: uncovered link not reported"; exit 1; }
echo "PASS"
