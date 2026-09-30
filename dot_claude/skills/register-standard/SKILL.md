---
name: register-standard
description: Use when creating, filing, editing, closing, migrating or linting a work-register entry in any repository — an `ABC-0012`-style entry under `docs/register/`, the register's README, its `closed/` directory, its `folder:` artifact, or its lint. Fires on "file a register entry", "close this entry", "definition of done", "closure condition", "ALIGNMENT REQUIRED", "TRIAGE REQUIRED", "standing status", `docs/register/`, `register next`, `register list`, `register show`, `register health`, `register-lint`, and on the question "is this done?" asked of a tracked item. Covers the nine statuses and which need which fields, the recoverability rule for closure conditions and the three sentinels that declare an absence, the initiative folder an entry names, why the finished-entry directory is `closed/` and never `archive/`, why each register's README must repeat the rules in full rather than cite them, who may file at all, and how a separate limitations register folds in as `held` entries.
---

# The register standard

A **register** is a repository's numbered list of tracked work: one markdown file per **entry**,
under `docs/register/`, each entry an **initiative** (a piece of work with a beginning, an end, and a
state worth seeing). An entry's **id** is a prefix and a number, `ABC-0012`. This skill is the
standard a register's README is written from.

**Scope: register entries only.** The documents an initiative produces (decision records, specs,
plans, runbooks) are skill `project-documentation`'s subject, including the initiative's folder.

**A private layer, if this machine has one.** If `~/.dotlocal/skills/register-standard.md` exists,
read it now. It names this machine's registers, their prefixes, and who files in each; where it
differs from this file, it wins.

## 0. The README governs, not this file

**Every register states its complete contract in its own `docs/register/README.md`, and cites
nothing outside the repository.** A reader of that repository may not be able to open this skill or
any other repository, so a pointer outward does not resolve; some repositories also run a commit
guard that refuses such pointers outright.

- **This skill is upstream**: the text a README is written from, and where a change to the
  standard is made first (§13).
- **The README governs entries in its repository.** Where the two disagree, the README wins there,
  and the disagreement is reported to whoever maintains the standard.

Nothing diffs the copies. Treat the README you are editing as the authority for its repository.

**When copying from this file, substitute the repository's own prefix** for `<PREFIX>` and `ABC`.

## 1. Layout

```
docs/register/
  README.md                  the contract, complete
  <PREFIX>-0009-slug.md      open entries
  closed/
    <PREFIX>-0001-slug.md    done and dropped entries
```

- **`docs/register/` in every repository**, one spelling, so every tool and reader looks in one
  place. A register found elsewhere has not migrated yet; that is drift, not a variant.
- **One register per repository.** Two programs in one repository share `docs/register/`,
  distinguished by prefix; one README, one `closed/`.
- **Closed entries move, never delete, and an id is never reused**, so a citation written a year
  ago still resolves.

### The finished-entry directory is `closed/`, never `archive/`

1. `closed/` names a status set that exists (`done`, `dropped`), not an action.
2. **Build tooling commonly skips any path containing `archive/`**, because an archived tree is
   frozen. A closed entry must keep being checked, so under `archive/` it silently drops out of
   every gate that skips the word, and the gates stay green while covering less.

`archive/` stays correct for frozen document trees (`docs/archive/`); the two words differ on
purpose. **Renaming the directory is not a rename alone:** any tool that enumerates, counts or
generates from it changes in the same commit, or it reports zero closed entries, which looks like
health. Grep the repository's scripts and configuration for the old word before committing.

### A limitations register folds in as `held` entries

A file of accepted gaps, each with an observable event that would revive it, is a list of things
deliberately deferred. That is status `held` with a `gate:` (the revive event), inside the one
register, not a second register.

- **`gate:` and the closure condition are different facts.** The gate is what would revive the item;
  the closure condition admits a second ending: *the limitation is resolved, or its acceptance is
  recorded as permanent*. Write that second arm as you fold, or record per entry why it is absent.
  Text where the two coincide is usually a narrowly written gate, not proof they are one field.
