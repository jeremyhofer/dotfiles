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

## 2026-10-29

### Python tools run on Python 3.9 again; `gitleaks` and `codespell` are REQUIRED (ACTION on a Mac: `brew bundle`)

- **`us-spelling-lint`, `comment-lint` and `doc-lint` crashed on Python 3.9**, the `python3` that
  macOS's command-line tools ship, at load (`TypeError: unsupported operand type(s) for |`): their
  annotations used the `X | None` form, which 3.9 evaluates. `us-spelling-lint` runs from a
  configured hook on every commit (2026-10-23 below), so in any context where 3.9 is the first
  `python3` on PATH (a GUI git client, an IDE, a launchd job) every commit in every repository was
  refused. Each now carries `from __future__ import annotations`, and their suites pass under 3.9.
  `overlay-doctor --machine` now reports which `python3` is first on PATH and its version.
- **`gitleaks` and `codespell` carry the Brewfile's `REQUIRED` marker.** Both are called by hooks that
  run on every commit and refuse when the tool is missing, which is what the marker means, so a Mac
  without them now has `chezmoi apply` refuse up front, naming `brew bundle`, instead of every commit
  refusing later. **ACTION on a Mac:** `brew bundle --file "$(chezmoi source-path)/Brewfile"` before
  applying. `overlay-doctor --machine` now lists `codespell` among the tools it assesses.
- **The `machine-snapshot` LaunchAgent (2026-10-17) is opt-in on the work domain.** It samples every
  process every 15 seconds, which on an employer's machine is the employer's call, and a refused
  `launchctl` there would fail the apply. With `domain = "work"` neither the agent nor its loader is
  deployed unless the machine's generated config has `machineSnapshot = true` in `[data]` (never
  prompted; `chezmoi init` keeps it, like `skipSkills`). Personal machines are unchanged.
- **`overlay-doctor`'s directory-conflict report names the fix**, and skill `dotfiles-update` now
  runs the full doctor BEFORE applying as well as after. A directory both layers manage with
  different attributes (the base's `private_dot_local` against an overlay's `dot_local`, say) makes
  chezmoi ask to overwrite it on every apply, as each instance resets the mode the other set. The
  report now gives both source entries and the overlay-side `git mv` that makes them agree.
- **`overlay-doctor` counts the directories an external implies (ACTION if an overlay has externals
  under a directory the base declares private).** An external makes chezmoi create every parent of
  its target, with plain attributes unless that instance's source declares the directory. An
  overlay cloning into `~/.local/share/<name>` therefore made `~/.local` 0755 against the base's
  `private_dot_local` (0700), and chezmoi asked to overwrite `~/.local` on every apply, though
  neither source tree showed a conflict. The doctor now reads each tree's `.chezmoiexternal.toml`
  (and `.toml.tmpl`) and reports such a directory with its fix: declare it in the overlay as the base
  does, `private_dot_local/.keep`. YAML and JSON externals files are not read.
- The first version of that change (`23e96bb`) did not parse under bash, so on a Mac, where `sh` is
  bash, `overlay-doctor` stopped at once with an "unexpected EOF while looking for matching" quote
  error. Fixed, and a
  new test parses every shell script in the repository under both `bash` and `sh`.
- **`overlay-doctor` honors a `.chezmoiroot`.** An overlay whose repository moves its source root into
  a subdirectory was read from the repository root, so every entry mapped to the wrong target and no
  co-owned directory or file could be found. The doctor now follows the file and says so on its
  first line.
- **`claude-trust-check` reads the manifest in three calls instead of two per project**
  (`fleet-decl --values <key>`, new), and `overlay-doctor` skips its Tier W trust report on the work
  domain unless `OVERLAY_DOCTOR_TRUST=1`. On a manifest of hundreds of repositories the per-project
  reads took minutes, and there most repositories never host a background session.
- `hook-doctor` switches the spelling hooks off during its leak-guard probes, as it already did the
  repository gates: a spelling refusal of its clean input used to read as `BLOCKED`, a broken guard.
