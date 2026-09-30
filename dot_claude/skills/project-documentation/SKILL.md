---
name: project-documentation
description: Use when writing, filing, reviewing or moving any document in a project repository's `docs/` tree (a decision record, spec, plan, runbook, research note, reference page or policy), or deciding its type, the initiative or subject it serves, or where it goes. Also fires when `context-lint` reports a `docs-*` finding (`docs-index`, `docs-layout`, `docs-dated`, `docs-retired`, `docs-outside`, `docs-nested`, `docs-initiative`, `docs-subject`) or `register-lint` an `initiative-*` one, on "write an ADR", "where does this doc go", "close this initiative", "declare a subject", "reorganize a notes repo", `docs/initiatives/`, `register show`, `register health`. Covers the `docs/` layout and index, initiatives and subjects (PARA's Projects and Areas), the initiative folder, the close sequence, the lookups, each document type, the decision record's shape and review, a disk-only vault for a sensitive subject, and adopting all of it in an existing notes repository. A register entry is skill `register-standard`.
---

# Project documentation: one layout, and what each document type is for

A document is placed on two axes: **which piece of work or standing area it serves** (an initiative,
a subject, or the repository as a whole), and **what type it is** (spec, runbook, …), which picks the
subdirectory. Both apply to every repository that keeps a `docs/` tree, notes repositories included.

## The layout

```
docs/
  README.md      the index: one line per subdirectory and per loose document
  adr/           decision records, numbered; one log per repository
  register/      tracked work, one file per entry; finished ones in register/closed/
  initiatives/   one folder per open initiative: <ID>-<slug>/, typed subdirectories inside
  <subject>/     one directory per subject, declared in AGENTS.md's `## Layout`, with a README
  specs/         designs for a build in progress         YYYY-MM-DD-slug.md
  plans/         execution plans for a build in progress  YYYY-MM-DD-slug.md
  runbooks/      repeatable procedures, kept current      undated
  research/      investigations, frozen once written      YYYY-MM-DD-slug.md
  reference/     the project's manual: architecture, commands, code style, testing, procedures
  policies/      governing policies           compliance/  compliance dossiers and control maps
  archive/       finished work: archive/specs/, archive/plans/, archive/initiatives/, and other
                 finished documents
```

The type directories directly under `docs/` (`specs/` through `compliance/`) are the
**repository-wide type folders**: they hold what several initiatives or subjects share, or what
concerns the whole repository (an organization chart, an architecture overview, the codebase's
manual).

- **Create a directory only when it has content.**
- **The index is required** wherever `docs/` exists. It names every subdirectory and every document
  loose at `docs/` root, and says what each holds. A loose document is fine once the index names it;
  move it into its type's directory when that is clearly better.
- **A subject directory is declared** on its own line in the context file's `## Layout` as
  `docs/<subject>/`. That declaration is what makes it part of the layout rather than drift.
- **Every document of a type lives under `docs/`.** A top-level `adr/`, `specs/`, `plans/`,
  `runbooks/`, `research/`, `reference/`, `evidence/`, `handoffs/` or `archive/` moves into it
  (evidence is research; handoffs are archive). So does a notes repository's own material: its
  standing areas become subjects and its pieces of work initiatives. Tool configuration, and
  content a build consumes (a site's source pages), are not documents and stay where they are.
- **A `docs/` tree below the root belongs only to a publishable package**, one whose
  `package.json` does not set `"private": true`: a monorepo package may ship its own docs. A
  single-project repository keeps every document in the root `docs/`.
- **Retired names stay retired.** No `docs/claude/` or `docs/agents/` (the project's manual is
  `docs/reference/`, and people read it too) and no `superpowers` directory anywhere (specs and
  plans are `docs/specs/` and `docs/plans/`). Declaring one in `## Layout` does not make it allowed.
- **Moving a document means updating everything that cites it**: other documents, configuration,
  gates and scripts, and archived documents too. Rewrite a path so it resolves; leave what an
  archived document says happened as it was written.
- `context-lint` checks all of this: the index (`docs-index`), that every subdirectory is standard
  or declared (`docs-layout`), that dated types carry dates (`docs-dated`), retired names
  (`docs-retired`), document directories outside `docs/` (`docs-outside`), `docs/` trees outside
  publishable packages (`docs-nested`), and the initiative and subject shapes below. It reads the
  git index, so an untracked leftover on disk does not count. Nothing inside `docs/archive/` is
  checked.

## Initiatives and subjects: where a document belongs

The method is **PARA**, Tiago Forte's (<https://fortelabs.com/blog/para/>), which sorts material by
how actionable it is: *Projects* are short-term efforts with a goal, *Areas* are parts of work or
life needing ongoing attention, *Archives* hold what is no longer active. The categories are PARA's;
the names are this layout's, because the register already calls a piece of work an initiative.

- **An initiative** is PARA's Project: a piece of work with one register entry that closes (skill
  `register-standard`). Its documents live in `docs/initiatives/<ID>-<slug>/`.
