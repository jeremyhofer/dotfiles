#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for claude-usage-override, the one switch and the one reader for standing down every
usage-based throttle for a bounded time.

Run: npx nx run suite-claude-usage-override:test
 or: uv run --script tests/test-claude-usage-override.py [-k <pattern>]

What is held: `status` is active (exit 0) only for a well-formed file whose `until` is still ahead;
no file and an expired one are not active (exit 1) and say which; anything malformed is not active
(exit 3) and says why. `set` writes that file and refuses an expiry in the past, one without a zone,
an empty reason and an expiry more than 21 days ahead. `clear` removes it. The reader holds the
21-day bound too, so a hand-edited file cannot stretch an override past it.

Everything runs against a scratch file (CLAUDE_USAGE_OVERRIDE_FILE), with the clock fixed by
CLAUDE_USAGE_OVERRIDE_NOW where a time is asserted.
"""
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_claude-usage-override"
NOW = 1_800_000_000  # 2027-01-15T08:00:00Z, a fixed clock
DAY = 86400


def iso(epoch, offset="+00:00"):
    """An ISO time with the given offset for an epoch, built without the tool's own code."""
    from datetime import datetime, timedelta, timezone
    sign = -1 if offset.startswith("-") else 1
    h, m = offset[1:].split(":")
    tz = timezone(sign * timedelta(hours=int(h), minutes=int(m)))
    return datetime.fromtimestamp(epoch, tz=tz).isoformat(timespec="seconds")


class Env:
    def __init__(self, tmp: Path):
        self.file = tmp / "state" / "claude-usage" / "override"
        self.tmp = tmp

    def run(self, *args, now=NOW, env_extra=None):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE_USAGE_OVERRIDE")}
        env.update({"CLAUDE_USAGE_OVERRIDE_FILE": str(self.file), "XDG_STATE_HOME": str(self.tmp / "xdg")})
        if now is not None:
            env["CLAUDE_USAGE_OVERRIDE_NOW"] = str(now)
        env.update(env_extra or {})
        return subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True,
                              env=env, timeout=30)

    def write(self, **fields):
        rec = {"format": 1, "until": iso(NOW + DAY), "reason": "run to the limit",
               "set_by": "tester", "set_at": iso(NOW - 60)}
        rec.update(fields)
        rec = {k: v for k, v in rec.items() if v is not None}
        self.file.parent.mkdir(parents=True, exist_ok=True)
        self.file.write_text(json.dumps(rec))

    def status(self, now=NOW):
        r = self.run("status", "--json", now=now)
        return r.returncode, json.loads(r.stdout)


@pytest.fixture
def e(tmp_path):
    return Env(tmp_path)


# ---- status ----------------------------------------------------------------------------------

def test_no_file_is_not_active(e):
    rc, st = e.status()
    assert rc == 1 and st["state"] == "absent" and st["active"] is False, (rc, st)
    r = e.run("status")
    assert r.returncode == 1 and r.stdout.startswith("inactive: no usage override is set"), r.stdout


def test_a_valid_unexpired_file_is_active(e):
    e.write()
    rc, st = e.status()
    assert rc == 0 and st["state"] == "active" and st["active"] is True, (rc, st)
    assert st["reason"] == "run to the limit" and st["until"] == iso(NOW + DAY), st
    assert st["until_epoch"] == NOW + DAY, "the expiry as epoch seconds, for a shell reader: %s" % st
    r = e.run("status")
    assert r.returncode == 0 and r.stdout.startswith("active: usage throttles stand down until "
                                                     + iso(NOW + DAY)), r.stdout
    assert '"run to the limit"' in r.stdout and "set by tester" in r.stdout and "(in 1d 0h)" in r.stdout, r.stdout


def test_an_expired_file_is_not_active_and_says_when(e):
    e.write()
    rc, st = e.status(now=NOW + DAY)
    assert rc == 1 and st["state"] == "expired" and st["active"] is False, (rc, st)
    assert st["detail"].startswith("inactive: the usage override expired at " + iso(NOW + DAY)), st
    rc, st = e.status(now=NOW + DAY - 1)
    assert rc == 0 and st["state"] == "active", "one second before the expiry it is still active: %s" % st


