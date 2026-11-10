#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for fleet-slot. The state directory, the config file and the session-name sources are all
under a temp dir, so nothing reads or writes the machine's real slot. fleet-slot runs as a
subprocess, the way a session meets it."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_fleet-slot"


# A stand-in for fleet-decl: what the fleet record says about the director seat, by STUB_DECL.
#   here       the record declares director-canonical for this machine (every test's default)
#   elsewhere  it declares it for another machine only
#   none       it declares no director
#   unreadable fleet-decl exits 2: no record, or one it cannot read
DECL_STUB = """#!/bin/sh
mode=${STUB_DECL:-here}
[ "$mode" = unreadable ] && { echo 'fleet-decl: no record' >&2; exit 2; }
[ "$2" = director-canonical ] || exit 1
[ "$mode" = none ] && exit 1
case "$1" in
  --canonical) echo director ;;
  --canonical-list) if [ "$mode" = here ]; then hostname; else echo another-host; fi ;;
  *) exit 1 ;;
esac
"""


@pytest.fixture(autouse=True)
def isolated(monkeypatch, tmp_path):
    stub = tmp_path / "fleet-decl"
    stub.write_text(DECL_STUB)
    stub.chmod(0o755)
    monkeypatch.setenv("FLEET_DECL_CMD", str(stub))
    monkeypatch.setenv("STUB_DECL", "here")
    monkeypatch.setenv("FLEET_SLOT_STATE", str(tmp_path / "slot"))
    monkeypatch.setenv("FLEET_CANONICALS_CONFIG", str(tmp_path / "config"))
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("FLEET_AGENTS_JSON_CMD", "echo []")
    monkeypatch.delenv("FLEET_AGENTS_JSON_ALL_CMD", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_SESSION_ID", raising=False)
    return tmp_path


def slot(*args, env=None):
    e = dict(os.environ, **(env or {}))
    return subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True, env=e)


def inside(tmp_path, name, sid="sid-1"):
    """The environment of a session named `name`: the usage file the status line writes."""
    d = tmp_path / "run" / "claude-usage"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{sid}.json").write_text(json.dumps({"session_name": name}))
    return {"CLAUDE_CODE_SESSION_ID": sid}


def state(tmp_path):
    return json.loads((tmp_path / "slot" / "slot.json").read_text())


def history(tmp_path):
    return [json.loads(l) for l in (tmp_path / "slot" / "history.jsonl").read_text().splitlines()]


def granted(holder="alpha", minutes="20"):
    assert slot("request", holder, "--minutes", minutes, "--what", "timed run", "--as", holder).returncode == 0
    r = slot("grant", holder, "--as", "director-canonical")
    assert r.returncode == 0, r.stderr


# ---- check -----------------------------------------------------------------------------------

def test_check_is_free_with_no_state_and_writes_nothing(isolated):
    r = slot("check", "alpha")
    assert r.returncode == 0 and r.stdout.strip() == "free"
    assert not (isolated / "slot").exists()


def test_check_exits_1_for_a_non_holder_and_0_for_the_holder(isolated):
    granted("alpha")
    other = slot("check", "beta")
    assert other.returncode == 1
    assert "held by alpha" in other.stdout and "timed run" in other.stdout
    assert slot("check", "alpha").returncode == 0


def test_check_reads_the_calling_session_and_treats_an_unnamed_caller_as_another(isolated):
    granted("alpha")
    assert slot("check", env=inside(isolated, "alpha")).returncode == 0
    assert slot("check", env=inside(isolated, "beta", sid="sid-2")).returncode == 1
    anon = slot("check")
    assert anon.returncode == 1 and "could not be read" in anon.stdout


def test_check_names_the_caller_from_the_agents_listing_when_there_is_no_usage_file(isolated):
    granted("alpha")
    listing = json.dumps([{"sessionId": "sid-9", "name": "alpha"}])
    env = {"CLAUDE_CODE_SESSION_ID": "sid-9", "FLEET_AGENTS_JSON_CMD": f"echo {listing}"}
    r = slot("check", env=env)
    assert r.returncode == 0 and "(you)" in r.stdout, r.stdout
    other = json.dumps([{"sessionId": "sid-9", "name": "beta"}])
    r = slot("check", env={**env, "FLEET_AGENTS_JSON_CMD": f"echo {other}"})
    assert r.returncode == 1 and "could not be read" not in r.stdout


