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

# 3b. If a diff or apply warns "config file template has changed", regenerate that instance's
#     config first (`chezmoi init`, `chezmoi-overlay init`): a template now reads a value the old
#     config lacks, asked for once. Skipped, the apply stops on "map has no entry for key".

# 4. See what would change, per instance — they are separate
chezmoi diff
chezmoi-overlay diff

# 5. On macOS, if the diff touches the Brewfile: install what it now declares BEFORE applying
brew bundle --file "$(chezmoi source-path)/Brewfile"

# 6. Apply
chezmoi apply
chezmoi-overlay apply

# 7. Confirm the overlay still satisfies the current standard
sh ~/.local/share/chezmoi/setup/overlay-doctor
```

Step 7 is the one people skip, and it is the one that catches the asymmetry above. `overlay-doctor`
is read-only, so running it is always safe.

Step 5 has its own backstop now: a `run_before_` script checks, on macOS only, that every Brewfile
formula marked `REQUIRED` (its header explains the marker) is on PATH, and refuses the apply by name
if one is not — so a skipped `brew bundle` fails at step 6 with one clear message instead of
somewhere unrelated, later. If you see that refusal, it means exactly step 5 above was skipped.

## Catching up a machine that is far behind

A machine weeks behind has several changelog entries to act on at once, and one of them can make the
apply itself refuse. Take it in this order:

```sh
git -C ~/.local/share/chezmoi log -1 --format='%h %ad' --date=short    # note it: the changelog starts here
git -C ~/.local/share/chezmoi pull --ff-only
# Read CHANGELOG.md from the top down to that date. List every ACTION before touching anything.
brew bundle --file ~/.local/share/chezmoi/Brewfile    # macOS: install what the Brewfile now requires
exec zsh -l                                           # a new login shell, so PATH changes take effect
sh ~/.local/share/chezmoi/private_dot_local/bin/executable_fleet-decl --check   # the manifest the git hooks read
sh ~/.local/share/chezmoi/setup/overlay-doctor --machine   # BEFORE the apply: what can this machine do?
chezmoi diff        # read it; a long diff is expected after weeks
chezmoi apply
chezmoi-overlay diff && chezmoi-overlay apply         # if the machine has a private layer
sh ~/.local/share/chezmoi/setup/overlay-doctor        # overlay compliance, then the assessment again
```

**Why the Brewfile comes first:** the base can start requiring a tool (`gitleaks` for the secret scan
on every commit, `yq` for the apply itself), and applying before installing it either stops the apply
or blocks every commit afterwards.

**Why the manifest check comes before the apply:** the base's commit hooks read the repository manifest
(`~/Devel/mani.yaml`) through `fleet-decl`, and refuse a commit they cannot classify. A manifest on an
older schema, or none at all, then shows up as refused commits rather than as one clear report. Both
commands run from the pulled source, because the deployed copies are the old ones until the apply.

**If `~/.claude/CLAUDE.md.before-base` appears after the apply,** the base has replaced a hand-kept
global `CLAUDE.md`. Move what belongs to this machine's domain into `~/.dotlocal/claude/CLAUDE.md`
(through the overlay, if there is one), which the base file imports, then delete the copy. Until then
those instructions are not loaded.

**Who runs what, when an agent is helping.** Claude Code's sandbox normally write-protects its own
configuration (`~/.claude/settings.json`, `~/.claude/CLAUDE.md` and similar), which the apply writes. So
an agent session reads the changelog, runs the read-only checks, reads the diffs and drafts the domain
fragments; the human runs `brew bundle`, both applies and the two probes in an ordinary terminal.

**Why the assessment runs twice:** before the apply it shows what the machine brings (which git runs,
whether its configured hooks fire, which tools are missing); after, it confirms the apply changed what
it should. A git older than 2.54, or one earlier on `PATH`, skips every configured hook silently,
which looks exactly like a working machine.

**Then measure what Claude Code does here**, in an ordinary terminal rather than inside an agent
session (whose sandbox changes what can run):

```sh
claude-context-probe            # which context files, imports, rules and skills load
claude-context-probe --fleet    # background sessions, their listing, resume, settings env, models
```

**Report back** the doctor's assessment and both probes' summaries by retyping or reading them out.
They carry versions, verdicts and key names only, never paths or values from the machine, which is
what makes them safe to move off it.

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
