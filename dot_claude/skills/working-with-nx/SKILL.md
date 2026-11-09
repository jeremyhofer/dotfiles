---
name: working-with-nx
description: Use when running, configuring, profiling or timing tasks in an Nx workspace — gates with `--nxBail`, `affected`, `inputs`/`outputs`, the cache, `NX_PROFILE`, `--graph`, `parallelism`, plugins and atomized targets (`createNodes`, `@nx/playwright`, the Vitest atomizer), or Nx run inside another Nx task. Also fires on the failure signatures — "Attempted to open socket that exceeds the maximum socket length", a cache that is per checkout instead of shared, a warm run with fewer cache hits than expected, an `affected` run that skips a project whose file changed, a task graph tool that crashes or finds no dependencies, `{workspaceRoot}` refused in a command, a Playwright config Nx ignores, a one-spec run failing on coverage thresholds, a nested Nx fixture whose cache checks fail, a task replayed green from the cache after an edit to a library it imports (a stale project graph after a tsconfig path-alias change), and E403 from a registry round trip in a sandbox. Verified against Nx 24.0.2 (some points also 23.1.1); each point says where it was read, so re-check after an upgrade.
---

# Working with Nx

Nx is a build orchestrator: it reads a *task graph* (which target of which project runs, and what it
depends on), hashes each task's declared *inputs*, and replays a stored result from its *cache* when
the hash has been seen. Nearly every trap below is the same shape: Nx does exactly what is declared,
the declaration was not what the author believed, and nothing errors. This skill records what was
read in the installed source or measured, so you can act on it instead of re-deriving it.

Version caveat: Nx's internals move between majors. The points are verified on **Nx 24.0.2** unless
a line says otherwise. Before believing any of them, check which Nx is actually installed (first
section). Paths like `nx/dist/src/...` are inside `node_modules/nx`; read the file, not this skill,
when the answer matters.

## 1. The cache and where it lives

**Check the installed Nx against the lockfile first.**

```sh
node -p "require('./node_modules/nx/package.json').version"
```

A checkout whose `node_modules` predates a lockfile bump runs the old Nx and shows the old
behavior: one checkout ran 23.1.1 under a lockfile at 24.0.0 and kept a per-checkout cache until
`npm ci` ran. Any "Nx does X" claim made from a stale install is a claim about the wrong version.

**Nx 24 keeps one cache per workspace, shared by every checkout and worktree, at `~/.nx/<workspace
id>/`** (`nx/dist/src/utils/cache-directory.js`). A second worktree of the same repository therefore
starts warm. Two things switch the sharing off without telling you:

- A `cacheDirectory` override in `nx.json` or the environment. Do not set one; the shared default is
  the point.
- A `~/.nx` Nx cannot write. It falls back to a per-checkout `.nx/cache`. In an agent sandbox this
  means the sandbox must grant write access to `~/.nx`; without the grant every checkout is cold and
  nothing says why.

**Daemon sockets need no override when `~/.nx` is writable.** Nx 24 then puts them in
`~/.nx/sockets`. `NX_SOCKET_DIR` was the old fix for "Attempted to open socket that exceeds the
maximum socket length" in deeply nested worktree paths; with a writable `~/.nx` it is not needed, so
do not add it as a reflex.

**The project graph is cached too, and it can go stale after a path-alias change.** Besides the task
cache, Nx keeps the project graph it builds, the per-file import edges included, in the checkout's
`.nx/workspace-data/`. Measured twice in one workspace on 2026-11-09 under Nx 24.0.2: after a change
to the TypeScript path aliases (`paths` in `tsconfig.base.json`), the cached graph kept stale edges,
the second time on `main` after a plain fast-forward. Two projects lost their edge to a library they
both import. A task hash built on that graph leaves the library out, so a later edit to the library
replays those projects' tasks green from the cache: the same silent stale replay as an undeclared
input, with every declaration correct. It does not happen every time, and no upstream issue was found
that matches it exactly. The fix is Nx's own command, which rebuilds the graph and leaves the shared
task cache alone:

```sh
npx nx reset --onlyWorkspaceData
```

Until the cause is known, run it before a gate in any checkout that takes an alias change, by a
commit or a pull, and at the start of a CI entrypoint whose working tree persists between runs. It
costs a few seconds of graph rebuild. To see whether a checkout is affected, compare `nx graph
--file=<out>.json` before and after the reset for an edge you know exists.

## 2. Inputs, outputs and `affected`

An *input* is anything whose change must invalidate the cache; an *output* is what Nx stores and
restores. An undeclared input is not an error: the task replays a stale result.