def test_check_does_not_run_the_listing_when_the_slot_is_free(isolated):
    marker = isolated / "listing-ran"
    env = {"CLAUDE_CODE_SESSION_ID": "sid-9", "FLEET_AGENTS_JSON_CMD": f"touch {marker}"}
    assert slot("check", env=env).returncode == 0
    assert not marker.exists()


def test_fleet_slot_as_names_the_caller_where_nothing_else_can(isolated):
    granted("alpha")
    r = slot("check", env={"FLEET_SLOT_AS": "alpha"})
    assert r.returncode == 0 and "(you)" in r.stdout, r.stdout
    assert slot("check", env={"FLEET_SLOT_AS": "beta"}).returncode == 1
    # a change made as that name records it, and --as may not contradict it
    r = slot("release", "alpha", env={"FLEET_SLOT_AS": "alpha"})
    assert r.returncode == 0, r.stderr
    assert slot("request", "beta", "--minutes", "5", "--what", "x", "--as", "gamma",
                env={"FLEET_SLOT_AS": "beta"}).returncode == 1


def test_the_usage_file_wins_over_fleet_slot_as(isolated):
    granted("alpha")
    env = {**inside(isolated, "alpha"), "FLEET_SLOT_AS": "beta"}
    assert slot("check", env=env).returncode == 0


# ---- grant -----------------------------------------------------------------------------------

def test_a_non_arbiter_grant_is_refused_and_changes_nothing(isolated):
    assert slot("request", "alpha", "--minutes", "5", "--what", "x", "--as", "alpha").returncode == 0
    r = slot("grant", "alpha", "--as", "alpha")
    assert r.returncode == 1 and "not an arbiter" in r.stderr
    assert state(isolated)["holder"] is None


def test_the_arbiter_list_comes_from_the_config(isolated):
    (isolated / "config").write_text("# comment\nslot-arbiter = director-canonical operator\n")
    assert slot("grant", "alpha", "--minutes", "5", "--what", "x", "--as", "operator").returncode == 0
    assert state(isolated)["holder"]["granted_by"] == "operator"


def test_grant_takes_minutes_and_what_from_the_queue_and_removes_the_entry(isolated):
    granted("alpha", minutes="17")
    st = state(isolated)
    assert st["holder"]["name"] == "alpha" and st["holder"]["minutes"] == 17
    assert st["holder"]["what"] == "timed run" and st["queue"] == []


def test_grant_to_an_unqueued_holder_needs_minutes_and_what(isolated):
    r = slot("grant", "alpha", "--as", "director-canonical")
    assert r.returncode == 2 and "--minutes and --what" in r.stderr


def test_grant_while_held_is_refused(isolated):
    granted("alpha")
    r = slot("grant", "beta", "--minutes", "5", "--what", "x", "--as", "director-canonical")
    assert r.returncode == 1 and "released first" in r.stderr
    assert state(isolated)["holder"]["name"] == "alpha"


# ---- who is asking ---------------------------------------------------------------------------

def test_as_may_not_contradict_the_session_it_runs_in(isolated):
    r = slot("grant", "alpha", "--minutes", "5", "--what", "x", "--as", "director-canonical",
             env=inside(isolated, "alpha"))
    assert r.returncode == 1 and "running inside 'alpha'" in r.stderr
    assert not (isolated / "slot" / "slot.json").exists()


def test_a_session_name_read_from_the_session_needs_no_as(isolated):
    env = inside(isolated, "director-canonical")
    assert slot("grant", "alpha", "--minutes", "5", "--what", "x", env=env).returncode == 0


def test_the_agents_listing_names_the_session_when_the_usage_file_is_missing(isolated):
    listing = json.dumps([{"sessionId": "sid-9", "name": "director-canonical"}])
    env = {"CLAUDE_CODE_SESSION_ID": "sid-9", "FLEET_AGENTS_JSON_CMD": f"echo {listing}"}
    r = slot("grant", "alpha", "--minutes", "5", "--what", "x", env=env)
    assert r.returncode == 0, r.stderr


def test_outside_a_session_as_is_required(isolated):
    r = slot("request", "alpha", "--minutes", "5", "--what", "x")
    assert r.returncode == 1 and "--as" in r.stderr


def test_a_session_requests_only_for_itself(isolated):
    r = slot("request", "beta", "--minutes", "5", "--what", "x", "--as", "alpha")
    assert r.returncode == 1 and "only for itself" in r.stderr
    assert slot("request", "beta", "--minutes", "5", "--what", "x", "--as", "director-canonical").returncode == 0


# ---- the queue -------------------------------------------------------------------------------

