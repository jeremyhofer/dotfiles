#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for `lint-tasknames --staged`, the commit-gate mode: it lints only when a staged path is a
file one of the tool's readers parses, and then exits with gate semantics (1 on an ERROR, 2 on a
reader or usage error, 0 otherwise). Each test builds a temp git repository, stages with `git add`
and commits nothing. The machine's global git config is replaced by /dev/null so no global hook or
signing setting reaches the temp repositories.

Run: npx nx run suite-lint-tasknames-staged:test
 or: uv run --script tests/test-lint-tasknames-staged.py [-k <pattern>]

LINT_TASKNAMES_TOOL points the suite at another copy of the tool, so a deliberately broken copy can be
run through the same tests to show each one fail.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = Path(os.environ.get("LINT_TASKNAMES_TOOL") or HERE.parent / "private_dot_local" / "bin" / "executable_lint-tasknames")
SKILL = "| `build` | produce artifacts |\n| `test` | run tests |\n| `check` · `verify` · `validate` | the triad |\n"
NONE_LINE = "lint-tasknames: no task file staged"
REFUSED = "commit refused"
PIPEFAIL = "bash -euo pipefail -c"


@pytest.fixture
def box(tmp_path):
    home = tmp_path / "home"
    (home / ".claude/skills/naming-build-tasks").mkdir(parents=True)
    (home / ".claude/skills/naming-build-tasks/SKILL.md").write_text(SKILL)
    for d in ("config", "data", "state", "cache"):
        (tmp_path / "mise" / d).mkdir(parents=True)
    repo = tmp_path / "repo"
    repo.mkdir()
    g = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True, env=env_for(tmp_path))
    g("init", "-q")
    g("config", "user.name", "T")
    g("config", "user.email", "t@example.invalid")
    return tmp_path


def env_for(box):
    e = {k: v for k, v in os.environ.items() if not k.startswith(("LINT_TASKNAMES_", "MISE_", "GIT_"))}
    e.update(HOME=str(box / "home"), GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
             MISE_CONFIG_DIR=str(box / "mise/config"), MISE_DATA_DIR=str(box / "mise/data"),
             MISE_STATE_DIR=str(box / "mise/state"), MISE_CACHE_DIR=str(box / "mise/cache"),
             MISE_TRUSTED_CONFIG_PATHS=str(box))
    return e


def write(box, rel, text, mode=None):
    p = box / "repo" / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    if mode:
        p.chmod(mode)
    return p


def stage(box, *rels):
    subprocess.run(["git", "-C", str(box / "repo"), "add", "-f", *rels], check=True, capture_output=True,
                   env=env_for(box))


def staged(box, *args, target="repo"):
    return subprocess.run([sys.executable, str(TOOL), "--staged", *args, *([str(box / target)] if target else [])],
                          capture_output=True, text=True, env=env_for(box), stdin=subprocess.DEVNULL)


def out(r):
    return r.stdout + r.stderr


def pkg(*names):
    return json.dumps({"scripts": {n: "true" for n in names}})


def test_a_staged_colon_named_npm_script_is_refused(box):
    write(box, "package.json", pkg("build:app"))
    stage(box, "package.json")
    r = staged(box)
    assert r.returncode == 1, out(r)
    assert "ERROR [npm] build:app: separator" in r.stdout, out(r)
    last = out(r).strip().splitlines()[-1]
    assert REFUSED in last and "naming-build-tasks" in last, out(r)


def test_a_staged_clean_npm_script_passes(box):
    write(box, "package.json", pkg("build-app"))
    stage(box, "package.json")
    r = staged(box)
    assert r.returncode == 0 and "clean." in r.stdout and REFUSED not in out(r), out(r)


@pytest.mark.skipif(shutil.which("just") is None, reason="just not installed")
def test_a_staged_clean_justfile_passes(box):
    write(box, "justfile", "build-app:\n\ttrue\n")
    stage(box, "justfile")
    r = staged(box)
    assert r.returncode == 0 and "just(1)" in r.stdout, out(r)


def test_a_warning_alone_does_not_block(box):
    write(box, "package.json", pkg("wifi-capture"))
    stage(box, "package.json")
    r = staged(box)
    assert r.returncode == 0 and "WARN  [npm] wifi-capture: verb" in r.stdout and REFUSED not in out(r), out(r)


