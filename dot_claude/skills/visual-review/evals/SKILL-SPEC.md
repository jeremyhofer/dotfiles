# visual-review — skill spec

What this skill is for and how to tell whether it works. Claude Code loads only `SKILL.md`, so this
file costs no context. Test runs and their results are logged by whoever maintains the skill, not
here; this file says what a run must show.

## Purpose

Stop a session from calling a UI change done after looking at a full-page screenshot. Rendered into
a chat transcript, that image is scaled down, so a 1px border or a subtle divider is simply absent
from what the reviewer sees. The incident behind it: an account-row redesign was declared done with
borders that did not render at all, because a CSS custom property name had a typo and fell back to
nothing. The second purpose is the human at the screen: a browser automation run that opens visible
windows interrupts whoever is there (six windows, at bedtime, once).

## Placement and where it applies

- **Placement:** public base. No private fragment.
- **Applies:** every domain and both operating systems, in any project with its own Playwright
  install (`ui-shot` resolves the project's, and fails loudly without one).

## Effect claims

Each is an outcome a session without the skill gets wrong often enough to measure. The fixture is a
small static page with a token stylesheet and a Playwright install.

| Id | Claim | Graded on |
| --- | --- | --- |
| `crop` | Before calling a UI change ready, the session captures the changed element on its own at native scale, not only the full page | the session's actions: an element screenshot, a clipped screenshot, or `ui-shot --selector` |
| `token` | Told a token-based style change is in, the session finds that it does not render (the token name is misspelt and resolves to nothing) and fixes it | the end state, rendered: the element's computed bottom border is non-zero |
| `dark` | Asked to check a theme whose dark arm is a `prefers-color-scheme` media query, the session renders the page under the dark condition | the session's actions: `ui-shot --color-scheme dark`, a Playwright `colorScheme: 'dark'` context, or `emulateMedia` |

**Not measured, with the reason:** "never opens a headed browser". The trials run with no display,
so a headed run cannot be observed as a window, and a headless session asked to debug a test almost
never reaches for `--headed` unprompted, so neither arm would fail. `ui-shot` having no headed mode
enforces it mechanically.

## Should-fire situations

The reached-for test's positive prompts. Each is a task with a deliverable, never a request for the
skill.

- A divider was added under each account row; confirm the change is good to merge.
- A card border was switched to the brand border token; check it renders and say whether it is done.
- Make the site header sticky when scrolling, and make sure it looks right.
- Add a dark colour scheme and check that both versions render well.
- Bump a button's padding and say how it looks.
- An end-to-end login test fails intermittently in CI; work out what the browser actually sees.
- Check the accounts page at a phone width for layout breakage.
- Amounts should be right-aligned in a column; verify the page shows that.

## Near-misses

Tasks that share the vocabulary but need no visual review. None should invoke the skill.

- Rename a CSS class everywhere in the project.
- Write a unit test for a price-formatting function.
- Count the custom properties a stylesheet defines.
- Add alt text to every image.
- Explain what the Playwright config configures, changing nothing.

## Failure signature

- "Looks good" with only a full-page capture in hand.
- A computed `0px none` border read as proof of a broken token: an element that is correctly
  borderless computes the same; `--token` is the check that discriminates.
- A "crop" the size of the page, from selecting a wrapper; `ui-shot` prints a warning.
- A `--selector` that matches nothing: `ui-shot` exits non-zero.

## Success measure

Written before the first effect run (2026-10-04), so a result cannot move it.

- **Reached for:** on Opus 5.5, at least 80% of should-fire trials and at most 20% of near-miss
  trials invoke the skill, at three trials per prompt, and a copy with its description replaced by a
  generic phrase of the same length fires clearly less. Also run on the two models used at work,
  Opus 4.8 and Sonnet 5, as floors.
- **Effect, per claim:** first, 5 trials with the skill removed. If all 5 pass, a session already
  gets this right without the skill; the claim cannot show an effect and is a candidate to cut from
  the body. Otherwise, 10 trials with the skill as deployed against 10 without, started together. The
  claim holds when the deployed arm passes more often, with Fisher's exact test one-sided p < 0.05
  (for example 8 of 10 against 3 of 10). Report counts with exact intervals.
- **Field:** invocations against sessions that render pages (Playwright, `ui-shot`, ImageMagick),
  counted from session transcripts at each periodic review. The first count, over September 2026,
  was 15 invocations against about 170 such calls. A fall below that is a finding.

## Test cases

The prompts, fixtures and graders live with the private test harness until the pilot of this spec
format is complete; they move into this directory then.
