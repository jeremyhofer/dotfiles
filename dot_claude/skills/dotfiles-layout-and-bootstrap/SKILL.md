---
name: dotfiles-layout-and-bootstrap
description: Use when changing, adding or debugging any dotfile or shell/app config (~/.zshrc, ~/.config/**, ~/.ssh/config, git config); when deciding whether a file belongs in the public base or the private overlay; when a change "doesn't take" or gets reverted; when running chezmoi apply/diff/add/edit or chezmoi-overlay; or when bootstrapping, adopting or auditing a machine. Covers the two-instance base+overlay model and the edit-the-source rule.
---

# Dotfiles: layout, the two instances, and bootstrap

## 1. The single rule that breaks everything else

**Edit the chezmoi SOURCE and apply. Never edit the deployed `~/…` file** — the next apply
overwrites it, silently, and the change is gone with no trace of why.

```
chezmoi edit ~/.zshrc     # opens the SOURCE
chezmoi diff              # what an apply would change
chezmoi apply             # base only -- see §2
```

If a config change "didn't take" or reverted, this is nearly always the cause: it was made to the
deployed copy.

## 2. There are TWO chezmoi instances, and `chezmoi` is only one of them

| | Command | Holds |
| --- | --- | --- |
| **Base** | `chezmoi …` | public, generic, machine-agnostic config |
| **Overlay** | `chezmoi-overlay …` | private / per-domain / per-machine config |

They are fully independent — separate source, config, persistent state and cache — but they target
the **same `$HOME`**. So:

- **`chezmoi apply` does NOT apply the overlay.** Applying "everything" is two commands. A diff that
  looks clean may simply be the wrong instance's diff.
- **Their managed file sets must stay DISJOINT.** One file, one owner. Two instances writing the same
  path is last-apply-wins with no diagnostic — never resolve an overlap by letting both manage it.
- Where a public file needs a private piece, the public file **includes a fragment** the overlay
  deploys under `~/.dotlocal/` (`source ~/.dotlocal/zshrc`, ssh `Include ~/.dotlocal/ssh/config`).
  That indirection is the pattern to follow for anything new; the public side names only the generic
  path and degrades to a no-op when the fragment is absent.

`chezmoi-overlay` is a script on `PATH`, so it works in scripts and over SSH.

## 3. Which layer does a new file go in?

**Base** if it is generic, machine-agnostic and publish-safe. **Overlay** if it names anything
private: hosts, keys, stores, remote URLs, employer or machine names, or per-domain values.

The base is **public**. Nothing private may reach it — in content, in comments, or in commit
messages. When in doubt, overlay: moving a file base→overlay later is easy, un-publishing is not.

OS differences belong in `.chezmoi.os` templates, not per-OS forks. Per-machine values come from
machine-local chezmoi data, not from committed conditionals on hostnames.

## 4. Turning a whole capability off on a machine

Gate it on a machine-local boolean in the overlay's config and reference that in
`.chezmoiignore`. Two semantics that are easy to get backwards:

- **`.chezmoiignore` stops a file being deployed, but never removes one already there.** Ignoring
  alone leaves orphans.
- **`.chezmoiremove` deletes the target — on every machine, at its next apply.** So a flag that is
  unset or mis-answered on the machine that *needs* the capability destroys it. Prefer ignore plus a
  deliberate manual removal; reach for `.chezmoiremove` only when the teardown is genuinely designed.

Gate **both** the payload and whatever installs it (bootstrap stages, PATH front ends). Gating only
the payload leaves an installer running for something that is no longer there.

## 5. Bootstrap / adopting a machine — do not improvise this

`setup/README.md` in the base is the authoritative, ordered flow, and it is written for exactly this.
**Read it rather than reconstructing the steps.** What matters before you start:

- Adopting a machine that **already has config** is the dangerous case; the flow exists to make it
  safe (`adopt-audit` gates, `chezmoi-safe-apply` backs up + diffs + confirms).
- **Never bypass the `adopt-audit` gate** to force an apply — capturing the flagged files first is
  the entire point of it.
- `overlay-doctor` audits an overlay for required pieces and is read-only; run it before assuming an
  overlay is complete.
- The system layer installs packages and chezmoi itself. Dotfiles do not install software.

## 6. Machine-specific detail

Which overlay this machine uses, what its capability flags mean, which machines exist and what each
holds, is **not** in this file. If `~/.dotlocal/skills/dotfiles-layout-and-bootstrap.md` exists, read
it — that is this domain's half. If it does not exist, this machine has no overlay-specific notes and
the generic model above is the whole picture.
