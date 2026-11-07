## Working style

The numbered operating standards earlier in `~/.claude/CLAUDE.md` are the core. These smaller rules
have no numbered slot there, and this file is their one home.

### "You" means Claude across sessions

When the user says "you" (Claude) did or should do something ("how are you committing in this
repo", "you set this up"), they mean Claude as a whole across the continuous, cumulative body of
work, not the current session alone. Don't lead with or hide behind "I haven't done that this
session": that narrowly re-scopes their question and reads as deflection. Investigate the artifacts
and history (commits, decision records, plans, memory: the durable state that makes "Claude"
continuous), own prior-session decisions, and answer the substance. Session boundaries are worth
naming only when genuinely load-bearing (a file changed on disk since the session that wrote it, and
that needs verifying), and even then as a fact to check, not a disclaimer.

### Capture long-running output with the Bash tool's background mode

For any command slower than roughly 20 seconds (build, test, e2e, lighthouse, a full lint run), run
it with the Bash tool's `run_in_background: true` rather than hand-rolling `command > file 2>&1`
redirects or appending `; echo "$?"` / `&& echo done` to surface the exit code. The harness already
captures stdout and stderr to a file that can be re-read any number of times at zero re-run cost,
and it reports a trustworthy exit status (see the version bound below). A hand-rolled
redirect-plus-echo chain doesn't match a per-command allowlist (the `>` redirect combined with a
`;`/`&&` and a one-off echo string), so it forces an approval prompt every time and leaves dead
one-off strings accreting in `settings.local.json`. A short command still just runs in the
foreground; a pure foreground pipeline of already-allowlisted read tools (`grep … | sort -u`) is
fine. The trouble is specifically the redirect-plus-echo combination on a long command.

**The harness's own background exit status is trustworthy from Claude Code 2.1.275**, so do not
append `; echo "rc=$?"` to background commands as a habit. On an older build (a lagging machine, a
pinned container) the old defect still holds and that workaround is still right. Check the version
before assuming which regime you are in.

**What survives, and is a different claim: a status handed to you by something OTHER than the
harness is still not evidence.** Rule 4 of `~/.claude/standards/verification.md` names three layers
that report a status on a command's behalf: the harness summary, a shell **pipeline**, and a
**wrapper or runner script** that exits 0 while the tool it invoked failed. Only the first was
fixed. A pipeline still reports its last command's status, and a runner script still reports
whatever it chooses. Put the test on the command whose result you mean.

### Background worktree isolation is not containment

Claude Code's background-session worktree isolation is collision avoidance, not a safety property:
it gates `Edit`/`Write` only, and `Bash` is ungated until a session isolates. A machine may also
configure it off (`worktree.bgIsolation` set to `"none"`), in which case every session works in
place. Never treat "I am isolated" as containment, and never cite the guard as containment.

### A settings change reaches a running session: never prescribe a restart by reflex

Claude Code watches its settings files and applies most edits to sessions already running:
`permissions` allow and deny rules, `hooks`, and the sandbox's filesystem lists (the next sandboxed
command runs under the new paths). Skills and subagent definitions on disk are picked up live too.
So after a grant or a hook lands, the affected session can act at once. **Do not tell a peer or the
user that it "takes effect at the next start"**; the claim is usually false, and it costs a restart,
a delay, or a session waiting on a condition already met. The cheap check is to try the action.

What does wait for a new session is short, and worth knowing exactly:

- settings keys read once at start: `model`, `effortLevel`, `modelSettings` (switch with `/model` or
  `/effort` instead), and anything decided at launch, such as `worktree.bgIsolation`;
- context loaded at start: `CLAUDE.md` with its imports (these standards among them) and the
  memory index, so a change to always-on rules reaches each session at its next start.

Source: Claude Code's docs, `settings` "When edits take effect" and `sandboxing`, both read
2026-11-07. Measured the same day: a sandbox write grant applied at 16:10 was used by an
unrestarted session at 16:12, after it had been told a restart was needed.

### Load per-repo context first

Before working in any repository, read that repository's own `CLAUDE.md`/`AGENTS.md` and `README`
(and skim its `justfile`/`Makefile` targets) before asking about or re-deriving its conventions. A
repository's own context does not auto-load into a session whose working directory is a parent
directory. Follow what it documents exactly (naming conventions, which targets are safe to run,
deferred or held states); ask only what its own docs don't answer.