def test_one_queue_entry_per_holder_a_second_request_updates_it_in_place(isolated):
    for who in ("alpha", "beta"):
        assert slot("request", who, "--minutes", "5", "--what", "first", "--as", who).returncode == 0
    r = slot("request", "alpha", "--minutes", "9", "--what", "second", "--as", "alpha")
    assert r.returncode == 0 and r.stdout.startswith("updated")
    q = state(isolated)["queue"]
    assert [e["name"] for e in q] == ["alpha", "beta"]
    assert q[0]["minutes"] == 9 and q[0]["what"] == "second"


def test_the_holder_cannot_queue_again_while_holding(isolated):
    granted("alpha")
    r = slot("request", "alpha", "--minutes", "5", "--what", "x", "--as", "alpha")
    assert r.returncode == 1 and "already holds" in r.stderr


def test_request_needs_minutes_and_what(isolated):
    assert slot("request", "alpha", "--what", "x", "--as", "alpha").returncode == 2
    assert slot("request", "alpha", "--minutes", "0", "--what", "x", "--as", "alpha").returncode == 2
    assert slot("request", "alpha", "--minutes", "five", "--what", "x", "--as", "alpha").returncode == 2


# ---- release ---------------------------------------------------------------------------------

def test_release_by_the_holder_records_how_long_it_ran(isolated):
    granted("alpha")
    r = slot("release", "alpha", "--as", "alpha")
    assert r.returncode == 0, r.stderr
    assert state(isolated)["holder"] is None
    last = history(isolated)[-1]
    assert last["event"] == "release" and last["holder"] == "alpha"
    assert isinstance(last["held_seconds"], int) and last["minutes"] == 20
    assert slot("check", "beta").returncode == 0


def test_release_by_another_session_is_refused_but_an_arbiter_may(isolated):
    granted("alpha")
    r = slot("release", "alpha", "--as", "beta")
    assert r.returncode == 1 and state(isolated)["holder"]["name"] == "alpha"
    assert slot("release", "alpha", "--as", "director-canonical").returncode == 0


def test_release_withdraws_a_queued_request(isolated):
    assert slot("request", "alpha", "--minutes", "5", "--what", "x", "--as", "alpha").returncode == 0
    r = slot("release", "alpha", "--as", "alpha")
    assert r.returncode == 0 and "withdrew" in r.stdout
    assert state(isolated)["queue"] == []


def test_release_of_a_name_neither_holding_nor_queued_is_refused(isolated):
    assert slot("release", "alpha", "--as", "alpha").returncode == 1


# ---- no arbiter: first come, first served ----------------------------------------------------
#
# The default arbiter is the director seat, and a machine has none until its fleet record declares
# one for it. With no arbiter nobody could ever grant, so the slot goes to whoever asks first.

def test_with_no_director_declared_a_request_on_a_free_slot_takes_it(isolated, monkeypatch):
    monkeypatch.setenv("STUB_DECL", "none")
    r = slot("request", "alpha", "--minutes", "5", "--what", "x", "--as", "alpha")
    assert r.returncode == 0, r.stderr
    h = state(isolated)["holder"]
    assert h["name"] == "alpha" and h["granted_by"] == "first-come"
    assert state(isolated)["queue"] == []
    assert "no arbiter" in r.stdout and "holds the slot" in r.stdout
    assert slot("check", "alpha").returncode == 0


def test_with_no_arbiter_a_release_passes_the_slot_to_the_next_in_line(isolated, monkeypatch):
    monkeypatch.setenv("STUB_DECL", "none")
    for who in ("alpha", "beta", "gamma"):
        assert slot("request", who, "--minutes", "5", "--what", who, "--as", who).returncode == 0
    assert state(isolated)["holder"]["name"] == "alpha"
    assert [e["name"] for e in state(isolated)["queue"]] == ["beta", "gamma"]
    r = slot("release", "alpha", "--as", "alpha")
    assert r.returncode == 0, r.stderr
    assert "beta now holds the slot" in r.stdout
    st = state(isolated)
    assert st["holder"]["name"] == "beta" and st["holder"]["what"] == "beta"
    assert [e["name"] for e in st["queue"]] == ["gamma"]
    last = history(isolated)[-1]
    assert (last["event"], last["holder"], last["rule"]) == ("grant", "beta", "first-come")


