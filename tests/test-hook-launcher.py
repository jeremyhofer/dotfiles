#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for hook-launcher, which the global commit hooks run each basic Python tool through so a
commit still goes through when mise's `python3` will not start in the repository.

Run: sh tests/run-all.sh --only test-hook-launcher.py
 or: uv run --script tests/test-hook-launcher.py [-k <pattern>]

What is held. Where mise's shim directory comes first on PATH, mise's `python3` fails, with exit 1
and a `mise ERROR`, in four cases: a never-trusted `mise.toml` in the directory, a trusted one that
does not parse, the global default naming a Python release that is not installed, and a SOPS file
a config loads whose age key is missing while `sops.strict` is on (mise's default). In each case:

* the plant is real: `python3` through the shim fails with that case's mise text, and the same
  directory without the plant runs mise's interpreter (the control);
* a commit through a launcher whose fallback branch is removed is refused (the red: what the hooks
  did before the launcher existed);
* a commit through the real launcher and the hook commands read from this repository's
  `dot_gitconfig` goes through, each hook printing exactly ONE launcher line naming that case's fix
  (for the config that does not parse, mise's own error), and no mise error text leaks;
* the tool runs on the machine's Python, not mise's.

Also: a planted British spelling still refuses the commit while the launcher falls back; a tool's
own exit status (3, 1, 0) passes through on both paths; mise's text matching no case names all
three fixes; a `python3` failure that is not mise's shim prints no launcher line; the shim
directory is the one DOTFILES_MISE_SHIMS names (the base exports it only where miseActive is on),
and with it unset or empty the launcher starts no `python3` at all, even with a shim directory on
PATH, and runs the tool directly.

Everything runs in a scratch HOME with scratch mise config, data, state and cache directories, a
scratch git config, and a stub fleet-decl that reports every repository as a fleet member (so the
spelling hooks act). mise's Python is the machine's own interpreter, linked into the scratch data
directory with `mise link` under a release number no real Python has (3.97.0), so nothing is
downloaded and the path `sys.executable` reports tells mise's run from the fallback. Needs mise,
codespell and git 2.54+ (configured hooks); the missing-key case also needs sops and age-keygen.
Each is a visible skip when absent.
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
LAUNCHER = ROOT / "private_dot_local" / "bin" / "executable_hook-launcher"
LINT = ROOT / "private_dot_local" / "bin" / "executable_us-spelling-lint"
GITCONFIG = ROOT / "dot_gitconfig"
HOOKS = ("us-spelling-pre-commit", "us-spelling-commit-msg")
MISE_PY = "3.97.0"      # the linked release: a number no real Python has
ABSENT_PY = "3.98.0"    # a release the global default names but nothing installs
PREFIX = "hook-launcher:"

# The case each plant must produce in mise's own words (read from mise 2026.11.5), and the fix the
# launcher's line must name.
CASES = {
    "untrusted": ("are not trusted", "mise trust"),
    "unparseable": ("Invalid TOML", "TOML parse error at line 1"),
    "not-installed": ("Tool not installed for shim: python3", "mise install"),
    "missing-key": ("no data key retrieved from metadata", "load the SOPS age key"),
}


def need(tool):
    if shutil.which(tool) is None:
        pytest.skip(f"{tool} not installed")


def git_has_configured_hooks():
    out = subprocess.run(["git", "--version"], capture_output=True, text=True).stdout
    m = re.search(r"(\d+)\.(\d+)", out)
    return bool(m) and (int(m[1]), int(m[2])) >= (2, 54)


def clean_path():
    """The caller's PATH without a virtualenv's bin (uv puts one first for this suite) or any mise
    shim directory, so `python3` on it is the machine's own."""
    drop = {str(Path(sys.prefix) / "bin")}
    if os.environ.get("VIRTUAL_ENV"):
        drop.add(str(Path(os.environ["VIRTUAL_ENV"]) / "bin"))
    keep = [d for d in os.environ.get("PATH", "").split(":")
            if d and d.rstrip("/") not in drop and not d.rstrip("/").endswith("/mise/shims")]
    return ":".join(keep)


class World:
    """The scratch machine every case shares: HOME, mise directories, the linked Python, the stub
    fleet-decl, the launcher and the spelling tool installed where the hooks look."""

    def __init__(self, tmp: Path, launcher_text: str | None = None):
        self.tmp = tmp
        self.home = tmp / "home"
        self.bin = self.home / ".local" / "bin"
        self.bin.mkdir(parents=True)
        self.data = self.home / ".local" / "share" / "mise"   # mise's default, made explicit
        self.shims = self.data / "shims"
        self.state = tmp / "mise-state"
        self.cache = tmp / "mise-cache"
        self.xdg_config = tmp / "xdg-config"                  # rops' default key path lives here
        for d in (self.data, self.state, self.cache, self.xdg_config):
            d.mkdir(parents=True, exist_ok=True)
        self.base_path = clean_path()
        self.machine_python = shutil.which("python3", path=self.base_path)
        assert self.machine_python, "no python3 on PATH outside mise"

        # The launcher and the tool, installed where dot_gitconfig's hook commands find them.
        if launcher_text is None:
            assert LAUNCHER.is_file(), f"{LAUNCHER} does not exist"
            launcher_text = LAUNCHER.read_text()
        self.install("hook-launcher", launcher_text)
        self.install("us-spelling-lint", LINT.read_text())

        # A stub fleet-decl: every repository is a member, tagged internal.
        stub = tmp / "stub-bin"
        stub.mkdir()
        (stub / "fleet-decl").write_text(
            "#!/bin/sh\n"
            '[ "$1" = --project ] && exit 0\n'
            '[ "$2" = tags ] && { echo "[internal]"; exit 0; }\n'
            "exit 1\n")
        (stub / "fleet-decl").chmod(0o755)
        self.stub = stub
        self.record = tmp / "mani.yaml"
        self.record.write_text("projects: {}\n")

        # The global git config: the two hook commands exactly as this repository ships them.
        self.gitconfig = tmp / "gitconfig"
        self.gitconfig.write_text("")
        for hook in HOOKS:
            for key in ("command", "event"):
                value = subprocess.run(
                    ["git", "config", "--file", str(GITCONFIG), "--get", f"hook.{hook}.{key}"],
                    capture_output=True, text=True, check=True).stdout.rstrip("\n")
                self.gitcfg(f"hook.{hook}.{key}", value)
        self.gitcfg("user.name", "Test")
        self.gitcfg("user.email", "test@example.invalid")
        self.gitcfg("commit.gpgsign", "false")
        self.gitcfg("init.defaultBranch", "main")

        # mise: the machine's Python linked as release 3.97.0, a shim for it, home's two settings.
        self.fakepy = tmp / "fakepy"
        (self.fakepy / "bin").mkdir(parents=True)
        (self.fakepy / "bin" / "python3").symlink_to(os.path.realpath(self.machine_python))
        self.config_root = tmp / "mise-config"
        self.mise_config(self.config_root, MISE_PY)
        self.mise(self.config_root, "link", f"python@{MISE_PY}", str(self.fakepy))
        self.mise(self.config_root, "reshim")
        assert (self.shims / "python3").exists(), "mise made no python3 shim"
        self.mise_python = str(self.data / "installs" / "python" / MISE_PY / "bin" / "python3")

        # A basic tool that reports which interpreter ran it and exits with its first argument.
        self.probe = tmp / "probe-tool"
        self.probe.write_text("#!/usr/bin/env python3\nimport sys\nprint(sys.executable)\n"
                              "sys.exit(int(sys.argv[1]) if len(sys.argv) > 1 else 0)\n")
        self.probe.chmod(0o755)

    def install(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o755)

    def gitcfg(self, key, value):
        subprocess.run(["git", "config", "--file", str(self.gitconfig), key, value], check=True)

    @staticmethod
    def mise_config(cfg: Path, default: str):
        (cfg / "conf.d").mkdir(parents=True, exist_ok=True)
        (cfg / "config.toml").write_text(f'[tools]\npython = "{default}"\n')
        (cfg / "conf.d" / "20-settings.toml").write_text(
            "[settings]\nauto_install = false\nnot_found_system_fallback = false\n"
            "use_versions_host = false\n")

    def env(self, cfg: Path, **extra):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("MISE_", "SOPS_", "GIT_", "XDG_", "VIRTUAL_ENV", "DOTFILES_"))}
        env.update({
            "HOME": str(self.home),
            "PATH": f"{self.shims}:{self.stub}:{self.base_path}",
            "MISE_CONFIG_DIR": str(cfg),
            "MISE_DATA_DIR": str(self.data),
            "MISE_STATE_DIR": str(self.state),
            "MISE_CACHE_DIR": str(self.cache),
            "XDG_CONFIG_HOME": str(self.xdg_config),
            "GIT_CONFIG_GLOBAL": str(self.gitconfig),
            "GIT_CONFIG_NOSYSTEM": "1",
            "FLEET_RECORD": str(self.record),
            # The base's seam: set only where miseActive is on, naming the shim directory.
            "DOTFILES_MISE_SHIMS": str(self.shims),
        })
        for k, v in extra.items():
            if v is None:
                env.pop(k, None)
            else:
                env[k] = v
        return env

    def mise(self, cfg, *args):
        env = self.env(cfg)
        env["PATH"] = f"{self.stub}:{self.base_path}"
        r = subprocess.run(["mise", *args], capture_output=True, text=True, env=env,
                           stdin=subprocess.DEVNULL, timeout=60)
        assert r.returncode == 0, f"mise {' '.join(args)}: {r.stderr}"
        return r

    def run(self, argv, cwd, cfg, **extra):
        return subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                              env=self.env(cfg, **extra), stdin=subprocess.DEVNULL, timeout=120)

    def repo(self, name):
        r = self.tmp / "repos" / name
        r.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(r)], check=True,
                       env=self.env(self.config_root))
        (r / "seed.md").write_text("seed\n")
        self.run(["git", "add", "seed.md"], r, self.config_root)
        c = self.run(["git", "commit", "-qm", "seed"], r, self.config_root)
        assert c.returncode == 0, c.stdout + c.stderr
        return r


