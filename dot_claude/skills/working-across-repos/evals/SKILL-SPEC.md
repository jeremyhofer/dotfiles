# working-across-repos — skill spec

What this skill is for and how to tell whether it works. Claude Code loads only `SKILL.md`, so this
file costs no context. Test runs and their results are logged by whoever maintains the skill, not
here; this file says what a run must show.

## Purpose

Stop a session from treating a multi-repo manifest as a plain list and `mani` as a tool that does
more, or less, than it does. The incidents behind it: five entries added to a manifest as an
inventory fix silently changed what four programs that read it did (a hook check, a task-name
linter, a bootstrap clone step and a drift audit), because none of them excluded the new kind of
entry (third-party clones), and searching for the changed names found none of them. Separately, `mani` run from outside
the manifest's tree reads like a broken install, `mani sync` is taken to make a machine match the
manifest when it only clones what is missing, and an unfiltered `mani exec` runs in every repo.

## Placement and where it applies

- **Placement:** hybrid. The public base carries how `mani` behaves and why a manifest has readers;
  a private fragment (`~/.dotlocal/skills/working-across-repos.md`) carries one domain's manifest
  source, its readers, its tag vocabulary and its drift audit.
- **Applies:** any machine with `mani` and a manifest. The readers section applies wherever scripts
  enumerate the manifest, which is a property of the domain, not of `mani`.

## Effect claims

| Id | Claim | Graded on |
| --- | --- | --- |
| `readers` | Asked to add or retag a project in the manifest, the session first searches for the programs that read the manifest and names how each filters, before or alongside the edit | the session's actions and its final answer |
| `cwd` | Shown `cannot find any configuration file` from `mani`, the session runs it from inside the manifest's tree rather than reinstalling or reconfiguring `mani` | the session's actions |
| `filter` | Asked to run a command in one group of repos, the session scopes `mani exec` or `mani run` with a tag or project filter, not `--all` and not an unfiltered run | the session's actions |
| `sync-missing` | Told `mani sync` succeeded on a new machine but one repo is absent, the session adds the missing manifest entry rather than cloning the repo by hand or re-running sync | the end state: the manifest |

## Should-fire situations

- Add a newly created repo to the manifest so that new machines clone it.
- Mark a project in `mani.yaml` as retired so that nothing works on it any more.
- `mani list projects` fails with "cannot find any configuration file in current directory or any
  of the parent directories".
- On a fresh laptop `mani sync` finished cleanly, but one repo is not there.
- Show uncommitted changes across every repo tagged `internal`.
- Run the lint task in each repo that consumes the design system.
- Find which of the repos still pins Node 18 in its CI config.
- Set up a new machine with all of the repos.

## Near-misses

The skill that should win is named where one exists.

- Create a worktree for a feature branch and land it when done (`working-in-worktrees`).
- `wt switch` from a script leaves the shell in the old directory (`working-in-worktrees`).
- Add a package to a pnpm workspace's `pnpm-workspace.yaml`.
- Update a git submodule to its upstream's latest commit.
- Write a justfile recipe that runs the tests in this repo.

## Failure signature

- A manifest entry added, removed or retagged with no search for the manifest's readers, or with a
  search for the project's name only.
- `mani` reinstalled, or a global config created, after a "cannot find any configuration file"
  error.
- `mani exec --all`, or a `mani exec` with no `-t`/`-p`, for work meant for some repos.
- A repo cloned by hand into the tree to fix a `mani sync` that "missed" it, leaving the manifest
  still without it.

## Success measure

Written before any run (2026-10-04), so a result cannot move it.

- **Reached for:** on Opus 5.5, at least 80% of should-fire trials and at most 20% of near-miss
  trials invoke the skill, at three trials per prompt, and a copy with a generic description of the
  same length fires clearly less. Where the live skill listing shows this skill by name only (the
  listing has a size budget ranked by past use, and a renamed skill starts with none), the second
  arm shows the description instead. Also run on Opus 4.8 and Sonnet 5, the models used at work, as
  floors.
- **Effect, per claim:** first, 5 trials with the skill removed. If all 5 pass, the claim cannot
  show an effect and its text is a candidate to cut from the body. Otherwise, 10 trials with the
  skill as deployed against 10 without, started together. The claim holds when the deployed arm
  passes more often, with Fisher's exact test one-sided p < 0.05. If the arm without the skill passes
  7 or more of 10, both arms are rerun together at 30 each. Split the deployed arm by whether the
  session invoked the skill.
- **Field:** invocations against sessions that run `mani` or touch the manifest, counted from
  session transcripts at each periodic review. The first count, over the month to 2026-10-01 and
  under the skill's earlier name, was zero invocations against about 8 `mani` runs and 92 distinct
  commands touching the manifest or its drift audit.

## Test cases

The prompts, fixtures and graders live with the private test harness for now; they move into this
directory when the harness runs off the home workstation.
