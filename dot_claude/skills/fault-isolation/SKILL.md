---
name: fault-isolation
description: Use when something is slow, broken, unreachable or intermittent and the layer at fault is not yet established — "X is slow", "can't reach Y", "it works from here but not there", "this worked yesterday", a timeout, a hang, a connection refused, a failed push, a performance gate that regressed with no code change. Also use before believing any single measurement that localises a fault. Covers the rung order (process → host → link → LAN → WAN → remote service), the one cheap command and explicit discriminator per rung, and — most importantly — which rungs are STRUCTURALLY BLIND from which context, so a session does not produce a confident wrong answer from a place that cannot see the fault.
---

# Fault isolation

**Localise before diagnosing.** Every incident behind this skill was eventually localised by improvising
a different sequence of checks from scratch, and several were chased at the wrong layer first — for
days, in one case. The cost is never the check; it is picking the wrong layer and then explaining
evidence away.

**The deliverable of each rung is a DISCRIMINATOR, not a reading.** A number that cannot change your
mind about which layer is at fault has told you nothing, however true it is.

## 0. Before the ladder: is it the INVOCATION?

Ask this first, always, because it is the cheapest and it invalidates everything below it.

- **Was the command wrapped?** A pipe, a redirect, a `;` compound or a wrapper script can change the
  environment a command runs in. Where the agent harness keeps a list of commands excluded from its
  sandbox, that silently moves a command from unsandboxed to sandboxed, and the resulting failure
  **names the remote host**, so it reads as the host being down.
  **An excluded command escapes the sandbox only when it runs ALONE**: no `;` or `&&` chain, no
  `$(…)` in its arguments, and no environment prefix (`export X=1; cmd` or `X=1 cmd`). Three instances
  of it: a chained `git worktree remove`, a chained CI-trigger command ("Network is unreachable" for
  the remote node), and `export NX_DAEMON=false; npx nx run …:serve` (served inside a network
  namespace, so the browser could not reach it, and the session concluded serving was impossible).
  The live list is `sandbox.excludedCommands` in `~/.claude/settings.json`; read it, do not guess it.
- **Is this the same context the claim is about?** Interactive vs non-interactive shell, login vs not,
  agent sandbox vs your terminal, user session vs a systemd unit. A `PATH` or `SSH_AUTH_SOCK` that
  exists in one does not exist in the other.
- **Is the tool the current build?** A stale deployed copy fails in ways its source cannot explain.

If any of these is unresolved, stop. You are debugging the harness, not the system.

**Arch's command-not-found message is not evidence the binary exists.** For a missing command it
prints the package that WOULD provide it and the path it WOULD install to (`extra/pnpm ...
/usr/bin/pnpm`), which reads like "present but not on PATH". Sessions have chased a PATH bug that
way. Settle it with `command -v <cmd>` and `ls -l <path>` before theorizing.

## The ladder

Work down. Stop at the first rung that discriminates — and record which rung answered, because that
is the finding, not the symptom.

| # | Rung | One cheap command | Discriminator — what tells you it IS or ISN'T this layer |
|---|---|---|---|
| 1 | **Process** | re-run it bare, alone, in the foreground | Behaves differently unwrapped → it was rung 0, not a fault |
| 2 | **Host** | `uptime`; `systemctl --failed`; `df -h /` `/tmp` | A unit latched `failed`, a full filesystem, or **uptime past ~30 days** — all three cause "network" symptoms |
| 3 | **Link** | `ping -c 20 <default-gateway>` | **The DISTRIBUTION, not the loss.** The incidents behind this skill ran at **0% packet loss**; the signal was baseline ~3 ms with bursts past 2000 ms. A mean hides it; a loss figure hides it completely |
| 4 | **LAN** | the same ping from a DIFFERENT host on the same segment | Both bad → LAN or uplink. One bad → that host's own link (and note wired vs wireless differ) |
| 5 | **WAN** | ping/curl something outside, from a host proven good at rung 4 | Isolates house-side from provider-side |
| 6 | **Remote service** | hit the service directly, bypassing whatever wraps it | Distinguishes "the service is down" from "our path to it is" |

**Rung 2 deserves more respect than it gets.** Two separate incidents were long-uptime
degradation that presented as *"the internet is slow"* and *"the website is slow"* — one an access
point, one a server, each after roughly seven weeks up — and both were cleared by a restart. *"How long has this been up?"* is the
cheapest question on the ladder and it has the best hit rate.

## Which rungs are BLIND from where you are standing

This is the part that cannot be automated and the reason this is a skill rather than a tool. A rung
you cannot observe from your context does not return "fine" — it returns nothing, or it returns a
fact about your probe. Both read as "fine".

