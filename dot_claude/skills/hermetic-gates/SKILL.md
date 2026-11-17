---
name: hermetic-gates
description: Use when a gate, test suite or timed run reaches, or is about to reach, a package registry or another remote service — deciding whether to allow a registry or network host for a check, `npm install` or `pip install` inside a check or test, a local test registry (Verdaccio or similar) that proxies to a public one, `--offline`, `--no-index`, an E403, ENOTFOUND, ETIMEDOUT or "network is unreachable" from a registry during a test run, a timing measurement whose samples fetched packages, or a check whose result changed with no commit. Covers the rule (a gate or timed run takes no network access; only explicit cache-filling steps reach a registry), the three reasons for it, how to make a package-manager workspace's checks run offline, and why a check of the real deployment stays separate.
---

# Hermetic gates: a gate or timed run fetches nothing

Two terms, as used here:

- A **gate** is a check that vouches for a commit: a commit hook, a test suite, a lint, a landing
  check, a CI lane.
- A **timed run** is a measurement of how long something takes, sampled repeatedly so the numbers
  can be compared across changes.

**The rule.** A gate and a timed run take no network access. Only the steps that fill a package cache
or a local registry's storage reach out, and each of those is an explicit step that names the one
host it needs, for that one command, with versions pinned by the lockfile. The gate then runs offline
against what those steps stored, and when something is missing it fails and names it rather than
fetching it.

## Why: three reasons, each enough alone

1. **Timing.** A timed run that fetches measures the network and the remote service as much as the
   code. Their variance lands in its numbers. And in any gate, a refused or throttled request reads
   as a defect in the code: an E403 from a registry looks like a packaging error.
2. **Drift.** A gate that installs whatever the remote serves at run time can change its result with
   no commit. It then no longer vouches for the commit it ran on. This is supply-chain drift (a
   dependency changing under you between two runs of the same code) inside the very check meant to
   catch a bad change.
3. **Least privilege.** A standing network allowance for a gate is reach the work does not need, to
   a host that often accepts writes as well as reads: a package registry accepts publishes.

## How, in a package-manager workspace

- **Only the cache-filling steps reach the registry.** The workspace's own frozen install (`npm ci`,
  `pnpm install --frozen-lockfile`) installs the dependencies and, in doing so, also fills the package
  manager's cache. A local registry the tests use gets its storage filled by an explicit step of its
  own. Where commands run in a sandbox with a network allowlist (an AI agent's sandbox, a CI runner
  with egress rules), these are the only commands that list the registry host, each on its own
  invocation rather than as a standing allowance.
- **Checks install offline.** A scratch install inside a check uses the cache and no network: npm's
  and pnpm's `--offline`, pip's `--no-index --find-links <dir>` (check the installed tool's
  spelling). An offline install fails when the cache lacks a version the lockfile names, which is
  the loud failure wanted: refill the cache, never let the check fetch.
- **A local test registry does not proxy.** A registry such as Verdaccio forwards requests for
  packages it does not hold to an "uplink", an upstream registry it proxies. For a gate, run it with
  no uplink (in Verdaccio, remove the `proxy:` lines from its package rules), serve the workspace's own
  packages from a local build (`npm pack`), and serve third-party packages from the filled cache or
  storage.
- **Refill when the lockfile changes.** Record a hash of the lockfile when the cache or storage is
  filled; a changed hash says it is time to refill.
- **A run that still fetches says so in its record.** If a timed run cannot be made offline yet, each
  sample it writes is marked as having fetched over the network, so its numbers are never compared
  with offline ones as if they were alike. This marks a transition, not an accepted state: the work
  still owed is to make the run offline.

## A deployment check is separate

A check whose point is the real remote service (does the published package install from the real
registry, with real TLS and real authentication?) proves something different, so it is a separate
check, run where it is wanted, not part of the gate. Kept apart, a network blip or an expired token
cannot read as a defect in the code, and a code defect cannot hide behind one.

## Related

- Skill `test-independence`: no test depends on another test or on the order tests run in.
- Skill `fault-isolation`: when a gate fails or slows and the layer at fault, network included, is
  not yet known.

## Provenance

The owner's standing practice for gates and timed runs, 2026-11-16, set after a timed run needed a
registry allowance that the work itself did not need. The tool flags above are as known to the author
on that date and were not each measured; check the installed version.
