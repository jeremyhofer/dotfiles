#!/bin/sh
# Test: every Python tool this repository deploys loads on Python 3.9, the python3 that macOS's
# command-line tools ship and that a hook may meet first on PATH (a GUI git client, an IDE, launchd).
# A tool that fails to load there fails every commit whose hook calls it, in every repository.
#
# It parses each tool with the python3 running the test and refuses two forms 3.9 cannot load:
#   * an `X | Y` union in an annotation, unless the file has `from __future__ import annotations`
#     (3.9 evaluates annotations when the module loads, and `|` between types is 3.10);
#   * a `match` statement (3.10).
# Parsing, not running, so no Python 3.9 is needed. It does not catch a 3.10+ call inside a function
# body (a 3.10-only keyword argument, say); that needs a 3.9 interpreter.
#
# PY39_FILES overrides the files checked, so a known-bad copy can be run to see the test fail.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { echo "test: python3 is required" >&2; exit 1; }

if [ -n "${PY39_FILES:-}" ]; then
  files=$PY39_FILES
else
  files=$(grep -l '^#!/usr/bin/env python3' "$here"/private_dot_local/bin/executable_* 2>/dev/null || true)
fi
[ -n "$files" ] || { echo "FAIL: no Python tools found to check" >&2; exit 1; }

# shellcheck disable=SC2086 # file names carry no spaces
python3 -I - $files <<'EOF'
import ast, sys

bad = 0
for path in sys.argv[1:]:
    tree = ast.parse(open(path, encoding="utf-8").read(), path)
    future = any(isinstance(n, ast.ImportFrom) and n.module == "__future__"
                 and any(a.name == "annotations" for a in n.names) for n in tree.body)
    for node in ast.walk(tree):
        if isinstance(node, ast.Match):
            print(f"FAIL: {path}:{node.lineno}: a match statement needs Python 3.10")
            bad += 1
        anns = []
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            args = node.args
            anns = [a.annotation for a in args.posonlyargs + args.args + args.kwonlyargs]
            anns += [args.vararg.annotation if args.vararg else None, args.kwarg.annotation if args.kwarg else None, node.returns]
        elif isinstance(node, ast.AnnAssign):
            anns = [node.annotation]
        if future:
            continue
        for ann in anns:
            if ann is not None and any(isinstance(n, ast.BinOp) and isinstance(n.op, ast.BitOr) for n in ast.walk(ann)):
                print(f"FAIL: {path}:{ann.lineno}: an `X | Y` annotation needs `from __future__ import annotations` on Python 3.9")
                bad += 1
print(f"{len(sys.argv) - 1} file(s) checked, {bad} problem(s)")
sys.exit(1 if bad else 0)
EOF
echo PASS
