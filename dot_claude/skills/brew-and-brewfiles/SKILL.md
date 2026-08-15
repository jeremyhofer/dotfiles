---
name: brew-and-brewfiles
description: Use when installing, adding, or removing software on a Homebrew-managed Mac — before any `brew install`, when editing a Brewfile or deciding which layer (public base Brewfile vs private Brewfile.role) an entry belongs in, or when running `brew bundle`, `brew bundle check`, or `brew bundle cleanup`. Also fires on the failure signatures — a declared formula or cask silently did not install though bundle was green, `check` claims many packages "need to be installed or updated", or cleanup proposes removing tools in daily use.
---

# Homebrew and the two-layer Brewfile

## 0. First question, before any install: is this brew's to install?

Not every tool on a Mac is Homebrew's to manage. Some are owned by **another channel** — a managed
software portal on a work machine, a vendor's native installer, a per-project version manager. The
base Brewfile itself carries one example: **node is never `brew "node"`** — it is installed
per-project via fnm.

- The per-domain list of what other channels own lives in this machine's fragment:
  `~/.dotlocal/skills/brew-and-brewfiles.md`. **Read it before adding anything.**
- If a tool is owned elsewhere, do **not** `brew install` it and do not add it to any Brewfile.
  A brew duplicate of a managed install means two copies with different update cadences and PATH
  ambiguity — the worst kind of "works on my machine".
- **If provenance is unclear** — not in a Brewfile, not in the fragment's list — **stop and ask the
  human** before installing. On a managed machine, guessing wrong can also violate policy.

## 1. Which layer gets the entry

- **Base `Brewfile`** (this public repo): the portable, publish-safe dev core that *every* Mac —
  including a managed work Mac — can and should install. Generic tools only.
- **`Brewfile.role`** (the private overlay): ONLY this domain's additions — personal-only apps,
  preference tools, anything not installable or not appropriate on other domains' machines.
  It is overlay-managed: **edit the overlay SOURCE and apply** (`chezmoi-overlay`), never the
  deployed `~/.dotlocal/Brewfile.role`.
- Composition direction: **the base includes the role at its bottom** (`if File.exist?`, so a
  machine with no overlay installs exactly the core). The role file holds additions only — never
  `instance_eval` the base from the role; that inverted shape double-evaluates every entry.

## 2. The one command, and why its path is odd

The base Brewfile is deliberately **not deployed to `~`** — it is consumed from the chezmoi source:

```sh
brew bundle --file "$(chezmoi source-path)/Brewfile"    # installs base + role in one pass
```

If this machine's fragment names a wrapper for this, prefer the wrapper — the hard-to-recall path
is exactly why one exists.

## 3. Reading `brew bundle check`

`check --verbose` says "needs to be installed or updated" for BOTH a package that is **absent** and
one that is merely **outdated** — it refuses to say which. Twenty hits may be three real gaps.
Distinguish per name with `brew list --formula <name>` / `--cask <name>` (or use the fragment's
wrapper, which splits them). A MISSING tool can break config that references it (a git pager, a
diff filter); OUTDATED usually breaks nothing.

## 4. `cleanup` — always against the BASE file, always dry-run first

`brew bundle cleanup` removes everything installed-but-undeclared **relative to the file you point
it at**. Pointed at the role file alone, the entire base core is "undeclared" and proposed for
removal. Always run it against the base file (which sees the union), read the dry-run list, and
only then `--force`. On a machine whose Brewfile has drifted, cleanup's list includes tools in
daily use — the list is a question, not an instruction.

## 5. Taps install NOTHING until trusted — and the skip is silent

Third-party taps are untrusted by default; `brew bundle` **silently skips** their formulae and
casks and still reports success. Signature: entry present in the Brewfile, bundle green, tool
absent. Fix: `tap "owner/name", trusted: true` for a tap you control; for one you do not, prefer
granular trust (`trusted: { formulae: [...] }`, hash-pinned, re-confirmed on change).

## 6. Small print

- `mas` entries (Mac App Store) need the `mas` CLI installed **and** a signed-in App Store.
- Machines whose OS has its own package manager (the Linux fleet) do not use brew at all —
  Brewfile edits affect Macs only; the system layer owns Linux packages.

## 7. Machine-specific detail

Which channels own what **on this machine**, the wrapper commands, and the state of optional roles
are in `~/.dotlocal/skills/brew-and-brewfiles.md` if it exists. If you are AUTHORING that fragment
for a domain: list each externally-owned tool with its actual install/update channel, written for a
reader with no access to any other domain — name the channel and the procedure, never another
domain's paths or values.
