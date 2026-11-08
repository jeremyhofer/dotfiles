#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for git-branch-gone. Every repository is a scratch one under a temp dir: a working clone
with two bare remotes, `origin` and `github`, so deletion is exercised against real remotes and
confirmed with real ls-remote. git-branch-gone runs as a subprocess, the way a user meets it."""
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "private_dot_local" / "bin" / "executable_git-branch-gone"


@pytest.fixture(autouse=True)
def isolated_git(monkeypatch):
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    for k in ("GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"):
        monkeypatch.setenv(k, "t")
    for k in ("GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"):
        monkeypatch.setenv(k, "t@example.invalid")


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True,
                          text=True).stdout.strip()


def gone(cwd, *args):
    return subprocess.run([sys.executable, str(TOOL), *args], cwd=str(cwd), capture_output=True, text=True)


def commit(cwd, name, text=None):
    (Path(cwd) / name).write_text(text or f"{name}\n")
    git(cwd, "add", name)
    git(cwd, "commit", "-q", "-m", f"add {name}")


def heads(remote):
    return set(git(remote, "for-each-ref", "--format=%(refname:short)", "refs/heads").split())


@pytest.fixture
def repo(tmp_path):
    """A clone with main pushed to two bare remotes; origin's HEAD is main."""
    origin, github, work = tmp_path / "origin.git", tmp_path / "github.git", tmp_path / "work"
    for bare in (origin, github):
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(bare)], check=True)
    work.mkdir()
    git(work, "init", "-q", "-b", "main")
    git(work, "config", "commit.gpgsign", "false")
    commit(work, "base.txt")
    git(work, "remote", "add", "origin", str(origin))
    git(work, "remote", "add", "github", str(github))
    git(work, "push", "-q", "origin", "main")
    git(work, "push", "-q", "github", "main")
    return work, origin, github


def feature(work, name="feat", files=("a.txt",)):
    git(work, "checkout", "-q", "-b", name, "main")
    for f in files:
        commit(work, f)
    git(work, "push", "-q", "origin", name)
    git(work, "push", "-q", "github", name)
    git(work, "checkout", "-q", "main")


def land_on_main(work, how, name="feat"):
    """Integrate the branch into main by `how` and push main to both remotes."""
    if how == "ff":
        git(work, "merge", "-q", "--ff-only", name)
    elif how == "squash":
        git(work, "merge", "-q", "--squash", name)
        git(work, "commit", "-q", "-m", "squash")
    elif how == "cherry-pick":
        commit(work, "unrelated.txt")   # main moves on, so a cherry-pick makes new commits
        for c in reversed(git(work, "rev-list", f"main..{name}").split()):
            git(work, "cherry-pick", c)
    for r in ("origin", "github"):
        git(work, "push", "-q", r, "main")


def test_an_unmerged_branch_is_refused_and_stays_everywhere(repo):
    work, origin, github = repo
    feature(work)
    r = gone(work, "feat", "--delete")
    assert r.returncode == 1
    assert "not in origin/main" in r.stderr
    assert "feat" in heads(origin) and "feat" in heads(github)


def test_a_branch_with_one_unique_commit_is_refused(repo):
    work, origin, github = repo
    feature(work, files=("a.txt", "b.txt"))
    git(work, "checkout", "-q", "main")
    git(work, "cherry-pick", git(work, "rev-list", "-n1", "feat~1"))  # a.txt lands, b.txt does not
    git(work, "push", "-q", "origin", "main")
    r = gone(work, "feat", "--delete")
    assert r.returncode == 1 and "feat" in heads(origin) and "feat" in heads(github)


