#!/usr/bin/env -S uv run --script
# run-all: serial
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
    monkeypatch.setenv("LOOP_TIME_SCRATCH", str(tmp_path_factory.mktemp("scratchbase")))
    # Never the machine's real timing slot: `true check` answers "free". The slot tests below
    # point it at the real fleet-slot with a private state directory.
    monkeypatch.setenv("LOOP_TIME_SLOT_CMD", "true")


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


def test_nx_parse_reads_colored_output_as_a_real_run_prints_it():
    # Lines as Nx printed them in a real run with color on: each piece wrapped in escape codes,
    # and a task name whose configuration is a third colon-separated part.
    e = "\x1b"
    text = (
        f"{e}[2m> {e}[22m{e}[2mnx run{e}[22m app-web:lint  {e}[2m[existing outputs match the cache, left as is]{e}[22m\n"
        f"{e}[2m> {e}[22m{e}[2mnx run{e}[22m app:lint-format\n"
        f"{e}[2m> {e}[22m{e}[2mnx run{e}[22m app-web:build  {e}[2m[local cache]{e}[22m\n"
        f"{e}[2m> {e}[22m{e}[2mnx run{e}[22m app:check-drift:node\n"
        f"{e}[2mNx read the output from the cache instead of running the command for 1 out of 10 tasks.{e}[22m\n"
    )
    r = lt.parse_nx_output(text)
    assert r["tasks"] == ["app-web:lint", "app:lint-format", "app-web:build", "app:check-drift:node"]
    assert r["cache_hits"] == ["app-web:lint", "app-web:build"]
    assert (r["summary_cached"], r["summary_total"]) == (1, 10)


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


def test_load_guard_reads_the_load_through_the_module_at_call_time(monkeypatch):
    # The run commands' tests replace lt.read_loadavg; the guard must see the replacement, not the
    # function bound when the module loaded. No reading (None) passes, and a max of -1 is below any
    # real load, so this passes only if the replacement is the one read.
    monkeypatch.setattr(lt, "read_loadavg", lambda: None)
    assert lt.wait_for_load(-1.0, False, sleep=lambda s: None, wait=0) is False


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


def test_sample_placeholder_makes_each_samples_edit_and_plant_distinct(tmp_path, project, capsys):
    # Under a persistent cache (Nx), re-applying the identical edit makes samples 2..n replay the
    # first sample's result: they time the cache, not the loop (keystone, 2026-11-07). `{sample}` in
    # an edit's or a plant's text becomes a token unique to the sample.
    log = tmp_path / "seen.log"
    p = write_decl(tmp_path, project, f'''
        [[loop]]
        id = "check"
        command = "cat lib/a.txt >> {log} && sh check.sh"
        runner = "nx"
        [[scenario]]
        name = "leaf"
        file = "lib/a.txt"
        edit = {{ append = "touched {{sample}}" }}
        plant = {{ find = "OK", replace = "BUG {{sample}}" }}
        loops = ["check"]
    ''')
    res = tmp_path / "r.jsonl"
    assert run_main("run", p, "check", "--mode", "scenario:leaf", "--samples", "2", "--results", res,
                    "--max-load", "9999") == 0
    seen = log.read_text()
    edits = [l for l in seen.splitlines() if l.startswith("touched")]
    plants = [l for l in seen.splitlines() if l.startswith("BUG")]
    assert len(edits) == 2 and len(set(edits)) == 2 and "{sample}" not in seen
    assert len(plants) == 2 and len(set(plants)) == 2
    assert (project / "lib" / "a.txt").read_text() == "OK\n"
    assert "replay" not in capsys.readouterr().err


def test_repeated_nx_scenario_without_placeholder_is_warned(tmp_path, project, capsys):
    p = write_decl(tmp_path, project, '''
        [[loop]]
        id = "check"
        command = "sh check.sh"
        runner = "nx"
        [[scenario]]
        name = "leaf"
        file = "lib/a.txt"
        edit = { append = "touched" }
        plant = { find = "OK", replace = "BUG" }
        loops = ["check"]
    ''')
    assert run_main("run", p, "check", "--mode", "scenario:leaf", "--samples", "2", "--results",
                    tmp_path / "r.jsonl", "--max-load", "9999") == 0
    assert "replay" in capsys.readouterr().err


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


# ---- setup, teardown, env, fresh-scratch cold, find/replace edits ------------------------

def run_ok(*argv):
    return run_main(*argv, "--max-load", "9999")


def hook_decl(tmp_path, project, extra="", scenario=False):
    log = tmp_path / "hooks.log"
    body = f"""
        [[loop]]
        id = "h"
        command = "echo c >> {log}; ! grep -q BUG lib/a.txt"
        setup = ["echo s >> {log}"]
        teardown = ["echo t >> {log}"]
        cold_prep = ["echo p >> {log}"]
        {extra}
    """
    if scenario:
        body += """
        [[scenario]]
        name = "leaf"
        file = "lib/a.txt"
        edit = { append = "x" }
        plant = { find = "OK", replace = "BUG" }
        loops = ["h"]
        """
    return write_decl(tmp_path, project, body), log


def test_setup_and_teardown_wrap_every_sample(tmp_path, project):
    p, log = hook_decl(tmp_path, project)
    assert run_ok("run", p, "h", "--samples", "2", "--results", tmp_path / "r.jsonl") == 0
    assert log.read_text().split() == ["s", "c", "t", "s", "c", "t"]


@pytest.mark.parametrize("mode,expected", [
    ("warm", "s c t"),
    ("cold", "p s c t"),
    ("scenario:leaf", "s c t s c t"),
    ("sequence", "p s c t s c t"),
])
def test_setup_and_teardown_run_in_every_mode(tmp_path, project, mode, expected):
    p, log = hook_decl(tmp_path, project, scenario=True)
    assert run_ok("run", p, "h", "--mode", mode, "--samples", "1", "--results", tmp_path / "r.jsonl") == 0
    assert " ".join(log.read_text().split()) == expected


def test_setup_and_teardown_run_in_root_not_the_loop_cwd(tmp_path, project):
    p = write_decl(tmp_path, project, '[[loop]]\nid="h"\ncwd="lib"\ncommand="true"\n'
                   'setup=["pwd > where.txt"]\n')
    assert run_ok("run", p, "h", "--samples", "1", "--results", tmp_path / "r.jsonl") == 0
    assert (project / "where.txt").exists()
    assert not (project / "lib" / "where.txt").exists()


def test_teardown_runs_when_the_sample_fails(tmp_path, project):
    p = write_decl(tmp_path, project, f'[[loop]]\nid="h"\ncommand="exit 3"\nteardown=["echo t >> {tmp_path}/t.log"]\n')
    assert run_ok("run", p, "h", "--samples", "1", "--results", tmp_path / "r.jsonl") == 1
    assert (tmp_path / "t.log").read_text().split() == ["t"]


def test_teardown_runs_after_an_interrupt(tmp_path, project, monkeypatch):
    p, log = hook_decl(tmp_path, project)

    def interrupted(*a, **k):
        raise KeyboardInterrupt

    monkeypatch.setattr(lt, "measure", interrupted)
    assert run_ok("run", p, "h", "--samples", "1", "--results", tmp_path / "r.jsonl") == 130
    assert log.read_text().split() == ["s", "t"]