def plant(world: World, case: str, name: str):
    """A repository and a mise config directory holding the planted case; returns (repo, cfg, env
    extras)."""
    r = world.repo(name)
    cfg = world.tmp / "cfg" / name
    world.mise_config(cfg, MISE_PY)
    extra = {}
    if case == "untrusted":
        # A config that only pins tools needs no trust; one with [env] does.
        (r / "mise.toml").write_text('[env]\nPLANTED = "1"\n')
    elif case == "unparseable":
        (r / "mise.toml").write_text("[tools\n")
        world.mise(cfg, "trust", str(r / "mise.toml"))
    elif case == "not-installed":
        world.mise_config(cfg, ABSENT_PY)
    elif case == "missing-key":
        need("sops")
        need("age-keygen")
        sops = world.tmp / "sops" / name
        sops.mkdir(parents=True)
        subprocess.run(["age-keygen", "-o", str(sops / "key.txt")], check=True,
                       capture_output=True)
        pub = subprocess.run(["age-keygen", "-y", str(sops / "key.txt")], check=True,
                             capture_output=True, text=True).stdout.strip()
        (sops / "plain.json").write_text('{"PLANTED_VALUE": "made-up"}\n')
        enc = subprocess.run(["sops", "encrypt", "--age", pub, "--input-type", "json",
                              "--output-type", "json", str(sops / "plain.json")],
                             check=True, capture_output=True, text=True,
                             env=world.env(cfg)).stdout
        (sops / "plain.json").unlink()
        (sops / "secrets.sops.json").write_text(enc)
        (sops / "key.txt").unlink()   # the key is gone; strict decryption must fail
        (cfg / "conf.d" / "30-secrets.toml").write_text(
            f'[env]\n_.file = "{sops / "secrets.sops.json"}"\n')
        extra["SOPS_AGE_KEY_FILE"] = str(sops / "key.txt")
    else:
        raise AssertionError(case)
    return r, cfg, extra


