# The fleet manifest: `~/Devel/mani.yaml`

One file per domain, written by that domain's private layer (the home and work repository sets are
separate, so each writes its own whole file). It does two jobs at once:

- **`mani` reads it** to clone and sync the domain's repositories into `~/Devel`. `mani sync
  --parallel` (4 at once; `--forks N` for more) clones several at a time, custom `clone:` commands
  included; stay serial for repositories that prompt for credentials. `mani describe` shows only some
  of mani's own keys (not `clone:`), so it is not a view of what an entry declares: read a key with
  `fleet-decl`. `mani` looks for a `mani.yaml` at or above the current directory; `~/.zshenv`
  exports `MANI_CONFIG=~/Devel/mani.yaml` when that file exists, which mani uses only when the
  search finds nothing, so `mani` works from anywhere and a repository's own `mani.yaml` still wins.
- **The base's tools read declarations about each repository from it**, always through `fleet-decl`,
  so that every tool resolves a path to the same entry.

`FLEET_RECORD` points the tools at another file (tests use this). Validate with:

```sh
fleet-decl --check      # prints findings; exit 0 clean, 1 findings, 2 the file is unusable
```

`overlay-doctor` runs the same check on the private layer's copy. Keys this page does not list are
allowed (other tools may read the file), except near-misses of the `leak*`, `canonical*`, `container*`, `claude*` and
`worktrunk` names below, which `--check` refuses as probable typos.

## What reading it means for a missing or broken file

`fleet-decl` exits 1 for "this repository declares nothing" and 2 for "the manifest cannot be read".
A tool that enforces something treats 2 as a refusal, never as "nothing declared": `leak-guard`
refuses the commit, and so does `run-repo-gates` when a repository has a gate it would have to
classify. An ABSENT file currently counts as unreadable (exit 2); treating absence as "nothing
declared" is a known improvement still to make.

## Project keys

Each entry is `projects.<name>`. The name is the key other tools use (`fleet-decl --entry <name>`).

### `mani`'s own

| Key | Value | Notes |
| --- | --- | --- |
| `path` | path relative to `~/Devel` | where `mani sync` puts the clone, and where `mani` tasks run. For a standard clone, the repository root. For a bare container, the DEFAULT-BRANCH WORKTREE (`<container>/<default-branch>`), never the container ([`repository-layouts.md`](repository-layouts.md)). Required by `mani` |
| `url` | the clone URL | `mani sync` sets `origin` from it. Required by `mani` |
| `tags` | list | `mani` selects by tag (`mani sync --tags active`). Two tags also change what the base's tools do (below) |
| `env` | map | exported to `mani` tasks for that project |
| `clone` | a command | replaces `mani`'s own clone. A standard clone needs none: `mani`'s own clone and `fleet-repo clone <name>` run the same `git clone`. `fleet-repo clone <name>` here declares a bare container (`git-clone-worktree --mani-project <name>` still works, as a forwarding shim); leaving it out of an entry meant to be bare makes it a standard clone, silently. `mani` runs it only where `path` does not exist yet, so a later change to the declaration reaches an existing container through `fleet-repo clone <name>` run by hand (it reconciles), never through `mani sync` |
| `branch` | a branch name | the branch a standard clone's checkout is on: `mani sync` and `fleet-repo clone` both clone with `git clone --branch <branch>`. Absent: the remote's default branch. Also what `fleet-repo check` compares the checkout against (`checkout-branch`), and what makes a standard entry part of a no-argument `fleet-repo check` |
| `single_branch` | `true` | a standard clone fetches only its `branch` (`git clone --single-branch`), for a very large repository; `fleet-repo` adds a fetch refspec for each `worktrees:` branch on top. `fleet-decl` reads `false` as absent |
| `worktrees` | list of `{name, path}` | durable worktrees; `path` is relative to the project's `path`: `.worktrees/<name>` in a standard clone, `../<name>` beside a bare container's default branch. Each `name` is a branch, and `fleet-repo clone` fetches it and creates the worktree with an upstream. `mani sync` creates them too where no `clone:` replaces its own, but (mani 0.32.1, measured) on a NEW branch named after the directory, from the checkout's commit, so let `fleet-repo clone <name>` make them |
| `sync` | `false` | `mani sync` never clones it, not even when named (`mani sync <name>`); clone it by hand if a machine wants it. Once it exists on disk it is an ordinary project: `mani exec --all`, `mani run` and `mani list` include it, and `fleet-decl` reads its declarations either way |

Top-level `tasks:` are `mani` tasks (`mani run <task>`). `lint-tasknames` checks their names against
the shared task vocabulary.

### Tags the base's tools act on

| Tag | Meaning | Effect |
| --- | --- | --- |
| `upstream` | somebody else's repository, cloned to read or build | no `leakPolicy` needed; `run-repo-gates` does not run its tracked hooks; `hook-doctor` and `lint-tasknames` skip it |
| `external` | lives under `~/Devel/external/`, including our own packaging repositories | not the same as `upstream`: an `external` repository we author keeps its gates |

Every other tag is the domain's own vocabulary and only selects.

### The fleet's declarations

| Key | Value | Read by | Required |
| --- | --- | --- | --- |
| `scope` | a path prefix, relative to `~/Devel` or absolute | `fleet-decl`: resolves a repository path to this entry by the LONGEST matching scope, so nested repositories resolve to the inner one. A scope that does not exist on this machine is skipped | for any entry a per-repository tool must find. An entry without one is never matched to a path |
| `leakPolicy` | `strict`, `private`, `notes` or `internal` | `leak-guard`, `hook-doctor` | yes, unless tagged `upstream` or fleet-only (see below). `fleet-decl --check` reports `[policy-missing]` |
| `leakPrefix` | comma-separated identifier prefixes | `leak-guard` | no. The repository's own program prefix(es): markers carrying one of them are allowed in this repository |
| `leakDisable` | `true` | `leak-guard`, `hook-doctor` | no. Turns the publish guard off for this repository entirely; prefer a wider `leakPolicy` |
| `container.branches` | `all`, `default` or a list of branch names | `fleet-repo` | no. Which branches a bare container fetches, beyond the default branch and every `worktrees:` name (always fetched). Absent: `containerDefaults.branches`, else `all` |
| `container.filter` | a git `--filter` spec, e.g. `blob:none` | `fleet-repo` | no. A partial clone: every commit and tree, file contents only on demand. Applies to a FRESH clone only; on an existing unfiltered container it is reported, not applied |
| `worktrunk.layout` | `bare` or `nested` | `wt-config-gen` | no. Where `wt` puts worktrees: siblings of a bare clone, or under `<repo>/.worktrees/`. Without it, the default in `base.toml` chooses by the repository's shape: a bare repository named `.git` gets siblings, anything else nests |
| `worktrunk.bootstrap` | `true` or `false` | `wt-config-gen` | no. Whether a new worktree installs its dependencies (`wt-bootstrap`) |
| `claudeTrust` | `false` | `claude-trust-check` | no. `false` leaves the project, and its launch directory, out of the workspace-trust check: for a repository no agent session should run in (a secrets store, a third-party clone kept for reading). Any other value, or none, is checked; `--check` refuses a value that is not an unquoted boolean, since `"false"` or `no` is a string in YAML 1.2 |
| `canonical` | a session name | a domain's session launcher, if it has one; `memory-doctor` | no. Declares the project's long-running agent session |
| `canonicalIdentity` | text | the session launcher | yes when `canonical` is set |
| `canonicalLaunchDir` | a path | the session launcher; `memory-doctor` | yes when `canonical` is set |
| `canonicalLaunchModel` | a model id | the session launcher | yes when `canonical` is set |
| `canonicalMachines` | list of machine names | the session launcher | yes when `canonical` is set |

**The layout is declared, and `fleet-decl --layout <name>` reads it.** An entry is a bare container
when it has a `container:` block, a `clone:` command that runs `fleet-repo` (or its older name
`git-clone-worktree`) as a command word, or `worktrunk.layout: bare`; any other entry is a standard
clone. `fleet-repo`, `wt-config-gen` and `fleet-repo check` all ask this one reader, so the layout is
stated once and no two tools can disagree about it. A bare entry gets sibling worktrees from
`wt-config-gen` unless `worktrunk.layout` says otherwise. `fleet-decl --check` validates the
`container:` block: `branches` must be `all`, `default` or a list of non-empty strings, `filter` a
non-empty string, and a near-miss of either key (`branchs`) is reported as `[container-key]`.

A container's bare repository is named `.git`. One made before that keeps it in `.bare` behind a
pointer file; every `fleet-repo` verb accepts both, `fleet-repo check` reports the old one as
`old-layout` and prints the conversion
([`repository-layouts.md`](repository-layouts.md#converting-a-bare-container-from-the-old-shape)).

```yaml
containerDefaults:            # fleet level; absent means every entry's branches is all
  branches: default
