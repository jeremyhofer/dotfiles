#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""No new logic-bearing shell: every shell script under `private_dot_local/bin/` and `tests/` must be
on the allowlist `tests/shell-allowlist.txt`, and every allowlist line must name a shell script that
still exists. Python is the language for new tools and suites; shell stays only where it is already
written, until it is ported.

Run: sh tests/run-all.sh --only test-no-new-shell.py
 or: uv run --script tests/test-no-new-shell.py [-k <pattern>]

WHAT COUNTS AS SHELL. A tracked, non-symlink file under one of the two directories whose first line
is a `#!` line naming sh, bash, zsh, dash or ksh, directly (`#!/bin/sh`) or through env
(`#!/usr/bin/env bash`, `#!/usr/bin/env -S zsh -f`). A file with no shebang counts when its name ends
in `.sh`, `.bash` or `.zsh` (a sourced library has no shebang and is still shell). Anything else,
Python above all, is not shell and needs no line. The scan reads `git ls-files`, so under the commit
gate it judges what is staged.

THE ALLOWLIST. One path per line, relative to the repository root; blank lines and lines starting
with `#` are ignored. A line may end with a marker, `  # exec-only` or `  # bootstrap`:

* exec-only: a script whose only logic is locating and `exec`-ing another program. It may check that
  the target exists and say so on stderr before exiting non-zero; it has no other branching, loop,
  parsing or state. It may set environment variables for the program it runs. A wrapper that also decides anything (picks a target by argument, builds a
  command line from a file, retries) is logic-bearing and is unmarked until it is ported.
* bootstrap: a stage that has to run before Python is available on the machine, so it cannot be
  ported to it.

A path with no marker is existing logic-bearing shell, waiting for its port. The marker is a claim
about the script, and a reviewer checks it; this suite checks only that the marker is one of the two.

THE LIST ONLY SHRINKS. A new shell script is refused until it is on the list, and the review of that
line is the point: adding one is a visible decision, not an accident. A listed path that is gone, or
that is no longer shell (it was ported in place), is refused too, so a port deletes its line in the
same commit and the list never goes stale.

