#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2", "pytest-xdist==3.8.0"]
# ///
"""Tests for seam-probe. Every suite here is a scratch directory of tiny case scripts, and every
fixture lives under a temp sandbox root, so nothing touches a real repository or starts Claude
Code. The worktree-takeover suite this base ships is linted here too."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_seam-probe"
SHIPPED = HERE.parent / "private_dot_local" / "share" / "seam-probe" / "suites"


def _load():
    loader = importlib.machinery.SourceFileLoader("seam_probe", str(TOOL))
    spec = importlib.util.spec_from_loader("seam_probe", loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["seam_probe"] = mod
    loader.exec_module(mod)
    return mod


sp = _load()

CASE = """\
[[case]]
id = "{id}"
question = "q"
relies = "r"
bears-on = "b"
regimes = [{regimes}]
script = "{id}.sh"
plants = [{{ id = "p1", expect = "FAIL" }}]
minutes = 1
"""


@pytest.fixture
def env(tmp_path, monkeypatch):
    suites, sandbox, state = tmp_path / "suites", tmp_path / "sandbox", tmp_path / "state"
    for d in (suites, sandbox, state):
        d.mkdir()
    # Never the machine's real timing slot: a heavy case skips while another session holds it or a
    # grant is pending, so a suite that read the live slot failed whenever any seat held it
    # (measured 2026-11-21: four bootstrap-timeout tests failed under a held slot and passed with
    # an empty slot state). A test that needs a held slot stubs fleet-slot on PATH instead.
    e = dict(os.environ, SEAM_PROBE_SUITES=str(suites), SEAM_PROBE_SANDBOX=str(sandbox),
             SEAM_PROBE_STATE=str(state), HOME=os.environ.get("HOME", str(tmp_path)),
             FLEET_SLOT_STATE=str(tmp_path / "fleet-slot"))
    e.pop("CLAUDECODE", None)
    e.pop("FLEET_SLOT_AS", None)
    return {"suites": suites, "sandbox": sandbox, "state": state, "env": e, "tmp": tmp_path}


def make_suite(env, cases, name="s", extra=""):
    """cases: {id: (bash body, regimes string)}"""
    d = env["suites"] / name
    d.mkdir()
    toml = f'suite = "{name}"\n{extra}\n'
    for cid, (body, regimes) in cases.items():
        toml += CASE.format(id=cid, regimes=regimes)
        (d / f"{cid}.sh").write_text("set -u\nsp=$SEAM_PROBE\n" + textwrap.dedent(body))
    (d / "suite.toml").write_text(toml)
    return d


def tool(env, *args, extra_env=None, cwd=None):
    e = dict(env["env"], **(extra_env or {}))
    return subprocess.run([str(TOOL), *args], capture_output=True, text=True, env=e, cwd=cwd, timeout=300)


# ---- declarations ------------------------------------------------------------------------------

@pytest.mark.parametrize("mutate,needle", [
    (lambda t: t.replace('relies = "r"\n', ""), "`relies` is required"),
    (lambda t: t.replace('plants = [{ id = "p1", expect = "FAIL" }]\n', ""), "at least one plant"),
    (lambda t: t.replace('expect = "FAIL"', 'expect = "PASS"'), "must expect FAIL"),
    (lambda t: t.replace('regimes = ["none"]', 'regimes = ["sandboxed"]'), "`regimes` must be"),
    (lambda t: t.replace("minutes = 1", "minutes = 0"), "`minutes` must be"),
    (lambda t: t + 'flavor = "x"\n', "unknown keys"),
    (lambda t: t + 'fixtures = "a1"\n', "`fixtures` must be a list"),
    (lambda t: t + 'fixtures = ["Bad Name"]\n', "`fixtures` must be a list"),
    (lambda t: t + 'commands = { remove = "wt remove x; ls" }\n', "is compound"),
    (lambda t: t + 'commands = { remove = "git -C a log | head" }\n', "is compound"),
    (lambda t: t.replace('script = "c.sh"', 'script = "missing.sh"'), "is not a file"),
])
def test_lint_refuses(env, mutate, needle):
    d = make_suite(env, {"c": ("", '"none"')})
    (d / "suite.toml").write_text(mutate((d / "suite.toml").read_text()))
    r = tool(env, "lint", "s")
    assert r.returncode == 2 and needle in r.stdout, r.stdout + r.stderr


def test_lint_accepts_a_single_command(env):
    d = make_suite(env, {"c": ("", '"none"')})
    (d / "suite.toml").write_text((d / "suite.toml").read_text() + 'commands = { remove = "wt remove --no-hooks --foreground x" }\n')
    assert tool(env, "lint", "s").returncode == 0


def test_shipped_suites_lint_clean(env):
    r = tool(env, "lint", extra_env={"SEAM_PROBE_SUITES": str(SHIPPED)})
    assert r.returncode == 0, r.stdout + r.stderr


# ---- verdicts and exit codes -------------------------------------------------------------------

@pytest.mark.parametrize("body,code,shown", [
    ('"$sp" verdict FAIL "it broke"\n', 1, "FAIL"),
    ('"$sp" verdict VOID "control misbehaved"\n', 3, "VOID"),
    ('"$sp" verdict DENIED "classifier"\n', 5, "DENIED"),
    ('"$sp" verdict SKIPPED "no trust"\n', 6, "SKIPPED"),
    ("exit 0\n", 3, "INCONCLUSIVE"),
    ('"$sp" verdict PASS "fine"\n', 4, "NOT-SEEN-RED"),
])
def test_verdict_exit(env, body, code, shown):
    make_suite(env, {"c": (body, '"none"')})
    r = tool(env, "run", "s", "--yes")
    assert r.returncode == code, r.stdout + r.stderr
    assert shown in r.stdout


def test_red_then_pass_is_zero(env):
    body = 'if [ "$SEAM_PROBE_PLANT" = p1 ]; then "$sp" verdict FAIL planted; else "$sp" verdict PASS fine; fi\n'
    d = make_suite(env, {"c": (body, '"none"')})
    r = tool(env, "red", "s", "c", "--yes")
    assert r.returncode == 0 and "RED" in r.stdout, r.stdout + r.stderr
    assert tool(env, "run", "s", "--yes").returncode == 0
    # Changing the case script retires its red.
    (d / "c.sh").write_text((d / "c.sh").read_text() + "# changed\n")
    assert tool(env, "run", "s", "--yes").returncode == 4


def test_red_key_includes_versions(env, tmp_path):
    body = 'if [ "$SEAM_PROBE_PLANT" = p1 ]; then "$sp" verdict FAIL planted; else "$sp" verdict PASS fine; fi\n'
    make_suite(env, {"c": (body, '"none"')})
    fake = tmp_path / "bin"
    fake.mkdir()
    (fake / "claude").write_text("#!/bin/sh\necho 9.9.9 '(Claude Code)'\n")
    (fake / "claude").chmod(0o755)
    path_a = {"PATH": f"{fake}:{os.environ['PATH']}"}
    assert tool(env, "red", "s", "c", "--yes", extra_env=path_a).returncode == 0
    assert tool(env, "run", "s", "--yes", extra_env=path_a).returncode == 0
    (fake / "claude").write_text("#!/bin/sh\necho 9.9.10 '(Claude Code)'\n")
    assert tool(env, "run", "s", "--yes", extra_env=path_a).returncode == 4


def test_plant_that_passes_is_blind(env):
    make_suite(env, {"c": ('"$sp" verdict PASS "never fails"\n', '"none"')})
    r = tool(env, "red", "s", "c", "--yes")
    assert r.returncode == 4 and "BLIND" in r.stdout, r.stdout + r.stderr


def test_fail_wins_over_unknowns():
    assert sp.combine([0, 6, 1, 3]) == 1
    assert sp.combine([0, 3, 6]) == 6
    assert sp.combine([]) == 0


def test_second_verdict_for_an_arm_is_refused(env):
    body = '"$sp" verdict --arm a PASS one\n"$sp" verdict --arm a FAIL two && echo SECOND-ACCEPTED\n"$sp" verdict --arm b FAIL other\n'
    make_suite(env, {"c": (body, '"none"')})
    r = tool(env, "run", "s", "--yes")
    run_dir = max((env["state"] / "s").iterdir(), key=lambda p: p.name)
    out = (run_dir / "output-c.txt").read_text()
    assert "SECOND-ACCEPTED" not in out and "already given" in out
    assert r.returncode == 1 and "c/b" in r.stdout and "c/a" in r.stdout


# ---- fixtures and cleanup ----------------------------------------------------------------------

def test_fixture_is_removed_after_the_case(env):
    body = 'repo=$("$sp" fixture repo f1) || exit 1\nprintf "%s\\n" "$repo" > "$SEAM_PROBE_SUITE_DIR/seen"\n"$sp" verdict FAIL x\n'
    d = make_suite(env, {"c": (body, '"none"')})
    tool(env, "run", "s", "--yes")
    repo = Path((d / "seen").read_text().strip())
    assert repo.parent == env["sandbox"] / "seams" / "s" and not repo.exists()
    assert not (repo.parent / "f1.remote.git").exists()


def test_fixture_commits_skip_signing_and_hooks(env):
    body = ('repo=$("$sp" fixture repo f1) || exit 1\n'
            'git -C "$repo" config --get commit.gpgsign > "$SEAM_PROBE_SUITE_DIR/sign"\n'
            'git -C "$repo" log --oneline origin/main > "$SEAM_PROBE_SUITE_DIR/pushed"\n'
            '"$sp" verdict FAIL x\n')
    d = make_suite(env, {"c": (body, '"none"')})
    tool(env, "run", "s", "--yes")
    assert (d / "sign").read_text().strip() == "false"
    assert "fixture" in (d / "pushed").read_text()


def test_interrupt_cleans_up(env):
    body = 'repo=$("$sp" fixture repo f1) || exit 1\ntouch "$SEAM_PROBE_SUITE_DIR/ready"\nsleep 60\n"$sp" verdict PASS late\n'
    d = make_suite(env, {"c": (body, '"none"')})
    p = subprocess.Popen([str(TOOL), "run", "s", "--yes"], env=env["env"], stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    deadline = time.time() + 60
    while not (d / "ready").exists() and time.time() < deadline:
        time.sleep(0.2)
    assert (d / "ready").exists()
    assert (env["sandbox"] / "seams/s/f1").exists()
    p.send_signal(signal.SIGINT)
    p.communicate(timeout=60)
    assert p.returncode == 130
    assert not (env["sandbox"] / "seams/s/f1").exists()


def test_refuses_to_replace_a_directory_it_did_not_make(env):
    stranger = env["sandbox"] / "seams/s/f1"
    stranger.mkdir(parents=True)
    (stranger / "keep.txt").write_text("not a fixture")
    body = '"$sp" fixture repo f1 || "$sp" verdict INCONCLUSIVE refused\n'
    make_suite(env, {"c": (body, '"none"')})
    r = tool(env, "run", "s", "--yes")
    assert "refused" in r.stdout and (stranger / "keep.txt").exists()


def test_fixture_root_outside_the_sandbox_is_refused(env, tmp_path):
    ledger = tmp_path / "l.jsonl"
    r = tool(env, "fixture", "repo", "f1", extra_env={"SEAM_PROBE_RUN": str(ledger),
                                                      "SEAM_PROBE_FIXTURES": str(tmp_path / "elsewhere")})
    assert r.returncode == 2 and "outside" in r.stderr
    assert not (tmp_path / "elsewhere").exists()


def test_primitive_needs_a_run(env):
    r = tool(env, "verdict", "PASS", "x")
    assert r.returncode == 2 and "SEAM_PROBE_RUN" in r.stderr


# ---- evidence ----------------------------------------------------------------------------------

def test_no_symlink(tmp_path):
    root = tmp_path / "repo"
    (root / ".claude/worktrees").mkdir(parents=True)
    assert sp.prim_no_symlink(str(root), ".claude/worktrees") == 0
    (root / ".claude/worktrees").rmdir()
    (root / "real").mkdir()
    (root / ".claude/worktrees").symlink_to(root / "real")
    assert sp.prim_no_symlink(str(root), ".claude/worktrees") == 1
    other = tmp_path / "repo2"
    other.mkdir()
    (other / ".claude").symlink_to(root / "real")
    assert sp.prim_no_symlink(str(other), ".claude/worktrees") == 1


def test_no_symlink_reports_above_the_root(tmp_path, capsys):
    (tmp_path / "real/.claude/worktrees").mkdir(parents=True)
    (tmp_path / "link").symlink_to(tmp_path / "real")
    assert sp.prim_no_symlink(str(tmp_path / "link"), ".claude/worktrees") == 0
    assert "at or above" in capsys.readouterr().out


# ---- where it may run, and what it prints ------------------------------------------------------

def test_session_case_refused_inside_claude_code(env):
    make_suite(env, {"c": ('"$sp" verdict PASS x\n', '"real"')})
    r = tool(env, "run", "s", "--yes", extra_env={"CLAUDECODE": "1"})
    assert r.returncode == 2 and "plain terminal" in r.stderr
    r = tool(env, "red", "s", "c", "--yes", extra_env={"CLAUDECODE": "1"})
    assert r.returncode == 2


def test_none_regime_runs_inside_claude_code(env):
    make_suite(env, {"c": ('"$sp" verdict FAIL x\n', '"none"')})
    assert tool(env, "run", "s", "--yes", extra_env={"CLAUDECODE": "1"}).returncode == 1


def test_no_terminal_without_yes_is_refused(env):
    make_suite(env, {"c": ('"$sp" verdict PASS x\n', '"none"')})
    r = subprocess.run([str(TOOL), "run", "s"], capture_output=True, text=True, env=env["env"],
                       stdin=subprocess.DEVNULL, timeout=60)
    assert r.returncode == 2 and "--yes" in r.stderr


def test_summary_names_no_path(env):
    body = '"$sp" verdict FAIL "saw $HOME/secret-place and $SEAM_PROBE_FIXTURES/f1"\n'
    make_suite(env, {"c": (body, '"none"')})
    tool(env, "run", "s", "--yes")
    run_dir = max((env["state"] / "s").iterdir(), key=lambda p: p.name)
    summary = (run_dir / "summary.txt").read_text()
    assert env["env"]["HOME"] not in summary and "<fixtures>/f1" in summary and "~/secret-place" in summary
    rec = json.loads((run_dir / "results.jsonl").read_text().splitlines()[0])
    assert rec["case"] == "c" and rec["arms"][0]["verdict"] == "FAIL" and "version_claude" in rec


def test_terminal_shows_real_paths_and_summary_stays_sanitized(env):
    body = ('repo=$("$sp" fixture repo f1) || exit 1\n'
            '"$sp" verdict SKIPPED "needs cd $repo && claude"\n')
    make_suite(env, {"c": (body, '"none"')})
    r = tool(env, "run", "s", "--yes")
    real = str(env["sandbox"] / "seams/s/f1")
    assert f"cd {real} && claude" in r.stdout and "<fixtures>" not in r.stdout, r.stdout
    run_dir = max((env["state"] / "s").iterdir(), key=lambda p: p.name)
    summary = (run_dir / "summary.txt").read_text()
    assert "cd <fixtures>/f1 && claude" in summary and str(env["sandbox"]) not in summary


KEEP = '''\
repo=$("$sp" fixture repo f1) || exit 1
"$sp" fixture keep "$repo" >/dev/null
"$sp" verdict SKIPPED x
'''


@pytest.mark.parametrize("verb", ["run", "red"])
def test_start_inside_the_fixture_tree_is_refused_before_anything_is_deleted(env, verb):
    make_suite(env, {"c": (KEEP, '"none"')})
    assert tool(env, "run", "s", "--yes").returncode == 6
    kept = env["sandbox"] / "seams/s/f1"
    assert (kept / ".git").exists()
    args = ["run", "s", "--yes"] if verb == "run" else ["red", "s", "c", "--yes"]
    for here in (kept, env["sandbox"] / "seams/s", kept / ".git"):
        r = tool(env, *args, cwd=here)
        assert r.returncode == 2 and "Traceback" not in r.stderr, r.stderr
        assert len(r.stderr.strip().splitlines()) == 1 and "cd out" in r.stderr and str(here) in r.stderr
        assert (kept / ".git").exists()  # the rebuild never started
    r = tool(env, *args, cwd=env["tmp"])
    assert "Traceback" not in r.stderr and "inside the fixture tree" not in r.stderr


def test_start_inside_the_fixture_tree_through_a_symlink_is_refused(env):
    make_suite(env, {"c": (KEEP, '"none"')})
    tool(env, "run", "s", "--yes")
    link = env["tmp"] / "link"
    link.symlink_to(env["sandbox"] / "seams/s/f1")
    r = subprocess.run(["sh", "-c", 'cd "$1" && exec "$2" "$3" run s --yes', "sh", str(link), sys.executable, str(TOOL)],
                       capture_output=True, text=True, env=env["env"], timeout=60)
    assert r.returncode == 2 and "inside the fixture tree" in r.stderr, r.stderr


def test_start_with_an_unreadable_directory_is_refused(env):
    make_suite(env, {"c": (KEEP, '"none"')})
    r = subprocess.run(["sh", "-c", 'mkdir gone && cd gone && rmdir ../gone && exec "$1" "$2" run s --yes', "sh", sys.executable, str(TOOL)],
                       capture_output=True, text=True, env=env["env"], cwd=env["tmp"], timeout=60)
    assert r.returncode == 2 and "Traceback" not in r.stderr and "cannot be read" in r.stderr, r.stderr


def test_trust_prints_a_copyable_block_per_declared_fixture(env):
    make_suite(env, {"c": ("", '"real"'), "d": ("", '"none"')})
    toml = env["suites"] / "s/suite.toml"
    t = toml.read_text().replace('script = "c.sh"\n', 'script = "c.sh"\nfixtures = ["a1", "b2"]\n')
    toml.write_text(t.replace('script = "d.sh"\n', 'script = "d.sh"\nfixtures = ["none-only"]\n'))
    r = tool(env, "trust", "s")
    assert r.returncode == 0, r.stderr
    for n in ("a1", "b2"):
        q = str(env["sandbox"] / "seams/s" / n)
        assert f"  cd {q} && claude\n  wt -C {q} config approvals add\n" in r.stdout, r.stdout
    assert "none-only" not in r.stdout and "<that repository>" not in r.stdout


def test_trust_quotes_a_path_with_a_space(env, tmp_path):
    make_suite(env, {"c": ("", '"real"')})
    toml = env["suites"] / "s/suite.toml"
    toml.write_text(toml.read_text().replace('script = "c.sh"\n', 'script = "c.sh"\nfixtures = ["a1"]\n'))
    sb = tmp_path / "with space"
    sb.mkdir()
    r = tool(env, "trust", "s", extra_env={"SEAM_PROBE_SANDBOX": str(sb)})
    assert f"cd '{sb}/seams/s/a1' && claude" in r.stdout, r.stdout


def test_shipped_cases_declare_their_fixtures():
    import tomllib
    data = tomllib.loads((SHIPPED / "worktree-takeover/suite.toml").read_text())
    assert {c["id"]: c["fixtures"] for c in data["case"]} == {
        "no-symlink": ["clean", "planted"], "local-md": ["lmd"], "claude-worktree": ["wtc"],
        "exempt-remove": ["exr"], "bootstrap-timeout": ["btm"]}


def test_heavy_case_waits_for_the_slot(env, tmp_path):
    d = make_suite(env, {"c": ('"$sp" verdict PASS x\n', '"none"')})
    (d / "suite.toml").write_text((d / "suite.toml").read_text() + "heavy = true\n")
    fake = tmp_path / "bin"
    fake.mkdir()
    (fake / "fleet-slot").write_text("#!/bin/sh\necho 'held by someone-else'\nexit 1\n")
    (fake / "fleet-slot").chmod(0o755)
    r = tool(env, "run", "s", "--yes", extra_env={"PATH": f"{fake}:{os.environ['PATH']}"})
    assert r.returncode == 6 and "someone-else" in r.stdout


# ---- the state directory -----------------------------------------------------------------------

def test_unwritable_state_directory_is_refused(env, tmp_path):
    make_suite(env, {"c": ('"$sp" verdict PASS x\n', '"none"')})
    blocker = tmp_path / "a-file"
    blocker.write_text("not a directory")
    for args in (("run", "s", "--yes"), ("red", "s", "c", "--yes")):
        r = tool(env, *args, extra_env={"SEAM_PROBE_STATE": str(blocker / "state")})
        assert r.returncode == 2, r.stdout + r.stderr
        assert "SEAM_PROBE_STATE" in r.stderr and "Traceback" not in r.stderr
        assert len(r.stderr.strip().splitlines()) == 1, r.stderr


# ---- sessions, against a fake claude -----------------------------------------------------------
# The fake records every call (argv, directory, stdin, the project settings file it found) and keeps
# an agents listing in a state directory. As a `--bg` session it creates the --worktree (where a
# worktrunk worktree-path in its environment or --settings puts it, as the plugin would, and the
# setup marker unless --settings disables the plugin), runs each numbered command of its prompt
# from there, and fakes the sandbox's refusal for a `git -C` outside its directory and its
# --add-dir grants. As `-p` it replies with every codeword in the CLAUDE.md and CLAUDE.local.md
# files from its directory up.

FAKE_CLAUDE = r"""#!/usr/bin/env python3
import json, os, re, secrets, shlex, shutil, signal, subprocess, sys, time, uuid
from pathlib import Path
st = Path(os.environ["FAKE_CLAUDE_STATE"]); st.mkdir(parents=True, exist_ok=True)
rows_f = st / "rows.json"
rows = json.loads(rows_f.read_text()) if rows_f.exists() else []
argv = sys.argv[1:]
try:
    os.getcwd()
