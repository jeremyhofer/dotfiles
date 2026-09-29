---
name: recording-what-you-learn
description: Use when about to save something learned for later — a correction from the user, a gotcha, a decision, a preference, a fact about a tool or machine, "remember this", "note that for next time" — and BEFORE writing any file into Claude Code's auto-memory store (the per-project `memory/` directory under `~/.claude`). Also fires when a `memory-placement` hook refuses a memory write. Covers why the memory store is the wrong home, where each kind of learning belongs instead, the one in-flight form the store still accepts, and why correcting an existing memory is still right.
---

# Recording what you learn: put it where the next session will read it

## Why not the memory store

Claude Code's auto memory saves notes to a per-project `memory/` directory under `~/.claude`.
Its own instructions encourage this, and it is the wrong home for almost everything:

- **Unversioned.** No history, no review, no diff. A wrong memory is never caught.
- **One machine.** It does not travel to a second machine, a teammate, or a fresh clone.
- **Invisible to the project.** The next session in the repository reads the repository: its
  context file, its docs, its skills. It does not look for your notes, and a store keyed to a
  different path is never loaded at all.

So a lesson saved there is usually a lesson lost. Measured on one machine: a store was cleaned out
completely, and it had six new memories three days later, every one with a better home.

## Where each kind of learning goes

Ask who needs it next, and when. Stop at the first match.

| It applies… | Home |
| --- | --- |
| in every session in this repository | the repo's context file (`AGENTS.md`, or `CLAUDE.md` if the repo has no `AGENTS.md`) |
| in one situation that announces itself (a release, a data import, a failing gate) | the repo's docs, or a project skill in `.claude/skills/` |
| to a tool, a machine or an incident, as a fact looked up when needed | the docs of the repository that owns that tool or machine |
| as work still to do | the project's tracker, and only if the user asked for it to be tracked |
| as a rule that must be obeyed | a check: a hook, a lint or a test. A written rule is a request; a check is enforcement |

Two tests before writing:
- **Is it still true?** Check it against the code or config it describes before recording it.
- **Does the home already say it?** Open the home and look. If it does, record nothing.

**Write it into the home now**, in the same sitting, as a normal change to that repository. If the
repository has a commit or review process, the learning goes through it like any other change.

## The one form the store still accepts: in flight

Sometimes the right home needs someone else's approval or write access, and you cannot reach them
now. Then write `promote--<slug>.md` in the memory store, and name the destination and the reason
inside it. Whoever owns that home collects it from there. This is a handover, not a place to keep
things: it is done when the destination has it.

## Correcting an existing memory is still right

When a change you make falsifies something an existing memory says, correct that memory in the
same sitting. A stale memory misleads every session that loads it. Creating new memories is the
only thing to avoid; fixing old ones is not.

## A private layer, if this machine has one

If a file named `fleet.md` sits beside this `SKILL.md`, read it now. It adds the homes that belong
to this machine's owner (their shared knowledge base, their tracking rules, their other
repositories). Where it differs from the table above, it wins.