Each case that plants a defect has a control beside it that the same check passes, in a scratch git
repository, so a refusal is shown to come from the planted defect.
"""
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ALLOWLIST = "tests/shell-allowlist.txt"
SCANNED = ("private_dot_local/bin/", "tests/")
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
SHELL_SUFFIXES = (".sh", ".bash", ".zsh")
MARKERS = {"exec-only", "bootstrap"}


def shebang_is_shell(line: bytes) -> bool:
    """True when a `#!` line runs a shell, directly or through env."""
    if not line.startswith(b"#!"):
        return False
    words = line[2:].decode("utf-8", "replace").split()
    if not words:
        return False
    first = os.path.basename(words[0])
    if first == "env":
        rest = [w for w in words[1:] if not w.startswith("-") and "=" not in w]
        first = os.path.basename(rest[0]) if rest else ""
    return first in SHELLS


def is_shell(root: Path, rel: str) -> bool:
    path = root / rel
    if path.is_symlink() or not path.is_file():
        return False
    with open(path, "rb") as f:
        first = f.readline(256)
    if first.startswith(b"#!"):
        return shebang_is_shell(first)
    return rel.endswith(SHELL_SUFFIXES)


def tracked(root: Path) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", *SCANNED],
        capture_output=True, check=True,
    ).stdout.decode("utf-8", "replace")
    return [p for p in out.split("\0") if p]


def read_allowlist(root: Path) -> tuple[dict[str, str], list[str]]:
    """The allowlist as {path: marker or ""}, and the findings about its own lines."""
    entries: dict[str, str] = {}
    findings: list[str] = []
    text = (root / ALLOWLIST).read_text()
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        path, _, comment = line.partition("#")
        path, marker = path.strip(), comment.strip()
        if marker and marker not in MARKERS:
            findings.append(f"{ALLOWLIST}:{n}: unknown marker {marker!r} (use one of {sorted(MARKERS)})")
        if path in entries:
            findings.append(f"{ALLOWLIST}:{n}: {path} is listed twice")
        if not path.startswith(SCANNED):
            findings.append(f"{ALLOWLIST}:{n}: {path} is outside {' and '.join(SCANNED)}")
        entries[path] = marker
    return entries, findings


def check(root: Path) -> list[str]:
    entries, findings = read_allowlist(root)
    shell = {p for p in tracked(root) if is_shell(root, p)}
    for p in sorted(shell - entries.keys()):
        findings.append(
            f"{p}: a shell script that is not on {ALLOWLIST}. Write the tool in Python; "
            "only an exec-only wrapper or a bootstrap stage is added to the list."
        )
    for p in sorted(entries.keys() - shell):
        why = "no longer shell" if (root / p).exists() else "gone"
        findings.append(f"{ALLOWLIST}: {p} is listed but {why}; delete its line.")
    return findings


# --- the real tree ----------------------------------------------------------------------------

def test_this_tree_matches_its_allowlist():
    if subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--git-dir"], capture_output=True).returncode:
        pytest.skip("not a git checkout")
    assert check(ROOT) == []


# --- the check itself, against scratch repositories ---------------------------------------------

GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
           "GIT_CONFIG_NOSYSTEM": "1"}


def git(root: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, env=GIT_ENV)


@pytest.fixture
def repo(tmp_path, monkeypatch):
    """A scratch repo with one shell script, one Python script and a matching allowlist."""
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", os.devnull)
    git(tmp_path, "init", "-q")
    put(tmp_path, "private_dot_local/bin/executable_old", "#!/bin/sh\necho old\n")
    put(tmp_path, "private_dot_local/bin/executable_tool", "#!/usr/bin/env python3\nprint(1)\n")
    put(tmp_path, ALLOWLIST, "# header\nprivate_dot_local/bin/executable_old\n")
    return tmp_path


def put(root: Path, rel: str, text: str) -> None:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    git(root, "add", rel)


def test_control_scratch_repo_is_clean(repo):
    assert check(repo) == []


def test_new_shell_script_is_refused(repo):
    put(repo, "private_dot_local/bin/executable_new", "#!/bin/bash\necho new\n")
    findings = check(repo)
    assert len(findings) == 1 and "executable_new" in findings[0] and "not on" in findings[0]


def test_new_shell_test_suite_is_refused(repo):
    put(repo, "tests/test-new.sh", "#!/bin/sh\nexit 0\n")
    assert any("tests/test-new.sh" in f for f in check(repo))


def test_new_sourced_library_without_shebang_is_refused(repo):
    put(repo, "tests/lib.sh", "x=1\n")
    assert any("tests/lib.sh" in f for f in check(repo))


def test_new_python_script_is_not_refused(repo):
    put(repo, "tests/test-new.py", "#!/usr/bin/env -S uv run --script\nprint(1)\n")
    put(repo, "tests/helper", "#!/usr/bin/env python3\nprint(1)\n")
    assert check(repo) == []


def test_listed_script_that_is_gone_is_refused(repo):
    git(repo, "rm", "-q", "-f", "private_dot_local/bin/executable_old")
    findings = check(repo)
    assert len(findings) == 1 and "executable_old" in findings[0] and "gone" in findings[0]


def test_listed_script_that_became_python_is_refused(repo):
    put(repo, "private_dot_local/bin/executable_old", "#!/usr/bin/env python3\nprint(1)\n")
    findings = check(repo)
    assert len(findings) == 1 and "no longer shell" in findings[0]


def test_unknown_marker_is_refused(repo):
    put(repo, ALLOWLIST, "private_dot_local/bin/executable_old  # exec-onyl\n")
    assert any("unknown marker" in f for f in check(repo))


def test_known_markers_pass(repo):
    put(repo, "private_dot_local/bin/executable_wrap", "#!/bin/sh\nexec other \"$@\"\n")
    put(repo, ALLOWLIST,
        "private_dot_local/bin/executable_old\n"
        "private_dot_local/bin/executable_wrap  # exec-only\n")
    assert check(repo) == []


def test_duplicate_line_is_refused(repo):
    put(repo, ALLOWLIST, "private_dot_local/bin/executable_old\nprivate_dot_local/bin/executable_old\n")
    assert any("listed twice" in f for f in check(repo))


def test_listed_path_outside_the_scanned_directories_is_refused(repo):
    put(repo, "setup/x", "#!/bin/sh\n")
    put(repo, ALLOWLIST, "private_dot_local/bin/executable_old\nsetup/x\n")
    assert any("outside" in f for f in check(repo))


def test_symlink_is_not_scanned(repo):
    os.symlink("executable_old", repo / "private_dot_local/bin/symlink_old")
    git(repo, "add", "private_dot_local/bin/symlink_old")
    assert check(repo) == []


@pytest.mark.parametrize("line,expected", [
    (b"#!/bin/sh\n", True),
    (b"#!/bin/bash -eu\n", True),
    (b"#! /bin/zsh -f\n", True),
    (b"#!/usr/bin/env bash\n", True),
    (b"#!/usr/bin/env zsh\n", True),
    (b"#!/usr/bin/env -S zsh -f\n", True),
    (b"#!/usr/bin/env -S FOO=1 sh\n", True),
    (b"#!/usr/bin/env python3\n", False),
    (b"#!/usr/bin/env -S uv run --script\n", False),
    (b"#!/usr/bin/env node\n", False),
    (b"#!/usr/bin/env\n", False),
    (b"#!\n", False),
    (b"# not a shebang, sh\n", False),
    (b"\x7fELF\x02\x01", False),
])
def test_shebang_forms(line, expected):
    assert shebang_is_shell(line) is expected


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))
