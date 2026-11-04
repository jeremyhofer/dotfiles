---
name: parking-and-handoff
description: Use when a session is stopping, pausing, handing over, or being recycled — on any pause/stop/bedtime signal, when a usage ramp-down warning or gate fires, when writing or refreshing a dated handoff, when staging, placing or recording a canonical's handoff pointer, or when arming a resume for after a usage window resets. Also fires on "park", "wrap up", "checkpoint", "hand over", "recycle this session", `fleet-canonicals stage`, `place`, `handoff --set`, `wait-for-reset`, `resume-at`. Covers the five park steps and which two are conditional, the audit of subagents and background jobs a park must enumerate and ask about rather than silently kill or silently abandon, why most pauses are checkpoints rather than parks, where the handoff file goes and how the pointer is recorded, closing the outgoing session, and the timestamp and kickoff-block shape a successor reads.
---

# Parking, checkpointing and handoff

Terms used below:

- **Canonical:** a long-lived, named Claude Code background session that owns one project. The name
  is the role: whoever holds it inherits the project and anything queued to it. Canonicals are
  declared in the fleet record (a `mani.yaml` read by `fleet-decl`) and launched by
  `fleet-canonicals`; skill `canonical-takeover` covers the launch side.
- **Hub:** a canonical that coordinates across projects and, in most setups, owns the repository
  handoffs are committed to. A setup may have none.
- **Handoff:** a dated markdown file that tells a cold successor session what it needs to continue.
- **Pointer:** the per-canonical record of which handoff the next launch reads.
  `fleet-canonicals handoff <name>` prints it; `--set <path>` records it.
- **Park:** ending a session so a successor takes over. **Checkpoint:** preserving the work while the
  same session continues. Most pauses are checkpoints (see below).
- **The human:** the person who decides. Only they approve.

## When this runs, and what outranks it

A pause, stop or end-of-day signal from the human, or a usage threshold. Where the domain has a
ramp-down hook, it injects these steps at the threshold. Where hooks are barred or absent, nothing
will interrupt you: watch your own usage on the status line, or let the human say when.

**A pause outranks everything else the session is doing**: autonomous defaults, escalation, being
exhaustive. If your domain's always-on rules give a fuller precedence order, that order is
canonical. The rule is "never impede wrapping up", not "never compact": a `/compact` or trim the
human asks for stays allowed at any threshold.

## The five steps

Steps 1, 1b, 2 and 4 are **unconditional**: they apply at a checkpoint as much as at a park. Steps 3
and 5 are **recycling** steps, taken only when a successor will actually read the handoff.