- **ACTION for a private layer, if anything outside the layers adds Claude Code hooks:** for every hook
  event the base or a layer's settings fragment declares (the base now declares `PreToolUse` and
  `SubagentStart`, since 2026-10-10), the joined list REPLACES that event's list in
  `~/.claude/settings.json` on apply. A hook present only in the live file for those events, added by
  hand or by other tooling, is removed. Declare every such hook in the layer's fragment.
  `docs/reference/private-layer.md` now describes the join.
- Documentation corrected for adopting a work or other second-domain machine: the configured-hooks
  table in `docs/reference/architecture.md` lists the spelling hooks; `docs/reference/private-layer.md`
  lists `sandbox.excludedCommands` among the keys `claude-project-settings` accepts and three more
  checks; `docs/reference/standard-clone-changeover.md` addresses machines with a private layer, the
  global ignore file the base does point git at, the `fleet-repo` support that landed 2026-10-10,
  and a container still in the `.bare` shape (no rename needed first).

## 2026-10-25

### A private layer can set tmux options in `~/.dotlocal/tmux.conf`

`~/.tmux.conf` now runs `source-file -q ~/.dotlocal/tmux.conf` after the base's own settings and
before TPM loads the plugins, so a layer's file overrides the base's values, plugin options
included. With no such file nothing changes (`-q`). Optional; the example is in
`docs/reference/private-layer.md`, "tmux". Linux and macOS alike.

## 2026-10-23

### New commit gate: `us-spelling-lint` refuses new British spellings (ACTION: install `codespell`; decide where it applies)

Two configured git hooks in `~/.gitconfig`, `us-spelling-pre-commit` and `us-spelling-commit-msg`,
run `us-spelling-lint --hook ...`. They refuse a commit that ADDS a British spelling to a staged
markdown line, or to the commit message; existing text is never judged. They act only in a
repository the fleet manifest lists and does not tag `upstream`; with no manifest they pass, and a
manifest that exists but cannot be read makes them refuse. Like every configured hook they need git
2.54+, and an older git skips them silently.

- **ACTION:** the engine is `codespell` (in the Brewfile, `REQUIRED` from 2026-10-29). While it is
  missing, the gate refuses every commit in a listed repository (exit 2). `command -v codespell` is
  the quick test; `us-spelling-lint --all` audits a repository's existing text.
