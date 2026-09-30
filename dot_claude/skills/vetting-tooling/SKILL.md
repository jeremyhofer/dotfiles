---
name: vetting-tooling
description: Use when recommending, selecting, or adopting a tool, library, framework, or service — "what should I use for X", "which of these should I pick", comparing candidates, or endorsing a specific tool someone named. Applies especially to quick picks under time pressure ("I want to choose today"), which is when the process below gets skipped.
---

# Vetting tooling

A recommendation assembled from model knowledge is a **direction, not a decision**. The decision
exists only after live verification — and the failure mode this skill exists for is delivering a
direction with a decision's confidence. That is the false green of tool selection: it ends the
investigation with nothing underneath it.

## The process

1. **Check the decision record first.** Search the project's work register (for example
   `register list --root docs/register --match <domain>`) and its decision-record index for the
   domain before proposing anything — an existing row or decision record may already own it, and the right move is extending
   that record, not opening a parallel decision. Recommending into an owned domain without reading
   its record is how shadow decisions happen.

2. **State the requirements from the record and the user's values before naming candidates** —
   non-negotiables first (config model, self-hosting, license posture). Candidates are judged
   against stated requirements, not general goodness.

3. **Derive the shortlist; never assume it.** Run a discovery sweep beyond the names that came to
   mind or were suggested, and keep a dismissals list — one line per rejected candidate. A reader
   must be able to see the shortlist came from the landscape.

4. **Verify against today's reality, with dates.** Release cadence over the last 18 months,
   bus-factor from actual commit distribution, open-issue hygiene, license file (not the repo
   badge), security advisories — from the live source (GitHub API, official docs), cited. Model
   memory is stale in exactly the ways that decide these calls: rewrites ship (criticisms of v5
   may not survive v6), maintainers leave, betas stall for years. Anything not verifiable right
   now is written as **unverified**, never guessed.

   - **A `WebFetch` result is not the live source.** It is a small model's answer about the page,
     and it produces confident, quote-shaped text. Fine for "does this page exist, roughly what
     does it cover". Once a detail becomes a premise (a license term, a scope, a version), download
     the file (`curl -fsSL -o "$TMPDIR/f" <raw-url>`) and grep it yourself.
   - **Bus factor is a weighted risk, not a filter.** Effective risk is roughly blast radius if it
     stalls × migration cost × likelihood of stalling. Replaceability dominates: a single-maintainer
     tool behind a simple, standard interface (POST to a URL, exportable state) costs little to
     leave, so its bus factor barely matters. Scrutinize single maintainers hard only for the
     **spine**: tools holding irreplaceable state or that everything else depends on (config
     management, secrets, provisioning). For low-lock-in niceties (dashboards, notifiers), a
     healthy, active single-maintainer project is a fine adoption. An over-strict reading of this is a
     known failure.

5. **The two checks that keep biting:**
   - **Config model:** is the config file an input the daemon obeys, or state the daemon owns and
     rewrites? A "declarative" tool whose daemon overwrites its own YAML is not declarative.
   - **Consumption model for placement:** "would I use this elsewhere/at work?" is answered for
     the artifact *as deployed and consumed*, not for its content in the abstract. Generic content
     with a personal-only consumption model is a private-tier artifact.

6. **Price is a tiebreaker, not a criterion.** For a paid tool, service or product, rank by
   capability, quality, fit and the provider's durability before price.

7. **Record it:** per-option trade-offs and the rejected candidates go in the decision record — they are the
   part worth re-reading. The user's re-weighting of your criteria (e.g. elevating bus factor for
   trust-critical infrastructure) is legitimate and gets recorded as a re-weighting, not silently
   swapped in as if it were the original analysis.

**Cost:** a heavy verification pass is a candidate for delegation to a cheaper model rather than
running inline on the most expensive session model.

## Under time pressure

"Pick today" changes the deliverable's *label*, not the process: give the direction, marked as a
direction, with the named closer ("verified pass over X/Y/Z before this becomes the decision").
Never promote it to a pick.

| Rationalization | Reality |
|---|---|
| "It's a quick pick, not a record-grade decision" | Then say "direction" and name the closer. The label costs one word. |
| "This tool is well known; the facts are stable" | Stalled betas, license changes and maintainer exits are precisely what memory misses. |
| "The user asked for a pick today" | They asked for your best deliverable today — a labeled direction with a closer IS that. |
| "I already compared these recently" | Dated evidence or it's memory. Cite the research doc or re-verify. |

**Red flags — you are about to ship a false green:** a named pick with zero tool calls behind it ·
no dismissals list · no dates on any claim · "adopt/fine to adopt" without the word "unverified"
appearing anywhere · recommending in a domain you haven't searched the record for.

---

If `~/.dotlocal/skills/vetting-tooling.md` exists, read it: it is this domain's half (where the
decision record lives, and the owner's standing preferences on price and delegation). If it does not,
the generic content above is the whole picture.
