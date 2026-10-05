# Changelog — dotfiles base

Changes that an **already-adopted machine** has to know about: anything that changes the *shape* of
the setup, moves or renames a file, or adds a piece the private overlay must now supply.

This is **not** a commit log. Most commits never appear here. An entry earns its place only if
pulling it can leave a machine broken, silently different, or newly non-compliant.

## How to use it

After pulling the base (or the overlay), read the entries dated **after your last apply**, then:

```sh
git -C ~/.local/share/chezmoi log -1 --format='%h %ad' --date=short   # what you have now
chezmoi diff                       # what the base would change
chezmoi-overlay diff               # what the overlay would change (separate instance)
sh ~/.local/share/chezmoi/setup/overlay-doctor   # is the overlay still compliant?
```

Entries marked **ACTION** need something from you — usually a change in the *private overlay*, which
no base update can make for you. That asymmetry is the whole reason this file exists: the base
propagates automatically, the overlay does not, and a machine can therefore end up carrying a base
that expects a piece its overlay never grew.

**A machine that is weeks behind** should not apply in one step. Skill `dotfiles-update` has the
walk: read every entry since the commit you have, install what the Brewfile now requires before
applying, then let `overlay-doctor` assess the machine and report what it found. On such a machine the
*deployed* copy of that skill predates the walk until the apply, so read it from the pulled source:
`~/.local/share/chezmoi/dot_claude/skills/dotfiles-update/SKILL.md`.

Entries are newest first.

---

## 2026-10-05

### The overlay's global gitignore must carry the base's defaults — ACTION, and it has since 2026-09-30

`~/.gitignore_global` is overlay-owned (git reads one global ignore file), so the base's default
ignores only reach a machine by being copied into the overlay's `dot_gitignore_global`. On 2026-09-30
the defaults grew (per-user agent state such as `.claude/settings.local.json`, `.claude/worktrees/`,
`CLAUDE.local.md`, `AGENTS.local.md`, `**/.claude/.cc-writes/`, and `.worktrees/`) and
`overlay-doctor` began checking for them, with no entry here, so an overlay written earlier drifted
without anything saying so.

- **ACTION, on every machine with a private layer:** run `sh setup/overlay-doctor`. If it reports
  `dot_gitignore_global lacks the base default`, it now prints the exact lines under `fix: append
  these lines`. Append them to the overlay's `dot_gitignore_global`, commit, apply the overlay.
  The authoritative list is every non-comment line above the marker in
  `overlay-skeleton/dot_gitignore_global.example`; future additions to it get an entry here.

### leak-guard names a present-but-patternless pattern file — ACTION if `~/.dotlocal/git-leak-*` holds only comments

A `git-leak-markers` or `git-leak-sensitive` file counts as configured by existing, so one holding
only comments and blank lines (a scaffold left behind) has always made the guard refuse every commit
in every strict repository on the machine, the dotfiles repositories included. The guard still
refuses, deliberately: reading an empty file as "no patterns" would let a truncated file switch it
off unnoticed. What changed is the message, which now names the file, says it holds no patterns, and
gives the fixes. `sh setup/overlay-doctor` also flags such a file in the overlay source.

- **ACTION, if the overlay ships a comment-only `git-leak-markers` or `git-leak-sensitive`:** either
  delete it (this machine has nothing to keep out; with no pattern file at all the guard passes
  everything) or add a pattern on its first non-comment line. Commit that in the overlay, apply it.

### Skill `working-across-repos` (formerly `mani-and-worktrunk`) is retired

Tested before retiring: sessions rarely reached for it, and with it loaded they did nothing
differently on the tasks it covered. Its `wt` material stays in `working-in-worktrees`. Applying
removes the deployed directory (`.chezmoiremove`).

- **If a private layer ships `~/.dotlocal/skills/working-across-repos.md`** (or the older
  `mani-and-worktrunk.md`), nothing reads it any more: move what it says to where it is met, such as
  a comment in the manifest it describes, and delete it.
- **If `skipSkills` lists either name,** the entry is now inert and can go.

## 2026-10-04

### Skill `mani-and-worktrunk` is now `working-across-repos` — ACTION on a machine with a private layer

The skill now covers `mani` and the repo manifest only. Its `wt` material moved into
`working-in-worktrees`, which already carried most of it. Applying removes the old deployed directory
(`.chezmoiremove`).

- **ACTION, if a private layer ships `~/.dotlocal/skills/mani-and-worktrunk.md`:** rename it to
  `working-across-repos.md`, or the skill stops reading it.
- **ACTION, if `skipSkills` lists `mani-and-worktrunk`:** list `working-across-repos` instead.

## 2026-10-02

