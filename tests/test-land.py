#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for land. Every repository is a scratch repository under a temp dir; the gate is a
stand-in shell command, so nothing depends on a real project. land runs as a subprocess, the way
a user meets it."""
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_land"


@pytest.fixture(autouse=True)
def isolated_git(monkeypatch):
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    monkeypatch.setenv("GIT_AUTHOR_NAME", "t")
    monkeypatch.setenv("GIT_AUTHOR_EMAIL", "t@example.invalid")
    monkeypatch.setenv("GIT_COMMITTER_NAME", "t")
    monkeypatch.setenv("GIT_COMMITTER_EMAIL", "t@example.invalid")
    # Never the machine's real timing slot: `true check` answers "free".
    monkeypatch.setenv("LAND_SLOT_CMD", "true")


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True,
                          text=True).stdout.strip()


def land(root, *args):
    return subprocess.run([sys.executable, str(TOOL), *args], cwd=str(root),
                          capture_output=True, text=True)


def commit(root, name, text="x\n"):
    (Path(root) / name).write_text(text)
    git(root, "add", name)
    git(root, "commit", "-q", "-m", f"add {name}")


@pytest.fixture
def repo(tmp_path):
    """A repository on main with one commit and a passing gate, plus a feature worktree."""
    root = tmp_path / "main"
    root.mkdir()
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "commit.gpgsign", "false")
    git(root, "config", "land.gate", "true")
    commit(root, "base.txt")
    feat = tmp_path / "feat"
    git(root, "worktree", "add", "-q", "-b", "feat", str(feat))
    return root, feat


def test_happy_path_ff_from_separate_worktree(repo):
    main, feat = repo
    commit(feat, "a.txt")
    r = land(feat, "check")
    assert r.returncode == 0, r.stderr
    r = land(feat)
    assert r.returncode == 0, r.stderr
    assert git(main, "rev-parse", "main") == git(feat, "rev-parse", "HEAD")
    # the main checkout was updated, not just the ref
    assert (main / "a.txt").exists()
    assert git(main, "status", "--porcelain") == ""


def test_happy_path_no_ff_merge_commit_tree_equals_passed_tree(repo):
    main, feat = repo
    git(main, "config", "land.merge", "no-ff")
    commit(feat, "a.txt")
    tree = git(feat, "rev-parse", "HEAD^{tree}")
    assert land(feat, "check").returncode == 0
    r = land(feat, "merge")
    assert r.returncode == 0, r.stderr
    tip = git(main, "rev-parse", "main")
    assert len(git(main, "rev-list", "--parents", "-n1", tip).split()) == 3  # a merge commit
    assert git(main, "rev-parse", "main^{tree}") == tree


def test_branch_not_checked_out_anywhere(repo):
    main, feat = repo
    git(main, "checkout", "-q", "-b", "other")
    commit(feat, "a.txt")
    assert land(feat, "check").returncode == 0
    r = land(feat)
    assert r.returncode == 0, r.stderr
    assert git(main, "rev-parse", "main") == git(feat, "rev-parse", "HEAD")


def test_no_ff_branch_not_checked_out_anywhere(repo):
    main, feat = repo
    git(main, "config", "land.merge", "no-ff")
    git(main, "checkout", "-q", "-b", "other")
    commit(feat, "a.txt")
    tree = git(feat, "rev-parse", "HEAD^{tree}")
    assert land(feat, "check").returncode == 0
    r = land(feat)
    assert r.returncode == 0, r.stderr
    assert git(main, "rev-parse", "main^{tree}") == tree
    assert len(git(main, "rev-list", "--parents", "-n1", "main").split()) == 3


def test_custom_integration_branch(repo):
    main, feat = repo
    git(main, "branch", "devel")
    git(feat, "rebase", "-q", "devel")
    git(main, "config", "land.branch", "devel")
    commit(feat, "a.txt")
    assert land(feat, "check").returncode == 0
    assert land(feat).returncode == 0
    assert git(main, "rev-parse", "devel") == git(feat, "rev-parse", "HEAD")
    assert git(main, "rev-parse", "main") != git(feat, "rev-parse", "HEAD")


def test_commit_after_pass_is_refused(repo):
    main, feat = repo
    commit(feat, "a.txt")
    assert land(feat, "check").returncode == 0
    commit(feat, "b.txt")
    before = git(main, "rev-parse", "main")
    r = land(feat)
    assert r.returncode != 0
    assert "land check" in r.stderr
    assert git(main, "rev-parse", "main") == before


def test_rebase_after_pass_is_refused(repo):
    main, feat = repo
    commit(feat, "a.txt")
    assert land(feat, "check").returncode == 0
    commit(main, "m.txt")
    git(feat, "rebase", "-q", "main")
    before = git(main, "rev-parse", "main")
    assert land(feat).returncode != 0
    assert git(main, "rev-parse", "main") == before


def test_failed_gate_records_nothing_and_landing_refused(repo):
    main, feat = repo
    git(main, "config", "land.gate", "exit 7")
    commit(feat, "a.txt")
    r = land(feat, "check")
    assert r.returncode != 0
    assert "7" in r.stderr
    before = git(main, "rev-parse", "main")
    r = land(feat)
    assert r.returncode != 0
    assert git(main, "rev-parse", "main") == before
    assert "no recorded pass" in land(feat, "status").stdout


def slot_stub(tmp_path, rc, text):
    p = tmp_path / "fleet-slot-stub"
    p.write_text(f"#!/bin/sh\necho '{text}'\nexit {rc}\n")
    p.chmod(0o755)
    return str(p)


def test_check_warns_but_passes_when_another_session_holds_the_slot(repo, tmp_path, monkeypatch):
    main, feat = repo
    monkeypatch.setenv("LAND_SLOT_CMD", slot_stub(tmp_path, 1, "held by other-session since 13:00"))
    commit(feat, "a.txt")
    r = land(feat, "check")
    assert r.returncode == 0, r.stderr
    assert "warning: the timing slot is held by other-session" in r.stderr
    assert land(feat).returncode == 0


def test_check_is_silent_when_the_slot_is_free_or_the_check_fails(repo, tmp_path, monkeypatch):
    main, feat = repo
    commit(feat, "a.txt")
    for rc, text in ((0, "free"), (2, "broken")):
        monkeypatch.setenv("LAND_SLOT_CMD", slot_stub(tmp_path, rc, text))
        r = land(feat, "check")
        assert r.returncode == 0 and "timing slot" not in r.stderr


def test_passing_after_failure_then_lands(repo):
    main, feat = repo
    git(main, "config", "land.gate", "test -e fixed.txt")
    commit(feat, "a.txt")
    assert land(feat, "check").returncode != 0
    commit(feat, "fixed.txt")
    assert land(feat, "check").returncode == 0
    assert land(feat).returncode == 0


def test_dirty_tree_refused_at_check_and_gate_not_run(repo, tmp_path):
    main, feat = repo
    marker = tmp_path / "ran"
    git(main, "config", "land.gate", f"touch {marker}")
    commit(feat, "a.txt")
    (feat / "a.txt").write_text("changed\n")
    r = land(feat, "check")
    assert r.returncode != 0
    assert "uncommitted" in r.stderr
    assert not marker.exists()


def test_untracked_file_counts_as_dirty_but_ignored_does_not(repo):
    main, feat = repo
    commit(feat, ".gitignore", "ign.txt\n")
    (feat / "ign.txt").write_text("i\n")
    assert land(feat, "check").returncode == 0
    (feat / "new.txt").write_text("n\n")
    assert land(feat, "check").returncode != 0


def test_dirty_tree_refused_at_land(repo):
    main, feat = repo
    commit(feat, "a.txt")
    assert land(feat, "check").returncode == 0
    (feat / "a.txt").write_text("changed\n")
    before = git(main, "rev-parse", "main")
    r = land(feat)
    assert r.returncode != 0
    assert "uncommitted" in r.stderr
    assert git(main, "rev-parse", "main") == before


def test_gate_that_dirties_the_tree_records_nothing(repo):
    main, feat = repo
    git(main, "config", "land.gate", "echo gen > generated.txt")
    commit(feat, "a.txt")
    r = land(feat, "check")
    assert r.returncode == 1
    (feat / "generated.txt").unlink()
    git(main, "config", "land.gate", "true")
    # nothing was recorded by the dirtying run: only a clean passing run records
    assert "no recorded pass" in land(feat, "status").stdout


def test_integration_branch_not_ancestor_refused(repo):
    main, feat = repo
    commit(feat, "a.txt")
    commit(main, "m.txt")
    assert land(feat, "check").returncode == 0
    before = git(main, "rev-parse", "main")
    r = land(feat)
    assert r.returncode != 0
    assert "not an ancestor of HEAD" in r.stderr
    assert git(main, "rev-parse", "main") == before


def test_integration_branch_not_ancestor_refused_no_ff(repo):
    main, feat = repo
    git(main, "config", "land.merge", "no-ff")
    commit(feat, "a.txt")
    commit(main, "m.txt")
    assert land(feat, "check").returncode == 0
    before = git(main, "rev-parse", "main")
    r = land(feat)
    assert r.returncode != 0
    assert "not an ancestor of HEAD" in r.stderr
    assert git(main, "rev-parse", "main") == before


def test_landing_into_dirty_main_worktree_refused(repo):
    main, feat = repo
    commit(feat, "a.txt")
    assert land(feat, "check").returncode == 0
    (main / "base.txt").write_text("dirty\n")
    before = git(main, "rev-parse", "main")
    r = land(feat)
    assert r.returncode != 0
    assert str(main) in r.stderr or "main" in r.stderr
    assert git(main, "rev-parse", "main") == before
    assert (main / "base.txt").read_text() == "dirty\n"


def test_ledger_shared_across_worktrees(repo, tmp_path):
    main, feat = repo
    commit(feat, "a.txt")
    assert land(feat, "check").returncode == 0
    second = tmp_path / "second"
    git(main, "worktree", "add", "-q", "-b", "second", str(second), "feat")
    assert "recorded pass" in land(second, "status").stdout
    assert "no recorded pass" not in land(second, "status").stdout
    # and the ledger is inside the common git dir, never in a worktree
    assert git(second, "status", "--porcelain") == ""
    assert (main / ".git" / "land").exists()


def test_status_reports_without_changing_anything(repo):
    main, feat = repo
    commit(feat, "a.txt")
    before = git(main, "rev-parse", "main")
    r = land(feat, "status")
    assert "no recorded pass" in r.stdout
    assert git(main, "rev-parse", "main") == before


def test_nothing_to_land_when_on_integration_branch(repo):
    main, feat = repo
    r = land(main)
    assert r.returncode == 0
    assert "nothing to land" in r.stdout.lower()


def test_missing_gate_config_is_an_error(repo):
    main, feat = repo
    git(main, "config", "--unset", "land.gate")
    r = land(feat, "check")
    assert r.returncode == 2
    assert "land.gate" in r.stderr


def test_help_documents_exit_codes(repo):
    main, feat = repo
    r = land(feat, "--help")
    assert r.returncode == 0
    assert "exit" in r.stdout.lower() and "land.gate" in r.stdout


def test_never_pushes(repo, tmp_path):
    main, feat = repo
    bare = tmp_path / "remote.git"
    subprocess.run(["git", "init", "-q", "--bare", str(bare)], check=True)
    git(main, "remote", "add", "origin", str(bare))
    commit(feat, "a.txt")
    assert land(feat, "check").returncode == 0
    assert land(feat).returncode == 0
    assert git(bare, "branch", "--list") == ""


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
