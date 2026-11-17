#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for claude-usage-report's per-session view (--sessions).

Run: sh tests/run-all.sh --only test-claude-usage-report-sessions.py
 or: uv run --script tests/test-claude-usage-report-sessions.py [-k <pattern>]

What is held: a streamed message, written as several records with one message.id and cumulative
usage, counts as one request at each field's maximum, so a session's total input is exact (summing
the records instead overcounts, and the dedupe test is the one that catches it); ctx@1, @10, @50 and
the last are the prompt sizes of those requests; subagents are counted apart; the seat name is the
custom title, else the agent name; `ended` is parked, live, compacted, exited or open, the last when
the session's process is in a pid namespace this one cannot see; the window and --seat filter whole
sessions; and no transcript text reaches the output.

Everything runs against a scratch tree (CLAUDE_PROJECTS_DIR, CLAUDE_SESSIONS_DIR), with the clock
fixed by CLAUDE_USAGE_NOW and the pid namespace by CLAUDE_USAGE_PID_NS.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_claude-usage-report"
NOW = 1792238400  # 2026-10-17T12:00:00Z
NS = "pid:[4242]"
SECRET = "SECRETPLANT-do-not-print"


def rec(path, mid, ts, inp=0, cr=0, cc=0, out=0, **extra):
    r = {"type": "assistant", "timestamp": ts, "cwd": "/w/proj",
         "message": {"id": mid, "model": "claude-test",
                     "content": [{"type": "text", "text": SECRET}],
                     "usage": {"input_tokens": inp, "cache_read_input_tokens": cr,
                               "cache_creation_input_tokens": cc, "output_tokens": out}}}
    for k, v in extra.items():
        if k == "content":
            r["message"]["content"] = v
        else:
            r[k] = v
    line(path, r)


