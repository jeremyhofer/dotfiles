#!/bin/sh
# Test: the BASE ships spell-capture, and it no-ops (exit 0) when no overlay is configured.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
sc="$here/../private_dot_local/bin/executable_spell-capture"
[ -f "$sc" ] || { echo "FAIL: base does not ship spell-capture"; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-spell-capture.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
# Fake HOME with no overlay config -> must no-op cleanly (exit 0).
HOME="$tmp" sh "$sc" "$tmp/whatever.utf-8.add" && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL: expected no-op exit 0 without overlay, got ${rc:-0}"; exit 1; }
echo "ok:   base ships spell-capture; no-ops without overlay"
echo "PASS"
