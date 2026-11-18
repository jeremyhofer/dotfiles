#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for the base's mise pieces: its conf.d drop-in, the apply step that creates mise's state
directory, and the per-machine `miseActive` value that keeps both off a machine until it is set.

Run: npx nx run suite-mise-base:test
 or: uv run --script tests/test-mise-base.py [-k <pattern>]

What is held:

* The drop-in, loaded by the installed mise from a scratch config directory, sets the three settings
  to the values the base owns, each sourced from the drop-in itself, and its `min_version` floor is
  honored: the floor at the installed release passes, one release above it refuses. The floor is
  checked with `mise ls`, which loads the configuration; `mise --version` and `mise settings get` do
  not enforce the floor (measured with mise 2026.11.5), so a probe through either cannot fail.
* The drop-in's floor is never above the installed mise, which would refuse every mise command.
* The state-directory step creates mise's state directory at mode 700, narrows an existing wider
  one, and finds the directory the way mise does (MISE_STATE_DIR, then XDG_STATE_HOME, then HOME).
* With `miseActive` false or absent, `.chezmoiignore` keeps every mise target off the machine, and
  chezmoi manages no target whose path names mise; with it true, the drop-in deploys, and the
  state-directory step runs only where a `mise` is on PATH.
* Regenerating the config writes `miseActive = false` when the key is absent and keeps `true`.

Every mise run uses scratch config, data, state and cache directories and a scratch HOME, with
MISE_OFFLINE=1, so nothing of this machine's mise is read or written and nothing reaches the
network. The chezmoi runs use a scratch config, persistent state and destination. The mise cases
skip where mise is not installed, the chezmoi cases where chezmoi is not.
"""
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DROPIN = ROOT / "dot_config" / "mise" / "conf.d" / "10-base.toml"
STATE_STEP = ROOT / "run_before_create-mise-state-dir.sh"
MISE = shutil.which("mise")
CHEZMOI = shutil.which("chezmoi")

needs_mise = pytest.mark.skipif(MISE is None, reason="mise not installed")
needs_chezmoi = pytest.mark.skipif(CHEZMOI is None, reason="chezmoi not installed")


# --- mise, in scratch directories ----------------------------------------------------------------

def mise_env(tmp: Path) -> dict:
    """The caller's environment without any MISE_ variable, pointed at scratch directories."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("MISE_", "__MISE_"))}
    for name in ("home", "config/conf.d", "data", "state", "cache", "cwd"):
        (tmp / name).mkdir(parents=True, exist_ok=True)
    env.update(
        HOME=str(tmp / "home"),
        MISE_CONFIG_DIR=str(tmp / "config"),
        MISE_DATA_DIR=str(tmp / "data"),
        MISE_STATE_DIR=str(tmp / "state"),
        MISE_CACHE_DIR=str(tmp / "cache"),
        MISE_CEILING_PATHS=str(tmp),
        MISE_OFFLINE="1",
    )
    for var in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
        env.pop(var, None)
    return env


def mise(tmp: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([MISE, *args], cwd=tmp / "cwd", env=mise_env(tmp),
                          capture_output=True, text=True, timeout=60)


def install_dropin(tmp: Path, text: str | None = None) -> None:
    mise_env(tmp)
    target = tmp / "config" / "conf.d" / DROPIN.name
    target.write_text(DROPIN.read_text() if text is None else text)


def installed_version(tmp: Path) -> tuple[int, int, int]:
    out = mise(tmp, "--version")
    assert out.returncode == 0, out.stderr
    m = re.match(r"(\d+)\.(\d+)\.(\d+)", out.stdout)
    assert m, f"cannot read a version from: {out.stdout!r}"
    return tuple(int(x) for x in m.groups())


def floor_of(text: str) -> tuple[int, int, int]:
    m = re.search(r'^min_version\s*=\s*"(\d+)\.(\d+)\.(\d+)"', text, re.M)
    assert m, "the drop-in sets no min_version"
    return tuple(int(x) for x in m.groups())


def test_dropin_exists():
    assert DROPIN.is_file(), f"no drop-in at {DROPIN.relative_to(ROOT)}"


@needs_mise
def test_dropin_settings_load_from_the_dropin(tmp_path):
    install_dropin(tmp_path)
    out = mise(tmp_path, "settings", "ls", "--json-extended")
    assert out.returncode == 0, out.stderr
    import json
    got = json.loads(out.stdout)
    want = {
        "use_versions_host": False,
        "use_versions_host_track": False,
        "idiomatic_version_file_enable_tools": ["node"],
    }
    source = str(tmp_path / "config" / "conf.d" / DROPIN.name)
    for key, value in want.items():
        assert key in got, f"{key} is not set by the drop-in; mise lists {sorted(got)}"
        assert got[key]["value"] == value, f"{key} = {got[key]['value']!r}, want {value!r}"
        assert got[key]["source"] == source, f"{key} comes from {got[key]['source']}, not the drop-in"


@needs_mise
def test_dropin_floor_is_not_above_the_installed_mise(tmp_path):
    install_dropin(tmp_path)
    assert floor_of(DROPIN.read_text()) <= installed_version(tmp_path), \
        "the drop-in's min_version is above the installed mise, so every mise command would refuse"
    out = mise(tmp_path, "ls")
    assert out.returncode == 0, f"mise ls refused under the drop-in as shipped: {out.stderr}"


@needs_mise
def test_dropin_floor_refuses_an_older_mise(tmp_path):
    major, minor, patch = installed_version(tmp_path)
    raised = f'min_version = "{major}.{minor}.{patch + 1}"'
    text = re.sub(r"^min_version\s*=.*$", raised, DROPIN.read_text(), count=1, flags=re.M)
    assert raised in text
    install_dropin(tmp_path, text)
    out = mise(tmp_path, "ls")
    assert out.returncode != 0, "a floor above the installed mise did not refuse `mise ls`"
    assert "is required" in out.stderr, out.stderr


@needs_mise
def test_dropin_without_a_floor_does_not_refuse(tmp_path):
    # The control for the case above: the same command with the floor line removed passes, so that
    # refusal comes from the floor and not from anything else in the scratch setup.
    text = re.sub(r"^min_version\s*=.*\n", "", DROPIN.read_text(), count=1, flags=re.M)
    install_dropin(tmp_path, text)
    out = mise(tmp_path, "ls")
    assert out.returncode == 0, out.stderr


# --- the state-directory step --------------------------------------------------------------------

def run_state_step(env_extra: dict, home: Path) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items()
           if k not in ("MISE_STATE_DIR", "XDG_STATE_HOME")}
    env["HOME"] = str(home)
    env.update(env_extra)
    return subprocess.run(["sh", str(STATE_STEP)], env=env, capture_output=True, text=True,
                          timeout=30)


