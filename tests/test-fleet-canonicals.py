#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2", "pytest-xdist==3.8.0"]
# ///
"""Tests for `fleet-canonicals` (private_dot_local/bin/executable_fleet-canonicals, bash): the roster
and status verbs, dedupe, the handoff pointer and the freshness gate, `up`, `down`, `refresh`,
`resume`, `clean`, `init`, the per-launch temp roots, the launch environment, and the autostart
setting. The request queue is tests/test-fleet-canonicals-requests.py's.

Run: npx nx run suite-fleet-canonicals:test
 or: uv run --script tests/test-fleet-canonicals.py [-k <pattern>]

Every case drives the real tool as a process (`bash fleet-canonicals <verb> ...`), the way a user or
a launcher does. Nothing here reaches a real session or real state: the fleet record, the state
directory, the sessions listing (`claude agents --json`, injected through $FLEET_AGENTS_JSON_CMD),
the transcripts, the per-process records, /proc, the snapshot, the launcher (`claude`) and the temp
root prefix are fixtures under one scratch directory per case.

HOW THIS RUNS FAST
==================
The cases are independent: each builds its own scratch world under its own `tmp_path` (the fleet
record, a state directory with a handoff pointer per seat, a sessions listing, transcripts), reads
nothing another case wrote and leaves nothing behind. pytest-xdist therefore runs them on several
workers in any order (-n, set in the entry point at the end of this file). The time is the tool's own
process starts (it calls `fleet-decl`, `jq` and `uv run ... fleet-canonicals-queue`), so the cases
are many and small rather than few and long; the tool is not changed to start fewer processes.

HERMETIC
========
* The `fleet-decl` under test is the one in this source tree, first on PATH, not a deployed copy.
* Every environment variable the tool reads is pointed at a fixture (config, launch fragment,
  `launchctl managername` hook, pid records, /proc, handoff trees, state, snapshot, transcripts,
  temp-root prefix, launcher), $SSH_CONNECTION is unset, and HOME and the XDG directories are
  empty directories of the case's own. No case reads the machine's live sessions or state, or writes
  under the real HOME.
* Git ignores the machine's global and system configuration (tests/git-isolated.gitconfig), so no
  commit hook or signing setting reaches a scratch repository.
* The fixture pids are above any pid_max, so a signal sent to one can never reach a real process,
  and none of them is an ancestor of this process (checked once per worker): the tool names the
  session it runs inside by walking its ancestry, and a fixture pid that was a real ancestor would
  read as "this session".
* A launch makes a temp root under $FLEET_TMPROOT_PREFIX (a fixture). When this file runs through
  its own entry point it also compares the real /tmp before and after the whole run, across every
  worker, and fails if a `c-<name>-XXXXXX` directory appeared that no running session owns.
* No case waits on a clock: a real wait is only the tool's own `sleep 1` while a signaled test
  process is still exiting.

THE TOOL UNDER TEST is private_dot_local/bin/executable_fleet-canonicals. FLEET_CANONICALS_TOOL
points the suite at a modified COPY of it (a mutant: one defect planted on purpose, to see a case
fail); a copy must sit beside copies of the queue script it runs, which the tool finds by its own
path.

PARITY: tests/test-fleet-canonicals.parity.md maps each check of the shell suite this file replaced to
the test that makes it now. The label of each check is the message of its assertion here.
"""
import contextlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
BIN = HERE.parent / "private_dot_local" / "bin"
TOOL = Path(os.environ.get("FLEET_CANONICALS_TOOL") or BIN / "executable_fleet-canonicals")
DECL = BIN / "executable_fleet-decl"
GIT_CONFIG = HERE / "git-isolated.gitconfig"
# $TMPDIR as the machine gives it, read before anything changes it.
ORIGINAL_TMP = tempfile.gettempdir()
HOST = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
REAL_SLEEP = shutil.which("sleep") or "/bin/sleep"
# Where a launch that was not redirected would leave its temp root, and the directory the end check
# watches. Only the check's own test of itself points the second elsewhere.
WATCH_TMP = os.environ.get("FLEET_SUITE_WATCH_TMP") or "/tmp"

# Fixture pids: above any pid_max (4194304 at most), so a signal to one reaches nothing.
P1, P2, P3, P4, P5, P6, P7 = 4999911, 4999922, 4999933, 4999944, 4999955, 4999966, 4999977
FIXTURE_PIDS = (P1, P2, P3, P4, P5, P6, P7)
FAKE_PID = 4999991


def _clean_path():
    """PATH without the directory of this interpreter: `uv run --script` puts its environment first."""
    own = os.path.realpath(os.path.dirname(sys.executable))
    parts = [d for d in os.environ.get("PATH", "").split(os.pathsep) if d and os.path.realpath(d) != own]
    return os.pathsep.join(parts)


CLEAN_PATH = _clean_path()


class R:
    """A tool run: its exit status and its stdout and stderr together (what `2>&1` gave), without the
    trailing newlines a command substitution drops."""

    def __init__(self, rc, out):
        self.rc, self.out = rc, out

    def __str__(self):
        return self.out

    def __contains__(self, s):
        return s in self.out

    def __repr__(self):
        return "rc %s\n%s" % (self.rc, self.out)


def seq(text, *parts):
    """True when each part occurs in `text`, in that order, without overlap: what the shell pattern
    *"a"*"b"* means."""
    pos = 0
    for p in parts:
        i = str(text).find(p, pos)
        if i < 0:
            return False
        pos = i + len(p)
    return True


def chk(cond, label, detail=""):
    """One check: its label is the assertion message, with what the tool printed after it."""
    assert cond, "%s: %s" % (label, detail) if detail != "" else label


def iso(epoch, frac=".000Z"):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(epoch)) + frac


def gstamp(epoch):
    """The minute stamp of a standard handoff name (local time), YYYY-MM-DD-HHMM."""
    return time.strftime("%Y-%m-%d-%H%M", time.localtime(epoch))


def old_mtime(path):
    """What `touch -t 202601010000` did: the local time 2026-01-01 00:00."""
    t = time.mktime((2026, 1, 1, 0, 0, 0, 0, 0, -1))
    os.utime(path, (t, t), follow_symlinks=False)


def _ancestors():
    chain, p = [], os.getpid()
    while p and p > 1:
        chain.append(p)
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(p)], capture_output=True, text=True).stdout.strip()
        p = int(out) if out.isdigit() else 0
    return chain


@pytest.fixture(scope="session", autouse=True)
def world(tmp_path_factory):
    """What every case only reads, made once per worker: the source `fleet-decl` on a PATH directory,
    the launcher stub, the uv cache, and the checks that this worker may run at all."""
    for tool in ("jq", "yq", "uv", "git", "bash"):
        if not shutil.which(tool):
            pytest.fail("%s is required" % tool)
    assert TOOL.is_file(), "tool not found at %s" % TOOL
    assert DECL.is_file(), "fleet-decl source not found at %s" % DECL
    # A fixture pid that is a real ancestor of this process would make the tool call a FIXTURE
    # session "this session": an unrelated assertion would fail and point nowhere near the cause.
    # Fixture pids this high make it impossible; the check names the case if that ever changes.
    clash = set(FIXTURE_PIDS) & set(_ancestors())
    assert not clash, "fixture pid %s is a real ancestor of this test process; raise FIXTURE_PIDS" % sorted(clash)
    w = tmp_path_factory.mktemp("world")
    (w / "bin").mkdir()
    os.symlink(DECL, w / "bin" / "fleet-decl")
    # A launcher stub: every launch appends its full argument list, so a case asserts the COMPOSED command.
    stub = w / "claude-stub"
    stub.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$TMPROOT_LAUNCHLOG\"\n")
    stub.chmod(0o755)
    (w / "uv-cache").mkdir()
    return w


RECORD_HEAD = "projects:\n"
RECORD_SEATS = [
    # key, scope, canonical, launch dir, model, extra lines
    ("alpha", "alpha", "alpha-canonical", "alpha", "fable", ""),
    ("beta", "beta", "beta-canonical", "beta", "fable", ""),
    ("delta", "proj", "delta-canonical", "proj", "fable", ""),
    ("epsilon", "consulting/example.com/repo/branch", "epsilon-canonical", "consulting/example.com/repo/branch", "opus", ""),
    ("eta", "eta", "eta-canonical", "eta", "fable", ""),
    ("self", "self", "self-canonical", "self", "fable", ""),
    ("theta", "theta", "theta-canonical", "theta", "fable", "    leakPolicy: private\n"),
    ("three", "three", "three-canonical", "three", "fable", ""),
    ("two", "two", "two-canonical", "two", "fable", ""),
    ("zeta", "zeta", "zeta-canonical", "zeta", "fable", ""),
    ("self2", "self2", "self2-canonical", "self2", "fable", ""),
]


def seat_yaml(key, scope, canonical, launch_dir, model, extra="", identity=None, machines=None):
    return ('  %s:\n    scope: %s\n    canonical: %s\n    canonicalIdentity: "%s"\n    canonicalLaunchDir: %s\n'
            "    canonicalLaunchModel: %s\n%s    canonicalMachines: [%s]\n") % (
        key, scope, canonical, identity or "the canonical session for %s" % canonical[:-len("-canonical")],
        launch_dir, model, extra, machines or HOST)


def record_text(seats=RECORD_SEATS, elsewhere=True):
    """The fleet record: a canonical exists because it is declared here and runs on this machine
    because canonicalMachines names it. `elsewhere` is declared for ANOTHER machine."""
    text = RECORD_HEAD + "".join(seat_yaml(*s) for s in seats)
    if elsewhere:
        text += seat_yaml("elsewhere", "other", "elsewhere-canonical", "other", "opus", machines="some-other-host")
    return text


ALL_NAMES = [s[2] for s in RECORD_SEATS] + ["elsewhere-canonical"]
ALL_DIRS = [s[3] for s in RECORD_SEATS] + ["other"]

# A fixture fleet: one healthy, one duplicated (older + newer), one missing entirely.
def default_agents():
    return [{"pid": P1, "id": "aaa1", "cwd": "/x", "kind": "background", "startedAt": 1000, "sessionId": "s1",
             "name": "alpha-canonical", "status": "idle", "state": "done"},
            {"pid": P2, "id": "bbb2", "cwd": "/y", "kind": "background", "startedAt": 1000, "sessionId": "s2",
             "name": "beta-canonical", "status": "idle", "state": "done"},
            {"pid": P3, "id": "ccc3", "cwd": "/y", "kind": "background", "startedAt": 9000, "sessionId": "s3",
             "name": "beta-canonical", "status": "busy", "state": "running"}]


