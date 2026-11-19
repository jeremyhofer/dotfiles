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
import json, os, re, secrets, shlex, shutil, signal, subprocess, sys, uuid
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
    events = []
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
    else:
        run_cmds(prompt, run_in, allowed)
    rows.append({"id": sid, "sessionId": u, "name": opt(flags, "-n"), "cwd": str(run_in), "state": "working",
                 "kind": "background", "startedAt": len(rows)}); save()
    t = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(run_in))
    t.mkdir(parents=True, exist_ok=True)
    lines = [{"type": "user", "message": {"content": prompt}}, *events,
             {"type": "assistant", "message": {"content": [{"type": "text", "text": os.environ.get("FAKE_CLAUDE_REPLY", "DONE")}]}}]
    (t / (u + ".jsonl")).write_text("".join(json.dumps(x) + "\n" for x in lines))
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


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider", *sys.argv[1:]]))
