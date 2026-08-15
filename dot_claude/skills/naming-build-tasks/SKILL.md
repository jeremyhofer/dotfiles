---
name: naming-build-tasks
description: Use when adding, renaming or reviewing a runnable task in any build tool — an Nx target, a `just` recipe, a Make target, an npm/pnpm script, a CI job step — or when deciding what to call one, when two repos spell the same job differently, or when a task needs a variant (unit vs e2e, local vs CI). Covers the shared verb categories, the difference between `lint`/`check`/`verify`/`validate`, and why a task name never encodes a machine.
---

# Naming build tasks

One vocabulary of **task verbs** across every build tool, so that `test:e2e` in one repo and `test-e2e`
in another are recognisably the same kind of thing. A reader who has never opened the repo should be
able to predict what a task does from its verb alone.

## The rule in three lines

1. **Standardize the verb. Do not standardize the name shape or the separator.** `test-e2e` in a
   justfile and `test:e2e` in a `package.json` are *the same verb*. Each tool keeps its own idiom —
   `-` for `just` and Make, `:` for Nx and npm. A repo that fights its ecosystem's convention is harder
   to read, not easier.
2. **These are categories to prefer and extend — not an allowlist to obey.** `test` is a category;
   `test:unit`, `test:e2e`, `test:visual`, `test:browser` are extensions *within* it, and all stay
   legible to a stranger. Adding a category the list lacks is fine.
3. **The only real prohibition: never use a listed verb to mean something else, and never invent a
   synonym for one.** A task nobody else has costs a reader one lookup. A verb that means something
   different in each repo costs them their confidence in all of them.

## The categories

| Verb | Means |
| --- | --- |
| `build` | produce the distributable artifact (`compile` is **not** a separate verb — it is this) |
| `test` | run the automated test suite |
| `lint` | the codified linters — a standard tool with standard rules |
| `typecheck` | type analysis only, nothing else |
| `serve` | run it locally for a human to look at |
| `e2e` | browser or full-integration suite |
| `format` | rewrite source to canonical style |
| `generate` | write generated sources into the working tree |
| `clean` | remove build outputs |
| `deploy` | push a running app to an environment |
| `publish` | release a package to a registry |
| `ci` | the **full gate** — the whole fan-out a CI run executes over the project's own targets |
| `check` · `verify` · `validate` | three different jobs — see below |

**Synonyms to avoid, because each is already taken:** `dev` or `start` when you mean **`serve`** ·
`release` when you mean **`publish`** · `lint:tsc` when you mean **`typecheck`** · `compile` when you
mean **`build`**.

## `check` vs `verify` vs `validate` — they differ by WHAT THEY READ

This is the part that is easy to get wrong, because all three sound like "make sure it's OK". They are
three distinct jobs, and the distinguisher is how far out each one reaches:

| Verb | Reads | Answers | Typical |
| --- | --- | --- | --- |
| `check` | **the tree** — source, config, generated or built output | *Is it well-formed?* | assert generated JSON-LD has the right shape; palette contrast; no forbidden licence; docs still match the help output |
| `verify` | **this machine and this repo's history** | *Is it actually true?* | installed packages match the committed SBOM; git hooks configured with no bypass; the signing key exists and is the right type; the HEAD signature verifies; a gate really fires on a known-bad input |
| `validate` | **a deployed, running target** | *Is the thing that's live good?* | e2e + performance audit against the deployed site; assert a release actually landed |

**Tree → environment → deployment.** Each reads strictly further out than the last. That ordering is
the whole mnemonic: if the task needs nothing but the checkout it is a `check`; if it needs *this
machine* it is a `verify`; if it needs something already running it is a `validate`.

**`check` vs `lint` is the softest line here, so state it when you use it.** Both read only the tree.
`lint` is someone else's rules run by a standard tool; `check` is a project-specific assertion no
linter would carry. If you cannot say which side a task falls on, it is a `lint`.

**`validate` is not the full CI gate.** That is `ci`. A task that runs everything over the project's
own targets is `ci`; a task that points at something already deployed is `validate`.

## A task name never encodes a machine

No `remote-` prefix, no host name, no `-remote` suffix. Tasks are **project-local** and should not care
what machine they run on.

The distinction that actually matters is **local vs CI**, and it is about **capability**, not location:
CI has the full browser matrix, the signing key, a clean checkout; a dev machine may have none of them.
That is a property of the environment a task *needs*, not of a host somewhere on a network — and a name
that hard-codes a hostname encodes the wrong thing and goes stale the moment the topology moves.

**So put a CI-only requirement in the task's contract, not in its name:** document the prerequisite, or
have the task **fail loudly** on a machine that lacks the capability. A task that silently does
something different on a dev machine is the failure this prevents; a task that stops and says which
capability is missing is the fix.

## How you can tell it went wrong

- **Two repos, two names, one job.** You go to run the local dev server and it is `serve` here and
  `start` there. The vocabulary exists to make that first guess correct — if you had to look, something
  is misnamed.
- **A listed verb doing something else.** The worst outcome, and worse than an unfamiliar name: a
  reader's confident guess is *wrong*. `validate` that rebuilds from source, or `verify` that only
  greps the tree, will mislead every time.
- **A new synonym appearing.** `dev`, `start`, `release` and `compile` are the usual arrivals. Each one
  means the category it belongs to already lost.
- **A variant invented as a new verb instead of an extension.** `e2e-visual-test` rather than
  `test:visual`. Extend the category; do not mint a verb.