def test_sigterm_runs_teardown(tmp_path, project):
    p = write_decl(tmp_path, project, f'[[loop]]\nid="slow"\ncommand="sleep 30"\n'
                   f'setup=["touch {tmp_path}/up"]\nteardown=["touch {tmp_path}/down"]\n')
    proc = subprocess.Popen([str(TOOL), "run", str(p), "slow", "--samples", "1",
                             "--results", str(tmp_path / "r.jsonl"), "--max-load", "9999"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(300):
        if (tmp_path / "up").exists():
            time.sleep(0.5)
            break
        time.sleep(0.1)
    assert (tmp_path / "up").exists()
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=20)
    assert (tmp_path / "down").exists()


def test_failing_setup_aborts_the_sample_without_a_record(tmp_path, project, capsys):
    log = tmp_path / "l.log"
    p = write_decl(tmp_path, project, f'[[loop]]\nid="h"\ncommand="echo c >> {log}"\n'
                   f'setup=["echo boom >&2; exit 7"]\n')
    res = tmp_path / "r.jsonl"
    assert run_ok("run", p, "h", "--samples", "1", "--results", res) == 1
    err = capsys.readouterr().err
    assert "setup failed" in err and "exit 7" in err and "'h'" in err
    assert not res.exists() or records(res) == []
    assert not log.exists()


def test_setup_and_teardown_time_is_excluded_from_the_sample(tmp_path, project):
    p = write_decl(tmp_path, project, '[[loop]]\nid="h"\ncommand="true"\nsetup=["sleep 1"]\nteardown=["sleep 1"]\n')
    res = tmp_path / "r.jsonl"
    assert run_ok("run", p, "h", "--samples", "1", "--results", res) == 0
    assert records(res)[0]["wall_seconds"] < 0.5


def test_plan_prints_setup_teardown_and_env(tmp_path, project, capsys):
    p = write_decl(tmp_path, project, '[env]\nA = "1"\n[[loop]]\nid="h"\ncommand="true"\nsetup=["echo up"]\n'
                   'teardown=["echo down"]\ncold="fresh-scratch"\n[loop.env]\nB = "{scratch}/b"\n')
    assert run_main("plan", p) == 0
    out = capsys.readouterr().out
    assert "setup:" in out and "echo up" in out and "teardown:" in out and "echo down" in out
    assert "env:" in out and "A=1" in out and "B={scratch}/b" in out and "fresh-scratch" in out


@pytest.mark.parametrize("body,needle", [
    ('[[loop]]\nid="a"\ncommand="true"\nsetup="echo"\n', "setup"),
    ('[[loop]]\nid="a"\ncommand="true"\nteardown=[1]\n', "teardown"),
    ('[[loop]]\nid="a"\ncommand="true"\ncold="sometimes"\n', "cold"),
    ('[[loop]]\nid="a"\ncommand="true"\ncold="fresh-scratch"\n', "{scratch}"),
    ('[[loop]]\nid="a"\ncommand="true"\n[loop.env]\nA = 1\n', "env"),
    ('[[loop]]\nid="a"\ncommand="true"\n[loop.env]\n"A B" = "x"\n', "env"),
    ('env = "x"\n[[loop]]\nid="a"\ncommand="true"\n', "env"),
])
def test_new_loop_fields_are_validated(tmp_path, project, body, needle):
    with pytest.raises(lt.DeclError) as e:
        lt.load_decl(write_decl(tmp_path, project, body))
    assert needle in "\n".join(e.value.problems)


ENV_DECL = """
    [env]
    V = "decl"
    ONLY_DECL = "d"
    [[loop]]
    id = "e"
    command = "echo $V,$ONLY_DECL,$R,$S >> {log}/cmd"
    setup = ["echo $V >> {log}/setup"]
    teardown = ["echo $V >> {log}/teardown"]
    cold_prep = ["echo $V >> {log}/prep"]
    [loop.env]
    V = "loop-secret-value"
    R = "{{root}}"
    S = "{{scratch}}/x"
"""


def test_env_reaches_every_command_and_the_loop_overrides_the_declaration(tmp_path, project):
    log = tmp_path / "log"
    log.mkdir()
    p = write_decl(tmp_path, project, ENV_DECL.format(log=log))
    assert run_ok("run", p, "e", "--mode", "cold", "--samples", "1", "--results", tmp_path / "r.jsonl") == 0
    for stage in ("setup", "teardown", "prep"):
        assert (log / stage).read_text().strip() == "loop-secret-value", stage
    v, d, r, s = (log / "cmd").read_text().strip().split(",")
    assert (v, d) == ("loop-secret-value", "d")
    assert r == str(project)
    scratch = Path(s[: -len("/x")])
    assert scratch.is_dir()
    assert scratch == Path(os.environ["LOOP_TIME_SCRATCH"]) / "demo"


def test_sample_records_env_key_names_never_values(tmp_path, project):
    log = tmp_path / "log"
    log.mkdir()
    p = write_decl(tmp_path, project, ENV_DECL.format(log=log))
    res = tmp_path / "r.jsonl"
    run_ok("run", p, "e", "--samples", "1", "--results", res)
    assert records(res)[0]["env_keys"] == ["ONLY_DECL", "R", "S", "V"]
    assert "loop-secret-value" not in res.read_text()


def test_default_scratch_root_is_under_agent_scratch(monkeypatch, tmp_path):
    # The default sits in ~/.cache/agent-scratch, the base's place for scratch too big for /tmp:
    # a session may delete there when its timing is recorded, and the tmpfiles rule ages what is
    # left. A root elsewhere in ~/.cache left gigabytes no session could remove.
    monkeypatch.delenv("LOOP_TIME_SCRATCH", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    assert lt.scratch_base() == tmp_path / ".cache" / "agent-scratch" / "loop-time"


def test_no_env_means_empty_env_keys_and_no_scratch_dir(tmp_path, project):
    res = tmp_path / "r.jsonl"
    p = write_decl(tmp_path, project, '[[loop]]\nid="a"\ncommand="true"\n')
    run_ok("run", p, "a", "--samples", "1", "--results", res)
    assert records(res)[0]["env_keys"] == []
    assert list(Path(os.environ["LOOP_TIME_SCRATCH"]).iterdir()) == []


FRESH = """
    [[loop]]
    id = "f"
    command = "ls $SC | wc -l > {out}; echo new > $SC/marker"
    cold = "fresh-scratch"
    [loop.env]
    SC = "{{scratch}}"
"""


def test_fresh_scratch_is_emptied_before_each_cold_sample_only(tmp_path, project):
    out = tmp_path / "count"
    p = write_decl(tmp_path, project, FRESH.format(out=out))
    scratch = Path(os.environ["LOOP_TIME_SCRATCH"]) / "demo"
    scratch.mkdir(parents=True)
    (scratch / lt.SCRATCH_MARKER).write_text("")  # as an earlier run left it
    (scratch / "stale").write_text("x")
    (scratch / "sub").mkdir()
    (scratch / "sub" / "deep").write_text("x")
    assert run_ok("run", p, "f", "--mode", "cold", "--samples", "1", "--results", tmp_path / "r.jsonl") == 0
    assert out.read_text().strip() == "0"
    assert sorted(x.name for x in scratch.iterdir()) == [lt.SCRATCH_MARKER, "marker"]
    # warm leaves what the previous sample made
    assert run_ok("run", p, "f", "--mode", "warm", "--samples", "1", "--results", tmp_path / "r.jsonl") == 0
    assert out.read_text().strip() == "1"


def test_fresh_scratch_does_not_follow_symlinks_out(tmp_path, project):
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "keep").write_text("k")
    p = write_decl(tmp_path, project, FRESH.format(out=tmp_path / "count"))
    scratch = Path(os.environ["LOOP_TIME_SCRATCH"]) / "demo"
    scratch.mkdir(parents=True)
    (scratch / lt.SCRATCH_MARKER).write_text("")  # as an earlier run left it
    (scratch / "link").symlink_to(outside)
    run_ok("run", p, "f", "--mode", "cold", "--samples", "1", "--results", tmp_path / "r.jsonl")
    assert (outside / "keep").read_text() == "k"
    assert not (scratch / "link").is_symlink()


def test_empty_scratch_refuses_anything_outside_the_scratch_root(tmp_path):
    base = tmp_path / "base"
    base.mkdir()
    victim = tmp_path / "victim"
    victim.mkdir()
    (victim / "precious").write_text("p")
    link = base / "proj"
    link.symlink_to(victim)
    for target in (victim, base, tmp_path, base / ".." / "victim", link):
        with pytest.raises(lt.DeclError):
            lt.empty_scratch(target, base)
    assert (victim / "precious").read_text() == "p"
    # a filesystem root or the home directory is never an acceptable scratch root
    for bad in (Path("/"), Path.home()):
        with pytest.raises(lt.DeclError):
            lt.empty_scratch(bad / "anything", bad)


def test_odd_project_names_cannot_name_a_directory_outside_the_scratch_root(tmp_path, monkeypatch):
    base = tmp_path / "base"
    monkeypatch.setenv("LOOP_TIME_SCRATCH", str(base))
    for name in ("..", ".", "../x", "a/../..", "/etc"):
        d = lt.scratch_dir(name)
        assert d.resolve().parent == base.resolve(), (name, d)


def test_cold_run_refuses_when_the_scratch_directory_escapes(tmp_path, project, monkeypatch):
    victim = tmp_path / "victim"
    victim.mkdir()
    (victim / "precious").write_text("p")
    base = tmp_path / "sb"
    base.mkdir()
    (base / "demo").symlink_to(victim)
    monkeypatch.setenv("LOOP_TIME_SCRATCH", str(base))
    p = write_decl(tmp_path, project, FRESH.format(out=tmp_path / "count"))
    assert run_ok("run", p, "f", "--mode", "cold", "--samples", "1", "--results", tmp_path / "r.jsonl") == 2
    assert (victim / "precious").read_text() == "p"


def test_cold_run_never_empties_a_directory_loop_time_did_not_make(tmp_path, project, monkeypatch):
    # LOOP_TIME_SCRATCH pointed at a parent of real checkouts: the project's "scratch directory"
    # is then someone's repository, strictly inside the root, and must not be emptied.
    repos = tmp_path / "repos"
    (repos / "demo").mkdir(parents=True)
    (repos / "demo" / "precious").write_text("p")
    monkeypatch.setenv("LOOP_TIME_SCRATCH", str(repos))
    p = write_decl(tmp_path, project, FRESH.format(out=tmp_path / "count"))
    assert run_ok("run", p, "f", "--mode", "cold", "--samples", "1", "--results", tmp_path / "r.jsonl") == 2
    assert (repos / "demo" / "precious").read_text() == "p"


def test_edit_may_be_find_and_replace_and_is_restored(tmp_path, project):
    seen = tmp_path / "seen"
    p = write_decl(tmp_path, project, f"""
        [[loop]]
        id = "check"
        command = "cat lib/a.txt >> {seen}; sh check.sh"
        [[scenario]]
        name = "leaf"
        file = "lib/a.txt"
        edit = {{ find = "OK", replace = "OK edited" }}
        plant = {{ find = "OK", replace = "BUG" }}
        loops = ["check"]
    """)
    res = tmp_path / "r.jsonl"
    assert run_ok("run", p, "check", "--mode", "scenario:leaf", "--samples", "1", "--results", res) == 0
    assert [r["step"] for r in records(res)] == ["edit", "plant"]
    assert seen.read_text().splitlines()[0] == "OK edited"
    assert (project / "lib" / "a.txt").read_text() == "OK\n"


def test_edit_find_is_applied_once_to_the_first_occurrence(tmp_path):
    f = tmp_path / "f.txt"
    f.write_text("a a a\n")
    lt.apply_edit(f, {"find": "a", "replace": "b"})
    assert f.read_text() == "b a a\n"


def test_edit_whose_find_text_is_absent_is_refused(tmp_path, project):
    body = """
        [[loop]]
        id = "check"
        command = "true"
        [[scenario]]
        name = "leaf"
        file = "lib/a.txt"
        edit = { find = "ABSENT", replace = "x" }
        plant = { append = "y" }
        loops = ["check"]
    """
    with pytest.raises(lt.DeclError) as e:
        lt.load_decl(write_decl(tmp_path, project, body))
    assert "ABSENT" in "\n".join(e.value.problems)
    f = tmp_path / "f.txt"
    f.write_text("abc\n")
    with pytest.raises(lt.DeclError):
        lt.apply_edit(f, {"find": "ABSENT", "replace": "x"})
    assert f.read_text() == "abc\n"


@pytest.mark.parametrize("edit", ['{ find = "OK" }', '{ append = "x", find = "OK", replace = "y" }',
                                  '{ replace = "y" }', '{ find = "OK", replace = "y", extra = 1 }'])
def test_malformed_edits_are_rejected(tmp_path, project, edit):
    body = ('[[loop]]\nid="a"\ncommand="true"\n[[scenario]]\nname="s"\nfile="lib/a.txt"\n'
            f'edit={edit}\nplant={{append="y"}}\nloops=["a"]\n')
    with pytest.raises(lt.DeclError):
        lt.load_decl(write_decl(tmp_path, project, body))


def test_plan_shows_a_find_replace_edit(tmp_path, project, capsys):
    p = write_decl(tmp_path, project, '[[loop]]\nid="a"\ncommand="true"\n[[scenario]]\nname="s"\n'
                   'file="lib/a.txt"\nedit={find="OK", replace="OK "}\nplant={append="y"}\nloops=["a"]\n')
    assert run_main("plan", p) == 0
    assert "edit: replace 'OK' with 'OK '" in capsys.readouterr().out


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


def test_report_excludes_failed_runs_from_the_timings_and_says_so(tmp_path, capsys):
    # A failed run measures a gate that stopped early, not the loop: averaged in, it drags the
    # median toward the failure's time (russ's first L3 baseline, 2026-11-07, failed on unchanged
    # code). A planted run is meant to fail, so its failure is the result and still counts.
    res = tmp_path / "r.jsonl"
    rows = [_rec("a", "warm", w, w, sample=i) for i, w in enumerate([10.0, 12.0])]
    bad = _rec("a", "warm", 1.0, 1.0, sample=2)
    bad["exit_code"] = 1
    rows.append(bad)
    plant = _rec("a", "scenario:x", 3.0, 3.0, step="plant")
    plant.update(exit_code=1, caught=True)
    rows.append(plant)
    res.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    assert run_main("report", "--results", res, "--json") == 0
    data = json.loads(capsys.readouterr().out)
    warm = next(g for g in data if g["mode"] == "warm")
    assert (warm["samples"], warm["failed"], warm["wall_median"], warm["wall_min"]) == (2, 1, 11.0, 10.0)
    planted = next(g for g in data if g["step"] == "plant")
    assert (planted["samples"], planted["failed"], planted["wall_median"]) == (1, 0, 3.0)
    assert run_main("report", "--results", res) == 0
    assert "1 failed, excluded" in capsys.readouterr().out


def test_run_refuses_before_timing_anything_when_the_results_file_cannot_be_written(
        decl_path, tmp_path, capsys):
    # An agent sandbox cannot write the default under ~/.local/state. Found only at the first
    # append, that costs the whole first sample: for keystone's cold gate, twenty minutes.
    ro = tmp_path / "ro"
    ro.mkdir()
    ro.chmod(0o500)
    marker = tmp_path / "ran"
    p = write_decl(tmp_path, decl_path.parent / "proj",
                   f'[[loop]]\nid = "x"\ncommand = "touch {marker}"\n')
    try:
        rc = run_main("run", p, "x", "--samples", "1", "--max-load", "9999",
                      "--results", ro / "sub" / "r.jsonl")
    finally:
        ro.chmod(0o700)
    assert rc == 2
    assert not marker.exists()
    assert "LOOP_TIME_RESULTS" in capsys.readouterr().err


def test_report_on_missing_file_is_an_error(tmp_path, capsys):
    assert run_main("report", "--results", tmp_path / "none.jsonl") == 2


def test_help_explains_modes_and_why_scenarios_plant_a_defect():
    r = subprocess.run([str(TOOL), "--help"], capture_output=True, text=True)
    assert r.returncode == 0
    for word in ("cold", "warm", "scenario", "sequence", "planted", "blind"):
        assert word in r.stdout


@pytest.mark.parametrize("with_env", [False, True])
def test_measured_commands_see_the_callers_path_not_the_tools_interpreter(tmp_path, project, with_env):
    # `uv run --script` puts the tool's own environment first on PATH. A measured command must not
    # inherit that: it would run the project's `python3` as the tool's private interpreter.
    seen = tmp_path / "path"
    body = f'[[loop]]\nid = "p"\ncommand = "printf %s \\"$PATH\\" > {seen}"\n'
    if with_env:
        body += '[loop.env]\nX = "1"\n'
    p = write_decl(tmp_path, project, body)
    own_bin = str(Path(sys.prefix) / "bin")
    caller_path = os.pathsep.join(e for e in os.environ["PATH"].split(os.pathsep) if e != own_bin)
    r = subprocess.run(["uv", "run", "--script", "--quiet", str(TOOL), "run", str(p), "p", "--samples", "1",
                        "--max-load", "9999", "--results", str(tmp_path / "r.jsonl")],
                       env={**os.environ, "PATH": caller_path}, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert seen.read_text() == caller_path


def test_caller_env_drops_only_the_tools_own_bin_directory(monkeypatch):
    monkeypatch.setattr(lt.sys, "prefix", "/venv/tool")
    monkeypatch.setattr(lt.sys, "base_prefix", "/usr")
    monkeypatch.setenv("PATH", "/venv/tool/bin:/usr/bin:/bin:/venv/tool/bin")
    monkeypatch.setenv("VIRTUAL_ENV", "/venv/tool")
    env = lt.caller_env()
    assert env["PATH"] == "/usr/bin:/bin"
    assert "VIRTUAL_ENV" not in env
    # Not in a virtual environment: nothing is removed, /usr/bin least of all.
    monkeypatch.setattr(lt.sys, "prefix", "/usr")
    monkeypatch.setenv("PATH", "/usr/bin:/bin")
    assert lt.caller_env()["PATH"] == "/usr/bin:/bin"


# ---- the timing slot ---------------------------------------------------------------------

SLOT_TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_fleet-slot"


@pytest.fixture
def slot(monkeypatch, tmp_path):
    """The real fleet-slot, its state under tmp_path, run outside any named session. The arbiter
    is configured, so the machine's own fleet record is never read."""
    monkeypatch.setenv("FLEET_SLOT_STATE", str(tmp_path / "slot"))
    (tmp_path / "slot-config").write_text("slot-arbiter = director-canonical\n")
    monkeypatch.setenv("FLEET_CANONICALS_CONFIG", str(tmp_path / "slot-config"))
    monkeypatch.setenv("FLEET_DECL_CMD", "false")
    monkeypatch.setenv("FLEET_AGENTS_JSON_CMD", "echo []")
    monkeypatch.delenv("CLAUDE_CODE_SESSION_ID", raising=False)
    cmd = f"{sys.executable} {SLOT_TOOL}"
    monkeypatch.setenv("LOOP_TIME_SLOT_CMD", cmd)

    def fs(*args):
        r = subprocess.run([sys.executable, str(SLOT_TOOL), *args], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
    fs.cmd = cmd
    return fs


def grant(fs, holder):
    fs("grant", holder, "--minutes", "5", "--what", "timed run", "--as", "director-canonical")


def test_run_is_refused_while_another_session_holds_the_slot_and_nothing_runs(decl_path, tmp_path, slot):
    grant(slot, "other-session")
    res = tmp_path / "r.jsonl"
    rc = run_main("run", decl_path, "check", "--mode", "cold", "--samples", "1", "--results", res,
                  "--max-load", "9999")
    assert rc == lt.EXIT_SLOT == 6
    assert not res.exists()
    assert not (tmp_path / "prep.log").exists()   # not even the cold_prep ran


def test_fleet_slot_as_in_the_environment_names_the_caller_end_to_end(decl_path, tmp_path, slot, monkeypatch):
    grant(slot, "me")
    monkeypatch.setenv("FLEET_SLOT_AS", "me")
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "check", "--mode", "cold", "--samples", "1", "--results", res,
                    "--max-load", "9999") == 0
    assert records(res)[0]["slot"] == {"state": "own", "holder": "me", "override": False}


def test_run_proceeds_after_release_and_records_the_slot_free(decl_path, tmp_path, slot):
    grant(slot, "other-session")
    slot("release", "other-session", "--as", "other-session")
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "check", "--samples", "1", "--results", res, "--max-load", "9999") == 0
    assert records(res)[0]["slot"] == {"state": "free", "holder": None, "override": False}


def test_run_proceeds_in_its_own_slot(decl_path, tmp_path, slot):
    grant(slot, "me")
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "check", "--samples", "1", "--results", res, "--max-load", "9999",
                    "--slot-holder", "me") == 0
    assert records(res)[0]["slot"] == {"state": "own", "holder": "me", "override": False}