class Fx:
    """One case's world, all new: the shell suite's TMPROOT, with its exported environment."""

    def __init__(self, root, w):
        self.T, self.W = root, w
        T = self.T
        self.now = int(time.time())
        self.state = T / "fcstate"
        self.hrepo = T / "hrepo"
        self.ftd = T / "ftd"
        self.launchlog = T / "launches.log"
        self.pids, self.proc = T / "pids", T / "proc"
        for d in (self.state, self.hrepo, self.ftd / "proj", self.pids, self.proc, T / "tmproots", T / "home", T / "run", T / "tmp"):
            d.mkdir(parents=True, exist_ok=True)
        self.launchlog.write_text("")
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("FLEET_", "CLAUDE_", "XDG_")) and k not in ("SSH_CONNECTION", "CANONICAL_ROSTER")}
        self.env.update({
            "PATH": str(w / "bin") + os.pathsep + CLEAN_PATH,
            "HOME": str(T / "home"), "XDG_STATE_HOME": str(T / "home" / ".local" / "state"),
            "XDG_CONFIG_HOME": str(T / "home" / ".config"), "XDG_RUNTIME_DIR": str(T / "run"),
            "TMPDIR": str(T / "tmp"), "UV_CACHE_DIR": str(w / "uv-cache"),
            "GIT_CONFIG_GLOBAL": str(GIT_CONFIG), "GIT_CONFIG_NOSYSTEM": "1", "TEST_GIT_ISOLATED": "1",
            # No config file, no launch fragment, no launchd-domain check: each case sets what it needs.
            "FLEET_CANONICALS_CONFIG": str(T / "no-config"), "FLEET_LAUNCH_ENV": str(T / "no-launch-env"),
            "FLEET_MANAGERNAME_CMD": "",
            "FLEET_PID_RECORD_DIR": str(self.pids), "FLEET_PROC_ROOT": str(self.proc),
            "FLEET_RECORD": str(T / "rec.yaml"), "FLEET_ROOT": str(T), "FLEET_STATE": str(self.state),
            "FLEET_HANDOFFS_SEARCH": str(T), "FLEET_TRANSCRIPT_DIR": str(self.ftd),
            "FLEET_SNAPSHOT_FILE": str(T / "sessions.json"), "FLEET_SNAPSHOT_MAX_AGE": "86400",
            "FLEET_TMPROOT_PREFIX": str(T / "tmproots"),
            "FLEET_CLAUDE_CMD": str(w / "claude-stub"), "TMPROOT_LAUNCHLOG": str(self.launchlog),
            "FLEET_AGENTS_JSON_CMD": "cat %s" % (T / "agents.json"),
        })
        # A session snapshot holding no seats, which every case reads: status, up, clean and refresh
        # refuse without one (since 2026-11-17), and a seat a fresh snapshot does not list is read
        # directly, which is what these cases test. Its own file and a day's max age, so a case that
        # sets its own FLEET_STATE still finds it and a slow run does not age it out. What the
        # snapshot itself decides (missing, stale, unknown, live) is the queue suite's to test.
        (T / "sessions.json").write_text(json.dumps({"version": 1, "takenAt": self.now, "seats": {}}) + "\n")
        (T / "rec.yaml").write_text(record_text())
        self.agents("agents.json", default_agents())
        self.ftd_from(T / "agents.json")
        (T / "roster").write_text("alpha-canonical\nbeta-canonical\n# a comment\ngamma-canonical\n")
        # Every declared launch directory exists, and every seat has a recorded handoff pointer: a
        # launch refuses without either, correctly, so a case about something else needs both.
        for d in ALL_DIRS:
            (T / d).mkdir(parents=True, exist_ok=True)
        for n in ALL_NAMES:
            f = self.first_launch_handoff(self.state, n)
            self.pointer(self.state, n, f, self.now)

    # ---- fixtures
    @staticmethod
    def first_launch_handoff(state, name):
        """The handoff `init` writes for a seat that never ran, in the shape the gate recognizes it by.
        A seat with no listing row and no transcript passes the gate on nothing else, and the default
        fixture seats are exactly that: declared, never run."""
        f = Path(state) / "stub-handoffs" / ("2026-01-01-000000-%s-first-launch.md" % name)
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text("fixture first-launch handoff for %s\n" % name)
        return f

    def agents(self, name, rows):
        """Write a sessions listing under the case's directory; returns its path."""
        p = self.T / name
        p.write_text(json.dumps(rows))
        return p

    def cat(self, path):
        return "cat %s" % path

    def ftd_from(self, listing, ftd=None):
        """A transcript for each listed row that has a sessionId and a startedAt, whose first entry is
        at that start (so the true start equals the listed one). The gate refuses a listed session
        whose transcript it cannot read."""
        d = (ftd or self.ftd) / "proj"
        d.mkdir(parents=True, exist_ok=True)
        for r in json.loads(Path(listing).read_text()):
            sid, st = r.get("sessionId"), r.get("startedAt")
            if sid is None or st is None:
                continue
            if st > 100000000000:
                st //= 1000
            (d / (sid + ".jsonl")).write_text(json.dumps({"type": "user", "isSidechain": False, "timestamp": iso(st)}) + "\n")

    def pointer(self, state, name, target, set_at):
        """Record a handoff pointer the way `handoff --set` does: the path, then `# set-at <epoch>`."""
        Path(state).mkdir(parents=True, exist_ok=True)
        (Path(state) / (name + ".handoff")).write_text("%s\n# set-at %s\n" % (target, set_at))

    def hcommit(self, d, file, epoch=None):
        """Commit <file> in the repository at <d> (made if absent) at <epoch> (default now). The handoff
        gate dates a document whose name carries no stamp by the commit that added it."""
        d = Path(d)
        d.mkdir(parents=True, exist_ok=True)
        e = epoch if epoch is not None else int(time.time())
        env = dict(self.env, GIT_AUTHOR_DATE="@%s +0000" % e, GIT_COMMITTER_DATE="@%s +0000" % e)
        if not (d / ".git").is_dir():
            subprocess.run(["git", "-C", str(d), "init", "-q"], check=True, env=env, capture_output=True)
        subprocess.run(["git", "-C", str(d), "add", "--", str(file)], check=True, env=env, capture_output=True)
        subprocess.run(["git", "-C", str(d), "commit", "-q", "-m", "add %s" % file], check=True, env=env, capture_output=True)

    def hdoc(self, name, epoch=None, text="orientation\n"):
        """A committed handoff in the fixture repository."""
        (self.hrepo / name).write_text(text)
        self.hcommit(self.hrepo, name, epoch)
        return self.hrepo / name

    # ---- running the tool
    def run(self, *args, env=None, timeout=300, tool=None):
        """The real tool as a process; `env` overrides the case's environment (a None value unsets)."""
        e = dict(self.env)
        for k, v in (env or {}).items():
            if v is None:
                e.pop(k, None)
            else:
                e[k] = str(v)
        p = subprocess.run(["bash", str(tool or TOOL), *map(str, args)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, timeout=timeout, env=e)
        return R(p.returncode, p.stdout.rstrip("\n"))

    def sh(self, script, *args, env=None):
        """`bash -c script _ args`: for the checks that source one function out of the tool."""
        e = dict(self.env)
        for k, v in (env or {}).items():
            if v is None:
                e.pop(k, None)
            else:
                e[k] = str(v)
        p = subprocess.run(["bash", "-c", script, "_", *map(str, args)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, env=e)
        return R(p.returncode, p.stdout.rstrip("\n"))

    def launches(self):
        return self.launchlog.read_text()

    # ---- fixture processes
    @contextlib.contextmanager
    def sleeper(self, n=1):
        """Real, harmless test-owned `sleep` processes standing in for sessions to stop. A thread reaps
        each as soon as it exits, so a signaled one stops answering `kill -0` at once instead of
        lingering as a zombie."""
        procs = [subprocess.Popen([REAL_SLEEP, "300"]) for _ in range(n)]
        for p in procs:
            threading.Thread(target=p.wait, daemon=True).start()
        try:
            yield procs
        finally:
            for p in procs:
                with contextlib.suppress(OSError):
                    p.kill()

    def live_holder(self, pid, name, sid, start="777"):
        """A per-process record and a /proc entry for a live process holding a seat's name."""
        (self.pids / ("%s.json" % pid)).write_text(json.dumps(
            {"pid": pid, "sessionId": sid, "kind": "bg", "name": name, "procStart": start, "status": "idle"}))
        (self.proc / str(pid)).mkdir(parents=True, exist_ok=True)
        (self.proc / str(pid) / "stat").write_text("%s (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 1 1\n" % (pid, start))

    def drop_holder(self, pid):
        (self.pids / ("%s.json" % pid)).unlink(missing_ok=True)
        shutil.rmtree(self.proc / str(pid), ignore_errors=True)


@pytest.fixture
def fx(tmp_path, world):
    f = Fx(tmp_path, world)
    yield f
    # The case's HOME and XDG directories stand where the real ones would, so a tool that wrote under
    # HOME (a cache, a state file) would leave something here: nothing may.
    left = sorted(str(p.relative_to(f.T / "home")) for p in (f.T / "home").rglob("*"))
    assert not left, "a case wrote under its HOME: %s" % left


def tool_text():
    return TOOL.read_text()


def function_body(text, name):
    """What `awk '/^name\\(\\)/,/^\\}/'` printed: from the function's first line to the next line that
    starts with a closing brace."""
    out, on = [], False
    for line in text.split("\n"):
        if not on and re.match(r"^%s\(\)" % re.escape(name), line):
            on = True
        if on:
            out.append(line)
            if line.startswith("}"):
                break
    return "\n".join(out)


# ============================================================================== the roster and dedupe

def rost(fx):
    return {"CANONICAL_ROSTER": fx.T / "roster"}


def test_status_reports_each_session_state(fx):
    r = fx.run("status", env=rost(fx))
    chk(seq(r.out, "alpha-canonical", "OK"), "single live session reports OK", "alpha: %s" % r.out)
    chk(seq(r.out, "beta-canonical", "DUPLICATE"), "two sessions with one name report DUPLICATE", "beta: %s" % r.out)
    chk(seq(r.out, "gamma-canonical", "MISSING"), "rostered but absent reports MISSING", "gamma: %s" % r.out)
    chk(r.rc == 1, "status exits non-zero when the fleet is not healthy", "status exit %s" % r.rc)


def test_dedupe_dry_run_targets_only_the_older_duplicate(fx):
    # dedupe must target the OLDER duplicate only, and must never touch a name with one session.
    out = fx.run("dedupe", "--dry-run", env=rost(fx)).out
    chk(str(P2) in out, "dedupe targets the older duplicate's pid", "dedupe target: %s" % out)
    chk(str(P3) not in out, "dedupe spares the newest session", "dedupe would kill the newest: %s" % out)
    chk(str(P1) not in out, "dedupe spares an unduplicated session", "dedupe would kill a lone session: %s" % out)
    # Stopping the process is not enough: a TERMed session stays in the `--all` listing as a `done`
    # row, so the agents view still has something to click. Reap must name the session ID it deletes.
    chk("id bbb2" in out, "dedupe names the row id it will delete, not just the pid",
        "dedupe would stop the process but leave the row: %s" % out)
    # `dedupe <name>` scopes to ONE canonical. The load-bearing assertion is the second: asking for a
    # name with no duplicate must leave the duplicated name ALONE; a scoping bug that ignored the
    # argument would still pass the first, because beta is what unscoped dedupe targets too.
    out = fx.run("dedupe", "--dry-run", "beta-canonical", env=rost(fx)).out
    chk(str(P2) in out, "dedupe <name> targets that canonical's older duplicate", "scoped dedupe missed its target: %s" % out)
    out = fx.run("dedupe", "--dry-run", "alpha-canonical", env=rost(fx)).out
    chk(str(P2) not in out, "dedupe <name> leaves every OTHER canonical alone",
        "scoped dedupe touched a name it was not given: %s" % out)
    chk("0 target(s)" in out, "dedupe on an already-clean name reports 0 targets", "clean name did not report 0: %s" % out)
    # Unscoped dedupe still walks the whole roster: the argument is optional, not required.
    out = fx.run("dedupe", "--dry-run", env=rost(fx)).out
    chk(str(P2) in out, "dedupe with no name still sweeps the fleet", "regression: %s" % out)


def test_dedupe_refuses_what_it_cannot_scope(fx):
    # An unknown name must be REFUSED. Reported as "0 target(s)" it is indistinguishable from a clean
    # fleet, so a typo would read as a completed dedupe.
    r = fx.run("dedupe", "--dry-run", "beta-canonicl", env=rost(fx))
    chk(r.rc != 0, "dedupe refuses a name that is not on the roster", "typo'd name exited 0: %s" % r.out)
    chk("target(s)" not in r.out, "a refused name does not report a target count", "refusal looked like a clean run: %s" % r.out)
    chk("beta-canonical" in r.out, "the refusal lists the valid names", "refusal unhelpful: %s" % r.out)
    r = fx.run("dedupe", "--dry-run", "alpha-canonical", "beta-canonical", env=rost(fx))
    chk(r.rc != 0, "dedupe refuses two names at once", "two names accepted: %s" % r.out)


def test_discovery_reads_the_fleet_record(fx):
    # Discovery with no roster variable: the FLEET RECORD is the manifest.
    out = fx.run("status").out
    chk(seq(out, "delta-canonical", "MISSING"), "discovers canonicals from the fleet record", "record discovery: %s" % out)
    # `list`: who exists and what each owns, from the record, FLEET-WIDE (not filtered by machine).
    r = fx.run("list")
    chk(r.rc == 0 and seq(r.out, "alpha-canonical", "the canonical session for alpha") and "elsewhere-canonical" in r.out,
        "list prints every declared canonical with its identity, fleet-wide", "list (rc=%s): %s" % (r.rc, r.out))
    r = fx.run("list", env={"FLEET_RECORD": fx.T / "does-not-exist.yaml"})
    chk(r.rc == 2 and "unreadable" in r.out, "list fails closed on an unreadable record (exit 2)",
        "list on a missing record should exit 2 and say unreadable (rc=%s): %s" % (r.rc, r.out))
    r = fx.run("list", "extra")
    chk(r.rc == 2, "list refuses arguments", "list with an argument should exit 2 (rc=%s): %s" % (r.rc, r.out))
    # A deeply nested launch directory: discovery is by declaration, so depth cannot affect it; this
    # is what would notice it regaining a depth limit.
    chk(seq(out, "epsilon-canonical", "MISSING"), "a deeply nested launch directory is still discovered",
        "nested canonical not discovered: %s" % out)
    # A canonical declared for a DIFFERENT machine is not this machine's to run: globbing had no way
    # to say that, so every host expected every canonical.
    chk("elsewhere-canonical" not in out, "a canonical declared for another machine is not expected here",
        "another machine's canonical leaked into this roster: %s" % out)


def test_up_dry_run_names_the_missing_and_spares_the_running(fx):
    # up starts real, long-lived sessions, so it is exercised through --dry-run. Both directions
    # matter: it must name what it WOULD start, and leave a running session alone.
    out = fx.run("up", "--dry-run").out
    chk(seq(out, "would start", "delta-canonical"), "up --dry-run names the missing session it would start", "up dry-run: %s" % out)
    # A rostered name that is not declared is a real gap, reported and not papered over.
    out = fx.run("up", "--dry-run", env=rost(fx)).out
    chk(seq(out, "REFUSED", "gamma-canonical"), "up refuses loudly for a rostered name that is not declared", "up refusal: %s" % out)
    # Asserted against the ROSTER invocation, where alpha and beta are expected AND already running:
    # against the discovery invocation it cannot fail, because alpha is not in that expected set.
    chk("alpha-canonical" not in out, "up leaves an already-running session alone", "up would relaunch a live session: %s" % out)
    chk("beta-canonical" not in out, "up leaves a duplicated-but-present name alone",
        "up touched a name that already has sessions: %s" % out)


CLAUDE_BIN = 'eval "$(sed -n "/^claude_bin()/p" "$1")"; claude_bin'


def test_claude_bin_resolves(fx):
    # REGRESSION GUARD. `claude_bin` was CALLED by cmd_dedupe and DEFINED NOWHERE, so dedupe stopped a
    # session's process and then died before deleting its row. Every dedupe case runs --dry-run,
    # which returns before that call, so the helper is asserted to RESOLVE without invoking the path
    # that signals anything.
    r = fx.sh(CLAUDE_BIN, TOOL, env={"FLEET_CLAUDE_CMD": None})
    chk(r.out == "claude", "claude_bin resolves to claude by default", "claude_bin default: %s" % r.out)
    # ONE override for the binary: launches, row deletion, attach and fork all go through it.
    r = fx.sh(CLAUDE_BIN, TOOL, env={"FLEET_CLAUDE_CMD": "/usr/bin/true"})
    chk(r.out == "/usr/bin/true", "claude_bin honors FLEET_CLAUDE_CMD", "claude_bin override: %s" % r.out)


def test_resume_at_argument_handling(fx):
    # Only the argument handling is asserted: the verb's whole job is to sleep and then launch.
    r = fx.run("resume-at", "--at", "1970-01-01 00:00:00", "--dry-run")
    chk("dry run" in r.out, "resume-at --dry-run does not sleep or launch", "resume-at dry run: %s" % r.out)
    r = fx.run("resume-at", "--at", "not-a-time", "--dry-run")
    chk(r.rc != 0 and "could not parse time" in r.out, "resume-at refuses an unparseable time",
        "resume-at accepted a bad time (rc=%s): %s" % (r.rc, r.out))
    r = fx.run("resume-at", "--bogus")
    chk(r.rc != 0 and "unknown argument" in r.out, "resume-at refuses an unknown argument",
        "resume-at accepted an unknown argument (rc=%s): %s" % (r.rc, r.out))


# ============================================================================== the handoff pointer

def test_handoff_pointer_never_guesses(fx):
    # The property under test is that this NEVER guesses. Every way of not having a usable handoff
    # must fail loudly, because the failure it replaces was silent: a stale path baked in still launches.
    hstate = fx.T / "hstate"
    real = fx.T / "real-handoff.md"
    real.write_text("hello\n")

    def hoff(*a):
        return fx.run("handoff", *a, env={"FLEET_STATE": hstate})

    r = hoff("alpha-canonical")
    chk(r.rc != 0 and "no handoff recorded" in r.out, "handoff fails loudly when no pointer exists",
        "handoff with no pointer (rc=%s): %s" % (r.rc, r.out))
    r = hoff("alpha-canonical", "--set", fx.T / "absent.md")
    chk(r.rc != 0 and "no such file" in r.out, "handoff --set refuses a pointer to a missing file",
        "handoff --set missing target (rc=%s): %s" % (r.rc, r.out))
    r = hoff("alpha-canonical", "--set", real)
    chk(r.rc == 0 and r.out == str(real), "handoff --set records an absolute path and echoes it",
        "handoff --set (rc=%s): %s" % (r.rc, r.out))
    r = hoff("alpha-canonical")
    chk(r.rc == 0 and r.out == str(real), "handoff resolves a recorded pointer", "handoff resolve (rc=%s): %s" % (r.rc, r.out))
    # The staleness case the design exists for: the pointer survives, its target does not.
    real.unlink()
    r = hoff("alpha-canonical")
    chk(r.rc != 0 and "points at a missing file" in r.out, "handoff fails when the pointer names a file that is gone",
        "handoff dangling pointer (rc=%s): %s" % (r.rc, r.out))
    (hstate / "beta-canonical.handoff").write_text("\n")
    r = hoff("beta-canonical")
    chk(r.rc != 0 and "is empty" in r.out, "handoff fails on an empty pointer file", "handoff empty pointer (rc=%s): %s" % (r.rc, r.out))
    r = hoff()
    chk(r.rc != 0 and "need a canonical name" in r.out, "handoff refuses a missing name", "handoff no name (rc=%s): %s" % (r.rc, r.out))


def test_up_refuses_an_unrecognized_word(fx):
    # Regression: the old parser checked only $1, so a stray argument silently disabled --dry-run and
    # launched a real canonical (observed live: `up foo --dry-run` started one). An unrecognized
    # word is refused as an unrecognized NAME; it must never be read as "no filter".
    r = fx.run("up", "foo", "--dry-run")
    chk(r.rc != 0 and "'foo' is not a canonical declared for this machine" in r.out,
        "up refuses an unrecognized name instead of launching", "up with a stray argument (rc=%s): %s" % (r.rc, r.out))
    chk("starting" not in r.out, "up launches nothing when it refuses", "up launched despite a bad argument: %s" % r.out)


def test_up_and_start_name_a_canonical(fx):
    # delta is declared and NOT running, beta is running: that asymmetry is what makes the name
    # filter falsifiable.
    out = fx.run("up", "delta-canonical", "--dry-run").out
    chk(seq(out, "would start", "delta-canonical"), "up <name> starts that canonical", "up <name>: %s" % out)
    out = fx.run("start", "delta-canonical", "--dry-run").out
    chk(seq(out, "would start", "delta-canonical"), "start is an alias for up", "start alias: %s" % out)


def test_a_live_process_the_listing_omits_holds_the_name(fx):
    # A live process that holds a name the sessions list omits: `up` refuses it and `status` says so,
    # rather than reading it MISSING (measured: a resumed canonical, idle, listed `done`).
    (fx.pids / "4242.json").write_text(json.dumps(
        {"pid": 4242, "sessionId": "s", "kind": "bg", "name": "delta-canonical", "procStart": "777", "status": "idle"}))
    out = fx.run("up", "delta-canonical", "--dry-run").out    # no /proc/4242: the record's process is gone
    chk(seq(out, "would start", "delta-canonical"), "up: a record whose pid is not running does not refuse (control)",
        "up with a dead record: %s" % out)
    (fx.proc / "4242").mkdir()
    (fx.proc / "4242" / "stat").write_text("4242 (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 777 1 1\n")
    out = fx.run("up", "delta-canonical", "--dry-run").out
    chk(seq(out, "REFUSED", "delta-canonical", "live process", "pid 4242") and "would start" not in out,
        "up refuses a name a live process holds though the sessions list omits it", "up with a live holder: %s" % out)
    # Not asserted: status's non-zero exit for LIVE-UNLISTED. Other names in this fixture read MISSING,
    # so the exit is non-zero with or without it.
    out = fx.run("status").out
    chk(seq(out, "delta-canonical", "LIVE-UNLISTED", "pid 4242"), "status names a live, unlisted holder instead of MISSING",
        "status with a live holder: %s" % out)
    line = "\n".join(l for l in out.split("\n") if l.startswith("delta-canonical"))
    chk("MISSING" not in line, "the live holder's line does not say MISSING", "status still says MISSING: %s" % out)


QUEUE_STAND_IN = '''import os, sys
c = os.environ["RACE_COUNT"]
n = int(open(c).read() or 0) if os.path.exists(c) else 0
open(c, "w").write(str(n + 1))
if sys.argv[1:2] == ["live-holders"] and n + 1 >= int(os.environ["RACE_AT"]):
    print(f"{sys.argv[2]}\\tpid 4343 (resumed meanwhile)\\t4343\\tabcdef0123456789")
'''


def race_up(fx, at):
    """A holder that appears AFTER up's first check (a resume from the agents view meanwhile): up
    re-reads the holder just before launching. A stand-in queue answers `live-holders` with nothing on
    its first call and a holder from call `at` on; 99 is the control, never a holder."""
    rq = fx.T / "race"
    rq.mkdir()
    (rq / "queue.py").write_text(QUEUE_STAND_IN)
    return fx.run("up", "delta-canonical", env={"RACE_COUNT": rq / "count", "RACE_AT": at,
                                                "FLEET_CANONICALS_QUEUE": rq / "queue.py"})


def test_up_launches_when_no_holder_appears(fx):
    out = race_up(fx, 99).out
    chk(seq(out, "starting", "delta-canonical") and "delta-canonical" in fx.launches(),
        "up launches when no holder appears (race control)", "race control did not launch: %s" % out)


def test_up_rechecks_the_holder_just_before_launching(fx):
    out = race_up(fx, 2).out
    chk(seq(out, "REFUSED", "delta-canonical", "took the name while up was checking", "pid 4343")
        and "delta-canonical" not in fx.launches(),
        "up re-checks the holder just before launching, and refuses one that appeared",
        "up launched over a holder that appeared after its first check: %s" % out)


DPID = FAKE_PID


class Done:
    """A seat whose job went `done` while its process lives: the live listing leaves it out, the full
    one keeps it. refresh and down treat the process as the session; up still refuses it."""

    def __init__(self, fx):
        self.fx = fx
        fx.agents("dn-live.json", [])
        fx.agents("dn-all.json", [{"id": "dn000001", "name": "delta-canonical", "state": "done", "sessionId": "dn000001-sess",
                                   "cwd": "/x", "kind": "background", "startedAt": 1000}])
        fx.ftd_from(fx.T / "dn-all.json")
        doc = fx.hdoc("dn-handoff.md")
        fx.pointer(fx.state, "delta-canonical", doc, fx.now)

    def fc(self, *args):
        fx = self.fx
        return fx.run(*args, env={"FLEET_AGENTS_JSON_CMD": fx.cat(fx.T / "dn-live.json"),
                                  "FLEET_AGENTS_JSON_ALL_CMD": fx.cat(fx.T / "dn-all.json")})

    def holder(self, pid):
        self.fx.live_holder(pid, "delta-canonical", "dn000001-sess")


def test_a_done_seat_whose_process_lives_is_stopped_and_refreshed(fx):
    d = Done(fx)
    d.holder(DPID)
    r = d.fc("refresh", "delta-canonical", "--dry-run")
    chk(r.rc == 0 and "its job reads done or failed" in r.out
        and seq(r.out, "would refresh", "delta-canonical", "pid %s" % DPID, "dn000001") and "would start" in r.out,
        "refresh acts on a done seat whose process lives: stops that process and job, then starts",
        "refresh of a done seat with a live holder (rc=%s): %s" % (r.rc, r.out))
    r = d.fc("down", "delta-canonical", "--dry-run")
    chk(r.rc == 0 and "its job reads done or failed" in r.out
        and seq(r.out, "would stop", "delta-canonical", "pid %s" % DPID, "dn000001") and "1 target(s)" in r.out,
        "down acts on a done seat whose process lives", "down of a done seat with a live holder (rc=%s): %s" % (r.rc, r.out))
    r = d.fc("up", "delta-canonical", "--dry-run")
    chk(seq(r.out, "REFUSED", "delta-canonical", "live process") and "would start" not in r.out,
        "up still refuses a done seat whose process lives", "up of a done seat with a live holder: %s" % r.out)


def test_a_done_seats_guards_still_hold(fx):
    # The guards stay: a holder that is this session's ancestor is never stopped, and with no handoff
    # recorded refresh still refuses before it stops anything.
    d = Done(fx)
    d.holder(os.getpid())
    r = d.fc("refresh", "delta-canonical", "--dry-run")
    chk(r.rc != 0 and "running inside" in r.out and "would refresh" not in r.out,
        "refresh refuses a done seat whose process is the session running it", "self refresh of a done seat (rc=%s): %s" % (r.rc, r.out))
    r = d.fc("down", "delta-canonical", "--dry-run")
    chk(seq(r.out, "skip", "is this session") and "0 target(s)" in r.out,
        "down skips a done seat whose process is the session running it", "self down of a done seat: %s" % r.out)
    fx.drop_holder(os.getpid())
    d.holder(DPID)
    (fx.state / "delta-canonical.handoff").rename(fx.state / "delta-canonical.handoff.off")
    r = d.fc("refresh", "delta-canonical", "--dry-run")
    chk(r.rc != 0 and "no handoff is recorded" in r.out and "would refresh" not in r.out,
        "refresh of a done seat still runs the handoff gate before stopping", "gate skipped for a done seat (rc=%s): %s" % (r.rc, r.out))


def test_up_refuses_a_misspelled_name(fx):
    # The safety property: an unrecognized name must be REFUSED, never fall through to "no filter".
    r = fx.run("up", "delta-canonicl", "--dry-run")
    chk(r.rc != 0 and "not a canonical declared for this machine" in r.out,
        "up refuses a misspelled name instead of starting everything", "up with a typo (rc=%s): %s" % (r.rc, r.out))
    chk("would start" not in r.out, "up starts nothing when a name is refused",
        "up would have started something despite a bad name: %s" % r.out)


def test_down_needs_a_name_and_refuses_all_with_names(fx):
    r = fx.run("down")
    chk(r.rc != 0 and "need a canonical name" in r.out, "down refuses with no name (never closes the fleet by accident)",
        "bare down (rc=%s): %s" % (r.rc, r.out))
    r = fx.run("down", "alpha-canonical", "--all", "--dry-run")
    chk(r.rc != 0, "down refuses names and --all together", "down names+--all (rc=%s): %s" % (r.rc, r.out))


def alpha_handoff(fx):
    """alpha's handoff, committed, and its pointer recorded now (the gate `down` runs needs both)."""
    doc = fx.hdoc("real-handoff-alpha.md")
    fx.pointer(fx.state, "alpha-canonical", doc, fx.now)


def test_down_names_the_session_it_closes(fx):
    alpha_handoff(fx)
    out = fx.run("down", "alpha-canonical", "--dry-run").out
    chk(seq(out, "would stop", "alpha-canonical"), "down <name> targets that session", "down <name>: %s" % out)
    out = fx.run("down", "nosuch-canonical", "--dry-run").out
    chk("not running" in out, "down reports a name that is not running rather than passing silently", "down of an absent name: %s" % out)
    out = fx.run("stop", "alpha-canonical", "--dry-run").out
    chk(seq(out, "would stop", "alpha-canonical"), "stop is an alias for down", "stop alias: %s" % out)


def test_down_identifies_its_own_session_by_process_ancestry(fx):
    # Must never signal the session it runs in: a self-kill mid-run is indistinguishable from a crash.
    # CLAUDE_SESSION_ID is NOT exported into the shell a session runs its own commands in, so on the
    # real path the guard resolves the session by walking process ancestry. This process is an
    # ancestor of the tool spawned below, so a fixture naming it is exactly the real shape: a listed
    # session that is an ancestor, and no env var. --dry-run is mandatory: the check runs before the
    # close either way, but a regression without it would TERM this very process.
    p = fx.agents("self.json", [{"pid": os.getpid(), "id": "self", "name": "self-canonical", "sessionId": "sx", "startedAt": 1}])
    r = fx.run("down", "self-canonical", "--dry-run", env={"FLEET_AGENTS_JSON_CMD": fx.cat(p)})
    chk("is this session" in r.out, "down identifies its own session by process ancestry, with no CLAUDE_SESSION_ID",
        "ancestry-based self-protection did not fire: %s" % r.out)


def test_down_skips_the_session_it_runs_inside(fx):
    alpha_handoff(fx)
    out = fx.run("down", "alpha-canonical", env={"CLAUDE_SESSION_ID": "s1"}).out
    chk("is this session" in out and "0 target" in out, "down skips the session it is running inside",
        "down did not protect itself: %s" % out)
    # --all resolves through expected_names, so alpha must be rostered for this to reach it.
    out = fx.run("down", "--all", env=dict(rost(fx), CLAUDE_SESSION_ID="s1")).out
    chk("is this session" in out, "down --all also skips the running session", "down --all did not protect itself: %s" % out)



# ============================================================================== the freshness gate and refresh
# The gate's property is a COMPARISON, not an age: a handoff recorded BEFORE the session it would
# replace cannot describe that session's work, however recent it is in absolute terms. So every case
# fixes both clocks explicitly rather than relying on wall time.

NS_NAME = "2026-09-19-fleet-park-context-architecture.md"   # the real shape of an unstamped name: no HHMM, no seat
GS_NAME = "zeta-canonical-park.md"


class Gate:
    """zeta: running, declared, and the seat the gate cases run against."""

    def __init__(self, fx):
        self.fx = fx
        self.now = fx.now
        self.gstate = fx.T / "gstate"
        self.gs2 = fx.T / "gstate2"
        self.gh2 = fx.T / "ghandoffs"
        self.start = self.now - 3600
        # startedAt in MILLISECONDS, an hour ago: the units matter (see the to_secs case).
        self.zeta = fx.agents("zeta.json", [{"pid": P4, "id": "ddd4", "name": "zeta-canonical", "sessionId": "sz",
                                             "startedAt": (self.now - 3600) * 1000}])
        fx.ftd_from(self.zeta)
        self.empty = fx.agents("empty.json", [])
        self.zdoc = fx.hdoc("zeta-handoff.md")

    def zfc(self, *args, state=None, listing=None, env=None):
        e = {"FLEET_STATE": state or self.gstate, "FLEET_AGENTS_JSON_CMD": self.fx.cat(listing or self.zeta)}
        e.update(env or {})
        return self.fx.run(*args, env=e)

    def set_ptr(self, epoch, state=None, name="zeta-canonical", target=None):
        """Record a pointer stamped at an arbitrary time."""
        self.fx.pointer(state or self.gstate, name, target or self.zdoc, epoch)

    # the document-gate fixtures (gzfc/gfresh/gdoc)
    def gzfc(self, *args, listing=None, env=None):
        e = {"FLEET_STATE": self.gs2, "FLEET_HANDOFFS_DIR": self.gh2, "FLEET_AGENTS_JSON_CMD": self.fx.cat(listing or self.zeta)}
        e.update(env or {})
        return self.fx.run(*args, env=e)

    def gfresh(self, target, set_at):
        """A clean state and handoffs tree, and a pointer at <target> ('-' for the plain committed file)."""
        shutil.rmtree(self.gs2, ignore_errors=True)
        shutil.rmtree(self.gh2, ignore_errors=True)
        (self.gs2 / "handoff-staging").mkdir(parents=True)
        self.gh2.mkdir(parents=True)
        self.fx.pointer(self.gs2, "zeta-canonical", self.zdoc if target == "-" else target, set_at)

    def staged(self, epoch, name=GS_NAME):
        return self.gs2 / "handoff-staging" / ("%s-%s" % (gstamp(epoch), name))

    @staticmethod
    def gdoc(path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text("x\n")


@pytest.fixture
def gate(fx):
    return Gate(fx)


def test_refresh_preflights_the_declaration(fx, gate):
    # Asserted on a name that IS running but is not declared. On a name merely absent the not-running
    # check would fire first, and this would pass without the pre-flight existing.
    orphan = fx.agents("orphan.json", [{"pid": P5, "id": "eee5", "name": "orphan-canonical", "sessionId": "so",
                                        "startedAt": fx.now * 1000}])
    r = gate.zfc("refresh", "orphan-canonical", "--dry-run", listing=orphan)
    chk(r.rc != 0 and "not a canonical declared for this machine" in r.out and "no way to start again" in r.out,
        "refresh pre-flights the declaration and refuses to stop what it cannot restart", "refresh pre-flight (rc=%s): %s" % (r.rc, r.out))
    chk("would refresh" not in r.out, "refresh stops nothing when the pre-flight refuses",
        "refresh would have stopped a session it cannot restart: %s" % r.out)


def test_refresh_of_a_name_that_is_not_running_launches_and_still_gates(fx, gate):
    # A name that is NOT running is LAUNCHED, not refused, but the gate still runs. The old refusal
    # sent the operator to `up`, which had no handoff gate, so it made the path WEAKER; the two
    # assertions are read together: the first alone would pass on an implementation that deleted the
    # branch and called `up`.
    r = gate.zfc("refresh", "delta-canonical", "--dry-run")
    chk(r.rc != 0 and "no handoff is recorded" in r.out, "refresh of a NOT-RUNNING name still runs the handoff gate (no handoff -> refused)",
        "not-running refresh skipped the gate (rc=%s): %s" % (r.rc, r.out))
    # theta is not running, is declared, and HAS a handoff recorded. It must launch.
    gate.set_ptr(gate.now, name="theta-canonical", target=fx.first_launch_handoff(gate.gstate, "theta-canonical"))
    r = gate.zfc("refresh", "theta-canonical", "--dry-run", listing=gate.empty)
    chk(r.rc == 0 and "not running" in r.out and seq(r.out, "would start", "theta-canonical"),
        "refresh launches a not-running name instead of making the operator retype it as 'up'",
        "not-running refresh did not launch (rc=%s): %s" % (r.rc, r.out))
    chk("would refresh" not in r.out, "refresh of a not-running name stops nothing (there is nothing to stop)",
        "refresh claimed to stop a session that was not running: %s" % r.out)


def test_a_pointer_whose_handoff_file_is_gone_is_refused(fx, gate):
    # The pointer read used to return its target unchecked, so a launch composed "Read <missing file>
    # first" and the successor started with no orientation and no error. Refused at the gate, which
    # runs before refresh's stop half, and in `up`, which has no gate, on a dry run as well.
    gate.set_ptr(gate.now, name="theta-canonical", target=fx.T / "theta-gone.md")
    r = gate.zfc("refresh", "theta-canonical", "--dry-run", listing=gate.empty)
    chk(r.rc != 0 and seq(r.out, "missing file", "theta-gone.md") and "would start" not in r.out,
        "refresh refuses a pointer whose handoff file is missing", "refresh accepted a missing handoff (rc=%s): %s" % (r.rc, r.out))
    r = gate.zfc("refresh", "theta-canonical", "--force", "why", "--dry-run", listing=gate.empty)
    chk(r.rc != 0 and "missing file" in r.out and "would start" not in r.out, "--force does not carry a missing handoff through",
        "--force launched with a missing handoff (rc=%s): %s" % (r.rc, r.out))
    r = gate.zfc("up", "theta-canonical", "--dry-run", listing=gate.empty)
    chk(r.rc != 0 and seq(r.out, "REFUSED", "theta-canonical", "missing file") and "would start" not in r.out,
        "up --dry-run refuses a missing handoff rather than rehearsing a blind launch",
        "up rehearsed a launch with a missing handoff (rc=%s): %s" % (r.rc, r.out))
    (gate.gstate / "theta-canonical.handoff").unlink()
    r = gate.zfc("up", "theta-canonical", "--dry-run", listing=gate.empty)
    chk(r.rc != 0 and seq(r.out, "REFUSED", "theta-canonical", "no handoff recorded"), "up --dry-run refuses a name with no pointer at all",
        "up rehearsed a launch with no pointer (rc=%s): %s" % (r.rc, r.out))


def test_up_names_the_next_step_when_no_pointer_exists(fx, gate):
    # The refusal names the next step, as down and refresh do. A candidate file is named only when
    # exactly one handoff for the seat exists; with none or several the operator picks, and `up`
    # never records a pointer itself.
    nsdir = fx.T / "ns-handoffs"
    nsdir.mkdir()

    def nsup():
        return gate.zfc("up", "theta-canonical", "--dry-run", listing=gate.empty, env={"FLEET_HANDOFFS_DIR": nsdir})

    r = nsup()
    chk(r.rc != 0 and "fleet-canonicals handoff theta-canonical --set <path-to-handoff>" in r.out and "none carries" in r.out,
        "up's missing-pointer refusal prints the handoff --set next step", "no next step on a missing pointer (rc=%s): %s" % (r.rc, r.out))
    (nsdir / "2026-01-01-0900-theta-canonical-park.md").write_text("# park\n")
    r = nsup()
    chk(r.rc != 0 and "fleet-canonicals handoff theta-canonical --set %s/2026-01-01-0900-theta-canonical-park.md" % nsdir in r.out,
        "with exactly one candidate, the next step names it", "one candidate not named (rc=%s): %s" % (r.rc, r.out))
    (nsdir / "2026-01-02-0900-theta-canonical-park.md").write_text("# park\n")
    r = nsup()
    chk(r.rc != 0 and "--set <path-to-handoff>" in r.out and "2 handoff files" in r.out and "--set %s/" % nsdir not in r.out,
        "with several candidates, none is named", "a candidate named among several (rc=%s): %s" % (r.rc, r.out))
    chk(not (gate.gstate / "theta-canonical.handoff").exists(), "up never records a pointer itself", "up recorded a pointer")


def test_init_writes_a_first_launch_handoff_for_a_never_launched_seat(fx, gate):
    # init: a NEVER-LAUNCHED seat gets a first-launch handoff from the record, and only such a seat.
    # theta has no pointer here; its transcripts are looked for under its launch directory's key.
    itd = fx.T / "init-transcripts"
    itd.mkdir()
    ptr = gate.gstate / "theta-canonical.handoff"

    def initfc(*args, env=None):
        return gate.zfc(*args, listing=gate.empty, env=dict({"FLEET_TRANSCRIPT_DIR": itd}, **(env or {})))

    r = initfc("init", "nosuch-canonical")
    chk(r.rc != 0 and "not a canonical declared for this machine" in r.out, "init refuses an undeclared name",
        "init of an undeclared name (rc=%s): %s" % (r.rc, r.out))
    ikey = re.sub(r"[^A-Za-z0-9]", "-", str(fx.T / "theta"))
    (itd / ikey).mkdir()
    (itd / ikey / "s1.jsonl").write_text('{"type":"agent-name","agentName":"theta-canonical","sessionId":"s1"}\n')
    r = initfc("init", "theta-canonical")
    chk(r.rc != 0 and "has a session transcript" in r.out and not ptr.exists(),
        "init refuses a seat with a transcript under its launch directory", "init over a seat that has run (rc=%s): %s" % (r.rc, r.out))
    shutil.rmtree(itd / ikey)
    # Only a finding on the seat's OWN project refuses: this record's other projects lack a leakPolicy
    # too, and the cases below pass despite them; with theta's removed, init names theta's.
    nopolicy = fx.T / "rec-nopolicy.yaml"
    nopolicy.write_text("".join(l + "\n" for l in (fx.T / "rec.yaml").read_text().split("\n") if l != "    leakPolicy: private").rstrip("\n") + "\n")
    r = initfc("init", "--dry-run", "theta-canonical", env={"FLEET_RECORD": nopolicy})
    chk(r.rc != 0 and seq(r.out, "not completely declared", "[policy-missing] theta:"),
        "init refuses a seat whose own project has a fleet-decl --check finding", "init over an incomplete declaration (rc=%s): %s" % (r.rc, r.out))
    r = initfc("init", "--dry-run", "theta-canonical")
    chk(r.rc == 0 and seq(r.out, "would init", "theta-canonical") and not ptr.exists(), "init --dry-run checks and writes nothing",
        "init --dry-run (rc=%s): %s" % (r.rc, r.out))
    r = initfc("init", "theta-canonical")
    ih = gate.zfc("handoff", "theta-canonical").out
    body = Path(ih).read_text() if Path(ih).is_file() else ""
    chk(r.rc == 0 and ih.endswith("theta-canonical-first-launch.md") and Path(ih).is_file()
        and "nothing to" in body and "canonicalLaunchDir: theta" in body,
        "init writes a first-launch handoff from the record and records the pointer", "init (rc=%s): %s / pointer: %s" % (r.rc, r.out, ih))
    r = initfc("up", "theta-canonical", "--dry-run")
    chk(r.rc == 0 and seq(r.out, "would start", "theta-canonical"), "after init, up accepts the seat", "up after init (rc=%s): %s" % (r.rc, r.out))
    r = initfc("init", "theta-canonical")
    chk(r.rc != 0 and "already has a handoff pointer" in r.out, "init refuses a seat that has a pointer", "a second init (rc=%s): %s" % (r.rc, r.out))
    ptr.unlink()
    fx.launchlog.write_text("")
    r = initfc("init", "--up", "theta-canonical")
    chk(r.rc == 0 and seq(r.out, "starting", "theta-canonical") and "theta-canonical" in fx.launches(),
        "init --up launches the seat", "init --up (rc=%s): %s" % (r.rc, r.out))


def test_refresh_refuses_a_missing_or_second_name_and_the_force_self_flag_is_gone(fx, gate):
    r = gate.zfc("refresh")
    chk(r.rc != 0 and "need a canonical name" in r.out, "refresh refuses with no name", "bare refresh (rc=%s): %s" % (r.rc, r.out))
    r = gate.zfc("refresh", "zeta-canonical", "eta-canonical", "--dry-run")
    chk(r.rc != 0 and "one name at a time" in r.out, "refresh refuses two names rather than half-refreshing a fleet",
        "refresh with two names (rc=%s): %s" % (r.rc, r.out))
    # A temporary --force-self flag existed once purely to measure whether the refusal protected
    # against anything. It did: the verb dies at the stop (it is a descendant of what it kills), the
    # relaunch never runs, and the harness respawns the killed worker with --resume, so the same
    # session returns reporting OK, having refreshed nothing. The flag was removed once measured;
    # this asserts it did not creep back.
    r = gate.zfc("refresh", "zeta-canonical", "--dry-run", "--force-self")
    chk(r.rc != 0 and "unknown option" in r.out, "--force-self is gone: the self-refusal has no escape hatch",
        "--force-self is accepted again (rc=%s): %s" % (r.rc, r.out))


def test_the_self_refusal_cites_what_was_measured(fx, gate):
    me = fx.agents("self.json", [{"pid": os.getpid(), "id": "self1", "name": "zeta-canonical", "sessionId": "ss",
                                  "startedAt": (gate.now - 3600) * 1000}])
    gate.set_ptr(gate.now)
    r = gate.zfc("refresh", "zeta-canonical", "--dry-run", listing=me)
    chk(r.rc != 0 and "MEASURED" in r.out and "reports OK" in r.out, "the self-refusal cites what was measured, not just a refusal",
        "self-refusal lost its evidence (rc=%s): %s" % (r.rc, r.out))


def test_the_gate_refuses_a_stale_handoff_and_passes_a_fresh_one(fx, gate):
    r = gate.zfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "no handoff is recorded" in r.out, "gate refuses when no handoff is recorded at all", "gate no-handoff (rc=%s): %s" % (r.rc, r.out))
    chk("--stub" in r.out, "gate names the stub escape hatch in its refusal", "gate refusal does not say how to satisfy it: %s" % r.out)
    chk("would refresh" not in r.out, "gate refusal stops nothing", "gate refused but still stopped: %s" % r.out)
    # The case the gate exists for: a pointer that resolves PERFECTLY, to a handoff describing an
    # earlier sitting. Nothing else in the tool can see this: `handoff` itself reports it as healthy.
    gate.set_ptr(gate.now - 7200)
    r = gate.zfc("handoff", "zeta-canonical")
    chk(r.rc == 0, "a stale pointer still RESOLVES -- which is why the gate is needed", "fixture wrong, pointer does not resolve: %s" % r.out)
    r = gate.zfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "PREDATES" in r.out, "gate refuses a handoff recorded before the session it would replace",
        "gate staleness (rc=%s): %s" % (r.rc, r.out))
    # ...and the other direction, or the gate is just "always refuse".
    gate.set_ptr(gate.now - 60)
    r = gate.zfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and seq(r.out, "would refresh", "zeta-canonical"), "gate passes a handoff recorded after the session started",
        "gate pass (rc=%s): %s" % (r.rc, r.out))
    chk(seq(r.out, "would start", "zeta-canonical"), "refresh --dry-run names both halves: what it would stop and what it would start",
        "refresh dry-run does not name the start half: %s" % r.out)
    chk(seq(r.out, "recorded", "ago)"), "refresh prints the handoff age it will resume from", "refresh does not report the handoff age: %s" % r.out)
    # UNITS. startedAt is milliseconds, set-at is seconds. Comparing them unconverted makes every
    # handoff look ~1000x older than its session, so the gate refuses unconditionally, which reads as
    # "the gate works" on every refusal case and is caught only by this pass case.
    chk("PREDATES" not in r.out, "gate converts startedAt ms to seconds before comparing",
        "gate compared ms against s and refused a fresh handoff: %s" % r.out)


