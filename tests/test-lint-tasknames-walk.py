#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for what lint-tasknames walks and how it judges the check/verify/validate triad: fixture
directories are skipped and counted, and a triad word is faulted only on positive evidence that the
task reads the wrong subject. The tool runs as a subprocess against a temp repository.

Run: sh tests/run-all.sh --only test-lint-tasknames-walk.py
 or: uv run --script tests/test-lint-tasknames-walk.py [-k <pattern>]

LINT_TASKNAMES_TOOL points the suite at another copy of the tool, so a deliberately broken copy can be
run through the same tests to show each one fail.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = Path(os.environ.get("LINT_TASKNAMES_TOOL") or HERE.parent / "private_dot_local" / "bin" / "executable_lint-tasknames")
SKILL = "| `build` | produce artifacts |\n| `test` | run tests |\n| `check` · `verify` · `validate` | the triad |\n"


@pytest.fixture
def repo(tmp_path):
    home = tmp_path / "home"
    (home / ".claude/skills/naming-build-tasks").mkdir(parents=True)
    (home / ".claude/skills/naming-build-tasks/SKILL.md").write_text(SKILL)
    r = tmp_path / "repo"
    r.mkdir()
    return r


def scripts(d, *names):
    d.mkdir(parents=True, exist_ok=True)
    (d / "package.json").write_text(json.dumps({"scripts": {n: "true" for n in names}}))


def lint(repo):
    e = {k: v for k, v in os.environ.items() if not k.startswith("LINT_TASKNAMES_")}
    e["HOME"] = str(repo.parent / "home")
    e["LINT_TASKNAMES_ALLOWANCES"] = ""
    e = {k: v for k, v in e.items() if v != ""}
    return subprocess.run([sys.executable, str(TOOL), str(repo)], capture_output=True, text=True,
                          env=e, stdin=subprocess.DEVNULL)


def out(r):
    return r.stdout + r.stderr


# ---- fixture directories -----------------------------------------------------------------------

@pytest.mark.parametrize("fixture_dir", ["fixtures/webapp", "effect/fixture-ok", "a/fixture_typo",
                                         "__fixtures__/app", "Fixtures/app", "x/fixture"])
def test_a_fixture_directory_is_not_linted_and_is_counted(repo, fixture_dir):
    scripts(repo / fixture_dir, "test:e2e")
    r = lint(repo)
    assert r.returncode == 0, out(r)
    assert "test:e2e" not in r.stdout, out(r)
    assert "skipped: 1 fixture directory" in r.stdout, out(r)


def test_the_same_build_file_outside_a_fixture_directory_is_linted(repo):
    # The control: the name is an ERROR wherever it is not test input.
    scripts(repo / "webapp", "test:e2e")
    r = lint(repo)
    assert r.returncode == 1, out(r)
    assert "ERROR [npm:webapp] test:e2e: separator" in r.stdout, out(r)
    assert "skipped:" not in r.stdout, out(r)


@pytest.mark.parametrize("name", ["fixtureish", "prefixtures", "my-fixtures"])
def test_a_directory_only_resembling_a_fixture_name_is_linted(repo, name):
    scripts(repo / name, "test:e2e")
    r = lint(repo)
    assert "ERROR [npm:" in r.stdout and "test:e2e" in r.stdout, out(r)


def test_several_skipped_fixture_directories_are_listed(repo):
    scripts(repo / "fixtures/a", "test:e2e")
    scripts(repo / "t/fixture-b", "test:e2e")
    r = lint(repo)
    assert "skipped: 2 fixture directories" in r.stdout, out(r)
    assert "fixtures" in r.stdout and "t/fixture-b" in r.stdout, out(r)


# ---- the triad: positive evidence only ---------------------------------------------------------

def just(repo, text):
    (repo / "justfile").write_text(text)


def test_a_validate_that_hands_off_to_another_tool_is_not_faulted(repo):
    just(repo, 'validate project:\n    /bin/zsh ./trigger.sh {{project}} validate\n')
    r = lint(repo)
    assert "triad" not in r.stdout, out(r)
    assert r.returncode == 0, out(r)


def test_a_validate_that_reaches_a_live_target_is_not_faulted(repo):
    just(repo, 'validate-site:\n    curl -fsS https://example.invalid/health\n')
    r = lint(repo)
    assert "triad" not in r.stdout, out(r)


def test_a_validate_that_only_inspects_the_machine_is_faulted_as_verify(repo):
    just(repo, 'validate-units:\n    systemctl --user is-active foo.service\n')
    r = lint(repo)
    assert r.returncode == 1, out(r)
    assert "ERROR [just] validate-units: triad" in r.stdout and "`verify`" in r.stdout, out(r)


def test_a_check_that_reaches_a_live_target_is_still_faulted(repo):
    # The other triad rules are unchanged by the validate fix.
    just(repo, 'check-site:\n    curl -fsS https://example.invalid/\n')
    r = lint(repo)
    assert r.returncode == 1, out(r)
    assert "ERROR [just] check-site: triad" in r.stdout, out(r)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider", *sys.argv[1:]]))
