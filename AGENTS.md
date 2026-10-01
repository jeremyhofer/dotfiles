# dotfiles: the public base

The public base layer of Jeremy Hofer's chezmoi dotfiles: generic mechanisms that every machine,
home or work, deploys unmodified, while each domain's private layer supplies its own content. It is
published on GitHub, so nothing private lands here, in a file or a commit message: no secrets, no
hostnames or remote URLs, no private repository names or paths, no decision-record or ticket ids, no
details of how any one machine is set up.

## Tasks

No task runner; the commands are plain.

- `sh tests/run-all.sh [filter]`: every suite, or those whose name contains the filter. The
  pre-commit hook runs it when a shipped file is staged.
- `chezmoi diff`, then `chezmoi apply`: deploy this source to the machine. The private layer is a
  second instance: `chezmoi-overlay diff`, `chezmoi-overlay apply`.
- `sh setup/overlay-doctor`: is this machine's private layer complete and disjoint from the base;
  `--machine` assesses the machine itself.
- `context-lint`: this file and `docs/`.

## Layout

- `docs/` follows the standard layout; `docs/README.md` indexes it.
- Everything else at the root deploys to `~` under chezmoi's source-state names (`dot_`,
  `private_`, `executable_`, `.tmpl`, `run_*`, `modify_`); `chezmoi target-path <source>` gives a
  file's target. `.chezmoiignore` keeps the repository's own files from deploying.
- `setup/`: adoption and audit tools, run from the checkout before anything is applied.
- `overlay-skeleton/`: what a new private layer is scaffolded from.
- `.chezmoitemplates/`: fragments composed into templates, named `<topic>.<scope>`.

## Deeper context

- `docs/reference/architecture.md`: read before adding a file, a tool or a seam. How the layers
  fit, how content reaches a machine, and where each kind of content belongs.
- `CHANGELOG.md`: read before a change an adopted machine must act on. Its head explains the ACTION
  convention.
- `setup/README.md`: read before bringing a new or already-configured machine into this setup.
- Skills: `dotfiles-layout-and-bootstrap` (which layer a file belongs in), `dotfiles-update`
  (catching a machine up), `overlay-doctor` (the private layer's checks), `cross-platform-tooling`
  (any script that runs on both Linux and macOS).

## Rules

- **Describe the general case.** A domain's leak guard refuses only the terms that domain lists, so
  write every comment, document and commit message as if read by a stranger: what the thing does and
  why, with no machine, person, project or private document named.
- **Mechanism here, content by seam.** A domain's content reaches a base file only through a seam:
  a `~/.dotlocal/` fragment the base file includes or imports, chezmoi data, the repository manifest
  read by `fleet-decl`, or an environment variable with a default. A base file works when the domain
  supplies nothing.
- **One owner per target.** The base and a private layer never manage the same file. Run
  `sh setup/overlay-doctor` after adding a target; it reports a collision with the layer it can see.
- **Edit the source, never the deployed copy**; the next apply overwrites it.
- **A change an adopted machine must act on gets a `CHANGELOG.md` entry**, marked ACTION when a
  private layer has to change. No check yet.
- **Vary by file, not by inline conditional.** Per-domain or per-OS content goes in `.chezmoiignore`
  or a `<topic>.<scope>` fragment, so a diff shows the scope in the file name.

## Writing here

**Prose voice: technical.** Pass `--voice technical` to `avoid-ai-writing`.
