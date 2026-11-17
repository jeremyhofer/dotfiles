#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for bootstrap-mac.sh's default-Node stage, the one stage whose choice of tool depends on
the machine: fnm, or mise on a machine switched to it.

Run: sh tests/run-all.sh --only test-bootstrap-mac.py
 or: uv run --script tests/test-bootstrap-mac.py [-k <pattern>]

What is held: a machine is switched to mise only when the [data] of its generated base chezmoi
config says `miseActive = true`. Without that config (a new machine, before chezmoi has run) or with
the key false, the stage runs fnm exactly as it always has and never calls mise. Switched, it runs
`mise install` of the global default and `mise install node@<pin>` of this repository's pin,
both from $HOME so no project's configuration is read, and never calls fnm; a pin that will not
install stops the bootstrap, naming the pin. The pin is `[tools] node` in the repository's
mise.toml, else its `.nvmrc`, on both paths: written in each accepted way it is read; a mise.toml
without that key, or with it only in another table, leaves the pin to `.nvmrc`; a value the reader
cannot take, and a mise.toml and `.nvmrc` that disagree, stop the stage before anything installs.

Nothing real is installed: the script runs one stage (`sh bootstrap-mac.sh node`) as a copy in a
scratch "repository" with its own `.nvmrc` (and, where a test writes one, `mise.toml`), HOME is a scratch directory, and PATH holds only stub
`fnm` and `mise` programs that record each call, beside links to the few system utilities the
script uses. The machine's own fnm and mise are never on that PATH.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "bootstrap-mac.sh"
PIN = "26.13.0"
OTHER = "26.14.1"
UTILITIES = ("sed", "grep", "sort", "tail", "cat", "dirname")

# fnm's stub: `fnm ls` prints $FNM_LS_FILE; `fnm exec --using=V ...` succeeds only for a version
# listed in it; everything else succeeds. Each call is appended to $STUB_LOG.
FNM_STUB = """#!/bin/sh
printf 'fnm %s\\n' "$*" >> "$STUB_LOG"
case "$1" in
  ls) cat "$FNM_LS_FILE" ;;
  exec)
    want=${2#--using=}
    while IFS= read -r line; do
      case "$line" in *"v$want"*) exit 0 ;; esac
    done < "$FNM_LS_FILE"
    exit 1 ;;
esac
exit 0
"""

# mise's stub: records the call with the directory it ran in, and fails when its arguments contain
# $MISE_FAIL_ON (when that is set).
MISE_STUB = """#!/bin/sh
printf 'mise %s (in %s)\\n' "$*" "$(pwd)" >> "$STUB_LOG"
if [ -n "${MISE_FAIL_ON:-}" ]; then
  case "$*" in *"$MISE_FAIL_ON"*) exit 1 ;; esac
fi
exit 0
"""


class Machine:
    def __init__(self, root: Path):
        self.home = root / "home"
        self.repo = root / "repo"
        self.stubs = root / "stubs"
        self.log = root / "calls.log"
        self.fnm_ls = root / "fnm-ls"
        for d in (self.home, self.repo, self.stubs):
            d.mkdir()
        shutil.copy(SCRIPT, self.repo / "bootstrap-mac.sh")
        (self.repo / ".nvmrc").write_text(PIN + "\n")
        for name in UTILITIES:
            real = shutil.which(name)
            assert real, f"{name} is needed to run the bootstrap under test"
            (self.stubs / name).symlink_to(real)
        self.fnm_ls.write_text("* v24.1.0 default\n")
        self.log.write_text("")
        self.extra_env: dict[str, str] = {}

    def mise_toml(self, text: str) -> None:
        (self.repo / "mise.toml").write_text(text)

    def stub(self, name: str, text: str) -> None:
        p = self.stubs / name
        p.write_text(text)
        p.chmod(0o755)

    def switch(self, value: str) -> None:
        cfg = self.home / ".config" / "chezmoi"
        cfg.mkdir(parents=True, exist_ok=True)
        (cfg / "chezmoi.toml").write_text(
            f'[data]\n    domain = "personal"\n    miseActive = {value}\n')

    def run(self, *stages: str) -> subprocess.CompletedProcess:
        env = {"HOME": str(self.home), "PATH": str(self.stubs), "STUB_LOG": str(self.log),
               "FNM_LS_FILE": str(self.fnm_ls), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               **self.extra_env}
        return subprocess.run([shutil.which("sh"), str(self.repo / "bootstrap-mac.sh"), *stages],
                              env=env, capture_output=True, text=True, timeout=60)

    def calls(self, tool: str) -> list[str]:
        return [ln for ln in self.log.read_text().splitlines() if ln.startswith(tool + " ")]