def launcher_lines(text):
    return [line for line in text.splitlines() if line.startswith(PREFIX)]


def commit(world, r, cfg, message="add a", body="The behavior.\n", **extra):
    (r / "a.md").write_text(body)
    world.run(["git", "add", "a.md"], r, cfg, **extra)
    before = world.run(["git", "rev-parse", "HEAD"], r, cfg).stdout
    c = world.run(["git", "commit", "-m", message], r, cfg, **extra)
    after = world.run(["git", "rev-parse", "HEAD"], r, cfg).stdout
    return c, before != after


@pytest.fixture(scope="module")
def world(tmp_path_factory):
    need("mise")
    need("codespell")
    if not git_has_configured_hooks():
        pytest.skip("git lacks configured hooks (needs 2.54+)")
    return World(tmp_path_factory.mktemp("launcher"))


@pytest.fixture(scope="module")
def no_fallback(tmp_path_factory):
    """The same machine with the launcher's fallback branch removed: what is left of it runs the
    tool and nothing else."""
    need("mise")
    need("codespell")
    if not git_has_configured_hooks():
        pytest.skip("git lacks configured hooks (needs 2.54+)")
    return World(tmp_path_factory.mktemp("nofallback"), launcher_text='#!/bin/sh\nexec "$@"\n')