| Context | Can answer | CANNOT answer, and will mislead you |
|---|---|---|
| Agent Bash sandbox | rungs 0-2 for the local box | **Rungs 3-6: there is no route at all.** `ping`/`ssh` fail identically to a dead host. The PID namespace is also isolated, so `ps` cannot see the real process tree |
| SSH into a box | most rungs for THAT box | Anything needing a GUI session — a consent dialog, a keychain prompt — is invisible, not absent |
| A systemd unit / scheduled job | what its own environment provides | The user's `PATH`, agent socket and session are absent unless explicitly set. A row that answers by hand can ERROR here for that reason alone |
| A check running ON the box | the box's current state | **"The box was never up."** A local check cannot observe its own absence — that needs an external dead-man's switch |

**Two agent-sandbox facts that masquerade as facts about the machine:**

- **Each Bash call gets its own network namespace.** A server started in one call keeps running,
  but its socket is unreachable from the next call: `curl` returns 000 and `ss` shows nothing while
  `pgrep` still finds the process. Serve and probe inside ONE call. Comparing
  `readlink /proc/self/ns/net` across calls is a false negative, because namespace ids are inode
  numbers and get recycled; only behaviour discriminates. Before blaming the sandbox, check the
  bind address with `ss -ltn`: a dev server bound to `[::1]` only answers on `localhost`, not
  `127.0.0.1`, even unsandboxed. Also: `pkill -f 'pattern'` matches its own command line and kills
  the calling shell; use the bracket trick, `pkill -f '[h]ttp.server 8765'`.
- **The sandbox bind-mounts `/dev/null` over masked config paths in a repo** (`.bashrc`,
  `.gitconfig`, `.claude/agents`, and about twenty more), so `git status --porcelain` lists them as
  untracked on a clean tree. They are character devices (`ls -l` shows `c`), not files. `git add -A`
  fails on them with rc=128, so stage explicit paths; a dirty-tree check must use `-uno`. Do not
  "clean them up" from inside a session: on disk each is an empty read-only placeholder that the
  sandbox creates for one command and deletes after it, and removing one another session is using
  breaks that session's next command. A session killed mid-command leaves its placeholders behind
  for good; the human sweeps those from a terminal with `claude-mask-sweep`, which keeps any a
  running session has mounted. `test -w` calls such a path writable (mode 666), so it cannot
  detect the mask.
- **`fatal: Unable to create '.../index.lock': Read-only file system` is not the signing lock.** It comes
  through the same `git` wrapper and reads like a key failure, but unlocking does nothing: the repo's
  bare container is missing from the sandbox's `allowWrite`. Adding that path is permission config, so it
  needs explicit consent from whoever owns the settings.
- **A command listed in `sandbox.excludedCommands` (for example `nx serve`) runs in the host network**,
  so a human browser reaches it; a sandboxed call still cannot. The per-call PID namespace also recycles
  small PIDs, so an uncleanly killed Nx task can leave a stale row that makes the next run report
  "Recursive task invocation detected". Clear it when no Nx is running:
  `sqlite3 .nx/workspace-data/*-v3.db "delete from task_invocations;"`.
- **A path can be read-only to the shell but not to the harness.** Where the sandbox denies shell
  writes to a directory, the `Edit`/`Write` tools may still succeed on the same files. So any
  shell-based writer (a hook, a maintenance script, a heredoc append) fails there, and one that
  swallows errors (`2>/dev/null`, `|| true`) fails silently and records nothing.

**So: before reporting "I found nothing", ask whether you could have seen it from here.** State the
limit rather than implying the stronger claim.

## Standing traps, each earned

- **0% loss is not a healthy link.** See rung 3. Loss is the wrong statistic for this failure mode.
- **A post-restart green is not a controlled comparison.** The machine state changed between the arms.
  It establishes *not present right now*, never *fixed*. If a reboot cleared it, the mechanism is still
  unidentified — say so.
- **A probe that cannot reproduce the failure has not exonerated anything.** Establish the probe CAN
  detect the failure mode before believing a negative — ideally by making it fail on purpose.
- **A tool one version behind fails in ways its source cannot explain.** Check the deployed artifact
  matches its declaration before debugging its behaviour.
- **Stop at the named exception.** When a diagnosis has a standing rule in the operator's own
  instructions (a cause already settled by policy), follow the rule instead of investigating. Rediscovering a settled
  cause is noise, and the rule exists because it was rediscovered too many times.

## Related skills — do not restate them here

- A command that behaves differently than written: **`writing-zsh-commands`**.
- A tool that works on one machine and not the other: **`cross-platform-tooling`**.

---

If `~/.dotlocal/skills/fault-isolation.md` exists, read it: it is this domain's half (the hosts and
links the ladder runs over, the dated incidents, and the related skills specific to this domain). If
it does not, the generic content above is the whole picture.
