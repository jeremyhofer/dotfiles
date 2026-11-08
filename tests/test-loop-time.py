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
    """The real fleet-slot, its state under tmp_path, run outside any named session."""
    monkeypatch.setenv("FLEET_SLOT_STATE", str(tmp_path / "slot"))
    monkeypatch.setenv("FLEET_CANONICALS_CONFIG", str(tmp_path / "no-config"))
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
