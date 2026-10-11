---
name: test-coverage
description: Use when setting up, changing or reviewing a project's test configuration (Vitest, Jest, pytest, Playwright), adding a package or module that ships, when a coverage threshold fails a run, or when deciding whether a line may be excluded from coverage. Fires on "coverage", "thresholds", "v8 ignore", "istanbul ignore", "pragma: no cover", "fail_under", "--cov-fail-under", and on "why is this uncovered". Covers the expected bar (100%, enforced), where the threshold lives, how an exception is written, ratcheting a project that is not there yet, proving the threshold can fail, how a browser lane that runs in several engines enforces coverage, and which environment (browser or node) a unit test belongs in.
---

# Test coverage: 100%, enforced by the test run itself

**The bar is 100% line, branch, function and statement coverage, enforced.** Not every line of every
project will meet it, but everything a project ships (a published package, a library other code
imports) is held to it, and the rest is held to it wherever that is reasonable. Coverage that is
measured but not enforced has been found sitting below the bar for months with nobody noticing, so
**measuring is not the standard; failing the run is.**

## 1. The threshold lives in the test run, never in a separate target

- Put the threshold in the runner's own configuration, so the ordinary test command fails when
  coverage drops: Vitest `test.coverage.thresholds`, Jest `coverageThreshold`, pytest-cov
  `fail_under` (or `--cov-fail-under`) in the project's config.
- Do **not** add a separate `coverage` task that someone has to remember to run. A distinctly named
  task is one nobody runs (skill `naming-build-tasks`), so the threshold would guard nothing.
- Coverage collection must be on in the configuration the test task actually uses, including in
  CI. A threshold in a config file the runner never loads passes silently.

## 2. An exception is an inline comment that says why

- Exclude code with the runner's inline marker at the code, with the reason on the same line:
  `/* v8 ignore next -- defensive: unreachable once parse() has validated */`,
  `# pragma: no cover -- platform branch, exercised only on macOS`.
- **Never exclude code by a configuration glob** to make a number pass. A config-level exclude hides
  whole files from every future reader; an inline one is visible where the code is and carries its
  reason. Config-level excludes are for files that are not code under test (generated output, the
  test files themselves, type declarations), each with a comment saying what it is.
- An exception with no reason is a defect: the next reader cannot tell a deliberate gap from a
  convenient one.
- **Under Vitest with V8 coverage, never put the marker inside an expression.** Vite's transform drops
  a `/* v8 ignore next */` written mid-expression before V8 reads it, so the line still counts as
  uncovered, or a reader believes it is excluded when it is not. Use the line form,
  `// v8 ignore start -- <reason>` … `// v8 ignore stop`, around the smallest range, or a
  statement-level `/* v8 ignore next -- <reason> */` on its own line (measured with Vitest 4.1 and
  Vite 8, 2026-10-11). Check an exception took effect by reading the coverage report, not the code.

## 3. A project below the bar ratchets up; it never lowers the floor

- Measure first. Set the threshold to the measured value (rounded down), so the run enforces "no
  worse than today" from that moment.
- Raise it as coverage is added, until it reaches 100. **Never lower a threshold to make a failing
  run pass**: add the test, or add an inline exception with its reason.
- Record the measured starting point and the plan to 100 where the project tracks its work.

## 4. See the threshold fail before trusting it

A threshold that has never failed is of unknown value. Before reporting coverage as enforced:

1. Plant a gap: add an untested branch (or delete one test) in the code under the threshold.
2. Run the ordinary test command and **see it fail on coverage**, naming the file.
3. Revert, and see it pass.

Plant at the granularity being claimed: a package-level threshold is proven by a gap in that
package, not in a neighbour.

## 5. Runner notes worth checking, not assuming

These are as of the writing of this skill; confirm against the runner's current documentation
before relying on them.

- **Vitest browser mode** collects coverage differently by browser: the V8 provider needs a
  Chromium-based browser, and other engines need the Istanbul provider. A lane that runs only in
  Firefox or WebKit may report no coverage at all under V8, which reads as a pass if no threshold
  applies to it. Section 6 sets the rule for a lane that runs in more than one engine.
- **Coverage from several test lanes** (a node lane and a browser lane of the same package) may need
  merging before a threshold means anything; a per-lane threshold on half the code passes while the
  package as a whole is uncovered.
- **pytest with xdist** (`-n`) needs pytest-cov's own xdist support to combine worker data; check
  the reported total matches a serial run once.

## 6. A browser lane in several engines enforces coverage on a Chromium-only run

**Split the lane into two runs.** One runs in Chromium alone, collects V8 coverage and holds the 100
threshold, and it is the run the gate executes as the test task. The other runs every test in the
remaining engines (Firefox, WebKit) and measures nothing. **Do not instrument with Istanbul to
measure several engines in one run.** A line reached only in another engine shows as uncovered in
the Chromium run; give it a Chromium test, or an inline exception that says why (section 2).

Why V8 on Chromium rather than Istanbul everywhere: V8 coverage comes from the engine, so the tests
run the code that ships, at native speed, with no extra dependency. Istanbul rewrites every module
before it runs, which slows the tests and changes their timing, and the tests that suffer are the
focus, scroll and animation tests that already flake. The two choices fail differently, and that
decides it: the split's weak spot is LOUD, a visible uncovered line; Istanbul's is QUIET, new
intermittent failures nobody can attribute.

The split is forced rather than chosen in at least one runner: Angular's Vitest builder
(`@angular/build` 22) selects the V8 provider only when every browser in the run is Chromium-based,
so a run that includes Firefox cannot collect V8 coverage at all. Check the runner in use before
assuming one run can do both.

A Playwright end-to-end lane is outside this rule; it measures behaviour, not line coverage.

## 7. A test runs in the environment its subject needs

**Code that runs in the browser and needs browser APIs is tested in a browser lane** (for example
Vitest browser mode); **code that runs in Node is tested in a node lane.** A browser lane is slower
and heavier, so nothing goes there that does not need a real engine.

**Do not use a DOM shim (jsdom, happy-dom) in a node lane for what only a real engine can answer.**
A shim has no layout engine and only part of the cascade: `getBoundingClientRect` returns zero-size
boxes, and `elementFromPoint`, `checkVisibility` and `matchMedia` are missing or stubbed. A test of a
size, a position, a computed colour or a focus order run there passes while measuring nothing,
which is the worst kind of green, because it reads as coverage.

**Where one piece of code both reads the page and decides from what it read, split it:** a thin
measuring layer, tested in the browser, and pure judging functions that hold the rules and the
branching, tested in Node. Most of the logic then runs in the fast lane, and the browser lane
tests only what needs a browser.
