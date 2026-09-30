---
name: claude-config-layers
description: Use when changing ANY Claude Code setting, permission, hook, plugin toggle or model default — deciding which of the four layers a setting belongs in, adding a permission, wiring a hook, or making a preference apply on every machine. Also fires on the failure signatures: a setting that will not stick or silently reverts, a preference that works on one machine and not another, a background/agent session coming up on the wrong model, or a settings file that was overwritten instead of merged, a background session that will not start until the workspace trust prompt is accepted, or any thought of editing `~/.claude.json`. Covers the precedence order, the never-blind-overwrite rule, and why the user settings file is only PARTIALLY managed.
---

# Claude Code config: four layers, and which one a thing belongs in

## 1. The layers, highest precedence first

| Layer | Path | What belongs here |
| --- | --- | --- |
| **Managed** (root) | `/etc/claude-code/managed-settings.json` | machine-wide **enforcement**: safety hooks, the enforced model default. Root-owned, so a session cannot quietly change it. |
| **CLI flag** | `--model`, `--settings` | one session, deliberately different. Does **not** write anything back. |
| **Project local** | `<repo>/.claude/settings.local.json` | per-machine, gitignored. Accreting permission grants live here. |
| **Project shared** | `<repo>/.claude/settings.json` | committed, structural, project-wide. Reviewable declarations of intent. |
| **User** | `~/.claude/settings.json` | personal preferences across all projects. |

Two consequences worth holding onto: **a `deny` rule at any layer wins** and cannot be loosened by a
lower one, and **`CLAUDE.md` is context, not enforcement** — anything that must be *obeyed* rather
than merely known belongs in settings, a hook, or a managed rule, never in prose.

## 2. The rule that has actually caused damage: never blind-overwrite

**Always `jq`-merge a settings file. Never `printf >` or `cat >` over one.**

This is not defensive style. A settings file can be clobbered exactly this way, destroying an
accreted permission allow-list, even in a session that has just read guidance telling it to merge.
The allow-lists are the part that hurts: they are built up one grant at a time, they are not
reproducible from anywhere, and nothing warns you they are gone.

Merging looks like this — read, transform, write, never truncate-then-write:

```bash
tmp=$(mktemp)
jq '.permissions.allow += ["Bash(foo:*)"]' ~/.claude/settings.json > "$tmp" && mv "$tmp" ~/.claude/settings.json
```

## 3. `~/.claude/settings.json` is managed, but only PARTIALLY

The right way to manage it is as a chezmoi **`modify_` script** (`dot_claude/modify_settings.json`
in the chezmoi source), not as a normal managed file.

The reason is that **Claude Code writes to this file at runtime**: `/model` writes `model`, `/config`
writes UI preferences, toggling a plugin rewrites `enabledPlugins`, and granting a permission
appends to `permissions.allow`. A normally-managed file would fight every one of those — each apply
reverting what the app just wrote, each app write showing up as drift. chezmoi's `modify_` prefix is
built for this case: the script receives the **current** file on stdin and prints the desired state,
so declared keys are enforced and everything else survives untouched.

**To make a preference apply on every machine:** set it however you like locally (`/config` is
fine), then add the same key to the declared block of the `modify_` script and commit. If it is
not in that block, it is local to this machine and will not travel — that is the whole gap the
script exists to close.

The base's script declares only preferences true on any machine. Keys that belong to one domain
(plugins, hooks, sandbox paths, permission rules) go in that domain's fragment,
`~/.dotlocal/claude/settings-declared`, which the script runs and merges on top; its header states
the fragment's contract.

**Two keys should deliberately NOT be declared, and adding them would do real damage:**

- **`model`** — the enforced default lives in the managed layer (see §4). Declaring it here too
  would create a second source of truth for one setting, with the losing copy sitting here looking
  authoritative.
- **`permissions.allow`** — an **array**. jq's object-merge operator **replaces arrays wholesale**
  rather than unioning them, so declaring it would silently discard every permission granted since
  the file was last captured.

## 4. The `/model` trap, and how the default is enforced

**Confirming a model pick in `/model` writes the `model` key into `~/.claude/settings.json` as the
default for every session started afterwards — not just the one it was typed in.** So one
interactive switch, made for a throwaway session, silently re-tiers every background and agent
session launched from then on, and nothing announces it. This has happened: a background session came up on
the wrong model hours after an unrelated switch.

