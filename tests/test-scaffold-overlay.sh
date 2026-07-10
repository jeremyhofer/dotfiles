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
echo "PASS"