**A private layer can now install skills from its own repositories.** List them in
`~/.dotlocal/skill-externals.yaml`, in the same shape as the base's public `skill_externals`, plus
`url` and `ref` for other hosts and tag names. `skill-externals-sync` installs each with git (this
machine's own credentials), pinned to its tag, after every base apply; it never overwrites a skill it
did not install and uninstalls one removed from the list. The overlay skeleton has the list and a
script that re-runs the sync when the list changes. Details: `docs/reference/private-layer.md`.

**Three new reference pages** under `docs/reference/`: `knowledge-base.md` (standing up `kb` and
loading its rules into sessions), `repository-layouts.md` (plain clone or bare container, and a tested
procedure to convert an existing clone), and `replacing-your-own-tooling.md` (mapping a machine's own
clone, worktree, skill and context scripts onto this setup, with a migration order).

**The private git config now overrides the base.** `~/.dotlocal/gitconfig` is included at the END
of `~/.gitconfig` instead of the start, so for any single-valued key the private value wins. Nothing
changes unless the private file sets a key the base also sets. One use: a domain whose commits already
carry its own AI attribution can turn off the base's co-author hook everywhere with
`[ai-coauthor] enabled = false` in `~/.dotlocal/gitconfig`.

**`remoteControlAtStartup` is no longer set by the base.** It is a per-domain choice, so a private
layer declares it if it wants it. A machine where the base set it keeps the value already in
`~/.claude/settings.json`; nothing to do unless you want it changed.

**The configured git hooks are documented by name, with how to switch each off** (per repository, for
the whole machine through `~/.dotlocal/gitconfig`, or the repo gates for one command):
`docs/reference/architecture.md`, under Git.

**The fleet manifest's schema is written down:** `docs/reference/fleet-manifest.md` lists every key in
`~/Devel/mani.yaml`, what reads it, what is required, and the allowed values, and the overlay
skeleton's `Devel/mani.yaml.tmpl.example` now carries every key, commented. ACTION only if your
manifest predates this: run `fleet-decl --check` and fix what it reports.

**Every private seam is documented in one place:** `docs/reference/private-layer.md` covers machine
data, the shell, git, ssh, packages, bootstrap stages, Claude Code (instructions, the settings
fragment and its merge rules, skill fragments), worktrees, the publish guard, the manifest, spelling,
the checks, and what a private layer cannot change.

## 2026-10-01

**ACTION (every clone made before this entry) — the history of `main` was rewritten.** Old commits
were reworded to remove machine- and project-specific details. The final files are unchanged, but
every commit from early on has a new id, so `git pull` refuses ("divergent branches" or "not possible
to fast-forward"). Check for local work, then move to the new history:

```sh
chezmoi git -- fetch origin
chezmoi git -- status --short          # anything listed is local work: keep it first
chezmoi git -- reset --keep origin/main
```


**ACTION (if a private layer deployed a leak-guard) — the leak-guard, `run-repo-gates` and
`hook-doctor` move into the base, with their git wiring.** `~/.gitconfig` now declares the six
configured hooks `hook.publish-guard-<event>` (to `~/.local/bin/leak-guard`) and
`hook.repo-gates-<event>` (to `~/.local/bin/run-repo-gates`) for pre-commit, commit-msg and pre-push,
and `~/.zshrc` runs `hook-doctor check --path <worktree> --quiet` once per worktree per day on `cd`.
An overlay that shipped its own copies must stop: remove its scripts and the cd-time check, delete
the same-named `hook.*` entries from `~/.dotlocal/gitconfig`, list the old script paths in its
`.chezmoiremove`, and apply the overlay **before** the base, so no machine runs two copies.

The guard is **off until the domain supplies patterns.** With neither
`~/.dotlocal/git-leak-markers` nor `~/.dotlocal/git-leak-sensitive` present it passes every commit;
with either, a missing or empty file for an active gate refuses. A domain that supplies them should
also add `probe-marker=<token>` to `~/.dotlocal/git-leak-policy` (a token its markers match, which
`hook-doctor` plants to prove the guard live). `overlay-skeleton/README.md` shows the four files, and
`overlay-doctor` reports the guard as Tier H.

**Run `fleet-decl --check` before applying.** `run-repo-gates` reads the manifest for any repository
that tracks its own gates (`.githooks/` or `.husky/`) and refuses a commit there when the manifest is
missing or unreadable; once the domain supplies patterns, the guard does the same for every commit.

`run-repo-gates` no longer runs a gate that git already runs natively: when the repository's hooks
directory (`core.hooksPath`, as husky sets it) is the gate's own directory or husky's `_` inside it,
it leaves the gate to git. Before this, such a repository ran its pre-commit twice.

## 2026-09-30

**ACTION (if a private layer managed `~/.claude/settings.json` or the status line) — the base now
owns both.** `dot_claude/modify_settings.json` merges generic preferences (editor mode, UI, the
status line) over the live file, then the domain's fragment: an executable at
`~/.dotlocal/claude/settings-declared` printing `{"declared": {...}, "retiredHooks": [...]}` for
plugins, hooks, sandbox paths and permission rules. `statusline-command.sh` moves here too. The
skeleton has a fragment stub and a `run_onchange_` script that re-applies this target when the
fragment changes.

*What changes for you:* move your private layer's declared keys into the fragment and stop managing
the two files there, in the same sitting as pulling this; until then both instances write them.

**Five skills and a tool move into the base** from a private layer: skills `naming-build-tasks`,
`cross-platform-tooling`, `fault-isolation`, `vetting-tooling`, `claude-config-layers`, and the tool
`lint-tasknames`. Each skill ends by pointing at an optional
`~/.dotlocal/skills/<name>.md` for what is specific to one domain. `tests/run-all.sh` now runs each
suite with the interpreter its shebang names.

**A machine can decline a base skill:** list it in `skipSkills` under `[data]` in
`~/.config/chezmoi/chezmoi.toml` (`skipSkills = ["seo"]`). `chezmoi init` keeps the value. Ignoring
stops future deploys only; remove an already-deployed skill by hand.

*What changes for you:* if a private layer used to deploy any of these, pull and apply it in the same
sitting, so both instances do not manage the same files. chezmoi will warn that the config template
changed; `chezmoi init` clears the warning and changes nothing else.

**ACTION — the base now owns `~/.claude/CLAUDE.md`.** It holds the operating standards true on any
machine, then imports `~/.claude/tooling.md` and `~/.dotlocal/claude/CLAUDE.md`, the domain's own
fragment: who the user is, whether usage is flat-rate or billed, how commits are signed, and any
further imports. A private overlay deploys that fragment; `overlay-skeleton/` has a stub for it.

*What changes for you:* before its first write, the apply copies a `CLAUDE.md` the base did not write
to `~/.claude/CLAUDE.md.before-base` and says so (chezmoi would otherwise replace it without asking).
If that copy appears, move what is specific to this machine's domain into the fragment, through the
overlay if the machine has one, then delete the copy. If an overlay used to manage
`~/.claude/CLAUDE.md`, pull and apply the overlay in the same sitting: until it has stopped managing
the file, both instances write it and the last apply wins.

**`overlay-doctor` now assesses the machine it runs on** (advisory; `overlay-doctor --machine` runs it
alone, with or without an overlay). It reports the git that runs and whether its configured hooks
actually fire, measured in a throwaway repository; every `git` on `PATH`, in order; the tools the base
expects (`git zsh jq yq gitleaks chezmoi mani wt claude`); the login shell; the OS; Claude Code's
version; and the top-level key names of any managed Claude Code policy. It prints versions, presence
and key names only, never a value or a path under the home directory, so its report can be retyped off
any machine. It ends by naming the two deeper checks, `claude-context-probe` and its background-session
mode.

**`claude-context-probe --fleet` measures Claude Code's background-session features** on the machine it
runs on: starting a named background session with a model and a settings `env` block, listing it as
JSON (and whether rows carry `pid` or `state`), the session's `TMPDIR`, its transcript, attach,
resume in the background, removal, respawn, which model aliases answer, and which of the tools a
session fleet uses exist. It starts one small session and a few one-line model calls, removes
everything it created, and prints versions and verdicts only. Run it in an ordinary terminal.

*What changes for you:* nothing required. After applying, run the doctor and read its assessment: a git
older than 2.54, or an older git earlier on `PATH`, means the configured hooks (the secret scan, the
co-author trailer) are skipped silently.

**`overlay-doctor` asks every private file for a reason (Tier P, advisory).** The setup is public by
default: a file the private layer deploys either states why it must be private, or its mechanism
belongs in the base with the private part supplied through a `~/.dotlocal` fragment, chezmoi data, the
repository manifest or an environment variable. The reasons live in `PRIVATE-REASONS` at the overlay's
source root, one `target-glob<TAB>reason<TAB>why` line each, with the reason one of `secrets`,
`identity`, `infra`, `domain-program`, `domain-context`. Tier P lists every deployed file that matches no
line; with no list it prints one advisory line.

*What changes for you:* nothing required. To adopt it, write `PRIVATE-REASONS` and add it to the
overlay's `.chezmoiignore`; the files it leaves unlisted are the ones to move to the base.

**Two `overlay-doctor` false results fixed.** A `run_` script of the same name in both layers was
reported as one file with two owners, failing a correct overlay: a script runs in its own instance and
deploys nothing. And a template's `.tmpl` suffix was kept in its target, so a plain file in one layer
and a template of the same target in the other went unreported.

**ACTION if a private layer deploys a `register-standard` skill.** The skill has shipped from the base
since 2026-09-29. A private copy of `~/.claude/skills/register-standard/` now collides with it, and
whichever layer applies last wins; the doctor reports the collision. Remove the private copy, and put
anything domain-specific in `~/.dotlocal/skills/register-standard.md`, which the public skill reads.

**`kb project --domain` never writes a repository's root context files** (2026-09-29). A domain's
slice of the projection is written inside the knowledge base (`index/projections/domains/<slug>`) or to
`--out`; a directory that is a repository root is refused, and the config's per-domain `repo` key is no
longer read. *What changes for you:* if a domain config relied on that key, point the importing file at
the slice instead.

**New since 2026-09-26, nothing to do:** `claude-context-probe` measures which context Claude Code
loads on the machine it runs on. `context-lint` and skill `project-context-file` check a repository's
agent context file against one shape; skill `project-documentation` and `context-lint`'s docs checks do
the same for `docs/`. `register` gains typed relations shown from both ends, `register related` and
cross-entry reports in `register health`; `register-lint` refuses malformed relations, and refuses a
`done` closure without its review line only in a register whose README sets a start date for that.
`doc-lint`'s `spec-dirs:` takes a one-segment `*`, and a spec archived in the commit that promotes its
decisions is judged by its staged copy. `adr-lint` reads a Living record's cadence only where it
declares one. New skills: `recording-what-you-learn`, `filing-bug-reports`, `scratch-copies`.
`claude-scratch-hook` cleans Claude Code agent scratch through lifecycle hooks, where the machine's
settings wire them; on Linux, a tmpfiles rule ages the same scratch hourly.


## 2026-09-26

**ACTION — every commit is now scanned for plaintext secrets, and refused without gitleaks.**
`~/.gitconfig` gains a configured hook, `hook.secret-scan`, on `pre-commit`, which runs the new
`~/.local/bin/git-secret-scan` in every repository. It scans the staged changes twice with gitleaks:
once with `~/.config/gitleaks/floor.toml` (gitleaks' default rules, which a repository config cannot
weaken), then with the repository's own `.gitleaks.toml` when it has one. Found secrets are
redacted from the output. A finding that is not a secret is allowed with a `gitleaks:allow` comment
on its line, or its fingerprint in the repository's `.gitleaksignore`.

*What changes for you:* install gitleaks before applying, or every commit on the machine is refused
with a message saying so. The base `Brewfile` now declares it for macOS (`brew bundle`); on Arch,
`pacman -S gitleaks`. On git older than 2.54 the hook is ignored silently, as with every configured
hook, so there is no scan at all there.

## 2026-09-25

**Commits made from a Claude Code session now get a Claude co-author trailer automatically.**
`~/.gitconfig` gains a configured hook, `hook.ai-coauthor`, on `prepare-commit-msg`, which runs the
new `~/.local/bin/git-ai-coauthor`. When `CLAUDECODE` is set (Claude Code sets it in its sessions and
in the shells its subagents run), the hook appends `Co-Authored-By: Claude (<model-id>)
<noreply@anthropic.com>` unless the message already carries an Anthropic co-author trailer. The model
comes from the session's transcript. It is best effort: a subagent's commit is credited to its
parent's model, and when the transcript cannot be read the trailer says plain `Claude`. Commits
typed outside a session are untouched.

*What changes for you:* nothing to do on a machine with git 2.54 or later. On an older git the
`hook.*` keys are ignored silently and commits stay unattributed; `git --version` tells you which
you have. To keep the trailer out of one repository, run `git config ai-coauthor.enabled false`
inside it.

## 2026-09-23

**macOS shells now put Homebrew ahead of the system directories.** `~/.zshenv` prepends
`/opt/homebrew/bin` and `/opt/homebrew/sbin` on macOS, and `~/.zprofile` prepends them again,
because `/etc/zprofile`'s `path_helper` runs between the two in a login shell and moves `/usr/bin`
back to the front. Before this, neither file added Homebrew at all, so a Mac where Homebrew reached
`PATH` some other way could still run Apple's older copy of a tool the base Brewfile declares.
Measured on one Mac: `which -a git` listed `/usr/bin/git` (Apple git 2.50.1) ahead of Homebrew's
2.55.0.

*What changes for you:* every Homebrew formula now wins over a same-named system tool in zsh. GUI
apps and launchd jobs do not read these files and still see `/usr/bin` first. To check a Mac after
applying, open a new login shell and run `which -a git`; Homebrew's copy should be listed first.

**`chezmoi apply` now refuses early on a Mac missing a REQUIRED Brewfile formula — ACTION if you
have never run `brew bundle` against a Brewfile that gained one.** A new `run_before_` script (macOS
only; a no-op elsewhere) reads the base `Brewfile`, finds every `brew "..."` line whose comment
carries the marker word `REQUIRED` (currently only `yq`), and aborts the apply with one message
naming the missing tool and the fix — rather than letting the failure surface later, unexplained,
deep inside whatever script first needed it. It checks with `command -v` plus a fixed prefix search
(`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`), never `brew` itself, so it stays fast and
silent when nothing is missing.

*What changes for you:* if an apply now refuses on this, run
`brew bundle --file "$(chezmoi source-path)/Brewfile"`, then re-run `chezmoi apply`. See the
Brewfile's own header for the `REQUIRED` marker convention if you are adding a new one.

## 2026-09-22

### worktrunk's user config is now GENERATED, from three layers — ACTION on a machine with a private layer

`~/.config/worktrunk/config.toml` is written by `wt-config-gen`, not deployed by any dotfiles layer.
Its sources: `~/.config/worktrunk/base.toml` (shipped here — generic settings only), an optional
private fragment at `~/.dotlocal/worktrunk.toml`, and a `worktrunk:` block on each project in the
repo manifest (`~/Devel/mani.yaml`, or `$FLEET_RECORD`). Applying this base runs the generator.

- **ACTION, if a private layer used to deploy `config.toml` itself:** it must stop, or the two will
  overwrite each other. Global private policy moves to the fragment; per-repo entries move to the
  manifest.
- **A machine with a manifest you edit by hand:** run `wt-config-gen` after editing it.
- **New tools here:** `wt-config-gen`, `wt-bootstrap` (dependency install for a new worktree, opt-in
  per repo with `worktrunk.bootstrap: true`), and `fleet-decl`, the manifest reader, which moved here
  from a private layer so a machine with only this base can read its own manifest. It needs the
  mikefarah `yq`, already required by this base.

---

## 2026-09-20

**New tool: `register-lint`** — checks a work register's entries against the contract its own README
states: the status vocabulary and which fields each status requires or forbids, where closed entries
live, that a closed entry carries a resolution and an open one a next action, and above all that a
closure condition is either written or its ABSENCE is declared in a fixed vocabulary. Not an ACTION on
its own; nothing changes until a repository chooses to call it.

**Why the absence needs a vocabulary at all, since this is the part that looks like ceremony.** A
checker cannot tell a real closure condition from a sentence explaining there isn't one — both are
just prose. Measured in one store before this existed: a checker written specifically to enforce "no
entry past `idea` without a closure condition" tested that the heading had some text beneath it, so
the literal string `TODO` passed it clean. A green run was fully compatible with the state the check
existed to prevent. Giving the absence a fixed spelling is what makes the check three-state — written,
declared absent, or unrecorded — and only the third can fail.

**It also reports a register whose finished entries sit in a directory named `archive/`.** Build
tooling commonly skips any path containing that word, because an archived tree is frozen and exempt
from checking, while a closed register entry is an ordinary document that must keep being checked.
The legacy directory is still READ, so a register can be linted before it is renamed — but the
fallback reports, so it can never be mistaken for a permitted spelling.

**What to do on an already-adopted machine:** nothing, until a repository you work in starts calling
it. When one does, that repository's commit hook will need this tool present — so apply the base
before pulling a repo that has wired it, or the hook fails on a machine that looks fine otherwise.


**New tool: `comment-lint`** — fails a source comment that depends on context the file cannot carry:
a record id from a tracker that lives elsewhere, a numbered unit of a plan the file does not contain,
a path under one user's home, prose that only resolves for whoever was in the room. Not an ACTION on
its own; nothing changes until a repository chooses to call it.

**Why it is installed rather than copied into each repository.** It is one file, on purpose. A
repository that gates on it calls it by name, so a rule tuned once takes effect everywhere at the
next apply. The alternative — a copy per repo — was tried first for two repos and abandoned: the
failure mode is silent, a category tuned in one copy and stale in another, with both copies still
passing their own tests.

**The trade-off, stated because it is real.** The gate now depends on a machine-level install rather
than travelling inside the repository. A checkout on a machine without this base has no gate, so any
caller must FAIL when the tool is absent rather than skip — a check that quietly does not run is
worse than no check.

**It carries no vocabulary.** The record ids it looks for are supplied per repository, through
`--markers`, `$COMMENT_LINT_MARKERS`, or `.comment-lint-markers` at the repository root. A built-in
list would be un-shippable in a public repo and would make the tool un-installable in precisely the
places that need it. With nothing configured, that one category reports itself INACTIVE on stderr
rather than passing in silence.

---

## 2026-08-31

**The zsh prompt now carries a one-character machine tag** — `[<tag>]` normally, `[ssh:<tag>]`
when the shell is an SSH session. Not an ACTION: the base ships the mechanism plus a generic fallback (the
first character of the short hostname), so it works with no overlay change.

**Optional overlay input:** the hostname → letter mapping is personal, so it is not in the published
base. Your private layer may set `FLEET_TAG` before the prompt is built to choose the letter.

Two things about the shape, so nobody "improves" them back: it is a bracketed LETTER rather than a
colour, because colour does not survive a monochrome terminal, a screenshot, a recording or a theme
change, and it is the first cue to fail a reader with a colour-vision or single-eye difference — the
colour here is decoration on top of a cue that already works without it. And SSH costs nothing: a
remote shell renders its prompt on the REMOTE host, so it tags itself correctly with no forwarding
and no client-side logic.

---

## 2026-08-30

**BREAKING IF YOU DO NOT PULL — the nvim `snacks` fork pin moved off sourcehut, and there is a
date on it.** sourcehut's terms now prohibit LLM-produced content and that forge is being vacated on
**2026-09-10**. This pin was the only thing in these dotfiles that would actually break: lazy.nvim
clones it on every machine, so left alone it fails on the next plugin install or on any fresh
machine — and it presents as *"Neovim is broken"* rather than as a forge shutting down, which is why
it earns a loud entry rather than a quiet fix.

It points at **github** rather than the self-hosted forge deliberately: this is cloned on
machines where no personal account is logged in, so the URL has to resolve as an anonymous,
unauthenticated HTTPS clone. That is the same constraint that already puts the public base there.
The `pending-upstream` branch was pushed to the github fork first — swapping the URL alone would
have failed on a missing branch, or, with the branch line dropped, silently fallen back to plain
upstream and reintroduced the image bug with nothing on screen to say why.

**Also nvim: the puppeteer browser-resolution block was deleted by accident and restored in the same
window.** If you pulled between those two commits, pull again. Without that block, puppeteer
downloads its own vendored Chrome (~150 MB) outside package management instead of using an
already-installed browser for mermaid rendering.

**ACTION (any machine you drive non-interactively — macOS especially) — `chezmoi-overlay` now
resolves the chezmoi binary itself, and an earlier "nothing pending" reading may have been false.**
It used to `exec chezmoi` bare. Over ssh on a Homebrew machine `/opt/homebrew/bin` is not on the
PATH that `.zshenv` builds, so the wrapper was reachable and its dependency was not: exit 127.

The quiet shape of that failure is why this is code rather than a note. A caller that FILTERS the
output — grepping for diff headers to see what is pending — gets an empty result and reads it as
"nothing pending, machine in sync", which is the exact inverse of the truth. Measured on the darwin
CI node: the overlay was three commits behind and reported no pending changes. It now resolves via
`command -v`, falls back to the usual prefixes, and exits 127 naming the PATH it searched.

*What to do:* re-run `chezmoi-overlay diff` and trust that reading rather than an earlier one taken
from a non-interactive shell.

**New: `ui-shot` and the `visual-review` skill — and `ui-shot` is already FROZEN.** It renders a page
headless and always produces TWO captures: the whole page, and the changed region at native scale.
The second is the entire point — a full-page screenshot rendered into a transcript is scaled down,
so a 1px border or a subtle divider is simply not present in what the reviewer sees, and "I looked
at it" becomes false confidence rather than a lie.

**Pulling this downloads nothing.** It resolves the PROJECT's playwright (shallowest `node_modules`
searching down from the repo root, which covers the three layouts in use) and fails loudly rather
than installing or falling back to a global one — so on a machine with no project playwright it is
simply inert. There is deliberately no `--headed`: a visible window is an unrequested interruption
of whoever is at the keyboard.

FROZEN on the day it landed, and the freeze is in the script's own header: **do not add flags.**
Visual-review tooling belongs in a shipped package that projects depend on, with its guiding skill
riding along, not developed globally here. What settled it: two projects independently asked for
authentication, and auth is irreducibly project-specific — a global tool cannot hold per-project
auth, route matrices or viewport sets. Keep using it; it works and was validated against real pages.
But a new capability belongs in the package. Known gaps left for it to inherit: authentication,
per-project route/viewport matrices, forced-colors emulation, and a combined index across runs.

**`overlay-doctor` gained a Tier V advisory check for `allowedSignersFile`, and it NEVER gates.**
`allowed_signers` is a shared asset — every signing repo on a machine points at the same file, so
one absent or empty copy degrades signature VERIFICATION everywhere at once, silently.

Advisory rather than required, deliberately: signing is legitimately disabled where an agent sandbox
cannot reach `~/.ssh` at all, and requiring signers there would turn a correct setup into a hard
failure — the cry-wolf outcome this doctor already avoids elsewhere. Three outcomes: no
`allowedSignersFile` configured reports `info`; a value pointing at a missing file reports
`advisory`; a file present but with no principal lines also reports `advisory`, because a
comments-only file looks populated and verifies nothing. **On a machine where signing is off by
design, a line here is the expected output, not something to fix.**

**`portability-lint` gained a bash 3.2 rule.** `empty-array-nounset` — under `set -u`, bash 3.2
aborts on `"${arr[@]}"` when the array is empty. macOS ships bash 3.2, so this is a macOS-only abort
that a Linux run cannot reproduce and a reviewer cannot see.

---

## 2026-08-29

**ACTION (KB repos only) — `kb install-hooks` now writes a wider hook; re-run it to pick that up.**
`kb` 0.3.0 adds `kb index --check`, the missing sibling of the existing `kb project --check`, and
the generated pre-commit now runs all three checks (`lint`, `project --check --if-present`,
`index --check --if-present`) instead of `lint` alone. An already-installed hook is NOT rewritten
by pulling the base — it is a file in each repo's `.git/hooks`, which chezmoi does not manage — so
a machine keeps the old lint-only hook until you re-run `kb install-hooks` in that repo. Nothing
breaks if you don't; you simply keep the old, narrower gate.

Why it exists: a KB has two derived outputs, and only one of them was checkable. Between
2026-08-17 and 2026-08-29 a KB on this fleet left `index/sources-of-truth.md` unregenerated —
missing an entry for a topic adopted in that window, plus four superseded descriptions — while
every projection stayed correct. The fresh layer is what hid the stale one.

**New: `portability-lint`** — finds GNU-only shell spellings that break on BSD/macOS. Run it in
any repo (`portability-lint`, or `portability-lint PATH...`); `--list` prints the rule table,
`--strict` fails on warnings too. Ten rules at the time of writing, each probed against a real macOS userland rather
than recalled — the table has GROWN since, and `portability-lint --list` is the live source
rather than this list: the in-place sed flag (no portable spelling exists — use temp-file + mv), `\t` inside a
sed/grep bracket expression, `stat -c`, `date -d`, `base64 -w`, `grep -P`, `find -printf`,
`timeout`, the `${TMPDIR:-/tmp}` trailing-slash trap, and a quoted `wc -l` compared as a string.

It deliberately does NOT flag `readlink -f` or `xargs -r`, which are commonly listed as GNU-only and
both work on modern macOS. An over-broad portability claim is worse than none — it sends you to
write a workaround for a problem you do not have, and costs trust in the rules that are real.

The two-spelling idiom (`stat -c … || stat -f …`) is the recommended FIX and is exempt, including
when the GNU attempt and the BSD fallback are on different lines. Suppress a genuine single-platform
case with `# portability-lint: ignore [rule,...]` on the line, or `# portability-lint: disable-file`.
Needs python3 (present on macOS and here); targets 3.9, which is macOS's system version.

ShellCheck does not overlap with this — it models shell syntax, not the userland of the commands you
invoke, and was verified silent (exit 0) on every rule above.

**Nothing ran the test suite — now something does.** The base ships 20 suites and had no
runner, no CI and no hook; they were run by hand, one file at a time, when someone remembered.
Added `tests/run-all.sh` (`sh tests/run-all.sh [filter]`, ~10s for all of them), and the git-hooks
installer now also writes a `pre-commit` into the source repo that runs it when anything under
`private_dot_local/bin/`, `setup/` or `tests/` is staged. Docs- and config-only commits are not
taxed. Escape hatch for a deliberate WIP commit: `SKIP_BASE_TESTS=1 git commit …`.

Judge suites by EXIT CODE, not by grepping for a `PASS` line — the suites do not share one
convention (`test-git-snapshot.sh` ends in `passed 13, failed 0`), and an ad-hoc grep-based runner
reports it as failing while it is green. That misreport happened on the first whole-suite run.

**Fixed: a tracked symlink in the base had been dangling since the `naming-build-tasks` skill moved
to the private layer.** The move was deliberate; the base's pointer at it was simply not removed
with it. The only symptom was `chezmoi: stat …: no such file or directory` on stdout from
`chezmoi execute-template` / `chezmoi diff`, which silently corrupts the output of anything
capturing them. New `tests/test-repo-hygiene.sh` fails on any dangling TRACKED symlink.

`--check` remains STRICT by default (a KB with content and no generated output is drift).
`--if-present` downgrades "never generated" to a pass, and exists for the generic hook, which has
to work in a KB that has deliberately published nothing yet. A repo that always publishes should
gate with the strict form, which additionally catches a DELETED output.

**New: `kb` enforces a size budget on the Tier-0 projection — opt-in, and per KB.** Set
`projection_max_bytes` in that KB's own `kb.toml`. No key means no check, so nothing changes for a
KB that does not set one — and separate instances (personal, work) can carry different ceilings.
`kb project` prints usage as a percentage; `kb project --check` treats over-budget as drift, so a
generated pre-commit refuses the commit that pushes it over.

It checks the **freshly rendered** projection, not the committed file. Checking the committed one
would pass the very change that pushes it over, since the committed file is by definition the
pre-change size.

Bytes rather than tokens, deliberately: bytes are exact and free to measure, while a token count is
an estimate that varies by tokenizer — and a budget that is precise about the wrong unit invites
arguing with it. Why it exists at all: the projection loads into EVERY session at startup, so its
size is a tax paid per session forever, and it only ever grows because every amendment adds and none
subtracts. The point is not the number, it is the forced choice — adding a rule means deciding what
leaves.

**The git-hooks installer now clears inherited `GIT_*` variables before running the suite.** Git
exports `GIT_DIR`, `GIT_INDEX_FILE` and friends into a hook, and everything the hook runs inherits
them — `GIT_DIR` in particular makes ANY directory look like a repo, so a test asserting "this is
not a repo" fails. Measured: a suite reported failing during a real commit while passing standalone.
A gate that cries wolf gets disabled, so they are cleared.

---

## 2026-08-15

- **`chezmoi-overlay` is now a real script**, not a zsh function (`~/.local/bin/chezmoi-overlay`).
  It previously did not exist in non-interactive shells, so `ssh <host> 'zsh -ls'` reported
  "command not found". No action: the command behaves identically, and now also works over SSH and
  from scripts.
- **`nm-applet` no longer autostarts.** The fleet runs iwd + systemd-networkd + systemd-resolved, so
  the applet had nothing to manage; it is suppressed by `~/.config/autostart/nm-applet.desktop`
  (`Hidden=true`), which covers every WM rather than one config at a time. **ACTION only if a machine
  genuinely uses NetworkManager** — delete that file there.
- **`overlay-doctor` got stricter and more correct.** It now recognises required pieces authored as
  `.tmpl`, and enforces the disjointness rule it previously only stated: the same target *file*
  managed by both layers is now a `CONFLICT`. **ACTION:** re-run it; a machine that was quietly
  co-owning a file will now be told.

## 2026-08-01

- **Brewfile include direction corrected: the BASE includes the overlay's role file.** The earlier
  (superseded) shape had `Brewfile.role` `instance_eval` the base — the inversion. A machine still
  carrying the old shape double-evaluates. **ACTION:** in your overlay, `Brewfile.role` must contain
  *only* this domain's additions; delete any `instance_eval(.../chezmoi/Brewfile)` line from it.
  _(This is the change that reached a machine silently and had to be fixed by hand. It is the reason
  this changelog exists.)_

## 2026-07-25

- **The overlay must supply its own `.chezmoi.toml.tmpl`.** Overlay config is now rendered from a
  template the overlay provides, and it is enforced. **ACTION:** an older overlay without one is
  non-compliant — author it (the base's `overlay-skeleton/` shows the shape).
- **`Devel/mani.yaml.tmpl` is a required Tier-C overlay piece** (the fleet repo manifest).
  **ACTION:** author it in the overlay if missing; `overlay-doctor` will flag it.

## 2026-07-10

- **Private spell tier renamed** `personal.utf-8.add` → **`private.utf-8.add`**. **ACTION:** rename it
  in the overlay; the old name is no longer read.
- **Commit signing moved to the overlay.** The base no longer carries signing config. **ACTION:** the
  overlay's `gitconfig` must define `user.signingkey` (and `gpgsign` where this domain signs) — the
  doctor treats an identity without a `signingkey` as incomplete.
- **`overlay-doctor` added.** Run it after any base update to see whether the overlay still satisfies
  the current standard.

## 2026-07-09

- **The full leak-guard is overlay-owned**; the base ships only a generic pre-push floor. No action
  for a machine that already has the guard; a machine without one is unguarded **by design**
  (home-only), not broken.

## Earlier

Before this file existed, shape changes were communicated only by reading the diff. If you are
adopting a long-dormant machine, do not trust this file to be complete for that era — run
`overlay-doctor`, `chezmoi diff` and `chezmoi-overlay diff` and treat their output as authoritative.