def test_an_unreadable_fleet_record_means_no_director_and_says_so(isolated, monkeypatch):
    monkeypatch.setenv("STUB_DECL", "unreadable")
    r = slot("request", "alpha", "--minutes", "5", "--what", "x", "--as", "alpha")
    assert r.returncode == 0 and state(isolated)["holder"]["name"] == "alpha"
    assert "unreadable" in slot("status").stdout


def test_a_director_declared_only_for_another_machine_is_no_arbiter_here(isolated, monkeypatch):
    monkeypatch.setenv("STUB_DECL", "elsewhere")
    assert slot("request", "alpha", "--minutes", "5", "--what", "x", "--as", "alpha").returncode == 0
    assert state(isolated)["holder"]["name"] == "alpha"


def test_an_empty_slot_arbiter_key_means_first_come(isolated):
    (isolated / "config").write_text("slot-arbiter =\n")
    assert slot("request", "alpha", "--minutes", "5", "--what", "x", "--as", "alpha").returncode == 0
    assert state(isolated)["holder"]["name"] == "alpha"


def test_with_no_arbiter_grant_is_refused_and_names_the_rule(isolated, monkeypatch):
    monkeypatch.setenv("STUB_DECL", "none")
    r = slot("grant", "alpha", "--minutes", "5", "--what", "x", "--as", "director-canonical")
    assert r.returncode == 1 and "first come" in r.stderr
    assert not (isolated / "slot" / "slot.json").exists()


def test_a_declared_director_is_the_default_arbiter_and_a_request_waits_for_it(isolated):
    r = slot("request", "alpha", "--minutes", "5", "--what", "x", "--as", "alpha")
    assert r.returncode == 0 and state(isolated)["holder"] is None
    assert "director-canonical" in r.stdout
    assert slot("grant", "alpha", "--as", "director-canonical").returncode == 0


def test_an_explicit_arbiter_list_is_used_as_written_whatever_the_record_says(isolated, monkeypatch):
    monkeypatch.setenv("STUB_DECL", "none")
    (isolated / "config").write_text("slot-arbiter = operator\n")
    assert slot("request", "alpha", "--minutes", "5", "--what", "x", "--as", "alpha").returncode == 0
    assert state(isolated)["holder"] is None
    assert slot("release", "alpha", "--as", "alpha").returncode == 0   # withdraws; nothing passes on
    assert state(isolated)["holder"] is None


def test_status_names_who_arbitrates(isolated, monkeypatch):
    assert "arbiter  director-canonical" in slot("status").stdout
    assert json.loads(slot("status", "--json").stdout)["arbiters"] == ["director-canonical"]
    monkeypatch.setenv("STUB_DECL", "none")
    out = slot("status").stdout
    assert "arbiter  none" in out and "first come" in out
    assert json.loads(slot("status", "--json").stdout)["arbiters"] == []


# ---- status ----------------------------------------------------------------------------------

def test_status_shows_holder_queue_recent_and_load(isolated):
    granted("alpha")
    assert slot("release", "alpha", "--as", "alpha").returncode == 0
    granted("beta")
    assert slot("request", "gamma", "--minutes", "7", "--what", "gate", "--as", "gamma").returncode == 0
    out = slot("status").stdout
    assert "held by beta" in out and "1. gamma, 7 min: gate" in out
    assert "recent   alpha" in out and "load" in out
    js = json.loads(slot("status", "--json").stdout)
    assert js["holder"]["name"] == "beta" and js["queue"][0]["name"] == "gamma"
    assert js["recent"][0]["holder"] == "alpha"


def test_an_overdue_slot_is_shown_overdue_and_never_released(isolated):
    granted("alpha", minutes="1")
    st = state(isolated)
    st["holder"]["since"] = int(time.time()) - 600   # ten minutes into a one-minute slot
    (isolated / "slot" / "slot.json").write_text(json.dumps(st))
    out = slot("status").stdout
    assert "OVERDUE by 9 min" in out
    assert slot("check", "beta").returncode == 1
    assert "overdue" in slot("check", "beta").stdout


def test_an_unreadable_state_file_is_exit_2_not_free(isolated):
    (isolated / "slot").mkdir()
    (isolated / "slot" / "slot.json").write_text("{not json")
    r = slot("check", "alpha")
    assert r.returncode == 2 and "not a readable slot state" in r.stderr


# ---- wait ------------------------------------------------------------------------------------
# The waits must be SEEN to hold a run back: a command started under `wait` has not run while the
# slot is held or the load is high, and runs once that changes. A wait that returned at once would
# pass every case that only checks the end state.

