---
name: dotfiles-update
description: Use when pulling or updating dotfiles on a machine — after `git pull` in the chezmoi source, when catching up a machine that has been dormant, before or after `chezmoi apply` / `chezmoi-overlay apply`, or when something worked on one machine but not another after an update. Walks what to re-check, what the changelog says changed, and why an overlay can be left behind by a base update.
---

# Updating a machine's dotfiles

## The asymmetry that causes every surprise

**The base propagates automatically. The private overlay does not.**

A base update can start expecting a piece that only the overlay can supply — a renamed file, a newly
required config, a signing key. Nothing pushes that into your overlay, so the machine ends up
carrying a base that expects something its overlay never grew. It usually shows up later, as one
machine behaving differently from another for no visible reason.

That is what this walk is for.

## The walk

```sh
# 1. Where am I now? (note this BEFORE pulling)
git -C ~/.local/share/chezmoi log -1 --format='%h %ad' --date=short

# 2. Pull both layers
git -C ~/.local/share/chezmoi pull --ff-only
git -C ~/.local/share/chezmoi-overlay pull --ff-only     # if this machine has an overlay

# 3. Read what changed FOR YOU
#    CHANGELOG.md in the base — only the entries dated after your last apply.
#    Entries marked ACTION need something done, usually in the overlay.

# 4. See what would change, per instance — they are separate
chezmoi diff
chezmoi-overlay diff

# 5. Apply
chezmoi apply
chezmoi-overlay apply

# 6. Confirm the overlay still satisfies the current standard
sh ~/.local/share/chezmoi/setup/overlay-doctor
```

Step 6 is the one people skip, and it is the one that catches the asymmetry above. `overlay-doctor`
is read-only, so running it is always safe.

## Things that will bite

- **`chezmoi apply` does not apply the overlay.** Two instances, two commands. A clean `chezmoi diff`
  says nothing about the overlay.
- **A failing external aborts the whole apply, part-way.** `.chezmoiexternal` fetches third-party
  content; if one fails (network down, a bad URL), the apply stops and later files are simply not
  written — with the earlier ones already changed. `chezmoi apply --exclude=externals` converges
  everything else; treat the external failure separately. The historical worst case — the global
  HTTPS→SSH git rewrite turning external refreshes into key-requiring fetches that failed on any
  machine dormant past the refresh period — is gone as of 2026-08-16: every external is now
  `type = "archive"` (chezmoi's own HTTP download, git never invoked, no key needed). If an
  external failure mentions SSH or access rights, the machine is running a pre-archive config —
  pull the base first.
- **Never edit the deployed file to "fix" an update.** Edit the source and re-apply, or the next
  apply silently reverts you.
- **A machine that has been dormant a long time** should not trust the changelog to be complete for
  that era. Run the doctor and both diffs and believe those instead.

## After updating

Open a **fresh shell** before judging whether something is broken — shell config only takes effect in
a new one, and half the "the update broke X" reports are a stale shell.

If a change did not take, check in this order: (1) did you apply the right instance, (2) is the file
managed at all (`chezmoi managed | grep <name>`, then the overlay's), (3) is it ignored on this
machine by a capability flag, (4) did you edit the deployed copy by mistake.

## Recording a change for others

If **you** make a change that will require action on another machine — a rename, a moved file, a new
required overlay piece — add an entry to `CHANGELOG.md` in the base, marked **ACTION**, in the same
commit. It is the only channel another machine has; a machine cannot infer from a diff what it was
supposed to do about it.

## Machine-specific detail

If `~/.dotlocal/skills/dotfiles-update.md` exists, read it for this domain's specifics — where the
sources and remotes are, and what this machine's update actually involves.
