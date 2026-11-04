---
name: canonical-takeover
description: Use when taking over, launching, relaunching, refreshing, resuming or closing a canonical session — running `fleet-canonicals up`/`down` (or `start`/`stop`)/`refresh`/`resume`/`dedupe`/`status`/`list`, declaring or changing a canonical in the fleet record (`canonical`, `canonicalLaunchModel`, `canonicalLaunchDir`, `canonicalIdentity`, `canonicalMachines`), choosing a canonical's model, or when a canonical name resolves to the wrong session, a stale duplicate row appears in the agents view, a canonical is missing on a machine that should run it, or a session comes up on an unexpected model. Covers how a launch is composed from the record, why the model is declared rather than inherited, how a launch resolves its handoff through a pointer, the handoff freshness gate on `down` and `refresh`, the verify-the-name-landed step, and why opening a stale row silently resumes it.
---

# Canonical takeover, launch and lifecycle

Terms used below:

- **Canonical:** a long-lived, named Claude Code background session (`claude --bg`) that owns one
  project. Its identity is its **name**, not a process: whoever holds the name inherits the project,
  its authority, and anything queued to it.
- **Fleet record:** the per-repository manifest (a `mani.yaml`, default `~/Devel/mani.yaml`,
  overridden by `FLEET_RECORD`) whose `canonical*` keys declare each canonical. Base `fleet-decl`
  reads it; `fleet-canonicals` launches from it.
- **Handoff and pointer:** the dated file a successor reads first, and the per-canonical record of
  which one that is. Skill `parking-and-handoff` covers writing and recording them.
- **Hub:** a canonical that coordinates across projects; a setup may have none. **The human:** the
  person who decides.

Which canonicals exist is resolved when needed, never carried as a list that can drift:
`fleet-canonicals list` (every declared canonical, what it owns, where it runs) and
`fleet-canonicals status` (one line per canonical expected on this machine; exit 0 only if all are
up). `CANONICAL_ROSTER`, when set, names a file of expected names that overrides the record's.

## Declaring a canonical

Each canonical's project in the record declares:

| key | meaning |
| --- | --- |
| `canonical` | the session name; unique across the record |
| `canonicalIdentity` | the phrase after "You are <name>," in the launch prompt |
| `canonicalLaunchDir` | the launch directory, relative to `FLEET_ROOT` (default `~/Devel`) |
| `canonicalLaunchModel` | the `--model` value |
| `canonicalMachines` | the machines it runs on, each as `hostname` prints it |

`fleet-decl --check` reports a canonical declared incompletely. **"This machine" is the output of
`hostname`, matched whole and case-sensitively**, not an SSH alias or a label. Run `hostname` on the
machine before declaring it: a name that does not match makes the canonical silently unexpected
there, and `up` never launches it. A canonical's directory, name or model changes in the record,
never at a park.

## What a launch runs

`fleet-canonicals` composes every launch from the record; nothing per repository stores one. The
equivalent by hand, which is also the fallback when the tool is unavailable:

```bash
cd "$FLEET_ROOT/<canonicalLaunchDir>"
handoff=$(fleet-canonicals handoff <name>)
claude --bg -n <name> --model <canonicalLaunchModel> \
  "This session is <name>, <canonicalIdentity>. The previous session's handoff is at $handoff: read it first and resume the work it describes. Reply with one line confirming you have resumed, then begin."
```

`-n` sets the name at launch, so no rename step follows. Typed by hand, the prompt is a shell
argument: keep it to this one line.

**No handoff path is stored in the record, and that is the point.** What changes between parks is
the handoff, and it is resolved through the pointer at launch, so a launch never quietly aims at a
path written down for an earlier sitting. A missing pointer, or one whose file is gone, launches
nothing: `up` prints `REFUSED <name>` with the reason (on `--dry-run` too), and `refresh` and `down`
refuse before stopping the session, `--force` included. Only `--stub`, which writes a new handoff,
gets past it. Read the pointer back after recording it all the same.

**The model is declared, never inherited.** A launch with no `--model` inherits the account's saved
default, and running `/model` in any session and confirming the pick writes the `model` key into
`~/.claude/settings.json` for every session started afterwards. One interactive switch made for a
throwaway session would re-tier every canonical launched after it. `--model` overrides the default
for that session only, which is why the tool always passes `canonicalLaunchModel`. Change a tier
there, not with `/model`. Which tier is the domain's model policy, where its always-on rules set
one. Prefer an alias (`opus`, `sonnet`, a context-qualified form such as `opus[1m]`) to a dated id.

