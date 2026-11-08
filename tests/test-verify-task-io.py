#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for verify-task-io. No Nx is installed or run: the Nx layer is a stand-in (FakeNx) that
describes a small task graph and runs each target as a shell command, so the real inotify trace and
the real attribution logic run against a scratch workspace whose plants are known.

Each plant is a target that does one thing a declaration does not cover; each test asserts the
audit reports exactly that thing, and the negative control asserts a covered read is NOT reported."""
import importlib.machinery
import importlib.util
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_verify-task-io"


def _load():
    loader = importlib.machinery.SourceFileLoader("verify_task_io", str(TOOL))
    spec = importlib.util.spec_from_loader("verify_task_io", loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["verify_task_io"] = mod
    loader.exec_module(mod)
    return mod


vti = _load()

CAN_TRACE = sys.platform.startswith("linux") and shutil.which("inotifywait") is not None
needs_inotify = pytest.mark.skipif(not CAN_TRACE, reason="tracing needs Linux and inotifywait")

# Long enough for inotifywait to write out the queued events on a loaded machine, short enough
# that a module's audits stay within seconds.
DRAIN = 0.5


@pytest.fixture(autouse=True)
def isolated_git(monkeypatch):
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    monkeypatch.setenv("GIT_AUTHOR_NAME", "t")
    monkeypatch.setenv("GIT_AUTHOR_EMAIL", "t@example.invalid")
    monkeypatch.setenv("GIT_COMMITTER_NAME", "t")
    monkeypatch.setenv("GIT_COMMITTER_EMAIL", "t@example.invalid")


class FakeNx:
    """The Nx seam: a fixed graph, declared inputs per project:target, and each target run as a
    shell command in the workspace. Like Nx, every run first reads nx.json, so the control's reads
    and a task's reads overlap and attribution by difference is exercised."""

    def __init__(self, root, tasks, deps, inputs, commands, projects, noop="ws:noop"):
        self.root = root
        self.tasks = tasks
        self.deps = deps
        self._inputs = inputs
        self.commands = commands
        self.projects = projects
        self.noop = noop
        self.ran = []

    def graph(self):
        return vti.Graph(projects=self.projects, tasks=self.tasks, dependencies=self.deps,
                         noop=self.noop)

    def inputs(self, key):
        files, dep_outputs = self._inputs.get(key, ([], []))
        return vti.Inputs(files=set(files), dep_outputs=set(dep_outputs))

    def refresh(self):
        pass

    def run(self, task_id, name):
        self.ran.append(task_id)
        (self.root / "nx.json").read_text()
        return subprocess.run(["sh", "-c", self.commands.get(task_id, "true")], cwd=self.root,
                              stdin=subprocess.DEVNULL, capture_output=True).returncode


def task(tid, outputs=(), cache=True):
    project, target = tid.split(":")[:2]
    return vti.Task(id=tid, project=project, target=target, outputs=list(outputs), cache=cache)


def make_workspace(root):
    for d in ("libs/a/src", "libs/b/src", "libs/c/src", "libs/d/src"):
        (root / d).mkdir(parents=True)
    (root / "nx.json").write_text("{}\n")
    (root / ".gitignore").write_text("dist/\n")
    (root / "libs/a/src/main.txt").write_text("declared\n")
    (root / "libs/a/secret.txt").write_text("undeclared\n")
    (root / "libs/b/src/main.txt").write_text("b\n")
    (root / "libs/c/child.txt").write_text("read by a grandchild\n")
    (root / "libs/d/src/main.txt").write_text("d\n")
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(root), "-c", "commit.gpgsign=false", "commit", "-q", "-m", "i"],
                   check=True)


PROJECTS = [("a", "libs/a"), ("b", "libs/b"), ("c", "libs/c"), ("d", "libs/d"), ("ws", ".")]


