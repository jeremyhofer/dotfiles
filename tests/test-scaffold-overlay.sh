#!/bin/sh
# Test: scaffold-overlay writes the renamed, self-documented skeleton into a new dir.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../setup/scaffold-overlay"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-scaffold-overlay.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
SKEL="$here/../overlay-skeleton" sh "$script" "$tmp/new-overlay"
[ -f "$tmp/new-overlay/.chezmoiignore" ]                     || { echo "FAIL: .chezmoiignore"; exit 1; }
[ -f "$tmp/new-overlay/dot_dotlocal/ssh/config" ]            || { echo "FAIL: ssh/config"; exit 1; }
[ -f "$tmp/new-overlay/dot_dotlocal/Brewfile.role" ]         || { echo "FAIL: Brewfile.role"; exit 1; }
[ -f "$tmp/new-overlay/dot_dotlocal/bootstrap.d/50-example.sh" ] || { echo "FAIL: bootstrap.d stage"; exit 1; }
[ -f "$tmp/new-overlay/README.md" ]                          || { echo "FAIL: README"; exit 1; }
grep -q "custom work tap" "$tmp/new-overlay/dot_dotlocal/Brewfile.role" || { echo "FAIL: tap comment missing"; exit 1; }
grep -q "IdentitiesOnly" "$tmp/new-overlay/dot_dotlocal/ssh/config"     || { echo "FAIL: ssh example missing"; exit 1; }
# refuses a non-empty dest
if SKEL="$here/../overlay-skeleton" sh "$script" "$tmp/new-overlay" 2>/dev/null; then echo "FAIL: should refuse non-empty"; exit 1; fi
# Tier-B/C shaped stubs land (overlay-doctor's required set):
[ -f "$tmp/new-overlay/dot_dotlocal/gitconfig" ]                    || { echo "FAIL: gitconfig stub"; exit 1; }
[ -f "$tmp/new-overlay/dot_dotlocal/allowed_signers" ]             || { echo "FAIL: allowed_signers stub"; exit 1; }
[ -f "$tmp/new-overlay/dot_dotlocal/zshenv.tmpl" ]                 || { echo "FAIL: zshenv.tmpl stub"; exit 1; }
[ -f "$tmp/new-overlay/dot_config/nvim/spell/private.utf-8.add" ]  || { echo "FAIL: private spell stub"; exit 1; }
grep -q 'FIXME(overlay-doctor)' "$tmp/new-overlay/dot_dotlocal/gitconfig" || { echo "FAIL: gitconfig missing FIXME sentinel"; exit 1; }
# Tier H (leak-guard) must NOT be scaffolded (home-only):
[ ! -e "$tmp/new-overlay/dot_dotlocal/git-leak-markers" ]          || { echo "FAIL: leak-guard should not be scaffolded"; exit 1; }
echo "ok:   Tier-B/C stubs land; Tier-H (leak-guard) absent"
echo "PASS"