except OSError:
    print("The current directory no longer exists (it was deleted or moved). Start Claude Code from an existing directory.")
    sys.exit(1)
stdin = sys.stdin.read() if "-p" in argv else None
proj = Path.cwd() / ".claude/settings.json"
with open(st / "calls.jsonl", "a") as f:
    f.write(json.dumps({"argv": argv, "cwd": os.getcwd(), "stdin": stdin,
                        "project_settings": json.loads(proj.read_text()) if proj.is_file() else None}) + "\n")
def save(): rows_f.write_text(json.dumps(rows))
def opt(flags, name): return flags[flags.index(name) + 1] if name in flags else None
# FAKE_CLAUDE_SPAWN: each session gets a real process of its own, which the pid record names and
# which a test can signal. On SIGTERM it ends and removes its record (FAKE_CLAUDE_TERM=ignore: it
# does not, so only SIGKILL stops it). FAKE_CLAUDE_RESPAWN ({"terminal": seconds}, matched on the
# display name) has a new process write the record again that many seconds after the stop, as a
# crash-respawn would; FAKE_CLAUDE_GROW has the session's transcript gain a line then.
SESSION_PROC = r'''
import json, os, signal, subprocess, sys, time
cfg = json.loads(sys.argv[1])
time.sleep(cfg.get("after", 0))
if cfg.get("grow_only"):
    open(cfg["transcript"], "a").write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "back"}]}}) + "\n")
    sys.exit(0)
rec = cfg["record"]
open(rec, "w").write(json.dumps(dict(cfg["data"], pid=os.getpid())))
def after(extra):
    subprocess.Popen([sys.executable, "-c", open(cfg["self"]).read(), json.dumps(extra)], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def term(*_):
    if cfg.get("ignore"): return
    try: os.unlink(rec)
    except OSError: pass
    if cfg.get("respawn") is not None:
        after(dict(cfg, after=cfg["respawn"], respawn=None, grow=None))
    if cfg.get("grow") is not None:
        after({"after": cfg["grow"], "grow_only": True, "transcript": cfg["transcript"]})
    sys.exit(0)
signal.signal(signal.SIGTERM, term)
while True: time.sleep(0.05)
'''
def spawn_session(sid, u, disp, transcript, plain=False):
    rec_dir = Path(os.environ["SEAM_PROBE_PID_RECORDS"]); rec_dir.mkdir(parents=True, exist_ok=True)
    rf = rec_dir / (sid + ".json")
    src = st / "session_proc.py"; src.write_text(SESSION_PROC)
    def pick(var):
        for key, d in json.loads(os.environ.get(var, "{}")).items():
            if "seam-probe-%s-" % key in (disp or ""): return d
        return None
    cfg = {"record": str(rf), "data": {"sessionId": u, "status": "idle", "name": disp}, "self": str(src),
           "ignore": os.environ.get("FAKE_CLAUDE_TERM") == "ignore", "transcript": str(transcript),
           "respawn": None if plain else pick("FAKE_CLAUDE_RESPAWN"), "grow": None if plain else pick("FAKE_CLAUDE_GROW")}
    subprocess.Popen([sys.executable, "-c", SESSION_PROC, json.dumps(cfg)], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if rf.exists(): break
        time.sleep(0.02)
if argv[:1] == ["--version"]:
    print("9.9.9 (Claude Code)"); sys.exit(0)
if argv[:1] == ["agents"] and os.environ.get("FAKE_CLAUDE_AGENTS") == "fail":
    print("boom"); sys.exit(1)
if argv[:1] == ["agents"]:
    print(json.dumps(rows if "--all" in argv else [r for r in rows if r["state"] != "stopped"])); sys.exit(0)
if argv[:1] == ["stop"]:
    if os.environ.get("FAKE_CLAUDE_STOP") != "ignore":
        for r in rows:
            if r["id"] == argv[1]: r["state"] = "stopped"
        save()
    print("stopping"); sys.exit(0)
if argv[:1] == ["rm"]:
    if os.environ.get("FAKE_CLAUDE_RM") == "refuse-once" and "--force-remove-worktree" not in argv:
        print("Not removed: the WorktreeRemove hook failed. To delete it anyway: claude rm %s --force-remove-worktree wt-0042" % argv[1])
        sys.exit(1)
    if os.environ.get("FAKE_CLAUDE_RM") == "escalate":
        # The refusals as measured: the first names one flag, the retry names both.
        if "--discard-unpushed" not in argv:
            print("Not removed: unpushed commits. To delete it anyway: claude rm %s --discard-unpushed dp-1" % argv[1])
            sys.exit(1)
        if "--force-remove-worktree" not in argv:
            print("Not removed: No WorktreeRemove hook is enabled here. claude rm %s --force-remove-worktree wt-9 --discard-unpushed dp-1" % argv[1])
            sys.exit(1)
    if os.environ.get("FAKE_CLAUDE_RM") == "never":
        n = sum(1 for l in (st / "calls.jsonl").read_text().splitlines() if json.loads(l)["argv"][:1] == ["rm"])
        print("Not removed: claude rm %s --discard-unpushed dp-%d" % (argv[1], n)); sys.exit(1)
    # FAKE_CLAUDE_RM_KEEP (["terminal"], matched on the display name): rm succeeds and leaves the row.
    if any("seam-probe-%s-" % k in (r.get("name") or "") for r in rows if r["id"] == argv[1] for k in json.loads(os.environ.get("FAKE_CLAUDE_RM_KEEP", "[]"))):
        print("removed"); sys.exit(0)
    gone_f = st / "removed.json"
    gone = json.loads(gone_f.read_text()) if gone_f.exists() else []
    gone += [r for r in rows if r["id"] == argv[1]]; gone_f.write_text(json.dumps(gone))   # the transcript outlives the row
    rows[:] = [r for r in rows if r["id"] != argv[1]]; save(); print("removed"); sys.exit(0)
if "-p" in argv:
    if os.environ.get("FAKE_CLAUDE_REFUSE"):
        print("This prompt contains unsafe content and cannot be processed."); sys.exit(0)
    text = ""
    for d in [Path.cwd(), *Path.cwd().parents]:
        for n in ("CLAUDE.md", "CLAUDE.local.md"):
            if (d / n).is_file():
                t = (d / n).read_text(); text += t
                for imp in re.findall(r"^@(\S+)", t, re.M):
                    if (d / imp).is_file(): text += (d / imp).read_text()
    print("\n".join(sorted(set(re.findall(r"SPROBE-[A-Z]+-[0-9a-f]+", text)))) or "NONE"); sys.exit(0)
if "--bg" in argv:
    sep = argv.index("--") if "--" in argv else len(argv)
    flags, prompt = argv[:sep], (argv[sep + 1] if sep + 1 < len(argv) else "")
    if "--resume" in flags:
        r = next((r for r in rows if r["sessionId"] == opt(flags, "--resume")), None)
        gone_f = st / "removed.json"
        if r is None and gone_f.exists():
            # A removed row's transcript is still there: resuming starts a session under a new id.
            old = next((g for g in json.loads(gone_f.read_text()) if g["sessionId"] == opt(flags, "--resume")), None)
            if old is not None:
                nid = secrets.token_hex(4)
                rows.append(dict(old, id=nid, state="working")); save()
                tf = next(Path(os.environ["CLAUDE_CONFIG_DIR"]).glob("projects/*/" + old["sessionId"] + ".jsonl"))
                with tf.open("a") as fh: fh.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "back"}]}}) + "\n")
                if os.environ.get("FAKE_CLAUDE_SPAWN") and os.environ.get("SEAM_PROBE_PID_RECORDS"):
                    spawn_session(nid, old["sessionId"], old["name"], tf, plain=True)
                print("backgrounded · " + nid); sys.exit(0)
        if r is None: print("no such session"); sys.exit(1)
        if os.environ.get("FAKE_CLAUDE_RESUME") == "copy-same-id":
            print("that session is running, so this started a copy\nbackgrounded · " + r["id"]); sys.exit(0)
        if os.environ.get("FAKE_CLAUDE_RESUME") == "copy":
            nid = secrets.token_hex(4)
            rows.append(dict(r, id=nid, sessionId=str(uuid.uuid4()), state="working")); save()
            print("that session is running, so this started a copy\nbackgrounded · " + nid); sys.exit(0)
        r["state"] = "working"; save(); print("backgrounded · " + r["id"]); sys.exit(0)
    sid, u, here = secrets.token_hex(4), str(uuid.uuid4()), Path.cwd()
    settings = json.loads(Path(opt(flags, "--settings")).read_text()) if "--settings" in flags else {}
    if "--worktree" in flags:
        n = opt(flags, "--worktree")
        plugin = settings.get("enabledPlugins", {}).get("worktrunk@worktrunk", True)
        env_wt = os.environ.get("WORKTRUNK_WORKTREE_PATH") or settings.get("env", {}).get("WORKTRUNK_WORKTREE_PATH")
        run_in = here / (".claude/worktrees" if env_wt or not plugin else ".worktrees") / n
        subprocess.run([shutil.which("git"), "-C", str(here), "worktree", "add", "-q", "-b", n, str(run_in)], check=True)
        if plugin: (run_in / "seam-probe-setup-ran").touch()
    else:
        run_in = here
    allowed = [run_in] + [Path(flags[i + 1]) for i, a in enumerate(flags) if a == "--add-dir"]
    events, holds = [], []
    def call(name, inp, text, err=False, record=True):
        if not record: return
        tid = "toolu_" + secrets.token_hex(6)
        events.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]}})
        events.append({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tid, "content": text, "is_error": err}]}})
    # The overlay's deny rules for wt remove, and the one form its sandbox exclusion matches: a
    # command with a redirect, pipe or chain is not that form, so it runs sandboxed.
    deny = re.compile(os.environ.get("FAKE_CLAUDE_DENY", r"^wt remove( .*)? (-y|--yes|-f|--force|-D|--reap|-C|--config)( |$)"))
    exempt = re.compile(r"^wt remove --no-hooks --foreground [^;&|<>`$()]+$")
    skip = os.environ.get("FAKE_CLAUDE_SKIP")
    def run_cmds(text, where, grants, record=True):
        for line in text.splitlines():
            m = re.match(r"^\d+\. (.*)$", line)
            if not m: continue
            cmd = m.group(1)
            if skip and re.search(skip, cmd): continue
            if "run_in_background" in text and os.environ.get("FAKE_CLAUDE_FOREGROUND"):
                call("Bash", {"command": cmd}, "", False, record); continue   # asked for background, ran in front
            if "run_in_background" in text:
                # A background command is started, not run: the fake never waits for it. Its
                # lifetime, for the idle model below: a `sleep N` N seconds (1000 or more: for good), anything
                # else none.
                sm = re.match(r"^sleep (\d+)$", cmd)
                holds.append((float(sm.group(1)) if float(sm.group(1)) < 1000 else float("inf")) if sm else 0.0)
                call("Bash", {"command": cmd, "run_in_background": True}, "Command running in background with ID: bg1", False, record); continue
            if deny.search(cmd):
                call("Bash", {"command": cmd}, f"Permission to use Bash with command {cmd} has been denied.", True, record); continue
            c = re.search(r"git -C (\S+)", cmd)
            target = Path(shlex.split(c.group(1))[0]) if c else where
            if not any(target == a or a in target.parents for a in grants):
                mark = re.search(r"> (\S+) 2>&1", cmd).group(1)
                (where / mark).write_text("fatal: unable to write new index file: Read-only file system\n")
                call("Bash", {"command": cmd}, "", False, record)
                continue
            env = dict(os.environ, FAKE_SANDBOXED="0" if exempt.match(cmd) else "1")
            p = subprocess.run(["sh", "-c", cmd], cwd=where, env=env, capture_output=True, text=True, check=False)
            call("Bash", {"command": cmd}, p.stdout + p.stderr, p.returncode != 0, record)
    def schedule(text):
        # The idle-holders schedule prompt: ToolSearch loads CronCreate (and CronDelete), then the
        # job is created and, when the prompt says so, deleted. FAKE_CLAUDE_NOCRON: no such tool.
        m = re.search(r'cron expression "([^"]*)"', text)
        call("ToolSearch", {"max_results": 5, "query": "select:CronCreate"}, "No matching deferred tools found" if os.environ.get("FAKE_CLAUDE_NOCRON") else "Loaded CronCreate")
        if os.environ.get("FAKE_CLAUDE_NOCRON"): return
        # FAKE_CLAUDE_CRON_RECURRING: the job is made recurring; FAKE_CLAUDE_CRON_WRONG: for another time.
        expr = "1 1 1 1 *" if os.environ.get("FAKE_CLAUDE_CRON_WRONG") else m.group(1)
        call("CronCreate", {"cron": expr, "prompt": "Reply DONE.", "recurring": bool(os.environ.get("FAKE_CLAUDE_CRON_RECURRING"))}, "Scheduled job cron-1")
        if "CronDelete" in text: call("CronDelete", {"id": "cron-1"}, "Deleted cron-1")
        else: holds.append(float("inf"))   # a pending job holds the session for good
    def plugin_timeout():
        # worktrunk's plugin as Claude Code finds it: None when it is not installed.
        try:
            root = Path(json.loads((Path(os.environ["CLAUDE_CONFIG_DIR"]) / "plugins/installed_plugins.json").read_text())
                        ["plugins"]["worktrunk@worktrunk"][0]["installPath"])
            h = json.loads((root / "hooks/hooks.json").read_text())["hooks"]["WorktreeCreate"][0]["hooks"][0]
        except (OSError, KeyError, IndexError, ValueError):
            return None
        return h.get("timeout", 600)
    def subagent(task):
        n = "agent-" + secrets.token_hex(4)
        inp = {"description": "probe", "prompt": task, "subagent_type": "general-purpose", "isolation": "worktree"}
        tmo = plugin_timeout()
        wtp = here / (".worktrees" if tmo is not None else ".claude/worktrees") / n
        subprocess.run([shutil.which("git"), "-C", str(here), "worktree", "add", "-q", "-b", n, str(wtp)], check=True)
        cfg = here / ".config/wt.toml"
        m = re.search(r'^pre-start = "(.*)"$', cfg.read_text(), re.M) if tmo is not None and cfg.is_file() else None
        if m:
            pr = subprocess.Popen(["sh", "-c", m.group(1).replace("{{ worktree_path }}", shlex.quote(str(wtp)))],
                                  cwd=wtp, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                rc = pr.wait(timeout=tmo)
            except subprocess.TimeoutExpired:
                os.killpg(pr.pid, signal.SIGKILL); pr.wait()
                call("Agent", inp, f"WorktreeCreate hook timed out after {tmo}s", True); return
            if rc:
                call("Agent", inp, f"WorktreeCreate hook failed: pre-start exited {rc}", True); return
        run_cmds(task, wtp, [wtp], record=False)
        call("Agent", inp, "DONE")
    parts = re.split(r"^=== (.+) ===$", prompt, flags=re.M)
    if len(parts) > 1:
        for title, body in zip(parts[1::2], parts[2::2]):
            if "subagent's task" in title: subagent(body)
            else: run_cmds(body, run_in, allowed)
    elif "Do not use any tool" in prompt and os.environ.get("FAKE_CLAUDE_CONTROL_CALL"):
        call("Bash", {"command": "true"}, "")   # a control that used a tool anyway
    elif "CronCreate" in prompt:
        schedule(prompt)
    else:
        run_cmds(prompt, run_in, allowed)
    rows.append({"id": sid, "sessionId": u, "name": opt(flags, "-n"), "cwd": str(run_in), "state": "working",
                 "kind": "background", "startedAt": len(rows)}); save()
    t = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(run_in))
    t.mkdir(parents=True, exist_ok=True)
    lines = [{"type": "user", "message": {"content": prompt}}, *events,
             {"type": "assistant", "message": {"content": [{"type": "text", "text": os.environ.get("FAKE_CLAUDE_REPLY", "DONE")}]}}]
    (t / (u + ".jsonl")).write_text("".join(json.dumps(x) + "\n" for x in lines))
    # The session's process, as Claude Code's pid record shows it: a record naming a pid that is alive
    # (FAKE_CLAUDE_LIVE_PID, the test's own) until a helper removes it after the delay
    # FAKE_CLAUDE_STOP_AFTER ({"control": seconds, ...}, matched on the session's display name) gives
    # for it; a session with no delay is never stopped.
    if os.environ.get("FAKE_CLAUDE_SPAWN") and os.environ.get("SEAM_PROBE_PID_RECORDS") and not os.environ.get("FAKE_CLAUDE_NORECORD") \
            and not any("seam-probe-%s-" % k in (opt(flags, "-n") or "") for k in json.loads(os.environ.get("FAKE_CLAUDE_NOSPAWN", "[]"))):
        spawn_session(sid, u, opt(flags, "-n"), t / (u + ".jsonl"))
    elif os.environ.get("SEAM_PROBE_PID_RECORDS") and not os.environ.get("FAKE_CLAUDE_NORECORD") and not os.environ.get("FAKE_CLAUDE_SPAWN"):
        rec = Path(os.environ["SEAM_PROBE_PID_RECORDS"]); rec.mkdir(parents=True, exist_ok=True)
        rf = rec / (sid + ".json")
        rf.write_text(json.dumps({"pid": int(os.environ["FAKE_CLAUDE_LIVE_PID"]), "sessionId": u, "status": "idle", "name": opt(flags, "-n")}))
        # The supervisor, modeled: with FAKE_CLAUDE_IDLE seconds set, a session stops that long after
        # its last holder ended (none: at once), and never while one holds it for good.
        delay, disp = None, opt(flags, "-n") or ""
        if os.environ.get("FAKE_CLAUDE_IDLE"):
            delay = float(os.environ["FAKE_CLAUDE_IDLE"]) + max(holds, default=0.0)
        for key, d in json.loads(os.environ.get("FAKE_CLAUDE_STOP_AFTER", "{}")).items():
            if "seam-probe-%s-" % key in disp: delay = d
        if delay is not None and delay != float("inf"):
            subprocess.Popen([sys.executable, "-c", "import os, sys, time; time.sleep(float(sys.argv[1])); os.path.exists(sys.argv[2]) and os.unlink(sys.argv[2])", str(delay), str(rf)],
                             start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.environ.get("FAKE_CLAUDE_NOID"): print("backgrounded · " + sid)
    sys.exit(0)
print("fake claude: unhandled", argv, file=sys.stderr); sys.exit(2)
"""

FAKE_WT = """#!/bin/sh
hooks='  post-start:\\n  touch seam-probe-setup-ran\\n  pre-start:\\n  sh {{ worktree_path }}/probe-bootstrap.sh\\n'
case "$*" in
  *--version*) echo "wt v0.0.0" ;;
  *"config approvals list"*)
    if [ -n "${FAKE_WT_UNAPPROVED:-}" ]; then
      printf "APPROVED\\n  (none)\\n\\nUNAPPROVED\\n$hooks"
    else
      printf "APPROVED\\n$hooks\\nUNAPPROVED\\n  (none)\\n"
    fi ;;
  "remove "*)
    # Run sandboxed (the fake claude says which), worktrunk's clean check meets the sandbox's
    # placeholder files and refuses; run exempt, it removes the branch's worktree.
    if [ "${FAKE_SANDBOXED:-1}" = 1 ] && [ -z "${FAKE_WT_NO_REFUSAL:-}" ]; then
      echo "Cannot remove: the worktree contains modified or untracked files" >&2; exit 1
    fi
    for a; do b=$a; done
    p=$(git worktree list --porcelain | awk -v b="branch refs/heads/$b" '/^worktree /{w=substr($0, 10)} $0 == b {print w}')
    [ -n "$p" ] || { echo "no worktree for $b" >&2; exit 1; }
    git worktree remove "$p" && git branch -q -d "$b" ;;
  *) exit 2 ;;
