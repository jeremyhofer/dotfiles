---
name: visual-review
description: Use before claiming any UI or frontend change looks right, is done, or "looks good" — and whenever running Playwright or any browser automation. Covers rendering the page headless with `ui-shot`, why a full-page screenshot cannot show a 1px border, cropping to the changed region at native scale, probing computed styles when something looks off, and the headless-only rule plus the headless debugging path (screenshots, request instrumentation, trace-after-the-fact). Fires on "does this look right", "screenshot the page", "check the UI", `playwright`, `--headed`, `--ui`, `--debug`, and on any CSS/layout/token change.
---

# Visual review

## The rule

For any UI change: **render the live page, look at it critically, and judge it from a crop of the
changed region at native scale before saying it is done.** Mandatory, not optional.

```sh
ui-shot <url> --selector '.changed-thing' --probe '.changed-thing'
```

**Read `ui-shot --help` before the first capture.** It carries the reasons this skill used to repeat:
why a full-page screenshot cannot show a 1px border, why `--token` and not the computed border tells
a misspelt custom property from a correctly borderless element, and what `--color-scheme`,
`--wait-for` and the viewport flags are for. Tested 2026-10-04: sessions that read the help did all
of that unprompted.

The incident behind the rule: an account-row redesign was declared done from a thumbnail-scale
screenshot, while its borders did not render at all because a CSS token name had a typo. Jeremy:
*"did you really look at it and review it as if you were a human trying to view it?"*

## What to actually look for

Ask *"would I be happy with this if I were the user opening the app for the first time?"* — then
scan specifically for: **hierarchy** (can I tell what matters?), **separation** (can I tell where
one thing ends and the next begins?), **alignment** (do related things line up?), **whitespace**
(intentional or accidental?), **contrast** (is anything supposed-to-be-visible actually visible?).

And **match user-facing claims to evidence**: do not say "looking good" without a capture in hand.
If the capture does not support the claim, the claim is wrong.

## Two crop mistakes the tool only half catches

- **A wrapper selector.** Selecting a page-level wrapper produces a "crop" the size of the page,
  which loses the whole native-scale benefit. `ui-shot` prints a `WARNING` about crop size; heed it
  and select the changed element.
- **A selector that matches nothing exits non-zero.** Read the exit status: otherwise you are left
  holding only the scaled-down full page, which is the failure this skill exists to prevent.

## Headless only — for any browser automation, not just ui-shot

**Never run Playwright (or anything else) in a mode that opens visible windows without asking
first**: no `--headed`, `--ui`, `--debug`, or `--trace=on` during a run. Windows appear on whoever's
screen, at a moment they did not choose; the incident was six browser windows at bedtime. The same
goes for anything else loud or long: say what it will do and get a yes first.

### Debugging a failing e2e test without a visible browser

1. `--reporter=line` for streaming output.
2. `await page.screenshot({ path: '/tmp/debug.png' })` — works fine headless.
3. `page.on('request', r => console.log(r.url()))` to instrument URL traffic.
4. `await page.content()` to inspect rendered HTML.
5. `--trace=retain-on-failure` produces a `.zip` you open **after** the run, not during.

Prefer `use: { headless: true }` in the project's `playwright.config.*` so a stray CLI flag cannot
override the default silently.
