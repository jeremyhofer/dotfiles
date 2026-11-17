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

NODE COMES FROM THE REPOSITORY'S PIN. Nx is a repository dependency (package.json), run under the
Node the repository pins. The pin is `[tools] node` in mise.toml, else .nvmrc while that file still
exists; with both present they must agree, or the apply is refused naming both values. A mise.toml
with no `[tools] node` leaves the pin to .nvmrc. Reading mise.toml needs tomllib (Python 3.11): under
an older python3 a repository with a mise.toml refuses the apply, naming the fix. The pin is then
selected by the first of these that applies:
  * where mise is active (DOTFILES_MISE_SHIMS set and not empty, which the base exports only on a
    machine whose chezmoi data sets miseActive) and `mise` is on PATH, every Node command runs as
    `mise exec node@<pin> --`, with mise's installing and network access switched off; a version
    mise has not installed refuses the apply, naming `mise install node@<pin>`;
  * with `fnm` on PATH, every Node command runs as `fnm exec --using=<pin>`; a version fnm has not
    installed refuses the apply, naming `fnm install <version>`;
  * otherwise the `node` on PATH is used only if its major version is the pin's; otherwise, or
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

UV RUNS OFFLINE. Nx runs each suite through tests/run-all.sh, which sets UV_OFFLINE=1 (a value the
caller set stays), and nx_env sets it too, so a uv-script suite takes its packages from uv's cache.
Both `pre` and `post --run` first run tests/seed-uv-cache.py, with the network, to fill that cache;
a seed that fails is logged and the suites go ahead on what is cached.

NX'S ENVIRONMENT. NX_DAEMON=false and NX_ISOLATE_PLUGINS=false, so Nx opens no socket: inside a
sandbox no socket directory passes Nx's ownership walk (from Nx 24.0.3), and plugin workers need a
socket as much as the daemon does. NX_TUI=false and --outputStyle=static, so the log is plain lines.
NX_PARALLEL, unless the caller set it, is the CPU count up to 8, the concurrency tests/run-all.sh
uses, so a cold apply is no slower than the runner it replaced.