esac
"""

# wt-bootstrap as the fixture's pre-start meets it: by lockfile, at the worktree's root or -C DIR. A
# first install fills the package cache npm_config_cache names; it never falls back to a real cache.
FAKE_BOOTSTRAP = """#!/bin/sh
dir=.
[ "${1:-}" = -C ] && dir=$2
[ -f "$dir/package-lock.json" ] || exit 0
[ -z "${FAKE_BOOTSTRAP_RC:-}" ] || exit "$FAKE_BOOTSTRAP_RC"
cache=${npm_config_cache:?the fake install needs npm_config_cache}
mkdir -p "$cache" "$dir/node_modules/is-number"
if [ -z "$(ls -A "$cache")" ] && [ -z "${FAKE_BOOTSTRAP_NOCACHE:-}" ]; then
  echo tgz > "$cache/is-number-7.0.0.tgz"
fi
"""


@pytest.fixture
def fake(env, tmp_path):
    """env, with a fake claude and wt first on PATH and Claude Code's state in a temp directory."""
    bin_ = tmp_path / "fakebin"
    bin_.mkdir()
    for n, body in (("claude", FAKE_CLAUDE), ("wt", FAKE_WT), ("wt-bootstrap", FAKE_BOOTSTRAP)):
        (bin_ / n).write_text(body)
        (bin_ / n).chmod(0o755)
    cfg = tmp_path / "claude-config"
    cfg.mkdir()
    (cfg / ".config.json").write_text(json.dumps({"projects": {}}))
    env["env"].update({"PATH": f"{bin_}:{os.environ['PATH']}", "SEAM_PROBE_CLAUDE": "claude",
                       "FAKE_CLAUDE_STATE": str(tmp_path / "fake-state"), "CLAUDE_CONFIG_DIR": str(cfg),
                       "SEAM_PROBE_POLL": "0.05", "SEAM_PROBE_LIST_WAIT": "1", "SEAM_PROBE_STOP_WAIT": "1",
                       "SEAM_PROBE_SESSION_WAIT": "10", "SEAM_PROBE_SETUP_WAIT": "1"})
    env.update({"calls": tmp_path / "fake-state/calls.jsonl", "rows": tmp_path / "fake-state/rows.json", "cfg": cfg})
    return env


def calls(env, first=None):
    if not env["calls"].exists():
        return []
    out = [json.loads(x) for x in env["calls"].read_text().splitlines()]
    return [c for c in out if first is None or c["argv"][:1] == [first]]


def rows(env):
    return json.loads(env["rows"].read_text()) if env["rows"].exists() else []


def trust(env, *repos):
    (env["cfg"] / ".config.json").write_text(json.dumps(
        {"projects": {str(r): {"hasTrustDialogAccepted": True} for r in repos}}))


LAUNCH = 'repo=$("$sp" fixture repo f1) || exit 1\n'


@pytest.mark.parametrize("regime", ["real", "bare", "candidate"])
def test_launch_argument_shapes(fake, regime, tmp_path):
    src = tmp_path / "src"
    (src / "private_dot_local/bin").mkdir(parents=True)
    (src / sp.CANDIDATE_HOOK).write_text("#!/bin/sh\n")
    body = LAUNCH + (f'"$sp" session launch s1 --regime {regime} --cwd "$repo" --add-dir "$repo" '
                     f'--allow Bash --candidate-source {src} -- "--not a flag"\n"$sp" verdict FAIL x\n')
    make_suite(fake, {"c": (body, f'"{regime}"')})
    tool(fake, "run", "s", "--yes")
    (launch,) = [c for c in calls(fake) if "--bg" in c["argv"]]
    a = launch["argv"]
    assert a[-2:] == ["--", "--not a flag"], a
    assert a[a.index("--model") + 1] == "haiku" and "--add-dir" in a[:a.index("--")]
    if regime == "real":
        assert "--setting-sources" not in a and "--settings" not in a and launch["project_settings"] is None
    else:
        assert a[a.index("--setting-sources") + 1] == "project"
        ps = launch["project_settings"]
        assert ps["worktree"] == {"bgIsolation": "none"}
        assert ps["sandbox"] == {"enabled": True, "allowUnsandboxedCommands": False}
        hooks = json.dumps(ps.get("hooks", {}))
        if regime == "candidate":
            assert str(src.resolve() / sp.CANDIDATE_HOOK) in hooks
            assert ps["enabledPlugins"] == {"worktrunk@worktrunk": True}
        else:
            assert "hooks" not in ps and "enabledPlugins" not in ps


