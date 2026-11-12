#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""The installed mise, checked on this machine: the suite every apply runs where mise is active.

Run: npx nx run suite-mise-installed:test
 or: uv run --script tests/test-mise-installed.py [-k <pattern>]

WHY IT EXISTS. mise is not pinned: it moves with the package manager. The base's drop-in sets a
version floor, and this suite checks, at every apply and after every package update, that the mise
now installed still does what the fleet relies on:
  * a pin resolves: a project's `[tools]` version runs through the shim;
  * a missing version fails, where the machine's drop-ins set `auto_install = false` and
    `not_found_system_fallback = false` (checked only there; skipped with the values elsewhere);
  * an untrusted config is refused: its shim fails and its `[env]` reaches nothing;
  * a dependency's config is ignored: a trusted `node_modules/<dep>/mise.toml` under a path in
    `ignored_config_paths` sets nothing;
  * a SOPS file decrypts: with `sops.strict` off, the decrypted value reaches a process (asserted in
    that process, never printed), through mise's built-in decryption with a key file; on macOS a
    second time through the external `sops`, with `SOPS_AGE_KEY_CMD` printing the key;
  * no age key sits at a default key path, where either decrypter would find it with no variable
    set: `~/.config/mise/age.txt`; on Linux `~/.config/sops/age/keys.txt`, on macOS
    `~/Library/Application Support/sops/age/keys.txt`; on both `$XDG_CONFIG_HOME/sops/age/keys.txt`
    where XDG_CONFIG_HOME is set;
  * every file the domain lists in `~/.dotlocal/mise/required-files` exists (the seam:
    docs/reference/private-layer.md, "mise checks"). Absent list, nothing required.
A failing check fails the suite, and so the apply.

ACTIVE, OR INERT. The suite runs only where the base's mise drop-in is deployed:
`<mise config dir>/conf.d/10-base.toml`, the config dir found as mise finds it ($MISE_CONFIG_DIR,
else $XDG_CONFIG_HOME/mise, else ~/.config/mise). The drop-in deploys only on a machine whose chezmoi
data sets `miseActive`, so its presence is that switch as deployed. Read from the file rather than
from `chezmoi data` because: the suite also runs outside an apply (the commit gate, the landing gate,
a hand run), where no chezmoi state is involved; on the apply that switches a machine on, the
pre-apply run comes before the drop-in is written, so the checks first run against a machine whose
mise settings are in place; and a drop-in left behind after the switch is turned off still sets this
machine's mise, so it is still checked. Without the drop-in every test SKIPs, naming the path. With
it and no mise on PATH, the suite fails: the machine was switched on without mise.

EVERYTHING MISE WRITES IS SCRATCH. Each check runs mise with MISE_DATA_DIR, MISE_STATE_DIR and
MISE_CACHE_DIR in a temporary directory, so no check installs a version, records trust or caches
anything on the machine. The CONFIG dir is the machine's, read and never written, so the checks run
under the drop-ins this machine deploys; MISE_GLOBAL_CONFIG_FILE is never set, since it would replace
that configuration. A pin is a fake install of an impossible Node version in the scratch data
directory, so nothing is downloaded and the check needs no network.

THE PROBES' ENVIRONMENT. Every MISE_* and SOPS_* variable of the caller is dropped, then only the
check's own are set: so a machine key (SOPS_AGE_KEY_FILE, SOPS_AGE_KEY, SOPS_AGE_KEY_CMD) never
reaches a probe, the decrypt check uses its throwaway key alone, and a caller's
MISE_TRUSTED_CONFIG_PATHS cannot trust the untrusted fixture. MISE_SOPS_STRICT=false for every
probe: a domain drop-in may load a SOPS file of its own, which the throwaway key cannot open, and
strict mode would fail every command on it. The decrypt check asserts the value reached its process,
which is the property strict mode would otherwise stand in for. Installing is switched off for every
probe but the missing-version one (MISE_AUTO_INSTALL and its two siblings false), so a tool the
machine's global config names is never downloaded into the scratch data dir; the missing-version
probe runs under the machine's own settings, and only where they forbid installing.

