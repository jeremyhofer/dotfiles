# Configuring a private layer

How to configure everything this base lets a domain (a machine set: personal, work) supply for
itself. [`architecture.md`](architecture.md) explains how the layers fit and lists each seam in one
table; this page is the how-to for each: the file, what reads it and when, its format, an example,
what happens without it, and how to check it.

Everything here is optional. A machine with only the base is a working, generic machine.

## Start here

1. `setup/scaffold-overlay <dir>` copies the stubs in [`overlay-skeleton/`](../../overlay-skeleton/)
   into a new private chezmoi source, renaming `.example` off. Its
   [`README.md`](../../overlay-skeleton/README.md) says which stubs are required.
2. Fill in each stub. A required one carries a `FIXME(overlay-doctor)` line until it is real.
3. Run `setup/overlay-doctor` from the base checkout: it fails until every required piece is filled.
4. Point the base at the private source with `overlayRepo` (next section), then apply both, base
   first and the private layer last, so its files land last: `chezmoi apply`, then
   `chezmoi-overlay apply` (`setup/chezmoi-safe-apply` does both, with a diff and a confirmation).

Files under the private source's `dot_dotlocal/` deploy to `~/.dotlocal/`, which is where the base
looks. Edit the private source and apply; never edit `~/.dotlocal/` directly, or the next apply
overwrites it.

## Machine data (chezmoi `[data]`)

Set once by `chezmoi init` and kept in `~/.config/chezmoi/chezmoi.toml`. Change a value by editing that
file, then apply.

| Key | Values | Effect |
| --- | --- | --- |
| `domain` | `personal` or `work` | the base's few domain-keyed choices (`.chezmoiignore`: two home-only items are not deployed under `work`) |
| `overlayRepo` | git URL of the private source | where `chezmoi-overlay` clones it from |
| `skipSkills` | list of base skill names | those skills are not deployed on this machine (an already-deployed one stays until removed by hand) |
| `dpi` | number, Linux only | X11 `.Xresources` |

```toml
[data]
    domain = "work"
    overlayRepo = "https://git.example.com/me/dotfiles-overlay.git"
    skipSkills = ["brew-and-brewfiles"]
```

## Shell

The base's zsh files source a private file at the end of each stage, if it exists.

| File | Sourced by | Put here |
| --- | --- | --- |
| `~/.dotlocal/zshenv` | `~/.zshenv`, every zsh (scripts, ssh, GUI-launched shells) | environment variables and `PATH` additions the domain needs everywhere |
| `~/.dotlocal/zprofile` | `~/.zprofile`, login shells only | login-time actions |
| `~/.dotlocal/zshrc` | `~/.zshrc`, interactive shells, after oh-my-zsh and the base's tools load | aliases, functions, completions, and `FLEET_TAG` |

`FLEET_TAG` is the short machine marker at the head of the prompt (`[w]`, or `[ssh:w]` over ssh).
Without it the prompt uses the host name's first letter.

```zsh
# ~/.dotlocal/zshrc
case ${HOST%%.*} in
  my-laptop) FLEET_TAG=L ;;
esac
alias k=kubectl
```

Not changeable from here: the oh-my-zsh plugin list (oh-my-zsh has already loaded), and the
variables the base also renders for the desktop session (`session_env` in `.chezmoidata.yaml`).

## Git

`~/.gitconfig` includes `~/.dotlocal/gitconfig` as its LAST line, so a private value overrides the
base's for any single-valued key. The private file carries the domain's identity and anything it
needs different.

```ini
# ~/.dotlocal/gitconfig
[user]
    name = Your Name
    email = you@example.com
    signingkey = ~/.ssh/id_ed25519.pub
[commit]
    gpgsign = true            # with gpg.format = ssh from the base: commits signed with that key
[ai-coauthor]
    enabled = false           # this domain adds its own AI attribution
```

