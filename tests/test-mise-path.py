#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for where mise's shim directory and the SOPS age key file reach a machine's environment:
both are one value each in the base's chezmoi data (.chezmoidata.yaml), and every file that puts
them in a context's environment renders them from that value, behind the per-machine `miseActive`.

Run: npx nx run suite-mise-path:test
 or: uv run --script tests/test-mise-path.py [-k <pattern>]

What is held, for Linux and for macOS (rendered with the OS overridden in chezmoi's data):

* With `miseActive` true, ~/.zshenv, sourced by `zsh -f`, puts the shim directory first on PATH and
  exports DOTFILES_MISE_SHIMS naming it; on Linux it also exports SOPS_AGE_KEY_FILE, a file inside
  $XDG_RUNTIME_DIR. ~/.zprofile on macOS puts the shim directory first again after path_helper has
  reordered PATH. ~/.config/environment.d (Linux), read by systemd's own generator, gives the user
  manager the shim directory first and the key file. Every base systemd unit and LaunchAgent that
  sets its own PATH starts it with the shim directory, and none names fnm. ~/.zshrc renders neither
  the direnv nor the fnm hook.
* With `miseActive` false or absent, nothing of the above renders: no shim directory, neither
  variable, and the direnv and fnm hooks as before; false and absent render the same bytes. The units
  and agents held to this are the ones chezmoi deploys under that data (`chezmoi managed`), so a
  file .chezmoiignore keeps off such a machine, like the Linux SOPS key loader, is not; each one
  skipped is seen to deploy with the flag on.
* ~/.zshenv starts no process, with the flag on or off: it is sourced with forking forbidden
  (RLIMIT_NPROC of 1), and a planted command substitution is seen to fail the same probe.
* The shim directory and the key file name are each written once in the source: no template carries
  either literal.

Each chezmoi run uses a scratch config and persistent state; each zsh a scratch HOME. Cases skip
where chezmoi or zsh is not installed, and the generator case where systemd's is not.
"""
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
CHEZMOI = shutil.which("chezmoi")
ZSH = shutil.which("zsh")
GENERATOR = Path("/usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator")

SHIMS_REL = ".local/share/mise/shims"
KEY_FILE = "${XDG_RUNTIME_DIR}/sops-age-key.txt"

needs_chezmoi = pytest.mark.skipif(CHEZMOI is None, reason="chezmoi not installed")
needs_zsh = pytest.mark.skipif(ZSH is None, reason="zsh not installed")
pytestmark = needs_chezmoi

OSES = ["linux", "darwin"]
FLAGS = {"on": "    miseActive = true\n", "off": "    miseActive = false\n", "absent": ""}

UNIT_DIR = ROOT / "dot_config" / "systemd" / "user"
AGENT_DIR = ROOT / "private_Library" / "LaunchAgents"


# --- rendering -----------------------------------------------------------------------------------

def chezmoi_argv(tmp: Path, os_name: str, flag: str) -> list[str]:
    """chezmoi run against this source under a scratch config holding the flag, with chezmoi's OS
    set to os_name."""
    tmp.mkdir(parents=True, exist_ok=True)
    cfg = tmp / f"c-{flag}.toml"
    cfg.write_text('[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n'
                   + FLAGS[flag])
    return [CHEZMOI, "--config", str(cfg), "--source", str(ROOT), "--refresh-externals=never",
            "--persistent-state", str(tmp / f"s-{flag}.db"),
            "--override-data", '{"chezmoi":{"os":"%s"}}' % os_name]


def render_text(tmp: Path, text: str, os_name: str, flag: str) -> str:
    """Template text rendered by chezmoi under a scratch config, with chezmoi's OS set to os_name."""
    out = subprocess.run([*chezmoi_argv(tmp, os_name, flag), "execute-template"],
                         input=text, capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    return out.stdout


def deployed(tmp: Path, os_name: str, flag: str) -> set[str]:
    """The source paths, relative to the source root, that chezmoi deploys under the same scratch
    config: its own reading of .chezmoiignore, so a file ignored under that data is not in it."""
    # Externals are left out, and chezmoi_argv never refreshes them: past an external's refresh
    # period chezmoi fetches its archive again, which needs the network, and this suite runs
    # offline. Limit, measured: with chezmoi's cache EMPTY it still fetches every archive, so this
    # holds on a machine that has applied, not on a fresh one. The units and agents checked here
    # are never externals.
    out = subprocess.run([*chezmoi_argv(tmp, os_name, flag), "managed", "--exclude", "externals",
                          "--path-style", "source-relative"],
                         capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    found = set(out.stdout.splitlines())
    assert found, "chezmoi listed nothing as managed, so the deploy filter would see nothing"
    return found


def render(tmp: Path, source: Path, os_name: str, flag: str) -> str:
    """A source file as deployed: rendered when it is a template, else its bytes."""
    if source.name.endswith(".tmpl"):
        return render_text(tmp, source.read_text(), os_name, flag)
    return source.read_text()


def home_dir(tmp: Path) -> str:
    return render_text(tmp, "{{ .chezmoi.homeDir }}", "linux", "absent")


def sourced(tmp: Path, files: list[Path], script: str, preamble: str = "") -> subprocess.CompletedProcess:
    """`zsh -f` sourcing each file in turn under a scratch HOME and XDG_RUNTIME_DIR, then running
    script. PATH starts as the system directories only."""
    home = tmp / "home"
    run = tmp / "run"
    home.mkdir(exist_ok=True)
    run.mkdir(exist_ok=True)
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "XDG_RUNTIME_DIR": str(run),
           "TERM": "dumb"}
    body = preamble + "".join(f'source {f}\n' for f in files) + script
    return subprocess.run([ZSH, "-f", "-c", body], env=env, capture_output=True, text=True,
                          timeout=60)


def zshenv(tmp: Path, os_name: str, flag: str) -> Path:
    f = tmp / f"zshenv-{os_name}-{flag}"
    f.write_text(render(tmp, ROOT / "dot_zshenv.tmpl", os_name, flag))
    return f


# --- the data values -----------------------------------------------------------------------------

def test_data_holds_each_value_once(tmp_path):
    assert render_text(tmp_path, "{{ .mise_shims_dir }}", "linux", "absent") == SHIMS_REL
    assert render_text(tmp_path, "{{ .sops_age_key_file }}", "linux", "absent") == KEY_FILE


def test_no_template_repeats_either_literal():
    """One value, one place: the literals live in .chezmoidata.yaml only, so each consumer renders
    from it rather than holding a copy."""
    listed = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-co", "--exclude-standard"],
                            capture_output=True, text=True, check=True).stdout.splitlines()
    assert listed, "git listed nothing, so this check would see nothing"
    offenders = []
    for rel in listed:
        if rel == ".chezmoidata.yaml" or rel.startswith(("tests/", "docs/")) or rel.endswith(".md"):
            continue
        p = ROOT / rel
        if not p.is_file() or p.is_symlink():
            continue
        try:
            text = p.read_text()
        except UnicodeDecodeError:
            continue
        if "mise/shims" in text or "sops-age-key.txt" in text:
            offenders.append(rel)
    assert not offenders, f"the shim directory or key file written outside the data: {offenders}"


# --- ~/.zshenv -----------------------------------------------------------------------------------

@needs_zsh
@pytest.mark.parametrize("os_name", OSES)
def test_zshenv_on_puts_the_shims_first_and_exports_the_variables(tmp_path, os_name):
    out = sourced(tmp_path, [zshenv(tmp_path, os_name, "on")],
                  'print -r -- "$path[1]"; print -r -- "${(t)DOTFILES_MISE_SHIMS-}"; '
                  'print -r -- "${DOTFILES_MISE_SHIMS-}"; print -r -- "${(t)SOPS_AGE_KEY_FILE-}"; '
                  'print -r -- "${SOPS_AGE_KEY_FILE-}"\n')
    assert out.returncode == 0 and not out.stderr, out.stderr
    first, kind, shims, key_kind, key = out.stdout.split("\n")[:5]
    want = str(tmp_path / "home" / SHIMS_REL)
    assert first == want, f"PATH starts with {first!r}, not the shim directory {want!r}"
    assert kind == "scalar-export" and shims == want
    if os_name == "linux":
        assert key_kind == "scalar-export"
        assert key == str(tmp_path / "run" / "sops-age-key.txt")
    else:
        assert key_kind == "" and key == "", "SOPS_AGE_KEY_FILE set on macOS"


@needs_zsh
@pytest.mark.parametrize("os_name", OSES)
@pytest.mark.parametrize("flag", ["off", "absent"])
def test_zshenv_off_sets_nothing_of_mise(tmp_path, os_name, flag):
    f = zshenv(tmp_path, os_name, flag)
    text = f.read_text()
    assert "mise" not in text.lower() and "SOPS_AGE_KEY_FILE" not in text
    out = sourced(tmp_path, [f], 'print -r -- "${(j.:.)path}"; print -r -- "${+DOTFILES_MISE_SHIMS}'
                  '${+SOPS_AGE_KEY_FILE}"\n')
    assert out.returncode == 0 and not out.stderr, out.stderr
    path_line, set_flags = out.stdout.split("\n")[:2]
    assert "mise" not in path_line and set_flags == "00"


@needs_zsh
@pytest.mark.parametrize("os_name", OSES)
@pytest.mark.parametrize("flag", ["on", "off"])
def test_zshenv_starts_no_process(tmp_path, os_name, flag):
    out = sourced(tmp_path, [zshenv(tmp_path, os_name, flag)], "print -r -- sourced\n",
                  preamble="ulimit -u 1\n")
    assert out.stdout.strip() == "sourced" and not out.stderr, out.stderr


@needs_zsh
def test_the_process_probe_sees_a_planted_process(tmp_path):
    """The probe above is blind if forking is not actually refused under it; a command
    substitution planted in the rendered file must fail it."""
    f = zshenv(tmp_path, "linux", "on")
    f.write_text(f.read_text() + "planted=$(true)\n")
    out = sourced(tmp_path, [f], "print -r -- sourced\n", preamble="ulimit -u 1\n")
    assert "fork failed" in out.stderr, (out.stdout, out.stderr)


# --- ~/.zprofile ---------------------------------------------------------------------------------

@needs_zsh
def test_zprofile_on_macos_puts_the_shims_first_again_after_path_helper(tmp_path):
    zp = tmp_path / "zprofile"
    text = render(tmp_path, ROOT / "dot_zprofile.tmpl", "darwin", "on")
    zp.write_text(text)
    lines = text.splitlines()
    brew = next(i for i, l in enumerate(lines) if "/opt/homebrew/bin" in l and l.startswith("["))
    shim = next(i for i, l in enumerate(lines) if "mise" in l and l.startswith("path="))
    assert shim > brew, "the shim directory is prepended before Homebrew, which then precedes it"
    # path_helper, run by /etc/zprofile between the two files, puts the system directories first.
    helper = tmp_path / "path_helper"
    helper.write_text("path=(/usr/bin /bin /usr/sbin /sbin $path)\n")
    out = sourced(tmp_path, [zshenv(tmp_path, "darwin", "on"), helper, zp],
                  'print -r -- "$path[1]"\n')
    assert out.returncode == 0 and not out.stderr, out.stderr
    assert out.stdout.strip() == str(tmp_path / "home" / SHIMS_REL)


@pytest.mark.parametrize("os_name,flag", [("darwin", "off"), ("darwin", "absent"),
                                          ("linux", "on"), ("linux", "off")])
def test_zprofile_adds_no_shims_elsewhere(tmp_path, os_name, flag):
    """Linux login shells keep the order ~/.zshenv set; macOS adds the shims only when on."""
    assert "mise" not in render(tmp_path, ROOT / "dot_zprofile.tmpl", os_name, flag)


# --- ~/.config/environment.d (Linux) -------------------------------------------------------------

ENVD = ROOT / "dot_config" / "environment.d" / "session-env.conf.tmpl"


def test_environment_d_on_names_the_shims_and_the_key_file(tmp_path):
    text = render(tmp_path, ENVD, "linux", "on")
    shims = f"{home_dir(tmp_path)}/{SHIMS_REL}"
    assert f"PATH={shims}:${{PATH}}" in text.splitlines()
    assert f"DOTFILES_MISE_SHIMS={shims}" in text.splitlines()
    assert f"SOPS_AGE_KEY_FILE={KEY_FILE}" in text.splitlines()


@pytest.mark.skipif(not GENERATOR.exists(), reason="systemd's environment.d generator not present")
def test_environment_d_on_reaches_the_user_manager(tmp_path):
    """systemd's own generator, reading the rendered file, gives units the shims first on PATH and
    the key file inside XDG_RUNTIME_DIR."""
    d = tmp_path / "xdg" / "environment.d"
    d.mkdir(parents=True)
    (d / "session-env.conf").write_text(render(tmp_path, ENVD, "linux", "on"))
    run = tmp_path / "run"
    out = subprocess.run([str(GENERATOR)], env={"PATH": "/usr/bin:/bin", "HOME": str(tmp_path),
                         "XDG_RUNTIME_DIR": str(run), "XDG_CONFIG_HOME": str(tmp_path / "xdg")},
                         capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    got = dict(l.split("=", 1) for l in out.stdout.splitlines() if "=" in l)
    assert got["PATH"].split(":")[0] == f"{home_dir(tmp_path)}/{SHIMS_REL}"
    assert got["PATH"].endswith(":/usr/bin:/bin")
    assert got["SOPS_AGE_KEY_FILE"] == f"{run}/sops-age-key.txt"


@pytest.mark.parametrize("flag", ["off", "absent"])
def test_environment_d_off_names_nothing_of_mise(tmp_path, flag):
    text = render(tmp_path, ENVD, "linux", flag)
    assert "mise" not in text.lower() and "SOPS_AGE_KEY_FILE" not in text


# --- systemd units and LaunchAgents --------------------------------------------------------------

def units() -> list[Path]:
    found = sorted(p for p in UNIT_DIR.iterdir()
                   if re.search(r"\.service(\.tmpl)?$", p.name) and not p.name.startswith("symlink_"))
    assert found, "no units listed, so these checks would see nothing"
    return found


def agents() -> list[Path]:
    found = sorted(p for p in AGENT_DIR.iterdir() if p.name.endswith((".plist", ".plist.tmpl")))
    assert found, "no LaunchAgents listed, so these checks would see nothing"
    return found


def unit_path(text: str) -> str | None:
    m = re.search(r"^Environment=PATH=(\S+)$", text, re.M)
    return m.group(1) if m else None


def agent_path(text: str) -> str | None:
    return plistlib.loads(text.encode()).get("EnvironmentVariables", {}).get("PATH")


def test_every_unit_that_sets_path_starts_it_with_the_shims(tmp_path):
    setters = []
    for u in units():
        p = unit_path(render(tmp_path, u, "linux", "on"))
        if p is None:
            continue
        setters.append(u.name)
        assert p.split(":")[0] == f"%h/{SHIMS_REL}", f"{u.name}: PATH={p}"
        assert "fnm" not in p, f"{u.name} still names fnm: PATH={p}"
    assert setters, "no unit sets PATH, so this check saw nothing"


def test_every_agent_that_sets_path_starts_it_with_the_shims(tmp_path):
    setters = []
    for a in agents():
        p = agent_path(render(tmp_path, a, "darwin", "on"))
        if p is None:
            continue
        setters.append(a.name)
        assert p.split(":")[0] == f"{home_dir(tmp_path)}/{SHIMS_REL}", f"{a.name}: PATH={p}"
        assert "fnm" not in p, f"{a.name} still names fnm: PATH={p}"
    assert setters, "no LaunchAgent sets PATH, so this check saw nothing"


def rel(source: Path) -> str:
    return str(source.relative_to(ROOT))


@pytest.mark.parametrize("flag", ["off", "absent"])
def test_units_and_agents_off_name_no_shims(tmp_path, flag):
    """A unit or LaunchAgent that deploys with the flag off names no shims. One that .chezmoiignore
    leaves out under that data never reaches such a machine, so it is not held to this."""
    linux, darwin = deployed(tmp_path, "linux", flag), deployed(tmp_path, "darwin", flag)
    checked = []
    for u in units():
        if rel(u) in linux:
            checked.append(u.name)
            assert "mise" not in render(tmp_path, u, "linux", flag), u.name
    for a in agents():
        if rel(a) in darwin:
            checked.append(a.name)
            text = render(tmp_path, a, "darwin", flag)
            plistlib.loads(text.encode())
            assert "mise" not in text, a.name
    assert any(n.endswith((".service", ".service.tmpl")) for n in checked), "no unit checked"
    assert any(n.endswith((".plist", ".plist.tmpl")) for n in checked), "no LaunchAgent checked"


@pytest.mark.parametrize("flag", ["off", "absent"])
def test_what_the_off_check_skips_deploys_with_the_flag_on(tmp_path, flag):
    """The check above skips only what the flag itself keeps from deploying: each unit or agent left
    out with the flag off is in chezmoi's view with it on, so the skip is not a blind view."""
    for os_name, sources in (("linux", units()), ("darwin", agents())):
        off, on = deployed(tmp_path, os_name, flag), deployed(tmp_path / "on", os_name, "on")
        for s in sources:
            if rel(s) not in off:
                assert rel(s) in on, f"{s.name} deploys on {os_name} with miseActive neither on nor {flag}"


@pytest.mark.parametrize("flag", ["on", "off"])
def test_agents_render_valid_plists(tmp_path, flag):
    for a in agents():
        plistlib.loads(render(tmp_path, a, "darwin", flag).encode())


# --- ~/.zshrc: the direnv and fnm hooks ------------------------------------------------------------

HOOKS = ('eval "$(direnv hook zsh)"', 'eval "$(fnm env ')


@pytest.mark.parametrize("os_name", OSES)
def test_zshrc_on_renders_no_direnv_or_fnm_hook(tmp_path, os_name):
    text = render(tmp_path, ROOT / "dot_zshrc.tmpl", os_name, "on")
    for hook in HOOKS:
        assert hook not in text, f"{hook!r} still renders with miseActive on"


@pytest.mark.parametrize("os_name", OSES)
@pytest.mark.parametrize("flag", ["off", "absent"])
def test_zshrc_off_keeps_both_hooks(tmp_path, os_name, flag):
    text = render(tmp_path, ROOT / "dot_zshrc.tmpl", os_name, flag)
    for hook in HOOKS:
        assert hook in text, f"{hook!r} is gone with miseActive {flag}"


# --- false and absent are the same machine -------------------------------------------------------

def touched() -> list[Path]:
    return [ROOT / "dot_zshenv.tmpl", ROOT / "dot_zprofile.tmpl", ROOT / "dot_zshrc.tmpl", ENVD,
            *units(), *agents()]


@pytest.mark.parametrize("os_name", OSES)
def test_off_and_absent_render_the_same_bytes(tmp_path, os_name):
    for f in touched():
        assert (render(tmp_path, f, os_name, "off")
                == render(tmp_path, f, os_name, "absent")), f.name


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", *sys.argv[1:]]))
