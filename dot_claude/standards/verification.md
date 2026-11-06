## Verification discipline

### Why these rules exist

Each rule below comes from a real incident in which a verification step looked sound and was not.
They are stated once, as one rule-set, so the same mistakes stop recurring one incident at a time.
The measurement behind each rule is given with it, because the evidence is why the rule exists.

### 1. A probe run in a different context than the claim proves nothing

Before reporting a measurement, ask what context it ran in and whether that is the context the claim
is about — interactive vs non-interactive shell, login vs not, agent harness vs plain shell, an
app's normal execution domain vs SSH, a tool's defaults vs the real harness config. A probe run
under different conditions than the thing it claims to measure can pass while the claim is false, or
fail while it is true. Prefer a **differential control**: run the same probe in both contexts and
compare. If a mismatch cannot be closed, state it as a caveat rather than reporting the finding bare.

**And check the differential control itself, because a control that CANNOT OBSERVE the failure will
pass and read as exoneration.** The trap is not a probe in an obviously wrong context — it is one
that *looks* like the right context and is not. Measured: a scheduled macOS agent could not read a
network volume, and `launchctl asuser` was chosen as the differential for "does the agent context
fail?". It runs attributed to the CALLING session, so it inherited that session's consent grant and
succeeded — which was read as "not a permissions problem" and sent the investigation the wrong way
for an hour. The pass was a fact about the probe, not about the agent.

**So when a probe fails to reproduce a failure, establish that it CAN detect that failure mode
before concluding the failure is absent** — ideally by making it fail on purpose, which is rule 4
applied to the instrument rather than the subject. A negative from an instrument that cannot detect
the thing is not a negative. Corollary worth holding: some failure modes are structurally invisible
from where you are standing (a GUI consent dialog cannot be seen over SSH), so "I found nothing"
must be weighed against "could I have seen it from here?". Skill `fault-isolation` names which
layers are blind from which context.

### 2. Enumerate by listing, never by a guessed pattern

For any "what exists of kind X" question — gates, configs, specs, rules — list the directory first,
then narrow. A guessed `find -name` pattern returns real hits, which *reads* like a complete answer,
so a silently missed central file gives no signal that anything was missed. Use `find -name` to
confirm a file whose name you already know, never to survey. If the enumeration will drive a
decision, treat it as a claim needing a falsifier.

**An anchored pattern encodes assumptions you never decided** — what may precede the keyword, what
may be interleaved, which characters are part of a token, which syntactic position carries the risk.
It then fails by matching a SUBSET, at exit 0, indistinguishable from a complete sweep that found
fewer things. **Anchoring fails downward and silently; loosening fails upward and visibly.** So run
the deliberately looser pattern as a control and diff the two: the delta is either real misses or
false positives, and either way you have measured the anchor's cost instead of assuming it. An
enumeration whose looser control was never run is an unverified claim.

**And the control must vary the assumption you did NOT decide.** The assumptions chosen deliberately
are the ones you will think to test; the load-bearing one is usually the one you never noticed
making. A control that loosens only the keyword, while both passes share an unexamined assumption
about quoting or field shape, agrees with the original and reads as confirmation. Measured: a
1-of-30 count and its looser control both missed 29, each assuming a quote character nobody had
chosen. The mirror failure is cheaper — loosen too far and you over-match on content added since,
which is visible because the number is obviously wrong.

**When the operation destroyed the list you need to check against, the transcript usually still
holds it.** A move, prune or rewrite deletes exactly the "before" state its verification needs,
leaving only the acting session's own account, which cannot fail. Every `Edit`/`Write` is journaled
in `~/.claude/projects/<project-key>/<session-id>.jsonl` as a `structuredPatch` carrying the removed
lines verbatim, produced by the diff engine rather than by the session, so it is an independent
record. Search it for a distinctive real value, not a section header (headers recur in fixtures),
and state the residual: a recovered index covers indexed items only.

### 3. A green control must be re-measured adjacent in time

A fix "verified" by green runs after an earlier red baseline proves nothing if the environment
between the two can drift. An earlier red is not a control — it is a measurement from a machine
state that may no longer exist. Run the control (unchanged code) and the treatment (the fix)
adjacent in time, ideally interleaved, not "red this morning, green now." If failure counts vary run
to run, treat that as a moving environment first and a code defect second, and check machine
resources (disk, tmpfs, RAM, file descriptors) before diagnosing the code. A fix that works on the
first try after a long hunt is the moment to re-test the unchanged baseline, not to report success.

### 4. A check never seen red is of unknown value — an affirmative obligation, not a passive warning