- **A limitation with no revive event, or one that can never fire, has no end.** It is not `held`;
  it belongs in a revisit list (things to look at, not to do). Report it rather than forcing a status.

## 2. Frontmatter: the state, and the only part tooling parses

```yaml
---
id: <PREFIX>-0009
title: One line, a noun phrase
status: scoped
gate:                # iff status is blocked or held
cadence:             # iff status is standing
owner: <who decides>
verified: 2026-01-20 # when someone last confirmed this entry true
closed:              # iff status is done or dropped
artifacts:
  - adr:ADR-0008
  - folder:docs/initiatives/<PREFIX>-0009-slug/
---
```

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | `<PREFIX>-NNNN`. Never reused, never renumbered. |
| `title` | yes | One line. |
| `status` | yes | One of the nine in §3. |
| `gate` | iff `blocked` / `held` | What must happen before it can move. |
| `cadence` | iff `standing` | `weekly`, `monthly`, `quarterly`, `biannual` or `annual`. |
| `owner` | yes | Who decides. |
| `verified` | yes | When someone last confirmed the entry true, `YYYY-MM-DD`. |
| `closed` | iff `done` / `dropped` | When it closed. |
| `artifacts` | no | A YAML list of `kind:value` pointers into this repository (below). |
| `supersedes`, `split-from` | no | An id this entry replaces, or was separated out of. |

**Artifacts.** `adr:` takes an id; `spec:`, `plan:`, `runbook:`, `research:` and `repo:` take a
value; `folder:` names the entry's initiative folder, `docs/initiatives/<ID>-<slug>/` (§7). A value
containing `/` is a path, resolved from the repository root; one that does not resolve is refused,
because a pointer that looks followable and is not is worse than none.

- **Omit a key that does not apply; never write it blank.** Blank and absent would otherwise mean
  the same, and a blank conditional field evades every check asking whether it is set.
- **A conditional field on the wrong status is a lie about why something is stuck**: a `gate:` on
  an `active` entry asserts a dependency that does not exist.
- **`verified` and `closed` are separate on purpose**: when it closed, and when someone last
  confirmed the write-up, are different questions.
- **Quote any value containing `#`**, list item or scalar. Unquoted, YAML reads a comment and the
  value truncates while the file still parses. Quote a value starting with a backtick, `@`, `&`,
  `*`, `!` or a bracket, or holding `: `, for the same reason.

**A migrated entry keeps its old `verified:` date and gains `migrated: <date>`.** Resetting
`verified` to the move date manufactures fresh verification out of a file move and hides real age.

## 3. The nine statuses

| Status | Means | Lives in |
| --- | --- | --- |
| `idea` | raised, not thought through; the only status exempt from a closure condition | `docs/register/` |
| `scoped` | understood, not committed to; also "written up, awaiting a decision" | `docs/register/` |
| `ready` | scoped and unblocked, next up | `docs/register/` |
| `active` | in flight | `docs/register/` |
| `blocked` | cannot proceed; `gate:` says what must clear | `docs/register/` |
| `held` | deliberately deferred; `gate:` says what would revive it | `docs/register/` |
| `standing` | accepted work with no end by design (§5) | `docs/register/` |
| `done` | closure condition met; Resolution cites the evidence | `closed/` |
| `dropped` | deliberately abandoned; Resolution says why | `closed/` |

- **Status is categorical; progress is counted** by the task checklist. A `nearly-done` status ends
  up meaning whatever its last writer felt.
- **When the only thing pending is a person's decision, use `scoped`**, not `blocked` or `held`:
  both demand a `gate:` and would assert an outside dependency.

## 4. The entry body

```markdown
# <PREFIX>-0009 — Title

## Next action
One paragraph, edited in place, for a reader who knows nothing about this entry.

## Body

### Definition of done
The closure condition (§5).

### Tasks
- [x] a unit of work, done
- [ ] a unit of work, outstanding

### Resolution
Empty until close. At close: how the condition was met, and the evidence.

## History
Append-only, newest last. One dated entry per material change.

### 2026-01-20 — what changed
```

