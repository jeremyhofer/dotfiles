#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""The repository installs from the public npm registry and nothing else.

Run: sh tests/run-all.sh --only test-npm-registry.py
 or: uv run --script tests/test-npm-registry.py [-k <pattern>]

Two refusals, both about what a machine's own configuration may rewrite:

* git tracks no `.npmrc` anywhere in the repository. A registry or auth setting belongs to the machine
  that installs (its user-level npm configuration), never to the tree, where it would pin every
  machine to one registry and could carry a token.
* every `resolved` URL in `package-lock.json` is on `https://registry.npmjs.org/`. A machine that
  must install through a mirror rewrites that host to its mirror's; a lockfile that names any other
  host (a private registry, a git URL, a tarball elsewhere) cannot be rewritten and breaks that
  machine's install.

Each refusal is shown against a planted defect in a scratch repository, beside a control the same
check passes. The check reads `git ls-files`, so under the commit gate it judges what is staged.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
REGISTRY = "https://registry.npmjs.org/"
LOCKFILE = "package-lock.json"


def tracked_npmrc(root: Path) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True)
    return [p for p in out.stdout.decode("utf-8", "replace").split("\0")
            if p and os.path.basename(p) == ".npmrc"]


def resolved_urls(node, where=""):
    """Every `resolved` value in a parsed lockfile, with the package path it sits under."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "resolved" and isinstance(value, str):
                yield where, value
            else:
                yield from resolved_urls(value, f"{where}/{key}" if where else key)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from resolved_urls(value, f"{where}[{i}]")


def check(root: Path) -> list[str]:
    findings = [f"{p}: a tracked .npmrc; registry settings belong to the machine, not the tree"
                for p in tracked_npmrc(root)]
    lock = root / LOCKFILE
    if not lock.is_file():
        return findings + [f"{LOCKFILE}: missing"]
    count = 0
    for where, url in resolved_urls(json.loads(lock.read_text())):
        count += 1
        if not url.startswith(REGISTRY):
            findings.append(f"{LOCKFILE}: {where} resolves to {url}, not {REGISTRY}")
    if count == 0:
        findings.append(f"{LOCKFILE}: no resolved URL at all, so this check would see nothing")
    return findings


def test_this_tree_installs_from_the_public_registry():
    if subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--git-dir"], capture_output=True).returncode:
        pytest.skip("not a git checkout")
    assert check(ROOT) == []


def git(root, *args):
    subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)


def lock_with(*urls):
    return json.dumps({"lockfileVersion": 3, "packages": {
        "": {"name": "x"},
        **{f"node_modules/p{i}": {"version": "1.0.0", "resolved": u} for i, u in enumerate(urls)},
    }}, indent=2)


@pytest.fixture
def repo(tmp_path, monkeypatch):
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", os.devnull)
    git(tmp_path, "init", "-q")
    (tmp_path / LOCKFILE).write_text(lock_with(REGISTRY + "p0/-/p0-1.0.0.tgz"))
    git(tmp_path, "add", LOCKFILE)
    return tmp_path


def test_control_clean_scratch_repo_passes(repo):
    assert check(repo) == []


@pytest.mark.parametrize("rel", [".npmrc", "sub/dir/.npmrc"])
def test_tracked_npmrc_is_refused(repo, rel):
    p = repo / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("registry=https://example.invalid/\n")
    git(repo, "add", rel)
    findings = check(repo)
    assert len(findings) == 1 and rel in findings[0] and ".npmrc" in findings[0]


def test_untracked_npmrc_is_not_refused(repo):
    (repo / ".npmrc").write_text("registry=https://example.invalid/\n")
    assert check(repo) == []


def test_a_file_named_like_npmrc_is_not_refused(repo):
    (repo / "private_dot_npmrc").write_text("x=1\n")
    git(repo, "add", "private_dot_npmrc")
    assert check(repo) == []


@pytest.mark.parametrize("url", [
    "https://registry.example.invalid/p0/-/p0-1.0.0.tgz",
    "http://registry.npmjs.org/p0/-/p0-1.0.0.tgz",
    "https://registry.npmjs.org.evil.invalid/p0/-/p0-1.0.0.tgz",
    "git+ssh://git@example.invalid/p0.git#abc",
])
def test_resolved_url_off_the_registry_is_refused(repo, url):
    (repo / LOCKFILE).write_text(lock_with(REGISTRY + "p0/-/p0-1.0.0.tgz", url))
    findings = check(repo)
    assert len(findings) == 1 and url in findings[0] and "node_modules/p1" in findings[0]


def test_a_lockfile_with_no_resolved_url_is_refused(repo):
    (repo / LOCKFILE).write_text(json.dumps({"lockfileVersion": 3, "packages": {"": {}}}))
    assert any("no resolved URL" in f for f in check(repo))


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))
