---
name: overlay-doctor
description: Use when overlay-doctor reports MISSING or PLACEHOLDER and you need to know what to actually provision; when setting up, scaffolding or upgrading a private chezmoi overlay; when a freshly scaffolded overlay is incomplete; when a FIXME(overlay-doctor) sentinel appears; or when checking whether the base and overlay layers are safely disjoint. Explains what each tier means and how to fix each finding — not just how to run the tool.
---

# overlay-doctor: reading and fixing what it reports

Run it from the base checkout: `sh setup/overlay-doctor`. It is **read-only and never mutates**, so
running it is always safe. Exit **0** compliant · **1** a required piece is missing or still a
placeholder · **2** precondition error (usually: no overlay source at all — scaffold one first).

Running it is the easy part. This skill is about **what to do with each finding**, which the tool
deliberately does not tell you, because the answer is per-domain.

## The tier model — it tells you WHERE a fix comes from

| Tier | What it is | How it gets fixed |
| --- | --- | --- |
| **A** | Generic mechanism, shipped by the **base** | `chezmoi apply` the base. Never hand-copy it into an overlay — auto-propagation is the whole point |
| **B** | **Private vocabulary**, authored per-domain | Author it from **THIS domain's own** vault/records |
| **C** | Domain-specific config (role packages, ssh hosts, repo manifest, bootstrap stages) | Author for this machine/domain |
| **H** | Leak-guard | **Optional and home-only by design.** Reported, never enforced — its absence is not a failure |

Only required A/B/C pieces gate the exit code.

## The two findings, and what each means

**`MISSING <path>`** — the file is not in the overlay source at all. Author it, then capture it with
the overlay instance (`chezmoi-overlay add <path>`) and commit. The `overlay-skeleton/` in the base
shows the intended shape of each piece.

**`PLACEHOLDER <path>`** — the file exists but still carries the `FIXME(overlay-doctor)` sentinel from
the scaffold. Fill in the real value **and delete the sentinel line** — the sentinel is what the tool
keys on, so a filled-in file that keeps the line still reports as a placeholder.

## The one rule that matters more than the checklist

**Never copy another domain's private values to make a check pass.** Tier B is *private vocabulary*:
identity, signing keys, signer principals, private env. Each domain authors its own from its own
vault. Copying satisfies the tool and silently cross-contaminates two domains that are supposed to be
separate — the audit would then be actively harmful, having certified the thing it exists to prevent.

If you cannot provision a piece because you lack access to that domain's vault, **stop and say so**.
An honest MISSING is a correct result.

## Conditional checks — a pass can depend on your own config

Some requirements only apply if this domain does the thing. The signing-key preload is required only
where the identity actually signs (`gpgsign = true`); the identity file must additionally carry a
`signingkey`, so a gitconfig without one reads as incomplete even though the file exists.

So a check that passed on one machine may legitimately fail on another with different config. Read
the finding, not just the exit code.

## Cross-layer safety — the check that exists because of real data loss

The base and overlay are two chezmoi instances targeting the same `$HOME`. Precisely, the doctor
makes three cross-layer checks:

1. **No deleting attribute anywhere** — `exact_` or `remove_` in *either* tree, co-owned directory or
   not. A blanket ban, not a scoped one.
2. **No conflicting attributes on a co-owned directory** (e.g. `private_` on one side, plain on the
   other → permissions flip-flop on alternating applies).
3. **No co-owned target FILE** — the same deployed path managed by both layers. Files each tree
   carries but neither *deploys* (agent context, repo docs) are excused by honouring the literal
   lines of `.chezmoiignore`; templated or glob ignore rules are not evaluated, so this can
   under-excuse and report a collision that ignores would have allowed — never the reverse.

Treat a finding here as serious. `exact_` on a directory the other instance also writes into means one
apply **deletes the other layer's files** — with no diagnostic, because each instance is behaving
correctly by its own lights. If you are adding a new co-owned directory, this is the check to think
about before you add it, not after.

## Upgrading an older overlay

An overlay created earlier can lack pieces added since. Do **not** re-scaffold. Pull and apply the
base (Tier A arrives automatically), run the doctor, provision what it flags, and re-run until it
reports compliant. `setup/README.md` has the ordered flow.

## Machine-specific detail

Where this domain's Tier-B/C values actually come from is not in this file. If
`~/.dotlocal/skills/overlay-doctor.md` exists, read it. If it does not, this machine has no
domain-specific notes and the generic guidance above is all there is.
