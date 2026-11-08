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


@pytest.fixture(autouse=True)
def isolated(monkeypatch, tmp_path):
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


def test_unknown_command_and_option_are_usage_errors(isolated):
    assert slot("frob").returncode == 2
    assert slot("status", "--frob").returncode == 2
    assert slot().returncode == 2


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))
