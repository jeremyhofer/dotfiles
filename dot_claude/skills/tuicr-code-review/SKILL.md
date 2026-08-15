---
name: tuicr-code-review
description: Use when reviewing code locally with tuicr, when helping drive it (what to pass to review a branch, a merged range, uncommitted work, or a PR), and — most often — when picking up a review a human already made so the comments can be acted on. Also use when asked to leave review comments for a human to read, when a session slug will not resolve, or when `tuicr review add` reports "session ... was not found". Covers the read/write handoff contract, the comment classifications and what each obliges, and the traps in the session store.
---

# Reviewing code with tuicr

`tuicr` is a vim-keybinding code-review TUI. The important thing for an agent is that it keeps
**persisted review sessions as JSON**, with a CLI to read and write them — so a human's review and
an agent's follow-up are the same artifact, not a copy-paste of prose.

## The handoff, in one picture

```
human opens the TUI, reviews, leaves classified comments   -> session persisted as JSON
agent: tuicr review list --all                             -> find the session
agent: tuicr review comments --session <slug|path>         -> read the review as JSON
agent does the work
agent: tuicr review add --session ... --username "<agent>" -> reply in the same session
human reopens the TUI and sees the replies inline
```

## The constraint that governs everything: an agent CANNOT start a review

Sessions are created by the **TUI**, which is interactive. `tuicr review add` against a session that
does not exist fails with:

```
Error: Invalid input: session 'local' was not found for repo <path>.
```

So the sequence is always **human first, agent second**. If asked to "review this branch with tuicr"
with no existing session, say that the human needs to open it first — and offer a normal code review
in the meantime. Do not try to synthesise a session file; the store is an implementation detail.

## Reading a review

```zsh
tuicr review list --all                     # every session on the machine, as JSON
tuicr review list --repo /path/to/checkout  # just this checkout's (and its origin's PR sessions)
tuicr review comments --session <slug-or-path>
```

`list` returns `slug`, `kind` (`local`/`pr`), `path` to the session JSON, `updated_at`,
`comment_count`, `file_count` and `active`. `comments` returns an array of:

| Field | Meaning |
| --- | --- |
| `location` | `path:line`, or `review` for a review-level comment |
| `path` · `start_line` · `end_line` · `side` | where it anchors (`side` is `old`/`new` in the diff) |
| `comment_type` | the classification — **this is the routing key**, see below |
| `lifecycle_state` | `local_draft` until submitted to a forge |
| `content` | the human's actual words |

**Two resolution traps:**

- **A slug resolves relative to `--repo`, which defaults to the current directory.** A slug listed by
  `--all` will *not* resolve if you are standing somewhere else — it fails with the same
  "session not found" error as a genuinely missing session, which is misleading. **Prefer the `path`
  from `list`**: a JSON path resolves on its own, from anywhere.
- **`--session <path>` is a LOCATOR, not a sandbox.** Copying a session file somewhere and writing to
  the copy still mutates the **canonical** session — the path identifies which session, it does not
  redirect the write. There is no scratch mode, and no `remove` subcommand, so a comment added by
  mistake has to be edited out of the store's JSON by hand. Treat every `add` as landing in the real
  review.

## What each classification obliges you to do

The classifications are configured with definitions precisely so an agent can route by them. Read
`comment_type` and act accordingly — do not treat every comment as a task:

| Type | Definition | What it means for you |
| --- | --- | --- |
| `issue` | must fix before merge — a correctness, security, or contract defect | **Do it.** Blocking. |
| `suggestion` | a concrete improvement the author should consider; not blocking | Do it or reply saying why not. |
| `nit` | small optional style/polish tweak; safe to ignore | Batch these; do not spend a round trip each. |
| `question` | ask for clarification; may become a follow-up task | **Answer it — do not silently "fix" it.** A question answered with a code change loses the question. |
| `praise` | positive callout; a pattern worth repeating | No action. Do not reply "thanks". |
| `none` | unclassified | Judge from the content; when unsure, ask. |

## Writing back

```zsh
tuicr review add --session <path> \
  --target-file src/thing.ts --line 42 \
  --type note --username "<your model name>" \
  "Fixed in <commit>: switched to the config form you described."
```

- **Always pass `--username`.** tuicr's own help asks agents to, so human and agent comments are
  visually distinguishable in the TUI. Without it everything is stamped `user` and the human cannot
  tell who wrote what.
- Omit `--target-file` for a review-level comment; add `--end-line` for a range.
- **`--type` is not validated** — an unknown value is accepted silently, so a typo becomes a comment
  nobody can route. Use one of the configured ids.
- `--input` takes literal JSON, `@file`, or `-` for stdin, which is the sane path for adding several
  comments at once.

## Driving the TUI (when helping a human start one)

| Situation | Command |
| --- | --- |
| Review a branch against its base | `tuicr -r main..HEAD` |
| Review **already-merged** work | `tuicr -r <sha>..<sha>` or `-r <merge-sha>^..<merge-sha>` |
| Review uncommitted work | `tuicr -w` (combine with `-r` to include commits too) |
| Narrow to one path | `tuicr -r … -p src/thing.ts` |
| Whole tree, not a diff | `tuicr -A` |
| Annotate a file with no VCS at all | `tuicr --file <path>` |
| A GitHub PR / GitLab MR | `tuicr pr <number-or-url>` |

`--stdout` exports to stdout instead of the clipboard, which is what you want when capturing an
export programmatically.

## How you can tell it went wrong

- **`session '<x>' was not found for repo <path>`** — either no session exists yet (the human has not
  reviewed), or you used a slug from a different checkout. Try the `path` from `tuicr review list
  --all` before concluding it is missing.
- **Your comment does not appear in the TUI where expected** — check `--target-file` and `--line`; a
  comment with no target becomes a review-level comment rather than an error.
- **The human cannot tell your comments from their own** — you omitted `--username`.
- **You answered a `question` by changing code and saying nothing** — the question is still open from
  their side, and the next review round will raise it again.
