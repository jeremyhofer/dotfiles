#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for apply-status, the tool that owns the apply ledger (apply.log).

Run: npx nx run suite-apply-status:test
 or: uv run --script tests/test-apply-status.py [-k <pattern>]

What is held: `append` writes one tab-separated line (time, host, instance, event, source head with
`-dirty` or `unknown`, source dir, detail), keeps the file to its newest 1000 lines, and never exits
non-zero for a write problem (a usage error is exit 2). `status` shows each instance's latest apply
and flags a start with no end as incomplete, and a source ahead of what was deployed. `wait` polls
the local ledger, prints events and polls, and exits 0 (both instances deployed), 1 (refused) or 3
(timeout).

Everything runs against a scratch state directory (XDG_STATE_HOME) and scratch git repositories;
APPLY_STATUS_NOW fixes the tool's clock where an age is asserted.
"""
import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_apply-status"
HOST = socket.gethostname().split(".")[0]
TIME = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")


class Env:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.state = tmp / "state"
        self.ledger = self.state / "dotfiles" / "apply.log"
        # A fake `uname` first on PATH, so the status view's macOS-only agents line is decided by
        # FAKE_UNAME (default Linux) and not by the machine running the suite.
        self.fakebin = tmp / "fakebin"
        self.fakebin.mkdir()
        self.tool("uname", '#!/bin/sh\nprintf "%s\\n" "${FAKE_UNAME:-Linux}"\n')

    def tool(self, name, body):
        p = self.fakebin / name
        p.write_text(body)
        p.chmod(0o755)

    def env(self, **extra):
        env = dict(os.environ)
        env.update({"XDG_STATE_HOME": str(self.state), "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "PATH": str(self.fakebin) + os.pathsep + os.environ["PATH"]})
        env.pop("APPLY_STATUS_NOW", None)
        for k in [k for k in env if k.startswith("CHEZMOI")]:
            del env[k]
        env.update(extra)
        return env

    def run(self, *args, timeout=60, **extra):
        return subprocess.run([sys.executable, str(TOOL), *args], env=self.env(**extra),
                              capture_output=True, text=True, stdin=subprocess.DEVNULL,
                              timeout=timeout)

    def repo(self, name="src") -> Path:
        d = self.tmp / name
        d.mkdir(exist_ok=True)
        (d / "f").write_text("one\n")
        for cmd in (["init", "-q"], ["add", "-A"],
                    ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                     "commit", "-q", "-m", "one"]):
            subprocess.run(["git", "-C", str(d), *cmd], env=self.env(), check=True,
                           capture_output=True)
        return d

    def commit(self, d: Path, text: str) -> None:
        (d / "f").write_text(text)
        subprocess.run(["git", "-C", str(d), "-c", "user.name=t", "-c", "user.email=t@t",
                        "-c", "commit.gpgsign=false", "commit", "-q", "-am", text],
                       env=self.env(), check=True, capture_output=True)

    def head(self, d: Path) -> str:
        return subprocess.run(["git", "-C", str(d), "rev-parse", "--short", "HEAD"],
                              env=self.env(), check=True, capture_output=True,
                              text=True).stdout.strip()

    def lines(self):
        return self.ledger.read_text().splitlines() if self.ledger.exists() else []

    def plant(self, *rows):
        """Write ledger lines directly: (time, instance, event, head, detail)."""
        self.ledger.parent.mkdir(parents=True, exist_ok=True)
        with open(self.ledger, "a") as f:
            for t, inst, ev, head, detail in rows:
                f.write("\t".join([t, HOST, inst, ev, head, str(self.tmp / "src"), detail]) + "\n")


@pytest.fixture
def e(tmp_path):
    return Env(tmp_path)


def iso(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


# --- append ----------------------------------------------------------------------------------------

def test_append_writes_one_tab_separated_line(e):
    src = e.repo()
    out = e.run("append", "--source", str(src), "base", "start")
    assert (out.returncode, out.stdout, out.stderr) == (0, "", "")
    [line] = e.lines()
    cols = line.split("\t")
    assert len(cols) == 7, line
    assert TIME.match(cols[0])
    assert cols[1:4] == [HOST, "base", "start"]
    assert cols[4] == e.head(src)
    assert cols[5] == str(src)
    assert cols[6] == ""


def test_append_creates_the_directory_and_appends(e):
    src = e.repo()
    e.run("append", "--source", str(src), "base", "start")
    e.run("append", "--source", str(src), "overlay", "deployed", "ok")
    assert [ln.split("\t")[2:4] for ln in e.lines()] == [["base", "start"], ["overlay", "deployed"]]
    assert e.lines()[1].split("\t")[6] == "ok"


def test_append_marks_a_dirty_tree(e):
    src = e.repo()
    (src / "f").write_text("changed\n")
    e.run("append", "--source", str(src), "base", "start")
    assert e.lines()[0].split("\t")[4] == e.head(src) + "-dirty"


def test_append_marks_a_source_that_is_not_a_repository_unknown(e):
    plain = e.tmp / "plain"
    plain.mkdir()
    out = e.run("append", "--source", str(plain), "base", "start")
    assert out.returncode == 0
    assert e.lines()[0].split("\t")[4] == "unknown"


def test_append_flattens_tabs_and_newlines_in_the_detail(e):
    src = e.repo()
    e.run("append", "--source", str(src), "base", "refused", "a\tb\nc\r\nd")
    [line] = e.lines()
    assert len(line.split("\t")) == 7
    assert line.split("\t")[6] == "a b c  d"


def test_append_keeps_the_newest_thousand_lines(e):
    src = e.repo()
    e.ledger.parent.mkdir(parents=True)
    e.ledger.write_text("".join(f"old{i}\n" for i in range(1005)))
    e.run("append", "--source", str(src), "base", "start")
    lines = e.lines()
    assert len(lines) == 1000
    assert lines[0] == "old6"
    assert lines[-1].split("\t")[3] == "start"


@pytest.mark.parametrize("args", [
    ["append", "base", "start"],
    ["append", "--source", "X", "nobody", "start"],
    ["append", "--source", "X", "base", "exploded"],
    ["append", "--source", "X", "base"],
    ["nonsense"],
])
def test_a_usage_error_is_exit_2_and_writes_nothing(e, args):
    args = [str(e.tmp) if a == "X" else a for a in args]
    out = e.run(*args)
    assert out.returncode == 2, out.stderr
    assert e.lines() == []


def test_a_write_problem_is_loud_and_exit_0(e):
    src = e.repo()
    e.state.write_text("a file where the state directory must go\n")
    out = e.run("append", "--source", str(src), "base", "start")
    assert out.returncode == 0
    assert out.stderr.count("\n") == 1
    assert "apply-status" in out.stderr and "ledger" in out.stderr


def test_a_directory_in_place_of_the_ledger_is_loud_and_exit_0(e):
    src = e.repo()
    e.ledger.mkdir(parents=True)
    out = e.run("append", "--source", str(src), "base", "start")
    assert out.returncode == 0
    assert "apply-status" in out.stderr


# --- status ----------------------------------------------------------------------------------------

def status(e, *args, **extra):
    out = e.run("--json", *args, **extra)
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout)


def test_status_with_no_ledger_says_no_apply_was_recorded(e):
    out = e.run()
    assert out.returncode == 0
    assert "no apply recorded" in out.stdout
    data = status(e)
    assert data["instances"]["base"]["state"] == "none"
    assert data["instances"]["overlay"]["state"] == "none"


def test_status_shows_a_deployed_apply_and_its_post_result(e):
    src = e.repo()
    h = e.head(src)
    e.plant(("2026-11-15T10:00:00Z", "base", "start", h, ""),
            ("2026-11-15T10:01:00Z", "base", "deployed", h, ""),
            ("2026-11-15T10:09:00Z", "base", "post-pass", h, "log: /x"))
    b = status(e)["instances"]["base"]
    assert b["state"] == "deployed"
    assert b["deployed_head"] == h
    assert b["source_ahead"] is False
    assert b["post"]["event"] == "post-pass"
    assert [ev["event"] for ev in b["events"]] == ["start", "deployed", "post-pass"]
    assert status(e)["instances"]["overlay"]["state"] == "none"
    human = e.run().stdout
    assert "base" in human and "deployed" in human and "post-pass" in human


def test_status_says_when_the_source_is_ahead_of_what_is_deployed(e):
    src = e.repo()
    h = e.head(src)
    e.plant(("2026-11-15T10:00:00Z", "base", "start", h, ""),
            ("2026-11-15T10:01:00Z", "base", "deployed", h, ""))
    e.commit(src, "two")
    b = status(e)["instances"]["base"]
    assert b["source_ahead"] is True
    assert b["source_head"] == e.head(src)
    assert "ahead of what is deployed" in e.run().stdout


def test_status_shows_a_refusal_with_its_detail(e):
    src = e.repo()
    e.plant(("2026-11-15T10:00:00Z", "base", "start", e.head(src), ""),
            ("2026-11-15T10:00:30Z", "base", "refused", e.head(src), "suites: test-x.sh; report: /r"))
    b = status(e)["instances"]["base"]
    assert b["state"] == "refused"
    assert "test-x.sh" in e.run().stdout


# --- a post-apply run's start ----------------------------------------------------------------------

T0 = 1_800_000_000


def planted_post(e, *tail):
    src = e.repo()
    h = e.head(src)
    e.plant((iso(T0), "base", "start", h, ""), (iso(T0 + 30), "base", "deployed", h, ""),
            (iso(T0 + 60), "base", "post-start", h, ""), *[(iso(t), "base", ev, h, d) for t, ev, d in tail])


def test_append_accepts_a_post_start_event(e):
    src = e.repo()
    out = e.run("append", "--source", str(src), "base", "post-start")
    assert (out.returncode, out.stderr) == (0, "")
    assert e.lines()[0].split("\t")[3] == "post-start"


def test_a_post_apply_run_in_progress_is_shown_with_its_age(e):
    planted_post(e)
    now = T0 + 60 + 7 * 60 + 20
    b = status(e, APPLY_STATUS_NOW=str(now))["instances"]["base"]
    assert b["post_run"] == {"state": "running", "since": iso(T0 + 60), "age_seconds": 440, "minutes": 7}
    human = e.run(APPLY_STATUS_NOW=str(now)).stdout
    assert "post-apply running since %s (7 min)" % iso(T0 + 60) in human


def test_a_finished_post_apply_replaces_the_running_line(e):
    planted_post(e, (T0 + 600, "post-pass", "log: /x"))
    b = status(e, APPLY_STATUS_NOW=str(T0 + 900))["instances"]["base"]
    assert b["post_run"] is None
    assert b["post"]["event"] == "post-pass"
    human = e.run(APPLY_STATUS_NOW=str(T0 + 900)).stdout
    assert "post-apply running" not in human and "did not finish" not in human
    assert "latest post result: post-pass" in human


def test_a_failed_post_apply_is_not_running_either(e):
    planted_post(e, (T0 + 600, "post-FAIL", "suites: test-x.sh; log: /x"))
    assert status(e, APPLY_STATUS_NOW=str(T0 + 900))["instances"]["base"]["post_run"] is None


def test_a_post_apply_overtaken_by_a_new_apply_did_not_finish(e):
    planted_post(e, (T0 + 3600, "start", ""))
    now = T0 + 3700
    b = status(e, APPLY_STATUS_NOW=str(now))["instances"]["base"]
    assert b["post_run"]["state"] == "unfinished"
    assert b["post_run"]["since"] == iso(T0 + 60)
    human = e.run(APPLY_STATUS_NOW=str(now)).stdout
    assert "post-apply did not finish (started %s)" % iso(T0 + 60) in human
    assert "post-apply running" not in human


def test_a_second_post_apply_run_is_the_one_that_counts(e):
    planted_post(e, (T0 + 100, "post-start", ""), (T0 + 400, "post-pass", "log: /x"))
    assert status(e, APPLY_STATUS_NOW=str(T0 + 500))["instances"]["base"]["post_run"] is None


def test_a_ledger_without_post_start_renders_as_before(e):
    src = e.repo()
    h = e.head(src)
    e.plant((iso(T0), "base", "start", h, ""), (iso(T0 + 30), "base", "deployed", h, ""))
    b = status(e, APPLY_STATUS_NOW=str(T0 + 5000))["instances"]["base"]
    assert b["post_run"] is None
    human = e.run(APPLY_STATUS_NOW=str(T0 + 5000)).stdout
    assert "post-apply" not in human


def test_wait_tolerates_a_post_start_line(e):
    src = e.repo()
    h = e.head(src)
    e.plant(("2026-11-15T10:00:00Z", "base", "start", h, ""),
            ("2026-11-15T10:00:30Z", "base", "deployed", h, ""),
            ("2026-11-15T10:00:31Z", "base", "post-start", h, ""))
    out = e.run("wait", "--since", "2026-11-15T09:00:00Z", "--instances", "base", "--timeout", "5s",
                "--interval", "1s")
    assert out.returncode == 0, out.stdout + out.stderr
    assert "post-start" in out.stdout


def test_a_start_with_no_end_is_incomplete_with_its_age(e):
    src = e.repo()
    t0 = 1_800_000_000
    e.plant((iso(t0), "base", "start", e.head(src), ""))
    b = status(e, APPLY_STATUS_NOW=str(t0 + 125))["instances"]["base"]
    assert b["state"] == "incomplete"
    assert b["age_seconds"] == 125
    assert "incomplete" in e.run(APPLY_STATUS_NOW=str(t0 + 125)).stdout


def test_status_reads_only_the_events_since_the_last_start(e):
    src = e.repo()
    h = e.head(src)
    e.plant(("2026-11-15T09:00:00Z", "base", "start", h, ""),
            ("2026-11-15T09:00:30Z", "base", "refused", h, "old"),
            ("2026-11-15T10:00:00Z", "base", "start", h, ""),
            ("2026-11-15T10:01:00Z", "base", "deployed", h, ""))
    b = status(e)["instances"]["base"]
    assert b["state"] == "deployed"
    assert [ev["event"] for ev in b["events"]] == ["start", "deployed"]


def test_status_with_the_explicit_subcommand_matches_the_bare_one(e):
    assert e.run("status").stdout == e.run().stdout


# --- wait ------------------------------------------------------------------------------------------

def test_wait_exits_0_once_both_instances_deployed_after_since(e):
    src = e.repo()
    h = e.head(src)
    now = int(time.time())
    e.plant((iso(now - 10), "base", "start", h, ""), (iso(now - 9), "base", "deployed", h, ""),
            (iso(now - 8), "overlay", "start", h, ""), (iso(now - 7), "overlay", "deployed", h, ""))
    out = e.run("wait", "--since", str(now - 60), "--timeout", "10s", "--interval", "1s")
    assert out.returncode == 0, out.stdout
    assert "base" in out.stdout and "overlay" in out.stdout


def test_wait_accepts_an_iso_since(e):
    src = e.repo()
    h = e.head(src)
    now = int(time.time())
    e.plant((iso(now), "base", "deployed", h, ""), (iso(now), "overlay", "deployed", h, ""))
    out = e.run("wait", "--since", iso(now - 5), "--timeout", "10s", "--interval", "1s")
    assert out.returncode == 0, out.stdout


def test_wait_ignores_events_before_since(e):
    src = e.repo()
    h = e.head(src)
    now = int(time.time())
    e.plant((iso(now - 500), "base", "deployed", h, ""), (iso(now - 500), "overlay", "deployed", h, ""),
            (iso(now - 500), "base", "refused", h, "old"))
    out = e.run("wait", "--since", str(now - 10), "--timeout", "2s", "--interval", "1s")
    assert out.returncode == 3, out.stdout


def test_wait_exits_1_at_a_refusal(e):
    src = e.repo()
    now = int(time.time())
    e.plant((iso(now), "base", "start", e.head(src), ""),
            (iso(now), "base", "refused", e.head(src), "suites: test-x.sh; report: /r"))
    out = e.run("wait", "--since", str(now - 5), "--timeout", "10s", "--interval", "1s")
    assert out.returncode == 1
    assert "refused" in out.stdout and "test-x.sh" in out.stdout


def test_wait_times_out_with_exit_3_and_says_what_it_saw(e):
    src = e.repo()
    now = int(time.time())
    e.plant((iso(now), "base", "deployed", e.head(src), ""))
    out = e.run("wait", "--since", str(now - 5), "--timeout", "2s", "--interval", "1s")
    assert out.returncode == 3
    assert "timed out" in out.stdout
    assert "overlay" in out.stdout


def test_wait_prints_a_poll_line_every_interval(e):
    now = int(time.time())
    out = e.run("wait", "--since", str(now), "--timeout", "3s", "--interval", "1s")
    assert out.returncode == 3
    polls = [ln for ln in out.stdout.splitlines() if "waiting" in ln]
    assert len(polls) >= 2, out.stdout


def test_wait_prints_events_that_land_while_it_runs(e):
    src = e.repo()
    now = int(time.time())
    proc = subprocess.Popen([sys.executable, str(TOOL), "wait", "--since", str(now - 5),
                             "--timeout", "30s", "--interval", "1s"], env=e.env(),
                            stdout=subprocess.PIPE, text=True, stdin=subprocess.DEVNULL)
    try:
        first = proc.stdout.readline()
        assert first, "the wait printed nothing at once"
        for inst in ("base", "overlay"):
            e.run("append", "--source", str(src), inst, "deployed")
        out = first + proc.communicate(timeout=30)[0]
    finally:
        proc.kill()
    assert proc.returncode == 0, out
    assert out.count("deployed") >= 2


@pytest.mark.parametrize("args", [
    ["wait"],
    ["wait", "--since", "yesterday-ish"],
    ["wait", "--since", "0", "--timeout", "soon"],
])
def test_wait_usage_errors_are_exit_2(e, args):
    assert e.run(*args).returncode == 2


# --- review fixes -----------------------------------------------------------------------------------

def test_a_refusal_that_a_later_start_superseded_does_not_fail_the_wait(e):
    h = "abc1234"
    now = int(time.time())
    e.plant((iso(now - 50), "base", "start", h, ""), (iso(now - 49), "base", "refused", h, "x"),
            (iso(now - 20), "base", "start", h, ""), (iso(now - 19), "base", "deployed", h, ""),
            (iso(now - 18), "overlay", "start", h, ""), (iso(now - 17), "overlay", "deployed", h, ""))
    out = e.run("wait", "--since", str(now - 60), "--timeout", "10s", "--interval", "1s")
    assert out.returncode == 0, out.stdout


def test_a_refusal_after_the_latest_start_still_fails_the_wait(e):
    h = "abc1234"
    now = int(time.time())
    e.plant((iso(now - 20), "base", "start", h, ""), (iso(now - 19), "base", "deployed", h, ""),
            (iso(now - 10), "base", "start", h, ""), (iso(now - 9), "base", "refused", h, "x"))
    out = e.run("wait", "--since", str(now - 60), "--timeout", "10s", "--interval", "1s")
    assert out.returncode == 1, out.stdout


def test_a_zoneless_since_is_refused_naming_the_fix(e):
    out = e.run("wait", "--since", "2026-11-15T10:09:00", "--timeout", "1s")
    assert out.returncode == 2
    assert "date -u +%Y-%m-%dT%H:%M:%SZ" in out.stderr and "epoch" in out.stderr


@pytest.mark.parametrize("since", ["2026-11-15 10:09:00Z", "2026-11-15T10:09Z", "2026-11-15T10:09:00+0000",
                                   "2026-11-15T10:09:00.5Z", "2026-13-15T10:09:00Z", "yesterday"])
def test_only_z_an_hh_mm_offset_or_epoch_is_a_time(e, since):
    ok = since in ("2026-11-15T10:09Z", "2026-11-15T10:09:00.5Z", "2026-11-15 10:09:00Z")
    out = e.run("wait", "--since", since, "--timeout", "1s", "--interval", "1s")
    assert (out.returncode == 3) if ok else (out.returncode == 2), (since, out.stdout, out.stderr)


def test_an_offset_since_means_the_same_instant_as_z(e):
    h = "abc1234"
    now = int(time.time())
    e.plant((iso(now), "base", "deployed", h, ""), (iso(now), "overlay", "deployed", h, ""))
    earlier = time.strftime("%Y-%m-%dT%H:%M:%S-05:00", time.gmtime(now - 5 - 5 * 3600))
    later = time.strftime("%Y-%m-%dT%H:%M:%S-05:00", time.gmtime(now + 100 - 5 * 3600))
    assert e.run("wait", "--since", earlier, "--timeout", "5s", "--interval", "1s").returncode == 0
    assert e.run("wait", "--since", later, "--timeout", "2s", "--interval", "1s").returncode == 3


def test_wait_for_a_base_only_machine(e):
    h = "abc1234"
    now = int(time.time())
    e.plant((iso(now), "base", "deployed", h, ""))
    out = e.run("wait", "--since", str(now - 5), "--instances", "base", "--timeout", "5s", "--interval", "1s")
    assert out.returncode == 0, out.stdout
    assert e.run("wait", "--since", str(now - 5), "--timeout", "2s", "--interval", "1s").returncode == 3


def test_wait_rejects_an_unknown_instance(e):
    assert e.run("wait", "--since", "0", "--instances", "base,nobody").returncode == 2


def test_the_ledger_survives_concurrent_appends_and_trims(e):
    src = e.repo()
    e.ledger.parent.mkdir(parents=True)
    e.ledger.write_text("".join(f"old{i}\n" for i in range(990)))
    procs = [subprocess.Popen(
        ["sh", "-c", f'for i in $(seq 25); do {sys.executable} {TOOL} append --source {src} base start; done'],
        env=e.env(), stdin=subprocess.DEVNULL) for _ in range(4)]
    for p in procs:
        assert p.wait(timeout=120) == 0
    lines = e.lines()
    assert len(lines) == 1000
    assert sum(1 for ln in lines if ln.split("\t")[3:4] == ["start"]) == 100


@pytest.mark.parametrize("args,event", [
    (None, "by-hand"),
    ("chezmoi apply", "start"),
    ("chezmoi --config /x/c.toml --source /x/s apply -v", "start"),
    ("chezmoi apply --dry-run", "dry-run"),
    ("chezmoi apply -n", "dry-run"),
    ("chezmoi apply -vn", "dry-run"),
    ("chezmoi apply --dry-run=true", "dry-run"),
    ("chezmoi apply --dry-run=false", "start"),
    ("chezmoi apply --exclude=externals", "start"),
    ("chezmoi apply -- -n", "targeted"),
    # A target on the command line: only those files are applied, so the line is not a full apply.
    # Shapes measured from chezmoi 2.74's CHEZMOI_ARGS, 2026-11-17.
    ("chezmoi apply --no-tty /home/u/.claude/settings.json", "targeted"),
    ("chezmoi -S /s -D /d apply --force -- /d/.b", "targeted"),
    ("chezmoi apply -n /home/u/.zshrc", "dry-run"),
    # Option values are not targets, whether before or after the verb, long or short, joined or not.
    ("chezmoi --config /x/c.toml --source /x/s --persistent-state /x/p --cache /x/k apply", "start"),
    ("chezmoi apply --config-format toml", "start"),
    ("chezmoi apply -x scripts", "start"),
    ("chezmoi apply -vx scripts", "start"),
    ("chezmoi apply -Sdir", "start"),
    ("chezmoi apply --color auto --mode file -W /w -o /o", "start"),
])
def test_a_hook_append_records_what_chezmoi_context_says(e, args, event):
    src = e.repo()
    extra = {} if args is None else {"CHEZMOI": "1", "CHEZMOI_ARGS": args}
    out = e.run("append", "--source", str(src), "--hook", "base", "start", "why", **extra)
    assert out.returncode == 0, out.stderr
    cols = e.lines()[0].split("\t")
    assert cols[3] == event
    assert cols[6] == ("why" if event == "start" else "start: why")


def test_a_targeted_apply_inside_an_apply_does_not_overtake_its_post_run(e):
    # The private layer's onchange settings merge runs `chezmoi apply <one file>` of the base while
    # the overlay applies, which fires the base's hooks. Measured on both machines 2026-11-17: its
    # `start` landed after the base's `post-start`, and status said the post-apply run "did not
    # finish" while it was still running.
    src = e.repo()
    full = {"CHEZMOI": "1", "CHEZMOI_ARGS": "chezmoi apply"}
    nested = {"CHEZMOI": "1", "CHEZMOI_ARGS": "chezmoi apply --no-tty /home/u/.claude/settings.json"}
    for event, env in (("start", full), ("deployed", full), ("post-start", {}), ("start", nested),
                       ("deployed", nested)):
        args = ["append", "--source", str(src)] + (["--hook"] if env else []) + ["base", event]
        assert e.run(*args, **env).returncode == 0
    b = status(e)["instances"]["base"]
    assert b["post_run"] is not None and b["post_run"]["state"] == "running", b
    assert "did not finish" not in e.run().stdout


def test_without_the_hook_flag_the_event_is_recorded_as_given(e):
    src = e.repo()
    e.run("append", "--source", str(src), "base", "start", CHEZMOI="1", CHEZMOI_ARGS="chezmoi apply -n")
    assert e.lines()[0].split("\t")[3] == "start"


def test_a_preview_or_hand_run_is_invisible_to_status_and_wait(e):
    h = "abc1234"
    now = int(time.time())
    e.plant((iso(now), "base", "dry-run", h, "start: x"), (iso(now), "base", "dry-run", h, "deployed: x"),
            (iso(now), "overlay", "by-hand", h, "deployed: x"))
    assert status(e)["instances"]["base"]["state"] == "none"
    assert status(e)["instances"]["overlay"]["state"] == "none"
    out = e.run("wait", "--since", str(now - 5), "--timeout", "2s", "--interval", "1s")
    assert out.returncode == 3, out.stdout
    assert "dry-run" not in out.stdout and "by-hand" not in out.stdout, out.stdout


def test_status_shows_a_deployed_head_even_with_no_start(e):
    src = e.repo()
    e.plant(("2026-11-15T10:01:00Z", "base", "deployed", e.head(src), ""))
    b = status(e)["instances"]["base"]
    assert b["state"] == "deployed" and b["deployed_head"] == e.head(src)
    human = e.run().stdout
    assert "no apply recorded" not in human.split("overlay")[0]
    assert e.head(src) in human and "2026-11-15T10:01:00Z" in human


def test_head_subcommand_prints_the_head_the_ledger_would_record(e):
    src = e.repo()
    assert e.run("head", str(src)).stdout.strip() == e.head(src)
    (src / "f").write_text("changed\n")
    assert e.run("head", str(src)).stdout.strip() == e.head(src) + "-dirty"
    assert e.run("head", str(e.tmp / "nowhere")).stdout.strip() == "unknown"


def test_append_head_overrides_the_head_it_would_read(e):
    src = e.repo()
    e.run("append", "--source", str(src), "--head", "feedbee", "base", "post-pass")
    assert e.lines()[0].split("\t")[4] == "feedbee"


# --- agents (macOS only) -----------------------------------------------------------------------------

AGENTS_OK = {"domain": "gui/501", "dir": "/d", "problems": 0, "agents": [
    {"label": "com.x.a", "file": "/d/a.plist", "state": "loaded", "loaded_path": "/d/a.plist"}]}
AGENTS_BAD = {"domain": "gui/501", "dir": "/d", "problems": 1, "agents": [
    {"label": "com.x.a", "file": "/d/a.plist", "state": "loaded", "loaded_path": "/d/a.plist"},
    {"label": "com.x.b", "file": "/d/b.plist", "state": "NOT-LOADED", "loaded_path": None}]}


def fake_agents(e, doc, rc=0, stderr=""):
    e.tool("launchagent-status", "#!/bin/sh\ncat <<'EOF_JSON'\n%s\nEOF_JSON\necho %r >&2\nexit %d\n"
           % (json.dumps(doc), stderr, rc))


def test_on_linux_the_status_view_has_no_agents_line_and_no_key(e):
    fake_agents(e, AGENTS_BAD, rc=1)
    out = e.run()
    assert out.returncode == 0
    assert "agents" not in out.stdout
    assert "agents" not in json.loads(e.run("--json").stdout)


def test_on_a_mac_the_status_view_ends_with_the_agents_line(e):
    fake_agents(e, AGENTS_BAD, rc=1)
    out = e.run(FAKE_UNAME="Darwin")
    assert out.returncode == 0
    last = out.stdout.splitlines()[-1]
    assert last.startswith("agents   ") and "com.x.b (NOT-LOADED)" in last
    assert "com.x.a" not in last


def test_on_a_mac_with_no_problem_the_agents_line_says_so(e):
    fake_agents(e, AGENTS_OK)
    last = e.run(FAKE_UNAME="Darwin").stdout.splitlines()[-1]
    assert last == "agents   1 LaunchAgents, none deployed without being loaded"


def test_on_a_mac_json_carries_the_tools_object(e):
    fake_agents(e, AGENTS_BAD, rc=1)
    out = e.run("--json", FAKE_UNAME="Darwin")
    assert out.returncode == 0
    assert json.loads(out.stdout)["agents"] == AGENTS_BAD


def test_a_missing_tool_is_not_checked(e):
    out = e.run(FAKE_UNAME="Darwin", PATH=str(e.fakebin) + os.pathsep + "/usr/bin:/bin")
    assert out.returncode == 0
    assert out.stdout.splitlines()[-1].startswith("agents   not checked: ")
    agents = json.loads(e.run("--json", FAKE_UNAME="Darwin",
                              PATH=str(e.fakebin) + os.pathsep + "/usr/bin:/bin").stdout)["agents"]
    assert agents["checked"] is False and agents["reason"]


def test_a_tool_that_cannot_tell_is_not_checked_with_its_reason(e):
    e.tool("launchagent-status", "#!/bin/sh\necho 'launchagent-status: the gui domain cannot be read' >&2\nexit 3\n")
    out = e.run(FAKE_UNAME="Darwin")
    assert out.returncode == 0
    assert out.stdout.splitlines()[-1] == "agents   not checked: launchagent-status: the gui domain cannot be read"
    assert json.loads(e.run("--json", FAKE_UNAME="Darwin").stdout)["agents"] == {
        "checked": False, "reason": "launchagent-status: the gui domain cannot be read"}


def test_a_tool_that_hangs_is_not_checked_after_its_limit(e):
    e.tool("launchagent-status", "#!/bin/sh\nexec sleep 60\n")
    # The tool's limit is 15 s; the test waits it out once.
    out = e.run(FAKE_UNAME="Darwin", timeout=45)
    assert out.returncode == 0
    assert "not checked: launchagent-status timed out" in out.stdout.splitlines()[-1]


def test_a_tool_that_prints_no_json_is_not_checked(e):
    e.tool("launchagent-status", "#!/bin/sh\necho nonsense\nexit 0\n")
    assert "not checked" in e.run(FAKE_UNAME="Darwin").stdout.splitlines()[-1]


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", *sys.argv[1:]]))
