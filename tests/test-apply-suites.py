#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for tests/apply-suites.py, which runs the suites through Nx around `chezmoi apply`, and for
its two chezmoi hooks, tests/pre-apply.sh and tests/post-apply.sh.

Run: sh tests/run-all.sh --only test-apply-suites.py
 or: uv run --script tests/test-apply-suites.py [-k <pattern>]

What is held: `pre` runs `nx run-many -t test` under the Node the repository pins (mise.toml's
`[tools] node`, else .nvmrc; both present must agree, or the apply is refused naming both): through
mise where mise is active (DOTFILES_MISE_SHIMS set, and mise on PATH) with its installing and
network access off, else through fnm, else a node on PATH of the pinned major. It runs `npm ci` only when node_modules does not hold what
package-lock.json names, gives Nx no socket to open, removes chezmoi's CHEZMOI_* variables, and
aborts the apply on a failure, naming the suite, the log and how to re-run it. Node that is missing
or of the wrong version refuses the apply; a skip switch or a missing suite tool skips it, loudly.
`post` returns at once while an uncached run goes on detached, one at a time, with a status file,
a bounded set of logs and the alert hook on a failure. The generated chezmoi config names both hooks.

Everything runs in a scratch copy: the script beside a stand-in `node_modules/.bin/nx` that records
how it was called and prints a canned Nx log, and a PATH of stand-ins for fnm, node, npm and the
tools the suites need (and, where a test adds it, for mise), so no suite, no install and no apply
runs, and the machine's own mise and fnm are never reached. Each refusal has a control beside
it that the same rig passes.
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SRC = HERE.parent
PIN = "26.13.0"
OTHER = "26.14.1"

# Nx's static output, as `nx run-many -t test --outputStyle=static` writes it (shortened).
NX_PASS = """
> nx run suite-good:test  [local cache]

PASS   test-good.sh

 NX   Successfully ran target test for 2 projects (1s)

Nx read the output from the cache instead of running the command for 1 out of 2 tasks.
"""
NX_FAIL = """
> nx run suite-good:test

PASS   test-good.sh

> nx run suite-broken:test

FAIL   test-broken.sh (exit 1)
       | the reason it failed

 NX   Ran target test for 2 projects (1s)

   ✔  1/2 succeeded [0 read from cache]

   ✖  1/2 targets failed, including the following:

      - suite-broken:test

Failed tasks:

- suite-broken:test
"""

LOCK = {
    "name": "dotfiles-base",
    "lockfileVersion": 3,
    "requires": True,
    "packages": {
        "": {"name": "dotfiles-base", "devDependencies": {"nx": "24.0.5"}},
        "node_modules/nx": {"version": "24.0.5", "dev": True},
        "node_modules/@nx/nx-linux-x64-gnu": {"version": "24.0.5", "dev": True, "optional": True},
        "node_modules/@nx/nx-darwin-arm64": {"version": "24.0.5", "dev": True, "optional": True},
    },
}


def installed_record(lock: dict) -> dict:
    """What npm writes to node_modules/.package-lock.json: no root entry, no other platform's binary."""
    packages = {k: v for k, v in lock["packages"].items() if k and "darwin" not in k}
    return {k: v for k, v in lock.items() if k != "packages"} | {"packages": packages}


def stub(path: Path, body: str) -> None:
    path.write_text(f"#!{sys.executable}\nimport os, sys, json, time\n{body}")
    path.chmod(0o755)