def line(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as fh:
        fh.write((obj if isinstance(obj, str) else json.dumps(obj)) + "\n")


def own_start():
    with open("/proc/self/stat") as fh:
        return fh.read().rsplit(")", 1)[1].split()[19]


@pytest.fixture
def tree(tmp_path):
    proj = tmp_path / "projects" / "-w-proj"
    # seat-a: three requests, m1 streamed in three records whose output peaks in the MIDDLE one.
    a = proj / "aaaaaaaa-1.jsonl"
    line(a, {"type": "custom-title", "customTitle": "seat-a", "sessionId": "aaaaaaaa-1"})
    line(a, {"type": "agent-name", "agentName": "ignored-when-titled"})
    rec(a, "m1", "2026-10-16T10:00:00Z", inp=1, cr=0, cc=100, out=5)
    rec(a, "m1", "2026-10-16T10:00:01Z", inp=1, cr=0, cc=100, out=40)
    rec(a, "m1", "2026-10-16T10:00:02Z", inp=1, cr=0, cc=100, out=30)
    rec(a, "m2", "2026-10-16T10:01:00Z", inp=2, cr=100, cc=50, out=10)
    rec(a, "m3", "2026-10-16T10:02:00Z", inp=3, cr=150, cc=20, out=7,
        content=[{"type": "tool_use", "name": "Bash",
                  "input": {"command": "fleet-canonicals stage seat-a /some/handoff.md"}}])
    rec(a, "side1", "2026-10-16T10:01:30Z", inp=999, cr=999, cc=999, out=999,
        isSidechain=True)  # an older build's inline subagent turn: not the main context
    rec(a, "syn", "2026-10-16T10:03:00Z", model="<synthetic>")
    line(a, "this is not json {{{")
    line(a, {"type": "user", "message": {"content": SECRET}})
    sub = proj / "aaaaaaaa-1" / "subagents" / "agent-x.jsonl"
    rec(sub, "s1", "2026-10-16T10:01:10Z", inp=10, cr=20, cc=30, out=1)
    rec(sub, "s1", "2026-10-16T10:01:11Z", inp=10, cr=20, cc=30, out=2)
    # seat-b: 60 requests, request i (1-based) sent i*1000 tokens; one compaction; not parked.
    b = proj / "bbbbbbbb-2.jsonl"
    line(b, {"type": "custom-title", "customTitle": "seat-b"})
    for i in range(1, 61):
        rec(b, "b%d" % i, "2026-10-16T11:%02d:00Z" % (i - 1), inp=i, cr=i * 1000 - i - 10, cc=10, out=1)
        if i == 30:
            line(b, {"type": "system", "subtype": "compact_boundary", "content": SECRET})
    # cccc: agent name only, a live process record.
    c = proj / "cccccccc-3.jsonl"
    line(c, {"type": "agent-name", "agentName": "seat-c"})
    rec(c, "c1", "2026-10-16T12:00:00Z", inp=1, cr=1, cc=1, out=1)
    # dddd: outside the default window (ten days back).
    d = proj / "dddddddd-4.jsonl"
    line(d, {"type": "custom-title", "customTitle": "seat-d"})
    rec(d, "d1", "2026-10-07T12:00:00Z", inp=1, cr=1, cc=1, out=1)
    for p in (a, b, c, d):
        os.utime(p, (NOW, NOW))
    sessions = tmp_path / "sessions"
    sessions.mkdir()
    env = dict(os.environ, CLAUDE_PROJECTS_DIR=str(tmp_path / "projects"),
               CLAUDE_SESSIONS_DIR=str(sessions), CLAUDE_USAGE_NOW=str(NOW),
               CLAUDE_USAGE_PID_NS=NS, TZ="UTC", HOME=str(tmp_path / "home"))
    return {"env": env, "sessions": sessions}


def live_record(tree, sid, ns=NS, start=None):
    d = {"pid": os.getpid(), "sessionId": sid, "pidDomain": "linux:boot:" + ns}
    if start is not None:
        d["procStart"] = start
    (tree["sessions"] / ("%s.json" % sid)).write_text(json.dumps(d))


def run(tree, *args):
    return subprocess.run([sys.executable, str(TOOL), *args], env=tree["env"],
                          capture_output=True, text=True)


def rows(tree, *args):
    p = run(tree, "--sessions", "--json", *args)
    assert p.returncode == 0, p.stderr
    return {r["seat"]: r for r in json.loads(p.stdout)["sessions"]}


def test_streamed_message_counts_once_at_each_fields_maximum(tree):
    a = rows(tree)["seat-a"]
    assert a["requests"] == 3
    # m1 101 + m2 152 + m3 173; summing m1's three records would give 527.
    assert a["total_input"] == 426
    assert a["output"] == 40 + 10 + 7
    assert a["cache_write"] == 170
    assert a["context"] == {"first": 101, "at_10": None, "at_50": None, "last": 173}
    assert a["avg_context"] == 142


def test_context_at_requests_1_10_50_and_last(tree):
    b = rows(tree)["seat-b"]
    assert b["requests"] == 60
    assert b["context"] == {"first": 1000, "at_10": 10000, "at_50": 50000, "last": 60000}
    assert b["total_input"] == 1000 * sum(range(1, 61))
    assert b["avg_context"] == 30500


def test_subagents_counted_apart_from_the_main_context(tree):
    a = rows(tree)["seat-a"]
    assert (a["subagent_requests"], a["subagent_total_input"]) == (1, 60)


def test_seat_name_is_the_title_else_the_agent_name(tree):
    r = rows(tree)
    assert set(r) == {"seat-a", "seat-b", "seat-c"}


def bash(cmd):
    return [{"type": "tool_use", "name": "Bash", "input": {"command": cmd}}]


def one_seat(tree, sid, seat, calls, last="2026-10-16T14:00:00Z"):
    """A session titled `seat`: one request per (timestamp, Bash command or None), then a last
    request at `last` with no tool call."""
    f = Path(tree["env"]["CLAUDE_PROJECTS_DIR"]) / "-w-proj" / ("%s.jsonl" % sid)
    line(f, {"type": "custom-title", "customTitle": seat})
    for i, (ts, cmd) in enumerate(calls):
        rec(f, "%s-%d" % (sid, i), ts, inp=1, cr=1, cc=1, out=1, **({"content": bash(cmd)} if cmd else {}))
    rec(f, "%s-last" % sid, last, inp=1, cr=1, cc=1, out=1)
    os.utime(f, (NOW, NOW))


# A seat parks by staging its handoff, by committing its own `*-<seat>-park.md`, or by recording
# its pointer (director-canonical commits its handoff directly, 2026-11-17), in the session's last
# 30 minutes. Committing ANOTHER seat's park file is placing it, and a park long before the end was
# followed by more work, so neither is a park.

def test_parked_by_committing_its_own_park_handoff(tree):
    one_seat(tree, "eeeeeeee-5", "seat-e", [("2026-10-16T13:50:00Z",
             "f=handoffs/2026-10-16-1350-seat-e-park.md && git add $f && git commit -q -m park")])
    assert rows(tree)["seat-e"]["ended"] == "parked"


def test_parked_by_recording_its_pointer(tree):
    one_seat(tree, "ffffffff-6", "seat-f", [("2026-10-16T13:55:00Z",
             "fleet-canonicals handoff seat-f --set /h/2026-10-16-1355-seat-f-checkpoint.md")])
    assert rows(tree)["seat-f"]["ended"] == "parked"


def test_committing_another_seats_park_handoff_is_not_a_park(tree):
    one_seat(tree, "99999999-7", "seat-g", [
        ("2026-10-16T13:50:00Z", "p=handoffs/2026-10-16-1350-seat-x-park.md; git add $p && git commit -q -m place"),
        ("2026-10-16T13:51:00Z", "fleet-canonicals stage seat-x /h/x.md"),
        ("2026-10-16T13:52:00Z", "fleet-canonicals handoff seat-x --set /h/x.md")])
    assert rows(tree)["seat-g"]["ended"] == "exited"


def test_a_park_long_before_the_end_is_not_a_park(tree):
    one_seat(tree, "88888888-8", "seat-h", [
        ("2026-10-16T12:00:00Z", "fleet-canonicals stage seat-h /h/park.md"),
        ("2026-10-16T12:01:00Z", "git add handoffs/2026-10-16-1201-seat-h-park.md && git commit -m p")])
    assert rows(tree)["seat-h"]["ended"] == "exited"


def test_ended_parked_compacted_exited(tree):
    r = rows(tree)
    assert (r["seat-a"]["ended"], r["seat-b"]["ended"], r["seat-c"]["ended"]) == ("parked", "compacted", "exited")
    assert r["seat-b"]["compactions"] == 1


def test_ended_live_when_its_process_runs(tree):
    live_record(tree, "cccccccc-3")
    assert rows(tree)["seat-c"]["ended"] == "live"


def test_ended_open_when_the_process_is_in_another_namespace(tree):
    live_record(tree, "cccccccc-3", ns="pid:[9999]")
    assert rows(tree)["seat-c"]["ended"] == "open"


@pytest.mark.skipif(not Path("/proc/self/stat").exists(), reason="start time needs /proc")
def test_a_reused_pid_is_not_live(tree):
    live_record(tree, "cccccccc-3", start="1")
    assert rows(tree)["seat-c"]["ended"] == "exited"
    live_record(tree, "cccccccc-3", start=own_start())
    assert rows(tree)["seat-c"]["ended"] == "live"


def test_window_filters_whole_sessions(tree):
    assert "seat-d" not in rows(tree)
    assert "seat-d" in rows(tree, "--days", "30")
    assert set(rows(tree, "--days", "30", "--until", "2026-10-15")) == {"seat-d"}


def test_until_bounds_the_default_report_too(tree):
    p = run(tree, "--json", "--days", "30", "--until", "2026-10-15")
    assert json.loads(p.stdout)["days"].keys() == {"2026-10-07"}


def test_seat_filter_is_a_repeatable_pattern(tree):
    assert set(rows(tree, "--seat", "seat-[ab]")) == {"seat-a", "seat-b"}
    assert set(rows(tree, "--seat", "seat-a", "--seat", "seat-c")) == {"seat-a", "seat-c"}


def test_human_output_labels_columns_and_prints_no_text(tree):
    p = run(tree, "--sessions")
    assert p.returncode == 0
    for col in ("ctx@1", "ctx@10", "ctx@50", "ctx@end", "avg ctx", "total input", "cache write", "ended"):
        assert col in p.stdout
    assert "parked" in p.stdout and "60" in p.stdout
    everything = p.stdout + run(tree, "--sessions", "--json", "--days", "30").stdout
    assert SECRET not in everything


def test_help_defines_the_columns(tree):
    h = " ".join(run(tree, "--help").stdout.split())
    assert "usage proxy" in h and "ctx@1" in h and "open" in h


def test_seat_without_sessions_is_refused(tree):
    assert run(tree, "--seat", "x").returncode == 2
    assert run(tree, "--sessions", "--until", "nope").returncode == 2


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", *sys.argv[1:]]))