def test_ignore_slot_measures_and_every_record_says_it_was_overridden(decl_path, tmp_path, slot):
    grant(slot, "other-session")
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "check", "--samples", "2", "--results", res, "--max-load", "9999",
                    "--ignore-slot") == 0
    for r in records(res):
        assert r["slot"] == {"state": "other", "holder": "other-session", "override": True}


def test_a_slot_granted_to_another_mid_run_stops_the_next_sample(tmp_path, project, slot):
    p = write_decl(tmp_path, project, f"""
        [[loop]]
        id = "grab"
        command = "{slot.cmd} grant other-session --minutes 5 --what x --as director-canonical"
        """)
    res = tmp_path / "r.jsonl"
    assert run_main("run", p, "grab", "--samples", "3", "--results", res, "--max-load", "9999") == 6
    recs = records(res)
    assert len(recs) == 1 and recs[0]["slot"]["state"] == "free"


def test_a_failing_slot_check_refuses_unless_ignored(decl_path, tmp_path, monkeypatch):
    monkeypatch.setenv("LOOP_TIME_SLOT_CMD", "sh -c 'echo broken >&2; exit 2'")
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "listy", "--samples", "1", "--results", res, "--max-load", "9999") == 6
    assert run_main("run", decl_path, "listy", "--samples", "1", "--results", res, "--max-load", "9999",
                    "--ignore-slot") == 0
    assert records(res)[0]["slot"] == {"state": "error", "holder": None, "override": True}


def test_without_fleet_slot_the_record_says_unchecked(monkeypatch):
    monkeypatch.setattr(lt, "slot_command", lambda: None)
    assert lt.slot_check(None, False) == {"state": "unchecked", "holder": None, "override": False}


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))


