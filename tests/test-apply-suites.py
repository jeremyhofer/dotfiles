#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for tests/apply-suites.py, which runs the suites through Nx around `chezmoi apply`, and for
its two chezmoi hooks, tests/pre-apply.sh and tests/post-apply.sh.

Run: sh tests/run-all.sh --only test-apply-suites.py
 or: uv run --script tests/test-apply-suites.py [-k <pattern>]

What is held: `pre` runs `nx run-many -t test` under the Node .nvmrc pins (through fnm, or a node
on PATH of the pinned major), runs `npm ci` only when node_modules does not hold what
package-lock.json names, gives Nx no socket to open, removes chezmoi's CHEZMOI_* variables, and
aborts the apply on a failure, naming the suite, the log and how to re-run it. Node that is missing
or of the wrong version refuses the apply; a skip switch or a missing suite tool skips it, loudly.
`post` returns at once while an uncached run goes on detached, one at a time, with a status file,
a bounded set of logs and the alert hook on a failure. The generated chezmoi config names both hooks.

Everything runs in a scratch copy: the script beside a stand-in `node_modules/.bin/nx` that records
how it was called and prints a canned Nx log, and a PATH of stand-ins for fnm, node, npm and the
tools the suites need, so no suite, no install and no apply runs. Each refusal has a control beside
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
    f.write(json.dumps({{"argv": sys.argv[1:], "env": dict(os.environ)}}) + "\\n")
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
        for tool in ("uv", "jq", "yq", "gitleaks", "wt"):
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

    @property
    def status(self) -> Path:
        return self.root / "state" / "dotfiles" / "post-apply.last"

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
    msg = (rig.rec / "alert").read_text()
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
    assert not (rig.rec / "alert").exists()


def test_post_names_a_refused_setup_in_the_alert(rig):
    alert = rig.root / "cfg" / "dotfiles" / "alert"
    stub(alert, f"open({str(rig.rec / 'alert')!r}, 'w').write(sys.argv[1])\n")
    out = rig.run("post", "--run", FNM_INSTALLED="")
    assert out.returncode == 1
    assert f"fnm install {PIN}" in (rig.rec / "alert").read_text()


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


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", *sys.argv[1:]]))
