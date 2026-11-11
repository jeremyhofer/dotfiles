#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest==8.4.2"]
# ///
"""Tests for image-bump: its frame and `validate`, `check` for a container image, `deploy`, the
artifact descriptors that move an image build's pinned inputs, and `latest`.

Run: sh tests/run-all.sh --only test-image-bump.py
 or: uv run --script tests/test-image-bump.py [-k <pattern>]

TWO KINDS OF TEST, AND WHY BOTH
===============================
An IN-PROCESS test loads the tool's file as a Python module (importlib, as the loop-time suite
does) and calls its `main(argv)` with the arguments a command line would pass. pytest's `capsys`
captures what it prints and `monkeypatch` sets its environment for that one test. No interpreter
starts per case, so a case costs milliseconds. Most of this file is in-process.

What an in-process test cannot see is the layer between the tool and the machine. It runs the tool
on the interpreter running pytest (uv's, 3.12 or newer), never on the `python3` the tool's shebang
finds; it never executes the shebang, nor the `sys.exit(main())` that turns main's return value into
an exit status; and it meets external programs through fakes (below), never through PATH. That
layer is where this repository's tools have actually failed on macOS: Apple's Python 3.9 rather than
the 3.12 the tests ran on, a PATH without the tools Linux has, and temporary directories under /var
that resolve to /private/var. A CONTRACT test covers that layer: it runs the tool file as its own
process, through its shebang, on the PATH the machine gives, and judges it only by exit status and
output. There are few of them (`test_contract_*`); they cover the shebang, the exit statuses, PATH
lookup of external programs, and loading on the deployed python3.

HOW THE WORLD OUTSIDE THE TOOL IS SIMULATED
===========================================
* External programs. The tool runs skopeo, trivy, podman and cosign. A FAKE is a Python function
  standing in for one of them: `Commands` replaces the tool module's `subprocess`, records every
  argument vector (argv) it is handed, answers the faked programs from fixtures, and hands any other
  program (gpg, gpgv) to the real subprocess.run. The shell suites this file replaced used
  executable stubs on PATH at the same boundary, an argv in and a status and output out; a fake
  records the argv exactly, so a test compares whole argument lists where the shell suites matched
  regular expressions. Finding a program on PATH is the contract tests' job.
* The release hosts and the apt repository are a real HTTP server on 127.0.0.1, run in a thread of
  this process (`Web`), so the tool's own urllib code meets real status codes, a body cut short and
  a refused connection. Nothing reaches the network. The proxy variables are removed so that a
  loopback request goes direct.
* gpg and gpgv are the real programs, over two throwaway keys made once per session.
* Time. `deploy` retries its checks once a second for up to --wait seconds. A virtual clock
  (`Clock`) replaces the tool's `time`, so a retry costs nothing and the number of tries is exact.
* Temporary paths. pytest resolves its tmp_path, which on macOS turns /var/... into /private/var/....
  The shell suites used $TMPDIR as given, and that is how macOS's /var symlink reached them; the
  `work` fixture keeps $TMPDIR as given, so a macOS run still meets /var.
* Isolation. Every test has its own directory with its own HOME, XDG directories and TMPDIR, and
  every IMAGE_BUMP_* variable is cleared, so no test reads the machine's own descriptors or state.

PARITY AND MUTANTS
==================
Each check of the five shell suites is kept: its label (the first argument of their `ok`, `expect`,
`has`, `logged` or `before`) is the message of the assertion or the label of the table row that
replaced it, and the parity table beside this file (test-image-bump.parity.md) maps every label to a
pytest id.

A MUTANT is a copy of the tool with one exact find-and-replace, made to break one behavior on
purpose. MUTANTS (at the end of this file) lists each with the test that must fail against it, and
`test_mutant_is_caught` runs that one test against that copy in a child pytest. A test that has never
been seen to fail is of unknown value; the table is how each behavior's test is seen to fail.

THE LANDING LANE. The mutants take ten times as long as every other test here (each starts a child
pytest), so they run only before work lands on the integration branch, not on every run. They carry
the `mutant` marker; a run through this file's own entry point (run-all.sh, `uv run --script`)
deselects them unless RUN_MUTANTS=1, which the landing gate sets (tests/land-gate.sh). Running pytest
on this file directly bypasses that entry point and runs everything.
"""
import gzip
import hashlib
import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import urllib.parse
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
# The meta-test points IMAGE_BUMP_TEST_TOOL at a mutated copy of the tool (see MUTANTS).
TOOL = Path(os.environ.get("IMAGE_BUMP_TEST_TOOL")
            or HERE.parent / "private_dot_local" / "bin" / "executable_image-bump")