def test_a_session_left_under_the_fixtures_stops_a_run_before_it_starts_anything(fake):
    make_suite(fake, {"c": (LAUNCH + '"$sp" session launch s1 --regime real --cwd "$repo" -- go\n"$sp" verdict FAIL x\n', '"real"')})
    left = fake["sandbox"] / "seams/s/f1/.claude/worktrees/sp-own"
    fake["rows"].parent.mkdir(parents=True, exist_ok=True)
    fake["rows"].write_text(json.dumps([
        {"id": "4376eeab", "sessionId": "u1", "name": "x", "cwd": str(left), "state": "stopped"},
        {"id": "aaaa1111", "sessionId": "u2", "name": "y", "cwd": str(fake["tmp"]), "state": "working"}]))
    for verb in (["run", "s", "--yes"], ["red", "s", "c", "--yes"]):
        r = tool(fake, *verb)
        assert r.returncode == 2 and "Traceback" not in r.stderr, r.stderr
        assert "claude stop 4376eeab && claude rm 4376eeab" in r.stderr and "aaaa1111" not in r.stderr, r.stderr
        assert not calls(fake, "--bg") and not (fake["sandbox"] / "seams/s/f1").exists()


def test_an_unreadable_listing_stops_a_run_that_starts_sessions(fake):
    make_suite(fake, {"c": (LAUNCH + '"$sp" verdict FAIL x\n', '"real"')})
    r = tool(fake, "run", "s", "--yes", extra_env={"FAKE_CLAUDE_AGENTS": "fail"})
    assert r.returncode == 2 and "agents listing cannot be read" in r.stderr, r.stderr
    assert not (fake["sandbox"] / "seams/s/f1").exists()


def test_a_none_regime_run_reads_no_listing(fake):
    make_suite(fake, {"c": ('"$sp" verdict FAIL x\n', '"none"')})
    tool(fake, "run", "s", "--yes")
    assert not calls(fake, "agents")


def test_claude_calls_never_inherit_the_callers_directory(fake):
    # The case script deletes the directory the tool was started in, as a rebuild of a fixture the
    # caller stood in once did; every claude call after that, cleanup's included, must still start
    # from a directory that exists, or the real claude refuses and the session is left behind.
    here = fake["tmp"] / "callers-dir"
    here.mkdir()
    body = (LAUNCH + '"$sp" session launch s1 --regime real --cwd "$repo" -- go\n'
            '"$sp" session ask a1 --regime real --cwd "$repo" -- hi >/dev/null\n'
            'rmdir "$SEAM_PROBE_CALLER_PWD"\n"$sp" verdict FAIL x\n')
    make_suite(fake, {"c": (body, '"real"')})
    r = tool(fake, "run", "s", "--yes", cwd=here)
    assert "CLEANUP-FAILED" not in r.stdout and rows(fake) == [], r.stdout + r.stderr
    assert not here.exists()
    assert all(c["cwd"] != str(here) for c in calls(fake)), [c for c in calls(fake) if c["cwd"] == str(here)]
    assert [c["argv"][0] for c in calls(fake) if c["argv"][0] in ("stop", "rm")] == ["stop", "rm"]


def test_the_callers_directory_read_at_the_start_reaches_the_case(env):
    here = env["tmp"] / "start-here"
    here.mkdir()
    make_suite(env, {"c": ('"$sp" verdict FAIL "from $SEAM_PROBE_CALLER_PWD"\n', '"none"')})
    r = tool(env, "run", "s", "--yes", cwd=here)
    assert f"from {here.resolve()}" in r.stdout, r.stdout


def test_skipped_reason_names_a_copyable_command_for_a_path_with_a_space(fake, tmp_path):
    sb = tmp_path / "with space"
    sb.mkdir()
    shipped(fake)
    r = tool(fake, "run", "worktree-takeover", "exempt-remove", "--yes", extra_env={"SEAM_PROBE_SANDBOX": str(sb)})
    shown = str(sb / "seams/worktree-takeover/exr").replace(" ", "\\ ")
    assert r.returncode == 6 and f"cd {shown} && claude" in r.stdout, r.stdout


def test_launch_names_a_model(fake):
    body = LAUNCH + '"$sp" session launch s1 --regime real --cwd "$repo" --model sonnet -- go\n"$sp" verdict FAIL x\n'
    make_suite(fake, {"c": (body, '"real"')})
    tool(fake, "run", "s", "--yes")
    (launch,) = [c for c in calls(fake) if "--bg" in c["argv"]]
    assert launch["argv"][launch["argv"].index("--model") + 1] == "sonnet"


def test_launch_outside_the_fixtures_is_refused(fake, tmp_path):
    body = f'"$sp" session launch s1 --regime real --cwd {tmp_path} -- go; echo "rc=$?" > "$SEAM_PROBE_SUITE_DIR/rc"\n"$sp" verdict FAIL x\n'
    d = make_suite(fake, {"c": (body, '"real"')})
    tool(fake, "run", "s", "--yes")
    assert (d / "rc").read_text().strip() == "rc=2" and not [c for c in calls(fake) if c["argv"] != ["--version"] and c["argv"][0] != "agents"]


def test_settings_file_outside_the_fixtures_is_refused(fake, tmp_path):
    fixtures = fake["sandbox"] / "seams/s"
    fixtures.mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    (fixtures / "escape").symlink_to(outside)
    e = {"SEAM_PROBE_RUN": str(tmp_path / "l.jsonl"), "SEAM_PROBE_FIXTURES": str(fixtures)}
    for target in (outside / "settings.json", fixtures / "escape/settings.json", fixtures / "../settings.json"):
        r = tool(fake, "fixture", "settings", str(target), "{}", extra_env=e)
        assert r.returncode == 2 and "outside the run's fixture directory" in r.stderr, (target, r.stderr)
    assert not list(outside.iterdir()) and not (fake["sandbox"] / "seams/settings.json").exists()
    r = tool(fake, "fixture", "settings", str(fixtures / "ok.json"), '{"a": 1}', extra_env=e)
    assert r.returncode == 0 and json.loads((fixtures / "ok.json").read_text()) == {"a": 1}


STOP = LAUNCH + ('"$sp" session launch s1 --regime real --cwd "$repo" -- go\n'
                 '"$sp" session stop s1 > "$SEAM_PROBE_SUITE_DIR/stop.out"; echo "$?" > "$SEAM_PROBE_SUITE_DIR/stop"\n'
                 '"$sp" verdict FAIL x\n')


def test_stop_is_confirmed_against_the_listing(fake):
    d = make_suite(fake, {"c": (STOP, '"real"')})
    tool(fake, "run", "s", "--yes")
    assert (d / "stop").read_text().strip() == "0" and "stop confirmed" in (d / "stop.out").read_text()


def test_unconfirmed_stop_is_inconclusive(fake):
    d = make_suite(fake, {"c": (STOP, '"real"')})
    tool(fake, "run", "s", "--yes", extra_env={"FAKE_CLAUDE_STOP": "ignore"})
    assert (d / "stop").read_text().strip() == "3" and "INCONCLUSIVE" in (d / "stop.out").read_text()


def test_resume_reports_the_same_id_or_a_copy(fake):
    body = LAUNCH + ('"$sp" session launch s1 --regime real --cwd "$repo" -- go\n'
                     '"$sp" session resume s1 --prompt again > "$SEAM_PROBE_SUITE_DIR/out"; echo "$?" > "$SEAM_PROBE_SUITE_DIR/rc"\n'
                     '"$sp" verdict FAIL x\n')
    d = make_suite(fake, {"c": (body, '"real"')})
    tool(fake, "run", "s", "--yes")
    assert (d / "rc").read_text().strip() == "0" and "same id" in (d / "out").read_text()
    (resume,) = [c for c in calls(fake) if "--resume" in c["argv"]]
    a = resume["argv"]
    assert a[:3] == ["--bg", "--resume", a[2]] and sp.UUID_RE.match(a[2]) and a[3:] == ["--", "again"]
    launch = next(c for c in calls(fake) if "--bg" in c["argv"] and "--resume" not in c["argv"])
    assert resume["cwd"] == launch["cwd"]
    tool(fake, "run", "s", "--yes", extra_env={"FAKE_CLAUDE_RESUME": "copy"})
    assert (d / "rc").read_text().strip() == "1" and "new id" in (d / "out").read_text()
    assert rows(fake) == []  # the copy was removed at cleanup too
    # A copy is not the same session even when the id it prints matches.
    tool(fake, "run", "s", "--yes", extra_env={"FAKE_CLAUDE_RESUME": "copy-same-id"})
    assert (d / "rc").read_text().strip() == "1" and "mentions a copy" in (d / "out").read_text()


def test_resume_runs_from_the_sessions_own_directory(fake):
    """A --worktree session works in its worktree, so its wake is issued from there."""
    body = LAUNCH + ('"$sp" session launch s1 --regime real --cwd "$repo" --worktree w1 -- go\n'
                     '"$sp" session resume s1\n"$sp" verdict FAIL x\n')
    make_suite(fake, {"c": (body, '"real"')})
    tool(fake, "run", "s", "--yes")
    (resume,) = [c for c in calls(fake) if "--resume" in c["argv"]]
    assert resume["cwd"].endswith("/.worktrees/w1") and resume["argv"] == resume["argv"][:3]


def test_rm_keeps_its_whole_output(fake):
    body = LAUNCH + ('"$sp" session launch s1 --regime real --cwd "$repo" -- go\n'
                     '"$sp" session rm s1 > "$SEAM_PROBE_SUITE_DIR/out"; echo "$?" > "$SEAM_PROBE_SUITE_DIR/rc"\n'
                     '"$sp" verdict FAIL x\n')
    d = make_suite(fake, {"c": (body, '"real"')})
    tool(fake, "run", "s", "--yes", extra_env={"FAKE_CLAUDE_RM": "refuse-once"})
    assert (d / "rc").read_text().strip() == "1" and "wt-0042" in (d / "out").read_text()
    run_dir = max((fake["state"] / "s").iterdir(), key=lambda p: p.name)
    assert "--force-remove-worktree wt-0042" in (run_dir / "session-c-s1-rm.txt").read_text()


CLEAN = LAUNCH + ('"$sp" session launch s1 --regime real --cwd "$repo" -- go\n'
                  'printf "%s\\n" "$repo" > "$SEAM_PROBE_SUITE_DIR/repo"\n"$sp" verdict FAIL x\n')


def test_cleanup_stops_and_removes_every_session(fake):
    d = make_suite(fake, {"c": (CLEAN, '"real"')})
    r = tool(fake, "run", "s", "--yes", extra_env={"FAKE_CLAUDE_RM": "refuse-once"})
    rms = [c["argv"] for c in calls(fake, "rm")]
    assert len(rms) == 2 and rms[1][2:] == ["--force-remove-worktree", "wt-0042"], rms
    assert rows(fake) == [] and "CLEANUP-FAILED" not in r.stdout
    assert [c["argv"][1] for c in calls(fake, "stop")] == [rms[0][1]]


def test_cleanup_retries_while_a_refusal_names_a_new_flag(fake):
    make_suite(fake, {"c": (CLEAN, '"real"')})
    r = tool(fake, "run", "s", "--yes", extra_env={"FAKE_CLAUDE_RM": "escalate"})
    rms = [c["argv"][2:] for c in calls(fake, "rm")]
    pairs = [sorted(zip(a[::2], a[1::2])) for a in rms]
    assert pairs == [[], [("--discard-unpushed", "dp-1")],
                     [("--discard-unpushed", "dp-1"), ("--force-remove-worktree", "wt-9")]], rms
    assert rows(fake) == [] and "CLEANUP-FAILED" not in r.stdout, r.stdout
    run_dir = max((fake["state"] / "s").iterdir(), key=lambda p: p.name)
    log = (run_dir / "cleanup-c.txt").read_text()
    assert sum(l.startswith("  claude rm ") for l in log.splitlines()) == 3, log


def test_cleanup_retry_is_bounded(fake):
    make_suite(fake, {"c": (CLEAN, '"real"')})
    r = tool(fake, "run", "s", "--yes", extra_env={"FAKE_CLAUDE_RM": "never"})
    # Each refusal names a value not yet passed, so only the bound stops it: the first call and three retries.
    assert len(calls(fake, "rm")) == 4, [c["argv"] for c in calls(fake, "rm")]
    assert "CLEANUP-FAILED" in r.stdout, r.stdout


def test_cleanup_keeps_each_transcript_in_the_results_directory(fake):
    body = CLEAN.replace('"$sp" verdict FAIL x\n',
                         'u=$(sed -n "s/.*\\"uuid\\": \\"\\([0-9a-f-]*\\)\\".*/\\1/p" "$SEAM_PROBE_RUN" | tail -1)\n'
                         'f=$(ls "$CLAUDE_CONFIG_DIR"/projects/*/"$u".jsonl | head -1)\n'
                         'mkdir "${f%.jsonl}"; echo side > "${f%.jsonl}/side.txt"\n"$sp" verdict FAIL x\n')
    make_suite(fake, {"c": (body, '"real"')})
    projects = fake["cfg"] / "projects"
    r = tool(fake, "run", "s", "--yes")
    run_dir = max((fake["state"] / "s").iterdir(), key=lambda p: p.name)
    kept = run_dir / "transcript-c-s1.jsonl"
    assert kept.is_file() and "tool_use" in kept.read_text() or kept.stat().st_size > 0, list(run_dir.iterdir())
    assert (run_dir / "transcript-c-s1" / "side.txt").read_text() == "side\n"
    assert not list(projects.glob("*/*.jsonl")) and not [p for p in projects.glob("*/*") if p.is_dir()]
    assert "transcript kept: " in (run_dir / "cleanup-c.txt").read_text()
    text = (run_dir / "summary.txt").read_text()
    assert str(run_dir) not in text and str(fake["sandbox"]) not in text 


def test_cleanup_removes_transcripts_only_under_fixture_keys(fake):
    d = make_suite(fake, {"c": (CLEAN, '"real"')})
    # The same session id under a project that is not a fixture is never touched.
    tool(fake, "run", "s", "--yes")
    projects = fake["cfg"] / "projects"
    repo = Path((d / "repo").read_text().strip())
    assert not list(projects.glob(f"{sp.project_key(repo)}/*.jsonl"))
    # Second run: plant a stranger's copy of the next session's transcript elsewhere, by hooking rows.
    stranger = projects / "-home-someone-else"
    stranger.mkdir(parents=True)
    body = CLEAN.replace('"$sp" verdict FAIL x\n',
                         'u=$("$sp" session stop s1 >/dev/null; sed -n "s/.*\\"uuid\\": \\"\\([0-9a-f-]*\\)\\".*/\\1/p" "$SEAM_PROBE_RUN" | tail -1)\n'
                         f'cp "$(ls {projects}/*/"$u".jsonl | head -1)" {stranger}/"$u".jsonl\n"$sp" verdict FAIL x\n')
    (d / "c.sh").write_text("set -u\nsp=$SEAM_PROBE\n" + body)
    tool(fake, "run", "s", "--yes")
    left = list(projects.glob("*/*.jsonl"))
    assert [p.parent for p in left] == [stranger], left


