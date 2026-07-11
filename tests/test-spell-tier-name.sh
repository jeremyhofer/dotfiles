#!/bin/sh
# Test: base spell.lua points entry-1 at the private per-domain tier private.utf-8.add
# (domain-neutral name), not the old personal.utf-8.add.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
lua="$here/../dot_config/nvim/lua/config/spell.lua"
grep -q 'private[.]utf-8[.]add' "$lua" || { echo "FAIL: spell.lua missing private.utf-8.add"; exit 1; }
if grep -q 'personal[.]utf-8[.]add' "$lua"; then echo "FAIL: spell.lua still references personal.utf-8.add"; exit 1; fi
echo "ok:   spell.lua entry-1 renamed to private.utf-8.add"
echo "PASS"
