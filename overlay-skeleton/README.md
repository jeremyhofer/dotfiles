# &lt;name&gt; overlay

Private overlay (a **second chezmoi instance**) for this domain/machine — it layers private,
non-publishable config on top of the public `dotfiles` base.

## What goes where (tiers)

- **A — generic mechanism** (e.g. `spell-capture`, the nvim spell tier): lives in the **public
  base** and arrives automatically on every `chezmoi apply`. Nothing to put here.
- **B — private-vocab** (identity `gitconfig`, `allowed_signers`, private `zshenv`, the private
  spell list): **you author these from THIS domain's own vault/records.** Fill in the `*.example`
  stubs (drop `.example`). Never copy another domain's values.
- **C — domain-specific** (`Brewfile.role`, `bootstrap.d/*`, `ssh/config`): this overlay writes
  its own. Fill in the stubs.

`dot_dotlocal/*` deploys to `~/.dotlocal/*` (the base's configs `Include`/read those paths).
`bootstrap.d/*.sh` run post-`chezmoi apply`, lexically, by the base's `bootstrap-mac.sh`.
`Brewfile.role` `instance_eval`s the base Brewfile then adds domain apps.

## Setting up

1. `setup/scaffold-overlay <dir>` copies these stubs (renaming `.example` off).
2. Fill in every stub; each required one carries a `FIXME(overlay-doctor)` line — delete it once real.
3. Run `setup/overlay-doctor` — it fails loudly until every required Tier-B/C piece is present and filled.
4. `git init`, add your (machine-local) overlay remote, and point `overlayRepo` at it during the base's `chezmoi init`.

The publish-boundary leak-guard is a **home-only** component and is intentionally not scaffolded here.
