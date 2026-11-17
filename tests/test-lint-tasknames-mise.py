#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for lint-tasknames' mise reader: task names from `mise.toml` `[tasks]` and from task files
under `mise-tasks/`, read through `mise tasks ls --json`. mise lists the tasks of every config above
the directory too (a parent's `mise.toml`, the global config), each with its `source`, so only tasks
whose source lies inside the directory being read are this repository's own. A `mise.toml` mise cannot
parse is a READER ERROR, never a clean run.

mise runs against scratch config, data, state and cache directories under the test's temp dir, never
the machine's own, and the fixture is trusted through MISE_TRUSTED_CONFIG_PATHS, because a sandboxed
session cannot write mise's trust records. Without mise on PATH the suite SKIPs.

Run: sh tests/run-all.sh --only test-lint-tasknames-mise.py
 or: uv run --script tests/test-lint-tasknames-mise.py [-k <pattern>]

LINT_TASKNAMES_TOOL points the suite at another copy of the tool, so a deliberately broken copy can be
run through the same tests to show each one fail.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = Path(os.environ.get("LINT_TASKNAMES_TOOL") or HERE.parent / "private_dot_local" / "bin" / "executable_lint-tasknames")
SKILL = "| `build` | produce artifacts |\n| `test` | run tests |\n| `check` · `verify` · `validate` | the triad |\n"

pytestmark = pytest.mark.skipif(shutil.which("mise") is None, reason="mise not installed")


@pytest.fixture
def box(tmp_path):
    """tmp_path holds HOME (with the vocabulary skill), scratch mise directories, and `repo/`."""
    home = tmp_path / "home"
    (home / ".claude/skills/naming-build-tasks").mkdir(parents=True)
    (home / ".claude/skills/naming-build-tasks/SKILL.md").write_text(SKILL)
    for d in ("config", "data", "state", "cache"):
        (tmp_path / "mise" / d).mkdir(parents=True)
    (tmp_path / "repo").mkdir()
    return tmp_path


def env_for(box, trusted=True, path=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith(("LINT_TASKNAMES_", "MISE_"))}
    e.update(HOME=str(box / "home"),
             MISE_CONFIG_DIR=str(box / "mise/config"), MISE_DATA_DIR=str(box / "mise/data"),
             MISE_STATE_DIR=str(box / "mise/state"), MISE_CACHE_DIR=str(box / "mise/cache"))
    if trusted:
        e["MISE_TRUSTED_CONFIG_PATHS"] = str(box)
    if path is not None:
        e["PATH"] = path
    return e


def lint(box, target="repo", **kw):
    return subprocess.run([sys.executable, str(TOOL), str(box / target)], capture_output=True, text=True,
                          env=env_for(box, **kw), stdin=subprocess.DEVNULL)


def out(r):
    return r.stdout + r.stderr


def findings(r):
    """The finding lines alone: the header carries temp paths, which hold the test's own name."""
    return "\n".join(l for l in r.stdout.splitlines() if l.startswith(("  ERROR", "  WARN", "  INFO")))


PIPEFAIL = "bash -euo pipefail -c"


def toml_tasks(d, **tasks):
    """A mise.toml in `d` with one `[tasks."<name>"]` table per keyword (name -> run line), each naming
    a pipefail shell, as every inline task must (the shell rule's own tests write theirs by hand)."""
    d.mkdir(parents=True, exist_ok=True)
    (d / "mise.toml").write_text("".join(f'[tasks."{n}"]\nshell = "{PIPEFAIL}"\nrun = "{r}"\n'
                                         for n, r in tasks.items()))


def file_task(d, rel, body="echo hi\n"):
    p = d / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("#!/bin/sh\n" + body)
    p.chmod(0o755)


# ---- the planted bad names: one in [tasks], one in mise-tasks/ ---------------------------------

def test_a_bad_name_in_mise_toml_tasks_is_reported(box):
    toml_tasks(box / "repo", **{"build-app": "true", "build:docs": "true", "wifi-capture": "true"})
    r = lint(box)
    assert r.returncode == 1, out(r)
    assert "ERROR [mise] build:docs: separator" in r.stdout, out(r)
    assert "WARN  [mise] wifi-capture: verb" in r.stdout, out(r)
    assert "mise(3)" in r.stdout, out(r)


def test_a_bad_name_in_mise_tasks_dir_is_reported(box):
    file_task(box / "repo", "mise-tasks/build-site")
    file_task(box / "repo", "mise-tasks/wifi-capture")
    r = lint(box)
    assert "WARN  [mise] wifi-capture: verb" in r.stdout, out(r)
    assert "build-site" not in findings(r), out(r)
    assert "mise(2)" in r.stdout, out(r)


def test_a_grouped_task_file_gets_mise_s_colon_name_and_is_an_error(box):
    # mise names mise-tasks/test/e2e `test:e2e`: the colon the vocabulary refuses, so it is reported.
    file_task(box / "repo", "mise-tasks/test/e2e")
    r = lint(box)
    assert r.returncode == 1, out(r)
    assert "ERROR [mise] test:e2e: separator" in r.stdout, out(r)


def test_a_hidden_task_is_still_linted(box):
    (box / "repo/mise.toml").write_text('[tasks."wifi-scan"]\nrun = "true"\nhide = true\n')
    r = lint(box)
    assert "WARN  [mise] wifi-scan: verb" in r.stdout, out(r)


# ---- only the repository's own tasks -----------------------------------------------------------

def test_a_parent_s_tasks_are_not_counted(box):
    toml_tasks(box, **{"wifi-parent": "true", "build:parent": "true"})
    toml_tasks(box / "repo", **{"build-app": "true"})
    r = lint(box)
    assert r.returncode == 0, out(r)
    assert "parent" not in findings(r), out(r)
    assert "mise(1)" in r.stdout and "clean." in r.stdout, out(r)


def test_a_global_task_is_not_counted(box):
    file_task(box / "mise/config", "tasks/wifi-global")
    toml_tasks(box / "repo", **{"build-app": "true"})
    r = lint(box)
    assert "wifi-global" not in findings(r), out(r)
    assert "mise(1)" in r.stdout, out(r)


def test_a_nested_mise_toml_is_read_once_and_labeled(box):
    toml_tasks(box / "repo", **{"build-app": "true"})
    toml_tasks(box / "repo/tools", **{"wifi-tool": "true"})
    r = lint(box)
    assert findings(r).count("wifi-tool") == 1, out(r)
    assert "WARN  [mise:tools] wifi-tool: verb" in r.stdout, out(r)
    assert "build-app" not in findings(r) and "mise(2)@2d" in r.stdout, out(r)


def test_a_dot_config_mise_toml_is_the_directory_s_own_and_counted_once(box):
    d = box / "repo/.config"
    d.mkdir(parents=True)
    (d / "mise.toml").write_text(f'[tasks."wifi-dot"]\nshell = "{PIPEFAIL}"\nrun = "true"\n')
    r = lint(box)
    assert findings(r).count("wifi-dot") == 1, out(r)
    assert "WARN  [mise] wifi-dot: verb" in r.stdout, out(r)


def test_a_mise_toml_inside_a_pruned_tree_is_not_read(box):
    toml_tasks(box / "repo/node_modules/dep", **{"build:dep": "true"})
    toml_tasks(box / "repo", **{"build-app": "true"})
    r = lint(box)
    assert "build:dep" not in findings(r) and r.returncode == 0, out(r)


# ---- what is exempt, and what is not read at all -----------------------------------------------

def test_default_is_exempt_as_just_s_is(box):
    toml_tasks(box / "repo", **{"default": "mise tasks ls", "build-app": "true"})
    r = lint(box)
    assert r.returncode == 0 and "default" not in findings(r), out(r)


def test_a_repository_with_no_mise_config_is_a_skip_and_runs_no_mise(box):
    (box / "empty-bin").mkdir()
    (box / "repo/package.json").write_text('{"scripts": {"build-app": "true"}}')
    r = lint(box, path=str(box / "empty-bin"))
    assert r.returncode == 0, out(r)
    assert "mise(-)" in r.stdout, out(r)


# ---- a failure to read is a READER ERROR, never a clean pass -----------------------------------

def test_an_unparseable_mise_toml_is_a_reader_error(box):
    (box / "repo/mise.toml").write_text('[tasks.build\nrun = "true"\n')
    r = lint(box)
    assert r.returncode == 2, out(r)
    assert "READER ERROR [mise]" in r.stderr, out(r)
    assert "mise(ERROR)" in r.stdout and "clean." not in r.stdout, out(r)


def test_a_task_table_mise_refuses_is_a_reader_error(box):
    (box / "repo/mise.toml").write_text("[tasks]\nbuild = 5\n")
    r = lint(box)
    assert r.returncode == 2 and "READER ERROR [mise]" in r.stderr, out(r)


def test_mise_missing_from_path_is_a_reader_error(box):
    (box / "empty-bin").mkdir()
    toml_tasks(box / "repo", **{"build-app": "true"})
    r = lint(box, path=str(box / "empty-bin"))
    assert r.returncode == 2, out(r)
    assert "READER ERROR [mise]" in r.stderr and "not found" in r.stderr, out(r)


def test_an_untrusted_config_is_read_or_an_error_never_clean(box):
    # Measured with mise 2026.11.5: listing tasks needs no trust. Whatever a later mise does, a planted
    # bad name in an untrusted config must not come back as a clean run.
    toml_tasks(box / "repo", **{"build:app": "true"})
    r = lint(box, trusted=False)
    assert r.returncode != 0, out(r)
    assert "ERROR [mise] build:app" in r.stdout or "READER ERROR [mise]" in r.stderr, out(r)


# ---- task bodies reach the triad check ---------------------------------------------------------

def test_a_toml_task_body_reaches_the_triad_check(box):
    toml_tasks(box / "repo", **{"check-site": "curl -fsS https://example.invalid/"})
    r = lint(box)
    assert r.returncode == 1 and "ERROR [mise] check-site: triad" in r.stdout, out(r)


def test_a_file_task_body_reaches_the_triad_check(box):
    file_task(box / "repo", "mise-tasks/validate-units", "systemctl --user is-active foo.service\n")
    r = lint(box)
    assert r.returncode == 1 and "ERROR [mise] validate-units: triad" in r.stdout, out(r)


# ---- an inline task names its own shell, with pipefail ------------------------------------------
# mise ignores `unix_default_inline_shell_args` in a project's mise.toml, so a task without its own
# `shell` runs without pipefail and `false | true` succeeds.

def test_an_inline_task_naming_no_shell_is_an_error(box):
    (box / "repo/mise.toml").write_text('[tasks.build-app]\nrun = "false | true"\n')
    r = lint(box)
    assert r.returncode == 1, out(r)
    assert "ERROR [mise] build-app: shell: names no `shell`" in r.stdout, out(r)


@pytest.mark.parametrize("shell", ["bash -c", "sh -eu -c", "/bin/zsh -c"])
def test_a_posix_shell_without_pipefail_is_an_error(box, shell):
    (box / "repo/mise.toml").write_text(f'[tasks.build-app]\nshell = "{shell}"\nrun = "false | true"\n')
    r = lint(box)
    assert r.returncode == 1, out(r)
    assert "ERROR [mise] build-app: shell: " in r.stdout and "pipefail" in r.stdout, out(r)


@pytest.mark.parametrize("shell", ["bash -euo pipefail -c", "sh -o pipefail -c", "python3 -c"])
def test_a_pipefail_shell_or_a_non_shell_interpreter_is_clean(box, shell):
    (box / "repo/mise.toml").write_text(f'[tasks.build-app]\nshell = "{shell}"\nrun = "true"\n')
    r = lint(box)
    assert r.returncode == 0 and "shell" not in findings(r), out(r)


def test_a_file_task_and_a_task_with_no_run_need_no_shell(box):
    file_task(box / "repo", "mise-tasks/build-site")
    (box / "repo/mise.toml").write_text('[tasks.build-all]\ndepends = ["build-site"]\n')
    r = lint(box)
    assert r.returncode == 0 and "shell" not in findings(r), out(r)


# ---- an allowance names the file the task lives in ---------------------------------------------

def test_an_allowance_matches_a_mise_task_by_its_own_file(box):
    file_task(box / "repo", "mise-tasks/wifi-up")
    toml_tasks(box / "repo", **{"wifi-down": "true"})
    (box / "mani.yaml").write_text("projects:\n  alpha:\n    path: repo\n")
    (box / "allow.toml").write_text(
        '[[allowance]]\nrepo = "alpha"\npath = "mise-tasks/wifi-up"\nmirror = "wifi"\n'
        'surface = "wifi --help"\nnames = ["wifi-up"]\nreason = "mirrors wifi"\n'
        '[[allowance]]\nrepo = "alpha"\npath = "mise.toml"\nmirror = "wifi"\n'
        'surface = "wifi --help"\nnames = ["wifi-down"]\nreason = "mirrors wifi"\n')
    e = env_for(box)
    e.update(LINT_TASKNAMES_MANIFEST=str(box / "mani.yaml"), LINT_TASKNAMES_ALLOWANCES=str(box / "allow.toml"))
    r = subprocess.run([sys.executable, str(TOOL), str(box / "repo")], capture_output=True, text=True,
                       env=e, stdin=subprocess.DEVNULL)
    assert "INFO  [mise] wifi-up: allowed" in r.stdout, out(r)
    assert "INFO  [mise] wifi-down: allowed" in r.stdout, out(r)
    assert "stale" not in r.stdout, out(r)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider", *sys.argv[1:]]))
