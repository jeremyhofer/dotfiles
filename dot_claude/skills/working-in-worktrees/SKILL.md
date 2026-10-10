---
name: working-in-worktrees
description: Use when deciding whether to work in a git worktree, and whenever creating, entering, landing, cleaning up or removing one — `wt switch --create`, `git worktree add`, the EnterWorktree or ExitWorktree tools, giving a subagent `isolation: worktree`, merging, cherry-picking or opening a pull request for a finished branch, deleting it on the remotes, or a worktree left behind. Also fires on the failure signatures — "is already used by worktree", "contains modified or untracked files", "Read-only file system" after leaving a worktree, a new worktree that starts weeks behind, tests that pass in one worktree and fail in another, a port already in use by another worktree, a cherry-picked branch that still reads as unmerged, a hook refusing a raw `git worktree` command, and EnterWorktree refused where sessions work in place. Covers when a worktree is warranted, one per stream of work, a named fresh base, a frozen install before any gate, landing into the branch it was cut from, by a local merge or a pull request as the repository, the domain or the host of `origin` decides, removing only what is provably elsewhere, and how this differs inside a sandboxed Claude Code session from a plain shell with no hooks.
---

# Working in worktrees

A git *worktree* is a second working directory attached to the same repository, with its own branch
checked out. Several branches can then be open at once without stashing, and two writers (an agent
and a person, or two agents) do not edit the same files under each other. This skill is the
procedure for the whole life of one: whether to make it, making it, working in it, landing it and
removing it.

**Every worktree operation goes through worktrunk (`wt`)**: `wt switch --create` to create,
`wt switch` to move between them, `wt remove` to remove. Worktrunk places a worktree where the
repository's layout says, runs the creation hooks (among them, where enabled, the fetch of the base),
and removes without force. Read state with `wt list`, or `git worktree list` where a tool needs its
porcelain output. Where this setup's Claude Code hooks are installed, a session's raw
`git worktree add` or `move` is refused with the `wt` command to use instead, and a raw
`git worktree remove` is let through with a warning naming the standard form (Removing it, step 4). Tooling that
manages worktrees itself (a clone tool, a CI runner) keeps calling git directly.

**`wt` is a shell function as well as a binary, and only the function can change directory.** A
program cannot move its parent shell, so `wt switch` is a function the shell rc defines around the
binary. A non-interactive shell (a script, a CI step, `ssh host '…'`) does not read the rc, so there
`wt` is `command not found`, or the binary runs and leaves you where you were. In those contexts call
`command wt … --no-cd` and `cd` to the path yourself; `command wt list` prints each worktree's path.

**Read this domain's half too:** `~/.dotlocal/skills/working-in-worktrees.md`, if it exists, lists
each repository's layout, landing branch, install steps and ports.

## Two layouts

A repository is in one of two shapes, and four steps below depend on which. **The standard clone is
the default**; the bare container is an older layout that the tooling still supports.

| | Standard clone (default) | Bare container (older) |
| --- | --- | --- |
| On disk | `<repo>/` is an ordinary checkout on the repository's working branch; worktrees nest at `<repo>/.worktrees/<name>` | `<repo>/.git/` is itself a bare repository, and every branch, the default one included, is a sibling worktree: `<repo>/main/`, `<repo>/<branch>/`. (A container made before the rename keeps the git data in `<repo>/.bare` behind a `.git` file saying `gitdir: ./.bare`; `fleet-repo check` reports it as `old-layout` and prints the conversion.) |
| How to tell | `git rev-parse --is-bare-repository` prints `false` at `<repo>/`, and `.git` holds a checkout's index | `git rev-parse --is-bare-repository` prints `true` at `<repo>/`, which has no working tree of its own |
| Where you stand to create, land and remove | the main checkout, `<repo>/` | the default branch's worktree, `<repo>/main/`. Never `<repo>/` itself: it has no working tree, so `git status` fails there and gates skip it |
| Reach another branch | `git -C <repo>/.worktrees/<branch>`, or from inside one, `git -C ../..` for the main checkout | `git -C ../<branch>` from any sibling |
| Its cost | the worktrees live inside a working tree: `.worktrees/` is listed in the repository's own `.gitignore`, and tools that walk the tree (formatters, linters, `rg`, build graphs) each need it excluded, or they scan every worktree too. The checkout is load-bearing: every nested worktree's git data lives in its `.git`, so deleting or re-cloning it takes them all, unpushed branches included | every sibling sits at the container root, outside the default branch's directory, so a sandboxed session creates one with the EnterWorktree tool rather than from Bash (below); build tools that keep data at the main worktree's root put it at the container root, which a session cannot write |
| Why it is used | IDEs, build tools and worktrunk handle it natively, and a sandboxed session and its subagents can write the checkout, the nested worktrees and the shared `.git` with no extra grant | removing any one directory, `main/` included, cannot break the others, and no branch is privileged |