def plants_nx(root):
    """Four targets, each with one plant (b:build is the clean owner of dist/b):
    a:build  reads its declared input AND an undeclared file; writes an undeclared source file
    b:build  writes only its declared output dist/b
    c:build  a GRANDCHILD process reads an undeclared file
    d:build  writes into b:build's declared output"""
    tasks = {t.id: t for t in [
        task("ws:noop", cache=False),
        task("a:build", outputs=["dist/a"]),
        task("b:build", outputs=["dist/b"]),
        task("c:build", outputs=["dist/c"]),
        task("d:build", outputs=["dist/d"]),
    ]}
    inputs = {
        "a:build": (["libs/a/src/main.txt"], []),
        "b:build": (["libs/b/src/main.txt"], []),
        "c:build": ([], []),
        "d:build": (["libs/d/src/main.txt"], []),
    }
    commands = {
        "a:build": "cat libs/a/src/main.txt libs/a/secret.txt > /dev/null; echo x > libs/a/generated.txt",
        "b:build": "cat libs/b/src/main.txt > /dev/null; mkdir -p dist/b; echo b > dist/b/out.txt",
        "c:build": "sh -c '(cat libs/c/child.txt > /dev/null) & wait'",
        "d:build": "cat libs/d/src/main.txt > /dev/null; mkdir -p dist/b; echo d > dist/b/stray.txt",
    }
    return FakeNx(root, tasks, {}, inputs, commands, PROJECTS)


def paths(result, tid, kind):
    return {f.path for f in result.findings.get(tid, []) if f.kind == kind}


@pytest.fixture(scope="module")
def plants(tmp_path_factory):
    """One audit over every plant, shared by the tests that read it (each trace costs a drain)."""
    mp = pytest.MonkeyPatch()
    for k, v in {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t",
                 "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "t",
                 "GIT_COMMITTER_EMAIL": "t@example.invalid"}.items():
        mp.setenv(k, v)
    root = tmp_path_factory.mktemp("ws")
    make_workspace(root)
    scratch = tmp_path_factory.mktemp("scratch")
    import io
    out = io.StringIO()
    result = vti.audit(root, plants_nx(root), scratch, requested=[], static_only=False, drain=DRAIN,
                       out=out, err=out)
    mp.undo()
    result.text = out.getvalue()
    return result


@needs_inotify
def test_undeclared_read_is_reported(plants):
    assert "libs/a/secret.txt" in paths(plants, "a:build", "UNDECLARED-READ"), plants.text


@needs_inotify
def test_declared_input_read_is_not_reported(plants):
    # The negative control: the same target reads a declared input, which no finding may name.
    named = {f.path for f in plants.findings.get("a:build", [])}
    assert "libs/a/src/main.txt" not in named, plants.text
    assert "b:build" not in plants.findings, plants.text


@needs_inotify
def test_undeclared_write_is_reported(plants):
    assert "libs/a/generated.txt" in paths(plants, "a:build", "UNDECLARED-WRITE"), plants.text


@needs_inotify
def test_read_by_a_child_process_is_reported(plants):
    assert "libs/c/child.txt" in paths(plants, "c:build", "UNDECLARED-READ"), plants.text


@needs_inotify
def test_write_into_another_targets_output_is_reported(plants):
    found = [f for f in plants.findings.get("d:build", [])
             if f.kind == "FOREIGN-WRITE" and f.path == "dist/b/stray.txt"]
    assert found and "b:build" in found[0].detail, plants.text


@needs_inotify
def test_findings_exit_one(plants):
    assert plants.code == 1, plants.text


def single_nx(root, command, inputs=("libs/a/src/main.txt",)):
    tasks = {t.id: t for t in [task("ws:noop", cache=False), task("a:build", outputs=["dist/a"])]}
    return FakeNx(root, tasks, {}, {"a:build": (list(inputs), [])}, {"a:build": command}, PROJECTS)


@needs_inotify
def test_clean_target_exits_zero(tmp_path):
    root = tmp_path / "ws"
    root.mkdir()
    make_workspace(root)
    import io
    out = io.StringIO()
    r = vti.audit(root, single_nx(root, "cat libs/a/src/main.txt > /dev/null; mkdir -p dist/a; "
                                        "echo a > dist/a/o"),
                  tmp_path / "s", requested=[], static_only=False, drain=DRAIN, out=out, err=out)
    assert r.code == 0 and not r.findings, out.getvalue()


class DriftingNx(FakeNx):
    """The closing control (`control-after`) reads one file more than the first three did."""

    def __init__(self, *a, drift_file, **k):
        super().__init__(*a, **k)
        self.drift_file = drift_file

    def run(self, task_id, name):
        if name == "control-after":
            (self.root / self.drift_file).read_text()
        return super().run(task_id, name)


