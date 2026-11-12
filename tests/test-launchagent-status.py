#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for launchagent-status, which reports LaunchAgent plists that are deployed but not loaded.

Run: npx nx run suite-launchagent-status:test
 or: uv run --script tests/test-launchagent-status.py [-k <pattern>]

The tool is Python for macOS; these tests run it on any machine by putting fake `uname`,
`launchctl` and `plutil` first on PATH in a scratch directory. The fakes read their answers from
the scratch tree: a "plist" is a text file of `Key=Value` lines (which the fake plutil extracts
from), launchd's loaded set is one file per label under `loaded/` (its content is what
`launchctl print gui/<uid>/<label>` prints), and `disabled.txt` is what `print-disabled` prints.

What is held: not macOS and an unreadable gui domain are exit 3 (cannot tell); a loaded agent is
fine; an unloaded one is NOT-LOADED and exit 1; both spellings of launchd's disabled list and the
plist's own Disabled key make an agent disabled (not a problem); a plist with no Label is
unreadable; an agent launchd loaded from another file is loaded-elsewhere; `--problems` filters;
`--json` parses and carries the counts; an empty or absent directory is zero agents, exit 0.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_launchagent-status"

FAKE_UNAME = '#!/bin/sh\nprintf "%s\\n" "${FAKE_UNAME:-Darwin}"\n'

FAKE_LAUNCHCTL = r'''#!/bin/sh
case "$1" in
    print)
        case "$2" in
            gui/*/*)
                label=${2#gui/*/}
                if [ -f "$FAKE_ROOT/loaded/$label" ]; then cat "$FAKE_ROOT/loaded/$label"; exit 0; fi
                echo "Could not find service \"$label\" in domain for user gui: 501" >&2
                exit 113 ;;
            gui/*) exit "${FAKE_DOMAIN_RC:-0}" ;;
        esac ;;
    print-disabled)
        [ -f "$FAKE_ROOT/disabled.txt" ] && cat "$FAKE_ROOT/disabled.txt"
        exit 0 ;;
esac
exit 64
'''

# plutil -extract KEY raw -o - FILE over a Key=Value text file.
FAKE_PLUTIL = r'''#!/bin/sh
key=$2
file=$6
[ -f "$file" ] || exit 1
val=$(sed -n "s/^$key=//p" "$file" | sed -n 1p)
[ -n "$(grep "^$key=" "$file")" ] || exit 1
printf '%s\n' "$val"
'''


class Fake:
    def __init__(self, tmp: Path):
        self.root = tmp / "root"
        self.bin = tmp / "fakebin"
        self.agents = tmp / "LaunchAgents"
        for d in (self.root / "loaded", self.bin, self.agents):
            d.mkdir(parents=True)
        for name, body in (("uname", FAKE_UNAME), ("launchctl", FAKE_LAUNCHCTL),
                           ("plutil", FAKE_PLUTIL)):
            p = self.bin / name
            p.write_text(body)
            p.chmod(0o755)

    def plist(self, name, label=None, **keys):
        lines = [] if label is None else ["Label=%s" % label]
        lines += ["%s=%s" % kv for kv in keys.items()]
        p = self.agents / name
        p.write_text("\n".join(lines) + "\n")
        return p

    def load(self, label, path):
        (self.root / "loaded" / label).write_text(
            "%s = {\n\tactive count = 1\n\tpath = %s\n\tstdout path = /tmp/x\n}\n" % (label, path))

    def disabled(self, text):
        (self.root / "disabled.txt").write_text(text)

    def run(self, *args, **extra):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   FAKE_ROOT=str(self.root), HOME=str(self.root))
        env.update(extra)
        return subprocess.run([sys.executable, str(TOOL), *args], env=env, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=60)

    def check(self, *args, **extra):
        return self.run("--dir", str(self.agents), *args, **extra)


@pytest.fixture
def f(tmp_path):
    return Fake(tmp_path)


def test_not_macos_cannot_tell(f):
    r = f.check(FAKE_UNAME="Linux")
    assert r.returncode == 3
    assert "launchagent-status: not macOS; there are no LaunchAgents to check" in r.stderr


def test_an_unreadable_gui_domain_cannot_tell(f):
    f.load("com.x.a", f.plist("a.plist", "com.x.a"))
    r = f.check(FAKE_DOMAIN_RC="113")
    assert r.returncode == 3
    assert "gui domain" in r.stderr and "cannot tell" in r.stderr
    assert "NOT-LOADED" not in r.stdout


def test_a_loaded_agent_is_fine(f):
    p = f.plist("a.plist", "com.x.a")
    f.load("com.x.a", p)
    r = f.check()
    assert r.returncode == 0
    assert "loaded  com.x.a  %s" % p in r.stdout
    assert "1 agents: 1 loaded, 0 disabled, 0 not loaded, 0 other problems" in r.stdout


def test_an_unloaded_agent_is_a_problem(f):
    p = f.plist("a.plist", "com.x.a")
    r = f.check()
    assert r.returncode == 1
    assert "NOT-LOADED  com.x.a  %s" % p in r.stdout
    assert "1 agents: 0 loaded, 0 disabled, 1 not loaded, 0 other problems" in r.stdout


@pytest.mark.parametrize("spelling", ["disabled", "true"])
def test_launchd_disabled_list_makes_an_agent_disabled(f, spelling):
    f.plist("a.plist", "com.x.a")
    f.disabled('disabled services = {\n\t"com.x.a" => %s\n\t"com.x.other" => enabled\n}\n' % spelling)
    r = f.check()
    assert r.returncode == 0, r.stdout
    assert "disabled  com.x.a" in r.stdout
    assert "NOT-LOADED" not in r.stdout
    assert "1 disabled" in r.stdout


