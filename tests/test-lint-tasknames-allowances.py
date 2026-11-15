#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for lint-tasknames' allowance mechanism: the allowlist file, its schema, severity, stale
allowances and surface verification. The tool runs as a subprocess, the way a session meets it, with
HOME, the allowlist and the manifest all under a temp dir.

Run: sh tests/run-all.sh --only test-lint-tasknames-allowances.py
 or: uv run --script tests/test-lint-tasknames-allowances.py [-k <pattern>]

LINT_TASKNAMES_TOOL points the suite at another copy of the tool, so a deliberately broken copy can be
run through the same tests to show each one fail.
"""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = Path(os.environ.get("LINT_TASKNAMES_TOOL") or HERE.parent / "private_dot_local" / "bin" / "executable_lint-tasknames")

SKILL = "| `build` | produce artifacts |\n| `check` · `verify` · `validate` | the triad |\n"


@pytest.fixture
def box(tmp_path):
    """A HOME with the vocabulary skill, a manifest declaring repo `alpha` and `beta`, and the repos."""
    home = tmp_path / "home"
    (home / ".claude/skills/naming-build-tasks").mkdir(parents=True)
    (home / ".claude/skills/naming-build-tasks/SKILL.md").write_text(SKILL)
    for n in ("alpha", "beta"):
        (tmp_path / n).mkdir()
    (tmp_path / "mani.yaml").write_text(
        "projects:\n  alpha:\n    path: alpha\n    tags: [a]\n  beta:\n    path: beta\n    tags: [b]\n")
    return tmp_path


def scripts(repo, **names):
    import json
    repo.mkdir(parents=True, exist_ok=True)
    (repo / "package.json").write_text(json.dumps({"scripts": {n: "true" for n in names}}))


def surface_script(box, body, name="up"):
    """A fake mirrored tool `name` on PATH (box/bin); returns the surface `name --help` that runs it."""
    d = box / "bin"
    d.mkdir(exist_ok=True)
    p = d / name
    p.write_text(f"#!{sys.executable}\nimport os, sys, time\n" + textwrap.dedent(body))
    p.chmod(0o755)
    return f"{name} --help"


def allowance(repo="alpha", mirror="up", surface="up --help", names=("foo",), path=None, reason="mirrors up"):
    lines = ["[[allowance]]", f'repo = "{repo}"', f'mirror = "{mirror}"', f'surface = "{surface}"',
             "names = [" + ", ".join(f'"{n}"' for n in names) + "]", f'reason = "{reason}"']
    if path:
        lines.append(f'path = "{path}"')
    return "\n".join(lines) + "\n"


def lint(box, *args, allow=None, env=None, repo="alpha", stdin=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith("LINT_TASKNAMES_")}
    e.update(HOME=str(box / "home"), LINT_TASKNAMES_MANIFEST=str(box / "mani.yaml"),
             PATH=f"{box / 'bin'}{os.pathsep}{os.environ['PATH']}")
    if allow is not None:
        f = box / "allowances.toml"
        f.write_text(allow)
        e["LINT_TASKNAMES_ALLOWANCES"] = str(f)
    e.update(env or {})
    e = {k: v for k, v in e.items() if v is not None}
    argv = [sys.executable, str(TOOL), *args, str(box / repo)]
    if args and args[0] == "--fleet":
        argv = [sys.executable, str(TOOL), *args]
    return subprocess.run(argv, capture_output=True, text=True, env=e, input="" if stdin is None else stdin)


def out(r):
    return r.stdout + r.stderr


# ---- no file, and the schema -------------------------------------------------------------------

def test_no_allowance_file_is_said_in_the_header_and_changes_nothing(box):
    scripts(box / "alpha", foo=1)
    r = lint(box)
    assert r.returncode == 0
    assert "allowances: none (no file at" in r.stdout
    assert "WARN  [npm] foo" in r.stdout


def test_a_named_allowance_file_that_does_not_exist_is_exit_2(box):
    scripts(box / "alpha", foo=1)
    r = lint(box, env={"LINT_TASKNAMES_ALLOWANCES": str(box / "missing.toml")})
    assert r.returncode == 2 and "does not exist" in r.stderr


BAD = {
    "unknown key": (allowance() + 'colour = "red"\n', "unknown key 'colour'"),
    "missing surface": (allowance().replace('surface = "up --help"\n', ""), "missing key 'surface'"),
    "empty surface": (allowance(surface=""), "key 'surface'"),
    "blank surface": (allowance(surface="   "), "key 'surface'"),
    "empty names": (allowance(names=()), "key 'names'"),
    "names not a list": (allowance().replace('names = ["foo"]', 'names = "foo"'), "key 'names'"),
    "names with a non-string": (allowance().replace('names = ["foo"]', "names = [1]"), "key 'names'"),
    "surface wrong type": (allowance().replace('surface = "up --help"', "surface = 3"), "key 'surface'"),
    "missing repo": (allowance().replace('repo = "alpha"\n', ""), "missing key 'repo'"),
    "missing reason": (allowance().replace('reason = "mirrors up"\n', ""), "missing key 'reason'"),
    "absolute path": (allowance(path="/etc/justfile"), "key 'path'"),
    "dotdot path": (allowance(path="../x/justfile"), "key 'path'"),
    "dotdot path in the middle": (allowance(path="a/../justfile"), "key 'path'"),
    "dot-slash path": (allowance(path="./justfile"), "key 'path'"),
    "double-slash path": (allowance(path="a//justfile"), "key 'path'"),
    "trailing-slash path": (allowance(path="sub/"), "key 'path'"),
    "surface with a slash": (allowance(surface="./up --help"), "not a path"),
    "surface with an absolute path": (allowance(surface="/usr/bin/up --help"), "not a path"),
    "surface that is not the mirror": (allowance(mirror="up", surface="just --summary"), "must run the mirrored tool"),
    "unknown top-level key": ('stray = 1\n' + allowance(), "unknown top-level"),
    "not toml": ("[[allowance\n", "unreadable"),
}


@pytest.mark.parametrize("label", sorted(BAD))
def test_each_schema_error_is_exit_2_naming_the_allowance_and_the_key(box, label):
    scripts(box / "alpha", foo=1)
    toml, expect = BAD[label]
    r = lint(box, allow=toml)
    assert r.returncode == 2, out(r)
    assert expect in r.stderr, r.stderr
    if label not in ("not toml", "unknown top-level key"):
        assert "allowance #1 (up)" in r.stderr


# ---- severity ---------------------------------------------------------------------------------

def test_an_allowed_name_is_info_not_warn_and_others_stay_warn(box):
    scripts(box / "alpha", foo=1, bar=1)
    r = lint(box, allow=allowance())
    assert r.returncode == 0, out(r)
    assert "INFO  [npm] foo: allowed: mirrors up (mirrors up)" in r.stdout
    assert "WARN  [npm] bar" in r.stdout and "WARN  [npm] foo" not in r.stdout
    assert "allowances: 1 for alpha" in r.stdout and "surfaces NOT run (no --strict)" in r.stdout


def test_an_allowance_never_downgrades_a_colon_error(box):
    scripts(box / "alpha", **{"foo:bar": 1})
    r = lint(box, allow=allowance(names=("foo:bar",)))
    assert r.returncode == 1, out(r)
    assert "ERROR [npm] foo:bar: separator" in r.stdout


def test_an_allowance_never_downgrades_a_triad_error(box):
    (box / "alpha").mkdir(exist_ok=True)
    (box / "alpha" / "justfile").write_text("check-site:\n    curl http://example.invalid/\n")
    r = lint(box, allow=allowance(names=("check-site",)))
    assert r.returncode == 1, out(r)
    assert "ERROR [just] check-site: triad" in r.stdout
    assert "INFO  [just] check-site: allowed" in r.stdout


def test_an_allowance_for_another_repository_applies_to_none_here(box):
    scripts(box / "alpha", foo=1)
    r = lint(box, allow=allowance(repo="beta"))
    assert "WARN  [npm] foo" in r.stdout and "allowances: 0 for alpha" in r.stdout


def test_a_repository_missing_from_the_manifest_gets_no_allowances_and_says_so(box):
    scripts(box / "alpha", foo=1)
    (box / "mani.yaml").write_text("projects:\n  beta:\n    path: beta\n")
    r = lint(box, allow=allowance())
    assert "not in the manifest" in r.stdout and "so none apply" in r.stdout and "WARN  [npm] foo" in r.stdout


# ---- stale ------------------------------------------------------------------------------------

def test_a_stale_allowance_is_warn_and_fails_only_under_strict(box):
    scripts(box / "alpha", foo=1)
    surface = surface_script(box, 'print("foo gone")\n')
    toml = allowance(surface=surface, names=("foo", "gone"))
    plain = lint(box, allow=toml)
    assert plain.returncode == 0 and "WARN  [allowance #1 (up)] gone: stale allowance" in plain.stdout
    strict = lint(box, "--strict", allow=toml)
    assert strict.returncode == 1 and "stale allowance" in strict.stdout


def test_a_fleet_run_reports_an_allowance_for_a_repository_the_fleet_lacks(box):
    scripts(box / "alpha", foo=1)
    scripts(box / "beta", **{"build-it": 1})
    surface = surface_script(box, 'print("foo")\n')
    fleet = ("--fleet", str(box / "mani.yaml"))
    clean = lint(box, *fleet, "--strict", allow=allowance(surface=surface))
    assert clean.returncode == 0, out(clean)
    toml = allowance(surface=surface) + allowance(repo="nowhere", surface=surface)
    r = lint(box, *fleet, allow=toml)
    assert r.returncode == 0 and "repo 'nowhere' is not in the manifest: stale allowance" in r.stdout
    assert lint(box, *fleet, "--strict", allow=toml).returncode == 1


def test_a_fleet_allowance_for_a_repository_tagged_upstream_says_so(box):
    scripts(box / "alpha", foo=1)
    scripts(box / "beta", foo=1)
    (box / "mani.yaml").write_text(
        "projects:\n  alpha:\n    path: alpha\n  beta:\n    path: beta\n    tags: [upstream]\n")
    r = lint(box, "--fleet", str(box / "mani.yaml"), allow=allowance(repo="beta"))
    assert "repo 'beta' is tagged upstream or missing on disk: stale allowance" in r.stdout


def test_a_stale_check_is_skipped_when_a_reader_errored(box):
    (box / "alpha").mkdir(exist_ok=True)
    (box / "alpha" / "package.json").write_text("{not json")
    r = lint(box, allow=allowance())
    assert r.returncode == 2 and "READER ERROR" in r.stderr
    assert "stale allowance" not in out(r)


# ---- surface verification ---------------------------------------------------------------------

def test_a_surface_that_lists_every_name_passes_under_strict(box):
    scripts(box / "alpha", foo=1, baz=1)
    surface = surface_script(box, 'print("commands: foo baz")\n')
    r = lint(box, "--strict", allow=allowance(surface=surface, names=("foo", "baz")))
    assert "0 ERROR, 0 WARN, 2 INFO." in r.stdout and "surfaces run (--strict)" in r.stdout
    assert [l for l in r.stdout.splitlines() if l.startswith("  WARN")] == []
    assert r.returncode == 0, out(r)


def test_a_name_missing_from_the_surface_output_is_an_error_naming_the_allowance(box):
    scripts(box / "alpha", foo=1)
    surface = surface_script(box, 'print("only bar")\n')
    r = lint(box, "--strict", allow=allowance(surface=surface))
    assert r.returncode == 1
    assert "ERROR [allowance #1 (up)]" in r.stdout and "lacks the claimed name 'foo'" in r.stdout


def test_a_name_must_be_a_whole_word_in_the_surface_output(box):
    scripts(box / "alpha", foo=1)
    surface = surface_script(box, 'print("foo-bar foobar xfoo")\n')
    r = lint(box, "--strict", allow=allowance(surface=surface))
    assert r.returncode == 1 and "lacks the claimed name 'foo'" in r.stdout


def test_a_surface_that_exits_nonzero_is_an_error(box):
    scripts(box / "alpha", foo=1)
    surface = surface_script(box, 'print("foo"); sys.exit(3)\n')
    r = lint(box, "--strict", allow=allowance(surface=surface))
    assert r.returncode == 1 and "exited 3" in r.stdout and "ERROR [allowance #1 (up)]" in r.stdout


def test_a_surface_that_times_out_is_an_error(box):
    scripts(box / "alpha", foo=1)
    surface = surface_script(box, 'time.sleep(30)\n')
    r = lint(box, "--strict", allow=allowance(surface=surface), env={"LINT_TASKNAMES_SURFACE_TIMEOUT": "0.5"})
    assert r.returncode == 1 and "timed out after 0.5s" in r.stdout


def test_a_surface_command_that_is_not_found_is_an_error(box):
    scripts(box / "alpha", foo=1)
    r = lint(box, "--strict", allow=allowance(mirror="no-such-tool-for-lint", surface="no-such-tool-for-lint --help"))
    assert r.returncode == 1 and "was not found" in r.stdout


def test_no_surface_command_runs_without_strict(box):
    scripts(box / "alpha", foo=1)
    marker = box / "ran"
    surface = surface_script(box, f'open({str(marker)!r}, "w").write("x"); print("foo")\n')
    toml = allowance(surface=surface)
    r = lint(box, allow=toml)
    assert r.returncode == 0 and not marker.exists() and "surfaces NOT run (no --strict)" in r.stdout
    r = lint(box, "--strict", allow=toml)
    assert r.returncode == 0 and marker.exists()


def test_the_surface_runs_in_the_repository_directory_without_a_shell(box):
    scripts(box / "alpha", foo=1)
    marker = box / "alpha-cwd"
    surface = surface_script(box, f'import os; open({str(marker)!r}, "w").write(os.getcwd()); print("foo")\n')
    lint(box, "--strict", allow=allowance(surface=surface))
    assert Path(marker.read_text()).resolve() == (box / "alpha").resolve()
    # a shell metacharacter is an argument, not a second command
    side = box / "side"
    r = lint(box, "--strict", allow=allowance(surface=f"{surface} ; touch {side}"))
    assert not side.exists()


# ---- path ---------------------------------------------------------------------------------------

def test_a_path_allowance_applies_only_to_that_build_file(box):
    scripts(box / "alpha", foo=1)
    scripts(box / "alpha" / "sub", foo=1)
    r = lint(box, allow=allowance(path="sub/package.json"))
    assert "INFO  [npm:sub] foo: allowed" in r.stdout
    assert "WARN  [npm] foo" in r.stdout
    assert "stale allowance" not in r.stdout


def test_a_path_allowance_is_stale_when_its_file_lacks_the_name(box):
    scripts(box / "alpha", foo=1)
    scripts(box / "alpha" / "sub", other=1)
    r = lint(box, allow=allowance(path="sub/package.json"))
    assert "stale allowance: no task of that name in sub/package.json" in r.stdout
    assert "WARN  [npm] foo" in r.stdout


# ---- the surface's environment ------------------------------------------------------------------

def test_a_surface_does_not_inherit_the_linters_stdin(box):
    scripts(box / "alpha", foo=1)
    surface = surface_script(box, 'print("foo" if sys.stdin.read() == "" else "piped")\n')
    r = lint(box, "--strict", allow=allowance(surface=surface), stdin="foo\n")
    assert r.returncode == 0, out(r)


def test_a_surface_that_floods_its_output_is_killed_at_the_cap(box):
    scripts(box / "alpha", foo=1)
    surface = surface_script(box, 'while True:\n    print("foo")\n')
    r = lint(box, "--strict", allow=allowance(surface=surface),
             env={"LINT_TASKNAMES_SURFACE_MAX_BYTES": "4096", "LINT_TASKNAMES_SURFACE_TIMEOUT": "20"})
    assert r.returncode == 1 and "printed more than 4096 bytes" in r.stdout
    assert "ERROR [allowance #1 (up)]" in r.stdout


def test_ansi_escapes_are_stripped_before_matching(box):
    scripts(box / "alpha", foo=1)
    surface = surface_script(box, 'print("\\x1b[1mfoo\\x1b[0m")\n')
    assert lint(box, "--strict", allow=allowance(surface=surface)).returncode == 0


def test_a_surface_runs_with_no_color_set(box):
    scripts(box / "alpha", foo=1)
    surface = surface_script(box, 'print("foo" if os.environ.get("NO_COLOR") == "1" else "bar")\n')
    assert lint(box, "--strict", allow=allowance(surface=surface), env={"NO_COLOR": None}).returncode == 0


def test_a_name_printed_only_on_stderr_counts(box):
    scripts(box / "alpha", foo=1)
    surface = surface_script(box, 'sys.stderr.write("foo\\n")\n')
    assert lint(box, "--strict", allow=allowance(surface=surface)).returncode == 0


def test_only_this_repositorys_surfaces_run(box):
    scripts(box / "alpha", foo=1)
    marker = box / "beta-surface-ran"
    other = surface_script(box, f'open({str(marker)!r}, "w").write("x"); print("foo")\n', name="other")
    toml = allowance() .replace("up --help", surface_script(box, 'print("foo")\n')) \
        + allowance(repo="beta", mirror="other", surface=other)
    r = lint(box, "--strict", allow=toml)
    assert r.returncode == 0, out(r)
    assert not marker.exists()


@pytest.mark.parametrize("var,value", [("LINT_TASKNAMES_SURFACE_TIMEOUT", "soon"),
                                       ("LINT_TASKNAMES_SURFACE_TIMEOUT", "0"),
                                       ("LINT_TASKNAMES_SURFACE_MAX_BYTES", "lots")])
def test_a_bad_number_in_the_environment_is_exit_2_not_a_traceback(box, var, value):
    scripts(box / "alpha", foo=1)
    r = lint(box, "--strict", allow=allowance(), env={var: value})
    assert r.returncode == 2 and var in r.stderr and "Traceback" not in r.stderr


# ---- identifying the repository ------------------------------------------------------------------

def git(cwd, *args):
    e = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    subprocess.run(["git", "-C", str(cwd), "-c", "user.name=t", "-c", "user.email=t@t",
                    "-c", "commit.gpgsign=false", *args], check=True, capture_output=True, env=e)


def test_a_linked_worktree_and_a_subdirectory_get_the_main_checkouts_allowances(box):
    alpha = box / "alpha"
    scripts(alpha, foo=1)
    scripts(alpha / "sub", foo=1)
    git(alpha, "init", "-q", "-b", "main")
    git(alpha, "add", "-A")
    git(alpha, "commit", "-q", "-m", "x")
    git(alpha, "worktree", "add", "-q", str(box / "wt"), "-b", "side")
    toml = allowance()
    wt = lint(box, allow=toml, repo="wt")
    assert "allowances: 1 for alpha" in wt.stdout and "INFO  [npm] foo: allowed" in wt.stdout
    sub = lint(box, allow=allowance(path="sub/package.json"), repo="alpha/sub")
    assert "allowances: 1 for alpha" in sub.stdout and "INFO  [npm] foo: allowed" in sub.stdout
    assert "run from a subdirectory, so the stale check is skipped" in sub.stdout
    assert "not in the manifest" not in sub.stdout


def test_a_subdirectory_run_does_not_call_an_allowance_stale_for_a_name_outside_it(box):
    alpha = box / "alpha"
    scripts(alpha, foo=1)
    scripts(alpha / "sub", other=1)
    git(alpha, "init", "-q", "-b", "main")
    r = lint(box, allow=allowance(), repo="alpha/sub")
    assert "allowances: 1 for alpha" in r.stdout and "stale allowance" not in r.stdout


def test_a_linked_worktree_is_not_linted_as_part_of_the_main_checkout(box):
    scripts(box / "alpha", foo=1)
    scripts(box / "alpha" / ".worktrees" / "side", zzz=1)
    r = lint(box, allow=allowance())
    assert "zzz" not in r.stdout and "npm(1)" in r.stdout


def test_a_symlinked_manifest_path_still_identifies_the_repository(box):
    scripts(box / "alpha", foo=1)
    (box / "link").symlink_to(box / "alpha")
    (box / "mani.yaml").write_text("projects:\n  alpha:\n    path: link\n")
    r = lint(box, allow=allowance())
    assert "allowances: 1 for alpha" in r.stdout


def test_the_header_tells_an_unreadable_manifest_from_an_absent_project(box):
    scripts(box / "alpha", foo=1)
    r = lint(box, allow=allowance(), env={"LINT_TASKNAMES_MANIFEST": None})
    assert "the manifest could not be read" in r.stdout and "not in the manifest" not in r.stdout
    (box / "mani.yaml").write_text("projects:\n  beta:\n    path: beta\n")
    r = lint(box, allow=allowance())
    assert "this repository is not in the manifest" in r.stdout


def test_a_named_manifest_that_does_not_exist_is_exit_2(box):
    scripts(box / "alpha", foo=1)
    r = lint(box, allow=allowance(), env={"LINT_TASKNAMES_MANIFEST": str(box / "nope.yaml")})
    assert r.returncode == 2 and "LINT_TASKNAMES_MANIFEST" in r.stderr


def test_two_keys_sharing_a_path_apply_no_allowances_and_name_both(box):
    scripts(box / "alpha", foo=1)
    (box / "mani.yaml").write_text("projects:\n  alpha:\n    path: alpha\n  twin:\n    path: alpha\n")
    r = lint(box, allow=allowance())
    assert "alpha and twin share this repository's path" in r.stdout and "WARN  [npm] foo" in r.stdout


MANIFESTS = {
    "a comment at column 0": "projects:\n  alpha:\n    path: alpha\n# note\n  beta:\n    path: beta\n",
    "a blank line": "projects:\n  alpha:\n    path: alpha\n\n  beta:\n    path: beta\n",
    "a quoted key": 'projects:\n  alpha:\n    path: alpha\n  "beta":\n    path: beta\n',
    "a single-quoted key and path": "projects:\n  alpha:\n    path: alpha\n  'beta':\n    path: 'beta'\n",
}


@pytest.mark.parametrize("label", sorted(MANIFESTS))
def test_the_manifest_parser_keeps_every_project_under_its_own_key(box, label):
    scripts(box / "alpha", foo=1)
    scripts(box / "beta", foo=1)
    (box / "mani.yaml").write_text(MANIFESTS[label])
    r = lint(box, allow=allowance(repo="alpha"), repo="beta")
    assert "allowances: 0 for beta" in r.stdout and "WARN  [npm] foo" in r.stdout, out(r)
    r = lint(box, allow=allowance(repo="beta"), repo="beta")
    assert "allowances: 1 for beta" in r.stdout and "INFO  [npm] foo: allowed" in r.stdout, out(r)


def test_a_project_key_the_parser_cannot_read_is_refused_not_misattributed(box):
    scripts(box / "alpha", foo=1)
    scripts(box / "beta", foo=1)
    (box / "mani.yaml").write_text("projects:\n  alpha:\n    path: alpha\n  be ta!:\n    path: beta\n")
    r = lint(box, allow=allowance(repo="alpha"), repo="beta")
    assert r.returncode == 2 and "mani.yaml:4" in r.stderr and "INFO" not in r.stdout
    assert lint(box, "--fleet", str(box / "mani.yaml")).returncode == 2


def test_a_project_with_no_path_does_not_borrow_its_neighbors(box):
    scripts(box / "alpha", foo=1)
    (box / "mani.yaml").write_text("projects:\n  alpha:\n    path: alpha\n  seat:\n    sync: false\n")
    fleet = lint(box, "--fleet", str(box / "mani.yaml"))
    assert fleet.stdout.count("lint-tasknames: alpha") == 1


# ---- the build file's name ---------------------------------------------------------------------

def test_the_build_file_name_comes_from_a_directory_listing(box, monkeypatch):
    loader = importlib.machinery.SourceFileLoader("lt_under_test", str(TOOL))
    spec = importlib.util.spec_from_loader("lt_under_test", loader)
    lt = importlib.util.module_from_spec(spec)
    loader.exec_module(lt)
    d = box / "alpha"
    d.mkdir(exist_ok=True)
    (d / "Justfile").write_text("")
    # a case-insensitive filesystem answers is_file() for every spelling of the name
    monkeypatch.setattr(Path, "is_file", lambda self: True)
    assert lt.real_build_file(d, ("justfile", "Justfile", ".justfile")) == "Justfile"


def test_the_nx_build_file_is_nx_json(box):
    # Nx is read at the workspace root only, through `npx nx`; a stand-in for npx answers it
    alpha = box / "alpha"
    alpha.mkdir(exist_ok=True)
    (alpha / "nx.json").write_text("{}")
    (box / "bin").mkdir(exist_ok=True)
    npx = box / "bin" / "npx"
    npx.write_text(f"#!{sys.executable}\nimport sys\n"
                   "print('[\"app\"]' if 'projects' in sys.argv else '{\"targets\": {\"foo\": {}}}')\n")
    npx.chmod(0o755)
    r = lint(box, allow=allowance(path="nx.json"))
    assert "INFO  [nx:app] foo: allowed" in r.stdout, out(r)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, *sys.argv[1:]]))
