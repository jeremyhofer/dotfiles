# CLAUDE.md — chezmoi dotfiles base (PUBLIC)

The **public** chezmoi source for the dotfiles base. Pushed to **public GitHub** and cloned on every
machine (home + work). **Treat everything here as world-readable.**

## Hard rules
- **PUBLIC — never leak private context.** Do not reference any private/personal decision records, internal
  docs, ticket or "ADR" numbers, or private repo paths/URLs in any file or commit message here. Comments must
  be **self-contained**: describe *what the thing does*, not *why per some external doc*.
- **Describe the generic pattern, never the private specifics.** The base+overlay architecture and generic
  `$HOME`/XDG paths (`~/.dotlocal/…`, `~/.config/…`) are fine to document here. NEVER put the security posture
  (key/secret tooling, how secrets are protected), the personal org layout (`~/REDACTED/…`, `~/REDACTED/…`), or the
  private overlay's internals in any file, comment, or commit message here — those live only in the private layer.
- **Edit the source, never the deployed copy.** Files here deploy to `~` via `chezmoi apply`; never edit the
  deployed `~/.config/...` / `~/.<file>` copies (apply overwrites them). Edit here, then `chezmoi apply`.
- **Source names are attribute-encoded:** `dot_` → leading `.`; `*.tmpl` → templated;
  `run_once_*`/`run_onchange_*`/`run_*` → scripts; `private_`/`executable_`/`encrypted_` → perms/encryption.

## Machine differences (home vs work)
- A **`domain`** template var = `personal` | `work` (set per machine in `~/.config/chezmoi/chezmoi.toml`,
  prompted at init). Branch with `{{ if eq .domain "personal" }}`.
- **Prefer `.chezmoiignore` (it is templated) over in-file domain conditionals** for "manage this only on some
  machines": add the file's **target name** under a `{{ if eq .domain "work" }}` block to exclude it on work.
  Get the target name with `chezmoi target-path <source>`.
- **OS/scope-varying content → `.chezmoitemplates/<topic>.<scope>` fragments**, composed from a thin orchestrator
  via `{{ includeTemplate "<topic>.<scope>" . }}` (pass `.` explicitly). Name by scope (`zprofile.linux`,
  `zshrc.darwin`) so `git diff` shows the scope in the **filename** — prefer this over inline
  `{{ if eq .chezmoi.os … }}` blocks, even for small diffs. (`chezmoi diff` shows *rendered* output for this
  machine; use `chezmoi git -- diff` / the source to see which scope a change lands in.)
- Non-deployable repo files (`README.md`, `CLAUDE.md`) are listed in `.chezmoiignore` so they are not deployed.

## The private overlay
Private/machine-local config lives in a **separate** chezmoi instance (the "overlay"), edited via a
`chezmoi-overlay` wrapper from a machine-local repo whose URL is **never committed here**. This base only
references overlay-deployed paths **generically** (e.g. `source ~/.dotlocal/zshrc`) — never the overlay's URL
or private content.

## Verify
`chezmoi diff` before `chezmoi apply` · `chezmoi target-path <source>` for a deploy path · `chezmoi ignored`
for per-machine exclusions.
