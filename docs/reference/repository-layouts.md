# Repository layouts: plain clone or bare container

A repository under `~/Devel` is in one of two shapes:

- **Plain clone:** `<repo>/` is the checkout, `<repo>/.git/` holds the git data, and worktrees nest
  under `<repo>/.worktrees/<branch>`.
- **Bare container:** `<repo>/.bare/` holds the git data, `<repo>/.git` is a file saying
  `gitdir: ./.bare`, and every branch, the default one included, is a sibling worktree:
  `<repo>/main/`, `<repo>/<branch>/`.

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
    path: work/my-service
    url: https://github.com/my-org/my-service.git
    clone: git-clone-worktree --mani-project my-service   # mani sync clones it as a bare container
    worktrunk:
      layout: bare                                        # wt places new worktrees beside main/
      bootstrap: true                                     # and installs dependencies in each
```

`git-clone-worktree` is idempotent: run on an existing container it re-creates only what is
missing, so `mani sync` may call it every time. After editing `worktrunk:` blocks, run
`wt-config-gen` (an apply also runs it).

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
git-clone-worktree "$(git -C "$old" remote get-url origin)" "$new"

# 3. Bring each local-only or ahead branch across, from the old clone (no push needed).
git -C "$new/main" fetch "$old" my-branch:my-branch

# 4. Prove it: build or test in "$new/main", and check the branches you carried across.

# 5. Swap, then repair: git records worktree paths as absolute, so moving the container leaves
#    main/ pointing at the old path ("fatal: not a git repository") until `worktree repair` runs.
mv "$old" "$old.plain-backup" && mv "$new" "$old"
git --git-dir="$old/.bare" worktree repair "$old"/*/

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
`git-clone-worktree --mani-project <name>` after its `clone:` line is added.
