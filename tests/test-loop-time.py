#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for loop-time. Every project here is a tiny scratch git repository under a temp dir and
every loop a stand-in command, so nothing depends on Nx, node or a real project."""
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
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_loop-time"


def _load():
    loader = importlib.machinery.SourceFileLoader("loop_time", str(TOOL))
    spec = importlib.util.spec_from_loader("loop_time", loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["loop_time"] = mod
    loader.exec_module(mod)
    return mod


lt = _load()


@pytest.fixture(autouse=True)
def isolated_git(monkeypatch, tmp_path_factory):
    monkeypatch.setenv("LOOP_TIME_TMP_ROOT", str(tmp_path_factory.mktemp("tmproot")))
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    monkeypatch.setenv("GIT_AUTHOR_NAME", "t")
    monkeypatch.setenv("GIT_AUTHOR_EMAIL", "t@example.invalid")
    monkeypatch.setenv("GIT_COMMITTER_NAME", "t")
    monkeypatch.setenv("GIT_COMMITTER_EMAIL", "t@example.invalid")
    monkeypatch.delenv("LOOP_TIME_RESULTS", raising=False)


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout


@pytest.fixture
def project(tmp_path):
    """A scratch repo: lib/a.txt holds OK; check.sh fails when it holds BUG."""
    root = tmp_path / "proj"
    (root / "lib").mkdir(parents=True)
    (root / "lib" / "a.txt").write_text("OK\n")
    (root / "check.sh").write_text("#!/bin/sh\n! grep -q BUG lib/a.txt\n")
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init")
    return root


DECL = """\
project = "demo"
root = "{root}"
versions = ["sh -c 'echo v1'"]

[[loop]]
id = "check"
command = "sh check.sh"
cold_prep = ["echo prep >> {prep}"]

[[loop]]
id = "listy"
command = ["sh", "-c", "exit 0"]

