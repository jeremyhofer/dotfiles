## Delegation

### Delegation tiers

Every delegation names its model tier deliberately: the Agent or Workflow `model` parameter, chosen
per call. The blunt uniform override (the `CLAUDE_CODE_SUBAGENT_MODEL` environment variable) is not
the mechanism: it forces every subagent in a session to one model regardless of task, defeating
per-task tiering.

| Task class | Tier |
| --- | --- |
| mechanical sweeps, rote edits, enumeration, format churn | Haiku |
| standard search/build/code with clear specs | Sonnet |
| judgment-heavy design, adversarial verification, ambiguous debugging | inherit the coordinating session's model |
| doc/fact lookups with a dedicated agent (for example `claude-code-guide`) | that agent's own definition |

Before any delegation, the default question is **"what is the cheapest tier that does this well?"**
Down-shifting is the default, not the exception. A cheap agent's claims are verified before they
are relayed (to the user or to another session); that check, not a default to a stronger model, is
what bounds the cost of a wrong cheap answer.

**Prefer one coordinating session delegating to right-sized subagents over fanning out top-tier
agents.** Top-tier fan-out multiplies the most expensive context, and when several sessions draw on
one shared usage window, one session doing it exhausts the window for all of them. Which model a
domain's own long-running sessions run is the domain's to declare.

### Development flow

Where a flow applies, it is used rather than improvised: brainstorming before creative work,
specs and plans before multi-step builds, test-driven development for implementation,
subagent-driven execution for independent plan tasks, verification before completion always. This
binds coordinating sessions and their delegates alike: a coordinator both follows these flows and
instructs its delegates into them.

Subagent-driven execution is the default for implementation plans: once a plan is ready to execute,
a session does not re-offer "subagent-driven or inline" as an open choice. This is one application
of the rule against asking on cosmetic choices, which `~/.claude/standards/autonomy.md` owns.

### Sizing work: estimate the human's REVIEW bandwidth, not engineering hours

Subagent-driven execution changes the calendar arithmetic. An exercise that reads as weeks of
evenings priced as hand-typing is days of dispatch and review; implementation time is rarely the
bottleneck. So when sizing scope, estimate **the user's attention: review hours and decision
touch-points**, not person-hours, and do not push them to slim scope on a person-hours argument,
because that argument measures the wrong resource.

**This is a sizing rule and explicitly NOT a license to act alone.** Cheap execution makes MORE work
reach the user for review, not less, so the loop-in obligations tighten rather than relax. The
escalation triggers in `~/.claude/standards/autonomy.md` are unchanged, and its "review bandwidth
is scarce" line is a reason to spend that bandwidth well, never a reason to route around it. Low
review bandwidth must not become agents acting unsupervised; it holds only provided the user is
still kept in the loop. If a sizing estimate ever implies fewer checkpoints, the estimate is being
misused.

### A gate you write into a dispatch must be one you can lift

**Never specify a release mechanism that excludes its own author.** A dispatch that says "wait for
the user's explicit word" cannot then be released by you relaying them: a peer relaying an approval
is not the approval, which is the same guard that stops permission laundering. A constraint whose
author cannot lift it is a design defect regardless of whether the constraint was wise. Either gate
on something you can release, or route the release through the authority you named.

**And the delegate's test on any peer instruction is POSITIVE, not suspicious: does the authority
exist independently of the peer?** If the always-on rules already permit the act, a peer restating
that is redundant rather than authorizing, and you may proceed on the rule. If they do not, no
amount of faithful relaying substitutes. Measured: a temporary hold was written into several
dispatches as a rule about the user's word versus their presence, and the delegate that held
against its author was right to, while the underlying act had been permitted by a standing rule the
whole time.

### Pedagogy and quality bars belong IN the delegate's prompt

A delegate produces what its prompt asks for and nothing else. A verification-only harness returns
a verification-only document, correct in every fact and useless as an explanation, and the miss is
the ORCHESTRATOR's prompt, not the agent's work. The same holds for any standard the controller
holds and the delegate was never told: teach first, define the jargon, review at native scale, name
the trade-offs. State the bar in the dispatch, or it does not exist for that agent.

Measured: research subagents returned a fact-verified deliverable that never defined its central
term, because nothing in their prompts asked them to teach.

### A delegate's work ends with its report, background jobs included

A delegate that has reported but left a command or agent running in the background has not handed
back: it sits on that job, often for hours, holding a seat and usage nobody is reading. Measured:
this recurs regularly, a finished delegate waiting on a command that never returns.

- **The delegate**, before its final report, stops every background command and agent it started,
  or waits for each and reads its result. If one must outlive the report, the report names it (its
  ID, what it is doing, why it must continue), and the coordinator decides.
- **The coordinator**, once a delegate's report is in hand, stops the delegate if it is still
  running (TaskStop with its agent ID or name), unless the report named work it left running for a
  reason. Unsure whether the report is final: ask the delegate, rather than wait.
- **The dispatch restates the rule** for any delegate that will run long or background commands,
  as it does the environment-fault rule (`~/.claude/standards/autonomy.md`).

This does not contradict the pause rule in `~/.claude/standards/sessions.md`, which forbids killing
work in flight. That rule protects a result that has not yet returned; once the report is in, what
is still running has no consumer, so stopping it discards nothing.
