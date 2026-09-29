---
name: project-documentation
description: Use when writing, filing, reviewing or moving any document in a project repository's `docs/` tree — a decision record (ADR), a spec, a plan, a runbook, a research note, a reference page, or a policy — or when deciding which of those a piece of writing should be, where it goes, or what its sections are for. Also fires when `context-lint` reports `docs-index`, `docs-layout`, `docs-dated`, `docs-retired`, `docs-outside` or `docs-nested`, when a `docs/` tree has no `docs/README.md`, on "write an ADR", "where does this doc go", "archive this spec", "is this a runbook or a plan". Covers the standard `docs/` layout, the index, what each document type is and when to choose it, the decision record's shape and the fresh-eyes review it owes, and the rules every type shares. A tracked-work entry has its own skill, `register-standard`.
---

# Project documentation: one layout, and what each document type is for

## The layout

```
docs/
  README.md    the index: one line per subdirectory and per loose document
  adr/         decision records, numbered
  register/    tracked work, one file per entry; finished ones in register/closed/
  specs/       designs for a build in progress         YYYY-MM-DD-slug.md
  plans/       execution plans for a build in progress  YYYY-MM-DD-slug.md
  runbooks/    repeatable procedures, kept current      undated
  research/    investigations, frozen once written      YYYY-MM-DD-slug.md
  reference/   the project's manual: architecture, commands, code style, testing, procedures
  policies/    governing policies           compliance/  compliance dossiers and control maps
  archive/     finished work: archive/specs/, archive/plans/, and other finished documents
  <subject>/   the project's own subjects, named in AGENTS.md's `## Layout`
```

- **Create a directory only when it has content.**
- **The index is required** wherever `docs/` exists. It names every subdirectory and every document
  loose at `docs/` root, and says what each holds. A loose document is fine once the index names it;
  move it into its type's directory when that is clearly better.
- **A project's own subjects** (search data, tax law, policies) get a directory named in the context
  file's `## Layout`. That declaration is what makes it part of the layout rather than drift.
- **Every document of a type lives under `docs/`.** A top-level `adr/`, `specs/`, `plans/`,
  `runbooks/`, `research/`, `reference/`, `evidence/`, `handoffs/` or `archive/` moves into it
  (evidence is research; handoffs are archive). A repository's subject content and tool
  configuration are not documents about the project and stay where they are.
- **A `docs/` tree below the root belongs only to a publishable package**, one whose
  `package.json` does not set `"private": true`: a monorepo package may ship its own docs. A
  single-project repository keeps every document in the root `docs/`.
- **Retired names stay retired.** No `docs/claude/` or `docs/agents/` (the project's manual is
  `docs/reference/`, and people read it too) and no `superpowers` directory anywhere (specs and
  plans are `docs/specs/` and `docs/plans/`). Declaring one in `## Layout` does not make it allowed.
- **Moving a document means updating everything that cites it**: other documents, configuration,
  gates and scripts, and archived documents too. Rewrite a path so it resolves; leave what an
  archived document says happened as it was written.
- `context-lint` checks all of this: the index, that every entry is named in it, that every
  subdirectory is standard or declared, that dated types carry dates, retired names, document
  directories outside `docs/`, and `docs/` trees outside publishable packages.

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
each decision before calling the spec finished, then move it to `archive/specs/`. A spec that
commissions a check makes "seen failing on a planted defect" its acceptance criterion.

## A plan

The execution steps for one build, each small enough to verify. Moves to `archive/plans/` when
executed.

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