@pytest.mark.parametrize("label,content,why", [
    ("not-json", "{not json", "not JSON"),
    ("not-object", "[1, 2]", "not a JSON object"),
    ("empty", "", "not JSON"),
])
def test_a_file_that_is_not_an_object_is_invalid(e, label, content, why):
    e.file.parent.mkdir(parents=True, exist_ok=True)
    e.file.write_text(content)
    rc, st = e.status()
    assert rc == 3 and st["state"] == "invalid" and st["active"] is False and why in st["detail"], (label, rc, st)
    assert "not applied" in st["detail"], st


@pytest.mark.parametrize("label,fields,why", [
    ("no-zone", {"until": "2027-01-16T08:00:00"}, "with a zone"),
    ("garbage-until", {"until": "next tuesday"}, "with a zone"),
    ("until-not-a-string", {"until": NOW + DAY}, "with a zone"),
    ("no-until", {"until": None}, "with a zone"),
    ("set-at-no-zone", {"set_at": "2027-01-15T07:59:00"}, "set_at"),
    ("empty-reason", {"reason": "   "}, "reason is missing or empty"),
    ("no-reason", {"reason": None}, "reason is missing or empty"),
    ("no-set-by", {"set_by": None}, "set_by is missing or empty"),
    ("wrong-format", {"format": 2}, "format is 2"),
    ("no-format", {"format": None}, "format is None"),
    ("until-before-set-at", {"until": iso(NOW + 30), "set_at": iso(NOW + 60)}, "is not after set_at"),
    ("set-at-in-the-future", {"set_at": iso(NOW + 3600), "until": iso(NOW + 2 * DAY)}, "in the future"),
    ("beyond-the-bound", {"set_at": iso(NOW - 60), "until": iso(NOW - 60 + 21 * DAY + 1)}, "more than 21 days"),
])
def test_a_malformed_field_is_invalid_never_active(e, label, fields, why):
    e.write(**fields)
    rc, st = e.status()
    assert rc == 3 and st["state"] == "invalid" and st["active"] is False, (label, rc, st)
    assert why in st["detail"], (label, st["detail"])


def test_exactly_the_bound_is_valid(e):
    e.write(set_at=iso(NOW - 60), until=iso(NOW - 60 + 21 * DAY))
    rc, st = e.status()
    assert rc == 0 and st["state"] == "active", st


def test_an_unreadable_file_is_invalid(e):
    if os.geteuid() == 0:
        pytest.skip("root reads a mode-000 file")
    e.write()
    e.file.chmod(0)
    try:
        rc, st = e.status()
    finally:
        e.file.chmod(0o600)
    assert rc == 3 and st["state"] == "invalid" and "cannot be read" in st["detail"], st


