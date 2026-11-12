#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""tests/coverage.map covers the tracked tree: the check in tools/nx/suites.js, on this tree and on
a fixture with each finding planted.

Run: npx nx run suite-coverage-map:test
 or: uv run --script tests/test-coverage-map.py [-k <pattern>]

WHY IT MATTERS. Each suite's Nx target hashes the paths its map lines claim, so a tracked file that
no line claims re-runs no suite when it changes: an edit there commits and applies on a replayed
pass. `node tools/nx/suites.js --check` refuses such a file until a line claims or exempts it, and
refuses a suite whose text names a tracked path (`dir/file`, or a tool as `executable_<name>`) that
its own lines do not claim, since that suite reads a file whose edit would not re-run it. The plugin
throws, failing every Nx command, on the map errors (a line naming no suite, a dead glob, a suite
with no line); the check reports those as exit 2.

The real tree is checked first. Then a fixture repository, a few files and a small map, is clean,
has each finding planted in turn and refused, and is clean again once each plant is reverted, so
every refusal is seen against the defect it names beside a control the same check passes. The check
reads `git ls-files`, so under the commit hook it judges what is staged; this suite's target hashes
that list (tools/nx/suites.js, THE SET OF TRACKED FILES).
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PLUGIN = ROOT / "tools" / "nx" / "suites.js"


def node() -> str:
    found = shutil.which("node")
    if not found:
        pytest.fail("node is not on PATH; the check is the Nx plugin's own (run this through Nx, "
                    "which runs under the Node the repository pins)")
    return found


def check(root: Path) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k != "NX_SUITES_MAP_FOR_TESTS"}
    return subprocess.run([node(), str(PLUGIN), "--check", str(root)], capture_output=True,
                          text=True, env=env, timeout=60)


def git(root: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)


def test_the_real_map_covers_every_tracked_file():
    out = check(ROOT)
    assert out.returncode == 0, out.stdout + out.stderr
    assert "the map covers all" in out.stdout


MAP = """\
core core.sh
test-a.sh  bin/a
test-b.sh  bin/b
tree test-t.sh bin/*
exempt skip/** tests/coverage.map
"""


@pytest.fixture
def fixture(tmp_path):
    r = tmp_path / "r"
    for d in ("tests", "bin", "skip", "private_dot_local/bin"):
        (r / d).mkdir(parents=True)
    (r / "tests" / "test-a.sh").write_text("#!/bin/sh\n# reads bin/a\n")
    (r / "tests" / "test-b.sh").write_text("#!/bin/sh\n# reads bin/b\n")
    (r / "tests" / "test-t.sh").write_text("#!/bin/sh\n# a whole-tree check\n")
    (r / "tests" / "coverage.map").write_text(MAP + "test-b.sh private_dot_local/bin/executable_tool\n")
    for name, text in (("bin/a", "a"), ("bin/b", "b"), ("core.sh", "c"), ("skip/x", "s"),
                       ("private_dot_local/bin/executable_tool", "t")):
        (r / name).write_text(text + "\n")
    git(r, "init", "-q")
    git(r, "add", "-A")
    return r


def append(path: Path, text: str) -> None:
    path.write_text(path.read_text() + text)


def test_a_covered_fixture_passes(fixture):
    out = check(fixture)
    assert out.returncode == 0, out.stdout + out.stderr


def test_a_tracked_file_nothing_claims_is_refused_until_a_line_claims_it(fixture):
    (fixture / "bin" / "new").write_text("n\n")
    git(fixture, "add", "bin/new")
    out = check(fixture)
    assert out.returncode == 1
    assert "unclaimed: bin/new" in out.stdout
    append(fixture / "tests" / "coverage.map", "test-b.sh bin/new\n")
    assert check(fixture).returncode == 0


def test_an_untracked_file_is_not_judged(fixture):
    (fixture / "bin" / "scratch").write_text("n\n")
    assert check(fixture).returncode == 0


def test_a_tree_line_claims_nothing(fixture):
    # test-t.sh's `tree bin/*` matches bin/new, yet bin/new is still unclaimed.
    (fixture / "bin" / "new").write_text("n\n")
    git(fixture, "add", "bin/new")
    assert "unclaimed: bin/new" in check(fixture).stdout


def test_an_exempt_path_is_covered(fixture):
    (fixture / "skip" / "y").write_text("y\n")
    git(fixture, "add", "skip/y")
    assert check(fixture).returncode == 0


def test_a_suite_naming_a_path_it_does_not_claim_is_refused_and_refs_clears_it(fixture):
    append(fixture / "tests" / "test-a.sh", "cat bin/b\n")
    out = check(fixture)
    assert out.returncode == 1
    assert "test-a.sh names bin/b but does not claim it" in out.stdout
    append(fixture / "tests" / "coverage.map", "refs test-a.sh bin/b\n")
    assert check(fixture).returncode == 0


def test_a_tool_named_by_its_file_name_counts_as_named(fixture):
    append(fixture / "tests" / "test-a.sh", "run executable_tool\n")
    out = check(fixture)
    assert out.returncode == 1
    assert "test-a.sh names private_dot_local/bin/executable_tool" in out.stdout


def test_a_name_inside_a_longer_word_is_not_a_name(fixture):
    append(fixture / "tests" / "test-a.sh", "echo xbin/b bin/bb\n")
    assert check(fixture).returncode == 0


def test_a_core_path_needs_no_claim(fixture):
    (fixture / "lib").mkdir()
    (fixture / "lib" / "core2").write_text("c\n")
    append(fixture / "tests" / "coverage.map", "core lib/core2\n")
    append(fixture / "tests" / "test-a.sh", "source lib/core2\n")
    git(fixture, "add", "-A")
    assert check(fixture).returncode == 0


@pytest.mark.parametrize("line, message", [
    ("test-gone.sh bin/a", "names no suite in tests/: test-gone.sh"),
    ("test-a.sh bin/renamed-away", "glob bin/renamed-away matches no tracked file"),
    ("test-a.sh", "a line with no globs"),
])
def test_a_map_the_plugin_refuses_is_exit_2(fixture, line, message):
    append(fixture / "tests" / "coverage.map", line + "\n")
    out = check(fixture)
    assert out.returncode == 2
    assert message in out.stderr


def test_a_suite_with_no_line_is_exit_2(fixture):
    (fixture / "tests" / "test-c.sh").write_text("#!/bin/sh\n")
    git(fixture, "add", "tests/test-c.sh")
    out = check(fixture)
    assert out.returncode == 2
    assert "test-c.sh has no line in the map" in out.stderr


def test_usage_is_exit_2():
    out = subprocess.run([node(), str(PLUGIN)], capture_output=True, text=True, timeout=60)
    assert out.returncode == 2
    assert "usage:" in out.stderr


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", *sys.argv[1:]]))
