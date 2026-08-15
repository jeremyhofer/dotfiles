# dotfiles

Jeremy Hofer's personal dotfiles, managed with [chezmoi](https://www.chezmoi.io).

This repository is the **public base layer** — generic, machine-agnostic configuration only.
It contains **no secrets and no machine-specific URLs**; private and per-domain config is
layered on at apply time (see *Architecture*).

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
