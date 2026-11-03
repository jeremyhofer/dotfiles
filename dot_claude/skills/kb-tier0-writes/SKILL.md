---
name: kb-tier0-writes
description: Use when proposing, authoring or adjudicating a change to an always-on ("Tier-0") knowledge base that many sessions load at startup — writing a KB proposal envelope, filing a proposal when cross-session messaging is unavailable, or (as the single writer) placing, bouncing or committing an incoming proposal. Fires on "KB proposal", "Tier-0 rule", "amend-rule", "new-rule", "drift-report", `kb project`, `kb index`, `kb lint`, and on the question "should this be a Tier-0 rule or a skill?". Covers the single-writer rule, all seven required envelope fields, the fallback ladder, writer QA and disposition, and why a commit must regenerate every derived output.
---

# Tier-0 knowledge-base writes

**Tier-0** is the small set of rules every session loads at startup. It is a knowledge base of topic files plus generated outputs. The **writer** is the one session (usually a coordinating hub) allowed to edit it. This skill is the procedure; where a domain half exists (last section) it names the writer and the repository.

### Rule

**One writer.** Reads are safe from anywhere. Every other session, canonical or delegate, proposes a change and never edits a Tier-0 file itself. Reason: the content is loaded by every session, so two writers produce contradictory always-on rules nobody reconciles.

**Placement is the writer's call, including whether a rule belongs in Tier-0 at all.** The always-on budget is finite. A rule needed only in a situation that announces itself belongs in a skill, which costs nothing until loaded. Ask "should this be Tier-0 or a skill?" before drafting.

**A topic body starts its own headings at `###`, never `##`.** `kb project` renders each topic as `## <topic-name>` followed by the body verbatim, so a `##` in a body renders as a false sibling of every topic name. Nest deeper as needed.

### Say which "kb" you mean

Two things share the name. **The `kb` CLI** (`kb lint`, `kb index`, `kb project`) ships in the public dotfiles base. **The KB records** (the topic files) live in a repository the domain names, which may be private. Never write a bare "kb": name the layer, and when one sitting touches both, report by repository first. A public tool's changelog naming private records crosses a publish boundary, and the crossing is invisible if both are called "kb".

### The fallback ladder

Get a proposal to the writer in order, depending on no one channel being up:

1. **Message the writer by its canonical name** when cross-session messaging exists and the name resolves (skill `fleet-messaging`, section 0, says how to tell).
2. **If the name does not resolve, messaging is unavailable, or the writer is parked:** write the proposal as a file in a place the writer's session will read. Preferred: a file in your own project repository (for example `proposals/kb/<date>-<slug>.md`), committed, so it survives and is reviewable. A flagged memory file in your own store is the weaker form, since it is unversioned and tied to one machine; use it only where the domain's half says the writer sweeps those. Either way, **tell the human the proposal exists and where**: with no channel, the human is the courier.
3. **The writer works its inbox as a standing item of each sitting** (messages, plus whatever files step 2 names). That sweep is manual.

A proposal with no courier, no channel and no sweep is not filed; it is lost. Say so rather than assuming it will be found.

### The envelope (all seven fields, always)

Whether by message or file, a proposal carries exactly these. The writer BOUNCES any proposal missing one, naming the field. A malformed proposal is returned, never guessed at.

- `from:` session name + project (for example `project-a-canonical / project-a`)
- `date:` when observed or decided
- `kind:` one of `new-rule` | `amend-rule` | `override-note` | `drift-report`
- `topic:` the target Tier-0 topic, or `new-topic:` plus a proposed name
- `statement:` the proposed canonical text: one rule, self-contained for a cold reader
- `evidence:` the incident or decision that motivated it, and where it is recorded
- `sensitivity:` the sender's confirmation the content is internal-or-lower (nothing restricted rides along)

#### Example, message form

```text
KB proposal
from: project-a-canonical / project-a
date: 2026-08-17
kind: new-rule
topic: signing
statement: A subagent that cannot reach the signing agent must fail loudly and stop; never fall back to an unsigned commit.
evidence: unsigned-commit near-miss in project-a; recorded in its decision log, entry 12
sensitivity: internal, no restricted content
```

#### Example, file form (committed in your own repository)

```text
---
name: proposal--signing-fail-closed
kind: new-rule
topic: signing
from: project-a-canonical / project-a
date: 2026-08-17
sensitivity: internal
---
statement: A subagent that cannot reach the signing agent must fail loudly and stop; never fall back to an unsigned commit.
evidence: unsigned-commit near-miss in project-a; recorded in its decision log, entry 12.
```

### Writer QA and disposition

`kind:` and `topic:` are the sender's PROPOSAL, not routing. On intake the writer assesses whether the item is the kind and scope claimed: it may belong in a better topic, amend an existing rule rather than duplicate it, be a narrower per-project override, or (drift-report) already be canonical content the sender had not seen. The writer then tells the originator the disposition: the final home (topic file + rule name), what was reshaped and why, or the bounce reason.

- **Messaging available:** the disposition returns as a direct message. The originator rewrites its local copy into a pointer stub at the named home.
- **No messaging:** the disposition ledger IS the git log. The commit message names the source envelope, and each topic's `### Provenance` section lists the envelopes it absorbed. The originator checks its outstanding proposals against that record at its next opportunity and stubs them itself.

Either way the originator ends up knowing where the information lives, which keeps its future proposals well-aimed.

**Promotion is content-rewriting, never file-moving.** The writer authors the canonical statement fresh; it does not relocate the sender's file. Material that cannot travel (restricted detail) therefore never rides along into a file that is internal-or-lower by construction.

### Writes are atomic and tracked

One logical Tier-0 change is one commit, made at write time, with a standard message carrying the envelope's provenance (`kb: <kind> <topic>, from <agent>`, evidence pointer in the body). Git history is the quality log for the no-messaging case, which is what makes the format load-bearing.

When an immediate commit is impossible (signing unavailable, mid-batch), the writer journals the pending file states and flushes them to commits before its sitting ends, so a parked writer never strands uncommitted Tier-0 state.

Recovery from corruption is `git revert` or checkout of the affected topic files, then regenerating BOTH derived outputs, which are always derivable from the topic files and never authoritative.

**There are TWO derived outputs, and a Tier-0 commit regenerates BOTH.** `kb project` renders the projection every session loads at startup; `kb index` regenerates the source-of-truth and backlink indexes. Run both in the same commit as the topic edit. Regenerating one is not evidence the other is current: a fresh projection makes the layer people look at correct, so a stale index goes unnoticed (it once omitted a whole topic for twelve days while every projection was right).

**This is gated, not left to habit.** `kb index --check` and `kb project --check` regenerate to a temporary location, diff against the committed files, write nothing, and exit non-zero naming each drifted file; the checker and generator are the same code, so they cannot disagree about "current". A KB repository wires `kb lint`, `kb project --check` and `kb index --check` into its pre-commit; `kb install-hooks` generates that hook, and a repository with its own hook adds them as a gate. Put them on the commit path rather than inside a build lane, because a gate behind a lane goes dark silently whenever an earlier step in the lane fails.

Where hooks are barred or unavailable, run the three checks by hand before each commit; a check you did not run is a check that did not pass.

### Writer takeover

Proposals address the writer's NAME, not a fixed session, so whoever holds the name inherits its write authority and its queue. Taking the name over follows your setup's canonical takeover procedure.

---

If `~/.dotlocal/skills/kb-tier0-writes.md` exists, read it: it is this domain's half (who the writer is, where the KB records live, how proposals reach it in practice, the standing sweep, and the dated incidents behind the rules). If it does not, the generic content above is the whole picture.