[[scenario]]
name = "leaf"
file = "lib/a.txt"
edit = {{ append = "touched" }}
plant = {{ find = "OK", replace = "BUG" }}
loops = ["check"]
"""


@pytest.fixture
def decl_path(project, tmp_path):
    p = tmp_path / "decl.toml"
    p.write_text(DECL.format(root=project, prep=tmp_path / "prep.log"))
    return p


def records(path):
    return [json.loads(l) for l in Path(path).read_text().splitlines() if l.strip()]


def run_main(*argv):
    return lt.main([str(a) for a in argv])


def write_decl(tmp_path, project, body):
    p = tmp_path / "d.toml"
    p.write_text(f'project = "demo"\nroot = "{project}"\n' + textwrap.dedent(body))
    return p


# ---- declaration validation -------------------------------------------------------------

def test_valid_declaration_loads(decl_path):
    d = lt.load_decl(decl_path)
    assert d.project == "demo"
    assert [l.id for l in d.loops] == ["check", "listy"]
    assert d.scenarios[0].name == "leaf"


def test_command_string_runs_in_a_shell_and_list_is_argv(decl_path):
    d = lt.load_decl(decl_path)
    assert lt.command_argv(d.loops[0].command) == ["sh", "-c", "sh check.sh"]
    assert lt.command_argv(d.loops[1].command) == ["sh", "-c", "exit 0"]


@pytest.mark.parametrize("body,needle", [
    ('bogus = 1\n[[loop]]\nid="a"\ncommand="true"\n', "bogus"),
    ('[[loop]]\nid="a"\ncommand="true"\nspeed = 3\n', "speed"),
    ('[[loop]]\nid="a"\ncommand="true"\n[[scenario]]\nname="s"\nfile="lib/a.txt"\nedit={append="x"}\n'
     'plant={append="y"}\nloops=["a"]\nextra=1\n', "extra"),
    ('[[loop]]\nid="a"\ncommand="true"\n[[scenario]]\nname="s"\nfile="lib/a.txt"\nedit={append="x"}\n'
     'plant={append="y", surprise="z"}\nloops=["a"]\n', "surprise"),
])
def test_unknown_keys_are_rejected(tmp_path, project, body, needle):
    p = write_decl(tmp_path, project, body)
    with pytest.raises(lt.DeclError) as e:
        lt.load_decl(p)
    assert needle in "\n".join(e.value.problems)


def test_scenario_without_plant_is_rejected(tmp_path, project):
    p = write_decl(tmp_path, project, '[[loop]]\nid="a"\ncommand="true"\n[[scenario]]\nname="s"\n'
                   'file="lib/a.txt"\nedit={append="x"}\nloops=["a"]\n')
    with pytest.raises(lt.DeclError) as e:
        lt.load_decl(p)
    assert "plant" in "\n".join(e.value.problems)


def test_scenario_without_edit_is_rejected(tmp_path, project):
    p = write_decl(tmp_path, project, '[[loop]]\nid="a"\ncommand="true"\n[[scenario]]\nname="s"\n'
                   'file="lib/a.txt"\nplant={append="x"}\nloops=["a"]\n')
    with pytest.raises(lt.DeclError) as e:
        lt.load_decl(p)
    assert "edit" in "\n".join(e.value.problems)


def test_missing_and_escaping_scenario_files_are_rejected(tmp_path, project):
    for f in ("lib/nope.txt", "../outside.txt"):
        p = write_decl(tmp_path, project, f'[[loop]]\nid="a"\ncommand="true"\n[[scenario]]\nname="s"\n'
                       f'file="{f}"\nedit={{append="x"}}\nplant={{append="y"}}\nloops=["a"]\n')
        with pytest.raises(lt.DeclError):
            lt.load_decl(p)


def test_plant_text_must_be_present_in_the_file(tmp_path, project):
    p = write_decl(tmp_path, project, '[[loop]]\nid="a"\ncommand="true"\n[[scenario]]\nname="s"\n'
                   'file="lib/a.txt"\nedit={append="x"}\nplant={find="ABSENT", replace="y"}\nloops=["a"]\n')
    with pytest.raises(lt.DeclError) as e:
        lt.load_decl(p)
    assert "ABSENT" in "\n".join(e.value.problems)


def test_unknown_loop_runner_duplicate_ids_and_missing_root(tmp_path, project):
    for body in (
        '[[loop]]\nid="a"\ncommand="true"\n[[scenario]]\nname="s"\nfile="lib/a.txt"\nedit={append="x"}\n'
        'plant={append="y"}\nloops=["zzz"]\n',
        '[[loop]]\nid="a"\ncommand="true"\nrunner="make"\n',
        '[[loop]]\nid="a"\ncommand="true"\n[[loop]]\nid="a"\ncommand="true"\n',
        '[[loop]]\nid="a"\n',
    ):
        with pytest.raises(lt.DeclError):
            lt.load_decl(write_decl(tmp_path, project, body))
    p = tmp_path / "e.toml"
    p.write_text('project="x"\nroot="/nonexistent/dir"\n[[loop]]\nid="a"\ncommand="true"\n')
    with pytest.raises(lt.DeclError):
        lt.load_decl(p)


def test_plan_prints_commands_and_validates(decl_path, capsys):
    assert run_main("plan", decl_path) == 0
    out = capsys.readouterr().out
    assert "sh check.sh" in out and "scenario:leaf" in out and "prep.log" in out
    assert "sequence" in out and "edit: append" in out and "plant: replace" in out


def test_plan_exits_nonzero_on_unknown_key(tmp_path, project, capsys):
    p = write_decl(tmp_path, project, 'bogus = 1\n[[loop]]\nid="a"\ncommand="true"\n')
    assert run_main("plan", p) == 2
    assert "bogus" in capsys.readouterr().err


def test_plan_cli_subprocess_nonzero_on_invalid(tmp_path, project):
    p = write_decl(tmp_path, project, '[[loop]]\nid="a"\ncommand="true"\nspeed=1\n')
    r = subprocess.run([str(TOOL), "plan", str(p)], capture_output=True, text=True)
    assert r.returncode == 2 and "speed" in r.stderr


# ---- platform reads and their degrade path ----------------------------------------------

def test_parse_meminfo_and_vm_stat():
    assert lt.parse_meminfo("MemTotal: 100 kB\nMemAvailable:    2048 kB\n") == 2048 * 1024
    assert lt.parse_meminfo("MemTotal: 100 kB\n") is None
    vm = ("Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
          "Pages free:                               100.\nPages inactive:                           50.\n"
          "Pages speculative:                        10.\n")
    assert lt.parse_vm_stat(vm) == 160 * 16384
    assert lt.parse_vm_stat("garbage") is None


def test_read_free_memory_degrades_with_a_reason():
    b, reason = lt.read_free_memory(system="Plan9")
    assert b is None and reason
    b, reason = lt.read_free_memory(system="Linux", meminfo_path="/nonexistent/meminfo")
    assert b is None and reason
    b, reason = lt.read_free_memory(system="Darwin", vm_stat_cmd=["/nonexistent/vm_stat"])
    assert b is None and reason


def test_read_free_memory_live_does_not_crash():
    b, reason = lt.read_free_memory()
    assert (b is None) == bool(reason)


def test_tmp_usage_counts_own_files_and_degrades(tmp_path):
    (tmp_path / "f").write_bytes(b"x" * 5000)
    b, reason = lt.tmp_usage(root=tmp_path)
    assert reason is None and b >= 5000
    b, reason = lt.tmp_usage(root=tmp_path / "missing")
    assert b is None and reason


# ---- nx output parsing ------------------------------------------------------------------

NX_OUT = """\
\x1b[2m> nx run-many -t test\x1b[22m

> nx run core:build  [local cache]
> nx run core:test
> nx run ui:build  [existing outputs match the cache, left as is]
> nx run ui:test:ci  [remote cache]

 NX   Successfully ran target test for 2 projects

Nx read the output from the cache instead of running the command for 3 out of 4 tasks.
"""


def test_nx_parse_finds_tasks_and_cache_hits():
    r = lt.parse_nx_output(NX_OUT)
    assert r["tasks"] == ["core:build", "core:test", "ui:build", "ui:test:ci"]
    assert r["cache_hits"] == ["core:build", "ui:build", "ui:test:ci"]


def test_nx_parse_uses_the_summary_when_task_lines_are_absent():
    r = lt.parse_nx_output("Nx read the output from the cache instead of running the command for 2 out of 5 tasks.\n")
    assert r["tasks"] == [] and r["summary_cached"] == 2 and r["summary_total"] == 5


def test_nx_parse_of_unrelated_output_is_empty_not_a_crash():
    r = lt.parse_nx_output("hello\n\x00\xff garbage")
    assert r["tasks"] == [] and r["cache_hits"] == []


# ---- load guard -------------------------------------------------------------------------

def test_load_guard_refuses_above_threshold():
    sleeps = []
    with pytest.raises(lt.LoadError):
        lt.wait_for_load(1.0, False, getload=lambda: 5.0, sleep=sleeps.append, wait=10, interval=5)
    assert sleeps  # it waited before refusing


def test_load_guard_waits_then_proceeds_when_load_drops():
    loads = iter([5.0, 5.0, 0.2])
    assert lt.wait_for_load(1.0, False, getload=lambda: next(loads), sleep=lambda s: None, wait=60, interval=5) is False


def test_load_guard_force_records_under_load():
    assert lt.wait_for_load(1.0, True, getload=lambda: 9.0, sleep=lambda s: None, wait=10, interval=5) is True


def test_load_guard_through_the_cli(decl_path, tmp_path):
    res = tmp_path / "r.jsonl"
    r = subprocess.run([str(TOOL), "run", str(decl_path), "listy", "--max-load=-1", "--load-wait", "0",
                        "--samples", "1", "--results", str(res)], capture_output=True, text=True)
    assert r.returncode == 4 and "load" in r.stderr
    assert not res.exists() or records(res) == []
    r = subprocess.run([str(TOOL), "run", str(decl_path), "listy", "--max-load=-1", "--force", "--samples", "1",
                        "--results", str(res)], capture_output=True, text=True)
    assert r.returncode == 0
    assert records(res)[0]["under_load"] is True


# ---- running ----------------------------------------------------------------------------

def test_warm_run_records_a_full_sample(decl_path, project, tmp_path):
    res = tmp_path / "res" / "r.jsonl"
    assert run_main("run", decl_path, "check", "--samples", "2", "--results", res, "--max-load", "9999") == 0
    recs = records(res)
    assert len(recs) == 2
    r = recs[0]
    for k in ("timestamp", "project", "loop", "mode", "scenario", "sample", "exit_code", "wall_seconds",
              "cpu_seconds", "git_head", "tree_dirty", "start", "end", "versions", "under_load", "output"):
        assert k in r, k
    assert (r["project"], r["loop"], r["mode"], r["sample"], r["exit_code"]) == ("demo", "check", "warm", 0, 0)
    assert r["git_head"] == git(project, "rev-parse", "HEAD").strip()
    assert r["tree_dirty"] is False and r["under_load"] is False
    assert r["versions"] == {"sh -c 'echo v1'": "v1"}
    assert "load1" in r["start"] and "mem_free_bytes" in r["start"] and "tmp_bytes" in r["start"]
    assert Path(r["output"]).exists()
    assert str(Path(r["output"]).parent).startswith(str(res.parent))


def test_results_default_comes_from_the_environment(decl_path, tmp_path, monkeypatch):
    res = tmp_path / "env.jsonl"
    monkeypatch.setenv("LOOP_TIME_RESULTS", str(res))
    assert run_main("run", decl_path, "listy", "--samples", "1", "--max-load", "9999") == 0
    assert len(records(res)) == 1


def test_dirty_tree_is_recorded(decl_path, project, tmp_path):
    (project / "stray.txt").write_text("x")
    res = tmp_path / "r.jsonl"
    run_main("run", decl_path, "listy", "--samples", "1", "--results", res, "--max-load", "9999")
    assert records(res)[0]["tree_dirty"] is True


def test_cpu_time_is_measured(tmp_path, project):
    p = write_decl(tmp_path, project, '[[loop]]\nid="burn"\ncommand=["python3","-c","sum(range(3_000_000))"]\n')
    res = tmp_path / "r.jsonl"
    run_main("run", p, "burn", "--samples", "1", "--results", res, "--max-load", "9999")
    assert records(res)[0]["cpu_seconds"] > 0.01


def test_cold_runs_prep_first_each_sample(decl_path, tmp_path):
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "check", "--mode", "cold", "--samples", "2", "--results", res,
                    "--max-load", "9999") == 0
    assert (tmp_path / "prep.log").read_text().split() == ["prep", "prep"]
    assert {r["mode"] for r in records(res)} == {"cold"}


def test_failing_loop_is_recorded_and_exits_one(tmp_path, project):
    p = write_decl(tmp_path, project, '[[loop]]\nid="bad"\ncommand="exit 3"\n')
    res = tmp_path / "r.jsonl"
    assert run_main("run", p, "bad", "--samples", "1", "--results", res, "--max-load", "9999") == 1
    assert records(res)[0]["exit_code"] == 3


def test_nx_runner_records_tasks_and_cache_hits(tmp_path, project):
    canned = project / "canned.txt"
    canned.write_text(NX_OUT)
    git(project, "add", "-A")
    git(project, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "canned")
    p = write_decl(tmp_path, project, '[[loop]]\nid="nx"\nrunner="nx"\ncommand="cat canned.txt"\n')
    res = tmp_path / "r.jsonl"
    assert run_main("run", p, "nx", "--samples", "1", "--results", res, "--max-load", "9999") == 0
    r = records(res)[0]
    assert r["nx"]["tasks"] == ["core:build", "core:test", "ui:build", "ui:test:ci"]
    assert len(r["nx"]["cache_hits"]) == 3
    assert "core:build" in Path(r["output"]).read_text()


def test_unknown_loop_or_mode_is_an_error(decl_path, tmp_path):
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "nope", "--results", res) == 2
    assert run_main("run", decl_path, "check", "--mode", "scenario:nope", "--results", res) == 2
    assert run_main("run", decl_path, "check", "--mode", "weird", "--results", res) == 2


# ---- scenarios --------------------------------------------------------------------------

def test_scenario_catches_the_planted_defect_and_restores(decl_path, project, tmp_path):
    before = (project / "lib" / "a.txt").read_bytes()
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "check", "--mode", "scenario:leaf", "--samples", "2", "--results", res,
                    "--max-load", "9999") == 0
    recs = records(res)
    assert [(r["step"], r["exit_code"]) for r in recs[:2]] == [("edit", 0), ("plant", 1)]
    assert recs[1]["caught"] is True and recs[0]["scenario"] == "leaf"
    assert len(recs) == 4
    assert (project / "lib" / "a.txt").read_bytes() == before


def test_planted_run_that_exits_zero_is_reported_blind(tmp_path, project, capsys):
    p = write_decl(tmp_path, project, '[[loop]]\nid="blind"\ncommand="exit 0"\n[[scenario]]\nname="leaf"\n'
                   'file="lib/a.txt"\nedit={append="x"}\nplant={find="OK", replace="BUG"}\nloops=["blind"]\n')
    res = tmp_path / "r.jsonl"
    rc = run_main("run", p, "blind", "--mode", "scenario:leaf", "--samples", "1", "--results", res,
                  "--max-load", "9999")
    assert rc == 3
    assert "BLIND" in capsys.readouterr().err
    assert records(res)[1]["caught"] is False
    assert (project / "lib" / "a.txt").read_text() == "OK\n"


def test_scenario_must_apply_to_the_loop(decl_path, tmp_path):
    assert run_main("run", decl_path, "listy", "--mode", "scenario:leaf", "--results", tmp_path / "r") == 2


def test_failing_edit_run_aborts_the_scenario_without_planting(tmp_path, project):
    p = write_decl(tmp_path, project, '[[loop]]\nid="x"\ncommand="exit 2"\n[[scenario]]\nname="leaf"\n'
                   'file="lib/a.txt"\nedit={append="x"}\nplant={find="OK", replace="BUG"}\nloops=["x"]\n')
    res = tmp_path / "r.jsonl"
    assert run_main("run", p, "x", "--mode", "scenario:leaf", "--samples", "1", "--results", res,
                    "--max-load", "9999") == 1
    assert [r["step"] for r in records(res)] == ["edit"]
    assert (project / "lib" / "a.txt").read_text() == "OK\n"


def test_scenario_file_is_restored_after_an_exception(decl_path, project, tmp_path, monkeypatch):
    calls = []
    real = lt.measure

    def boom(*a, **k):
        calls.append(1)
        if len(calls) == 2:  # the planted run: the file holds the defect right now
            assert "BUG" in (project / "lib" / "a.txt").read_text()
            raise OSError("boom")
        return real(*a, **k)

    monkeypatch.setattr(lt, "measure", boom)
    with pytest.raises(OSError):
        run_main("run", decl_path, "check", "--mode", "scenario:leaf", "--samples", "1",
                 "--results", tmp_path / "r.jsonl", "--max-load", "9999")
    assert (project / "lib" / "a.txt").read_text() == "OK\n"


def test_scenario_file_is_restored_after_keyboard_interrupt(decl_path, project, tmp_path, monkeypatch):
    def interrupted(*a, **k):
        raise KeyboardInterrupt

    monkeypatch.setattr(lt, "measure", interrupted)
    rc = run_main("run", decl_path, "check", "--mode", "scenario:leaf", "--samples", "1",
                  "--results", tmp_path / "r.jsonl", "--max-load", "9999")
    assert rc == 130
    assert (project / "lib" / "a.txt").read_text() == "OK\n"


def test_sigterm_restores_the_file(tmp_path, project):
    p = write_decl(tmp_path, project, '[[loop]]\nid="slow"\ncommand="sleep 30"\n[[scenario]]\nname="leaf"\n'
                   'file="lib/a.txt"\nedit={append="x"}\nplant={find="OK", replace="BUG"}\nloops=["slow"]\n')
    proc = subprocess.Popen([str(TOOL), "run", str(p), "slow", "--mode", "scenario:leaf", "--samples", "1",
                             "--results", str(tmp_path / "r.jsonl"), "--max-load", "9999"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    target = project / "lib" / "a.txt"
    for _ in range(300):
        if target.read_text() != "OK\n":
            break
        time.sleep(0.1)
    assert target.read_text() != "OK\n", "the edit never appeared"
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=20)
    assert target.read_text() == "OK\n"


def test_unverifiable_restore_refuses_to_continue(decl_path, project, tmp_path, monkeypatch):
    monkeypatch.setattr(lt, "restore_file", lambda path, data: None)  # a revert that does nothing
    res = tmp_path / "r.jsonl"
    rc = run_main("run", decl_path, "check", "--mode", "scenario:leaf", "--samples", "2", "--results", res,
                  "--max-load", "9999")
    assert rc == 5
    assert len(records(res)) == 1  # it stopped after the first step
    git(project, "checkout", "--", "lib/a.txt")


def test_refuses_to_start_when_a_scenario_file_differs_from_head(decl_path, project, tmp_path, capsys):
    (project / "lib" / "a.txt").write_text("OK\nlocal change\n")
    res = tmp_path / "r.jsonl"
    rc = run_main("run", decl_path, "check", "--mode", "scenario:leaf", "--results", res, "--max-load", "9999")
    assert rc == 2 and "differs from HEAD" in capsys.readouterr().err
    assert (project / "lib" / "a.txt").read_text() == "OK\nlocal change\n"
    assert not res.exists()


def test_sequence_runs_cold_then_edits_and_restores(tmp_path, project):
    (project / "lib" / "b.txt").write_text("B\n")
    git(project, "add", "-A")
    git(project, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "b")
    p = write_decl(tmp_path, project, '''
        [[loop]]
        id = "check"
        command = "sh check.sh"
        cold_prep = ["echo prep >> ../prep.log"]
        [[scenario]]
        name = "one"
        file = "lib/a.txt"
        edit = { append = "e1" }
        plant = { find = "OK", replace = "BUG" }
        loops = ["check"]
        [[scenario]]
        name = "two"
        file = "lib/b.txt"
        edit = { append = "e2" }
        plant = { append = "p2" }
        loops = ["check"]
    ''')
    res = tmp_path / "r.jsonl"
    assert run_main("run", p, "check", "--mode", "sequence", "--samples", "1", "--results", res,
                    "--max-load", "9999") == 0
    assert [r["step"] for r in records(res)] == ["cold", "edit:one", "edit:two"]
    assert {r["mode"] for r in records(res)} == {"sequence"}
    assert (project / "lib" / "a.txt").read_text() == "OK\n"
    assert (project / "lib" / "b.txt").read_text() == "B\n"
    assert (tmp_path / "prep.log").read_text().split() == ["prep"]


def test_sequence_edits_accumulate_without_reverting_between_steps(tmp_path, project):
    p = write_decl(tmp_path, project, '''
        [[loop]]
        id = "peek"
        command = "cat lib/a.txt"
        [[scenario]]
        name = "one"
        file = "lib/a.txt"
        edit = { append = "e1" }
        plant = { append = "p" }
        loops = ["peek"]
        [[scenario]]
        name = "two"
        file = "lib/a.txt"
        edit = { append = "e2" }
        plant = { append = "p" }
        loops = ["peek"]
    ''')
    res = tmp_path / "r.jsonl"
    run_main("run", p, "peek", "--mode", "sequence", "--samples", "1", "--results", res, "--max-load", "9999")
    last = records(res)[-1]
    assert "e1" in Path(last["output"]).read_text() and "e2" in Path(last["output"]).read_text()
    assert (project / "lib" / "a.txt").read_text() == "OK\n"


# ---- report -----------------------------------------------------------------------------

def _rec(loop, mode, wall, cpu, step=None, sample=0, nx=None):
    r = {"project": "demo", "loop": loop, "mode": mode, "step": step, "scenario": None, "sample": sample,
         "exit_code": 0, "wall_seconds": wall, "cpu_seconds": cpu}
    if nx:
        r["nx"] = nx
    return r


def test_report_summarizes_per_group(tmp_path, capsys):
    res = tmp_path / "r.jsonl"
    rows = [_rec("a", "warm", w, w * 2, sample=i,
                 nx={"tasks": ["t1", "t2"], "cache_hits": ["t1"]}) for i, w in enumerate([1.0, 3.0, 2.0])]
    rows.append(_rec("b", "cold", 10.0, 5.0))
    res.write_text("\n".join(json.dumps(r) for r in rows) + "\nnot json\n")
    assert run_main("report", "--results", res, "--json") == 0
    data = json.loads(capsys.readouterr().out)
    a = next(g for g in data if g["loop"] == "a")
    assert (a["samples"], a["wall_median"], a["wall_min"], a["wall_max"], a["cpu_median"]) == (3, 2.0, 1.0, 3.0, 4.0)
    assert a["cache_hit_share"] == 0.5
    b = next(g for g in data if g["loop"] == "b")
    assert b["cache_hit_share"] is None
    assert run_main("report", "--results", res) == 0
    out = capsys.readouterr().out
    assert "demo" in out and "50%" in out and "2.00" in out


def test_report_on_missing_file_is_an_error(tmp_path, capsys):
    assert run_main("report", "--results", tmp_path / "none.jsonl") == 2


def test_help_explains_modes_and_why_scenarios_plant_a_defect():
    r = subprocess.run([str(TOOL), "--help"], capture_output=True, text=True)
    assert r.returncode == 0
    for word in ("cold", "warm", "scenario", "sequence", "planted", "blind"):
        assert word in r.stdout


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