# --- the gate reads the DOCUMENT the pointer names, by its standard name only ---
# A pointer recorded after the start can still name a superseded document, or miss a newer one.
# Standard name: YYYY-MM-DD-HHMM-<seat>-(park|checkpoint).md, exactly; anything else is not read.
# Each refusal is paired with a control that must pass, so a gate that always refuses fails.

def test_the_gate_refuses_a_document_stamped_before_the_session(fx, gate):
    g, start = gate, gate.start
    f = g.staged(start - 7200)
    g.gfresh(f, g.now - 60)
    g.gdoc(f)
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "BEFORE the session started" in r.out,
        "gate refuses a pointer, recorded after the start, naming a document stamped before it",
        "document predating the session passed (rc=%s): %s" % (r.rc, r.out))
    r = g.gzfc("refresh", "zeta-canonical", "--force", "test", "--dry-run")
    chk(r.rc == 0 and "FORCED" in r.out, "--force skips the document-stamp refusal", "--force (rc=%s): %s" % (r.rc, r.out))
    r = g.gzfc("refresh", "zeta-canonical", "--stub", "test", "--dry-run")
    # (dry run: --stub writes nothing, so this asserts the gate PASSED; the written stub over the same
    # refusal is asserted for real in the up-gate cases, "refresh --stub of a stale stopped seat")
    chk(r.rc == 0 and "would write a stub handoff" in r.out and "BEFORE the session started" not in r.out,
        "--stub passes over the document-stamp refusal (dry run)", "--stub (rc=%s): %s" % (r.rc, r.out))
    # control: stamped in the same minute as the session's start
    f = g.staged(start)
    g.gfresh(f, g.now - 60)
    g.gdoc(f)
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "would refresh" in r.out, "gate passes a standard target stamped in the same minute as the start",
        "same-minute target refused (rc=%s): %s" % (r.rc, r.out))


def test_the_gate_refuses_a_target_while_a_newer_handoff_exists(fx, gate):
    g, start = gate, gate.start
    f = g.staged(start + 600)
    g.gfresh(f, g.now - 60)
    g.gdoc(f)
    newer = g.gh2 / ("%s-%s" % (gstamp(start + 1800), GS_NAME))
    g.gdoc(newer)
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "NEWER handoff" in r.out and "handoff zeta-canonical --set %s" % newer in r.out,
        "gate refuses a standard target while a newer one is placed, naming it and the command",
        "newer placed handoff not caught (rc=%s): %s" % (r.rc, r.out))
    r = g.gzfc("refresh", "zeta-canonical", "--force", "test", "--dry-run")
    chk(r.rc == 0 and "FORCED" in r.out, "--force skips the newer-handoff refusal", "--force newer (rc=%s): %s" % (r.rc, r.out))
    # a non-standard target is compared by the pointer's set-at minute
    g.gfresh("-", g.now - 60)
    newer = g.staged(g.now)
    g.gdoc(newer)
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "NEWER handoff" in r.out and "--set %s" % newer in r.out,
        "gate refuses a non-standard target when a standard file is stamped after the pointer was set",
        "newer staged file vs non-standard target (rc=%s): %s" % (r.rc, r.out))


def test_the_gate_dates_a_non_standard_target_by_its_first_commit(fx, gate):
    # A non-standard target is dated by the commit that ADDED it, never by the pointer's own time: a
    # pointer recorded after the start can name an old document whose name carries no stamp.
    g, start, now = gate, gate.start, gate.now
    nsr = fx.T / "nsrepo"

    def fresh_repo():
        shutil.rmtree(nsr, ignore_errors=True)
        nsr.mkdir()

    # a. committed BEFORE the start: refused, though the pointer was recorded after it
    fresh_repo()
    g.gdoc(nsr / NS_NAME)
    fx.hcommit(nsr, NS_NAME, start - 7200)
    g.gfresh(nsr / NS_NAME, now - 60)
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "BEFORE the session started" in r.out and "committed" in r.out,
        "gate refuses a non-standard target committed before the session started",
        "non-standard target committed before the start passed (rc=%s): %s" % (r.rc, r.out))
    r = g.gzfc("refresh", "zeta-canonical", "--force", "test", "--dry-run")
    chk(r.rc == 0 and "FORCED" in r.out, "--force skips the committed-before-start refusal", "--force old non-standard (rc=%s): %s" % (r.rc, r.out))
    # b. committed AFTER the start: passes (the control for a)
    fresh_repo()
    g.gdoc(nsr / NS_NAME)
    fx.hcommit(nsr, NS_NAME, start + 600)
    g.gfresh(nsr / NS_NAME, now - 60)
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "would refresh" in r.out, "gate passes a non-standard target committed after the session started",
        "non-standard target committed after the start refused (rc=%s): %s" % (r.rc, r.out))
    # b2. committed BEFORE the start, then MOVED (git mv, committed) AFTER it: the document is still
    # as old as its first commit, so it is refused; a path-limited log without --follow reads the
    # move as an add
    fresh_repo()
    g.gdoc(nsr / NS_NAME)
    fx.hcommit(nsr, NS_NAME, start - 7200)
    (nsr / "moved").mkdir()
    e = dict(fx.env, GIT_AUTHOR_DATE="@%s +0000" % (start + 600), GIT_COMMITTER_DATE="@%s +0000" % (start + 600))
    subprocess.run(["git", "-C", str(nsr), "mv", NS_NAME, "moved/" + NS_NAME], check=True, env=e, capture_output=True)
    subprocess.run(["git", "-C", str(nsr), "commit", "-q", "-m", "move " + NS_NAME], check=True, env=e, capture_output=True)
    g.gfresh(nsr / "moved" / NS_NAME, now - 60)
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "BEFORE the session started" in r.out,
        "gate dates a moved non-standard target by the commit that first added it, not the move",
        "moved non-standard target committed before the start passed (rc=%s): %s" % (r.rc, r.out))
    # c. in a repository but never committed: the pointer check that runs before the gate (and which
    # --force does not lift) already refuses it, so the gate never has to date such a file
    fresh_repo()
    subprocess.run(["git", "-C", str(nsr), "init", "-q"], check=True, env=fx.env, capture_output=True)
    g.gdoc(nsr / NS_NAME)
    g.gfresh(nsr / NS_NAME, now - 60)
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "not committed" in r.out, "an uncommitted non-standard target in a repository is refused before the gate",
        "uncommitted non-standard target in a repository passed (rc=%s): %s" % (r.rc, r.out))
    # d. not in a repository at all
    g.gfresh("-", now - 60)
    g.gdoc(fx.T / "nogit" / NS_NAME)
    fx.pointer(g.gs2, "zeta-canonical", fx.T / "nogit" / NS_NAME, now - 60)
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "cannot be dated" in r.out and "--force" in r.out,
        "gate refuses a non-standard target outside any repository, saying it cannot be dated and naming --force",
        "non-standard target outside a repository passed (rc=%s): %s" % (r.rc, r.out))
    r = g.gzfc("refresh", "zeta-canonical", "--force", "test", "--dry-run")
    chk(r.rc == 0 and "FORCED" in r.out, "--force passes an undatable non-standard target", "--force undatable (rc=%s): %s" % (r.rc, r.out))


def test_the_gate_controls_that_must_pass(fx, gate):
    g, start, now = gate, gate.start, gate.now
    # a datable target with no newer standard file
    nsr = fx.T / "nsrepo"
    nsr.mkdir()
    g.gdoc(nsr / NS_NAME)
    fx.hcommit(nsr, NS_NAME, start + 600)
    g.gfresh(nsr / NS_NAME, now - 60)
    g.gdoc(g.staged(now - 1800))
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "would refresh" in r.out, "gate passes a non-standard target committed after the start with no newer standard file",
        "no-newer control refused (rc=%s): %s" % (r.rc, r.out))
    f = g.staged(start + 600)
    g.gfresh(f, now - 60)
    g.gdoc(f)
    g.gdoc(g.gh2 / f.name)
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "would refresh" in r.out, "a placed and a staged copy sharing the target's basename do not trigger the newer check",
        "same-basename copies refused (rc=%s): %s" % (r.rc, r.out))
    g.gfresh("-", now - 60)
    g.gdoc(g.staged(now, "eta-canonical-park.md"))
    g.gdoc(g.gh2 / ("%s-x-zeta-canonical-park.md" % gstamp(now)))
    g.gdoc(g.gh2 / ("%s-zeta-canonical-checkpoint.md.bak" % gstamp(now)))
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "would refresh" in r.out, "another seat's newer file, including one whose name ends with this seat's, is ignored",
        "other seat's newer file refused (rc=%s): %s" % (r.rc, r.out))
    g.gfresh("-", now - 60)
    g.gdoc(g.gh2 / ("%s-zeta-canonical-park-notes.md" % gstamp(now)))
    r = g.gzfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "would refresh" in r.out, "a name that is not exactly standard (...-park-notes.md) is not read",
        "non-standard name refused (rc=%s): %s" % (r.rc, r.out))


def test_the_gate_refuses_when_no_session_start_is_known(fx, gate):
    # No known session start: neither a listing startedAt nor a transcript.
    nostart = fx.agents("zeta-nostart.json", [{"pid": P4, "id": "ddd4", "name": "zeta-canonical", "sessionId": "sz"}])
    gate.gfresh("-", gate.now - 60)
    env = {"FLEET_TRANSCRIPT_DIR": fx.T / "nope"}
    r = gate.gzfc("refresh", "zeta-canonical", "--dry-run", listing=nostart, env=env)
    chk(r.rc != 0 and "start of 'zeta-canonical''s session is not known" in r.out, "gate refuses rather than skips when no session start is known",
        "no-start gate passed (rc=%s): %s" % (r.rc, r.out))
    r = gate.gzfc("refresh", "zeta-canonical", "--force", "test", "--dry-run", listing=nostart, env=env)
    chk(r.rc == 0 and "FORCED" in r.out, "--force passes a session with no known start", "--force no-start (rc=%s): %s" % (r.rc, r.out))


# --- WORK SINCE THE PARK: a seat that parked and then kept working in the same session. The
# threshold is 40 main-thread tool calls after the document's date (twice the largest tail measured
# after a real park); a refusal needs MORE than 40, so 40 itself is the boundary control.

class Wsp:
    def __init__(self, fx, g):
        self.fx, self.g = fx, g
        self.dir = fx.T / "wsp-transcripts"
        self.listing = fx.agents("zeta-wsp.json", [{"pid": P5, "id": "eee5", "name": "zeta-canonical", "sessionId": "swp",
                                                    "startedAt": (g.now - 3600) * 1000}])
        d = g.now - 3000
        self.doc = d - d % 60          # the park's stamp (minute precision, so the minute below it)

    @staticmethod
    def giso(e):
        return iso(e, ".250Z")

    def build(self, after, before, side, dups=0):
        """A transcript for session swp. It opens two hours ago (before the document), has <before> tool
        calls dated before the document, <after> after it of which <side> are isSidechain:true, and
        <dups> EXTRA lines repeating the last after-call's id (one assistant message split across lines)."""
        shutil.rmtree(self.dir, ignore_errors=True)
        (self.dir / "proj").mkdir(parents=True)
        now, doc, lines = self.g.now, self.doc, []
        lines.append({"type": "user", "isSidechain": False, "timestamp": self.giso(now - 7200)})
        for i in range(1, before + 1):
            lines.append({"type": "assistant", "isSidechain": False, "timestamp": self.giso(doc - 600 - i),
                          "message": {"id": "mb%d" % i, "content": [{"type": "text", "text": "x"}, {"type": "tool_use", "id": "tb%d" % i}]}})
        for i in range(1, after + 1):
            lines.append({"type": "assistant", "isSidechain": i <= side, "timestamp": self.giso(doc + 60 + i),
                          "message": {"id": "ma%d" % i, "content": [{"type": "tool_use", "id": "ta%d" % i}]}})
        for i in range(1, dups + 1):
            lines.append({"type": "assistant", "isSidechain": False, "timestamp": self.giso(doc + 200 + i),
                          "message": {"id": "ma1", "content": [{"type": "tool_use", "id": "ta1"}]}})
        (self.dir / "proj" / "swp.jsonl").write_text("".join(json.dumps(l) + "\n" for l in lines))

    def fresh(self):
        f = self.g.staged(self.doc)
        self.g.gfresh(f, self.g.now - 60)
        self.g.gdoc(f)

    def fc(self, *args):
        return self.g.gzfc(*args, listing=self.listing, env={"FLEET_TRANSCRIPT_DIR": self.dir})


