#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for sops-key-loader, which decrypts a machine's SOPS age key from its systemd credential
into the file SOPS_AGE_KEY_FILE names, inside $XDG_RUNTIME_DIR, and for the templates that deploy it.

Run: sh tests/run-all.sh --only test-sops-key-loader.py
 or: uv run --script tests/test-sops-key-loader.py [-k <pattern>]

The real `systemd-creds` is never run: a stub first on PATH plays it, its behavior chosen per case
through STUB_MODE, and every path is in a scratch directory, so no real runtime directory or key is
touched. The fake key below is not an age key; it only carries the prefix the tool checks for.

What is held, for the tool: an absent key file is created with mode 600 and the decrypted bytes;
a present one is left untouched and the credential is never decrypted; a decrypt that writes part
of the key and then fails leaves no file at all, neither the key file nor a temporary beside it; a
decrypt that succeeds with something that is not an age key leaves no file; a key file another
loader created while this one decrypted is kept, not replaced; a missing credential, an unset
variable and a key file outside the runtime directory are refused; and in no case does the key
reach the tool's output.

What is held, for the templates: with `miseActive` false or absent, the rendered ~/.zshrc and the
list of managed targets are byte-identical to the source with the loader's files and block taken
out; with it true on Linux, ~/.zshrc runs the loader only when the key file is missing, and the
tool, the unit and the link that enables it at login are deployed.
"""
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SRC = HERE.parent
TOOL = SRC / "private_dot_local" / "bin" / "executable_sops-key-loader"
ZSHRC = SRC / "dot_zshrc.tmpl"
LOADER_FILES = (
    "private_dot_local/bin/executable_sops-key-loader",
    "dot_config/systemd/user/sops-key-loader.service",
    "dot_config/systemd/user/default.target.wants/symlink_sops-key-loader.service",
)
LOADER_TARGETS = (
    ".local/bin/sops-key-loader",
    ".config/systemd/user/sops-key-loader.service",
    ".config/systemd/user/default.target.wants/sops-key-loader.service",
)

# Split so that no secret scanner reads this file as holding a key.
FAKE_KEY = "# created: test\n" + "AGE-SECRET-KEY-" + "1TESTONLYNOTAREALKEY\n"
FAKE_KEY_LINE = "AGE-SECRET-KEY-" + "1TESTONLYNOTAREALKEY"

# STUB_MODE: ok (prints the key), partial (prints half the key, then fails), garbage (succeeds
# with something that is not an age key), race (another loader creates the key file mid-decrypt,
# then this decrypt succeeds). Every call appends its arguments to STUB_LOG.
STUB = r'''#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG"
case "$STUB_MODE" in
  ok) cat "$STUB_KEY" ;;
  partial) head -c 20 "$STUB_KEY"; echo "systemd-creds: stub decrypt failure" >&2; exit 1 ;;
  garbage) printf 'not a key\n' ;;
  race) printf 'from the other loader\n' > "$SOPS_AGE_KEY_FILE"; cat "$STUB_KEY" ;;
  *) echo "stub: unknown STUB_MODE" >&2; exit 99 ;;
esac
'''


class Box:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.bin = tmp / "stubs"
        self.run_dir = tmp / "run"
        self.home = tmp / "home"
        for d in (self.bin, self.run_dir, self.home):
            d.mkdir()
        self.run_dir.chmod(0o700)
        stub = self.bin / "systemd-creds"
        stub.write_text(STUB)
        stub.chmod(0o755)
        self.key_src = tmp / "key-plain"
        self.key_src.write_text(FAKE_KEY)
        self.cred = tmp / "age-key.cred"
        self.cred.write_text("opaque credential\n")
        self.log = tmp / "stub.log"
        self.key_file = self.run_dir / "sops" / "age-key"

    def env(self, **over):
        env = {
            "PATH": "%s:/usr/bin:/bin" % self.bin,
            "HOME": str(self.home),
            "XDG_RUNTIME_DIR": str(self.run_dir),
            "SOPS_AGE_KEY_FILE": str(self.key_file),
            "SOPS_KEY_LOADER_CREDENTIAL": str(self.cred),
            "STUB_KEY": str(self.key_src),
            "STUB_LOG": str(self.log),
            "STUB_MODE": "ok",
        }
        for k, v in over.items():
            if v is None:
                env.pop(k, None)
            else:
                env[k] = v
        return env

    def run(self, *args, **over):
        # umask 022 so that a file the tool creates without choosing its mode shows as 644.
        r = subprocess.run([sys.executable, str(TOOL), *args], env=self.env(**over),
                           stdin=subprocess.DEVNULL, capture_output=True, text=True,
                           timeout=30, preexec_fn=lambda: os.umask(0o022))
        assert FAKE_KEY_LINE not in r.stdout + r.stderr, "the key reached the tool's output"
        assert "1TESTONLY" not in r.stdout + r.stderr, "part of the key reached the tool's output"
        return r

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def leftovers(self):
        """Every entry under the runtime directory, as relative paths."""
        return sorted(str(p.relative_to(self.run_dir)) for p in self.run_dir.rglob("*"))


@pytest.fixture
def box(tmp_path):
    return Box(tmp_path)


# --- the tool ------------------------------------------------------------------------------------

def test_absent_key_file_is_created_600_with_the_key(box):
    r = box.run()
    assert r.returncode == 0, r.stderr
    assert box.key_file.read_text() == FAKE_KEY
    assert stat.S_IMODE(box.key_file.stat().st_mode) == 0o600
    assert stat.S_IMODE(box.key_file.parent.stat().st_mode) == 0o700
    assert box.leftovers() == ["sops", "sops/age-key"], "a temporary file was left behind"
    assert box.calls() == ["--user --name=sops-age-key decrypt %s -" % box.cred]


def test_credential_name_is_configurable(box):
    r = box.run(SOPS_KEY_LOADER_CREDENTIAL_NAME="other-name")
    assert r.returncode == 0, r.stderr
    assert box.calls() == ["--user --name=other-name decrypt %s -" % box.cred]


def test_present_key_file_is_untouched_and_nothing_is_decrypted(box):
    box.key_file.parent.mkdir(mode=0o700)
    box.key_file.write_text("already here\n")
    box.key_file.chmod(0o600)
    before = box.key_file.stat()
    r = box.run()
    assert r.returncode == 0, r.stderr
    assert box.key_file.read_text() == "already here\n"
    after = box.key_file.stat()
    assert (after.st_mtime_ns, after.st_ino) == (before.st_mtime_ns, before.st_ino)
    assert box.calls() == [], "the credential was decrypted though the key file was present"


def test_failed_decrypt_after_partial_output_leaves_no_file(box):
    r = box.run(STUB_MODE="partial")
    assert r.returncode == 1
    assert not box.key_file.exists(), "a partial key file was left"
    assert box.leftovers() in ([], ["sops"]), "something was left: %s" % box.leftovers()


def test_decrypt_that_is_not_an_age_key_leaves_no_file(box):
    r = box.run(STUB_MODE="garbage")
    assert r.returncode == 1
    assert "not an age key" in r.stderr
    assert box.leftovers() in ([], ["sops"]), "something was left: %s" % box.leftovers()


def test_a_key_file_created_meanwhile_is_kept_not_replaced(box):
    r = box.run(STUB_MODE="race")
    assert r.returncode == 0, r.stderr
    assert box.key_file.read_text() == "from the other loader\n"
    assert box.leftovers() == ["sops", "sops/age-key"], "a temporary file was left behind"


def test_missing_credential_is_refused_without_decrypting(box):
    box.cred.unlink()
    r = box.run()
    assert r.returncode == 1
    assert str(box.cred) in r.stderr
    assert box.calls() == []
    assert not box.key_file.exists()


def test_unset_key_file_variable_is_a_usage_error(box):
    r = box.run(SOPS_AGE_KEY_FILE=None)
    assert r.returncode == 2
    assert "SOPS_AGE_KEY_FILE" in r.stderr
    assert box.calls() == []


def test_key_file_outside_the_runtime_directory_is_refused(box):
    outside = box.tmp / "elsewhere" / "age-key"
    r = box.run(SOPS_AGE_KEY_FILE=str(outside))
    assert r.returncode == 2
    assert "XDG_RUNTIME_DIR" in r.stderr
    assert not outside.exists() and not outside.parent.exists()
    assert box.calls() == []


def test_key_file_escaping_the_runtime_directory_by_dotdot_is_refused(box):
    sneaky = box.run_dir / ".." / "escaped-key"
    r = box.run(SOPS_AGE_KEY_FILE=str(sneaky))
    assert r.returncode == 2
    assert "XDG_RUNTIME_DIR" in r.stderr
    assert not (box.tmp / "escaped-key").exists()
    assert box.calls() == []


def test_unset_runtime_directory_is_a_usage_error(box):
    r = box.run(XDG_RUNTIME_DIR=None)
    assert r.returncode == 2
    assert "XDG_RUNTIME_DIR" in r.stderr
    assert box.calls() == []


def test_key_file_flag_overrides_the_variable(box):
    other = box.run_dir / "flag-key"
    r = box.run("--key-file", str(other))
    assert r.returncode == 0, r.stderr
    assert other.read_text() == FAKE_KEY
    assert not box.key_file.exists()


# --- the templates -------------------------------------------------------------------------------

needs_chezmoi = pytest.mark.skipif(shutil.which("chezmoi") is None, reason="chezmoi not installed")
on_linux = pytest.mark.skipif(sys.platform != "linux", reason="the loader deploys on Linux only")


def config(tmp: Path, mise_active):
    line = "" if mise_active is None else "    miseActive = %s\n" % str(mise_active).lower()
    cfg = tmp / ("c-%s.toml" % mise_active)
    cfg.write_text('[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n' + line)
    return cfg


def chezmoi(tmp: Path, src: Path, cfg: Path, *args, stdin=None):
    r = subprocess.run(["chezmoi", "--config", str(cfg), "--source", str(src),
                        "--destination", str(tmp / "dest"), "--cache", str(tmp / "cache"),
                        "--persistent-state", str(tmp / "state.db"), *args],
                       input=stdin, capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr
    return r.stdout


def render_zshrc(tmp: Path, text: str, mise_active):
    return chezmoi(tmp, SRC, config(tmp, mise_active), "execute-template", stdin=text)


def zshrc_without_loader_block(text: str) -> str:
    """dot_zshrc.tmpl with the miseActive block cut out: the template as it was before it."""
    lines = text.splitlines(keepends=True)
    start = [i for i, ln in enumerate(lines) if ln.startswith("{{- if") and "miseActive" in ln]
    assert len(start) == 1, "expected exactly one miseActive block in dot_zshrc.tmpl"
    end = next(i for i in range(start[0], len(lines)) if lines[i].startswith("{{- end"))
    # Both tags open with {{- , which trims the newline before each, so with the flag off the
    # block renders as nothing at all: the same as cutting its lines out whole.
    return "".join(lines[:start[0]] + lines[end + 1:])


@needs_chezmoi
@pytest.mark.parametrize("mise_active", [False, None])
def test_zshrc_is_unchanged_when_mise_is_not_active(tmp_path, mise_active):
    text = ZSHRC.read_text()
    assert render_zshrc(tmp_path, text, mise_active) == \
        render_zshrc(tmp_path, zshrc_without_loader_block(text), mise_active)
    assert "sops-key-loader" not in render_zshrc(tmp_path, text, mise_active)


@needs_chezmoi
@on_linux
def test_zshrc_runs_the_loader_only_when_the_key_file_is_missing(tmp_path):
    out = render_zshrc(tmp_path, ZSHRC.read_text(), True)
    lines = [ln for ln in out.splitlines() if "sops-key-loader" in ln and not ln.startswith("#")]
    assert lines == ['if [[ -n ${SOPS_AGE_KEY_FILE:-} && ! -e $SOPS_AGE_KEY_FILE ]]; '
                     'then sops-key-loader; fi'], lines
    # The rendered line, run by zsh: the loader is called when the file is missing, not otherwise.
    stub = tmp_path / "bin"
    stub.mkdir()
    (stub / "sops-key-loader").write_text('#!/bin/sh\necho called >> "$CALLS"\n')
    (stub / "sops-key-loader").chmod(0o755)
    calls = tmp_path / "calls"
    key = tmp_path / "key"
    env = {"PATH": "%s:/usr/bin:/bin" % stub, "CALLS": str(calls), "SOPS_AGE_KEY_FILE": str(key)}
    subprocess.run(["zsh", "-f", "-c", lines[0]], env=env, check=True)
    assert calls.read_text() == "called\n"
    key.write_text("x")
    subprocess.run(["zsh", "-f", "-c", lines[0]], env=env, check=True)
    assert calls.read_text() == "called\n", "the loader ran though the key file was present"


def source_copy(tmp: Path) -> Path:
    """A scratch copy of the source, without the externals, whose downloads listing does not need."""
    dst = tmp / "src"
    names = subprocess.run(["git", "-C", str(SRC), "ls-files", "-z", "--cached", "--others",
                            "--exclude-standard"], capture_output=True, check=True).stdout
    for rel in filter(None, names.decode().split("\0")):
        s = SRC / rel
        if not (s.exists() or s.is_symlink()) or rel.startswith(".chezmoiexternal"):
            continue
        d = dst / rel
        d.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(s, d, follow_symlinks=False)
    return dst


@needs_chezmoi
@pytest.mark.parametrize("mise_active", [False, None])
def test_managed_targets_are_unchanged_when_mise_is_not_active(tmp_path, mise_active):
    src = source_copy(tmp_path)
    cfg = config(tmp_path, mise_active)
    with_loader = chezmoi(tmp_path, src, cfg, "managed")
    assert with_loader.strip(), "chezmoi listed nothing, so this check would see nothing"
    for rel in LOADER_FILES:
        (src / rel).unlink()
    without = src / "dot_config/systemd/user/default.target.wants"
    if without.is_dir() and not any(without.iterdir()):
        without.rmdir()
    assert with_loader == chezmoi(tmp_path, src, cfg, "managed")


@needs_chezmoi
@on_linux
def test_loader_tool_unit_and_enable_link_deploy_when_mise_is_active(tmp_path):
    src = source_copy(tmp_path)
    managed = chezmoi(tmp_path, src, config(tmp_path, True), "managed").splitlines()
    for target in LOADER_TARGETS:
        assert target in managed, "%s is not deployed with miseActive true" % target
    link = (src / LOADER_FILES[2]).read_text().strip()
    assert link == "../sops-key-loader.service"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", *sys.argv[1:]]))