class Rig:
    def __init__(self, root: Path):
        self.root = root
        self.src = root / "src"
        self.bin = root / "bin"
        self.rec = root / "rec"
        for d in (self.src / "tests", self.bin, self.rec, root / "logs", root / "state",
                  root / "cfg" / "dotfiles", root / "home", self.src / "node_modules" / ".bin",
                  root / "nodebin"):
            d.mkdir(parents=True, exist_ok=True)
        shutil.copy(HERE / "apply-suites.py", self.src / "tests" / "apply-suites.py")
        shutil.copy(HERE / "pre-apply.sh", self.src / "tests" / "pre-apply.sh")
        shutil.copy(HERE / "post-apply.sh", self.src / "tests" / "post-apply.sh")
        shutil.copy(HERE / "seed-uv-cache.py", self.src / "tests" / "seed-uv-cache.py")
        (self.src / "tests" / "test-uv.py").write_text("#!/usr/bin/env -S uv run --script\n")
        tool = self.src / "private_dot_local" / "bin"
        tool.mkdir(parents=True)
        shutil.copy(SRC / "private_dot_local" / "bin" / "executable_apply-status", tool)
        for name in ("test-good.sh", "test-broken.sh"):
            (self.src / "tests" / name).write_text("#!/bin/sh\nexit 0\n")
        (self.src / ".nvmrc").write_text(PIN + "\n")
        (self.src / ".gitignore").write_text("node_modules/\n")
        self.write_lock(LOCK)
        self.write_installed(installed_record(LOCK))
        self.nx_out = root / "nx.out"
        self.nx_out.write_text(NX_PASS)
        # The stand-in Nx: records its argv, the environment it got, the Node it ran under, then
        # prints the canned log and exits NX_STUB_RC. With NX_STUB_HOLD it waits for the release file.
        stub(self.src / "node_modules" / ".bin" / "nx", f"""
rec = {str(self.rec)!r}
with open(os.path.join(rec, "nx.calls"), "a") as f:
    f.write(json.dumps({{"argv": sys.argv[1:], "env": dict(os.environ),
                        "seeded": os.path.exists(os.path.join(rec, "uv.calls")),
                        "ledger": open({str(root / "state" / "dotfiles" / "apply.log")!r}).read()
                                  if os.path.exists({str(root / "state" / "dotfiles" / "apply.log")!r}) else ""}}) + "\\n")
if os.environ.get("NX_STUB_DIRTY"):
    open({str(self.src / "dirtied")!r}, "w").write("x")
if os.environ.get("NX_STUB_HOLD"):
    while not os.path.exists({str(root / "release")!r}):
        time.sleep(0.05)
sys.stdout.write(open({str(self.nx_out)!r}).read())
sys.exit(int(os.environ.get("NX_STUB_RC", "0")))
""")
        # The stand-in fnm: `fnm exec --using=V -- cmd ...` runs cmd with the stand-in node first on
        # PATH, reporting V, when V is in FNM_INSTALLED; otherwise fails as fnm does.
        stub(self.bin / "fnm", f"""
args = sys.argv[1:]
assert args[0] == "exec" and args[1].startswith("--using=") and args[2] == "--", args
v = args[1][len("--using="):]
if v not in os.environ.get("FNM_INSTALLED", "").split():
    sys.stderr.write(f"error: Requested version v{{v}} is not currently installed\\n")
    sys.exit(1)
os.environ["NODE_VERSION"] = v
os.environ["FNM_USED"] = v
os.environ["PATH"] = {str(root / "nodebin")!r} + os.pathsep + os.environ["PATH"]
os.execvp(args[3], args[3:])
""")
        for d in (self.bin, root / "nodebin"):
            stub(d / "node", 'print("v" + os.environ.get("NODE_VERSION", "0.0.0"))\n')
            # The stand-in npm: records each call; `ci` writes the install record npm would.
            stub(d / "npm", f"""
with open(os.path.join({str(self.rec)!r}, "npm.calls"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")
if sys.argv[1:2] == ["ci"]:
    if os.environ.get("NPM_STUB_RC", "0") != "0":
        print("npm error: the install failed")
        sys.exit(int(os.environ["NPM_STUB_RC"]))
    lock = json.load(open("package-lock.json"))
    pk = {{k: v for k, v in lock["packages"].items() if k and "darwin" not in k}}
    os.makedirs("node_modules", exist_ok=True)
    json.dump(dict(lock, packages=pk), open("node_modules/.package-lock.json", "w"))
""")
        # The stand-in uv records each call and exits UV_STUB_RC (seeding with it set fails).
        stub(self.bin / "uv", f"""
with open(os.path.join({str(self.rec)!r}, "uv.calls"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")
sys.exit(int(os.environ.get("UV_STUB_RC", "0")))
""")
        for tool in ("jq", "yq", "gitleaks", "wt"):
            stub(self.bin / tool, "sys.exit(0)\n")
        os.symlink(sys.executable, self.bin / "python3")
        os.symlink(shutil.which("git"), self.bin / "git")
        os.symlink(shutil.which("dirname"), self.bin / "dirname")
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "one")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.src), "-c", "user.name=t", "-c", "user.email=t@t",
                               "-c", "commit.gpgsign=false", *args], env=self.env(), check=True,
                              capture_output=True, text=True).stdout

    def write_lock(self, lock: dict) -> None:
        (self.src / "package-lock.json").write_text(json.dumps(lock))

    def write_installed(self, record: dict) -> None:
        (self.src / "node_modules" / ".package-lock.json").write_text(json.dumps(record))

    def env(self, **extra: str) -> dict:
        env = {
            "PATH": str(self.bin),
            "HOME": str(self.root / "home"),
            "TMPDIR": str(self.root / "logs"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "XDG_CONFIG_HOME": str(self.root / "cfg"),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "FNM_INSTALLED": PIN,
            "CHEZMOI": "1",
            "CHEZMOI_ARGS": "chezmoi apply",
        }
        env.update(extra)
        return {k: v for k, v in env.items() if v is not None}

    def run(self, *args: str, **extra: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(self.src / "tests" / "apply-suites.py"), *args],
                              env=self.env(**extra), capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=60)

    def nx_calls(self) -> list:
        f = self.rec / "nx.calls"
        return [json.loads(line) for line in f.read_text().splitlines()] if f.exists() else []

    def npm_calls(self) -> list:
        f = self.rec / "npm.calls"
        return f.read_text().splitlines() if f.exists() else []

    def drop_fnm(self) -> None:
        (self.bin / "fnm").unlink()

    def write_mise_toml(self, node: str) -> None:
        (self.src / "mise.toml").write_text(f'[tools]\nnode = "{node}"\npython = "3.15.2"\n')

    def add_mise(self) -> None:
        """The stand-in mise: `mise exec node@V -- cmd ...` records its argv and environment, then
        runs cmd with the stand-in node first on PATH, reporting V, when V is in MISE_INSTALLED.
        Otherwise it does what mise 2026.11.5 did with installing switched off (measured in scratch
        mise directories): a warning, then cmd on the PATH it was given. Anything else fails."""
        stub(self.bin / "mise", f"""
args = sys.argv[1:]
with open(os.path.join({str(self.rec)!r}, "mise.calls"), "a") as f:
    f.write(json.dumps({{"argv": args, "env": dict(os.environ)}}) + "\\n")
if len(args) < 4 or args[0] != "exec" or not args[1].startswith("node@") or args[2] != "--":
    sys.stderr.write(f"stub mise: unexpected call {{args}}\\n")
    sys.exit(2)
v = args[1][len("node@"):]
if v in os.environ.get("MISE_INSTALLED", "").split():
    os.environ["NODE_VERSION"] = v
    os.environ["MISE_USED"] = v
    os.environ["PATH"] = {str(self.root / "nodebin")!r} + os.pathsep + os.environ["PATH"]
else:
    sys.stderr.write(f"mise WARN  node@{{v}} is not installed and auto-install is disabled, so mise "
                     f"looks for node on PATH instead. Install it with: mise install node@{{v}}\\n")
os.execvp(args[3], args[3:])
""")

    def mise_call_list(self) -> list:
        f = self.rec / "mise.calls"
        return [json.loads(line) for line in f.read_text().splitlines()] if f.exists() else []

    def mise_calls(self) -> list:
        return [c["argv"] for c in self.mise_call_list()]

    def mise_call_envs(self) -> list:
        return [c["env"] for c in self.mise_call_list()]

    def run_without_tomllib(self, *args: str, **extra: str) -> subprocess.CompletedProcess:
        """The script under a Python that cannot import tomllib, as Python 3.9 cannot."""
        script = str(self.src / "tests" / "apply-suites.py")
        boot = ("import runpy, sys; sys.modules['tomllib'] = None; "
                f"sys.argv = [{script!r}] + sys.argv[1:]; runpy.run_path({script!r}, run_name='__main__')")
        return subprocess.run([sys.executable, "-c", boot, *args], env=self.env(**extra),
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)

    @property
    def status(self) -> Path:
        return self.root / "state" / "dotfiles" / "post-apply.last"

    @property
    def ledger_file(self) -> Path:
        return self.root / "state" / "dotfiles" / "apply.log"

    def ledger(self) -> list:
        """The apply ledger as (instance, event, head, detail) rows."""
        if not self.ledger_file.exists():
            return []
        rows = [ln.split("\t") for ln in self.ledger_file.read_text().splitlines()]
        return [(r[2], r[3], r[4], r[6]) for r in rows]

    def events(self) -> list:
        return [r[1] for r in self.ledger()]

    def alert_stub(self) -> Path:
        alert = self.root / "cfg" / "dotfiles" / "alert"
        stub(alert, f"open({str(self.rec / 'alert')!r}, 'a').write(sys.argv[1] + '\\n')\n")
        return self.rec / "alert"

    def slow_alert(self) -> None:
        """An alert hook that does not return until the test releases it (or 15 s pass)."""
        alert = self.root / "cfg" / "dotfiles" / "alert"
        stub(alert, f"for _ in range(300):\n    if os.path.exists({str(self.root / 'release')!r}): break\n"
                    f"    time.sleep(0.05)\n")

    def wait_text(self, path: Path, seconds: float = 20) -> str:
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if path.exists() and path.read_text():
                return path.read_text()
            time.sleep(0.05)
        return path.read_text() if path.exists() else ""

    @property
    def lock(self) -> Path:
        return self.src / ".git" / "post-apply.lock"

    def wait_for(self, path: Path, seconds: float = 20) -> bool:
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if path.exists():
                return True
            time.sleep(0.05)
        return path.exists()

    def wait_idle(self, seconds: float = 20) -> None:
        end = time.monotonic() + seconds
        while self.lock.exists() and time.monotonic() < end:
            time.sleep(0.05)