1. **Finish or cleanly abort the unit in flight, fast.** Start nothing new, not even a fix a review
   just surfaced; write it down as a one-line next-session item instead.

   **Leave any worktree this session entered.** A canonical parks from its primary checkout, the
   directory its declared launch starts in (`canonicalLaunchDir`), never from a worktree it entered
   mid-session. Decide the worktree's fate now: merge it if the branch is done (skill
   `working-in-worktrees`), or keep it and say so in the handoff, then `ExitWorktree` either way.
   Left undecided, the stop makes the decision and can fail doing it (see "A worktree wedges the
   stop" below).

   **Audit what this session leaves running, report it, and ask.** From inside the session, work in
   flight and leftover residue look the same and have opposite right answers, so a park never
   decides their fate silently. List, briefly:

   - **Subagents this session spawned.** Where `ListAgents` exists it lists them, along with peer
     sessions, which are not yours to stop.
   - **Background jobs this session started** (`run_in_background`, `Workflow`). You issued them and
     hold their ids, so this is something you know, not something to discover.
   - **Work dispatched to a peer** that is still expected to report back.

   Mark each as meaningful work or residue, and ask. The decision procedure:

   - At a natural stopping point, kill it: nobody is waiting for its result.
   - Transitive or already-orphaned leftovers are residue: kill them.
   - Meaningful work still going, when the park only protects the main session against a usage
     limit: let it run. Killing it spends finished work to save nothing.

   **State the audit's limit.** Under the Bash sandbox the PID namespace is isolated, so `ps` sees
   only the sandbox and a session cannot enumerate its own OS descendants. The list is what the
   session started, not proof that the machine is quiet; say so. The failure this step prevents is
   silence, not blindness: a job the session knew about, left unreported, whose completion later
   re-invokes the parked session at a moment nobody chose.

1b. **Sweep for loose ends and give each a durable home.** Walk the whole session, not its last
   hour: unanswered questions, findings from you, a reviewer or a peer, promises made, "later"
   items, unverified claims, changes committed but not yet applied on every machine that consumes
   them, replies you owe. Each goes to the work tracker, a decision record, a committed file, or the
   handoff's open list. **Nothing lives only in chat**, because the successor never sees the chat.
   This sweep is the "no loose ends?" question, asked by the session before the human has to.

2. **Commit everything**, then push only where that repository's push policy allows (your domain's
   always-on rules or the repository's context file say which). Where the policy needs the human
   first, commit and stop there.

3. **Write or refresh a dated handoff, then record it as the pointer** (when recycling or handing
   over). See "Where the handoff goes" and "What a handoff contains" below. A pause that ends with
   the same session continuing does not need one: the commit preserved the work, a handoff preserves
   only orientation, and writing one spends the context the pause was meant to protect.

4. **Update the work-tracker entries you touched**, including the loose ends step 1b placed there.

5. **Stop** (when recycling or handing over). Open no new threads. Do not `/compact` at high context
   fill: a compaction costs about one full-history request and is cheap only at roughly 60% fill or
   less with a warm cache. At high fill, a fresh session beats compacting.

## Checkpointing is not parking, and most pauses are checkpoints

Running all five steps on every pause assumes a pause ends the session. Usually it does not:
sessions survive for days and rarely approach a full context window. **Commit is the step that
matters**; it is cheap, preserves the actual work, and makes any stop safe.

- A usage window, a break, the end of a working day: **checkpoint**. Finish, commit, update the
  tracker, start nothing new, leave the session up.
- A deliberate recycle or a handover: **park**. All five steps, because a successor will read the
  handoff.

The one thing that costs real headroom is an **idle gap longer than the prompt-cache lifetime**: the
next request rebuilds the cache at a premium, in proportion to context depth. That is a reason to
shed depth before a long gap, not a reason to write a handoff.

## Where the handoff goes

Handoffs are committed to a handoffs directory in one repository, so they are versioned and read
cold. The directory is the `handoffs` key of `fleet-canonicals`' configuration file
(`fleet-canonicals --help`, "configuration"). `docs/reference/fleet-sessions.md` in the base's
checkout (`chezmoi source-path`) is the full lifecycle, where every file lives, the sandbox entries
each role needs, and setting up a machine; this section is the part a parking session acts on.

First read the handoff you started from: `fleet-canonicals handoff <name>`. The new handoff names
its basename on a line in its first 15 lines, ``Supersedes `<basename>`.``, which keeps the chain
intact.

- **If you are the hub** (your shell can write the handoffs repository), write
  `<handoffs>/YYYY-MM-DD-HHMM-<name>-park.md` there, commit it, and record it:
  `fleet-canonicals handoff <name> --set <path>`.
- **Otherwise, stage it.** Write a draft wherever you can (`$TMPDIR` is fine: the tool copies it),
  then `fleet-canonicals stage <name> <draft> [--kind checkpoint]`. It copies the draft to
  `$FLEET_STATE/handoff-staging/YYYY-MM-DD-HHMM-<name>-park.md` (or `-checkpoint.md`) and records the
  pointer, so you never choose a path. It refuses a draft whose `Supersedes` line does not name the
  current handoff, printing the line to add, and never overwrites a staged file. Where the domain
  configures `stage-check`, it also runs the handoffs repository's commit gates on the draft and
  refuses with their findings: fix the draft and stage again, since nothing was staged. Staging needs your
  Bash sandbox to write `$FLEET_STATE` (default `~/.local/state/fleet-canonicals`), not the
  handoffs repository.
- **Placing** copies staged handoffs into the handoffs directory, and commits them there when
  `place-commit` is on (it never pushes): `fleet-canonicals place --dry-run`, then `place`, run by
  the hub, or on a machine where no hub runs, by whoever can write the repository there. It reads
  only this machine's staging. It places a handoff only when its predecessor is in the
  `handoffs-search` tree or placed in the same run (otherwise `BROKEN-CHAIN`), leaves files that are
  not a canonical's dated handoff for a judgment call (`NEEDS-JUDGMENT`), and repoints each pointer
  that named the staged copy. Then it removes each staging copy whose content is in a commit of its
  placed copy and that no pointer names; it keeps, and counts, any whose content is in no commit.
  **So do not edit your staged handoff after it is placed:** the edit reaches no commit, and the
  copy then sits in staging for the hub to judge.

**Placement is durability, not continuity, so the hub is not a prerequisite for parking.** `--set`
only checks that the target exists. A canonical parking while the hub is down or busy leaves its
pointer on the staging copy and parks normally; the successor resolves it and reads it. What lags is
only the committed copy, and `$FLEET_STATE` is machine-local and backed up nowhere, so **say in the
handoff that it is still staged**. `fleet-canonicals status` lists each one as `handoff UNPLACED`
until it is placed.

**A stub breaks the chain.** After `down` or `refresh` with `--stub`, the pointer names a generated
stub under `$FLEET_STATE/stub-handoffs/`, which is never placed. The next handoff must name the stub
as its predecessor, and `place` reports it `BROKEN-CHAIN`; the hub places it with
`place --accept-broken-chain` once the dry run shows the stub is the only gap.

**Do not use `Write` or `Edit` to reach a repository your Bash sandbox cannot write.** Those tools
can reach arbitrary absolute paths, because the sandbox covers only Bash and its children; that is
exactly why using them to get around it is wrong. The test is not "the gate let me" but "is this
the block the human intended".

**Cite every decision record with its log's prefix** (`ACME-ADR-0015`, not `ADR-0015`) when the
handoffs repository cites several decision logs. A bare number is ambiguous there; `doc-lint`'s
`bare-adr` check refuses it where the repository's `.doc-lint` declares `adr-owners:`, and with it
every other handoff in the same `place` run. A configured `stage-check` catches it at `stage`.

### Recording the pointer

The pointer is `$FLEET_STATE/<name>.handoff`: the handoff's absolute path, then a `# set-at <epoch>`
line. It lives **outside every git repository**, so a session whose guard refuses writes to its own
checkout can still record it. With no pointer, or one whose file is gone, a launch starts nothing:
`up` prints `REFUSED <name>` with the reason, on `--dry-run` too, and `refresh` refuses before
stopping anything. Read it back all the same.

- **Type the path. Never resolve it with a glob.** `--set` checks only existence, so a glob matching
  several handoffs records the wrong one and nothing complains. Then read it back with
  `fleet-canonicals handoff <name>` and confirm it is the file you meant.
- **After placement, the pointer must name the placed path with its original `# set-at` stamp.**
  `place` does this. Do not repoint by hand with `--set`, which restamps it: `down` and `refresh`
  compare the stamp to the holder session's start time, so a fresh stamp tells them a successor
  parked when it has not, and the next refresh recycles it with no handoff describing its work.
- **Re-set after editing your own handoff's content.** That is a new recording, so the fresh stamp
  is correct. The gate compares the stamp, not the file, with the session's start, so a handoff
  edited by a session that started after it was recorded still reads as older than that session,
  and the next relaunch is refused.

## What a handoff contains

### A time, not just a date

Sessions turn over in hours, so a date alone cannot tell "a previous session" from "a previous
day", and a successor reads it as the second. A handoff written half an hour earlier gets treated as
settled overnight.

1. **A header stamp** near the top, before anything else: `**Parked 2026-01-14 20:14 EST.**` It
   works on every machine, because it is text in a document with nothing to deploy.
2. **A time in the file name** of a new handoff, four-digit local `HHMM` after the date:
   `2026-01-14-2014-project-a-canonical-park.md`. It sorts chronologically, unlike adjective
   suffixes (`-evening` sorts before the plain name). `stage` names files this way already.
3. **Absolute times in the body**: "committed at 18:32", not "earlier". When citing another
   document, cite when it was written.

Do not rename existing handoffs to fit: they form a supersession chain and are pointer targets, and
a pointer validates only existence. Before describing a file's age, run
`git log -1 --format=%ci -- <path>`; a date stamp is evidence of when it was written, not of how
long ago that was.

### In-flight program state: required, and the most-omitted section

Before the tactical queue, state for every multi-phase program this canonical is executing or
gating: its **plan path**, the **phase now current**, what is **done and not done**, and the **next
gate**. One short table. A program is in flight if a plan exists and any phase is unfinished, not
only if it was touched this sitting. A handoff that lists only this sitting's work teaches the
successor that the sitting is the work; it then re-derives program state from disk, badly.

**The test:** a successor that reads only the handoff can say which phase of each live program it is
in and what the next gate is, without searching the tracker.

### The kickoff block

Every park handoff ends with a "Next session kickoff" block in two parts.

**(a) User steps:** what the human runs. Normally `fleet-canonicals refresh <name>`, which
pre-flights the declared launch, stops the outgoing session, checks its row cleared, and launches
the successor. It refuses inside the target session, so the parking canonical cannot run it; the
human does. The by-hand launch, if the tool is unavailable, is in skill `canonical-takeover`.

**(b) The prompt:** thin. Identity (which canonical this is), what to read first (the handoff,
resolved through the pointer, plus any plan it names), and the immediate task. Nothing else. The
launch composes this itself from the fleet record:

```
This session is <name>, <canonicalIdentity>. The previous session's handoff is at <handoff>: read it first and resume the work it describes. Reply with one line confirming you have resumed, then begin.
```

It describes the session and names the handoff as a record of work to resume, rather than saying
"you are" and "follow it": a persona line followed by an instruction to obey a file is the shape a
cautious safety filter refuses as a prompt injection, and one did on a work machine (2026-11-04).
Write a by-hand kickoff prompt in the same form.

Task-specific detail (which sitting this is, which tracker to read next) belongs in the handoff,
which the successor reads anyway. Operating preferences never ride in a prompt: they reach a new
session through the always-on context layers. **Needing a preference spelled out in a kickoff
prompt is the signal that it belongs in those layers.** And on a by-hand launch, a long prompt is a
shell argument, with quoting, newline and truncation hazards that produce a session started from a
mangled instruction and no sign of it.

## Closing the outgoing session

A canonical's name resolves to its newest session, so a takeover leaves the outgoing session alive
and idle, still holding a row in the sessions view (`claude agents`). After a few handovers the view
stops answering the one question it is consulted for: is each canonical present exactly once.
Closing the outgoing session is part of the handover, not tidying afterwards.

- **When:** once the successor is confirmed up (skill `canonical-takeover`, the verify-the-name
  step), not before; closing first risks having no live canonical if the launch fails. A session
  cannot close itself as its own final act, so a park with no successor (a usage ramp-down) has
  nothing to close.
- **How, and who:** the human runs it, from a terminal; a session names the command and does not
  run it. `fleet-canonicals dedupe [--dry-run] [<name>]` closes every session for a name except
  the newest and never signals the session it runs inside. `fleet-canonicals down <name>` closes a
  canonical outright. Both act on the list of live sessions, which inside a session's sandbox can
  be wrong (the base's `docs/reference/fleet-sessions.md`, "Sandbox and permissions"). Both stop the process and then delete the row with `claude rm <id>`.
- **Why delete, not just stop:** a stopped session leaves `claude agents --json` but stays in
  `--all` as a `done` row, and opening that row resumes it. A resumed session re-registers under the
  canonical name with its start time rewritten, so it looks like a fresh launch while carrying days
  of stale context and having resolved no handoff. If you are unsure whether a row is live or old,
  **do not open it to find out**; check `fleet-canonicals status` against the id you expect.
- **Deleting is reversible:** `claude rm` leaves the transcript on disk, and `claude --resume`
  (or `/resume`, whose picker includes deleted sessions) brings it back.
- **The worktree hazard:** deleting a row from the agents view removes a worktree Claude created
  for that session, uncommitted changes included. `claude rm` keeps such a worktree when it holds
  uncommitted changes, and both keep one with unpushed commits, one locked by a running session, or
  one you created. Step 2 commits before this point, which is what makes it safe; do not reorder.

### A worktree wedges the stop

The opposite failure: a session still inside a worktree it entered **cannot be stopped at all**.
The exit path tries to remove that worktree, the worktree is locked while a session holds it, and
the failed removal fails the whole stop. A `refresh` then starts the successor but cannot end the
old session, leaving two live rows for one name, and `dedupe` hits the same wall.

The fix is at park time (step 1: merge or keep, then `ExitWorktree`), because by the time the stop
fails, the session that could have decided is the one that cannot be closed. If you are already in
this state: commit or merge what is in the worktree, `ExitWorktree` (keeping it) from the stuck
session if it still responds, and only then stop the row. Never force-remove the worktree to make
the stop succeed; that discards what the lock was protecting.

## Arming a resume after a usage window resets

Whether a session may arm one without asking is the domain's call; the domain half says. The
mechanics, decided by one question, will a session still be alive to wake up?

- **A live session that will continue (the normal case):** `fleet-canonicals wait-for-reset`, run
  through the Bash tool with `run_in_background: true`. It blocks until the window resets and
  exits; the harness re-invokes the session on exit, so the session resumes itself. It launches
  nothing and leaves nothing to clean up.
- **No session will be alive:** `fleet-canonicals resume-at &`, the same wait followed by `up`.

Both read the reset time from a cached status-line payload, the only place Claude Code reports rate
limits, where this machine has a status line that caches it. They wait for a **5-hour** window only:
on a plan whose only rolling limit is the 7-day window they refuse and name the weekly reset, since a
weekly reset can be days off and is a pause to wait out or a session to end, not a timer to set.
**`--at '<time>'` waits for a time you choose** and is the form to use when no reset time is cached
or the plan has no 5-hour window. `--dry-run` reports without waiting.

**Do not hand-roll a `sleep` instead.** Resolving the reset time, converting it to a delay and
getting the sign right is the fiddly part, and a wrong delay fails silently, indistinguishable from
a correct arm.

1. **Never call a trigger armed until it is seen running.** `wait-for-reset` prints `ARMED pid <n>`
   first; confirm the line appeared and the process is alive. A trigger reported but never armed is
   worse than none, because it is relied on.
2. **State what was armed in one line:** the mechanism and the fire time.
3. **Then go idle.** Arming is the whole task. Fixing something noticed in passing spends the window
   the trigger exists to protect, at the moment the account has least to give. Anything found is a
   one-line note for after the reset.

---

If `~/.dotlocal/skills/parking-and-handoff.md` exists, read it: it is this domain's half (the hub's
name, the handoffs repository and directory, the hooks that fire this procedure, the usage plan and
whether arming a resume needs permission, and the dated incidents behind the rules). If it does not,
the generic content above is the whole picture.
