---
name: filing-bug-reports
description: Use before drafting, staging or sending any bug report, feature request or feedback to an outside project or vendor — a GitHub issue upstream, Claude Code's /feedback, a vendor support ticket — and when deciding whether to attach a transcript, log, config or screenshot. Covers reproducing the bug in an isolated scratch environment first, writing the report from that clean reproduction with generic names only, never attaching a session transcript, and leaving the sending to the human.
---

# Filing bug reports: reproduce clean, report only the reproduction

A bug found during real work arrives wrapped in real context: project names, paths, people, the
session's whole conversation. None of that belongs in a report to an outside party, and a report
built from it is also a poor report, because the maintainer cannot tell which parts matter.

## The procedure

1. **Reproduce it in isolated scratch.** Use a throwaway directory made for the purpose: a fresh
   git repository if the bug needs one, with generic names (`@acme/source`, `example.com`,
   `user@example.com`). Put it somewhere your session is allowed to delete afterwards, such as
   `$TMPDIR`, so cleanup does not need anyone else's help.
2. **Run a control.** Change only the one thing you believe triggers the bug, and show that the
   control behaves correctly. A reproduction without a control shows *a* failure, not *this*
   failure's cause.
3. **Write the report from the reproduction alone:** the version, the platform, the minimal
   command or steps, what happened (quote the exact message), the control, and what you expected.
   Nothing from the original project: no repository names, paths, internal ids, timestamps, or
   tool-call ids from real sessions.
4. **Never attach a session transcript.** A transcript carries everything the session had in
   context, including personal and project material the report never needed. When a tool offers to
   include one (Claude Code's `/feedback` does), decline it.
5. **The human sends it.** Posting to an outside party is outward-facing and can be neither
   unsent nor unindexed. Stage the text and let the human file it.
6. **Delete the scratch reproduction** when the report is staged.

## Why "clean first" is not optional

- **It proves the bug is real and general.** A failure seen only inside one project may come from
  that project's configuration. A clean reproduction rules that out.
- **It keeps scope tight.** The maintainer gets the smallest thing that fails, not a tour of your
  setup.
- **It is the only way to leave personal context behind.** Redacting a real report after the fact
  misses things; a report written from scratch has nothing to redact.