@pytest.fixture
def rig(tmp_path):
    r = Rig(tmp_path)
    yield r
    # A detached run still holding is released and waited for, so none outlives the test.
    (tmp_path / "release").touch()
    r.wait_idle()


# --- pre: the run ----------------------------------------------------------------------------------

def test_pre_runs_every_suite_target_through_nx_under_the_pinned_node(rig):
    out = rig.run("pre")
    assert out.returncode == 0, out.stderr
    [call] = rig.nx_calls()
    assert call["argv"] == ["run-many", "-t", "test", "--outputStyle=static"]
    assert call["env"].get("FNM_USED") == PIN, "Nx did not run under fnm's pinned Node"
    assert "Successfully ran target test for 2 projects" in out.stderr
    assert "read the output from the cache instead of running the command for 1 out of 2" in out.stderr
    assert f"Node v{PIN} via fnm" in out.stderr
    assert not list((rig.root / "logs").iterdir()), "a passing run's log is removed"


def test_pre_gives_nx_no_socket_to_open_and_the_runner_s_concurrency(rig):
    rig.run("pre")
    env = rig.nx_calls()[0]["env"]
    assert env["NX_DAEMON"] == "false"
    assert env["NX_ISOLATE_PLUGINS"] == "false"
    assert env["NX_TUI"] == "false"
    assert 1 <= int(env["NX_PARALLEL"]) <= 8


def test_pre_keeps_a_concurrency_the_caller_set(rig):
    rig.run("pre", NX_PARALLEL="2")
    assert rig.nx_calls()[0]["env"]["NX_PARALLEL"] == "2"


def test_pre_removes_chezmoi_s_variables(rig):
    rig.run("pre", CHEZMOI="1", CHEZMOI_SOURCE_DIR="/somewhere")
    env = rig.nx_calls()[0]["env"]
    assert not [k for k in env if k.startswith("CHEZMOI")]


def test_a_failing_suite_aborts_the_apply_naming_it_and_its_log(rig):
    rig.nx_out.write_text(NX_FAIL)
    out = rig.run("pre", NX_STUB_RC="1")
    assert out.returncode == 1
    assert "apply ABORTED, nothing was deployed" in out.stderr
    assert "FAIL   test-broken.sh (exit 1)" in out.stderr
    assert f"run-all.sh --only test-broken.sh" in out.stderr
    assert "the reason it failed" not in out.stderr, "the suite's own output stays in the log"
    log = Path(out.stderr.split("why, in full: ")[1].split()[0])
    assert "the reason it failed" in log.read_text()


def test_an_nx_failure_with_no_suite_named_still_aborts_and_shows_why(rig):
    rig.nx_out.write_text("Error: suites plugin: tests/coverage.map:3: a line with no globs\n")
    out = rig.run("pre", NX_STUB_RC="1")
    assert out.returncode == 1
    assert "apply ABORTED" in out.stderr
    assert "a line with no globs" in out.stderr


# --- pre: skips ------------------------------------------------------------------------------------

