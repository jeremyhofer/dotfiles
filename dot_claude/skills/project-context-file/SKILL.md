---
name: project-context-file
description: Use when creating, converting, reviewing or trimming a repository's agent context file — `AGENTS.md`, `CLAUDE.md`, `.claude/rules/`, or a nested context file in a subdirectory — and when deciding whether something belongs in that always-loaded file at all. Also fires when `context-lint` fails, when a context file is over 200 lines or 14,000 bytes, when a generator such as Nx writes into `CLAUDE.md`, or on "set up AGENTS.md", "slim down CLAUDE.md", "where should this instruction go". Covers the six fixed sections, what the size caps count and why imports do not help, the on-demand patterns that keep situational content out of every session, generated blocks, and how to convert an existing file.
---

# The project context file: a short map in `AGENTS.md`, imported by `CLAUDE.md`

## What the file is for

An agent loads the repository's context file at the start of every session. Controlled studies
found such files do not make agents more capable, but agents do follow their instructions, and
repository overviews did not help. So the file is a **map**: where to look and how to act ("`just
--list` is the live task list"; "decisions in `docs/adr/` win over any summary"). It is not a tour
of what the agent will read in the code anyway.

Test every line: **would a fresh session get this wrong, or spend real effort working it out,
without the line?** If not, it does not belong in an always-loaded file.

## The two files

- **`AGENTS.md`** at the root holds everything that is not specific to one tool.
- **`CLAUDE.md`** at the root starts with `@AGENTS.md` on its first line, then holds only what is
  specific to Claude Code: a skill to reach for, a generated block for Claude.

Why an import, not a symlink and not native reading: Claude Code reads `AGENTS.md` by itself only
when no `CLAUDE.md` or `CLAUDE.local.md` exists, so the day someone creates a personal
`CLAUDE.local.md`, native reading silently drops the whole file. A symlink leaves nowhere for
Claude-specific text, and a generator writing `CLAUDE.md` would write through it into `AGENTS.md`.

Templates: `template-AGENTS.md` and `template-CLAUDE.md` beside this file.

## The six sections, fixed headings, in this order

| Heading | Holds | Keep out |
| --- | --- | --- |
| `# <repo name>` + one or two sentences | What it is, who owns it, its boundary: public, private or client-owned, and what must never land in it | A feature tour |
| `## Tasks` | The entry point, the command that lists tasks live, and the few a session needs first: set up, the fast check, the full gate | A full command catalogue; it drifts |
| `## Layout` | That `docs/` follows the standard layout and `docs/README.md` indexes it (skill `project-documentation`); the project's own `docs/` subjects, each named as `docs/<name>/`; top-level directories whose purpose is not obvious | A tour of what `ls` shows |
| `## Deeper context` | Where to read before acting, each with the situation that calls for it; that the decision log wins over summaries; project skills | The documents' content |
| `## Rules` | Only rules no hook or gate can enforce | Anything a check enforces; generic good practice |
| `## Writing here` | The prose voice line, and anything specific to this repository's documents | A documentation standard |

Optional sections (`## Architecture`, `## Testing`, a domain section) go **after** `## Writing
here`, and pass the same test as every other line.

**Rules.** Enforce a rule with a hook or gate whose block message says why and what to do
instead; that message teaches the rule at the moment it matters. List a rule only when no check can
enforce it. One exception: a rule whose gate fires only after expensive work (a long CI run) may be
listed, naming the gate. A rule a check *could* enforce but none does yet stays listed, marked "no
check yet", until the check lands; then delete the line. Generic good practice ("write good tests")
is never listed.

**Content.** One clause of why per rule. No status (it belongs in the tracker or a handoff). No
figure that an edit elsewhere can make false ("412 tests", "currently", "as of 2026"): name the
command that measures it. Every path resolves in the repository.

## The caps, and what they count

**200 lines and 14,000 bytes** for everything that loads unconditionally: `AGENTS.md`, the rest of
`CLAUDE.md`, every file either imports (followed through further imports), and every
`.claude/rules/` file without a `paths:` scope. The line cap follows the vendor's adherence
guidance; the byte cap stops long lines from defeating it (14,000 is 200 lines at 70 bytes).

**An import does not help.** An `@import` loads at session start with the file that names it, so
moving text into one changes nothing a session loads. Use imports to organise, or to include a file
another writer maintains, and expect them to count.

Why cap at all: instructions are followed less as a file grows, and every unconditional byte is
paid by every session whether or not its task needs it.

## Where situational content goes instead: the on-demand patterns

Each loads only when its situation arises. **Confirm each on the machine and Claude Code version
you use before relying on it:** run `claude-context-probe` and read its "Rules files" and "On
demand" rows.

| Pattern | How | Loads when |
| --- | --- | --- |
| A deeper-context document | Write `docs/reference/<topic>.md`; add a `## Deeper context` line naming the situation: "read before cutting a release" | The session judges that the situation has arisen |
| A nested context file | In the subdirectory it concerns, an `AGENTS.md` with the content and a `CLAUDE.md` whose first line is `@AGENTS.md` | A file in that subdirectory is read |
| A path-scoped rules file | `.claude/rules/<topic>.md` with frontmatter `paths:` listing globs, e.g. `- "src/api/**"` | A file matching a glob is read |
| A project skill | `.claude/skills/<name>/SKILL.md`, its description naming the situations | Its description always; its body when invoked |

A deeper-context pointer depends on the session choosing to follow it, so word the situation
precisely. The other three are triggered by the harness.

A nested context file adds to the root file and never overrides it: Claude Code loads both, and
other tools resolve nesting differently. It carries only its own content, not the root's six
sections. Check one with `context-lint --nested <subdirectory>`.

## Generated blocks

A generator that writes into a context file (Nx's AI setup, for one) owns only the text between its
markers. Put its block **last**, in the file it writes (Nx's Claude setup writes `CLAUDE.md`, so its
block goes after `@AGENTS.md`), and never edit inside the markers. A tool that would **replace** the
whole file is not a generator here: run it to a separate output and edit what you need into the
file yourself. The file has one owner, and no tool overwrites it.

Check a generator's other side effects every time it runs: Nx's setup, for example, also edits
`.claude/settings.json`.

## Converting an existing file

1. Run `context-lint` at the root to see where it stands. If the old file never says whether the
   repository is public, private or client-owned, ask its owner; do not guess the boundary line.
2. Create `AGENTS.md` from the template. Move each line of the old `CLAUDE.md` into its section, or
   out: a rule a check already enforces goes; an overview goes; status goes to the tracker;
   situational procedure goes to an on-demand pattern.
3. Reduce `CLAUDE.md` to `@AGENTS.md` plus anything Claude-specific, with any generated block last.
4. Run `context-lint` until nothing blocks, and `doc-lint` for the paths.
5. Put `context-lint` on the commit path (a pre-commit hook, or the fast check task), and see it
   fail on a planted defect before trusting it.

## Related

- `context-lint --help`: exactly what the check enforces and what it cannot.
- `claude-context-probe`: which context this machine actually loads.
- `recording-what-you-learn`: where a lesson learned mid-work belongs, often one of the homes above.
- `project-documentation`: the `docs/` layout, its index, and what each document type is.
