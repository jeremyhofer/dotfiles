---
name: spellcheck-standard
description: Use when adding, changing or reviewing a spellchecker in a project (cspell, codespell, typos, Vale), editing `.us-spelling-lint`, `flagWords`, a `cspell.config` or a `codespellrc`, running `us-spelling-lint`, or when a commit is refused for a British spelling. Also fires on "should I add a spell check", "cspell or codespell", and on adding a word to an allow-list to make a check pass. Covers the two different checks (American spelling vs general spelling), why list-based and dictionary-based checkers fail in opposite directions, what may be excluded or allowed and why a name you own is renamed instead, and how to choose and configure a project's general spellchecker.
---

# Spellcheck: one American-spelling check from the machine, general spelling by project

**Two different checks get called "spellcheck", and mixing them is how a gate gets switched off.**
The *American-spelling check* refuses a British form (`behaviour`) where an American one exists. It is
one rule, the same in every repository. *General spelling* catches typos (`recieve`). How much that is
worth depends on the project, so it is each project's choice.

## 1. Why the two kinds of checker matter

- A **list-based** checker (codespell, typos) carries known misspellings and their corrections and
  flags only those. Few false alarms, no upkeep; a misspelling not on its list passes.
- A **dictionary-based** checker (cspell, an editor's spell mode) knows the valid words and flags
  everything else, so every name and term the repository uses must first be added to a word list.
  Run over a repository of notes it flags thousands of names, tools and shell terms.

So a list-based tool is a cheap typo net, and a dictionary-based one is worth its upkeep only where
the prose is published and every word matters.

## 2. The American-spelling check is `us-spelling-lint`, and nothing else

`us-spelling-lint` judges only the lines a commit **adds** (old text never fails it), using codespell's
British-to-American dictionary plus a short list of forms that dictionary lacks. A configured git hook
runs it, at commit and on the commit message, in the repositories this machine's fleet record lists;
a repository wires nothing itself and does not opt out. Without the fleet record the hook passes
silently. Without codespell installed it refuses, because a gate that passes when its engine is
missing is no gate.

**No other tool carries the rule.** Do not put British forms in cspell `flagWords` or forbidden words,
or `en-GB_to_en-US` in a project's codespell `builtin` list, and keep cspell at `language: "en"`.
Reasons: the list of British forms would be copied into every configuration in each tool's syntax and
drift, and cspell matches a forbidden `!word` entry by case while its dictionaries ignore case, so
`Behaviour` passes until every capitalized form is listed too. A British form the tool lacks is added
to `us-spelling-lint`, once, for everyone.

### `.us-spelling-lint` (one per repository, at the root, monorepos included)

```
# comment
exclude: docs/archive/
include: *.ts
allow: aria-labelledby
```

- `exclude: <path prefix>`, repeatable. May skip only: text a commit carries **forward** unchanged
  (an archive, a closed record); text **not authored here** (vendored or generated files, raw
  captures, fixtures that copy text verbatim); a file that **is a quotation**. Do not exclude
  handoffs, research notes or decision records: what a commit adds to them is new prose.
- `include: <glob>`, repeatable. Adds files to the default `*.md`. A glob without a slash matches the
  name at any depth. In an included code file the whole added line is checked, identifiers too.
- `allow: <word> [<word>...]`, repeatable. Accepted everywhere. An unknown key is an error.
- One occurrence: end the line with `<!-- codespell:ignore word -->` (markdown) or
  `# codespell:ignore word` (a comment style the file allows).

**What may be allowed is only a name the repository cannot change:** a web-standard or third-party
name (`aria-labelledby`), a proper noun (a band, a venue, `Lincoln Theatre`), or a quotation's own
spelling. **A name the project owns is renamed**, with its references, any data migration and any
recorded baseline: an identifier, file or directory name, data key, test title, or vocabulary that
is British gets its American form, never an exception. A name is matched as a whole word in any case.
**A common English word is never allowed to silence one name**: allowing it hides every real use of
that word, and the exclusion is wrong at the scale of the repository when the problem is one name.
Skip the one file, or use the one-line comment instead.

### When a commit is refused

1. Read the finding (`path:line: word ==> suggestion`). If it is a real British spelling in prose,
   fix the spelling.
2. If it is a name this repository owns, rename it.
3. If you cannot change it (third-party, proper noun, quotation), allow it: the one-line comment for a
   single place, `allow:` for a name used widely, `exclude:` for a file that is a quotation.
4. If a British form slipped through, that is a gap in `us-spelling-lint`'s list; report it there.

## 3. General spelling: whether, and with which tool

Optional per project. If the project checks it, use one of two tools, and **one tool per file**
(a repository running both scopes them to disjoint paths):

| Choose | When |
| --- | --- |
| **cspell** | Published or user-facing prose; the project has a Node toolchain; a word list in the repository is worth keeping. Install from the lockfile. Put raw data, snapshots, generated output and frozen records in `ignorePaths`. |
| **codespell, default dictionary** | A low-upkeep typo net where a word list is not worth maintaining. |

Run it on **staged files at commit time**; a whole-tree run in a lint lane is a backstop, never the
only run (a gate behind a lane goes dark when an earlier step in the lane fails). In a monorepo the
choice is the repository's, with one configuration at its root.

cspell fragment (keys as used in a working `cspell.config.mjs`):

```js
export default {
  version: "0.2",
  language: "en",          // never a British locale; never British flagWords
  words: ["Webalizer"],    // names; give each a comment saying why
  flagWords: [],
  ignorePaths: ["**/*.json", "**/__snapshots__/**"],
  useGitignore: true,
};
```

codespell fragment (`.codespellrc` or `[tool.codespell]` in `pyproject.toml`; check `codespell --help`
for keys, they mirror the long options):

```toml
[tool.codespell]
skip = "*.lock,*.svg,node_modules,data"
ignore-words-list = "finmodel,roth"
quiet-level = 2
```

Keep `ignore-words-list` to words with no real-word collision: allowing a short token that is also
a real misspelling's target hides real typos tree-wide; skip the one file instead.

## 4. Who provides what

The machine provides codespell and the hook. The project provides its general spellchecker (from its
lockfile) and its configuration. An editor's spell mode and its word lists are advisory and gate
nothing.

If `~/.dotlocal/skills/spellcheck-standard.md` exists, read it: it is this domain's half (which
repositories the hook covers and which general spellchecker each runs today). If it does not, this
machine has no fleet-specific layer and this skill stands alone.