def test_the_skip_switch_skips_loudly(rig):
    out = rig.run("pre", DOTFILES_SKIP_PRE_APPLY="1", NX_STUB_RC="1")
    assert out.returncode == 0
    assert "SKIPPED by DOTFILES_SKIP_PRE_APPLY=1" in out.stderr
    assert rig.nx_calls() == []


def test_a_missing_suite_tool_skips_loudly(rig):
    (rig.bin / "uv").unlink()
    out = rig.run("pre", NX_STUB_RC="1")
    assert out.returncode == 0
    assert "suites SKIPPED, not installed: uv" in out.stderr
    assert rig.nx_calls() == []


# --- pre: Node -------------------------------------------------------------------------------------

def test_a_pin_fnm_has_not_installed_refuses_naming_the_install(rig):
    out = rig.run("pre", FNM_INSTALLED="24.18.0")
    assert out.returncode == 1
    assert f"fnm install {PIN}" in out.stderr
    assert "Apply ABORTED" in out.stderr
    assert rig.nx_calls() == []


def test_without_fnm_a_node_of_the_pinned_major_is_used(rig):
    rig.drop_fnm()
    out = rig.run("pre", NODE_VERSION="26.1.0")
    assert out.returncode == 0, out.stderr
    [call] = rig.nx_calls()
    assert "FNM_USED" not in call["env"]
    assert "Node v26.1.0 from PATH (no fnm)" in out.stderr


def test_without_fnm_a_node_of_another_major_refuses(rig):
    rig.drop_fnm()
    out = rig.run("pre", NODE_VERSION="24.18.0")
    assert out.returncode == 1
    assert "is v24.18.0, but .nvmrc pins 26.13.0" in out.stderr
    assert f"fnm install {PIN}" in out.stderr
    assert rig.nx_calls() == []


def test_without_fnm_or_node_the_apply_is_refused(rig):
    rig.drop_fnm()
    (rig.bin / "node").unlink()
    out = rig.run("pre")
    assert out.returncode == 1
    assert "no fnm and no node on PATH" in out.stderr
    assert rig.nx_calls() == []


# --- pre: the pin, from mise.toml or .nvmrc --------------------------------------------------------

def test_a_mise_toml_pin_alone_is_used(rig):
    (rig.src / ".nvmrc").unlink()
    rig.write_mise_toml(PIN)
    out = rig.run("pre")
    assert out.returncode == 0, out.stderr
    [call] = rig.nx_calls()
    assert call["env"].get("FNM_USED") == PIN


def test_the_mise_toml_pin_is_the_one_selected(rig):
    # fnm has only the pin installed and mise.toml names another version: the refusal names that
    # file and that version, so the version reached fnm from mise.toml.
    (rig.src / ".nvmrc").unlink()
    rig.write_mise_toml(OTHER)
    out = rig.run("pre")
    assert out.returncode == 1
    assert f"Node {OTHER} (mise.toml) is not installed in fnm" in out.stderr
    assert f"fnm install {OTHER}" in out.stderr


def test_a_mise_toml_and_an_nvmrc_that_agree_are_used(rig):
    rig.write_mise_toml(PIN)
    out = rig.run("pre")
    assert out.returncode == 0, out.stderr
    assert rig.nx_calls()[0]["env"].get("FNM_USED") == PIN


def test_a_mise_toml_and_an_nvmrc_that_disagree_refuse_naming_both(rig):
    rig.write_mise_toml(OTHER)
    out = rig.run("pre", FNM_INSTALLED=f"{PIN} {OTHER}")
    assert out.returncode == 1
    assert f"mise.toml pins Node {OTHER}" in out.stderr
    assert f".nvmrc pins {PIN}" in out.stderr
    assert "Apply ABORTED" in out.stderr
    assert rig.nx_calls() == []


def test_a_mise_toml_without_a_node_pin_falls_back_to_the_nvmrc(rig):
    (rig.src / "mise.toml").write_text('[tools]\npython = "3.15.2"\n\n[env]\nX = "1"\n')
    out = rig.run("pre")
    assert out.returncode == 0, out.stderr
    assert rig.nx_calls()[0]["env"].get("FNM_USED") == PIN


def test_neither_pin_file_refuses(rig):
    (rig.src / ".nvmrc").unlink()
    out = rig.run("pre")
    assert out.returncode == 1
    assert "mise.toml" in out.stderr and ".nvmrc" in out.stderr
    assert rig.nx_calls() == []


@pytest.mark.parametrize("value", ['"latest"', '"lts"', '["26.13.0"]', '{ version = "26.13.0" }'])
def test_a_mise_toml_pin_that_is_not_a_version_number_refuses(rig, value):
    (rig.src / ".nvmrc").unlink()
    (rig.src / "mise.toml").write_text(f"[tools]\nnode = {value}\n")
    out = rig.run("pre")
    assert out.returncode == 1
    assert "mise.toml" in out.stderr and "not a version number" in out.stderr
    assert rig.nx_calls() == []


def test_a_mise_toml_that_does_not_parse_refuses_naming_it(rig):
    (rig.src / "mise.toml").write_text("[tools\nnode = \n")
    out = rig.run("pre")
    assert out.returncode == 1
    assert "mise.toml" in out.stderr and "cannot be read" in out.stderr
    assert rig.nx_calls() == []


def test_a_python_without_tomllib_refuses_a_mise_toml_naming_the_fix(rig):
    # macOS's command-line tools ship Python 3.9, which has no tomllib; a hook may meet it first.
    rig.write_mise_toml(PIN)
    out = rig.run_without_tomllib("pre")
    assert out.returncode == 1
    assert "tomllib" in out.stderr and "3.11" in out.stderr
    assert rig.nx_calls() == []


