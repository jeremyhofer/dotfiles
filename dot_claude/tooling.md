# Tooling — public layer

Shipped by the dotfiles base; true on any machine it is installed on, including a
managed machine with no private overlay. Never names a private tool. (Rationale and the incident that
prompted the name table: this repo's README.)

**Binary names that differ from the project name.** `command -v <project-name>` is not the test.

| worktrunk → `wt` | ripgrep → `rg` | neovim → `nvim` | fd-find → `fd` |
| --- | --- | --- | --- |

**Installed by this repo:** `adr-lint` (a directory of decision records against the shape it
declares — reads both the bullet-header and frontmatter conventions and reports the split rather
than normalising it; `--strict` for a repo that has adopted a status vocabulary; `--subjects` renders a by-subject
view on demand) ·
`chezmoi-overlay` (runs the private second chezmoi instance) ·
`claude-scratch-hook` (Claude Code lifecycle hooks — SubagentStart/SubagentStop/Stop/SessionEnd —
that nudge an agent to tidy a session's scratch tree and delete it outright at session end; acts
only on a `CLAUDE_CODE_TMPDIR` that resolves to a `c-*` directory directly under `/tmp`) ·
`claude-mask-sweep` (stale Claude Code sandbox placeholder files, the ones `claude update` warns
about; `--remove` deletes those no running session has mounted; a terminal tool, refuses in a sandbox) ·
`claude-context-probe` (measures which instruction files, imports, hooks, skills and MCP servers Claude Code loads on this machine; skill `claude-context-probe`) ·
`memory-doctor` (health of Claude Code's auto-memory stores: index size against the silent-truncation cliff, stale project memories, orphans and dangling links; `usage` needs a read-log hook) ·
`context-footprint` (bytes of always-on context per component — CLAUDE.md files and their imports, memory index, skill and agent descriptions, plugins — against a token budget; reports, `--check` to gate) ·
`register` (read a work register — list, stats, show an entry with its initiative folder, what has gone quiet (`health`), the next free id, and render a browsable index on demand rather than committing one that can go stale; skill `register-standard`) ·
`lint-tasknames` (a repo's task names — just, npm, make, Nx — against the vocabulary in skill `naming-build-tasks`; `--fleet` for every repo the mani manifest declares) ·
`comment-lint` (fails a source comment that depends on context the file cannot carry) · `doc-lint` (its sibling for markdown prose: references a cold reader cannot resolve; per-repo `.doc-lint` config) ·
`context-lint` (a repository's `AGENTS.md`/`CLAUDE.md` against the context-file standard: sections, size caps counting imports; skill `project-context-file`) ·
`git-ai-coauthor` (prepare-commit-msg hook: adds a Claude co-author trailer, naming the session's model when it can, to commits made from a Claude Code session; wired in `~/.gitconfig`, per-repo opt-out `ai-coauthor.enabled false`) ·
`git-clone-worktree` (clone as bare + sibling worktrees; bootstraps the layout `wt` then manages,
since worktrunk has no clone verb) · `git-merge-diff` (diff a merge would introduce) ·
`git-secret-scan` (gitconfig pre-commit hook: gitleaks on staged changes, every repo) ·
`leak-guard` (gitconfig commit and push hooks: refuses the domain's private vocabulary, from its
`~/.dotlocal/git-leak-*` files, outside the repos the fleet record allows it in; passes everything
where the domain supplies none) · `run-repo-gates` (runs a manifest repo's tracked `.githooks/<event>`)
· `hook-doctor` (is the leak-guard live per worktree; `--path <dir>`) ·
`git-snapshot` (capture uncommitted work before a destructive command) · `kb` (markdown KB with
typed edges) · `nvim-healthdump` · `portability-lint` (fails GNU-only shell spellings) · `register-lint` (a work register's entries against the contract its README states) ·
`spell-capture` · `ui-shot` (headless render for visual review) ·
`skill-externals-sync` (installs the pinned skills a private layer lists in `~/.dotlocal/skill-externals.yaml`, by git; runs after every apply) ·
`fleet-decl` (reads one declaration from the per-repo record, a mani.yaml; exit 2 means the record is unreadable, never "not declared") ·
`wt-bootstrap` (installs a fresh worktree's dependencies from whichever lockfile it finds, frozen; wired in as worktrunk's `pre-start` hook) ·
`wt-config-gen` (generates worktrunk's user config from `base.toml`, an optional private fragment, and each repo's `worktrunk:` block in the manifest).

**Assumed third-party:** `chezmoi` (two instances) · `wt` (worktree lifecycle; `wt switch --create`
makes one) · `mani` (multi-repo sync/fan-out) · `just` · `git` with SSH-signed commits · `zsh` ·
`nvim` · `tmux` · `rg`.