def _tree_under_plain_root(tmp_path):
    """A plain directory (not a repository) holding one checkout `t`, as a declaration whose root
    collects throwaway clones has it."""
    root = tmp_path / "plain"
    t = root / "t"
    (t / "lib").mkdir(parents=True)
    (t / "lib" / "a.txt").write_text("OK\n")
    (t / "check.sh").write_text("#!/bin/sh\n! grep -q BUG lib/a.txt\n")
    git(t, "init", "-q")
    git(t, "add", "-A")
    git(t, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init")
    body = ('[[loop]]\nid="c"\ncwd="t"\ncommand="sh check.sh"\n[[scenario]]\nname="leaf"\n'
            'file="t/lib/a.txt"\nedit={append="x"}\nplant={find="OK", replace="BUG"}\nloops=["c"]\n')
    return root, t, write_decl(tmp_path, root, body)


def test_scenario_file_check_works_when_the_root_is_not_a_repository(tmp_path):
    """Measured 2026-11-14 by finmodel: a root holding `git clone --shared` trees refused every
    scenario file as "differs from HEAD", because git ran at the root, which is no repository."""
    root, t, p = _tree_under_plain_root(tmp_path)
    res = tmp_path / "r.jsonl"
    assert run_main("run", p, "c", "--mode", "scenario:leaf", "--samples", "1", "--results", res,
                    "--max-load", "9999") == 0
    assert (t / "lib" / "a.txt").read_text() == "OK\n"


def test_scenario_file_check_still_refuses_a_dirty_file_under_a_plain_root(tmp_path, capsys):
    root, t, p = _tree_under_plain_root(tmp_path)
    (t / "lib" / "a.txt").write_text("OK\nlocal change\n")
    rc = run_main("run", p, "c", "--mode", "scenario:leaf", "--samples", "1", "--results", tmp_path / "r.jsonl",
                  "--max-load", "9999")
    assert rc == 2 and "differs from HEAD" in capsys.readouterr().err


def test_git_state_is_read_from_each_loops_own_cwd(tmp_path):
    """A root holding several checkouts (a directory of worktrees inside a repository, as finmodel
    declares `root = <repo>/.worktrees`) must record each loop's own tree. Measured 2026-11-10: two
    loops in worktrees at different commits both recorded the enclosing checkout's HEAD, dirty."""
    outer = tmp_path / "outer"
    outer.mkdir()
    git(outer, "init", "-q")
    (outer / "f").write_text("outer\n")
    git(outer, "add", "-A")
    git(outer, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "outer")
    heads = {}
    for name in ("a", "b"):
        d = outer / "trees" / name
        d.mkdir(parents=True)
        git(d, "init", "-q")
        (d / "f").write_text(f"{name}\n")
        git(d, "add", "-A")
        git(d, "-c", "commit.gpgsign=false", "commit", "-q", "-m", name)
        heads[name] = git(d, "rev-parse", "HEAD").strip()
    p = write_decl(tmp_path, outer / "trees",
                   '[[loop]]\nid="la"\ncwd="a"\ncommand="true"\n[[loop]]\nid="lb"\ncwd="b"\ncommand="true"\n')
    res = tmp_path / "r.jsonl"
    for loop in ("la", "lb"):
        assert run_main("run", p, loop, "--samples", "1", "--results", res, "--max-load", "9999") == 0
    got = {r["loop"]: (r["git_head"], r["tree_dirty"]) for r in records(res)}
    assert got == {"la": (heads["a"], False), "lb": (heads["b"], False)}


# ---- percentile --------------------------------------------------------------------------

def test_percentile_is_nearest_rank_so_p90_of_three_is_the_maximum():
    assert lt.percentile([3.0, 1.0, 2.0], 90) == 3.0
    assert lt.percentile([float(i) for i in range(1, 11)], 90) == 9.0
    assert lt.percentile([float(i) for i in range(1, 11)], 100) == 10.0
    assert lt.percentile([5.0], 90) == 5.0
    assert lt.percentile([], 90) is None


def test_percentile_rank_is_the_max_only_when_the_sample_is_too_small_to_tell():
    assert lt.percentile_is_max(3, 90) is True
    assert lt.percentile_is_max(9, 90) is True       # ceil(8.1) = 9
    assert lt.percentile_is_max(10, 90) is False
    assert lt.percentile_is_max(1, 90) is False       # one sample: nothing to be the max of


# ---- pressure: parsing -------------------------------------------------------------------

PSI_IO = ("some avg10=75.60 avg60=60.00 avg300=40.00 total=111\n"
          "full avg10=73.50 avg60=50.00 avg300=30.00 total=222\n")
PSI_CPU_NOFULL = "some avg10=0.20 avg60=0.10 avg300=0.05 total=333\n"


def test_parse_psi_reads_some_and_full_and_tolerates_a_missing_full():
    got = lt.parse_psi(PSI_IO)
    assert got["some"]["avg10"] == 75.6 and got["full"]["avg10"] == 73.5 and got["full"]["total"] == 222
    got = lt.parse_psi(PSI_CPU_NOFULL)
    assert got["some"]["avg10"] == 0.2 and got["full"] is None
    assert lt.parse_psi("garbage\n") == {"some": None, "full": None}


def write_psi(d, cpu=PSI_CPU_NOFULL, io=PSI_IO, memory=PSI_CPU_NOFULL):
    d.mkdir(parents=True, exist_ok=True)
    for name, text in (("cpu", cpu), ("io", io), ("memory", memory)):
        (d / name).write_text(text)
    return d


def test_read_pressure_from_a_psi_directory(tmp_path):
    d = write_psi(tmp_path / "psi")
    got = lt.read_pressure(system="Linux", psi_dir=d)
    assert got["source"] == "psi" and got["reason"] is None
    v = got["values"]
    assert v["io_some"] == 75.6 and v["io_full"] == 73.5 and v["cpu_some"] == 0.2
    assert "cpu_full" not in v            # an absent line is absent, not zero
    assert "load1" in v


def test_read_pressure_without_psi_says_it_has_none_and_still_gives_load(tmp_path):
    got = lt.read_pressure(system="Linux", psi_dir=tmp_path / "nope")
    assert got["source"] == "none" and "no pressure files" in got["reason"]
    assert "io_some" not in got["values"] and "load1" in got["values"]


TOP_OUT = """Processes: 400 total
CPU usage: 9.00% user, 6.00% sys, 85.00% idle
Processes: 401 total
CPU usage: 12.50% user, 7.50% sys, 80.00% idle
"""


def test_darwin_parsers_read_the_last_top_sample_and_memory_pressure():
    assert lt.parse_top_cpu_busy(TOP_OUT) == 20.0
    assert lt.parse_top_cpu_busy("nothing") is None
    assert lt.parse_memory_pressure_free("System-wide memory free percentage: 52%\n") == 52.0
    assert lt.parse_memory_pressure_free("") is None


def test_read_pressure_on_darwin_reports_no_psi_and_uses_what_the_platform_has():
    runs = {"top": TOP_OUT, "memory_pressure": "System-wide memory free percentage: 52%\n"}
    got = lt.read_pressure(system="Darwin", run=lambda argv: runs.get(argv[0], ""))
    assert got["source"] == "darwin" and "no /proc/pressure" in got["reason"]
    assert got["values"]["cpu_busy"] == 20.0 and got["values"]["mem_free_pct"] == 52.0
    assert not any(k.endswith("_some") for k in got["values"])


# ---- pressure: the sampler ---------------------------------------------------------------

def test_sampler_summarizes_a_series_as_peak_median_p90_and_min():
    readings = iter([{"io_some": v} for v in (10.0, 30.0, 20.0, 90.0)])
    s = lt.PressureSampler(lambda: {"source": "psi", "reason": None, "values": next(readings)},
                           interval=0.0, max_readings=4)
    s.start()
    s.stop()
    out = s.summary()
    ser = out["series"]["io_some"]
    assert out["source"] == "psi" and out["n"] == 4
    assert ser == {"peak": 90.0, "median": 25.0, "p90": 90.0, "min": 10.0}


def test_sampler_takes_a_reading_at_start_and_at_stop_even_for_an_instant_run():
    n = []

    def reader():
        n.append(1)
        return {"source": "psi", "reason": None, "values": {"cpu_some": float(len(n))}}

    s = lt.PressureSampler(reader, interval=60.0)
    s.start()
    s.stop()
    assert s.summary()["n"] >= 2 and len(n) >= 2


def test_sampler_that_cannot_read_says_why_and_carries_no_series():
    s = lt.PressureSampler(lambda: {"source": "none", "reason": "no pressure files", "values": {}},
                           interval=0.0, max_readings=2)
    s.start()
    s.stop()
    out = s.summary()
    assert out["source"] == "none" and out["reason"] == "no pressure files" and out["series"] == {}


def test_sampler_survives_a_reader_that_raises():
    def boom():
        raise OSError("gone")

    s = lt.PressureSampler(boom, interval=0.0, max_readings=2)
    s.start()
    s.stop()
    assert s.summary()["series"] == {} and "OSError" in s.summary()["reason"]


# ---- pressure: in the records ------------------------------------------------------------

def test_every_record_carries_the_pressure_series_and_the_idle_io_baseline(tmp_path, decl_path, monkeypatch):
    """The PSI reader, on any machine: the platform is pinned to Linux, since on macOS the tool
    reads top and memory_pressure and never the PSI files this test supplies."""
    monkeypatch.setattr(lt.platform, "system", lambda: "Linux")
    monkeypatch.setenv("LOOP_TIME_PRESSURE_DIR", str(write_psi(tmp_path / "psi")))
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "listy", "--samples", "1", "--results", res, "--max-load", "9999",
                    "--pressure-interval", "0.05") == 0
    r = records(res)[0]
    assert r["pressure"]["source"] == "psi" and r["pressure"]["n"] >= 2
    assert r["pressure"]["series"]["io_some"]["peak"] == 75.6
    assert r["io_baseline"] == {"io_some": 75.6, "io_full": 73.5}


def test_every_record_carries_available_memory_from_the_real_platform(tmp_path, decl_path):
    """No stand-in files: /proc/meminfo on Linux, vm_stat on macOS."""
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "listy", "--samples", "1", "--results", res, "--max-load", "9999",
                    "--pressure-interval", "0.05") == 0
    assert records(res)[0]["pressure"]["series"]["mem_available"]["min"] > 0


def test_started_at_is_the_commands_start_even_when_a_pressure_reading_is_slow(tmp_path, project, monkeypatch):
    """On macOS a reading runs `top -l 2`, about a second. The sampler's first reading is taken
    before started_at, so started_at, and with it a group's barrier, marks the command's start."""
    def slow():
        time.sleep(0.6)
        return {"source": "none", "reason": "slow", "values": {}}

    real = lt.PressureSampler
    monkeypatch.setattr(lt, "PressureSampler", lambda **kw: real(reader=slow, **kw))
    stamp = tmp_path / "stamp"
    decl = write_decl(tmp_path, project, f'''[[loop]]
id = "stamp"
command = "python3 -c 'import time; print(time.time())' > {stamp}"
''')
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl, "stamp", "--samples", "1", "--results", res, "--max-load", "9999",
                    "--pressure-interval", "30") == 0
    began = float(stamp.read_text())
    assert abs(began - records(res)[0]["started_at"]) < 0.3


