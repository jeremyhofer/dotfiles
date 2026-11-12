#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for the base's own gates running uv offline, and for the step that fills uv's cache.

Run: npx nx run suite-hermetic-uv:test
 or: uv run --script tests/test-hermetic-uv.py [-k <pattern>]

What is held: tests/apply-suites.py's Nx environment, which every run of the suites goes through
(the apply, the commit gate, the landing gate), gives every suite UV_OFFLINE=1 unless the caller set
UV_OFFLINE, whatever its value. tests/seed-uv-cache.py, the one step that may reach a registry, lists
exactly the `uv run --script` files under tests/ and private_dot_local/bin/ (by the first line),
syncs each through uv with UV_OFFLINE removed from its environment, names every file that failed and
exits 1 after trying them all. That each mode of apply-suites.py hands Nx this environment, and that a
uv-script suite failing on a cache miss gets a line naming the seed command, is held end to end in
tests/test-apply-suites.py.

No test reaches the network: uv is a stand-in that records how it was called.
"""
import importlib.util
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SEED = HERE / "seed-uv-cache.py"
UVSH = "#!/usr/bin/env -S uv run --script\n"

@pytest.fixture
def rig(tmp_path):
    return Rig(tmp_path)


class Rig:
    """A stand-in uv first on PATH."""

    def __init__(self, root: Path):
        self.root = root
        self.bin = root / "bin"
        self.bin.mkdir()
        self.uvlog = root / "uv.log"
        # `uv sync --script FILE`: records UV_OFFLINE and the file, fails for `# syncfail`.
        uv = self.bin / "uv"
        uv.write_text(f"""#!/bin/sh
echo "$1 $2 $3 UV_OFFLINE=${{UV_OFFLINE-unset}}" >> {self.uvlog}
grep -q '^# syncfail' "$3" && {{ echo "sync failed for $3" >&2; exit 1; }}
exit 0
""")
        uv.chmod(0o755)

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if k != "UV_OFFLINE"}
        env["PATH"] = f"{self.bin}{os.pathsep}{env['PATH']}"
        env["TMPDIR"] = str(self.root)
        env.update(extra)
        return env


# --- the default ----------------------------------------------------------------------------------

def test_apply_suites_gives_nx_offline_uv_unless_the_caller_chose():
    spec = importlib.util.spec_from_file_location("apply_suites", HERE / "apply-suites.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert mod.nx_env({"PATH": "/bin"})["UV_OFFLINE"] == "1"
    assert mod.nx_env({"PATH": "/bin", "UV_OFFLINE": "0"})["UV_OFFLINE"] == "0"
    assert mod.nx_env({"PATH": "/bin", "UV_OFFLINE": "false"})["UV_OFFLINE"] == "false"


# --- the seed step --------------------------------------------------------------------------------

def seed_root(tmp_path):
    root = tmp_path / "src"
    (root / "tests").mkdir(parents=True)
    (root / "private_dot_local" / "bin").mkdir(parents=True)
    return root


def seed(rig, root, *args, **extra):
    return subprocess.run([sys.executable, str(SEED), "--root", str(root), *args],
                          env=rig.env(**extra), capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, timeout=60)


def test_seed_lists_exactly_the_uv_script_files(rig, tmp_path):
    root = seed_root(tmp_path)
    (root / "tests" / "test-a.py").write_text(UVSH + "# /// script\n# ///\n")
    (root / "tests" / "test-b.sh").write_text("#!/bin/sh\n# uv run --script is only text here\n")
    (root / "tests" / "helper.py").write_text("#!/usr/bin/env python3\nprint(1)\n")
    (root / "private_dot_local" / "bin" / "executable_tool").write_text(UVSH)
    (root / "private_dot_local" / "bin" / "executable_plain").write_text("#!/usr/bin/env python3\n")
    r = seed(rig, root, "--list")
    assert r.returncode == 0, r.stderr
    assert sorted(r.stdout.splitlines()) == ["private_dot_local/bin/executable_tool", "tests/test-a.py"]
    # Plant one more uv-script file: listed. Plant a non-uv script: not listed.
    (root / "tests" / "test-new.py").write_text(UVSH)
    (root / "tests" / "other.py").write_text("#!/usr/bin/env python3\n")
    again = seed(rig, root, "--list").stdout.splitlines()
    assert "tests/test-new.py" in again and "tests/other.py" not in again


def test_seed_syncs_each_file_with_the_network_allowed(rig, tmp_path):
    root = seed_root(tmp_path)
    (root / "tests" / "test-a.py").write_text(UVSH)
    (root / "private_dot_local" / "bin" / "executable_tool").write_text(UVSH)
    r = seed(rig, root, UV_OFFLINE="1")
    assert r.returncode == 0, r.stderr
    calls = rig.uvlog.read_text().splitlines()
    assert sorted(c.split()[2] for c in calls) == sorted(
        [str(root / "private_dot_local/bin/executable_tool"), str(root / "tests/test-a.py")])
    assert all(c.startswith("sync --script ") and c.endswith("UV_OFFLINE=unset") for c in calls), calls


def test_seed_tries_every_file_and_names_the_failures(rig, tmp_path):
    root = seed_root(tmp_path)
    (root / "tests" / "test-a.py").write_text(UVSH + "# syncfail\n")
    (root / "tests" / "test-b.py").write_text(UVSH)
    r = seed(rig, root)
    assert r.returncode == 1
    assert "test-a.py" in r.stderr
    assert len(rig.uvlog.read_text().splitlines()) == 2        # test-b.py was still tried


def test_seed_without_uv_is_a_usage_error(rig, tmp_path):
    root = seed_root(tmp_path)
    (root / "tests" / "test-a.py").write_text(UVSH)
    (rig.bin / "uv").unlink()
    env = {"PATH": str(rig.bin), "HOME": str(tmp_path)}
    r = subprocess.run([sys.executable, str(SEED), "--root", str(root)], env=env,
                       capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    assert r.returncode == 2 and "uv is not installed" in r.stderr


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, *sys.argv[1:]]))