`wt switch --create` places a worktree correctly in either shape once the repository's layout is
configured. `fleet-repo clone` clones a repository in the shape its manifest entry declares.

## Who works where

Where one long-running session owns a repository, and subagents or a person work beside it:

- **The owning session works in the checkout itself.** It does not move into a worktree to do its own
  work.
- **Parallel work goes to subagents in their own worktrees**, each launched with
  `isolation: "worktree"`.
- **The owning session never calls EnterWorktree.** A session and its subagents share one write set,
  the directory the session stands in plus the repository's `.git`; entering a worktree takes the
  checkout out of it, for the subagents too. To work on another branch it uses that branch's
  worktree **by path**, staying where it is: `git -C .worktrees/<name> …`, `(cd .worktrees/<name> && …)` in a
  subshell (a bare `cd`, even inside one command, moves the session's own directory), and edits to files under `.worktrees/<name>/`, all of which its write set
  covers in a standard clone. Or it hands the work to a subagent. Such a repository sets
  `worktree.bgIsolation: "none"` (in its settings or the user's), and where this setup's hooks are
  installed, EnterWorktree is refused wherever that is the effective value.
- **It pushes before it dispatches.** A subagent's worktree starts from the base as fetched from the
  remote, so commits only in the checkout are not in it. A hook warns at dispatch when the checkout
  has commits on no remote.
- **A person works in `.worktrees/` through `wt switch`**, never in a checkout a session owns.

## Do you need one?

Work in a worktree when **either** holds:

- **More than one writer may touch the checkout at once**: parallel agents, fanned-out subagents, or
  a person editing it while you work.
- **Landing has an outside consequence**: the branch must be reviewed, gated or released before it
  reaches the shared branch.

Otherwise work in the checkout directly. Whether the session is in the background or interactive is
not the test.

**One worktree per stream of work, not one per change.** A stream is one tracked item or one thing
asked for. Land from it as often as the work needs and remove it once, when the stream is finished.
Many short-lived worktrees for one stream each leave a removal behind, and removal is often a
person's job (below). A stream that never ends, such as a daily log, keeps one standing worktree, and
says so.

**Reading or comparing code is not a stream.** Review a branch with `git diff <base>...<branch>`,
`git log -p` or `git show`, not by staging its diff onto a detached checkout. A worktree made only
to run or compare an older commit holds no edits and is removed in the sitting that made it.

## Creating one

1. **Start from where the layout says** (the table above): the main checkout of a standard clone, or
   the default branch's worktree of a bare container. Never from inside another worktree, from a
   subdirectory, or from a bare container's root. A session that leaves a worktree returns to
   where it entered from, and if that place is gone or read-only, the next step fails.
2. **The base must be freshly fetched.** `wt switch --create` on its own branches from the LOCAL
   base and never fetches, and a push through a multi-URL remote does not update the other remotes'
   tracking refs, so an unfetched base can be weeks old. Where `wt-fetch-base` is enabled
   (`git config fetch-base.enabled true`), creation fetches the base from `origin`, falls back to the
   remotes named by `git config fetch-base.fallback`, starts the new branch at the fetched commit,
   and refuses to create anything when no remote can be reached. Elsewhere, fetch first:
   `git fetch --all`.
3. **Create it from a named base.**

   *A subagent* gets one by being launched with `isolation: "worktree"`, and *a sandboxed session in
   a repository that isolates sessions* with the EnterWorktree tool, by name. Where worktrunk's Claude Code plugin is installed, both go
   through its WorktreeCreate hook, which runs `wt switch --create` outside the sandbox, so the
   layout, the fetch and the creation hooks all apply. Without the plugin, Claude Code makes a plain
   git worktree under `.claude/worktrees/` that skips all three.

   *A person, a script, or a session in a standard clone* uses:

   ```sh
   wt switch --create <branch> --base <base> --no-cd -y --format=json
   ```

   The JSON names the new path. `--no-cd` keeps your shell where it is, which is what a script or an
   agent wants; `-y` skips approval prompts. Worktrunk puts the worktree where the repository's
   layout says (nested under `.worktrees/` in a standard clone, beside the branches in a bare
   container) and runs the repository's creation hooks.
4. **Check the base you got**: `git -C <path> log -1 --format='%h %s'` names the commit you expect.
5. **Install before any gate.** Run the repository's frozen install in the new worktree (`npm ci`,
   `uv sync`, and so on, once per package root). Without it, Node resolves the parent directory's
   `node_modules`, gates silently test the wrong dependencies, and dependency work can corrupt the
   other checkout. A worktree also has no build output and no gitignored local files; anything a
   gate expects there has to be built or copied first.

## Working in one

- **Run every gate inside the worktree**, never two at once in the same one: they share build output
  and collide.
- **Use the worktree's own ports.** A repository that derives ports from the checkout's path gives
  each worktree its own; a fixed port means a server from another worktree can answer, and a test
  passes against the wrong build. Stop a server by its process id, never with `pkill -f <pattern>`:
  the pattern is in `pkill`'s own command line, so it kills itself.
- **Gitignored inputs are invisible.** A linter or cache that skips ignored paths can go quiet in a
  worktree without failing. When a gate passes suspiciously fast, check that it saw the files.
- **A shared build cache replays other worktrees' results.** When worktrees share a task cache, a
  gate in one can report green from tasks that ran in another, which is sound only if the inputs are
  identical. For a run that has to prove something, read which tasks executed and which were
  replayed, or bypass the cache for it.
- **Stage explicit paths.** `git add -A` in a shared checkout sweeps up whatever else is uncommitted.
- **Read the command's own output, not a pipeline's status.** `<tests> | tail` reports `tail`'s
  status, which hides a failure.

## Landing it

**First, which branch does this land in, and may you merge into it yourself?**

- **The target is the branch you cut from.** A worktree branched off `main` lands in `main`. A
  worktree branched off a feature branch lands back in that feature branch, never past it into
  `main`: the feature branch reaches `main` by its own route later. Name the base when you create
  the worktree (`--base <branch>`) and land into that same branch.
- **Many shared branches cannot be merged into locally at all.** Where a branch requires a reviewed
  pull request (common for `main` in a team repository), the route is: push the worktree's branch,
  open a pull request against the target, and stop. The review and the merge happen there, by the
  people allowed to do them. A direct merge and push to such a branch is either refused by the
  server or, worse, accepted and bypasses review.
- **How to know, in this order; the first that answers decides:**
  1. **The repository's context file** (`AGENTS.md`, `CLAUDE.md`), where it says how work lands.
  2. **This domain's half**, which says whether this machine's repositories use pull requests at
     all, and names any review forge by host.
  3. **Where `origin` lives** (`git remote get-url origin`). On a hosted review forge (`github.com`,
     `gitlab.com`, `bitbucket.org`, or a host the domain half names), the target takes a pull
     request. On anything else (a self-hosted forge, a network or local path, no remote at all),
     merge locally.
  4. **Still unclear: ask** before merging into a branch you did not create.

  A branch you created yourself in this stream (a feature branch, a sub-branch of it) is always
  yours to merge into.
- **When the answer is a pull request, it holds even if you cannot open one.** With no forge CLI or
  no web access, push the branch, tell the person which branch to open it from and against which
  target, and stop. Being asked to "land" the work does not change the route; merging into the
  target locally instead commits it to a history the review has not seen.

**Then land by the repository's own route**, which this domain's half names: a fast-forward into the main
branch, a merge commit, a cherry-pick of reviewed commits, or a separate integration branch with the
main branch reserved for releases. `wt merge` squashes, rebases and removes the worktree by default,
so use it only where that is the route, or with the flags that make it so.

- **Land from the checkout of the target branch**: the main checkout of a standard clone, or the
  target branch's own worktree in a bare container (`<repo>/main/`). Leave the worktree you worked
  in first.
- **Never reach the main branch another way**: not by pushing the branch to the remote's main branch,
  and not by moving the main branch's ref from inside the worktree. Both skip the checkout that
  serves it.
- **Verify on the remotes**: `git ls-remote <remote> refs/heads/<branch>` on each remote names the
  new commit. Ahead/behind counts read local tracking refs, which can be stale.
- **Cite the landed commit**, the one on the target branch. A cherry-pick makes a new commit; the
  worktree branch's id does not exist on the target.
- **Refresh the target checkout's dependencies** when the landing changed a lockfile: the checkout
  someone runs the app from keeps the old packages otherwise.

To keep working in the same stream, go back into the same worktree and bring it level with the
target (`git merge --ff-only <target>` inside it).

## Removing it

Only when its stream is finished, its work is on the target branch, and you are not inside it.
Under a pull-request route the stream finishes when the pull request merges; keep the worktree until
then for review changes, and expect the server may already have deleted the remote branch. Run these
from where the layout says to stand.

1. **Prove the work landed.** For a merged branch, `git branch --merged <target>` lists it. For
   cherry-picked work, use `git cherry -v <target> <branch>`: a `-` line is a commit whose change is
   already on the target, a `+` line is one that is not. An ancestry check reports every
   cherry-picked branch as unlanded.
2. **Prove nothing in it exists only there**, gitignored files included:

   ```sh
   find <path> -type f -not -path '*/.git' -not -path '*/node_modules/*' | while read -r f; do
     git cat-file -e "$(git hash-object -- "$f")" 2>/dev/null || echo "ONLY HERE: $f"
   done
   ```

   Move anything it prints somewhere durable first.
3. **Prove it is clean**: `git -C <path> status --porcelain` prints nothing but the sandbox's
   placeholders (below). Staged, unstaged and intent-to-add (`git add -N`) leftovers all make the
   removal refuse, and they are exactly what that refusal exists to surface. In a worktree you made,
   resolve every line by committing it to the branch, or by reviewing it and reverting it. In one
   another session left behind, revert nothing you did not write: report what is there and hand it
   to the person.
4. **Leave it, then remove it with worktrunk, without force.** A session that entered it leaves with
   ExitWorktree, action `keep`; never ExitWorktree's `remove`, which refuses inside the sandbox and
   does not go through worktrunk. Then, from where the layout says to stand:

   ```sh
   wt remove --no-hooks --foreground <name> --format=json
   ```

   and read `branch_outcome`: `deleted` means done, and a `retained_*` value says why the branch was
   kept. Without `--foreground` the removal runs in the background and its result goes to a log.
   `--no-hooks` is part of the form on purpose: where a setup lets exactly this command run outside a
   session's sandbox (so git sees a true clean check, below), the repository's removal hooks must not
   run there too. Never `-y`, `-D`, `-f`/`--force`, `--reap` or `rm -rf`: a refusal means something is
   still there, and forcing it loses it.

   **Fallback:** a plain `git worktree remove <path>`, run alone, where a setup exempts it from the
   sandbox too; git's own clean check still refuses a worktree holding uncommitted work. Use it when
   the standard form cannot run; a hook warns when it is used. Where neither is exempt, removal from a
   session is the person's step.
5. **Delete the branch on every remote it reached** (`git push <remote> --delete <branch>` for each),
   then confirm with `git ls-remote`. A branch only ever local needs nothing.

If a removal is refused and you cannot see why, stop and hand it to the person, with the exact plain
command to run. Do not look for a way around the refusal.

**Before handing any removal to a person, run steps 1 to 3 yourself.** Hand over only a command
those checks say will succeed, or say what is still in the worktree; a command that will be refused
moves the investigation onto them. If a leftover genuinely has to be forced, snapshot it first
(`git-snapshot --untracked -C <path>`) and name the ref it prints alongside the command.

## Subagents in worktrees

Giving a subagent `isolation: worktree` creates a worktree on a fresh branch for it.

- **Its base is whatever the remote has**, fetched at creation where `wt-fetch-base` is enabled.
  Push the work it builds on first (a hook warns at dispatch when the checkout has commits on no
  remote), and have its prompt name the expected base commit, so it can check.
- **It installs before any gate**, like any new worktree.
- **The dispatching session owns the cleanup**: review, land, then remove, as above. A subagent's
  finished worktree is left behind in `.worktrees/`; once its work is landed, remove it with
  `wt remove --no-hooks --foreground <name>` (or the `git worktree remove <path>` fallback where
  the standard form cannot run), after the checks in Removing it. A session that ends with unlanded
  work in a worktree it created names that worktree in its handoff.

## Inside a sandboxed Claude Code session

These are properties of Claude Code's sandbox and its worktree tools, not of git. A plain shell, or a
machine where Claude Code's hooks are not available, has none of them.

- **Entering and leaving.** Only in a repository that isolates sessions; where sessions work in
  place, use the worktree by path (Who works where). The EnterWorktree tool with a *path* enters an
  existing worktree; with a *name* it creates a new one (Creating one, step 3). **Without worktrunk's plugin, create with
  `wt switch --create`, then enter by path.** ExitWorktree with `keep` returns the session to where
  it entered from; its `remove` is never used (Removing it, step 4).
- **A session writes the directory it stands in, plus the repository's `.git`**, except `config` and
  `hooks/` there, which stay read-only; its subagents share that write set live. In a standard
  clone a session started in the checkout can therefore write the checkout, every nested worktree
  and the shared git data. After EnterWorktree it writes only the worktree it entered: the checkout
  it left becomes read-only, for its subagents too, which is why a session that works in place never
  enters one. The consequence for landing: a session lands from the checkout of the target after
  ExitWorktree, never into it from a worktree. A fast-forward run from the wrong place fails with
  `Read-only file system`, sometimes after writing part of the change under a writable
  subdirectory: check `git status` and restore those files. In a bare container the default
  branch's directory is itself a worktree, so a sibling cannot be created from Bash
  (`could not create leading directories … Read-only file system`): use EnterWorktree there.
- **Protected paths show as untracked files.** The sandbox mounts empty placeholders over paths it
  protects (settings files, shell profiles and similar), and git lists them as untracked, so
  `git worktree remove` and `wt remove` refuse a clean worktree from inside the sandbox. Do not force
  it and do not add an ignore rule for them: removal is the person's step, or the step of a settings
  exception that lets exactly `wt remove --no-hooks --foreground <name>` (the standard) or a plain
  `git worktree remove <path>` (the fallback) run outside the sandbox. A session killed mid-command leaves them on disk as
  real empty files, outside any sandbox; from a normal shell, `claude-mask-sweep --remove` deletes
  those (keeping any a running session still uses), then `git status --short` shows what is really
  there and the plain remove succeeds.
- **Where Claude Code's background-isolation guard is on** (a repository can turn it off with
  `worktree.bgIsolation: "none"`, as one whose owning session works in its checkout does), it
  **refuses compound commands** in a worktree: a git command inside `&&`, a
  path in a variable, a loop, a heredoc that touches git. Run single commands, and name paths with
  `git -C <path>` rather than relying on the current directory, which can drift after leaving.
