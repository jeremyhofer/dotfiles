## Correction propagation

### The rule

Correcting a claim is not finished when the body that states it is fixed. It is finished when
**every place that restates or DEPENDS ON that claim is corrected in the same edit**: frontmatter
descriptions, index lines, portfolio rows, tables of contents, README command lists, handoffs, and
same-document cross-references. A body fix that leaves its own index line asserting the old claim
is not a completed correction; it is a narrower instance of the drift the fix was meant to remove.

### The one principle underneath all of it

**The body OWNS the claim; every other layer derives from it or points at it.** Two consequences
follow, and every specific rule below is one of them applied to a different layer:

1. **The derived layer is the one that loads first.** Descriptions, index lines and handoffs are
   read at session start or on first glance; the body is read on demand, if ever. So the stale copy
   is usually the copy that gets acted on, the inverse of the intuition that a summary line matters
   less than the "real" content it points to.
2. **A check cannot see the layer outside what it enumerates.** A sweep that verifies bodies scores
   a store with this defect CLEAN, because the contradiction lives one layer up from what it
   examines. This is the verification anyone reaches for first, which is exactly what makes the
   class invisible.

Consequence 2 is why this section is long rather than one paragraph: the failure recurs at **every**
layer, and at each one the check that would seem to cover it does not.

### The layers

The chain is multi-hop, and propagation is checked across the whole chain, not just the next link
downstream of whatever you happen to be editing.

| # | Layer | Relation | Why the obvious check misses it |
| --- | --- | --- | --- |
| 1 | the body | **owns** the claim | — |
| 2 | embedded summary: frontmatter `description:`, header comment, doc-string | restates | sits *between* body and index, so "grep the index" walks straight past it; some flows generate the index line FROM it |
| 3 | index line, portfolio row, TOC, README command list | restates | a body-only sweep never looks up |
| 4 | **handoffs**, outside the store entirely | restates | a body/description/index sweep of the store scores CLEAN. This is the highest-traffic copy of all: committed, pushed, and the first thing a successor session is handed to read |
| 5 | same-document cross-reference: "as described below", "the cleanup pass", "see §" | **depends**, does not restate | shares no text with the claim, so grepping the changed claim never touches it (see below) |
| 6 | **the per-project memory store**, `~/.claude/projects/<key>/memory/` | restates | **the only layer in a DIFFERENT SYSTEM from the artifact.** The sweep above runs in the repository; the stale restatement is outside it, enumerated by no repository check and cross-referenced against a repository by no memory check |

**The author of a correction is the WORST-placed person to notice its derived layer is stale**, and
this is structural rather than carelessness: they are holding the corrected version in mind, so the
edit feels finished. Measured: four instances in one day across three sessions, every one authored
by someone who had just made the correction, and every one caught by an outside prompt rather than
by the author looking again. One was written in the SAME SITTING as the correction it contradicted.
So the check is mechanical or it is prompted from outside; "remember to propagate" is the one form
that has never worked.

**Layer 6 needs a different trigger, because a sweep cannot reach it.** Layers 2-5 are found by
grepping outward from the edit; a memory store is not in the tree being swept. **So the trigger is
the COMMIT: when a commit closes, fixes or removes something a memory asserts, amend that memory in
the same sitting.** Not at a later audit: nothing schedules one, and nothing propagates a commit
into a store.