def _drift_audit(tmp_path, drift_file):
    import io
    root = tmp_path / "ws"
    root.mkdir()
    make_workspace(root)
    (root / "package-lock.json").write_text("{}\n")
    base = single_nx(root, "cat libs/a/src/main.txt > /dev/null; mkdir -p dist/a; echo a > dist/a/o")
    nx = DriftingNx(root, base.tasks, base.deps, base._inputs, base.commands, base.projects,
                    drift_file=drift_file)
    out = io.StringIO()
    r = vti.audit(root, nx, tmp_path / "s", requested=[], static_only=False, drain=DRAIN,
                  out=out, err=out)
    return r, out.getvalue()


@needs_inotify
def test_closing_control_drift_in_the_root_lockfile_is_noted_not_refused(tmp_path):
    r, text = _drift_audit(tmp_path, "package-lock.json")
    assert r.code == 0, text
    assert "note: the closing control read the root lockfile" in text and "package-lock.json" in text, text


@needs_inotify
def test_closing_control_drift_elsewhere_still_refuses(tmp_path):
    r, text = _drift_audit(tmp_path, "libs/a/secret.txt")
    assert r.code == vti.EXIT_UNTRUSTED and "drifted during the audit" in text, text


@needs_inotify
def test_a_failed_target_makes_the_run_untrustworthy_not_ok(tmp_path):
    # A target that exits non-zero leaves a partial trace (its dependencies unbuilt, say): reading its
    # line as "ok" would bless a measurement that never finished (keystone, 2026-11-08).
    root = tmp_path / "ws"
    root.mkdir()
    make_workspace(root)
    import io
    out = io.StringIO()
    r = vti.audit(root, single_nx(root, "cat libs/a/src/main.txt > /dev/null; exit 1"),
                  tmp_path / "s", requested=[], static_only=False, drain=DRAIN, out=out, err=out)
    text = out.getvalue()
    assert r.code == vti.EXIT_UNTRUSTED, text
    assert "FAILED a:build" in text and "ok   a:build" not in text, text


@needs_inotify
def test_nested_worktrees_are_not_watched(tmp_path):
    # A checkout holding other sessions' worktrees under .worktrees/: their activity during a run
    # must not read as this target's writes.
    root = tmp_path / "ws"
    root.mkdir()
    make_workspace(root)
    import io
    out = io.StringIO()
    r = vti.audit(root, single_nx(root, "cat libs/a/src/main.txt > /dev/null; mkdir -p dist/a; "
                                        "echo a > dist/a/o; mkdir -p .worktrees/other; "
                                        "echo x > .worktrees/other/f"),
                  tmp_path / "s", requested=[], static_only=False, drain=DRAIN, out=out, err=out)
    assert r.code == 0 and not r.findings, out.getvalue()


@needs_inotify
def test_register_accepts_a_read_and_reports_a_stale_entry(tmp_path):
    root = tmp_path / "ws"
    root.mkdir()
    make_workspace(root)
    (root / ".verify-task-io.toml").write_text(
        '[[accepted]]\nkind = "read"\nglob = "libs/a/secret.txt"\ntargets = ["a:build"]\n'
        'why = "measured harmless"\n\n'
        '[[accepted]]\nkind = "read"\nglob = "libs/a/never-read.txt"\ntargets = ["a:build"]\n'
        'why = "no longer happens"\n')
    import io
    out = io.StringIO()
    r = vti.audit(root, single_nx(root, "cat libs/a/src/main.txt libs/a/secret.txt > /dev/null"),
                  tmp_path / "s", requested=[], static_only=False, drain=DRAIN, out=out, err=out)
    assert "a:build" not in r.findings, out.getvalue()  # the used entry excused the read
    stale = [f for fs in r.findings.values() for f in fs if f.kind == "STALE-ACCEPTANCE"]
    assert [f.path for f in stale] == ["libs/a/never-read.txt"], out.getvalue()
    assert r.code == 1


def test_static_reports_an_eagerly_hashed_dependency_output(tmp_path):
    root = tmp_path / "ws"
    root.mkdir()
    (root / "nx.json").write_text("{}\n")
    tasks = {t.id: t for t in [task("ws:noop", cache=False), task("b:build", outputs=["dist/b"]),
                               task("d:test", outputs=[])]}
    nx = FakeNx(root, tasks, {"d:test": ["b:build"]},
                {"d:test": (["dist/b/out.txt", "libs/d/src/main.txt"], []), "b:build": ([], [])},
                {}, PROJECTS)
    import io
    out = io.StringIO()
    r = vti.audit(root, nx, tmp_path / "s", requested=[], static_only=True, drain=DRAIN, out=out,
                  err=out)
    assert paths(r, "d:test", "EAGER-HASHED-DEPENDENCY-OUTPUT") == {"dist/b/out.txt"}, out.getvalue()
    assert nx.ran == []  # static mode executes nothing
    assert r.code == 1