EACH CHECK IS SEEN TO FAIL, EVERY RUN. A check is a setup step building its fixture and a probe
returning the problems it finds. Beside each machine test, a plant test runs the same check in a
scratch world twice: unchanged (it must pass, the control) and with one defect planted between
setup and probe (it must report that defect): the pinned version's install removed, the system
fallback forced on, the untrusted fixture trusted, the ignore list dropped, the throwaway key
removed, a key at each default path, a listed file missing. A check that cannot fail fails its plant.

Needs, where active: mise, sops and age-keygen on PATH. The macOS second decrypt is a machine test
only on macOS (Linux machines decrypt with a key file), but its plant test runs wherever
sops is installed.
"""
import os
import platform
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

BASE_DROPIN = Path("conf.d") / "10-base.toml"
REQUIRED_LIST = Path(".dotlocal") / "mise" / "required-files"
# Node versions that will never exist, so a probe can never resolve or download a real one.
PIN = "1999.1.2"
MISSING = "1999.0.7"
SECRET_VAR = "DOTFILES_MISE_SOPS_PROBE"
TRUST_VAR = "DOTFILES_MISE_TRUST_PROBE"
TIMEOUT = 120
# Every probe but the missing-version one: a machine whose global config names a tool the scratch
# data dir lacks would otherwise download it on each run.
NO_INSTALL = {"MISE_AUTO_INSTALL": "false", "MISE_EXEC_AUTO_INSTALL": "false",
              "MISE_NOT_FOUND_AUTO_INSTALL": "false"}


def mise_config_dir(env: dict) -> Path:
    if env.get("MISE_CONFIG_DIR"):
        return Path(env["MISE_CONFIG_DIR"])
    home = Path(env.get("HOME") or Path.home())
    return Path(env.get("XDG_CONFIG_HOME") or home / ".config") / "mise"


def base_dropin(env: dict) -> Path:
    return mise_config_dir(env) / BASE_DROPIN


ACTIVE = base_dropin(os.environ).is_file()
pytestmark = pytest.mark.skipif(
    not ACTIVE, reason=f"mise is not active on this machine: {base_dropin(os.environ)} is not deployed")


# --- the two file checks ----------------------------------------------------------------------------

def default_key_paths(home: Path, env: dict, system: str) -> list:
    """Where mise's built-in decryption or the external sops finds an age key with nothing set."""
    paths = [home / ".config" / "mise" / "age.txt"]
    if system == "Darwin":
        paths.append(home / "Library" / "Application Support" / "sops" / "age" / "keys.txt")
    else:
        paths.append(home / ".config" / "sops" / "age" / "keys.txt")
    if env.get("XDG_CONFIG_HOME"):
        paths.append(Path(env["XDG_CONFIG_HOME"]) / "sops" / "age" / "keys.txt")
    out = []
    for p in paths:
        if p not in out:
            out.append(p)
    return out


def keys_at_default_paths(home: Path, env: dict, system: str) -> list:
    return [f"an age key sits at a default key path, where a decrypter would use it unasked: {p}"
            for p in default_key_paths(home, env, system) if os.path.lexists(p)]


def required_files_problems(home: Path) -> list:
    """The domain's list of files that must exist: one absolute or ~/ path per line, blank lines and
    # comments ignored. No list, nothing required."""
    listing = home / REQUIRED_LIST
    if not os.path.lexists(listing):
        return []
    try:
        lines = listing.read_text().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        return [f"{listing} cannot be read: {e}"]
    problems = []
    for n, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        p = home / line[2:] if line.startswith("~/") else Path(line)
        if not p.is_absolute():
            problems.append(f"{listing}:{n}: {line!r} is neither absolute nor ~/-relative")
        elif not p.is_file():
            problems.append(f"{listing}:{n}: required file {p} does not exist (or is not a file)")
    return problems


# --- the scratch mise world the probes run in ----------------------------------------------------------

def probe_env(caller: dict, config_dir: Path, root: Path, home: Path) -> dict:
    """The caller's environment without its MISE_* and SOPS_* variables, plus scratch mise directories
    under `root` and the machine's config dir. MISE_GLOBAL_CONFIG_FILE is never set."""
    env = {k: v for k, v in caller.items() if not k.startswith(("MISE_", "SOPS_"))}
    env.update({
        "HOME": str(home),
        "MISE_CONFIG_DIR": str(config_dir),
        "MISE_DATA_DIR": str(root / "data"),
        "MISE_STATE_DIR": str(root / "state"),
        "MISE_CACHE_DIR": str(root / "cache"),
        "MISE_SOPS_STRICT": "false",
    })
    env["PATH"] = os.pathsep.join([str(root / "data" / "shims"), str(root / "sys"), caller.get("PATH", "")])
    return env