**And when reading any memory that asserts an ABSENCE** ("nothing in the repo says…", "no gate
covers this", "not adopted", "not merged"), **re-verify the absence against the artifact before
relying on it.** An absence claim is the kind a single commit falsifies silently, and it fails in
the expensive direction: a stale absence does not merely fail to help, it reports work as
not-yet-due.

**How to apply.** After editing any file that has a summary or pointer entry anywhere, grep every
layer between the edit and the outermost index for the claim just changed, **in the same edit**,
not as a follow-up. Include the handoffs directory, not just the store. When a handoff carries a
*conditional* instruction ("if X is fixed, correct that memory"), treat the condition firing as an
edit to that handoff. Where handoffs are reached through a recorded pointer, re-record the pointer
after editing a handoff's content; a stale pointer time is a separate failure, and a launch guard
that checks it will refuse.

### The check runs in BOTH directions, and the reverse one is worse to skip

Correcting a body means propagating outward to every restatement. Correcting a restatement means
opening the file it points at and checking the body agrees.

The two directions are not equally bad, and the asymmetry is why the reverse is mandatory rather
than optional. A stale index over a corrected body misleads the skimmer, but anyone who opens the
file still gets the truth. **A corrected index over a still-stale body is worse**: the skimmer now
gets the truth while the reader who does the careful thing, opening the file the index points at,
gets the superseded claim, with a freshly corrected index line vouching for the store's maintenance
on the way in. It punishes exactly the diligence that was supposed to be the safe path.

The actionable core: editing an index line either propagates a fix already made upstream (benign)
or papers over an upstream defect never fixed (malignant), **and you cannot tell which from the
index alone.** That inability, not symmetry as a principle, is what makes the reverse check
mandatory every time a restatement is touched.

### Layer 5 in full: a body can go stale against ITSELF

Layers 2-4 restate a claim they do not own, so they contradict it when it changes. A
cross-reference does the opposite: it asserts nothing about the claim's content, so it breaks when
the target section changes **shape** rather than its facts. The pointer stays grammatical, the
section still exists, nothing looks wrong in isolation; only a reader holding both halves at once
can see that the thing pointed at is no longer the thing described.

This is why the sweep above cannot catch it: every other layer is found by grepping for the
*changed claim*, because a restatement contains it. A cross-reference contains only a pointer, and
shares no text with the claim at all. So a sweep that runs correctly and fixes every restatement
still scores the document CLEAN with the broken cross-reference untouched.

**The rule: when a section changes SHAPE, grep the same document for references TO it**
(`below|above|the .* pass|described|see §`) and check each hit still describes what it now points
at, in the same edit. **In practice this is found by reading, not grepping**, which is worth saying
plainly rather than pretending a mechanical check exists; the searchable half is knowing to look,
and that one grep is cheap and bounded.

### Before rewriting a value, ask whether this document OWNS it or QUOTES it

Determine whether the document **owns** the path, identifier or figure you are about to correct, or
merely **quotes** it from another artifact. Correcting a quoted value manufactures a false
quotation: the document then asserts something about the other artifact that the artifact does not
say. Verify the artifact instead, and record what it actually now contains.

**An existence check cannot detect this**, which is why it needs stating: a quoted path may still
resolve perfectly. Same asymmetry as above, one layer out: there, a derivative must not be corrected
without checking its source; here, a quotation must not be corrected at all, because its
correctness is a fact about someone else's artifact. Diagnosing which repair a broken reference
needs at all is rule 7 of `~/.claude/standards/verification.md`.

### RE-OPENING a closed item is a claim, and needs evidence exactly as closing one did

Everything above assumes a correction fails to travel outward. The reverse happens too: an item
that was **correctly closed** gets re-opened by a downstream document, each hop adding confidence
and none adding evidence. Measured across three documents in one project over three days: a
closure softened by the next day's memory, then escalated by a handoff into a real decision filed
with a deadline, with no new evidence at either hop; re-measurement confirmed the original closure
exactly.

No check above sees this, because the claim never changed: a closed item merely acquired an open
status. And the asymmetry runs the wrong way: re-opening *looks* like diligence, so it draws no
scrutiny, while the cost lands outside the store, in a human's decision queue.

**How to apply.** When a document treats an item as open and an earlier document closed it, the
burden is on the **re-opening**: name what changed. If nothing did, restore the closure and state
which document supersedes which. Softening a closure without evidence is an edit, not a hedge.
