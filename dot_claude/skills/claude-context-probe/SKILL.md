---
name: claude-context-probe
description: Use when you need to know which context Claude Code actually loads on a machine — before designing how instructions, rules or knowledge reach sessions there, on a managed machine whose policy may differ from home, after a Claude Code upgrade, or when a CLAUDE.md, import, hook, skill or MCP server seems to be ignored. Fires on "does this machine read CLAUDE.md above .git", "do hooks work here", "is dynamic context available", "context loading limits", "AGENTS.md support", `claude-context-probe`. Covers running the probe, reading each verdict, the controls that make a verdict trustworthy, and relaying the summary off a machine without exporting anything from it.
---

# Probing what context Claude Code loads

Where Claude Code reads instruction files from, whether hooks run, whether a hook's injected context
reaches the model, and whether MCP servers attach all depend on the Claude Code version and on any
managed policy an administrator installed. The docs describe the defaults, not a given machine. So
**measure a machine before designing context delivery for it**, and re-measure after an upgrade.

## Run it

```sh
claude-context-probe          # a few minutes; four short headless sessions
claude-context-probe --keep   # also keep the temp tree, for debugging on that machine only
```

- **Run it in an ordinary terminal**, not from inside an agent session. An agent's sandbox changes
  what can run: under one, Claude Code could not create its per-session environment directory, so
  every SessionStart hook failed, and that says nothing about the machine.
- **Run it on a machine you trust first, then on the one you are asking about, and compare.** The
  first run is the baseline: a verdict that differs between the two is a fact about the second
  machine; a verdict that is the same is a fact about the Claude Code version.
- It needs `claude` and `git` on PATH, and `python3` for the MCP check (skipped without it).
- It spends four model sessions and writes only under the temp directory, which it deletes.

## Relay it

The summary carries only the Claude Code version, the OS family, one verdict per check, and the
top-level key names of a managed settings file if one exists. No paths, names or values from the
machine. **Relay the summary as printed** (retype it or read it out) rather than copying files off
the machine. `--keep` output is for debugging on that machine and should not leave it.

## Read it

**First line: the four sessions.** Each must say `OK` before any of its rows mean anything.

- `INCONCLUSIVE`: the session failed, or the model did not report the repository-root CLAUDE.md
  that every session must see (the positive control). Its rows are not verdicts. Re-run; if it
  persists, run with `--keep` and read `out-*.err`.
- `INVALID`: the model reported a codeword planted in a file nothing references (the negative
  control), so it was guessing or reading files. Every row from it is untrustworthy.

**Instruction files.** `loaded` means the file's content reached the model at session start.

| Row | If `loaded` | If `NOT loaded` |
| --- | --- | --- |
| container above a worktree | a CLAUDE.md in a bare-repository container directory reaches every worktree's sessions, and sits outside every worktree's history | instruction files must live inside the working tree, or be projected there |
| directory above a clone | the walk up the tree continues past a `.git` directory | the walk stops at the repository boundary |
| `.claude/CLAUDE.md`, `CLAUDE.local.md` | these alternate locations are read | only `CLAUDE.md` at the root is dependable |
| subdirectory, at session start | unexpected: subdirectory files normally load only when files there are read | the normal, lazy behaviour |
| `AGENTS.md` alone | Claude Code reads `AGENTS.md` natively on this version | keep a `CLAUDE.md` that imports it |

**Imports.** An `@import` inside the repository is the control for the import mechanism. An import
from outside the repository may need the one-time approval an interactive session asks for, which a
headless run cannot give, so `NOT loaded` there is not conclusive: open an interactive session in
the kept tree and check `/memory` before designing around it.

**Hooks.** Each hook reports whether it RAN (it wrote a marker file) and whether its context was
DELIVERED (the model saw its codeword). These fail for different reasons:

- `ran=no`: hooks from `--settings` are not executed. A managed policy may allow only managed hooks;
  the managed-settings key names on the last lines hint at this. Hook-based dynamic context is not
  available there.
- `ran=yes, delivered=no`: the hook runs but its `additionalContext` does not reach the model.
- The 12,000-character UserPromptSubmit hook shows whether a size cap truncates injected context:
  `start` delivered and `end` not means a cap below 12,000 characters. Split larger context across
  several hooks.

**Skill dynamic context.** A line in a SKILL.md written `` !`command` `` runs when the skill is
invoked, and its output replaces the line before the model sees the skill. This is the channel for
context that must be current when it is used: the command can render records, status or state
fresh each time. It works in skills and custom commands only; a `CLAUDE.md` does not run it.

- `delivered`: the command ran at invocation and its output reached the model, with no shell call
  of the model's own that could have fetched it instead.
- `NOT delivered (disabled by policy)`: `disableSkillShellExecution` is set, typically by a managed
  policy. Skills still load, as static text.
- `NOT delivered (permission check failed)`: an injected command never prompts; it must already be
  allowed, for example by the skill's `allowed-tools` frontmatter, or the invocation aborts.
- `INCONCLUSIVE (the model ran a shell command itself)`: the codeword may have come from the
  model's own call. Re-run.

**Skills and MCP.** A listed project skill means skills in `.claude/skills` are an on-demand
channel on this machine. A listed MCP tool means a stdio MCP server can be attached, which is what
on-demand retrieval over MCP would need. `NOT loaded` on either usually means a managed policy.

## What it does not test

- Hooks and MCP servers configured in user or project settings files. It passes them through
  `--settings` and `--mcp-config`, so it measures whether those channels work at all, not whether a
  particular settings file is honoured.
- Interactive sessions. Everything runs headless (`claude -p`); interactive-only behaviour, such as
  approval prompts, is out of scope.
- Plugins, output styles and user-level `~/.claude` files: it never writes outside its temp tree.
- Skills synced from a claude.ai account: Claude Code never runs their injected commands, whatever
  this probe reports for a local skill.
