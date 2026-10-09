# Repository layouts: plain clone or bare container

A repository under `~/Devel` is in one of two shapes:

- **Plain clone:** `<repo>/` is the checkout, `<repo>/.git/` holds the git data, and worktrees nest
  under `<repo>/.worktrees/<branch>`.
- **Bare container:** `<repo>/.git/` is itself a bare repository (`core.bare = true`, no pointer
  file), and every branch, the default one included, is a sibling worktree: `<repo>/main/`,
  `<repo>/<branch>/`. The directory is named `.git` because Claude Code's sandbox lets a linked
  worktree write its shared git directory (commits, ref updates) only under that name; with any
  other name the container's root has to be granted writable by hand, which also opens the
  directory's `config` and `hooks/` to every session. A container made before this naming keeps its
  git data in `<repo>/.bare/` behind a one-line `.git` file saying `gitdir: ./.bare`; the fleet
  tools accept both, `fleet-repo check` reports the old one as `old-layout`, and the conversion is
  [below](#converting-a-bare-container-from-the-old-shape).

The skill `working-in-worktrees` has the full comparison: how to tell them apart, where to stand to
create, land and remove a worktree, what each costs, and when to choose which. In one line: a bare
container suits a repository where more than one writer (several agent sessions, say) works at once,
because deleting any one directory, `main/` included, cannot break the others; a plain clone suits a
repository with one writer and an occasional worktree.

## Declaring a repository's layout

Both live in the repository's entry in `~/Devel/mani.yaml` ([`fleet-manifest.md`](fleet-manifest.md)):

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
    worktrunk:
      bootstrap: true                                     # install dependencies in each worktree
```

A `container:` block, or a `clone:` that runs `fleet-repo`, already says the entry is a bare container,
so `wt-config-gen` places new worktrees beside `main/` without `worktrunk: {layout: bare}`; an explicit
`worktrunk.layout` still wins. What the container fetches, and the `container:` keys, are in
[`fleet-manifest.md`](fleet-manifest.md).

Three rules, each of which fails quietly when broken (all measured with a real `mani sync`):

- **`path:` names the default-branch worktree,** `<container>/<default-branch>`, and the container is
  its parent. `mani` runs tasks and `mani exec` in `path`, and the container itself is bare, so it
  could not be that directory. Use the repository's real default branch, which differs from
  repository to repository (`main`, `master`, `develop`): `git ls-remote --symref <url> HEAD`
  names it. A wrong name is warned about, the real default is created instead, and `mani sync`
  then reports the project failed, because the declared path does not exist. A `path:` naming the
  container makes its parent the container; `fleet-repo` refuses that when the parent
  already holds files, which protects the devel root from becoming a repository.
- **`clone:` is required.** Without it `mani sync` reports success and produces an ordinary
  checkout, with any `worktrees:` nested inside it and sharing its `.git`: the layout this page
  exists to avoid, with nothing to say so.
- **`worktrees:` paths are relative to `path`,** so a sibling of the default branch is `../<name>`.

`fleet-repo clone` is idempotent: run on an existing container it RECONCILES it with the
declaration. It adds and fetches newly declared branches, drops the refspec and remote-tracking ref of
a branch no longer declared (reporting, never deleting, a local branch or worktree for it), repairs
upstreams and re-creates missing worktrees. `mani` runs `clone:` only where `path` is missing, so
`mani sync` never reconciles: after changing a declaration, run `fleet-repo clone <name>` yourself.
It sets an upstream on every branch that has a worktree, which a bare clone does not record, so
`fleet-repo update` (or `mani exec --all 'git pull --ff-only'`) works in containers and plain clones
alike; re-run `fleet-repo clone` once on a container cloned before it did ("There is no tracking
information for the current branch"). `fleet-repo check` reports the drift between declaration and
disk without fixing it. The old name `git-clone-worktree` forwards to `fleet-repo clone`. Mixed
default branches across repositories need nothing special: each clone reads its own from the
remote. After editing `worktrunk:` blocks, run `wt-config-gen` (an apply also runs it). The skill
`fleet-manifest` walks the whole procedure.

## Files a worktree needs that git does not carry

A worktree is a fresh checkout, so the gitignored, per-machine files a repository needs to build or
run are not in it: Gradle's `local.properties` (the Android SDK location), a `.env`, local
configuration. The standard:

1. **The files live in the default branch's worktree** (`<container>/main/` in a bare container, the
   checkout itself in a plain clone). That worktree is where you set a repository up by hand once.
2. **The repository lists them in `.worktreeinclude`** at that worktree's root, one gitignore-style
   pattern per line. A file is copied only if it is BOTH gitignored and listed, so a tracked file is
   never touched and an unlisted ignored file (build output, `node_modules/`) is never copied.
3. **Every new worktree gets a copy**, whichever way it is made:
   - `wt switch --create`, and so a Claude Code worktree made through the worktrunk plugin: a global
     `pre-start` hook in the base's `base.toml` runs `wt step copy-ignored --require-include`. It
     blocks, so the files are in place before any later hook or build.
   - `fleet-repo clone`, for each `worktrees:` entry it adds to an existing container: it runs the
     same worktrunk copy, because `git worktree add` runs no worktrunk hook. Without `wt` installed
     it says so; a failed copy is a warning, not a failed clone.

   A file already present in the new worktree is never overwritten. A repository with no
   `.worktreeinclude` gets nothing copied and no message.

**`.worktreeinclude` may be committed or local.** Commit it where the team shares the convention;
Claude Code reads the same file natively. In a repository you cannot commit to, keep it untracked
and hide it, with the files it lists if they are not already ignored, in the repository's own
exclude file, which every worktree of the container shares:

```sh
cd ~/Devel/<path>/<container>/main
printf 'local.properties\n' > .worktreeinclude
printf '.worktreeinclude\n' >> "$(git rev-parse --git-common-dir)/info/exclude"
```

**What it does not cover: the first worktree of a fresh clone.** There is nothing to copy from, so
the default worktree is set up by hand, once, per machine. A standard way to seed it at clone time is
not designed yet.

**Copy, not symlink:** a tool that rewrites its file (Android Studio does, for `local.properties`)
changes only its own worktree's copy. The cost is that a later change in `main/` does not reach
worktrees that already exist; copy it across by hand, or re-run
`wt step copy-ignored --from main --to <branch> --force` from any worktree of the container.

## Converting a `.bare` container from the old shape

The conversion is a rename and one repair. There is deliberately no command for it: `fleet-repo
check` prints these three, with the container's path filled in, and a person runs them.

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
2. **Expect a workspace-trust prompt.** Trust is keyed on the repository root, which the rename can
   change, so Claude Code may ask again in the first session afterwards. Accept it.

To go back, mirror the steps: rename `.git` to `.bare`, write `gitdir: ./.bare` into a new `.git`
file, and run `git -C <container>/.bare worktree repair <each worktree path>`.

Convert one container at a time, a rarely-used one first, and check it in a real session: a commit
and a ref update succeed, and a write to the shared `config` or `hooks/` is refused.

## Converting an existing plain clone

Nothing is pushed, rewritten or deleted until the new container is proven. Unpushed local branches
are carried across by fetching them from the old clone directly.

```sh
old=~/Devel/work/my-service            # the plain clone
new=~/Devel/work/my-service.new        # the container, renamed into place at the end

# 1. Know what the old clone holds that its remote does not.
git -C "$old" status --short           # uncommitted changes: commit or stash them first
git -C "$old" stash list               # stashes do not travel; apply and commit what you need
git -C "$old" worktree list            # worktrees to re-create
git -C "$old" for-each-ref --format='%(refname:short) %(upstream:short) %(upstream:track)' refs/heads
#   a branch with no upstream was never pushed; [ahead N] has N unpushed commits; carry both

# 2. Clone the container beside it.
fleet-repo clone --url "$(git -C "$old" remote get-url origin)" "$new"

# 3. Bring each local-only or ahead branch across, from the old clone (no push needed).
git -C "$new/main" fetch "$old" my-branch:my-branch

# 4. Prove it: build or test in "$new/main", and check the branches you carried across.

# 5. Swap, then repair: git records worktree paths as absolute, so moving the container leaves
#    main/ pointing at the old path ("fatal: not a git repository") until `worktree repair` runs.
mv "$old" "$old.plain-backup" && mv "$new" "$old"
git -C "$old/.git" worktree repair "$old"/*/

# 6. Re-create the worktrees you use, now at their final paths, and copy any untracked files they
#    need (.env, local config). The branch exists already, so no --create.
git -C "$old/main" worktree add ../my-branch my-branch

# 7. Update the repository's mani.yaml entry as above. Delete the backup only once you have worked
#    from the container for a while.
```

Run end to end against a scratch repository on 2026-10-02: the container came out bare, the unpushed
branch arrived with its commit, the move broke `main/` until `worktree repair` ran, and the carried
branch then checked out as a sibling worktree.

Remote names other than `origin` (a fork's `upstream`, say) are re-added with `git remote add` in the
container. A repository the manifest manages can instead be cloned with
`fleet-repo clone <name>` after its `clone:` line is added.
