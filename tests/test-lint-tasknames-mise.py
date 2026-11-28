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

Run: npx nx run suite-lint-tasknames-mise:test
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
    # Measured with mise 2026.11.14: a plain config lists untrusted. Whatever a later mise does, a planted
    # bad name in an untrusted config must not come back as a clean run.
    toml_tasks(box / "repo", **{"build:app": "true"})
    r = lint(box, trusted=False)
    assert r.returncode != 0, out(r)
    assert "ERROR [mise] build:app" in r.stdout or "READER ERROR [mise]" in r.stderr, out(r)


# ---- an untrusted config that mise refuses to list is read statically, running nothing ---------
# Measured with mise 2026.11.14: a plain untrusted config lists fine, but one with `[vars]` or a
# `{{ ... }}` template is refused ("are not trusted", exit 1). Trusting it would RUN its
# `{{ exec(...) }}` templates, so the tool reads the TOML itself instead. Each test gets a fresh
# directory because mise records trust state.

STATIC_NOTE = "read without mise"


def vars_config(d, body=""):
    d.mkdir(parents=True, exist_ok=True)
    (d / "mise.toml").write_text('[vars]\nx = "1"\n' + body)


def test_mise_refuses_this_untrusted_config_so_the_fallback_is_exercised(box):
    # Control for the tests below: it is the premise, measured against mise itself.
    vars_config(box / "repo", '[tasks.build-app]\nrun = "echo {{vars.x}}"\n')
    r = subprocess.run(["mise", "tasks", "ls", "--json", "--hidden"], cwd=box / "repo", capture_output=True,
                       text=True, env=env_for(box, trusted=False), stdin=subprocess.DEVNULL)
    assert r.returncode != 0 and "are not trusted" in r.stderr, r.stderr


def test_an_untrusted_vars_config_is_read_statically_not_a_reader_error(box):
    vars_config(box / "repo", f'[tasks."build:docs"]\nshell = "{PIPEFAIL}"\nrun = "echo {{{{vars.x}}}}"\n'
                f'[tasks.wifi-capture]\nshell = "{PIPEFAIL}"\nrun = "true"\n')
    r = lint(box, trusted=False)
    assert r.returncode == 1, out(r)
    assert "READER ERROR" not in r.stderr, out(r)
    assert "ERROR [mise] build:docs: separator" in r.stdout, out(r)
    assert "WARN  [mise] wifi-capture: verb" in r.stdout, out(r)
    assert "mise(2)" in r.stdout, out(r)


def test_an_untrusted_template_in_run_is_read_statically(box):
    (box / "repo/mise.toml").write_text(f'[tasks.build-app]\nshell = "{PIPEFAIL}"\nrun = "echo {{{{ env.HOME }}}}"\n'
                                        f'[tasks.wifi-x]\nshell = "{PIPEFAIL}"\nrun = "true"\n')
    r = lint(box, trusted=False)
    assert r.returncode == 0 and "READER ERROR" not in r.stderr, out(r)
    assert "WARN  [mise] wifi-x: verb" in r.stdout and "mise(2)" in r.stdout, out(r)


def test_the_header_says_which_directories_were_read_without_mise_and_why(box):
    vars_config(box / "repo", f'[tasks.build-app]\nshell = "{PIPEFAIL}"\nrun = "true"\n')
    vars_config(box / "repo/tools", f'[tasks.build-tool]\nshell = "{PIPEFAIL}"\nrun = "true"\n')
    r = lint(box, trusted=False)
    line = next((l for l in r.stdout.splitlines() if STATIC_NOTE in l), "")
    assert "untrusted" in line and "." in line and "tools" in line, out(r)
    assert r.returncode == 0, out(r)


def test_a_plain_untrusted_config_is_still_listed_by_mise_and_not_flagged_static(box):
    toml_tasks(box / "repo", **{"build-app": "true"})
    r = lint(box, trusted=False)
    assert r.returncode == 0 and STATIC_NOTE not in r.stdout, out(r)


def test_static_read_takes_string_and_table_values_and_counts_hidden_tasks(box):
    (box / "repo/mise.toml").write_text(
        '[vars]\nx = "1"\n[tasks]\nbuild-a = "true"\n'
        f'[tasks."wifi-b"]\nrun = "true"\nshell = "{PIPEFAIL}"\nhide = true\n')
    r = lint(box, trusted=False)
    assert "WARN  [mise] wifi-b: verb" in r.stdout, out(r)
    assert "mise(2)" in r.stdout, out(r)