- **Each command has its own network namespace**, so a server started in one command cannot be
  reached from the next. Start the server and the client in the same command.

## Failure signatures

| You see | It means | Do |
| --- | --- | --- |
| `protected branch`, `GH006`, `pre-receive hook declined` or "changes must be made through a pull request" on push | the target requires a reviewed pull request | push your branch and open a pull request against the target instead |
| `fatal: '<branch>' is already used by worktree at …` | that branch is checked out elsewhere | work in that worktree, or operate the other branch through its own worktree |
| `contains modified or untracked files` on a clean worktree | sandbox placeholders | run the exact `wt remove --no-hooks --foreground <name>` form, or hand the removal to the person |
| A hook refuses `git worktree add` or `move` | worktrunk owns worktree creation here | run the `wt` command the refusal names |
| A hook warns on `git worktree remove` | the raw removal is the fallback, not the standard | prefer `wt remove --no-hooks --foreground <name>` next time |
| EnterWorktree refused: "this repository's sessions work in place" | the effective `worktree.bgIsolation` is `none` | use the worktree by path (`git -C .worktrees/<name> …`), or hand the work to a subagent |
| `wt-fetch-base: refusing to create …: no remote could be reached` | the base could not be fetched from `origin` or any fallback | bring a remote back; do not create from the stale local base |
| `Read-only file system` after leaving a worktree | the session is not where the layout says to stand | stop; restore any half-written files; give the person the commands |
| `could not create leading directories … Read-only file system` creating a worktree from Bash | a sandboxed command cannot write a bare container's root | create it with the EnterWorktree tool by name; a person or an unsandboxed script uses `wt switch --create` |
| A commit or ref update fails with `Read-only file system` in a bare container's worktree | the container is in the old `.bare` shape, which the sandbox's git-directory rule does not cover | convert it (`fleet-repo check` prints the commands) |
| `fatal: this operation must be run in a work tree` | you are at a bare container's root | stand in the default branch's worktree |
| A new worktree far behind | its base was never fetched (`wt-fetch-base` not enabled, `--no-hooks`, or a plain git worktree) | fetch every remote, recreate from a named base |
| Tests pass here and fail there, or pass suspiciously fast | a borrowed install, missing build output, or an ignored input | install and build in this worktree |
| `address already in use` | another worktree's server | use this worktree's ports; stop the server by its pid |
| A cherry-picked branch reads as unmerged | ancestry cannot see a cherry-pick | `git cherry -v <target> <branch>` |
| `wt: command not found` in a script or over SSH, or `wt switch` leaves you in the old directory | the shell function is absent; only the binary ran | `command wt … --no-cd`, then `cd` yourself |
| `git commit` exits non-zero but the commit is there | a stale lock after the commit was written | check `git log` before retrying |