**Legacy `affected` (`affected.legacy: true`) selects a project when the changed file is under its
root, or matches a `{workspaceRoot}` input declared by any of its targets.** Only an *undeclared*
input goes unselected, and that is the same input the cache would replay stale. So `affected` is a
second check on your declarations: a file that changes the output of a task but selects nothing is a
missing input. Legacy mode also over-selects dependents, which costs time, not correctness. (A
reading of this from source once said the opposite; the rule above was planted and seen twice. Plant
a change in a file the input list must cover before trusting a narrowed list.)

**One file has one writer.** No task writes or edits another task's output. When two tasks
contribute to one file, each writes a fragment and a third task joins them. Two writers make the
cached output depend on run order, which is a correctness bug the cache hides.

**A committed file that a cached task writes is that task's output, never another target's plain
input.** A plain file input is hashed when the task graph is built, before the writer runs, so a
reader's key can describe the file's previous content. Leave the file out of the reader's plain
globs and depend on the writer, so `dependentTasksOutputFiles` hashes it after the write (measured
2026-11-08 on a generated `_redirects` file: `verify-task-io --static` found 22 such gaps with the
file left in a plain glob, 18 without it, the same 18 that predated the change).

**But an exclusion from a SHARED named input reaches every target naming that set.** A target that
names the set and does not depend on the writer silently stops hashing the file, and the static
tracer cannot see it, since that target has no dependency to compare against (the same change left
eight post-build gates with the file in no cache key). So run `nx show target inputs <target>
--check <file>` for every target that names the set, not only the tracer's findings, and give the
targets that read the file without its writer a set that still lists it.

**A project whose root holds only `project.json`, its source living elsewhere in the workspace,
names its inputs as `{workspaceRoot}` paths through named inputs.** `{projectRoot}` and
`^production` both resolve to its empty directory, so they hash nothing and the target replays
stale. Its edges go in `implicitDependencies`, since there is no source under its root to infer them
from (measured 2026-11-08: six Python module projects carved out of one root project).

**An input list derived from what a test reaches must follow every import path the runner adds.**
In a Python workspace that means the modules on pytest's `pythonpath` (a `scripts/` directory, for
one): a test that reached a higher module through a script passed a check that followed only
imports and fixtures. Reach is not the whole list either: a helper in another module's test
directory can be reached and still sit outside the importer's inputs, and a test that reads all
source as text depends on every module. Plant a change in each module a target should not depend
on, and in one it should, before trusting a derived list.

**Read `verify-task-io` findings against a single-target differential before adding an input.**
In a run over several targets, every `uv run` writes `.venv/.lock`, which reports as a foreign write
(accept it in `.verify-task-io.toml` with its reason). Inside an agent sandbox, the session's own
harness reading the watched tree (placeholder files under `.claude/`, `.mcp.json`, an open source
file) can surface as one target's undeclared reads, and disappears when that target is traced alone
(both measured 2026-11-08).

**A repeated identical edit times the cache, not the work.** A timing scenario that writes the same
text each sample replays the first sample's result from the second on (3.6 to 3.9 s against a real
101 s). Vary the edit per sample.

## 3. Running gates

A *gate* is one command that must pass before work lands (a lint, test and build run).

**One Nx invocation per gate.** A shell target that runs Nx inside Nx hides the real task graph from
the profile, from `--graph` and from the cache view, and every process writes the same `NX_PROFILE`
file. Declare the targets with `dependsOn` edges and run them in one invocation.

**`--nxBail` skips tasks not yet started; tasks already running finish** (Nx 23.1.1 and 24.0.2,
`nx/dist/src/tasks-runner/task-orchestrator.js`). The gate exits when the longest running task
ends, not at the first failure. Two consequences:

- Putting cheap checks first with a `dependsOn` edge is not the remedy. Nothing consumes the edge
  (the cheap task produces nothing the expensive one reads), and it delays every focused run. Do
  cheap file-local checks in an earlier tier, such as a commit hook.
- A task with `"parallelism": false` is started only when nothing else is running
  (`tasks-schedule.js`, `canBeScheduled`), so cheap tasks drain first and `--nxBail` reports early
  around it. That is the scheduler's current behavior, not a documented guarantee; do not build on it
  without re-reading the file.

**A test that runs Nx inside an Nx task must drop the outer `NX_` environment.** Under
`--skip-nx-cache` Nx exports `NX_SKIP_NX_CACHE=true` to every task (`task-env.js:143`). A test that
runs a nested Nx workspace (a fixture) inherits it, so the fixture's own cache checks fail with no
defect. Strip those variables from the child's environment.

**Inside an agent sandbox, gitignored dotfiles in a main checkout can be the sandbox's empty
read-only placeholders** (a `.mcp.json`, a file under `.claude/`). Tools that parse them or read
every file fail ("Permission denied", a parse error on an empty file). Run such a gate from a
worktree, where the files are real or absent.

