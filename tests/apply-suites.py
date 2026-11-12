#!/usr/bin/env python3
"""apply-suites -- run this source tree's suites through Nx around `chezmoi apply`.

    python3 tests/apply-suites.py pre          before the apply; a failure aborts it
    python3 tests/apply-suites.py post         after it: start an uncached full run, detached
    python3 tests/apply-suites.py post --run   that run, in the foreground

chezmoi reaches this through tests/pre-apply.sh (`hooks.apply.pre`) and tests/post-apply.sh
(`hooks.apply.post`), both wired in .chezmoi.toml.tmpl. chezmoi aborts the apply when a pre hook
exits non-zero (measured with chezmoi 2.74: exit 1, no target written).

ONE PASS CACHE: NX'S. Each suite is an Nx target (tools/nx/suites.js) whose inputs are the paths
tests/coverage.map says it reads, the shared core, the tool versions it runs through, and
SANDBOX_RUNTIME. `pre` runs `nx run-many -t test`: a suite whose inputs did not change since it last
passed is replayed from Nx's cache, and every suite whose inputs changed runs. So the apply waits on
exactly what the change can break. The working tree is what Nx hashes, dirty edits and untracked
files included, which is also what an apply deploys.

THE SANDBOX IS PART OF THE KEY. A suite can pass inside a Claude Code session's sandbox and fail in a
terminal (one did: the sandbox could not write /tmp, so the leak the suite checks for could not
happen there). Claude Code sets SANDBOX_RUNTIME in a sandboxed command, and the plugin hashes it, so
a pass recorded in a sandbox never replays in a terminal, nor the reverse.

NODE COMES FROM .nvmrc. Nx is a repository dependency (package.json), run under the Node the
repository pins:
  * with `fnm` on PATH, every Node command runs as `fnm exec --using=<.nvmrc>`; a version fnm has not
    installed refuses the apply, naming `fnm install <version>`;
  * without fnm, the `node` on PATH is used only if its major version is the pin's; otherwise, or
    with no node at all, the apply is refused, naming the fix.
The version is never installed from here: a download on the apply path is a side effect the apply
should not have, and some machines must install through a mirror their owner configures.

NPM CI ONLY WHEN THE INSTALL IS STALE. node_modules/.package-lock.json is npm's record of what is
installed. It omits the root package and the optional packages for other platforms (Nx's native
binary for each OS and CPU), so it is compared by entry rather than byte for byte: every installed
entry must equal the lockfile's, and every lockfile entry that is not installed must be optional.
Anything else, or a record that is missing or unreadable, runs `npm ci --no-audit --no-fund`; its
failure refuses the apply. Residual: an optional package newly added for THIS platform alone, with
no other entry changing, is not noticed; Nx fails loudly if its native binary is missing.

NX'S ENVIRONMENT. NX_DAEMON=false and NX_ISOLATE_PLUGINS=false, so Nx opens no socket: inside a
sandbox no socket directory passes Nx's ownership walk (from Nx 24.0.3), and plugin workers need a
socket as much as the daemon does. NX_TUI=false and --outputStyle=static, so the log is plain lines.
NX_PARALLEL, unless the caller set it, is the CPU count up to 8, the concurrency tests/run-all.sh
uses, so a cold apply is no slower than the runner it replaced.

SKIPS, loudly and with exit 0:
  * DOTFILES_SKIP_PRE_APPLY=1 (`pre`) or DOTFILES_SKIP_POST_APPLY=1 (`post`): for the apply a suite
    itself depends on, which cannot pass before that apply deploys what the suite needs;
  * a tool the suites need is not installed: on a fresh machine's first apply the tools arrive with
    or after that apply, and refusing it would leave the machine unable to bootstrap.
Missing or mismatched Node is not a skip: Node is needed only to run the suites, so a machine with
the other tools and no usable Node would otherwise apply untested every time.

The CHEZMOI_* variables chezmoi sets for a hook are removed first, so the suites run as they do at
commit time rather than inside chezmoi's environment.

POST: EVERY SUITE, UNCACHED, IN THE BACKGROUND. `post` returns at once and leaves
`post --run` running in its own session with every descriptor closed, because chezmoi waits for a
hook's output pipes as well as its exit. That run is `nx run-many -t test --skip-nx-cache`: the one
run that trusts no recorded pass, on a machine that may never land a change itself. One run at a
time: an atomic mkdir of <git common dir>/post-apply.lock, holding the run's pid; a second run that
finds a live holder exits without testing, and a lock whose pid is gone is reclaimed. Its results,
under ${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/:
  post-apply-<utc time>.log   the run's full output; the newest 5 are kept
  post-apply.last             one line: time, HEAD's tree (or `dirty`), `pass` or `FAIL`, log path
On a failure ${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/alert, when it is an executable file, is run
with one argument naming the failing suites and the log. This base knows no notification service; a
private layer supplies the file. A failing alert hook is ignored: the status file holds the result.

Exit: `pre` 0 the suites passed, or skipped; 1 a suite failed or the suites could not be run (the
apply is aborted). `post` 0 always. `post --run` 0 a pass (or another run holds the lock), 1 a failure.

Standard library only, and Python 3.9 syntax: macOS's command-line tools ship that python3, and a
hook may meet it first on PATH (tests/test-python39-syntax.sh checks this file).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parent
REQUIRED = ("git", "python3", "uv", "jq", "yq", "gitleaks", "wt")
TARGET = "test"
KEEP_LOGS = 5
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


class Refused(Exception):
    """The suites cannot be run; the message names why and the fix."""


def say(tag: str, msg: str) -> None:
    print(f"dotfiles {tag}: {msg}", file=sys.stderr, flush=True)


def hook_env() -> dict:
    return {k: v for k, v in os.environ.items() if not k.startswith("CHEZMOI")}


def missing_tools(env: dict) -> list:
    return [t for t in REQUIRED if shutil.which(t, path=env.get("PATH", "")) is None]


def version_parts(text: str) -> list:
    return re.findall(r"\d+", text)


def capture(cmd: list, env: dict) -> str | None:
    """A command's stripped stdout, or None when it cannot run or exits non-zero."""
    try:
        out = subprocess.run(cmd, env=env, cwd=str(SRC), stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def select_node(env: dict) -> tuple:
    """(prefix, description): the argv prefix that runs a Node command under the pinned version."""
    try:
        want = (SRC / ".nvmrc").read_text().strip()
    except OSError:
        raise Refused(f"no readable {SRC / '.nvmrc'}, so the Node the suites run under is unknown")
    want = want[1:] if want.startswith("v") else want
    if not re.fullmatch(r"\d+(\.\d+){0,2}", want):
        raise Refused(f".nvmrc holds {want!r}, not a version number")
    wanted = want.split(".")
    path = env.get("PATH", "")
    fnm = shutil.which("fnm", path=path)
    if fnm:
        prefix = [fnm, "exec", f"--using={want}", "--"]
        got = capture(prefix + ["node", "--version"], env)
        if got is None or version_parts(got)[: len(wanted)] != wanted:
            raise Refused(f"Node {want} (.nvmrc) is not installed in fnm. Install it with "
                          f"`fnm install {want}`, then apply again")
        return prefix, f"Node {got} via fnm"
    node = shutil.which("node", path=path)
    if node is None:
        raise Refused(f"no fnm and no node on PATH. Install fnm (the Brewfile's, or the "
                      f"distribution's package) and run `fnm install {want}`, then apply again")
    got = capture([node, "--version"], env) or "an unreadable version"
    if version_parts(got)[:1] != wanted[:1]:
        raise Refused(f"the node on PATH ({node}) is {got}, but .nvmrc pins {want}, major "
                      f"{wanted[0]}. Install fnm and run `fnm install {want}`, or put Node "
                      f"{wanted[0]} first on PATH, then apply again")
    return [], f"Node {got} from PATH (no fnm)"


def install_is_current(src: Path) -> tuple:
    """(True, "") when node_modules holds what package-lock.json names; else (False, why)."""
    try:
        lock = json.loads((src / "package-lock.json").read_text())["packages"]
    except (OSError, ValueError, KeyError, TypeError):
        return False, "package-lock.json cannot be read"
    try:
        have = json.loads((src / "node_modules" / ".package-lock.json").read_text())["packages"]
    except (OSError, ValueError, KeyError, TypeError):
        return False, "nothing is installed (no readable node_modules/.package-lock.json)"
    for name, entry in have.items():
        if lock.get(name) != entry:
            return False, f"{name} differs from package-lock.json"
    for name, entry in lock.items():
        if name and name not in have and not (isinstance(entry, dict) and entry.get("optional")):
            return False, f"{name} is not installed"
    return True, ""


def ensure_install(prefix: list, env: dict, log) -> str:
    current, why = install_is_current(SRC)
    if current:
        return "node_modules current, npm ci skipped"
    log.write(f"apply-suites: npm ci, because {why}\n")
    log.flush()
    rc = subprocess.run(prefix + ["npm", "ci", "--no-audit", "--no-fund"], env=env, cwd=str(SRC),
                        stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT).returncode
    if rc != 0:
        raise Refused(f"npm ci failed (exit {rc}), so Nx cannot run; its output is in the log below")
    return f"npm ci ran: {why}"


def nx_env(env: dict) -> dict:
    out = dict(env)
    out["NX_DAEMON"] = "false"
    out["NX_ISOLATE_PLUGINS"] = "false"
    out["NX_TUI"] = "false"
    if not out.get("NX_PARALLEL"):
        out["NX_PARALLEL"] = str(min(os.cpu_count() or 4, 8))
    return out


def run_nx(prefix: list, env: dict, extra: list, log) -> int:
    nx = SRC / "node_modules" / ".bin" / "nx"
    if not nx.exists():
        raise Refused(f"{nx} is missing after the install, so Nx cannot run")
    cmd = prefix + [str(nx), "run-many", "-t", TARGET, "--outputStyle=static"] + extra
    log.write("apply-suites: " + " ".join(cmd) + "\n")
    log.flush()
    return subprocess.run(cmd, env=nx_env(env), cwd=str(SRC), stdin=subprocess.DEVNULL,
                          stdout=log, stderr=subprocess.STDOUT).returncode


def read_log(path: Path) -> list:
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return []
    return [ANSI.sub("", line).rstrip() for line in text.splitlines()]


def nx_summary(lines: list) -> str:
    keep = [ln.strip() for ln in lines
            if "Successfully ran target" in ln or "read the output from the cache" in ln]
    return " ".join(keep) or (lines[-1].strip() if lines else "")


def failures(lines: list) -> tuple:
    """(runner lines, suite files): run-all's FAIL lines, and the suites Nx says failed."""
    shown = [ln for ln in lines if ln.startswith("FAIL ") or ln.startswith("run-all:")]
    suites = []
    for ln in lines:
        m = re.match(r"^FAIL +(test-\S+)", ln)
        if m and m.group(1) not in suites:
            suites.append(m.group(1))
    for ln in lines:
        m = re.match(r"^\s*-\s+suite-(\S+):" + TARGET + r"\b", ln)
        if not m:
            continue
        for ext in (".sh", ".py"):
            name = f"test-{m.group(1)}{ext}"
            if (HERE / name).exists() and name not in suites:
                suites.append(name)
    return shown, suites


# --- pre -------------------------------------------------------------------------------------------

def pre() -> int:
    if os.environ.get("DOTFILES_SKIP_PRE_APPLY") == "1":
        say("pre-apply", "SKIPPED by DOTFILES_SKIP_PRE_APPLY=1; the apply goes ahead untested.")
        return 0
    env = hook_env()
    missing = missing_tools(env)
    if missing:
        say("pre-apply", "suites SKIPPED, not installed: " + " ".join(missing)
            + ". The apply goes ahead untested;\n  install them (the Brewfile, or the distribution"
            " packages) and the next apply runs the suites.")
        return 0
    tmp = os.environ.get("TMPDIR") or "/tmp"
    try:
        fd, name = tempfile.mkstemp(prefix="dotfiles-pre-apply.", dir=tmp)
    except OSError:
        say("pre-apply", "no temp file for the log; apply refused")
        return 1
    logpath = Path(name)
    with os.fdopen(fd, "w") as log:
        try:
            prefix, node = select_node(env)
            installed = ensure_install(prefix, env, log)
            say("pre-apply", f"running the suites through Nx ({node}; {installed}); a suite whose"
                " inputs are unchanged replays from Nx's cache...")
            rc = run_nx(prefix, env, [], log)
        except Refused as e:
            log.write(f"apply-suites: refused: {e}\n")
            say("pre-apply", f"{e}.\n  Apply ABORTED, nothing was deployed. Setup output: {logpath}")
            return 1
    lines = read_log(logpath)
    if rc == 0:
        say("pre-apply", nx_summary(lines))
        logpath.unlink()
        return 0
    shown, suites = failures(lines)
    print("", file=sys.stderr)
    say("pre-apply", "a suite failed -- apply ABORTED, nothing was deployed:")
    for ln in shown or lines[-15:]:
        print("  " + ln, file=sys.stderr)
    print(f"\n  why, in full: {logpath}", file=sys.stderr)
    for s in suites:
        print(f"  re-run one:   sh {HERE}/run-all.sh --only {s}", file=sys.stderr)
    return 1


# --- post ------------------------------------------------------------------------------------------

def state_dir() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(base) / "dotfiles"


def git_out(env: dict, *args: str) -> str | None:
    return capture(["git", "-C", str(SRC)] + list(args), env)


def lock_path(env: dict) -> Path:
    common = git_out(env, "rev-parse", "--git-common-dir")
    if not common:
        return state_dir() / "post-apply.lock"
    p = Path(common)
    return (p if p.is_absolute() else SRC / p) / "post-apply.lock"


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def take_lock(lock: Path) -> bool:
    """The run's lock, reclaimed once from a holder whose pid is gone; a pid not yet written is held."""
    for attempt in (1, 2):
        try:
            lock.mkdir()
        except FileExistsError:
            try:
                holder = int((lock / "pid").read_text().strip())
            except (OSError, ValueError):
                return False
            if attempt == 2 or pid_alive(holder):
                return False
            shutil.rmtree(lock, ignore_errors=True)
            continue
        except OSError:
            return False
        (lock / "pid").write_text(f"{os.getpid()}\n")
        return True
    return False


def clean_tree(env: dict) -> str:
    status = git_out(env, "status", "--porcelain")
    if status is None or status != "":
        return ""
    return git_out(env, "rev-parse", "HEAD^{tree}") or ""


def post_detach() -> int:
    if os.environ.get("DOTFILES_SKIP_POST_APPLY") == "1":
        say("post-apply", "SKIPPED by DOTFILES_SKIP_POST_APPLY=1; the suites do not run after this apply.")
        return 0
    missing = missing_tools(hook_env())
    if missing:
        say("post-apply", "suites SKIPPED, not installed: " + " ".join(missing)
            + ". Install them and the next apply runs the suites.")
        return 0
    say("post-apply", "running every suite in the background, uncached; last result in the status"
        " file post-apply.last")
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "post", "--run"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, close_fds=True, cwd=str(SRC))
    return 0


