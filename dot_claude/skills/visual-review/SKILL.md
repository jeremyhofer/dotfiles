---
name: visual-review
description: Use before claiming any UI or frontend change looks right, is done, or "looks good" — and whenever running Playwright or any browser automation. Covers rendering the page headless with `ui-shot`, why a full-page screenshot cannot show a 1px border, cropping to the changed region at native scale, probing computed styles when something looks off, and the headless-only rule plus the headless debugging path (screenshots, request instrumentation, trace-after-the-fact). Fires on "does this look right", "screenshot the page", "check the UI", `playwright`, `--headed`, `--ui`, `--debug`, and on any CSS/layout/token change.
---

# Visual review

## The rule

For any UI change: **render the live page, look at it critically, and crop to the changed region
at native scale before saying it is done.** Mandatory, not optional.

Use the tool rather than re-deriving Playwright boilerplate:

```sh
ui-shot <url> --selector '.changed-thing' --probe '.changed-thing'
```

It resolves the PROJECT's Playwright (layouts differ: `node_modules/`, `frontend/node_modules/`,
`main/node_modules/` are all in use here), renders headless, and always writes two things — the
full page, and the selected element at native scale.

## Why two captures, not one

A full-page screenshot rendered into a chat transcript is **scaled down**, so a 1px border, a
subtle divider, or a low-contrast edge is simply not present in what the reviewer sees. Looking at
it and approving is then false confidence rather than dishonesty. The full-page shot is for
spotting layout regressions; the **native-scale crop is the one you actually judge quality from.**

Originating incident (2026-06-04): an account-row redesign was declared done with a paragraph of
self-congratulation. Jeremy: *"did you really look at it and review it as if you were a human
trying to view it? I feel you may have viewed it but just saw everything and were like 'that's
ok!' which is not ok."* He was right. The screenshot was at thumbnail scale, and the real defect
was a CSS token typo (`--groove-border-default` for `--groove-color-border-default`) making the
borders fall back to nothing.

## Probe when something looks off

A CSS token typo **falls through silently** — no error, no warning, just a missing border:

```sh
ui-shot <url> --probe '.suspect' --token '--groove-color-border-default'
```

**The computed border alone is NOT diagnostic, and an earlier version of this skill said it was.**
A typo'd token and an element that is *correctly borderless* both compute to
`borderTop: "0px none rgb(...)"` — byte-identical. Borderless is the overwhelmingly common case,
so reading that as "wrong token" produces a false positive on exactly the layout primitives a
reviewer probes first. Measured against a real stylesheet by finmodel-canonical, 2026-08-30.

**`--token` is the check that discriminates**: an undefined custom property resolves to empty
(`UNDEFINED`), a defined one to its value. Use `--probe` to see what the element actually rendered,
and `--token` to decide whether the property it names exists at all.

## What to actually look for

Ask *"would I be happy with this if I were the user opening the app for the first time?"* — then
scan specifically for: **hierarchy** (can I tell what matters?), **separation** (can I tell where
one thing ends and the next begins?), **alignment** (do related things line up?), **whitespace**
(intentional or accidental?), **contrast** (is anything supposed-to-be-visible actually visible?).

And **match user-facing claims to evidence**: do not say "looking good" without a capture in hand.
If the capture does not support the claim, the claim is wrong.

## Headless only — and this one is about the human, not the tooling

**Never run Playwright (or anything else) in a mode that opens visible windows without asking
first**: no `--headed`, `--ui`, `--debug`, or `--trace=on` during a run. `ui-shot` has no
`--headed` flag at all, by design.

The cost is not technical. Visible windows appear on whoever's screen, at a moment they did not
choose — the originating incident was **six browser windows at bedtime** ("headless!! need
headless!!"). One annoyed interruption outweighs any convenience of a quick visual peek. The same
applies to anything else that seizes attention or does something loud and long: say what it will
do and get a yes first.

### Debugging a failing e2e test without a visible browser

1. `--reporter=line` for streaming output.
2. `await page.screenshot({ path: '/tmp/debug.png' })` — works fine headless.
3. `page.on('request', r => console.log(r.url()))` to instrument URL traffic.
4. `await page.content()` to inspect rendered HTML.
5. `--trace=retain-on-failure` produces a `.zip` you open **after** the run, not during.

Prefer `use: { headless: true }` in the project's `playwright.config.*` so a stray CLI flag cannot
override the default silently.

## Other things the tool does, that reviews keep needing

- `--color-scheme dark|light` — renders the media condition. A theme whose dark arm is a
  `@media (prefers-color-scheme: dark)` query is otherwise **untestable**, and a light-pin that
  exists to defend against it cannot be verified without rendering the case it defends against.
- `--wait-for '.sel'` — `networkidle` is the wrong primitive for anything polling or holding a
  socket; it resolves early or never. Wait on the thing you are reviewing instead.
- `--width` / `--height` — `--width 390` gives the mobile layout. Output pixels are
  `--width × --scale`.
- **Heed the `WARNING` about crop size.** Selecting a page-level wrapper produces a "crop" the size
  of the page, which silently loses the entire native-scale benefit — and a wrapper class is the
  easiest selector to reach for.
- **A `--selector` that matches nothing exits non-zero.** It used to exit 0, which meant a typo
  left you holding only the scaled-down full page while the run reported success — failing back
  into precisely the bug this skill exists to prevent.