def test_static_read_applies_the_inline_shell_rule(box):
    (box / "repo/mise.toml").write_text(
        '[vars]\nx = "1"\n[tasks]\nbuild-a = "false | true"\n'
        '[tasks.build-b]\nshell = "bash -c"\nrun = "true"\n'
        f'[tasks.build-c]\nshell = "{PIPEFAIL}"\nrun = ["true", "true"]\n'
        '[tasks.build-d]\ndepends = ["build-c"]\n')
    r = lint(box, trusted=False)
    assert r.returncode == 1, out(r)
    assert "ERROR [mise] build-a: shell: names no `shell`" in r.stdout, out(r)
    assert "ERROR [mise] build-b: shell: " in r.stdout and "pipefail" in r.stdout, out(r)
    assert "build-c" not in findings(r) and "build-d" not in findings(r), out(r)


def test_static_read_sends_the_run_body_to_the_triad_check(box):
    (box / "repo/mise.toml").write_text(
        f'[vars]\nx = "1"\n[tasks.check-site]\nshell = "{PIPEFAIL}"\nrun = "curl -fsS https://example.invalid/"\n')
    r = lint(box, trusted=False)
    assert r.returncode == 1 and "ERROR [mise] check-site: triad" in r.stdout, out(r)


def test_a_data_file_named_mise_toml_with_no_tasks_is_clean_and_flagged_static(box):
    (box / "repo/mise.toml").write_text('[[miseGlobal.node]]\nversion = "22"\nx = "{{ .y }}"\n'.replace("{{ .y }}", "{{ y }}"))
    r = lint(box, trusted=False)
    assert r.returncode == 0 and "READER ERROR" not in r.stderr, out(r)
    assert STATIC_NOTE in r.stdout and "mise(0)" in r.stdout, out(r)


def test_a_toml_syntax_error_in_an_untrusted_config_is_still_a_reader_error(box):
    (box / "repo/mise.toml").write_text('[vars]\nx = "{{ y }}"\n[tasks.build\nrun = "true"\n')
    r = lint(box, trusted=False)
    assert r.returncode == 2, out(r)
    assert "READER ERROR [mise]" in r.stderr, out(r)


def test_task_config_includes_are_reported_as_not_covered(box):
    vars_config(box / "repo", '[task_config]\nincludes = ["extra-tasks"]\n'
                f'[tasks.build-a]\nshell = "{PIPEFAIL}"\nrun = "true"\n')
    r = lint(box, trusted=False)
    line = next((l for l in r.stdout.splitlines() if l.startswith("  mise:") and "includes" in l), "")
    assert "not covered" in line, out(r)


def test_task_files_are_not_read_statically_and_the_header_says_so(box):
    # mise's file-task naming (measured 2026.11.14) strips some extensions (`.sh`, `.py`, ...) and not
    # others (`.tar`, `.md`) and drops `.toml`, so the static path does not guess: it names the limit.
    vars_config(box / "repo", f'[tasks.build-a]\nshell = "{PIPEFAIL}"\nrun = "true"\n')
    file_task(box / "repo", "mise-tasks/wifi-file")
    r = lint(box, trusted=False)
    assert "wifi-file" not in findings(r) and "mise(1)" in r.stdout, out(r)
    line = next((l for l in r.stdout.splitlines() if l.startswith("  mise:") and "file tasks" in l), "")
    assert "not covered" in line, out(r)


def test_a_static_read_of_a_nested_config_does_not_count_a_parent_s_tasks(box):
    toml_tasks(box, **{"wifi-parent": "true"})
    vars_config(box / "repo", f'[tasks.build-a]\nshell = "{PIPEFAIL}"\nrun = "true"\n')
    r = lint(box, trusted=False)
    assert "parent" not in findings(r) and "mise(1)" in r.stdout, out(r)


def marker_config(box, marker):
    # Measured 2026.11.14: a trusted listing evaluates `exec` in `[vars]` (not in a task's `run`).
    (box / "repo/mise.toml").write_text(
        f'[vars]\nv = "{{{{ exec(command=\'touch {marker}\') }}}}"\n'
        f'[tasks.build-a]\nshell = "{PIPEFAIL}"\nrun = "echo {{{{vars.v}}}}"\n')


def test_a_static_read_runs_nothing(box):
    marker = box / "marker-ran"
    marker_config(box, marker)
    r = lint(box, trusted=False)
    assert r.returncode == 0 and STATIC_NOTE in r.stdout, out(r)
    assert not marker.exists(), "a lint run evaluated a template"


def test_the_marker_test_can_fail_a_trusted_listing_creates_the_marker(box):
    # Control for the test above: with the config trusted, mise itself DOES run the template.
    marker = box / "marker-ran"
    marker_config(box, marker)
    lint(box, trusted=True)
    assert marker.exists(), "mise did not evaluate the template when trusted: the marker test cannot detect"


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