def test_hooks_are_wired_through_the_launcher():
    for hook in HOOKS:
        cmd = subprocess.run(["git", "config", "--file", str(GITCONFIG), "--get",
                              f"hook.{hook}.command"], capture_output=True, text=True).stdout
        assert cmd.startswith('"$HOME/.local/bin/hook-launcher" "$HOME/.local/bin/us-spelling-lint"'), cmd


def test_control_mise_resolves_and_the_launcher_is_silent(world):
    r = world.repo("control")
    p = world.run([str(world.bin / "hook-launcher"), str(world.probe)], r, world.config_root)
    assert p.returncode == 0, p.stderr
    assert p.stdout.strip() == world.mise_python, "mise's shim did not run the tool"
    assert p.stderr == ""
    c, made = commit(world, r, world.config_root)
    assert c.returncode == 0 and made, c.stdout + c.stderr
    assert launcher_lines(c.stderr) == []


@pytest.mark.parametrize("case", list(CASES))
def test_the_plant_breaks_mise(world, case):
    r, cfg, extra = plant(world, case, f"real-{case}")
    p = world.run(["python3", "-c", ""], r, cfg, **extra)
    assert p.returncode != 0, f"{case}: python3 still starts, so the plant is not a plant"
    assert CASES[case][0] in p.stderr, p.stderr


@pytest.mark.parametrize("case", list(CASES))
def test_red_without_the_fallback_the_commit_is_refused(no_fallback, case):
    r, cfg, extra = plant(no_fallback, case, f"red-{case}")
    c, made = commit(no_fallback, r, cfg, **extra)
    assert c.returncode != 0 and not made, f"{case}: committed without the fallback"
    assert "mise ERROR" in c.stderr or "Invalid TOML" in c.stderr, c.stderr


@pytest.mark.parametrize("case", list(CASES))
def test_the_commit_passes_with_one_line_naming_the_fix(world, case):
    r, cfg, extra = plant(world, case, f"green-{case}")
    c, made = commit(world, r, cfg, **extra)
    assert c.returncode == 0 and made, f"{case}: {c.stdout}{c.stderr}"
    lines = launcher_lines(c.stderr)
    # Two hooks ran (pre-commit and commit-msg), each through the launcher: one line each.
    assert len(lines) == 2, c.stderr
    assert lines[0] == lines[1], lines
    assert CASES[case][1] in lines[0], lines[0]
    assert "mise ERROR" not in c.stderr, c.stderr
    assert "\n" not in lines[0]


@pytest.mark.parametrize("case", list(CASES))
def test_the_fallback_runs_the_machines_python_with_one_line(world, case):
    r, cfg, extra = plant(world, case, f"probe-{case}")
    p = world.run([str(world.bin / "hook-launcher"), str(world.probe)], r, cfg, **extra)
    assert p.returncode == 0, p.stderr
    assert p.stdout.strip() == world.machine_python, p.stdout
    assert len(p.stderr.splitlines()) == 1, p.stderr
    assert p.stderr.startswith(PREFIX) and CASES[case][1] in p.stderr, p.stderr


def test_the_fix_lines_are_specific(world):
    """Each case names its own fix and not another case's."""
    seen = {}
    for case in CASES:
        r, cfg, extra = plant(world, case, f"specific-{case}")
        seen[case] = world.run([str(world.bin / "hook-launcher"), str(world.probe)], r, cfg,
                               **extra).stderr
    assert "mise install" not in seen["untrusted"] and "SOPS" not in seen["untrusted"]
    assert "mise trust" not in seen["not-installed"] and "SOPS" not in seen["not-installed"]
    assert "mise trust" not in seen["missing-key"] and "mise install" not in seen["missing-key"]
    for fix in ("mise trust", "mise install", "SOPS"):
        assert fix not in seen["unparseable"], seen["unparseable"]
    assert "mise.toml" in seen["unparseable"], "the parse line does not name the file"


