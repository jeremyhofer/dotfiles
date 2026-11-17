#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for the base's own gates running uv offline, and for the step that fills uv's cache.

Run: sh tests/run-all.sh --only test-hermetic-uv.py
 or: uv run --script tests/test-hermetic-uv.py [-k <pattern>]

What is held: a gate (tests/run-all.sh, so also the commit hook's selector run and land-gate.sh,
which both go through it; tests/apply-suites.py's Nx environment) gives every suite UV_OFFLINE=1
unless the caller set UV_OFFLINE, whatever its value. tests/seed-uv-cache.py, the one step that may
reach a registry, lists exactly the `uv run --script` files under tests/ and private_dot_local/bin/
(by the first line), syncs each through uv with UV_OFFLINE removed from its environment, names every
file that failed and exits 1 after trying them all. A uv-script suite that fails because a package
is not in uv's cache gets one extra line naming the seed command, under the underlying error; a
failure for any other reason gets none.

No test reaches the network: uv is a stand-in that records how it was called.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SEED = HERE / "seed-uv-cache.py"
UVSH = "#!/usr/bin/env -S uv run --script\n"

# What uv 0.13 prints for a package missing from its cache with the network disabled.
OFFLINE_MISS = """error: No solution found when resolving script dependencies
  cause: Because pytest was not found in the cache and you require pytest==8.4.2, we can conclude that your requirements are unsatisfiable.

hint: Packages were unavailable because the network was disabled. When the network is disabled, registry packages may only be read from the cache.
"""


@pytest.fixture
def rig(tmp_path):
    return Rig(tmp_path)


class Rig:
    """A scratch tests/ holding the runner and stand-in suites, and a stand-in uv first on PATH."""

    def __init__(self, root: Path):
        self.root = root
        self.tests = root / "tests"
        self.bin = root / "bin"
        self.tests.mkdir()
        self.bin.mkdir()
        for name in ("run-all.sh", "land-gate.sh", "git-isolate.sh", "git-isolated.gitconfig"):
            shutil.copy(HERE / name, self.tests / name)
        self.uvlog = root / "uv.log"
        # `uv run --script FILE`: records UV_OFFLINE, prints the file's `# say=` text, exits with its
        # `# exit=`. `uv sync --script FILE`: records UV_OFFLINE and the file, fails for `# syncfail`.
        uv = self.bin / "uv"
        uv.write_text(f"""#!/bin/sh
echo "$1 $2 $3 UV_OFFLINE=${{UV_OFFLINE-unset}}" >> {self.uvlog}
if [ "$1" = sync ]; then
  grep -q '^# syncfail' "$3" && {{ echo "sync failed for $3" >&2; exit 1; }}
  exit 0
fi
[ -f "$3.say" ] && cat "$3.say"
exit "$(sed -n 's/^# exit=//p' "$3")"
""")
        uv.chmod(0o755)

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if k != "UV_OFFLINE"}
        env["PATH"] = f"{self.bin}{os.pathsep}{env['PATH']}"
        env["TMPDIR"] = str(self.root)
        env.update(extra)
        return env

    def suite(self, name, body, shebang="#!/bin/sh\n"):
        p = self.tests / name
        p.write_text(shebang + body)
        return p

    def runner(self, script, *args, **extra):
        return subprocess.run(["sh", str(self.tests / script), *args], env=self.env(**extra),
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)


# --- the default, in the runner and the landing gate ---------------------------------------------

PROBE = 'printf "%s" "${UV_OFFLINE-unset}" > "$PROBE_OUT"\n'


def seen(rig, script="run-all.sh", **extra):
    rig.suite("test-probe.sh", PROBE)
    out = rig.root / "probe.out"
    r = rig.runner(script, "--only", "test-probe.sh", PROBE_OUT=str(out), **extra)
    assert r.returncode == 0, r.stdout + r.stderr
    return out.read_text()


def test_run_all_gives_every_suite_offline_uv(rig):
    assert seen(rig) == "1"


def test_land_gate_gives_every_suite_offline_uv(rig):
    assert seen(rig, "land-gate.sh") == "1"


@pytest.mark.parametrize("value", ["0", "false", "1", ""])
def test_a_callers_explicit_value_is_respected(rig, value):
    assert seen(rig, UV_OFFLINE=value) == value


def test_apply_suites_gives_nx_offline_uv_unless_the_caller_chose():
    spec = importlib.util.spec_from_file_location("apply_suites", HERE / "apply-suites.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert mod.nx_env({"PATH": "/bin"})["UV_OFFLINE"] == "1"
    assert mod.nx_env({"PATH": "/bin", "UV_OFFLINE": "0"})["UV_OFFLINE"] == "0"
    assert mod.nx_env({"PATH": "/bin", "UV_OFFLINE": "false"})["UV_OFFLINE"] == "false"


# --- the hint on a cache miss ---------------------------------------------------------------------

def test_a_cache_miss_names_the_seed_command_and_keeps_the_error(rig):
    s = rig.suite("test-miss.py", "# exit=1\n", UVSH)
    (rig.tests / "test-miss.py.say").write_text(OFFLINE_MISS)
    r = rig.runner("run-all.sh", "--only", "test-miss.py")
    assert r.returncode == 1
    assert "was not found in the cache" in r.stdout          # the underlying error is not hidden
    hints = [ln for ln in r.stdout.splitlines() if "seed-uv-cache.py" in ln]
    assert len(hints) == 1, r.stdout
    assert s.name == "test-miss.py"


def test_another_failure_gets_no_hint(rig):
    rig.suite("test-other.py", "# exit=3\n", UVSH)
    (rig.tests / "test-other.py.say").write_text("AssertionError: 1 != 2\n")
    r = rig.runner("run-all.sh", "--only", "test-other.py")
    assert r.returncode == 1
    assert "AssertionError" in r.stdout
    assert "seed-uv-cache" not in r.stdout


def test_a_passing_suite_prints_no_hint(rig):
    rig.suite("test-fine.py", "# exit=0\n", UVSH)
    r = rig.runner("run-all.sh", "--only", "test-fine.py")
    assert r.returncode == 0 and "seed-uv-cache" not in r.stdout


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