`~/.dotlocal/allowed_signers` (stub in the skeleton) lets `git log --show-signature` verify the
domain's signatures. The commit hooks, and how to switch any of them off from this file, are in
[`architecture.md`](architecture.md#switching-a-hook-off).

## SSH

`~/.ssh/config` starts with `Include ~/.dotlocal/ssh/config`. ssh takes the FIRST value it finds for
each option, so the private file's hosts and settings win over the base's `Host *` defaults.

```sshconfig
# ~/.dotlocal/ssh/config
Host build
    HostName build.internal.example.com
    User me
```

## Packages (macOS)

The base `Brewfile` evaluates `~/.dotlocal/Brewfile.role` if it exists, so one `brew bundle`
installs both and `brew bundle cleanup` sees the union. The role file only ADDS: it uses the same
Brewfile syntax and must never evaluate the base itself.

```ruby
# ~/.dotlocal/Brewfile.role
brew "awscli"
cask "slack"
```

## Bootstrap stages

`bootstrap-mac.sh` runs every `~/.dotlocal/bootstrap.d/*.sh` in lexical order after the apply. Name
them with a number prefix (`20-mount.sh`, `60-services.sh`). Each runs under `sh`; the base prints
"core only" when the directory is absent.

## Claude Code

### Instructions: `~/.dotlocal/claude/CLAUDE.md`

The base's `~/.claude/CLAUDE.md` holds the standards true on any machine and imports this file
last, so the domain adds who the user is, its machines, and its own rules. Claude Code skips a
missing import.

### Settings: `~/.dotlocal/claude/settings-declared`

An EXECUTABLE that prints one JSON object. The base's `modify_settings.json` merges its own block,
then this object's `declared` keys, over the live `~/.claude/settings.json`; the later wins, and
every key neither declares is left as the app wrote it. A script rather than a JSON file so a reason
can sit beside each entry. `CLAUDE_SETTINGS_FRAGMENT` points at another path.

```bash
#!/usr/bin/env bash
cat <<'EOF'
{
  "declared": {
    "env": { "HTTPS_PROXY": "http://proxy.example.com:8080" },
    "sandbox": { "enabled": true }
  },
  "retiredHooks": []
}
EOF
```

Rules the merge imposes:

- **Arrays replace.** A declared array overwrites the live one, which is right for lists the app
  never writes (sandbox paths, deny rules, hooks).
- **Never declare `permissions.allow`** (the app appends to it as permissions are granted; declaring
  it would discard them) **or `model`** (an enforced default belongs in the machine's managed
  settings).
- **`retiredHooks`** lists hook script names to remove from every event: the merge can only add, so
  a hook dropped from `declared` would otherwise keep firing.
- Managed settings (`/etc/claude-code/managed-settings.json`, or the macOS equivalent) outrank this
  file; a key they enforce cannot be changed from here.
- A fragment that fails or prints anything but a JSON object is skipped with a warning; the base's
  block still applies.

The base's apply runs this fragment, so after the private layer changes it, re-apply the base's
target: `chezmoi apply ~/.claude/settings.json`.

### Skills: `~/.dotlocal/skills/<skill>.md`

Some base skills end by pointing at a fragment with this domain's specifics (its hosts, layout,
incidents). Currently: `brew-and-brewfiles`, `claude-config-layers`, `cross-platform-tooling`,
`dotfiles-layout-and-bootstrap`, `dotfiles-update`, `fault-isolation`, `naming-build-tasks`,
`overlay-doctor`, `register-standard`, `vetting-tooling`, `working-across-repos`,
`working-in-worktrees`. A missing fragment means the generic skill stands alone. Write it as plain
markdown that completes the skill; do not restate it. Leave a skill out on one machine with
`skipSkills`.

### Skills from other repositories

A skill can be installed from a repository rather than written here, pinned to a tag so it cannot
change unreviewed. There are two lists, one per layer, and they work the same way:

| List | Fetched by | Holds |
| --- | --- | --- |
| `skill_externals` in the base's `.chezmoidata.yaml` | chezmoi, as a release archive from public GitHub, checked by `run_onchange_after_verify-skill-externals.sh` | public third-party skills every machine gets |
| `~/.dotlocal/skill-externals.yaml` | `skill-externals-sync`, with plain git and this machine's own credentials | the domain's own skills, private repositories included |

The private list uses the same fields, plus `url` and `ref` for a repository that is not on GitHub or
a tag not named `v<version>`:

```yaml
skill_externals:
  - name: team-runbook              # must equal SKILL.md's `name:`; also the directory name
    repo: my-org/team-skills        # -> https://github.com/my-org/team-skills.git
    version: "1.4.0"                # -> tag v1.4.0; checked against SKILL.md's `version:` if present
    subtree: skills/team-runbook    # the directory holding SKILL.md ("" for the repository root)
  - name: other-skill
    url: https://git.example.com/team/other.git
    ref: release-2026-09
    subtree: ""
```

What `skill-externals-sync` does, per entry:

- installs the subtree into `~/.claude/skills/<name>`, staged and swapped so a session never sees a
  half-copied skill, and records it in `~/.local/state/skill-externals/installed.tsv`;