def test_a_high_io_pressure_never_refuses_or_marks_a_sample(tmp_path, decl_path, monkeypatch):
    """No guard reads I/O pressure: it is 75 at idle on the machine this was built for, so a guard on
    it would refuse every run. It is recorded only."""
    io = "some avg10=99.00 avg60=99.00 avg300=99.00 total=1\nfull avg10=99.00 avg60=99.00 avg300=99.00 total=1\n"
    monkeypatch.setenv("LOOP_TIME_PRESSURE_DIR", str(write_psi(tmp_path / "psi", io=io)))
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "listy", "--samples", "2", "--results", res, "--max-load", "9999") == 0
    assert all(r["under_load"] is False for r in records(res))


def test_no_pressure_switches_the_sampler_off(tmp_path, decl_path):
    res = tmp_path / "r.jsonl"
    assert run_main("run", decl_path, "listy", "--samples", "1", "--results", res, "--max-load", "9999",
                    "--no-pressure") == 0
    assert records(res)[0]["pressure"] is None


# ---- per-child CPU -----------------------------------------------------------------------

def test_cpu_seconds_is_the_childs_own_not_the_process_wide_children_total(tmp_path):
    """Concurrent samples share one process, so a before/after difference of the children's total
    would charge each sample with its neighbors' CPU. wait4 gives each child's own."""
    import threading
    burn = ["python3", "-c", "import time\nt=time.process_time()\nwhile time.process_time()-t<0.6: pass"]
    idle = ["sleep", "0.8"]
    out = {}

    def go(name, argv):
        out[name] = lt.measure(argv, tmp_path, tmp_path / f"{name}.log")

    ts = [threading.Thread(target=go, args=(n, a)) for n, a in (("burn", burn), ("idle", idle))]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert out["burn"][2] >= 0.5
    assert out["idle"][2] < 0.2, out
    assert out["burn"][0] == 0 and out["idle"][0] == 0


def test_measure_still_reports_a_failing_exit_code(tmp_path):
    assert lt.measure(["sh", "-c", "exit 7"], tmp_path, tmp_path / "o.log")[0] == 7


# ---- run-group ---------------------------------------------------------------------------

GROUP_DECL = """\
[[loop]]
id = "nap"
command = "sleep 1"

[[loop]]
id = "quick"
command = "true"

[[loop]]
id = "bad"
command = "exit 3"

[[loop]]
id = "scr"
command = "pwd >> {out}; echo $SCR >> {out}"
env = {{ SCR = "{{scratch}}" }}
cold = "fresh-scratch"

[[loop]]
id = "slowsetup"
command = "true"
setup = ["sleep 1.5"]

[[loop]]
id = "badsetup"
command = "true"
setup = ["exit 1"]
"""


@pytest.fixture
def group_decl(tmp_path, project):
    return write_decl(tmp_path, project, GROUP_DECL.format(out=tmp_path / "out.txt"))


def group(decl, loops, *extra, res=None):
    return run_main("run-group", decl, "--loops", loops, "--max-load", "9999", "--results", res, *extra)


def test_run_group_starts_the_loops_at_a_barrier_and_they_overlap(tmp_path, group_decl):
    res = tmp_path / "r.jsonl"
    t0 = time.monotonic()
    # --no-pressure: this tests the barrier. A pressure reading on macOS costs about a second
    # outside the measured interval, which would push a serial-versus-parallel bound past 5.5 s.
    assert group(group_decl, "nap,nap,nap", "--samples", "2", "--no-pressure", res=res) == 0
    took = time.monotonic() - t0
    recs = records(res)
    assert len(recs) == 6
    assert took < 5.5          # serial would be at least 6 s of sleeping
    for rnd in (0, 1):
        starts = [r["started_at"] for r in recs if r["sample"] == rnd]
        assert len(starts) == 3 and max(starts) - min(starts) < 1.0
    ends = sorted((r["started_at"], r["started_at"] + r["wall_seconds"]) for r in recs if r["sample"] == 0)
    assert ends[1][0] < ends[0][1]          # the second began before the first ended


def test_run_group_records_share_a_group_id_and_are_concurrent_not_under_load(tmp_path, group_decl):
    res = tmp_path / "r.jsonl"
    assert group(group_decl, "nap,quick", "--samples", "2", res=res) == 0
    recs = records(res)
    assert len({r["group"] for r in recs}) == 1
    assert all(r["concurrent"] is True and r["under_load"] is False and r["group_size"] == 2 for r in recs)
    assert sorted(r["group_index"] for r in recs if r["sample"] == 0) == [0, 1]
    assert all(r["group_loops"] == ["nap", "quick"] for r in recs)
    assert {r["loop"] for r in recs} == {"nap", "quick"}


def test_solo_records_are_not_marked_concurrent(tmp_path, decl_path):
    res = tmp_path / "r.jsonl"
    run_main("run", decl_path, "listy", "--samples", "1", "--results", res, "--max-load", "9999")
    r = records(res)[0]
    assert r.get("concurrent") is False and r.get("group") is None


def test_each_group_member_gets_its_own_scratch_directory(tmp_path, group_decl):
    res = tmp_path / "r.jsonl"
    assert group(group_decl, "scr,scr", "--samples", "1", "--mode", "cold", res=res) == 0
    scratches = [l for l in (tmp_path / "out.txt").read_text().splitlines() if "/" in l and "proj" not in l]
    assert len(scratches) == 2 and len(set(scratches)) == 2
    assert all(Path(s).is_dir() for s in scratches)


def test_group_members_running_the_same_loop_write_separate_logs(tmp_path, group_decl):
    res = tmp_path / "r.jsonl"
    assert group(group_decl, "quick,quick,quick", "--samples", "1", res=res) == 0
    outs = [r["output"] for r in records(res)]
    assert len(set(outs)) == 3 and all(Path(o).is_file() for o in outs)


def test_one_failing_member_fails_the_group_but_every_member_is_recorded(tmp_path, group_decl):
    res = tmp_path / "r.jsonl"
    assert group(group_decl, "quick,bad", "--samples", "2", res=res) == 1
    recs = records(res)
    assert len(recs) == 4
    assert sorted((r["loop"], r["exit_code"]) for r in recs if r["sample"] == 1) == [("bad", 3), ("quick", 0)]


def test_a_member_whose_setup_fails_aborts_the_group_without_a_deadlock(tmp_path, group_decl, capsys):
    res = tmp_path / "r.jsonl"
    t0 = time.monotonic()
    rc = group(group_decl, "nap,badsetup", "--samples", "1", res=res)
    assert rc == 1 and time.monotonic() - t0 < 10
    assert "setup failed" in capsys.readouterr().err


@pytest.mark.parametrize("extra,needle", [
    (["--loops", "nope"], "unknown loop 'nope'"),
    (["--loops", "nap", "--mode", "sequence"], "warm or cold"),
    (["--loops", "nap", "--mode", "scenario:x"], "warm or cold"),
    (["--loops", "nap", "--samples", "0"], "at least 1"),
    (["--loops", ""], "--loops"),
])
def test_run_group_refuses_bad_arguments(tmp_path, group_decl, capsys, extra, needle):
    rc = run_main("run-group", group_decl, "--max-load", "9999", "--results", tmp_path / "r.jsonl", *extra)
    assert rc == 2 and needle in capsys.readouterr().err
    assert not (tmp_path / "r.jsonl").exists()


def test_run_group_refuses_a_busy_machine_once_before_starting(tmp_path, group_decl, monkeypatch, capsys):
    monkeypatch.setattr(lt, "read_loadavg", lambda: 50.0)
    rc = run_main("run-group", group_decl, "--loops", "quick,quick", "--max-load", "1", "--load-wait", "0",
                  "--results", tmp_path / "r.jsonl")
    assert rc == 4 and not (tmp_path / "r.jsonl").exists()


def test_run_group_refuses_while_another_session_holds_the_slot(tmp_path, group_decl, monkeypatch):
    monkeypatch.setenv("LOOP_TIME_SLOT_CMD", "false")
    rc = group(group_decl, "quick,quick", res=tmp_path / "r.jsonl")
    assert rc == 6 and not (tmp_path / "r.jsonl").exists()


# ---- report: percentile and cells --------------------------------------------------------

def rec(loop, wall, **kw):
    base = {"project": "demo", "loop": loop, "mode": "warm", "step": None, "exit_code": 0,
            "wall_seconds": wall, "cpu_seconds": wall}
    base.update(kw)
    return base


def test_summarize_adds_a_percentile_only_when_asked():
    recs = [rec("a", w) for w in (1.0, 2.0, 3.0)]
    assert "wall_p90" not in lt.summarize(recs)[0]
    g = lt.summarize(recs, percentile=90)[0]
    assert g["wall_p90"] == 3.0 and g["wall_median"] == 2.0 and g["percentile_is_max"] is True


def test_percentile_leaves_out_failed_runs_like_the_median_does():
    recs = [rec("a", 1.0), rec("a", 2.0), rec("a", 99.0, exit_code=1)]
    assert lt.summarize(recs, percentile=90)[0]["wall_p90"] == 2.0


def test_summarize_keeps_a_concurrent_cell_apart_from_a_solo_one_and_from_another_composition():
    solo = [rec("a", 1.0)]
    g2 = [rec("a", 2.0, concurrent=True, group="g1", group_loops=["a", "a"]),
          rec("a", 4.0, concurrent=True, group="g1", group_loops=["a", "a"])]
    g3 = [rec("a", 9.0, concurrent=True, group="g2", group_loops=["a", "a", "a"])]
    out = lt.summarize(solo + g2 + g3)
    cells = {g["cell"]: g for g in out}
    assert set(cells) == {None, "a+a", "a+a+a"}
    assert cells["a+a"]["wall_median"] == 3.0 and cells["a+a"]["samples"] == 2
    assert cells[None]["wall_median"] == 1.0 and cells["a+a+a"]["wall_median"] == 9.0


