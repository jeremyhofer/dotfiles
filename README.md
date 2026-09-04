# dotfiles

Jeremy Hofer's personal dotfiles, managed with [chezmoi](https://www.chezmoi.io).

This repository is the **public base layer** — generic, machine-agnostic configuration only.
It contains **no secrets and no machine-specific URLs**; private and per-domain config is
layered on at apply time (see *Architecture*).

## What is in here

This is the public base of a two-layer chezmoi setup, along with the command-line tools, agent
skills and tests behind a governed fleet of AI coding agents.

### Command-line tools

Installed to `~/.local/bin`.

- `chezmoi-overlay` runs a second, independent chezmoi instance for private configuration, with its
  own config, state and cache. Both instances target the same home directory, so their managed file
  sets have to stay disjoint.
- `git-clone-worktree` clones a repository as a bare repo with worktrees as sibling directories, so
  several branches can be checked out at the same time.
- `git-merge-diff` shows the diff a merge would introduce, computed from the merge base rather than
  from the branch tips. Commits that landed on the base branch since you forked do not show up as
  part of your change.
- `git-snapshot` captures uncommitted work before a command that would discard it. `git checkout`,
  `git restore`, `git reset --hard` and `git clean -fd` all discard silently and exit 0, so there is
  no error to notice and nothing left to recover from.
- `kb` is a CLI for a markdown knowledge base whose records carry typed relationship edges. It
  scaffolds records, lints them for dangling and orphaned links, and regenerates the derived indexes,
  so a stale index cannot be committed alongside a changed record.
- `nvim-healthdump` captures a Neovim health and plugin inventory report for comparing two machines.
  It runs Neovim headless, so it works over SSH on a machine with no display.
- `portability-lint` fails a commit that contains GNU-only shell spellings. Those spellings work on
  Linux and break on macOS, so without this the failure appears only on the other machine, usually
  long after the change was written.
- `spell-capture` re-imports a Neovim spell wordlist back into the private source layer, so applying
  configuration later does not clobber a word that was added interactively.
- `ui-shot` renders a page headless and captures it for visual review, including cropping to a region
  at native scale. A full-page screenshot is scaled down, which is enough to hide a one-pixel border.

### Agent skills

Installed to `~/.claude/skills`. An agent skill is an on-demand procedure document that a coding
agent loads by name when its trigger applies, rather than something kept in context all the time.

- `brew-and-brewfiles` covers installing and removing software on a Homebrew-managed Mac, which
  Brewfile layer an entry belongs in, and the failure signatures where a declared package silently
  did not install.
- `dotfiles-layout-and-bootstrap` covers the two-instance model, deciding which layer a file belongs
  in, and the rule that you edit the source and apply rather than editing the deployed file.
- `dotfiles-update` covers pulling and applying an update, catching up a machine that has been
  dormant, and why one layer can be left behind by an update to the other.
- `mani-and-worktrunk` covers working across several repositories at once and managing git worktrees
  for parallel branches.
- `overlay-doctor` covers setting up and auditing the private layer, and what to provision for each
  finding the checker reports.
- `tuicr-code-review` covers driving a local code review and, more often, picking up a review a human
  already made so the comments can be acted on.
- `visual-review` covers verifying a UI change before claiming it looks right, and why a screenshot
  has to be cropped at native scale to show what changed.
- `writing-zsh-commands` covers the ways zsh differs from bash. The differences fail silently and
  return an empty result or a false success rather than an error, so they are read before writing a
  shell command rather than after one misbehaves.

### Tests

Run them with `sh tests/run-all.sh`, optionally with a filter argument to run one suite.

There are 22 test scripts plus the runner. They cover each of the tools above and each subcommand of
`kb`, and they run as a pre-commit gate in this repository.

## Layout
- Managed files use chezmoi source-state naming — e.g. `dot_zshrc.tmpl` → `~/.zshrc`,
  `dot_config/i3/config` → `~/.config/i3/config`.
- **OS differences** are handled generically via `.chezmoi.os` templating (Linux / macOS),
  not per-OS forks. **Per-machine** values (e.g. display DPI) come from machine-local chezmoi data.
- Third-party, non-package content (oh-my-zsh, tmux TPM, …) is fetched via `.chezmoiexternal`.

## Architecture (base + overlay)
- **This repo (base):** public, generic config + OS templates + the external/ignore manifests.
- **Private overlay:** per-domain (personal / work) config, held in a **second, independent chezmoi
  instance** with its own source, config, state and cache. It targets the same `$HOME`, so the two
  instances' managed file sets must stay **disjoint** — the base owns public files, the overlay owns
  private ones plus the `~/.dotlocal/*` fragments that public files include (`source ~/.dotlocal/zshrc`,
  ssh `Include`, …). The overlay's location lives only in machine-local chezmoi config and never
  appears in this repo. Run it with the `chezmoi-overlay` wrapper; plain `chezmoi` is the base only.
- **System/package layer:** packages — and chezmoi itself — are installed by the system layer
  (konfigkoll on Arch, Homebrew Bundle on macOS), not by chezmoi. This repo is dotfiles only.

## Bootstrap a machine
```sh
chezmoi init --apply <this-repo>
```
chezmoi renders the machine config (prompting for domain + the overlay repo, if any), fetches the
externals, applies the dotfiles, and then a `run_once` script clones and applies the overlay — or
skips silently on a machine that has none.

**Adopting a machine that already has config** (stow, hand-placed, or a managed install) has its own
guarded flow — audit what would be overwritten, back it up, diff, confirm. See
[`setup/README.md`](setup/README.md); start there rather than applying straight onto existing files.