## Takeover procedure

1. **The outgoing session parks**, ending its handoff with a kickoff block (skill
   `parking-and-handoff`). Step 2 is what that block's user-steps half asks the human to run.
2. **The human runs `fleet-canonicals refresh <name>`**, from a plain terminal, another session or
   the agents view. A session runs it only outside its Bash sandbox: a launch creates a job
   directory under `~/.claude` that sandboxed Bash cannot write (`docs/reference/fleet-sessions.md`
   in the base's checkout, `chezmoi source-path`, section "Sandbox and permissions"). It pre-flights
   the declared launch before stopping anything (a name it cannot start is a name it will not stop),
   stops the outgoing session, verifies between the halves that its row really went away, then
   launches. That check is what prevents the stale duplicate row a bare launch leaves behind. A name that is not running is simply launched.

   **It refuses inside the target session.** Run there, it would die at the stop, the relaunch
   would never run, and the harness would respawn the killed worker with `--resume`: the same
   session back, start time rewritten, reporting OK, having refreshed nothing. So the outgoing
   canonical cannot refresh itself.
3. **Names resolve newest-wins**, so the new session takes over the address and inherits anything
   queued to it.
4. **The new session verifies it holds the name before acting under it**: `ListAgents` where
   cross-session tools exist, otherwise `fleet-canonicals status` or `claude agents --json`. Inside
   a sandbox that cannot reach Claude Code's session service, both of those can show the session
   missing while it runs; where they do, ask the human to confirm from a terminal rather than
   concluding the launch failed.
5. **The outgoing session is closed once the successor is confirmed**, not before; `refresh` does
   this itself, and `dedupe <name>` clears a leftover (skill `parking-and-handoff`, "Closing the
   outgoing session").

**Fallback:** `/rename <name>` turns a session already running (one not launched with `-n`) into a
canonical, with the same newest-wins addressing and the same verify step.

## The handoff freshness gate

`down <name>` and `refresh <name>` refuse to end the session holding a name unless its pointer was
recorded **after that session started**. A pointer older than the session it replaces cannot
describe that session's work, and the successor would read it as current. Two escape hatches, which
are opposites; give at most one:

- `--stub [reason]`: the **handoff** is wrong, nothing was written for this sitting. Replaces the
  pointer with a generated "nothing to inherit" note. Destructive if a good handoff exists.
- `--force [reason]`: the **comparison** is wrong, the recorded handoff does describe this sitting.
  Keeps the pointer and skips the check. The usual cause, a session resumed after it parked, is now
  detected from the transcript, so this should be rare.

## Other lifecycle verbs

**These are the human's, run from a terminal; a session names the command and does not run it.**
Each acts on the list of live sessions, and inside a session's sandbox that list can be wrong: on a
machine whose sandbox could not reach the session service, every other session read as stopped, so
`up` would duplicate them and `clean` would remove their scratch roots (the base's
`docs/reference/fleet-sessions.md`, "Sandbox and permissions").

- `up [--dry-run] [name...]`: launch missing canonicals as declared. An unknown name is refused, not
  treated as "no filter".
- `down [--dry-run] <name>... | --all`: stop and delete the rows (transcripts kept, so resumable).
- `dedupe [--dry-run] [<name>]`: one session per name, keeping the newest.
- `resume <name> [--dry-run]`: bring a canonical back **from its own transcript** when it was never
  parked (its handoff predates the work), then close the row it forked from. When it did park, use
  `refresh`, which reads the handoff.
- The scratch directories each launch creates are removed by `down`, `refresh` and `dedupe`; where
  no cleanup hook runs, `fleet-canonicals clean` sweeps the ones whose session is gone (run
  `--dry-run` first; it keeps anything it cannot prove orphaned).

**Never open a stale row to find out whether it is live.** Opening a listed row resumes that session,
which re-registers it under the canonical name with a rewritten start time: it then looks like a
fresh launch in `status` while carrying old context and having resolved no handoff. Compare
`fleet-canonicals status` against the id you expect, or check the transcript's size and birth time.

## Messaging

Addressing peers, what to send to whom, when not to send at all, and how to coordinate where no
cross-session messaging exists: skill `fleet-messaging`.

---

If `~/.dotlocal/skills/canonical-takeover.md` exists, read it: it is this domain's half (where the
record lives here, the machines, the model policy, and the dated incidents behind the rules). If it
does not, the generic content above is the whole picture.