def test_a_surprise_inside_the_reader_is_invalid_not_a_crash(e, monkeypatch):
    """The backstop: whatever the checks did not foresee raises inside _read, and read() still
    answers, not active. Loaded in-process, because no file is known to reach it."""
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("cuo_under_test", str(TOOL))
    spec = importlib.util.spec_from_loader("cuo_under_test", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    monkeypatch.setenv("CLAUDE_USAGE_OVERRIDE_FILE", str(e.file))

    def boom():
        raise OverflowError("date value out of range")
    monkeypatch.setattr(mod, "_read", boom)
    st = mod.read()
    assert st["state"] == "invalid" and st["active"] is False and "OverflowError" in st["detail"], st


def test_the_default_path_is_under_the_state_directory(e, tmp_path):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE_USAGE_OVERRIDE")}
    env["XDG_STATE_HOME"] = str(tmp_path / "xdg")
    r = subprocess.run([sys.executable, str(TOOL), "status", "--json"], capture_output=True, text=True, env=env)
    assert json.loads(r.stdout)["path"] == str(tmp_path / "xdg" / "claude-usage" / "override"), r.stdout
    env.pop("XDG_STATE_HOME")
    env["HOME"] = str(tmp_path / "home")
    r = subprocess.run([sys.executable, str(TOOL), "status", "--json"], capture_output=True, text=True, env=env)
    assert json.loads(r.stdout)["path"] == str(tmp_path / "home" / ".local" / "state" / "claude-usage" / "override"), r.stdout


# ---- set ---------------------------------------------------------------------------------------

def test_set_writes_an_active_override(e):
    r = e.run("set", "--until", iso(NOW + 3 * DAY, "-06:00"), "--reason", "  run   to\nthe limit ", "--by", "hub")
    assert r.returncode == 0 and r.stdout.startswith("active: "), (r.returncode, r.stdout, r.stderr)
    rec = json.loads(e.file.read_text())
    assert rec == {"format": 1, "until": iso(NOW + 3 * DAY, "-06:00"), "reason": "run to the limit",
                   "set_by": "hub", "set_at": iso(NOW, "-06:00")}, rec
    assert stat.S_IMODE(e.file.stat().st_mode) == 0o600, oct(e.file.stat().st_mode)
    assert stat.S_IMODE(e.file.parent.stat().st_mode) == 0o700, oct(e.file.parent.stat().st_mode)
    rc, st = e.status()
    assert rc == 0 and st["set_by"] == "hub", st


@pytest.mark.parametrize("given", ["2027-01-16T08:00Z", "2027-01-16T08:00:00+0000", "2027-01-16T02:00-06:00"])
def test_set_takes_z_and_both_offset_spellings(e, given):
    r = e.run("set", "--until", given, "--reason", "x")
    assert r.returncode == 0, (given, r.stderr)
    rc, st = e.status()
    assert rc == 0, st


def test_set_defaults_who_to_the_user_at_the_host(e):
    r = e.run("set", "--until", iso(NOW + DAY), "--reason", "x")
    assert r.returncode == 0, r.stderr
    assert "@" in json.loads(e.file.read_text())["set_by"]


def test_set_says_what_it_replaced(e):
    e.write(reason="first")
    r = e.run("set", "--until", iso(NOW + DAY), "--reason", "second")
    assert r.returncode == 0 and r.stdout.startswith('replaced: active:') and '"first"' in r.stdout, r.stdout


@pytest.mark.parametrize("label,args,why", [
    ("past", ["--until", iso(NOW - 1), "--reason", "x"], "not in the future"),
    ("now", ["--until", iso(NOW), "--reason", "x"], "not in the future"),
    ("no-zone", ["--until", "2027-01-16T08:00", "--reason", "x"], "with a zone"),
    ("garbage", ["--until", "tomorrow", "--reason", "x"], "with a zone"),
    ("empty-reason", ["--until", iso(NOW + DAY), "--reason", " \n "], "may not be empty"),
    ("no-reason", ["--until", iso(NOW + DAY)], "may not be empty"),
    ("no-until", ["--reason", "x"], "--until is required"),
    ("too-far", ["--until", iso(NOW + 21 * DAY + 1), "--reason", "x"], "more than 21 days ahead"),
    ("long-reason", ["--until", iso(NOW + DAY), "--reason", "x" * 301], "keep it to 300"),
    ("unknown-option", ["--until", iso(NOW + DAY), "--reason", "x", "--force"], "unknown argument"),
    ("dangling-option", ["--until"], "needs a value"),
])
def test_set_refuses_and_writes_nothing(e, label, args, why):
    r = e.run("set", *args)
    assert r.returncode == 2 and why in r.stderr, (label, r.returncode, r.stderr)
    assert not e.file.exists(), label


def test_set_accepts_exactly_the_bound(e):
    r = e.run("set", "--until", iso(NOW + 21 * DAY), "--reason", "x")
    assert r.returncode == 0, r.stderr


def test_set_reports_an_unwritable_directory(e):
    if os.geteuid() == 0:
        pytest.skip("root writes anywhere")
    e.file.parent.parent.mkdir(parents=True)
    e.file.parent.parent.chmod(0o500)
    try:
        r = e.run("set", "--until", iso(NOW + DAY), "--reason", "x")
    finally:
        e.file.parent.parent.chmod(0o700)
    assert r.returncode == 1 and "cannot write" in r.stderr, (r.returncode, r.stderr)


# ---- clear and the rest ------------------------------------------------------------------------

def test_clear_removes_the_file(e):
    e.write()
    r = e.run("clear")
    assert r.returncode == 0 and r.stdout.startswith("cleared:") and not e.file.exists(), r.stdout
    r = e.run("clear")
    assert r.returncode == 0 and r.stdout.startswith("nothing to clear"), r.stdout


def test_usage_errors(e):
    assert e.run().returncode == 2
    assert e.run("bogus").returncode == 2
    assert e.run("status", "--yaml").returncode == 2
    assert e.run("clear", "x").returncode == 2
    r = e.run("--help")
    assert r.returncode == 0 and "claude-usage-override" in r.stdout


def test_the_real_clock_is_used_without_the_test_variable(e):
    e.write(until="2000-01-01T00:00:00+00:00", set_at="1999-12-31T00:00:00+00:00")
    r = e.run("status", "--json", now=None)
    assert r.returncode == 1 and json.loads(r.stdout)["state"] == "expired", r.stdout


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider", *sys.argv[1:]]))
