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
- **Private overlay:** per-domain (personal / work) config cloned to `~/.dotlocal` via
  `.chezmoiexternal`; the base sources it through a single domain-neutral indirection. The
  overlay's location lives only in machine-local chezmoi config and never appears in this repo.
- **System/package layer:** packages — and chezmoi itself — are installed by the system layer
  (konfigkoll on Arch, Homebrew Bundle on macOS), not by chezmoi. This repo is dotfiles only.

## Bootstrap a machine
```sh
chezmoi init --apply <this-repo>
```
chezmoi renders the machine config (prompting for domain + overlay), clones the overlay and
externals, then applies the dotfiles.