def test_two_groups_of_the_same_composition_pool_into_one_cell():
    recs = [rec("a", 1.0, concurrent=True, group="g1", group_loops=["a", "a"]),
            rec("a", 3.0, concurrent=True, group="g2", group_loops=["a", "a"])]
    out = lt.summarize(recs)
    assert len(out) == 1 and out[0]["samples"] == 2


def test_report_percentile_prints_a_column_and_says_when_it_is_the_maximum(tmp_path, capsys):
    res = tmp_path / "r.jsonl"
    res.write_text("".join(json.dumps(rec("a", w)) + "\n" for w in (1.0, 2.0, 3.0)))
    assert run_main("report", "--results", res, "--percentile", "90") == 0
    out = capsys.readouterr().out
    assert "wall p90" in out and "3.00" in out and "p90 is the max of 3" in out


def test_report_json_carries_the_percentile_and_the_cell(tmp_path, capsys):
    res = tmp_path / "r.jsonl"
    res.write_text("".join(json.dumps(rec("a", w, concurrent=True, group="g", group_loops=["a", "a"])) + "\n"
                           for w in (1.0, 2.0, 3.0)))
    assert run_main("report", "--results", res, "--percentile", "90", "--json") == 0
    g = json.loads(capsys.readouterr().out)[0]
    assert g["wall_p90"] == 3.0 and g["cell"] == "a+a"


@pytest.mark.parametrize("bad", ["0", "101", "-5", "x"])
def test_report_refuses_a_percentile_outside_1_to_100(tmp_path, capsys, bad):
    res = tmp_path / "r.jsonl"
    res.write_text(json.dumps(rec("a", 1.0)) + "\n")
    with pytest.raises(SystemExit) as e:
        run_main("report", "--results", res, "--percentile", bad)
    assert e.value.code == 2


def test_report_without_percentile_prints_no_percentile_column(tmp_path, capsys):
    res = tmp_path / "r.jsonl"
    res.write_text(json.dumps(rec("a", 1.0)) + "\n")
    run_main("report", "--results", res)
    assert "p90" not in capsys.readouterr().out