@pytest.fixture
def m(tmp_path):
    machine = Machine(tmp_path)
    machine.stub("fnm", FNM_STUB)
    machine.stub("mise", MISE_STUB)
    return machine


# Today's fnm sequence for a machine whose fnm has v24.1.0 and not the pin: the default is already
# installed, it is made the default, the pin is checked and then installed.
FNM_TODAY = ["fnm ls", "fnm ls", "fnm default v24.1.0",
             f"fnm exec --using={PIN} node --version", f"fnm install {PIN}"]


def test_no_chezmoi_config_runs_fnm_as_before_and_never_mise(m):
    r = m.run("node")
    assert r.returncode == 0, r.stderr
    assert m.calls("mise") == []
    assert m.calls("fnm") == FNM_TODAY


def test_mise_active_false_runs_fnm_as_before_and_never_mise(m):
    m.switch("false")
    r = m.run("node")
    assert r.returncode == 0, r.stderr
    assert m.calls("mise") == []
    assert m.calls("fnm") == FNM_TODAY


def test_switched_installs_the_global_default_and_the_pin_through_mise(m):
    m.switch("true")
    r = m.run("node")
    assert r.returncode == 0, r.stderr
    assert m.calls("mise") == [f"mise install (in {m.home})",
                               f"mise install node@{PIN} (in {m.home})"]
    assert m.calls("fnm") == []


def test_switched_without_a_pin_installs_the_global_default_only(m):
    m.switch("true")
    (m.repo / ".nvmrc").unlink()
    r = m.run("node")
    assert r.returncode == 0, r.stderr
    assert m.calls("mise") == [f"mise install (in {m.home})"]


def test_switched_a_pin_that_will_not_install_stops_the_bootstrap(m):
    m.switch("true")
    m.extra_env["MISE_FAIL_ON"] = f"node@{PIN}"
    r = m.run("node")
    assert r.returncode != 0
    assert PIN in r.stderr


def test_switched_a_global_install_failure_is_reported_and_the_pin_still_installs(m):
    m.switch("true")
    m.extra_env["MISE_FAIL_ON"] = "install"
    # Every install fails here, so the pin's failure stops it; what is held is that the global
    # failure alone did not, because the pin's install was still attempted.
    r = m.run("node")
    assert f"mise install node@{PIN} (in {m.home})" in m.calls("mise")
    assert "global default" in r.stdout + r.stderr


def test_switched_without_mise_on_path_skips_and_never_falls_back_to_fnm(m):
    m.switch("true")
    (m.stubs / "mise").unlink()
    r = m.run("node")
    assert r.returncode == 0, r.stderr
    assert "mise not on PATH" in r.stdout
    assert m.calls("fnm") == []


# --- the pin: [tools] node in mise.toml, else .nvmrc ---------------------------------------------------

def test_switched_a_mise_toml_pin_alone_is_installed_through_mise(m):
    m.switch("true")
    (m.repo / ".nvmrc").unlink()
    m.mise_toml(f'[tools]\nnode = "{OTHER}"\npython = "3.15.2"\n')
    r = m.run("node")
    assert r.returncode == 0, r.stderr
    assert m.calls("mise") == [f"mise install (in {m.home})",
                               f"mise install node@{OTHER} (in {m.home})"]


