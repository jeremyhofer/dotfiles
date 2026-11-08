## Sessions, the fleet and the knowledge base

### Pausing and parking

**A pause, stop or end-of-day signal outranks everything**: autonomous defaults, escalation
triggers, exhaustiveness. The full precedence order is in `~/.claude/standards/autonomy.md`.

**Most pauses are CHECKPOINTS, not parks**, and three steps are unconditional: finish or cleanly
abort the unit in flight (start nothing new), **commit everything** and push where that repository's
stance allows, and update the tracker, carrying every loose end forward. Commit is the step that
matters: it is cheap, and it is what makes any stop safe.

**"Start nothing new" does not mean "kill what is already running."** A pause stops the session
DISPATCHING work; it does not authorize terminating subagents or background jobs already in flight.
(A delegate that has already reported is not in flight: `~/.claude/standards/delegation.md`.) The
asymmetry is the reason: letting one finish costs only tokens already committed, while killing
it is irreversible and discards everything it has accumulated. When one option is reversible and
the other is not, a debatable reading is grounds to ask, not to act. If running work looks
genuinely expensive against a nearly exhausted usage window, **name what is running and what
stopping it would cost, and let the user decide**; never make that call silently. Measured: an agent
killed at a hard gate, after two of its three sweeps had already returned into its context, lost
the synthesis; the inputs survived only because a stopped agent can be resumed from its transcript,
which formed no part of the reasoning that killed it. The subagents could have continued.

**Writing a handoff and stopping the session are RECYCLING steps**, conditional on a successor
actually reading the handoff. A pause that ends with this session continuing needs neither.

The five park steps in full, closing the outgoing session, arming a resume after a usage reset, the
handoff pointer and the kickoff block: **invoke skill `parking-and-handoff`.** It is needed only once
you are actually parking, handing over or recycling, all situations that announce themselves.

### Merged work is finished when its branch is gone from the remotes too

When a branch is merged and its worktree cleaned up, delete that branch on **every remote it was
pushed to**, in the same sitting. Removing a worktree drops the local ref and nothing else, so
`refs/heads/<branch>` survives on the remote, where it reads as live work to a person scanning
branches and to any tool that enumerates them. Confirm with `git ls-remote <remote>`, never with an
ahead/behind count: a push to a remote other than the one a tracking ref follows does not move that
ref, and a failed refetch leaves the refs stale, so the count can read wrong.

### The canonical-session roster

Where a domain runs long-lived named sessions ("canonicals"), they are declared in its fleet record
(the repository manifest), which is what the tools read. Hold no copy of the list in always-on
context or memory: resolve it when you need it. `fleet-canonicals list` prints every canonical,
what it owns and where it runs; `fleet-canonicals status` shows which of this machine's are live. The
domain's own fragment names its hub, the canonical that coordinates across projects. **A domain
may split what the hub does:** coordination and the one consolidated ask to the user are the hub's
by definition, while the Tier-0 writes (below) and placing handoffs can sit with another seat. Where
they are split, the domain's fragment names each seat, and "the hub" means the coordinating one.

**Only cross-project items go through the hub.** A question or report for the user that has
implications beyond one project, or needs a solution coordinated across projects, goes to the hub,
which consolidates across the fleet and asks once. **Anything confined to one project stays in that
project's own session:** ask the user there, and do not message the hub to report it or to have it
relayed. How to address a peer, what to send to whom, and when not to send at all: **invoke skill
`fleet-messaging`** before sending any cross-session message.

A canonical's identity is its NAME, not a fixed process; whoever holds the name inherits its
authority and its queue. The takeover sequence, the `fleet-canonicals` verbs, how a launch is
composed from the fleet record (including why the model is declared, never inherited), and closing
a superseded session: **invoke skill `canonical-takeover`.** Model tier policy is
`~/.claude/standards/delegation.md`.

### Writing an always-on knowledge base

Where a domain keeps its always-on ("Tier-0") rules in a knowledge base:

**Tier-0 is single-writer: only the session the domain names (often its hub) writes it.** Reads
are safe from anywhere. Every other session, canonical or delegate, **proposes** a change and never
edits a Tier-0 file itself.

**A proposal is a seven-field envelope** (`from`, `date`, `kind`, `topic`, `statement`, `evidence`,
`sensitivity`). The writer BOUNCES any proposal missing one, naming the missing field. If messaging
is unavailable, use the fallback the domain names (a committed proposal file in your own
repository, or a flagged memory the writer sweeps), and tell the user where it is.

**A topic body starts its own headings at `###`, never `##`**: `##` collides with the topic-name
heading the projection generates, rendering flat as a false sibling of every topic name.

**Placement is the writer's call, not the sender's**, including whether a rule belongs in Tier-0 at
all rather than in a skill. The always-on budget is finite; a rule needed only in a situation that
announces itself belongs in a skill and costs none of it.

Envelope templates, the fallback ladder, writer QA and disposition, and the rule that one Tier-0
change is one commit which regenerates BOTH derived outputs: **invoke skill `kb-tier0-writes`.**
