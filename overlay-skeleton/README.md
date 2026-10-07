# &lt;name&gt; overlay

Private overlay (a **second chezmoi instance**) for this domain/machine — it layers private,
non-publishable config on top of the public `dotfiles` base.

## What goes where (tiers)

- **A — generic mechanism** (e.g. `spell-capture`, the nvim spell tier): lives in the **public
  base** and arrives automatically on every `chezmoi apply`. Nothing to put here.
- **B — private-vocab** (identity `gitconfig`, `allowed_signers`, private `zshenv`, the private
  spell list): **you author these from THIS domain's own vault/records.** Fill in the `*.example`
  stubs (drop `.example`). Never copy another domain's values.
- **C — domain-specific** (`Brewfile.role`, `bootstrap.d/*`, `ssh/config`, `Devel/mani.yaml.tmpl`):
  this overlay writes its own. Fill in the stubs.

`dot_dotlocal/*` deploys to `~/.dotlocal/*` (the base's configs `Include`/read those paths).
`bootstrap.d/*.sh` run post-`chezmoi apply`, lexically, by the base's `bootstrap-mac.sh`.
`Brewfile.role` holds ONLY this domain's additions — the base Brewfile includes it (never
`instance_eval` the base from the role file; that inverted shape double-evaluates).

Every seam, with its format and an example: the base's `docs/reference/private-layer.md`. Optional
stubs: `dot_dotlocal/skill-externals.yaml` with `run_onchange_after_sync-skill-externals.sh.tmpl`
(skills installed from this domain's own repositories); delete both if the domain has none.

The `run_onchange_` scripts here re-run a base mechanism when an input this layer ships changes;
keep each one whose input you keep. `opt-in/` holds two more, a plugin installer and a commit gate
for this repository, which `scaffold-overlay` does not copy: adopt them by hand where the machine
allows it. Which trigger each input needs: the base's `docs/reference/private-layer.md`, "Triggers".

## Setting up

1. `setup/scaffold-overlay <dir>` copies these stubs (renaming `.example` off).
2. Fill in every stub; each required one carries a `FIXME(overlay-doctor)` line — delete it once real.
3. Run `setup/overlay-doctor` — it fails loudly until every required Tier-B/C piece is present and filled.
4. `git init`, add your (machine-local) overlay remote, and point `overlayRepo` at it during the base's `chezmoi init`.

## Optional: the leak-guard

The base wires `~/.local/bin/leak-guard` into every commit and push, and it passes everything until
this domain says what to keep out. It is deliberately not scaffolded: a placeholder pattern would
start refusing commits. To turn it on, add to the overlay's `dot_dotlocal/`:

- `git-leak-markers`: one extended regex on the first non-comment line. Identifiers that must stay
  in this domain's notes repository (its program ids, paths into that repository). Blocked in every
  repository except those the fleet record declares `leakPolicy: notes` or `internal`.
- `git-leak-sensitive`: one extended regex, matched case-insensitively. Terms that must not reach a
  public destination (hostnames, internal service names). Blocked except in `private` repositories
  and on pushes to a private destination.
- `git-leak-policy`: `private-url=<regex>` naming the push destinations that are private (anything
  else is public), and `probe-marker=<token>`, a token the markers match that `hook-doctor` plants
  to prove the guard is live.
- `git-leak-allow` (optional): one regex matched whole-line against `<path>:<added line>`, exempting
  a known generated line from the sensitive gate.

Then declare each repository's `leakPolicy` in the manifest, apply, and run `hook-doctor check`.