class Rig:
    def __init__(self, root: Path, config_dir: Path, home: Path, caller: dict):
        self.root = root
        self.home = home
        for d in ("data", "state", "cache", "sys", "fixtures", "neutral"):
            (root / d).mkdir(parents=True, exist_ok=True)
        self.env = probe_env(caller, config_dir, root, home)
        assert "MISE_GLOBAL_CONFIG_FILE" not in self.env
        self.mise = shutil.which("mise", path=caller.get("PATH", ""))
        # A stand-in for the machine's own node, after the shims on PATH: a probe that reaches it
        # fell back to the system.
        self.script(root / "sys" / "node", 'echo "SYSTEM-NODE"\n')

    @staticmethod
    def script(p: Path, body: str) -> None:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("#!/bin/sh\n" + body)
        p.chmod(0o755)

    def run(self, argv: list, cwd: Path, extra: dict | None = None,
            machine_installs: bool = False) -> subprocess.CompletedProcess:
        """Run a probe. Unless `machine_installs`, installing is switched off for it, so a tool the
        machine's global config names is never downloaded into the scratch data dir."""
        env = {**self.env, **({} if machine_installs else NO_INSTALL), **(extra or {})}
        return subprocess.run(argv, cwd=str(cwd), env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=TIMEOUT)

    def mise_ok(self, *args: str, cwd: Path | None = None, machine_installs: bool = False) -> str:
        r = self.run([self.mise, *args], cwd or self.root / "neutral", machine_installs=machine_installs)
        if r.returncode != 0:
            raise RuntimeError(f"mise {' '.join(args)} failed (exit {r.returncode}): {r.stderr.strip()}")
        return r.stdout.strip()

    def install_fake_node(self, version: str) -> None:
        """A Node install mise counts as installed, in the scratch data dir, then its shim."""
        self.script(self.root / "data" / "installs" / "node" / version / "bin" / "node",
                    f'echo "RIG-NODE {version} trust-probe=${TRUST_VAR}"\n')
        self.mise_ok("reshim")

    def project(self, name: str, files: dict) -> Path:
        d = self.root / "fixtures" / name
        for rel, text in files.items():
            (d / rel).parent.mkdir(parents=True, exist_ok=True)
            (d / rel).write_text(text)
        return d

    def trust(self, p: Path) -> None:
        self.mise_ok("trust", str(p))

    def setting(self, name: str) -> str:
        """The value this machine's configuration gives, with no override from this suite."""
        return self.mise_ok("settings", "get", name, machine_installs=True)


# --- the mise checks: setup builds a fixture, probe returns the problems ---------------------------------

def setup_pin(rig: Rig) -> Path:
    rig.install_fake_node(PIN)
    proj = rig.project("pin", {"mise.toml": f'[tools]\nnode = "{PIN}"\n'})
    rig.trust(proj / "mise.toml")
    return proj


def probe_pin(rig: Rig, proj: Path) -> list:
    r = rig.run(["node"], proj)
    if r.returncode == 0 and f"RIG-NODE {PIN}" in r.stdout:
        return []
    return [f"a pin did not resolve: node pinned to {PIN} in {proj} gave exit {r.returncode}, "
            f"stdout {r.stdout.strip()!r}, stderr {r.stderr.strip()[-300:]!r}"]


def d7_set(rig: Rig) -> tuple:
    """(set, why): whether this machine's drop-ins set both settings a missing version fails under."""
    auto, fallback = rig.setting("auto_install"), rig.setting("not_found_system_fallback")
    return (auto == "false" and fallback == "false",
            f"auto_install={auto}, not_found_system_fallback={fallback}")


def setup_missing(rig: Rig) -> Path:
    rig.install_fake_node(PIN)  # a Node is installed, just not the pinned one
    proj = rig.project("missing", {"mise.toml": f'[tools]\nnode = "{MISSING}"\n'})
    rig.trust(proj / "mise.toml")
    return proj