def test_interrupt_stops_and_removes_sessions(fake):
    body = LAUNCH + '"$sp" session launch s1 --regime real --cwd "$repo" -- go\ntouch "$SEAM_PROBE_SUITE_DIR/ready"\nsleep 60\n"$sp" verdict PASS late\n'
    d = make_suite(fake, {"c": (body, '"real"')})
    p = subprocess.Popen([str(TOOL), "run", "s", "--yes"], env=fake["env"], stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    deadline = time.time() + 60
    while not (d / "ready").exists() and time.time() < deadline:
        time.sleep(0.2)
    assert (d / "ready").exists() and len(rows(fake)) == 1
    p.send_signal(signal.SIGINT)
    p.communicate(timeout=60)
    assert p.returncode == 130
    assert rows(fake) == [] and len(calls(fake, "rm")) == 1


def test_session_ask_runs_headless_with_tools_off(fake):
    body = LAUNCH + ('printf "x SPROBE-ROOT-ab12\\n" > "$repo/CLAUDE.md"\n'
                     'out=$("$sp" session ask a1 --regime real --cwd "$repo" -- "--list them")\n'
                     'echo "$?" > "$SEAM_PROBE_SUITE_DIR/rc"\n'
                     '"$sp" evidence codeword "$out" SPROBE-ROOT-ab12 > "$SEAM_PROBE_SUITE_DIR/seen"\n'
                     '"$sp" evidence codeword a1 SPROBE-ROOT-ab12 >> "$SEAM_PROBE_SUITE_DIR/seen"\n'
                     '"$sp" verdict FAIL x\n')
    d = make_suite(fake, {"c": (body, '"real"')})
    tool(fake, "run", "s", "--yes")
    (ask,) = calls(fake, "-p")
    a = ask["argv"]
    assert a[-2:] == ["--tools", ""] and "--list them" not in a and ask["stdin"].strip() == "--list them"
    assert a[a.index("--model") + 1] == "haiku" and "--no-session-persistence" in a
    assert (d / "rc").read_text().strip() == "0" and (d / "seen").read_text().count("seen: ") == 2
    tool(fake, "run", "s", "--yes", extra_env={"FAKE_CLAUDE_REFUSE": "1"})
    assert (d / "rc").read_text().strip() == "4"


def test_prompt_is_built_from_the_declared_commands(fake):
    d = make_suite(fake, {"c": ('"$sp" prompt one two "dir=/a b" > "$SEAM_PROBE_SUITE_DIR/p"\n'
                                '"$sp" prompt one > "$SEAM_PROBE_SUITE_DIR/q" 2>&1; echo "$?" >> "$SEAM_PROBE_SUITE_DIR/q"\n'
                                '"$sp" verdict FAIL x\n', '"none"')})
    (d / "suite.toml").write_text((d / "suite.toml").read_text()
                                  + 'commands = { one = "git -C {dir} status > m1 2>&1", two = "echo done > m2" }\n')
    tool(fake, "run", "s", "--yes")
    text = (d / "p").read_text()
    assert "1. git -C '/a b' status > m1 2>&1\n2. echo done > m2" in text and "own separate Bash call" in text
    assert "needs a value for {dir}" in (d / "q").read_text() and (d / "q").read_text().strip().endswith("2")


# ---- evidence ----------------------------------------------------------------------------------

def git_(*a, cwd):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *a],
                          cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def test_evidence_committed(tmp_path, capsys):
    repo = tmp_path / "r"
    repo.mkdir()
    git_("init", "-q", "-b", "main", cwd=repo)
    git_("commit", "-q", "--allow-empty", "-m", "base", cwd=repo)
    base = git_("rev-parse", "HEAD", cwd=repo)
    assert sp.prim_committed(str(repo), base, None) == 1
    git_("commit", "-q", "--allow-empty", "-m", "the-one", cwd=repo)
    assert sp.prim_committed(str(repo), base, None) == 0
    assert sp.prim_committed(str(repo), base, "the-one") == 0
    assert sp.prim_committed(str(repo), base, "another") == 1
    assert sp.prim_committed(str(tmp_path / "missing"), base, None) == 3
    assert sp.prim_committed(str(repo), "0" * 40, None) == 3


def test_evidence_refused(tmp_path, capsys):
    m = tmp_path / "mark"
    assert sp.prim_refused(str(m), None) == 3 and "INCONCLUSIVE" in capsys.readouterr().out
    m.write_text("[main 1234] ok\n")
    assert sp.prim_refused(str(m), None) == 1
    m.write_text("fatal: unable to write new index file: Read-only file system\n")
    assert sp.prim_refused(str(m), None) == 0
    m.write_text("error: contains modified or untracked files\n")
    assert sp.prim_refused(str(m), None) == 1
    assert sp.prim_refused(str(m), ["contains modified or untracked files"]) == 0


def test_evidence_path(tmp_path, capsys):
    (tmp_path / "d").mkdir()
    assert sp.prim_path(str(tmp_path / "d"), "exists", None) == 0
    assert sp.prim_path(str(tmp_path / "d"), "absent", None) == 1
    assert sp.prim_path(str(tmp_path / "nope"), "absent", None) == 0
    assert sp.prim_path(str(tmp_path / "nope"), "exists", None) == 1
    (tmp_path / "real/worktrees").mkdir(parents=True)
    (tmp_path / "repo").mkdir()
    (tmp_path / "repo/.claude").symlink_to(tmp_path / "real")
    assert sp.prim_path(str(tmp_path / "repo/.claude/worktrees"), "no-symlink", str(tmp_path / "repo")) == 1
    (tmp_path / "clean/.claude/worktrees").mkdir(parents=True)
    assert sp.prim_path(str(tmp_path / "clean/.claude/worktrees"), "no-symlink", str(tmp_path / "clean")) == 0


def test_evidence_codeword_from_a_file(tmp_path, capsys):
    f = tmp_path / "reply"
    f.write_text("SPROBE-ROOT-1\nSPROBE-LOCAL-2\n")
    assert sp.prim_codeword(str(f), "SPROBE-LOCAL-2") == 0
    assert sp.prim_codeword(str(f), "SPROBE-NEG-3") == 1


def test_evidence_codeword_from_a_transcript(fake):
    body = LAUNCH + ('"$sp" session launch s1 --regime real --cwd "$repo" -- go\n'
                     '"$sp" evidence codeword s1 SPROBE-X-1 > "$SEAM_PROBE_SUITE_DIR/seen"; echo "$?" >> "$SEAM_PROBE_SUITE_DIR/seen"\n'
                     '"$sp" evidence codeword nobody SPROBE-X-1 >> "$SEAM_PROBE_SUITE_DIR/seen"; echo "$?" >> "$SEAM_PROBE_SUITE_DIR/seen"\n'
                     '"$sp" verdict FAIL x\n')
    d = make_suite(fake, {"c": (body, '"real"')})
    tool(fake, "run", "s", "--yes", extra_env={"FAKE_CLAUDE_REPLY": "I see SPROBE-X-1"})
    lines = (d / "seen").read_text().splitlines()
    assert lines[0].startswith("seen:") and lines[1] == "0" and lines[3] == "3"


def test_wait_mark(fake, tmp_path):
    e = {"SEAM_PROBE_RUN": str(tmp_path / "l.jsonl"), "SEAM_PROBE_POLL": "0.05"}
    r = tool(fake, "wait", "mark", str(tmp_path / "m"), "--seconds", "0.3", extra_env=e)
    assert r.returncode == 3 and "INCONCLUSIVE" in r.stdout
    (tmp_path / "deep/er").mkdir(parents=True)
    (tmp_path / "deep/er/m").write_text("half\n")
    r = tool(fake, "wait", "mark", "--under", str(tmp_path), "m", "--line", "done", "--seconds", "0.3", extra_env=e)
    assert r.returncode == 3
    (tmp_path / "deep/er/m").write_text("half\ndone\n")
    r = tool(fake, "wait", "mark", "--under", str(tmp_path), "m", "--line", "done", "--seconds", "0.3", extra_env=e)
    assert r.returncode == 0 and r.stdout.strip() == str(tmp_path / "deep/er/m")


def test_evidence_trusted(fake, tmp_path):
    e = {"SEAM_PROBE_RUN": str(tmp_path / "l.jsonl")}
    assert tool(fake, "evidence", "trusted", "/x/repo", extra_env=e).returncode == 1
    trust(fake, "/x/repo")
    assert tool(fake, "evidence", "trusted", "/x/repo", extra_env=e).returncode == 0
    (fake["cfg"] / ".config.json").write_text("{}")
    r = tool(fake, "evidence", "trusted", "/x/repo", extra_env={**e, "HOME": str(tmp_path)})
    assert r.returncode == 3 and "INCONCLUSIVE" in r.stdout


# ---- the shipped session cases, end to end against the fakes -----------------------------------

def shipped(env):
    env["env"]["SEAM_PROBE_SUITES"] = str(SHIPPED)
    return env


def summary(env):
    run_dir = max((env["state"] / "worktree-takeover").glob("2*"), key=lambda p: p.name)
    return (run_dir / "summary.txt").read_text()


def test_local_md_case(fake):
    shipped(fake)
    r = tool(fake, "run", "worktree-takeover", "local-md", "--yes")
    assert r.returncode == 4 and "NOT-SEEN-RED" in r.stdout, r.stdout + r.stderr
    r = tool(fake, "red", "worktree-takeover", "local-md", "--yes")
    assert r.returncode == 0, r.stdout + r.stderr
    assert r.stdout.count(" RED ") == 3, r.stdout
    assert tool(fake, "run", "worktree-takeover", "local-md", "--yes").returncode == 0
    assert not (fake["sandbox"] / "seams/worktree-takeover/lmd").exists()


def test_claude_worktree_case(fake):
    shipped(fake)
    trust(fake, fake["sandbox"] / "seams/worktree-takeover/wtc")
    r = tool(fake, "run", "worktree-takeover", "claude-worktree", "--yes")
    assert r.returncode == 4 and r.stdout.count("NOT-SEEN-RED") == 3, r.stdout + r.stderr
    (launch,) = [c for c in calls(fake) if "--bg" in c["argv"]]
    assert launch["argv"][launch["argv"].index("--worktree") + 1] == "sp-own"
    r = tool(fake, "red", "worktree-takeover", "claude-worktree", "--yes")
    assert r.returncode == 0, r.stdout + r.stderr
    # plugin-off is read on the setup arm alone; grant-withheld on every arm.
    assert r.stdout.count(" RED ") == 4 and "placement [plant plugin-off] PASS" in r.stdout, r.stdout
    r = tool(fake, "run", "worktree-takeover", "claude-worktree", "--yes")
    assert r.returncode == 0, r.stdout
    assert rows(fake) == [] and not (fake["sandbox"] / "seams/worktree-takeover/wtc").exists()


@pytest.mark.parametrize("mark", ["own", "grant", "refuse"])
def test_claude_worktree_names_a_command_that_never_ran(fake, mark):
    shipped(fake)
    trust(fake, fake["sandbox"] / "seams/worktree-takeover/wtc")
    r = tool(fake, "run", "worktree-takeover", "claude-worktree", "--yes",
             extra_env={"FAKE_CLAUDE_SKIP": f"seam-probe-mark-{mark}"})
    text = summary(fake)
    assert f"the {mark} command never ran" in text, text
    assert "could not be read" not in text and "INCONCLUSIVE" in text, text
    assert "transcript-claude-worktree-own.jsonl" in text, text


@pytest.mark.parametrize("untrusted,unapproved,needle", [
    (True, False, "&& claude"), (False, True, "config approvals add"), (True, True, "; and worktrunk"),
])
def test_claude_worktree_skips_without_its_grants(fake, untrusted, unapproved, needle):
    shipped(fake)
    repo = fake["sandbox"] / "seams/worktree-takeover/wtc"
    if not untrusted:
        trust(fake, repo)
    extra = {"FAKE_WT_UNAPPROVED": "1"} if unapproved else {}
    r = tool(fake, "run", "worktree-takeover", "claude-worktree", "--yes", extra_env=extra)
    assert r.returncode == 6 and needle in summary(fake), r.stdout
    assert (repo / ".git").exists() and not calls(fake, "--bg")  # left in place for the grant; no session
    shown = r.stdout  # the terminal's copy names the real path; summary.txt names <fixtures>
    if untrusted:
        assert f"cd {repo} && claude, accept" in shown and "<fixtures>" not in shown, shown
        assert "<fixtures>" in summary(fake) and str(repo) not in summary(fake)
    r = tool(fake, "trust", "worktree-takeover")
    assert f"left in place: {repo}" in r.stdout
    for n in ("wtc", "exr", "btm"):
        q = fake["sandbox"] / "seams/worktree-takeover" / n
        assert f"  cd {q} && claude\n  wt -C {q} config approvals add\n" in r.stdout, r.stdout


# ---- evidence read from git, a transcript and a plugin's files ---------------------------------

def test_evidence_worktree(tmp_path, capsys):
    repo = tmp_path / "r"
    repo.mkdir()
    git_("init", "-q", "-b", "main", cwd=repo)
    git_("commit", "-q", "--allow-empty", "-m", "base", cwd=repo)
    wt = repo / ".claude/worktrees/w1"
    git_("worktree", "add", "-q", "-b", "w1", str(wt), cwd=repo)
    assert sp.prim_worktree(str(repo), str(wt)) == 0 and "listed by git; directory present" in capsys.readouterr().out
    # A removal that stopped half way: git no longer lists it, the directory is left.
    (repo / ".git/worktrees/w1").rename(tmp_path / "gone")
    assert sp.prim_worktree(str(repo), str(wt)) == 1 and "not listed by git; directory present" in capsys.readouterr().out
    shutil.rmtree(wt)
    assert sp.prim_worktree(str(repo), str(wt)) == 1 and "directory absent" in capsys.readouterr().out
    assert sp.prim_worktree(str(tmp_path / "missing"), str(wt)) == 3


def transcript_env(fake, tmp_path, events):
    """A ledger naming one session, and its transcript holding EVENTS, for the evidence primitives."""
    u = "12345678-1234-1234-1234-123456789abc"
    ledger = tmp_path / "l.jsonl"
    ledger.write_text(json.dumps({"kind": "session", "name": "own", "id": "abc123", "uuid": u}) + "\n")
    d = fake["cfg"] / "projects/-some-fixture"
    d.mkdir(parents=True)
    (d / f"{u}.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
    return {"SEAM_PROBE_RUN": str(ledger)}


def use(tid, name, inp):
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]}}


def res(tid, text, err=False):
    return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tid, "content": text, "is_error": err}]}}


def test_evidence_calls(fake, tmp_path):
    e = transcript_env(fake, tmp_path, [
        use("t1", "Bash", {"command": "wt remove  --foreground x"}), res("t1", "Cannot remove: contains modified or untracked files", True),
        use("t2", "Bash", {"command": "wt remove --no-hooks --foreground -y x"}),
        res("t2", "Permission to use Bash with command wt remove --no-hooks --foreground -y x has been denied.", True),
        use("t3", "Agent", {"prompt": "p", "isolation": "worktree"}), res("t3", [{"type": "text", "text": "DONE"}]),
        use("t4", "Agent", {"prompt": "p", "isolation": "worktree"}),
    ])
    r = tool(fake, "evidence", "calls", "own", extra_env=e)
    rows_ = [x.split("\t") for x in r.stdout.splitlines()]
    assert r.returncode == 0 and [x[0] for x in rows_] == ["error", "denied", "ok", "no-result"], r.stdout
    assert rows_[0][2] == "wt remove --foreground x" and rows_[2][2] == "isolation=worktree"
    r = tool(fake, "evidence", "calls", "own", "--tool", "Agent", "--tool", "Task", extra_env=e)
    assert [x.split("\t")[0] for x in r.stdout.splitlines()] == ["ok", "no-result"]
    r = tool(fake, "evidence", "calls", "own", "--command", "wt remove --foreground x", extra_env=e)
    assert r.returncode == 0 and r.stdout.startswith("error\tBash")
    r = tool(fake, "evidence", "calls", "own", "--command", "wt remove --no-hooks --foreground x", extra_env=e)
    assert r.returncode == 1 and r.stdout == ""
    (tmp_path / "l.jsonl").write_text(json.dumps({"kind": "session", "name": "own", "id": "abc123",
                                                  "uuid": "00000000-0000-0000-0000-000000000000"}) + "\n")
    r = tool(fake, "evidence", "calls", "own", extra_env=e)
    assert r.returncode == 3 and "INCONCLUSIVE" in r.stdout