def _load(path):
    loader = importlib.machinery.SourceFileLoader("image_bump", str(path))
    spec = importlib.util.spec_from_loader("image_bump", loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["image_bump"] = mod
    loader.exec_module(mod)
    return mod


ib = _load(TOOL)

# $TMPDIR as the machine gives it, read before any test changes TMPDIR. Not resolved: see the
# module docstring on temporary paths.
ORIGINAL_TMP = tempfile.gettempdir()
PROXIES = ("http_proxy", "https_proxy", "all_proxy", "no_proxy",
           "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY")


# ================================================================= the harness

class Result:
    """What one run of the tool produced: its exit status and what it printed."""

    def __init__(self, status, out, err):
        self.status, self.out, self.err = status, out, err

    @property
    def lines(self):
        return (self.out + self.err).splitlines()

    def __repr__(self):
        return "status %s\n--- stdout\n%s--- stderr\n%s" % (self.status, self.out, self.err)


def expect(r, status, text=None, label="", stream="any"):
    """The run exited `status` and, when `text` is given, printed it (on `stream`: any, out, err)."""
    where = {"any": r.out + r.err, "out": r.out, "err": r.err}[stream]
    assert r.status == status, "%s: status %s, wanted %s\n%r" % (label, r.status, status, r)
    if text is not None:
        assert text in where, "%s: %r not in %s\n%r" % (label, text, stream, r)


@pytest.fixture
def work():
    """This test's directory, under $TMPDIR as given (not resolved), removed afterwards."""
    d = Path(tempfile.mkdtemp(prefix="image-bump-test-", dir=ORIGINAL_TMP))
    yield d
    shutil.rmtree(d, ignore_errors=True)


@pytest.fixture(autouse=True)
def isolated(work, monkeypatch):
    """A HOME, XDG directories and TMPDIR of this test's own; no IMAGE_BUMP_* or proxy variable."""
    for sub in ("home", "tmp"):
        (work / sub).mkdir()
    monkeypatch.setenv("HOME", str(work / "home"))
    for name, sub in (("XDG_STATE_HOME", "state"), ("XDG_CONFIG_HOME", "config"),
                      ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data")):
        monkeypatch.setenv(name, str(work / sub))
    monkeypatch.setenv("TMPDIR", str(work / "tmp"))
    # tempfile caches the directory it chose; the tool's TemporaryDirectory must land in this one.
    monkeypatch.setattr(tempfile, "tempdir", str(work / "tmp"))
    for name in [n for n in os.environ if n.startswith("IMAGE_BUMP_")] + list(PROXIES) + ["GNUPGHOME"]:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.chdir(work)


@pytest.fixture
def tool(capsys):
    """Run the tool in-process: tool("validate", "svc", "--root", root) -> Result."""
    def run(*argv):
        capsys.readouterr()
        status = ib.main([str(a) for a in argv])
        out, err = capsys.readouterr()
        return Result(status, out, err)
    return run


class Commands:
    """Stands in for the tool's `subprocess` module. A program named in `fakes` (argv[0] -> a
    function taking the argv and returning (status, stdout bytes, stderr bytes)) is answered by its
    fake and its argv appended to `log`, in call order; any other program runs for real."""
    PIPE = subprocess.PIPE
    STDOUT = subprocess.STDOUT

    def __init__(self):
        self.log = []
        self.fakes = {}

    def run(self, argv, stdout=None, stderr=None, **kwargs):
        argv = [str(a) for a in argv]
        fake = self.fakes.get(argv[0])
        if fake is None:
            return subprocess.run(argv, stdout=stdout, stderr=stderr, **kwargs)
        self.log.append(argv)
        status, out, err = fake(argv)
        if stderr == subprocess.STDOUT:
            out, err = out + err, b""
        # Like a real process: output not asked for with PIPE is not handed back.
        return subprocess.CompletedProcess(argv, status, out if stdout == subprocess.PIPE else None,
                                           err if stderr == subprocess.PIPE else None)

    def lines(self):
        return [" ".join(a) for a in self.log]


@pytest.fixture
def cmds(monkeypatch):
    c = Commands()
    monkeypatch.setattr(ib, "subprocess", c)
    return c


class Clock:
    """A virtual clock for the tool's `time`: sleep() advances monotonic() and returns at once."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        web = self.server.web
        web.log.append(self.path)
        u = urllib.parse.urlparse(self.path)
        rel = u.path.lstrip("/")
        if web.by_ref:
            rel += "@" + urllib.parse.parse_qs(u.query).get("ref", [""])[0]
        f = web.root / rel
        code_file, cut = Path(str(f) + ".code"), Path(str(f) + ".cut")
        if code_file.is_file():
            code = int(code_file.read_text())
        else:
            code = 200 if f.is_file() else 404
        body = f.read_bytes() if f.is_file() else b""
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body[:len(body) // 2] if cut.exists() else body)

    def log_message(self, *args):
        pass


class Web:
    """A release host on 127.0.0.1, serving the files under `root`, logging each request path.

    A request for /p is the file `root/p`; with `by_ref` set, /p?ref=T is the file `root/p@T` (a
    contents listing differs per git tag, and a file name cannot hold a query), and /p with no ref is
    `root/p@`. A sibling `<file>.code` holding a number answers that HTTP status; a sibling
    `<file>.cut` announces the whole file and sends half of it; an absent file is a 404."""

    def __init__(self, root):
        self.root = root
        root.mkdir(parents=True, exist_ok=True)
        self.log = []
        self.by_ref = False
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.server.daemon_threads = True
        self.server.web = self
        # serve_forever checks for shutdown() every poll_interval; the default 0.5 s would be paid by
        # every test at teardown.
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]

    def put(self, rel, data):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data if isinstance(data, bytes) else data.encode())
        return p

    def close(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def web(work):
    w = Web(work / "srv")
    yield w
    w.close()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def findings(*specs, packages=None):
    """A trivy JSON report. Each spec is "ID:package:fixed version", the fixed version possibly
    empty (an unfixed finding); `packages` adds that many detected packages."""
    vs = []
    for spec in specs:
        vid, pkg, fixed = spec.split(":")
        vs.append({"VulnerabilityID": vid, "PkgName": pkg, "InstalledVersion": "1.0",
                   "FixedVersion": fixed, "Severity": "HIGH"})
    result = {"Target": "x", "Vulnerabilities": vs or None}
    if packages is not None:
        result["Packages"] = [{"Name": "p%d" % n} for n in range(packages)]
    return {"Results": [result]}


class Trivy:
    """The trivy fake. `image --download-db-only` succeeds; `version --format json` answers
    `version` (None: it fails); a scan without --skip-db-update fails, because it would fetch the
    database again; `image ... <ref>` answers `by_ref[ref]`, `rootfs ... <dir>` answers
    `by_sha[sha256 of the one file under dir]`. A missing fixture fails."""

    def __init__(self):
        self.version = {"Version": "0.99.0", "VulnerabilityDB": {"UpdatedAt": "2026-10-27T06:00:00.5Z"}}
        self.by_ref = {}
        self.by_sha = {}

    def __call__(self, argv):
        a = argv[1:]
        if a[:2] == ["image", "--download-db-only"]:
            return 0, b"", b""
        if a[:2] == ["version", "--format"]:
            if self.version is None:
                return 1, b"", b"stub trivy: version unavailable"
            return 0, json.dumps(self.version).encode(), b""
        if "--skip-db-update" not in a:
            return 1, b"", b"stub trivy: a scan would download the database"
        if a[0] == "image":
            key, doc = argv[-1], self.by_ref.get(argv[-1])
        elif a[0] == "rootfs":
            files = sorted(p for p in Path(argv[-1]).rglob("*") if p.is_file())
            if len(files) != 1:
                return 1, b"", ("stub trivy: want one file, got %r" % files).encode()
            key = sha(files[0].read_bytes())
            doc = self.by_sha.get(key)
        else:
            return 2, b"", ("stub trivy: unexpected %r" % a).encode()
        if doc is None:
            return 1, b"", ("stub trivy: no fixture %s" % key).encode()
        return 0, json.dumps(doc).encode(), b""


# ---------------------------------------------------------------- container descriptors

IMG = "registry.invalid/acme/widget"
D0 = "sha256:" + "0123456789abcdef" * 4      # the current pin
DA = "sha256:" + "aa" * 32                   # the new arm64 manifest
DB = "sha256:" + "bb" * 32                   # the new amd64 manifest
DX = "sha256:" + "dd" * 32                   # some other digest
OLDPIN = "%s:v1.2.3-rootless@%s" % (IMG, D0)
NEWTAG = "v1.3.0-rootless"
NEWPIN = "%s:%s@%s" % (IMG, NEWTAG, DA)

# A valid container descriptor: field -> the Python source of its value, in descriptor order.
CONTAINER = {
    "image": '"%s"' % IMG,
    "release_line": '"patch-of-pinned-major"',
    "release_api": '{"host": "github", "repo": "acme/widget"}',
    "git_tag": '"v{version}"',
    "platform": '"linux/arm64"',
    "pin_file": '"IMAGE"',
    "scan_dir": '"scans"',
    "gate": '{"kind": "fixable-count-floor"}',
    "migrations": '{"kind": "added-files", "path": "models/migrations"}',
    "volume": '"widget-data"',
    "container": '"widget"',
    "service": '"widget.service"',
    "vm_unit": '"/etc/containers/systemd/widget.container"',
    "install": '{"kind": "vm-copy", "applied_unit": "/tmp/widget.container"}',
    "checks": '[{"name": "health", "command": ["curl", "-f", "http://localhost/health"], "pass": "exit 0"}]',
    "checklist": '["read the release notes"]',
    "tag_suffix": '"-rootless"',
}
# The fields only `deploy` reads, which a descriptor with a manual install must not have.
DEPLOY_ONLY = ("volume", "vm_unit", "container", "service", "checks")


def descriptor_text(**changes):
    """CONTAINER with `changes` applied: a value replaces a field's source, None removes it."""
    fields = dict(CONTAINER)
    for name, value in changes.items():
        if value is None:
            fields.pop(name, None)
        else:
            fields[name] = value
    return "".join("%s = %s\n" % kv for kv in fields.items())


def manual(steps='["load the tar as root", "check the unit is up"]', **more):
    """The changes that make a descriptor's install manual: its deploy-only fields removed."""
    return dict(dict.fromkeys(DEPLOY_ONLY), install='{"kind": "manual", "steps": %s}' % steps, **more)


def write_service(root, name, text, pin=OLDPIN):
    d = root / name
    d.mkdir(parents=True)
    (d / "IMAGE").write_text(pin + "\n")
    (d / "image_bump.py").write_text(text)
    return d


# ================================================================= the frame and `validate`

def test_a_good_descriptor_validates(work, tool):
    write_service(work / "root", "good", descriptor_text())
    r = tool("validate", "good", "--root", work / "root")
    expect(r, 0, label="good descriptor validates")
    assert "ok good" in r.out.splitlines(), "prints 'ok good'"


# Each refusal changes ONE thing in an otherwise valid descriptor, so it can only come from that.
VALIDATE = [
    pytest.param("missing field", {"volume": None}, OLDPIN, 4, "volume: missing", id="missing-field"),
    pytest.param("unknown gate kind", {"gate": '{"kind": "count-everything"}'}, OLDPIN, 4,
                 "gate: unknown kind 'count-everything'", id="unknown-gate-kind"),
    pytest.param("unknown migrations kind", {"migrations": '{"kind": "always-maybe", "path": "m"}'},
                 OLDPIN, 4, "migrations: unknown kind 'always-maybe'", id="unknown-migrations-kind"),
    pytest.param("unknown install kind", {"install": '{"kind": "teleport", "applied_unit": "/tmp/u"}'},
                 OLDPIN, 4, "install: unknown kind 'teleport'", id="unknown-install-kind"),
    pytest.param("unknown release_line strategy", {"release_line": '"whatever-is-newest"'}, OLDPIN, 4,
                 "release_line: unknown strategy", id="unknown-release-line"),
    pytest.param("platform not os/arch", {"platform": '"arm64"'}, OLDPIN, 4,
                 "platform: 'arm64' is not of the form os/arch", id="platform-not-os-arch"),
    pytest.param("near miss: another os/arch passes", {"platform": '"darwin/amd64"'}, OLDPIN, 0, None,
                 id="near-miss-another-os-arch"),
    pytest.param("missing container", {"container": None}, OLDPIN, 4, "container: missing",
                 id="missing-container"),
    pytest.param("missing service", {"service": None}, OLDPIN, 4, "service: missing", id="missing-service"),
    pytest.param("empty service", {"service": '""'}, OLDPIN, 4, "service: expected a non-empty str",
                 id="empty-service"),
    pytest.param("wrong type", {"volume": "7"}, OLDPIN, 4, "volume: expected a non-empty str",
                 id="wrong-type"),
    pytest.param("git_tag without {version}", {"git_tag": '"v1"'}, OLDPIN, 4,
                 "git_tag: must contain {version}", id="git-tag-without-version"),
    pytest.param("unparsable pin file", {}, "registry.invalid/acme/widget:v1.2.3", 4,
                 "pin_file: not of the form", id="unparsable-pin-file"),
    pytest.param("pin names another image", {}, "registry.invalid/acme/other:1.0@" + D0, 4, "pins image",
                 id="pin-names-another-image"),
    pytest.param("manual install without the deploy-only fields validates", manual(), OLDPIN, 0, None,
                 id="manual-validates"),
    pytest.param("manual without steps", dict(manual(), install='{"kind": "manual"}'), OLDPIN, 4,
                 "install: kind manual needs a non-empty list of non-empty strings in 'steps'",
                 id="manual-without-steps"),
    pytest.param("manual with empty steps", manual("[]"), OLDPIN, 4,
                 "install: kind manual needs a non-empty list", id="manual-empty-steps"),
    pytest.param("manual with an empty step", manual('["ok", ""]'), OLDPIN, 4,
                 "install: kind manual needs a non-empty list", id="manual-an-empty-step"),
    pytest.param("manual with a non-string step", manual("[7]"), OLDPIN, 4,
                 "install: kind manual needs a non-empty list", id="manual-non-string-step"),
] + [
    pytest.param("manual with %s present" % f, manual('["x"]', **{f: '"x"'}), OLDPIN, 4,
                 "%s: not valid with an install kind of manual" % f, id="manual-with-%s" % f)
    for f in DEPLOY_ONLY
] + [
    pytest.param("manual still needs migrations (check reads it)", manual('["x"]', migrations=None),
                 OLDPIN, 4, "migrations: missing", id="manual-needs-migrations"),
    pytest.param("near miss: a vm-copy install ignores a stray steps key",
                 {"install": '{"kind": "vm-copy", "applied_unit": "/tmp/u", "steps": 3}'}, OLDPIN, 0, None,
                 id="near-miss-vm-copy-stray-steps"),
]


@pytest.mark.parametrize("label,changes,pin,status,text", VALIDATE)
def test_validate(work, tool, label, changes, pin, status, text):
    write_service(work / "root", "svc", descriptor_text(**changes), pin)
    expect(tool("validate", "svc", "--root", work / "root"), status, text, label=label, stream="err")


def test_validate_without_a_descriptor_is_refused(work, tool):
    (work / "root").mkdir()
    expect(tool("validate", "absent", "--root", work / "root"), 4, "no descriptor at",
           label="no descriptor", stream="err")


def test_a_descriptor_raising_at_import_is_status_2_never_1(work, tool):
    (work / "root" / "boom").mkdir(parents=True)
    (work / "root" / "boom" / "image_bump.py").write_text('raise RuntimeError("boom")\n')
    expect(tool("validate", "boom", "--root", work / "root"), 2, "RuntimeError: boom",
           label="descriptor raising at import", stream="err")


def test_latest_on_an_unreachable_host_is_an_environment_error(work, tool, monkeypatch):
    write_service(work / "root", "good", descriptor_text())
    # Port 1 on the loopback: nothing listens, so the connection is refused at once.
    monkeypatch.setenv("IMAGE_BUMP_GITHUB_API", "http://127.0.0.1:1")
    monkeypatch.setenv("IMAGE_BUMP_CODEBERG_API", "http://127.0.0.1:1")
    expect(tool("latest", "good", "--root", work / "root"), 2, "reading http://127.0.0.1:1",
           label="latest on an unreachable host is an environment error", stream="err")


def test_an_unknown_verb_is_a_usage_error(tool):
    expect(tool("bogus", "good"), 2, label="unknown verb is a usage error")


def test_image_bump_root_is_the_default_root(work, tool, monkeypatch):
    write_service(work / "root", "good", descriptor_text())
    monkeypatch.setenv("IMAGE_BUMP_ROOT", str(work / "root"))
    expect(tool("validate", "good"), 0, label="IMAGE_BUMP_ROOT is the default root")


def test_the_pin_reader_and_version_helpers():
    label = "pin reader and version helpers"
    digest = "sha256:" + "ab" * 32
    assert ib.parse_pin("host:5000/a/b:v1.2@" + digest + "\n") == ("host:5000/a/b", "v1.2", digest), label
    for bad in ("a/b:1", "a/b@" + digest, "a/b:1@sha256:abc", "a/b:1@" + digest + "\nc/d:2@" + digest):
        with pytest.raises(ValueError):
            ib.parse_pin(bad)
    assert ib.version_from_tag("v1.2.3-rootless", "-rootless") == "1.2.3", label
    assert ib.version_from_tag("1.2.3") == "1.2.3", label
    assert ib.version_from_tag("v1.2.3", "-rootless") == "1.2.3", label
    assert ib.git_tag_for("v{version}", "1.2.3") == "v1.2.3", label


# ================================================================= `check` for a container image

def scan_argv(ref):
    """The argv of one image scan, exactly as the tool must run it."""
    return ["trivy", "image", "--skip-db-update", "--scanners", "vuln", "--image-src", "remote",
            "--platform", "linux/arm64", "--severity", "HIGH,CRITICAL", "--format", "json", ref]


class CheckWorld:
    """A container service `svc` pinned at 1.2.3 (D0), and a release 1.3.0 whose index lists an
    amd64 manifest (DB) and an arm64 one (DA). The current pin carries three findings, two fixable;
    the new image none. The migrations listing is a.go, b.go at both tags."""

    def __init__(self, work, web, cmds, tool, gate="fixable-count-floor", new_arch="arm64",
                 migrations=None):
        self.cmds, self.web, self._tool = cmds, web, tool
        self.root = work / "root"
        self.d = write_service(self.root, "svc", descriptor_text(
            gate='{"kind": "%s"}' % gate, migrations=migrations or CONTAINER["migrations"],
            checklist='["read the release notes", "tell the other sessions"]'))
        self.skopeo = {
            ("raw", "docker://%s:%s" % (IMG, NEWTAG)): json.dumps({"schemaVersion": 2, "manifests": [
                {"digest": DB, "platform": {"os": "linux", "architecture": "amd64"}},
                {"digest": DA, "platform": {"os": "linux", "architecture": "arm64"}}]}).encode(),
            ("config", "docker://%s@%s" % (IMG, DA)):
                json.dumps({"architecture": new_arch, "os": "linux"}).encode(),
        }
        self.trivy = Trivy()
        self.newfind()
        self.curfind("CVE-1:libfoo:1.1", "CVE-2:libbar:", "CVE-3:libbaz:2.0")
        cmds.fakes["skopeo"] = self._skopeo
        cmds.fakes["trivy"] = self.trivy
        web.by_ref = True
        self.listing("v1.2.3", "a.go", "b.go")
        self.listing("v1.3.0", "a.go", "b.go")

    def _skopeo(self, argv):
        mode = "raw" if "--raw" in argv else "config" if "--config" in argv else ""
        body = self.skopeo.get((mode, argv[-1]))
        if body is None:
            return 1, b"", ("stub skopeo: no fixture %s %s" % (mode, argv[-1])).encode()
        return 0, body, b""

    def newfind(self, *specs):
        self.trivy.by_ref["%s@%s" % (IMG, DA)] = findings(*specs)

    def curfind(self, *specs):
        self.trivy.by_ref["%s@%s" % (IMG, D0)] = findings(*specs)

    LISTING = "repos/acme/widget/contents/models/migrations@"

    def listing(self, tag, *names):
        """The migrations directory at a git tag, as the contents API lists it; a name ending in
        "/" is a directory."""
        self.web.put(self.LISTING + tag, json.dumps(
            [{"name": n.rstrip("/"), "type": "dir" if n.endswith("/") else "file"} for n in names]))

    def go(self, *args):
        return self._tool("check", "svc", *args, "--root", self.root)

    def pin(self):
        return (self.d / "IMAGE").read_text()

    def record(self):
        found = sorted((self.d / "scans").glob("widget-1.3.0-*.txt"))
        return found[0] if found else None

    def snap(self):
        """The pin file and every file under the scan directory, with their contents."""
        scans = self.d / "scans"
        files = sorted(scans.rglob("*")) if scans.exists() else []
        return self.pin(), [(str(p), p.read_bytes() if p.is_file() else None) for p in files]


@pytest.fixture
def check_world(work, web, cmds, tool, monkeypatch):
    monkeypatch.setenv("IMAGE_BUMP_GITHUB_API", web.url)
    return lambda **knobs: CheckWorld(work, web, cmds, tool, **knobs)


def test_check_a_clean_new_image_passes(check_world, cmds):
    w = check_world()
    r = w.go("1.3.0")
    expect(r, 0, "gate fixable-count-floor: pass", label="clean new image passes")
    log = cmds.log
    assert ["skopeo", "inspect", "--raw", "docker://%s:%s" % (IMG, NEWTAG)] in log, \
        "index resolved with --raw on the new tag"
    assert ["skopeo", "inspect", "--config", "docker://%s@%s" % (IMG, DA)] in log, \
        "config read on the chosen arm64 digest"
    db = ["trivy", "image", "--download-db-only"]
    assert log.count(db) == 1, "database fetched exactly once"
    scans = [i for i, a in enumerate(log) if "--skip-db-update" in a]
    assert scans and log.index(db) < scans[0], "database fetched before the first scan"
    assert ["trivy", "version", "--format", "json"] in log, "version read for the database timestamp"
    for d in (DA, D0):
        assert scan_argv("%s@%s" % (IMG, d)) in log, "scan of %s carries --skip-db-update and --platform" % d
    assert len(scans) == 2, "exactly two scans"
    assert w.pin() == NEWPIN + "\n", "pin file rewritten"
    rec = w.record()
    assert rec is not None, "record written as <name>-<version>-<date>.txt"
    assert re.fullmatch(r"widget-1\.3\.0-\d{4}-\d{2}-\d{2}\.txt", rec.name), "record name has an ISO date"
    assert "checklist: read the release notes" in r.out.splitlines(), "checklist printed"

    text = rec.read_text()
    lines = text.splitlines()
    assert lines[0] == "widget image CVE scan record", "record title line"
    for want in ("image: %s:%s" % (IMG, NEWTAG), "digest: " + DA, "platform: linux/arm64",
                 "replaces: " + D0, "scanner: 0.99.0", "database: 2026-10-27T06:00:00.5Z",
                 "gate: fixable-count-floor", "verdict: pass", "migrates: no"):
        assert want in lines, "record has '%s'" % want
    assert any(re.fullmatch(r"scanned: \d{4}-\d{2}-\d{2}T[0-9:]+[+-][0-9:]+ .+", ln) for ln in lines), \
        "record scanned: date-time with offset and host"
    assert re.search(r"CVE-1 +libfoo", text) and re.search(r"CVE-2 +libbar", text), \
        "record lists the current pin's findings"

    h = ib.read_record(str(rec))
    label = "read_record round-trips replaces, migrates, digest"
    assert (h["replaces"], h["migrates"], h["digest"], h["verdict"]) == (D0, "no", DA, "pass"), label
    assert h["scanned"].count(" ") == 1 and "CVE-1" not in str(h), label


def test_check_never_overwrites_a_record(check_world):
    w = check_world()
    assert w.go("1.3.0").status == 0
    rec = w.record()
    kept = rec.read_bytes()
    (w.d / "IMAGE").write_text(OLDPIN + "\n")
    expect(w.go("1.3.0"), 4, "exists", label="an existing record is never overwritten")
    assert rec.read_bytes() == kept, "existing record untouched"
    assert w.pin() == OLDPIN + "\n", "pin untouched on that refusal"


def test_check_refuses_an_image_built_for_another_platform(check_world, cmds):
    w = check_world(new_arch="amd64")
    expect(w.go("1.3.0"), 4, "built for linux/amd64",
           label="index whose arm64 entry's config says amd64 is refused")
    assert not any("--skip-db-update" in a for a in cmds.log), "no scan after the platform refusal"
    assert w.pin() == OLDPIN + "\n", "pin untouched"
    assert w.record() is None, "no record"


def test_check_refuses_an_index_without_the_platform(check_world):
    w = check_world()
    w.skopeo[("raw", "docker://%s:%s" % (IMG, NEWTAG))] = json.dumps({"manifests": [
        {"digest": "sha256:cc", "platform": {"os": "linux", "architecture": "amd64"}}]}).encode()
    expect(w.go("1.3.0"), 4, "no linux/arm64 entry", label="index with no entry for the platform is refused")


def test_check_a_single_manifest_resolves_to_the_hash_of_its_bytes(check_world):
    w = check_world()
    raw = b'{"schemaVersion": 2, "config": {"digest": "sha256:feed"}, "layers": []}\n'
    sd = "sha256:" + sha(raw)
    w.skopeo[("raw", "docker://%s:%s" % (IMG, NEWTAG))] = raw
    w.skopeo[("config", "docker://%s@%s" % (IMG, sd))] = b'{"architecture": "arm64", "os": "linux"}'
    w.trivy.by_ref["%s@%s" % (IMG, sd)] = findings()
    expect(w.go("1.3.0"), 0, label="single-manifest image resolves to the hash of its bytes")
    assert w.pin() == "%s:%s@%s\n" % (IMG, NEWTAG, sd), "pin is the manifest's own digest"


def test_check_refuses_a_tag_that_is_already_pinned(check_world, cmds):
    # The same image on both sides: fixable-count-floor would refuse it, so this uses the set rule.
    w = check_world(gate="no-new-findings")
    w.skopeo[("raw", "docker://%s:%s" % (IMG, NEWTAG))] = json.dumps({"manifests": [
        {"digest": D0, "platform": {"os": "linux", "architecture": "arm64"}}]}).encode()
    w.skopeo[("config", "docker://%s@%s" % (IMG, D0))] = b'{"architecture": "arm64", "os": "linux"}'
    expect(w.go("1.3.0"), 4, "already pinned", label="a tag resolving to the current digest is refused")
    before = w.snap()
    cmds.log.clear()
    expect(w.go("1.3.0", "--no-write"), 0, "already pinned",
           label="near miss: --no-write reports it and continues")
    assert any("--skip-db-update" in a for a in cmds.log), "scans ran under --no-write"
    assert w.snap() == before, "--no-write wrote nothing"


def test_check_floor_refuses_a_fixable_finding_against_a_clean_pin(check_world):
    w = check_world()
    w.newfind("CVE-9:libnew:2.0")
    w.curfind()
    expect(w.go("1.3.0"), 4, "not fewer than the current pin's 0",
           label="fixable finding with a clean current pin is refused")
    assert w.record() is None and w.pin() == OLDPIN + "\n", "refusal writes nothing"


def test_check_floor_fewer_fixable_than_the_current_pin_is_an_exception(check_world):
    w = check_world()
    w.newfind("CVE-1:libfoo:1.1", "CVE-2:libbar:")
    r = w.go("1.3.0")
    expect(r, 3, "needs the operator's explicit approval",
           label="fewer fixable than the current pin is an exception")
    assert "1 fixable HIGH/CRITICAL findings (2 in all); the current pin carries 2 (3 in all)" in r.out, \
        "approval line carries both counts"
    assert "verdict: exception" in w.record().read_text().splitlines(), "exception recorded"
    assert w.pin() == NEWPIN + "\n", "exception writes the pin"


# The current pin carries two fixable findings (CVE-1, CVE-3) and one unfixed (CVE-2).
FLOOR = [
    # The shell suite's case of this name gave the new image THREE fixable findings against two,
    # so the boundary itself was never tested; it is kept below as "more fixable".
    pytest.param("equal fixable count is refused", ("CVE-1:libfoo:1.1", "CVE-3:libbaz:2.0"), 4, "not fewer",
                 id="equal-count-refused"),
    pytest.param("more fixable than the current pin is refused",
                 ("CVE-1:libfoo:1.1", "CVE-3:libbaz:2.0", "CVE-4:libqux:3"), 4, "not fewer",
                 id="more-fixable-refused"),
    pytest.param("near miss: unfixed findings are not counted, so pass", ("CVE-2:libbar:", "CVE-7:libunfixed:"),
                 0, "gate fixable-count-floor: pass", id="unfixed-not-counted"),
]


@pytest.mark.parametrize("label,new,status,text", FLOOR)
def test_check_floor(check_world, label, new, status, text):
    w = check_world()
    w.newfind(*new)
    expect(w.go("1.3.0"), status, text, label=label)


# The current pin's findings: CVE-1 (libfoo), CVE-2 (libbar), CVE-3 (libbaz).
NO_NEW = [
    pytest.param("no-new-findings with one new finding is refused", ("CVE-1:libfoo:1.1", "CVE-8:libnew:"),
                 4, "CVE-8 (libnew)", id="one-new-refused"),
    pytest.param("near miss: an equal finding set passes", ("CVE-3:libbaz:2.0", "CVE-1:libfoo:1.1", "CVE-2:libbar:"),
                 0, "gate no-new-findings: pass", id="equal-set-passes"),
    pytest.param("a subset of the current findings passes", ("CVE-1:libfoo:",), 0, None, id="subset-passes"),
]


@pytest.mark.parametrize("label,new,status,text", NO_NEW)
def test_check_no_new_findings(check_world, label, new, status, text):
    w = check_world(gate="no-new-findings")
    w.newfind(*new)
    expect(w.go("1.3.0"), status, text, label=label)


def test_check_a_name_only_in_the_new_listing_migrates(check_world):
    w = check_world()
    w.listing("v1.3.0", "a.go", "b.go", "v9_add.go")
    expect(w.go("1.3.0"), 0, "migrates: yes", label="a name only in the new listing")
    assert "migrates: yes" in w.record().read_text().splitlines(), "record says migrates: yes"


MIGRATIONS = [
    pytest.param("near miss: identical listings", None, 0, "migrates: no", id="identical"),
    pytest.param("near miss: a file only in the OLD listing", lambda w: w.listing("v1.3.0", "a.go"),
                 0, "migrates: no", id="only-in-old"),
    pytest.param("near miss: a new directory is not a new file",
                 lambda w: w.listing("v1.3.0", "a.go", "b.go", "sub/"), 0, "migrates: no", id="new-directory"),
    pytest.param("no listing at the new tag (a 404) is an environment error",
                 lambda w: (w.web.root / (w.LISTING + "v1.3.0")).unlink(), 2, "environment: listing",
                 id="no-listing-new-tag"),
    pytest.param("no listing at the old tag is an environment error",
                 lambda w: (w.web.root / (w.LISTING + "v1.2.3")).unlink(), 2, "environment: listing",
                 id="no-listing-old-tag"),
    pytest.param("a non-list response is an environment error",
                 lambda w: w.web.put(w.LISTING + "v1.3.0", '{"message": "Not Found"}\n'), 2,
                 "not a list of files", id="non-list-response"),
]


@pytest.mark.parametrize("label,arrange,status,text", MIGRATIONS)
def test_check_migrations(check_world, label, arrange, status, text):
    w = check_world()
    if arrange:
        arrange(w)
    expect(w.go("1.3.0"), status, text, label=label)
    if status == 2:
        assert w.pin() == OLDPIN + "\n" and w.record() is None, "nothing written then"


def test_check_migrations_kind_always(check_world):
    w = check_world(migrations='{"kind": "always"}')
    expect(w.go("1.3.0"), 0, "migrates: yes", label="migrations kind always")


def test_check_no_write_on_an_exception(check_world, cmds):
    w = check_world()
    w.newfind("CVE-1:libfoo:1.1")
    (w.d / "scans").mkdir()
    (w.d / "scans" / "widget-1.0.0-2026-01-01.txt").write_text("old\n")
    before = w.snap()
    expect(w.go("1.3.0", "--no-write"), 3, "not written (--no-write)",
           label="--no-write on an exception still reports it")
    assert w.snap() == before, "--no-write leaves pin file and scan dir identical"
    assert any("--skip-db-update" in a for a in cmds.log), "--no-write still scanned"


def test_check_trivy_failing_is_an_environment_error(check_world):
    w = check_world()
    w.trivy.version = None
    expect(w.go("1.3.0"), 2, "environment", label="trivy failing is an environment error")


def test_check_unreadable_json_from_skopeo_is_an_environment_error(check_world):
    w = check_world()
    w.skopeo[("raw", "docker://%s:%s" % (IMG, NEWTAG))] = b"not json\n"
    expect(w.go("1.3.0"), 2, "unreadable JSON", label="unreadable JSON from skopeo is an environment error")


def test_check_a_missing_skopeo_is_an_environment_error(check_world, cmds, work, monkeypatch):
    w = check_world()
    del cmds.fakes["skopeo"]                      # so the real subprocess.run looks it up...
    (work / "emptybin").mkdir()
    monkeypatch.setenv("PATH", str(work / "emptybin"))   # ...on a PATH that has no skopeo
    expect(w.go("1.3.0"), 2, "cannot run skopeo", label="a missing skopeo is an environment error")


def test_check_refuses_an_invalid_descriptor_before_any_command(check_world, cmds):
    w = check_world()
    (w.d / "image_bump.py").write_text(descriptor_text(platform='"arm64"'))
    expect(w.go("1.3.0"), 4, "not of the form os/arch",
           label="an invalid descriptor is refused before any command runs")
    assert cmds.log == [], "no stub was called"


def test_check_a_manual_descriptor_reads_no_deploy_only_field(check_world):
    w = check_world()
    (w.d / "image_bump.py").write_text(descriptor_text(**manual('["load the tar as root"]')))
    expect(w.go("1.3.0"), 0, "gate fixable-count-floor: pass",
           label="check passes on a manual descriptor without the deploy-only fields")
    assert w.pin() == NEWPIN + "\n", "manual: pin file rewritten"
    assert w.record() is not None, "manual: record written"


# ================================================================= `deploy`

VMU = "/vm/units/widget.container"
KEPT = VMU + ".pre-1.3.0"


def vm(*args):
    return ["podman", "machine", "ssh", *args]


KEEP = vm("cp", VMU, KEPT)
RESTORE = vm("cp", KEPT, VMU)
RELOAD = vm("systemctl", "--user", "daemon-reload")
RESTART = vm("systemctl", "--user", "restart", "widget.service")
STOP = vm("systemctl", "--user", "stop", "widget.service")


class DeployWorld:
    """A service whose applied pin is 1.3.0 (DA) while the container runs D0, with a scan record
    for DA that replaces D0, an older record for another digest (DX) that must not be picked, and
    a health check. The podman fake answers `inspect` with the running image and `image exists`
    with `exists`; a `machine ssh cp <kept unit> <unit>` (a restore) brings the service back up,
    as the real one would, unless `stays_down`. Knobs: migrates (the record's yes/no), install
    (vm-copy or script), health (up or down), running (digest), exists (0 or 1), rolled (a digest
    already listed as rolled back), record (False: none for DA), flaky (a check that passes on its
    second try), stays_down, restore_fails."""

    def __init__(self, work, cmds, tool, monkeypatch, migrates="no", install="vm-copy", health="up",
                 running=D0, exists=0, rolled=None, record=True, flaky=False, stays_down=False,
                 restore_fails=False):
        self._tool = tool
        self.clock = Clock()
        monkeypatch.setattr(ib, "time", self.clock)
        self.root = work / "root"
        self.d = self.root / "svc"
        (self.d / "scans").mkdir(parents=True)
        (self.d / "IMAGE").write_text(NEWPIN + "\n")
        (self.d / "widget.container").write_text("[Container]\n")
        self.health, self.running, self.exists = health, running, exists
        self.stays_down, self.restore_fails = stays_down, restore_fails
        self.install_rc, self.flaky_count = 0, 0
        self.check = str(self.d / ("check-flaky" if flaky else "check-health"))
        self.install_script = str(self.d / "install.sh")
        inst = ('{"kind": "script", "path": "install.sh"}' if install == "script"
                else '{"kind": "vm-copy", "applied_unit": "widget.container"}')
        checks = json.dumps([{"name": "flaky" if flaky else "health", "command": [self.check],
                              "pass": "exit 0"}])
        (self.d / "image_bump.py").write_text(descriptor_text(
            migrations='{"kind": "always"}', vm_unit=json.dumps(VMU), install=inst, checks=checks))
        if record:
            rec = ("widget image CVE scan record\nimage: %s:%s\ndigest: %s\nplatform: linux/arm64\n"
                   "replaces: %s\nverdict: pass\nmigrates: %s\n\nNew image findings: none\n")
            (self.d / "scans" / "widget-1.3.0-2026-10-27.txt").write_text(rec % (IMG, NEWTAG, DA, D0, migrates))
            (self.d / "scans" / "widget-1.2.9-2026-10-01.txt").write_text(rec % (IMG, NEWTAG, DX, D0, "yes"))
        self.rolled_back = work / "state" / "image-bump" / "svc.rolled-back"
        if rolled:
            self.rolled_back.parent.mkdir(parents=True)
            self.rolled_back.write_text(rolled + "\n")
        cmds.fakes.update({"podman": self._podman, str(self.d / "check-health"): self._health,
                           str(self.d / "check-flaky"): self._flaky, self.install_script: self._install})

    def _podman(self, argv):
        a = argv[1:]
        if a[0] == "inspect":
            return 0, ("%s@%s\n" % (IMG, self.running)).encode(), b""
        if a[:2] == ["image", "exists"]:
            return self.exists, b"", b""
        if a[0] == "machine" and a[2:3] == ["cp"] and ".pre-" in a[3]:
            if self.restore_fails:
                return 1, b"", b"stub podman: cp failed"
            if not self.stays_down:
                self.health = "up"
        return 0, b"", b""

    def _health(self, argv):
        return (0 if self.health == "up" else 1), b"", b""

    def _flaky(self, argv):
        n, self.flaky_count = self.flaky_count, self.flaky_count + 1
        return (0 if n >= 1 else 1), b"", b""

    def _install(self, argv):
        return self.install_rc, b"", b""

    def go(self, *args):
        return self._tool("deploy", "svc", "--root", self.root, *args)

    def listed(self):
        return self.rolled_back.read_text().split() if self.rolled_back.exists() else []


@pytest.fixture
def deploy_world(work, cmds, tool, monkeypatch):
    return lambda **knobs: DeployWorld(work, cmds, tool, monkeypatch, **knobs)


def touched(cmds):
    """Whether the run changed anything: any command inside the VM, or any volume command."""
    return [ln for ln in cmds.lines() if "machine ssh" in ln or "volume" in ln]


def test_deploy_a_clean_deploy(deploy_world, cmds, work):
    w = deploy_world()
    r = w.go("--wait", "0")
    expect(r, 0, "deployed", label="a clean deploy exits 0")
    log = cmds.log
    install = vm("cp", str(w.d / "widget.container"), VMU)
    assert ["podman", "inspect", "widget", "--format", "{{.ImageName}}"] in log, \
        "the running image is read from the container"
    assert ["podman", "image", "exists", "%s@%s" % (IMG, D0)] in log, \
        "the replaced image is looked up in the VM's storage"
    assert KEEP in log, "the unit is kept as .pre-<version>"
    assert install in log, "the applied unit, resolved to its path, is copied in"
    assert RELOAD in log, "systemd is reloaded"
    assert RESTART in log, "the service is restarted"
    assert log.index(KEEP) < log.index(install), "keep before install"
    assert log.index(install) < log.index(RELOAD), "install before reload"
    assert log.index(RELOAD) < log.index(RESTART), "reload before restart"
    assert log.index(RESTART) < log.index([w.check]), "restart before the checks"
    assert not [ln for ln in cmds.lines() if "systemctl --user stop" in ln or "volume export" in ln], \
        "no stop and no export when the version does not migrate"
    assert RESTORE not in log, "no restore"
    assert not w.rolled_back.exists(), "nothing listed as rolled back"
    assert "kept as " + KEPT in r.out, "the report names the kept unit"
    assert "tell the other users" in r.out, "reminder: tell other users"


DEPLOY_REFUSALS = [
    pytest.param("refused: applied pin is already running", {"running": DA},
                 "pin not applied or already running", id="already-running"),
    pytest.param("refused: the running image is not the one the record replaces", {"running": DX},
                 "but the scan record says this version replaces", id="running-not-replaced"),
    pytest.param("refused: the replaced image is gone from the VM", {"exists": 1},
                 "not in the VM's storage", id="replaced-image-gone"),
    pytest.param("refused: the digest was rolled back before", {"rolled": DA},
                 "was rolled back before", id="rolled-back-before"),
]


@pytest.mark.parametrize("label,knobs,text", DEPLOY_REFUSALS)
def test_deploy_refuses(deploy_world, cmds, label, knobs, text):
    w = deploy_world(**knobs)
    expect(w.go("--wait", "0"), 4, text, label=label)
    assert touched(cmds) == [], "nothing changed on that refusal"


def test_deploy_refuses_without_a_scan_record(deploy_world, cmds):
    w = deploy_world(record=False)
    expect(w.go("--wait", "0"), 4, "no scan record", label="refused: no scan record for the applied digest")
    assert cmds.log == [], "no podman call at all"


def test_deploy_another_rolled_back_digest_does_not_stop_it(deploy_world):
    w = deploy_world(rolled=DX)
    expect(w.go("--wait", "0"), 0, "deployed",
           label="near miss: another digest in the rolled-back list does not stop it")


def test_deploy_rolls_back_a_service_that_never_comes_back(deploy_world, cmds):
    w = deploy_world(health="down")
    r = w.go("--wait", "1")
    expect(r, 5, "must be reverted by a commit", label="no migration, checks fail: rolled back, exit 5")
    log = cmds.log
    # On the virtual clock, --wait 1 is exactly two tries (at 0 s and 1 s); the restored service
    # passes on its first. The shell suite could only ask for "at least 3".
    assert log.count([w.check]) == 3, "the check was retried within the wait, then re-run after the restore"
    assert RESTORE in log, "the kept unit is restored"
    assert log.index([w.check]) < log.index(RESTORE), "restore after the failed check"
    assert log.count(RELOAD) == 2 and log.count(RESTART) == 2, \
        "reload and restart ran for the install and for the restore"
    last_check = len(log) - 1 - log[::-1].index([w.check])
    assert last_check > len(log) - 1 - log[::-1].index(RESTORE), "the checks re-run after the restore"
    assert "the checks pass again" in r.out, "the restored service's result is reported"
    assert w.listed() == [DA], "the applied digest is listed as rolled back"
    expect(w.go("--wait", "0"), 4, "was rolled back before", label="a second deploy of that digest refuses")


def test_deploy_a_rollback_that_does_not_recover_stops_for_a_person(deploy_world):
    w = deploy_world(health="down", stays_down=True)
    expect(w.go("--wait", "0"), 6, "NOT RECOVERED", label="rolled back but still failing: exit 6, not 5")
    assert DA in w.listed(), "the digest is still listed, so nothing retries it"


def test_deploy_a_restore_that_fails_stops_for_a_person(deploy_world):
    w = deploy_world(health="down", restore_fails=True)
    expect(w.go("--wait", "0"), 6, "ROLLBACK FAILED", label="the restore command itself fails: exit 6")


def test_deploy_a_migrating_version_that_fails_restores_nothing(deploy_world, cmds, work):
    w = deploy_world(migrates="yes", health="down")
    expect(w.go("--wait", "0"), 6, "%s/widget-data-pre-1.3.0.tar" % (work / "home"),
           label="migrating, checks fail: exit 6")
    assert RESTORE not in cmds.log, "nothing restored"
    assert cmds.log.count(RESTART) == 1, "no second restart"
    assert not w.rolled_back.exists(), "not listed as rolled back"


def test_deploy_a_migrating_version_exports_the_volume_first(deploy_world, cmds, work):
    w = deploy_world(migrates="yes")
    export = "%s/widget-data-pre-1.3.0.tar" % (work / "home")
    expect(w.go("--wait", "0"), 0, "delete %s once the nightly backup" % export, label="migrating, clean: exit 0")
    log = cmds.log
    exp = ["podman", "volume", "export", "widget-data", "-o", export]
    install = vm("cp", str(w.d / "widget.container"), VMU)
    assert STOP in log, "the service is stopped"
    assert exp in log, "the volume is exported to the version-named file"
    assert log.index(STOP) < log.index(exp), "stop before export"
    assert log.index(exp) < log.index(KEEP), "export before keep"
    assert log.index(exp) < log.index(install), "export before install"


def test_deploy_an_install_script_that_succeeds(deploy_world, cmds):
    w = deploy_world(install="script")
    expect(w.go("--wait", "0"), 0, "deployed", label="near miss: a script install that succeeds")
    log = cmds.log
    assert [w.install_script] in log, "the script ran"
    assert log.index(KEEP) < log.index([w.install_script]), "keep before the script"
    assert log.index([w.install_script]) < log.index([w.check]), "the script before the checks"
    assert not [ln for ln in cmds.lines() if "cp %s" % w.root in ln or "restart widget.service" in ln], \
        "a script install is not copied or restarted by the tool"


def test_deploy_a_failing_install_script_is_rolled_back(deploy_world, cmds):
    w = deploy_world(install="script")
    w.install_rc = 1
    expect(w.go("--wait", "0"), 5, "the install script exited 1",
           label="a failing install script counts as a failed check: rolled back")
    assert RESTORE in cmds.log, "the unit is restored"
    assert DA in w.listed(), "digest listed"


def test_deploy_a_failing_install_script_on_a_migrating_version(deploy_world, cmds):
    w = deploy_world(install="script", migrates="yes")
    w.install_rc = 1
    expect(w.go("--wait", "0"), 6, "the install script exited 1",
           label="a failing install script on a migrating version: exit 6")
    assert RESTORE not in cmds.log, "nothing restored"


def test_deploy_retries_a_check_within_the_wait(deploy_world, cmds):
    w = deploy_world(flaky=True)
    expect(w.go("--wait", "3"), 0, "deployed", label="near miss: a check that passes on its second try")
    assert cmds.log.count([w.check]) == 2, "tried twice"


def test_deploy_refuses_a_manual_install_before_touching_anything(deploy_world, cmds):
    w = deploy_world()
    (w.d / "image_bump.py").write_text(descriptor_text(migrations='{"kind": "always"}', **manual()))
    r = w.go("--wait", "0")
    expect(r, 4, "deploy: svc is installed by hand on its host; steps:",
           label="deploy on a manual descriptor is refused")
    assert "  load the tar as root" in r.lines, "step one printed, indented"
    assert "  check the unit is up" in r.lines, "step two printed, indented"
    assert cmds.log == [], "no podman call"
    assert not w.rolled_back.exists(), "no state written"


def test_deploy_a_missing_podman_is_an_environment_error(deploy_world, cmds, work, monkeypatch):
    w = deploy_world()
    del cmds.fakes["podman"]
    (work / "emptybin").mkdir()
    monkeypatch.setenv("PATH", str(work / "emptybin"))
    expect(w.go("--wait", "0"), 2, "cannot run podman", label="a missing podman is an environment error")


# ================================================================= artifact descriptors

ARCH = {"arm": "arm64", "x86": "amd64"}
IDENTITY = "https://example.invalid/acme/widget/release.yml@refs/tags/v3.1.0"
ISSUER = "https://issuer.invalid"
WARM = sha(b"widget 3.1.0 arm64")    # the 3.1.0 widget binaries' hashes
WX86 = sha(b"widget 3.1.0 amd64")


class Key:
    def __init__(self, home, public, fpr):
        self.home, self.public, self.fpr = home, public, fpr


@pytest.fixture(scope="session")
def keys():
    """Two signing keys, made once: "good", the one a descriptor pins, and "evil"."""
    for prog in ("gpg", "gpgv", "gpgconf"):
        if shutil.which(prog) is None:
            # Linux machines all have gnupg; on macOS it is an optional install.
            if sys.platform == "darwin":
                pytest.skip("%s is not installed (brew install gnupg to run these tests)" % prog)
            pytest.fail("%s is required" % prog)
    base = Path(tempfile.mkdtemp(prefix="image-bump-keys-", dir=ORIGINAL_TMP))
    made, homes = {}, []
    try:
        for name in ("good", "evil"):
            home = base / name
            home.mkdir(mode=0o700)
            homes.append(home)
            gpg = ["gpg", "--homedir", str(home), "--batch"]
            made_key = subprocess.run(gpg + ["--pinentry-mode", "loopback", "--passphrase", "", "--quick-generate-key",
                                             "%s <%s@example.invalid>" % (name, name), "ed25519", "sign", "never"],
                                      capture_output=True, text=True)
            assert made_key.returncode == 0, "gpg could not make a key in %s:\n%s" % (home, made_key.stderr)
            public = subprocess.run(gpg + ["--export", "--armor"], check=True, capture_output=True).stdout
            listing = subprocess.run(gpg + ["--with-colons", "--list-keys"], check=True,
                                     capture_output=True, text=True).stdout
            fpr = next(ln.split(":")[9] for ln in listing.splitlines() if ln.startswith("fpr:"))
            made[name] = Key(home, public, fpr)
        yield made
    finally:
        # Generating a key starts a gpg-agent for that home; it would outlive the test run.
        for home in homes:
            subprocess.run(["gpgconf", "--homedir", str(home), "--kill", "gpg-agent"], capture_output=True)
        shutil.rmtree(base, ignore_errors=True)


def deb(version, arch):
    """A .deb (an ar archive) whose data.tar.gz holds ./usr/bin/vector; returns (bytes, the
    binary's bytes)."""
    inner = ("vector %s %s" % (version, arch)).encode()
    tarbuf = io.BytesIO()
    # mtime=0: the gzip header otherwise carries the clock, and two builds could differ.
    with gzip.GzipFile(fileobj=tarbuf, mode="wb", mtime=0) as gz, tarfile.open(fileobj=gz, mode="w") as tf:
        ti = tarfile.TarInfo("./usr/bin/vector")
        ti.size, ti.mode = len(inner), 0o755
        tf.addfile(ti, io.BytesIO(inner))

    def member(name, body):
        return (name.ljust(16).encode() + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6)
                + b"100644".ljust(8) + str(len(body)).ljust(10).encode() + b"`\n" + body
                + (b"\n" if len(body) % 2 else b""))
    return (b"!<arch>\n" + member("debian-binary", b"2.0\n") + member("control.tar.gz", b"x")
            + member("data.tar.gz", tarbuf.getvalue())), inner


COMMON = '''arches = {"arm": "arm64", "x86": "amd64"}
pins_files = {"arm": "image/pins-arm.txt", "x86": "image/pins-x86.txt"}
release_line = "github-latest-stable"
git_tag = "v{version}"
scan_dir = "image/scans"
gate = {"kind": "fixable-count-floor"}
checklist = ["read the release notes"]
'''
WIDGET = COMMON + '''release_api = {"host": "github", "repo": "acme/widget"}
artifact = {"kind": "release-file", "path": "/usr/local/bin/widget", "asset": "widget-v{version}.linux.{arch}",
            "sbom": "widget-v{version}.linux.{arch}.spdx.sbom.json"}
verify = {"kind": "cosign-bundle", "checksums": "widget-v{version}.checksums.txt",
          "bundle": "widget-v{version}.checksums.sigstore.json",
          "certificate_identity": "https://example.invalid/acme/widget/release.yml@refs/tags/v{version}",
          "certificate_oidc_issuer": "https://issuer.invalid"}
'''
VECTOR = COMMON + '''release_api = {"host": "github", "repo": "acme/vector"}
artifact = {"kind": "release-deb", "package": "vector", "asset": "vector_{version}-1_{arch}.deb"}
verify = {"kind": "apt-release", "repo": "%s/apt", "suite": "stable", "component": "vector-0",
          "fingerprint": "%s", "key_file": "key.public"}
'''


class Estate:
    """An image build's repository (`repo`) whose two pins files, one per architecture, pin a
    release-file artifact `widget` at 3.0.0 and a release-deb `vector` at 1.0.0, plus a release
    host serving widget 3.0.0 and 3.1.0 (checksums file, sigstore bundle, assets, SBOMs) and a
    signed apt repository serving vector 1.0.0 and 1.1.0. The current directory is the repository,
    as when a person runs the tool from it.

    The cosign fake "verifies" a bundle that holds the sha256 of the checksums file, and demands the
    identity of 3.1.0 and the issuer. Real verification needs sigstore's trust root, which is online.
    Knobs: pinned (False: the pins say PLACEHOLDER), signer (who signs the Release), keyfile (whose
    key the descriptor's key file holds), onlygz (the Release lists only Packages.gz), sigform
    ("inrelease": a clearsigned InRelease instead of Release and Release.gpg)."""

    def __init__(self, work, web, cmds, tool, keys, monkeypatch, pinned=True, signer="good",
                 keyfile="good", onlygz=False, sigform=None):
        self.web, self._tool, self.keys = web, tool, keys
        self.repo = work / "repo"
        self.trivy = Trivy()
        self.trivy.version = {"Version": "0.99.0", "VulnerabilityDB": {"UpdatedAt": "2026-10-27T06:00:00Z"}}
        cmds.fakes["cosign"] = self._cosign
        cmds.fakes["trivy"] = self.trivy
        monkeypatch.setenv("IMAGE_BUMP_GITHUB_DOWNLOAD", web.url)
        monkeypatch.setenv("IMAGE_BUMP_GITHUB_API", web.url)
        self.dl = web.url + "/acme/widget/releases/download"
        self._release_host()
        self._apt(work, signer, onlygz, sigform)
        self._repository(pinned, keyfile)
        monkeypatch.chdir(self.repo)

    def report(self, key, npkgs, *vulns):
        """The trivy answer for the one file whose sha256 is `key`: `npkgs` packages, `vulns`."""
        self.trivy.by_sha[key] = findings(*vulns, packages=npkgs)

    def _release_host(self):
        for ver in ("3.0.0", "3.1.0"):
            lines = []
            for a in ARCH.values():
                data = ("widget %s %s" % (ver, a)).encode()
                name = "widget-v%s.linux.%s" % (ver, a)
                self.web.put("acme/widget/releases/download/v%s/%s" % (ver, name), data)
                self.web.put("acme/widget/releases/download/v%s/%s.spdx.sbom.json" % (ver, name),
                             '{"sbom": "%s %s"}' % (ver, a))
                lines.append("%s  %s\n" % (sha(data), name))
                self.report(sha(data), 7)
            lines.append("%s  widget-v%s.darwin.arm64\n" % ("ab" * 32, ver))
            text = "".join(lines)
            self.web.put("acme/widget/releases/download/v%s/widget-v%s.checksums.txt" % (ver, ver), text)
            self.web.put("acme/widget/releases/download/v%s/widget-v%s.checksums.sigstore.json" % (ver, ver),
                         sha(text.encode()))
        self.web.put("repos/acme/widget/releases/latest", json.dumps({"tag_name": "v3.1.0"}))

    def _apt(self, work, signer, onlygz, sigform):
        def gpg(*args):
            return subprocess.run(["gpg", "--homedir", str(self.keys[signer].home), "--batch", "--yes",
                                   "--pinentry-mode", "loopback", "--passphrase", ""] + list(args),
                                  check=True, capture_output=True).stdout
        packages = {}
        for ver in ("1.0.0", "1.1.0"):
            for a in ARCH.values():
                blob, inner = deb(ver, a)
                fn = "pool/v/ve/vector_%s-1_%s.deb" % (ver, a)
                self.web.put("apt/" + fn, blob)
                self.report(sha(inner), 5)
                packages.setdefault(a, []).append(
                    "Package: vector\nVersion: %s-1\nArchitecture: %s\nFilename: %s\nSize: %d\nSHA256: %s\n"
                    "Description: a log shipper\n" % (ver, a, fn, len(blob), sha(blob)))
        rel = ["Codename: stable\nDate: Thu, 29 Oct 2026 15:22:04 UTC\nSHA256:\n"]
        for a, stanzas in packages.items():
            # Another package of the same name at another architecture must not be picked.
            text = ("\n".join(stanzas) + "\nPackage: curl\nVersion: 9\nArchitecture: %s\n"
                    "Filename: pool/c/curl_9_%s.deb\nSHA256: %s\n" % (a, a, "cd" * 32)).encode()
            self.web.put("apt/dists/stable/vector-0/binary-%s/Packages" % a, text)
            packed = gzip.compress(text, mtime=0)
            self.web.put("apt/dists/stable/vector-0/binary-%s/Packages.gz" % a, packed)
            if not onlygz:
                rel.append(" %s %16d vector-0/binary-%s/Packages\n" % (sha(text), len(text), a))
            rel.append(" %s %16d vector-0/binary-%s/Packages.gz\n" % (sha(packed), len(packed), a))
        release = work / "Release"
        release.write_text("".join(rel))
        if sigform == "inrelease":
            self.web.put("apt/dists/stable/InRelease", gpg("--clearsign", "-o", "-", str(release)))
        else:
            self.web.put("apt/dists/stable/Release", release.read_bytes())
            self.web.put("apt/dists/stable/Release.gpg", gpg("--detach-sign", "-o", "-", str(release)))

    def _repository(self, pinned, keyfile):
        base = self.web.url
        for k, a in ARCH.items():
            if not pinned:
                file_line = "file /usr/local/bin/widget PLACEHOLDER sha256:PLACEHOLDER"
                deb_line = "deb vector PLACEHOLDER sha256:PLACEHOLDER"
            else:
                file_line = "file /usr/local/bin/widget %s/v3.0.0/widget-v3.0.0.linux.%s sha256:%s" % (
                    self.dl, a, sha(("widget 3.0.0 %s" % a).encode()))
                deb_line = "deb vector %s/apt/pool/v/ve/vector_1.0.0-1_%s.deb sha256:%s  # the shipper" % (
                    base, a, sha(deb("1.0.0", a)[0]))
            self.pins(k).parent.mkdir(parents=True, exist_ok=True)
            self.pins(k).write_text(
                "# pinned inputs, %s\npackage curl\n\n%s\nfile /usr/local/bin/other http://127.0.0.1/o sha256:%s\n"
                "%s\nimage registry.invalid/x sha256:%s\n" % (k, file_line, "ee" * 32, deb_line, "ff" * 32))
        self.scans.mkdir()
        for name, text in (("widget", WIDGET), ("vector", VECTOR % (base, self.keys["good"].fpr))):
            (self.repo / "image" / "bump" / name).mkdir(parents=True)
            self.descriptor(name).write_text(text)
        (self.repo / "image" / "bump" / "vector" / "key.public").write_bytes(self.keys[keyfile].public)

    def _cosign(self, argv):
        if argv[1] != "verify-blob":
            return 2, b"", b"stub cosign: not verify-blob"
        a = argv[2:]
        opt, blob = dict(zip(a[:-1:2], a[1:-1:2])), a[-1]
        for flag, want in (("--certificate-identity", IDENTITY), ("--certificate-oidc-issuer", ISSUER)):
            if opt.get(flag) != want:
                return 1, b"", ("stub cosign: %s is %r, wanted %r" % (flag, opt.get(flag), want)).encode()
        if Path(opt["--bundle"]).read_text().strip() != sha(Path(blob).read_bytes()):
            return 1, b"", b"stub cosign: invalid signature when validating ASN.1 encoded signature"
        return 0, b"", b"Verified OK\n"

    @property
    def scans(self):
        return self.repo / "image" / "scans"

    def pins(self, k):
        return self.repo / "image" / ("pins-%s.txt" % k)

    def pins_text(self):
        return [self.pins(k).read_text() for k in ARCH]

    def descriptor(self, name):
        return self.repo / "image" / "bump" / name / "image_bump.py"

    def srv(self, rel):
        return self.web.root / rel

    def record(self, name, version):
        found = sorted(self.scans.glob("%s-%s-*.txt" % (name, version)))
        return found[0].read_text() if found else None

    def go(self, *args):
        return self._tool(*args, "--root", "image/bump")


@pytest.fixture
def estate(work, web, cmds, tool, keys, monkeypatch):
    return lambda **knobs: Estate(work, web, cmds, tool, keys, monkeypatch, **knobs)


def test_estate_widget_passes(estate, cmds):
    e = estate()
    before = {k: e.pins(k).read_text().splitlines() for k in ARCH}
    expect(e.go("check", "widget", "3.1.0"), 0, "gate fixable-count-floor: pass", label="widget 3.1.0 passes")
    log = "\n".join(cmds.lines())
    assert "verify-blob --bundle" in log, \
        "cosign was given the bundle, the identity of this version and the issuer"
    assert "--certificate-identity %s --certificate-oidc-issuer %s" % (IDENTITY, ISSUER) in log, \
        "with the version in the identity"
    assert "file /usr/local/bin/widget %s/v3.1.0/widget-v3.1.0.linux.arm64 sha256:%s" % (e.dl, WARM) \
        in e.pins("arm").read_text(), "arm pin is the verified hash at the release URL"
    assert "file /usr/local/bin/widget %s/v3.1.0/widget-v3.1.0.linux.amd64 sha256:%s" % (e.dl, WX86) \
        in e.pins("x86").read_text(), "x86 pin is the verified hash at the release URL"
    for k in ARCH:
        after = e.pins(k).read_text().splitlines()
        assert len(after) == len(before[k]) and sum(x != y for x, y in zip(after, before[k])) == 1, \
            "%s: exactly one line replaced" % k
        assert "# the shipper" in e.pins(k).read_text(), "%s: the other pin and its comment are intact" % k
    rec = e.record("widget", "3.1.0")
    assert rec is not None, "scan record written"
    assert "verify: cosign-bundle: widget-v3.1.0.checksums.txt signed by %s via %s" % (IDENTITY, ISSUER) in rec, \
        "record names what signed what"
    assert "arm: %s/v3.1.0/widget-v3.1.0.linux.arm64 sha256:%s" % (e.dl, WARM) in rec, \
        "record has the arm URL and hash"
    sbom = e.srv("acme/widget/releases/download/v3.1.0/widget-v3.1.0.linux.arm64.spdx.sbom.json").read_bytes()
    assert "sbom-arm: widget-v3.1.0.linux.arm64.spdx.sbom.json sha256:%s" % sha(sbom) in rec, \
        "record has the SBOM hash"
    assert "replaces: 3.0.0" in rec, "record replaces 3.0.0"
    assert "coverage: yes" in rec, "record says coverage"
    assert "verdict: pass" in rec, "record verdict"


def test_estate_widget_already_pinned(estate):
    e = estate()
    assert e.go("check", "widget", "3.1.0").status == 0
    expect(e.go("check", "widget", "3.1.0"), 4, "already pinned", label="an already pinned version is refused")
    expect(e.go("check", "widget", "3.1.0", "--no-write"), 0, "continuing because of --no-write",
           label="near miss: --no-write continues on an already pinned version")


def test_estate_a_tampered_checksums_file_is_refused(estate):
    e = estate()
    before = e.pins_text()
    f = e.srv("acme/widget/releases/download/v3.1.0/widget-v3.1.0.checksums.txt")
    text = f.read_text()
    # One hash changed after signing: its first digit becomes another digit.
    f.write_text(("1" if text[0] == "0" else "0") + text[1:])
    expect(e.go("check", "widget", "3.1.0"), 4, "cosign verify-blob refused",
           label="a tampered checksums file is refused")
    assert list(e.scans.iterdir()) == [], "no record"
    assert e.pins_text() == before, "both pins files unchanged"
    assert not [p for p in e.web.log if re.search(r"linux\.(arm64|amd64)$", p)], \
        "no asset was fetched before the signature held (server log)"


def test_estate_an_asset_with_the_wrong_bytes_is_refused(estate):
    e = estate()
    before = e.pins_text()
    e.srv("acme/widget/releases/download/v3.1.0/widget-v3.1.0.linux.amd64").write_bytes(b"swapped")
    expect(e.go("check", "widget", "3.1.0"), 4, "widget-v3.1.0.linux.amd64: the downloaded bytes hash to",
           label="an x86 asset with the wrong bytes is refused")
    assert e.pins_text() == before, "one architecture failing leaves both pins files unchanged"
    assert list(e.scans.iterdir()) == [], "no record"


def test_estate_a_transfer_cut_short_is_an_environment_error(estate):
    e = estate()
    e.srv("acme/widget/releases/download/v3.1.0/widget-v3.1.0.linux.amd64.cut").touch()
    expect(e.go("check", "widget", "3.1.0"), 2, "bytes of the",
           label="a transfer that ends early is an environment error")
    assert list(e.scans.iterdir()) == [], "nothing written"


def test_estate_a_signed_checksums_file_that_omits_an_asset_is_refused(estate):
    e = estate()
    d = "acme/widget/releases/download/v3.1.0/"
    text = "".join(ln for ln in e.srv(d + "widget-v3.1.0.checksums.txt").read_text().splitlines(True)
                   if "linux.amd64" not in ln)
    e.web.put(d + "widget-v3.1.0.checksums.txt", text)
    e.web.put(d + "widget-v3.1.0.checksums.sigstore.json", sha(text.encode()))   # validly signed
    expect(e.go("check", "widget", "3.1.0"), 4, "does not list widget-v3.1.0.linux.amd64",
           label="a validly signed file that omits an asset is refused")


def test_estate_gate_a_fixable_finding_against_a_clean_pin_is_refused(estate):
    e = estate()
    e.report(WARM, 7, "CVE-9:libnew:2")
    expect(e.go("check", "widget", "3.1.0"), 4, "not fewer than the current pin's 0",
           label="a fixable finding with a clean current pin is refused")
    assert list(e.scans.iterdir()) == [], "nothing written"


def test_estate_gate_a_fixable_finding_in_one_architecture_is_refused(estate):
    e = estate()
    e.report(WX86, 7, "CVE-9:libnew:2")
    expect(e.go("check", "widget", "3.1.0"), 4, "not fewer",
           label="a fixable finding in the x86 artifact alone is refused")


def test_estate_no_coverage_on_one_architecture_is_an_exception(estate):
    e = estate()
    e.report(WX86, 0)
    r = e.go("check", "widget", "3.1.0")
    expect(r, 3, "NO COVERAGE: trivy detected no package in the x86 artifact",
           label="no trivy coverage on one architecture is exit 3, never 0")
    rec = e.record("widget", "3.1.0")
    assert rec is not None, "the record exists"
    assert "coverage: none" in rec, "the record says coverage none"
    assert "packages: arm 7, x86 0" in rec, "and counts the packages"
    assert "verdict: exception" in rec, "and the verdict is exception"
    assert "so there is no coverage" in r.out, "the approval line says no coverage"


def test_estate_a_placeholder_pin_is_moved(estate):
    e = estate(pinned=False)
    expect(e.go("check", "widget", "3.1.0"), 0, "wrote ", label="a placeholder pin is moved")
    assert "replaces: none" in e.record("widget", "3.1.0"), "record: replaces none"
    assert "widget-v3.1.0.linux.arm64 sha256:" + WARM in e.pins("arm").read_text(), "arm line written"


def test_estate_a_first_pin_with_a_fixable_finding_is_an_exception(estate):
    e = estate(pinned=False)
    e.report(WARM, 7, "CVE-9:libnew:2", "CVE-8:libold:")
    r = e.go("check", "widget", "3.1.0")
    expect(r, 3, "gate fixable-count-floor: exception: 1 fixable findings in a first pin",
           label="a first pin with a fixable finding is exit 3")
    assert "in a first pin, which has no current pin to compare" in r.out, "the approval line says why"
    rec = e.record("widget", "3.1.0")
    assert rec is not None, "the record exists"
    assert "verdict: exception" in rec, "the record's verdict is exception"
    assert "replaces: none" in rec, "the record replaces none"
    assert "CVE-9" in rec, "the record lists the fixable finding"
    assert "CVE-8" in rec, "and the unfixed one"
    assert "widget-v3.1.0.linux.arm64 sha256:" + WARM in e.pins("arm").read_text(), "the arm line is written"


def _two_widget_lines(e):
    e.pins("arm").write_text("file /usr/local/bin/widget http://x sha256:PLACEHOLDER\n" + e.pins("arm").read_text())


def _no_widget_line(e):
    e.pins("x86").write_text("".join(ln for ln in e.pins("x86").read_text().splitlines(True)
                                     if "bin/widget" not in ln))


def _versions_disagree(e):
    text = e.pins("x86").read_text()
    e.pins("x86").write_text(text.replace("v3.0.0/widget-v3.0.0.linux.amd64", "v2.9.0/widget-v2.9.0.linux.amd64"))


def _current_pin_tampered(e):
    e.srv("acme/widget/releases/download/v3.0.0/widget-v3.0.0.linux.arm64").write_bytes(b"tampered")


PINS_FILES = [
    pytest.param("two lines for the pin in one file is refused", _two_widget_lines,
                 "has 2 `file /usr/local/bin/widget` lines", id="two-lines"),
    pytest.param("no line for the pin is refused", _no_widget_line,
                 "has 0 `file /usr/local/bin/widget` lines", id="no-line"),
    pytest.param("pins files naming different versions are refused", _versions_disagree,
                 "disagree on the version", id="versions-disagree"),
    pytest.param("a current pin whose bytes no longer match its hash is refused", _current_pin_tampered,
                 "no longer matches its own hash", id="current-pin-tampered"),
]


@pytest.mark.parametrize("label,arrange,text", PINS_FILES)
def test_estate_pins_files(estate, label, arrange, text):
    e = estate()
    arrange(e)
    expect(e.go("check", "widget", "3.1.0"), 4, text, label=label)


def test_estate_latest(estate):
    e = estate()
    expect(e.go("latest", "widget"), 7, "newer widget 3.0.0 -> 3.1.0 (v3.1.0)",
           label="latest: reads 3.0.0 from the arm URL and sees 3.1.0")
    expect(e.go("latest", "widget", "--pin", "3.1.0"), 0, "up to date widget 3.1.0", label="latest: up to date")


def test_estate_latest_with_a_placeholder_pin(estate):
    e = estate(pinned=False)
    expect(e.go("latest", "widget"), 2, "no version yet", label="latest: a placeholder pin has no version")


def test_estate_deploy_and_validate(estate):
    e = estate()
    expect(e.go("deploy", "widget"), 4, "nothing to deploy", label="deploy refuses an artifact descriptor")
    expect(e.go("validate", "widget"), 0, "ok widget", label="validate accepts the good descriptor")


def _replace(find, replace):
    def edit(text):
        assert find in text, "the edit's text %r is not in the descriptor" % find
        return text.replace(find, replace)
    return edit


def _without_verify(text):
    return "".join(ln for ln in text.splitlines(True)
                   if not ln.startswith(("verify = ", '          "bundle', '          "certificate')))


WIDGET_DESCRIPTORS = [
    pytest.param("validate: a descriptor with no verify is refused", _without_verify, "verify: missing",
                 id="no-verify"),
    pytest.param("validate: an asset without {version} is refused",
                 _replace('"asset": "widget-v{version}.linux', '"asset": "widget-v1.linux'),
                 "artifact.asset: must be a string containing both {version} and {arch}", id="asset-without-version"),
    pytest.param("validate: an asset without {arch} is refused",
                 _replace('"asset": "widget-v{version}.linux.{arch}"', '"asset": "widget-v{version}.linux"'),
                 "artifact.asset: must be a string containing both", id="asset-without-arch"),
    pytest.param("validate: a container field is refused", lambda t: t + 'service = "x.service"\n',
                 "service: not used by an artifact descriptor", id="container-field"),
    pytest.param("validate: pins_files keys must match arches",
                 _replace('"x86": "image/pins-x86.txt"', '"mips": "image/pins-x86.txt"'),
                 "pins_files: must have the same keys as arches", id="pins-files-keys"),
    pytest.param("validate: a deb cannot be verified by cosign-bundle",
                 _replace('"kind": "release-file", "path": "/usr/local/bin/widget"', '"kind": "release-deb", "package": "widget"'),
                 "cannot verify an artifact of kind release-deb", id="deb-by-cosign"),
    pytest.param("validate: a cosign descriptor needs its identity",
                 _replace('"certificate_identity"', '"certificate_idx"'),
                 "needs a non-empty string 'certificate_identity'", id="cosign-needs-identity"),
    pytest.param("validate: a missing pins line is a problem",
                 _replace('"path": "/usr/local/bin/widget"', '"path": "/usr/local/bin/nothere"'),
                 "has 0 `file /usr/local/bin/nothere` lines", id="missing-pins-line"),
]


@pytest.mark.parametrize("label,edit,text", WIDGET_DESCRIPTORS)
def test_estate_validate_refuses(estate, label, edit, text):
    e = estate()
    good = e.descriptor("widget").read_text()
    bad = edit(good)
    assert bad != good, "the edit changed nothing"
    e.descriptor("widget").write_text(bad)
    expect(e.go("validate", "widget"), 4, text, label=label)


def test_estate_vector_passes(estate, keys, cmds):
    e = estate()
    expect(e.go("check", "vector", "1.1.0"), 0, "verified the Release", label="vector 1.1.0 passes")
    armdeb = sha(e.srv("apt/pool/v/ve/vector_1.1.0-1_arm64.deb").read_bytes())
    x86deb = sha(e.srv("apt/pool/v/ve/vector_1.1.0-1_amd64.deb").read_bytes())
    assert "deb vector %s/apt/pool/v/ve/vector_1.1.0-1_arm64.deb sha256:%s  # the shipper" % (e.web.url, armdeb) \
        in e.pins("arm").read_text(), "arm deb pinned at the pool URL with the Packages hash"
    assert "deb vector %s/apt/pool/v/ve/vector_1.1.0-1_amd64.deb sha256:%s" % (e.web.url, x86deb) \
        in e.pins("x86").read_text(), "x86 deb pinned"
    assert "widget-v3.0.0.linux.arm64" in e.pins("arm").read_text(), "the widget pin was left alone"
    rec = e.record("vector", "1.1.0")
    assert "verify: apt-release: Release of %s/apt stable signed by key %s" % (e.web.url, keys["good"].fpr) in rec, \
        "record names the key and the chain"
    assert "packages: arm 5, x86 5" in rec, "record: packages detected in the unpacked deb"
    assert "trivy rootfs --skip-db-update --scanners vuln" in "\n".join(cmds.lines()), \
        "trivy scanned an unpacked directory with rootfs"
    expect(e.go("check", "vector", "1.1.0"), 4, "already pinned", label="an already pinned deb is refused")


def test_estate_a_release_signed_by_another_key_is_refused(estate, keys):
    e = estate(signer="evil")
    before = e.pins_text()
    expect(e.go("check", "vector", "1.1.0"), 4, "is not signed by the pinned key " + keys["good"].fpr,
           label="a Release signed by another key is refused")
    assert e.pins_text() == before and list(e.scans.iterdir()) == [], "nothing written"
    assert not [p for p in e.web.log if "pool/" in p], "no .deb was fetched"


def test_estate_a_key_file_that_is_not_the_pinned_key_is_refused(estate, keys):
    e = estate(keyfile="evil", signer="evil")
    expect(e.go("check", "vector", "1.1.0"), 4, "not exactly the pinned " + keys["good"].fpr,
           label="a key file whose fingerprint is not the pinned one is refused")


def test_estate_a_swapped_packages_index_is_refused(estate):
    e = estate()
    p = e.srv("apt/dists/stable/vector-0/binary-arm64/Packages")
    p.write_text(re.sub(r"(?m)^SHA256: .*$", "SHA256: " + "f" * 64, p.read_text()))
    e.srv("apt/dists/stable/vector-0/binary-arm64/Packages.gz").unlink()
    expect(e.go("check", "vector", "1.1.0"), 4, "does not match the hash the signed Release gives it",
           label="a Packages index that differs from the signed Release hash is refused")


def test_estate_a_deb_that_does_not_match_its_packages_hash_is_refused(estate):
    e = estate()
    e.srv("apt/pool/v/ve/vector_1.1.0-1_amd64.deb").write_bytes(b"swapped deb")
    before = e.pins_text()
    expect(e.go("check", "vector", "1.1.0"), 4, "the signed Packages index says",
           label="an x86 .deb that does not match the signed Packages hash is refused")
    assert e.pins_text() == before, "both pins files unchanged"


def test_estate_a_version_absent_from_packages_is_refused(estate):
    e = estate()
    expect(e.go("check", "vector", "9.9.9"), 4, "lists 0 entries for vector_9.9.9-1_arm64.deb",
           label="a version absent from Packages is refused")


def test_estate_a_gzip_only_packages_index_is_read(estate):
    e = estate(onlygz=True)
    expect(e.go("check", "vector", "1.1.0"), 0, "verified the Release", label="a gzip-only Packages index is read")
    assert [p for p in e.web.log if "Packages.gz" in p], "the .gz was the one fetched"


def test_estate_inrelease_is_used_without_release_gpg(estate):
    e = estate(sigform="inrelease")
    expect(e.go("check", "vector", "1.1.0"), 0, "verified the Release",
           label="InRelease is used when Release.gpg is absent")


def test_estate_an_inrelease_from_another_key_is_refused(estate):
    e = estate(sigform="inrelease", signer="evil")
    expect(e.go("check", "vector", "1.1.0"), 4, "is not signed by the pinned key",
           label="a clearsigned InRelease from another key is refused")


def test_estate_a_gpgv_that_returns_no_signed_text_is_refused(estate, keys, cmds):
    # A gpgv that reports a good signature but returns no signed text (exits 0, prints no text) is
    # refused with a message, not a traceback from reading a file that is not there.
    e = estate(sigform="inrelease")
    line = ("[GNUPG:] VALIDSIG %s 2026-01-01 1767225600 0 4 0 1 10 01 %s\n" % ((keys["good"].fpr,) * 2)).encode()
    cmds.fakes["gpgv"] = lambda argv: (0, line, b"") if "--status-fd 1" in " ".join(argv) else (0, b"", line)
    r = e.go("check", "vector", "1.1.0")
    expect(r, 4, "returned no signed text", label="a gpgv that returns no signed text is refused")
    assert "Traceback" not in r.err, "and not with a traceback"


def test_estate_validate_refuses_a_plain_http_repository(estate):
    e = estate()
    d = e.descriptor("vector")
    d.write_text(re.sub(r'"repo": "http://127\.0\.0\.1:\d+/apt"', '"repo": "http://repo.example.invalid/apt"',
                        d.read_text()))
    expect(e.go("validate", "vector"), 4, "'repo' must be an https URL", label="validate: an http repository is refused")


# Plain http is allowed only to the loopback address the tests use, judged by the HOST: an address or
# a name that merely starts with "127.0.0.1" is another host.
@pytest.mark.parametrize("host", ["127.0.0.10", "127.0.0.1.example.invalid"])
def test_estate_validate_refuses_http_to_a_lookalike_of_the_loopback(estate, host):
    e = estate()
    d = e.descriptor("vector")
    d.write_text(re.sub(r'"repo": "http://127\.0\.0\.1:\d+/apt"', '"repo": "http://%s/apt"' % host,
                        d.read_text()))
    expect(e.go("validate", "vector"), 4, "'repo' must be an https URL",
           label="validate: http to %s is not the loopback, and is refused" % host)


# ================================================================= `latest` for a container image

RELEASES = "repos/acme/widget/releases"


class LatestWorld:
    """A service `svc` whose pin's tag is `tag`, and a release host (both hosts' base URLs point at
    the same loopback server) whose answers each test writes."""

    def __init__(self, work, web, tool, monkeypatch, host, line, tag="v15.0.9-rootless"):
        self.web, self._tool, self.monkeypatch = web, tool, monkeypatch
        self.root = work / "root"
        self.d = write_service(self.root, "svc", descriptor_text(
            release_line='"%s"' % line, release_api='{"host": "%s", "repo": "acme/widget"}' % host,
            migrations='{"kind": "always"}',
            checks='[{"name": "health", "command": ["true"], "pass": "exit 0"}]'),
            pin="%s:%s@%s" % (IMG, tag, D0))
        web.by_ref = True
        monkeypatch.setenv("IMAGE_BUMP_GITHUB_API", web.url)
        monkeypatch.setenv("IMAGE_BUMP_CODEBERG_API", web.url)

    def releases(self, *specs):
        """The release list; a tag suffixed ":d" is a draft, ":p" a pre-release."""
        out = []
        for spec in specs:
            tag, _, flag = spec.partition(":")
            out.append({"tag_name": tag, "draft": flag == "d", "prerelease": flag == "p"})
        self.web.put(RELEASES + "@", json.dumps(out))

    def latest(self, tag):
        self.web.put(RELEASES + "/latest@", json.dumps({"tag_name": tag, "draft": False, "prerelease": False}))

    def go(self, *args):
        return self._tool("latest", "svc", *args, "--root", self.root)

    def snap(self):
        return (self.d / "IMAGE").read_text(), sorted(p.name for p in self.d.iterdir())


@pytest.fixture
def latest_world(work, web, tool, monkeypatch):
    return lambda host, line, tag="v15.0.9-rootless": LatestWorld(work, web, tool, monkeypatch, host, line, tag)


PATCH, STABLE = "patch-of-pinned-major", "github-latest-stable"


def _unreachable(w):
    w.monkeypatch.setenv("IMAGE_BUMP_GITHUB_API", "http://127.0.0.1:1")


LATEST = [
    pytest.param("a newer patch on the pinned major", "github", PATCH, None,
                 lambda w: w.releases("v15.0.12", "v15.0.10", "v14.9.9"), 7,
                 "newer svc 15.0.9 -> 15.0.12 (v15.0.12)", ("GitHub is asked per_page=50", "releases?per_page=50"),
                 id="newer-patch"),
    pytest.param("numeric ordering: 15.0.10 is newer than 15.0.9", "github", PATCH, None,
                 lambda w: w.releases("v15.0.10", "v15.0.9", "v15.0.2"), 7, "-> 15.0.10 (v15.0.10)", None,
                 id="numeric-ordering"),
    pytest.param("a newer major only is not an alert", "github", PATCH, None,
                 lambda w: w.releases("v16.0.0", "v16.1.0", "v15.0.9", "v15.0.8"), 0, "up to date svc 15.0.9", None,
                 id="newer-major-only"),
    pytest.param("equal versions are up to date", "github", PATCH, None,
                 lambda w: w.releases("v15.0.9"), 0, "up to date svc 15.0.9", None, id="equal"),
    pytest.param("a pre-release or draft newer than current is skipped", "github", PATCH, None,
                 lambda w: w.releases("v15.0.12:p", "v15.0.11:d", "v15.0.9"), 0, "up to date svc 15.0.9", None,
                 id="prerelease-draft-skipped"),
    pytest.param("a non-numeric tag is skipped, never compared", "github", PATCH, None,
                 lambda w: w.releases("v99.0.0-rc1", "nightly", "v15.0.12-rc1", "v15.0.9"), 0,
                 "up to date svc 15.0.9", None, id="non-numeric-skipped"),
    pytest.param("skipped tags do not hide a real newer one", "github", PATCH, None,
                 lambda w: w.releases("v15.0.12-rc1", "v15.0.11", "nightly"), 7, "-> 15.0.11 (v15.0.11)", None,
                 id="skipped-do-not-hide"),
    pytest.param("a newer patch on a Codeberg-hosted repo", "codeberg", PATCH, None,
                 lambda w: w.releases("v15.0.12", "v15.0.9"), 7, "-> 15.0.12 (v15.0.12)",
                 ("Codeberg is asked limit=50", "releases?limit=50"), id="codeberg-newer"),
] + [
    pytest.param("an HTTP 500 on %s" % host, host, PATCH, None,
                 lambda w: (w.web.put(RELEASES + "@.code", "500\n"), w.releases("v15.0.12")), 2, "reading", None,
                 id="http-500-%s" % host)
    for host in ("github", "codeberg")
] + [
    pytest.param("a non-JSON body", "github", PATCH, None,
                 lambda w: w.web.put(RELEASES + "@", "this is not json"), 2, "unreadable JSON", None, id="non-json"),
    pytest.param("a non-list releases body", "github", PATCH, None,
                 lambda w: w.web.put(RELEASES + "@", '{"message": "rate limited"}'), 2, "not a list of releases", None,
                 id="non-list"),
    pytest.param("a 404", "github", PATCH, None, None, 2, "reading", None, id="not-found"),
    pytest.param("a host that does not answer", "github", PATCH, None, _unreachable, 2, "reading", None,
                 id="host-does-not-answer"),
    pytest.param("a newer stable release on the latest line", "github", STABLE, "v1.4.2",
                 lambda w: w.latest("v1.5.0"), 7, "newer svc 1.4.2 -> 1.5.0 (v1.5.0)",
                 ("the latest endpoint is asked", "/releases/latest"), id="stable-newer"),
    pytest.param("a newer major counts on the latest line", "github", STABLE, "v1.4.2",
                 lambda w: w.latest("v2.0.0"), 7, "-> 2.0.0", None, id="stable-newer-major"),
    pytest.param("latest equal to the pin is up to date", "github", STABLE, "v1.4.2",
                 lambda w: w.latest("v1.4.2"), 0, "up to date svc 1.4.2", None, id="stable-equal"),
    pytest.param("latest line orders numerically", "github", STABLE, "v1.4.2",
                 lambda w: w.latest("v1.4.10"), 7, "-> 1.4.10", None, id="stable-numeric"),
    pytest.param("a non-numeric latest tag cannot be compared", "github", STABLE, "v1.4.2",
                 lambda w: w.latest("v9.0.0-beta1"), 2, "not a numeric version", None, id="stable-non-numeric"),
    pytest.param("the latest line on Codeberg", "codeberg", STABLE, "v1.4.2",
                 lambda w: w.latest("v1.5.0"), 7, "-> 1.5.0", None, id="stable-codeberg"),
    pytest.param("latest line: an HTTP 500", "github", STABLE, "v1.4.2",
                 lambda w: (w.latest("v1.5.0"), w.web.put(RELEASES + "/latest@.code", "500\n")), 2, "reading", None,
                 id="stable-http-500"),
    pytest.param("latest line: a body that is not a release object", "github", STABLE, "v1.4.2",
                 lambda w: w.web.put(RELEASES + "/latest@", "[1,2]"), 2, "not a release object", None,
                 id="stable-not-object"),
    pytest.param("latest line: a non-JSON body", "github", STABLE, "v1.4.2",
                 lambda w: w.web.put(RELEASES + "/latest@", "nope"), 2, "unreadable JSON", None,
                 id="stable-non-json"),
]


@pytest.mark.parametrize("label,host,line,tag,arrange,status,text,asked", LATEST)
def test_latest(latest_world, web, label, host, line, tag, arrange, status, text, asked):
    w = latest_world(host, line, *([tag] if tag else []))
    if arrange:
        arrange(w)
    expect(w.go(), status, text, label=label)
    if asked:
        assert [p for p in web.log if asked[1] in p], asked[0]


def test_latest_with_pin(latest_world):
    w = latest_world("github", PATCH)
    w.releases("v15.0.9", "v15.0.7")
    expect(w.go(), 0, "up to date svc 15.0.9", label="pinned at the newest is up to date")
    before = w.snap()
    expect(w.go("--pin", "15.0.5"), 7, "newer svc 15.0.5 -> 15.0.9 (v15.0.9)",
           label="--pin older makes a same-major release newer")
    assert w.snap() == before, "--pin writes nothing"
    expect(w.go("--pin", "15.0.x"), 2, "not a numeric", label="a non-numeric --pin is an error")


# ================================================================= contract tests

def deployed_env(**extra):
    """The environment a person's shell would give the tool: this process's, minus the interpreter
    pytest runs on. `uv run --script` puts its environment's bin directory first on PATH, where
    `python3` is uv's; left there, a contract test would run the tool on the very interpreter the
    in-process tests already use, and prove nothing about the machine's own."""
    env = dict(os.environ)
    if sys.prefix != sys.base_prefix:      # running in a virtual environment, as uv runs this file
        inside = [os.path.realpath(p) for p in (sys.prefix, env.get("VIRTUAL_ENV")) if p]
        env["PATH"] = os.pathsep.join(
            d for d in env.get("PATH", "").split(os.pathsep)
            if d and not any(os.path.realpath(d) == p or os.path.realpath(d).startswith(p + os.sep) for p in inside))
    for name in ("VIRTUAL_ENV", "PYTHONHOME", "PYTHONPATH"):
        env.pop(name, None)
    env.update(extra)
    return env


def deployed_python3():
    py = shutil.which("python3", path=deployed_env()["PATH"])
    assert py, "no python3 on the deployed PATH: the tool's shebang (#!/usr/bin/env python3) cannot run"
    return py


def run_process(argv, env=None, cwd=None):
    """The tool as its own process, through its shebang unless argv starts with an interpreter."""
    p = subprocess.run([str(a) for a in argv], env=env or deployed_env(), cwd=cwd, capture_output=True, text=True)
    return Result(p.returncode, p.stdout, p.stderr)


def test_contract_the_shebang_is_env_python3():
    assert TOOL.read_text().splitlines()[0] == "#!/usr/bin/env python3", "the shebang finds python3 on PATH"
    assert os.access(TOOL, os.X_OK), "the tool file is executable"


def test_contract_loads_and_runs_on_the_deployed_python3(work):
    py = deployed_python3()
    version = subprocess.run([py, "-c", "import sys; print('%d.%d' % sys.version_info[:2])"],
                             capture_output=True, text=True).stdout.strip()
    write_service(work / "root", "good", descriptor_text())
    # Executed directly, so the kernel reads the shebang and env finds python3 on the deployed PATH.
    r = run_process([TOOL, "validate", "good", "--root", work / "root"])
    expect(r, 0, label="loads on the deployed python3 (%s, Python %s)" % (py, version))
    assert r.out == "ok good\n", r


def _contract_world(work, web):
    root = work / "root"
    write_service(root, "good", descriptor_text())
    (root / "boom").mkdir()
    (root / "boom" / "image_bump.py").write_text('raise RuntimeError("boom")\n')
    web.by_ref = True
    web.put(RELEASES + "@", json.dumps([{"tag_name": "v1.2.4", "draft": False, "prerelease": False}]))
    return root


EXIT_STATUSES = [
    pytest.param(("validate", "good"), 0, "ok good", id="ok-0"),
    pytest.param(("validate", "absent"), 4, "no descriptor at", id="refused-4"),
    pytest.param(("bogus", "good"), 2, "invalid choice", id="usage-2"),
    pytest.param(("validate", "boom"), 2, "RuntimeError: boom", id="exception-2-never-1"),
    pytest.param(("latest", "good"), 7, "newer good 1.2.3 -> 1.2.4", id="newer-7"),
]


@pytest.mark.parametrize("args,status,text", EXIT_STATUSES)
def test_contract_exit_statuses(work, web, args, status, text):
    root = _contract_world(work, web)
    r = run_process([TOOL, *args, "--root", root], env=deployed_env(IMAGE_BUMP_GITHUB_API=web.url))
    expect(r, status, text, label="exit status %d through a real process" % status)


def test_contract_external_programs_are_found_on_path(work):
    write_service(work / "root", "svc", descriptor_text())
    py = deployed_python3()
    stubs, log = work / "stubs", work / "stub.log"
    stubs.mkdir()
    (stubs / "skopeo").write_text('#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$STUB_LOG"\n'
                                  'echo "stub says no" >&2\nexit 3\n')
    (stubs / "skopeo").chmod(0o755)
    # PATH holds only the stub, so the interpreter is named by its path; the tool must find skopeo.
    r = run_process([py, TOOL, "check", "svc", "1.3.0", "--root", work / "root"],
                    env=deployed_env(PATH=str(stubs), STUB_LOG=str(log)))
    expect(r, 2, "skopeo inspect --raw failed (status 3): stub says no", label="skopeo is run from PATH")
    assert log.read_text() == "inspect --raw docker://%s:%s\n" % (IMG, NEWTAG), "the stub on PATH was run"
    (work / "emptybin").mkdir()
    r = run_process([py, TOOL, "check", "svc", "1.3.0", "--root", work / "root"],
                    env=deployed_env(PATH=str(work / "emptybin")))
    expect(r, 2, "cannot run skopeo", label="no skopeo on PATH is an environment error")


# ================================================================= mutants

def make_mutant(directory, find, replace):
    """A copy of the tool in `directory` with `find` replaced by `replace`. `find` must occur
    exactly once, so the mutant changes the one place it names; anything else fails the test, as
    does a replacement that leaves the text as it was."""
    source = TOOL.read_text()
    n = source.count(find)
    if n != 1:
        pytest.fail("mutant: %r occurs %d times in the tool; it must occur exactly once" % (find, n))
    mutated = source.replace(find, replace)
    if mutated == source:
        pytest.fail("mutant: the replacement changed nothing")
    # One directory per mutant (the fixture's `work`): Python caches a module's bytecode by path,
    # size and modification time to the second, so a second mutant of the same size written to the
    # same path within that second would run the first one's code.
    path = directory / "image-bump-mutant"
    path.write_text(mutated)
    shutil.copymode(TOOL, path)
    return path


@pytest.fixture
def mutant(work):
    return lambda find, replace: make_mutant(work, find, replace)


def run_one_test(nodeid, tool_path):
    """Run one test of this file in a child pytest, with the tool loaded from `tool_path`."""
    # TMPDIR as this run was given it, not this test's own: the child makes its own directories
    # under it, and a gpg home nested two levels deeper can exceed the length of a socket path.
    env = dict(os.environ, IMAGE_BUMP_TEST_TOOL=str(tool_path), TMPDIR=ORIGINAL_TMP)
    p = subprocess.run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider",
                        "%s::%s" % (Path(__file__).resolve(), nodeid)],
                       env=env, cwd=str(HERE), capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