projects:
  ios:
    path: work/ios/develop    # <container>/<default-branch>
    url: git@github.com:org/ios.git
    clone: fleet-repo clone ios
    worktrees:
      - name: main
        path: ../main
    container:
      branches: default       # all | default | [names]
      filter: blob:none
```

What each form fetches: `all`, every branch; `default`, the remote's default branch only; a list,
the default plus those names; and in every case the `worktrees:` branches. The set is written into
the container as fetch refspecs, so a later `git fetch` or `git pull` stays inside it. That is also
what keeps branch names differing only in case (`Feature/x`, `feature/x`) from colliding on a
case-insensitive file system: an undeclared one is never fetched. Changing the declaration and
running `fleet-repo clone <name>` again reconciles an existing container: it adds and fetches new
branches, drops the refspec and remote-tracking ref of a branch no longer declared, and only
REPORTS a local branch or worktree for it, since either may hold unpushed work.

`fleet-repo check` compares the declaration with the disk (exit 0 clean, 1 drift, 2 manifest
unusable) and `fleet-repo update` fast-forwards a repository's worktrees; `fleet-repo --help` has
the details. With no project named, `check` examines every bare entry and every standard entry that
declares `branch:`, so a machine whose manifest declares no standard entries sees no change.

### Adding a repository, and proving it

**As a standard clone**, the fleet layout:

1. **Write the entry** with `path:` the repository root, `scope:` the same, and `branch:` the branch
   its checkout should be on; no `clone:`. Where a chezmoi instance deploys the manifest, edit that
   source and apply.
2. **Validate:** `fleet-decl --check`, and `fleet-decl --layout <name>` prints `standard`.
3. **Prove it on that one project:**

   ```sh
   mani sync <name>                                        # or: fleet-repo clone <name>
   git -C <path> rev-parse --is-bare-repository            # false
   git -C <path> branch --show-current                     # the declared branch
   fleet-repo check <name>                                 # exit 0
   ```

   Then add `.worktrees/` to the repository's `.gitignore` if it is not there yet.

**As a bare container**, on a machine that still uses them:

1. **Find the default branch**, which differs between repositories:
   `git ls-remote --symref <url> HEAD` (first line: `ref: refs/heads/<default>  HEAD`).
2. **Write the entry** with `path: <container>/<default-branch>` (the worktree; the container is its
   parent) and `clone: fleet-repo clone <name>`.
3. **Validate:** `fleet-decl --check`, and `fleet-decl --layout <name>` prints `bare`.
4. **Prove it on that one project** before syncing the rest:

   ```sh
   mani sync <name>
   git -C <container>/.git rev-parse --is-bare-repository          # true
   git -C <container>/<default-branch> rev-parse --git-common-dir  # ends in <container>/.git
   fleet-repo check <name>                                         # exit 0
   ```

A ✓ from `mani sync` is not the proof for a container, because three mistakes also tick: leaving out
`clone:` (a standard clone, with `worktrees:` nested inside it), naming the container in `path:` (the
container is built one level up), and adding `clone:` to an entry whose `path` already holds a clone
(`mani` runs `clone:` only where `path` is missing, so nothing changes). A wrong default branch in
`path:` warns "manifest expects the worktree at" and marks the project ✕; fix `path:` and re-sync. A
hand edit of the manifest does not run `wt-config-gen`, so new worktrees nest until it runs;
`fleet-repo check` reports that as `worktrunk-missing`.

**What `leakPolicy` allows.** The publish guard keeps two classes of the domain's private vocabulary
out of repositories, from files the private layer supplies under `~/.dotlocal/`: **markers**
(`git-leak-markers`: program identifiers such as a register entry's id, and pointers into the
domain's notes) and **sensitive terms** (`git-leak-sensitive`).

| `leakPolicy` | Markers | Sensitive terms |
| --- | --- | --- |
| `strict` (also the default when absent) | blocked, except the repository's own `leakPrefix` | blocked |
| `private` | blocked, except its own `leakPrefix` | allowed in commits; still blocked on a push to a destination the domain has not declared private (`git-leak-policy`) |
| `notes` | allowed | allowed |
| `internal` | allowed | allowed |

A domain that supplies neither pattern file has no guard: every commit passes and `leakPolicy`
governs nothing.

**Fleet-only entries.** An entry with no `scope` that declares a `canonical*` key or `worktrunk`
settings is exempt from `leakPolicy`: no path resolves to it, so a policy would govern nothing.

## Fleet-level keys

| Key | Value | Read by |
| --- | --- | --- |
| `containerDefaults.branches` | `all`, `default` or a list | `fleet-repo`: the `container.branches` of every entry that sets none; absent means `all` (a domain with very large repositories sets `default`) |
| `remoteConvention.remotes.<name>` | `{from: url | env.<VAR>, required: bool}` | a domain's own remote-setup tool, if it has one (`fleet-decl --fleet-keys remoteConvention.remotes`) |
| `remoteConvention.fanout` | `{name, fetch, push: [remotes]}` | the same: one remote that fetches from one and pushes to several |
| `remoteConvention.retire` | list of remote names | the same: removed from every managed repository wherever found |

## A starting point

`overlay-skeleton/Devel/mani.yaml.tmpl.example` carries every key above, commented, for a new
domain to fill in. Run `fleet-decl --check` after writing it.