@pytest.mark.parametrize("spelling", ["enabled", "false"])
def test_an_enabled_entry_in_the_disabled_list_does_not_disable(f, spelling):
    f.plist("a.plist", "com.x.a")
    f.disabled('disabled services = {\n\t"com.x.a" => %s\n}\n' % spelling)
    r = f.check()
    assert r.returncode == 1
    assert "NOT-LOADED  com.x.a" in r.stdout


def test_the_plist_disabled_key_makes_an_agent_disabled(f):
    f.plist("a.plist", "com.x.a", Disabled="true")
    r = f.check()
    assert r.returncode == 0, r.stdout
    assert "disabled  com.x.a" in r.stdout


def test_a_plist_disabled_false_does_not_disable(f):
    f.plist("a.plist", "com.x.a", Disabled="false")
    r = f.check()
    assert r.returncode == 1
    assert "NOT-LOADED  com.x.a" in r.stdout


def test_a_plist_with_no_label_is_unreadable(f):
    p = f.plist("bad.plist")
    r = f.check()
    assert r.returncode == 1
    assert "unreadable  -  %s" % p in r.stdout
    assert "0 not loaded, 1 other problems" in r.stdout


def test_an_agent_loaded_from_another_file_is_loaded_elsewhere(f):
    p = f.plist("a.plist", "com.x.a")
    f.load("com.x.a", "/somewhere/else/a.plist")
    r = f.check()
    assert r.returncode == 1
    line = next(ln for ln in r.stdout.splitlines() if ln.startswith("loaded-elsewhere"))
    assert str(p) in line and "/somewhere/else/a.plist" in line
    assert "0 loaded, 0 disabled, 0 not loaded, 1 other problems" in r.stdout


def test_problems_prints_only_problem_lines_and_the_summary(f):
    good = f.plist("a.plist", "com.x.a")
    f.load("com.x.a", good)
    f.plist("b.plist", "com.x.b")
    f.plist("c.plist", "com.x.c", Disabled="true")
    r = f.check("--problems")
    assert r.returncode == 1
    lines = r.stdout.splitlines()
    assert len(lines) == 2
    assert lines[0].startswith("NOT-LOADED  com.x.b")
    assert lines[1].startswith("3 agents: 1 loaded, 1 disabled, 1 not loaded")


def test_agents_are_listed_sorted(f):
    for n in ("b", "a", "c"):
        f.load("com.x." + n, f.plist(n + ".plist", "com.x." + n))
    r = f.check()
    labels = [ln.split()[1] for ln in r.stdout.splitlines() if ln.startswith("loaded")]
    assert labels == ["com.x.a", "com.x.b", "com.x.c"]


def test_json_parses_and_carries_states_and_the_problem_count(f):
    good = f.plist("a.plist", "com.x.a")
    f.load("com.x.a", good)
    f.plist("b.plist", 'com.x."b"\\')
    f.load("com.x.e", "/elsewhere.plist")
    el = f.plist("e.plist", "com.x.e")
    r = f.check("--json")
    assert r.returncode == 1
    data = json.loads(r.stdout)
    assert data["dir"] == str(f.agents)
    assert data["domain"] == "gui/%d" % os.getuid()
    assert data["problems"] == 2
    by = {a["label"]: a for a in data["agents"]}
    assert by["com.x.a"]["state"] == "loaded" and by["com.x.a"]["loaded_path"] == str(good)
    assert by['com.x."b"\\']["state"] == "NOT-LOADED" and by['com.x."b"\\']["loaded_path"] is None
    assert by["com.x.e"]["state"] == "loaded-elsewhere"
    assert by["com.x.e"]["loaded_path"] == "/elsewhere.plist" and by["com.x.e"]["file"] == str(el)


def test_json_for_a_clean_directory_has_no_problems(f):
    f.load("com.x.a", f.plist("a.plist", "com.x.a"))
    r = f.check("--json")
    assert r.returncode == 0
    assert json.loads(r.stdout)["problems"] == 0


def test_an_empty_directory_is_zero_agents(f):
    r = f.check()
    assert r.returncode == 0
    assert "no LaunchAgent plists" in r.stdout
    assert "0 agents: 0 loaded, 0 disabled, 0 not loaded, 0 other problems" in r.stdout
    assert json.loads(f.check("--json").stdout)["agents"] == []


def test_an_absent_directory_is_zero_agents(f):
    r = f.run("--dir", str(f.agents / "nowhere"))
    assert r.returncode == 0
    assert "0 agents" in r.stdout


def test_the_default_directory_is_home_library_launchagents(f):
    d = f.root / "Library" / "LaunchAgents"
    d.mkdir(parents=True)
    (d / "a.plist").write_text("Label=com.x.a\n")
    r = f.run()
    assert r.returncode == 1
    assert "NOT-LOADED  com.x.a  %s" % (d / "a.plist") in r.stdout


def test_a_directory_reached_through_a_symlink_is_the_same_directory(f, tmp_path):
    p = f.plist("a.plist", "com.x.a")
    f.load("com.x.a", p)  # launchd knows the real path
    link = tmp_path / "linked"
    link.symlink_to(f.agents)
    r = f.run("--dir", str(link))
    assert r.returncode == 0, r.stdout
    assert "loaded  com.x.a  %s" % (link / "a.plist") in r.stdout
    assert "loaded-elsewhere" not in r.stdout


@pytest.mark.parametrize("args", [["--bogus"], ["--dir"]])
def test_usage_errors_are_exit_2(f, args):
    assert f.run(*args).returncode == 2


def test_help_is_exit_0_and_names_the_stale_plist_limit(f):
    r = f.run("--help")
    assert r.returncode == 0
    assert "stale copy" in r.stdout


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", *sys.argv[1:]]))