def test_the_gate_refuses_a_session_that_kept_working_after_its_park(fx, gate):
    w = Wsp(fx, gate)
    w.build(41, 0, 0)
    w.fresh()
    r = w.fc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "kept working" in r.out and "41" in r.out and "limit is 40" in r.out
        and seq(r.out, "owes a", "park") and "--force" in r.out and "--stub" in r.out and "handoff zeta-canonical --set" in r.out,
        "gate refuses a session with 41 main-thread tool calls after the document date",
        "41 tool calls after the park passed or lacked the text (rc=%s): %s" % (r.rc, r.out))
    r = w.fc("refresh", "zeta-canonical", "--force", "test", "--dry-run")
    chk(r.rc == 0 and "FORCED" in r.out, "--force skips the work-since-park refusal", "--force work-since-park (rc=%s): %s" % (r.rc, r.out))


def test_the_gate_counts_only_main_thread_calls_after_the_document(fx, gate):
    w = Wsp(fx, gate)
    w.build(40, 0, 0)
    w.fresh()
    r = w.fc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "would refresh" in r.out and "kept working" not in r.out,
        "gate passes exactly 40 tool calls after the document date (the boundary)", "40 tool calls refused (rc=%s): %s" % (r.rc, r.out))
    w.build(40, 5, 0)       # 45 calls in all, 5 of them before the document
    w.fresh()
    r = w.fc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "would refresh" in r.out, "gate counts only tool calls AFTER the document date (41+ in all, 40 after)",
        "calls before the document date were counted (rc=%s): %s" % (r.rc, r.out))
    w.build(41, 0, 1)       # 41 after, 1 of them a sidechain
    w.fresh()
    r = w.fc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "would refresh" in r.out, "gate does not count isSidechain tool calls", "sidechain tool calls were counted (rc=%s): %s" % (r.rc, r.out))
    w.build(40, 0, 0, 5)    # 45 lines, 40 distinct tool_use ids
    w.fresh()
    r = w.fc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "would refresh" in r.out, "gate counts distinct tool_use ids, not lines (one message split across lines)",
        "split message lines were counted more than once (rc=%s): %s" % (r.rc, r.out))


def test_the_work_check_fails_closed_without_a_transcript(fx, gate):
    # no transcript for the listed session: REFUSED (it used to be skipped with a note and pass)
    w = Wsp(fx, gate)
    w.fresh()
    r = gate.gzfc("refresh", "zeta-canonical", "--dry-run", listing=w.listing, env={"FLEET_TRANSCRIPT_DIR": fx.T / "nope"})
    chk(r.rc != 0 and "no readable transcript" in r.out and "--force" in r.out and "would refresh" not in r.out,
        "with no transcript the work-since-park check refuses (fails closed), naming --force",
        "missing transcript passed or lacked the text (rc=%s): %s" % (r.rc, r.out))


def test_stub_satisfies_the_gate_and_repoints_the_pointer(fx, gate):
    # These run the REAL verb: a stopped seat with no pointer, so `refresh` goes gate -> `up`, and the
    # launcher is `false`, so nothing starts and no real state is touched.
    sstate = fx.T / "sstate"
    sstate.mkdir()
    empty = fx.agents("s-empty.json", [])
    env = {"FLEET_STATE": sstate, "FLEET_CLAUDE_CMD": "false", "FLEET_AGENTS_JSON_CMD": fx.cat(empty),
           "FLEET_AGENTS_JSON_ALL_CMD": fx.cat(empty)}
    r = fx.run("refresh", "zeta-canonical", "--stub", "nothing in flight", env=env)
    # (rc is the launcher's: `false` exits 1, so only the gate's output is asserted)
    chk("stub written and recorded" in r.out and "REFUSED" not in r.out, "--stub satisfies the gate with no prior handoff", "--stub (rc=%s): %s" % (r.rc, r.out))
    stubs = sorted((sstate / "stub-handoffs").glob("*-zeta-canonical-stub.md")) if (sstate / "stub-handoffs").is_dir() else []
    stub = stubs[0] if stubs else None
    chk(stub is not None and stub.stat().st_size > 0, "--stub writes a real, non-empty handoff file", "--stub wrote no file")
    body = stub.read_text() if stub else ""
    chk("nothing in flight" in body, "--stub records the reason it was given", "--stub dropped the reason: %s" % body)
    chk("no orientation to inherit" in body, "--stub tells the successor outright that there is nothing to inherit",
        "--stub body does not say there is nothing to inherit")
    # The point of stub-over-bypass: the pointer now names the stub, so the NEXT run is satisfied by a
    # real artifact rather than by a flag having been passed once.
    chk(fx.run("handoff", "zeta-canonical", env=env).out == str(stub), "--stub repoints the handoff pointer at the stub it wrote",
        "--stub did not record the pointer")


def test_handoff_set_stamps_when_it_was_recorded(fx, gate):
    gate.zfc("handoff", "zeta-canonical", "--set", gate.zdoc)
    text = (gate.gstate / "zeta-canonical.handoff").read_text()
    chk("# set-at " in text, "handoff --set stamps when it was recorded", "no set-at stamp written")
    got = gate.zfc("handoff", "zeta-canonical").out
    chk(got == str(gate.zdoc), "the stamp does not break pointer resolution (reader strips #-comments)", "stamp broke resolution: %s" % got)


def test_a_pointer_written_before_stamping_falls_back_to_the_file_mtime(fx, gate):
    # A pointer written before stamping existed must still work: there are live ones on this fleet.
    gate.gstate.mkdir()
    ptr = gate.gstate / "zeta-canonical.handoff"
    ptr.write_text("%s\n" % gate.zdoc)
    os.utime(ptr, (gate.now - 60, gate.now - 60))
    r = gate.zfc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc == 0, "an unstamped legacy pointer falls back to file mtime rather than failing", "legacy pointer rejected (rc=%s): %s" % (r.rc, r.out))


def test_down_gates_the_holder_but_not_all_or_dedupe(fx, gate):
    env = dict(rost(fx), FLEET_STATE=gate.gstate)
    r = fx.run("down", "alpha-canonical", "--dry-run", env=env)
    chk(r.rc != 0 and "no handoff is recorded" in r.out, "down <name> gates the session that holds the name", "down gate (rc=%s): %s" % (r.rc, r.out))
    chk("would stop" not in r.out, "down closes nothing when the gate refuses", "down closed despite the gate: %s" % r.out)
    # --all is the ramp-down path: no successor is coming, so there is nothing to hand over to. If this
    # ever starts gating, the fleet's ramp-down wedges.
    r = fx.run("down", "--all", "--dry-run", env=env)
    chk(r.rc == 0 and "no handoff is recorded" not in r.out, "down --all is exempt from the gate (ramp-down, not a handover)",
        "down --all was gated (rc=%s): %s" % (r.rc, r.out))
    # beta has two rows; the OLDER one is a superseded duplicate that was already replaced. Demanding
    # a handoff from it would wedge the takeover path. Only the holder is gated.
    r = fx.run("dedupe", "--dry-run", env=env)
    chk(r.rc == 0 and str(P2) in r.out, "dedupe is exempt from the gate (it closes rows that were already superseded)",
        "dedupe was gated (rc=%s): %s" % (r.rc, r.out))


def test_refresh_refuses_the_session_it_runs_inside(fx, gate):
    # $$ analogue: this process is an ancestor of the tool and no CLAUDE_SESSION_ID is set, so this
    # exercises the ancestry path that actually runs. --dry-run is mandatory: if the refusal regressed
    # the tool would TERM this process.
    me = fx.agents("self2.json", [{"pid": os.getpid(), "id": "self2", "name": "self2-canonical", "sessionId": "sy",
                                   "startedAt": fx.now * 1000}])
    r = gate.zfc("refresh", "self2-canonical", "--dry-run", listing=me)
    chk(r.rc != 0 and "is the session this is running inside" in r.out, "refresh refuses to refresh the session it runs inside",
        "refresh self-refusal did not fire (rc=%s): %s" % (r.rc, r.out))
    chk("would refresh" not in r.out, "refresh stops nothing when it refuses itself", "refresh would have killed its own session: %s" % r.out)
    # It must refuse BEFORE the gate, or the message names the wrong problem entirely.
    chk("no handoff is recorded" not in r.out, "self-refusal precedes the handoff gate, so the error names the real problem",
        "self-refresh reported a handoff problem instead of the self problem: %s" % r.out)


# ============================================================================== portability helpers
# REGRESSION GUARD for a class a Linux-only run structurally cannot see. `stat -c` and `date -d` are
# GNU spellings that ERROR on BSD/darwin rather than degrading: they print nothing and the caller
# silently loses a value. So these RUN the helpers on whatever platform the suite is on, rather
# than asserting a spelling.

def helpers_source():
    lines = tool_text().split("\n")
    out = [l for l in lines if l.startswith("file_mtime()") or l.startswith("fmt_epoch()")]
    on = False
    for l in lines:
        if not on and l.startswith("parse_time()"):
            on = True
        if on:
            out.append(l)
            if l.startswith("}"):
                break
    return "\n".join(out) + "\n"


def run_helper(fx, call):
    helpers = fx.T / "helpers.sh"
    helpers.write_text(helpers_source())
    return fx.sh(". '%s'; %s" % (helpers, call))


def test_file_mtime_returns_an_epoch(fx):
    r = run_helper(fx, "file_mtime '%s'" % TOOL)
    chk(r.out.isdigit(), "file_mtime returns an epoch on this platform (GNU or BSD stat)", "file_mtime did not resolve an mtime here: %s" % r.out)


def test_fmt_epoch_formats_an_epoch(fx):
    r = run_helper(fx, "fmt_epoch 1756000000 '%Y-%m-%d'")
    chk(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", r.out) is not None, "fmt_epoch formats an epoch on this platform (GNU or BSD date)",
        "fmt_epoch did not format here: %s" % r.out)


def test_parse_time_parses_a_real_time_and_refuses_junk(fx):
    # parse_time is the one helper whose two branches are NOT equivalent: GNU takes free-form input,
    # BSD needs an explicit format. Both directions are asserted: a real time must parse, and junk
    # must still be refused, because a greedy BSD format tried too early would accept junk.
    r = run_helper(fx, "parse_time '2026-08-28 14:30'")
    chk(r.out.isdigit(), "parse_time parses a date-time on this platform (GNU or BSD date)", "parse_time did not parse a real time here: %s" % r.out)
    r = run_helper(fx, "parse_time 'not-a-time'")
    chk(r.rc != 0 and r.out == "", "parse_time still refuses junk on this platform", "parse_time accepted junk (rc=%s): %s" % (r.rc, r.out))



# ============================================================================== launching: up, its stdin, its command line

STUB_STDIN = """#!/bin/sh
name=""
while [ $# -gt 0 ]; do case "$1" in -n) name=$2; shift 2 ;; *) shift ;; esac; done
cat > "$LEAKDIR/$name.stdin"
: > "$LEAKDIR/$name.started"
"""
STUB_ARGS = """#!/bin/sh
printf '%s\\n' "$*" >> "$LEAKDIR/args.log"
"""
STUB_ENV = """#!/bin/sh
name=""; prev=""
for a in "$@"; do [ "$prev" = "-n" ] && name=$a; prev=$a; done
env > "$LEAKDIR/$name.env"
"""


class Leak:
    """A small fleet of three seats (one, two, three), none running, each with a recorded handoff, and
    launcher stand-ins that record what they were started with. `up` is the verb whose real effect
    cannot be exercised, so every launch lands in a stub: the cases assert the COMPOSED command (the
    working directory, the model tier, the identity sentence) and the environment it starts with."""

    def __init__(self, fx):
        self.fx = fx
        self.dir = fx.T / "leak"
        self.st = self.dir / "st"
        self.st.mkdir(parents=True)
        self.rec = self.dir / "rec.yaml"
        self.rec.write_text(RECORD_HEAD + "".join(seat_yaml(n, n, n + "-canonical", n, "fable") for n in ("one", "two", "three")))
        for n in ("one", "two", "three"):
            (self.dir / n).mkdir()
            fx.pointer(self.st, n + "-canonical", fx.first_launch_handoff(self.st, n + "-canonical"), fx.now)
        self.agents = fx.agents("leak/agents.json", [])
        for name, text in (("stub", STUB_STDIN), ("argstub", STUB_ARGS), ("envstub", STUB_ENV)):
            p = self.dir / name
            p.write_text(text)
            p.chmod(0o755)
        (self.dir / "args.log").write_text("")

    def up(self, *args, stub="argstub", env=None, rec=None, state=None):
        e = {"FLEET_ROOT": self.dir, "FLEET_RECORD": rec or self.rec, "FLEET_STATE": state or self.st,
             "FLEET_CLAUDE_CMD": self.dir / stub, "LEAKDIR": self.dir, "FLEET_AGENTS_JSON_CMD": self.fx.cat(self.agents)}
        e.update(env or {})
        return self.fx.run(*(args or ("up",)), env=e)

    def args_log(self):
        return (self.dir / "args.log").read_text()


@pytest.fixture
def leak(fx):
    return Leak(fx)


def test_up_hands_a_launched_session_no_stdin_to_swallow(fx, leak):
    # `up` loops over a names STREAM, so a launched session that inherits stdin gets the REMAINING
    # names: Claude Code appends piped stdin to its prompt argument, so a canonical starts with
    # leftover roster names glued onto its first message, AND the read drains the stream so every
    # canonical after it is silently never started while `up` still reports success. The stand-in
    # reads stdin exactly as `claude` does, reproducing both effects without a real session.
    out = leak.up(stub="stub").out
    leaked = "".join(p.read_text() for p in sorted(leak.dir.glob("*.stdin"))).rstrip("\n")
    chk(leaked == "", "up hands a launched session no stdin to swallow into its prompt",
        "up leaked roster names into a launched session's stdin: %s" % leaked.replace("\n", " "))
    missing = "".join(" " + n for n in ("one", "two", "three") if not (leak.dir / (n + "-canonical.started")).exists())
    chk(missing == "", "up starts every missing canonical, not just the first",
        "up never started:%s (stream drained by an earlier launch?) -- %s" % (missing, out))
    chk("started 3" in out, "up's reported count matches what it actually started", "up count disagrees with the launches it performed: %s" % out)


def test_the_launch_carries_the_declared_tier_and_a_prompt_that_describes(fx, leak):
    # The stub sees the whole command line, so the DECLARED model tier and the composed identity
    # sentence are assertable. While each repo carried its own script neither was visible to any
    # test, which is how a declared tier and a running one diverged with nothing surfacing it.
    leak.up()
    args = leak.args_log()
    chk("--model fable" in args, "the launch carries the DECLARED model tier", "declared tier absent from the composed launch: %s" % args)
    chk("This session is one-canonical, the canonical session for one. " in args, "the identity sentence is composed from the declared role",
        "composed identity sentence wrong: %s" % args)
    # The prompt DESCRIBES the session and treats the handoff as a record of work, never as a source
    # of commands: a persona line ("You are ...") followed by "read <file> and follow it" is the
    # shape a cautious safety filter refuses as an injection, and a work machine's did.
    chk(seq(args, "The previous session's handoff is at %s/" % leak.dir,
            ": read it first and resume the work it describes. Reply with one line confirming you have resumed, then begin."),
        "the launch prompt names the handoff as the previous session's record of work", "launch prompt wording wrong: %s" % args)
    chk("You are " not in args and "follow it" not in args, "the launch prompt carries no persona line and no follow-the-file instruction",
        "launch prompt still carries the old persona or follow-it wording: %s" % args)


def rcup(fx, leak, vars, rec=None):
    """Run `up` against the leak fleet with a fresh launch log; the first launch line for one-canonical."""
    (leak.dir / "args.log").write_text("")
    r = leak.up(env=dict(vars, FLEET_RECORD=rec or leak.rec))
    (leak.dir / "rc.out").write_text(r.out)
    for line in leak.args_log().split("\n"):
        if "-n one-canonical " in line:
            return line
    return ""


def test_remote_control_follows_the_machine_key_and_the_seats_override(fx, leak):
    # `--remote-control` takes an OPTIONAL name, so the launch always gives one: a bare flag before
    # the prompt would take the prompt as the name. Asserted on the composed argument list.
    a = rcup(fx, leak, {"FLEET_REMOTE_CONTROL": ""})
    chk(a != "" and "--remote-control" not in a, "with remote-control unset, a launch carries no --remote-control", "remote-control unset: %s" % a)
    a = rcup(fx, leak, {"FLEET_REMOTE_CONTROL": "true"})
    chk("--bg -n one-canonical --remote-control one-canonical --model " in a,
        "remote-control = true: the launch carries --remote-control <its own name>, before the prompt", "remote-control true: %s" % a)
    a = rcup(fx, leak, {"FLEET_REMOTE_CONTROL": "yes"})
    said = (leak.dir / "rc.out").read_text()
    chk(a != "" and "--remote-control" not in a and re.search(r"remote-control in .* is yes, not true or false", said) is not None,
        "a value other than true or false launches without Remote Control, and says so", "remote-control yes: %s / %s" % (a, said))
    off = fx.T / "rec-rc-off.yaml"
    on = fx.T / "rec-rc-on.yaml"
    seats = lambda extra: RECORD_HEAD + "".join(seat_yaml(n, n, n + "-canonical", n, "fable", extra if n == "one" else "") for n in ("one", "two", "three"))
    off.write_text(seats("    canonicalRemoteControl: false\n"))
    on.write_text(seats("    canonicalRemoteControl: true\n"))
    a = rcup(fx, leak, {"FLEET_REMOTE_CONTROL": "true"}, rec=off)
    chk(a != "" and "--remote-control" not in a, "a canonical's canonicalRemoteControl: false overrides the machine's true",
        "manifest false over config true: %s" % a)
    a = rcup(fx, leak, {"FLEET_REMOTE_CONTROL": ""}, rec=on)
    chk("--remote-control one-canonical" in a, "a canonical's canonicalRemoteControl: true turns it on where the machine has it off",
        "manifest true over config unset: %s" % a)


def test_resume_forks_carry_the_remote_control_arguments(fx):
    body = function_body(tool_text(), "cmd_resume").split("\n")
    needle = '-n "$name" ${rc_args[@]+"${rc_args[@]}"} --resume "$uuid"'
    n = sum(1 for l in body if needle in l)
    chk(n == 2, "BOTH resume --fork invocations carry the Remote Control arguments",
        "expected the Remote Control arguments on both fork invocations, found %s" % n)


# ---- the launch environment: macOS refuses a launch over SSH; the launch fragment -------------------
# On macOS a session started over SSH lands in the background login session, which cannot read the
# login Keychain, and a Claude Code daemon it starts keeps that environment for every session after
# it. So on macOS a launch is refused while SSH_CONNECTION is set; on Linux it is not. A domain may
# supply a launch fragment: KEY=VALUE lines the launch exports into the environment it starts
# `claude` in, read only when SSH_CONNECTION is unset. FLEET_OS stands in for `uname -s`, and the stub
# writes the environment it was started with, per launched name.

SSHC = "192.0.2.1 50000 192.0.2.2 22"
PROBE = "FLEET_T13_PROBE=from the fragment, spaces kept"


class LaunchEnv:
    def __init__(self, fx, leak):
        self.fx, self.leak = fx, leak
        self.frag = leak.dir / "launch.frag"
        self.frag.write_text('# a comment, then a blank line\n\nFLEET_T13_PROBE=from the fragment, spaces kept\n'
                             'FLEET_T13_QUOTED="kept literally"\n')
        self.envfile = leak.dir / "one-canonical.env"

    def up(self, vars=None, args=("up", "one-canonical"), agents=None):
        """`up one-canonical` by default, with a fresh env capture; SSH_CONNECTION unset unless given."""
        for p in self.leak.dir.glob("*-canonical.env"):
            p.unlink()
        e = {"SSH_CONNECTION": None, "FLEET_LAUNCH_ENV": self.frag}
        if agents:
            e["FLEET_AGENTS_JSON_CMD"] = self.fx.cat(agents)
        e.update(vars or {})
        return self.leak.up(*args, stub="envstub", env=e)

    def lines(self):
        return self.envfile.read_text().split("\n") if self.envfile.exists() else []

    def started(self):
        return self.envfile.exists()


@pytest.fixture
def le(fx, leak):
    return LaunchEnv(fx, leak)


def test_macos_over_ssh_a_launch_is_refused_and_nothing_starts(fx, le):
    r = le.up({"FLEET_OS": "Darwin", "SSH_CONNECTION": SSHC})
    chk(r.rc != 0 and seq(r.out, "REFUSED", "one-canonical", "SSH") and not le.started(),
        "macOS: a launch with SSH_CONNECTION set is refused, and nothing is started",
        "macOS over SSH: a launch proceeded or was not refused (rc=%s, started=%s): %s" % (r.rc, "yes" if le.started() else "no", r.out))
    r = le.up({"FLEET_OS": "Darwin", "SSH_CONNECTION": SSHC}, args=("up", "--dry-run", "one-canonical"))
    chk(r.rc != 0 and seq(r.out, "REFUSED", "SSH") and "would start" not in r.out, "macOS: the dry run refuses over SSH, as the real launch would",
        "macOS over SSH: the dry run did not refuse (rc=%s): %s" % (r.rc, r.out))


def test_the_launch_fragment_reaches_the_launched_environment(fx, le):
    r = le.up({"FLEET_OS": "Darwin"})
    chk(PROBE in le.lines(), "macOS, not over SSH: a launch fragment variable reaches the launched claude's environment",
        "the fragment's variable never reached the launched claude (rc=%s): %s" % (r.rc, r.out))
    chk('FLEET_T13_QUOTED="kept literally"' in le.lines(), "a fragment value is taken literally: no quote removal, no expansion",
        "a fragment value was not kept literally: %s" % [l for l in le.lines() if "FLEET_T13_QUOTED" in l])
    r = le.up({"FLEET_OS": "Linux"})
    chk(PROBE in le.lines(), "Linux, not over SSH: the fragment is read too (the base reads it wherever a domain puts it)",
        "Linux, not over SSH: the fragment was not read (rc=%s): %s" % (r.rc, r.out))
    r = le.up({"FLEET_OS": "Darwin", "FLEET_LAUNCH_ENV": le.leak.dir / "no-such-launch.frag"})
    chk(r.rc == 0 and le.started() and not any(l.startswith("FLEET_T13_PROBE=") for l in le.lines()),
        "with no fragment a launch proceeds unchanged", "a missing fragment changed the launch (rc=%s): %s" % (r.rc, r.out))


