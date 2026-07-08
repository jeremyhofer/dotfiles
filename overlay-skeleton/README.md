# &lt;name&gt; overlay

Private overlay (a **second chezmoi instance**) for this domain/machine. It layers private,
non-publishable config on top of the public `dotfiles` base.

- **Deploys** `dot_dotlocal/*` → `~/.dotlocal/*` (the public base's configs `Include`/read those paths).
- **`dot_dotlocal/bootstrap.d/*.sh`** run **post-chezmoi**, in lexical order, by the base's `bootstrap-mac.sh`.
- **`dot_dotlocal/Brewfile.role`** is the domain's Brewfile — it `instance_eval`s the base Brewfile then adds
  role apps; `bootstrap-mac.sh` runs `brew bundle` against it.

See the notes repo: `repo-topology.md` + `specs/2026-07-08-reusable-mac-setup-core-design.md`.

Fill in the `*.example` files (rename by dropping `.example`), then `git init`, add your remote, and point
`overlayRepo` at it during the base's `chezmoi init`.
