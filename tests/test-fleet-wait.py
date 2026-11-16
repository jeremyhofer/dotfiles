#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for fleet-wait. Every file it reads is under a temp dir (FLEET_STATE, FLEET_SLOT_STATE, the
config), and the CI read is a stub (FLEET_WAIT_CI_CMD), so nothing touches the machine's real fleet
state or the CI node. fleet-wait runs as a subprocess, the way a session meets it: each event case
starts a wait, waits for its first line (the baseline is taken by then), plants one change, and
expects the wait to end on it well before its heartbeat."""
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_fleet-wait"

CI_STUB = """#!/bin/sh
[ -f "$CI_FAIL" ] && { echo 'ci-trigger: ssh never reached the node' >&2; exit 1; }
cat "$CI_OUT"
"""


class Fleet:
    def __init__(self, tmp):
        self.tmp, self.state = tmp, tmp / "state"

    def ci(self, run, status):
        (self.tmp / "ci.out").write_text(f"run:    {run}\nstatus: {status}\n{{}}\n")

    def snapshot(self, seats, age=0):
        (self.state / "sessions.json").write_text(json.dumps(
            {"version": 1, "takenAt": int(time.time()) - age, "seats": {n: {"state": s} for n, s in seats.items()}}))

    def slot(self, holder, queue):
        (self.state / "slot" / "slot.json").write_text(json.dumps(
            {"holder": holder, "queue": [{"name": n, "at": 0, "minutes": 5, "what": "x", "by": n} for n in queue]}))

    def result(self, rid, outcome):
        (self.state / "requests" / f"{rid}.result.json").write_text(json.dumps({"id": rid, "outcome": outcome}))


@pytest.fixture
def fl(tmp_path, monkeypatch):
    f = Fleet(tmp_path)
    for d in ("requests", "handoff-staging", "slot"):
        (f.state / d).mkdir(parents=True)
    stub = tmp_path / "ci-stub"
    stub.write_text(CI_STUB)
    stub.chmod(0o755)
    env = {"FLEET_STATE": str(f.state), "FLEET_SLOT_STATE": str(f.state / "slot"),
           "FLEET_CANONICALS_CONFIG": str(tmp_path / "config"), "FLEET_WAIT_CI_CMD": str(stub),
           "CI_OUT": str(tmp_path / "ci.out"), "CI_FAIL": str(tmp_path / "ci.fail")}
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    # Who the heartbeat is for: named by FLEET_SLOT_AS, with no session id so the usage file and the
    # agents listing are never consulted.
    monkeypatch.delenv("CLAUDE_CODE_SESSION_ID", raising=False)
    monkeypatch.setenv("FLEET_SLOT_AS", "alpha-canonical")
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    f.ci("run-1", "running")
    f.snapshot({"alpha-canonical": "live", "beta-canonical": "live", "gamma-canonical": "dead"})
    f.slot(None, [])
    return f


def start(*args):
    # stdout alone: what the tool prints there is the contract. stderr may carry the runner's own
    # warnings (uv warned of a deprecated variable on a work Mac and failed every comparison).
    p = subprocess.Popen([str(TOOL), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         env=dict(os.environ))
    header = p.stdout.readline()
    assert header.startswith("fleet-wait: watching"), header
    return p, header


def finish(p, timeout=8):
    out, _err = p.communicate(timeout=timeout)
    return p.returncode, out.strip()


def run(*args, timeout=30):
    p = subprocess.run([str(TOOL), *args], capture_output=True, text=True, timeout=timeout, env=dict(os.environ))
    return p.returncode, p.stdout.strip()


FAST = ("--heartbeat", "20s", "--interval", "0.2s")


# ---- the heartbeat, and no early exit ----------------------------------------------------------

def test_heartbeat_fires_at_the_deadline_and_not_before(fl):
    t = time.monotonic()
    rc, out = run("--heartbeat", "2s", "--interval", "0.3s")
    took = time.monotonic() - t
    assert rc == 0 and out.splitlines()[-1] == "heartbeat 2s" and took >= 2, (rc, out, took)


def test_unrelated_rewrites_are_not_events(fl):
    """A waiting result rewritten with the same outcome, the slot queue while it is held, and a
    seat that was already dead: none ends the wait, which then runs to its heartbeat."""
    fl.result("r1", "waiting")
    p, _ = start("--heartbeat", "2s", "--interval", "0.2s")
    time.sleep(0.5)
    fl.result("r1", "waiting")
    fl.slot("alpha-canonical", ["beta-canonical"])
    fl.snapshot({"alpha-canonical": "live", "beta-canonical": "live"})
    rc, out = finish(p)
    assert rc == 0 and out == "heartbeat 2s", (rc, out)


# ---- each event, planted -----------------------------------------------------------------------

def test_a_new_request_result_is_an_event(fl):
    p, _ = start(*FAST)
    fl.result("r-new", "done")
    assert finish(p) == (0, "event request-result r-new done")


def test_a_changed_outcome_is_an_event(fl):
    fl.result("r1", "waiting")
    p, _ = start(*FAST)
    fl.result("r1", "done")
    assert finish(p) == (0, "event request-result r1 done")


def test_a_slot_request_queued_while_free_is_an_event(fl):
    p, _ = start(*FAST)
    fl.slot(None, ["keystone-groove-canonical"])
    assert finish(p) == (0, "event slot-queued keystone-groove-canonical")


def test_the_slot_coming_free_with_a_queue_is_an_event(fl):
    fl.slot("alpha-canonical", ["beta-canonical"])
    p, _ = start(*FAST)
    fl.slot(None, ["beta-canonical"])
    assert finish(p) == (0, "event slot-queued beta-canonical")


def test_the_same_queue_returning_after_a_grant_and_a_release_is_an_event(fl):
    """Armed while a request waited on a free slot: the grant, the release, and the same holder
    queuing again leave the slot as it was at the start, yet it is a new request nobody has seen.
    Compared against the start alone it read as no change, and the request waited unseen until the
    heartbeat (measured 2026-11-15, 18:42 to 19:12)."""
    fl.slot(None, ["beta-canonical"])
    p, _ = start(*FAST)
    time.sleep(0.5)
    fl.slot("beta-canonical", [])
    time.sleep(0.5)
    fl.slot(None, [])
    time.sleep(0.5)
    fl.slot(None, ["beta-canonical"])
    assert finish(p) == (0, "event slot-queued beta-canonical")


def test_a_staged_handoff_is_an_event(fl):
    p, _ = start(*FAST)
    (fl.state / "handoff-staging" / "2026-11-12-1930-x-park.md").write_text("x")
    assert finish(p) == (0, "event staged 2026-11-12-1930-x-park.md")


def test_a_live_seat_going_missing_is_an_event(fl):
    p, header = start(*FAST)
    assert "seats watched (2 live)" in header, header
    fl.snapshot({"alpha-canonical": "live", "beta-canonical": "dead", "gamma-canonical": "dead"})
    assert finish(p) == (0, "event seat-missing beta-canonical dead")


def test_a_live_seat_absent_from_the_snapshot_is_an_event(fl):
    p, _ = start(*FAST)
    fl.snapshot({"alpha-canonical": "live"})
    assert finish(p) == (0, "event seat-missing beta-canonical absent")


def test_a_snapshot_going_stale_is_an_event(fl):
    p, _ = start(*FAST)
    fl.snapshot({"alpha-canonical": "live", "beta-canonical": "live"}, age=100)
    rc, out = finish(p)
    assert rc == 0 and out.startswith("event snapshot-stale 10") and out.endswith("s"), (rc, out)


def test_a_stale_snapshot_at_the_start_is_said_and_not_watched(fl):
    fl.snapshot({"alpha-canonical": "live"}, age=100)
    p, header = start("--heartbeat", "1s", "--interval", "0.2s")
    assert "seats NOT watched (the snapshot was already older than 45s)" in header, header
    assert finish(p) == (0, "heartbeat 1s")


def test_a_snapshot_with_no_seats_is_watched_and_said(fl):
    """A machine with no seats declared has a readable, empty snapshot: not "no readable snapshot",
    and its going stale still ends the wait."""
    fl.snapshot({})
    p, header = start(*FAST)
    assert "seats watched (0 live; the snapshot names no seat for this machine)" in header, header
    fl.snapshot({}, age=100)
    rc, out = finish(p)
    assert rc == 0 and out.startswith("event snapshot-stale"), (rc, out)


def test_an_unreadable_snapshot_is_said(fl):
    (fl.state / "sessions.json").write_text("{not json")
    p, header = start("--heartbeat", "1s", "--interval", "0.2s")
    assert "seats NOT watched (no readable snapshot at" in header, header
    assert finish(p) == (0, "heartbeat 1s")


def test_snapshot_max_age_comes_from_the_config(fl):
    (fl.tmp / "config").write_text("snapshot-max-age = 200\n")
    fl.snapshot({"alpha-canonical": "live"}, age=100)
    p, header = start("--heartbeat", "1s", "--interval", "0.2s")
    assert "seats watched (1 live)" in header, header
    finish(p)


def test_a_ci_change_is_an_event(fl):
    p, header = start("--ci", "--ci-every", "0.2s", *FAST)
    assert "CI watched (run-1 running)" in header, header
    fl.ci("run-1", "passed")
    assert finish(p) == (0, "event ci run-1 passed")


def test_ci_is_polled_only_every_ci_every(fl):
    p, _ = start("--ci", "--ci-every", "10m", "--heartbeat", "2s", "--interval", "0.2s")
    fl.ci("run-2", "running")
    assert finish(p) == (0, "heartbeat 2s")


def test_an_unreachable_ci_is_said_at_the_start(fl):
    (fl.tmp / "ci.fail").write_text("")
    p, header = start("--ci", "--heartbeat", "1s", "--interval", "0.2s")
    assert "CI NOT watched: ci-trigger: ssh never reached the node" in header, header
    assert finish(p) == (0, "heartbeat 1s")


def test_without_ci_it_is_said_unwatched(fl):
    p, header = start("--heartbeat", "1s", "--interval", "0.2s")
    assert "CI not watched (no --ci)" in header, header
    finish(p)


def test_several_changes_print_one_line_each(fl):
    p, _ = start("--heartbeat", "20s", "--interval", "1s")
    fl.result("r-a", "done")
    (fl.state / "handoff-staging" / "h.md").write_text("x")
    rc, out = finish(p)
    assert rc == 0 and out.splitlines() == ["event request-result r-a done", "event staged h.md"], (rc, out)


# ---- --once, signals, usage --------------------------------------------------------------------

def test_once_with_no_change_exits_1(fl):
    assert run("--heartbeat", "30m", "--interval", "0.2s", "--once")[0] == 1


def test_once_with_a_change_exits_0(fl):
    p, _ = start("--heartbeat", "30m", "--interval", "1s", "--once")
    fl.result("r-once", "failed")
    assert finish(p) == (0, "event request-result r-once failed")


@pytest.mark.parametrize("sig", [signal.SIGTERM, signal.SIGINT])
def test_a_signal_ends_the_wait_cleanly(fl, sig):
    p, _ = start("--heartbeat", "30m", "--interval", "0.2s")
    time.sleep(0.3)
    p.send_signal(sig)
    rc, out = finish(p)
    assert rc == 0 and out == f"stopped ({sig.name})", (rc, out)


# ---- one heartbeat per holder ------------------------------------------------------------------

def rec(fl, holder="alpha-canonical"):
    return fl.state / "heartbeats" / f"{holder}.rec"


def plant_stale(fl, holder, age=3600):
    """A record whose wait died without cleaning up: the file is there and nobody holds its lock."""
    path = rec(fl, holder)
    path.parent.mkdir(exist_ok=True)
    path.write_text(f"holder: {holder}\nstarted: {time.time() - age}\nheartbeat: 1200.0\ninterval: 0.2\n")
    os.utime(path, (time.time() - age,) * 2)
    return path.read_text()


def lock_held(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def holder_pid(path):
    """The pid of the process holding the record's lock, from /proc/locks by inode (the python
    process, not the uv wrapper)."""
    ino = os.stat(path).st_ino
    for line in Path("/proc/locks").read_text().splitlines():
        f = line.split()
        if "FLOCK" in f and f[5].endswith(f":{ino}"):
            return int(f[4])
    raise AssertionError(f"no flock on inode {ino}")


def arm_as(holder, *args):
    env = dict(os.environ, FLEET_SLOT_AS=holder)
    p = subprocess.Popen([str(TOOL), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    assert p.stdout.readline().startswith("fleet-wait: watching")
    return p


def test_a_heartbeat_writes_its_record_and_removes_it_on_a_wake(fl):
    p, _ = start(*FAST)
    text = rec(fl).read_text()
    assert text.splitlines()[0] == "holder: alpha-canonical" and "interval: 0.2" in text, text
    fl.result("r-wake", "done")
    assert finish(p)[0] == 0
    assert not rec(fl).exists()


def test_a_heartbeat_removes_its_record_on_sigterm(fl):
    p, _ = start(*FAST)
    assert rec(fl).exists()
    p.send_signal(signal.SIGTERM)
    assert finish(p)[0] == 0
    assert not rec(fl).exists()


def test_a_heartbeat_removes_its_record_on_an_exception(fl):
    """A config that is not valid UTF-8 makes the tool raise after the record is written."""
    (fl.tmp / "config").write_bytes(b"\xff\xfe\x00")
    rc, _out = run(*FAST)
    assert rc not in (0, 2), rc
    assert not rec(fl).exists()


def test_a_second_heartbeat_for_the_same_holder_is_refused(fl):
    p, _ = start(*FAST)
    before = rec(fl).read_text()
    q = subprocess.run([str(TOOL), *FAST], capture_output=True, text=True, timeout=10, env=dict(os.environ))
    assert q.returncode == 2 and q.stdout == "", (q.returncode, q.stdout)
    assert q.stderr.startswith("fleet-wait: REFUSED: a heartbeat for alpha-canonical is already armed"), q.stderr
    assert rec(fl).read_text() == before
    fl.result("r-first", "done")
    assert finish(p) == (0, "event request-result r-first done")
    assert not rec(fl).exists()


def test_a_different_holder_is_not_refused(fl):
    p, _ = start(*FAST)
    q = arm_as("beta-canonical", *FAST)
    assert rec(fl, "beta-canonical").exists() and rec(fl).exists()
    fl.result("r-both", "done")
    assert finish(p)[0] == 0 and finish(q)[0] == 0


def test_a_record_with_no_lock_holder_does_not_refuse_and_is_replaced(fl):
    old = plant_stale(fl, "alpha-canonical")
    p, _ = start(*FAST)
    new = rec(fl).read_text()
    assert new != old and lock_held(rec(fl))
    p.send_signal(signal.SIGTERM)
    finish(p)


def test_a_sigkilled_heartbeat_is_taken_over_at_once(fl):
    """The kernel frees the lock when the holder dies by SIGKILL, with the record file left behind.
    The next wait for the same holder is not refused and takes the record over. The signal goes to
    the python process holding the lock, not the uv wrapper that launched it."""
    p, _ = start(*FAST)
    holder = holder_pid(rec(fl))
    old = rec(fl).read_text()
    os.kill(holder, signal.SIGKILL)
    for _ in range(50):
        if not lock_held(rec(fl)):
            break
        time.sleep(0.1)
    assert rec(fl).exists()  # SIGKILL ran no cleanup
    q, _ = start(*FAST)
    assert rec(fl).read_text() != old
    assert holder_pid(rec(fl)) != holder
    q.send_signal(signal.SIGTERM)
    finish(q)
    p.kill()
    p.communicate()


def test_the_record_is_refreshed_while_waiting(fl):
    p, _ = start(*FAST)
    os.utime(rec(fl), (time.time() - 5,) * 2)
    time.sleep(1.0)
    assert time.time() - os.path.getmtime(rec(fl)) < 2
    p.send_signal(signal.SIGTERM)
    finish(p)


def test_the_record_is_written_in_place_so_the_lock_stays_on_its_inode(fl):
    p, _ = start(*FAST)
    ino = os.stat(rec(fl)).st_ino
    time.sleep(0.8)
    assert os.stat(rec(fl)).st_ino == ino and lock_held(rec(fl))
    p.send_signal(signal.SIGTERM)
    finish(p)


def test_armed_lists_the_live_one_and_the_json_parses(fl):
    p, _ = start(*FAST)
    plant_stale(fl, "beta-canonical")
    rc, out = run("--armed")
    assert rc == 0 and "alpha-canonical" in out.split("stale")[0], out
    assert "stale" in out and "beta-canonical" in out.split("stale")[1], out
    rc, out = run("--armed", "--json")
    d = json.loads(out)
    assert rc == 0 and [r["holder"] for r in d["armed"]] == ["alpha-canonical"], d
    assert [r["holder"] for r in d["stale"]] == ["beta-canonical"], d
    p.send_signal(signal.SIGTERM)
    finish(p)


def test_armed_with_nothing_armed(fl):
    assert run("--armed") == (0, "armed: none")
    assert json.loads(run("--armed", "--json")[1]) == {"armed": [], "stale": []}


def test_once_writes_no_record(fl):
    p, _ = start("--heartbeat", "30m", "--interval", "1s", "--once")
    assert not rec(fl).exists() and not (fl.state / "heartbeats").exists()
    fl.result("r-once2", "failed")
    finish(p)


def test_an_unresolved_holder_is_said_in_the_records_first_line(fl, monkeypatch):
    monkeypatch.delenv("FLEET_SLOT_AS")
    p, _ = start(*FAST)
    (path,) = list((fl.state / "heartbeats").glob("unresolved-*.rec"))
    assert "UNRESOLVED" in path.read_text().splitlines()[0]
    p.send_signal(signal.SIGTERM)
    finish(p)


@pytest.mark.parametrize("args", [(), ("--heartbeat",), ("--heartbeat", "soon"), ("--heartbeat", "0"),
                                  ("--heartbeat", "1m", "--frob"), ("--heartbeat", "1m", "--interval", "-1")])
def test_usage_errors_exit_2(fl, args):
    assert run(*args)[0] == 2


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))
