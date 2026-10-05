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
claude-context-probe          # a few minutes; five short headless sessions
claude-context-probe --keep   # also keep the temp tree, for debugging on that machine only
claude-context-probe --fleet  # the background-session checks only; see "Fleet checks"
```

- **Run it in an ordinary terminal**, not from inside an agent session. An agent's sandbox changes
  what can run: under one, Claude Code could not create its per-session environment directory, so
  every SessionStart hook failed, and that says nothing about the machine.
- **Run it on a machine you trust first, then on the one you are asking about, and compare.** The
  first run is the baseline: a verdict that differs between the two is a fact about the second
  machine; a verdict that is the same is a fact about the Claude Code version.
- It needs `claude` and `git` on PATH, and `python3` for the MCP check (skipped without it).
- It spends five model sessions and writes only under the temp directory, which it deletes.

## Relay it

The summary carries only the Claude Code version, the OS family, one verdict per check, and the
top-level key names of a managed settings file if one exists. No paths, names or values from the
machine. **Relay the summary as printed** (retype it or read it out) rather than copying files off
the machine. `--keep` output is for debugging on that machine and should not leave it.

## Read it

**A `POLICY:` banner above the first line** means managed settings switched off a channel the
probe measures, so the rows it names read `POLICY (<key>)` instead of a failure, and the banner
counts them. `allowManagedHooksOnly` and `disableAllHooks` make the four hook rows `POLICY` (hooks
passed with `--settings` do not run). `disableSideloadFlags` makes the MCP row `POLICY`: the client
rejects `--mcp-config` at startup, so the probe leaves the flag off and the other rows still run.
`POLICY` is a measured answer about the machine, not something to re-run.

**First line: the five sessions.** Each must say `OK` before any of its rows mean anything.

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
| `AGENTS.md` beside a `CLAUDE.md` | both are read | `AGENTS.md` is read only when no `CLAUDE.md` is found; import it from the `CLAUDE.md` |
| symlink two levels up | a `CLAUDE.md` that is a symlink to a file kept elsewhere is read, with no approval, and shows that file's current content | surface an external file some other way |

**Imports.** An `@import` inside the repository is the control for the import mechanism. An import
from outside the repository is gated: Claude Code records a per-project approval for external
includes, asked for once in an interactive session, and a headless run cannot give it. So `NOT
loaded` there means "not without that approval", and every new project path, such as each agent
worktree, needs its own. To surface a file kept outside a project, prefer a symlinked `CLAUDE.md`,
which the symlink row tests.

**Rules files.** A `.claude/rules/` file without a `paths:` scope should read `loaded` at session
start, so it costs as much as the `CLAUDE.md` does; one with a scope should read `NOT loaded` there.

**On demand.** One session keeps the Read tool on and reads three files that carry no codeword: one
beside a nested `CLAUDE.md`, one beside a nested `CLAUDE.md` that imports a nested `AGENTS.md`, and
one matching a rules file's `paths:` scope. `loaded` after the read, with `NOT loaded` at session
start, means that pattern loads context only when it is needed, which is what makes it a place to
move content out of an always-on file. The session is `INCONCLUSIVE` if it read any other file (it
could have read a codeword itself) or skipped one of the three.

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

## Fleet checks (--fleet)

`claude-context-probe --fleet` runs ONLY these checks, not the context ones. They answer whether
the features that long-lived, named background sessions depend on work on this build and policy.
It starts real background sessions and a few small `haiku` calls (plus one each on `sonnet`, `opus`
and `opus[1m]`), so it costs a few model calls, billed wherever that machine's usage is billed.
Run it in an ordinary terminal, not inside an agent session, and run it at home first as the
baseline to compare other machines against.

Every row reads `yes`, `no`, or `INCONCLUSIVE (reason)`; the summary carries no paths, names or
values, so it can be retyped. Every session it started is removed, even on failure, along with its
transcripts and temp dir (`--keep` keeps only the temp dir).

| Row | `yes` means |
| --- | --- |
| `bg-launch` | `claude --bg -n <name> --model haiku --settings ...` started a session and exited 0 |
| `agents-json` | `claude agents --json` lists it with an id, name, session id and cwd. Measured on 2.1.285, a row has exactly `cwd id kind name sessionId startedAt state` (state seen: `working`, `blocked`) |
| `agents-pid`, `agents-state` | informational: rows carry a `pid`, rows carry a `state`. 2.1.285 has no `pid`; a tool that keys liveness on it needs to know. Liveness in the rows below uses `pid` when present, else `state` (any value other than an exited or completed one counts as live) |
| `settings-env` | an env var set through `--settings` reached the session's shell |
| `tmpdir` | `CLAUDE_CODE_TMPDIR` from `--settings` decided the session's `TMPDIR` |
| `transcript` | the session's `.jsonl` transcript exists under the Claude config dir's `projects` folder |
| `attach` | `claude attach` ran and killing it left the session listed and live |
| `resume-bg` | `--bg --resume <session id>` started a second, listed session |
| `rm` | `claude rm` removed the row and left the transcript |
| `respawn` | after its process was killed, a session with the same name came back on a new pid; `INCONCLUSIVE` where rows carry no pid |
| `model <alias>` | `claude -p --model <alias>` answered, for `haiku`, `sonnet`, `opus`, `opus[1m]` |
| `tool <name>` | `present` or `absent` from the session's own list of tool names, for `Agent`, `Workflow`, `EnterWorktree`, `SendMessage`, `ListAgents`; `Bash` is reported present only, since `run_in_background` is a parameter of it that a name list cannot show |

A `no` on `bg-launch` makes the rows that need a session `INCONCLUSIVE`. The exit status is
non-zero unless every row before `tool` is `yes`, apart from the two informational `agents-` rows.

## What it does not test

- Hooks and MCP servers configured in user or project settings files. It passes them through
  `--settings` and `--mcp-config`, so it measures whether those channels work at all, not whether a
  particular settings file is honoured.
- Interactive sessions. Everything runs headless (`claude -p`); interactive-only behaviour, such as
  approval prompts, is out of scope.
- Plugins, output styles and user-level `~/.claude` files: it never writes outside its temp tree.
- Skills synced from a claude.ai account: Claude Code never runs their injected commands, whatever
  this probe reports for a local skill.
