---
name: test-independence
description: Use when writing, reviewing or debugging tests whose result depends on which other tests ran or in what order — a test that passes alone and fails in the suite (or the reverse), a failure that comes and goes between runs, a suite that breaks when run in parallel, sharded, or with a different worker count, and whenever setting up or changing how a project's suites order their tests. Fires on "flaky", "passes locally", "order-dependent", "test pollution", "shuffle", "random order", "seed", `--sequence.shuffle`, `--randomize`, `--shuffle`, pytest-xdist, `--dist`, `beforeAll`, module-scoped or session-scoped fixtures, and on any thought of pinning test order or turning off parallel runs to make a suite green. Covers the rule (no test depends on another test or on order), why pinning an order is never the fix, shuffled order by default with a printed seed, and each runner's shuffle option as measured on installed versions.
---

# Test independence: no test depends on another, or on the order they run in

**The rule.** A test never depends on another test having run, or on the order tests run in. Each
test builds the state it needs and leaves none behind. A test that passes only in some orders is a
defect **in the tests**, fixed where it is found. It is never worked around by pinning an order,
running serially, or turning shuffling or parallel runs off.

**Why it is a rule and not a preference.** An order-dependent suite is green by coincidence: the
order that happens to run today is the only one anyone has checked. The day something changes the
order (a new test file, a worker count, sharding, a runner upgrade, a work-stealing scheduler) a
failure appears in a test nobody touched, and it reads as flakiness rather than as the coupling it
is. Pinning the order keeps that coupling and hides it. The suite then cannot be split, parallelized
or run in part, and a test run on its own stops meaning what its name says.

## 1. Run shuffled by default, and print the seed

Order-dependence is found only by running in more than one order, so **each project's suites run in
a shuffled order by default**, in the configuration every developer and CI run uses, not behind a
flag someone remembers. The seed is printed on every run, so a failing order can be replayed
exactly. A shuffle that cannot be replayed turns a real defect into an unreproducible flake.

A project whose suite fails under shuffling does not wait for it to pass before turning shuffling
on. It fixes the failing tests first, then turns it on.

## 2. Diagnosing an order-dependent failure

1. **Replay the failing seed** and confirm it fails again. If it does not, the failure is not about
   order; look at timing, the machine or the network instead (skill `fault-isolation`).
2. **Bisect the tests that ran before it:** run the failing test after the first half of its
   predecessors, then the half that still fails, until one predecessor remains. That one leaves
   state behind, or the failing test relies on state it creates.
3. **Fix the coupling at its source.** Usually that means shared mutable state: a module-level
   cache, a global or singleton, an environment variable, a mocked function never restored, a
   database row or file not cleaned up, or a fixture wider than one test (`beforeAll`, pytest
   `module`/`session` scope) that a test mutates. The fix is to make the state per test, or to reset
   it in that test's own setup and teardown, so that both tests pass in either order.
4. **Confirm with more than the replayed seed.** Run the pair in both orders and the suite with a few
   fresh seeds. The fix is shown when the test that failed passes after its old predecessor and
   alone.

## 3. Runner notes: check the installed version, do not assume

Measured against installed packages on 2026-11-15. Options move between releases, so check the
version a project actually has.

- **Vitest (4.1.12):** `sequence.shuffle: true` in the config (or `--sequence.shuffle`); it also
  takes `{ files, tests }` to shuffle one level only. With shuffling on, the seed defaults to the
  current time, the run header prints `Running tests with seed "<n>"`, and `--sequence.seed <n>`
  replays it. Vitest 3.2.4 has the same option.
- **Jest (29.7.0):** `--randomize` shuffles tests **within** a file, and `--showSeed` prints the seed
  in the summary. `--seed <n>` replays a run, and a test can read it with `jest.getSeed()`. Set both
  `randomize` and `showSeed` in the config so they are the default.
- **Playwright (1.64.1):** `--shuffle [seed]` schedules test files, and tests in parallel mode, in a
  random order, and the run header names `shuffle seed <n>`. It is a command-line option only (it
  is read from the CLI overrides), so a project puts it in the command its scripts and CI run. A
  Playwright test already gets a fresh browser context, but a server, database or file a test
  shares across workers does not reset with it.
- **pytest:** there is no built-in shuffle. A plugin provides it (`pytest-randomly` is the common
  one, which also reseeds `random`), or a project's own `conftest.py` reorders the collected items in
  the core hook `pytest_collection_modifyitems` from a seed it prints and reads back. Neither was
  measured here. `pytest-xdist` changes which tests share a worker process with each run, so a
  suite that is green serially and red under `-n` has the same defect as an order-dependent one.

## Provenance

The owner's standing rule for every project, 2026-11-15, given when a test-ordering check was
framed as a risk of a scheduling change, not as a rule the suite must already meet.