The short form is operating standard #1 in `~/.claude/CLAUDE.md` and is not restated here. But that
form is passive: it is satisfiable by merely asserting a check *could* fail, which proves nothing.
Two clauses, read together — clause 2 is meaningless to a reader who has not accepted clause 1.

**Clause 1 — manufacture the red yourself.** Citing a gate, test or check as proof that work is
complete is admissible only if **this session observed that check FAIL against a deliberate defect
in the artifact under review, then observed it pass after the defect was reverted.** Not a red from
an earlier session, and not a reasoned "it would obviously have caught this." A check only ever seen
green is reported as an unverified claim, naming what would verify it.

**Clause 2 — plant at the granularity you claim.** The manufactured red also establishes the gate's
**resolution**: how finely it discriminates. A gate seen to reject a whole malformed entry is not
thereby known to reject a single malformed field inside an otherwise valid entry. Where a claim's
strength depends on that granularity, plant the defect at the granularity being claimed — not one
coarser, even if the coarser plant is easier to author.

**The concrete tells, which is this rule-set's addition to the short form:**

- **Wrong lane** — the check runs against a target the gate does not cover. Green, but it never
  touched the thing.
- **A plant the gate erases** — a break placed in a *derived* artifact the gate regenerates before
  diffing. Plant in the source it derives from.
- **A check blind to the subject** — it runs, but the surface it claims to cover was never rendered
  or exercised. The most dangerous shape: it passes rather than erroring, masking a regression. Ask
  what a check *enumerates*, not what it is named.
- **A merged view hiding a per-axis fault** — comparing a union of two states (light+dark) lets a
  fault present in only one axis read as fine.
- **The SOURCE was tested and the claim was about the MACHINE.** A tool is edited in a dotfiles
  source tree and consumed from a deployed copy, and the two disagree until someone applies.
  Verifying a fix by invoking the source proves the fix, not the behavior anyone will meet. Run the
  check against the **deployed** copy; a tool change is done when every consuming machine has
  applied, not when it is committed. Measured twice in three days, the second time with a claim
  precise enough to be true and still wrong about the machine.
- **Values or paths that do not match the live shape** — expectations copied from a doc marked
  historical, or a flattened name checked against a nested source. Read from the live source.
- **A REPORTED exit status that is not the checked command's.** The pipeline case is familiar:
  `cmd | filter && echo "PROBLEM"` reports the status of the *last* command in the pipe, which
  succeeds on empty input, so the alarm can fire on a clean tree or never fire when `cmd` does not
  exist. Put the test on the command whose result is meant (`if grep -q X f; then …`).

  **But a pipeline is only one layer that reports a status on a command's behalf, and the others
  look more authoritative** — the agent harness's own background-task summary, and wrapper or runner
  scripts that exit 0 while the tool they invoked failed. All three produced the same false green
  within one sitting. _(The harness layer specifically was **fixed upstream in Claude Code 2.1.275**
  and re-measured fixed on 2.1.278 — see `~/.claude/standards/working-style.md`. The other two were
  never broken-and-fixed; they are how pipelines and runner scripts work, and they stand. The example
  is kept because the lesson is the shape, not the count.)_ **So the rule is not "beware pipes": the
  status you were HANDED is not evidence; the status the checked command itself produced is.** Read
  the body, not the summary. When a runner sits between you and the command, verify it propagates
  failure before trusting green.

  **A uniform result across many independent checks** (all green, or all failing identically) is
  worth treating as a sign you are measuring the harness rather than the subject — but that is a
  **backstop for the misconfigured-runner shape only, and NOT the detector.** The common case is a
  *single* command reporting green with nothing anomalous to notice, and only reading the output
  catches it. A reader who takes the anomaly heuristic as the method guards the easy case and misses
  the frequent one.

**How to apply:** before writing any verification step, state in one sentence what would be
*observably different* if the task actually succeeded, then write the command that reads exactly
that — derive the check from the success state, not from the symptom you are worried about. If a
step cannot be made to fail on purpose it is not a check; say so rather than shipping it, and tell
whoever executes the plan that refusing an impossible step is correct, not non-compliance. Then
apply both clauses: manufacture the red against the real artifact, at the granularity of the claim.

### 5. A gate reachable only through a lane can go dark, and the lane will not tell you

Rules 1-4 assume the check RAN. This is the case where it silently did not.

When a check is reachable only as a step inside a build lane, an **unrelated** failure earlier in
that lane aborts the dependency chain and every check behind it stops running. Nothing announces
this: the lane reports the failure it hit, not "and N gates did not run", so the gates behind it are
simply absent from the output — and an absent check reads like a passing one to anybody scanning
for red.