def test_nothing_task_related_staged_prints_one_line_and_does_not_lint(box):
    write(box, "package.json", pkg("build:app"))  # in the working tree, NOT staged
    write(box, "README.md", "hello\n")
    stage(box, "README.md")
    r = staged(box)
    assert r.returncode == 0, out(r)
    assert r.stdout.strip() == NONE_LINE and r.stderr == "", out(r)


def test_nothing_staged_at_all_is_the_one_line(box):
    r = staged(box)
    assert r.returncode == 0 and r.stdout.strip() == NONE_LINE, out(r)


def test_repo_defaults_to_the_current_directory_and_resolves_to_the_top_level(box):
    write(box, "package.json", pkg("build:app"))
    stage(box, "package.json")
    (box / "repo/sub").mkdir()
    r = subprocess.run([sys.executable, str(TOOL), "--staged"], cwd=box / "repo/sub", capture_output=True,
                       text=True, env=env_for(box), stdin=subprocess.DEVNULL)
    assert r.returncode == 1 and "build:app" in r.stdout, out(r)


def test_a_staged_package_json_under_a_fixtures_directory_does_not_trigger(box):
    write(box, "fixtures/app/package.json", pkg("build:app"))
    stage(box, "fixtures/app/package.json")
    r = staged(box)
    assert r.returncode == 0 and r.stdout.strip() == NONE_LINE, out(r)


@pytest.mark.parametrize("rel", ["node_modules/dep/package.json", ".worktrees/w/package.json",
                                 ".claude/worktrees/w/package.json", "effect/fixture-ok/package.json"])
def test_a_staged_build_file_in_a_directory_the_walk_skips_does_not_trigger(box, rel):
    write(box, rel, pkg("build:app"))
    stage(box, rel)
    r = staged(box)
    assert r.returncode == 0 and r.stdout.strip() == NONE_LINE, out(r)


@pytest.mark.skipif(shutil.which("mise") is None, reason="mise not installed")
def test_a_staged_mise_toml_with_a_colon_task_is_refused(box):
    write(box, "mise.toml", f'[tasks."build:docs"]\nshell = "{PIPEFAIL}"\nrun = "true"\n')
    stage(box, "mise.toml")
    r = staged(box)
    assert r.returncode == 1 and "ERROR [mise] build:docs: separator" in r.stdout, out(r)


@pytest.mark.skipif(shutil.which("mise") is None, reason="mise not installed")
@pytest.mark.parametrize("rel", ["mise-tasks/build-site", "tools/mise-tasks/build-site", ".mise/tasks/build-site",
                                 ".config/mise/conf.d/extra.toml"])
def test_a_staged_file_under_a_mise_task_directory_or_config_triggers(box, rel):
    write(box, rel, "#!/bin/sh\ntrue\n" if "toml" not in rel else "", 0o755)
    stage(box, rel)
    r = staged(box)
    assert NONE_LINE not in r.stdout and "lint-tasknames: repo" in r.stdout, out(r)


def test_a_staged_nx_json_triggers(box):
    write(box, "nx.json", "{}")
    stage(box, "nx.json")
    r = staged(box)
    assert NONE_LINE not in r.stdout, out(r)


def test_a_non_git_directory_is_exit_2(box):
    (box / "plain").mkdir()
    r = staged(box, target="plain")
    assert r.returncode == 2 and "git" in r.stderr, out(r)


def test_a_missing_directory_is_exit_2(box):
    r = staged(box, target="nope")
    assert r.returncode == 2, out(r)


def test_staged_with_fleet_is_a_usage_error(box):
    r = subprocess.run([sys.executable, str(TOOL), "--staged", "--fleet"], capture_output=True, text=True,
                       env=env_for(box), stdin=subprocess.DEVNULL)
    assert r.returncode == 2 and "--staged" in r.stderr and "--fleet" in r.stderr, out(r)


def test_a_reader_error_is_exit_2_and_refuses(box):
    write(box, "package.json", "{not json")
    stage(box, "package.json")
    r = staged(box)
    assert r.returncode == 2 and "READER ERROR" in r.stderr and REFUSED in out(r), out(r)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider", *sys.argv[1:]]))