def post_run() -> int:
    env = hook_env()
    sd = state_dir()
    sd.mkdir(parents=True, exist_ok=True)
    lock = lock_path(env)
    if not take_lock(lock):
        return 0

    def stop(_sig, _frame):
        raise SystemExit(1)

    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, stop)
    try:
        return post_body(env, sd)
    finally:
        shutil.rmtree(lock, ignore_errors=True)


def post_body(env: dict, sd: Path) -> int:
    tree = clean_tree(env)
    logpath = sd / ("post-apply-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + ".log")
    with open(logpath, "w") as log:
        try:
            prefix, node = select_node(env)
            log.write(f"apply-suites: {node}; {ensure_install(prefix, env, log)}\n")
            rc = run_nx(prefix, env, ["--skip-nx-cache"], log)
            refusal = ""
        except Refused as e:
            log.write(f"apply-suites: refused: {e}\n")
            rc, refusal = 1, str(e)
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    logs = sorted(sd.glob("post-apply-*.log"), reverse=True)
    for old in logs[KEEP_LOGS:]:
        old.unlink()
    result = "pass" if rc == 0 else "FAIL"
    tmp = sd / f"post-apply.last.{os.getpid()}"
    tmp.write_text(f"{now} {tree or 'dirty'} {result} {logpath}\n")
    os.replace(tmp, sd / "post-apply.last")
    if rc == 0:
        return 0
    _, suites = failures(read_log(logpath))
    what = ", ".join(suites) or (f"none ran ({refusal})" if refusal else "unknown")
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    alert = Path(base) / "dotfiles" / "alert"
    if alert.is_file() and os.access(alert, os.X_OK):
        try:
            subprocess.run([str(alert), f"dotfiles post-apply: suites failed after the apply: {what};"
                            f" log: {logpath}"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except OSError:
            pass
    return 1


def main(argv: list) -> int:
    if argv == ["pre"]:
        return pre()
    if argv == ["post"]:
        return post_detach()
    if argv == ["post", "--run"]:
        return post_run()
    print("usage: apply-suites.py pre | post [--run]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
