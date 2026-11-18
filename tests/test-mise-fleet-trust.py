#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for mise-fleet-trust, the apply step that trusts the mise configurations the fleet manifest
opts in and writes mise's miserc, and for the apply script and `.chezmoiignore` lines that run it
only where `miseActive` is true.

Run: npx nx run suite-mise-fleet-trust:test
 or: uv run --script tests/test-mise-fleet-trust.py [-k <pattern>]

What is held:

* An opted-in project's own `mise.toml` and `mise.local.toml` are trusted, and nothing else is: a
  `mise.toml` in a subdirectory of the project, one in a directory whose name merely starts with
  the project's, and one in a project that does not opt in all stay untrusted. A stub that trusts
  the project's directory as a prefix fails this check (seen red below).
* The miserc the tool writes makes mise ignore a dependency's `node_modules/x/mise.toml`, a
  workspace package's `pkg/node_modules/y/mise.toml` and a `miseIgnore` path while the project's own configuration still applies, and stops the walk above
  the project (the ceiling); without it, mise reads and refuses them (the controls). A stub whose
  ignore list is empty fails the first check (seen red below). Measured with `mise config ls`.
* The miserc is written at mise's configuration directory (MISE_CONFIG_DIR, else XDG_CONFIG_HOME),
  mode 644, with a header, replacing what was there; a domain fragment is copied into it verbatim,
  and a fragment that sets either list is refused, leaving the old file in place.
* The base source's own `mise.toml` is trusted with `--base-source`, also where there is no fleet
  record at all. An unreadable record and an invalid `miseIgnore` refuse (exit 2), trust no project
  and leave the miserc unchanged; a project not on disk is skipped; `--dry-run` writes and trusts
  nothing.
* With `miseActive` false or absent, `.chezmoiignore` keeps both the tool and its apply script off
  the machine; with it true they deploy, and the script runs only where `mise` is installed. The
  rendered script hashes the tool and passes the source directory.

