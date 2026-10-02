# The knowledge base (`kb`)

`kb` manages a knowledge base: a directory of markdown records with YAML frontmatter and typed links
between them. It scaffolds records with valid frontmatter, lints them, and generates the derived
views, including the **projection**: the rules every agent session should load, flattened into one
file that `~/.claude/CLAUDE.md` imports. `kb help` lists every command.

A domain usually keeps its KB inside its notes repository (`<notes>/kb/`), so records are versioned
and reviewed like the rest of its notes.

## What a record is

Each record is one markdown file with this frontmatter (`kb new` writes it; do not hand-author it):

| Field | Values | Meaning |
| --- | --- | --- |
| `name` | the file's slug | unique across the KB |
| `type` | `standard`, `decision`, `context`, `research`, `register` | decides the directory: `standards/`, `decisions/`, `context/`, `research/`, `registers/` |
| `domain` | `universal`, or a domain slug from the config | `universal` applies to every session; a domain slug to one project area |
| `tier` | `0`, `1`, `2` | 0: in the always-on projection, loaded by every session. 1: in a domain's slice. 2: read on demand only |
| `sensitivity` | `public`, `internal`, `private`, `restricted` | `kb project --max-sensitivity` leaves out anything above the level given |
| `status` | `draft`, `active`, `retired` | |
| `related`, `depends-on`, `supersedes` | lists of record names | forward edges; `kb index` writes the backlinks |
| `updated` | a date | |

Tier 0 is expensive: it is read by every session, every time. Put a rule there only if its failure
cannot be noticed from inside the task; procedure that a situation announces belongs in a skill.

## Standing one up

1. **Mark the root.** Create the directory and a `kb.toml` in it. `kb.toml` may set
   `projection_max_bytes`, the size budget the Tier-0 projection must stay under:

   ```toml
   # <notes>/kb/kb.toml
   projection_max_bytes = 40960
   ```

2. **Configure the machine.** The private layer deploys `~/.config/kb/config.toml`. Paths are
   absolute; `kb` does not expand `~`, so template them with chezmoi:

   ```toml
   root = "/home/me/Devel/work/journal/kb"      # the default KB, so `kb` works from anywhere

   [instance.work]
   root = "/home/me/Devel/work/journal/kb"

   [domain.platform]                               # every valid `domain:` value besides `universal`
   [domain.billing]
   ```

   `kb` finds its root by, in order: `--kb-root`, `KB_ROOT`, this config file, then walking up
   from the current directory to a `kb.toml` or `.kb/`. `kb debug-root` prints what it resolved.

3. **Guard it.** `kb install-hooks <notes-repo>` adds a pre-commit that runs `kb lint` and fails when
   `index/` or the projection is stale, so a commit can never carry a hand-edited derived file.

4. **Write records** with `kb new <type> <slug>`, edit the body, link with `kb link A --related B`,
   then regenerate: `kb index` and `kb project --max-sensitivity internal`. Commit the records and
   the regenerated `index/` together.

5. **Load the projection in every session.** `kb project` writes `index/projections/CLAUDE.md`
   (also `AGENTS.md` and `GEMINI.md`). The private layer's `~/.dotlocal/claude/CLAUDE.md`, which the
   base's `~/.claude/CLAUDE.md` imports, imports it in turn:

   ```markdown
   ## Standing rules
   @/home/me/Devel/work/journal/kb/index/projections/CLAUDE.md
   ```

   A session reads this at start, so a KB change reaches running sessions only when they restart. On
   a machine without the notes repository the import resolves to nothing and sessions carry on
   without those rules.

## Day to day

| Task | Command |
| --- | --- |
| a new record | `kb new standard <slug>` (or `decision`, `context`, `research`, `register`) |
| a memory file becoming a record | `kb promote <file> --type T --domain D [--tier N]` |
| a link | `kb link A --related B` (`--depends-on`, `--supersedes`) |
| rename, keeping every link | `kb rename A C` |
| retire | `kb retire A` (marks it and strips inbound links) |
| check | `kb lint` |
| regenerate | `kb index`, `kb project --max-sensitivity internal`; a domain's slice: `kb project --domain D` |
| in a pre-commit or CI | `kb index --check`, `kb project --check` (exit 1 on drift, write nothing) |

`kb project --domain D` writes a domain's Tier-1 slice under the KB's own
`index/projections/domains/D/`, never into a repository root: each repository's `AGENTS.md` and
`CLAUDE.md` belong to that repository.

A per-instance record template at `<root>/.templates/<type>.md` replaces the built-in one
(`__NAME__`, `__TYPE__` and `__UPDATED__` are substituted).