- **A subject** is PARA's Area: a standing area with no end (a team's on-call, a tax domain, a
  person's career). Its documents live in `docs/<subject>/`.
- **Archives** are `docs/archive/`; a closed initiative's folder moves there whole.

### Where a new document goes

1. **Does it serve exactly one open initiative?** File it in that initiative's folder, under its
   type. If the work has no register entry, it is not yet an initiative; filing one is a decision
   with its own tests (skill `register-standard`, "Who may file"), so go to step 2.
2. **Does it serve exactly one subject?** File it in `docs/<subject>/`.
3. **Otherwise** (it serves several, or the whole repository) file it in the repository-wide type
   folder.
4. **Then its type** (the table under "Which type is it?") picks the subdirectory and whether the
   name is dated.

**Never inside a folder:** decision records and register entries. A repository keeps one `docs/adr/`
and one `docs/register/`, so every decision and every piece of tracked work has one place to look.
An initiative's README lists the records that belong to it instead.

### The initiative folder

```
docs/initiatives/ABC-0042-billing-refactor/
  README.md
  specs/     2026-03-02-billing-refactor-design.md
  plans/     2026-03-09-billing-refactor.md
  research/  2026-02-20-invoice-volume-baseline.md
  runbooks/  reference/  policies/  compliance/     (only those with content)
```

- **Name:** `<ID>-<slug>`, the `<ID>` being the entry's id in this repository's register. An
  initiative with no documents of its own needs no folder. Create the folder with its first
  document, and add `folder:docs/initiatives/<ID>-<slug>/` to the entry's `artifacts:`. The id and
  the pointer link folder and entry both ways, and `register-lint` checks both.
- **Only typed subdirectories** (`specs/`, `plans/`, `runbooks/`, `research/`, `reference/`,
  `policies/`, `compliance/`), created as needed; the one file directly in the folder is
  `README.md`. Entries directly under `specs/`, `plans/` and `research/` are dated,
  `YYYY-MM-DD-slug`, as at the repository-wide folders.
- **The README** says what the initiative is for in one sentence; names its register entry; names
  the subjects its outputs will go to; lists every file in the folder, grouped by type; and lists
  the decision records that belong to it. **It carries no status**: status lives only in the
  register entry, and a second copy goes stale.
- **A recurring cycle** (one quarter's review, one year's plan) is its own initiative each time,
  so each one closes.

### A subject directory

- **A `README.md`** saying what the subject covers and, if it has one, its `standing` register entry
  (recurring work with no end).
- **Typed subdirectories** once it holds more than one type of document; **flat** while it holds
  one type, its README naming that type.
- **Declared** on its own line in `## Layout` as `docs/<subject>/`, and named in `docs/README.md`.

### A sensitive subject: a disk-only vault

Material that must not enter the repository's history (notes on people you manage or review, for
instance) goes in a **vault**: a separate git repository with **no remote**, on the machine's own
disk, outside the repository's tree.

- The repository declares the subject and the vault's location in `## Layout`, one line (for example
  `` `<vault path>` — review notes; a separate repository, never copied here ``), and holds none of
  its content: no excerpts, no names from it in entries, commit messages or documents.
- Do not write that line as `docs/<name>/`: the vault is not under `docs/`, and the subject checks
  read that form.