def mode(p: Path) -> int:
    return stat.S_IMODE(p.stat().st_mode)


def test_state_step_exists():
    assert STATE_STEP.is_file(), f"no state-directory step at {STATE_STEP.relative_to(ROOT)}"


def test_state_step_creates_the_directory_private(tmp_path):
    target = tmp_path / "s" / "mise"
    out = run_state_step({"MISE_STATE_DIR": str(target)}, tmp_path / "home")
    assert out.returncode == 0, out.stderr
    assert target.is_dir()
    assert mode(target) == 0o700, oct(mode(target))


def test_state_step_narrows_an_existing_wider_directory(tmp_path):
    target = tmp_path / "s" / "mise"
    target.mkdir(parents=True)
    target.chmod(0o755)
    (target / "kept").write_text("x")
    out = run_state_step({"MISE_STATE_DIR": str(target)}, tmp_path / "home")
    assert out.returncode == 0, out.stderr
    assert mode(target) == 0o700, oct(mode(target))
    assert (target / "kept").read_text() == "x", "the step changed what the directory holds"


def test_state_step_follows_xdg_state_home(tmp_path):
    out = run_state_step({"XDG_STATE_HOME": str(tmp_path / "xdg")}, tmp_path / "home")
    assert out.returncode == 0, out.stderr
    assert mode(tmp_path / "xdg" / "mise") == 0o700
    assert not (tmp_path / "home" / ".local" / "state" / "mise").exists()