- **`## Next action` is edited in place.** An open entry must have one; one with nothing to do
  next is finished or abandoned, and should say so.
- **`### Tasks` makes progress counted, not asserted**: N of M, no weights, no estimates, so it
  cannot rot. Its history in version control is a burndown for free.
- **`### Resolution` is required to close and cites evidence**: a commit, a record, an artifact.
  Closing is a claim, and a claim needs a referent.
- **Durable narrative belongs in a decision record, spec or runbook**; the entry cites it.
- **A filename begins with its id**, so a rename cannot orphan it from its citations. Truncate the
  slug at a word boundary.

## 5. The closure condition

**Written on the way in, not on the way out.** An entry may not leave `idea` without one. Most
arguments about whether something is finished are about a condition nobody wrote down, and while
the work is still hypothetical is the only time it can be written honestly.

### Recoverable, not invented

- **Write one wherever it can be recovered** from what is already known (the entry's words, its
  title, the repository's state, an earlier decision) without making a design decision.
- **Where writing one would settle something unsettled, do not**: that pre-empts the design.
- **Test outcome against mechanism first.** A condition says what done looks like, never how.
  *"Transactions arrive with no manual capture step"* decides nothing about which provider, so an
  entry with an undecided tool usually still has a recoverable outcome.
- **Unrecoverable means the outcome itself is unchosen**: the work is undesigned, or the entry is
  two threads under one id and needs splitting first.
- **Recovery is often partial.** State the recovered half as binding and mark only the remainder.
- **Recoverability is judged per moment.** Re-test a sentinel when the entry changes shape (split,
  decomposed, a decision landed); a sentinel records a judgement nothing else re-examines.

**Blocked and unwritable are independent.** An entry can be fully gated and perfectly defined:
use `blocked` with a `gate:` and a real condition. Do not park it at `idea` because it cannot start
(that buys the exemption for the wrong reason), and do not give it a sentinel because it is blocked.

### The three sentinels

The section is never blank. When no condition can be written, one of these stands **on its own
line**, followed by what is known, what is not, and why; the second half names the conversation
that has to happen.

| Sentinel | Means | Who owes the next move |
| --- | --- | --- |
| `NONE REQUIRED` | status is `idea`; no condition is owed | nobody |
| `ALIGNMENT REQUIRED` | writing one would decide something undecided | the human who decides |
| `TRIAGE REQUIRED` | inherited without one and not yet examined | whoever maintains the register |

- **Three, not two, because the owners differ.** Folding triage into alignment queues work for the
  decider that needs only a maintainer's half-hour, diluting the one signal that means a person is
  genuinely needed.
- **`TRIAGE REQUIRED` is for a register inherited and set aside**, typically a migration done under
  an instruction not to triage. Whoever is dispositioning entries is looking, so their answer is a
  condition, a partial one, or `ALIGNMENT REQUIRED`, never `TRIAGE REQUIRED`.
- A blank section and an unwritable one look identical; the sentinel is the difference, and it
  greps: `grep -rln '^\(NONE\|ALIGNMENT\|TRIAGE\) REQUIRED' docs/register --include='*.md'`.

### `standing`: work with no end

In place of a closure condition, a `standing` entry states: (1) **what is re-verified**, concretely
enough for someone else to do it; (2) **the cadence**, also in `cadence:`; (3) **the de-standing
trigger**, which always includes *the re-verification stopped happening*. Without all three it is
`active` wearing a label. A `standing` entry whose `verified:` is older than its cadence is stale,
and the lint refuses it.

`standing` is for perpetual *doing*. Perpetual *looking* ("re-check on each major release") belongs
in a revisit list. Report standing entries apart from closing work: a burndown that counts items
that never burn down is not read.

## 6. Who may file

**Three tests, each able to fail alone:**

1. **Did the human who decides indicate it should be tracked?** In any words: *"back-burner it"*,
   *"can be a backlog item"* count. An agent deciding something deserves an entry does not: a finding
   needs no entry to be useful; fix it now, or report it and let them choose.
2. **Does an entry already cover it?** Search before authoring, every time; approval to track says
   nothing about duplicates. Where a related entry exists, extend it: two entries for one concern
   split its history, and neither knows about the other.
   `register list --match '<topic>'` searches ids and titles; `grep -rli '<topic>' docs/register`
   searches bodies.
3. **Is it an initiative?** A beginning, an end, a state worth seeing. A finding, defect or task is
   content inside one (its checklist or history). If you cannot honestly write a closure condition
   and a task list, it is not an entry. Chores and routines are not entries.

**Allocate the id with `register next`.** It reads every id numerically, `closed/` included, and
keeps the register's width. A new register's first id is written by hand (`<PREFIX>-0001`, padded
to the width you want kept): with no entries, every `register` command stops with "holds no
entries". Never read the highest id off a listing: a lexical sort puts `99` after `100`, and
sessions have double-allocated that way.

Who may file in a given repository is a rule held by reading; no tool distinguishes one author from
another. The README says who, and says that nothing enforces it.

## 7. The initiative folder

An initiative with documents of its own gets one folder, `docs/initiatives/<ID>-<slug>/`, created
with its first document and named once in the entry's `artifacts:` as
`folder:docs/initiatives/<ID>-<slug>/`. The id in the folder name and the `folder:` pointer link the
two in both directions, so neither can drift from the other unnoticed.

- **At `done` or `dropped` the folder moves to `docs/archive/initiatives/`** and the `folder:`
  pointer is rewritten to the new path, in the same commit that closes the entry.
- **A recurring cycle (a quarterly review, a yearly plan) is a new initiative each time**, so each
  cycle closes.
- What goes inside the folder, its README, and the full close sequence: skill
  `project-documentation`.

## 8. Lookups

All take `--root <dir>`, default `docs/register`, so run them from the repository root.

| Question | Command |
| --- | --- |
| What is open, and where is each one's folder? | `register list --open` (`--status active`, `--match <regex>`, `--long` adds gates) |
| Everything about one entry | `register show <ID>`: the entry, then its folder's files by type subdirectory and the decision records its README names |
| Counts by status | `register stats` |
| What has gone quiet or unclaimed? | `register health`: an `active` entry whose folder has no commit in 30 days, a `standing` entry past its cadence, a document in the repository-wide type folders named by nothing or by one initiative only. Advisory; always exits 0 |
| The next free id | `register next` |
| A browsable table | `register index --write <path>`, on demand; never commit one, since a derived file nobody regenerates is believed while wrong |

## 9. Enforcement: `register-lint`

`register-lint [docs/register]` runs on the **commit path** (a pre-commit hook), not in a build
lane: a gate inside a lane goes dark whenever an earlier step fails, and nothing reports that it
did not run.

**Blocking:** `closure-condition`, `undeclared-absence` (prose like "TBD" or "not recorded" with no
sentinel; a heuristic), `sentinel-mismatch`, `conditional-field`, `empty-field`, `yaml-truncation`,
`yaml-invalid`, `artifact-path`, `initiative-id` (a folder under `docs/initiatives/` or
`docs/archive/initiatives/` whose name does not start with an id in this register),
`initiative-folder` (a live folder its entry does not name as `folder:`), `initiative-place` (a live
folder for a closed entry, or an archived one for an open entry), `status-vocabulary`, `location`,
`resolution`, `next-action`, `filename`, `id-integrity`, `required-field`, `date-format`,
`standing-stale`, `not-renamed` (finished entries under `archive/`).
**Advisory:** `triage-debt`, `alignment-owed`, `stale-entry` (an `active` entry unverified for 30
days, `ready`/`scoped`/`blocked`/`held` for 90). The prefix is derived from the entries, never
configured.

**What it cannot check:** whether a condition is a good one, whether the tasks reflect the work,
whether an entry should exist, or who filed it. The README's "What is not built" section says so.

**Believe it only after seeing it red.**
1. Reach a green baseline first. On a register with findings outstanding, a planted defect is
   indistinguishable from the existing red, and the exercise proves nothing.
2. Plant a defect at the granularity you are claiming (one bad field, not a whole broken entry),
   watch the lint fail, revert, watch it pass.

A checker that tested only "the heading has text under it" once passed the literal string `TODO`;
that is why the sentinel vocabulary exists.

**Wiring it:**
- **Name the register path in the hook.** An absent register is "nothing to check" and exits 0, so
  a hook pointed at the wrong path is permanently green. Confirm the entry count it prints.
- **Scope it to the pre-commit stage**, so it runs once per commit.
- **A commit that moves the register updates the hook in the same commit.**

**Moving or folding a register breaks things outside it.** Relative links in moved content resolve
one level short; repair each by resolving it against the new location, not by assuming a uniform
depth shift. Before retiring an old register file, enumerate every tracked file citing it, and
prefer a redirect to a deletion.

**Tooling is a size question.** Below roughly twenty open entries, `register list` is enough; the
README says which regime the register is in. A migration that crosses the threshold does not make a
new aggregate tool due in the same commit.

## 10. Referring to things outside the repository

- **Never cite another repository's ids or paths in an entry.** A pointer the reader cannot open
  looks like it resolves. Write the reasoning into the entry and cite nothing.
- **If the repository has a publish or leak guard, run it before declaring a migration done.**
  Content written for months without that boundary in mind is exactly what a move drags across it.
  Record a guard refusal inside the entry it affected.
- **Let the guard decide what is publishable**: stage the text and run it. Earlier occurrences are
  evidence about the past, and reading its pattern file can mislead where exemptions apply after
  matching.
- **A bare `ADR-NNNN` is this repository's own decision log.** Where two logs both number from
  0001, open both candidates and let a date or heading settle which is meant.
- **Never write a bare number** (`#36`); write the full id or a qualified form.

## 11. Query traps

- **The README matches itself**: its template lists every status, so `grep 'status: active'`
  returns it. Anchor with `^` and scope to the id pattern, or use `register list`.
- **An unmatched glob is an error in zsh**, so `grep … docs/register/ABC-*.md` fails exactly when
  every entry is closed. Use `grep -r … --include=`.
- **Anything that counts `*.md` in the directory counts the README as an entry**, silently. Exclude
  it by name.
- **Cross-check a completeness claim ("the old id appears nowhere") with a second command of a
  different shape.** A pipeline has been seen returning empty on a pattern plainly present.

A query is tested in the state where it returns nothing, and a count against a number found
another way.

## 12. The README template

Copy into `docs/register/README.md`, substitute the prefix and domain, and fill every section.

```markdown
# The <PREFIX> register

Tracked work for <domain>. One file per entry; closed entries move to `closed/`, never deleted.

This file is the complete contract for entries in this repository. It cites no document outside
the repository, deliberately.

## What earns an entry
## The id, and where it may appear
## The shape of an entry            (frontmatter table, artifacts incl. folder:, body sections)
## Status vocabulary                (all nine, and which live in closed/)
## The closure condition            (the recoverability rule and the three sentinels)
## Initiative folders               (folder:, archiving at close)
## What is not built, and why       (what does not enforce these rules)
## Referring to things outside this repository
```

**"What is not built" is required**: a reader assumes a gate exists unless told otherwise.

## 13. Changing the standard

- **Operative text** (wording, a recorded trap, a clarification that decides nothing): change it
  here first, then in every register's README in the same sitting.
- **A decision** (a new status, a directory name, who may file): record it in the owning
  repository's decision log, decided by the human who decides, before changing it here; otherwise
  the registers run ahead of the record that governs them.

Nothing diffs this skill against the READMEs, so a change reaches a repository only by hand.