- **A vault has no off-machine copy**, so the machine's own backup is its only protection. Its other
  rules (encryption, retention) are decided on that machine by its owner. Deciding what counts as
  sensitive is the owner's call, not an agent's.

### Closing an initiative

At `done`, in this order, then commit it all at once, because the lints refuse every half-done
state (an open entry with an archived folder, or the reverse):

1. **Promote each spec's and plan's decisions** to their durable homes. `doc-lint` treats a spec
   leaving a spec directory as finished and refuses one still holding a `pending` decision.
2. **Move each output** (a convention, a runbook, a reference page) into the subject it serves, or
   the repository-wide folders, and **update everything that cites it**: documents, configuration,
   scripts. `git grep -nF '<old file name>'` finds them; `doc-lint`'s advisory `dangling-path`
   catches some of what is missed.
3. **Archive the folder:** `git mv docs/initiatives/<ID>-<slug> docs/archive/initiatives/`.
4. **Rewrite the entry's `folder:`** to `docs/archive/initiatives/<ID>-<slug>/`.
5. **Close the entry**: `status: done`, `closed:` dated, a Resolution naming where each output went,
   the file moved to `docs/register/closed/`.
6. **Run the lints** (below) before committing.

At `dropped`, skip step 2: archive the folder as it is.

### Lookups

| Question | Answer |
| --- | --- |
| What is in flight, and where is each one's folder? | `register list --open` |
| Everything about one initiative | `register show <ID>`: the entry, its folder's files by type, and the decision records its README names |
| Which subjects exist? | the `docs/<subject>/` lines of `## Layout` |
| What has gone quiet, or is filed in the wrong place? | `register health`: an active initiative whose folder has had no commit in 30 days, a standing entry past its cadence, a document in the repository-wide folders named by nothing (no entry, decision record or README) or by one initiative only (a candidate to move into its folder). Advisory |
| Where does a new document go? | "Where a new document goes", above |

Render a list with status in it on demand; never commit one, because a derived list nobody
regenerates is believed while wrong.

### The checks

- `context-lint` `docs-initiative`: a folder under `docs/initiatives/` without `README.md`; a README
  not naming each subdirectory and each document in them; a file in the folder other than the README; a subdirectory outside
  the typed list; a file directly in `docs/initiatives/` other than a `README.md`. `docs-dated`: an
  undated entry under an initiative's `specs/`, `plans/` or `research/`. `docs-subject`: a declared
  subject that exists without a `README.md`.
- `register-lint` `initiative-id`: a folder under `docs/initiatives/` or `docs/archive/initiatives/`
  whose name does not start with an id in the register. `initiative-folder`: a live folder its entry
  does not name as `folder:`. `initiative-place`: a closed entry's folder still live, or an open
  entry's folder archived. `artifact-path`: a `folder:` pointer that does not resolve.
- `doc-lint` reaches specs and plans inside initiatives once `.doc-lint` says
  `spec-dirs: docs/specs/ docs/plans/ docs/initiatives/*/specs/ docs/initiatives/*/plans/` (a `*`
  standing for one whole path segment).
- **Not checked:** what a subject README says, and anything in `docs/archive/`.
- **In a git work tree the checks read the index,** as a commit records it: a file written but not
  yet staged is not counted, and the output says so.

## Which type is it?

| It is… | Type | Lifetime |
| --- | --- | --- |
| a decision, and the options it rejected | decision record, `adr/NNNN-slug.md` | immutable once accepted |
| the design for a build | spec | scaffolding: archived when built |
| the steps to execute a build | plan | scaffolding: archived when executed |
| a from-scratch procedure a person follows on a live system | runbook | living, kept current |
| a cited investigation | research note | frozen; a newer note supersedes it |
| how the project works, looked up when needed (architecture, commands, testing, a workflow) | reference page, `reference/` | living |
| a rule the project is governed by, or its compliance evidence | policy, `policies/` or `compliance/` | living, versioned |
| the state of a piece of work | register entry (skill `register-standard`) | living |

**Status lives only in the register.** Never narrate what is in flight into a context file, a
README, a record or a spec.

## A decision record

