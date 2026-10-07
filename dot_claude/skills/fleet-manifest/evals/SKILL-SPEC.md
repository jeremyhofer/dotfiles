# Skill spec: fleet-manifest

Claude Code loads only `SKILL.md`; this file costs no context. It says why the skill exists and
how to tell whether it works. The procedure itself is the skill body.

## Purpose

Prevents a misconfigured `~/Devel/mani.yaml` that a sync reports as fine. Observed on a newly
configured machine, 2026-10-06: an agent setting up manifest entries for bare containers doubted
its own entries, treated `mani describe` output as the list of keys that matter, and tried
`git-clone-worktree --help`, which then ran `mkdir -p --help`. The base's own reference example
named the container in `path:`, which (measured with a real `mani sync`) builds the container
one directory too high, at worst in the devel root itself.

## Placement

Public base. The manifest's shape and the tools that read it are public; each domain's actual
entries are private and stay in that domain's layer.

## Effect claims

A session without the skill, asked to add a repository as a bare container, gets these wrong:

1. `path:` names `<container>/<default-branch>`, not the container.
2. The entry has a `clone: git-clone-worktree --mani-project <name>` line.
3. The default branch in `path:` is read from the remote (`git ls-remote --symref`), not assumed
   to be `main`.
4. Asked whether a key outside `mani describe`'s output has any effect, it answers from
   `fleet-decl` or the reference, not from `describe`.
5. It proves the layout on one project (`.bare` present, `--git-common-dir` ends in `.bare`)
   rather than citing `mani sync`'s ✓.

## Should-fire situations

- "Add `org/payments` to the manifest as a bare container; its default branch is develop."
- "Set up all my work repositories with mani on this new machine."
- `mani sync` printed ✕ for one project after "manifest expects the worktree at work/app/main".
- "`mani describe` doesn't show `leakPolicy`, so can I drop it?"
- `git-clone-worktree: work already holds files and is not a container`.
- "Why did `mani sync` give me a normal clone instead of `.bare` plus worktrees?"
- Editing a project's `worktrees:` list to add a durable `devel` worktree.

## Near-misses

- Creating a short-lived worktree for a feature branch with `wt switch --create`: skill
  `working-in-worktrees`.
- Choosing a task name for the manifest's `tasks:` block: skill `naming-build-tasks`.
- Updating the dotfiles after a pull, including a changed manifest template: skill
  `dotfiles-update`.
- A commit refused by `leak-guard`: the policy table is in the reference, but the refusal itself is
  the publish guard's, and is not a manifest-editing task.

## Failure signature

As in the skill body: a container without `.bare`; a worktree whose common git directory is inside
a sibling; a `.git` in a non-repository directory; `fleet-decl --check` findings; a conclusion
about keys drawn from `mani describe`.

## Success measure

Reached for: at least 4 of 5 should-fire prompts and at most 1 of 4 near-misses, per the base's
skill-audit method. Effect: the deployed arm beats the ablated arm on each claim above, 5 trials a
claim. Field: rare by design; a machine's manifest is written once and edited occasionally.

## Test cases

Not yet run. The should-fire and near-miss prompts above are the reached-for cases. The effect
fixture is a scratch `~/Devel` with two local bare origins whose default branches are `develop` and
`master`; grading reads the resulting `mani.yaml` and the layout on disk after `mani sync`.