def test_evidence_calls_summaries(fake, tmp_path):
    """A background Bash call is marked; any tool but Bash, Agent and Task shows its input as compact,
    sorted JSON cut at 200 characters; Agent and Task keep isolation=."""
    long_inp = {"z": "x" * 300, "a": 1}
    e = transcript_env(fake, tmp_path, [
        use("t1", "Bash", {"command": "sleep  9000", "run_in_background": True}), res("t1", "started"),
        use("t2", "Bash", {"command": "sleep 5", "run_in_background": False}), res("t2", "ok"),
        use("t3", "CronCreate", {"prompt": "Reply DONE.", "cron": "5 4 1 1 *", "recurring": False}), res("t3", "scheduled"),
        use("t4", "Task", {"prompt": "p", "isolation": "worktree"}), res("t4", "DONE"),
        use("t5", "ToolSearch", long_inp), res("t5", "x"),
    ])
    r = tool(fake, "evidence", "calls", "own", extra_env=e)
    got = [x.split("\t") for x in r.stdout.splitlines()]
    assert r.returncode == 0 and len(got) == 5, r.stdout
    assert got[0][2] == "sleep 9000 [background]" and got[1][2] == "sleep 5"
    assert got[2][2] == '{"cron":"5 4 1 1 *","prompt":"Reply DONE.","recurring":false}'
    assert got[3][2] == "isolation=worktree"
    assert got[4][2].startswith('{"a":1,"z":"xxx') and len(got[4][2]) == 200
    # --command still matches the command without the marker.
    r = tool(fake, "evidence", "calls", "own", "--command", "sleep 9000", extra_env=e)
    assert r.returncode == 0 and r.stdout.count("\n") == 1


def test_prompt_background_asks_for_run_in_background(fake):
    d = make_suite(fake, {"c": ('"$sp" prompt --background one two > "$SEAM_PROBE_SUITE_DIR/p"\n'
                                '"$sp" prompt one > "$SEAM_PROBE_SUITE_DIR/q"\n'
                                '"$sp" verdict FAIL x\n', '"none"')})
    (d / "suite.toml").write_text((d / "suite.toml").read_text()
                                  + 'commands = { one = "sleep 9000", two = "echo done" }\n')
    tool(fake, "run", "s", "--yes")
    text, plain = (d / "p").read_text(), (d / "q").read_text()
    assert "run_in_background" in text and "set to true" in text and "each as its own separate Bash call" in text
    assert "not wait" in text.replace("Do not wait", "not wait") and "poll" in text and "DONE" in text
    assert "notified" in text and text.rstrip().endswith("1. sleep 9000\n2. echo done")
    assert "run_in_background" not in plain and plain.rstrip().endswith("1. sleep 9000")


# ---- session process ---------------------------------------------------------------------------

UUID_A = "aaaaaaaa-1111-2222-3333-444444444444"
UUID_B = "bbbbbbbb-1111-2222-3333-444444444444"


def process_env(fake, tmp_path, records=None, roster="absent", uuid=UUID_A):
    """A ledger naming session `own`, a pid record directory holding RECORDS (name -> dict, or a raw
    string for a file that is not JSON) and a daemon roster ('absent', raw text, or a dict)."""
    ledger = tmp_path / "l.jsonl"
    ledger.write_text(json.dumps({"kind": "session", "name": "own", "id": "abc123", "uuid": uuid}) + "\n")
    rec = tmp_path / "pidrecs"
    rec.mkdir()
    for n, d in (records or {}).items():
        (rec / n).write_text(d if isinstance(d, str) else json.dumps(d))
    ros = tmp_path / "roster.json"
    if roster != "absent":
        ros.write_text(roster if isinstance(roster, str) else json.dumps(roster))
    return {"SEAM_PROBE_RUN": str(ledger), "SEAM_PROBE_PID_RECORDS": str(rec), "SEAM_PROBE_DAEMON_ROSTER": str(ros)}


def proc(fake, e):
    return tool(fake, "session", "process", "own", extra_env=e)


EMPTY_ROSTER = {"workers": {}}
LIVE = os.getpid()   # a pid that is alive on Linux and macOS; no procStart, so existence decides


def dead_pid():
    p = subprocess.Popen(["true"])
    p.wait()
    return p.pid


def test_session_process_a_live_pid_record_shows_a_process(fake, tmp_path):
    e = process_env(fake, tmp_path, {"1.json": {"pid": LIVE, "sessionId": UUID_A, "status": "idle"}}, EMPTY_ROSTER)
    r = proc(fake, e)
    assert r.returncode == 0 and "pid record" in r.stdout and "status idle" in r.stdout, r.stdout + r.stderr


def test_session_process_a_record_for_another_session_does_not_count(fake, tmp_path):
    e = process_env(fake, tmp_path, {"1.json": {"pid": LIVE, "sessionId": UUID_B, "status": "busy"}}, EMPTY_ROSTER)
    r = proc(fake, e)
    assert r.returncode == 1 and "no process" in r.stdout, r.stdout + r.stderr


def test_session_process_a_dead_pid_does_not_count(fake, tmp_path):
    e = process_env(fake, tmp_path, {"1.json": {"pid": dead_pid(), "sessionId": UUID_A, "status": "idle"}}, EMPTY_ROSTER)
    r = proc(fake, e)
    assert r.returncode == 1 and "no process" in r.stdout, r.stdout + r.stderr


@pytest.mark.skipif(not Path("/proc/self/stat").exists(), reason="procStart is compared only where /proc exists")
def test_session_process_a_reused_pid_does_not_count(fake, tmp_path):
    e = process_env(fake, tmp_path, {"1.json": {"pid": LIVE, "sessionId": UUID_A, "procStart": "1", "status": "idle"}},
                    EMPTY_ROSTER)
    assert proc(fake, e).returncode == 1


def test_session_process_the_roster_alone_shows_a_process(fake, tmp_path):
    e = process_env(fake, tmp_path, {}, {"workers": {"ab12": {"sessionId": UUID_A}}})
    r = proc(fake, e)
    assert r.returncode == 0 and "roster" in r.stdout, r.stdout + r.stderr


@pytest.mark.parametrize("records,roster,needle", [
    ({"1.json": "{not json"}, EMPTY_ROSTER, "pid record (1.json) cannot be read"),
    ({}, "absent", "is absent"),
    ({}, "{not json", "cannot be read or parsed"),
    ({}, {"workers": ["x"]}, "malformed"),
    ({}, [], "malformed"),
])
def test_session_process_an_unreadable_source_is_inconclusive(fake, tmp_path, records, roster, needle):
    e = process_env(fake, tmp_path, records, roster)
    r = proc(fake, e)
    assert r.returncode == 3 and "INCONCLUSIVE" in r.stdout and needle in r.stdout, r.stdout + r.stderr


def test_session_process_a_missing_record_directory_is_inconclusive(fake, tmp_path):
    e = process_env(fake, tmp_path, {}, EMPTY_ROSTER)
    e["SEAM_PROBE_PID_RECORDS"] = str(tmp_path / "nowhere")
    r = proc(fake, e)
    assert r.returncode == 3 and "cannot be listed" in r.stdout, r.stdout + r.stderr


def test_session_process_a_process_is_shown_despite_an_unreadable_record(fake, tmp_path):
    e = process_env(fake, tmp_path, {"1.json": "{not json", "2.json": {"pid": LIVE, "sessionId": UUID_A}}, "absent")
    assert proc(fake, e).returncode == 0


def test_session_process_an_unknown_uuid_is_inconclusive(fake, tmp_path):
    e = process_env(fake, tmp_path, {}, EMPTY_ROSTER, uuid=None)
    r = proc(fake, e)
    assert r.returncode == 3 and "no known full session id" in r.stdout, r.stdout + r.stderr


def install_plugin(env, hooks, manifest=None):
    """A worktrunk plugin as Claude Code records an install: installed_plugins.json naming its
    directory, whose hooks/hooks.json holds HOOKS (a WorktreeCreate timeout, or none)."""
    root = env["cfg"] / "plugins/cache/worktrunk/worktrunk/abc123"
    (root / "hooks").mkdir(parents=True, exist_ok=True)
    (root / ".claude-plugin").mkdir(exist_ok=True)
    (root / "hooks/hooks.json").write_text(json.dumps({"hooks": hooks}))
    (root / ".claude-plugin/plugin.json").write_text(json.dumps(manifest or {"name": "worktrunk"}))
    (env["cfg"] / "plugins/installed_plugins.json").write_text(json.dumps(
        {"version": 2, "plugins": {"worktrunk@worktrunk": [{"scope": "user", "installPath": str(root), "version": "abc123"}]}}))
    return root


def create_hook(timeout=None):
    h = {"type": "command", "command": "bash -c 'wt switch --create x'"}
    if timeout is not None:
        h["timeout"] = timeout
    return {"WorktreeCreate": [{"hooks": [h]}]}


def test_evidence_hook(fake):
    r = tool(fake, "evidence", "hook", "worktrunk@worktrunk", "WorktreeCreate")
    assert r.returncode == 3 and "INCONCLUSIVE" in r.stdout
    root = install_plugin(fake, create_hook(45))
    r = tool(fake, "evidence", "hook", "worktrunk@worktrunk", "WorktreeCreate")
    assert r.returncode == 0 and "timeout: 45 (declared)" in r.stdout and f"file: {root}/hooks/hooks.json" in r.stdout
    install_plugin(fake, create_hook())
    r = tool(fake, "evidence", "hook", "worktrunk@worktrunk", "WorktreeCreate")
    assert r.returncode == 0 and f"timeout: {sp.HOOK_DEFAULT_TIMEOUT} (none declared" in r.stdout
    assert tool(fake, "evidence", "hook", "worktrunk@worktrunk", "WorktreeRemove").returncode == 1
    # A manifest that holds the hooks inline wins over hooks/hooks.json.
    install_plugin(fake, create_hook(45), manifest={"name": "worktrunk", "hooks": create_hook(7)})
    r = tool(fake, "evidence", "hook", "worktrunk@worktrunk", "WorktreeCreate")
    assert "timeout: 7 (declared)" in r.stdout and "plugin.json" in r.stdout


# ---- exempt-remove, end to end against the fakes ------------------------------------------------

EXR = "seams/worktree-takeover/exr"


def test_exempt_remove_case(fake):
    shipped(fake)
    trust(fake, fake["sandbox"] / EXR)
    r = tool(fake, "run", "worktree-takeover", "exempt-remove", "--yes")
    assert r.returncode == 4 and "NOT-SEEN-RED" in r.stdout and "took the worktree off" in r.stdout, r.stdout + r.stderr
    (launch,) = [c for c in calls(fake) if "--bg" in c["argv"]]
    prompt = launch["argv"][-1]
    # The exempt removal is issued bare, its own numbered call; the control's output goes to a mark.
    assert "\n2. wt remove --no-hooks --foreground sp-remove\n" in prompt, prompt
    assert "1. wt remove --foreground sp-refuse > seam-probe-mark-refuse 2>&1" in prompt
    r = tool(fake, "red", "worktree-takeover", "exempt-remove", "--yes")
    assert r.returncode == 0 and " RED " in r.stdout and "denied, as the deny rule" in r.stdout, r.stdout
    r = tool(fake, "run", "worktree-takeover", "exempt-remove", "--yes")
    assert r.returncode == 0, r.stdout
    assert rows(fake) == [] and not (fake["sandbox"] / EXR).exists()


@pytest.mark.parametrize("extra,code,needle", [
    ({"FAKE_CLAUDE_SKIP": "--no-hooks"}, 3, "never issued"),
    ({"FAKE_CLAUDE_DENY": "^wt remove --no-hooks"}, 5, "stopped the exempt removal itself"),
    ({"FAKE_WT_NO_REFUSAL": "1"}, 3, "refusal control"),
])
def test_exempt_remove_readings(fake, extra, code, needle):
    shipped(fake)
    trust(fake, fake["sandbox"] / EXR)
    r = tool(fake, "run", "worktree-takeover", "exempt-remove", "--yes", extra_env=extra)
    assert r.returncode == code and needle in summary(fake), r.stdout


def test_exempt_remove_plant_without_the_deny_rule_is_blind(fake):
    shipped(fake)
    trust(fake, fake["sandbox"] / EXR)
    r = tool(fake, "red", "worktree-takeover", "exempt-remove", "--yes", extra_env={"FAKE_CLAUDE_DENY": "^never$"})
    assert r.returncode == 4 and "BLIND" in r.stdout and "the deny rule did not stop it" in r.stdout, r.stdout


def test_exempt_remove_skips_without_trust(fake):
    shipped(fake)
    r = tool(fake, "run", "worktree-takeover", "exempt-remove", "--yes")
    assert r.returncode == 6 and "&& claude" in summary(fake) and not calls(fake, "--bg"), r.stdout


# ---- bootstrap-timeout, end to end against the fakes -------------------------------------------

BTM = "seams/worktree-takeover/btm"


def btm(fake, timeout=2):
    shipped(fake)
    trust(fake, fake["sandbox"] / BTM)
    install_plugin(fake, create_hook(timeout))
    return fake


def test_bootstrap_timeout_case(fake):
    btm(fake)
    r = tool(fake, "run", "worktree-takeover", "bootstrap-timeout", "--yes")
    assert r.returncode == 4 and r.stdout.count("NOT-SEEN-RED") == 2, r.stdout + r.stderr
    s = summary(fake)
    # The timeout is the one the plugin declares, read from its file, and recorded in each reason.
    assert s.count("the 2s timeout (declared, plugin abc123, cache/worktrunk/worktrunk/abc123/hooks/hooks.json)") == 2, s
    assert str(fake["cfg"]) not in s
    assert "cache entries at the start: 0" in s and "cache entries at the start: 1" in s
    (launch,) = [c for c in calls(fake) if "--bg" in c["argv"]]
    a = launch["argv"]
    assert a[a.index("--model") + 1] == "sonnet" and a[-1].count("isolation parameter") == 1
    r = tool(fake, "red", "worktree-takeover", "bootstrap-timeout", "--yes")
    assert r.returncode == 0, r.stdout + r.stderr
    # install-past-timeout is read on the cold arm alone; control-fails on both.
    assert r.stdout.count(" RED ") == 3 and "timed out after 2s" in r.stdout, r.stdout
    assert tool(fake, "run", "worktree-takeover", "bootstrap-timeout", "--yes").returncode == 0
    assert rows(fake) == [] and not (fake["sandbox"] / BTM).exists()


@pytest.mark.parametrize("extra,code,needle", [
    ({"FAKE_BOOTSTRAP_NOCACHE": "1"}, 4, "the cache was not warm"),
    ({"FAKE_BOOTSTRAP_RC": "1"}, 3, "the install itself failed (exit 1)"),
])
def test_bootstrap_timeout_readings(fake, extra, code, needle):
    btm(fake)
    r = tool(fake, "run", "worktree-takeover", "bootstrap-timeout", "--yes", extra_env=extra)
    assert r.returncode == code and needle in summary(fake), r.stdout