**Shape:** a title that states the decision; a short header (status, date, deciders, tags); then
`## Context`, `## Considered Options`, `## Decision` with numbered `### D1 — …` decisions,
`## Consequences`, `## Pros & Cons of the Options`, `## Judgment`, `## Notes / References`.
Statuses: Proposed, Accepted, Rejected, Deferred, Superseded (by a named record).

**What each section is for.** A record can have the right headings and still be wrong. The rules:
1. **A decision is an imperative.** `### D2` says what the project will do, as an instruction to
   someone who was not there. If its first sentence is a finding ("X turns out to…"), it belongs
   in Context.
2. **Context opens with the problem, in numbers.** What is wrong, and how big.
3. **Evidence lives in Context, worked examples in Notes, and a decision carries neither.**
4. **Name the real category; never coin one.** If nothing existing names what you are governing,
   the scope is probably wrong.
5. **An outside claim carries a resolvable link and a date**, fetched, never recalled. Characterise
   a statistic (its subject, its sample) rather than quoting it bare.
6. **Cite, do not import.** If a claim changes, which file must be edited? If not this one, cite it.
7. **A record that resolves or contradicts an older one amends the older one in the same change.**

**`## Judgment`** names the grounding behind each decision (a document, a measurement, a stated
direction), then every place a decision departs from a recommendation the record itself cites, and
why. "None" is a valid answer when stated plainly.

**Pros and cons per option** are the part worth re-reading: why the rejected options lost.

**Immutable once accepted.** Correct it with a dated entry in an `## Amendment log` at the foot (what
was wrong, what is true, why, what changed in the decision), or supersede it with a new record.

**The fresh-eyes review, before it reaches the decider.** Dispatch three reviewers in parallel, each
in a fresh context, not in your own: one checks it against every other record on the subject
(conflicts, material imported, older records it resolves); one checks it for a cold reader (every
reference resolves, every figure re-measured, no coined term); one reads it as a hostile editor
against the seven rules. Fix what they find, raise to the decider what disputes the decision itself,
and record the review in a `## Review` section.

## A spec

A status line, and a `## Decisions` list naming where each decision will live once made: a record,
a runbook, the project's docs, or `pending`. A spec is never a decision's permanent home; promote
each decision before calling the spec finished, then move it to `archive/specs/`; a spec in an
initiative folder stays there and is archived with the folder. A spec that
commissions a check makes "seen failing on a planted defect" its acceptance criterion.

## A plan

The execution steps for one build, each small enough to verify. Moves to `archive/plans/` when
executed, or with its initiative's folder.

## A runbook

Followed by hand on a live system, so ground every step: read the system's own notes and the live
system first, check each command against the tool's help, and say which steps were verified and
which inferred. Where a record and the machine disagree, the machine wins. Hand it over in chunks
verified with the person running it.

## A research note

Dated, cited, and frozen once written: every source with a link and the date it was fetched,
anything not verified marked **unverified**. A newer note supersedes it; the old one stays.

## A reference page

