---
name: scratch-copies
description: Use before copying a repository, a build output, an installed dependency tree or any large directory into $TMPDIR or another scratch location — to compare two commits, reproduce something at an older commit, A/B a change (control vs treatment, red vs green), run a check against a clean tree, or keep a before-state. Also use when a task that made scratch copies is finishing, when handing results back to a parent agent, or when tests fail with "Disk quota exceeded", EDQUOT, errno 122, or browser crashes and module-fetch failures that look like code bugs. Covers comparing by commit with a git worktree instead of a copy, copying only the paths a check reads, why sparse worktrees fail inside the Claude Code sandbox, and deleting every copy when its result is recorded.
---

# Scratch copies: make them small, delete them when done

## The rule

1. **Copy only what the check will read.** A test run against `src/` and `tests/` does not need the
   repository's docs, frontend or data directories.
2. **Get an old commit with git, never with `cp -r` plus `git init`.** A git worktree shares the
   repository's history instead of duplicating it, and `git archive` extracts just the paths you
   name.
3. **Delete every copy once its result is recorded**, and before handing back to a parent agent.
   Anything over about 50 MB, say up front when it will be deleted. When handing back, list what you
   kept and why.


## When a copy is too big for `/tmp`

`/tmp` is a RAM tmpfs with a per-user quota. A scratch copy that needs gigabytes (a whole scratch
application with its dependencies, a copy of another repository) goes on disk instead, in the one
sanctioned place:

```sh
big="$HOME/.cache/agent-scratch/$(basename "${CLAUDE_CODE_TMPDIR:-c-adhoc-$$}")"
mkdir -p "$big"
```

- **Name it for the session's `/tmp` root** (`$CLAUDE_CODE_TMPDIR`, a `c-*` directory, when a launcher
  set one): `claude-scratch-hook` removes exactly that folder when the session ends.
- **Delete it yourself when the result is recorded.** Deleting under `~/.cache/agent-scratch/` is
  allowed where a guard restricts `rm`; the rest of `~/.cache` is not scratch and stays protected.
- **Never put it anywhere else under `~/.cache`**: nothing cleans an arbitrary folder there, and an
  agent may not be allowed to delete it, so the cleanup lands on a person.
- On Linux, anything left is aged out after three days without a write; on macOS only the session-end
  removal and your own deletion clean it.

## Why this matters more than it looks

**`$TMPDIR` is shared.** The Claude Code sandbox points every session a user runs, and every
subagent, at the same per-user temp directory. On many Linux machines `/tmp` is a RAM filesystem
with a per-user quota. When the quota fills, the failure does not say "disk full": it arrives as
`Disk quota exceeded` (`EDQUOT`, errno 122), or as symptoms that look like code defects — browser
tests crashing, "Failed to fetch dynamically imported module", database "disk I/O error". `df` can
show plenty of free space while one user is at the quota.

**Nobody else cleans it up in time.** System cleanup typically ages `/tmp` over days, and on a laptop
its timer can pause while the machine sleeps. Parallel agents can fill a quota within a single day.
One measured machine held 9.2 GB of leftovers against a 12 GB quota with nothing running. About
5 GB of it was agents' experiment copies, and none had ever been deleted.

**On disk it costs twice.** A copy made under a snapshotted home directory and then deleted stays
pinned by every snapshot taken while it existed.

## Recipes

The worktree, `git archive`, manifest and prune recipes were run and checked; the pnpm row is
from pnpm's documented design, not measured here. Put each task's scratch in one directory so a single delete
removes it: `work="$TMPDIR/<task-name>"`.

| You need | Do | Cost |
| --- | --- | --- |
| A full checkout of another commit, with git available in it | `git worktree add --detach "$work/wt" <commit>` | The checked-out files only; history is shared |
| Only some paths at a commit (run a linter or tests on `src/`) | `mkdir -p "$work/tree" && git archive <commit> <path>... \| tar -x -C "$work/tree"` | Only the named paths; no git metadata |
| To compare two build outputs file by file | Build one arm, record a manifest (`find dist -type f -exec sha256sum {} + \| sort -k2 > "$work/a.sha"`), delete the build, build the other arm, diff the manifests | Two small text files instead of two builds |
| A tool that needs the complete artifact (a performance audit crawling a whole site, a package installed for real) | Keep the full copy, but one arm at a time where possible. Record the result, delete, then build the next | The honest cost of the proof, once |
| Two real installs of dependencies | Let both use the package manager's shared cache. pnpm's content-addressed store links files into each install, so a second one costs little | Mostly shared |

**Where a scratch worktree lives:** inside the task's scratch directory (`$work`, under
`$TMPDIR`), never beside the repository's own worktrees. A scratch worktree next to real ones looks
like live work, and removing it runs into the rule below.

**Do not commit throwaway state just so a plain remove succeeds.** In a repository that requires
signed commits, that is a signed commit for every experiment. Skipping hooks or signing to make it
cheap is not acceptable either.

**Removing a worktree:** `git worktree remove "$work/wt"`. Git refuses without `--force` when the
worktree holds untracked files, such as build output, and permission rules often deny `--force`,
because on a real worktree it destroys uncommitted work. For a scratch worktree, delete the directory
(`rm -rf "$work"`) and then run `git worktree prune` in the repository. Deleting without pruning
leaves a stale entry, shown as `prunable` in `git worktree list`, until a prune runs. That was
measured, and `prune` was checked to work inside the Claude Code sandbox.

**Sparse worktrees fail inside the Claude Code sandbox.** `git sparse-checkout set` in a linked
worktree must write `extensions.worktreeConfig` into the main repository's `.git/config`. The
sandbox blocks writes to that file (a `/dev/null` stand-in at `.git/config.lock`), so the command
fails with `could not lock config file`. For a subset of paths, use `git archive` instead. Outside
the sandbox it works, but it still changes the shared repository config, which is worth avoiding.

## Finishing a task

- `rm -rf "$work"` once the numbers, diffs or logs you needed are written down somewhere durable.
  If it held a worktree, run `git worktree prune` in the repository afterwards.
- If a parent agent may need to re-check your result, keep only the smallest thing that lets it do
  so (a manifest, a log, a report), say where it is, and say who deletes it.
- Check your footprint before handing back: `du -sh "$work"`.