THE LEDGER. Every step below also appends a line to the machine's apply ledger,
${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/apply.log, through the SOURCE copy of the
apply-status tool (private_dot_local/bin/executable_apply-status, run with this Python: the first
apply that ships the tool has no installed copy), so a session that cannot watch the terminal can
read what happened. The tool owns the line format and the event names. The lines are written with
the tool's --hook flag, which reads chezmoi's own CHEZMOI and CHEZMOI_ARGS: a dry run
(`chezmoi apply -n`, `--dry-run`) is recorded as `dry-run`, and a hook script run by hand (no
CHEZMOI) as `by-hand`, each with the real event in its detail, and `apply-status` ignores both.
`post --run` records the head from BEFORE its run, not after. `pre` writes `start` first,
before any skip check, then `skipped` (with the reason) on each skip path, or `refused` (naming the
failing suites and the report) when it aborts the apply. `post` writes `deployed` before it
detaches, also on its skip paths, since the apply did deploy; `post --run` writes `post-start` as it begins (before any suite, so `apply-status` can tell a run
that is still going from one that died), then `post-pass` or
`post-FAIL` (naming the failing suites and the log) when its run ends. A ledger failure of any kind
is ignored here: it never changes a hook's exit code.

SKIPS, loudly and with exit 0:
  * DOTFILES_SKIP_PRE_APPLY=1 (`pre`) or DOTFILES_SKIP_POST_APPLY=1 (`post`): for the apply a suite
    itself depends on, which cannot pass before that apply deploys what the suite needs;
  * a tool the suites need is not installed: on a fresh machine's first apply the tools arrive with
    or after that apply, and refusing it would leave the machine unable to bootstrap.
Missing or mismatched Node is not a skip: Node is needed only to run the suites, so a machine with
the other tools and no usable Node would otherwise apply untested every time.

A REFUSAL IS KEPT AND ANNOUNCED. `pre`'s report is moved from the temp directory into
${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/pre-apply-<utc time>.log (the newest 5 are kept, apart
from the post logs), and the path printed and recorded is that one, so it survives a reboot. The
alert hook (below) is also called, with a message beginning `dotfiles pre-apply: apply REFUSED: `
that names the failing suites and the report: the refusal is the case a person is not watching.
The alert hook is started detached and never waited for, here and after a post failure.

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
  apply.log                   the ledger, shared with `pre` and the private layer's hooks
On a failure ${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/alert, when it is an executable file, is run
with one argument naming the failing suites and the log (the same hook, with its own message, on a
`pre` refusal). This base knows no notification service; a private layer supplies the file. A
failing alert hook is ignored: the status file and the ledger hold the result.

Exit: `pre` 0 the suites passed, or skipped; 1 a suite failed or the suites could not be run (the
apply is aborted; the ledger and alert never change this). `post` 0 always. `post --run` 0 a pass (or another run holds the lock), 1 a failure.

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
LEDGER_TOOL = SRC / "private_dot_local" / "bin" / "executable_apply-status"
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


class Refused(Exception):
    """The suites cannot be run; the message names why and the fix."""


def say(tag: str, msg: str) -> None:
    print(f"dotfiles {tag}: {msg}", file=sys.stderr, flush=True)


def hook_env() -> dict:
    return {k: v for k, v in os.environ.items() if not k.startswith("CHEZMOI")}


def ledger(event: str, detail: str = "", head: str = "") -> None:
    """Append one ledger line through the source copy of apply-status. Never raises, never changes
    a hook's exit code: a ledger that cannot be written costs a line on stderr and nothing else.
    `--hook` makes the tool read chezmoi's own CHEZMOI and CHEZMOI_ARGS (so this runs with the
    whole environment, not hook_env's): a dry run or a hand run is recorded as such, not as an apply."""
    cmd = [sys.executable, str(LEDGER_TOOL), "append", "--source", str(SRC), "--hook"]
    if head:
        cmd += ["--head", head]
    try:
        subprocess.run(cmd + ["base", event, detail], env=dict(os.environ), stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, timeout=120)
    except Exception as e:  # noqa: BLE001 -- a ledger problem must never abort an apply
        say("apply-status", f"the ledger line {event!r} was not written ({e})")


def source_head() -> str:
    """The head string the ledger would record now ("" when the tool cannot say)."""
    try:
        out = subprocess.run([sys.executable, str(LEDGER_TOOL), "head", str(SRC)], env=hook_env(),
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             universal_newlines=True, timeout=60)
    except Exception:  # noqa: BLE001
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def alert_hook(message: str) -> None:
    """Start the machine's alert hook with one message, when it is an executable file, and do not
    wait for it: a slow notifier (fleet-notify's retries on a degraded link take about 90 s) must not
    hold up a refused apply or the chain behind it. Detached, no descriptors, its failure ignored."""
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    alert = Path(base) / "dotfiles" / "alert"
    if alert.is_file() and os.access(alert, os.X_OK):
        try:
            subprocess.Popen([str(alert), message], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        except OSError:
            pass


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


def pin_value(value, where: str) -> str:
    """A pin as written, checked to be a version number, without a leading `v`."""
    if not isinstance(value, str):
        raise Refused(f"{where} holds {value!r}, not a version number")
    want = value.strip()
    want = want[1:] if want.startswith("v") else want
    if not re.fullmatch(r"\d+(\.\d+){0,2}", want):
        raise Refused(f"{where} holds {want!r}, not a version number")
    return want


def node_pin() -> tuple:
    """(pin, file): the Node version the repository pins, and the name of the file it came from.
    mise.toml's `[tools] node` first, .nvmrc while it still exists; both present must agree."""
    toml_path, nvmrc_path = SRC / "mise.toml", SRC / ".nvmrc"
    from_toml = None
    if toml_path.exists():
        try:
            import tomllib  # Python 3.11; imported here so a repository without mise.toml needs none
        except ImportError:
            raise Refused(f"{toml_path} cannot be read by this python3 ({sys.version.split()[0]}), "
                          f"which has no tomllib. Put Python 3.11 or later first on PATH, then apply again")
        try:
            data = tomllib.loads(toml_path.read_text())
        except (OSError, ValueError) as e:
            raise Refused(f"{toml_path} cannot be read ({e}), so the Node the suites run under is unknown")
        tools = data.get("tools")
        if isinstance(tools, dict) and "node" in tools:
            from_toml = pin_value(tools["node"], "mise.toml's [tools] node")
    from_nvmrc = None
    if nvmrc_path.exists():
        try:
            from_nvmrc = pin_value(nvmrc_path.read_text(), ".nvmrc")
        except OSError:
            raise Refused(f"no readable {nvmrc_path}, so the Node the suites run under is unknown")
    if from_toml is not None and from_nvmrc is not None and from_toml != from_nvmrc:
        raise Refused(f"mise.toml pins Node {from_toml} but .nvmrc pins {from_nvmrc}, so the Node the "
                      f"suites run under is ambiguous. Make them agree, or delete .nvmrc, then apply again")
    if from_toml is not None:
        return from_toml, "mise.toml"
    if from_nvmrc is not None:
        return from_nvmrc, ".nvmrc"
    raise Refused(f"neither {toml_path} ([tools] node) nor {nvmrc_path} pins Node, so the Node the "
                  f"suites run under is unknown")


# Every mise command run from here: nothing installed, nothing fetched. Without them `mise exec`
# installs a missing version first (its exec_auto_install setting), and may ask the network which
# versions exist. They reach the suites too, where nothing should install either.
MISE_NO_INSTALL = {"MISE_EXEC_AUTO_INSTALL": "false", "MISE_AUTO_INSTALL": "false",
                   "MISE_NOT_FOUND_AUTO_INSTALL": "false", "MISE_OFFLINE": "1"}


def select_node(env: dict) -> tuple:
    """(prefix, description, env): the argv prefix that runs a Node command under the pinned
    version, what it is, and the environment to run it with."""
    want, source = node_pin()
    wanted = want.split(".")
    path = env.get("PATH", "")
    mise = shutil.which("mise", path=path) if env.get("DOTFILES_MISE_SHIMS") else None
    if mise:
        menv = dict(env, **MISE_NO_INSTALL)
        prefix = [mise, "exec", f"node@{want}", "--"]
        got = capture(prefix + ["node", "--version"], menv)
        # With installing off, mise runs a node from PATH for a version it lacks (with a warning),
        # so the version is checked, not only the exit status.
        if got is None or version_parts(got)[: len(wanted)] != wanted:
            raise Refused(f"Node {want} ({source}) is not installed in mise. Install it with "
                          f"`mise install node@{want}`, then apply again")
        return prefix, f"Node {got} via mise", menv
    fnm = shutil.which("fnm", path=path)
    if fnm:
        prefix = [fnm, "exec", f"--using={want}", "--"]
        got = capture(prefix + ["node", "--version"], env)
        if got is None or version_parts(got)[: len(wanted)] != wanted:
            raise Refused(f"Node {want} ({source}) is not installed in fnm. Install it with "
                          f"`fnm install {want}`, then apply again")
        return prefix, f"Node {got} via fnm", env
    node = shutil.which("node", path=path)
    if node is None:
        raise Refused(f"no fnm and no node on PATH. Install fnm (the Brewfile's, or the "
                      f"distribution's package) and run `fnm install {want}`, then apply again")
    got = capture([node, "--version"], env) or "an unreadable version"
    if version_parts(got)[:1] != wanted[:1]:
        raise Refused(f"the node on PATH ({node}) is {got}, but {source} pins {want}, major "
                      f"{wanted[0]}. Install fnm and run `fnm install {want}`, or put Node "
                      f"{wanted[0]} first on PATH, then apply again")
    return [], f"Node {got} from PATH (no fnm)", env


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


def seed_uv_cache(log) -> None:
    """Fill uv's cache for every uv-script suite (tests/seed-uv-cache.py, with the network): the
    suites then run offline. A failed seed is written to the log and goes no further, since a
    machine that is offline today may hold what the suites need already, and a suite that finds a
    package missing fails naming the seed command."""
    seed = HERE / "seed-uv-cache.py"
    log.write(f"apply-suites: {seed.name}\n")
    log.flush()
    try:
        rc = subprocess.run([sys.executable, str(seed), "--root", str(SRC)], stdin=subprocess.DEVNULL,
                            stdout=log, stderr=subprocess.STDOUT, env=hook_env(), timeout=1800).returncode
    except (OSError, subprocess.TimeoutExpired) as e:
        log.write(f"apply-suites: uv cache seeding did not run ({e})\n")
        return
    if rc != 0:
        log.write(f"apply-suites: uv cache seeding failed (exit {rc}); the suites go ahead on what is cached\n")
    log.flush()


def nx_env(env: dict) -> dict:
    out = dict(env)
    out["NX_DAEMON"] = "false"
    out["NX_ISOLATE_PLUGINS"] = "false"
    out["NX_TUI"] = "false"
    # The suites run offline against uv's cache (tests/seed-uv-cache.py fills it); a UV_OFFLINE the
    # caller set is kept.
    out.setdefault("UV_OFFLINE", "1")
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

def keep_report(logpath: Path) -> Path:
    """Move a refusal's report from the temp directory into the state directory, keeping the newest
    KEEP_LOGS; the path to quote. The report stays where it is when it cannot be moved."""
    sd = state_dir()
    dest = sd / ("pre-apply-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + ".log")
    try:
        sd.mkdir(parents=True, exist_ok=True)
        shutil.move(str(logpath), str(dest))
        for old in sorted(sd.glob("pre-apply-*.log"), reverse=True)[KEEP_LOGS:]:
            old.unlink()
    except OSError:
        return logpath if logpath.exists() else dest
    return dest


def refuse(what: str, report: Path | None) -> None:
    """Record a refusal in the ledger and announce it through the alert hook."""
    tail = f"; report: {report}" if report else ""
    ledger("refused", f"{what}{tail}")
    alert_hook(f"dotfiles pre-apply: apply REFUSED: {what}{tail}")


def pre() -> int:
    ledger("start")
    if os.environ.get("DOTFILES_SKIP_PRE_APPLY") == "1":
        say("pre-apply", "SKIPPED by DOTFILES_SKIP_PRE_APPLY=1; the apply goes ahead untested.")
        ledger("skipped", "DOTFILES_SKIP_PRE_APPLY=1")
        return 0
    env = hook_env()
    missing = missing_tools(env)
    if missing:
        say("pre-apply", "suites SKIPPED, not installed: " + " ".join(missing)
            + ". The apply goes ahead untested;\n  install them (the Brewfile, or the distribution"
            " packages) and the next apply runs the suites.")
        ledger("skipped", "suites tools not installed: " + " ".join(missing))
        return 0
    tmp = os.environ.get("TMPDIR") or "/tmp"
    try:
        fd, name = tempfile.mkstemp(prefix="dotfiles-pre-apply.", dir=tmp)
    except OSError:
        say("pre-apply", "no temp file for the log; apply refused")
        refuse("none ran (no temp file for the log)", None)
        return 1
    logpath = Path(name)
    with os.fdopen(fd, "w") as log:
        try:
            prefix, node, env = select_node(env)
            installed = ensure_install(prefix, env, log)
            seed_uv_cache(log)
            say("pre-apply", f"running the suites through Nx ({node}; {installed}); a suite whose"
                " inputs are unchanged replays from Nx's cache...")
            rc = run_nx(prefix, env, [], log)
        except Refused as e:
            log.write(f"apply-suites: refused: {e}\n")
            log.flush()
            logpath = keep_report(logpath)
            say("pre-apply", f"{e}.\n  Apply ABORTED, nothing was deployed. Setup output: {logpath}")
            refuse(f"none ran ({e})", logpath)
            return 1
    lines = read_log(logpath)
    if rc == 0:
        say("pre-apply", nx_summary(lines))
        logpath.unlink()
        return 0
    shown, suites = failures(lines)
    logpath = keep_report(logpath)
    print("", file=sys.stderr)
    say("pre-apply", "a suite failed -- apply ABORTED, nothing was deployed:")
    for ln in shown or lines[-15:]:
        print("  " + ln, file=sys.stderr)
    print(f"\n  why, in full: {logpath}", file=sys.stderr)
    for s in suites:
        print(f"  re-run one:   sh {HERE}/run-all.sh --only {s}", file=sys.stderr)
    refuse("suites failed: " + (", ".join(suites) or "none named, see the report"), logpath)
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
    ledger("deployed")
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
    head = source_head()
    ledger("post-start", "", head)
    logpath = sd / ("post-apply-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + ".log")
    with open(logpath, "w") as log:
        try:
            prefix, node, env = select_node(env)
            log.write(f"apply-suites: {node}; {ensure_install(prefix, env, log)}\n")
            seed_uv_cache(log)
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
        ledger("post-pass", f"log: {logpath}", head)
        return 0
    _, suites = failures(read_log(logpath))
    what = ", ".join(suites) or (f"none ran ({refusal})" if refusal else "unknown")
    ledger("post-FAIL", f"suites: {what}; log: {logpath}", head)
    alert_hook(f"dotfiles post-apply: suites failed after the apply: {what}; log: {logpath}")
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