def test_interrupting_a_group_kills_every_members_command(tmp_path, project):
    """An interrupted group must not leave K gates running unwatched."""
    pids = tmp_path / "pids"
    d = write_decl(tmp_path, project,
                   f'[[loop]]\nid="long"\ncommand="echo $$ >> {pids}; exec sleep 30"\n')
    p = subprocess.Popen([sys.executable, str(TOOL), "run-group", str(d), "--loops", "long,long",
                          "--max-load", "9999", "--no-pressure", "--results", str(tmp_path / "r.jsonl")],
                         env={**os.environ, "LOOP_TIME_SLOT_CMD": "true"}, stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and not (pids.exists() and len(pids.read_text().split()) == 2):
        time.sleep(0.1)
    started = pids.read_text().split()
    assert len(started) == 2
    p.send_signal(signal.SIGTERM)
    assert p.wait(timeout=20) == 130
    for pid in started:
        with pytest.raises(ProcessLookupError):
            os.kill(int(pid), 0)


def test_the_barrier_holds_a_fast_member_until_a_slow_one_is_ready(tmp_path, group_decl):
    """A member whose setup takes 1.5 s must not let the others start 1.5 s ahead of it."""
    res = tmp_path / "r.jsonl"
    assert group(group_decl, "slowsetup,quick,quick", "--samples", "1", res=res) == 0
    starts = [r["started_at"] for r in records(res)]
    assert max(starts) - min(starts) < 0.5


# ---- --set-env ---------------------------------------------------------------------------

SETENV_DECL = """\
env = {{ KEEP = "decl", OVER = "decl" }}

[[loop]]
id = "show"
command = "echo $KEEP,$OVER,$WORKERS >> {out}"
env = {{ OVER = "loop" }}
"""


def test_set_env_overrides_declaration_and_loop_env_on_run(tmp_path, project):
    out = tmp_path / "out.txt"
    d = write_decl(tmp_path, project, SETENV_DECL.format(out=out))
    res = tmp_path / "r.jsonl"
    assert run_ok("run", d, "show", "--samples", "1", "--results", res,
                  "--set-env", "WORKERS=4", "--set-env", "OVER=cli") == 0
    assert out.read_text().strip() == "decl,cli,4"
    assert records(res)[0]["env_keys"] == ["KEEP", "OVER", "WORKERS"]
    assert "cli" not in json.dumps(records(res)[0])


def test_set_env_reaches_every_member_of_a_group(tmp_path, project):
    out = tmp_path / "out.txt"
    d = write_decl(tmp_path, project, SETENV_DECL.format(out=out))
    assert run_ok("run-group", d, "--loops", "show,show", "--samples", "1", "--max-load", "9999",
                  "--results", tmp_path / "r.jsonl", "--set-env", "WORKERS=7") == 0
    assert out.read_text().split() == ["decl,loop,7", "decl,loop,7"]


@pytest.mark.parametrize("bad", ["NOEQUALS", "=x", "1BAD=x", "A-B=x"])
def test_set_env_refuses_a_malformed_pair(tmp_path, project, bad, capsys):
    d = write_decl(tmp_path, project, SETENV_DECL.format(out=tmp_path / "o"))
    with pytest.raises(SystemExit) as e:
        run_main("run", d, "show", "--results", tmp_path / "r.jsonl", "--set-env", bad)
    assert e.value.code == 2
    assert "KEY=VALUE" in capsys.readouterr().err


# ---- curve: the cell plan and its seed ---------------------------------------------------

def _plan(seed, **kw):
    args = dict(ns=[1, 2, 4, 6, 8], samples=3, samples_at_1=1, control=4)
    args.update(kw)
    return lt.curve_plan(seed=seed, **args)


def _order(plan):
    return [(c["role"], c["n"], c["sample"]) for c in plan]


def test_curve_plan_has_the_right_cells_and_controls_at_start_middle_end():
    plan = _plan(7)
    cells = [c for c in plan if c["role"] == "cell"]
    # three samples at each N of 2 and above, one at N=1
    assert sorted((c["n"], c["sample"]) for c in cells) == sorted(
        [(1, 0)] + [(n, s) for n in (2, 4, 6, 8) for s in range(3)])
    controls = [i for i, c in enumerate(plan) if c["role"] == "control"]
    assert len(controls) == 3 and all(plan[i]["n"] == 4 for i in controls)
    assert controls[0] == 0 and controls[-1] == len(plan) - 1
    assert 0 < controls[1] < len(plan) - 1
    assert [plan[i]["sample"] for i in controls] == [0, 1, 2]


def test_curve_plan_runs_round_by_round_each_round_shuffled():
    plan = [c for c in _plan(7) if c["role"] == "cell"]
    rounds = [c["round"] for c in plan]
    assert rounds == sorted(rounds)
    for r in range(3):
        assert {c["n"] for c in plan if c["round"] == r} == ({1, 2, 4, 6, 8} if r == 0 else {2, 4, 6, 8})


def test_one_seed_gives_one_order_twice_and_another_seed_another_order():
    assert _order(_plan(11)) == _order(_plan(11))
    orders = {tuple(_order(_plan(s))) for s in range(12)}
    assert len(orders) > 1
    assert _order(_plan(11)) != _order(_plan(12))


# ---- curve: the quiet wait ---------------------------------------------------------------

class FakeClock:
    """A clock that only moves when the code sleeps, so a wait costs no real time."""

    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s


def _quiet(values, below=5.0, hold=3.0, timeout=100.0):
    clock = FakeClock()
    seq = iter(values)
    return clock, lambda: lt.wait_quiet(lambda: next(seq), below, hold, timeout, sleep=clock.sleep,
                                        clock=clock.now, interval=1.0)


def test_quiet_wait_returns_after_the_hold_once_the_reading_is_below_the_threshold():
    clock, wait = _quiet([9, 9, 2, 2, 2, 2, 2, 2])
    assert wait() == 5.0  # quiet from t=2, held for 3 s


def test_a_spike_during_the_hold_restarts_it():
    clock, wait = _quiet([2, 2, 9, 2, 2, 2, 2, 2])
    assert wait() == 6.0  # quiet from t=3 after the spike at t=2


def test_a_reading_that_cannot_be_taken_is_not_quiet():
    clock, wait = _quiet([None, None, None, 2, 2, 2, 2, 2])
    assert wait() == 6.0


def test_quiet_wait_that_never_goes_quiet_raises_after_the_timeout():
    clock = FakeClock()
    with pytest.raises(lt.QuietError) as e:
        lt.wait_quiet(lambda: 40.0, 5.0, 3.0, 10.0, sleep=clock.sleep, clock=clock.now, interval=1.0)
    assert "10" in str(e.value) and "40" in str(e.value)
    assert clock.t >= 10.0


def test_quiet_wait_with_no_hold_returns_at_once_when_already_quiet():
    clock = FakeClock()
    assert lt.wait_quiet(lambda: 1.0, 5.0, 0.0, 10.0, sleep=clock.sleep, clock=clock.now) == 0.0


# ---- curve: the analysis (knee, ceiling, failures, flaky, control drift) ------------------

def crec(n, wall, sample=0, role="cell", exit_code=0, flaky=None, failed_tests=None, gates=1, member=0):
    r = {"curve": "c1", "role": role, "n": n, "gates": gates, "curve_sample": sample,
         "curve_cell": f"{role}:{n}:{sample}", "exit_code": exit_code, "wall_seconds": wall,
         "cpu_seconds": wall, "seed": 1, "var": "W"}
    if flaky is not None:
        r["flaky"] = flaky
    if failed_tests is not None:
        r["failed_tests"] = failed_tests
    return r


def curve_recs(walls, **per_n):
    """walls: {n: [wall, ...]}; per_n: n -> extra record fields for every sample at that n."""
    return [crec(n, w, i, **per_n.get(f"n{n}", {})) for n, ws in walls.items() for i, w in enumerate(ws)]


def by_n(result, n):
    return next(x for x in result["per_n"] if x["n"] == n)


KNEE_AT_4 = {1: [100], 2: [60, 60, 60], 4: [40, 40, 40], 6: [38, 38, 60], 8: [41, 41, 41]}


def test_p4_a_knee_planted_at_4_and_a_high_variance_cell_at_6_gives_knee_4_and_rejects_6():
    r = lt.analyze_curve(curve_recs({1: [100], 2: [60] * 3, 4: [40] * 3, 6: [38, 38, 60]}))
    assert r["knee"] == 4
    assert r["ceiling"] == 4
    six = by_n(r, 6)
    assert not six["eligible"] and any("p90" in why for why in six["reasons"])
    assert six["wall_median"] == 38 and six["wall_p90"] == 60


def test_p4_flipping_the_variance_plant_off_lets_6_be_the_ceiling():
    r = lt.analyze_curve(curve_recs({1: [100], 2: [60] * 3, 4: [40] * 3, 6: [38, 38, 38]}))
    assert r["knee"] == 4 and r["ceiling"] == 6
    assert by_n(r, 6)["eligible"]


def test_p4_flipping_the_knee_plant_off_moves_the_knee_to_6():
    r = lt.analyze_curve(curve_recs({1: [100], 2: [60] * 3, 4: [55] * 3, 6: [38, 38, 38]}))
    assert r["knee"] == 6 and r["ceiling"] == 6
    four = by_n(r, 4)
    assert not four["eligible"] and any("10%" in why for why in four["reasons"])


def test_p4_with_both_plants_flipped_the_other_way_nothing_qualifies_but_the_minimum_is_rejected():
    r = lt.analyze_curve(curve_recs({1: [100], 2: [60] * 3, 4: [55] * 3, 6: [38, 38, 60]}))
    assert r["knee"] is None and r["ceiling"] is None


def test_knee_is_the_smallest_and_ceiling_the_largest_eligible_n():
    r = lt.analyze_curve(curve_recs(KNEE_AT_4))
    assert r["knee"] == 4 and r["ceiling"] == 8


def test_p5_a_failing_cell_is_counted_not_timed_and_fails_the_cap_rule():
    recs = curve_recs({1: [100], 2: [60] * 3, 4: [40, 40], 6: [38] * 3})
    recs.append(crec(4, 5.0, sample=2, exit_code=1))  # fast because it stopped early
    r = lt.analyze_curve(recs)
    four = by_n(r, 4)
    assert four["failures"] == 1 and four["samples"] == 2 and four["wall_median"] == 40
    assert not four["eligible"] and any("fail" in why for why in four["reasons"])
    assert r["knee"] == 6
    # the plant flipped off: the same cell passing gives knee 4
    recs[-1] = crec(4, 40.0, sample=2)
    assert lt.analyze_curve(recs)["knee"] == 4


def test_a_command_that_exits_zero_but_reports_failed_tests_is_a_failure():
    recs = curve_recs({2: [60] * 3, 4: [40, 40, 40], 6: [38] * 3})
    recs[3]["failed_tests"] = 2
    r = lt.analyze_curve(recs)
    assert by_n(r, 4)["failures"] == 1 and r["knee"] == 6


def test_flaky_above_the_controls_median_fails_the_cap_rule_and_moves_the_knee():
    recs = curve_recs({2: [60] * 3, 4: [40] * 3, 6: [38] * 3}, n4={"flaky": 2}, n6={"flaky": 0})
    recs += [crec(4, 40.0, i, role="control", flaky=0) for i in range(3)]
    r = lt.analyze_curve(recs)
    four = by_n(r, 4)
    assert not four["eligible"] and any("flaky" in why for why in four["reasons"])
    assert r["knee"] == 6
    # planted off: the same cells with no extra flakiness keep the knee at 4
    for x in recs:
        if x["role"] == "cell" and x["n"] == 4:
            x["flaky"] = 0
    assert lt.analyze_curve(recs)["knee"] == 4


def test_flaky_equal_to_the_controls_median_passes():
    recs = curve_recs({4: [40] * 3, 6: [38] * 3}, n4={"flaky": 1}, n6={"flaky": 1})
    recs += [crec(4, 40.0, i, role="control", flaky=1) for i in range(3)]
    assert lt.analyze_curve(recs)["knee"] == 4


def test_without_any_flaky_count_the_rule_is_the_three_conditions():
    r = lt.analyze_curve(curve_recs({4: [40] * 3, 6: [38] * 3}))
    assert r["knee"] == 4 and by_n(r, 4)["flaky"] == 0


def test_a_gate_group_cell_takes_its_slowest_member_and_fails_if_any_member_fails():
    recs = [crec(4, 10.0, 0, gates=2), crec(4, 12.0, 0, gates=2),
            crec(4, 10.0, 1, gates=2), crec(4, 11.0, 1, gates=2, exit_code=1)]
    four = by_n(lt.analyze_curve(recs), 4)
    assert four["cells"] == 2 and four["samples"] == 1 and four["failures"] == 1
    assert four["wall_median"] == 12.0 and four["throughput"] == pytest.approx(2 / 12.0)


def test_p90_of_three_samples_is_the_maximum_and_says_so():
    four = by_n(lt.analyze_curve(curve_recs({4: [40, 41, 42]})), 4)
    assert four["wall_p90"] == 42 and four["p90_is_max"] is True


def _controls(*walls):
    return [crec(4, w, i, role="control") for i, w in enumerate(walls)]


def test_control_drift_a_planted_10_percent_spread_is_flagged():
    c = lt.analyze_curve(curve_recs({4: [40] * 3}) + _controls(100.0, 105.0, 110.0))["control"]
    assert c["spread"] == pytest.approx(0.10) and c["drifted"] is True


def test_control_drift_a_2_percent_spread_is_not_flagged():
    c = lt.analyze_curve(curve_recs({4: [40] * 3}) + _controls(100.0, 101.0, 102.0))["control"]
    assert c["spread"] == pytest.approx(0.02) and c["drifted"] is False


def test_control_drift_needs_two_passing_controls_else_it_says_unknown():
    c = lt.analyze_curve(curve_recs({4: [40] * 3}) + _controls(100.0))["control"]
    assert c["spread"] is None and c["drifted"] is None


# ---- curve: the driver -------------------------------------------------------------------

@pytest.fixture
def quiet_machine(monkeypatch):
    """The CPU reads as idle, so no test waits on, or depends on, the real machine."""
    monkeypatch.setattr(lt, "read_cpu_pressure", lambda: 0.0)


def curve_decl(tmp_path, project, command=None):
    log = tmp_path / "w.log"
    command = command or f"echo $W >> {log}"
    return write_decl(tmp_path, project, f'[[loop]]\nid="w"\ncommand = "{command}"\n'), log


def curve(decl, res, *extra):
    return run_main("curve", decl, "--loop", "w", "--var", "W", "--no-pressure", "--quiet-for", "0",
                    "--quiet-timeout", "0", "--results", res, *extra)


SMALL = ("--n", "1,2", "--samples", "2", "--samples-at-1", "1", "--control", "2", "--seed", "5")


def test_curve_runs_every_cell_in_the_seeded_order_with_the_variable_set(tmp_path, project, quiet_machine):
    d, log = curve_decl(tmp_path, project)
    res = tmp_path / "r.jsonl"
    assert curve(d, res, *SMALL) == 0
    plan = lt.curve_plan([1, 2], 2, 1, 2, 5)
    assert [int(x) for x in log.read_text().split()] == [c["n"] for c in plan]
    assert [(r["role"], r["n"], r["curve_sample"]) for r in records(res)] == [
        (c["role"], c["n"], c["sample"]) for c in plan]
    assert len(plan) == 3 + 1 + 2


def test_every_curve_record_carries_the_curve_fields_and_says_the_load_guard_was_not_used(
        tmp_path, project, quiet_machine):
    d, _ = curve_decl(tmp_path, project)
    res = tmp_path / "r.jsonl"
    assert curve(d, res, *SMALL) == 0
    recs = records(res)
    assert len({r["curve"] for r in recs}) == 1
    for r in recs:
        assert r["seed"] == 5 and r["var"] == "W" and r["gates"] == 1
        assert r["role"] in ("control", "cell") and isinstance(r["quiet_wait_s"], (int, float))
        assert r["under_load"] is False and r["load_guard"].startswith("not used")
        assert "W" in r["env_keys"] and r["concurrent"] is False
    assert {r["n"] for r in recs if r["role"] == "control"} == {2}


def test_curve_prints_and_records_a_drawn_seed_when_none_is_given(tmp_path, project, quiet_machine, capsys):
    d, _ = curve_decl(tmp_path, project)
    res = tmp_path / "r.jsonl"
    assert curve(d, res, "--n", "2", "--samples", "1", "--control", "2") == 0
    seed = records(res)[0]["seed"]
    assert isinstance(seed, int) and f"seed {seed}" in capsys.readouterr().out
    assert {r["seed"] for r in records(res)} == {seed}


def test_curve_gates_runs_each_cell_as_a_group_and_the_control_as_one_gate(tmp_path, project, quiet_machine):
    d, log = curve_decl(tmp_path, project)
    res = tmp_path / "r.jsonl"
    assert curve(d, res, "--n", "2", "--samples", "2", "--control", "2", "--seed", "1", "--gates", "2") == 0
    recs = records(res)
    cells = [r for r in recs if r["role"] == "cell"]
    ctl = [r for r in recs if r["role"] == "control"]
    assert len(cells) == 4 and all(r["concurrent"] and r["gates"] == 2 for r in cells)
    assert len({r["group"] for r in cells}) == 2
    assert len(ctl) == 3 and all(not r["concurrent"] and r["gates"] == 1 for r in ctl)
    assert len({r["curve_cell"] for r in cells}) == 2


def test_set_env_reaches_every_curve_cell(tmp_path, project, quiet_machine):
    d, log = curve_decl(tmp_path, project, command="echo $W,$EXTRA >> LOG")
    d.write_text(d.read_text().replace("LOG", str(log)))
    assert curve(d, tmp_path / "r.jsonl", "--n", "2", "--samples", "1", "--control", "2", "--seed", "1",
                 "--set-env", "EXTRA=hi") == 0
    assert set(log.read_text().split()) == {"2,hi"}


def test_flaky_and_failed_counts_are_read_from_the_output_when_a_regex_matches(
        tmp_path, project, quiet_machine):
    d, _ = curve_decl(tmp_path, project, command="echo 3 flaky; echo 2 failed; echo 4 passed")
    res = tmp_path / "r.jsonl"
    curve(d, res, "--n", "2", "--samples", "1", "--control", "2", "--seed", "1",
          "--flaky-regex", r"(\d+) flaky", "--failed-regex", r"(\d+) failed")
    assert all(r["flaky"] == 3 and r["failed_tests"] == 2 for r in records(res))


def test_no_regex_or_no_match_means_the_fields_are_absent(tmp_path, project, quiet_machine):
    d, _ = curve_decl(tmp_path, project, command="echo 4 passed")
    res = tmp_path / "r.jsonl"
    curve(d, res, "--n", "2", "--samples", "1", "--control", "2", "--seed", "1")
    curve(d, res, "--n", "2", "--samples", "1", "--control", "2", "--seed", "1", "--flaky-regex", r"(\d+) flaky")
    assert all("flaky" not in r and "failed_tests" not in r for r in records(res))


def test_a_regex_needs_exactly_one_capture_group(tmp_path, project, quiet_machine, capsys):
    d, log = curve_decl(tmp_path, project)
    assert curve(d, tmp_path / "r.jsonl", *SMALL, "--flaky-regex", r"\d+ flaky") == 2
    assert "one capture group" in capsys.readouterr().err and not log.exists()


def test_a_failing_cell_still_records_the_others_run_and_the_exit_is_one(tmp_path, project, quiet_machine):
    d, log = curve_decl(tmp_path, project, command="echo $W >> LOG; test $W -ne 1")
    d.write_text(d.read_text().replace("LOG", str(log)))
    res = tmp_path / "r.jsonl"
    assert curve(d, res, *SMALL) == 1
    recs = records(res)
    assert len(recs) == 6
    assert [r["exit_code"] for r in recs if r["n"] == 1] == [1]
    assert all(r["exit_code"] == 0 for r in recs if r["n"] != 1)


def test_a_machine_that_never_goes_quiet_exits_4_runs_nothing_and_records_why(
        tmp_path, project, monkeypatch, capsys):
    monkeypatch.setattr(lt, "read_cpu_pressure", lambda: 40.0)
    d, log = curve_decl(tmp_path, project)
    res = tmp_path / "r.jsonl"
    assert curve(d, res, *SMALL) == 4
    assert not log.exists()
    ev = records(res)
    assert len(ev) == 1 and ev[0]["event"] == "quiet_timeout" and ev[0]["seed"] == 5
    assert "40" in ev[0]["reason"] and ev[0]["curve"]
    assert "did not stay below" in capsys.readouterr().err


def _busy_after(calls, monkeypatch):
    seen = {"n": 0}

    def reader():
        seen["n"] += 1
        return 0.0 if seen["n"] <= calls else 40.0

    monkeypatch.setattr(lt, "read_cpu_pressure", reader)


def test_a_cell_is_never_timed_on_a_busy_machine_the_earlier_cells_stay_recorded(
        tmp_path, project, monkeypatch):
    _busy_after(2, monkeypatch)
    d, log = curve_decl(tmp_path, project)
    res = tmp_path / "r.jsonl"
    assert curve(d, res, *SMALL) == 4
    assert len(log.read_text().split()) == 2
    assert [r.get("event") for r in records(res)] == [None, None, "quiet_timeout"]


def test_resume_runs_only_the_cells_not_finished_and_keeps_the_seed(tmp_path, project, monkeypatch):
    _busy_after(2, monkeypatch)
    d, log = curve_decl(tmp_path, project)
    res = tmp_path / "r.jsonl"
    assert curve(d, res, *SMALL) == 4
    cid = records(res)[0]["curve"]
    monkeypatch.setattr(lt, "read_cpu_pressure", lambda: 0.0)
    assert curve(d, res, *SMALL[:-2], "--resume", cid) == 0
    plan = lt.curve_plan([1, 2], 2, 1, 2, 5)
    assert [int(x) for x in log.read_text().split()] == [c["n"] for c in plan]
    done = [r for r in records(res) if "event" not in r]
    assert [(r["role"], r["n"], r["curve_sample"]) for r in done] == [(c["role"], c["n"], c["sample"]) for c in plan]
    assert {r["curve"] for r in done} == {cid} and {r["seed"] for r in done} == {5}


def test_resume_refuses_an_unknown_curve_or_a_different_seed(tmp_path, project, quiet_machine, capsys):
    d, _ = curve_decl(tmp_path, project)
    res = tmp_path / "r.jsonl"
    assert curve(d, res, *SMALL[:-2], "--resume", "nope") == 2
    assert curve(d, res, *SMALL) == 0
    cid = records(res)[0]["curve"]
    assert curve(d, res, *SMALL[:-2], "--seed", "9", "--resume", cid) == 2
    assert "seed" in capsys.readouterr().err


def test_an_interrupt_stops_the_curve_and_keeps_the_records_so_far(tmp_path, project, quiet_machine, monkeypatch):
    d, log = curve_decl(tmp_path, project)
    res = tmp_path / "r.jsonl"
    real, calls = lt.run_loop, {"n": 0}

    def flaky_run(*a, **kw):
        calls["n"] += 1
        if calls["n"] == 3:
            raise KeyboardInterrupt
        return real(*a, **kw)

    monkeypatch.setattr(lt, "run_loop", flaky_run)
    assert curve(d, res, *SMALL) == 130
    assert len(records(res)) == 2


@pytest.mark.parametrize("extra,needle", [
    (("--n", "1,x"), "--n"), (("--n", "0,2"), "--n"), (("--n", "2,2"), "--n"), (("--samples", "0"), "--samples"),
    (("--samples-at-1", "0"), "--samples-at-1"), (("--control", "0"), "--control"), (("--gates", "0"), "--gates"),
    (("--set-env", "W=3"), "--var"), (("--loop", "nope"), "unknown loop"),
])
def test_curve_refuses_bad_arguments_before_running_anything(tmp_path, project, quiet_machine, capsys, extra, needle):
    d, log = curve_decl(tmp_path, project)
    argv = ["curve", d, "--loop", "w", "--var", "W", "--no-pressure", "--results", tmp_path / "r.jsonl",
            *SMALL, *extra]
    # a later duplicate flag wins in argparse, so the bad value replaces the good one
    assert run_main(*argv) == 2
    assert needle in capsys.readouterr().err and not log.exists()


def test_curve_refuses_a_bad_variable_name(tmp_path, project, quiet_machine, capsys):
    d, _ = curve_decl(tmp_path, project)
    assert run_main("curve", d, "--loop", "w", "--var", "1-x", "--results", tmp_path / "r.jsonl", *SMALL) == 2
    assert "--var" in capsys.readouterr().err


def test_curve_refuses_while_another_session_holds_the_slot(tmp_path, project, quiet_machine, monkeypatch):
    monkeypatch.setenv("LOOP_TIME_SLOT_CMD", "sh -c 'echo held by someone; exit 1'")
    d, log = curve_decl(tmp_path, project)
    assert curve(d, tmp_path / "r.jsonl", *SMALL) == 6
    assert not log.exists()


# ---- report --curve ----------------------------------------------------------------------

def write_curve(path, recs):
    path.write_text("".join(json.dumps(r) + "\n" for r in recs))


def test_report_curve_gives_the_knee_ceiling_and_control_spread_as_json(tmp_path, capsys):
    res = tmp_path / "r.jsonl"
    write_curve(res, curve_recs({1: [100], 2: [60] * 3, 4: [40] * 3, 6: [38, 38, 60]}) +
                [crec(4, w, i, role="control") for i, w in enumerate((100.0, 110.0, 105.0))])
    assert run_main("report", "--results", res, "--curve", "c1", "--json") == 0
    out = json.loads(capsys.readouterr().out)
    assert out["curve"] == "c1" and out["knee"] == 4 and out["ceiling"] == 4 and out["seed"] == 1
    assert out["control"]["drifted"] is True
    assert [x["n"] for x in out["per_n"]] == [1, 2, 4, 6]


def test_report_curve_table_names_the_knee_the_p90_caveat_and_the_drift(tmp_path, capsys):
    res = tmp_path / "r.jsonl"
    write_curve(res, curve_recs({2: [60] * 3, 4: [40] * 3}) +
                [crec(4, w, i, role="control") for i, w in enumerate((100.0, 110.0, 105.0))])
    assert run_main("report", "--results", res, "--curve", "c1") == 0
    out = capsys.readouterr().out
    assert "knee 4" in out and "ceiling 4" in out and "p90 is the max of 3" in out
    assert "DRIFTED" in out and "10.0%" in out


def test_report_curve_says_ok_when_the_control_held(tmp_path, capsys):
    res = tmp_path / "r.jsonl"
    write_curve(res, curve_recs({4: [40] * 3}) + [crec(4, w, i, role="control") for i, w in enumerate((100.0, 101.0, 102.0))])
    run_main("report", "--results", res, "--curve", "c1")
    out = capsys.readouterr().out
    assert "DRIFTED" not in out and "2.0%" in out


def test_report_curve_shows_failures_and_flaky_counts_and_why_an_n_was_rejected(tmp_path, capsys):
    res = tmp_path / "r.jsonl"
    recs = curve_recs({4: [40, 40], 6: [38] * 3})
    recs.append(crec(4, 5.0, 2, exit_code=1))
    recs.append(crec(6, 38.0, 3, flaky=2))
    write_curve(res, recs)
    run_main("report", "--results", res, "--curve", "c1")
    out = capsys.readouterr().out
    assert "1 failed" in out and "knee" in out


def test_report_curve_of_an_unknown_id_is_an_error(tmp_path, capsys):
    res = tmp_path / "r.jsonl"
    write_curve(res, curve_recs({4: [40] * 3}))
    assert run_main("report", "--results", res, "--curve", "other") == 2
    assert "other" in capsys.readouterr().err


def test_plain_report_ignores_a_curves_event_records(tmp_path, capsys):
    res = tmp_path / "r.jsonl"
    write_curve(res, [{"event": "quiet_timeout", "curve": "c1", "reason": "busy"}, rec("a", 1.0)])
    assert run_main("report", "--results", res, "--json") == 0
    out = json.loads(capsys.readouterr().out)
    assert [g["loop"] for g in out] == ["a"]


def test_help_documents_curve_set_env_and_the_curve_report(capsys):
    with pytest.raises(SystemExit):
        run_main("--help")
    out = capsys.readouterr().out
    for word in ("curve", "--set-env", "knee", "ceiling", "quiet", "DRIFTED", "--resume", "--seed"):
        assert word in out, word