def test_not_switched_a_mise_toml_pin_alone_is_installed_through_fnm(m):
    (m.repo / ".nvmrc").unlink()
    m.mise_toml(f'[tools]\nnode = "{OTHER}"\n')
    r = m.run("node")
    assert r.returncode == 0, r.stderr
    assert m.calls("fnm")[-2:] == [f"fnm exec --using={OTHER} node --version", f"fnm install {OTHER}"]
    assert m.calls("mise") == []


@pytest.mark.parametrize("text", [
    '[tools]\nnode = "{v}"\n',
    "[tools]\nnode='{v}'\n",
    '  [tools]   # the runtimes\n  node   =   "{v}"   # the apply\'s pin\n',
    '[env]\nX = "1"\n\n[tools]\npython = "3.15.2"\n"node" = "{v}"\n\n[tasks.x]\nrun = "true"\n',
    '[tools]\nnode = "v{v}"\n',
    'tools.node = "{v}"\n\n[env]\nX = "1"\n',
])
def test_switched_the_mise_toml_pin_is_read_in_each_way_it_is_written(m, text):
    m.switch("true")
    (m.repo / ".nvmrc").unlink()
    m.mise_toml(text.format(v=OTHER))
    r = m.run("node")
    assert r.returncode == 0, r.stderr
    assert m.calls("mise")[-1] == f"mise install node@{OTHER} (in {m.home})"


def test_switched_a_mise_toml_and_an_nvmrc_that_agree_install_the_pin(m):
    m.switch("true")
    m.mise_toml(f'[tools]\nnode = "{PIN}"\n')
    r = m.run("node")
    assert r.returncode == 0, r.stderr
    assert m.calls("mise")[-1] == f"mise install node@{PIN} (in {m.home})"


@pytest.mark.parametrize("switched", ["true", "false"])
def test_a_mise_toml_and_an_nvmrc_that_disagree_stop_naming_both(m, switched):
    m.switch(switched)
    m.mise_toml(f'[tools]\nnode = "{OTHER}"\n')
    r = m.run("node")
    assert r.returncode != 0
    assert OTHER in r.stderr and PIN in r.stderr
    assert "mise.toml" in r.stderr and ".nvmrc" in r.stderr
    assert not [c for c in m.calls("mise") + m.calls("fnm") if "node@" in c or "install " in c]


@pytest.mark.parametrize("text", [
    '[tools]\npython = "3.15.2"\n',
    '[env]\nnode = "{v}"\n',
    '[env]\ntools.node = "{v}"\n',
    '# node = "{v}"\n[tools]\n',
])
def test_switched_a_mise_toml_without_a_node_pin_falls_back_to_the_nvmrc(m, text):
    m.switch("true")
    m.mise_toml(text.format(v=OTHER))
    r = m.run("node")
    assert r.returncode == 0, r.stderr
    assert m.calls("mise")[-1] == f"mise install node@{PIN} (in {m.home})"


@pytest.mark.parametrize("text", [
    '[tools]\nnode = {{ version = "{v}" }}\n',
    '[tools]\nnode = ["{v}"]\n',
    '[tools]\nnode = "latest"\n',
    '[tools]\nnode = 26\n',
    '[tools]\nnode = "{v}\n',
    '[tools]\nnode = "{v}" extra\n',
    '[tools.node]\nversion = "{v}"\n',
])
def test_a_mise_toml_pin_the_reader_cannot_take_stops_naming_it(m, text):
    m.switch("true")
    (m.repo / ".nvmrc").unlink()
    m.mise_toml(text.format(v=OTHER))
    r = m.run("node")
    assert r.returncode != 0
    assert "mise.toml" in r.stderr
    assert not [c for c in m.calls("mise") if "node@" in c]


def test_an_unknown_stage_is_refused(m):
    r = m.run("nodes")
    assert r.returncode != 0
    assert "nodes" in r.stderr
    assert m.log.read_text() == ""


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider", *sys.argv[1:]]))