Every mise run uses scratch config, data, state and cache directories and a scratch HOME, with
MISE_OFFLINE=1, so nothing of this machine's mise is read or written. The mise cases skip where mise
is not installed, the record cases where yq is not, the chezmoi cases where chezmoi is not.
"""
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tomllib
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
BIN = ROOT / "private_dot_local" / "bin"
TOOL = BIN / "executable_mise-fleet-trust"
SCRIPT = ROOT / "run_onchange_after_trust-mise-configs.sh.tmpl"
MISE = shutil.which("mise")
YQ = shutil.which("yq")
CHEZMOI = shutil.which("chezmoi")

needs_mise = pytest.mark.skipif(MISE is None or YQ is None, reason="mise or yq not installed")
needs_chezmoi = pytest.mark.skipif(CHEZMOI is None, reason="chezmoi not installed")


# --- a scratch world: mise directories, a Devel tree, a fleet record, a base source ---------------

def env_toml(var: str, value: str) -> str:
    return f'[env]\n{var} = "{value}"\n'


class World:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.devel = tmp / "devel"
        self.proj = self.devel / "internal" / "proj"
        self.base = tmp / "base-source"
        self.record = tmp / "mani.yaml"
        self.miserc = tmp / "config" / "miserc.toml"
        self.fragment = tmp / "home" / ".dotlocal" / "mise" / "miserc.extra.toml"
        # A ceiling at the projects' parent, for a probe made before the tool has written its
        # miserc: without it the untrusted parent config fails every probe.
        self.ceil = {"MISE_CEILING_PATHS": str(self.devel / "internal")}
        # mise names whichever of the project's two files it reads first.
        self.own_configs = (self.proj / "mise.toml", self.proj / "mise.local.toml")
        for name in ("home", "config/conf.d", "data", "state", "cache"):
            (tmp / name).mkdir(parents=True, exist_ok=True)
        files = {
            self.proj / "mise.toml": env_toml("OWN", "proj"),
            self.proj / "mise.local.toml": env_toml("LOCAL", "proj"),
            self.proj / "sub" / "mise.toml": env_toml("SUB", "sub"),
            self.proj / "node_modules" / "x" / "mise.toml": env_toml("DEP", "x"),
            # A workspace package's own dependency, below the project's top level.
            self.proj / "pkg" / "node_modules" / "y" / "mise.toml": env_toml("DEPY", "y"),
            self.proj / "fixtures" / "mise.toml": env_toml("FIX", "fixture"),
            # A directory whose name starts with the project's: trusted only by a string prefix.
            self.devel / "internal" / "proj-other" / "mise.toml": env_toml("OTHER", "other"),
            # A project that does not opt in.
            self.devel / "internal" / "optout" / "mise.toml": env_toml("OPTOUT", "optout"),
            # Above the project: read unless the ceiling stops the walk.
            self.devel / "internal" / "mise.toml": env_toml("PARENT", "parent"),
            self.base / "mise.toml": env_toml("BASE", "base"),
        }
        for p, text in files.items():
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        self.write_record(
            "projects:\n"
            "  proj:\n    path: internal/proj\n    miseTrust: true\n    miseIgnore: [fixtures]\n"
            "  optout:\n    path: internal/optout\n    miseTrust: false\n"
            "  away:\n    path: internal/away\n    miseTrust: true\n"
        )

    def write_record(self, text: str) -> None:
        self.record.write_text(text)

    def write_fragment(self, text: str) -> None:
        self.fragment.parent.mkdir(parents=True, exist_ok=True)
        self.fragment.write_text(text)

    def env(self, extra: dict | None = None, drop: tuple = ()) -> dict:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("MISE_", "__MISE_"))}
        for var in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
            env.pop(var, None)
        env.update(
            HOME=str(self.tmp / "home"),
            MISE_CONFIG_DIR=str(self.tmp / "config"),
            MISE_DATA_DIR=str(self.tmp / "data"),
            MISE_STATE_DIR=str(self.tmp / "state"),
            MISE_CACHE_DIR=str(self.tmp / "cache"),
            MISE_OFFLINE="1",
            FLEET_RECORD=str(self.record),
            FLEET_DEVEL_ROOT=str(self.devel),
        )
        env.update(extra or {})
        for var in drop:
            env.pop(var, None)
        return env

    def run(self, *args: str, tool: Path = TOOL, extra: dict | None = None, drop: tuple = ()):
        return subprocess.run([sys.executable, str(tool), *args], env=self.env(extra, drop),
                              capture_output=True, text=True, timeout=120)

    def mise(self, cwd: Path, *args: str, extra: dict | None = None):
        return subprocess.run([MISE, *args], cwd=cwd, env=self.env(extra),
                              capture_output=True, text=True, timeout=60)

    def mise_env(self, cwd: Path, extra: dict | None = None):
        return self.mise(cwd, "env", "-s", "bash", extra=extra)

    def config_ls(self, cwd: Path, extra: dict | None = None):
        return self.mise(cwd, "config", "ls", extra=extra)

    def lists(self) -> dict:
        return tomllib.loads(self.miserc.read_text())


@pytest.fixture
def world(tmp_path):
    if MISE is None or YQ is None:
        pytest.skip("mise or yq not installed")
    return World(tmp_path)


def untrusted(out, *configs: Path) -> bool:
    """mise refused, naming one of these configuration files as the untrusted one."""
    return (out.returncode != 0 and "not trusted" in out.stderr
            and any(str(c) in out.stderr for c in configs))


# The two checks the plan's red cases name, written once so the same function can be pointed at the
# real tool and at a defective stub.

def check_only_exact_files_trusted(w: World, tool: Path = TOOL) -> None:
    out = w.run(tool=tool)
    assert out.returncode == 0, out.stderr
    own = w.mise_env(w.proj, w.ceil)
    assert own.returncode == 0, f"the project's own config is not trusted: {own.stderr}"
    assert "OWN=proj" in own.stdout and "LOCAL=proj" in own.stdout, own.stdout
    for d in (w.proj / "sub", w.devel / "internal" / "proj-other", w.devel / "internal" / "optout"):
        got = w.mise_env(d, w.ceil)
        assert untrusted(got, d / "mise.toml"), f"{d.relative_to(w.tmp)} is trusted: {got.stdout}{got.stderr}"


def check_dependency_ignored(w: World, tool: Path = TOOL) -> None:
    out = w.run(tool=tool)
    assert out.returncode == 0, out.stderr
    for d in (w.proj / "node_modules" / "x", w.proj / "pkg" / "node_modules" / "y", w.proj / "fixtures"):
        got = w.config_ls(d)
        assert got.returncode == 0, f"{d.relative_to(w.tmp)} is read, not ignored: {got.stderr}"
        assert str(w.proj / "mise.toml") in got.stdout, "the project's own config is not listed"
        assert str(d / "mise.toml") not in got.stdout, f"{d.relative_to(w.tmp)}'s config is listed"


# --- the tool -----------------------------------------------------------------------------------

def test_tool_exists():
    assert TOOL.is_file(), f"no tool at {TOOL.relative_to(ROOT)}"


@needs_mise
def test_only_the_projects_own_files_are_trusted(world):
    check_only_exact_files_trusted(world)


@needs_mise
def test_a_dependency_and_a_mise_ignore_path_are_ignored(world):
    check_dependency_ignored(world)


@needs_mise
def test_without_the_miserc_the_dependency_is_read(world):
    # The control for the case above: the same directory, the project trusted but no miserc, is
    # read and refused, so the pass above comes from the miserc and not from the setup.
    assert world.run().returncode == 0
    world.miserc.unlink()
    dep = world.proj / "node_modules" / "x"
    assert untrusted(world.config_ls(dep, world.ceil), dep / "mise.toml")


@needs_mise
def test_the_lists_under_a_settings_table_are_not_honored(world):
    # The form matters: the same two lists the tool writes, moved under [settings], leave the
    # dependency read. So the pass above comes from the lists being top-level keys.
    assert world.run().returncode == 0
    text = world.miserc.read_text()
    i = text.index("ignored_config_paths = ")
    world.miserc.write_text(text[:i] + "[settings]\n" + text[i:])
    assert "settings" in tomllib.loads(world.miserc.read_text())
    dep = world.proj / "node_modules" / "x"
    # The ceiling from the environment, so the untrusted parent (also unread only through the
    # miserc) cannot be what fails: the refusal must name the dependency.
    assert untrusted(world.config_ls(dep, world.ceil), dep / "mise.toml")


@needs_mise
def test_the_ceiling_stops_the_walk_above_the_project(world):
    parent = world.devel / "internal" / "mise.toml"
    assert untrusted(world.config_ls(world.proj), parent), "the parent is not read, so this sees nothing"
    assert world.run().returncode == 0
    got = world.config_ls(world.proj)
    assert got.returncode == 0, got.stderr
    assert str(parent) not in got.stdout and str(world.proj / "mise.toml") in got.stdout, got.stdout


@needs_mise
def test_the_miserc_lists_every_opted_in_project(world):
    assert world.run().returncode == 0
    got = world.lists()
    for name in ("node_modules", ".venv", "vendor"):
        assert str(world.proj / "**" / name / "**") in got["ignored_config_paths"], name
    assert str(world.proj / "fixtures") in got["ignored_config_paths"]
    # A project not on this machine still gets its entries, so a later clone is covered.
    assert str(world.devel / "internal" / "away" / "**" / "node_modules" / "**") in got["ignored_config_paths"]
    assert got["ceiling_paths"] == [str(world.devel / "internal")]
    assert not any("optout" in p for p in got["ignored_config_paths"])


@needs_mise
def test_the_miserc_is_generated_644_and_replaced(world):
    world.miserc.write_text("stale = true\n")
    assert world.run().returncode == 0
    text = world.miserc.read_text()
    assert text.startswith("# Generated by mise-fleet-trust"), text
    assert "stale" not in text
    assert stat.S_IMODE(world.miserc.stat().st_mode) == 0o644
    assert sorted(p.name for p in world.miserc.parent.iterdir()) == ["conf.d", "miserc.toml"], \
        "a temporary file was left beside the miserc"


@needs_mise
def test_the_miserc_follows_xdg_config_home(world):
    xdg = world.tmp / "xdg"
    out = world.run(extra={"XDG_CONFIG_HOME": str(xdg)}, drop=("MISE_CONFIG_DIR",))
    assert out.returncode == 0, out.stderr
    assert (xdg / "mise" / "miserc.toml").is_file()
    assert not world.miserc.exists()


@needs_mise
def test_a_fragment_reaches_the_miserc(world):
    line = 'override_tool_versions_filenames = ["none"]\n'
    world.write_fragment("# the domain's own\n" + line)
    assert world.run().returncode == 0
    text = world.miserc.read_text()
    assert text.endswith("# the domain's own\n" + line), "the fragment is not copied verbatim, last"
    assert world.lists()["override_tool_versions_filenames"] == ["none"]
    # mise acts on it: `.tool-versions` is no longer read. (`mise settings get` prints `[]` with
    # the setting and without it, so it cannot tell.) The control is the same run without it.
    tool_versions = world.proj / ".tool-versions"
    tool_versions.write_text("python 3.99.0\n")
    got = world.config_ls(world.proj)
    assert got.returncode == 0 and str(tool_versions) not in got.stdout, (got.stdout, got.stderr)
    world.fragment.unlink()
    assert world.run().returncode == 0
    assert str(tool_versions) in world.config_ls(world.proj).stdout, "the control reads no .tool-versions"


@pytest.mark.parametrize("line", ["ignored_config_paths = []", 'ceiling_paths = ["/x"]',
                                  '"ceiling_paths" = []'])
@needs_mise
def test_a_fragment_setting_a_list_is_refused(world, line):
    world.miserc.write_text("kept = true\n")
    world.write_fragment(line + "\n")
    out = world.run()
    assert out.returncode == 2, (out.returncode, out.stderr)
    assert "this tool writes that list" in out.stderr, out.stderr
    assert world.miserc.read_text() == "kept = true\n", "the miserc changed on a refusal"
    assert untrusted(world.mise_env(world.proj, world.ceil), *world.own_configs)


@needs_mise
def test_a_fragment_naming_a_list_in_a_comment_is_not_refused(world):
    world.write_fragment("# ceiling_paths is written by the tool\n")
    assert world.run().returncode == 0


@needs_mise
def test_base_source_is_trusted(world):
    assert untrusted(world.mise_env(world.base), world.base / "mise.toml")
    out = world.run("--base-source", str(world.base))
    assert out.returncode == 0, out.stderr
    got = world.mise_env(world.base)
    assert got.returncode == 0 and "BASE=base" in got.stdout, got.stderr


@needs_mise
def test_no_record_still_trusts_the_base_source(world):
    world.record.unlink()
    out = world.run("--base-source", str(world.base))
    assert out.returncode == 0, out.stderr
    assert "no fleet record" in out.stderr
    assert world.mise_env(world.base).returncode == 0
    assert world.lists()["ignored_config_paths"] == []
    assert untrusted(world.mise_env(world.proj, world.ceil), *world.own_configs)


@needs_mise
def test_an_unreadable_record_refuses_and_trusts_no_project(world):
    world.write_record("projects: [this is: not: a map\n")
    out = world.run()
    assert out.returncode == 2, (out.returncode, out.stderr)
    assert not world.miserc.exists(), "a miserc was written from an unreadable record"
    assert untrusted(world.mise_env(world.proj, world.ceil), *world.own_configs)


@pytest.mark.parametrize("bad", ["../escape", "/abs", "a/./b", "x*"])
@needs_mise
def test_an_invalid_mise_ignore_refuses(world, bad):
    world.write_record(f"projects:\n  proj:\n    path: internal/proj\n    miseTrust: true\n"
                       f"    miseIgnore: ['{bad}']\n")
    out = world.run()
    assert out.returncode == 2, (out.returncode, out.stdout, out.stderr)
    assert not world.miserc.exists()
    assert untrusted(world.mise_env(world.proj, world.ceil), *world.own_configs)


@pytest.mark.parametrize("char", ["*", "?", "["])
@needs_mise
def test_a_project_directory_holding_a_glob_character_refuses(world, char):
    # Its ignore globs are written under its directory, so a glob character there would make them
    # match other paths. The directory exists, so only the character can refuse it.
    name = f"g{char}lob"
    (world.devel / "internal" / name).mkdir()
    (world.devel / "internal" / name / "mise.toml").write_text(env_toml("GLOB", "glob"))
    world.write_record("projects:\n"
                       "  proj:\n    path: internal/proj\n    miseTrust: true\n"
                       f"  globby:\n    path: 'internal/{name}'\n    miseTrust: true\n")
    out = world.run()
    assert out.returncode == 2, (out.returncode, out.stdout, out.stderr)
    assert "globby" in out.stderr and "glob character" in out.stderr, out.stderr
    assert not world.miserc.exists(), "a miserc was written for a refused record"
    assert untrusted(world.mise_env(world.proj, world.ceil), *world.own_configs)


@needs_mise
def test_a_project_not_on_disk_is_skipped(world):
    out = world.run()
    assert out.returncode == 0, out.stderr
    assert "away" in out.stderr and "not on disk" in out.stderr, out.stderr


@needs_mise
def test_dry_run_writes_and_trusts_nothing(world):
    out = world.run("--dry-run", "--base-source", str(world.base))
    assert out.returncode == 0, out.stderr
    assert str(world.proj / "mise.toml") in out.stdout
    assert "ignored_config_paths = [" in out.stdout
    assert not world.miserc.exists()
    assert untrusted(world.mise_env(world.proj, world.ceil), *world.own_configs)
    assert untrusted(world.mise_env(world.base), world.base / "mise.toml")


@needs_mise
def test_no_project_opts_in(world):
    world.write_record("projects:\n  optout:\n    path: internal/optout\n")
    assert world.run().returncode == 0
    got = world.lists()
    assert got["ignored_config_paths"] == [] and got["ceiling_paths"] == []


# --- the checks against defective stubs: each must fail ---------------------------------------

def mutant(tmp: Path, name: str, anchor: str, inserted: str) -> Path:
    src = TOOL.read_text()
    assert src.count(anchor) == 1, f"mutation anchor {anchor!r} not found once in the tool"
    out = tmp / f"mutant-{name}"
    out.write_text(src.replace(anchor, anchor + inserted))
    # A sibling fleet-decl, as the real tool finds one.
    shutil.copy2(BIN / "executable_fleet-decl", tmp / "executable_fleet-decl")
    return out


PREFIX_STUB = (
    "    d = os.path.join(os.environ['MISE_CONFIG_DIR'], 'conf.d')\n"
    "    os.makedirs(d, exist_ok=True)\n"
    "    with open(os.path.join(d, '99-prefix.toml'), 'w') as f:\n"
    "        f.write('[settings]\\ntrusted_config_paths = [\"%s\"]\\n' % project.dir)\n"
    "    return True\n"
)


@needs_mise
def test_a_prefix_trusting_stub_fails_the_exact_file_check(world, tmp_path):
    stub = mutant(tmp_path, "prefix", "def trust_project(mise, project, dry_run):\n", PREFIX_STUB)
    with pytest.raises(AssertionError, match="is trusted"):
        check_only_exact_files_trusted(world, stub)


@needs_mise
def test_a_stub_without_the_ignore_list_fails_the_dependency_check(world, tmp_path):
    stub = mutant(tmp_path, "no-ignore", "def ignore_paths(project):\n", "    return []\n")
    with pytest.raises(AssertionError, match="is read, not ignored"):
        check_dependency_ignored(world, stub)


# --- the miseActive gate and the apply script ---------------------------------------------------

def chezmoi_config(tmp: Path, data_lines: str) -> Path:
    cfg = tmp / "c.toml"
    cfg.write_text('[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n'
                   + data_lines)
    return cfg


def render(tmp: Path, template: Path, data_lines: str, path_dirs: list[Path]) -> str:
    cfg = chezmoi_config(tmp, data_lines)
    env = dict(os.environ, PATH=os.pathsep.join(str(d) for d in path_dirs))
    with open(template) as stdin:
        out = subprocess.run(
            [CHEZMOI, "--config", str(cfg), "--source", str(ROOT),
             "--persistent-state", str(tmp / "s.db"), "execute-template"],
            stdin=stdin, env=env, capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    return out.stdout


def stub_bin(tmp: Path, with_mise: bool = True) -> Path:
    d = tmp / "stubbin"
    d.mkdir(exist_ok=True)
    if with_mise:
        (d / "mise").write_text("#!/bin/sh\nexit 0\n")
        (d / "mise").chmod(0o755)
    return d


TARGETS = {".local/bin/mise-fleet-trust", "trust-mise-configs.sh"}


@needs_chezmoi
@pytest.mark.parametrize("data_lines", ["", "    miseActive = false\n"], ids=["absent", "false"])
def test_inactive_ignores_the_tool_and_the_script(tmp_path, data_lines):
    ignored = set(render(tmp_path, ROOT / ".chezmoiignore", data_lines,
                         [stub_bin(tmp_path)]).split())
    missing = TARGETS - ignored
    assert not missing, f"not ignored while miseActive is off: {sorted(missing)}"


@needs_chezmoi
def test_active_deploys_the_tool_and_the_script(tmp_path):
    ignored = set(render(tmp_path, ROOT / ".chezmoiignore", "    miseActive = true\n",
                         [stub_bin(tmp_path)]).split())
    wrongly = TARGETS & ignored
    assert not wrongly, f"ignored although miseActive is on and mise is installed: {sorted(wrongly)}"


@needs_chezmoi
def test_active_without_mise_skips_only_the_script(tmp_path):
    ignored = set(render(tmp_path, ROOT / ".chezmoiignore", "    miseActive = true\n",
                         [stub_bin(tmp_path, with_mise=False)]).split())
    assert "trust-mise-configs.sh" in ignored, "the script runs where no mise is installed"
    assert ".local/bin/mise-fleet-trust" not in ignored


@needs_chezmoi
def test_script_hashes_the_tool_and_passes_the_source(tmp_path):
    text = render(tmp_path, SCRIPT, "    miseActive = true\n", [stub_bin(tmp_path)])
    assert hashlib.sha256(TOOL.read_bytes()).hexdigest() in text, "the tool's hash is not rendered"
    assert f'--base-source "{ROOT}"' in text, text


def run_rendered(tmp: Path, with_mise: bool) -> tuple[subprocess.CompletedProcess, Path]:
    text = render(tmp, SCRIPT, "    miseActive = true\n", [stub_bin(tmp)])
    script = tmp / "trust-mise-configs.sh"
    script.write_text(text)
    bindir = tmp / "runbin"
    bindir.mkdir()
    if with_mise:
        (bindir / "mise").write_text("#!/bin/sh\nexit 0\n")
        (bindir / "mise").chmod(0o755)
    log = tmp / "argv"
    (bindir / "mise-fleet-trust").write_text(
        f"#!{sys.executable}\nimport sys\nopen({str(log)!r}, 'w').write(' '.join(sys.argv[1:]))\n")
    (bindir / "mise-fleet-trust").chmod(0o755)
    # PATH holds only the stubs, so a mise installed on this machine cannot stand in for the stub's
    # absence; the script needs nothing else from PATH.
    env = dict(os.environ, PATH=str(bindir))
    out = subprocess.run(["/bin/sh", str(script)], env=env, capture_output=True, text=True,
                         timeout=60)
    return out, log


@needs_chezmoi
def test_rendered_script_runs_the_tool(tmp_path):
    out, log = run_rendered(tmp_path, with_mise=True)
    assert out.returncode == 0, out.stderr
    assert log.read_text() == f"--base-source {ROOT}", log.read_text()


@needs_chezmoi
def test_rendered_script_skips_without_mise(tmp_path):
    out, log = run_rendered(tmp_path, with_mise=False)
    assert out.returncode == 0, out.stderr
    assert "skipped" in out.stderr
    assert not log.exists(), "the tool ran where mise is not installed"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", *sys.argv[1:]]))
