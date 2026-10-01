# dotfiles

**One public base for every machine I use, home or work. Each domain plugs in only what is its own.**

Jeremy Hofer's dotfiles, managed with [chezmoi](https://www.chezmoi.io). This repository is the
public half: shell, editor, git, Claude Code and a set of command-line tools, written so they work
on any machine. Identity, secrets, hosts and each domain's own context live in a separate private
layer that plugs into this one, and never appear here.

![managed with chezmoi](https://img.shields.io/badge/managed%20with-chezmoi-4B91E2)
![Linux and macOS](https://img.shields.io/badge/runs%20on-Linux%20%C2%B7%20macOS-555)
![tests on every commit](https://img.shields.io/badge/tests-on%20every%20commit-2DA44E)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/reference/architecture-dark.svg">
  <img src="docs/reference/architecture-light.svg" alt="Two chezmoi sources apply into one home directory. The public base supplies every mechanism: shell, editor, git, Claude Code configuration and tools. A private layer, one per domain and never published, supplies identity, secrets, hosts and its own context through four seams: fragment files under ~/.dotlocal, chezmoi data, the repository manifest and environment variables. System packages are installed first, underneath both, and checks run on every commit and on each machine." width="100%">
</picture>

## The idea

A dotfiles repository that mixes the generic with the personal either stays private or leaks.
This one splits them along a single line: **mechanism here, content there.** Anything true of any
machine (how the shell starts, how git hooks run, how Claude Code's settings are merged) lives in
this public base. Anything only one domain has (who signs commits, which hosts exist, which projects
are private) lives in that domain's private layer, a second chezmoi instance that plugs into the base
through four seams: fragment files under `~/.dotlocal/`, chezmoi data, a repository manifest, and
environment variables.

A machine with only this repository is a complete, generic machine. Add a private layer and it
becomes yours. [The architecture page](docs/reference/architecture.md) has the whole picture.

## What's inside

| | |
| --- | --- |
| 🐚 **Shell** | zsh with oh-my-zsh, tmux, and a prompt that tags which machine you are on |
| ✏️ **Editor** | Neovim on LazyVim, with diagram, PDF and LaTeX rendering |
| 🌿 **Git** | delta, sensible defaults, and hooks that run in every repository: a secret scan, a leak guard for each domain's private terms, a repository's own tracked gates, and a co-author trailer for commits an AI agent made |
| 🤖 **Claude Code** | global operating standards, a settings merge that coexists with the app writing the same file, a status line, and a library of agent skills loaded on demand |
| 🧰 **Tools** | linters for docs, comments, decision records and agent context files; doctors that check a machine's private layer and its git hooks; a knowledge-base CLI; worktree helpers. The full list is [`dot_claude/tooling.md`](dot_claude/tooling.md) |
| ✅ **Tests** | a suite per tool and script, run before every commit that touches one |

## Getting started

**A fresh machine:**

```sh
chezmoi init --apply jeremyhofer/dotfiles
```

chezmoi asks for the domain and the private layer's address (leave it blank for none), applies the
base, then clones and applies the private layer.

**A machine that already has configuration:** follow [`setup/README.md`](setup/README.md). It
audits what an apply would overwrite, backs it up, shows the diff and asks before changing anything.

**Starting your own private layer:** `sh setup/scaffold-overlay <dir>` copies
[`overlay-skeleton/`](overlay-skeleton/) with a stub for every piece, and `sh setup/overlay-doctor`
reports what is still missing.

## Keeping a machine current

```sh
chezmoi git -- pull --ff-only
chezmoi diff && chezmoi apply
chezmoi-overlay diff && chezmoi-overlay apply
```

Before applying, read [`CHANGELOG.md`](CHANGELOG.md) from the top down to your last update. It
lists only what an adopted machine has to know, and marks **ACTION** where a private layer has to
change too, because the base propagates on its own and a private layer does not.

## Repository map

```text
dot_*  private_dot_local/   deployed to ~ (chezmoi source-state names)
.chezmoitemplates/          shared template fragments, named <topic>.<scope>
docs/                       architecture and reference
setup/                      adoption and audit tools, run from the checkout
overlay-skeleton/           what a new private layer starts from
tests/                      the suites; tests/run-all.sh runs them
```

Working on the repository itself, as a person or an agent: [`AGENTS.md`](AGENTS.md) has the rules,
the commands and where to read first.