- does not fetch again while the recorded url and ref match, so it costs no network on an ordinary
  apply;
- refuses, keeping whatever was installed before: a name that is not a plain skill name, a subtree
  outside the repository, a fetched tree with no `SKILL.md` at the subtree's root, a frontmatter
  `name` that differs from the entry, a frontmatter `version` that contradicts the pin, and any
  existing `~/.claude/skills/<name>` it did not install (a base skill or a public external is never
  overwritten);
- uninstalls a skill removed from the list, and only skills it recorded;
- treats an unreadable list as an error and changes nothing, rather than as an empty list.

One failed entry never stops the others or fails the apply. It runs after every base apply; because
the private layer applies after the base, the overlay also re-runs it when its list changes
(`run_onchange_after_sync-skill-externals.sh` in the skeleton). Run it by hand with
`skill-externals-sync`, and `skill-externals-sync --status` lists what it installed.

## Worktrees

### `~/.dotlocal/worktrunk.toml`

`wt-config-gen` builds worktrunk's only config file from three sources: the base's `base.toml`, this
fragment, and each project's `worktrunk:` block in the manifest. Two rules, both checked: only
`base.toml` may hold top-level keys, so the fragment holds TABLES only; and no two sources may open
the same table. The generated file is overwritten on every run; edit the sources. `WT_GEN_FRAGMENT`
points at another path.

### `~/.dotlocal/hooks/post-worktree-create`

`git-clone-worktree` runs it, if it is executable, with the new worktree's absolute path. Advisory
only: its exit status is ignored, so it can report but never block a worktree's creation.

## The publish guard

`leak-guard` runs on every commit and push and passes everything until the domain says what to keep
out. Its four files under `~/.dotlocal/` (`git-leak-markers`, `git-leak-sensitive`,
`git-leak-policy`, `git-leak-allow`) are described in the
[skeleton README](../../overlay-skeleton/README.md#optional-the-leak-guard); they are not stubbed,
because a placeholder pattern would start refusing commits. In short:

- **Markers** are identifiers that belong only in the domain's notes repository: its program ids
  (a register entry such as `ABC-0012`) and paths into that repository. Blocked everywhere except
  repositories whose manifest entry says `leakPolicy: notes` or `internal`.
- **Sensitive terms** are words that must not reach a public destination: internal hostnames,
  service names. Matched case-insensitively. Allowed in `private`, `notes` and `internal`
  repositories' commits; a `private` repository still cannot push them to a destination
  `git-leak-policy` does not declare private. Blocked everywhere else.

Each pattern file holds ONE extended regex on its first non-comment line; put alternatives in it
with `|`. Test a pattern before relying on it:

```sh
printf 'a line that mentions build.internal.example.com\n' \
  | grep -Ei "$(grep -vE '^[[:space:]]*(#|$)' ~/.dotlocal/git-leak-sensitive | head -1)"
```

Then declare every repository's `leakPolicy` in the manifest and run `hook-doctor check`, which plants
the `probe-marker=` token from `git-leak-policy` to prove the guard refuses it.

## The repository manifest

`~/Devel/mani.yaml`, the domain's repository set and the declarations about each repository:
[`fleet-manifest.md`](fleet-manifest.md).

## Spelling (Neovim)

nvim's spell files are `~/.config/nvim/spell/private.utf-8.add` (the domain's words) and
`shared.utf-8.add` (the base's). `zg` adds a word to the private list, and `spell-capture` copies it
back into the private source so the next apply keeps it. The skeleton has a stub.

## Checking it

| Check | Run | Tells you |
| --- | --- | --- |
| `setup/overlay-doctor` | from the base checkout, after changing either layer | required private pieces present and filled, every private file has a recorded reason, no file owned by both layers, the manifest's schema |
| `setup/overlay-doctor --machine` | on a machine | git, tools and Claude Code on that machine |
| `fleet-decl --check` | after editing the manifest | the manifest's declarations |
| `hook-doctor check` | after configuring the guard | each configured git hook is live, and the guard refuses a planted marker |
| `chezmoi diff`, `chezmoi-overlay diff` | before applying | what an apply would change |

## What a private layer cannot change

Fixed in the base on purpose, because they are the same on every machine: the oh-my-zsh plugin list,
the tmux plugins, the secret-scan floor (`~/.config/gitleaks/floor.toml`; a repository may add its
own `.gitleaks.toml`), and Brewfile removals (the role file only adds). A domain that needs one of
these changed proposes it to the base.
