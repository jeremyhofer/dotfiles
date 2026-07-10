# Setting up (adopting) a machine with these dotfiles

This directory holds the setup tooling and this guide. Use it to bring a **new machine** — or a machine that
**already has config** (from GNU stow, hand-placed files, or a managed/IT install) — safely into this dotfiles
setup, without silently overwriting what's already there.

It's written to be reusable and to give a Claude session enough context to help drive the process.

## How the layers work

- **Base** (this repo) — public, generic config shared across every machine and domain.
- **Overlay** (optional, per-domain) — a *second, private* chezmoi instance holding machine/domain-specific and
  private config. Domains are `personal` and `work`; each domain has its own overlay repo (**your private overlay
  remote**). The overlay deploys on top of the base, so its files win where the two overlap.

The golden rule everywhere: **edit the chezmoi source, then apply — never edit the deployed `~/…` copy** (apply
overwrites it).

## The tools

| Tool | What it does |
|------|--------------|
| `../bootstrap-mac.sh` | macOS entry point: foundation → `brew bundle` → default Node → **guarded apply** → overlay bootstrap stages. Re-runnable. |
| `setup/scaffold-overlay <dir>` | Create a brand-new overlay source skeleton (self-documented) to fill in. |
| `setup/adopt-audit` | **Pre-apply safety check**: for every path an apply would write, flags any *differing* file already deployed there that isn't yet captured in source (base or overlay). Non-zero exit = capture those first. |
| `setup/chezmoi-safe-apply` | **Guarded apply**: runs `adopt-audit` as a gate, backs up every would-change file, shows the diff, asks to confirm, then applies base then overlay. |
| `setup/brew-inventory` | Snapshot installed Homebrew formulae/casks (to seed a Brewfile). |

`bootstrap-mac.sh` calls `chezmoi-safe-apply` for you; you can also run the `setup/` scripts directly from this
checkout **before** anything is applied (they're plain scripts here on purpose).

## Prerequisites (foundation) — domain-gated

`bootstrap-mac.sh`'s foundation step reads `domain` from `~/.config/chezmoi/chezmoi.toml`:

- **`personal`** — auto-installs Xcode Command Line Tools and Homebrew via the standard public methods.
- **`work`** — does **not** install them. If missing, it stops and tells you to install CLT + Homebrew **via the
  managed/bespoke method for that machine**, then re-run. (Managed machines install these their own way; bootstrap
  only verifies they're present.)

## The ordered flow

Run `bootstrap-mac.sh`; it does step 1, then the guarded apply's gate stops it until the overlay is ready — do
steps 2–3, then re-run and it proceeds. Steps 2–3 need your judgment (and are where a Claude session helps).

1. **Foundation** — `sh bootstrap-mac.sh` (installs/verifies CLT + Homebrew per domain, runs `brew bundle`, sets a
   default Node). No `$HOME` config is touched yet.
2. **Scaffold the overlay** *(only if this domain has no overlay yet)* —
   `sh setup/scaffold-overlay ~/.local/share/chezmoi-overlay`, then fill in the skeleton, `git init` it, add
   **your private overlay remote**, and write its chezmoi config (with the right `domain`). *(If the overlay
   already exists — e.g. cloned from your remote — skip this and just ensure it's present.)*
3. **Populate the overlay** — capture each piece of pre-existing, machine/domain-specific or private config into
   the overlay source (generic, shareable config belongs in the base instead — but that's upstream, changed rarely).
   Use `chezmoi --source ~/.local/share/chezmoi-overlay … add <path>` (or your overlay wrapper) to capture a
   deployed file's **content** into the overlay. Template or domain-gate anything that differs per machine/domain.
   Run `setup/adopt-audit` as you go to see what's still uncaptured.
4. **Audit** — `sh setup/adopt-audit`. It must pass (nothing uncaptured) before the apply. This is also the gate
   inside step 5, so a clean audit here means the apply won't stop.
5. **Guarded apply** — re-run `sh bootstrap-mac.sh` (or `sh setup/chezmoi-safe-apply` directly). It: gates on
   `adopt-audit`, **backs up** every file it will change to `~/.bootstrap-backups/<timestamp>/`, shows the diff,
   asks to confirm, then applies the base and then the overlay.
6. **Verify** — open a fresh shell; confirm the expected config is in place and overlay overrides landed where you
   expect. Spot-check the things you migrated.
7. **Cleanup** — once verified, decommission the old setup (e.g. remove the stow symlinks / retire `~/.dotfiles`),
   and prune the backup dir. Do this **last** — never before the apply is verified.

## Safety guarantees

- **Nothing uncaptured is silently lost.** The guarded apply hard-stops if a file it would overwrite isn't already
  captured in source, and backs up everything it does change before changing it.
- **You always see the change first.** The diff + confirm step means no surprise overwrites.
- **It's re-runnable.** Every tool here is idempotent; re-running after fixing what the gate flagged just continues.

## Notes for a Claude session helping with this

- Work through the steps **in order**; the human decides, for each pre-existing config, whether it belongs in the
  base (generic) or the overlay (machine/domain-specific or private), and how it's templated/gated.
- Never bypass the `adopt-audit` gate to force an apply — capturing the flagged files first is the whole point.
- Keep everything you write to the **base** publish-safe: no private hosts, keys, stores, remote URLs, employer or
  machine names. Machine/domain-specific and private content goes in the **overlay**, not here.