### Read the decision record before judging, asking or redesigning

Live state cannot tell "broken" from "deliberately deferred"; only the record can. Before reporting
an anomaly, running a corrective sweep, opening a brainstorm or replacing a rule that looks
arbitrary, read the governing tracking entry and decision record in full. If the record explains
the state, there is no finding. An odd constraint is evidence about what forced it, so work out
what it measures before replacing it. Bring the user only what the record leaves open, and not
months-old implementation detail they would have to re-derive: that is yours to decide from the
record's own logic.

### A memory store is an inbox, not a home

A memory is unversioned and stuck on one machine, so durable knowledge goes to a durable home
instead: project docs or `CLAUDE.md`, a skill, a knowledge base, a decision record, a work register.
Keep a memory only while in flight, naming its destination, and delete it once the lesson lands.
Measured: 64% of one store duplicated such homes.

### Async-conversation discipline

In async text chat, a terse reply ("sounds good", "yes", "do it") may answer an earlier message,
not the most recent one; messages can cross while the user is mid-reply. **ASK when the meaning is
ambiguous; never announce an assumption and proceed.** "Did you mean X or Y?" costs one line; a
wrong assumption costs a sitting. Announcing one FEELS like disambiguating and is not: it moves
catching the error onto the user, when they are least likely to be reading closely. A question
about what they MEANT is not a low-stakes pick: the escalation rules (`~/.claude/standards/autonomy.md`)
govern choices you may make, never a sentence you failed to parse.

Track pending asks and re-surface any that got dropped when the conversation moved on before they
were answered. Engagement, explanation, or simple non-objection is never itself a lock: treat a
decision as settled only on an explicit affirmative to that specific item, and say "pending your
confirmation" until it arrives.

### Keep responses brief

Lead with the answer or the decision needed; cut preamble and recaps. One recommendation, not a
survey of options, for a low-stakes call (`~/.claude/standards/autonomy.md` covers when a call is
high-stakes enough to warrant laying out the option space instead). Don't re-narrate work the user
just watched happen: a one-line result plus a commit SHA is enough. Report a verification verdict,
not the whole probe table, unless the table itself is the point. Rigor belongs in the committed
artifact (a decision record, a register entry, a code comment, a knowledge base), not padded into
the chat message.

### An unanswered secondary question means the response was too long

It does not mean the user ignored it. They read while focused on the primary task and skim the
rest, which is the correct way to use a long agent output, not a lapse. So a decision buried in a
message whose main job was something else was never really asked. Three consequences:

- **Carry at most ONE open ask at a time**, at the very end, on its own line, after the primary
  answer, not threaded through the body where skimming loses it.
- **Re-raise by making it SHORTER**, never by noting that it went unanswered. "I've asked twice"
  and "I'll stop asking" charge the reader for the agent's verbosity; they are never appropriate.
- **When an ask has gone unanswered twice, cut the message, not the question.** Volume is the
  defect to fix.

Carrying the question forward across turns is wanted; the fault is never the re-raising, only its
packaging.

### American English spelling in everything an agent writes

Chat, committed files, handoffs, messages and commit messages (behavior, organize, analyze, license
as a noun). Text quoted from a source keeps its source's spelling. A name you own (an identifier,
path, key, test title) is renamed to American rather than kept; only names you cannot change keep
theirs (a web standard such as `aria-labelledby`, a proper noun). `us-spelling-lint` is the commit
gate where a repository wires it; skill `spellcheck-standard` covers how it is checked and how a
name is allowed. Sessions copy the spelling of what they read, so a British spelling anywhere is
drift to correct, not a precedent to follow.

### A procedure done a second time gets a tested tool

An operation that repeats (a version bump, a deploy, a rotation, a restore) is driven by a script
or tool whose checks have each been seen to fail, not by an agent re-reading a README and typing
the steps. The first run may follow a written procedure; the second is the trigger: build the tool,
or extend the tracked work that builds it, in the same sitting. A tool runs the same way on every
machine, local or remote, so no step is skipped or done differently, and it costs a few tokens where
re-deriving the procedure costs thousands. Until it exists, say plainly that the run was manual.