# (id, what the mutant breaks, find, replace, the test that must fail against it). Each find occurs
# exactly once in the tool. A `# guard:` or `# step:` comment in the tool marks a line a mutant here
# disables.
MUTANTS = [
    ("url-ok-prefix", "a host that merely starts with the loopback's address passes as the loopback",
     'return parts.scheme == "http" and parts.hostname == "127.0.0.1"',
     'return parts.scheme == "http" and (parts.hostname or "").startswith("127.0.0.1")',
     "test_estate_validate_refuses_http_to_a_lookalike_of_the_loopback[127.0.0.10]"),
    # --- the frame and validate
    ("validate-missing-field", "a missing field is not reported",
     "if not hasattr(module, name) and not (manual and name in DEPLOY_ONLY):", "if False:",
     "test_validate[missing-field]"),
    ("validate-pin-image", "a pin naming another image is accepted",
     'if image != get("image"):', "if False:", "test_validate[pin-names-another-image]"),
    ("validate-manual-fields", "a manual descriptor may keep a deploy-only field",
     'problems.append("%s: not valid with an install kind of manual" % name)', "pass",
     "test_validate[manual-with-volume]"),
    ("never-exit-1", "an unexpected exception escapes main",
     "except Exception as exc:  # noqa: BLE001", "except ZeroDivisionError as exc:  # noqa: BLE001",
     "test_a_descriptor_raising_at_import_is_status_2_never_1"),
    # --- check, for a container image
    ("check-platform", "an image built for another platform is accepted",
     "if got != platform:", "if False:", "test_check_refuses_an_image_built_for_another_platform"),
    ("check-db-once", "the database is fetched twice",
     'run_cmd(["trivy", "image", "--download-db-only"])',
     'run_cmd(["trivy", "image", "--download-db-only"]); run_cmd(["trivy", "image", "--download-db-only"])',
     "test_check_a_clean_new_image_passes"),
    ("check-skip-db-update", "the scans fetch the database again",
     '["trivy", "image", "--skip-db-update", "--scanners", "vuln",', '["trivy", "image", "--scanners", "vuln",',
     "test_check_a_clean_new_image_passes"),
    ("check-already-pinned", "a tag already pinned is not refused",
     'raise Refusal("%s:%s is already pinned (%s)" % (image, new_tag, digest))', "pass",
     "test_check_refuses_a_tag_that_is_already_pinned"),
    ("gate-floor-boundary", "an equal fixable count passes as an exception",
     "if n < c:", "if n <= c:", "test_check_floor[equal-count-refused]"),
    ("gate-unfixed-counted", "unfixed findings count as fixable",
     'return [f for f in findings if f["fixed"]]', "return list(findings)",
     "test_check_floor[unfixed-not-counted]"),
    ("gate-no-new-findings", "a new finding is never seen",
     'added = sorted(set((f["id"], f["pkg"]) for f in new) - old)', "added = []",
     "test_check_no_new_findings[one-new-refused]"),
    ("migration-direction", "a migration is detected from the old listing's extra files",
     "return bool(new - old)", "return bool(old - new)", "test_check_a_name_only_in_the_new_listing_migrates"),
    ("migration-non-list", "a listing that is not a list reads as no migration",
     'raise EnvError("listing %s: not a list of files" % url)', "doc = []",
     "test_check_migrations[non-list-response]"),
    ("check-no-write", "--no-write writes the record and the pin",
     '    if args.no_write:\n        print("not written (--no-write)")\n    else:\n'
     '        scan_dir = resolve_path(desc.scan_dir, directory)',
     '    if False:\n        print("not written (--no-write)")\n    else:\n'
     '        scan_dir = resolve_path(desc.scan_dir, directory)',
     "test_check_no_write_on_an_exception"),
    ("check-record-overwrite", "an existing scan record is overwritten",
     'if os.path.exists(record):\n            raise Refusal("scan record %s exists; records are never '
     'overwritten" % record)\n        os.makedirs(',
     'if False:\n            raise Refusal("scan record %s exists; records are never '
     'overwritten" % record)\n        os.makedirs(',
     "test_check_never_overwrites_a_record"),
    # --- deploy
    ("deploy-record-found", "deploy runs without a scan record",
     "if record is None:  # guard: record-found", "if False:  # guard: record-found",
     "test_deploy_refuses_without_a_scan_record"),
    ("deploy-applied-differs", "deploy runs when the pin is already running",
     "if running == applied:  # guard: applied-differs", "if False:  # guard: applied-differs",
     "test_deploy_refuses[already-running]"),
    ("deploy-running-is-replaces", "deploy replaces an image the record does not name",
     "if running != replaces:  # guard: running-is-replaces", "if False:  # guard: running-is-replaces",
     "test_deploy_refuses[running-not-replaced]"),
    ("deploy-image-exists", "deploy runs with nothing to roll back to",
     'if not image_exists("%s@%s" % (image, replaces)):  # guard: image-exists', "if False:  # guard: image-exists",
     "test_deploy_refuses[replaced-image-gone]"),
    ("deploy-rolled-back", "a digest rolled back before is deployed again",
     "if applied in read_rolled_back(args.service):  # guard: rolled-back", "if False:  # guard: rolled-back",
     "test_deploy_refuses[rolled-back-before]"),
    ("deploy-bounded-wait", "the checks run once more than --wait allows",
     "if time.monotonic() >= deadline:  # guard: bounded-wait",
     "if time.monotonic() > deadline:  # guard: bounded-wait",
     "test_deploy_rolls_back_a_service_that_never_comes_back"),
    ("deploy-not-recovered", "a rollback that did not bring the service back exits 5",
     "if not back:  # guard: not-recovered", "if False:  # guard: not-recovered",
     "test_deploy_a_rollback_that_does_not_recover_stops_for_a_person"),
    ("deploy-not-recovered-restore-fails", "a restore that failed exits 5, as if it had worked",
     "if not back:  # guard: not-recovered", "if False:  # guard: not-recovered",
     "test_deploy_a_restore_that_fails_stops_for_a_person"),
    ("deploy-migrating-no-restore", "a failed migrating version is restored",
     "if migrates:  # guard: migrating-no-restore", "if False:  # guard: migrating-no-restore",
     "test_deploy_a_migrating_version_that_fails_restores_nothing"),
    ("deploy-export", "a migrating version is deployed without its export",
     "if migrates:  # step: export", "if False:  # step: export",
     "test_deploy_a_migrating_version_exports_the_volume_first"),
    ("deploy-keep", "the unit is not kept before the install",
     'vm("cp", vm_unit, kept)  # step: keep', "pass  # step: keep", "test_deploy_a_clean_deploy"),
    ("deploy-manual", "deploy drives a manual install",
     'if desc.install["kind"] == "manual":  # guard: manual-install', "if False:  # guard: manual-install",
     "test_deploy_refuses_a_manual_install_before_touching_anything"),
    ("deploy-artifact", "deploy drives an artifact descriptor",
     "if is_artifact(desc):  # guard: no-artifact-deploy", "if False:  # guard: no-artifact-deploy",
     "test_estate_deploy_and_validate"),
    # --- artifacts
    ("cosign-refusal", "a checksums file cosign refused is used",
     'raise Refusal("cosign verify-blob refused %s (status %d): %s" % (names["checksums"], status, err))', "pass",
     "test_estate_a_tampered_checksums_file_is_refused"),
    ("asset-hash", "an asset whose bytes do not match the verified hash is pinned",
     "if got != want:\n            raise Refusal(\"%s: the downloaded bytes hash to %s, the verified checksums",
     "if False:\n            raise Refusal(\"%s: the downloaded bytes hash to %s, the verified checksums",
     "test_estate_an_asset_with_the_wrong_bytes_is_refused"),
    ("download-cut", "a transfer cut short is not noticed",
     "if announced is not None and announced.isdigit() and int(announced) != size:", "if False:",
     "test_estate_a_transfer_cut_short_is_an_environment_error"),
    ("first-pin-exception", "a first pin with fixable findings passes",
     'return "exception", ("%d fixable findings in a first pin', 'return "pass", ("%d fixable findings in a first pin',
     "test_estate_a_first_pin_with_a_fixable_finding_is_an_exception"),
    ("first-pin-refused", "a first pin with fixable findings is refused, as before the fix",
     "        if first:\n", "        if False:\n",
     "test_estate_a_first_pin_with_a_fixable_finding_is_an_exception"),
    ("no-coverage", "an artifact trivy detected nothing in passes",
     '            verdict = "exception"\n', "            pass\n",
     "test_estate_no_coverage_on_one_architecture_is_an_exception"),
    ("pins-line-count", "two lines for one pin are accepted",
     "if len(found) != 1:", "if not found:", "test_estate_pins_files[two-lines]"),
    ("pins-disagree", "pins files naming different versions are accepted",
     "if len(real) > 1:", "if False:", "test_estate_pins_files[versions-disagree]"),
    ("current-pin-hash", "a current pin whose bytes changed is scanned anyway",
     'if got != st["hash"]:', "if False:", "test_estate_pins_files[current-pin-tampered]"),
    ("apt-signer", "a Release signed by another key is trusted",
     "if status != 0 or fpr not in signers:", "if False:", "test_estate_a_release_signed_by_another_key_is_refused"),
    ("apt-key-file", "a key file holding another key is used",
     "if primaries != [want]:", "if False:", "test_estate_a_key_file_that_is_not_the_pinned_key_is_refused"),
    ("apt-packages-hash", "a Packages index the Release does not vouch for is read",
     "if got != hashes[rel][0] or len(raw) != hashes[rel][1]:", "if False:",
     "test_estate_a_swapped_packages_index_is_refused"),
    ("apt-deb-hash", "a .deb whose bytes do not match Packages is pinned",
     "if got != want:\n            raise Refusal(\"%s: the downloaded bytes hash to %s, the signed Packages",
     "if False:\n            raise Refusal(\"%s: the downloaded bytes hash to %s, the signed Packages",
     "test_estate_a_deb_that_does_not_match_its_packages_hash_is_refused"),
    ("apt-no-signed-text", "an empty signed text is read as a Release",
     "if not text.strip():", "if False:", "test_estate_a_gpgv_that_returns_no_signed_text_is_refused"),
    ("url-https", "a plain-http repository is accepted",
     'return parts.scheme == "http" and parts.hostname == "127.0.0.1"',
     'return parts.scheme == "http"', "test_estate_validate_refuses_a_plain_http_repository"),
    # --- latest
    ("latest-prerelease", "a pre-release counts as a release",
     'if rel.get("draft") or rel.get("prerelease"):', 'if rel.get("draft"):',
     "test_latest[prerelease-draft-skipped]"),
    ("latest-numeric", "versions compare as text",
     'return tuple(int(n) for n in text.split("."))', 'return tuple(text.split("."))',
     "test_latest[numeric-ordering]"),
    ("latest-major", "a newer major counts on the patch line",
     "if found is None or found[0] != current[0] or found <= current:", "if found is None or found <= current:",
     "test_latest[newer-major-only]"),
    ("latest-github-query", "GitHub is asked Codeberg's query",
     'query = "limit=50" if host == "codeberg" else "per_page=50"', 'query = "limit=50"',
     "test_latest[newer-patch]"),
    ("latest-non-list", "a releases body that is not a list reads as up to date",
     'raise EnvError("%s: not a list of releases" % url)', "doc = []", "test_latest[non-list]"),
    # --- the contract
    ("contract-exit-status", "main's status never reaches the exit status",
     "    sys.exit(main())", "    main()", "test_contract_exit_statuses[refused-4]"),
    ("contract-shebang", "the shebang names an interpreter other than python3",
     "#!/usr/bin/env python3\n", "#!/usr/bin/env python\n", "test_contract_the_shebang_is_env_python3"),
    ("contract-path-lookup", "external programs are not looked up on PATH",
     "        proc = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)\n"
     "    except OSError as exc:\n        raise EnvError(\"cannot run %s: %s\" % (argv[0], exc.strerror))\n"
     "    if proc.returncode != 0:",
     "        proc = subprocess.run([\"/nonexistent/\" + argv[0]] + argv[1:], stdout=subprocess.PIPE, "
     "stderr=subprocess.PIPE)\n"
     "    except OSError as exc:\n        raise EnvError(\"cannot run %s: %s\" % (argv[0], exc.strerror))\n"
     "    if proc.returncode != 0:",
     "test_contract_external_programs_are_found_on_path"),
]


