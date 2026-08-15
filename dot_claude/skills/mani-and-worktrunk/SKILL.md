---
name: mani-and-worktrunk
description: Use when working across several repos at once — cloning a machine's repo set, running the same command in many repos, or finding which repo something lives in — and when creating, switching, listing or removing git worktrees for parallel branches. Fires on `mani`, `mani sync`, `mani run`, `mani exec`, `wt`, `wt switch`, `worktrunk`, and when `wt` reports "command not found" over SSH or in a script, or a worktree command seems not to change directory.
---

# Multi-repo with `mani`, worktrees with `worktrunk`

Two small single-binary tools with one job each. `mani` operates on **many repos**; `worktrunk`
(the `wt` command) operates on **many branches of one repo**. They do not overlap.

- `mani` — <https://github.com/alajmo/mani>
- `worktrunk` — <https://github.com/max-sixty/worktrunk>

## `wt` must be a shell function, and that is the thing that trips agents

A program cannot change its parent shell's directory. So `wt switch` is a **shell function** that
wraps the binary and does the `cd` itself. Consequences you have to plan around:

| Context | Is `wt` there? |
| --- | --- |
| An interactive shell | **Yes** — the function is defined by the shell rc |
| A non-interactive shell, a script, `ssh host 'zsh -ls'` | **No.** `.zshrc` is not read, so the function does not exist and you get `command not found` |
| The binary itself, anywhere | Yes — but it **cannot change your directory**, only report and act |

**So in a script or over SSH, call the binary (`command wt …`) and do your own `cd`.** Never assume
the function exists just because it works when a human types it. If you need the path rather than
the side effect, `command wt list` prints one per worktree.

## `wt` — the operations worth knowing

| Command | Does |
| --- | --- |
| `wt switch <branch>` | switch to that worktree, **creating it if it does not exist** — this is the main entry point |
| `wt list` | every worktree with branch, dirty state, ahead/behind vs the trunk and vs the remote |
| `wt remove` | remove the worktree, and delete the branch **if it has been merged** |
| `wt merge` | merge the current branch into the target |

`wt list` is the one to run before anything else: it shows in a single view which worktrees have
uncommitted work and which are behind, which is exactly what you need before switching or removing.

## `mani` — the manifest is the whole model

`mani` reads a manifest listing every project with a `path`, a clone `url`, and **`tags`**. Work is
scoped by filtering on those tags, not by remembering which directory you are in.

```zsh
mani list projects              # everything the manifest knows about
mani list tags                  # the tag vocabulary, with members
mani sync                       # clone anything in the manifest that is missing locally
mani exec -t <tag> -- <command> # run an arbitrary command in every project with that tag
mani run <task> -t <tag>        # run a manifest-defined task
mani check                      # validate the manifest
```

**Filter, always.** `mani exec` with no filter runs everywhere, which is rarely what is wanted and
is occasionally destructive. `-t <tag>` and `-p <project>` are how you scope; `mani list tags` tells
you what is available before you guess.

**`mani sync` is additive.** It clones what is missing and leaves existing checkouts alone — it is
the "make this machine complete" command, not a "make this machine match" command. It does not pull,
does not remove anything, and will not fix a repo that has drifted.

## The gap `mani` does not close

The manifest is hand-maintained, so it drifts from reality in **both** directions: a repo can exist
on the origin with no manifest entry (it will never be cloned by `sync`, silently), and an entry can
outlive the repo it names. `mani check` validates the manifest's *syntax*, not its correspondence to
what actually exists — so a manifest can be perfectly valid and completely wrong.

If a drift audit exists for this domain, it is named in the private fragment below.

## How you can tell it went wrong

- **`wt: command not found`** in a script, a CI step, or over SSH — you are relying on the shell
  function in a non-interactive shell. Use `command wt`, and handle the `cd` yourself.
- **`wt switch` "worked" but you are still in the old directory** — you invoked the binary rather
  than the function; the binary cannot move you.
- **`mani sync` reported success but a repo you expected is absent** — it is missing from the
  manifest, not missing from the origin. `sync` only ever acts on manifest entries.
- **A `mani exec` took far longer than expected, or touched a repo you did not mean** — the filter
  was omitted and it ran across every project.
- **`fatal: not a git repository`** from `wt` — it operates on the repo of the current directory;
  `-C` is not a substitute for being in the right place.

---

For this domain's project and tag inventory, where the manifest comes from, and the drift audit,
read `~/.dotlocal/skills/mani-and-worktrunk.md` if it exists.