def test_task_graph_dependencies_accept_nx24_edge_objects_and_nx23_ids():
    # Nx 24 writes each task-graph edge as an object ({"id": ..., "waitFor"?, "inputs"?}); Nx 23 wrote
    # the id string. Read either; an object read as an id crashed the first live run (2026-11-08), and
    # the TypeScript original silently found no dependencies at all.
    tg = {"tasks": {"a:t": {"target": {"project": "a", "target": "t"}, "outputs": [], "cache": True},
                    "b:t": {"target": {"project": "b", "target": "t"}, "outputs": ["dist/b"], "cache": True},
                    "c:t": {"target": {"project": "c", "target": "t"}, "outputs": [], "cache": True}},
          "dependencies": {"a:t": [{"id": "b:t"}, {"id": "c:t", "waitFor": "ready"}],
                           "b:t": ["c:t"], "c:t": []}}
    g = vti.task_graph(tg, projects=[], noop=None)
    assert g.dependencies == {"a:t": ["b:t", "c:t"], "b:t": ["c:t"], "c:t": []}
    assert set(g.tasks) == {"a:t", "b:t", "c:t"} and g.tasks["b:t"].outputs == ["dist/b"]


def test_unknown_target_is_a_usage_error(tmp_path):
    root = tmp_path / "ws"
    root.mkdir()
    make_workspace(root)
    import io
    out = io.StringIO()
    r = vti.audit(root, single_nx(root, "true"), tmp_path / "s", requested=["nope:build"],
                  static_only=True, drain=DRAIN, out=out, err=out)
    assert r.code == vti.EXIT_USAGE


def test_register_entry_without_a_reason_is_refused(tmp_path):
    (tmp_path / ".verify-task-io.toml").write_text('[[accepted]]\nkind = "read"\nglob = "x"\n')
    with pytest.raises(vti.UsageError, match="why"):
        vti.load_register(tmp_path)


def test_non_linux_is_refused_before_anything_runs(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(vti.sys, "platform", "darwin")
    (tmp_path / "nx.json").write_text("{}\n")
    code = vti.main(["--workspace", str(tmp_path)])
    assert code == vti.EXIT_PLATFORM == 4
    assert "Linux" in capsys.readouterr().err


def test_event_queue_overflow_is_a_measurement_failure():
    with pytest.raises(vti.MeasurementError):
        vti.parse_events("Q_OVERFLOW\t./\n", "x")


def test_parse_events_reads_and_writes():
    opens, writes = vti.parse_events(
        "CLOSE_NOWRITE,CLOSE\t./a.txt\nCLOSE_NOWRITE,CLOSE,ISDIR\t./libs\n"
        "CLOSE_WRITE,CLOSE\t./b.txt\nCREATE,ISDIR\t./dist\nCLOSE_NOWRITE,CLOSE\t./.nx/x\n", "x")
    assert dict(opens) == {"a.txt": 1}
    assert writes == {"b.txt", "dist/"}


@pytest.mark.parametrize("path,pattern,expected", [
    ("dist/b/out.txt", "dist/b/**", True),
    ("dist/b/.hidden", "dist/b/**/*", False),
    ("libs/x/.gitignore", "**/.gitignore", True),
    (".gitignore", "**/.gitignore", True),
    ("dist/a/x.js", "dist/{a,b}/*.js", True),
    ("dist/c/x.js", "dist/{a,b}/*.js", False),
    ("package.json", "package.json", True),
    ("libs/package.json", "package.json", False),
])
def test_glob_match(path, pattern, expected):
    assert vti.glob_match(path, pattern) is expected


@pytest.mark.parametrize("path,expected", [
    ("nx.json", True),
    ("package-lock.json", True),
    ("pnpm-lock.yaml", True),
    ("yarn.lock", True),
    ("libs/a/package-lock.json", False),
    ("src/lock.json", False),
])
def test_nx_config_counts_the_root_lockfile_as_nx_own(path, expected):
    # Nx reads the root lockfile on every graph build, so its control count may vary like nx.json's.
    assert bool(vti.NX_CONFIG.match(path)) is expected


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))
