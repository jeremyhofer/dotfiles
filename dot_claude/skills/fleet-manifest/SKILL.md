---
name: fleet-manifest
description: Use when writing, editing or checking `~/Devel/mani.yaml` — adding a repository, choosing its `path:`, `clone:`, `worktrees:`, `scope:` or `worktrunk:` keys, running `mani sync`, `mani exec` or `mani run`, cloning a bare container with `git-clone-worktree --mani-project`, or judging which keys matter (never from `mani describe`). Also fires on the failure signatures — a project marked ✕ by `mani sync`, "manifest expects the worktree at", "already holds files and is not a container", an ordinary checkout where a bare container was expected, a stray `.bare` or `.git` in a non-repository directory, `fleet-decl --check` findings. Covers the file's two readers, the add-a-repository procedure and its one-project proof, and the four rules that fail silently.
---

# The fleet manifest: `~/Devel/mani.yaml`

One YAML file declares every repository a machine keeps under `~/Devel`. **Two different readers
consume it**, and most mistakes come from forgetting the second:

- **`mani`** (a multi-repository sync tool) reads its own keys: `path`, `url`, `clone`,
  `worktrees`, `tags`, `env`, `sync`, and top-level `tasks:`. It clones what is missing and runs
  commands across repositories.
- **The dotfiles base's tools** read declarations about each repository through `fleet-decl`:
  `scope`, `leakPolicy`, `leakPrefix`, `worktrunk.*`, `canonical*`. The publish guard
  (`leak-guard`), `hook-doctor`, `wt-config-gen` and `memory-doctor` act on them.

The tooling choice is settled, not open for re-evaluation: `mani` for sync and `worktrunk` (`wt`)
for worktrees were adopted after a survey of the alternatives and a hands-on trial, and
`git-clone-worktree` stays as the bootstrap because `wt` has no clone verb. Its behaviour below is
measured with a real `mani sync` and covered by the base's `tests/test-git-clone-worktree.sh`. If
something here looks wrong, test it on one throwaway project; do not reason from the tool's
silence.

Full key reference: `docs/reference/fleet-manifest.md` in the dotfiles base source
(`chezmoi source-path` prints where that is). Layouts and converting a clone:
`docs/reference/repository-layouts.md` beside it.

## `mani describe` is not the effective configuration

`mani describe projects <name>` prints a fixed set of fields (name, sync, path, url,
single_branch, tags, env). It omits keys that change behaviour, **including `clone:`, which mani
itself executes**, and every key the base's tools read. Concluding "this key has no effect because
describe does not show it" is reading a display as a schema.

To read a declaration, ask the reader that uses it:

```sh
fleet-decl <repo-path> <key>        # e.g. fleet-decl internal/app/main leakPolicy
fleet-decl --entry <name> <key>     # by project name
fleet-decl --check                  # validates the whole file: exit 0 clean, 1 findings, 2 unreadable
```

## Adding a repository, as a bare container

A **bare container** keeps git's data in `<container>/.bare` and every branch, the default one
included, as a sibling worktree (`<container>/main/`, `<container>/develop/`), so deleting any one
worktree cannot orphan the others. Skill `working-in-worktrees` covers when to choose it.

1. **Find the default branch.** It differs between repositories (`main`, `master`, `develop`):

   ```sh
   git ls-remote --symref <url> HEAD      # first line: ref: refs/heads/<default>  HEAD
   ```

2. **Write the entry.** If a chezmoi instance deploys the manifest (`chezmoi source-path
   ~/Devel/mani.yaml`, or the private instance's equivalent, succeeds), edit that source and apply;
   an edit to the deployed file is overwritten by the next apply.

   ```yaml
   projects:
     app:
       path: work/app/develop                    # <container>/<default-branch>: the WORKTREE
       url: git@github.com:org/app.git
       scope: work/app                           # the container, so every worktree resolves here
       clone: git-clone-worktree --mani-project app
       worktrees:                                # optional further durable worktrees
         - name: main
           path: ../main                         # relative to path:
       tags: [work, active]
       leakPolicy: strict                        # what the publish guard allows (see the reference)
       worktrunk:
         layout: bare
   ```

3. **Validate:** `fleet-decl --check`. Where a private layer exists, `overlay-doctor` runs the same
   check on its copy.

4. **Prove it on that one project** before syncing the rest:

   ```sh
   mani sync app
   cat work/app/.git                                    # gitdir: ./.bare
   git -C work/app/develop rev-parse --git-common-dir   # ends in work/app/.bare
   ```

   A ✓ from `mani sync` is not this proof: two of the four mistakes below also tick.

5. If you changed a `worktrunk:` block, run `wt-config-gen` (an apply also runs it).

## The four rules that fail quietly

| Rule | Broken, it looks like | What happened |
| --- | --- | --- |
| **`clone:` is required** for a bare container | `mani sync` ✓, and an ordinary checkout at `path` with `worktrees:` nested inside it | mani used its own clone; nothing says so |
| **`path:` names `<container>/<default-branch>`**, never the container | the container is built one level up: `.bare` and `.git` in the parent | the container is always `path`'s parent. `git-clone-worktree` now refuses when that parent already holds files ("already holds files and is not a container"), which keeps `~/Devel` from becoming a repository; an empty or new parent is still used |
| **`path:` uses the real default branch** | a warning "manifest expects the worktree at …", then ✕ for the project | the real default was created instead; fix `path:` and re-sync |
| **`clone:` only acts where `path` does not exist yet** | adding `clone:` to an entry with an existing plain clone: ✓, and still a plain clone | mani clones only missing paths. Convert by hand: `repository-layouts.md`, "Converting an existing plain clone" |

`worktrees:` paths are relative to `path:`, so a sibling of the default branch is `../<name>`.
Re-running `mani sync` is safe: `git-clone-worktree` re-creates only what is missing, and a deleted
declared worktree comes back.

## Daily verbs

- `mani sync` — clone what is missing and create declared worktrees; `mani sync <name>` or
  `--tags active` for a subset, `--status` to look without cloning. It never pulls into an existing
  checkout. Cloning is serial unless `--parallel`, which suits repositories that prompt for
  credentials. `--sync-remotes` rewrites existing checkouts' remotes from the manifest; leave it to
  whatever owns remote wiring on that machine.
- `mani exec --all 'git pull --ff-only'` — the safe update; fast-forward only, so it never clobbers
  local work. It runs in each project's `path`, which is why `path` must be a worktree: the bare
  container has no working tree to run in. It updates only the branch checked out at `path`; other
  worktrees are pulled in their own directories. A container whose default branch answers "There
  is no tracking information" was cloned by an older `git-clone-worktree`, and `mani sync` will not
  fix it (it runs `clone:` only where `path` is missing). Repair every project at once:
  `mani exec --all 'git rev-parse --abbrev-ref "@{u}" >/dev/null 2>&1 || git branch --set-upstream-to="origin/$(git branch --show-current)"'`.
- `mani run <task> --projects <name>` — a task from the top-level `tasks:` block. Task names follow
  skill `naming-build-tasks`; `lint-tasknames` checks them.

## Failure signature

The procedure went wrong if any of these is true after a sync: a container has no `.bare`; a
worktree's `git rev-parse --git-common-dir` points inside a sibling rather than at `.bare`; a
`.git` exists in a directory that is not a repository (`~/Devel` itself, a group directory such as
`work/`); `fleet-decl --check` reports findings; or a conclusion about which keys matter rests on
`mani describe`.
