#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for seam-probe. Every suite here is a scratch directory of tiny case scripts, and every
fixture lives under a temp sandbox root, so nothing touches a real repository or starts Claude
Code. The worktree-takeover suite this base ships is linted here too."""
import importlib.machinery
import importlib.util
import json
import os
import signal
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_seam-probe"
SHIPPED = HERE.parent / "private_dot_local" / "share" / "seam-probe" / "suites"


def _load():
    loader = importlib.machinery.SourceFileLoader("seam_probe", str(TOOL))
    spec = importlib.util.spec_from_loader("seam_probe", loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["seam_probe"] = mod
    loader.exec_module(mod)
    return mod


sp = _load()

CASE = """\
[[case]]
id = "{id}"
question = "q"
relies = "r"
bears-on = "b"
regimes = [{regimes}]
script = "{id}.sh"
plants = [{{ id = "p1", expect = "FAIL" }}]
minutes = 1
"""


@pytest.fixture
def env(tmp_path, monkeypatch):
    suites, sandbox, state = tmp_path / "suites", tmp_path / "sandbox", tmp_path / "state"
    for d in (suites, sandbox, state):
        d.mkdir()
    e = dict(os.environ, SEAM_PROBE_SUITES=str(suites), SEAM_PROBE_SANDBOX=str(sandbox),
             SEAM_PROBE_STATE=str(state), HOME=os.environ.get("HOME", str(tmp_path)))
    e.pop("CLAUDECODE", None)
    e.pop("FLEET_SLOT_AS", None)
    return {"suites": suites, "sandbox": sandbox, "state": state, "env": e, "tmp": tmp_path}


def make_suite(env, cases, name="s", extra=""):
    """cases: {id: (bash body, regimes string)}"""
    d = env["suites"] / name
    d.mkdir()
    toml = f'suite = "{name}"\n{extra}\n'
    for cid, (body, regimes) in cases.items():
        toml += CASE.format(id=cid, regimes=regimes)
        (d / f"{cid}.sh").write_text("set -u\nsp=$SEAM_PROBE\n" + textwrap.dedent(body))
    (d / "suite.toml").write_text(toml)
    return d


def tool(env, *args, extra_env=None, cwd=None):
    e = dict(env["env"], **(extra_env or {}))
    return subprocess.run([str(TOOL), *args], capture_output=True, text=True, env=e, cwd=cwd, timeout=300)


# ---- declarations ------------------------------------------------------------------------------

@pytest.mark.parametrize("mutate,needle", [
    (lambda t: t.replace('relies = "r"\n', ""), "`relies` is required"),
    (lambda t: t.replace('plants = [{ id = "p1", expect = "FAIL" }]\n', ""), "at least one plant"),
    (lambda t: t.replace('expect = "FAIL"', 'expect = "PASS"'), "must expect FAIL"),
    (lambda t: t.replace('regimes = ["none"]', 'regimes = ["sandboxed"]'), "`regimes` must be"),
    (lambda t: t.replace("minutes = 1", "minutes = 0"), "`minutes` must be"),
    (lambda t: t + 'flavor = "x"\n', "unknown keys"),
    (lambda t: t + 'commands = { remove = "wt remove x; ls" }\n', "is compound"),
    (lambda t: t + 'commands = { remove = "git -C a log | head" }\n', "is compound"),
    (lambda t: t.replace('script = "c.sh"', 'script = "missing.sh"'), "is not a file"),
])
def test_lint_refuses(env, mutate, needle):
    d = make_suite(env, {"c": ("", '"none"')})
    (d / "suite.toml").write_text(mutate((d / "suite.toml").read_text()))
    r = tool(env, "lint", "s")
    assert r.returncode == 2 and needle in r.stdout, r.stdout + r.stderr


def test_lint_accepts_a_single_command(env):
    d = make_suite(env, {"c": ("", '"none"')})
    (d / "suite.toml").write_text((d / "suite.toml").read_text() + 'commands = { remove = "wt remove --no-hooks --foreground x" }\n')
    assert tool(env, "lint", "s").returncode == 0


def test_shipped_suites_lint_clean(env):
    r = tool(env, "lint", extra_env={"SEAM_PROBE_SUITES": str(SHIPPED)})
    assert r.returncode == 0, r.stdout + r.stderr


# ---- verdicts and exit codes -------------------------------------------------------------------

@pytest.mark.parametrize("body,code,shown", [
    ('"$sp" verdict FAIL "it broke"\n', 1, "FAIL"),
    ('"$sp" verdict VOID "control misbehaved"\n', 3, "VOID"),
    ('"$sp" verdict DENIED "classifier"\n', 5, "DENIED"),
    ('"$sp" verdict SKIPPED "no trust"\n', 6, "SKIPPED"),
    ("exit 0\n", 3, "INCONCLUSIVE"),
    ('"$sp" verdict PASS "fine"\n', 4, "NOT-SEEN-RED"),
])
def test_verdict_exit(env, body, code, shown):
    make_suite(env, {"c": (body, '"none"')})
    r = tool(env, "run", "s", "--yes")
    assert r.returncode == code, r.stdout + r.stderr
    assert shown in r.stdout


def test_red_then_pass_is_zero(env):
    body = 'if [ "$SEAM_PROBE_PLANT" = p1 ]; then "$sp" verdict FAIL planted; else "$sp" verdict PASS fine; fi\n'
    d = make_suite(env, {"c": (body, '"none"')})
    r = tool(env, "red", "s", "c", "--yes")
    assert r.returncode == 0 and "RED" in r.stdout, r.stdout + r.stderr
    assert tool(env, "run", "s", "--yes").returncode == 0
    # Changing the case script retires its red.
    (d / "c.sh").write_text((d / "c.sh").read_text() + "# changed\n")
    assert tool(env, "run", "s", "--yes").returncode == 4


def test_red_key_includes_versions(env, tmp_path):
    body = 'if [ "$SEAM_PROBE_PLANT" = p1 ]; then "$sp" verdict FAIL planted; else "$sp" verdict PASS fine; fi\n'
    make_suite(env, {"c": (body, '"none"')})
    fake = tmp_path / "bin"
    fake.mkdir()
    (fake / "claude").write_text("#!/bin/sh\necho 9.9.9 '(Claude Code)'\n")
    (fake / "claude").chmod(0o755)
    path_a = {"PATH": f"{fake}:{os.environ['PATH']}"}
    assert tool(env, "red", "s", "c", "--yes", extra_env=path_a).returncode == 0
    assert tool(env, "run", "s", "--yes", extra_env=path_a).returncode == 0
    (fake / "claude").write_text("#!/bin/sh\necho 9.9.10 '(Claude Code)'\n")
    assert tool(env, "run", "s", "--yes", extra_env=path_a).returncode == 4


def test_plant_that_passes_is_blind(env):
    make_suite(env, {"c": ('"$sp" verdict PASS "never fails"\n', '"none"')})
    r = tool(env, "red", "s", "c", "--yes")
    assert r.returncode == 4 and "BLIND" in r.stdout, r.stdout + r.stderr


def test_fail_wins_over_unknowns():
    assert sp.combine([0, 6, 1, 3]) == 1
    assert sp.combine([0, 3, 6]) == 6
    assert sp.combine([]) == 0


def test_second_verdict_for_an_arm_is_refused(env):
    body = '"$sp" verdict --arm a PASS one\n"$sp" verdict --arm a FAIL two && echo SECOND-ACCEPTED\n"$sp" verdict --arm b FAIL other\n'
    make_suite(env, {"c": (body, '"none"')})
    r = tool(env, "run", "s", "--yes")
    run_dir = max((env["state"] / "s").iterdir(), key=lambda p: p.name)
    out = (run_dir / "output-c.txt").read_text()
    assert "SECOND-ACCEPTED" not in out and "already given" in out
    assert r.returncode == 1 and "c/b" in r.stdout and "c/a" in r.stdout


# ---- fixtures and cleanup ----------------------------------------------------------------------

def test_fixture_is_removed_after_the_case(env):
    body = 'repo=$("$sp" fixture repo f1) || exit 1\nprintf "%s\\n" "$repo" > "$SEAM_PROBE_SUITE_DIR/seen"\n"$sp" verdict FAIL x\n'
    d = make_suite(env, {"c": (body, '"none"')})
    tool(env, "run", "s", "--yes")
    repo = Path((d / "seen").read_text().strip())
    assert repo.parent == env["sandbox"] / "seams" / "s" and not repo.exists()
    assert not (repo.parent / "f1.remote.git").exists()


def test_fixture_commits_skip_signing_and_hooks(env):
    body = ('repo=$("$sp" fixture repo f1) || exit 1\n'
            'git -C "$repo" config --get commit.gpgsign > "$SEAM_PROBE_SUITE_DIR/sign"\n'
            'git -C "$repo" log --oneline origin/main > "$SEAM_PROBE_SUITE_DIR/pushed"\n'
            '"$sp" verdict FAIL x\n')
    d = make_suite(env, {"c": (body, '"none"')})
    tool(env, "run", "s", "--yes")
    assert (d / "sign").read_text().strip() == "false"
    assert "fixture" in (d / "pushed").read_text()


def test_interrupt_cleans_up(env):
    body = 'repo=$("$sp" fixture repo f1) || exit 1\ntouch "$SEAM_PROBE_SUITE_DIR/ready"\nsleep 60\n"$sp" verdict PASS late\n'
    d = make_suite(env, {"c": (body, '"none"')})
    p = subprocess.Popen([str(TOOL), "run", "s", "--yes"], env=env["env"], stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    deadline = time.time() + 60
    while not (d / "ready").exists() and time.time() < deadline:
        time.sleep(0.2)
    assert (d / "ready").exists()
    assert (env["sandbox"] / "seams/s/f1").exists()
    p.send_signal(signal.SIGINT)
    p.communicate(timeout=60)
    assert p.returncode == 130
    assert not (env["sandbox"] / "seams/s/f1").exists()


def test_refuses_to_replace_a_directory_it_did_not_make(env):
    stranger = env["sandbox"] / "seams/s/f1"
    stranger.mkdir(parents=True)
    (stranger / "keep.txt").write_text("not a fixture")
    body = '"$sp" fixture repo f1 || "$sp" verdict INCONCLUSIVE refused\n'
    make_suite(env, {"c": (body, '"none"')})
    r = tool(env, "run", "s", "--yes")
    assert "refused" in r.stdout and (stranger / "keep.txt").exists()


def test_fixture_root_outside_the_sandbox_is_refused(env, tmp_path):
    ledger = tmp_path / "l.jsonl"
    r = tool(env, "fixture", "repo", "f1", extra_env={"SEAM_PROBE_RUN": str(ledger),
                                                      "SEAM_PROBE_FIXTURES": str(tmp_path / "elsewhere")})
    assert r.returncode == 2 and "outside" in r.stderr
    assert not (tmp_path / "elsewhere").exists()


def test_primitive_needs_a_run(env):
    r = tool(env, "verdict", "PASS", "x")
    assert r.returncode == 2 and "SEAM_PROBE_RUN" in r.stderr


# ---- evidence ----------------------------------------------------------------------------------

def test_no_symlink(tmp_path):
    root = tmp_path / "repo"
    (root / ".claude/worktrees").mkdir(parents=True)
    assert sp.prim_no_symlink(str(root), ".claude/worktrees") == 0
    (root / ".claude/worktrees").rmdir()
    (root / "real").mkdir()
    (root / ".claude/worktrees").symlink_to(root / "real")
    assert sp.prim_no_symlink(str(root), ".claude/worktrees") == 1
    other = tmp_path / "repo2"
    other.mkdir()
    (other / ".claude").symlink_to(root / "real")
    assert sp.prim_no_symlink(str(other), ".claude/worktrees") == 1


def test_no_symlink_reports_above_the_root(tmp_path, capsys):
    (tmp_path / "real/.claude/worktrees").mkdir(parents=True)
    (tmp_path / "link").symlink_to(tmp_path / "real")
    assert sp.prim_no_symlink(str(tmp_path / "link"), ".claude/worktrees") == 0
    assert "at or above" in capsys.readouterr().out


# ---- where it may run, and what it prints ------------------------------------------------------

def test_session_case_refused_inside_claude_code(env):
    make_suite(env, {"c": ('"$sp" verdict PASS x\n', '"real"')})
    r = tool(env, "run", "s", "--yes", extra_env={"CLAUDECODE": "1"})
    assert r.returncode == 2 and "plain terminal" in r.stderr
    r = tool(env, "red", "s", "c", "--yes", extra_env={"CLAUDECODE": "1"})
    assert r.returncode == 2


def test_none_regime_runs_inside_claude_code(env):
    make_suite(env, {"c": ('"$sp" verdict FAIL x\n', '"none"')})
    assert tool(env, "run", "s", "--yes", extra_env={"CLAUDECODE": "1"}).returncode == 1


def test_no_terminal_without_yes_is_refused(env):
    make_suite(env, {"c": ('"$sp" verdict PASS x\n', '"none"')})
    r = subprocess.run([str(TOOL), "run", "s"], capture_output=True, text=True, env=env["env"],
                       stdin=subprocess.DEVNULL, timeout=60)
    assert r.returncode == 2 and "--yes" in r.stderr


def test_summary_names_no_path(env):
    body = '"$sp" verdict FAIL "saw $HOME/secret-place and $SEAM_PROBE_FIXTURES/f1"\n'
    make_suite(env, {"c": (body, '"none"')})
    tool(env, "run", "s", "--yes")
    run_dir = max((env["state"] / "s").iterdir(), key=lambda p: p.name)
    summary = (run_dir / "summary.txt").read_text()
    assert env["env"]["HOME"] not in summary and "<fixtures>/f1" in summary and "~/secret-place" in summary
    rec = json.loads((run_dir / "results.jsonl").read_text().splitlines()[0])
    assert rec["case"] == "c" and rec["arms"][0]["verdict"] == "FAIL" and "version_claude" in rec


def test_heavy_case_waits_for_the_slot(env, tmp_path):
    d = make_suite(env, {"c": ('"$sp" verdict PASS x\n', '"none"')})
    (d / "suite.toml").write_text((d / "suite.toml").read_text() + "heavy = true\n")
    fake = tmp_path / "bin"
    fake.mkdir()
    (fake / "fleet-slot").write_text("#!/bin/sh\necho 'held by someone-else'\nexit 1\n")
    (fake / "fleet-slot").chmod(0o755)
    r = tool(env, "run", "s", "--yes", extra_env={"PATH": f"{fake}:{os.environ['PATH']}"})
    assert r.returncode == 6 and "someone-else" in r.stdout


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))