The project's manual, in `docs/reference/`, for a person or an agent: architecture, the command
catalogue, code style, testing, a release or drafting workflow. Each page the context file's
`## Deeper context` points at is named there with the situation that calls for it ("read before
cutting a release"); that pointer is how a session finds it on demand. A dated audit is research,
and a migration plan is a plan, even when an agent wrote them: file them by type.
Skill `project-context-file` covers the always-loaded half of a project's context.

## Every type

- **Written for a cold reader:** every reference resolves for someone with none of the session's
  context. `doc-lint` catches part of it.
- **No volatile figures** that an edit elsewhere will make false; name the command that measures it.
- **A check is evidence only once it has been seen to fail** on a planted defect, then pass.

## Adopting this in an existing notes repository

For a repository of notes and working documents (several pieces of work in flight, some standing
areas, material sorted however it grew) moving to this layout. Everything here runs offline with
the tools this skill names. Work on a clean tree, and commit at each step so any one can be reverted.

**0. Check the tools and read the repository.** `command -v register register-lint context-lint
doc-lint` prints four paths. Read the repository's own context file and README first; they may
already declare things this procedure would otherwise guess at.

**1. Inventory, before moving anything.** List what exists: `git ls-files | cut -d/ -f1 | sort |
uniq -c` for the top level, then each directory's contents. Put every directory and loose document
in one class:

| Class | Test | Goes to |
| --- | --- | --- |
| initiative | live work that will finish (a refactor, a ticket-tracker cleanup, one review cycle) | `docs/initiatives/<ID>-<slug>/` (step 4) |
| subject | a standing area with no end (a team, a system you own, career notes) | `docs/<subject>/` (step 3) |
| sensitive subject | material that must not be in this repository's history | a vault (step 3) |
| repository-wide | shared by several, or about the whole repository (org chart, architecture) | `docs/<type>/` |
| finished | work that ended before adoption | `docs/archive/`, not sorted further |
| not a document | tool configuration, data a tool owns | stays where it is |
| unsettled | purpose unclear | stays where it is, listed for the owner |

**Show the inventory to the repository's owner and take their corrections before step 2.** Which
work is live, which is finished, and what is sensitive are theirs to say, and every move after this
rewrites paths.

**2. Build the frame.** In one commit:
- `AGENTS.md` with a `## Layout` section, and `CLAUDE.md` importing it (skill
  `project-context-file`).
- `docs/README.md`, one line per entry under `docs/`.
- `docs/register/README.md` from the template in skill `register-standard`, with a prefix: short,
  uppercase, and unused here (`git grep -nE '\bABC-[0-9]'` finds nothing).
- `.doc-lint` with `spec-dirs: docs/specs/ docs/plans/ docs/initiatives/*/specs/
  docs/initiatives/*/plans/`.
- Any top-level `adr/`, `specs/`, `plans/`, `runbooks/`, `research/`, `reference/` or `archive/`
  moved under `docs/` with `git mv`.

**3. Subjects.** For each: `git mv` its material into `docs/<subject>/` (typed subdirectories if it
holds more than one type), write its `README.md`, add a `docs/<subject>/` line to `## Layout` and a
line to `docs/README.md`.
For a sensitive subject, make a vault instead: `git init` a directory outside this repository's
tree, move the material there with plain `mv`, commit it there, and add one `## Layout` line naming
the subject and the vault's location (not in the `docs/<name>/` form). **If the material was ever
committed here, it is still in this repository's history.** Tell the owner; rewriting history is
their decision and not part of this procedure.

**4. Register entries, then folders, one initiative per commit.** For each initiative the owner
confirmed:
1. Search the register first (`register list --match '<topic>'`), then allocate with
   `register next` and write the entry (skill `register-standard`): status, a closure condition or
   sentinel, a Next action. The first entry is `<PREFIX>-0001` by hand: on an empty register every
   `register` command stops with "holds no entries".
2. `mkdir -p docs/initiatives/<ID>-<slug>/<type>` and `git mv` each document into its type
   subdirectory. Give an undated spec, plan or research note the date it was first committed:
   `git log --diff-filter=A --follow --format=%as -- <file> | tail -1`.
3. Write the folder's `README.md` (purpose, entry, subjects, every file by type, its decision
   records) and add `folder:docs/initiatives/<ID>-<slug>/` to the entry's `artifacts:`.
4. Rewrite every citation of each moved file so it resolves: `git grep -nF '<old path>'`, and for
   bare file names `git grep -nF '<file name>'`, across documents, configuration and scripts. Then
   confirm with a search of a different shape, `rg -uu -g '!.git' -F '<old path>'`, before calling
   it done: one query's empty result is not proof.
5. Run the lints (step 5) and commit.

**5. Lints, seen red.** Run `context-lint`, `register-lint docs/register` and `doc-lint` until
green, and read `register health`. Then plant one defect per check and watch it fail before relying
on it: delete a folder's `README.md` (`docs-initiative`); rename a folder so it does not start with
an id (`initiative-id`); remove an entry's `folder:` line (`initiative-folder`); add an undated file
under an initiative's `research/` (`docs-dated`). Revert each and watch it pass. Then wire the three
into the repository's pre-commit hook, naming the register path explicitly.

**Leave for later**, and say so in the handover rather than doing it: the `unsettled` material;
sorting finished work into initiatives (it stays in `docs/archive/`); `register health`'s list of
documents named by nothing, worked down over time; history rewrites; entries for standing subjects,
unless the owner asks for them.