def test_bootstrap_timeout_skips_without_the_plugin_or_its_grants(fake):
    shipped(fake)
    trust(fake, fake["sandbox"] / BTM)
    r = tool(fake, "run", "worktree-takeover", "bootstrap-timeout", "--yes")
    assert r.returncode == 6 and "plugin is not installed" in summary(fake), r.stdout
    install_plugin(fake, create_hook(2))
    r = tool(fake, "run", "worktree-takeover", "bootstrap-timeout", "--yes", extra_env={"FAKE_WT_UNAPPROVED": "1"})
    assert r.returncode == 6 and "config approvals add" in summary(fake) and not calls(fake, "--bg"), r.stdout


def test_bootstrap_timeout_is_heavy():
    data, errs = sp.load(SHIPPED / "worktree-takeover")
    assert not errs and sp.get_case(data, "bootstrap-timeout").get("heavy") is True


def test_red_of_a_heavy_case_waits_for_the_slot(env, tmp_path):
    d = make_suite(env, {"c": ('touch "$SEAM_PROBE_SUITE_DIR/ran"\n"$sp" verdict FAIL x\n', '"none"')})
    (d / "suite.toml").write_text((d / "suite.toml").read_text() + "heavy = true\n")
    fake = tmp_path / "bin"
    fake.mkdir()
    (fake / "fleet-slot").write_text("#!/bin/sh\necho 'held by someone-else'\nexit 1\n")
    (fake / "fleet-slot").chmod(0o755)
    r = tool(env, "red", "s", "c", "--yes", extra_env={"PATH": f"{fake}:{os.environ['PATH']}"})
    assert r.returncode == 6 and "someone-else" in r.stdout and not (d / "ran").exists(), r.stdout


# ---- session term ------------------------------------------------------------------------------

SLEEPER = "import time\nwhile True: time.sleep(0.05)"
DEAF = "import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nprint('ready', flush=True)\nwhile True: time.sleep(0.05)"


PROCS = []


@pytest.fixture(autouse=True)
def _reap_processes():
    yield
    while PROCS:
        pr = PROCS.pop()
        pr.kill()
        pr.wait()


def term_env(fake, tmp_path, code, session=True):
    """A real process running CODE, a pid record naming it for session `own`, and a ledger for it.
    Returns the process; a test waits for it."""
    pr = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True)
    PROCS.append(pr)
    if "ready" in code:
        assert pr.stdout.readline().strip() == "ready"
    e = process_env(fake, tmp_path, {"1.json": {"pid": pr.pid, "sessionId": UUID_A, "status": "idle"}} if session else {}, EMPTY_ROSTER)
    fake["env"].update(e)
    fake["env"]["SEAM_PROBE_TERM_WAIT"] = "0.6"
    return pr


def term(fake):
    return tool(fake, "session", "term", "own")


def ledger_kinds(fake, kind):
    return [json.loads(x) for x in Path(fake["env"]["SEAM_PROBE_RUN"]).read_text().splitlines() if json.loads(x).get("kind") == kind]


def test_session_term_sigterm_is_enough_then_rm_runs(fake, tmp_path):
    pr = term_env(fake, tmp_path, SLEEPER)
    r = term(fake)
    assert pr.wait(timeout=5) == -signal.SIGTERM
    assert r.returncode == 0 and "SIGTERM was enough" in r.stdout and "claude rm abc123 exit 0" in r.stdout, r.stdout + r.stderr
    assert [c["argv"] for c in calls(fake, "rm")] == [["rm", "abc123"]]
    t = ledger_kinds(fake, "session-term")
    assert len(t) == 1 and t[0]["pid"] == pr.pid and t[0]["killed"] is False and t[0]["rm_rc"] == 0


def test_session_term_a_process_that_ignores_term_gets_kill(fake, tmp_path):
    pr = term_env(fake, tmp_path, DEAF)
    r = term(fake)
    pr.wait(timeout=5)
    assert r.returncode == 0 and "SIGKILL was needed" in r.stdout, r.stdout + r.stderr
    assert pr.returncode == -signal.SIGKILL and ledger_kinds(fake, "session-term")[0]["killed"] is True
    assert len(calls(fake, "rm")) == 1


def test_session_term_without_a_live_pid_record_is_inconclusive_and_removes_nothing(fake, tmp_path):
    pr = term_env(fake, tmp_path, SLEEPER, session=False)
    r = term(fake)
    assert r.returncode == 3 and "no live pid record" in r.stdout, r.stdout + r.stderr
    assert not calls(fake, "rm") and pr.poll() is None   # nothing signaled, nothing removed
    assert not ledger_kinds(fake, "session-term")


def test_session_term_a_process_that_survives_kill_is_inconclusive(fake, tmp_path, monkeypatch, capsys):
    e = process_env(fake, tmp_path, {"1.json": {"pid": LIVE, "sessionId": UUID_A, "status": "idle"}}, EMPTY_ROSTER)
    for k, v in {**fake["env"], **e, "SEAM_PROBE_TERM_WAIT": "0.2"}.items():
        monkeypatch.setenv(k, v)
    sent = []
    # signals reach nothing; signal 0 is the existence probe (macOS), which finds the pid alive
    monkeypatch.setattr(sp.os, "kill", lambda pid, sig: sig and sent.append(sig))
    assert sp.main(["session", "term", "own"]) == 3
    assert "still present after SIGTERM and SIGKILL" in capsys.readouterr().out
    assert sent == [signal.SIGTERM, signal.SIGKILL] and not calls(fake, "rm")


def test_session_term_keeps_the_whole_rm_output_and_a_failed_rm_exits_1(fake, tmp_path):
    pr = term_env(fake, tmp_path, SLEEPER)
    fake["env"]["FAKE_CLAUDE_RM"] = "refuse-once"
    r = term(fake)
    pr.wait(timeout=5)
    assert r.returncode == 1 and "exit 1" in r.stdout, r.stdout + r.stderr
    kept = (Path(fake["env"]["SEAM_PROBE_RUN"]).parent / "session-case-own-rm.txt").read_text()
    assert "exit 1" in kept and "--force-remove-worktree wt-0042" in kept
    assert "WorktreeRemove hook failed" in ledger_kinds(fake, "session-rm")[0]["output"]


def test_session_term_is_listed_in_the_help():
    assert "session term NAME" in sp.EPILOG


def test_manual_without_a_terminal_is_refused_and_auto_records_it(fake, tmp_path):
    ledger = tmp_path / "m.jsonl"
    e = dict(fake["env"], SEAM_PROBE_RUN=str(ledger))
    r = subprocess.run([str(TOOL), "manual", "open it"], capture_output=True, text=True, env=e,
                       stdin=subprocess.DEVNULL, start_new_session=True, timeout=30)   # no controlling terminal
    assert r.returncode == 2 and "needs a terminal" in r.stderr and not ledger.exists(), r.stdout + r.stderr
    r = tool(fake, "manual", "open it", extra_env={"SEAM_PROBE_RUN": str(ledger), "SEAM_PROBE_MANUAL_AUTO": "1"})
    assert r.returncode == 0 and "MANUAL STEP: open it" in r.stdout, r.stdout + r.stderr
    assert json.loads(ledger.read_text())["text"] == "open it"



def run_on_a_pty(env, *args, answer=True, timeout=60):
    """Run the tool as a person does: its own session, with a pseudo-terminal as its controlling
    terminal and stdin/stdout. Enter is typed each time a manual step's prompt appears. Returns the
    exit status and what the terminal showed."""
    import fcntl, pty, select, termios
    master, slave = pty.openpty()
    def ctty():
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    pr = subprocess.Popen([str(TOOL), *args], stdin=slave, stdout=slave, stderr=slave,
                          env=env["env"], start_new_session=True, preexec_fn=ctty)
    os.close(slave)
    shown, answered, end = b"", 0, time.monotonic() + timeout
    while time.monotonic() < end:
        r, _, _ = select.select([master], [], [], 0.5)
        if r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            shown += chunk
            if answer and shown.count(b"press Enter when done") > answered:
                answered += 1
                os.write(master, b"\n")
        elif pr.poll() is not None:
            break
    pr.wait(timeout=10)
    os.close(master)
    return pr.returncode, shown.decode(errors="replace")


def test_a_manual_step_in_a_case_reaches_the_persons_terminal(env):
    # The case script runs in its own session, as every case does, so it has no controlling
    # terminal of its own: the prompt must still reach the person's terminal and read their Enter.
    body = '"$sp" manual "attach it" || { "$sp" verdict FAIL "the manual step was refused"; exit 0; }\n' \
           '"$sp" verdict PASS "the person answered"\n'
    make_suite(env, {"c": (body, '"none"')})
    _, shown = run_on_a_pty(env, "run", "s", "--yes")
    run_dir = max((env["state"] / "s").iterdir(), key=lambda p: p.name)
    summary = (run_dir / "summary.txt").read_text()
    # The verdict's reason says which branch the script took; a run never seen red reads
    # NOT-SEEN-RED whatever its verdict, so the reason is what is checked.
    assert "MANUAL STEP: attach it" in shown, shown
    assert "the person answered" in summary and "refused" not in summary, shown + summary


def test_manual_called_directly_on_a_terminal_reads_the_enter(env, tmp_path):
    # Outside a case there is no handed-down terminal and /dev/tty is opened; a text-mode "r+"
    # open of a tty is refused by Python, so this is the other path that must reach the person.
    ledger = tmp_path / "m.jsonl"
    rc, shown = run_on_a_pty({"env": dict(env["env"], SEAM_PROBE_RUN=str(ledger))}, "manual", "open it")
    assert rc == 0 and "MANUAL STEP: open it" in shown, shown
    assert json.loads(ledger.read_text())["text"] == "open it"

# ---- idle-holders, end to end against the fakes ------------------------------------------------
# The fake models the supervisor: with FAKE_CLAUDE_IDLE a session's pid record goes that many
# seconds after its last holder ended, and never while a background `sleep 9000` or a pending cron
# job holds it. The release command is shortened to `sleep 2` in a copy of the shipped suite, and
# the case's times are a tenth of a second to a few seconds.

IDL = "seams/session-lifecycle/idl"


def idle(fake, tmp_path, stop_after=None, idle_s=6, release_s=2, cap=40, records=None):
    suites = tmp_path / "idle-suites"
    shutil.copytree(SHIPPED / "session-lifecycle", suites / "session-lifecycle")
    toml = suites / "session-lifecycle/suite.toml"
    assert 'release = "sleep 900"' in toml.read_text()
    toml.write_text(toml.read_text().replace('release = "sleep 900"', f'release = "sleep {release_s}"'))
    recs = tmp_path / "pidrecs"
    recs.mkdir()
    for n, text in (records or {}).items():
        (recs / n).write_text(text)
    roster = tmp_path / "roster.json"
    roster.write_text(json.dumps({"workers": {}}))
    fake["env"].update({
        "SEAM_PROBE_SUITES": str(suites), "SEAM_PROBE_PID_RECORDS": str(recs), "SEAM_PROBE_DAEMON_ROSTER": str(roster),
        "FAKE_CLAUDE_LIVE_PID": str(os.getpid()), "FAKE_CLAUDE_IDLE": str(idle_s),
        "FAKE_CLAUDE_STOP_AFTER": json.dumps(stop_after or {}),
        "SEAM_PROBE_IDLE_POLL": "0.1", "SEAM_PROBE_IDLE_MARGIN": "1", "SEAM_PROBE_IDLE_CAP": str(cap)})
    trust(fake, fake["sandbox"] / IDL)
    return suites


def idle_run(fake, verb="run", extra_env=None):
    args = ["run", "session-lifecycle", "idle-holders"] if verb == "run" else ["red", "session-lifecycle", "idle-holders"]
    return tool(fake, *args, "--yes", extra_env=extra_env)


def idle_arms(fake, plant=None):
    run_dir = max((fake["state"] / "session-lifecycle").glob("2*"), key=lambda p: p.name)
    for line in (run_dir / "results.jsonl").read_text().splitlines():
        rec = json.loads(line)
        if rec["plant"] == plant:
            return {a["arm"]: (a["verdict"], a["reason"]) for a in rec["arms"]}, run_dir
    raise AssertionError("no record for plant " + str(plant))


def verdicts_of(arms):
    return {k: v[0] for k, v in arms.items()}


def test_idle_holders_pass_path(fake, tmp_path):
    idle(fake, tmp_path)
    r = idle_run(fake)
    arms, run_dir = idle_arms(fake)
    assert verdicts_of(arms) == {"control": "PASS", "shell": "PASS", "schedule": "PASS", "release": "PASS"}, r.stdout + str(arms)
    assert r.returncode == 4   # every PASS, none seen red yet
    assert "the idle stop was observed" in arms["control"][1] and "min after its first turn ended" in arms["shell"][1]
    assert "after its background command ended" in arms["release"][1]
    series = (run_dir / "session-idle-holders-poll-series.txt").read_text()
    assert "control=stopped" in series and "shell=running(idle)" in series
    # One launch per arm, each with its own prompt: the three holders are the shell, release and schedule sessions.
    launches = [c["argv"] for c in calls(fake) if "--bg" in c["argv"]]
    prompts = {a[a.index("-n") + 1].split("-")[2]: a[-1] for a in launches}
    assert set(prompts) == {"control", "shell", "schedule", "release"}
    assert "run_in_background" in prompts["shell"] and "1. sleep 9000" in prompts["shell"] and "1. sleep 2" in prompts["release"]
    assert "select:CronCreate" in prompts["schedule"] and '"recurring' not in prompts["schedule"] and "recurring set to false" in prompts["schedule"]
    assert "Do not use any tool" in prompts["control"]


def test_idle_holders_red_of_every_plant(fake, tmp_path):
    idle(fake, tmp_path, cap=25)
    r = idle_run(fake, "red")
    assert r.returncode == 0 and r.stdout.count(" RED ") == 6, r.stdout   # control-held reads on every arm
    holder, run_dir = idle_arms(fake, "holder-dropped")
    assert holder["shell"][0] == "FAIL" and "before the end of the run" in holder["shell"][1]
    assert idle_arms(fake, "schedule-dropped")[0]["schedule"][0] == "FAIL"
    held, _ = idle_arms(fake, "control-held")
    assert set(verdicts_of(held).values()) == {"VOID"} and "never stopped" in held["control"][1]
    # With the reds recorded, the run reads PASS and exits 0.
    assert idle_run(fake).returncode == 0


def test_idle_holders_control_that_never_stops_voids_every_arm(fake, tmp_path):
    idle(fake, tmp_path, stop_after={"control": None}, cap=6)
    r = idle_run(fake)
    arms, _ = idle_arms(fake)
    assert set(verdicts_of(arms).values()) == {"VOID"} and "the control was never stopped" in arms["shell"][1], arms
    assert r.returncode == 3


@pytest.mark.parametrize("who", ["shell", "schedule"])
def test_idle_holders_a_holder_stopped_early_fails_its_arm_only(fake, tmp_path, who):
    idle(fake, tmp_path, stop_after={who: 0.2})
    r = idle_run(fake)
    arms, _ = idle_arms(fake)
    want = {"control": "PASS", "shell": "PASS", "schedule": "PASS", "release": "PASS", who: "FAIL"}
    assert verdicts_of(arms) == want, arms
    assert "min after its first turn ended, before the end of the run" in arms[who][1] and r.returncode == 1


def test_idle_holders_release_stopped_while_its_command_ran_fails(fake, tmp_path):
    idle(fake, tmp_path, stop_after={"release": 0.2}, release_s=12)
    idle_run(fake)
    arms, _ = idle_arms(fake)
    assert arms["release"][0] == "FAIL" and "while its background command" in arms["release"][1], arms
    assert arms["shell"][0] == "PASS"