def test_state_step_defaults_under_home(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    out = run_state_step({}, home)
    assert out.returncode == 0, out.stderr
    assert mode(home / ".local" / "state" / "mise") == 0o700


def test_state_step_refuses_a_file_in_the_way(tmp_path):
    target = tmp_path / "mise"
    target.write_text("not a directory")
    out = run_state_step({"MISE_STATE_DIR": str(target)}, tmp_path / "home")
    assert out.returncode != 0, "a file where the directory belongs was passed over silently"


# --- the miseActive gate -------------------------------------------------------------------------

def chezmoi_config(tmp: Path, data_lines: str) -> Path:
    cfg = tmp / "c.toml"
    cfg.write_text('[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n'
                   + data_lines)
    return cfg


def render_ignore(tmp: Path, data_lines: str, path_dirs: list[Path]) -> set[str]:
    """The source's .chezmoiignore rendered under a scratch config, with PATH set to path_dirs
    only, so `lookPath "mise"` sees exactly the mise the case provides."""
    cfg = chezmoi_config(tmp, data_lines)
    env = dict(os.environ, PATH=os.pathsep.join(str(d) for d in path_dirs))
    out = subprocess.run(
        [CHEZMOI, "--config", str(cfg), "--source", str(ROOT),
         "--persistent-state", str(tmp / "s.db"), "execute-template"],
        stdin=open(ROOT / ".chezmoiignore"), env=env, capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    return {line.strip() for line in out.stdout.splitlines()}


def stub_mise_dir(tmp: Path) -> Path:
    d = tmp / "stubbin"
    d.mkdir(exist_ok=True)
    stub = d / "mise"
    stub.write_text("#!/bin/sh\nexit 0\n")
    stub.chmod(0o755)
    return d


ACTIVE_TARGETS = {".config/mise", "create-mise-state-dir.sh"}


@needs_chezmoi
@pytest.mark.parametrize("data_lines", ["", "    miseActive = false\n"], ids=["absent", "false"])
def test_inactive_ignores_every_mise_target(tmp_path, data_lines):
    ignored = render_ignore(tmp_path, data_lines, [stub_mise_dir(tmp_path)])
    missing = ACTIVE_TARGETS - ignored
    assert not missing, f"not ignored while miseActive is off: {sorted(missing)}"


@needs_chezmoi
def test_active_deploys_the_dropin_and_the_step(tmp_path):
    ignored = render_ignore(tmp_path, "    miseActive = true\n", [stub_mise_dir(tmp_path)])
    wrongly = ACTIVE_TARGETS & ignored
    assert not wrongly, f"ignored although miseActive is on and mise is installed: {sorted(wrongly)}"


@needs_chezmoi
def test_active_without_mise_skips_only_the_step(tmp_path):
    empty = tmp_path / "emptybin"
    empty.mkdir()
    ignored = render_ignore(tmp_path, "    miseActive = true\n", [empty])
    assert "create-mise-state-dir.sh" in ignored, "the state step runs where no mise is installed"
    assert ".config/mise" not in ignored


def scratch_source(tmp: Path) -> Path:
    """A copy of the source as chezmoi would read it (tracked and untracked, not ignored), without
    .chezmoiexternal*, whose downloads the question does not need."""
    src = tmp / "src"
    files = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others",
                            "--exclude-standard"], capture_output=True, check=True).stdout
    for rel in filter(None, files.decode().split("\0")):
        s = ROOT / rel
        if not (s.exists() or s.is_symlink()) or rel.startswith(".chezmoiexternal"):
            continue
        d = src / rel
        d.parent.mkdir(parents=True, exist_ok=True)
        if s.is_symlink():
            d.symlink_to(os.readlink(s))
        else:
            shutil.copy2(s, d)
    return src


@pytest.fixture(scope="module")
def source_copy(tmp_path_factory):
    if CHEZMOI is None:
        pytest.skip("chezmoi not installed")
    return scratch_source(tmp_path_factory.mktemp("mise-src"))


def managed(tmp: Path, src: Path, data_lines: str, path_dirs: list[Path]) -> list[str]:
    cfg = chezmoi_config(tmp, data_lines)
    (tmp / "home").mkdir(exist_ok=True)
    env = dict(os.environ, PATH=os.pathsep.join(str(d) for d in path_dirs))
    out = subprocess.run(
        [CHEZMOI, "--source", str(src), "--config", str(cfg), "--destination", str(tmp / "home"),
         "--cache", str(tmp / "cache"), "--persistent-state", str(tmp / "s.db"),
         "managed", "--include", "all"],
        env=env, capture_output=True, text=True, timeout=120)
    assert out.returncode == 0, out.stderr
    listed = out.stdout.splitlines()
    assert listed, "chezmoi listed nothing, so this check would see nothing"
    return listed


@needs_chezmoi
@pytest.mark.parametrize("data_lines", ["", "    miseActive = false\n"], ids=["absent", "false"])
def test_inactive_manages_nothing_of_mise(tmp_path, source_copy, data_lines):
    # PATH holds a mise, so only the flag can be what keeps the targets off.
    path_dirs = [stub_mise_dir(tmp_path), *map(Path, os.environ["PATH"].split(os.pathsep))]
    hits = [t for t in managed(tmp_path, source_copy, data_lines, path_dirs) if "mise" in t]
    assert not hits, f"managed while miseActive is off: {hits}"


@needs_chezmoi
def test_active_manages_the_dropin_and_the_step(tmp_path, source_copy):
    path_dirs = [stub_mise_dir(tmp_path), *map(Path, os.environ["PATH"].split(os.pathsep))]
    got = set(managed(tmp_path, source_copy, "    miseActive = true\n", path_dirs))
    for want in (".config/mise/conf.d/10-base.toml", "create-mise-state-dir.sh"):
        assert want in got, f"{want} is not managed with miseActive on"


# --- the generated config ------------------------------------------------------------------------

def init_render(tmp: Path, data_lines: str) -> str:
    cfg = chezmoi_config(tmp, data_lines)
    out = subprocess.run(
        [CHEZMOI, "--config", str(cfg), "--source", str(ROOT),
         "--persistent-state", str(tmp / "s.db"), "execute-template", "--init", "--no-tty"],
        stdin=open(ROOT / ".chezmoi.toml.tmpl"), capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    return out.stdout


@needs_chezmoi
def test_init_writes_mise_active_false_by_default(tmp_path):
    assert re.search(r"^\s*miseActive = false$", init_render(tmp_path, ""), re.M)


@needs_chezmoi
def test_init_keeps_mise_active_true(tmp_path):
    assert re.search(r"^\s*miseActive = true$",
                     init_render(tmp_path, "    miseActive = true\n"), re.M)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", *sys.argv[1:]]))
