---
name: working-across-repos
description: Use when working across several repos at once with `mani` — cloning a machine's repo set, running the same command in many repos, finding which repo something lives in — and before adding, removing or retagging a project in the repo manifest (`mani.yaml`), which other programs read. Fires on `mani`, `mani sync`, `mani run`, `mani exec`, `mani list`, `mani.yaml`, and when mani reports "cannot find any configuration file", `mani sync` succeeds but a repo is missing, or a `mani exec` ran in repos it should not have. For worktrees and `wt`, use skill `working-in-worktrees`.
---

# Working across repos with `mani`

`mani` operates on **many repos** from one manifest: a file listing every project with a `path`, a
clone `url`, and **`tags`**. Work is scoped by filtering on those tags, not by remembering which
directory you are in. (Many branches of *one* repo is a different job: skill `working-in-worktrees`.)

- `mani` — <https://github.com/alajmo/mani>

## The commands

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

**mani finds its manifest by walking UP from the current directory**, exactly like git finds `.git`.
Run it from outside the tree and every command fails with `cannot find any configuration file … in
current directory or any of the parent directories` — which reads like a broken install and is only a
wrong `cwd`. There is no global fallback location.

**`mani sync` is additive, with one write you should expect.** It clones what is missing and leaves
existing checkouts alone — it is the "make this machine complete" command, not "make this machine
match". It does not pull, does not remove, and will not fix a repo that has drifted. But it is **not
read-only**: `--sync-gitignore` defaults to **true**, so it also writes a `.gitignore` in the manifest
root. Pass `--sync-gitignore=false` if that is unwanted. Remotes are likewise **not** touched unless
you pass `--sync-remotes`, so a freshly synced repo may have only its clone origin.

## Editing the manifest: other programs read it

A manifest looks like a list and is often an **input**: scripts enumerate it to decide which repos to
check, lint, clone or wire remotes for. Adding, removing or retagging an entry changes what they do,
and nothing in the file says so, so searching for the name you changed finds nothing. Before editing,
find the readers: search the places scripts live for the manifest's file name, and check how each one
filters (which tag it skips). The private fragment below names this domain's readers.

## The gap `mani` does not close

The manifest is hand-maintained, so it drifts from reality in **both** directions: a repo can exist
on the origin with no manifest entry (it will never be cloned by `sync`, silently), and an entry can
outlive the repo it names. `mani check` validates the manifest's *syntax*, not its correspondence to
what actually exists — so a manifest can be perfectly valid and completely wrong.

If a drift audit exists for this domain, it is named in the private fragment below.

## How you can tell it went wrong

- **`cannot find any configuration file`** — you are outside the manifest's tree; `cd` into it.
- **`mani sync` reported success but a repo you expected is absent** — it is missing from the
  manifest, not missing from the origin. `sync` only ever acts on manifest entries.
- **A `mani exec` took far longer than expected, or touched a repo you did not mean** — the filter
  was omitted and it ran across every project.
- **After a manifest edit, a check or clone silently skips a repo, or now covers one it should not**
  — a program that reads the manifest filters on a tag the edit changed.

---

For this domain's project and tag inventory, where the manifest comes from, its readers, and the
drift audit, read `~/.dotlocal/skills/working-across-repos.md` if it exists.
