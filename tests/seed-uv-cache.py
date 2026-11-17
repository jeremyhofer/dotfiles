#!/usr/bin/env python3
"""seed-uv-cache -- fill uv's cache for every `uv run --script` file in this tree, with the network.

    python3 tests/seed-uv-cache.py [--list] [--root DIR]

The gates run uv offline (tests/run-all.sh sets UV_OFFLINE=1), so a script's pinned packages must
already be in uv's cache. This is the one step that reaches a registry. For each file under tests/
and private_dot_local/bin/ whose first line is a `uv run --script` shebang it runs
`uv sync --script <file>`, which resolves the file's inline dependencies and installs them into the
script environment `uv run --script` then reuses, without running the script. It removes UV_OFFLINE
from uv's environment, since reaching the registry is its purpose. It tries every file, names each
that failed, and exits 1 if any did.

--list prints the files it would seed, relative to the root, one per line, and runs nothing.
--root DIR seeds another tree (default: the tree this file is in).

Exit: 0 every file seeded; 1 some file failed; 2 uv is not installed, or a usage error.
Run by tests/apply-suites.py before every apply's suites. Standard library only, Python 3.9 syntax
(a hook runs it with the python3 on PATH).
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

DIRS = ("tests", "private_dot_local/bin")


def is_uv_script(path: Path) -> bool:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            first = f.readline()
    except OSError:
        return False
    return first.startswith("#!") and "uv run --script" in first


def uv_scripts(root: Path) -> list:
    found = []
    for d in DIRS:
        base = root / d
        if base.is_dir():
            found += [p for p in sorted(base.iterdir()) if p.is_file() and is_uv_script(p)]
    return found


def main(argv: list) -> int:
    ap = argparse.ArgumentParser(prog="seed-uv-cache", description=__doc__.split("\n\n")[0])
    ap.add_argument("--list", action="store_true", help="print the files, run nothing")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    args = ap.parse_args(argv)
    root = Path(args.root)
    files = uv_scripts(root)
    if args.list:
        for f in files:
            print(f.relative_to(root))
        return 0
    if shutil.which("uv") is None:
        print("seed-uv-cache: uv is not installed, so nothing was seeded", file=sys.stderr)
        return 2
    env = {k: v for k, v in os.environ.items() if k != "UV_OFFLINE"}
    failed = []
    for f in files:
        r = subprocess.run(["uv", "sync", "--script", str(f)], env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, universal_newlines=True)
        if r.returncode != 0:
            failed.append(str(f.relative_to(root)))
            print(f"seed-uv-cache: {f.relative_to(root)} failed (exit {r.returncode}):\n{r.stderr.rstrip()}",
                  file=sys.stderr)
    if failed:
        print("seed-uv-cache: not seeded: " + " ".join(failed), file=sys.stderr)
        return 1
    print(f"seed-uv-cache: {len(files)} script(s) seeded", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