def test_a_python_without_tomllib_still_reads_an_nvmrc_alone(rig):
    out = rig.run_without_tomllib("pre")
    assert out.returncode == 0, out.stderr
    assert rig.nx_calls()[0]["env"].get("FNM_USED") == PIN


# --- pre: Node through mise, where mise is active (DOTFILES_MISE_SHIMS set) ------------------------

def test_mise_active_runs_node_through_mise_for_the_pin(rig):
    rig.add_mise()
    out = rig.run("pre", DOTFILES_MISE_SHIMS=str(rig.root / "shims"), MISE_INSTALLED=PIN)
    assert out.returncode == 0, out.stderr
    [call] = rig.nx_calls()
    assert call["env"].get("MISE_USED") == PIN, "Nx did not run under mise's pinned Node"
    assert "FNM_USED" not in call["env"]
    assert f"Node v{PIN} via mise" in out.stderr
    calls = rig.mise_calls()
    assert calls and all(c[:3] == ["exec", f"node@{PIN}", "--"] for c in calls), calls


def test_mise_active_takes_the_pin_from_mise_toml(rig):
    (rig.src / ".nvmrc").unlink()
    rig.write_mise_toml(PIN)
    rig.add_mise()
    out = rig.run("pre", DOTFILES_MISE_SHIMS=str(rig.root / "shims"), MISE_INSTALLED=PIN)
    assert out.returncode == 0, out.stderr
    assert rig.nx_calls()[0]["env"].get("MISE_USED") == PIN


def test_mise_active_never_lets_mise_install_or_reach_the_network(rig):
    rig.add_mise()
    rig.run("pre", DOTFILES_MISE_SHIMS=str(rig.root / "shims"), MISE_INSTALLED=PIN)
    envs = rig.mise_call_envs()
    assert envs, "mise was not called"
    for env in envs:
        assert env.get("MISE_EXEC_AUTO_INSTALL") == "false"
        assert env.get("MISE_AUTO_INSTALL") == "false"
        assert env.get("MISE_NOT_FOUND_AUTO_INSTALL") == "false"
        assert env.get("MISE_OFFLINE") == "1"


def test_mise_active_a_pin_mise_has_not_installed_refuses_naming_the_install(rig):
    rig.add_mise()
    out = rig.run("pre", DOTFILES_MISE_SHIMS=str(rig.root / "shims"), MISE_INSTALLED=OTHER)
    assert out.returncode == 1
    assert f"Node {PIN} (.nvmrc) is not installed in mise" in out.stderr
    assert f"mise install node@{PIN}" in out.stderr
    assert "fnm install" not in out.stderr
    assert rig.nx_calls() == []


def test_mise_active_a_path_node_of_another_version_is_not_taken_for_the_pin(rig):
    # With installing off, mise falls back to a node on PATH (measured on mise 2026.11.5, with a
    # warning); one of another version than the pin is refused.
    rig.add_mise()
    out = rig.run("pre", DOTFILES_MISE_SHIMS=str(rig.root / "shims"), MISE_INSTALLED="",
                  NODE_VERSION="26.1.0")
    assert out.returncode == 1
    assert f"mise install node@{PIN}" in out.stderr
    assert rig.nx_calls() == []


@pytest.mark.parametrize("shims", [None, ""])
def test_mise_on_path_but_not_active_selects_through_fnm_as_before(rig, shims):
    rig.add_mise()
    out = rig.run("pre", DOTFILES_MISE_SHIMS=shims, MISE_INSTALLED=PIN)
    assert out.returncode == 0, out.stderr
    assert rig.nx_calls()[0]["env"].get("FNM_USED") == PIN
    assert rig.mise_calls() == []


def test_mise_active_without_mise_on_path_selects_through_fnm_as_before(rig):
    out = rig.run("pre", DOTFILES_MISE_SHIMS=str(rig.root / "shims"))
    assert out.returncode == 0, out.stderr
    assert rig.nx_calls()[0]["env"].get("FNM_USED") == PIN


# --- pre: npm ci -----------------------------------------------------------------------------------

def test_npm_ci_is_skipped_when_the_install_matches_the_lockfile(rig):
    out = rig.run("pre")
    assert out.returncode == 0, out.stderr
    assert rig.npm_calls() == []
    assert "npm ci skipped" in out.stderr


def test_another_platform_s_optional_binary_missing_is_not_a_stale_install(rig):
    # The control for the cases below: the installed record lacks the darwin binary and the root.
    assert "node_modules/@nx/nx-darwin-arm64" not in json.loads(
        (rig.src / "node_modules" / ".package-lock.json").read_text())["packages"]
    rig.run("pre")
    assert rig.npm_calls() == []


@pytest.mark.parametrize("change", ["no-record", "version", "new-package"])
def test_npm_ci_runs_when_the_install_is_stale(rig, change):
    if change == "no-record":
        (rig.src / "node_modules" / ".package-lock.json").unlink()
    else:
        lock = json.loads(json.dumps(LOCK))
        if change == "version":
            lock["packages"]["node_modules/nx"]["version"] = "24.0.6"
        else:
            lock["packages"]["node_modules/undici"] = {"version": "7.30.1", "dev": True}
        rig.write_lock(lock)
    out = rig.run("pre")
    assert out.returncode == 0, out.stderr
    assert rig.npm_calls() == ["ci --no-audit --no-fund"]
    assert "npm ci ran" in out.stderr
    assert len(rig.nx_calls()) == 1


def test_a_failed_npm_ci_refuses_the_apply(rig):
    (rig.src / "node_modules" / ".package-lock.json").unlink()
    out = rig.run("pre", NPM_STUB_RC="1")
    assert out.returncode == 1
    assert "npm ci failed" in out.stderr
    assert rig.nx_calls() == []


# --- post ------------------------------------------------------------------------------------------