def test_idle_holders_release_never_stopping_fails(fake, tmp_path):
    idle(fake, tmp_path, stop_after={"release": None}, cap=20)
    idle_run(fake)
    arms, _ = idle_arms(fake)
    assert arms["release"][0] == "FAIL" and "still running at the end of the run" in arms["release"][1], arms
    assert arms["shell"][0] == "PASS"


@pytest.mark.parametrize("knob", ["FAKE_CLAUDE_CRON_RECURRING", "FAKE_CLAUDE_CRON_WRONG"])
def test_idle_holders_a_job_that_is_not_the_one_shot_asked_for_is_unmeasured(fake, tmp_path, knob):
    # A recurring job fires and so starts turns; a job for another time may fire inside the run.
    # Either way the arm would measure something else, so it is INCONCLUSIVE, never PASS.
    idle(fake, tmp_path)
    idle_run(fake, extra_env={knob: "1"})
    arms, _ = idle_arms(fake)
    assert arms["schedule"][0] == "INCONCLUSIVE" and "not an ok one-shot job" in arms["schedule"][1], arms["schedule"]
    assert arms["shell"][0] == "PASS"


def test_idle_holders_schedule_tool_unavailable_is_skipped(fake, tmp_path):
    idle(fake, tmp_path)
    r = idle_run(fake, extra_env={"FAKE_CLAUDE_NOCRON": "1"})
    arms, _ = idle_arms(fake)
    assert verdicts_of(arms) == {"control": "PASS", "shell": "PASS", "schedule": "SKIPPED", "release": "PASS"}, arms
    assert "no CronCreate tool was available" in arms["schedule"][1] and r.returncode == 6


def test_idle_holders_a_holder_never_made_is_inconclusive_not_failed(fake, tmp_path):
    idle(fake, tmp_path)
    r = idle_run(fake, extra_env={"FAKE_CLAUDE_SKIP": "sleep 9000"})
    arms, _ = idle_arms(fake)
    assert arms["shell"][0] == "INCONCLUSIVE" and 'never ran "sleep 9000"' in arms["shell"][1], arms
    assert arms["control"][0] == "PASS" and arms["release"][0] == "PASS"


def test_idle_holders_a_state_never_readable_leaves_every_arm_inconclusive(fake, tmp_path):
    idle(fake, tmp_path, records={"garbage.json": "{not json"}, cap=4)
    idle_run(fake, extra_env={"FAKE_CLAUDE_NORECORD": "1"})
    arms, run_dir = idle_arms(fake)
    assert set(verdicts_of(arms).values()) == {"INCONCLUSIVE"} and "could not be read at any poll" in arms["control"][1], arms
    assert "control=unreadable" in (run_dir / "session-idle-holders-poll-series.txt").read_text()


def test_idle_holders_a_control_that_becomes_unreadable_is_inconclusive_not_void(fake, tmp_path):
    # The control must be read as running at least once before the fake supervisor removes its pid
    # record (idle_s after launch), and then read as unreadable. Under load the setup before the
    # first poll ran past idle_s=6, so the control was never read and the verdict was a different
    # one: 15 failures in 20 runs beside a cold run of every other suite (2026-11-21, load 49-107).
    # idle_s=20 leaves the setup that room; the cap stays 10 s past it.
    idle(fake, tmp_path, records={"garbage.json": "{not json"}, idle_s=20, cap=30)
    idle_run(fake)
    arms, _ = idle_arms(fake)
    assert set(verdicts_of(arms).values()) == {"INCONCLUSIVE"} and "unreadable at the end" in arms["control"][1], arms


def test_idle_holders_a_command_not_run_in_the_background_is_inconclusive(fake, tmp_path):
    idle(fake, tmp_path)
    idle_run(fake, extra_env={"FAKE_CLAUDE_FOREGROUND": "1"})
    arms, _ = idle_arms(fake)
    assert arms["shell"][0] == "INCONCLUSIVE" and "not an ok background call" in arms["shell"][1], arms
    assert arms["release"][0] == "INCONCLUSIVE" and arms["control"][0] == "PASS"


def test_idle_holders_a_control_that_used_a_tool_voids_every_arm(fake, tmp_path):
    idle(fake, tmp_path)
    idle_run(fake, extra_env={"FAKE_CLAUDE_CONTROL_CALL": "1"})
    arms, _ = idle_arms(fake)
    assert set(verdicts_of(arms).values()) == {"VOID"} and "the control made tool calls" in arms["shell"][1], arms


def test_idle_holders_a_first_turn_that_never_finishes_is_inconclusive(fake, tmp_path):
    idle(fake, tmp_path)
    idle_run(fake, extra_env={"FAKE_CLAUDE_REPLY": "still thinking", "SEAM_PROBE_SESSION_WAIT": "2"})
    arms, _ = idle_arms(fake)
    assert set(verdicts_of(arms).values()) == {"INCONCLUSIVE"} and "first turn did not finish" in arms["control"][1], arms


def test_idle_holders_a_run_cut_short_of_the_margin_cannot_pass_a_holder(fake, tmp_path):
    idle(fake, tmp_path, cap=14)
    idle_run(fake, extra_env={"SEAM_PROBE_IDLE_MARGIN": "600"})
    arms, _ = idle_arms(fake)
    assert arms["control"][0] == "PASS"
    assert arms["shell"][0] == "INCONCLUSIVE" and "ended too soon" in arms["shell"][1], arms
    assert arms["schedule"][0] == "INCONCLUSIVE"


def test_idle_holders_skips_without_trust(fake, tmp_path):
    idle(fake, tmp_path)
    trust(fake)
    r = idle_run(fake)
    assert r.returncode == 6 and "Claude Code's trust" in r.stdout and not calls(fake, "--bg"), r.stdout
    assert (fake["sandbox"] / IDL / ".git").exists()


# ---- attached-stop, end to end against the fakes -----------------------------------------------
# Each session is a real process the fake's pid record names (FAKE_CLAUDE_SPAWN), so `session term`
# really signals it. The watch is 2 s: a planted sign of return comes 0.3 s after the stop, and a
# 0.6 s watch missed it once under a full 8-wide suite run (2026-11-22), so the watch keeps a wide
# margin over the sign. `manual` records its instruction and goes on
# (SEAM_PROBE_MANUAL_AUTO), where a person would attach a client and press Enter.

ATS = "seams/session-lifecycle/ats"


def ats(fake, tmp_path, watch="2", roster=True, **env):
    suites = tmp_path / "ats-suites"
    shutil.copytree(SHIPPED / "session-lifecycle", suites / "session-lifecycle")
    recs = tmp_path / "pidrecs"
    recs.mkdir()
    roster_f = tmp_path / "roster.json"
    if roster:
        roster_f.write_text(json.dumps({"workers": {}}))
    fake["env"].update({"SEAM_PROBE_SUITES": str(suites), "SEAM_PROBE_PID_RECORDS": str(recs), "SEAM_PROBE_DAEMON_ROSTER": str(roster_f),
                        "FAKE_CLAUDE_SPAWN": "1", "SEAM_PROBE_MANUAL_AUTO": "1", "SEAM_PROBE_RESPAWN_WATCH": watch,
                        "SEAM_PROBE_TERM_WAIT": "0.5", **env})
    trust(fake, fake["sandbox"] / ATS)


def ats_run(fake, verb="run", extra_env=None):
    return tool(fake, verb, "session-lifecycle", "attached-stop", "--yes", extra_env=extra_env)


def ats_ledger(run_dir, plant=None):
    f = run_dir / ("ledger-attached-stop%s.jsonl" % ("-" + plant if plant else ""))
    return [json.loads(x) for x in f.read_text().splitlines()]


def test_attached_stop_pass_path(fake, tmp_path):
    ats(fake, tmp_path)
    r = ats_run(fake)
    arms, run_dir = idle_arms(fake)
    assert verdicts_of(arms) == {"control": "PASS", "terminal": "PASS", "agentview": "PASS"}, r.stdout + str(arms)
    assert r.returncode == 4   # every PASS, none seen red yet
    for a in ("terminal", "agentview"):
        assert "confirmed by the person at the terminal, not observed by the instrument" in arms[a][1]
    # Each arm was stopped as the fleet stops one: a term, then a rm of its id, control first.
    assert len(calls(fake, "rm")) == 3
    led = ats_ledger(run_dir)
    assert [e["name"] for e in led if e["kind"] == "session-term"] == ["control", "terminal", "agentview"]
    # The person is told the real id to attach, the display name to select, and asked to look after each watch.
    manual = [e["text"] for e in led if e["kind"] == "manual"]
    sess = {}
    for e in led:
        if e["kind"] == "session":
            sess.setdefault(e["name"], {}).update(e)
    assert len(manual) == 4
    assert "claude attach " + sess["terminal"]["id"] in manual[0] and "claude agents" in manual[1] and sess["agentview"]["display"] in manual[1]
    assert "look at the attached terminal" in manual[2] and "agent view" in manual[3] and all("Enter" in m for m in manual)
    series = (run_dir / "session-attached-stop-watch.txt").read_text()
    assert "control +" in series and "process=absent" in series and "listed=no" in series and "transcript=" in series


def test_attached_stop_red_of_every_plant(fake, tmp_path):
    ats(fake, tmp_path)
    r = ats_run(fake, "red")
    assert r.returncode == 0 and r.stdout.count(" RED ") >= 2, r.stdout
    arms, run_dir = idle_arms(fake, "respawn")
    assert verdicts_of(arms) == {"control": "PASS", "terminal": "FAIL", "agentview": "PASS"}, arms
    assert "a process for its session uuid" in arms["terminal"][1]
    voided, rd2 = idle_arms(fake, "control-respawn")
    assert set(verdicts_of(voided).values()) == {"VOID"} and "an unattached session came back after the stop too" in voided["control"][1]
    # The plant resumed the stopped session under a new id, which the ledger holds so cleanup removes it.
    led = ats_ledger(run_dir, "respawn")
    assert any(e["kind"] == "session-resume" and e["name"] == "terminal" for e in led)
    assert any(e["kind"] == "session" and e["name"] == "terminal-resume1" for e in led)
    assert not rows(fake)   # every session is gone, the resumed copy too
    # The manual steps ran under the plant as well.
    assert sum(e["kind"] == "manual" for e in led) == 4
    assert ats_run(fake).returncode == 0   # with the reds recorded, the run reads PASS


@pytest.mark.parametrize("knob,sign", [
    ({"FAKE_CLAUDE_RESPAWN": '{"terminal": 0.3}'}, "a process for its session uuid"),
    ({"FAKE_CLAUDE_GROW": '{"terminal": 0.3}'}, "new lines in its transcript"),
    ({"FAKE_CLAUDE_RM_KEEP": '["terminal"]'}, "a listed row for its id or uuid"),
], ids=["process", "transcript", "listing"])
def test_attached_stop_a_sign_of_return_in_one_arm_fails_that_arm_only(fake, tmp_path, knob, sign):
    ats(fake, tmp_path, **knob)
    r = ats_run(fake)
    arms, _ = idle_arms(fake)
    assert verdicts_of(arms) == {"control": "PASS", "terminal": "FAIL", "agentview": "PASS"}, arms
    assert sign in arms["terminal"][1] and " s after the stop" in arms["terminal"][1] and r.returncode == 1
    assert "while the control stayed stopped" in arms["terminal"][1]


def test_attached_stop_a_control_that_comes_back_voids_every_arm(fake, tmp_path):
    ats(fake, tmp_path, FAKE_CLAUDE_RESPAWN='{"control": 0.3}')
    r = ats_run(fake)
    arms, _ = idle_arms(fake)
    assert set(verdicts_of(arms).values()) == {"VOID"} and "cannot be laid to attachment" in arms["agentview"][1], arms
    assert r.returncode == 3


def test_attached_stop_a_session_that_needs_kill_is_still_stopped_and_read(fake, tmp_path):
    ats(fake, tmp_path, FAKE_CLAUDE_TERM="ignore")
    r = ats_run(fake)
    arms, run_dir = idle_arms(fake)
    assert set(verdicts_of(arms).values()) == {"PASS"}, arms
    assert "SIGKILL was needed" in (run_dir / "session-attached-stop-watch.txt").read_text()


def test_attached_stop_a_term_that_cannot_run_leaves_that_arm_inconclusive(fake, tmp_path):
    ats(fake, tmp_path, FAKE_CLAUDE_NOSPAWN='["terminal"]')
    r = ats_run(fake)
    arms, run_dir = idle_arms(fake)
    assert verdicts_of(arms) == {"control": "PASS", "terminal": "INCONCLUSIVE", "agentview": "PASS"}, arms
    assert "no live pid record" in arms["terminal"][1] and "could not be stopped as the fleet stops one" in arms["terminal"][1]
    # The look the person is asked for follows a watch, so an arm that was not watched asks for none.
    assert sum(e["kind"] == "manual" for e in ats_ledger(run_dir)) == 3


def test_attached_stop_an_unmeasured_control_leaves_every_arm_inconclusive(fake, tmp_path):
    ats(fake, tmp_path, FAKE_CLAUDE_NOSPAWN='["control"]', FAKE_CLAUDE_RESPAWN='{"terminal": 0.3}')
    r = ats_run(fake)
    arms, _ = idle_arms(fake)
    assert set(verdicts_of(arms).values()) == {"INCONCLUSIVE"} and "control could not be measured" in arms["terminal"][1], arms


def test_attached_stop_a_sign_never_read_leaves_the_arm_inconclusive_not_passed(fake, tmp_path):
    ats(fake, tmp_path, roster=False)   # with no daemon roster, "no process" can never be told from "unreadable"
    r = ats_run(fake)
    arms, _ = idle_arms(fake)
    assert set(verdicts_of(arms).values()) == {"INCONCLUSIVE"}, arms
    assert "process could not be read at any poll" in arms["control"][1], arms


def test_attached_stop_without_a_terminal_the_attached_arms_are_inconclusive(fake, tmp_path):
    ats(fake, tmp_path, SEAM_PROBE_MANUAL_AUTO="0")   # the case runs with no controlling terminal
    r = ats_run(fake)
    arms, _ = idle_arms(fake)
    assert verdicts_of(arms) == {"control": "PASS", "terminal": "INCONCLUSIVE", "agentview": "INCONCLUSIVE"}, arms
    assert "needs a terminal" in arms["terminal"][1] or "could not be asked" in arms["terminal"][1]


def test_attached_stop_a_first_turn_that_never_finishes_is_inconclusive(fake, tmp_path):
    ats(fake, tmp_path, FAKE_CLAUDE_REPLY="hmm", SEAM_PROBE_SESSION_WAIT="1")
    r = ats_run(fake)
    arms, _ = idle_arms(fake)
    assert set(verdicts_of(arms).values()) == {"INCONCLUSIVE"} and "no DONE" in arms["control"][1], arms


def test_attached_stop_skips_without_trust(fake, tmp_path):
    ats(fake, tmp_path)
    trust(fake)
    r = ats_run(fake)
    assert r.returncode == 6 and "Claude Code's trust" in r.stdout and not calls(fake, "--bg"), r.stdout
    assert (fake["sandbox"] / ATS / ".git").exists()


if __name__ == "__main__":
    # pytest-xdist runs the tests on several workers. Most of this suite's time is waiting on the
    # fake claude's idle caps and polls, not CPU: run one at a time it was 515 s of the base's 684 s
    # cold run (measured 2026-11-21). Every test's state is under its own tmp_path,
    # which xdist makes per worker. A `-n` given on the command line comes later and wins.
    workers = str(min(8, os.cpu_count() or 2))
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider", "-n", workers, *sys.argv[1:]]))