## 4. Profiling and measuring

**`NX_PROFILE` is joined to the workspace root even when given an absolute path**
(`nx/dist/src/tasks-runner/life-cycles/task-profiling-life-cycle.js:11`). A profile written into a
path git does not ignore changes every whole-repository input and spoils the next warm run (4 cache
hits against 12). Give a relative path inside an ignored directory.

**Under nested Nx the outer process writes the profile last** (Nx 24 reads the variable in
`run-command.js`) and overwrites the inner run's per-task profile. This is how the single-invocation
rule shows up when you measure.

**Splitting one cached test target into per-layer targets moves the cost; it does not only cut
it.** A top-layer edit gets cheaper, since only the top layer re-runs. A bottom-layer edit can get
dearer: every layer above it re-runs, each pays the runner's own start-up (pytest, xdist, coverage),
and with `parallelism: false` they run one after another. Measured 2026-11-08 by one Python
workspace's gate after a one-line edit, against an adjacent control of the unsplit graph at 322 s:
a top-layer edit 163 s, a bottom-layer edit 422 s in sequence, 292 s with four or five workers. So
time both a top-layer and a bottom-layer edit against an adjacent control before landing a split.

**Write `--graph=<file>` outside the workspace.** Inside it, a formatter's whole-repository check
flags the file.

**Nx 24's task graph writes each dependency edge as an object, `{id, waitFor?, inputs?}`; Nx 23
wrote the id string** (`nx/dist/src/tasks-runner/create-task-graph.js:124-166`). A tool that reads
edges as ids crashes (Python) or silently finds no dependencies (JavaScript). Read `edge.id` and
accept both shapes.

**Time one lane with `--excludeTaskDependencies`** and the lane run alone, or the time of the lanes
it depends on folds into it.

**A one-spec timing run of a suite with a global coverage threshold exits non-zero on coverage
alone.** Read the test summary, not the exit code. Measure coverage with the project's own options:
adding a `--cov=<module>` on top of a path-form `--cov` already in `addopts` produced a spurious
failure in a compiled-query library, a measurement artifact and not a defect.

**Check a lane's worker bound before crediting a change in file layout.** A lane running 1,180
test-seconds in about 409 s on 3 workers is bound by its worker count; splitting its files cannot
make it faster.

## 5. Plugins and atomizers

A *plugin* adds targets by inferring them from config files. An *atomizer* splits one target (all
tests of a project) into one task per file, so a change reruns only the affected atoms.

**Plugin and graph API (Nx 24).**

- The export is `createNodes`; `createNodesV2` is deprecated.
- A static dependency edge needs a source file the *source* project owns. A project with no such
  file declares its edge as an implicit dependency instead.
- A `{workspaceRoot}` token is refused inside a `run-commands` command string.
- `tsc` copies no non-TypeScript file (CSS, JSON assets, templates). A package that ships one needs a
  target that assembles it and a check that asserts it is in the output.

**Atomizer behavior (read in 24.0.2; the stale-atom defect still held there).**

- Atomizers copy inputs inside the plugin and add no `dependsOn`, so overrides in `project.json`
  never reach the atoms. Configure atoms through `targetDefaults` glob keys.
- Every atom hashes the whole project root, so atomizing narrows nothing for an edit inside the
  project: all atoms rerun.
- The Vitest atomizer has no coverage merge; coverage per atom is not combined.
- With the defaults, an atom replays stale after a generated input (generated CSS, here) is
  regenerated. Plant a change to the generated file and confirm the atom reruns before relying on it.

**`@nx/playwright` silently ignores a config not named `playwright.config.*` that sits beside
`project.json`, and its atoms run every Playwright project.** A renamed or relocated config yields
no inferred target and no error, and an atom runs every configured browser, including one that does
not launch on the machine.

## 6. Sandboxes

**A registry round trip (publish to a local registry, install back) needs the public registry in the
command's allowed domains.** The scratch consumer fetches third-party dependencies from it. Without
the grant the sandbox proxy answers E403. That is an environment fault, not a defect in the package:
stop and report the missing grant instead of retrying or routing around the proxy.

For the other sandbox cases in this skill, see the cache write grant (section 1) and placeholder
dotfiles (section 3).

## Why these rules exist

A repository's fast-loop rules (declare inputs and outputs and believe them only once verified; one
writer per file; uncached only for a recorded reason; a gate stops at its first failure; atomize
only the critical path; one graph per gate) all rest on facts about how Nx behaves. Where this skill
and an installed Nx disagree, the installed source wins: read the file named in the point, then
correct the point.