def probe_missing(rig: Rig, proj: Path, extra: dict | None = None) -> list:
    # Under the machine's own install settings: they are what this check is about. Reached only
    # where they forbid installing, so nothing is downloaded.
    r = rig.run(["node"], proj, extra, machine_installs=True)
    problems = []
    if r.returncode == 0:
        problems.append(f"a missing version did not fail: node pinned to {MISSING}, not installed, exited 0")
    if "SYSTEM-NODE" in r.stdout:
        problems.append("a missing version fell back to the system's node")
    if MISSING not in r.stderr:
        problems.append(f"the failure does not name the missing version {MISSING}: {r.stderr.strip()[-300:]!r}")
    return problems


def setup_untrusted(rig: Rig) -> Path:
    rig.install_fake_node(PIN)
    return rig.project("untrusted", {"mise.toml": f'[tools]\nnode = "{PIN}"\n[env]\n{TRUST_VAR} = "loaded"\n'})


def probe_untrusted(rig: Rig, proj: Path) -> list:
    r = rig.run(["node"], proj)
    problems = []
    if r.returncode == 0:
        problems.append(f"an untrusted config was not refused: its shim exited 0 ({r.stdout.strip()!r})")
    if "trust-probe=loaded" in r.stdout:
        problems.append("an untrusted config's [env] reached a process")
    if "not trusted" not in r.stderr:
        problems.append(f"the refusal does not say the config is not trusted: {r.stderr.strip()[-300:]!r}")
    return problems


def setup_dependency(rig: Rig) -> tuple:
    proj = rig.project("deps", {
        "mise.toml": '[env]\nDOTFILES_MISE_PROJECT_PROBE = "project"\n',
        "node_modules/dep/mise.toml": '[env]\nDOTFILES_MISE_DEP_PROBE = "dependency"\n',
    })
    # Both trusted, so the ignore list is the only thing between the dependency's config and a process.
    rig.trust(proj / "mise.toml")
    rig.trust(proj / "node_modules" / "dep" / "mise.toml")
    return proj, {"MISE_IGNORED_CONFIG_PATHS": str(proj / "node_modules")}


def probe_dependency(rig: Rig, fixture: tuple) -> list:
    proj, ignore = fixture
    r = rig.run([rig.mise, "x", "--", "sh", "-c",
                 'printf "%s|%s" "$DOTFILES_MISE_PROJECT_PROBE" "$DOTFILES_MISE_DEP_PROBE"'],
                proj / "node_modules" / "dep", ignore)
    if r.returncode == 0 and r.stdout == "project|":
        return []
    return [f"a dependency's config was not ignored under ignored_config_paths: exit {r.returncode}, "
            f"project|dependency values {r.stdout!r}, stderr {r.stderr.strip()[-300:]!r}"]


def setup_sops(rig: Rig) -> dict:
    """A throwaway age key, and a SOPS file encrypted to it, loaded as a repository loads one: from
    mise.local.toml with `_.file`. Both files are trusted, as paranoid mode's env_files requires."""
    keydir = rig.root / "key"
    keydir.mkdir()
    key = keydir / "age.txt"
    gen = subprocess.run(["age-keygen", "-o", str(key)], capture_output=True, text=True, timeout=TIMEOUT)
    recipient = next((ln.split(": ", 1)[1].strip() for ln in (gen.stderr + gen.stdout).splitlines()
                      if ln.startswith("Public key: ")), "")
    if gen.returncode != 0 or not recipient:
        raise RuntimeError(f"age-keygen failed (exit {gen.returncode}): {gen.stderr.strip()}")
    value = secrets.token_hex(16)
    proj = rig.project("sops", {"mise.local.toml": '[env]\n_.file = ".mise.secrets.sops.json"\n'})
    plain = keydir / "plain.json"
    plain.write_text('{"%s": "%s"}\n' % (SECRET_VAR, value))
    enc = subprocess.run(["sops", "--encrypt", "--age", recipient, "--input-type", "json",
                          "--output-type", "json", str(plain)], cwd=str(keydir), env=rig.env,
                         capture_output=True, text=True, timeout=TIMEOUT)
    plain.unlink()
    if enc.returncode != 0:
        raise RuntimeError(f"sops --encrypt failed (exit {enc.returncode}): {enc.stderr.strip()}")
    (proj / ".mise.secrets.sops.json").write_text(enc.stdout)
    rig.trust(proj / "mise.local.toml")
    rig.trust(proj / ".mise.secrets.sops.json")
    return {"proj": proj, "key": key, "value": value}