def test_post_returns_at_once_and_the_detached_run_records_a_pass(rig):
    out = rig.run("post", NX_STUB_HOLD="1")
    assert out.returncode == 0
    assert rig.wait_for(rig.rec / "nx.calls"), "the run did not start"
    assert not rig.status.exists(), "the hook waited for the run"
    (rig.root / "release").touch()
    assert rig.wait_for(rig.status)
    rig.wait_idle()
    tree = rig.git("rev-parse", "HEAD^{tree}").strip()
    when, label, result, log = rig.status.read_text().split()
    assert (label, result) == (tree, "pass")
    assert "PASS   test-good.sh" in Path(log).read_text()
    assert rig.nx_calls()[0]["argv"] == ["run-many", "-t", "test", "--outputStyle=static",
                                         "--skip-nx-cache"]


def test_post_failure_calls_the_alert_hook_with_the_suites_and_the_log(rig):
    rig.nx_out.write_text(NX_FAIL)
    alert = rig.root / "cfg" / "dotfiles" / "alert"
    stub(alert, f"open({str(rig.rec / 'alert')!r}, 'w').write(sys.argv[1])\n")
    out = rig.run("post", "--run", NX_STUB_RC="1")
    assert out.returncode == 1
    msg = rig.wait_text(rig.rec / "alert")
    log = rig.status.read_text().split()[3]
    assert "test-broken.sh" in msg and log in msg
    assert " FAIL " in rig.status.read_text()


def test_post_without_an_alert_hook_fails_quietly_and_a_plain_file_is_not_run(rig):
    rig.nx_out.write_text(NX_FAIL)
    out = rig.run("post", "--run", NX_STUB_RC="1")
    assert (out.returncode, out.stderr) == (1, "")
    alert = rig.root / "cfg" / "dotfiles" / "alert"
    alert.write_text(f"#!/bin/sh\necho ran > {rig.rec / 'alert'}\n")
    rig.run("post", "--run", NX_STUB_RC="1")
    time.sleep(0.5)
    assert not (rig.rec / "alert").exists()


def test_post_names_a_refused_setup_in_the_alert(rig):
    alert = rig.root / "cfg" / "dotfiles" / "alert"
    stub(alert, f"open({str(rig.rec / 'alert')!r}, 'w').write(sys.argv[1])\n")
    out = rig.run("post", "--run", FNM_INSTALLED="")
    assert out.returncode == 1
    assert f"fnm install {PIN}" in rig.wait_text(rig.rec / "alert")


def test_a_dirty_tree_is_tested_and_labelled_dirty(rig):
    (rig.src / ".nvmrc").write_text(PIN + "\n\n")
    rig.run("post", "--run")
    assert " dirty pass " in rig.status.read_text()


def test_a_second_run_while_one_holds_the_lock_tests_nothing(rig):
    rig.run("post", NX_STUB_HOLD="1")
    assert rig.wait_for(rig.rec / "nx.calls")
    second = rig.run("post", "--run", NX_STUB_HOLD="1")
    assert second.returncode == 0
    assert len(rig.nx_calls()) == 1
    (rig.root / "release").touch()
    assert rig.wait_for(rig.status)
    rig.wait_idle()
    assert len(rig.nx_calls()) == 1


def test_a_lock_whose_holder_is_gone_is_reclaimed(rig):
    rig.lock.mkdir()
    (rig.lock / "pid").write_text("999999\n")
    out = rig.run("post", "--run")
    assert out.returncode == 0
    assert len(rig.nx_calls()) == 1
    assert not rig.lock.exists()


def test_post_keeps_the_newest_five_logs(rig):
    d = rig.root / "state" / "dotfiles"
    d.mkdir(parents=True, exist_ok=True)
    for i in range(1, 8):
        (d / f"post-apply-2020010{i}T000000Z.log").touch()
    rig.run("post", "--run")
    logs = sorted(p.name for p in d.glob("post-apply-*.log"))
    assert len(logs) == 5
    assert "post-apply-20200101T000000Z.log" not in logs


@pytest.mark.parametrize("why", ["switch", "tool"])
def test_post_skips_loudly(rig, why):
    extra = {"DOTFILES_SKIP_POST_APPLY": "1"} if why == "switch" else {}
    if why == "tool":
        (rig.bin / "gitleaks").unlink()
    out = rig.run("post", **extra)
    assert out.returncode == 0
    assert "SKIPPED" in out.stderr
    time.sleep(0.3)
    assert rig.nx_calls() == []


# --- the apply ledger ------------------------------------------------------------------------------

def test_a_passing_pre_records_only_a_start_with_the_source_head(rig):
    out = rig.run("pre")
    assert out.returncode == 0, out.stderr
    assert rig.ledger() == [("base", "start", rig.git("rev-parse", "--short", "HEAD").strip(), "")]


def test_a_dirty_source_is_recorded_dirty(rig):
    (rig.src / ".nvmrc").write_text(PIN + "\n\n")
    rig.run("pre")
    assert rig.ledger()[0][2].endswith("-dirty")


def test_the_skip_switch_records_a_start_and_a_skipped_with_its_reason(rig):
    rig.run("pre", DOTFILES_SKIP_PRE_APPLY="1")
    assert rig.events() == ["start", "skipped"]
    assert "DOTFILES_SKIP_PRE_APPLY" in rig.ledger()[1][3]


def test_a_missing_suite_tool_records_a_skipped_naming_it(rig):
    (rig.bin / "uv").unlink()
    rig.run("pre")
    assert rig.events() == ["start", "skipped"]
    assert "uv" in rig.ledger()[1][3]