- **ACTION, decide per domain:** a listed repository whose spelling is not yours to change (a
  client's, a third party's, an employer's with its own style) gets the gate too. Tag it `upstream` in
  the manifest, or switch the hooks off in the layer's git config: `hook.us-spelling-pre-commit.enabled
  false` and `hook.us-spelling-commit-msg.enabled false` (`docs/reference/architecture.md`, "Switching
  a hook off").
- A per-repository `.us-spelling-lint` file configures it (`exclude:`, `include:`, `allow:`), and a
  trailing `codespell:ignore <word>` comment exempts one word. Skill `spellcheck-standard` has the
  split between this check and a project's own spellchecker.

## 2026-10-17

### `machine-snapshot` runs on macOS too, from a LaunchAgent

A Mac now records what is loading it every 15 seconds, as the Linux machines do from their systemd
timer: `~/Library/LaunchAgents/com.jeremyhofer.machine-snapshot.plist`, loaded by a `run_onchange`
script on apply, with the same `now`, `since MINUTES` and `between START END` (which also takes
`@EPOCH` seconds now). It reads libproc instead of /proc, records the memory and thermal pressure
levels and swap instead of /proc/pressure, sees only its own user's processes (macOS hides other
users' entirely; their load shows only in the load average), and files load
under the CI bridge's worker and podman's VM as well as Claude sessions. It runs
`/usr/bin/python3`, so the Command Line Tools must be installed (they already are wherever Homebrew
is); the load step needs the user logged in graphically, and fails the apply where nobody is.

## 2026-10-12

### Commit gates judge what is staged, not the working tree (silently different; ACTION if a layer installed a test gate)

`run-repo-gates` now runs a repository's tracked `.githooks/pre-commit` through the new
`git-staged-run`, which sets unstaged edits to tracked files aside for the gate's run and puts them
back afterwards. Before, a gate read the disk while the commit was made from the index, so it could
pass or refuse on code the commit did not contain. Untracked files stay visible; during a merge the
gate runs on the working tree; if the edits cannot be put back, both patches are kept in `$TMPDIR`
and named. A gate refuses to run when `git-staged-run` is not on PATH, so apply the base first. An
unstaged fix no longer changes a gate's verdict: stage it.

- The base's own source-tree gate is now written by `install-test-gate`, which judges the staged tree
  the same way.
- **ACTION, only if a private layer installed a test gate with `install-test-gate`:** the layer's
  trigger hashes its `tests/run-all.sh`, not the tool, so the installed `.git/hooks/pre-commit` keeps
  judging the working tree until `install-test-gate` is run again. Re-run the command the layer's
  `run_onchange_install-test-gate.sh.tmpl` runs (`overlay-skeleton/opt-in/`).

### `claude-project-settings`: per-project Claude Code settings declared in the manifest (opt-in)

A project's `.claude/settings.local.json` can be declared instead of hand-edited on each machine:
`claudeLocalSettings: claude/projects/<project>.json` in its manifest entry names a JSON file under
`~/.dotlocal`. `claude-project-settings apply` validates and merges each one (declared keys win, an
array replaces the live one, other live keys are kept), `check` reports drift, and `validate` holds
a file to closed rules: only `sandbox.filesystem.allowWrite` and `sandbox.excludedCommands`, never
`permissions`. Nothing happens unless a manifest declares the key, and `fleet-decl --check` accepts
it (from 2026-10-25). **ACTION when adopting:** copy
`overlay-skeleton/opt-in/run_onchange_after_apply-project-claude-settings.sh.tmpl.example` into the
layer without `.example`; `overlay-doctor` requires that trigger whenever the manifest declares the
key. A sandboxed session cannot run `apply`. Reference: `docs/reference/private-layer.md`.

### `fleet-repo clone` runs an optional `~/.dotlocal/hooks/post-clone`

At the end of every `fleet-repo clone <project>`, fresh or reconciling, an executable
`~/.dotlocal/hooks/post-clone` is called with the repository's path and the project name, so a layer
can finish a clone with what only it knows (remotes, say). Unlike `post-worktree-create` it is not
advisory: a failing hook makes `fleet-repo` exit 1, the clone left in place, and it runs on every
re-run, so it must be idempotent. `clone --url` does not run it. No hook, no change.

## 2026-10-10

### Standard clones are the fleet layout; `fleet-repo` learns them (ACTION, per repository)

A repository is now an ordinary clone with worktrees nested at `<repo>/.worktrees/<name>`. A manifest
entry is a standard clone unless it declares a container (`container:`, a `clone:` running
`fleet-repo` or `git-clone-worktree`, or `worktrunk: layout: bare`); `fleet-decl --layout <project>`
answers which. `fleet-repo clone`, `update` and `check` handle standard entries and refuse a container
found where a standard clone is declared; containers keep today's behaviour, so **a machine whose
manifest still declares containers sees no change**. Changing a repository over is a fresh clone with
the old directory kept: `docs/reference/standard-clone-changeover.md`. **ACTION, when you change a
repository over:** list `.worktrees/` in its own `.gitignore` before creating any worktree (Nx and
other tree-walkers break on un-ignored nested copies), and never run `mani sync -w` on it (it removes
undeclared worktrees).

### New Claude Code hooks, and hook lists now merge across layers (ACTION if your layer declares hooks)

`claude-worktree-hook` is wired from the base's settings merge: it refuses a session's raw
`git worktree add`/`move` (warns on `remove`), refuses `EnterWorktree` wherever the effective
`worktree.bgIsolation` is `"none"`, and warns when a subagent starts while the checkout has commits
not on its upstream. **Hook event lists from the base and the private fragment are now joined**, where
before the fragment's list replaced the base's; check that your fragment's hooks still appear once.
The base no longer declares `worktree.baseRef` (Claude Code's default, `"fresh"`, applies; a live
file keeps whatever it already has).

### `wt-fetch-base`: new worktrees start from a fresh fetch (opt-in)

Two worktrunk hooks make worktree creation fetch the base branch from `origin` (then each
`fetch-base.fallback` remote) and refuse when none answers. Off until `git config fetch-base.enabled
true` at some scope; the base does not enable it.

## 2026-10-09

### `mani` finds `~/Devel/mani.yaml` from any directory

`~/.zshenv` now exports `MANI_CONFIG=~/Devel/mani.yaml` when that file exists (a value already set
is kept). mani reads it only when no `mani.yaml` is found at or above the current directory, so a
repository with its own manifest is unaffected. Nothing to do beyond applying; open a new shell.

### Skill `fleet-manifest` is retired

Everything it said is now in `docs/reference/fleet-manifest.md`, including the add-a-repository
procedure and its one-project proof (a new section). The mistakes it warned about are refused or
reported by the tools themselves: `fleet-repo` refuses a populated non-container parent and warns
on a wrong default branch, and `fleet-repo check` reports `plain-clone`, `worktrunk-missing` and
`old-layout`. Its predecessor `working-across-repos` was retired on the same grounds, after a test.
Applying removes the deployed directory (`.chezmoiremove`). If `skipSkills` lists it, that entry is
now inert and can go.

### A bare container's repository is named `.git`; worktrunk's default path follows the shape

**Why.** Claude Code's sandbox lets a linked worktree write its repository's shared git directory
(commits, ref updates) only when that directory is named `.git`. A container whose bare repository
is `.bare` therefore needed its whole root granted writable in sandbox settings, which also opens the
repository's `config` and `hooks/` to every sandboxed session. Naming the bare repository `.git`
makes the built-in rule apply, and the sandbox leaves `config` and `hooks/` read-only.

**What changed.**

- **`fleet-repo clone` builds the new shape:** `<container>/.git/` is the bare repository, with no
  pointer file. Every verb still accepts an old `.bare` container, so updating the base converts
  nothing and breaks nothing.
- **`fleet-repo check` reports an old container as `old-layout`** and prints the three conversion
  commands. There is no conversion verb.
- **`base.toml`'s default `worktree-path` is shape-aware:** a bare repository named `.git` gets
  sibling worktrees, anything else nests under `.worktrees/`. An undeclared bare container no longer
  gets worktrees inside its own git directory. `worktrunk.layout` stays valid.
- **`hook-doctor` and `claude-context-probe`** recognise both shapes; the probe's container fixture
  is now the new one.
- **`claude-trust-check` is new, and `overlay-doctor` reports untrusted directories (Tier W,
  advisory).** Claude Code refuses `claude --bg` in a directory whose workspace trust nobody has
  accepted; the tool reads Claude Code's state (never writes it) and lists the manifest's
  directories still waiting, grouped by repository, with the command to accept each.
- **`claudeTrust: false` on a manifest project** leaves it out of `claude-trust-check` (and so out of overlay-doctor's list), for a repository no agent session should run in. The summary names every opted-out project.
- **Skill `working-in-worktrees`:** a sandboxed session creates a worktree with the EnterWorktree
  tool by name; `wt switch --create` remains the route for a person or an unsandboxed script. A
  session writes the worktree it is in plus the shared `.git`, so it lands from the default
  branch's worktree after ExitWorktree.

**ACTION, in this order.**

1. **Update the base on every machine first** (pull, `chezmoi apply`). The tools accept both shapes,
   so nothing needs converting yet.
2. **Convert each container,** with nothing running in it (no session, editor or git process;
   every worktree is broken between the second and third command):

   ```sh
   rm <container>/.git
   mv <container>/.bare <container>/.git
   git -C <container>/.git worktree repair
   ```

   `fleet-repo check` prints these with the path filled in. The procedure is in
   `docs/reference/repository-layouts.md`, "Converting a `.bare` container from the old shape".
3. **Move the container's Claude Code memory store** from the project key ending in `--bare`
   (under `~/.claude/projects/`) to the same key without the suffix. Claude Code will ask for
   workspace trust again after converting a container (the trust key changes from
   `<container>/.bare` to `<container>`); accept it. `claude-trust-check` lists what still needs it.
4. **A private layer's container-root sandbox grants become unnecessary** once its containers are
   converted. Remove them then, not before: an unconverted container still needs its grant.

---

## 2026-10-08

### New worktrees get the gitignored files their repository lists in `.worktreeinclude`

The standard is in `docs/reference/repository-layouts.md` ("Files a worktree needs that git does not
carry"): per-machine files such as Gradle's `local.properties` or a `.env` live in the default
branch's worktree, the repository lists them in a `.worktreeinclude` there, and every new worktree
gets a copy. Two mechanisms, one copy (worktrunk's `wt step copy-ignored`):

- **`base.toml` ships a global `pre-start` hook, `copy-files`.** It does nothing, silently, in a
  repository without a `.worktreeinclude`, so existing repositories are unaffected until they opt in.
- **`fleet-repo clone` copies into each `worktrees:` entry it adds** to an existing container.
- **`wt-config-gen` now MERGES a hook table opened by more than one source** instead of refusing it,
  and refuses a hook name defined twice. Before this, a private fragment's `[pre-start]` and the
  base's would have collided. Every other duplicate table is still refused.

**ACTION, on any machine whose private worktrunk fragment defines a `pre-start` hook named
`copy-files`:** rename it; the generator now refuses the clash and keeps the old config. Then, per
repository that needs files copied, write its `.worktreeinclude` (the doc shows the untracked form
for a repository you cannot commit to). A fresh clone's first worktree is not covered: set it up by
hand once.

## 2026-10-07

### `fleet-repo` replaces `git-clone-worktree`, and a manifest entry can declare its container

`fleet-repo clone <project>` makes a bare container match its manifest entry, and `fleet-repo update`
and `fleet-repo check` keep it matching. `git-clone-worktree` still exists and forwards to it
(`--mani-project <name>` to `clone <name>`, `<url> [target]` to `clone --url`, `--filter=` as an
override), so no `clone:` line breaks. A domain can move its lines to `fleet-repo clone <name>` at its
own pace.

- **What a container fetches is now declared.** A project's `container:` block takes `branches`
  (`all`, `default` or a list) and `filter` (a partial clone, for a fresh clone only); a fleet-level
  `containerDefaults.branches` sets the default, and absent still means `all`, so a machine that
  declares nothing behaves as before. The default branch and every `worktrees:` branch are always
  fetched. Branches outside the set never arrive, which also avoids the ref collisions that
  case-differing branch names cause on a case-insensitive file system.
- **Re-running reconciles, and never deletes your branches.** `mani sync` runs `clone:` only where
  `path` is missing, so a changed declaration reaches an existing container only through
  `fleet-repo clone <name>` run by hand. That adds and fetches new branches, drops the refspec and
  remote-tracking ref of an undeclared one, and only reports a local branch or worktree for it.
  The old tool deleted every local branch except the default on each re-run.
- **A container is bare to `wt-config-gen` without a `worktrunk:` block.** An entry with a
  `container:` block, or a `clone:` that runs `fleet-repo` or `git-clone-worktree`, gets the sibling
  worktree layout unless `worktrunk.layout` says otherwise. After the next apply, those entries
  gain a table in the generated worktrunk config; `worktrunk: {layout: bare}` on them is redundant.
- **`fleet-decl` grows read-only additions:** `--entry-list <project> <key> [<item-key>]`, and
  `--check` validates `container:` and `containerDefaults:` (a near-miss such as `branchs` is a
  finding). Its exit codes and every existing answer are unchanged.
- No ACTION is required. To adopt: change a `clone:` line to `fleet-repo clone <name>`, move any
  `--filter=` into `container.filter`, and run `fleet-repo check`. The shim is removed once no
  manifest names it.

### A private layer carries a trigger for each input it ships — ACTION where its manifest has none

The base re-runs its generators and installers only when the base's files change. An input a private
layer ships (its manifest, its Claude settings fragment, its skill list) reaches its deployed file on
apply and reaches nothing generated from it unless the layer carries a `run_onchange_` script that
hashes it. A layer without one applied a manifest declaring bare containers, and worktrunk kept the
nested layout, with nothing to say so.

- **`overlay-doctor` checks it (Tier T)**, and a missing trigger, or one that exists but does not hash
  its input, gates. Every row is in `docs/reference/private-layer.md`, "Triggers".
- **ACTION** for a layer that ships `Devel/mani.yaml.tmpl` without
  `run_onchange_after_generate-worktrunk-config.sh.tmpl`: copy it from `overlay-skeleton/`, keep the
  `include` line for each input you ship, apply, and re-run `overlay-doctor`. Until then,
  `wt-config-gen` by hand.
- **Two mechanisms moved into the base as opt-in tools**, so a layer's trigger is a few lines:
  `install-claude-plugins` (declaring a plugin does not install it) and `install-test-gate` (a
  test-suite commit gate for the layer's own repository, which refuses to overwrite a pre-commit it
  did not write). Their triggers are in `overlay-skeleton/opt-in/`, which `scaffold-overlay` does not
  copy: some machines may not install plugins or run custom git hooks. The doctor requires the plugin
  trigger only where the fragment declares plugins, and only notes a layer test suite without a gate.

### Bringing a machine set up before these changes to the current shape — ACTION

For a machine whose containers, manifest or skill list predate 2026-10-07 (the changes of
2026-10-06 below and the two entries above). In order, after updating and applying the base:

1. `sh ~/.local/share/chezmoi/setup/overlay-doctor`, and fix what it gates. A layer that ships a
   manifest now needs the worktrunk trigger (entry above).
2. `fleet-decl --check`, then `fleet-repo check`, from `~/Devel`. For each finding, `fleet-repo clone
   <name>` repairs the container. That covers a default branch with no upstream (any container
   cloned before 2026-10-06 22:10, where `git pull` stops at "There is no tracking information"),
   refspecs that differ from the declaration, and missing worktrees. `check` never changes
   anything, and `clone` on an existing container never deletes a local branch or worktree.
3. Move each `clone:` line to `fleet-repo clone <name>`, and any `--filter=` on it into
   `container.filter`. For a repository with thousands of branches, declare `container.branches`
   (`default`, or a list) before cloning it, or set `containerDefaults.branches` for the domain.
4. `wt-config-gen`, then confirm a bare entry's `worktree-path` in `~/.config/worktrunk/config.toml`
   is `{{ repo_path }}/../{{ branch | sanitize }}`.
5. `bash ~/.local/share/chezmoi/tests/test-fleet-repo.sh` once on a Mac: `fleet-repo` has not yet run
   under the stock bash 3.2 that `/usr/bin/env bash` finds there.

## 2026-10-06

### `skill-externals-sync`: one clone per repository, and `--force`

- Entries that share a url and ref share one clone, so twenty skills from one repository's release
  are one fetch, not twenty.
- `--force` replaces what is already at a listed name that this tool did not install: a symlink is
  removed (its target untouched), a real directory is moved to the state directory's `displaced/`,
  never deleted. A name either chezmoi instance manages is refused even then. Use it once to adopt
  skills first installed by hand or by a symlink into a clone; later runs need no flag.

### `git-clone-worktree` fixes, now carried by `fleet-repo`

Found on a work machine's first bare clones; all in `fleet-repo` too, so a machine that moves its
`clone:` lines inherits them.

- `--mani-project` read only the scheme of any url with a colon (`https://`, `ssh://host:port`,
  `git@host:org/x`), failing with "repository 'https' does not exist".
- A `path:` naming the container instead of its default-branch worktree built the container in the
  parent; a populated non-container directory is now refused.
- `--help` printed `mkdir`'s help; it prints its own, and unknown options are refused.
- Many-branch repositories: the extra local branches are deleted in one transaction (8.9 s to 0.35 s
  at 3,000 branches), and a fresh clone is one transfer instead of a clone and a fetch.
- A container's default branch now tracks its remote, so `mani exec --all 'git pull --ff-only'`
  updates containers as well as plain clones. Before this, every container was skipped.
- `--filter=<spec>` for a partial clone; `container.filter` is the declared form now.

### Skill `fleet-manifest`, and the layout references corrected

A new skill for writing and checking `~/Devel/mani.yaml`: its two readers (`mani`, and the base's
tools through `fleet-decl`), why `mani describe` is not the effective configuration (it omits
`clone:`), adding a repository with a one-project proof, the rules that fail silently, and
`mani sync --parallel`. `docs/reference/repository-layouts.md`'s example had named the container in
`path:`; `path:` names `<container>/<default-branch>`. `sync: false` is documented as what it is:
`mani` never clones such an entry, not even by name, and treats it as ordinary once it exists.

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