def probe_sops(rig: Rig, fx: dict, via: str) -> list:
    """`rops`: mise's built-in decryption, the key named by SOPS_AGE_KEY_FILE. `sops`: the external
    program (MISE_SOPS_ROPS=false), the key printed by SOPS_AGE_KEY_CMD, as macOS reads it."""
    if via == "rops":
        extra = {"SOPS_AGE_KEY_FILE": str(fx["key"])}
    else:
        if any(c.isspace() for c in str(fx["key"])):
            return [f"the throwaway key's path has a space, which SOPS_AGE_KEY_CMD cannot carry: {fx['key']}"]
        extra = {"MISE_SOPS_ROPS": "false", "SOPS_AGE_KEY_CMD": f"cat {fx['key']}"}
    # The value is compared inside the process and never printed.
    r = rig.run([rig.mise, "x", "--", "sh", "-c", f'[ "${SECRET_VAR}" = "$1" ]', "sh", fx["value"]],
                fx["proj"], extra)
    if r.returncode == 0:
        return []
    return [f"a SOPS file did not decrypt into a process ({via}, sops.strict off): exit {r.returncode}, "
            f"stderr {r.stderr.strip()[-300:]!r}"]


# --- this machine ----------------------------------------------------------------------------------

@pytest.fixture
def rig(tmp_path):
    mise = shutil.which("mise")
    if mise is None:
        pytest.fail(f"mise is active here ({base_dropin(os.environ)} is deployed) but not on PATH: "
                    "install it from the package manager")
    return Rig(tmp_path / "rig", mise_config_dir(os.environ), Path.home(), dict(os.environ))


def need(*tools: str) -> None:
    missing = [t for t in tools if shutil.which(t) is None]
    if missing:
        pytest.fail("mise is active here but these are not on PATH: " + " ".join(missing)
                    + "; install them from the package manager")


def test_a_pin_resolves(rig):
    assert probe_pin(rig, setup_pin(rig)) == []


def test_a_missing_version_fails_where_the_dropins_say_so(rig):
    on, why = d7_set(rig)
    if not on:
        pytest.skip(f"this machine's drop-ins do not set both ({why}); a missing version may install or fall back here")
    assert probe_missing(rig, setup_missing(rig)) == []


def test_an_untrusted_config_is_refused(rig):
    assert probe_untrusted(rig, setup_untrusted(rig)) == []


def test_a_dependencys_config_is_ignored(rig):
    assert probe_dependency(rig, setup_dependency(rig)) == []


def test_a_sops_file_decrypts_with_a_key_file(rig):
    need("sops", "age-keygen")
    assert probe_sops(rig, setup_sops(rig), "rops") == []


@pytest.mark.skipif(platform.system() != "Darwin",
                    reason="macOS only: there the key comes from a command through the external sops; "
                           "Linux reads a key file, checked above (its plant below runs here too)")
def test_a_sops_file_decrypts_through_sops_with_a_key_command(rig):
    need("sops", "age-keygen")
    assert probe_sops(rig, setup_sops(rig), "sops") == []


def test_no_key_at_a_default_key_path():
    assert keys_at_default_paths(Path.home(), dict(os.environ), platform.system()) == []


def test_the_domains_required_files_exist():
    assert required_files_problems(Path.home()) == []


def test_no_probe_sets_the_global_config_file(tmp_path):
    caller = dict(os.environ, MISE_GLOBAL_CONFIG_FILE=str(tmp_path / "elsewhere.toml"))
    env = probe_env(caller, tmp_path / "cfg", tmp_path, tmp_path)
    assert "MISE_GLOBAL_CONFIG_FILE" not in env
    assert not [k for k in env if k.startswith("SOPS_")]


# --- each check against a planted defect, in a scratch world --------------------------------------------