def test_a_failing_suite_records_a_refusal_naming_the_suite_and_the_kept_report(rig):
    rig.nx_out.write_text(NX_FAIL)
    out = rig.run("pre", NX_STUB_RC="1")
    assert out.returncode == 1
    assert rig.events() == ["start", "refused"]
    detail = rig.ledger()[1][3]
    [report] = (rig.root / "state" / "dotfiles").glob("pre-apply-*.log")
    assert "test-broken.sh" in detail and str(report) in detail
    assert "the reason it failed" in report.read_text()
    assert f"why, in full: {report}" in out.stderr
    assert not list((rig.root / "logs").iterdir()), "the report left the temp directory"


def test_a_refused_setup_records_a_refusal_and_keeps_its_report(rig):
    out = rig.run("pre", FNM_INSTALLED="24.18.0")
    assert out.returncode == 1
    assert rig.events() == ["start", "refused"]
    [report] = (rig.root / "state" / "dotfiles").glob("pre-apply-*.log")
    assert str(report) in rig.ledger()[1][3]
    assert str(report) in out.stderr
    assert f"fnm install {PIN}" in rig.ledger()[1][3]


def test_a_refusal_calls_the_alert_hook_naming_the_suites_and_the_report(rig):
    rig.nx_out.write_text(NX_FAIL)
    alert = rig.alert_stub()
    rig.run("pre", NX_STUB_RC="1")
    [msg] = rig.wait_text(alert).splitlines()
    assert msg.startswith("dotfiles pre-apply: apply REFUSED: ")
    [report] = (rig.root / "state" / "dotfiles").glob("pre-apply-*.log")
    assert "test-broken.sh" in msg and str(report) in msg


def test_a_pass_and_a_skip_do_not_call_the_alert_hook(rig):
    alert = rig.alert_stub()
    rig.run("pre")
    rig.run("pre", DOTFILES_SKIP_PRE_APPLY="1")
    time.sleep(0.5)
    assert not alert.exists()


def test_a_refusal_without_an_alert_hook_still_refuses(rig):
    rig.nx_out.write_text(NX_FAIL)
    assert rig.run("pre", NX_STUB_RC="1").returncode == 1


def test_pre_keeps_the_newest_five_reports_apart_from_the_post_logs(rig):
    d = rig.root / "state" / "dotfiles"
    d.mkdir(parents=True, exist_ok=True)
    for i in range(1, 8):
        (d / f"pre-apply-2020010{i}T000000Z.log").touch()
    (d / "post-apply-20200101T000000Z.log").touch()
    rig.nx_out.write_text(NX_FAIL)
    rig.run("pre", NX_STUB_RC="1")
    reports = sorted(p.name for p in d.glob("pre-apply-*.log"))
    assert len(reports) == 5
    assert "pre-apply-20200101T000000Z.log" not in reports
    assert (d / "post-apply-20200101T000000Z.log").exists()


def test_a_ledger_that_cannot_be_written_changes_no_exit_code(rig):
    (rig.root / "state").rmdir()
    (rig.root / "state").write_text("a file where the state directory must go\n")
    assert rig.run("pre").returncode == 0
    rig.nx_out.write_text(NX_FAIL)
    out = rig.run("pre", NX_STUB_RC="1")
    assert out.returncode == 1
    assert "why, in full: " in out.stderr, "the report stays where it was"
    assert rig.run("post").returncode == 0


def test_a_missing_ledger_tool_changes_no_exit_code(rig):
    (rig.src / "private_dot_local" / "bin" / "executable_apply-status").unlink()
    assert rig.run("pre").returncode == 0
    assert rig.run("post", "--run").returncode == 0
    rig.nx_out.write_text(NX_FAIL)
    assert rig.run("pre", NX_STUB_RC="1").returncode == 1


def test_post_records_deployed_before_the_run_it_detaches(rig):
    rig.run("post", NX_STUB_HOLD="1")
    assert rig.wait_for(rig.rec / "nx.calls"), "the run did not start"
    assert rig.events() == ["deployed", "post-start"], "the run's start is written before its result"
    (rig.root / "release").touch()
    assert rig.wait_for(rig.status)
    rig.wait_idle()
    assert rig.events() == ["deployed", "post-start", "post-pass"]


def test_post_start_is_in_the_ledger_before_the_suites_run(rig):
    rig.run("post", "--run")
    [call] = rig.nx_calls()
    assert "post-start" in call["ledger"], "nothing said the run had begun when Nx started"


@pytest.mark.parametrize("why", ["switch", "tool"])
def test_post_records_deployed_even_when_its_suites_are_skipped(rig, why):
    extra = {"DOTFILES_SKIP_POST_APPLY": "1"} if why == "switch" else {}
    if why == "tool":
        (rig.bin / "gitleaks").unlink()
    rig.run("post", **extra)
    assert rig.events() == ["deployed"]


def test_a_post_pass_names_its_log(rig):
    rig.run("post", "--run")
    [_start, (inst, event, _head, detail)] = rig.ledger()
    log = rig.status.read_text().split()[3]
    assert (inst, event) == ("base", "post-pass") and log in detail


def test_a_post_failure_records_post_fail_with_the_suites_and_the_log(rig):
    rig.nx_out.write_text(NX_FAIL)
    rig.run("post", "--run", NX_STUB_RC="1")
    [_post_start, (inst, event, _head, detail)] = rig.ledger()
    log = rig.status.read_text().split()[3]
    assert (inst, event) == ("base", "post-FAIL")
    assert "test-broken.sh" in detail and log in detail


def test_a_second_run_that_finds_the_lock_held_records_nothing(rig):
    rig.lock.mkdir()
    (rig.lock / "pid").write_text(f"{os.getpid()}\n")
    rig.run("post", "--run")
    assert rig.ledger() == []


# --- review fixes ----------------------------------------------------------------------------------