def wait_bg(*args, env=None):
    e = dict(os.environ, **(env or {}))
    return subprocess.Popen([sys.executable, str(TOOL), "wait", *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, env=e)


def test_wait_on_a_free_slot_runs_the_command_at_once(isolated):
    r = slot("wait", "--free", "--interval", "0.1", "--", "sh", "-c", "echo ran")
    assert r.returncode == 0 and r.stdout.strip() == "ran", r.stderr


def test_wait_runs_the_command_without_its_own_interpreter_first_on_path(isolated):
    """`uv run --script` puts the tool's own environment's bin first on PATH; the command must not
    inherit it. Measured 2026-11-10: a publish run under `fleet-slot wait` resolved python3 to
    fleet-slot's uv environment, and overlay-doctor's report then named a path in the home
    directory, failing publish-check."""
    own = os.path.dirname(sys.executable)
    env = {"PATH": own + os.pathsep + os.environ["PATH"], "VIRTUAL_ENV": sys.prefix}
    r = slot("wait", "--free", "--interval", "0.1", "--", "sh", "-c", 'echo "$PATH"; echo "venv=${VIRTUAL_ENV:-}"',
             env=env)
    assert r.returncode == 0, r.stderr
    path_line, venv_line = r.stdout.strip().splitlines()
    dirs = [os.path.realpath(d) for d in path_line.split(os.pathsep) if d]
    assert os.path.realpath(own) not in dirs
    assert venv_line == "venv="
    assert "/usr/bin" in dirs or "/bin" in dirs  # the rest of PATH survives


def test_wait_returns_the_commands_status(isolated):
    r = slot("wait", "--free", "--interval", "0.1", "--", "sh", "-c", "exit 7")
    assert r.returncode == 7


def test_wait_holds_while_another_session_has_the_slot_then_runs_when_released(isolated):
    granted("alpha")
    mark = isolated / "ran"
    p = wait_bg("--free", "--interval", "0.1", "--", "sh", "-c", f"touch {mark}")
    time.sleep(1.5)
    assert p.poll() is None and not mark.exists(), "the command ran while another session held the slot"
    assert slot("release", "alpha", "--as", "alpha").returncode == 0
    assert p.wait(timeout=20) == 0 and mark.exists()


def test_wait_holds_while_the_load_is_high_then_runs_when_it_falls(isolated):
    lf = isolated / "load"
    lf.write_text("9.5 9 9\n")
    mark = isolated / "ran"
    p = wait_bg("--free", "--load", "8", "--interval", "0.1", "--", "sh", "-c", f"touch {mark}",
                env={"FLEET_SLOT_LOAD": str(lf)})
    time.sleep(1.5)
    assert p.poll() is None and not mark.exists(), "the command ran at a load above the limit"
    lf.write_text("3.0 5 6\n")
    assert p.wait(timeout=20) == 0 and mark.exists()


def test_wait_steady_needs_the_conditions_to_hold_for_that_long(isolated):
    lf = isolated / "load"
    lf.write_text("1.0\n")
    t0 = time.monotonic()
    r = slot("wait", "--free", "--load", "8", "--steady", "1.5", "--interval", "0.1",
             env={"FLEET_SLOT_LOAD": str(lf)})
    assert r.returncode == 0 and time.monotonic() - t0 >= 1.5


def test_wait_times_out_with_exit_3_naming_the_holder(isolated):
    granted("alpha")
    r = slot("wait", "--free", "--timeout", "0.5", "--interval", "0.1", "--", "sh", "-c", "echo ran")
    assert r.returncode == 3 and "held by alpha" in r.stderr and "ran" not in r.stdout


def test_wait_without_free_accepts_the_callers_own_slot(isolated):
    granted("alpha")
    r = slot("wait", "--as", "alpha", "--timeout", "2", "--interval", "0.1", "--", "sh", "-c", "echo ran")
    assert r.returncode == 0 and r.stdout.strip() == "ran", r.stderr
    r = slot("wait", "--free", "--as", "alpha", "--timeout", "0.5", "--interval", "0.1")
    assert r.returncode == 3


def test_wait_usage_errors(isolated):
    assert slot("wait", "--load", "x").returncode == 2
    assert slot("wait", "--timeout", "-1").returncode == 2
    assert slot("wait", "--").returncode == 2
    assert slot("wait", "extra").returncode == 2


def test_unknown_command_and_option_are_usage_errors(isolated):
    assert slot("frob").returncode == 2
    assert slot("status", "--frob").returncode == 2
    assert slot().returncode == 2


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))
