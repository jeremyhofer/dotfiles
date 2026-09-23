# Tooling — public layer

Shipped by the dotfiles base; true on any machine it is installed on, including a managed work
machine with no private overlay. Never names a private tool. (Rationale and the incident that
prompted the name table: this repo's README.)

**Binary names that differ from the project name.** `command -v <project-name>` is not the test.

| worktrunk → `wt` | ripgrep → `rg` | neovim → `nvim` | fd-find → `fd` |
| --- | --- | --- | --- |

**Installed by this repo:** `adr-lint` (a directory of decision records against the shape it
declares — reads both the bullet-header and frontmatter conventions and reports the split rather
than normalising it; `--strict` for a repo that has adopted a status vocabulary; `--subjects` renders a by-subject
view on demand) ·
`chezmoi-overlay` (runs the private second chezmoi instance) ·
`register` (read a work register — list, stats, show, the next free id, and render a browsable index on demand rather than committing one that can go stale) ·
`comment-lint` (fails a source comment that depends on context the file cannot carry) ·
`git-clone-worktree` (clone as bare + sibling worktrees; bootstraps the layout `wt` then manages,
since worktrunk has no clone verb) · `git-merge-diff` (diff a merge would introduce) ·
`git-snapshot` (capture uncommitted work before a destructive command) · `kb` (markdown KB with
typed edges) · `nvim-healthdump` · `portability-lint` (fails GNU-only shell spellings) · `register-lint` (a work register's entries against the contract its README states) ·
`spell-capture` · `ui-shot` (headless render for visual review) ·
`fleet-decl` (reads one declaration from the per-repo record, a mani.yaml; exit 2 means the record is unreadable, never "not declared") ·
`wt-bootstrap` (installs a fresh worktree's dependencies from whichever lockfile it finds, frozen; wired in as worktrunk's `pre-start` hook) ·
`wt-config-gen` (generates worktrunk's user config from `base.toml`, an optional private fragment, and each repo's `worktrunk:` block in the manifest).

**Assumed third-party:** `chezmoi` (two instances) · `wt` (worktree lifecycle; `wt switch --create`
makes one) · `mani` (multi-repo sync/fan-out) · `just` · `git` with SSH-signed commits · `zsh` ·
`nvim` · `tmux` · `rg`.
