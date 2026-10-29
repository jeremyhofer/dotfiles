#!/bin/sh
# Test: every shell script in this repository parses under bash as well as under sh.
#
# On macOS /bin/sh is bash 3.2, and Linux distributions differ in what `sh` is (dash, or bash in its
# POSIX mode). The same file can parse under one and not another: an apostrophe inside the word of a
# `${var:-word}` expansion within double quotes is accepted by bash's POSIX mode and refused by plain
# bash, so a script that passed every test on Linux failed to load at all on a Mac. Parsing (`-n`)
# runs nothing, so this is safe on any file.
#
# Checked: files with a `#!/bin/sh`, `#!/usr/bin/env sh` or bash shebang under setup/, tests/ and
# private_dot_local/bin/. Templates (`.tmpl`) are skipped, since their template markup is not shell.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
command -v bash >/dev/null 2>&1 || { echo "test: bash is required" >&2; exit 1; }

checked=0
bad=0
for f in "$here"/setup/* "$here"/tests/*.sh "$here"/private_dot_local/bin/executable_*; do
  [ -f "$f" ] || continue
  case "$f" in *.tmpl) continue ;; esac
  first=$(head -n 1 "$f")
  case "$first" in
    '#!/bin/sh'*|'#!/usr/bin/env sh'*) shells="sh bash" ;;
    '#!/bin/bash'*|'#!/usr/bin/env bash'*) shells="bash" ;;
    *) continue ;;
  esac
  for s in $shells; do
    if ! out=$($s -n "$f" 2>&1); then
      echo "FAIL: ${f#"$here"/} does not parse under $s: $out"
      bad=$((bad + 1))
    fi
  done
  checked=$((checked + 1))
done

[ "$checked" -gt 0 ] || { echo "FAIL: no shell scripts found to check"; exit 1; }
echo "$checked script(s) checked, $bad failure(s)"
[ "$bad" -eq 0 ] || exit 1
echo PASS
