# Repository layouts: standard clone or bare container

A **worktree** is a directory where one branch's files are checked out; one repository can have
several, each on its own branch, all sharing one git database. A **bare repository** is that database
with no files checked out beside it. A repository under `~/Devel` is in one of two shapes:

- **Standard clone, the fleet layout:** an ordinary clone. `<repo>/` is the checkout, on the branch
  its owner works on, `<repo>/.git/` holds the git data, and further worktrees nest inside it at
  `<repo>/.worktrees/<name>`.
- **Bare container, the older layout:** `<repo>/.git/` is itself a bare repository
  (`core.bare = true`, no pointer file), and every branch, the default one included, is a sibling
  worktree: `<repo>/main/`, `<repo>/<branch>/`. Nothing is checked out at `<repo>/` itself. A
  container made before the bare repository was named `.git` keeps its git data in `<repo>/.bare/`
  behind a one-line `.git` file saying `gitdir: ./.bare`; `fleet-repo check` reports it as
  `old-layout`, and its conversion is [below](#converting-a-bare-container-from-the-old-shape). The
  fleet tools keep supporting containers until every machine has changed over.

## Why the standard clone

**Agent sessions can work in it with no extra permission.** Claude Code runs a session's shell
commands in a sandbox that lets it write the directory it stands in and its repository's `.git`
(except `.git/config` and `.git/hooks/`); subagents share that. In a standard clone everything a
session touches is inside `<repo>/`: the checkout, the worktrees its subagents create under
`.worktrees/`, and the caches tools keep at the repository root (Nx's task database, for one). In a
bare container the container root sits outside every worktree, so a cache at the main worktree's
root and a new worktree beside the others both land where no session may write, and every container
needs a sandbox grant that also opens its `config` and `hooks/`.

**It is what other tools expect.** IDEs such as Android Studio and Xcode open a standard clone or a
nested worktree directly, and worktrunk (`wt`) handles it with its defaults.

**What it costs.** The checkout is load-bearing: deleting or re-cloning `<repo>/` takes every nested
worktree with it, uncommitted work and unpushed branches included, so remove worktrees with
`wt remove` and never by deleting a directory. And `.worktrees/` must be ignored, in the repository's
own `.gitignore`: a tool that walks the tree (Nx, prettier, eslint, `rg`) otherwise meets a second
copy of the repository. Nx in particular fails to load its plugins with an un-ignored nested worktree
present.

The skill `working-in-worktrees` covers the day-to-day: where to stand to create, land and remove a
worktree, and how sessions and people share one clone.

## Declaring a repository's layout

In the repository's entry in `~/Devel/mani.yaml` ([`fleet-manifest.md`](fleet-manifest.md)). The
layout is DECLARED, never detected from the disk: an entry is a bare container when it has a
`container:` block, a `clone:` command that runs `fleet-repo` (or its older name
`git-clone-worktree`), or `worktrunk.layout: bare`; every other entry is a standard clone.
`fleet-decl --layout <name>` prints the answer, and every fleet tool asks it, so no two tools can
disagree about an entry.

### A standard clone

```yaml
projects:
  my-service:
    path: work/my-service                                 # the repository root
    url: https://github.com/my-org/my-service.git
    scope: work/my-service                                # every nested worktree resolves to this entry
    branch: main                                          # mani's key: the checkout's branch
    # single_branch: true                                 # mani's key: fetch only that branch
    worktrees:                                            # optional: durable worktrees, relative to path
      - name: develop
        path: .worktrees/develop
    worktrunk:
      bootstrap: true                                     # install dependencies in each worktree
```

- **`path:` names the repository root**, where `mani` clones and runs tasks.
- **No `clone:` is needed.** `mani sync` clones with `git clone --branch <branch>`, adding
  `--single-branch` for `single_branch: true`, and `fleet-repo clone <name>` runs the same command,
  so either one gives a machine the same checkout and the same fetch settings (measured with mani
  0.32.1). Without `branch:` both check out the remote's default branch.
- **`worktrees:` paths are relative to `path`,** so a nested one is `.worktrees/<name>`. Each `name`
  is a branch. `fleet-repo clone <name>` checks that branch out with an upstream; `mani sync` does
  not (mani 0.32.1 makes a new branch named after the directory, from the checkout's commit), so
  after a first `mani sync` of an entry with worktrees, check them, or make them with `fleet-repo`.
- **`.worktrees/` goes in the repository's own `.gitignore`**, committed, so it holds on every
  machine and in every tool.

`fleet-repo clone <name>` is idempotent: run on an existing clone it creates missing worktrees and
sets missing upstreams. A checkout on another branch than the declared one is reported, never
switched back: the checkout belongs to whoever works in it. A bare container found where a standard
clone is declared is refused and left exactly as it is ([changing one over](#changing-a-container-over)).
`fleet-repo update` fast-forwards the checkout and its declared worktrees, and `fleet-repo check`
reports drift without fixing it: `no-checkout`, `bare-container`, `not-a-clone`, `checkout-branch`,
`no-upstream`, `missing-worktree`, and `worktrunk-bare` (the generated worktrunk config still puts
new worktrees beside the repository; run `wt-config-gen`).

### A bare container (older layout)

```yaml
projects:
  my-service:
    path: work/my-service/main                            # the DEFAULT-BRANCH WORKTREE, not the container
    url: https://github.com/my-org/my-service.git
    scope: work/my-service                                # the container: every worktree resolves to this entry
    clone: fleet-repo clone my-service                    # mani sync clones it as a bare container
    worktrees:                                            # optional: further durable worktrees, relative to path
      - name: develop
        path: ../develop
    container:                                            # optional: what the container fetches
      branches: default                                   # all | default | [names]; default: all
      filter: blob:none                                   # optional partial clone, fresh clones only
```

The container declaration already makes `wt-config-gen` place new worktrees beside `main/`, so
`worktrunk: {layout: bare}` is not needed; an explicit `worktrunk.layout` still wins. What the
container fetches, and the `container:` keys, are in [`fleet-manifest.md`](fleet-manifest.md).
Three rules, each of which fails quietly when broken (all measured with a real `mani sync`):

- **`path:` names the default-branch worktree,** `<container>/<default-branch>`, and the container is
  its parent: `mani` runs tasks in `path`, and the container itself has no checkout. Use the
  repository's real default branch (`git ls-remote --symref <url> HEAD` names it); a wrong name is
  warned about and the real default created instead. A `path:` naming the container makes its
  parent the container; `fleet-repo` refuses that when the parent already holds files, which also
  catches a manifest change to a standard clone made only halfway (root `path:`, `clone:` still
  there).
- **`clone:` is required.** Without it the entry reads as a standard clone.
- **`worktrees:` paths are relative to `path`,** so a sibling of the default branch is `../<name>`.

`fleet-repo clone` RECONCILES an existing container with the declaration: it adds and fetches newly
declared branches, drops the refspec and remote-tracking ref of a branch no longer declared
(reporting, never deleting, a local branch or worktree for it), repairs upstreams and re-creates
missing worktrees. `mani` runs `clone:` only where `path` is missing, so after changing a declaration
run `fleet-repo clone <name>` yourself. Adding a repository and proving it:
[`fleet-manifest.md`](fleet-manifest.md#adding-a-repository-and-proving-it).

After editing `worktrunk:` blocks, or changing an entry's layout, run `wt-config-gen` (an apply
also runs it).

## Files a worktree needs that git does not carry

A worktree is a fresh checkout, so the gitignored, per-machine files a repository needs to build or
run are not in it: Gradle's `local.properties` (the Android SDK location), a `.env`, local
configuration. The standard:

1. **The files live in the primary worktree**: the checkout itself in a standard clone,
   `<container>/main/` in a bare container. That is where you set a repository up by hand once.
2. **The repository lists them in `.worktreeinclude`** at that worktree's root, one gitignore-style
   pattern per line. A file is copied only if it is BOTH gitignored and listed, so a tracked file is
   never touched and an unlisted ignored file (build output, `node_modules/`) is never copied.
3. **Every new worktree gets a copy**, whichever way it is made:
   - `wt switch --create`, and so a Claude Code worktree made through the worktrunk plugin: a global
     `pre-start` hook in the base's `base.toml` runs `wt step copy-ignored --require-include`. It
     blocks, so the files are in place before any later hook or build.
   - `fleet-repo clone`, for each `worktrees:` entry it creates: it runs the same worktrunk copy,
     because `git worktree add` runs no worktrunk hook. Without `wt` installed it says so; a failed
     copy is a warning, not a failed clone.

   A file already present in the new worktree is never overwritten. A repository with no
   `.worktreeinclude` gets nothing copied and no message.

**`.worktreeinclude` may be committed or local.** Commit it where the team shares the convention;
Claude Code reads the same file natively. In a repository you cannot commit to, keep it untracked
and hide it, with the files it lists if they are not already ignored, in the repository's own
exclude file, which every worktree of the repository shares:

```sh
cd <the primary worktree>
printf 'local.properties\n' > .worktreeinclude
printf '.worktreeinclude\n' >> "$(git rev-parse --git-common-dir)/info/exclude"
```

**What it does not cover: the first checkout of a fresh clone.** There is nothing to copy from, so
the primary worktree is set up by hand, once, per machine. A standard way to seed it at clone time is
not designed yet.

**Copy, not symlink:** a tool that rewrites its file (Android Studio does, for `local.properties`)
changes only its own worktree's copy. The cost is that a later change in the primary worktree does
not reach worktrees that already exist; copy it across by hand, or re-run
`wt step copy-ignored --from <primary branch> --to <branch> --force` from any worktree.

## Changing a container over

A bare container becomes a standard clone by a **fresh clone, never in place**: the container is
renamed aside (`<repo>.old`) and kept untouched, a standard clone is made at the original path, and
what the fresh clone lacks (ignored files, unpushed branches, local settings) is carried across from
an inventory. Going back is a rename until the new clone has taken writes. Converting in place edits
the only copy, and removing a worktree deletes its ignored files with it.

No tool does this for you. Once the manifest entry declares a standard clone, `fleet-repo clone` and
`fleet-repo update` refuse the container still on disk, and `fleet-repo check` reports it as
`bare-container`, until a person has changed it over. The procedure, with the inventory, the
restore and the checks: [`standard-clone-changeover.md`](standard-clone-changeover.md).

## Converting a `.bare` container from the old shape

For a machine still on bare containers. The conversion is a rename and one repair. There is
deliberately no command for it: `fleet-repo check` prints these three, with the container's path
filled in, and a person runs them.

```sh
rm <container>/.git                        # the pointer file, so the name is free
mv <container>/.bare <container>/.git
git -C <container>/.git worktree repair    # rewrites every worktree's .git file at once
```

**Run them with no session, editor, watcher or git process in that container.** Between the `mv`
and the `repair` every worktree is broken (`fatal: not a git repository`), and a process that touches
one in that window fails or holds a stale path. After `repair`, each worktree's common directory is
`<container>/.git` and `git status` works in it. Measured on a scratch container with two worktrees.

Two things happen outside git, and only a person can do them, because a sandboxed session cannot
write Claude Code's own directory:

1. **Move the container's Claude Code memory store.** Claude Code keys a project's memory by its
   directory path, so the container's store lives under a project key that ends in `--bare` (the
   path of the old `.bare` directory, with separators flattened). Move
   `~/.claude/projects/<key>--bare/` to the same key without the `--bare` suffix, so the next
   session in the container finds it.
2. **Expect a workspace-trust prompt.** Claude Code keys trust on the repository's git common
   directory with a trailing `/.git` removed. For an old container that was `<container>/.bare`;
   after the rename it is `<container>`, so the converted container WILL ask again, and a
   background session (`claude --bg`) in it is refused until someone accepts. Open `claude` in the
   container once and accept. `claude-trust-check` lists every manifest directory still waiting.

To go back, mirror the steps: rename `.git` to `.bare`, write `gitdir: ./.bare` into a new `.git`
file, and run `git -C <container>/.bare worktree repair <each worktree path>`.