@pytest.mark.mutant
@pytest.mark.parametrize("name,description,find,replace,test", MUTANTS, ids=[m[0] for m in MUTANTS])
def test_mutant_is_caught(mutant, name, description, find, replace, test):
    status, output = run_one_test(test, mutant(find, replace))
    # Status 1 is "tests failed"; 2 to 5 would be an interrupted, broken or empty run, which says
    # nothing about the test.
    assert status == 1 and re.search(r"\b1 failed\b", output), \
        "mutant %s (%s) was not caught by %s:\n%s" % (name, description, test, output[-3000:])


@pytest.mark.mutant
def test_mutant_harness_passes_an_unchanged_copy(work):
    copy = work / "image-bump-copy"
    shutil.copy2(TOOL, copy)
    status, output = run_one_test("test_check_refuses_an_image_built_for_another_platform", copy)
    assert status == 0 and re.search(r"\b1 passed\b", output), output[-3000:]


@pytest.mark.mutant
def test_mutant_fixture_refuses_a_replacement_that_changes_nothing(work):
    with pytest.raises(pytest.fail.Exception, match="occurs 0 times"):
        make_mutant(work, "text that is not in the tool", "x")
    with pytest.raises(pytest.fail.Exception, match="changed nothing"):
        make_mutant(work, "if got != platform:", "if got != platform:")


class _Lane:
    """The landing lane. A normal run deselects every test marked `mutant`; with RUN_MUTANTS=1 (the
    landing gate sets it) they all run. Deselecting, not skipping, so the summary says how many were
    left out ("N deselected") instead of counting them as passes."""

    def pytest_collection_modifyitems(self, config, items):
        if os.environ.get("RUN_MUTANTS") == "1":
            return
        left = [i for i in items if i.get_closest_marker("mutant")]
        if left:
            config.hook.pytest_deselected(items=left)
            items[:] = [i for i in items if not i.get_closest_marker("mutant")]


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider",
                          "-o", "markers=mutant: a mutant meta-test, run in the landing lane only",
                          *sys.argv[1:]], plugins=[_Lane()]))