def test_a_slow_alert_hook_does_not_hold_up_a_refusal(rig):
    rig.nx_out.write_text(NX_FAIL)
    rig.slow_alert()
    started = time.monotonic()
    out = rig.run("pre", NX_STUB_RC="1")
    assert out.returncode == 1
    assert time.monotonic() - started < 8, "the refusal waited on the alert hook"
    assert rig.events() == ["start", "refused"]


def test_a_slow_alert_hook_does_not_hold_up_post_run(rig):
    rig.nx_out.write_text(NX_FAIL)
    rig.slow_alert()
    started = time.monotonic()
    assert rig.run("post", "--run", NX_STUB_RC="1").returncode == 1
    assert time.monotonic() - started < 8, "post --run waited on the alert hook"


@pytest.mark.parametrize("args", ["chezmoi apply --dry-run", "chezmoi apply -n", "chezmoi apply -vn"])
def test_a_dry_run_is_recorded_as_a_dry_run_not_an_apply(rig, args):
    rig.run("pre", CHEZMOI_ARGS=args)
    rig.run("post", "--run", CHEZMOI_ARGS=args)
    assert rig.events() == ["dry-run", "dry-run", "dry-run"]
    assert [r[3] for r in rig.ledger()] == ["start", "post-start",
                                            "post-pass: log: " + rig.status.read_text().split()[3]]


def test_a_refusal_in_a_dry_run_is_not_recorded_as_a_refusal(rig):
    rig.nx_out.write_text(NX_FAIL)
    rig.run("pre", NX_STUB_RC="1", CHEZMOI_ARGS="chezmoi apply --dry-run")
    assert "refused" not in rig.events()


def test_a_hook_run_by_hand_is_recorded_as_by_hand(rig):
    rig.run("post", CHEZMOI=None, CHEZMOI_ARGS=None)
    assert rig.events() == ["by-hand"]


def test_the_post_result_records_the_head_from_before_the_run(rig):
    rig.run("post", "--run", NX_STUB_DIRTY="1")
    [(_i, started, start_head, _d), (_inst, event, head, _detail)] = rig.ledger()
    assert (started, event) == ("post-start", "post-pass")
    want = rig.git("rev-parse", "--short", "HEAD").strip()
    assert not head.endswith("-dirty") and head == want and start_head == want


# --- the hooks -------------------------------------------------------------------------------------

def wrapper(rig: Rig, name: str, path: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["/bin/sh", str(rig.src / "tests" / name), *args],
                          env=rig.env(PATH=path), capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, timeout=60)


def test_the_pre_hook_runs_apply_suites_pre(rig):
    out = wrapper(rig, "pre-apply.sh", str(rig.bin))
    assert out.returncode == 0, out.stderr
    assert rig.nx_calls()[0]["argv"][:3] == ["run-many", "-t", "test"]


def test_the_post_hook_passes_run_through(rig):
    out = wrapper(rig, "post-apply.sh", str(rig.bin), "--run")
    assert out.returncode == 0, out.stderr
    assert "--skip-nx-cache" in rig.nx_calls()[0]["argv"]
    assert rig.status.exists(), "--run ran in the foreground"


@pytest.mark.parametrize("name", ["pre-apply.sh", "post-apply.sh"])
def test_a_hook_without_python3_skips_loudly(rig, name):
    nopy = rig.root / "nopy"
    nopy.mkdir()
    os.symlink(shutil.which("dirname"), nopy / "dirname")
    out = wrapper(rig, name, str(nopy))
    assert out.returncode == 0
    assert "SKIPPED, not installed: python3" in out.stderr


@pytest.mark.skipif(shutil.which("chezmoi") is None, reason="chezmoi is not installed")
def test_the_chezmoi_config_names_both_hooks(tmp_path):
    old = tmp_path / "old.toml"
    old.write_text('[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n')
    with open(SRC / ".chezmoi.toml.tmpl") as tmpl:
        cfg = subprocess.run(["chezmoi", "--config", str(old), "--source", str(SRC),
                              "--persistent-state", str(tmp_path / "s.db"), "execute-template",
                              "--init", "--no-tty"], stdin=tmpl, capture_output=True, text=True,
                             check=True).stdout
    for hook in ("pre", "post"):
        block = cfg.split(f"[hooks.apply.{hook}]\n")[1].split("\n\n")[0]
        assert '    command = "sh"' in block.splitlines(), cfg
        assert f'    args = ["{SRC}/tests/{hook}-apply.sh"]' in block.splitlines(), cfg


def uv_calls(rig):
    f = rig.rec / "uv.calls"
    return f.read_text().splitlines() if f.exists() else []


def test_pre_seeds_uv_s_cache_before_the_suites_and_runs_them_offline(rig):
    assert rig.run("pre").returncode == 0
    assert uv_calls(rig) == [f"sync --script {rig.src}/tests/test-uv.py"]
    [call] = rig.nx_calls()
    assert call["seeded"] is True
    assert call["env"]["UV_OFFLINE"] == "1"


def test_pre_keeps_a_uv_offline_the_caller_set(rig):
    assert rig.run("pre", UV_OFFLINE="0").returncode == 0
    assert rig.nx_calls()[0]["env"]["UV_OFFLINE"] == "0"


def test_a_failed_seed_does_not_abort_the_apply(rig):
    r = rig.run("pre", UV_STUB_RC="1")
    assert r.returncode == 0, r.stderr
    assert len(rig.nx_calls()) == 1


def test_the_post_run_seeds_uv_s_cache_before_its_suites(rig):
    assert rig.run("post", "--run").returncode == 0
    assert uv_calls(rig) == [f"sync --script {rig.src}/tests/test-uv.py"]
    [call] = rig.nx_calls()
    assert call["seeded"] is True and call["env"]["UV_OFFLINE"] == "1"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", *sys.argv[1:]]))
