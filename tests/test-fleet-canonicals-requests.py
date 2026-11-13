#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2", "pytest-xdist==3.8.0"]
# ///
"""Tests for `fleet-canonicals request` and `fleet-canonicals serve-requests`, the lifecycle request
queue, and for the session snapshot the same implementation writes (private_dot_local/bin/
executable_fleet-canonicals-queue, run through executable_fleet-canonicals).

Run: sh tests/run-all.sh --only test-fleet-canonicals-requests.py
 or: uv run --script tests/test-fleet-canonicals-requests.py [-k <pattern>]

THE RUNNER'S CHECKS ARE ITS CONTAINMENT. It runs outside every sandbox, on a file anyone with write
access to the queue can write, so every check has a PLANTED request it must refuse and a CONTROL the
same check lets through. A test names the check it plants against in its label (the `check` field of
the result file). Do not weaken a refusal case to a control-only case: the refusal is the point.

Nothing here reaches a real session or real state. The fleet record, the state directory, the
sessions listing, the transcripts, the usage files, the pid records, /proc, the trust check and the
`claude` binary are fixtures under one scratch directory; the `claude` stub records what it was asked.

HOW THIS RUNS FAST (the shell suite it replaced took two minutes)
=================================================================
* In parallel. The cases share nothing: each has its own state, queue, listing and config. pytest-xdist
  runs them on several workers (-n, set in the entry point at the end of this file).
* Without a process per call to the queue. Most cases load the queue file as a Python module
  (importlib, as the image-bump suite does) and call its `cmd_request` / `cmd_serve` with the
  environment a run would have; the module reads its paths from the environment when it is loaded,
  so each case loads its own copy. The queue still runs the real `fleet-decl`, `hostname`, the
  `claude` stub and the real `fleet-canonicals` verbs (up, down, refresh) as processes, exactly as
  the runner does; only the interpreter start of `bash -> uv run --script -> python` is skipped.
* A virtual clock where a case waited for time to pass (a waiting request's `since`), and a
  respawn wait of 0 where a case waited for a process that never comes.

WHAT IN-PROCESS CANNOT SEE: the layer between the machine and the queue. CONTRACT tests
(`test_contract_*`) run the real chain `bash fleet-canonicals -> uv run --script -> queue` as
processes: the verbs a user types, the PATH a launched session receives, the runner lock, `--loop`
and its signals.

PARITY AND MUTANTS
==================
Each check of the shell suite is kept: its label is the message of the assertion that replaced it,
and tests/test-fleet-canonicals-requests.parity.md maps every label to a pytest id.

A MUTANT is a copy of the queue with one exact find-and-replace that disables one check on purpose.
MUTANTS (at the end of this file) lists each with the test that must fail against it; the meta-test
runs that test against that copy in a child pytest, via FLEET_CANONICALS_QUEUE (the variable
`fleet-canonicals` itself reads to find the queue, and that the cases here use to load it). A check
whose test has never been seen to fail is of unknown value; the table is how each is seen to fail.
The mutants run only in the landing lane (RUN_MUTANTS=1, tests/land-gate.sh); a normal run through
this file's own entry point deselects the tests marked `mutant`.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
BIN = HERE.parent / "private_dot_local" / "bin"
TOOL = BIN / "executable_fleet-canonicals"
DECL = BIN / "executable_fleet-decl"
# The meta-test points FLEET_CANONICALS_QUEUE at a mutated copy of the queue (see MUTANTS).
QUEUE_SRC = Path(os.environ.get("FLEET_CANONICALS_QUEUE") or BIN / "executable_fleet-canonicals-queue")
# $TMPDIR as the machine gives it, read before any test changes it. Not resolved: the shell suite
# used it as given, and that is how macOS's /var symlink reaches the code under test.
ORIGINAL_TMP = tempfile.gettempdir()
HOST = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip() or socket.gethostname()
FAKE_PID = 4999991  # above any pid_max, so a stop of it can never reach a real process
NOW_SOURCES = ("time",)


def _clean_path():
    """PATH without the directory of this interpreter: `uv run --script` puts its environment first,
    and the queue is meant to hand its children the caller's PATH without it."""
    own = os.path.realpath(os.path.dirname(sys.executable))
    parts = [d for d in os.environ.get("PATH", "").split(os.pathsep) if d and os.path.realpath(d) != own]
    return os.pathsep.join(parts)


CLEAN_PATH = _clean_path()


class Result:
    def __init__(self, status, out):
        self.status, self.out = status, out

    def __repr__(self):
        return "status %s\n%s" % (self.status, self.out)


# ================================================================= the world (once per worker)

CLAUDE_STUB = r"""#!/bin/sh
printf '%s\n' "$*" >> "$CLAUDE_LOG"
printf '%s\n' "$PATH" > "$CLAUDE_LOG.path"
case "$1" in
  respawn) jq --arg i "$2" 'map(if .id == $i then .state = "working" | .live = true else . end)' "$AGENTS" > "$AGENTS.n" && mv "$AGENTS.n" "$AGENTS"
           # A respawned session runs under the daemon, so its roster lists a worker for it, unless
           # the fixture says the respawn brought no process up.
           sid=$(jq -r --arg i "$2" '.[] | select(.id == $i) | .sessionId' "$AGENTS")
           [ -n "${RESPAWN_NO_PROCESS:-}" ] || { jq --arg sid "$sid" '.workers[$sid] = {pid: 1, sessionId: $sid}' "$ROSTER" > "$ROSTER.n" && mv "$ROSTER.n" "$ROSTER"; } ;;
  rm)      # The removed session's process exits too: drop its fixture pid records and /proc entries.
           sid=$(jq -r --arg i "$2" '.[] | select(.id == $i) | .sessionId' "$AGENTS")
           for r in "$FLEET_PID_RECORD_DIR"/*.json; do
             [ -f "$r" ] && [ "$(jq -r .sessionId "$r")" = "$sid" ] && { p=$(jq -r .pid "$r"); rm -f "$r"; rm -f "$FLEET_PROC_ROOT/$p/stat"; }
           done
           jq --arg i "$2" 'map(select(.id != $i))' "$AGENTS" > "$AGENTS.n" && mv "$AGENTS.n" "$AGENTS" ;;
esac
exit 0
"""
TRUST_STUB = """#!/bin/sh
cat "$TRUST_NAMES"; exit "$(cat "$TRUST_RC")"
"""
# A `sleep` that returns at once, for the one case that waits out a fixed fifteen-second loop.
FAST_SLEEP = "#!/bin/sh\nexit 0\n"

RECORD = """projects:
  alpha:
    scope: alpha
    canonical: alpha-canonical
    canonicalIdentity: "the canonical session for alpha"
    canonicalLaunchDir: alpha
    canonicalLaunchModel: opus
    canonicalMachines: [{host}]
  beta:
    scope: beta
    canonical: beta-canonical
    canonicalIdentity: "the canonical session for beta"
    canonicalLaunchDir: beta
    canonicalLaunchModel: opus
    canonicalMachines: [{host}]
  gamma:
    scope: gamma
    canonical: gamma-canonical
    canonicalIdentity: "the canonical session for gamma"
    canonicalLaunchDir: gamma
    canonicalLaunchModel: opus
    canonicalMachines: [{host}]
    leakPolicy: private
  director:
    scope: director
    canonical: director-canonical
    canonicalIdentity: "the director seat"
    canonicalLaunchDir: director
    canonicalLaunchModel: opus
    canonicalMachines: [{host}]
  elsewhere:
    scope: elsewhere
    canonical: elsewhere-canonical
    canonicalIdentity: "a canonical another machine runs"
    canonicalLaunchDir: elsewhere
    canonicalLaunchModel: opus
    canonicalMachines: [some-other-host]
"""


def _write_exe(path, text):
    path.write_text(text)
    path.chmod(0o755)


@pytest.fixture(scope="session", autouse=True)
def world():
    """What every case only reads, made once per worker: the fleet record, the stubs, a launch
    directory and a handoff file per seat, and a handoff POINTER per seat recorded by the real
    `fleet-canonicals handoff --set` (a case copies the pointers into its own state directory)."""
    if not shutil.which("jq"):
        pytest.fail("jq is required")
    s = Path(tempfile.mkdtemp(prefix="fcq-world-", dir=ORIGINAL_TMP))
    (s / "bin").mkdir()
    os.symlink(DECL, s / "bin" / "fleet-decl")
    _write_exe(s / "bin" / "claude-stub", CLAUDE_STUB)
    _write_exe(s / "bin" / "trust-stub", TRUST_STUB)
    (s / "fast").mkdir()
    _write_exe(s / "fast" / "sleep", FAST_SLEEP)
    (s / "rec.yaml").write_text(RECORD.format(host=HOST))
    (s / "state-template").mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("FLEET_", "CLAUDE_"))}
    env.update(FLEET_STATE=str(s / "state-template"), PATH=str(s / "bin") + os.pathsep + CLEAN_PATH)
    for n in ("alpha", "beta", "gamma", "director"):
        (s / n).mkdir()
        (s / (n + ".handoff.md")).write_text("handoff for %s\n" % n)
        p = subprocess.run(["bash", str(TOOL), "handoff", n + "-canonical", "--set", str(s / (n + ".handoff.md"))],
                           env=env, capture_output=True, text=True)
        assert p.returncode == 0, p.stdout + p.stderr
    yield s
    shutil.rmtree(s, ignore_errors=True)