@pytest.mark.parametrize("how,test", [("ff", "ancestor"), ("cherry-pick", "cherry"), ("squash", "merge-tree")])
def test_an_integrated_branch_is_deleted_from_every_remote_and_confirmed(repo, how, test):
    work, origin, github = repo
    feature(work, files=("a.txt", "b.txt"))   # two commits, so a squash's patch matches neither
    land_on_main(work, how)
    r = gone(work, "feat", "--delete")
    assert r.returncode == 0, r.stderr
    assert f"integrated: {test}" in r.stdout
    assert r.stdout.count("ls-remote confirms it is gone") == 2
    assert "feat" not in heads(origin) and "feat" not in heads(github)
    assert git(work, "for-each-ref", "refs/git-branch-gone") == ""   # its temporary refs are gone


def test_a_remote_tip_ahead_of_a_merged_local_branch_is_refused_on_that_remote(repo, tmp_path):
    work, origin, github = repo
    feature(work)
    land_on_main(work, "ff")
    other = tmp_path / "other"   # someone else adds a commit to feat on github only
    subprocess.run(["git", "clone", "-q", "-b", "feat", str(github), str(other)], check=True)
    git(other, "config", "commit.gpgsign", "false")
    commit(other, "late.txt")
    git(other, "push", "-q", "origin", "feat")
    r = gone(work, "feat", "--delete")
    assert r.returncode == 1
    assert "feat" not in heads(origin)          # origin's tip was merged: deleted
    assert "feat" in heads(github)              # github's tip has a later commit: kept
    assert "github: refused" in r.stderr


def test_without_delete_nothing_changes(repo):
    work, origin, github = repo
    feature(work)
    land_on_main(work, "ff")
    r = gone(work, "feat")
    assert r.returncode == 0 and r.stdout.count("would delete feat") == 2
    assert "feat" in heads(origin) and "feat" in heads(github)


@pytest.mark.parametrize("name", ["main", "devel"])
def test_a_protected_branch_is_refused(repo, name):
    work, origin, github = repo
    if name != "main":
        git(work, "branch", name)
        git(work, "push", "-q", "origin", name)
    r = gone(work, name, "--delete")
    assert r.returncode == 1 and "protected" in r.stderr
    assert name in heads(origin)


def test_land_branch_is_protected(repo):
    work, origin, github = repo
    feature(work, name="release")
    land_on_main(work, "ff", name="release")
    git(work, "config", "land.branch", "release")
    r = gone(work, "release", "--delete")
    assert r.returncode == 1 and "release" in heads(origin)


def test_a_remote_without_the_branch_is_skipped_and_one_url_is_one_remote(repo):
    work, origin, github = repo
    git(work, "remote", "add", "all", str(origin))   # a fan-out remote with origin's URL
    git(work, "checkout", "-q", "-b", "feat", "main")
    commit(work, "a.txt")
    git(work, "push", "-q", "origin", "feat")         # on origin only
    git(work, "checkout", "-q", "main")
    land_on_main(work, "ff")
    r = gone(work, "feat", "--delete")
    assert r.returncode == 0, r.stderr
    assert r.stdout.count("deleted feat") == 1        # origin once, not again as `all`
    assert "feat" not in heads(origin)


def test_a_clone_integrating_into_devel_judges_against_devel(repo):
    """The remote's default is main, but the clone integrates into devel (worktrunk's default
    branch), as a repository whose release branch is main does."""
    work, origin, github = repo
    git(work, "branch", "devel")
    git(work, "push", "-q", "origin", "devel")
    git(work, "config", "worktrunk.default-branch", "devel")
    git(work, "checkout", "-q", "-b", "feat", "devel")
    commit(work, "a.txt")
    git(work, "push", "-q", "origin", "feat")
    git(work, "checkout", "-q", "devel")
    git(work, "merge", "-q", "--ff-only", "feat")
    git(work, "push", "-q", "origin", "devel")       # in devel, not in main
    r = gone(work, "feat", "--delete")
    assert r.returncode == 0, r.stderr
    assert "feat" not in heads(origin)
    r = gone(work, "main", "--delete")               # the remote's default stays protected
    assert r.returncode == 1 and "main" in heads(origin)

def test_no_remote_has_it(repo):
    work, _, _ = repo
    r = gone(work, "nope", "--delete")
    assert r.returncode == 0 and "nothing to do" in r.stdout


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))