def test_linux_over_ssh_launches_without_reading_the_fragment(fx, le):
    r = le.up({"FLEET_OS": "Linux", "SSH_CONNECTION": SSHC})
    chk(r.rc == 0 and le.started(), "Linux: SSH_CONNECTION set does not refuse a launch (the refusal is macOS-only)",
        "Linux over SSH: the launch was refused or did not start (rc=%s): %s" % (r.rc, r.out))
    chk(le.started() and not any(l.startswith("FLEET_T13_PROBE=") for l in le.lines()), "over SSH the launch fragment is not read",
        "the fragment was read over SSH, or nothing launched: %s" % [l for l in le.lines() if "FLEET_T13" in l])


def test_a_malformed_fragment_refuses_the_launch(fx, le):
    bad = le.leak.dir / "bad.frag"
    bad.write_text("FLEET_T13_PROBE=fine\nexport NOT_A_LINE=x\n")
    r = le.up({"FLEET_OS": "Darwin", "FLEET_LAUNCH_ENV": bad})
    chk(r.rc != 0 and seq(r.out, "REFUSED", str(bad), "line 2") and not le.started(),
        "a fragment line that is not KEY=VALUE refuses the launch, naming the file and line",
        "a malformed fragment was not refused (rc=%s): %s" % (r.rc, r.out))
    bad2 = le.leak.dir / "bad2.frag"
    bad2.write_text("NO_EQUALS_SIGN\n")
    r = le.up({"FLEET_OS": "Linux", "FLEET_LAUNCH_ENV": bad2})
    chk(r.rc != 0 and seq(r.out, "REFUSED", "line 1") and not le.started(), "a fragment line with no = refuses the launch",
        "a fragment line with no = was not refused (rc=%s): %s" % (r.rc, r.out))


def test_refresh_and_resume_refuse_over_ssh_before_acting(fx, le):
    # refresh stops a session before it launches the successor, so the refusal must come first: a
    # refresh refused only at its launch would leave the seat down.
    live = fx.agents("agents-le.json", [{"pid": P4, "id": "le1", "cwd": "/x", "kind": "background", "startedAt": 1000,
                                         "sessionId": "sle1", "name": "one-canonical", "status": "idle", "state": "done"}])
    r = le.up({"FLEET_OS": "Darwin", "SSH_CONNECTION": SSHC}, args=("refresh", "--dry-run", "one-canonical"), agents=live)
    chk(r.rc != 0 and "SSH" in r.out and "stopping" not in r.out and "would start" not in r.out,
        "macOS: refresh over SSH refuses before it stops anything", "macOS over SSH: refresh did not refuse up front (rc=%s): %s" % (r.rc, r.out))
    # resume wakes or forks a session, a launch either way.
    stopped = fx.agents("agents-le2.json", [{"pid": None, "id": "le2", "cwd": "/x", "kind": "background", "startedAt": 1000,
                                             "sessionId": "sle2", "name": "one-canonical", "status": "idle", "state": "done"}])
    r = le.up({"FLEET_OS": "Darwin", "SSH_CONNECTION": SSHC}, args=("resume", "one-canonical", "--dry-run"), agents=stopped)
    chk(r.rc != 0 and "SSH" in r.out and "would wake" not in r.out, "macOS: resume over SSH is refused before it wakes or forks",
        "macOS over SSH: resume was not refused (rc=%s): %s" % (r.rc, r.out))


def test_resume_applies_the_launch_fragment_to_every_launch(fx):
    n = sum(1 for l in function_body(tool_text(), "cmd_resume").split("\n") if "apply_launch_env" in l)
    chk(n == 3, "resume applies the launch fragment to the wake and to BOTH fork invocations",
        "expected apply_launch_env on resume's wake and both forks, found %s" % n)


def test_the_launchd_domain_hook_decides_where_a_macos_launch_may_run(fx, le):
    # FLEET_MANAGERNAME_CMD names the command (the base sets it empty, off). When it names one, on
    # macOS a launch proceeds only where it prints Aqua.
    bg, aqua = le.leak.dir / "mn-bg", le.leak.dir / "mn-aqua"
    bg.write_text("#!/bin/sh\necho Background\n")
    aqua.write_text("#!/bin/sh\necho Aqua\n")
    bg.chmod(0o755)
    aqua.chmod(0o755)
    r = le.up({"FLEET_OS": "Darwin", "FLEET_MANAGERNAME_CMD": bg})
    chk(r.rc != 0 and seq(r.out, "REFUSED", "Background") and not le.started(),
        "macOS: with the launchd-domain hook set, a launch outside Aqua is refused",
        "the launchd-domain hook did not refuse a Background launch (rc=%s): %s" % (r.rc, r.out))
    r = le.up({"FLEET_OS": "Darwin", "FLEET_MANAGERNAME_CMD": aqua})
    chk(r.rc == 0 and le.started(), "macOS: with the launchd-domain hook set, a launch in Aqua proceeds",
        "the launchd-domain hook refused an Aqua launch (rc=%s): %s" % (r.rc, r.out))
    r = le.up({"FLEET_OS": "Linux", "FLEET_MANAGERNAME_CMD": bg})
    chk(r.rc == 0 and le.started(), "Linux: the launchd-domain hook is not consulted",
        "the launchd-domain hook was consulted on Linux (rc=%s): %s" % (r.rc, r.out))


def test_the_default_launchd_domain_hook_runs_launchctl(fx, le):
    # Unset, the hook defaults to `launchctl managername` on macOS. A stub `launchctl` first on PATH
    # stands in for the real one; set empty, the check is off.
    d = le.leak.dir
    for name, word in (("lc-bg", "Background"), ("lc-aqua", "Aqua")):
        (d / name).mkdir()
        (d / name / "launchctl").write_text('#!/bin/sh\n[ "$1" = managername ] && echo %s\n' % word)
        (d / name / "launchctl").chmod(0o755)

    def unset_mn(lcdir, vars):
        return le.up(dict({"FLEET_MANAGERNAME_CMD": None, "PATH": "%s%s%s" % (lcdir, os.pathsep, fx.env["PATH"])}, **vars))

    r = unset_mn(d / "lc-bg", {"FLEET_OS": "Darwin"})
    chk(r.rc != 0 and seq(r.out, "REFUSED", "Background") and not le.started(),
        "macOS: unset, the hook runs launchctl managername and refuses a launch outside Aqua",
        "macOS: the default hook did not refuse a Background launch (rc=%s): %s" % (r.rc, r.out))
    r = unset_mn(d / "lc-aqua", {"FLEET_OS": "Darwin"})
    chk(r.rc == 0 and le.started(), "macOS: unset, the hook lets a launch in Aqua proceed",
        "macOS: the default hook refused an Aqua launch (rc=%s): %s" % (r.rc, r.out))
    r = unset_mn(d / "lc-bg", {"FLEET_OS": "Darwin", "FLEET_MANAGERNAME_CMD": ""})
    chk(r.rc == 0 and le.started(), "macOS: FLEET_MANAGERNAME_CMD set empty turns the check off",
        "macOS: an empty FLEET_MANAGERNAME_CMD still ran the check (rc=%s): %s" % (r.rc, r.out))
    r = unset_mn(d / "lc-bg", {"FLEET_OS": "Linux"})
    chk(r.rc == 0 and le.started(), "Linux: unset, the hook still runs nothing", "Linux: the default hook was consulted (rc=%s): %s" % (r.rc, r.out))


# ---- the handoff a launch may name: inside the handoffs trees, and committed where it is in git -------
# A launch hands its successor one file as the work to resume, so that file must be a handoff the
# fleet's own tooling put there: in the staging directory or a configured handoffs tree, reached
# without a symlink or a `..` out of it, and, where it sits in a git repository, committed with no
# change since, so what is read is what passed that repository's commit gates. A staged copy, which
# nothing has committed yet, gets the location check alone: requiring a commit would stall every
# relaunch on the hub placing it first.

