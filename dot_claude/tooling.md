# Tooling — public layer

Shipped by the dotfiles base; true on any machine it is installed on, including a managed machine
with no private overlay. Never names a private tool. One line per tool: what it is for. **Before
using one, read its `--help`**, or the full entry in `~/.claude/tooling-reference.md` (flags, exit
codes, state files, caveats). This file is short on purpose: every session loads it on every request.

**Binary names that differ from the project name.** `command -v <project-name>` is not the test.

| worktrunk → `wt` | ripgrep → `rg` | neovim → `nvim` | fd-find → `fd` |
| --- | --- | --- | --- |

**Installed by this repo.**

- Docs and repos: `adr-lint` (decision records against their declared shape) · `doc-lint` (markdown
  references a cold reader cannot resolve) · `comment-lint` (source comments needing outside
  context) · `prose-lint` (a repo's mechanical voice rules) · `us-spelling-lint` (commit gate on new
  British spellings) · `context-lint` (`AGENTS.md`/`CLAUDE.md` against the standard) ·
  `portability-lint` (GNU-only shell spellings) · `lint-tasknames` (task names against skill
  `naming-build-tasks`) · `register` (read a work register; skill `register-standard`) ·
  `register-lint` (a register against its README's contract) · `kb` (markdown knowledge base with
  typed edges; `kb project` writes a domain's projection).
- Git: `land` (the landing gate: `land check`, then `land` moves the integration branch) ·
  `git-branch-gone` (delete a merged, or superseded via `--into`, branch from every remote) ·
  `git-secret-scan` (gitleaks on staged changes) · `leak-guard` (refuses a domain's private
  vocabulary outside its allowed repos) · `run-repo-gates` (a repo's tracked `.githooks/<event>`) ·
  `git-staged-run` (run a command against what is staged) · `hook-doctor` (is leak-guard live per
  worktree) · `hook-launcher` (runs a basic Python tool from a git hook on a Python that starts) ·
  `git-ai-coauthor` (adds the Claude co-author trailer) · `git-snapshot` (capture uncommitted work
  before a destructive command) · `git-merge-diff` (the diff a merge would introduce) ·
  `git-clone-worktree` (old name for `fleet-repo clone`).
- Worktrees and repos: `fleet-repo` (make a repo on disk match its manifest entry) · `fleet-decl`
  (read one declaration from the manifest; exit 2 = unreadable) · `mise-fleet-trust` (trust the
  mise configurations the manifest opts in; writes mise's miserc) · `wt-bootstrap` (a fresh
  worktree's frozen install) · `wt-fetch-base` (a new worktree starts from a fetched base) ·
  `wt-config-gen` (worktrunk's user config).
- The fleet: `fleet-canonicals` (the long-running named sessions: status, up/down, refresh,
  handoffs, the request queue; skill `canonical-takeover`) · `fleet-canonicals-queue` (behind
  `fleet-canonicals request`) · `fleet-slot` (the timing slot for heavy work) · `fleet-wait` (a
  coordinating session's heartbeat, at most 55m) · `machine-snapshot` (what is loading the machine)
  · `apply-status` (the dotfiles apply ledger; `wait --since T`) · `launchagent-status` (macOS:
  deployed agents not loaded) · `chezmoi-overlay` (runs the private chezmoi instance).
- Claude Code: `claude-usage-report` (where tokens went; `--sessions` per session) ·
  `claude-usage-override` (one temporary override of usage throttles) · `context-footprint` (bytes
  of always-on context against a budget) · `memory-doctor` (auto-memory store health) ·
  `claude-context-probe` (what Claude Code loads) · `claude-project-settings` (writes declared repo
  and directory settings) · `claude-trust-check` (unaccepted workspace-trust prompts) ·
  `claude-mask-sweep` (stale sandbox placeholder files) · `install-claude-plugins` ·
  `claude-dispatch-hook` (refuses a dispatch naming no model, or Fable without its opt-in) ·
  `claude-worklog-hook` (dispatch and work-note log) · `claude-worktree-hook` (worktree command
  guard) · `claude-scratch-hook` (scratch-tree tidying) · `skill-externals-sync` (pinned external
  skills).
- Alerts and services: `ntfy-inbox` (local copy of ntfy alerts) · `alert-digest` (new alerts since a
  reader last looked) · `hc-status` (Healthchecks.io states) · `bing-webmaster` (Bing search
  statistics) · `image-bump` (personal domain: move a digest-pinned image behind a scan gate).
- Build and test: `loop-time` (time a project's iteration loops reproducibly) · `seam-probe` (declared suites measuring tool and harness behavior no unit test reaches) · `verify-task-io`
  (does each cached Nx target declare its files) · `install-test-gate` (a test-suite commit gate) ·
  `ui-shot` (headless render for visual review) · `sops-key-loader` (Linux: the machine's SOPS age
  key file, once per login) · `nvim-healthdump` · `spell-capture`.

**Assumed third-party:** `chezmoi` (two instances) · `wt` (worktree lifecycle; `wt switch --create`
makes one) · `mani` (multi-repo sync/fan-out) · `just` · `git` with SSH-signed commits · `zsh` ·
`nvim` · `tmux` · `rg`.
