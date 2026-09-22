# Tooling — public layer

Shipped by the dotfiles base; true on any machine it is installed on, including a managed work
machine with no private overlay. Never names a private tool. (Rationale and the incident that
prompted the name table: this repo's README.)

**Binary names that differ from the project name.** `command -v <project-name>` is not the test.

| worktrunk → `wt` | ripgrep → `rg` | neovim → `nvim` | fd-find → `fd` |
| --- | --- | --- | --- |

**Installed by this repo:** `adr-lint` (a directory of decision records against the shape it
declares — reads both the bullet-header and frontmatter conventions and reports the split rather
than normalising it; `--strict` for a repo that has adopted a status vocabulary) ·
`chezmoi-overlay` (runs the private second chezmoi instance) ·
`comment-lint` (fails a source comment that depends on context the file cannot carry) ·
`git-clone-worktree` (clone as bare + sibling worktrees; bootstraps the layout `wt` then manages,
since worktrunk has no clone verb) · `git-merge-diff` (diff a merge would introduce) ·
`git-snapshot` (capture uncommitted work before a destructive command) · `kb` (markdown KB with
typed edges) · `nvim-healthdump` · `portability-lint` (fails GNU-only shell spellings) · `register-lint` (a work register's entries against the contract its README states) ·
`spell-capture` · `ui-shot` (headless render for visual review).

**Assumed third-party:** `chezmoi` (two instances) · `wt` (worktree lifecycle; `wt switch --create`
makes one) · `mani` (multi-repo sync/fan-out) · `just` · `git` with SSH-signed commits · `zsh` ·
`nvim` · `tmux` · `rg`.