The fix is layered, and both halves matter:

- **Enforced default** — `model` in the managed file, which outranks the user file. A `/model` write
  still happens but is outranked and inert, while `/model` still switches the running session.
  Being root-owned, that file is provisioned outside the user dotfiles, by whatever mechanism the
  machine uses for system config.
- **Per-session pinning** — every launch script passes `--model <alias>` explicitly. `--model` is
  session-scoped and never writes back, so a script states the tier it needs and is immune to
  whatever the default drifted to.

**Do not add `availableModels` to the managed file** unless a hard lock is genuinely wanted: it
constrains which models may be selected *at all*, including via `--model`, so it would make it
impossible to deliberately run a session on a different model.

Two gotchas when checking a model value: the CLI's `--model` help lists only the bare aliases, but
context-qualified forms such as `opus[1m]` are accepted — and **the CLI exits 0 even for an
unrecognised model**, so exit status is not a usable check. The rejection appears only in the output.

## 5. Repo-level settings: shared vs local

- **`.claude/settings.json`** — committed. Deliberate, project-wide, structural: hooks the project
  needs, a `worktree` policy, permissions that are a property of the project rather than of your
  machine. Being committed and reviewable is the point.
- **`.claude/settings.local.json`** — gitignored, per-machine. This is where per-session permission
  grants accumulate, and it gets large. **Do not promote that accretion into the committed file.**

Widening what a repo's settings *permit* is a change to what every future session may do there.
Treat it as needing explicit, fresh agreement for that specific edit — not inferred from an adjacent
instruction like "try again".

## 5b. `CLAUDE.md` discovery walks to the filesystem root; the other layers do not

Measured on core Claude Code with a two-file marker test: `CLAUDE.md` loading walks from
the working directory up to `/` with **no `.git` boundary**, for the main session and subagents
alike, so a `CLAUDE.md` in a parent directory reaches every repo nested below it. What IS scoped to the project:
auto-memory (keyed on the git common dir), settings and permissions (no downward inheritance), and
skills, agents and commands (they do not walk parents). A managed install may clamp this
(managed `claudeMdExcludes`, a policy hook, a sandbox read-deny), so on a managed machine rely on
inheritance first and keep each repo self-contained as the fallback.

## 6. When a setting does not take effect

Work down this list before concluding anything is broken:

1. **Is it read at session start?** Several keys, `worktree.bgIsolation` among them, are read when
   the session starts. The session that writes the file does not benefit from it — restart first,
   and do not conclude the file is wrong.
2. **Is a higher layer overriding it?** Check managed first, then a CLI flag, then project-local.
   A `deny` at any layer cannot be loosened lower down.
3. **Did an apply revert it?** Only for keys named in the `declared` block — that is the script
   doing its job. Change the declared value, not the deployed file.
4. **Did you edit the deployed file instead of the source?** Edits to `~/.claude/...` are overwritten
   on the next apply. Edit the chezmoi source, then apply.

## 7. `~/.claude.json` is the app's STATE file, not a settings layer: never write it

Easy to confuse with `~/.claude/settings.json` by name alone. `~/.claude.json` is written by Claude
Code itself, continuously: the login, onboarding and notice flags, feature-flag caches, usage
counters, user-scope MCP servers, and a `projects` map keyed by path (last-session stats,
`activeWorktreeSession`, `hasTrustDialogAccepted`). Nothing manages it, and it is not in the precedence
order of §1. Read it for diagnosis; change behaviour through a settings layer instead.

**Do not write it, by hand or by script**; accepting a prompt is preferable to risking state
corruption. The app rewrites the file while it runs, which is where that risk comes
from. The obvious edit does not work either: setting `hasTrustDialogAccepted` does not grant workspace trust.

**Workspace trust is granted only by accepting the prompt.** Since a release around 2.1.277–2.1.280,
`claude --bg` in an untrusted directory asks for trust, or exits when it cannot ask, so a
non-interactive background launch fails there with the CLI's own message. The fix is for the human owner to
run `claude` once in that directory and accept. Trust is kept per path, so a session or worktree
started from a new path needs it again. Do not build tooling around it.

---

If `~/.dotlocal/skills/claude-config-layers.md` exists, read it: it is this domain's half (where the
managed file and the settings `modify_` script live here, and the dated evidence and decisions). If it
does not, the generic content above is the whole picture.