def load_queue(path=None):
    """The queue file as a module. It reads its paths from the environment as it is loaded."""
    path = path or QUEUE_SRC
    loader = importlib.machinery.SourceFileLoader("fleet_canonicals_queue", str(path))
    spec = importlib.util.spec_from_loader("fleet_canonicals_queue", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class Fleet:
    """One case's world: a state directory, queue, sessions listing, config and so on, all new."""

    def __init__(self, root, world, monkeypatch):
        self.T, self.S, self.mp = root, world, monkeypatch
        T = root
        self.state = T / "state"
        self.Q = self.state / "requests"
        self.audit = self.state / "requests-audit.jsonl"
        self.config = T / "config"
        self.agents = T / "agents.json"
        self.log = T / "claude.log"
        self.roster = T / "roster.json"
        self.pids, self.proc, self.jobs = T / "pids", T / "proc", T / "jobs"
        self.transcripts = T / "transcripts" / "p"
        self.usage = T / "run" / "claude-usage"
        self.trust_rc, self.trust_names = T / "trust.rc", T / "trust.names"
        self.snap = self.state / "sessions.json"
        for d in (self.transcripts, self.usage, self.pids, self.proc, T / "tmproots", T / "home"):
            d.mkdir(parents=True, exist_ok=True)
        shutil.copytree(world / "state-template", self.state)
        self.config.write_text("")
        self.log.write_text("")
        self.agents.write_text("[]")
        self.roster.write_text('{"workers":{}}')
        self.trust_rc.write_text("0\n")
        self.trust_names.write_text("")
        for k in [k for k in os.environ if k.startswith(("FLEET_", "CLAUDE_"))]:
            monkeypatch.delenv(k)
        env = {
            "HOME": T / "home", "XDG_STATE_HOME": T / "xdg-state", "XDG_CONFIG_HOME": T / "xdg-config",
            "FLEET_RECORD": world / "rec.yaml", "FLEET_DEVEL_ROOT": world, "FLEET_ROOT": world,
            "FLEET_STATE": self.state, "FLEET_TMPROOT_PREFIX": T / "tmproots",
            "FLEET_HANDOFFS_SEARCH": world, "FLEET_TRANSCRIPT_DIR": T / "transcripts",
            "XDG_RUNTIME_DIR": T / "run", "FLEET_CANONICALS_CONFIG": self.config,
            "FLEET_RESPAWN_WAIT": "0",
            "FLEET_PID_RECORD_DIR": self.pids, "FLEET_PROC_ROOT": self.proc, "FLEET_JOBS_DIR": self.jobs,
            "FLEET_DAEMON_ROSTER": self.roster, "ROSTER": self.roster,
            "FLEET_AGENTS_JSON_CMD": "jq -c map(select(.live)) %s" % self.agents,
            "FLEET_AGENTS_JSON_ALL_CMD": "cat %s" % self.agents,
            "CLAUDE_LOG": self.log, "AGENTS": self.agents,
            "FLEET_CLAUDE_CMD": world / "bin" / "claude-stub",
            "FLEET_TRUST_CHECK_CMD": world / "bin" / "trust-stub",
            "TRUST_NAMES": self.trust_names, "TRUST_RC": self.trust_rc,
            "FLEET_CANONICALS_BIN": "bash %s" % TOOL, "FLEET_CANONICALS_QUEUE": QUEUE_SRC,
            "PATH": str(world / "bin") + os.pathsep + CLEAN_PATH,
        }
        for k, v in env.items():
            monkeypatch.setenv(k, str(v))
        self.path = env["PATH"]
        self.q = load_queue()

    # ---- running things
    def call(self, fn, *args):
        """Run a function of the queue module in this process; its exit becomes a status."""
        out, err = io.StringIO(), io.StringIO()
        status = 0
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                status = fn(*args) or 0
            except SystemExit as e:
                status = e.code if isinstance(e.code, int) else 1
        return Result(status, out.getvalue() + err.getvalue())

    def request(self, *argv):
        return self.call(self.q.cmd_request, list(argv))

    def serve(self):
        """One pass of the runner, in this process. Returns what it printed."""
        r = self.call(self.q.cmd_serve, [])
        assert r.status == 0, r
        return r.out

    def snapshot(self):
        return self.call(self.q.cmd_snapshot, [])

    def fc(self, *args, env=None, timeout=300):
        """The real `fleet-canonicals` as a process; stdout and stderr together, as 2>&1 had them."""
        p = subprocess.run(["bash", str(TOOL), *map(str, args)], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout,
                           env=dict(os.environ, **(env or {})))
        return Result(p.returncode, p.stdout)

    # ---- the queue
    def queued(self):
        return sorted(self.Q.glob("*.request.json")) if self.Q.is_dir() else []

    def plant(self, rid, verb, name, requester, age=0):
        """Write a request file directly, as a sandboxed writer could, bypassing every check
        `request` makes, so only the runner stands between it and the verb."""
        self.Q.mkdir(parents=True, exist_ok=True)
        (self.Q / (rid + ".request.json")).write_text(json.dumps(
            {"id": rid, "time": int(time.time()) - age, "verb": verb, "name": name,
             "reason": "test", "requester": requester}))

    def result_doc(self, rid):
        try:
            return json.loads((self.Q / (rid + ".result.json")).read_text())
        except (OSError, ValueError):
            return {}

    def result(self, rid, key):
        return self.result_doc(rid).get(key) or ""

    def expect(self, rid, outcome, check, label):
        got = (self.result(rid, "outcome"), self.result(rid, "check"))
        assert got == (outcome, check), "%s (outcome %r, check %r; wanted %r, %r): %s" % (
            label, got[0], got[1], outcome, check, self.result_doc(rid))

    def set_config(self, text):
        self.config.write_text(text + "\n")

    def audit_lines(self):
        return [json.loads(l) for l in self.audit.read_text().splitlines()] if self.audit.exists() else []

    def add_audit(self, **entry):
        with open(self.audit, "a") as fh:
            fh.write(json.dumps(entry) + "\n")

    def claude_calls(self):
        return self.log.read_text()

    # ---- the sessions listing, transcripts, pid records, roster
    def _rows(self):
        return json.loads(self.agents.read_text())

    def live_row(self, rid, name, state, session, **extra):
        rows = self._rows()
        rows.append(dict({"id": rid, "name": name, "state": state, "sessionId": session, "cwd": "/x",
                          "kind": "background", "startedAt": 1000, "live": True}, **extra))
        self.agents.write_text(json.dumps(rows))

    def done_row(self, rid, name, session):
        """A row that is not live: the live listing leaves it out, the full one has it."""
        rows = self._rows()
        rows.append({"id": rid, "name": name, "state": "done", "sessionId": session, "cwd": "/x",
                     "kind": "background", "startedAt": 1000})
        self.agents.write_text(json.dumps(rows))

    def stopped_row(self, rid, name):
        self.done_row(rid, name, "x")

    def edit_rows(self, fn):
        rows = self._rows()
        for r in rows:
            fn(r)
        self.agents.write_text(json.dumps(rows))

    def transcript(self, session, kind):
        lines = [{"type": "user", "message": {"role": "user", "content": "go"}, "timestamp": "2026-11-08T01:00:00Z"}]
        if kind == "ended":
            lines += [{"type": "assistant", "message": {"role": "assistant", "stop_reason": "end_turn"},
                       "timestamp": "2026-11-08T01:00:05Z"},
                      {"type": "system", "subtype": "turn_duration", "timestamp": "2026-11-08T01:00:06Z"},
                      {"type": "last-prompt"}]
        else:
            lines += [{"type": "assistant", "message": {"role": "assistant", "stop_reason": "tool_use"},
                       "timestamp": "2026-11-08T01:00:05Z"},
                      {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result"}]},
                       "timestamp": "2026-11-08T01:00:09Z"}]
        (self.transcripts / (session + ".jsonl")).write_text("".join(json.dumps(l) + "\n" for l in lines))

    def future_transcript(self, session):
        """A transcript that began in 2099, so no recorded handoff is newer than the session."""
        lines = [{"type": "user", "message": {"role": "user", "content": "go"}, "timestamp": "2099-01-01T00:00:00Z"},
                 {"type": "system", "subtype": "turn_duration", "timestamp": "2099-01-01T00:00:06Z"}]
        (self.transcripts / (session + ".jsonl")).write_text("".join(json.dumps(l) + "\n" for l in lines))

    def roster_worker(self, session):
        d = json.loads(self.roster.read_text())
        d["workers"][session[:8]] = {"pid": 1, "sessionId": session}
        self.roster.write_text(json.dumps(d))

    def pid_record(self, pid, name, procstart):
        """A Claude Code per-process record naming a canonical (its process is not alive until
        `proc_alive` gives it a /proc entry)."""
        (self.pids / ("%s.json" % pid)).write_text(json.dumps(
            {"pid": pid, "sessionId": "s", "kind": "bg", "name": name, "procStart": procstart, "status": "idle"}))

    def proc_alive(self, pid, start):
        """A /proc/<pid>/stat whose field 22 is `start`."""
        (self.proc / str(pid)).mkdir(parents=True, exist_ok=True)
        (self.proc / str(pid) / "stat").write_text("%s (claude) S 1 1 1 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 1 0 %s 1000 100\n" % (pid, start))

    def pid_for(self, pid, name, session, status):
        """A live pid record for a session: the record and its /proc entry."""
        (self.pids / ("%s.json" % pid)).write_text(json.dumps(
            {"pid": pid, "sessionId": session, "kind": "bg", "name": name, "procStart": "555", "status": status}))
        (self.proc / str(pid)).mkdir(parents=True, exist_ok=True)
        (self.proc / str(pid) / "stat").write_text("%s (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 555 1 1\n" % pid)

    def set_handoff(self, name, target):
        r = self.fc("handoff", name, "--set", target)
        assert r.status == 0, r

    def write_snapshot(self, age, name, state, why="fixture", **extra):
        seat = dict({"state": state, "why": why}, **extra)
        self.snap.write_text(json.dumps({"version": 1, "takenAt": int(time.time()) - age, "seats": {name: seat}}))

    def snap_seat(self, name):
        try:
            return json.loads(self.snap.read_text())["seats"][name]["state"]
        except (OSError, ValueError, KeyError):
            return "absent"


@pytest.fixture
def fleet(world, monkeypatch):
    root = Path(tempfile.mkdtemp(prefix="fcq-test-", dir=ORIGINAL_TMP))
    monkeypatch.chdir(root)
    yield Fleet(root, world, monkeypatch)
    shutil.rmtree(root, ignore_errors=True)


def audit_for(fl, rid):
    return [a for a in fl.audit_lines() if a.get("id") == rid]


# ================================================================= request

def test_request_queues_one_file(fleet):
    """Through the real chain: the verb a user types."""
    r = fleet.fc("request", "up", "alpha-canonical", "--reason", "start of day", "--as", "alpha-canonical")
    files = fleet.queued()
    assert r.status == 0 and len(files) == 1, "request queues one file (rc=%s): %s" % (r.status, r.out)
    doc = json.loads(files[0].read_text())
    assert [doc[k] for k in ("verb", "name", "requester", "reason")] == ["up", "alpha-canonical", "alpha-canonical", "start of day"], \
        "the request records verb, name, requester and reason: %s" % doc
    assert 0 <= time.time() - doc["time"] < 30, "the request records when it was written"
    assert not list(fleet.Q.glob(".tmp-*")), "request leaves no temp file behind (written then renamed)"


@pytest.mark.parametrize("verb", ["dedupe", "clean", "place"])
def test_request_refuses_verb(fleet, verb):
    r = fleet.request(verb, "alpha-canonical", "--reason", "x", "--as", "alpha-canonical")
    assert r.status != 0 and not fleet.queued(), "request refuses verb '%s': %s" % (verb, r.out)


@pytest.mark.parametrize("flag", ["--force", "--stub"])
def test_request_refuses_flag(fleet, flag):
    r = fleet.request("refresh", "alpha-canonical", "--reason", "x", "--as", "alpha-canonical", flag)
    assert r.status != 0 and "never accepted" in r.out and not fleet.queued(), \
        "request refuses %s (rc=%s): %s" % (flag, r.status, r.out)


def test_request_refuses_a_canonical_declared_for_another_machine(fleet):
    r = fleet.request("up", "elsewhere-canonical", "--reason", "x", "--as", "alpha-canonical")
    assert r.status != 0 and "not declared for this machine" in r.out, \
        "request refuses a canonical declared for another machine (rc=%s): %s" % (r.status, r.out)


def test_request_refuses_an_undeclared_name(fleet):
    r = fleet.request("up", "nosuch-canonical", "--reason", "x", "--as", "alpha-canonical")
    assert r.status != 0 and not fleet.queued(), "request refuses an undeclared name: %s" % r.out


def test_request_requires_a_reason(fleet):
    r = fleet.request("up", "alpha-canonical", "--as", "alpha-canonical")
    assert r.status != 0 and "--reason" in r.out, "request requires --reason (rc=%s): %s" % (r.status, r.out)
    ok = fleet.request("up", "alpha-canonical", "--reason", "start of day", "--as", "alpha-canonical")
    assert ok.status == 0, "(control) the same request with a reason is queued: %s" % ok.out


def test_request_without_a_requester_is_refused(fleet):
    r = fleet.request("up", "alpha-canonical", "--reason", "x")
    assert r.status != 0 and "--as" in r.out, \
        "request refuses when the requester cannot be told and --as is absent (rc=%s): %s" % (r.status, r.out)


def test_request_never_touch_default(fleet):
    r = fleet.request("refresh", "director-canonical", "--reason", "x", "--as", "director-canonical")
    assert r.status != 0 and "never-touch" in r.out and not fleet.queued(), \
        "request refuses a never-touch canonical (the default list), and nothing lands (rc=%s): %s" % (r.status, r.out)


def test_request_never_touch_configured(fleet):
    fleet.set_config("never-touch = gamma-canonical")
    r = fleet.request("up", "director-canonical", "--reason", "x", "--as", "director-canonical")
    assert r.status == 0, "the never-touch list is the config's when the key is set (rc=%s): %s" % (r.status, r.out)
    r = fleet.request("up", "gamma-canonical", "--reason", "x", "--as", "director-canonical")
    assert r.status != 0 and "never-touch" in r.out, \
        "request refuses a configured never-touch name (rc=%s): %s" % (r.status, r.out)


SESSION = "11111111-2222-3333-4444-555555555555"


def _inside_beta(fleet, monkeypatch):
    (fleet.usage / (SESSION + ".json")).write_text(
        json.dumps({"session_id": SESSION, "session_name": "beta-canonical", "seven_day_pct": 1}))
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", SESSION)


def test_request_records_the_calling_sessions_name(fleet, monkeypatch):
    _inside_beta(fleet, monkeypatch)
    r = fleet.request("down", "beta-canonical", "--reason", "park")
    files = fleet.queued()
    assert r.status == 0 and files and json.loads(files[0].read_text())["requester"] == "beta-canonical", \
        "request records the calling session's canonical name as the requester (rc=%s): %s" % (r.status, r.out)


def test_request_as_cannot_contradict_the_calling_session(fleet, monkeypatch):
    _inside_beta(fleet, monkeypatch)
    r = fleet.request("down", "alpha-canonical", "--reason", "x", "--as", "director-canonical")
    assert r.status != 0 and "running inside 'beta-canonical'" in r.out, \
        "--as cannot name someone other than the calling session (rc=%s): %s" % (r.status, r.out)
    ok = fleet.request("down", "alpha-canonical", "--reason", "x", "--as", "beta-canonical")
    assert ok.status == 0, "(control) --as naming the calling session itself is accepted: %s" % ok.out


def test_request_refuses_a_second_request_for_a_queued_canonical(fleet):
    first = fleet.request("up", "gamma-canonical", "--reason", "x", "--as", "gamma-canonical")
    assert first.status == 0, "(control) the first request is queued: %s" % first.out
    r = fleet.request("up", "gamma-canonical", "--reason", "y", "--as", "gamma-canonical")
    assert r.status != 0 and "already queued" in r.out, \
        "request refuses a second request for a canonical already queued (rc=%s): %s" % (r.status, r.out)
    other = fleet.request("up", "alpha-canonical", "--reason", "y", "--as", "alpha-canonical")
    assert other.status == 0, "(control) a request for another canonical is not held up by it: %s" % other.out


# ================================================================= serve: the verb and the shape

def test_serve_a_valid_request_runs_its_verb(fleet):
    fleet.plant("r-ok", "up", "alpha-canonical", "alpha-canonical")
    out = fleet.serve()
    fleet.expect("r-ok", "done", "", "a valid up request is served: the verb runs")
    assert "--bg -n alpha-canonical" in fleet.claude_calls(), \
        "the served up launches through the verb, as declared: %s / %s" % (fleet.claude_calls(), out)
    assert (fleet.Q / "r-ok.served.json").is_file() and not (fleet.Q / "r-ok.request.json").exists(), \
        "a served request leaves the queue"
    assert "fleet-canonicals up alpha-canonical exited 0" in fleet.result("r-ok", "output"), \
        "the result carries the verb's output: %s" % fleet.result("r-ok", "output")
    last = fleet.audit_lines()[-1]
    assert [last.get(k) for k in ("id", "outcome", "verb", "name", "requester")] == \
        ["r-ok", "done", "up", "alpha-canonical", "alpha-canonical"], "an audit line is appended per request: %s" % last
    fleet.serve()
    assert len(fleet.audit_lines()) == 1, "a second pass serves nothing twice"


def test_serve_refuses_a_malformed_request_or_verb(fleet):
    fleet.plant("r-verb", "dedupe", "alpha-canonical", "alpha-canonical")
    fleet.plant("r-flag", "refresh --force", "alpha-canonical", "alpha-canonical")
    fleet.plant("r-name", "up", "--stub", "alpha-canonical")
    fleet.plant("r-space", "up", "alpha canonical", "alpha-canonical")
    (fleet.Q / "r-bad.request.json").write_text('{"id":"r-bad","verb":"up"}')
    (fleet.Q / "r-junk.request.json").write_text("not json")
    (fleet.Q / "r-time.request.json").write_text(json.dumps(
        {"id": "r-time", "time": "yesterday", "verb": "up", "name": "alpha-canonical", "reason": "test", "requester": "alpha-canonical"}))
    fleet.serve()
    fleet.expect("r-verb", "refused", "verb", "the runner refuses a verb outside the four")
    fleet.expect("r-flag", "refused", "verb", "the runner refuses --force smuggled into a verb")
    fleet.expect("r-name", "refused", "verb", "the runner refuses an option in place of a name")
    fleet.expect("r-space", "refused", "verb", "the runner refuses a name that is not a plain canonical name")
    fleet.expect("r-bad", "refused", "shape", "the runner refuses a request missing its fields")
    fleet.expect("r-junk", "refused", "shape", "the runner refuses a file that is not JSON")
    fleet.expect("r-time", "refused", "shape", "the runner refuses a request whose time is not an integer (new in the port)")
    assert fleet.claude_calls() == "", "no refused request reached claude: %s" % fleet.claude_calls()


def test_serve_paused(fleet):
    fleet.Q.mkdir(parents=True)
    (fleet.Q / "PAUSED").write_text("")
    fleet.plant("r-p", "up", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-p", "refused", "paused", "a PAUSED file refuses every request")
    (fleet.Q / "PAUSED").unlink()
    fleet.plant("r-p2", "up", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-p2", "done", "", "with PAUSED removed the same request runs")


def test_serve_age(fleet):
    fleet.plant("r-old", "up", "alpha-canonical", "alpha-canonical", 660)
    fleet.plant("r-young", "up", "beta-canonical", "beta-canonical", 540)
    fleet.serve()
    fleet.expect("r-old", "refused", "age", "a request older than ten minutes is refused as stale")
    fleet.expect("r-young", "done", "", "a request nine minutes old still runs")


def test_serve_age_follows_the_config(fleet):
    fleet.set_config("request-max-age = 30")
    fleet.plant("r-cfg", "up", "alpha-canonical", "alpha-canonical", 60)
    fleet.serve()
    fleet.expect("r-cfg", "refused", "age", "request-max-age in the config sets the limit")


def test_serve_age_refuses_a_request_dated_in_the_future(fleet):
    fleet.plant("r-future", "up", "alpha-canonical", "alpha-canonical", -3600)
    fleet.serve()
    fleet.expect("r-future", "refused", "age", "a request dated an hour ahead is refused (new in the port)")


def test_serve_never_touch(fleet):
    fleet.plant("r-dir", "refresh", "director-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-dir", "refused", "never-touch", "the runner refuses the never-touch canonical, whoever asks")
    fleet.set_config("never-touch =")
    fleet.plant("r-dir2", "up", "director-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-dir2", "done", "", "an empty never-touch list lets it through")


def test_serve_declared_for_this_machine(fleet):
    fleet.plant("r-else", "up", "elsewhere-canonical", "elsewhere-canonical")
    fleet.plant("r-none", "up", "nosuch-canonical", "nosuch-canonical")
    fleet.serve()
    fleet.expect("r-else", "refused", "declared", "the runner refuses a canonical declared for another machine")
    fleet.expect("r-none", "refused", "declared", "the runner refuses a name the record does not declare")


def test_serve_requester(fleet):
    fleet.plant("r-other", "up", "beta-canonical", "alpha-canonical")
    fleet.plant("r-dirq", "up", "gamma-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-other", "refused", "requester", "a canonical may not request another canonical's action")
    fleet.expect("r-dirq", "done", "", "the director may request any canonical's action (request-any default)")
    fleet.set_config("request-any = owner")
    fleet.plant("r-own", "up", "beta-canonical", "owner")
    fleet.serve()
    fleet.expect("r-own", "done", "", "request-any in the config names who may act on anyone")


def test_serve_self_refresh(fleet):
    fleet.plant("r-self", "refresh", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-self", "refused", "self-refresh", "a canonical's request to refresh itself is refused by default")
    fleet.set_config("allow-self-refresh = true")
    fleet.plant("r-self2", "refresh", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-self2", "done", "", "allow-self-refresh = true lets a self-refresh run, for the measurement")


def test_serve_self_down_is_allowed(fleet):
    fleet.plant("r-selfdown", "down", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-selfdown", "done", "", "a canonical may still request its own down")


def test_serve_one_per_canonical_queued(fleet):
    fleet.plant("r-a1", "up", "alpha-canonical", "alpha-canonical")
    fleet.plant("r-a2", "up", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-a1", "done", "", "of two requests for one canonical, the first queued runs")
    fleet.expect("r-a2", "refused", "one-per-canonical", "the second request for the same canonical is refused")


def test_serve_one_per_canonical_running(fleet):
    fleet.plant("r-run", "up", "alpha-canonical", "alpha-canonical")
    (fleet.Q / "r-run.request.json").rename(fleet.Q / "r-run.running.json")
    fleet.plant("r-b", "up", "alpha-canonical", "alpha-canonical")
    fleet.plant("r-c", "up", "beta-canonical", "beta-canonical")
    fleet.serve()
    fleet.expect("r-b", "refused", "one-per-canonical", "a request is refused while one for the same canonical is marked running")
    fleet.expect("r-c", "done", "", "another canonical's request is not held up by it")


# ================================================================= serve: rate limits

def test_serve_rate_per_canonical(fleet):
    now = int(time.time())
    for _ in range(3):
        fleet.add_audit(at=now - 600, name="alpha-canonical", outcome="done")
    for _ in range(3):  # the shell suite gave beta ONE old action, under the limit of 3 either way
        fleet.add_audit(at=now - 7200, name="beta-canonical", outcome="done")
    for _ in range(3):
        fleet.add_audit(at=now - 600, name="beta-canonical", outcome="refused")
    fleet.plant("r-rate", "up", "alpha-canonical", "alpha-canonical")
    fleet.plant("r-rate2", "up", "beta-canonical", "beta-canonical")
    fleet.serve()
    fleet.expect("r-rate", "refused", "rate", "a fourth action for one canonical within the hour is refused")
    fleet.expect("r-rate2", "done", "", "refused requests and actions over an hour old do not count")


def test_serve_rate_per_canonical_two_actions_are_under_the_limit(fleet):
    now = int(time.time())
    for _ in range(2):
        fleet.add_audit(at=now - 600, name="alpha-canonical", outcome="done")
    fleet.plant("r-rate3", "up", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-rate3", "done", "", "a third action within the hour is still allowed (the boundary under the limit; new in the port)")


def _ten_actions(fleet, names="abcdefghij"):
    now = int(time.time())
    for n in names:
        fleet.add_audit(at=now - 300, name="%s-canonical" % n, outcome="done")


def test_serve_rate_fleet(fleet):
    _ten_actions(fleet)
    fleet.plant("r-fleet", "up", "gamma-canonical", "gamma-canonical")
    fleet.serve()
    fleet.expect("r-fleet", "refused", "rate", "an eleventh action for the fleet within the hour is refused")
    fleet.set_config("request-limit-fleet = 20")
    fleet.plant("r-fleet2", "up", "gamma-canonical", "gamma-canonical")
    fleet.serve()
    fleet.expect("r-fleet2", "done", "", "request-limit-fleet in the config raises the fleet limit")


def _thirteen_seats(fleet):
    """With no key, the fleet limit scales with the seats the record declares for THIS machine:
    max(10, 2 x seats), so one refresh round plus one recovery per seat fits. A 13-seat machine gets
    26; ten actions in the hour, the old fixed default, must not stop its eleventh."""
    text = (fleet.S / "rec.yaml").read_text()
    for n in ("s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9"):
        text += ('  %s:\n    scope: %s\n    canonical: %s-canonical\n    canonicalIdentity: "%s"\n'
                 '    canonicalLaunchDir: %s\n    canonicalLaunchModel: opus\n    canonicalMachines: [%s]\n'
                 % (n, n, n, n, n, HOST))
    rec = fleet.T / "rec13.yaml"
    rec.write_text(text)
    fleet.mp.setenv("FLEET_RECORD", str(rec))
    p = subprocess.run([str(DECL), "--canonicals"], capture_output=True, text=True)
    assert len(p.stdout.split()) == 14, "the 13-seat fixture: %s" % p.stdout.split()


def test_serve_rate_fleet_scales_with_the_seats_declared_here(fleet):
    _thirteen_seats(fleet)
    _ten_actions(fleet)
    fleet.plant("r-fleet13", "up", "gamma-canonical", "gamma-canonical")
    fleet.serve()
    fleet.expect("r-fleet13", "done", "", "with 13 seats declared here, an eleventh action in the hour is not refused")


def test_serve_rate_fleet_limit_is_twice_the_seats(fleet):
    _thirteen_seats(fleet)
    now = int(time.time())
    for n in range(1, 27):
        fleet.add_audit(at=now - 300, name="x%d-canonical" % n, outcome="done")
    fleet.plant("r-fleet13b", "up", "gamma-canonical", "gamma-canonical")
    fleet.serve()
    fleet.expect("r-fleet13b", "refused", "rate", "...and its twenty-seventh is (26 = 2 x 13)")


# ================================================================= serve: init

def test_serve_init(fleet):
    """A never-launched seat, requested from inside a sandbox. Only a request-any requester can ask
    (the seat has no session to ask for itself), and the runner runs `init --up`, so it launches."""
    (fleet.state / "gamma-canonical.handoff").unlink()
    fleet.plant("r-init", "init", "gamma-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-init", "refused", "requester", "a canonical cannot request another seat's init")
    fleet.plant("r-init2", "init", "gamma-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-init2", "done", "", "a director's init request is served")
    pointer = fleet.fc("handoff", "gamma-canonical").out
    assert "--bg -n gamma-canonical" in fleet.claude_calls() and pointer.strip().endswith("first-launch.md"), \
        "the served init writes the first-launch handoff and launches the seat: %s / %s" % (fleet.claude_calls(), pointer)


# ================================================================= serve: usage and trust

def _usage_files(fleet, first, second, resets_first, resets_second):
    for name, pct, resets in (("a", first, resets_first), ("b", second, resets_second)):
        (fleet.usage / (name + ".json")).write_text(json.dumps(
            {"session_name": "x", "seven_day_pct": pct, "seven_day_resets_at": resets}))


def test_serve_usage(fleet):
    later = int(time.time()) + 86400
    _usage_files(fleet, 85, 12, later, later)
    fleet.plant("r-u1", "up", "alpha-canonical", "alpha-canonical")
    fleet.plant("r-u2", "refresh", "beta-canonical", "director-canonical")
    fleet.plant("r-u3", "down", "gamma-canonical", "gamma-canonical")
    fleet.serve()
    fleet.expect("r-u1", "refused", "usage", "up is refused at 85% of the 7-day window (the highest file wins)")
    fleet.expect("r-u2", "refused", "usage", "refresh is refused at the threshold too")
    fleet.expect("r-u3", "done", "", "down is never refused for usage")
    fleet.set_config("request-usage-exempt = alpha-canonical")
    fleet.plant("r-u4", "up", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-u4", "done", "", "a canonical on the exempt list may still be started")


def test_serve_usage_ignores_a_window_that_already_reset(fleet):
    now = int(time.time())
    _usage_files(fleet, 99, 84, now - 60, now + 86400)
    fleet.plant("r-u5", "up", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-u5", "done", "", "a usage file whose window already reset is not read as current")


def test_serve_trust(fleet):
    fleet.trust_rc.write_text("1\n")
    fleet.trust_names.write_text("beta\ngamma\n")
    fleet.plant("r-t1", "up", "beta-canonical", "beta-canonical")
    fleet.plant("r-t2", "up", "alpha-canonical", "alpha-canonical")
    fleet.plant("r-t3", "down", "gamma-canonical", "gamma-canonical")
    fleet.serve()
    fleet.expect("r-t1", "refused", "trust", "up is refused where claude-trust-check reports the directory untrusted")
    fleet.expect("r-t2", "done", "", "an untrusted neighbor does not refuse a trusted canonical")
    fleet.expect("r-t3", "done", "", "down needs no trust")


def test_serve_trust_unknown_state_fails_closed(fleet):
    fleet.trust_rc.write_text("3\n")
    fleet.plant("r-t4", "up", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-t4", "refused", "trust", "an unknown trust state refuses up (fail closed)")


# ================================================================= serve: working

def test_serve_working_waits_until_the_session_is_idle(fleet):
    fleet.live_row("aaaa1111", "alpha-canonical", "working", "s-alpha"); fleet.transcript("s-alpha", "ended")
    fleet.live_row("bbbb2222", "beta-canonical", "done", "s-beta"); fleet.transcript("s-beta", "working")
    fleet.live_row("cccc3333", "gamma-canonical", "done", "s-gamma"); fleet.transcript("s-gamma", "ended")
    fleet.plant("r-w1", "down", "alpha-canonical", "alpha-canonical")
    fleet.plant("r-w2", "refresh", "beta-canonical", "director-canonical")
    fleet.plant("r-w3", "down", "gamma-canonical", "gamma-canonical")
    fleet.serve()
    fleet.expect("r-w1", "waiting", "working", "down waits while the listing reports the session working")
    fleet.expect("r-w2", "waiting", "working", "refresh waits while the transcript's last turn has not ended")
    assert (fleet.Q / "r-w1.request.json").is_file() and (fleet.Q / "r-w2.request.json").is_file() \
        and not (fleet.Q / "r-w1.served.json").exists(), "a waiting request stays queued: %s" % sorted(p.name for p in fleet.Q.iterdir())
    fleet.expect("r-w3", "done", "", "down of an idle session whose turn ended runs")
    assert fleet.result("r-w3", "admitted") == "listed 'done'; its last turn ended", \
        "...its result names the listed state that admitted it: %s" % fleet.result("r-w3", "admitted")
    calls = fleet.claude_calls()
    assert "rm cccc3333" in calls and "aaaa1111" not in calls and "bbbb2222" not in calls, \
        "only the idle session's row was removed: %s" % calls
    # a waiting request is served once the session is idle, and waiting writes no audit line
    since = fleet.result("r-w2", "since")
    assert not any(a.get("outcome") == "waiting" for a in fleet.audit_lines()), "waiting is not in the audit log"
    # Two seconds pass on the runner's clock (the shell suite slept one), so a `since` that was
    # rewritten each pass would differ.
    real_now = fleet.q.now
    fleet.q.now = lambda: real_now() + 2
    fleet.serve()
    assert since and fleet.result("r-w2", "since") == since, \
        "a second waiting pass keeps when the wait began: '%s' -> '%s'" % (since, fleet.result("r-w2", "since"))
    fleet.q.now = real_now
    fleet.transcript("s-beta", "ended")
    fleet.serve()
    fleet.expect("r-w2", "done", "", "a waiting refresh is served once the transcript's turn has ended")
    fleet.expect("r-w1", "waiting", "working", "a request for a session still working keeps waiting")
    fleet.edit_rows(lambda r: r.update(state="idle") if r["id"] == "aaaa1111" else None)
    fleet.serve()
    fleet.expect("r-w1", "done", "", "a waiting down is served once the listing reports the session idle")
    assert len(audit_for(fleet, "r-w1")) == 1, \
        "a request that waited gets one audit line, when it is served: %s" % fleet.audit_lines()


def test_serve_a_waiting_request_past_max_age_is_refused_stale(fleet):
    fleet.set_config("allow-self-refresh = true")
    fleet.live_row("ffff6666", "alpha-canonical", "working", "s-alpha"); fleet.transcript("s-alpha", "ended")
    fleet.plant("r-w6", "refresh", "alpha-canonical", "alpha-canonical", 590)
    fleet.serve()
    fleet.expect("r-w6", "waiting", "working", "a self-refresh while working waits")
    fleet.plant("r-w6", "refresh", "alpha-canonical", "alpha-canonical", 700)
    fleet.serve()
    fleet.expect("r-w6", "refused", "age", "a waiting request past request-max-age is refused stale")
    detail = fleet.result("r-w6", "detail")
    assert "had waited since" in detail and "is working" in detail and not (fleet.Q / "r-w6.request.json").exists(), \
        "the stale refusal names the wait and consumes the request: %s" % detail


def test_serve_an_unreadable_transcript_refuses_a_stop(fleet):
    fleet.live_row("dddd4444", "alpha-canonical", "done", "s-missing")
    fleet.plant("r-w4", "down", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-w4", "refused", "working", "an unreadable transcript refuses a stop (fail closed)")


def test_serve_an_unreadable_sessions_list_refuses_a_stop(fleet):
    fleet.mp.setenv("FLEET_AGENTS_JSON_CMD", "false")
    fleet.plant("r-w5", "down", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-w5", "refused", "working", "an unreadable sessions list refuses a stop (fail closed)")


def test_serve_blocked_without_waiting_for_waits_and_says_so(fleet):
    fleet.live_row("bl000001", "alpha-canonical", "blocked", "s-bl"); fleet.transcript("s-bl", "ended"); fleet.roster_worker("s-bl")
    fleet.plant("r-bl", "down", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-bl", "waiting", "working", "a blocked session's stop waits")
    assert "no waitingFor" in fleet.result("r-bl", "detail"), \
        "the reason names a blocked state with no waitingFor: %s" % fleet.result("r-bl", "detail")


# parked signals: `blocked` with no waitingFor is idle only when the session's own pid record says
# idle AND its handoff was recorded after it started (the world records each handoff at its start)

def test_serve_parked_blocked_session_is_served(fleet):
    fleet.live_row("pk000001", "alpha-canonical", "blocked", "s-pk"); fleet.transcript("s-pk", "ended")
    fleet.pid_for(5101, "alpha-canonical", "s-pk", "idle")
    fleet.plant("r-pk1", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-pk1", "done", "", "blocked with no waitingFor, idle by its own record and parked since it started, is served")
    adm = fleet.result("r-pk1", "admitted")
    assert "'blocked'" in adm and "parked" in adm, "...its result says the parked path admitted it: %s" % adm


def test_serve_blocked_session_whose_record_is_busy_waits(fleet):
    fleet.live_row("pk000002", "alpha-canonical", "blocked", "s-pk"); fleet.transcript("s-pk", "ended")
    fleet.pid_for(5102, "alpha-canonical", "s-pk", "busy")
    (fleet.jobs / "pk000002").mkdir(parents=True)
    (fleet.jobs / "pk000002" / "state.json").write_text(json.dumps(
        {"state": "blocked", "tempo": "blocked", "needs": "Decide: footer basis"}))
    fleet.plant("r-pk2", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-pk2", "waiting", "working", "the same, but its own record says busy, still waits")
    detail = fleet.result("r-pk2", "detail")
    assert "not idle" in detail, "...and the reason says the session's record is not idle: %s" % detail
    assert "asked: Decide: footer basis" in detail, "...and quotes what its last turn asked: %s" % detail


def test_serve_blocked_session_parked_before_it_started_waits(fleet):
    fleet.live_row("pk000003", "alpha-canonical", "blocked", "s-un")
    fleet.pid_for(5103, "alpha-canonical", "s-un", "idle")
    fleet.future_transcript("s-un")
    fleet.plant("r-pk3", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-pk3", "waiting", "working", "idle but not parked since it started (its handoff is older) still waits")
    assert "before the session started" in fleet.result("r-pk3", "detail"), \
        "...and the reason says the handoff predates the session: %s" % fleet.result("r-pk3", "detail")


def test_serve_blocked_with_a_real_waiting_for_waits(fleet):
    fleet.live_row("pk000004", "alpha-canonical", "blocked", "s-pk", waitingFor="permission prompt")
    fleet.transcript("s-pk", "ended")
    fleet.pid_for(5104, "alpha-canonical", "s-pk", "idle")
    fleet.plant("r-pk4", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-pk4", "waiting", "working", "a blocked session with a real waitingFor still waits, parked or not")
    assert "waiting for permission prompt" in fleet.result("r-pk4", "detail"), \
        "...and the reason quotes its waitingFor: %s" % fleet.result("r-pk4", "detail")


# stopped and parked: `blocked` with no waitingFor and NO live process (the idle stop leaves the row
# listed) is served only when no live pid record holds the name, the daemon roster lists no worker
# for the session, and its handoff names a placed file recorded after the session started

def test_serve_stopped_and_parked_blocked_session_is_served(fleet):
    fleet.live_row("st000001", "alpha-canonical", "blocked", "s-st"); fleet.transcript("s-st", "ended")
    fleet.plant("r-st1", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-st1", "done", "", "blocked, no process, no roster worker, parked since it started: the refresh is served")


def test_serve_stopped_but_the_roster_lists_a_worker_waits(fleet):
    fleet.live_row("st000002", "alpha-canonical", "blocked", "s-st"); fleet.transcript("s-st", "ended"); fleet.roster_worker("s-st")
    fleet.plant("r-st2", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-st2", "waiting", "working", "the same, but the daemon roster lists a worker for it: waits")
    assert "roster lists a running worker" in fleet.result("r-st2", "detail"), \
        "...and the reason names the roster worker: %s" % fleet.result("r-st2", "detail")


def test_serve_stopped_but_a_live_pid_record_holds_the_name_waits(fleet):
    fleet.live_row("st000003", "alpha-canonical", "blocked", "s-st"); fleet.transcript("s-st", "ended")
    fleet.pid_for(5301, "alpha-canonical", "s-other", "idle")
    fleet.plant("r-st3", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-st3", "waiting", "working", "the same, but a live pid record holds the name: waits")
    assert "live process still holds the name" in fleet.result("r-st3", "detail"), \
        "...and the reason names the live process: %s" % fleet.result("r-st3", "detail")


def test_serve_stopped_but_never_parked_waits(fleet):
    fleet.live_row("st000004", "alpha-canonical", "blocked", "s-sx")
    fleet.future_transcript("s-sx")
    fleet.plant("r-st4", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-st4", "waiting", "working", "stopped, but its handoff predates the session (never parked): waits")
    assert "before the session started" in fleet.result("r-st4", "detail"), \
        "...and the reason says the handoff predates it: %s" % fleet.result("r-st4", "detail")


def test_serve_stopped_with_a_real_waiting_for_waits(fleet):
    fleet.live_row("st000005", "alpha-canonical", "blocked", "s-st", waitingFor="permission prompt")
    fleet.transcript("s-st", "ended")
    fleet.plant("r-st5", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-st5", "waiting", "working", "stopped and parked, but a real waitingFor: waits")


def test_serve_an_unreadable_roster_waits(fleet):
    fleet.live_row("st000006", "alpha-canonical", "blocked", "s-st"); fleet.transcript("s-st", "ended")
    fleet.roster.unlink()
    fleet.plant("r-st6", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-st6", "waiting", "working", "an unreadable daemon roster waits (fail closed)")
    detail = fleet.result("r-st6", "detail")
    assert "roster" in detail and "cannot be read" in detail, "...and the reason names the roster: %s" % detail


def test_serve_a_pointer_outside_the_placed_handoffs_waits(fleet):
    outside = fleet.T / "outside.md"
    outside.write_text("a draft\n")
    fleet.set_handoff("alpha-canonical", outside)
    fleet.live_row("st000007", "alpha-canonical", "blocked", "s-st"); fleet.transcript("s-st", "ended")
    fleet.plant("r-st7", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-st7", "waiting", "working", "stopped, but the pointer names a file outside the placed handoffs: waits")
    assert "not under the placed handoffs" in fleet.result("r-st7", "detail"), \
        "...and the reason says it is not a placed copy: %s" % fleet.result("r-st7", "detail")


def test_serve_refresh_fails_loudly_when_another_process_still_holds_the_name(fleet):
    """After the stop, a live process that still holds the name is waited for, then refused loudly,
    rather than handed to a launch that would refuse halfway through. `refresh` waits fifteen
    iterations of `sleep 1` for that; the case runs it with a `sleep` that returns at once."""
    fleet.live_row("rf000001", "alpha-canonical", "idle", "s-rf"); fleet.transcript("s-rf", "ended")
    fleet.pid_for(5201, "alpha-canonical", "s-other", "idle")
    fleet.plant("r-rf", "refresh", "alpha-canonical", "director-canonical")
    fleet.mp.setenv("PATH", str(fleet.S / "fast") + os.pathsep + os.environ["PATH"])
    fleet.serve()
    fleet.expect("r-rf", "failed", "", "a refresh whose name another live process still holds after the stop fails")
    assert "was stopped but a live process still holds the name" in fleet.result("r-rf", "output"), \
        "...saying the stop took but another process still holds the name: %s" % fleet.result("r-rf", "output")


# live-process: a live process holds the name while the sessions list has no live row for it

def test_serve_up_is_refused_while_a_live_process_holds_the_name(fleet):
    fleet.pid_record(4242, "alpha-canonical", "777"); fleet.proc_alive(4242, 777)
    fleet.plant("r-lp1", "up", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-lp1", "refused", "live-process", "up is refused while a live process holds the name the list omits")
    assert "pid 4242" in fleet.result("r-lp1", "detail") and fleet.claude_calls() == "", \
        "the refusal names the pid and nothing was launched: '%s', claude: %s" % (fleet.result("r-lp1", "detail"), fleet.claude_calls())


def test_serve_resume_is_refused_while_a_live_process_holds_the_name(fleet):
    fleet.stopped_row("eeee5555", "alpha-canonical")
    fleet.pid_record(4242, "alpha-canonical", "777"); fleet.proc_alive(4242, 777)
    fleet.plant("r-lp2", "resume", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-lp2", "refused", "live-process", "resume is refused while a live process holds the name")


def test_serve_a_reused_pid_does_not_refuse_up(fleet):
    fleet.pid_record(4242, "alpha-canonical", "777"); fleet.proc_alive(4242, 999)
    fleet.plant("r-lp3", "up", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-lp3", "done", "", "a reused pid (start time differs) does not refuse up")


def test_serve_a_record_whose_pid_is_gone_does_not_refuse_up(fleet):
    fleet.pid_record(4242, "alpha-canonical", "777")
    fleet.plant("r-lp4", "up", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-lp4", "done", "", "a record whose pid is gone does not refuse up")


def test_serve_a_live_process_under_another_name_does_not_refuse_up(fleet):
    fleet.pid_record(4242, "beta-canonical", "777"); fleet.proc_alive(4242, 777)
    fleet.plant("r-lp5", "up", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-lp5", "done", "", "a live process under another name does not refuse up")


def test_serve_a_live_process_the_list_shows_is_left_to_the_working_check(fleet):
    fleet.live_row("cccc3333", "alpha-canonical", "idle", "s-alpha"); fleet.transcript("s-alpha", "ended")
    fleet.pid_record(4242, "alpha-canonical", "777"); fleet.proc_alive(4242, 777)
    fleet.plant("r-lp6", "down", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-lp6", "done", "", "a live process the list does show is left to the working check")


# A `working` row with no waitingFor. Measured: a turn end sometimes writes no final job state, so the
# listing says `working` for a session that is idle. It counts as idle only when the session's own pid
# record says `idle` AND its transcript's last turn ended; either alone is not enough.

def test_serve_stuck_working_row_with_an_idle_record_and_an_ended_turn_is_served(fleet):
    fleet.live_row("wk000001", "alpha-canonical", "working", "s-wk"); fleet.transcript("s-wk", "ended")
    fleet.pid_for(FAKE_PID, "alpha-canonical", "s-wk", "idle")
    fleet.plant("r-wk1", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-wk1", "done", "", "a working row with an idle pid record and an ended turn is served")
    adm = fleet.result("r-wk1", "admitted")
    assert "'working'" in adm and "idle" in adm and "ended" in adm, \
        "...its result says the stuck-working path admitted it: %s" % adm


def test_serve_working_row_whose_record_says_shell_waits(fleet):
    fleet.live_row("wk000002", "alpha-canonical", "working", "s-wk"); fleet.transcript("s-wk", "ended")
    fleet.pid_for(FAKE_PID, "alpha-canonical", "s-wk", "shell")
    fleet.plant("r-wk2", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-wk2", "waiting", "working", "a working row whose pid record says shell waits")
    detail = fleet.result("r-wk2", "detail")
    assert "'shell'" in detail and "not idle" in detail and fleet.claude_calls() == "", \
        "...the reason names the pid record's status and nothing was stopped: %s; claude: %s" % (detail, fleet.claude_calls())


def test_serve_working_row_with_an_idle_record_but_an_unfinished_turn_waits(fleet):
    fleet.live_row("wk000003", "alpha-canonical", "working", "s-wk"); fleet.transcript("s-wk", "working")
    fleet.pid_for(FAKE_PID, "alpha-canonical", "s-wk", "idle")
    fleet.plant("r-wk3", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-wk3", "waiting", "working", "a working row with an idle record but a turn that has not ended waits")
    assert "last turn has not ended" in fleet.result("r-wk3", "detail"), \
        "...the reason names the transcript: %s" % fleet.result("r-wk3", "detail")


def test_serve_working_row_with_no_pid_record_waits(fleet):
    fleet.live_row("wk000004", "alpha-canonical", "working", "s-wk"); fleet.transcript("s-wk", "ended")
    fleet.plant("r-wk4", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-wk4", "waiting", "working", "a working row with no pid record at all waits")


def test_serve_working_row_whose_record_says_busy_waits(fleet):
    fleet.live_row("wk000005", "alpha-canonical", "working", "s-wk"); fleet.transcript("s-wk", "ended")
    fleet.pid_for(FAKE_PID, "alpha-canonical", "s-wk", "busy")
    fleet.plant("r-wk5", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-wk5", "waiting", "working", "a working row whose pid record says busy waits")


def test_serve_working_row_with_a_waiting_for_waits_whatever_the_record_says(fleet):
    fleet.live_row("wk000006", "alpha-canonical", "working", "s-wk", waitingFor="permission prompt")
    fleet.transcript("s-wk", "ended")
    fleet.pid_for(FAKE_PID, "alpha-canonical", "s-wk", "idle")
    fleet.plant("r-wk6", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-wk6", "waiting", "working", "a working row with a waitingFor waits whatever its record says")


# A seat whose job went `done` while its process lives is left out of the live listing but is in the
# full one. refresh and down act on it when the process is idle and its turn ended; up and resume
# still refuse it.

def _done_seat(fleet, n, turn, status):
    session = "dn00000%d-sess" % n
    fleet.done_row("dn00000%d" % n, "alpha-canonical", session)
    if turn:
        fleet.transcript(session, turn)
    if status:
        fleet.pid_for(FAKE_PID, "alpha-canonical", session, status)


def test_serve_refresh_of_a_done_seat_with_an_idle_process(fleet):
    _done_seat(fleet, 1, "ended", "idle")
    fleet.plant("r-dn1", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-dn1", "done", "", "a refresh of a done seat with a live, idle process is served")
    adm = fleet.result("r-dn1", "admitted")
    assert "no live row" in adm and "idle" in adm, "...its result says the unlisted-process path admitted it: %s" % adm
    calls = fleet.claude_calls()
    assert "rm dn000001" in calls and "--bg" in calls, \
        "...the launcher removed the unlisted job and relaunched the seat: %s; %s" % (calls, fleet.result("r-dn1", "output"))
    lines = calls.splitlines()
    first_rm = next(i for i, l in enumerate(lines) if "rm dn000001" in l)
    first_bg = next(i for i, l in enumerate(lines) if "--bg" in l)
    assert first_rm < first_bg, "...and stopped it before launching: %s" % calls


def test_serve_refresh_of_a_done_seat_whose_process_is_busy_waits(fleet):
    _done_seat(fleet, 2, "ended", "busy")
    fleet.plant("r-dn2", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-dn2", "waiting", "live-process", "a refresh of a done seat whose process is busy is not served")
    assert fleet.claude_calls() == "", "...and nothing was stopped: %s" % fleet.claude_calls()


def test_serve_down_of_a_done_seat_with_a_background_shell_waits(fleet):
    _done_seat(fleet, 3, "ended", "shell")
    fleet.plant("r-dn3", "down", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-dn3", "waiting", "live-process", "a down of a done seat with a background shell running is not served")


def test_serve_done_seat_with_an_idle_record_but_an_unfinished_turn_waits(fleet):
    _done_seat(fleet, 4, "working", "idle")
    fleet.plant("r-dn4", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-dn4", "waiting", "live-process", "a done seat whose record is idle but whose turn has not ended waits")


def test_serve_done_seat_with_an_unreadable_transcript_is_refused(fleet):
    _done_seat(fleet, 5, None, "idle")
    fleet.plant("r-dn5", "refresh", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-dn5", "refused", "live-process", "a done seat whose transcript cannot be read is refused (fail closed)")


def test_serve_down_of_a_done_seat_with_an_idle_process(fleet):
    _done_seat(fleet, 6, "ended", "idle")
    fleet.plant("r-dn6", "down", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-dn6", "done", "", "a down of a done seat with a live, idle process is served")
    calls = fleet.claude_calls()
    assert "rm dn000006" in calls and "--bg" not in calls, "...it was stopped and not relaunched: %s" % calls


def test_serve_up_still_refuses_a_done_seat_whose_process_lives(fleet):
    _done_seat(fleet, 7, "ended", "idle")
    fleet.plant("r-dn7", "up", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-dn7", "refused", "live-process", "up still refuses a done seat whose process lives, idle or not")


def test_serve_resume_still_refuses_a_done_seat_whose_process_lives(fleet):
    _done_seat(fleet, 8, "ended", "idle")
    fleet.plant("r-dn8", "resume", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-dn8", "refused", "live-process", "resume still refuses a done seat whose process lives")


# ================================================================= serve: resume

def test_serve_resume_of_a_stopped_session(fleet):
    fleet.stopped_row("eeee5555", "alpha-canonical")
    fleet.plant("r-r1", "resume", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-r1", "done", "", "resume of a stopped session runs and the session is live again")
    assert fleet.claude_calls().strip() == "respawn eeee5555", \
        "resume runs claude respawn on the canonical's last session: %s" % fleet.claude_calls()
    fleet.plant("r-r2", "resume", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-r2", "refused", "working", "resume is refused while the session is running")


def test_serve_resume_with_no_listed_session_fails(fleet):
    fleet.plant("r-r3", "resume", "alpha-canonical", "alpha-canonical")
    fleet.serve()
    fleet.expect("r-r3", "failed", "", "resume with no listed session fails, naming up")
    assert "request `up`" in fleet.result("r-r3", "output"), \
        "...and the failure names up (new in the port): %s" % fleet.result("r-r3", "output")


# resume of a LISTED row whose process is provably gone (measured 2026-11-08): the idle stop leaves
# a session listed, often `blocked`, with nothing running it. Served whatever its state once no live
# pid record holds the name and the daemon roster lists no worker; a live process is refused.

@pytest.mark.parametrize("state", ["blocked", "idle", "done"])
def test_serve_resume_of_a_listed_row_with_no_process(fleet, state):
    fleet.live_row("gn-" + state, "alpha-canonical", state, "s-gn"); fleet.transcript("s-gn", "ended")
    fleet.plant("r-gn-" + state, "resume", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-gn-" + state, "done", "",
                 "resume of a listed '%s' row with no process and no roster worker is served" % state)
    if state == "done":
        assert fleet.claude_calls().strip() == "respawn gn-done", "...and it respawns the listed row: %s" % fleet.claude_calls()
        assert "a process holds the session again" in fleet.result("r-gn-done", "output"), \
            "...and confirms by a process, not by the row it already saw: %s" % fleet.result("r-gn-done", "output")


def test_serve_resume_of_a_listed_row_with_a_live_pid_record_is_refused(fleet):
    fleet.live_row("gb000001", "alpha-canonical", "blocked", "s-gb"); fleet.transcript("s-gb", "ended")
    fleet.pid_for(5401, "alpha-canonical", "s-gb", "idle")
    fleet.plant("r-gb1", "resume", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-gb1", "refused", "working", "resume of a listed 'blocked' row is refused while a live pid record holds the name")
    detail = fleet.result("r-gb1", "detail")
    assert "listed 'blocked'" in detail and "live process still holds the name" in detail and fleet.claude_calls() == "", \
        "...naming the process, and nothing was respawned: '%s', claude: %s" % (detail, fleet.claude_calls())


def test_serve_resume_of_a_listed_row_with_a_roster_worker_is_refused(fleet):
    fleet.live_row("gb000002", "alpha-canonical", "blocked", "s-gb"); fleet.transcript("s-gb", "ended"); fleet.roster_worker("s-gb")
    fleet.plant("r-gb2", "resume", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-gb2", "refused", "working", "resume of a listed 'blocked' row is refused while the daemon roster lists its worker")
    assert "roster lists a running worker" in fleet.result("r-gb2", "detail"), \
        "...naming the roster worker: %s" % fleet.result("r-gb2", "detail")


def test_serve_resume_is_refused_when_the_roster_cannot_be_read(fleet):
    fleet.live_row("gb000003", "alpha-canonical", "blocked", "s-gb"); fleet.transcript("s-gb", "ended")
    fleet.roster.unlink()
    fleet.plant("r-gb3", "resume", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-gb3", "refused", "working", "resume is refused when the daemon roster cannot be read (fail closed)")


def test_serve_resume_is_refused_for_a_row_with_no_session_id(fleet):
    fleet.live_row("gb000004", "alpha-canonical", "blocked", ""); fleet.transcript("s-gb", "ended")
    fleet.plant("r-gb4", "resume", "alpha-canonical", "director-canonical")
    fleet.serve()
    fleet.expect("r-gb4", "refused", "working", "resume is refused for a listed row with no session id to look up")


def test_serve_a_respawn_that_brings_no_process_up_fails(fleet):
    fleet.live_row("gf000001", "alpha-canonical", "blocked", "s-gf"); fleet.transcript("s-gf", "ended")
    fleet.plant("r-gf1", "resume", "alpha-canonical", "director-canonical")
    fleet.mp.setenv("RESPAWN_NO_PROCESS", "1")
    fleet.serve()
    fleet.expect("r-gf1", "failed", "", "a respawn that brings no process up fails, though the row was listed all along")
    assert "no process (pid record or daemon roster worker) appeared" in fleet.result("r-gf1", "output"), \
        "...saying no process appeared: %s" % fleet.result("r-gf1", "output")


# ================================================================= serve: the runner lock

def test_serve_a_second_runner_leaves_the_queue_to_the_first(fleet):
    fleet.plant("r-l", "up", "alpha-canonical", "alpha-canonical")
    ready = fleet.T / "locked"
    holder = subprocess.Popen([sys.executable, "-c",
                               "import fcntl,sys,time; f=open(sys.argv[1],'w'); fcntl.flock(f,fcntl.LOCK_EX);"
                               " open(sys.argv[2],'w').close(); time.sleep(30)",
                               str(fleet.Q / ".serve.lock"), str(ready)])
    try:
        for _ in range(100):
            if ready.exists():
                break
            time.sleep(0.1)
        assert ready.exists(), "the lock holder did not start"
        out = fleet.serve()
        assert (fleet.Q / "r-l.request.json").is_file() and "another runner" in out, \
            "a second runner does not serve a queue another holds: %s" % out
    finally:
        holder.kill()
        holder.wait()
    fleet.serve()
    fleet.expect("r-l", "done", "", "once the lock is free the request is served")


# ================================================================= contract: the real chain

def test_contract_a_launch_inherits_the_callers_path(fleet):
    """What the runner starts gets the runner's caller's PATH, without uv's environment for the queue.
    The chain here is the real one: bash, `uv run --script`, the queue, the claude stub."""
    fleet.plant("r-env", "up", "alpha-canonical", "alpha-canonical")
    r = fleet.fc("serve-requests")
    fleet.expect("r-env", "done", "", "up runs (the PATH case's control)")
    seen = Path(str(fleet.log) + ".path").read_text().strip()
    assert seen == os.environ["PATH"], \
        "a launch inherits exactly the caller's PATH, not the queue's uv environment: %s\nwanted %s\n%s" % (seen, os.environ["PATH"], r)


def test_contract_serve_requests_prints_one_line_per_request(fleet):
    fleet.plant("r-c1", "up", "alpha-canonical", "alpha-canonical")
    fleet.plant("r-c2", "up", "beta-canonical", "alpha-canonical")
    r = fleet.fc("serve-requests")
    assert r.status == 0, r
    lines = r.out.splitlines()
    assert lines[0].startswith("done     up alpha-canonical (from alpha-canonical)") and \
        lines[1].startswith("refused  up beta-canonical (from alpha-canonical) -- requester:"), r.out


# Upper bounds, not durations: each returns as soon as its condition holds, so a generous bound costs
# nothing on an idle machine. 15 s and 20 s failed on a work Mac at load 40-55 (2026-11-12).
LOADED_WAIT = 90


def _waitfor(seconds, fn):
    for _ in range(int(seconds * 10)):
        if fn():
            return True
        time.sleep(0.1)
    return False


def _stop_loop(proc):
    proc.send_signal(signal.SIGTERM)
    try:
        return proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        return 99


def _start_loop(fleet):
    out, err = open(fleet.T / "loop.out", "w"), open(fleet.T / "loop.err", "w")
    return subprocess.Popen(["bash", str(TOOL), "serve-requests", "--loop", "--interval", "1"],
                            stdin=subprocess.DEVNULL, stdout=out, stderr=err, env=dict(os.environ))


def test_contract_loop_serves_each_pass_and_ends_on_sigterm(fleet):
    """--loop: one pass, then another every --interval seconds, until SIGTERM/SIGINT; every wait bounded."""
    fleet.plant("l-1", "up", "alpha-canonical", "alpha-canonical")
    proc = _start_loop(fleet)
    try:
        def served(rid):
            return (fleet.Q / (rid + ".result.json")).is_file()
        debug = lambda: (fleet.T / "loop.out").read_text() + (fleet.T / "loop.err").read_text()
        assert _waitfor(LOADED_WAIT, lambda: served("l-1")), "--loop serves the queue on its first pass: %s" % debug()
        fleet.plant("l-2", "up", "beta-canonical", "beta-canonical")
        assert _waitfor(LOADED_WAIT, lambda: served("l-2")), "--loop serves a request that arrives after the first pass (a second pass ran): %s" % debug()
    finally:
        rc = _stop_loop(proc)
    assert rc == 0, "SIGTERM ends --loop with status 0 (99: had to be killed; got %s)" % rc
    assert (fleet.T / "loop.err").read_text() == "", \
        "SIGTERM leaves nothing on stderr (no traceback): %s" % (fleet.T / "loop.err").read_text()
    done = [l for l in (fleet.T / "loop.out").read_text().splitlines() if l.startswith("done ")]
    assert len(done) == 2, "--loop's per-pass output is the one-shot output, one line per served request: %s" % done


def test_contract_loop_survives_a_failed_pass(fleet):
    """A pass that fails is reported and does not end the loop: the lock file is a directory, so the
    pass cannot open it; once it is removed the next pass serves."""
    (fleet.Q / ".serve.lock").mkdir(parents=True)
    fleet.plant("l-3", "up", "gamma-canonical", "gamma-canonical")
    proc = _start_loop(fleet)
    try:
        err = fleet.T / "loop.err"
        assert _waitfor(LOADED_WAIT, lambda: "pass failed" in err.read_text()), "a failing pass is reported on stderr: %s" % err.read_text()
        assert proc.poll() is None, "the loop is still running after a failed pass"
        (fleet.Q / ".serve.lock").rmdir()
        assert _waitfor(LOADED_WAIT, lambda: (fleet.Q / "l-3.result.json").is_file()), "a later pass serves once the fault clears: %s" % err.read_text()
    finally:
        rc = _stop_loop(proc)
    assert rc == 0, "SIGTERM after a failed pass still ends the loop with status 0 (got %s)" % rc


def test_contract_serve_requests_usage_errors(fleet):
    r = fleet.fc("serve-requests", "--interval", "1")
    assert r.status != 0 and "--loop" in r.out, "--interval without --loop is a usage error (rc=%s): %s" % (r.status, r.out)
    r = fleet.fc("serve-requests", "--loop", "--interval", "0")
    assert r.status != 0, "--interval must be positive: %s" % r.out
    r = fleet.fc("serve-requests", "extra")
    assert r.status != 0, "serve-requests still takes no other arguments: %s" % r.out


# ================================================================= the session-state snapshot
# `snapshot`, run outside every sandbox by a timer, writes each seat's state to sessions.json; the
# readers use a fresh one, refuse a stale one and note a missing one. Every source is a fixture.

def test_snapshot_states(fleet):
    fleet.live_row("11111111", "alpha-canonical", "idle", "sa")
    fleet.pid_record(4343, "beta-canonical", "900"); fleet.proc_alive(4343, 900)
    r = fleet.snapshot()
    states = {n: fleet.snap_seat(n) for n in ("alpha-canonical", "beta-canonical", "gamma-canonical", "elsewhere-canonical")}
    assert r.status == 0 and states == {"alpha-canonical": "live", "beta-canonical": "live",
                                        "gamma-canonical": "dead", "elsewhere-canonical": "absent"}, \
        "snapshot: listed and pid-record seats live, the rest dead, other machines' seats absent (rc=%s): %s / %s" % (
            r.status, r.out, states)


def test_snapshot_unreadable_list_is_unknown_never_dead(fleet):
    fleet.pid_record(4343, "beta-canonical", "900"); fleet.proc_alive(4343, 900)
    fleet.mp.setenv("FLEET_AGENTS_JSON_CMD", "false")
    fleet.snapshot()
    assert fleet.snap_seat("gamma-canonical") == "unknown" and fleet.snap_seat("beta-canonical") == "live", \
        "snapshot: an unreadable sessions list makes an unseen seat unknown, never dead: %s" % fleet.snap.read_text()


def test_snapshot_refuses_inside_a_sandbox(fleet):
    (fleet.proc / "1").mkdir()
    (fleet.proc / "1" / "comm").write_text("bwrap\n")
    r = fleet.snapshot()
    assert r.status != 0 and "inside a sandbox" in r.out and not fleet.snap.exists(), \
        "snapshot refuses inside a sandbox and writes nothing (rc=%s): %s" % (r.status, r.out)


# The snapshot names its seats from four reads of the whole record rather than several per seat (a
# 29-seat machine took about 15 s a pass that way, 2026-11-12). It must name exactly the seats the
# per-seat test, declared_here(), accepts, in the record's order.
EDGE_SEATS = """  block:
    scope: block
    canonical: block-canonical
    canonicalLaunchDir: block
    canonicalMachines:
      - some-other-host
      - {host}
  nodir:
    scope: nodir
    canonical: nodir-canonical
    canonicalMachines: [{host}]
  nomachines:
    scope: nomachines
    canonical: nomachines-canonical
    canonicalLaunchDir: nomachines
  scalarmachine:
    scope: scalarmachine
    canonical: scalarmachine-canonical
    canonicalLaunchDir: scalarmachine
    canonicalMachines: {host}
  twice1:
    scope: twice1
    canonical: twice-canonical
    canonicalLaunchDir: twice1
    canonicalMachines: [{host}]
  twice2:
    scope: twice2
    canonical: twice-canonical
    canonicalLaunchDir: twice2
    canonicalMachines: [{host}]
"""


def test_snapshot_seats_are_the_per_seat_test_in_record_order(fleet):
    rec = fleet.T / "rec-edges.yaml"
    rec.write_text((fleet.S / "rec.yaml").read_text() + EDGE_SEATS.format(host=HOST))
    fleet.mp.setenv("FLEET_RECORD", str(rec))
    r = fleet.snapshot()
    got = list(json.loads(fleet.snap.read_text())["seats"]) if r.status == 0 else r.out
    names = subprocess.run([str(DECL), "--canonicals"], capture_output=True, text=True).stdout.split()
    per_seat = [n for n in dict.fromkeys(names) if fleet.q.declared_here(n)[0]]
    want = ["alpha-canonical", "beta-canonical", "gamma-canonical", "director-canonical", "block-canonical"]
    assert per_seat == want and got == want, \
        "snapshot: the seats are the per-seat test's, in the record's order: a block-style machine " \
        "list counts; no launch directory, no machine list, a scalar machine, another machine and a " \
        "name two projects declare do not (per-seat %s, snapshot %s)" % (per_seat, got)


# status: a seat the snapshot shows live reads LIVE-UNLISTED, an unknown one UNKNOWN, never MISSING

def _status_line(fleet, name):
    r = fleet.fc("status")
    return r, next((l for l in r.out.splitlines() if l.startswith(name)), "")


def test_status_a_fresh_snapshots_live_seat_is_live_unlisted(fleet):
    fleet.write_snapshot(5, "gamma-canonical", "live", "pid 9999 (fixture)")
    r, line = _status_line(fleet, "gamma-canonical")
    assert "LIVE-UNLISTED" in line and "pid 9999" in line, \
        "status: a fresh snapshot's live seat is LIVE-UNLISTED: %s" % r.out


def test_status_an_unknown_seat_reads_unknown_not_missing(fleet):
    fleet.write_snapshot(5, "gamma-canonical", "unknown", "no readable source: the sessions list could not be read")
    r, line = _status_line(fleet, "gamma-canonical")
    assert "UNKNOWN (no readable source" in line and "MISSING" not in line, \
        "status: an unknown seat reads UNKNOWN, not MISSING: %s" % r.out


def test_status_refuses_a_stale_snapshot(fleet):
    fleet.write_snapshot(100, "gamma-canonical", "dead")
    r = fleet.fc("status")
    assert r.status != 0 and re.search(r"snapshot is 1\d\ds old", r.out) and "fleet-canonicals-snapshot" in r.out, \
        "status refuses a stale snapshot, naming the timer (rc=%s): %s" % (r.status, r.out)


def test_status_with_no_snapshot_notes_it_and_reads_the_sessions_directly(fleet):
    r = fleet.fc("status")
    assert "no session snapshot" in r.out and "alpha-canonical" in r.out, \
        "status with no snapshot notes it and reads the sessions directly: %s" % r.out


# up: refuses a seat the snapshot shows live or unknown; a dead one starts

def test_up_refuses_a_seat_the_snapshot_reads_unknown(fleet):
    fleet.write_snapshot(5, "gamma-canonical", "unknown", "no readable source")
    out = fleet.fc("up", "gamma-canonical", "--dry-run").out
    assert re.search(r"REFUSED.*gamma-canonical.*UNKNOWN", out, re.S) and "would start" not in out, \
        "up refuses a seat the snapshot reads UNKNOWN: %s" % out


def test_up_refuses_a_seat_the_snapshot_shows_running(fleet):
    fleet.write_snapshot(5, "gamma-canonical", "live", "pid 9999 (fixture)")
    out = fleet.fc("up", "gamma-canonical", "--dry-run").out
    assert re.search(r"REFUSED.*gamma-canonical.*snapshot shows it running", out, re.S), \
        "up refuses a seat the snapshot shows running though the list omits it: %s" % out


def test_up_starts_a_seat_the_snapshot_reads_dead(fleet):
    fleet.write_snapshot(5, "gamma-canonical", "dead")
    out = fleet.fc("up", "gamma-canonical", "--dry-run").out
    assert re.search(r"would start.*gamma-canonical", out, re.S), "up starts a seat the snapshot reads dead (control): %s" % out


def test_up_and_clean_refuse_a_stale_snapshot(fleet):
    fleet.write_snapshot(100, "gamma-canonical", "dead")
    r = fleet.fc("up", "gamma-canonical", "--dry-run")
    assert r.status != 0 and re.search(r"snapshot is 1\d\ds old", r.out) and "would start" not in r.out, \
        "up refuses a stale snapshot (rc=%s): %s" % (r.status, r.out)
    r = fleet.fc("clean", "--dry-run")
    assert r.status != 0 and re.search(r"snapshot is 1\d\ds old", r.out), \
        "clean refuses a stale snapshot (rc=%s): %s" % (r.status, r.out)


# the runner: a stale snapshot refuses every request; a fresh one refuses starting an unknown seat

def test_serve_snapshot_stale(fleet):
    fleet.write_snapshot(100, "gamma-canonical", "dead")
    fleet.plant("r-snap1", "up", "gamma-canonical", "gamma-canonical")
    fleet.serve()
    fleet.expect("r-snap1", "refused", "snapshot", "the runner refuses a request while the snapshot is stale")


def test_serve_snapshot_unknown_seat(fleet):
    fleet.write_snapshot(5, "gamma-canonical", "unknown", "no readable source")
    fleet.plant("r-snap2", "up", "gamma-canonical", "gamma-canonical")
    fleet.serve()
    fleet.expect("r-snap2", "refused", "snapshot", "the runner refuses starting a seat the snapshot reads UNKNOWN")


def test_serve_snapshot_fresh_and_dead_is_served(fleet):
    fleet.write_snapshot(5, "gamma-canonical", "dead")
    fleet.plant("r-snap3", "up", "gamma-canonical", "gamma-canonical")
    fleet.serve()
    fleet.expect("r-snap3", "done", "", "the runner serves it once the snapshot is fresh and the seat dead (control)")


def test_serve_snapshot_unknown_seat_may_still_be_stopped(fleet):
    fleet.write_snapshot(5, "gamma-canonical", "unknown", "no readable source")
    fleet.plant("r-snap4", "down", "gamma-canonical", "gamma-canonical")
    fleet.serve()
    fleet.expect("r-snap4", "done", "", "a seat the snapshot reads UNKNOWN may still be stopped (control; new in the port)")


# refresh: the snapshot that was current when refresh STOPPED the seat still lists the stopped
# process, so the relaunch must wait for one taken after the stop instead of refusing on it.
# Measured 2026-11-10 06:49: refresh stopped pid 11281, then `up` refused "the session snapshot
# shows it running" on a snapshot up to 15 s old, and the seat was left down.

def _refresh_fixture(fleet):
    fleet.live_row("rf000001", "gamma-canonical", "idle", "s"); fleet.transcript("s", "ended")
    fleet.pid_record(6101, "gamma-canonical", "600"); fleet.proc_alive(6101, 600)
    fleet.snap.write_text(json.dumps({"version": 1, "takenAt": int(time.time()), "seats": {"gamma-canonical": {
        "state": "live", "why": "listed (idle); pid 6101 (fixture)", "pids": [6101]}}}))


def _snap_seat_after(fleet, delay, state):
    """After `delay` seconds, write a snapshot taken then, showing gamma in `state`."""
    def write():
        time.sleep(delay)
        tmp = Path(str(fleet.snap) + ".n")
        tmp.write_text(json.dumps({"version": 1, "takenAt": int(time.time()), "seats": {"gamma-canonical": {
            "state": state, "why": "fixture, after the stop", "pids": []}}}))
        tmp.replace(fleet.snap)
    t = threading.Thread(target=write)
    t.start()
    return t


def test_refresh_a_pre_stop_snapshot_listing_the_stopped_pid_does_not_block_the_relaunch(fleet):
    _refresh_fixture(fleet)
    t = _snap_seat_after(fleet, 3, "dead")
    r = fleet.fc("refresh", "gamma-canonical", env={"FLEET_REFRESH_SNAPSHOT_WAIT": str(LOADED_WAIT)})
    t.join()
    assert r.status == 0 and "started 1" in r.out and "REFUSED" not in r.out, \
        "refresh: a snapshot from before the stop that lists the stopped pid does not block the relaunch (rc=%s): %s" % (r.status, r.out)


def test_refresh_a_post_stop_snapshot_that_still_shows_the_seat_running_refuses(fleet):
    _refresh_fixture(fleet)
    t = _snap_seat_after(fleet, 3, "live")
    r = fleet.fc("refresh", "gamma-canonical", env={"FLEET_REFRESH_SNAPSHOT_WAIT": str(LOADED_WAIT)})
    t.join()
    assert r.status != 0 and re.search(r"REFUSED.*snapshot shows it running", r.out, re.S) and "started 1" not in r.out, \
        "refresh: a snapshot taken AFTER the stop that still shows the seat running refuses (control) (rc=%s): %s" % (r.status, r.out)


def test_refresh_with_no_snapshot_after_the_stop_refuses_naming_the_next_step(fleet):
    _refresh_fixture(fleet)
    r = fleet.fc("refresh", "gamma-canonical", env={"FLEET_REFRESH_SNAPSHOT_WAIT": "2"})
    assert r.status != 0 and "not retaken" in r.out and "fleet-canonicals up gamma-canonical" in r.out and "started 1" not in r.out, \
        "refresh: no snapshot after the stop within the wait refuses, naming the next step (rc=%s): %s" % (r.status, r.out)


# context use: the snapshot records each live seat's prompt size at its last main-thread reply
# (input + cache read + cache creation) against its window, and status flags 50% or more.

def _ctx_transcript(fleet, session, tokens, sidechain=None):
    """A transcript whose last main-thread reply's prompt was `tokens`, optionally followed by a
    larger subagent (sidechain) reply that must not count."""
    lines = [{"type": "user", "message": {"role": "user", "content": "go"}, "timestamp": "2026-11-10T11:00:00Z"},
             {"type": "assistant", "timestamp": "2026-11-10T11:00:05Z", "message": {
                 "role": "assistant", "stop_reason": "end_turn",
                 "usage": {"input_tokens": 1, "cache_creation_input_tokens": 100,
                           "cache_read_input_tokens": tokens - 101, "output_tokens": 50}}}]
    if sidechain:
        lines.append({"type": "assistant", "isSidechain": True, "timestamp": "2026-11-10T11:00:09Z",
                      "message": {"role": "assistant", "usage": {"input_tokens": sidechain, "output_tokens": 5}}})
    (fleet.transcripts / (session + ".jsonl")).write_text("".join(json.dumps(l) + "\n" for l in lines))


def _ctx(fleet, name, key=None):
    d = json.loads(fleet.snap.read_text())["seats"][name]["context"]
    if key is None:
        return d
    return None if d is None else d.get(key)


def _ctx_status(fleet, tokens, session="s-cx"):
    _ctx_transcript(fleet, session, tokens)
    fleet.snapshot()
    return _status_line(fleet, "alpha-canonical")[1]


def test_snapshot_context_is_the_last_main_thread_prompt(fleet):
    fleet.live_row("cx000001", "alpha-canonical", "idle", "s-cx")
    _ctx_transcript(fleet, "s-cx", 145600, sidechain=900000)
    fleet.snapshot()
    got = [_ctx(fleet, "alpha-canonical", k) for k in ("tokens", "window", "percent", "sessionId")]
    assert got == [145600, 200000, 72.8, "s-cx"], \
        "snapshot: a live seat's context is its last main-thread prompt against a 200k window; a later subagent reply is ignored: %s" % got
    assert _ctx(fleet, "beta-canonical") is None, \
        "snapshot: a dead seat has no context figure: %s" % _ctx(fleet, "beta-canonical")
    line = _status_line(fleet, "alpha-canonical")[1]
    assert "OK" in line and "context 72.8% (145k of 200k) CONTEXT-HIGH" in line, \
        "status: a seat at 72.8% shows its context and the CONTEXT-HIGH flag: %s" % line


def test_status_context_bands(fleet):
    fleet.live_row("cx000001", "alpha-canonical", "idle", "s-cx")
    line = _ctx_status(fleet, 99800)
    assert "context 49.9%" in line and "CONTEXT-" not in line, "status: 49.9%% is not flagged: %s" % line
    rc_low = fleet.fc("status").status
    line = _ctx_status(fleet, 145600)
    rc_high = fleet.fc("status").status
    assert rc_high == rc_low, "status: the flag does not change the exit code (advisory): %s flagged vs %s not" % (rc_high, rc_low)
    line = _ctx_status(fleet, 100000)
    assert re.search(r"context 50.*CONTEXT-WATCH", line) and "CONTEXT-HIGH" not in line, \
        "status: exactly 50%% is CONTEXT-WATCH (a refresh at the next boundary), not HIGH: %s" % line
    # The bands follow the refresh rule of 2026-11-10 13:11: 50-65 watch, 65-80 high, 80+ critical.
    line = _ctx_status(fleet, 129800)
    assert re.search(r"context 64.9%.*CONTEXT-WATCH", line), "status: 64.9%% is still CONTEXT-WATCH: %s" % line
    line = _ctx_status(fleet, 130000)
    assert re.search(r"context 65.*CONTEXT-HIGH", line) and "CONTEXT-WATCH" not in line, "status: 65%% is CONTEXT-HIGH: %s" % line
    line = _ctx_status(fleet, 160000)
    assert re.search(r"context 80.*CONTEXT-CRITICAL", line) and "CONTEXT-HIGH" not in line, "status: 80%% is CONTEXT-CRITICAL: %s" % line
    fleet.set_config("context-high-pct = 75")
    line = _ctx_status(fleet, 145600)
    assert re.search(r"context 72.8%.*CONTEXT-WATCH", line), "status: context-high-pct moves the band: %s" % line


def test_snapshot_a_1m_model_is_measured_against_a_million_tokens(fleet):
    fleet.live_row("cx000001", "alpha-canonical", "idle", "s-cx")
    _ctx_transcript(fleet, "s-cx", 145600)
    rec = fleet.T / "rec1m.yaml"
    rec.write_text((fleet.S / "rec.yaml").read_text().replace("canonicalLaunchModel: opus\n", 'canonicalLaunchModel: "opus[1m]"\n'))
    fleet.mp.setenv("FLEET_RECORD", str(rec))
    fleet.snapshot()
    got = [_ctx(fleet, "alpha-canonical", k) for k in ("window", "percent")]
    assert got == [1000000, 14.6], "snapshot: a seat launched on a [1m] model is measured against 1,000,000 tokens: %s" % got


def test_snapshot_a_prompt_larger_than_the_window_names_the_window_as_wrong(fleet):
    """A prompt larger than the assumed window proves the window value wrong, not the seat over 100%.
    Measured 2026-11-10: a seat launched as plain `opus` reached 291k tokens with no compaction, and
    status flagged it CONTEXT-HIGH at 145.7% of the 200k default."""
    fleet.live_row("cx000001", "alpha-canonical", "idle", "s-cx")
    line = _ctx_status(fleet, 291452)
    assert _ctx(fleet, "alpha-canonical", "percent") is None and _ctx(fleet, "alpha-canonical", "overWindow") is True, \
        "snapshot: a prompt larger than the window records no percent, and says so: %s" % _ctx(fleet, "alpha-canonical")
    assert "context 291k, more than the 200k window" in line and "CONTEXT-" not in line and "%" not in line, \
        "status: a prompt larger than the window names the window as wrong, never CONTEXT-HIGH: %s" % line


def test_snapshot_a_live_seat_with_no_readable_transcript_shows_a_question_mark(fleet):
    fleet.live_row("cx000001", "alpha-canonical", "idle", "s-cx")
    fleet.snapshot()
    line = _status_line(fleet, "alpha-canonical")[1]
    assert _ctx(fleet, "alpha-canonical") is None and "context ?" in line, \
        "a live seat with no readable transcript shows context ?, not a number: %s" % line


# ================================================================= mutants

def make_mutant(directory, find, replace):
    """A copy of the queue in `directory` with `find` replaced by `replace`. `find` must occur
    exactly once, so the mutant changes the one place it names; anything else fails the test, as
    does a replacement that leaves the text as it was."""
    source = QUEUE_SRC.read_text()
    n = source.count(find)
    if n != 1:
        pytest.fail("mutant: %r occurs %d times in the queue; it must occur exactly once" % (find, n))
    mutated = source.replace(find, replace)
    if mutated == source:
        pytest.fail("mutant: the replacement changed nothing")
    # One directory per mutant: Python caches a module's bytecode by path, size and modification
    # time to the second, so two mutants of the same size at one path could run the first's code.
    path = directory / "fleet-canonicals-queue-mutant"
    path.write_text(mutated)
    shutil.copymode(QUEUE_SRC, path)
    return path


def run_one_test(nodeid, queue_path, directory):
    """Run one test of this file in a child pytest, with the queue loaded from `queue_path`."""
    # TMPDIR as this run was given it: the child makes its own directories under it.
    env = dict(os.environ, FLEET_CANONICALS_QUEUE=str(queue_path), TMPDIR=ORIGINAL_TMP)
    p = subprocess.run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider",
                        "-o", "markers=mutant: a mutant meta-test, run in the landing lane only",
                        "%s::%s" % (Path(__file__).resolve(), nodeid)],
                       env=env, cwd=str(HERE), capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def _check_off(name):
    """A mutant that disables a whole check: its function returns at once."""
    header = "def check_%s(req: dict, ctx: Pass, path: Path) -> str | None:\n" % name
    return header, header + "    return None\n"


def _off(check, description, test):
    find, replace = _check_off(check)
    return ("check-" + check.replace("_", "-"), description, find, replace, test)


MUTANTS = [
    # --- the runner's checks, each switched off whole (CHECKS in the queue, in its order)
    _off("shape", "a request missing its fields is served", "test_serve_refuses_a_malformed_request_or_verb"),
    _off("verb", "a verb outside the four, or an option smuggled in a verb or name, is served", "test_serve_refuses_a_malformed_request_or_verb"),
    _off("paused", "a PAUSED queue is served", "test_serve_paused"),
    _off("age", "a stale request is served", "test_serve_age"),
    _off("never_touch", "the never-touch canonical is acted on", "test_serve_never_touch"),
    _off("declared", "a canonical declared for another machine is acted on", "test_serve_declared_for_this_machine"),
    _off("requester", "a canonical may request another canonical's action", "test_serve_requester"),
    _off("self_refresh", "a canonical's request to refresh itself is served", "test_serve_self_refresh"),
    _off("one_per_canonical", "two requests for one canonical both run", "test_serve_one_per_canonical_queued"),
    _off("rate", "no rate limit", "test_serve_rate_per_canonical"),
    _off("usage", "starting verbs ignore the 7-day window", "test_serve_usage"),
    _off("trust", "an untrusted directory is launched into", "test_serve_trust"),
    _off("snapshot", "a stale snapshot is read as current", "test_serve_snapshot_stale"),
    _off("live_process", "up starts a second session beside a live process the list omits", "test_serve_up_is_refused_while_a_live_process_holds_the_name"),
    _off("working", "a working session is stopped", "test_serve_working_waits_until_the_session_is_idle"),
    # --- the checks, one condition at a time
    ("shape-time", "a request whose time is not an integer passes the shape check",
     'if not isinstance(req["time"], int):', 'if False:', "test_serve_refuses_a_malformed_request_or_verb"),
    ("verb-name-pattern", "a name with a space or a slash passes the verb check",
     'if not re.fullmatch(r"[A-Za-z0-9._-]+", req["name"]):', 'if False:', "test_serve_refuses_a_malformed_request_or_verb"),
    ("verb-option", "a verb or name starting with a dash passes",
     'if req["verb"].startswith("-") or req["name"].startswith("-") or " " in req["verb"]:', 'if False:',
     "test_serve_refuses_a_malformed_request_or_verb"),
    ("age-future", "a request dated in the future passes",
     "    if age < -60:\n", "    if False:\n", "test_serve_age_refuses_a_request_dated_in_the_future"),
    ("age-waited", "a stale refusal of a waiting request forgets the wait",
     'if prior.get("outcome") == "waiting":\n            why +=', 'if False:\n            why +=',
     "test_serve_a_waiting_request_past_max_age_is_refused_stale"),
    ("requester-any", "request-any is ignored",
     'req["requester"] in as_list(ctx.cfg["request-any"])', 'False', "test_serve_requester"),
    ("self-refresh-config", "allow-self-refresh = true does not allow it",
     'if ctx.cfg["allow-self-refresh"].lower() == "true":', 'if False:', "test_serve_self_refresh"),
    ("one-per-running", "a request is served while one for the same canonical is marked running",
     '        if r and r.get("name") == req["name"]:\n            return (f"another request for \'{req[\'name\']}\' is marked running',
     '        if False:\n            return (f"another request for \'{req[\'name\']}\' is marked running',
     "test_serve_one_per_canonical_running"),
    ("one-per-queued", "an older queued request for the same canonical does not hold the second",
     'if p.name < path.name and r and r.get("name") == req["name"]:', 'if False:', "test_serve_one_per_canonical_queued"),
    ("rate-canonical", "the per-canonical limit is not applied",
     "    if len(mine) >= lc:\n", "    if False:\n", "test_serve_rate_per_canonical"),
    ("rate-fleet", "the fleet limit is not applied",
     "    if len(acted) >= lf:\n", "    if False:\n", "test_serve_rate_fleet"),
    ("rate-boundary", "the per-canonical limit refuses at one action fewer",
     "    if len(mine) >= lc:\n", "    if len(mine) >= lc - 1:\n", "test_serve_rate_per_canonical_two_actions_are_under_the_limit"),
    ("rate-counts-refusals", "refused requests count as actions",
     'if a.get("outcome") in ("done", "failed") and a.get("at", 0) > hour]', 'if a.get("outcome") and a.get("at", 0) > hour]',
     "test_serve_rate_per_canonical"),
    ("rate-hour", "actions of any age count",
     ' and a.get("at", 0) > hour]', ']', "test_serve_rate_per_canonical"),
    ("rate-fleet-floor", "the fleet limit ignores the seats declared here",
     "return max(FLEET_LIMIT_FLOOR, 2 * n) if n is not None else FLEET_LIMIT_FLOOR", "return FLEET_LIMIT_FLOOR",
     "test_serve_rate_fleet_scales_with_the_seats_declared_here"),
    ("rate-fleet-factor", "the fleet limit is three times the seats, not twice",
     "max(FLEET_LIMIT_FLOOR, 2 * n)", "max(FLEET_LIMIT_FLOOR, 3 * n)", "test_serve_rate_fleet_limit_is_twice_the_seats"),
    ("rate-fleet-config", "request-limit-fleet in the config is ignored",
     "    return as_int(cfg, \"request-limit-fleet\")\n", "    return FLEET_LIMIT_FLOOR\n", "test_serve_rate_fleet"),
    ("usage-threshold", "the 7-day window refuses one percent late",
     "if pct is not None and pct >= limit:", "if pct is not None and pct > limit:", "test_serve_usage"),
    ("usage-reset-window", "a usage file whose window already reset still counts",
     "        if isinstance(resets, (int, float)) and resets < t:\n            continue\n", "", 
     "test_serve_usage_ignores_a_window_that_already_reset"),
    ("usage-exempt", "request-usage-exempt is ignored",
     ' or req["name"] in as_list(ctx.cfg["request-usage-exempt"])', '', "test_serve_usage"),
    ("usage-verbs", "stopping verbs are refused for usage too",
     'if req["verb"] not in STARTING or ', 'if ', "test_serve_usage"),
    ("trust-neighbor", "any untrusted directory refuses every launch",
     "        if proj is None or proj in untrusted:", "        if True:", "test_serve_trust"),
    ("trust-verbs", "down needs trust too",
     'if req["verb"] not in ("up", "resume", "init"):\n        return None\n', "if False:\n        return None\n", "test_serve_trust"),
    ("trust-fail-closed", "an unreadable trust state lets the launch through",
     '    return f"workspace trust could not be read (claude-trust-check exit {rc})"', "    return None",
     "test_serve_trust_unknown_state_fails_closed"),
    ("snapshot-unknown", "a seat the snapshot reads UNKNOWN is started",
     'if req["verb"] in STARTING and seat.get("state") == "unknown":', 'if False:', "test_serve_snapshot_unknown_seat"),
    ("snapshot-stopping", "a seat the snapshot reads UNKNOWN cannot be stopped",
     'if req["verb"] in STARTING and seat.get("state") == "unknown":', 'if seat.get("state") == "unknown":',
     "test_serve_snapshot_unknown_seat_may_still_be_stopped"),
    ("snapshot-age", "a stale snapshot is accepted",
     "    if ctx.t - taken > limit:\n", "    if False:\n", "test_serve_snapshot_stale"),
    ("snapshot-seats-machine-list", "the machine lists are read with plain --values, which prints a list whole",
     'machines = decl_pairs("--values-list", "canonicalMachines")', 'machines = decl_pairs("--values", "canonicalMachines")',
     "test_snapshot_seats_are_the_per_seat_test_in_record_order"),
    ("snapshot-seats-twice", "a name two projects declare is a seat",
     "if n and owners[n] == 1 and p in with_dir", "if n and p in with_dir",
     "test_snapshot_seats_are_the_per_seat_test_in_record_order"),
    ("snapshot-seats-launch-dir", "a seat with no launch directory is a seat",
     " and p in with_dir and p in here]", " and p in here]",
     "test_snapshot_seats_are_the_per_seat_test_in_record_order"),
    ("live-process-reused-pid", "a reused pid counts as the live process",
     "return not proc_start or (len(fields) > 19 and fields[19] == str(proc_start))", "return True",
     "test_serve_a_reused_pid_does_not_refuse_up"),
    ("live-process-gone-pid", "a record whose pid is gone counts as the live process",
     "        except (OSError, IndexError):\n            return False\n", "        except (OSError, IndexError):\n            return True\n",
     "test_serve_a_record_whose_pid_is_gone_does_not_refuse_up"),
    ("live-process-name", "any live process refuses",
     'if not isinstance(d, dict) or d.get("name") != name or not isinstance(d.get("pid"), int):\n            continue\n        if pid_alive(d["pid"], str(d.get("procStart") or "")):\n            found.append',
     'if not isinstance(d, dict) or not isinstance(d.get("pid"), int):\n            continue\n        if pid_alive(d["pid"], str(d.get("procStart") or "")):\n            found.append',
     "test_serve_a_live_process_under_another_name_does_not_refuse_up"),
    ("unlisted-busy", "a done seat whose process is busy is stopped",
     '    if not statuses or any(st != "idle" for st in statuses):\n        return Wait(f"\'{name}\' has no live row',
     '    if not statuses:\n        return Wait(f"\'{name}\' has no live row',
     "test_serve_refresh_of_a_done_seat_whose_process_is_busy_waits"),
    ("unlisted-turn", "a done seat whose turn has not ended is stopped",
     "        if not ended:\n            return Wait(f\"'{name}' has a live process (pid {pid}) with no live row",
     "        if False:\n            return Wait(f\"'{name}' has a live process (pid {pid}) with no live row",
     "test_serve_done_seat_with_an_idle_record_but_an_unfinished_turn_waits"),
    ("unlisted-transcript", "a done seat whose transcript cannot be read is stopped",
     "        if ended is None:\n            return (f\"'{name}' has a live process",
     "        if False:\n            return (f\"'{name}' has a live process",
     "test_serve_done_seat_with_an_unreadable_transcript_is_refused"),
    ("working-state", "any listed state counts as idle",
     'if state not in as_list(ctx.cfg["request-idle-states"]):', 'if False:',
     "test_serve_working_waits_until_the_session_is_idle"),
    ("working-list", "an unreadable sessions list lets a stop through",
     '        return "the sessions list (claude agents --json) could not be read, so work in flight cannot be ruled out"',
     "        return None", "test_serve_an_unreadable_sessions_list_refuses_a_stop"),
    ("working-transcript", "an unreadable transcript lets a stop through",
     "    if ended is None:\n        return f\"'{req['name']}''s transcript cannot be read",
     "    if False:\n        return f\"'{req['name']}''s transcript cannot be read",
     "test_serve_an_unreadable_transcript_refuses_a_stop"),
    ("working-turn", "a turn in progress does not hold a stop",
     "    if not ended:\n        return Wait(f\"'{req['name']}' is working: its transcript's last turn has not ended\")",
     "    if False:\n        return Wait(f\"'{req['name']}' is working: its transcript's last turn has not ended\")",
     "test_serve_working_row_with_an_idle_record_but_an_unfinished_turn_waits"),
    ("working-wait", "a busy session's request is refused instead of left queued",
     "    if isinstance(detail, Wait):\n", "    if False:\n", "test_serve_working_waits_until_the_session_is_idle"),
    ("working-since", "a waiting request forgets when its wait began",
     'since = prior.get("since") if prior.get("outcome") == "waiting" else None', "since = None",
     "test_serve_working_waits_until_the_session_is_idle"),
    ("working-stuck-no-record", "a working row with no pid record counts as idle",
     '    if not statuses:\n        return "no live pid record says the session is idle"',
     '    if False:\n        return "no live pid record says the session is idle"',
     "test_serve_working_row_with_no_pid_record_waits"),
    ("working-stuck-busy", "a working row whose pid record is not idle counts as idle",
     "    if any(st != \"idle\" for st in statuses):\n        return f\"the session's own pid record says '{', '.join(statuses)}', not idle\"\n    return None\n\n\ndef check_working",
     "    if False:\n        return f\"the session's own pid record says '{', '.join(statuses)}', not idle\"\n    return None\n\n\ndef check_working",
     "test_serve_working_row_whose_record_says_shell_waits"),
    ("working-waiting-for", "a blocked row with a waitingFor counts as parked",
     'if not ((state == "blocked" and not row.get("waitingFor") and parked is None)', 'if not ((state == "blocked" and parked is None)',
     "test_serve_blocked_with_a_real_waiting_for_waits"),
    ("parked-since-start", "a handoff recorded before the session started counts as parked",
     "    if set_at <= start:\n", "    if False:\n", "test_serve_blocked_session_parked_before_it_started_waits"),
    ("parked-placed", "a pointer outside the placed handoffs counts as parked",
     "if os.path.commonpath([root, os.path.realpath(target)]) != root:", "if False:",
     "test_serve_a_pointer_outside_the_placed_handoffs_waits"),
    ("parked-busy-record", "a blocked row whose pid record is busy counts as parked",
     '    if any(st != "idle" for st in statuses):\n        return f"the session\'s own pid record says \'{\', \'.join(statuses)}\', not idle"\n    return handoff_since_start(name, session_id)',
     '    return handoff_since_start(name, session_id)', "test_serve_blocked_session_whose_record_is_busy_waits"),
    ("gone-pid-record", "a live pid record does not count as a process behind the session",
     '    holders = live_pid_records(name)\n    if holders:\n        return f"a live process still holds the name ({holders[0]})"',
     '    holders = []\n    if holders:\n        return f"a live process still holds the name ({holders[0]})"',
     "test_serve_stopped_but_a_live_pid_record_holds_the_name_waits"),
    ("gone-roster-worker", "a roster worker does not count as a process behind the session",
     "    if session_id and session_id in ids:\n", "    if False:\n", "test_serve_stopped_but_the_roster_lists_a_worker_waits"),
    ("gone-roster-unreadable", "an unreadable roster reads as no workers",
     '    if ids is None:\n        return f"the daemon roster ({ROSTER}) cannot be read, so a running worker cannot be ruled out"\n',
     '    ids = ids if ids is not None else set()\n', "test_serve_an_unreadable_roster_waits"),
    ("gone-no-session", "a row with no session id counts as having no worker",
     "    if need_session and not session_id:\n", "    if False:\n", "test_serve_resume_is_refused_for_a_row_with_no_session_id"),
    ("resume-listed", "resume respawns a listed row whatever runs it",
     "        if gone is None:\n            req[\"_admitted\"] = f\"listed", "        if True:\n            req[\"_admitted\"] = f\"listed",
     "test_serve_resume_of_a_listed_row_with_a_live_pid_record_is_refused"),
    ("resume-confirmation", "a respawn is confirmed with no process behind it",
     "            if process_present(name, sid):", "            if True:", "test_serve_a_respawn_that_brings_no_process_up_fails"),
    # --- the runner itself
    ("runner-lock", "two runners serve one queue",
     "            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)", "            pass", "test_serve_a_second_runner_leaves_the_queue_to_the_first"),
    ("runner-audit", "a served request leaves no audit line",
     "    append_audit(entry)\n    ctx.audit.append(entry)\n", "    ctx.audit.append(entry)\n", "test_serve_a_valid_request_runs_its_verb"),
    ("runner-init", "init does not launch the seat",
     'extra = ["--up"] if req["verb"] == "init" else []', "extra = []", "test_serve_init"),
    ("runner-path", "a launched session inherits the queue's uv environment",
     "             if d and os.path.realpath(d) != own_bin]", "             if d]", "test_contract_a_launch_inherits_the_callers_path"),
    # --- request
    ("request-never-touch", "request queues a never-touch canonical",
     '    if name in as_list(cfg["never-touch"]):\n', "    if False:\n", "test_request_never_touch_default"),
    ("request-declared", "request queues a canonical this machine does not run",
     '    if not ok:\n        die(f"request: {why}; refusing to queue it", 1)', '    if False:\n        die(f"request: {why}; refusing to queue it", 1)',
     "test_request_refuses_a_canonical_declared_for_another_machine"),
    ("request-verb", "request queues a verb the queue does not accept",
     "    if verb not in VERBS:\n", "    if False:\n", "test_request_refuses_verb[dedupe]"),
    ("request-flag", "request accepts --force",
     '        if a in ("--force", "--stub"):\n', '        if False:\n', "test_request_refuses_flag[--force]"),
    ("request-reason", "request queues with no reason",
     "    if not reason:\n", "    if False:\n", "test_request_requires_a_reason"),
    ("request-as", "--as can contradict the calling session",
     "    if derived and claimed and claimed != derived:\n", "    if False:\n", "test_request_as_cannot_contradict_the_calling_session"),
    ("request-requester", "request queues with no requester",
     "    if not requester:\n", "    if False:\n", "test_request_without_a_requester_is_refused"),
    ("request-queued", "request queues a second request for one canonical",
     "    if pend:\n", "    if False:\n", "test_request_refuses_a_second_request_for_a_queued_canonical"),
    # --- snapshot
    ("snapshot-sandbox", "snapshot writes from inside a sandbox",
     "    if in_sandbox():\n", "    if False:\n", "test_snapshot_refuses_inside_a_sandbox"),
    ("snapshot-unknown-state", "an unreadable source reads as dead",
     "        elif unread:\n", "        elif False:\n", "test_snapshot_unreadable_list_is_unknown_never_dead"),
    ("context-sidechain", "a subagent's reply counts as the seat's context",
     'if not isinstance(e, dict) or e.get("isSidechain") or e.get("type") != "assistant":',
     'if not isinstance(e, dict) or e.get("type") != "assistant":', "test_snapshot_context_is_the_last_main_thread_prompt"),
    ("context-1m", "a [1m] model is measured against 200k",
     'model.strip().lower().endswith("[1m]")', 'model.strip().lower().endswith("[2m]")',
     "test_snapshot_a_1m_model_is_measured_against_a_million_tokens"),
    ("context-over-window", "a prompt larger than the window is reported as over 100%",
     "    if tokens > window:\n", "    if False:\n", "test_snapshot_a_prompt_larger_than_the_window_names_the_window_as_wrong"),
]


@pytest.fixture
def mutant_dir():
    """A directory under $TMPDIR as given, removed afterwards (pytest's own tmp_path would leave a
    pytest-of-<user> directory behind in $TMPDIR)."""
    d = Path(tempfile.mkdtemp(prefix="fcq-mutant-", dir=ORIGINAL_TMP))
    yield d
    shutil.rmtree(d, ignore_errors=True)


@pytest.mark.mutant
@pytest.mark.parametrize("name,description,find,replace,test", MUTANTS, ids=[m[0] for m in MUTANTS])
def test_mutant_is_caught(mutant_dir, name, description, find, replace, test):
    status, output = run_one_test(test, make_mutant(mutant_dir, find, replace), mutant_dir)
    # Status 1 is "tests failed"; 2 to 5 would be an interrupted, broken or empty run, which says
    # nothing about the test.
    assert status == 1 and re.search(r"\b1 failed\b", output), \
        "mutant %s (%s) was not caught by %s:\n%s" % (name, description, test, output[-3000:])


@pytest.mark.mutant
def test_mutant_harness_passes_an_unchanged_copy(mutant_dir):
    copy = mutant_dir / "fleet-canonicals-queue-copy"
    shutil.copy2(QUEUE_SRC, copy)
    status, output = run_one_test("test_serve_paused", copy, mutant_dir)
    assert status == 0 and re.search(r"\b1 passed\b", output), output[-3000:]


@pytest.mark.mutant
def test_mutant_fixture_refuses_a_replacement_that_changes_nothing(mutant_dir):
    with pytest.raises(pytest.fail.Exception, match="occurs 0 times"):
        make_mutant(mutant_dir, "text that is not in the queue", "x")
    with pytest.raises(pytest.fail.Exception, match="changed nothing"):
        make_mutant(mutant_dir, "VERB_TIMEOUT = 600", "VERB_TIMEOUT = 600")


if __name__ == "__main__":
    # pytest-xdist runs the cases on several workers. The landing lane is `-m "not mutant"` rather
    # than a plugin object, because each worker collects for itself and needs the same selection.
    workers = str(min(8, os.cpu_count() or 2))
    lane = [] if os.environ.get("RUN_MUTANTS") == "1" else ["-m", "not mutant"]
    # pytest (and xdist) make a pytest-of-<user> directory under $TMPDIR for tmp_path; this file
    # does not use tmp_path, so its basetemp is one directory of its own, removed afterwards.
    base = tempfile.mkdtemp(prefix="fcq-basetemp-", dir=ORIGINAL_TMP)
    try:
        status = pytest.main([__file__, "-q", "-p", "no:cacheprovider", "--basetemp", base,
                              "-o", "markers=mutant: a mutant meta-test, run in the landing lane only",
                              "-n", workers, *lane, *sys.argv[1:]])
    finally:
        shutil.rmtree(base, ignore_errors=True)
    sys.exit(status)