class Provenance:
    def __init__(self, fx, leak):
        self.fx, self.leak = fx, leak
        hp = self.hp = leak.dir / "prov"
        for d in ("st/handoff-staging", "one", "tree/handoffs", "elsewhere", "tmproots"):
            (hp / d).mkdir(parents=True)
        self.rec = hp / "rec.yaml"
        self.rec.write_text(RECORD_HEAD + seat_yaml("one", "one", "one-canonical", "one", "fable"))
        (hp / "st" / "handoff-staging" / "one-staged.md").write_text("staged\n")
        (hp / "elsewhere" / "notes.md").write_text("stray\n")
        os.symlink(hp / "elsewhere" / "notes.md", hp / "st" / "handoff-staging" / "one-link.md")

    def plaunch(self, path, noconf=False):
        """Record <path> as one-canonical's handoff, run `up`, and return "launched" or what it said
        instead. With noconf, no handoffs directory is configured, as on a machine without one."""
        hp = self.hp
        d, search = ("", "") if noconf else (hp / "tree" / "handoffs", hp / "tree")
        self.fx.run("handoff", "one-canonical", "--set", path, env={"FLEET_STATE": hp / "st"})
        (hp / "args.log").write_text("")
        # --force: where the handoff sits is the subject here, not its freshness, and the seat has no row
        # and no transcript (the gate would otherwise accept only init's first-launch handoff).
        r = self.fx.run("up", "--force", "freshness is not under test", env={"FLEET_ROOT": hp, "FLEET_RECORD": self.rec, "FLEET_STATE": hp / "st", "FLEET_HANDOFFS_DIR": d,
                                   "FLEET_HANDOFFS_SEARCH": search, "FLEET_TMPROOT_PREFIX": hp / "tmproots",
                                   "FLEET_CLAUDE_CMD": self.leak.dir / "argstub", "LEAKDIR": hp,
                                   "FLEET_AGENTS_JSON_CMD": self.fx.cat(self.leak.agents)})
        return "launched" if (hp / "args.log").stat().st_size else r.out

    def pgit(self, *args):
        """The fixture repository must not run this machine's hooks or sign with its key."""
        subprocess.run(["git", "-C", str(self.hp / "tree"), "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args],
                       env=dict(self.fx.env, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1"), capture_output=True)


@pytest.fixture
def prov(fx, leak):
    return Provenance(fx, leak)


def test_a_launch_names_only_a_handoff_inside_the_handoff_trees(fx, prov):
    hp = prov.hp
    r = prov.plaunch(hp / "st" / "handoff-staging" / "one-staged.md")
    chk(r == "launched", "a staged handoff launches (location check only)", "staged handoff refused: %s" % r)
    (hp / "st" / "stub-handoffs").mkdir()
    (hp / "st" / "stub-handoffs" / "one-stub.md").write_text("stub\n")
    r = prov.plaunch(hp / "st" / "stub-handoffs" / "one-stub.md")
    chk(r == "launched", "a stub handoff written by --stub launches", "stub handoff refused: %s" % r)
    r = prov.plaunch(hp / "st" / "handoff-staging" / "one-staged.md", noconf=True)
    chk(r == "launched", "a staged handoff launches where no handoffs directory is configured",
        "staged handoff refused with no handoffs directory configured: %s" % r)
    r = prov.plaunch(hp / "elsewhere" / "notes.md")
    chk(r != "launched" and "outside the handoff directories" in r, "a handoff outside the staging and handoffs trees is refused",
        "outside handoff: %s" % r)
    r = prov.plaunch("%s/st/handoff-staging/../../elsewhere/notes.md" % hp)
    chk(r != "launched" and "outside the handoff directories" in r, "a path that climbs out of staging with .. is refused", ".. escape: %s" % r)
    r = prov.plaunch(hp / "st" / "handoff-staging" / "one-link.md")
    chk(r != "launched" and "symbolic link" in r, "a symlink in staging is refused, wherever it points", "symlinked handoff: %s" % r)
    (hp / "tree" / "handoffs" / "one-placed.md").write_text("placed\n")
    r = prov.plaunch(hp / "tree" / "handoffs" / "one-placed.md", noconf=True)
    chk(r != "launched" and "outside the handoff directories" in r,
        "with no handoffs directory configured, a file in an unconfigured tree is refused", "unconfigured tree accepted: %s" % r)
    r = prov.plaunch(hp / "tree" / "handoffs" / "one-placed.md")
    chk(r == "launched", "a placed handoff outside any git repository launches", "placed, no git: %s" % r)


def test_a_placed_handoff_in_git_must_be_committed_and_unchanged(fx, prov):
    placed = prov.hp / "tree" / "handoffs" / "one-placed.md"
    placed.write_text("placed\n")
    prov.pgit("init", "-q")
    r = prov.plaunch(placed)
    chk(r != "launched" and "not committed" in r, "a placed handoff in a git repository but never committed is refused", "untracked handoff: %s" % r)
    prov.pgit("add", "handoffs/one-placed.md")
    r = prov.plaunch(placed)
    chk(r != "launched" and "not committed" in r, "a placed handoff staged in git but not committed is refused", "added, uncommitted handoff: %s" % r)
    prov.pgit("commit", "-q", "-m", "placed")
    r = prov.plaunch(placed)
    chk(r == "launched", "a committed handoff launches", "committed handoff refused: %s" % r)
    with open(placed, "a") as fh:
        fh.write("edited after the commit\n")
    r = prov.plaunch(placed)
    chk(r != "launched" and "changed since its last commit" in r, "a committed handoff edited since its commit is refused", "edited handoff: %s" % r)


# ---- every launch gets its own temp root, recorded AND passed to the launch via --settings -----------

def test_every_launch_gets_a_temp_root_that_is_recorded_and_passed(fx, leak):
    # FLEET_TMPROOT_PREFIX is redirected under the scratch directory rather than the real /tmp: this
    # is what lets the assertions check the REAL mkdir and record-write side effects (not just the
    # composed argument string) without a production launch's /tmp ever being touched by this suite.
    roots = leak.dir / "tmproots"
    roots.mkdir()
    leak.up(env={"FLEET_TMPROOT_PREFIX": roots})
    args = leak.args_log()
    chk(seq(args, "--settings", "CLAUDE_CODE_TMPDIR"), "up's launch carries --settings with a CLAUDE_CODE_TMPDIR env override",
        "no --settings/CLAUDE_CODE_TMPDIR in the composed launch: %s" % args)
    rec = leak.st / "one-canonical.tmproot"
    chk(rec.is_file(), "up records the launched session's temp root under FLEET_STATE", "no .tmproot record written for one-canonical")
    recorded = rec.read_text().rstrip("\n") if rec.is_file() else ""
    chk(re.fullmatch(re.escape(str(roots)) + r"/c-one-[A-Za-z0-9]{6}", recorded) is not None,
        "the recorded root matches the /tmp/c-<short>-XXXXXX shape (under the test prefix)", "recorded root has the wrong shape: %s" % recorded)
    chk(recorded != "" and '"CLAUDE_CODE_TMPDIR":"%s"' % recorded in args, "the root named in --settings is the SAME root that got recorded",
        "the launched --settings root and the recorded root disagree: recorded=%s args=%s" % (recorded, args))
    chk(recorded != "" and os.path.isdir(recorded) and not os.path.islink(recorded),
        "the launch actually created its temp root as a real directory (not a symlink)", "temp root directory was not created on disk: %s" % recorded)


# ---------- resume: wake in place, fork only on request ----------
# `claude attach <id>` resumes a background session IN PLACE, including a STOPPED one. `claude --bg
# --resume <uuid>` always FORKS: new session id, transcript copied. Source assertions rather than
# live-session runs: spawning real sessions in a suite is not worth the cost, and these are the
# properties that regressed or nearly did while authoring.

def test_resume_prefers_waking_over_forking(fx):
    text = tool_text()
    body = function_body(text, "cmd_resume")
    chk('attach "$row_id"' in text, "wakes an existing session via attach rather than forking it",
        "no attach path in resume -- every resume would duplicate a transcript")
    chk("force_fork" in text, "forking is opt-in (--fork), not the default", "no --fork opt-in; the lossy path must be chosen deliberately")
    # The fork path must read the ALL listing: a stopped session is exactly what --fork branches from,
    # and the live listing drops those.
    chk("json=$(agents_json_all)" in body, "the fork path reads the --all listing, so a stopped session is visible",
        "fork reads the live-only listing: --fork on a stopped session cannot see it")
    # Forking a LIVE session is refused outright: the copy would be seeded from a transcript still
    # being written, so it branches from an arbitrary mid-write moment. The escape hatch is
    # stop-then-fork, so nothing is prevented, only made deliberate.
    chk("fork is REFUSED on a live session" in body, "--fork on a LIVE session is refused, with stop-then-fork named as the way through",
        "--fork would branch a live session from a transcript still being written")
    # A fork inherits the CALLER's cwd, and cwd selects the project: forking a canonical from the
    # wrong directory brings it up on another project's context while still carrying the right NAME.
    chk("src_cwd" in body, "the fork launches from the SOURCE session's cwd, not the caller's", "fork ignores the source cwd: right name, wrong project")
    # A fork is a real launch too, and the fix this guards is that fork was the one launch path missed
    # the first time a temp-root pass was written.
    chk('record_tmproot "$name" "$root"' in body, "the fork path records its own temp root, same as launch_canonical",
        "resume's fork path never calls record_tmproot -- a forked session would share/leak a root")
    # Both invocations (the branch that cd's into the source cwd, and the fallback) must carry the
    # flag. Counting rather than a single containment: a regression that dropped it from only ONE of
    # the two would still pass, since the other occurrence matches.
    n = sum(1 for l in body.split("\n") if '--resume "$uuid" --settings "$settings"' in l)
    chk(n == 2, "BOTH fork invocations (cd-into-src-cwd and the fallback) carry --settings",
        "expected --settings on both fork invocations, found %s: %s" % (n, body))



# ---- resume-proof freshness gate, and the --force hatch ----------------------------------------------
# THE BUG THIS CLOSES. Opening a parked canonical from the agents view RESUMES it, which rewrites
# `startedAt` to the moment of the click. The freshness gate compared the handoff against that value,
# so a canonical parked correctly the previous evening was refused on the next morning's `refresh`:
# the gate reporting staleness that did not exist. The transcript is the fixed point: a resume
# APPENDS to the same <sessionId>.jsonl, so its first timestamped entry still marks when the session
# really began.

class Eta:
    def __init__(self, fx):
        self.fx = fx
        n = fx.now
        self.estate = fx.T / "estate"
        # The fixture IS the incident: startedAt is NOW (the resume), the handoff was recorded an hour
        # ago, and the transcript says the session really began two hours ago. Under the old
        # comparison this is a refusal; under the transcript comparison it is a pass.
        self.listing = fx.agents("eta.json", [{"pid": P6, "id": "fff6", "name": "eta-canonical", "sessionId": "eta-sess-uuid",
                                               "startedAt": n * 1000}])
        self.transcripts = fx.T / "transcripts"
        (self.transcripts / "proj").mkdir(parents=True)
        # Epoch -> ISO is computed here, so the fixture cannot build an EMPTY timestamp on a platform
        # whose `date` spells it differently and then measure the fallback path while claiming to
        # measure the transcript path.
        lines = ['{"type":"summary","summary":"no timestamp on this line, deliberately"}',
                 json.dumps({"type": "user", "timestamp": iso(n - 7200)}),
                 json.dumps({"type": "assistant", "timestamp": iso(n - 3900)})]
        self.transcript = self.transcripts / "proj" / "eta-sess-uuid.jsonl"
        self.transcript.write_text("\n".join(lines) + "\n")
        self.doc = fx.hdoc("eta-handoff.md")

    def efc(self, *args, listing=None, env=None):
        e = {"FLEET_STATE": self.estate, "FLEET_TRANSCRIPT_DIR": self.transcripts, "FLEET_AGENTS_JSON_CMD": self.fx.cat(listing or self.listing)}
        e.update(env or {})
        return self.fx.run(*args, env=e)

    def set_ptr(self, epoch):
        self.fx.pointer(self.estate, "eta-canonical", self.doc, epoch)


@pytest.fixture
def eta(fx):
    return Eta(fx)


def test_the_gate_reads_a_sessions_true_start_from_its_transcript(fx, eta):
    t = eta.transcript.read_text()
    chk(eta.transcript.stat().st_size > 0 and re.search(r"20[0-9][0-9]-", t) is not None, "transcript fixture carries a real timestamp on this platform",
        "transcript fixture has no timestamp -- the cases below would measure the fallback path")
    eta.set_ptr(fx.now - 3600)
    r = eta.efc("refresh", "eta-canonical", "--dry-run")
    chk(r.rc == 0 and "would refresh" in r.out, "gate reads the session's TRUE start from its transcript, so a resume does not fake staleness",
        "resumed session still refused (rc=%s): %s" % (r.rc, r.out))
    chk(seq(r.out, "resumed:", "using the transcript"), "the gate SAYS it substituted the transcript start, naming both times",
        "gate substituted the start time silently: %s" % r.out)
    # ...and the substitution must not blind the gate. A handoff older than the TRUE start is still
    # stale, or this change traded a false refusal for a false pass: the worse of the two.
    eta.set_ptr(fx.now - 10800)
    r = eta.efc("refresh", "eta-canonical", "--dry-run")
    chk(r.rc != 0 and "PREDATES" in r.out, "a handoff older than the transcript start is still refused",
        "transcript start made the gate unfalsifiable (rc=%s): %s" % (r.rc, r.out))
    # With no transcript at all the gate must fall back to startedAt, not break. Same stale pointer,
    # transcript dir pointed somewhere empty: the refusal must survive.
    r = eta.efc("refresh", "eta-canonical", "--dry-run", env={"FLEET_TRANSCRIPT_DIR": fx.T / "nope"})
    chk(r.rc != 0 and "PREDATES" in r.out, "an unreadable transcript falls back to startedAt rather than disabling the gate",
        "missing transcript broke the gate (rc=%s): %s" % (r.rc, r.out))


def test_force_carries_a_refusal_through_and_keeps_the_pointer(fx, eta):
    eta.set_ptr(fx.now - 10800)
    r = eta.efc("refresh", "eta-canonical", "--force", "clicked in from the agents view", "--dry-run")
    chk(r.rc == 0 and "FORCED" in r.out and "would refresh" in r.out, "--force carries a refusal through", "--force did not pass the gate (rc=%s): %s" % (r.rc, r.out))
    chk("clicked in from the agents view" in r.out, "--force records the operator's reason in the output", "--force dropped the reason: %s" % r.out)
    chk("pointer LEFT AS-IS" in r.out, "--force leaves the recorded handoff pointer untouched", "--force did not say the pointer survived: %s" % r.out)
    # The property that separates it from --stub, asserted on the STATE rather than the message.
    ptr = (eta.estate / "eta-canonical.handoff").read_text()
    chk("eta-handoff.md" in ptr, "--force did not rewrite the pointer to a generated stub", "--force replaced the real handoff: %s" % ptr)
    # Giving both is a contradiction about WHICH thing is wrong, so it is refused rather than ordered.
    r = eta.efc("refresh", "eta-canonical", "--force", "x", "--stub", "y", "--dry-run")
    chk(r.rc != 0 and "opposites" in r.out, "--stub and --force together are refused", "both hatches accepted (rc=%s): %s" % (r.rc, r.out))
    # A refusal has to TEACH the difference, or the operator reaches for --stub (which destroys a good
    # handoff) because it is the only hatch the message names.
    shutil.rmtree(eta.estate)
    r = eta.efc("refresh", "eta-canonical", "--dry-run")
    chk("--force" in r.out and "--stub" in r.out, "the gate's refusal names BOTH hatches and what each one does",
        "refusal still names only one way out: %s" % r.out)


def test_one_canonical_name_declared_by_two_projects_is_reported(fx):
    # The record's version of the abandoned-worktree hazard: two trees claiming one name used to be
    # resolved by locale collation and the loser was often the live checkout. A record cannot have two
    # scripts, but it CAN have two projects declaring the same canonical, and each entry is
    # individually well formed, so nothing but an explicit check sees the collision.
    dupe = fx.T / "dupe.yaml"
    dupe.write_text(RECORD_HEAD + seat_yaml("eta", "eta", "eta-canonical", "eta", "fable")
                    + seat_yaml("eta_old", "eta.pre-worktree", "eta-canonical", "eta.pre-worktree", "fable", identity="the canonical session for eta"))
    env = dict(fx.env, FLEET_RECORD=str(dupe))
    p = subprocess.run(["fleet-decl", "--check"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, stdin=subprocess.DEVNULL)
    out = p.stdout.rstrip("\n")
    chk(p.returncode != 0 and "canonical-duplicate" in out and "eta-canonical" in out,
        "one name declared by two projects is reported, not silently tie-broken", "duplicate canonical not caught (rc=%s): %s" % (p.returncode, out))
    p = subprocess.run(["fleet-decl", "--canonical", "eta-canonical", "canonicalLaunchDir"], env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, stdin=subprocess.DEVNULL)
    out = p.stdout.rstrip("\n")
    chk(p.returncode == 2 and "not tie-broken" in out and "eta eta_old" in out,
        "a reader asked about an ambiguous name refuses and names both projects",
        "ambiguous read did not refuse with both names (rc=%s): %s" % (p.returncode, out))


# ---- a canonical sitting in a linked worktree ---------------------------------------------------
# MEASURED: a canonical session that never left its worktree could not be closed: the exit path tries
# to remove a worktree that is locked while a session holds it, and treats the removal it cannot
# perform as a failure of the whole stop. The refresh had already started a successor, so the name was
# left with two live rows. This warns; the prevention is in the parking skill. Both directions are
# asserted, because a warning that always fires teaches nothing.

def test_refresh_warns_when_the_canonical_sits_in_a_linked_worktree(fx, eta):
    wtrepo, linked = fx.T / "wtrepo", fx.T / "wtlinked"
    subprocess.run(["git", "init", "-q", str(wtrepo)], env=fx.env, capture_output=True)
    # -c commit.gpgsign=false is LOAD-BEARING: a machine that signs through an agent that prompts for
    # an unlock would block a throwaway fixture commit on a prompt that never comes.
    subprocess.run(["git", "-C", str(wtrepo), "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
                    "-c", "gpg.format=openpgp", "commit", "-q", "--allow-empty", "-m", "init"], env=fx.env, capture_output=True)
    subprocess.run(["git", "-C", str(wtrepo), "worktree", "add", "-q", "-b", "side", str(linked)], env=fx.env, capture_output=True)
    chk(linked.is_dir(), "fixture: could not create a linked worktree, so the warning was never exercised",
        "fixture: could not create a linked worktree, so the warning was never exercised")

    def wt_json(cwd):
        return fx.agents("wt.json", [{"pid": P7, "id": "ggg7", "name": "eta-canonical", "sessionId": "eta-sess-uuid",
                                      "startedAt": fx.now * 1000, "cwd": str(cwd)}])

    eta.set_ptr(fx.now - 3600)
    r = eta.efc("refresh", "eta-canonical", "--dry-run", listing=wt_json(linked))
    chk("linked worktree" in r.out, "refresh warns when the canonical is sitting in a linked worktree", "no worktree warning (rc=%s): %s" % (r.rc, r.out))
    chk("would refresh" in r.out, "the worktree warning does not block the refresh -- it is a warning, not a gate", "worktree warning refused the verb: %s" % r.out)
    r = eta.efc("refresh", "eta-canonical", "--dry-run", listing=wt_json(wtrepo))
    chk("linked worktree" not in r.out, "no warning for a canonical in its primary checkout", "worktree warning fires on a primary checkout too: %s" % r.out)


# ---- UNPLACED STAGED HANDOFFS -------------------------------------------------------------------
# A canonical that cannot write the handoffs repository stages its handoff and points at it.
# Continuity is fine, the pointer resolves, but DURABILITY lags, and until this check existed nothing
# said so. The third case decides whether the check survives contact: one staged file is legitimately
# placed under research/ rather than handoffs/, so a handoffs-only comparison reports a false orphan,
# and a check that cries wolf gets ignored, which is worse than none.

def test_status_reports_staged_handoffs_nobody_placed(fx):
    up = fx.T / "fc-unplaced"
    staging = up / "state" / "handoff-staging"
    for d in (staging, up / "prog" / "handoffs", up / "prog" / "research"):
        d.mkdir(parents=True)

    def ufc():
        return fx.run("status", env={"FLEET_STATE": up / "state", "FLEET_HANDOFFS_DIR": up / "prog" / "handoffs",
                                     "FLEET_HANDOFFS_SEARCH": up / "prog"}).out

    (staging / "orphan.md").write_text("")
    out = ufc()
    chk("UNPLACED  orphan.md" in out, "an unplaced staged handoff is reported", "unplaced handoff not reported: %s" % out)
    (up / "prog" / "handoffs" / "placed.md").write_text("")
    (staging / "placed.md").write_text("")
    out = ufc()
    chk("UNPLACED  placed.md" not in out, "one placed in handoffs/ is not reported", "placed handoff reported as unplaced: %s" % out)
    # THE ARM THAT MATTERS: placed ELSEWHERE in the tree must not read as an orphan.
    (up / "prog" / "research" / "elsewhere.md").write_text("")
    (staging / "elsewhere.md").write_text("")
    out = ufc()
    chk("UNPLACED  elsewhere.md" not in out, "one placed outside handoffs/ is not a false orphan",
        "file placed under research/ reported as unplaced: %s" % out)
    # THE ARM THIS CHECK FAILED IN PRODUCTION: placed under a DIFFERENT NAME. Placement is a judgment,
    # so the hub may rename a staged draft or fold it into a differently-named standing document, and
    # no widening of the search can find it, because there is nothing to match. The staged copy
    # instead declares its own disposition in a header, and that declaration is read. Both spellings
    # are exercised because both are in real use.
    (staging / "renamed.md").write_text("# d\n\n> **PLACED AND COMMITTED** elsewhere under another name.\n")
    out = ufc()
    chk("UNPLACED  renamed.md" not in out, "a staged file DECLARING it was placed is not an orphan", "declared-placed file reported as unplaced: %s" % out)
    (staging / "superseded.md").write_text("# d\n\n> **SUPERSEDED -- PLACED 2026-09-06**, see the runbook.\n")
    out = ufc()
    chk("UNPLACED  superseded.md" not in out, "a staged file DECLARING it is superseded is not an orphan",
        "declared-superseded file reported as unplaced: %s" % out)
    # THE COUNTER-ARM, without which the two above prove only that the check went quiet. A marker
    # BELOW the header must NOT excuse a file: otherwise any handoff that merely discusses placing
    # some other document silences its own orphan warning.
    (staging / "late-marker.md").write_text("# d\n\n" + "".join("filler line %d\n" % i for i in range(1, 26))
                                            + "> **PLACED** -- but this is line 28, far below the header.\n")
    out = ufc()
    chk("UNPLACED  late-marker.md" in out, "a marker below the header does NOT excuse a file",
        "late marker wrongly treated as a placement declaration: %s" % out)
    # And the count must match the real orphans, not every staged file.
    out = ufc()
    chk("2 staged handoff(s)" in out, "the count reflects real orphans only", "orphan count wrong: %s" % out)


# ================================================================ per-launch temp roots
# Every real filesystem path below is redirected under the case's scratch directory (via
# FLEET_TMPROOT_PREFIX or a scratch FLEET_STATE), never the real /tmp a production launch uses.

RM_TMPROOT = 'eval "$(sed -n "/^tmproot_path()/,/^}/p;/^rm_tmproot()/,/^}/p" "$1")"; rm_tmproot "$2"'


class RmRoot:
    """The REAL rm_tmproot in isolation: just that function (and the tmproot_path it calls) is sourced
    out of the tool under test, rather than reimplemented here where a second copy could drift."""

    def __init__(self, fx):
        self.fx = fx
        self.state, self.prefix = fx.T / "rm-state", fx.T / "rm-prefix"
        self.state.mkdir()
        self.prefix.mkdir()

    def rm(self, name):
        return self.fx.sh(RM_TMPROOT, TOOL, name, env={"FLEET_STATE": self.state, "FLEET_TMPROOT_PREFIX": self.prefix})


@pytest.fixture
def rmroot(fx):
    return RmRoot(fx)


def test_rm_tmproot_removes_a_recorded_root_of_the_exact_shape(rmroot):
    # a recorded root that matches the exact shape, is a real directory, not a symlink: MUST be
    # removed, and its record cleared with it.
    (rmroot.prefix / "c-alpha-aB3xYz").mkdir()
    (rmroot.state / "alpha.tmproot").write_text("%s\n" % (rmroot.prefix / "c-alpha-aB3xYz"))
    rmroot.rm("alpha")
    chk(not (rmroot.prefix / "c-alpha-aB3xYz").is_dir(), "rm_tmproot removes a recorded root that matches the exact shape",
        "rm_tmproot left a matching, well-formed root in place")
    chk(not (rmroot.state / "alpha.tmproot").is_file(), "rm_tmproot clears the record once its root is gone",
        "rm_tmproot left a stale record behind after removing the root")


def test_rm_tmproot_leaves_a_sibling_it_was_not_told_about(rmroot):
    # a sibling directory that is NOT the recorded path must survive: rm_tmproot acts on the exact
    # recorded string, never a glob over every /tmp/c-<name>-* directory.
    (rmroot.prefix / "c-beta-aB3xYz").mkdir()
    (rmroot.prefix / "c-beta-other").mkdir()
    (rmroot.state / "beta.tmproot").write_text("%s\n" % (rmroot.prefix / "c-beta-aB3xYz"))
    rmroot.rm("beta")
    chk(not (rmroot.prefix / "c-beta-aB3xYz").is_dir(), "rm_tmproot removes the exact recorded root", "the recorded root survived deletion")
    chk((rmroot.prefix / "c-beta-other").is_dir(), "a sibling directory NOT named in the record survives untouched",
        "rm_tmproot deleted a sibling it was never told about -- looks like a glob sweep, not an exact match")


def test_rm_tmproot_refuses_a_path_outside_the_expected_shape(rmroot):
    # a recorded path that does not match the c-<short>-XXXXXX shape at all must be refused outright:
    # neither the target nor the record itself is touched, so a mismatch stays visible.
    (rmroot.prefix / "decoy-dir").mkdir()
    (rmroot.state / "gamma.tmproot").write_text("%s\n" % (rmroot.prefix / "decoy-dir"))
    rmroot.rm("gamma")
    chk((rmroot.prefix / "decoy-dir").is_dir(), "a recorded path outside the expected shape is left untouched",
        "rm_tmproot deleted something outside the /tmp/c-<short>-XXXXXX shape")
    chk((rmroot.state / "gamma.tmproot").is_file(), "a mismatched record is left in place too, rather than silently cleared",
        "rm_tmproot cleared a record it refused to act on")


def test_rm_tmproot_never_follows_a_symlink(rmroot):
    (rmroot.prefix / "real-target").mkdir()
    link = rmroot.prefix / "c-delta-aB3xYz"
    os.symlink(rmroot.prefix / "real-target", link)
    (rmroot.state / "delta.tmproot").write_text("%s\n" % link)
    rmroot.rm("delta")
    chk(link.is_symlink() and (rmroot.prefix / "real-target").is_dir(), "rm_tmproot refuses a recorded path that is a symlink, even to a real directory",
        "rm_tmproot followed a symlink -- its real target may have been deleted")


def test_rm_tmproot_accepts_a_root_that_is_already_gone(rmroot):
    # the usual case: the session-end scratch hook deletes it when the stop ends the session. No
    # error, the record is cleared, and the note says it was already gone rather than reading as a fault.
    (rmroot.state / "epsilon.tmproot").write_text("%s\n" % (rmroot.prefix / "c-epsilon-aB3xYz"))
    r = rmroot.rm("epsilon")
    chk(r.rc == 0, "a recorded root that never existed on disk does not error", "rm_tmproot errored on an already-absent root (rc=%s): %s" % (r.rc, r.out))
    chk(not (rmroot.state / "epsilon.tmproot").is_file(), "an already-gone root's record is cleared",
        "rm_tmproot left the record of an already-gone root behind")
    chk("already gone" in r.out and "leaving it alone" not in r.out, "...and its note says already gone, not a refusal", "already-gone note: %s" % r.out)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def test_down_deletes_the_recorded_root_and_only_that(fx):
    e2e = fx.T / "stop-e2e"
    state, prefix = e2e / "state", e2e / "tmproots"
    for d in (state, prefix):
        d.mkdir(parents=True)
    # `down` gates on a recorded handoff for the name it is closing; without one it refuses before
    # ever reaching close_one.
    (e2e / "handoff.md").write_text("orientation\n")
    fx.hcommit(e2e, "handoff.md")
    fx.pointer(state, "stop-canonical", e2e / "handoff.md", fx.now)
    with fx.sleeper() as (proc,):
        # A DYNAMIC agents listing: reports the row only while the process is actually alive, so
        # `down`'s live-rows check observes a REAL disappearance after close_one signals it, exactly
        # as the live tool would against a real `claude agents --json`.
        agents = e2e / "agents.sh"
        agents.write_text("#!/bin/sh\nif kill -0 %d 2>/dev/null; then\n"
                          "  printf '[{\"pid\":%d,\"id\":\"stopid1\",\"name\":\"stop-canonical\",\"sessionId\":\"stop-sess\",\"startedAt\":1}]'\n"
                          "else\n  printf '[]'\nfi\n" % (proc.pid, proc.pid))
        agents.chmod(0o755)
        root, sibling = prefix / "c-stop-aB3xYz", prefix / "c-stop-canonical-other"
        root.mkdir()
        sibling.mkdir()
        (state / "stop-canonical.tmproot").write_text("%s\n" % root)
        # the gate counts work since the park, which needs this session's transcript
        fx.ftd_from(fx.agents("stop-row.json", [{"sessionId": "stop-sess", "startedAt": 1}]))
        r = fx.run("down", "stop-canonical", env={"FLEET_STATE": state, "FLEET_TMPROOT_PREFIX": prefix,
                                                  "FLEET_CLAUDE_CMD": "/usr/bin/true", "FLEET_AGENTS_JSON_CMD": agents})
        chk(not alive(proc.pid), "down actually signals the session's process", "down did not terminate the dummy session process (rc=%s): %s" % (r.rc, r.out))
        chk(not root.is_dir(), "down removes the recorded temp root once the session is gone", "down left the recorded temp root in place: %s" % r.out)
        chk(not (state / "stop-canonical.tmproot").is_file(), "down clears the .tmproot record along with the root", "down removed the root but left a stale record")
        chk(sibling.is_dir(), "down leaves an unrelated sibling directory alone", "down deleted a sibling it was never told about")


DEDUPE_AGENTS = r'''#!/bin/sh
rows=""
if kill -0 OLDPID 2>/dev/null; then
  rows="${rows}{\"pid\":OLDPID,\"id\":\"ddold\",\"name\":\"dd-canonical\",\"sessionId\":\"dd-old-sess\",\"startedAt\":1000},"
fi
if kill -0 NEWPID 2>/dev/null; then
  rows="${rows}{\"pid\":NEWPID,\"id\":\"ddnew\",\"name\":\"dd-canonical\",\"sessionId\":\"dd-new-sess\",\"startedAt\":9000},"
fi
printf '[%s]' "${rows%,}"
'''


def test_dedupe_never_deletes_the_survivors_root(fx):
    e2e = fx.T / "dedupe-e2e"
    state, prefix = e2e / "state", e2e / "tmproots"
    for d in (state, prefix):
        d.mkdir(parents=True)
    (e2e / "roster").write_text("dd-canonical\n")
    with fx.sleeper(2) as (old, new):
        # The record reflects the SURVIVOR's (newer) root, as a real launch through this tool would
        # leave it: there is only ever one record per name, and it is always the most recent launch's.
        root = prefix / "c-dd-zZ9qQ9"
        root.mkdir()
        (state / "dd-canonical.tmproot").write_text("%s\n" % root)
        agents = e2e / "agents.sh"
        agents.write_text(DEDUPE_AGENTS.replace("OLDPID", str(old.pid)).replace("NEWPID", str(new.pid)))
        agents.chmod(0o755)
        r = fx.run("dedupe", "dd-canonical", env={"CANONICAL_ROSTER": e2e / "roster", "FLEET_STATE": state, "FLEET_TMPROOT_PREFIX": prefix,
                                                  "FLEET_CLAUDE_CMD": "/usr/bin/true", "FLEET_AGENTS_JSON_CMD": agents})
        chk(not alive(old.pid), "dedupe signals the OLDER duplicate's process", "dedupe did not terminate the older duplicate (rc=%s): %s" % (r.rc, r.out))
        chk(alive(new.pid), "dedupe leaves the NEWER survivor's process running", "dedupe touched the survivor's process -- it should never be a dedupe target")
        chk(root.is_dir(), "dedupe never deletes the survivor's recorded temp root",
            "dedupe deleted the SURVIVING session's live temp root -- this would rm -rf a running session's TMPDIR")
        rec = state / "dd-canonical.tmproot"
        chk(rec.is_file() and str(root) in rec.read_text().split("\n"), "the record still points at the survivor's root, untouched",
            "dedupe altered the surviving session's tmproot record")


def test_refresh_deletes_the_old_root_only_never_the_new_one(fx):
    e2e = fx.T / "refresh-e2e"
    state, prefix = e2e / "state", e2e / "tmproots"
    for d in (e2e / "dir", state, prefix):
        d.mkdir(parents=True)
    rec = e2e / "rec.yaml"
    rec.write_text(RECORD_HEAD + seat_yaml("rfp", "rfp", "rf-canonical", "dir", "fable"))
    (e2e / "handoff.md").write_text("orientation\n")
    fx.hcommit(e2e, "handoff.md")
    fx.pointer(state, "rf-canonical", e2e / "handoff.md", fx.now)
    with fx.sleeper() as (old,):
        old_root = prefix / "c-rf-aB3xYz"
        old_root.mkdir()
        (state / "rf-canonical.tmproot").write_text("%s\n" % old_root)
        # Dynamic listing, same technique as the stop case: reports the row only while the process is
        # alive, so refresh's own "wait for the row to actually go" loop observes a real disappearance.
        agents = e2e / "agents.sh"
        agents.write_text("#!/bin/sh\nif kill -0 %d 2>/dev/null; then\n"
                          "  printf '[{\"pid\":%d,\"id\":\"rfold1\",\"name\":\"rf-canonical\",\"sessionId\":\"rf-old-sess\",\"startedAt\":1}]'\n"
                          "else\n  printf '[]'\nfi\n" % (old.pid, old.pid))
        agents.chmod(0o755)
        # the gate counts work since the park, which needs this session's transcript
        fx.ftd_from(fx.agents("rf-row.json", [{"sessionId": "rf-old-sess", "startedAt": 1}]))
        argstub = e2e / "argstub"
        argstub.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$REFRESH_ARGSLOG\"\n")
        argstub.chmod(0o755)
        (e2e / "args.log").write_text("")
        r = fx.run("refresh", "rf-canonical", env={"FLEET_ROOT": e2e, "FLEET_RECORD": rec, "FLEET_STATE": state, "FLEET_TMPROOT_PREFIX": prefix,
                                                   "FLEET_CLAUDE_CMD": argstub, "REFRESH_ARGSLOG": e2e / "args.log",
                                                   "FLEET_AGENTS_JSON_CMD": agents})
        chk(r.rc == 0, "refresh completes successfully end to end", "refresh failed (rc=%s): %s" % (r.rc, r.out))
        chk(not old_root.is_dir(), "refresh removes the OLD session's recorded temp root", "refresh left the old temp root in place: %s" % r.out)
        newp = state / "rf-canonical.tmproot"
        new_root = newp.read_text().rstrip("\n") if newp.exists() else ""
        chk(new_root != "" and new_root != str(old_root), "refresh records a NEW root, distinct from the old one",
            "refresh did not record a fresh root (or reused the old one): %s" % new_root)
        chk(new_root != "" and os.path.isdir(new_root) and not os.path.islink(new_root), "the new root is a real directory on disk",
            "the newly recorded root was not actually created: %s" % new_root)
        args = (e2e / "args.log").read_text()
        chk(new_root != "" and '"CLAUDE_CODE_TMPDIR":"%s"' % new_root in args, "the relaunch's --settings carries the SAME new root that got recorded",
            "the relaunch's --settings root and the recorded root disagree: root=%s args=%s" % (new_root, args))
        chk(not alive(old.pid), "the old session's process was actually terminated by the refresh", "refresh did not terminate the old session's process")


# ---- resume: the "handoff is NEWER than the transcript" advisory ------------------------------------
# The advisory tells an operator that a session they are about to fork from its transcript had in fact
# parked, so `refresh` would read the handoff it wrote. It read the pointer file whole, and a pointer
# written by `handoff --set` carries a second `# set-at N` line, so the path it tested was two lines
# long, never a file, and the note could not fire. The fixture records the pointer the way every real
# one is recorded, through `handoff --set`.

def test_resume_fork_advisory_fires_only_for_a_newer_handoff(fx):
    rs = fx.T / "resume-adv"
    for d in ("state", "transcripts/proj", "cwd"):
        (rs / d).mkdir(parents=True)
    uuid = "r5e5a1e0-0000-4000-8000-000000000001"
    # A STOPPED row (no pid): with --fork that takes the fork path without trying to wake anything.
    listing = fx.agents("resume-adv/agents.json", [{"pid": None, "id": "r5e5a1e0", "name": "alpha-canonical", "sessionId": uuid,
                                                    "startedAt": 1000, "cwd": str(rs / "cwd")}])
    tr = rs / "transcripts" / "proj" / (uuid + ".jsonl")
    tr.write_text('{"type":"user","timestamp":"2026-01-01T00:00:00.000Z"}\n')
    old_mtime(tr)
    (rs / "handoff.md").write_text("parked\n")
    env = {"FLEET_STATE": rs / "state", "FLEET_TRANSCRIPT_DIR": rs / "transcripts", "FLEET_AGENTS_JSON_CMD": fx.cat(listing)}
    fx.run("handoff", "alpha-canonical", "--set", rs / "handoff.md", env=env)
    r = fx.run("resume", "alpha-canonical", "--fork", "--dry-run", env=env)
    chk(r.rc == 0 and seq(r.out, "would resume", uuid), "resume finds the transcript under FLEET_TRANSCRIPT_DIR",
        "resume did not find the transcript in the configured directory (rc=%s): %s" % (r.rc, r.out))
    chk("handoff is NEWER than the transcript" in r.out, "the advisory fires for a stamped pointer naming a handoff newer than the transcript",
        "no advisory for a handoff newer than the transcript: %s" % r.out)
    # The counter-arm: a note that always fires teaches nothing.
    t = time.mktime((2025, 1, 1, 0, 0, 0, 0, 0, -1))
    os.utime(rs / "handoff.md", (t, t))
    r = fx.run("resume", "alpha-canonical", "--fork", "--dry-run", env=env)
    chk("NEWER than the transcript" not in r.out, "the advisory stays quiet when the handoff is older than the transcript",
        "advisory fired for an older handoff: %s" % r.out)



# ---- clean: scratch roots whose session is gone -------------------------------------------------------
# Every launch makes a root under the prefix, and `down`/`refresh` remove the recorded one. Roots whose
# record was overwritten (a fork) or whose session ended without either verb are left, and a machine
# with no session-end hook keeps them forever. `clean` removes those and nothing else: it must never
# delete a root a running session may own, and must never act on a path of any other shape. Every root
# is aged past the young-root guard except the one that tests that guard.

class Clean:
    def __init__(self, fx, roster):
        self.fx = fx
        self.dir = fx.T / "clean"
        self.prefix, self.state = self.dir / "tmp", self.dir / "state"
        for d in (self.prefix, self.state, self.dir / "target"):
            d.mkdir(parents=True)
        (self.dir / "roster").write_text("".join(n + "\n" for n in roster))
        self.agents = fx.agents("clean/agents.json", [])

    def mkroot(self, name):
        d = self.prefix / name
        (d / "claude-1000").mkdir(parents=True)
        (d / "claude-1000" / "f").write_text("x\n")
        old_mtime(d)

    def record(self, seat, root):
        (self.state / (seat + ".tmproot")).write_text("%s\n" % (self.prefix / root))

    def fc(self, *args, env=None):
        e = {"CANONICAL_ROSTER": self.dir / "roster", "FLEET_STATE": self.state, "FLEET_TMPROOT_PREFIX": self.prefix,
             "FLEET_AGENTS_JSON_CMD": self.fx.cat(self.agents)}
        e.update(env or {})
        return self.fx.run("clean", *args, env=e)

    def exists(self, name):
        return os.path.lexists(self.prefix / name)


def test_clean_removes_the_roots_of_gone_sessions_and_only_those(fx):
    now = fx.now
    c = Clean(fx, ["gone-canonical", "quiet-canonical", "solo-canonical", "solo2-canonical", "twin-canonical"])
    for n in ("c-gone-AAAAAA", "c-gone-BBBBBB", "c-quiet-CCCCCC", "c-solo-DDDDDD", "c-solo-EEEEEE", "c-solo2-PPPPPP", "c-solo2-QQQQQQ",
              "c-twin-FFFFFF", "c-twin-GGGGGG", "c-gone-toolong7", "c-gone-abc", "c-stranger-IIIIII"):
        c.mkroot(n)
    c.record("quiet-canonical", "c-quiet-CCCCCC")
    c.record("solo-canonical", "c-solo-DDDDDD")
    old_mtime(c.state / "solo-canonical.tmproot")
    c.record("solo2-canonical", "c-solo2-PPPPPP")
    (c.prefix / "c-gone-HHHHHH").mkdir()                       # young: just made, as a launch in flight
    os.symlink(c.dir / "target", c.prefix / "c-gone-JJJJJJ")
    (c.dir / "target" / "f").write_text("keep\n")
    (c.prefix / "c-gone-KKKKKK").write_text("file\n")
    old_mtime(c.prefix / "c-gone-KKKKKK")
    # solo: one running session that started AFTER its root was recorded, so the recorded root is its.
    # solo2: one running session that started long BEFORE its record was written, so the record may be
    # another launch's and the running session's own root cannot be told apart: keep every one.
    # twin: two running sessions under one name, each with a root of its own: keep both.
    fx.agents("clean/agents.json", [
        {"pid": P1, "id": "cl1", "name": "solo-canonical", "startedAt": now * 1000},
        {"pid": P2, "id": "cl2", "name": "solo2-canonical", "startedAt": (now - 86400) * 1000},
        {"pid": P3, "id": "cl3", "name": "twin-canonical", "startedAt": now * 1000},
        {"pid": P4, "id": "cl4", "name": "twin-canonical", "startedAt": now * 1000}])
    every = ["c-gone-AAAAAA", "c-gone-BBBBBB", "c-quiet-CCCCCC", "c-solo-DDDDDD", "c-solo-EEEEEE", "c-solo2-PPPPPP", "c-solo2-QQQQQQ",
             "c-twin-FFFFFF", "c-twin-GGGGGG", "c-gone-HHHHHH", "c-gone-toolong7", "c-gone-abc", "c-stranger-IIIIII", "c-gone-JJJJJJ", "c-gone-KKKKKK"]
    r = c.fc("--dry-run")
    missing = [n for n in every if not c.exists(n)]
    chk(r.rc == 0 and not missing and seq(r.out, "would remove", "c-gone-AAAAAA"), "clean --dry-run names what it would remove and removes nothing",
        "clean --dry-run (rc=%s, gone:%s): %s" % (r.rc, " " + " ".join(missing) if missing else "", r.out))
    r = c.fc()
    gone = ["c-gone-AAAAAA", "c-gone-BBBBBB", "c-quiet-CCCCCC", "c-solo-EEEEEE"]
    kept = ["c-solo-DDDDDD", "c-solo2-PPPPPP", "c-solo2-QQQQQQ", "c-twin-FFFFFF", "c-twin-GGGGGG", "c-gone-HHHHHH", "c-gone-toolong7",
            "c-gone-abc", "c-stranger-IIIIII", "c-gone-JJJJJJ", "c-gone-KKKKKK"]
    left = [n for n in gone if (c.prefix / n).exists()]
    chk(r.rc == 0 and not left, "clean removes the roots of names with no running session", "clean left roots of gone sessions (rc=%s, left:%s): %s" % (r.rc, " " + " ".join(left), r.out))
    chk(not (c.state / "quiet-canonical.tmproot").is_file(), "clean clears the record of a root it removed", "clean removed a recorded root but left its record")
    lost = [n for n in kept if not c.exists(n)]
    chk(not lost, "clean keeps every root a running session may own, and every path of another shape",
        "clean deleted roots it must keep: %s -- %s" % (" ".join(lost), r.out))
    chk((c.prefix / "c-solo-DDDDDD" / "claude-1000" / "f").is_file() and (c.prefix / "c-twin-FFFFFF" / "claude-1000" / "f").is_file(),
        "a kept root's contents are untouched", "clean emptied a live session's root")
    chk((c.dir / "target" / "f").is_file(), "clean never follows a symlink of the root's shape", "clean deleted through a symlink")
    chk((c.state / "solo-canonical.tmproot").is_file() and (c.state / "solo2-canonical.tmproot").is_file(),
        "clean leaves the records of running sessions alone", "clean removed a running session's record")


def test_clean_fails_closed_and_refuses_unknown_arguments(fx):
    c = Clean(fx, ["gone-canonical"])
    c.mkroot("c-gone-LLLLLL")
    # Fail closed: a listing that cannot be read is not an empty fleet.
    r = c.fc(env={"FLEET_AGENTS_JSON_CMD": "false"})
    chk(r.rc == 2 and (c.prefix / "c-gone-LLLLLL").is_dir(), "clean refuses, removing nothing, when the sessions list cannot be read",
        "clean on an unreadable listing (rc=%s): %s" % (r.rc, r.out))
    r = c.fc("--bogus")
    chk(r.rc != 0 and (c.prefix / "c-gone-LLLLLL").is_dir(), "clean refuses an unknown argument", "clean accepted an unknown argument (rc=%s): %s" % (r.rc, r.out))


def test_clean_keeps_the_roots_of_a_seat_the_listing_omits_while_its_process_lives(fx):
    # A seat the live listing omits (its job reads `done` or `failed`) while its process still runs is
    # a running session: its roots are kept. Measured on a work machine: every running seat there was
    # listed `failed`, and clean removed all ten of their roots once they were ten minutes old.
    c = Clean(fx, ["ghost-canonical"])
    c.mkroot("c-ghost-MMMMMM")
    c.mkroot("c-ghost-NNNNNN")
    fx.live_holder(93111, "ghost-canonical", "gh000001-sess")
    r = c.fc()
    chk(r.rc == 0 and (c.prefix / "c-ghost-MMMMMM").is_dir() and (c.prefix / "c-ghost-NNNNNN").is_dir()
        and (c.prefix / "c-ghost-MMMMMM" / "claude-1000" / "f").is_file(),
        "clean keeps the roots of a seat the listing omits while its process lives", "clean removed a live, unlisted seat's roots (rc=%s): %s" % (r.rc, r.out))
    chk(seq(r.out, "c-ghost-MMMMMM", "live process"), "...and says a live process holds the name", "ghost keep reason: %s" % r.out)
    # Its process gone, the same roots are a gone session's and are removed.
    fx.drop_holder(93111)
    r = c.fc()
    chk(r.rc == 0 and not (c.prefix / "c-ghost-MMMMMM").exists() and not (c.prefix / "c-ghost-NNNNNN").exists(),
        "with no live process behind it, an unlisted seat's roots are removed", "clean kept a gone seat's roots (rc=%s): %s" % (r.rc, r.out))


def test_clean_refuses_where_it_cannot_see_live_processes(fx):
    # Fail closed where the live-process check cannot see: inside the Linux sandbox other sessions'
    # processes are hidden, and without the queue script or uv the check cannot run at all. Either
    # way every unlisted seat would read as gone, so clean refuses and removes nothing.
    c = Clean(fx, ["gone-canonical"])
    c.mkroot("c-gone-RRRRRR")
    (fx.proc / "1").mkdir()
    (fx.proc / "1" / "comm").write_text("bwrap\n")
    r = c.fc()
    shutil.rmtree(fx.proc / "1")
    chk(r.rc == 2 and (c.prefix / "c-gone-RRRRRR").is_dir() and "sandbox" in r.out, "clean refuses inside a sandbox, removing nothing",
        "clean in a sandbox (rc=%s): %s" % (r.rc, r.out))
    r = c.fc(env={"FLEET_CANONICALS_QUEUE": c.dir / "no-such-queue"})
    chk(r.rc == 2 and (c.prefix / "c-gone-RRRRRR").is_dir(), "clean refuses, removing nothing, when the live-process check cannot run",
        "clean without the queue script (rc=%s): %s" % (r.rc, r.out))


# ---- on-demand seats: canonicalAutostart and the autostart-default config key ----------------------------
# Not every seat should start on a bare `up`: some are always on, others case by case. A seat's
# `canonicalAutostart` (else the machine's `autostart-default`, else true) decides whether a bare `up`
# starts it, and nothing that acts on seats WITHOUT a name may start one that is off. Every case runs
# against its own fixture record.

AU_SEATS = [("opt", "auto-opt-canonical", "the optional seat", "    canonicalAutostart: false\n"),
            ("plain", "auto-plain-canonical", "the seat that sets no key", ""),
            ("crit", "auto-crit-canonical", "the critical seat", "    canonicalAutostart: true\n")]


class Auto:
    def __init__(self, fx):
        self.fx = fx
        self.dir = fx.T / "autostart"
        self.st = self.dir / "st"
        self.st.mkdir(parents=True)

        def rec(opt_extra=None, keys=True):
            return RECORD_HEAD + "".join(
                seat_yaml(k, k, n, k, "fable", (opt_extra if (k == "opt" and opt_extra is not None) else extra) if keys else "", identity=ident)
                for k, n, ident, extra in AU_SEATS)

        (self.dir / "rec.yaml").write_text(rec())
        # The same fleet with no seat setting the key: what every machine runs today.
        (self.dir / "rec-nokeys.yaml").write_text(rec(keys=False))
        (self.dir / "rec-bad.yaml").write_text(rec(opt_extra="    canonicalAutostart: maybe\n"))
        for k, n, _i, _e in AU_SEATS:
            (self.dir / k).mkdir()
            fx.pointer(self.st, n, fx.first_launch_handoff(self.st, n), fx.now)
        fx.agents("autostart/none.json", [])
        # Only the always-on pair is running: the optional seat is down.
        fx.agents("autostart/pair.json", [
            {"pid": P1, "id": "pl1", "cwd": "/x", "kind": "background", "startedAt": 1000, "sessionId": "s1", "name": "auto-plain-canonical", "status": "idle", "state": "done"},
            {"pid": P2, "id": "cr2", "cwd": "/y", "kind": "background", "startedAt": 1000, "sessionId": "s2", "name": "auto-crit-canonical", "status": "idle", "state": "done"}])
        fx.agents("autostart/all3.json", [
            {"pid": P1, "id": "op0", "cwd": "/x", "kind": "background", "startedAt": 1000, "sessionId": "s0", "name": "auto-opt-canonical", "status": "idle", "state": "done"}])

    def run(self, rec, js, *args, env=None):
        e = {"FLEET_ROOT": self.dir, "FLEET_RECORD": self.dir / rec, "FLEET_STATE": self.st, "FLEET_AGENTS_JSON_CMD": self.fx.cat(self.dir / js)}
        e.update(env or {})
        return self.fx.run(*args, env=e)


@pytest.fixture
def au(fx):
    return Auto(fx)


def starts(out, name):
    return re.search(r"^would start +%s( |$)" % re.escape(name), str(out), re.M) is not None


def verdict(out, name, rest):
    return re.search(r"^%s +%s" % (re.escape(name), rest), str(out), re.M) is not None


def test_autostart_a_bare_up_skips_a_seat_set_false(au):
    out = au.run("rec.yaml", "none.json", "up", "--dry-run").out
    chk(not starts(out, "auto-opt-canonical"), "a: bare up skips a seat with canonicalAutostart: false",
        "a: bare up --dry-run would start a seat with canonicalAutostart: false: %s" % out)
    chk(starts(out, "auto-plain-canonical") and starts(out, "auto-crit-canonical"), "a: bare up still starts the seat with no key and the one set true",
        "a: bare up lost an autostart seat: %s" % out)


def test_autostart_default_comes_from_the_env_or_the_config_and_a_seats_key_wins(au):
    out = au.run("rec.yaml", "none.json", "up", "--dry-run", env={"FLEET_AUTOSTART_DEFAULT": "false"}).out
    chk(not starts(out, "auto-plain-canonical"), "b: autostart-default = false skips a seat that sets no key",
        "b: autostart-default false did not skip a seat with no key: %s" % out)
    chk(starts(out, "auto-crit-canonical"), "b: a seat set true still starts under autostart-default = false", "b: canonicalAutostart: true lost to the default: %s" % out)
    chk(not starts(out, "auto-opt-canonical"), "b: the false seat stays off under default false", "b: the false seat started under default false: %s" % out)
    # The default can come from the config file, read like the other keys.
    cfg = au.dir / "config"
    cfg.write_text("autostart-default = false\n")
    out = au.run("rec.yaml", "none.json", "up", "--dry-run", env={"FLEET_CANONICALS_CONFIG": cfg}).out
    chk(not starts(out, "auto-plain-canonical") and starts(out, "auto-crit-canonical"), "b: autostart-default is read from the config file",
        "b: config file key ignored: %s" % out)
    # A seat's own key wins over a default of true as well.
    cfg.write_text("autostart-default = true\n")
    out = au.run("rec.yaml", "none.json", "up", "--dry-run", env={"FLEET_CANONICALS_CONFIG": cfg}).out
    chk(not starts(out, "auto-opt-canonical") and starts(out, "auto-plain-canonical"), "b: a seat's false beats a default of true",
        "b: seat key lost to default true: %s" % out)


def test_autostart_naming_a_seat_starts_it_wherever_the_default_points(au):
    out = au.run("rec.yaml", "none.json", "up", "--dry-run", "auto-opt-canonical").out
    chk(starts(out, "auto-opt-canonical"), "c: up --dry-run <name> starts an optional seat", "c: naming an optional seat did not start it: %s" % out)
    chk(not starts(out, "auto-plain-canonical"), "c: naming one seat starts only that seat", "c: a named up started another seat: %s" % out)
    out = au.run("rec.yaml", "none.json", "up", "--dry-run", "auto-plain-canonical", env={"FLEET_AUTOSTART_DEFAULT": "false"}).out
    chk(starts(out, "auto-plain-canonical"), "c: a named seat starts even where the default is false", "c: named seat refused by the default: %s" % out)


def test_autostart_up_all_starts_every_declared_seat(au):
    out = au.run("rec.yaml", "none.json", "up", "--all", "--dry-run", env={"FLEET_AUTOSTART_DEFAULT": "false"}).out
    chk(starts(out, "auto-opt-canonical") and starts(out, "auto-plain-canonical") and starts(out, "auto-crit-canonical"),
        "d: up --all --dry-run starts every declared seat", "d: up --all missed a seat: %s" % out)
    r = au.run("rec.yaml", "none.json", "up", "--all", "auto-opt-canonical", "--dry-run")
    chk(r.rc != 0, "d: up --all with names is refused", "d: up --all plus a name was accepted: %s" % r.out)


def test_autostart_status_reads_a_down_optional_seat_as_off_not_missing(au):
    r = au.run("rec.yaml", "pair.json", "status")
    chk(verdict(r.out, "auto-opt-canonical", r"off \(on demand\)"), "e: a down optional seat reads 'off (on demand)'", "e: optional seat verdict: %s" % r.out)
    chk("MISSING" not in r.out and r.rc == 0, "e: an off seat is not missing: status exits 0", "e: an off seat counted as unhealthy (rc=%s): %s" % (r.rc, r.out))
    r = au.run("rec.yaml", "none.json", "status")
    chk(verdict(r.out, "auto-crit-canonical", "MISSING") and verdict(r.out, "auto-plain-canonical", "MISSING") and r.rc == 1,
        "e: a down autostart seat is still MISSING, and status exits 1", "e: autostart seat verdict (rc=%s): %s" % (r.rc, r.out))
    out = au.run("rec.yaml", "all3.json", "status").out
    chk(verdict(out, "auto-opt-canonical", "OK "), "e: a live optional seat still reads OK", "e: live optional seat: %s" % out)
    out = au.run("rec.yaml", "pair.json", "status", env={"FLEET_AUTOSTART_DEFAULT": "false"}).out
    chk(verdict(out, "auto-opt-canonical", r"off \(on demand\)"), "e: the default applies to status too (no key, default false)", "e: status ignored the default: %s" % out)


def test_autostart_with_no_config_and_no_key_every_seat_starts(au):
    # today's behavior: no config and no key means every seat autostarts.
    out = au.run("rec-nokeys.yaml", "none.json", "up", "--dry-run").out
    chk(starts(out, "auto-opt-canonical") and starts(out, "auto-plain-canonical") and starts(out, "auto-crit-canonical"),
        "g: with no config and no key, bare up starts every seat", "g: default is not today's behavior: %s" % out)
    out = au.run("rec-nokeys.yaml", "none.json", "status").out
    chk("off (on demand)" not in out, "g: with no config and no key, nothing reads off", "g: status shows an off seat: %s" % out)
    # A value other than true or false fails toward starting, and says so.
    out = au.run("rec-nokeys.yaml", "none.json", "up", "--dry-run", env={"FLEET_AUTOSTART_DEFAULT": "maybe"}).out
    chk(starts(out, "auto-opt-canonical") and starts(out, "auto-plain-canonical") and seq(out, "autostart-default", "maybe", "not true or false"),
        "g: a bad autostart-default is reported and treated as true", "g: bad default: %s" % out)
    out = au.run("rec-bad.yaml", "none.json", "up", "--dry-run").out
    chk(starts(out, "auto-opt-canonical") and seq(out, "canonicalAutostart", "maybe", "not true or false"),
        "g: a bad canonicalAutostart is reported and treated as true", "g: bad seat key: %s" % out)


# ---- up runs the handoff freshness gate ---------------------------------------------------------------
# `up` used to check only that the pointer's file exists, so a seat that died unparked, or whose last
# park predates its last session, launched on a stale document while `refresh` of the same seat
# refused. The gate is fed the FULL listing, so a stopped row still supplies the session to compare.

class UpGate:
    def __init__(self, fx, g):
        self.fx, self.g = fx, g
        self.dir = fx.T / "ua"
        (self.dir / "transcripts" / "proj").mkdir(parents=True)
        self.start = fx.now - 3600
        self.live = fx.agents("ua/live.json", [])
        self.all = fx.agents("ua/all.json", [{"pid": None, "id": "ddd4", "name": "zeta-canonical", "sessionId": "sz", "state": "done",
                                              "startedAt": self.start * 1000}])
        self.stale = g.staged(self.start - 7200)     # the park is stamped two hours before the session it would hand over from
        self.good = g.staged(self.start + 600)

    def transcript(self, doc, calls):
        """A transcript for session sz: it begins at its start and has <calls> tool calls after <doc>."""
        lines = [{"type": "user", "isSidechain": False, "timestamp": iso(self.start, ".250Z")}]
        for i in range(1, calls + 1):
            lines.append({"type": "assistant", "isSidechain": False, "timestamp": iso(doc + 60 + i, ".250Z"),
                          "message": {"id": "ua%d" % i, "content": [{"type": "tool_use", "id": "uat%d" % i}]}})
        (self.dir / "transcripts" / "proj" / "sz.jsonl").write_text("".join(json.dumps(l) + "\n" for l in lines))

    def fc(self, *args, env=None):
        e = {"FLEET_STATE": self.g.gs2, "FLEET_HANDOFFS_DIR": self.g.gh2, "FLEET_TRANSCRIPT_DIR": self.dir / "transcripts",
             "FLEET_AGENTS_JSON_CMD": self.fx.cat(self.live), "FLEET_AGENTS_JSON_ALL_CMD": self.fx.cat(self.all)}
        e.update(env or {})
        return self.fx.run(*args, env=e)

    def fresh(self, doc):
        self.g.gfresh(doc, self.fx.now - 60)
        self.g.gdoc(doc)

    def live_row(self):
        self.live = self.fx.agents("ua/live.json", [{"pid": P4, "id": "ddd4", "name": "zeta-canonical", "sessionId": "sz", "startedAt": self.start * 1000}])


@pytest.fixture
def ua(fx, gate):
    return UpGate(fx, gate)


def test_up_refuses_a_dead_seat_whose_park_predates_its_last_session(fx, ua):
    ua.fresh(ua.stale)
    ua.transcript(ua.start - 7200, 3)
    r = ua.fc("up", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and seq(r.out, "REFUSED", "zeta-canonical", "BEFORE the session started") and "would start" not in r.out,
        "up refuses a dead seat whose last session started after its park's stamp", "up passed a stale park (rc=%s): %s" % (r.rc, r.out))
    # controls: a correctly parked seat starts; --force on the stale case proceeds, loudly
    ua.fresh(ua.good)
    ua.transcript(ua.start + 600, 3)
    r = ua.fc("up", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and seq(r.out, "would start", "zeta-canonical") and "REFUSED" not in r.out,
        "up starts a dead seat whose park follows its last session (control)", "up refused a correctly parked seat (rc=%s): %s" % (r.rc, r.out))
    ua.fresh(ua.stale)
    r = ua.fc("up", "zeta-canonical", "--force", "x", "--dry-run")
    chk(r.rc == 0 and "FORCED" in r.out and seq(r.out, "would start", "zeta-canonical"), "up --force proceeds on the stale case, saying FORCED",
        "up --force (rc=%s): %s" % (r.rc, r.out))
    r = ua.fc("up", "zeta-canonical", "--stub", "x", "--dry-run")
    chk(r.rc == 0 and "would write a stub handoff" in r.out and seq(r.out, "would start", "zeta-canonical"),
        "up --stub --dry-run passes the stale pointer and would proceed (writes nothing)", "up --stub (rc=%s): %s" % (r.rc, r.out))
    r = ua.fc("up", "zeta-canonical", "--force", "x", "--stub", "y", "--dry-run")
    chk(r.rc != 0 and "opposites" in r.out, "up refuses --force with --stub", "up --force --stub (rc=%s): %s" % (r.rc, r.out))
    r = ua.fc("up", "zeta-canonical", "--bogus", "--dry-run")
    chk(r.rc != 0 and "unknown option '--bogus'" in r.out, "up still refuses an unknown option", "up --bogus (rc=%s): %s" % (r.rc, r.out))


def test_up_with_several_seats_refuses_the_stale_one_and_starts_the_other(fx, ua):
    ua.fresh(ua.stale)
    ua.transcript(ua.start + 600, 3)
    # theta never ran: no row, no transcript, and the first-launch handoff init writes.
    theta = fx.first_launch_handoff(ua.g.gs2, "theta-canonical")
    fx.pointer(ua.g.gs2, "theta-canonical", theta, fx.now - 60)
    r = ua.fc("up", "zeta-canonical", "theta-canonical", "--dry-run")
    chk(r.rc != 0 and seq(r.out, "REFUSED", "zeta-canonical", "BEFORE the session started") and seq(r.out, "would start", "theta-canonical")
        and not any(l.startswith("would start zeta") for l in r.out.split("\n")),
        "up with two seats: the stale one is refused, the other would start, the status is nonzero", "up with two seats (rc=%s): %s" % (r.rc, r.out))


def test_refresh_runs_the_gate_once_and_up_does_not_undo_it(fx, ua):
    # refresh must not be gated twice, nor undone by up: a refresh --force of a stopped, stale seat runs up once
    ua.transcript(ua.start + 600, 3)
    ua.fresh(ua.stale)
    r = ua.fc("refresh", "zeta-canonical", "--force", "x", env={"FLEET_CLAUDE_CMD": "false"})
    chk("FORCED" in r.out and "REFUSED" not in r.out and "BEFORE the session started" not in r.out,
        "refresh --force of a stale stopped seat is not undone by up's gate", "refresh --force was refused or gated twice (rc=%s): %s" % (r.rc, r.out))
    n = sum(1 for l in r.out.split("\n") if "FORCED" in l)
    chk(n == 1, "refresh runs the gate once, not once more through up", "gate ran %s times through refresh: %s" % (n, r.out))
    # refresh --stub of the same seat likewise (the stub is not standard-named; up must not gate it again)
    ua.fresh(ua.stale)
    r = ua.fc("refresh", "zeta-canonical", "--stub", "x", env={"FLEET_CLAUDE_CMD": "false"})
    chk("stub written" in r.out and "REFUSED" not in r.out, "refresh --stub of a stale stopped seat is not refused by up's gate",
        "refresh --stub refused through up (rc=%s): %s" % (r.rc, r.out))


@pytest.mark.parametrize("dv", ["refresh", "up"])
def test_a_dry_run_stub_writes_nothing(fx, ua, dv):
    # A rehearsal changes nothing: --stub under --dry-run writes no file and leaves the pointer where
    # it was, for refresh and for up alike, and says it would write one.
    ua.fresh(ua.good)
    ua.transcript(ua.start + 600, 3)
    before = ua.fc("handoff", "zeta-canonical").out
    r = ua.fc(dv, "zeta-canonical", "--dry-run", "--stub", "x")
    after = ua.fc("handoff", "zeta-canonical").out
    chk(r.rc == 0 and before == after and before != "" and not (ua.g.gs2 / "stub-handoffs").exists()
        and "would write a stub handoff" in r.out and "stub written" not in r.out and str(ua.g.gs2 / "stub-handoffs") in r.out,
        "%s --dry-run --stub writes no stub, leaves the pointer alone and names the directory it would write to" % dv,
        "%s --dry-run --stub changed state or did not say so (rc=%s, ptr %s -> %s): %s" % (dv, r.rc, before, after, r.out))


def test_down_dry_run_stub_writes_nothing_and_names_its_directory(fx, ua):
    ua.fresh(ua.good)
    ua.transcript(ua.start + 600, 3)
    ua.live_row()
    before = ua.fc("handoff", "zeta-canonical").out
    r = ua.fc("down", "zeta-canonical", "--dry-run", "--stub", "x")
    after = ua.fc("handoff", "zeta-canonical").out
    d = ua.g.gs2 / "stub-handoffs"
    chk(r.rc == 0 and before == after and before != "" and not d.exists() and "would write a stub handoff" in r.out and str(d) in r.out,
        "down --dry-run --stub writes nothing, leaves the pointer alone and names the stub directory",
        "down --dry-run --stub (rc=%s, ptr %s -> %s, dir exists %s): %s" % (r.rc, before, after, d.exists(), r.out))


def test_the_work_since_park_check_fails_closed(fx, ua):
    # A listed seat whose transcript cannot be read cannot be shown not to have worked past its park,
    # so the gate refuses (it used to print "skipped" and pass), naming the hatches.
    ua.fresh(ua.good)
    ua.live_row()
    r = ua.fc("down", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "no readable transcript" in r.out and "--force" in r.out and "--stub" in r.out and "handoff zeta-canonical --set" in r.out,
        "down refuses a listed seat whose transcript cannot be read (work-since-park fails closed)", "unreadable transcript passed the work check (rc=%s): %s" % (r.rc, r.out))
    r = ua.fc("down", "zeta-canonical", "--force", "x", "--dry-run")
    chk(r.rc == 0 and "FORCED" in r.out, "--force lifts the unreadable-transcript refusal", "--force unreadable transcript (rc=%s): %s" % (r.rc, r.out))
    ua.transcript(ua.start + 600, 40)
    r = ua.fc("down", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "no readable transcript" not in r.out, "a transcript with 40 calls after the document passes (control)",
        "a readable transcript was refused (rc=%s): %s" % (r.rc, r.out))


def test_force_does_not_lift_the_no_pointer_refusal_and_the_equal_second_boundary(fx, ua):
    g = ua.g
    g.gs2.mkdir(parents=True)
    r = ua.fc("refresh", "zeta-canonical", "--dry-run", "--force", "x")
    chk(r.rc != 0 and "no handoff is recorded" in r.out and "FORCED" not in r.out, "refresh --force with no pointer is refused",
        "--force passed with no pointer (rc=%s): %s" % (r.rc, r.out))
    r = ua.fc("refresh", "zeta-canonical", "--dry-run", "--stub", "x")
    chk(r.rc == 0 and "would write a stub handoff" in r.out and not (g.gs2 / "stub-handoffs").exists(),
        "--stub stays the hatch for no pointer (dry run: writes nothing)", "--stub with no pointer (rc=%s): %s" % (r.rc, r.out))
    # a pointer recorded in the very second the session started predates its work: refused, as in the queue
    ua.live_row()
    g.gfresh("-", ua.start)
    r = ua.fc("refresh", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "PREDATES" in r.out, "a pointer recorded at exactly the session's start second is refused",
        "equal-second pointer passed (rc=%s): %s" % (r.rc, r.out))
    g.gfresh("-", ua.start + 1)
    r = ua.fc("refresh", "zeta-canonical", "--dry-run")
    chk("PREDATES" not in r.out, "a pointer one second after the start is not refused as predating (control)",
        "pointer one second after start refused as PREDATES (rc=%s): %s" % (r.rc, r.out))


# ---- the gate when the seat's listing row is gone ----------------------------------------------------------
# `down`, `down --all` and `refresh` close a session with `claude rm`, which deletes its row, so the next
# `up` finds no row for the seat. The gate used to read "no row" as "a seat that never ran" and skip both
# the predates comparison and the work-since-park count, launching on a stale park unchecked. It now
# recovers the seat's LAST session from the transcripts filed under its launch directory, and a seat with
# neither a row nor a transcript passes only on the first-launch handoff `init` writes.

class NoRow:
    """zeta with no listing row anywhere, and transcripts filed where its launch directory says."""

    def __init__(self, fx, ua):
        self.fx, self.ua = fx, ua
        ua.all = fx.agents("ua/norow.json", [])
        self.tdir = ua.dir / "transcripts"
        self.key = re.sub(r"[^A-Za-z0-9]", "-", str(fx.T / "zeta"))
        (self.tdir / self.key).mkdir(parents=True, exist_ok=True)

    def session(self, sid, start, doc=None, calls=0, name="zeta-canonical"):
        """A transcript for session <sid> naming the seat (the compact spelling a real transcript has),
        beginning at <start>, with <calls> main-thread tool calls after <doc>. Returns its path."""
        def dump(o):
            return json.dumps(o, separators=(",", ":")) + "\n"
        lines = [dump({"type": "agent-name", "agentName": name, "sessionId": sid}),
                 dump({"type": "user", "isSidechain": False, "timestamp": iso(start, ".250Z")})]
        for i in range(1, calls + 1):
            lines.append(dump({"type": "assistant", "isSidechain": False, "timestamp": iso(doc + 60 + i, ".250Z"),
                               "message": {"id": "%s-m%d" % (sid, i), "content": [{"type": "tool_use", "id": "%s-t%d" % (sid, i)}]}}))
        f = self.tdir / self.key / (sid + ".jsonl")
        f.write_text("".join(lines))
        return f


@pytest.fixture
def nr(fx, ua):
    return NoRow(fx, ua)


def test_the_gate_runs_without_a_row_and_refuses_a_park_older_than_the_last_session(fx, ua, nr):
    # (a) The pointer was recorded before the seat's last session began, and the row that would say so is gone.
    ua.g.gfresh(ua.stale, ua.start - 100)
    ua.g.gdoc(ua.stale)
    nr.session("sz", ua.start)
    r = ua.fc("up", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and seq(r.out, "REFUSED", "zeta-canonical", "PREDATES") and "would start" not in r.out and "from the transcript" in r.out,
        "up with no listing row compares the park against the last session found in the seat's transcripts",
        "up launched on a park older than the seat's last session (rc=%s): %s" % (r.rc, r.out))


def test_the_work_since_park_count_runs_without_a_row(fx, ua, nr):
    # (b) A session that began before its park and kept working after it: counted from its transcript.
    doc = ua.start + 600
    ua.fresh(ua.g.staged(doc))
    nr.session("sz", ua.start, doc, calls=41)
    r = ua.fc("up", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "kept working" in r.out and "41" in r.out and "would start" not in r.out,
        "up with no listing row counts the tool calls the last session made after its park",
        "up launched on a park the last session worked past (rc=%s): %s" % (r.rc, r.out))


def test_a_seat_with_no_row_and_no_transcript_is_refused_unless_it_never_ran(fx, ua, nr):
    # (c) Nothing shows the seat never ran: fail closed, naming the places looked and the hatches.
    ua.fresh(ua.good)
    r = ua.fc("up", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "would start" not in r.out and "no row" in r.out and "--force" in r.out and "--stub" in r.out
        and "transcript" in r.out and nr.key in r.out,
        "up with no row and no transcript refuses, naming what was looked for, where, and both hatches",
        "up passed a seat with no row and no transcript (rc=%s): %s" % (r.rc, r.out))
    r = ua.fc("up", "zeta-canonical", "--force", "x", "--dry-run")
    chk(r.rc == 0 and "FORCED" in r.out and "would start" in r.out, "--force lifts that refusal (control)", "--force (rc=%s): %s" % (r.rc, r.out))
    r = ua.fc("up", "zeta-canonical", "--stub", "x", "--dry-run")
    chk(r.rc == 0 and "would write a stub handoff" in r.out and "would start" in r.out, "--stub lifts that refusal (control)", "--stub (rc=%s): %s" % (r.rc, r.out))


def test_a_seat_with_no_row_passes_on_a_fresh_park_with_little_work_after_it(fx, ua, nr):
    # (d) Control: the last session began before the park and did little after it.
    doc = ua.start + 600
    ua.fresh(ua.g.staged(doc))
    nr.session("sz", ua.start, doc, calls=3)
    r = ua.fc("up", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and seq(r.out, "would start", "zeta-canonical") and "REFUSED" not in r.out and "listing has no row" in r.out,
        "up with no row passes a fresh park, and says the session start came from the transcript",
        "up refused a fresh park (rc=%s): %s" % (r.rc, r.out))


def test_a_first_launch_handoff_passes_for_a_seat_that_never_ran(fx, ua, nr):
    # (e) Control: `init` wrote the pointer's target; no row, no transcript. theta is the seat whose
    # declaration is complete enough for init (see the init case above).
    ua.g.gs2.mkdir(parents=True)
    r = ua.fc("init", "theta-canonical")
    chk(r.rc == 0 and "first-launch" in r.out, "init writes the first-launch handoff", "init (rc=%s): %s" % (r.rc, r.out))
    r = ua.fc("up", "theta-canonical", "--dry-run")
    chk(r.rc == 0 and seq(r.out, "would start", "theta-canonical") and "REFUSED" not in r.out,
        "up with no row and no transcript passes on the first-launch handoff init wrote",
        "up refused a never-run seat (rc=%s): %s" % (r.rc, r.out))
    # The same file name somewhere else is not init's file: a copy outside the stub directory is refused.
    other = fx.T / "elsewhere"
    other.mkdir()
    copy = other / Path(ua.fc("handoff", "theta-canonical").out).name
    copy.write_text("x\n")
    fx.pointer(ua.g.gs2, "theta-canonical", copy, fx.now)
    r = ua.fc("up", "theta-canonical", "--dry-run")
    chk(r.rc != 0 and "would start" not in r.out, "a first-launch-shaped file outside the stub directory does not pass",
        "up passed a look-alike (rc=%s): %s" % (r.rc, r.out))


def test_the_gate_compares_against_the_seats_newest_session_not_the_first_match(fx, ua, nr):
    # (f) Two sessions name the seat. The park lies between their starts, so against the older session it
    # would pass and against the newer it predates. The older one sorts first by name and is newer by file
    # time, so choosing by name, by file time or by first match all pick it.
    ua.g.gfresh(ua.g.staged(fx.now - 5000), fx.now - 5000)
    ua.g.gdoc(ua.g.staged(fx.now - 5000))
    old = nr.session("aa-old", fx.now - 7200)
    new = nr.session("zz-new", fx.now - 3600)
    os.utime(new, (fx.now - 9000, fx.now - 9000))
    os.utime(old, (fx.now, fx.now))
    r = ua.fc("up", "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "PREDATES" in r.out and "would start" not in r.out,
        "the gate compares against the session that started last, not the first or the most recently written transcript",
        "up compared against the older session (rc=%s): %s" % (r.rc, r.out))
    # Control: with only the older session on file, the same pointer passes.
    new.unlink()
    r = ua.fc("up", "zeta-canonical", "--dry-run")
    chk(r.rc == 0 and "would start" in r.out, "the same pointer passes against the older session alone (control)",
        "up refused against the older session (rc=%s): %s" % (r.rc, r.out))


# ---- up and resume from a sandbox refuse a seat a fresh snapshot lacks -----------------------------------------

def in_sandbox_snapshot(fx, seats, taken=None):
    """Make this case's process tree read as the Linux sandbox, and write the snapshot's seats."""
    (fx.proc / "1").mkdir(exist_ok=True)
    (fx.proc / "1" / "comm").write_text("bwrap\n")
    (fx.T / "sessions.json").write_text(json.dumps({"version": 1, "takenAt": taken or fx.now, "seats": seats}) + "\n")


@pytest.mark.parametrize("verb", ["up", "resume"])
def test_from_a_sandbox_a_seat_the_snapshot_lacks_is_refused(fx, ua, verb):
    ua.fresh(ua.good)
    ua.transcript(ua.start + 600, 3)
    ua.live = fx.agents("ua/live.json", [])
    in_sandbox_snapshot(fx, {})
    r = ua.fc(verb, "zeta-canonical", "--dry-run")
    chk(r.rc != 0 and "snapshot lacks" in r.out and "fleet-canonicals request %s zeta-canonical" % verb in r.out
        and "would start" not in r.out and "would wake" not in r.out and "would fork" not in r.out,
        "%s from a sandbox refuses a seat the fresh snapshot does not list, pointing at the request queue" % verb,
        "%s acted on the blind reading (rc=%s): %s" % (verb, r.rc, r.out))
    # Controls: the same seat listed dead goes on; out of the sandbox the absent seat is read directly.
    in_sandbox_snapshot(fx, {"zeta-canonical": {"state": "dead", "why": "no session"}})
    r = ua.fc(verb, "zeta-canonical", "--dry-run")
    chk("snapshot lacks" not in r.out and "REFUSED" not in r.out, "%s proceeds for a seat the snapshot lists dead (control)" % verb,
        "%s refused a dead seat (rc=%s): %s" % (verb, r.rc, r.out))
    shutil.rmtree(fx.proc / "1")
    (fx.T / "sessions.json").write_text(json.dumps({"version": 1, "takenAt": fx.now, "seats": {}}) + "\n")
    r = ua.fc(verb, "zeta-canonical", "--dry-run")
    chk("snapshot lacks" not in r.out and "REFUSED" not in r.out, "%s outside a sandbox reads the absent seat directly, as before (control)" % verb,
        "%s refused outside a sandbox (rc=%s): %s" % (verb, r.rc, r.out))


# ---- an unreadable pid record newer than the snapshot -----------------------------------------------------------

@pytest.mark.parametrize("snap_state", ["dead", None])
def test_an_unreadable_pid_record_newer_than_the_snapshot_reads_unknown(fx, snap_state):
    taken = fx.now - 100
    seats = {"zeta-canonical": {"state": snap_state, "why": "no session"}} if snap_state else {}
    (fx.T / "sessions.json").write_text(json.dumps({"version": 1, "takenAt": taken, "seats": seats}) + "\n")
    rec = fx.pids / "4999888.json"
    rec.write_text('{"pid": 4999888, "name": "zeta-can')     # caught mid-write
    line = lambda: [l for l in fx.run("status").out.split("\n") if l.startswith("zeta-canonical")][0]
    got = line()
    chk("UNKNOWN" in got and "MISSING" not in got, "status reads UNKNOWN, not MISSING, when a half-written pid record is newer than the snapshot",
        "status line: %s" % got)
    r = fx.run("up", "zeta-canonical", "--dry-run")
    if snap_state:
        chk("REFUSED" in r.out and "would start" not in r.out and "unreadable pid record" in r.out,
            "up refuses on that record too", "up (rc=%s): %s" % (r.rc, r.out))
    # Control: the same file older than the snapshot changes nothing.
    t = taken - 1000
    os.utime(rec, (t, t))
    got = line()
    chk("UNKNOWN" not in got and "MISSING" in got, "a garbage pid record older than the snapshot is still skipped (control)", "status line: %s" % got)


# ============================================================================== no leak into the real /tmp

TMPROOT_SHAPE = re.compile(r"^%s/c-[A-Za-z0-9-]+-[A-Za-z0-9]{6}$" % re.escape(WATCH_TMP.rstrip("/")))
SUITE_OWN_SHAPE = re.compile(r"^%s/c-test-[A-Za-z0-9]{6}$" % re.escape(WATCH_TMP.rstrip("/")))


def real_tmproots():
    """Only what a launch makes is a temp root: a DIRECTORY named c-<short>-XXXXXX. Another session's
    stray file named c-* is not one."""
    try:
        names = os.listdir(WATCH_TMP)
    except OSError:
        return set()
    out = set()
    for n in names:
        p = os.path.join(WATCH_TMP, n)
        if n.startswith("c-") and os.path.isdir(p) and not os.path.islink(p) and TMPROOT_SHAPE.match(p):
            out.add(p)
    return out


def live_session_roots():
    """The real fleet records each live root in its own state, which this suite never writes, so a
    new root recorded there is a running session's (a live canonical can be REFRESHED while the suite
    runs, making a new root mid-run), not a leak."""
    state = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "fleet-canonicals"
    roots = set()
    for f in state.glob("*.tmproot"):
        with contextlib.suppress(OSError):
            roots.update(l.strip() for l in f.read_text().split("\n") if l.strip())
    return roots


def leaked_roots(before, after, live):
    """Directories that appeared during the run and that no running session owns. The exact shape
    `c-test-XXXXXX` is another suite's (the scratch-hook suite makes its fixtures there because the
    guard it tests acts only there), and no seat in this suite shortens to `test`."""
    return sorted(p for p in set(after) - set(before) - set(live) if not SUITE_OWN_SHAPE.match(p))


class TmpRootLeakCheck:
    """A plugin of the entry point below: no temp-root directory may appear in the real /tmp during the
    whole run. Every launch here is redirected under a case's scratch directory, so one that appears
    escaped the redirect. It lives in the process that runs the workers and compares before the first
    case and after the last, so it spans every worker."""

    def __init__(self):
        self.before = None

    def pytest_configure(self, config):
        if not hasattr(config, "workerinput"):
            self.before = real_tmproots()

    def pytest_sessionfinish(self, session, exitstatus):
        if hasattr(session.config, "workerinput") or self.before is None:
            return
        leaked = leaked_roots(self.before, real_tmproots(), live_session_roots())
        if leaked:
            print("\nFAILED: found real %s temp-root leftovers during this suite: %s" % (WATCH_TMP, " ".join(leaked)), file=sys.stderr)
            session.exitstatus = 1
        else:
            print("\nok: no temp-root directories leaked into the real %s during this suite" % WATCH_TMP)


def test_the_leak_check_names_a_new_root_and_spares_what_it_should():
    w = WATCH_TMP.rstrip("/")
    before = {w + "/c-alpha-aaaaaa"}
    after = {w + "/c-alpha-aaaaaa", w + "/c-beta-bbbbbb", w + "/c-gamma-cccccc", w + "/c-test-dddddd"}
    chk(leaked_roots(before, after, live={w + "/c-gamma-cccccc"}) == [w + "/c-beta-bbbbbb"],
        "the end check reports a new root nothing owns, and ignores one that was there before, a running session's, and the scratch-hook suite's")


if __name__ == "__main__":
    # pytest-xdist runs the cases on several workers. The plugin is the end check: it spans them all.
    workers = str(min(8, os.cpu_count() or 2))
    # pytest (and xdist) make a pytest-of-<user> directory under $TMPDIR for tmp_path; this file's
    # basetemp is one directory of its own, removed afterwards.
    base = tempfile.mkdtemp(prefix="fcs-basetemp-", dir=ORIGINAL_TMP)
    try:
        status = pytest.main([__file__, "-q", "-p", "no:cacheprovider", "--basetemp", base, "-n", workers, *sys.argv[1:]],
                             plugins=[TmpRootLeakCheck()])
    finally:
        shutil.rmtree(base, ignore_errors=True)
    sys.exit(status)