**So when triaging a lane failure, the first question is not "how bad is this failure" but "what did
this lane stop running".** Fix the failure and you restore the gates; triage only the failure and
you may never notice they were dark, including for however long the lane was red.

**The structural fix is placement, not vigilance.** A cheap structural check belongs on the **commit
path**, exercised on every commit, rather than behind a lane whose earlier steps can fail first. A
gate that runs on every commit fails loudly the day it breaks; a gate behind a lane fails silently
the day something else breaks.

**Measured, and the numbers are why this is a rule rather than a caution:** in one repository a
single unaligned markdown table aborted `lint`'s dependency on `lint-format` and left **fifteen**
workspace gates dark across a range of commits. Work authored in that window shipped defective, and
the violation surfaced only once the lane was restored — **after two long-running sessions had
independently reviewed that merge and called it clean.** In the same sitting commitlint, which runs
on the commit path rather than in a lane, correctly caught a malformed commit body. Same repository,
same day: the commit-path check held, the lane-gated checks did not.

### 6. A summary is least reliable exactly when its author made the thing

Rules 1-5 are about checks. This is about SOURCES, and it is the failure that survives all of them:
the claim never gets checked at all, because a trustworthy source already told you.

Operating standard #1 says never relay a subagent's claim unverified. That covers a source you
already suspect. The harder case is a **competent peer describing their own work** — and their
summary is not a weaker version of the artifact, it is a *biased* one, in a specific direction. The
author has the least distance from the thing; their compression is shaped by what they were thinking
about while building it, so it drops precisely the details an outside reader would go looking for.
That is the opposite of the usual intuition, which is that the person who built it knows it best.

**So: read the artifact. The pull to skip that step is strongest exactly when a competent peer has
just told you what is in it**, because at that moment reading feels redundant rather than diligent.

Measured, and by the session that got it wrong rather than by an observer: one session told another
that a rule was missing from its skill; it was already there, at a line in the very commit whose sha
it had been given. The outcome happened to be good — the push for a measurement was right and the
peer then measured it — which is its own lesson: **a correct outcome reached without method is luck,
and does not retire the finding.** The peer, in turn, verified the commit said what was claimed
before replying. That instinct is the rule working.

**How to apply:** when a peer's message is about to become a premise — for a commit, a report, a
correction, or another agent's dispatch — open the artifact it describes first. Cite the line, not
the message. This binds hardest on the claims that sound most settled.

### 7. A broken reference is a symptom, and reconnecting it is often the wrong repair

When a reference stops resolving — a wikilink to a missing memory, a doc link to a deleted file, a
comment naming a symbol that no longer exists — the reflex is to hunt for the target and reconnect
it. That reflex is wrong often enough to need a rule, because a reference breaks for two causes that
are indistinguishable from inside the document and have OPPOSITE repairs:

1. **The target was lost.** Moved, renamed or deleted while the claim it carried is still true. The
   repair is to reconnect: retarget it, or point at wherever that claim now lives.
2. **The target's SUBJECT was resolved.** The bug was fixed, the trap designed out, the feature
   sunset. The reference dangles because the thing it described stopped existing. The repair is to
   record the resolution and stop pointing. Reconnecting here is actively harmful — it restores a
   live-looking pointer to finished work, and the next reader treats a closed item as open.

**Telling them apart means leaving the document and checking the world it describes** — the code,
the deployed config, the actual repository — not searching harder inside the store for a filename
that matches. That is the whole rule, and it is exactly what a bulk relink pass cannot do.

**Why this earns a rule rather than a habit: every mechanical remedy points the wrong way.** A link
checker reports both causes with identical wording. A bulk relink or fuzzy-match pass "fixes" case 2
by construction, because it optimizes for a resolving pointer — precisely the wrong outcome there.
And the finding count dropping to zero reads as success either way. The tooling's green state is
reached fastest by making the error this rule forbids.

**Corollary: an integrity count is not a work queue.** Each finding needs a diagnosis before it needs
a fix, and some resolve to "record that this is done" rather than to an edit that clears the finding.

**How to apply.** For each broken reference ask *"is the thing this describes still a thing?"* before
*"where did the target go?"* Verify against the artifact — grep for the symbol, check the route
exists, read the config — then either retarget it, or write the resolution in place and drop the
pointer. When dropping one, say what happened to its subject and when: a bare deletion loses the
fact that the work was completed, which is usually the only part still worth knowing.