@pytest.fixture
def scratch(tmp_path):
    """A rig with its own config dir and home: a drop-in setting the two settings under which a missing version fails."""
    if shutil.which("mise") is None:
        pytest.fail("mise is active here but not on PATH")
    cfg = tmp_path / "cfg"
    (cfg / "conf.d").mkdir(parents=True)
    (cfg / "conf.d" / "50-missing-fails.toml").write_text(
        "[settings]\nauto_install = false\nnot_found_system_fallback = false\n")
    home = tmp_path / "home"
    home.mkdir()
    # The caller's XDG_CONFIG_HOME would point sops at the machine's default key path.
    return Rig(tmp_path / "rig", cfg, home, dict(os.environ, XDG_CONFIG_HOME=str(home / ".config")))


def test_plant_pin_install_removed(scratch):
    proj = setup_pin(scratch)
    assert probe_pin(scratch, proj) == []
    shutil.rmtree(scratch.root / "data" / "installs" / "node" / PIN)
    assert any("did not resolve" in p for p in probe_pin(scratch, proj))


def test_plant_missing_version_falls_back(scratch):
    assert d7_set(scratch)[0]
    proj = setup_missing(scratch)
    assert probe_missing(scratch, proj) == []
    # The defect: a mise that falls back to the system's node despite the drop-in.
    problems = probe_missing(scratch, proj, {"MISE_NOT_FOUND_SYSTEM_FALLBACK": "true"})
    assert any("fell back to the system" in p for p in problems)


def test_plant_missing_version_check_skips_without_the_settings(tmp_path):
    if shutil.which("mise") is None:
        pytest.fail("mise is active here but not on PATH")
    (tmp_path / "cfg").mkdir()
    (tmp_path / "home").mkdir()
    r = Rig(tmp_path / "rig", tmp_path / "cfg", tmp_path / "home",
            dict(os.environ, XDG_CONFIG_HOME=str(tmp_path / "home" / ".config")))
    on, why = d7_set(r)
    assert not on and "auto_install=true" in why


def test_plant_untrusted_fixture_trusted(scratch):
    proj = setup_untrusted(scratch)
    assert probe_untrusted(scratch, proj) == []
    scratch.trust(proj / "mise.toml")
    problems = probe_untrusted(scratch, proj)
    assert any("was not refused" in p for p in problems)
    assert any("[env] reached a process" in p for p in problems)


def test_plant_dependency_ignore_dropped(scratch):
    fixture = setup_dependency(scratch)
    assert probe_dependency(scratch, fixture) == []
    assert any("was not ignored" in p for p in probe_dependency(scratch, (fixture[0], {})))


@pytest.mark.parametrize("via", ["rops", "sops"])
def test_plant_throwaway_key_removed(scratch, via):
    for t in ("sops", "age-keygen"):
        if shutil.which(t) is None:
            pytest.fail(f"{t} is not on PATH")
    fx = setup_sops(scratch)
    assert probe_sops(scratch, fx, via) == []
    fx["key"].unlink()
    assert any("did not decrypt" in p for p in probe_sops(scratch, fx, via))


@pytest.mark.parametrize("system", ["Linux", "Darwin"])
def test_plant_key_at_each_default_path(tmp_path, system):
    home = tmp_path / "home"
    env = {"XDG_CONFIG_HOME": str(tmp_path / "xdg")}
    paths = default_key_paths(home, env, system)
    assert len(paths) == 3
    assert keys_at_default_paths(home, env, system) == []
    for p in paths:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("AGE-SECRET-KEY-PLANTED\n")
        assert keys_at_default_paths(home, env, system) == [
            f"an age key sits at a default key path, where a decrypter would use it unasked: {p}"]
        p.unlink()


def test_plant_required_file_missing(tmp_path):
    home = tmp_path / "home"
    (home / REQUIRED_LIST).parent.mkdir(parents=True)
    assert required_files_problems(home) == []  # no list: nothing required
    present = home / "token.sops.json"
    present.write_text("{}\n")
    (home / REQUIRED_LIST).write_text(f"# the domain's files\n\n~/token.sops.json\n{present}\n")
    assert required_files_problems(home) == []
    (home / REQUIRED_LIST).write_text("~/token.sops.json\n~/gone.sops.json\nrelative/path\n")
    assert required_files_problems(home) == [
        f"{home / REQUIRED_LIST}:2: required file {home / 'gone.sops.json'} does not exist (or is not a file)",
        f"{home / REQUIRED_LIST}:3: 'relative/path' is neither absolute nor ~/-relative",
    ]


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", *sys.argv[1:]]))
