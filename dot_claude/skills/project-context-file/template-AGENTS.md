# <repo name>

<What this repository is, in one sentence.> <Who owns it; whether it is public, private or
client-owned; and what must never land in it.>

## Tasks

Entry point: `<just | npx nx | make>`. Live list: `<just --list | npx nx show projects | make help>`.

- `<setup task>`: install tooling and hooks, after a clone or pull
- `<check task>`: the fast check, before every commit
- `<ci task>`: the full gate

## Layout

- `docs/` follows the standard layout; `docs/README.md` indexes it.
- <`docs/<subject>/`: each project-specific docs directory, one line each>
- <only the top-level directories whose purpose is not obvious from their names>

## Deeper context

- Decisions in `docs/adr/` win over any summary, including this file.
- <`docs/reference/<topic>.md`: read before <the situation that calls for it>.>

## Rules

- <A rule no hook or gate can enforce, with one clause of why.>

## Writing here

**Prose voice: <technical | plain | ...>.**
