#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for seam-probe. Every suite here is a scratch directory of tiny case scripts, and every
fixture lives under a temp sandbox root, so nothing touches a real repository or starts Claude
Code. The worktree-takeover suite this base ships is linted here too."""
import importlib.machinery
import importlib.util
import json
import os
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
    e = dict(os.environ, SEAM_PROBE_SUITES=str(suites), SEAM_PROBE_SANDBOX=str(sandbox),
             SEAM_PROBE_STATE=str(state), HOME=os.environ.get("HOME", str(tmp_path)))
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
import json, os, re, secrets, shlex, shutil, subprocess, sys, uuid
from pathlib import Path
st = Path(os.environ["FAKE_CLAUDE_STATE"]); st.mkdir(parents=True, exist_ok=True)
rows_f = st / "rows.json"
rows = json.loads(rows_f.read_text()) if rows_f.exists() else []
argv = sys.argv[1:]
stdin = sys.stdin.read() if "-p" in argv else None
proj = Path.cwd() / ".claude/settings.json"
with open(st / "calls.jsonl", "a") as f:
    f.write(json.dumps({"argv": argv, "cwd": os.getcwd(), "stdin": stdin,
                        "project_settings": json.loads(proj.read_text()) if proj.is_file() else None}) + "\n")
def save(): rows_f.write_text(json.dumps(rows))
def opt(flags, name): return flags[flags.index(name) + 1] if name in flags else None
if argv[:1] == ["--version"]:
    print("9.9.9 (Claude Code)"); sys.exit(0)
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
    for line in prompt.splitlines():
        m = re.match(r"^\d+\. (.*)$", line)
        if not m: continue
        cmd = m.group(1)
        c = re.search(r"git -C (\S+)", cmd)
        target = Path(shlex.split(c.group(1))[0]) if c else run_in
        if not any(target == a or a in target.parents for a in allowed):
            mark = re.search(r"> (\S+) 2>&1", cmd).group(1)
            (run_in / mark).write_text("fatal: unable to write new index file: Read-only file system\n")
            continue
        subprocess.run(["sh", "-c", cmd], cwd=run_in, check=False)
    rows.append({"id": sid, "sessionId": u, "name": opt(flags, "-n"), "cwd": str(run_in), "state": "working",
                 "kind": "background", "startedAt": len(rows)}); save()
    t = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(run_in))
    t.mkdir(parents=True, exist_ok=True)
    (t / (u + ".jsonl")).write_text(json.dumps({"type": "user", "message": {"content": prompt}}) + "\n" + json.dumps(
        {"type": "assistant", "message": {"content": [{"type": "text", "text": os.environ.get("FAKE_CLAUDE_REPLY", "DONE")}]}}) + "\n")
    if not os.environ.get("FAKE_CLAUDE_NOID"): print("backgrounded · " + sid)
    sys.exit(0)
print("fake claude: unhandled", argv, file=sys.stderr); sys.exit(2)
"""

FAKE_WT = """#!/bin/sh
case "$*" in
  *--version*) echo "wt v0.0.0" ;;
  *"config approvals list"*)
    if [ -n "${FAKE_WT_UNAPPROVED:-}" ]; then
      printf 'APPROVED\\n  (none)\\n\\nUNAPPROVED\\n  post-start:\\n  touch seam-probe-setup-ran\\n'
    else
      printf 'APPROVED\\n  post-start:\\n  touch seam-probe-setup-ran\\n\\nUNAPPROVED\\n  (none)\\n'
    fi ;;
  *) exit 2 ;;
esac
"""


@pytest.fixture
def fake(env, tmp_path):
    """env, with a fake claude and wt first on PATH and Claude Code's state in a temp directory."""
    bin_ = tmp_path / "fakebin"
    bin_.mkdir()
    for n, body in (("claude", FAKE_CLAUDE), ("wt", FAKE_WT)):
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
    assert (d / "rc").read_text().strip() == "rc=2" and not [c for c in calls(fake) if c["argv"] != ["--version"]]


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
    r = tool(fake, "trust", "worktree-takeover")
    assert f"left in place: {repo}" in r.stdout


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))