def test_a_british_spelling_still_fails_the_commit(world):
    r, cfg, extra = plant(world, "untrusted", "british")
    c, made = commit(world, r, cfg, body="The behaviour.\n", **extra)
    assert c.returncode != 0 and not made, c.stdout + c.stderr
    assert "a.md:1: behaviour ==> behavior" in c.stdout + c.stderr
    assert len(launcher_lines(c.stderr)) == 1, c.stderr   # pre-commit refused; commit-msg never ran


@pytest.mark.parametrize("code", [3, 1, 0])
@pytest.mark.parametrize("case", [None, "untrusted"])
def test_the_tools_exit_status_passes_through(world, case, code):
    if case is None:
        r, cfg, extra = world.repo(f"exit-{code}"), world.config_root, {}
    else:
        r, cfg, extra = plant(world, case, f"exit-{case}-{code}")
    p = world.run([str(world.bin / "hook-launcher"), str(world.probe), str(code)], r, cfg, **extra)
    assert p.returncode == code, p.stderr


def test_unknown_mise_text_names_all_three_fixes(world, tmp_path):
    """A python3 in the shim directory failing with text that matches no case."""
    shims = tmp_path / "share" / "mise" / "shims"
    shims.mkdir(parents=True)
    (shims / "python3").write_text("#!/bin/sh\necho 'mise ERROR something new' >&2\nexit 1\n")
    (shims / "python3").chmod(0o755)
    r = world.repo("unknown")
    p = world.run([str(world.bin / "hook-launcher"), str(world.probe)], r, world.config_root,
                  DOTFILES_MISE_SHIMS=str(shims),
                  PATH=f"{shims}:{world.stub}:{world.base_path}")
    assert p.returncode == 0, p.stderr
    assert p.stdout.strip() == world.machine_python
    assert len(p.stderr.splitlines()) == 1, p.stderr
    for fix in ("mise trust", "mise install", "load the SOPS age key"):
        assert fix in p.stderr, p.stderr


def test_a_failure_outside_the_shim_directory_prints_no_line(world, tmp_path):
    """python3 failing where mise's shims are not is not mise's case: the tool runs as it is and
    reports for itself."""
    other = tmp_path / "other-bin"
    other.mkdir()
    (other / "python3").write_text("#!/bin/sh\nexit 7\n")
    (other / "python3").chmod(0o755)
    r = world.repo("outside")
    p = world.run([str(world.bin / "hook-launcher"), str(world.probe)], r, world.config_root,
                  PATH=f"{other}:{world.stub}:{world.base_path}")
    assert p.returncode == 7, (p.returncode, p.stderr)
    assert launcher_lines(p.stderr) == []


@pytest.mark.parametrize("seam", ["set", "unset", "empty"])
def test_without_the_seam_the_launcher_does_not_probe(world, tmp_path, seam):
    """DOTFILES_MISE_SHIMS is what says mise is active on the machine. Unset or empty, the launcher
    runs the tool directly, starting no `python3`, even with a shim directory on PATH and
    MISE_DATA_DIR pointing at it (so a launcher working out mise's default directory would find it
    and probe). Set, the same counting `python3` is seen to start once, so the count can see a
    probe."""
    data = tmp_path / "share" / "mise"
    shims = data / "shims"
    shims.mkdir(parents=True)
    starts = tmp_path / "starts"
    (shims / "python3").write_text(
        f'#!/bin/sh\necho start >> "{starts}"\nexec "{world.machine_python}" "$@"\n')
    (shims / "python3").chmod(0o755)
    tool = tmp_path / "tool"
    tool.write_text("#!/bin/sh\nexit 5\n")
    tool.chmod(0o755)
    value = {"set": str(shims), "unset": None, "empty": ""}[seam]
    p = world.run([str(world.bin / "hook-launcher"), str(tool)], world.tmp, world.config_root,
                  MISE_DATA_DIR=str(data), DOTFILES_MISE_SHIMS=value,
                  PATH=f"{shims}:{world.stub}:{world.base_path}")
    assert p.returncode == 5, (p.returncode, p.stderr)
    assert p.stderr == "", p.stderr
    count = starts.read_text().count("start") if starts.exists() else 0
    assert count == (1 if seam == "set" else 0), f"{seam}: python3 started {count} times"


def test_no_tool_is_a_usage_error(world):
    p = world.run([str(world.bin / "hook-launcher")], world.tmp, world.config_root)
    assert p.returncode == 2 and "usage" in p.stderr


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v", *sys.argv[1:]]))
