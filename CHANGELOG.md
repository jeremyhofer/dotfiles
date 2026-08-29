# Changelog — dotfiles base

Changes that an **already-adopted machine** has to know about: anything that changes the *shape* of
the setup, moves or renames a file, or adds a piece the private overlay must now supply.

This is **not** a commit log. Most commits never appear here. An entry earns its place only if
pulling it can leave a machine broken, silently different, or newly non-compliant.

## How to use it

After pulling the base (or the overlay), read the entries dated **after your last apply**, then:

```sh
git -C ~/.local/share/chezmoi log -1 --format='%h %ad' --date=short   # what you have now
chezmoi diff                       # what the base would change
chezmoi-overlay diff               # what the overlay would change (separate instance)
sh ~/.local/share/chezmoi/setup/overlay-doctor   # is the overlay still compliant?
```

Entries marked **ACTION** need something from you — usually a change in the *private overlay*, which
no base update can make for you. That asymmetry is the whole reason this file exists: the base
propagates automatically, the overlay does not, and a machine can therefore end up carrying a base
that expects a piece its overlay never grew.

Entries are newest first.

---

## 2026-08-29

**ACTION (KB repos only) — `kb install-hooks` now writes a wider hook; re-run it to pick that up.**
`kb` 0.3.0 adds `kb index --check`, the missing sibling of the existing `kb project --check`, and
the generated pre-commit now runs all three checks (`lint`, `project --check --if-present`,
`index --check --if-present`) instead of `lint` alone. An already-installed hook is NOT rewritten
by pulling the base — it is a file in each repo's `.git/hooks`, which chezmoi does not manage — so
a machine keeps the old lint-only hook until you re-run `kb install-hooks` in that repo. Nothing
breaks if you don't; you simply keep the old, narrower gate.

Why it exists: a KB has two derived outputs, and only one of them was checkable. Between
2026-08-17 and 2026-08-29 a KB on this fleet left `index/sources-of-truth.md` unregenerated —
missing an entry for a topic adopted in that window, plus four superseded descriptions — while
every projection stayed correct. The fresh layer is what hid the stale one.

**New: `portability-lint`** — finds GNU-only shell spellings that break on BSD/macOS. Run it in
any repo (`portability-lint`, or `portability-lint PATH...`); `--list` prints the rule table,
`--strict` fails on warnings too. Ten rules, each probed against a real macOS userland rather than
recalled: the in-place sed flag (no portable spelling exists — use temp-file + mv), `\t` inside a
sed/grep bracket expression, `stat -c`, `date -d`, `base64 -w`, `grep -P`, `find -printf`,
`timeout`, the `${TMPDIR:-/tmp}` trailing-slash trap, and a quoted `wc -l` compared as a string.

It deliberately does NOT flag `readlink -f` or `xargs -r`, which are commonly listed as GNU-only and
both work on modern macOS. An over-broad portability claim is worse than none — it sends you to
write a workaround for a problem you do not have, and costs trust in the rules that are real.

The two-spelling idiom (`stat -c … || stat -f …`) is the recommended FIX and is exempt, including
when the GNU attempt and the BSD fallback are on different lines. Suppress a genuine single-platform
case with `# portability-lint: ignore [rule,...]` on the line, or `# portability-lint: disable-file`.
Needs python3 (present on macOS and here); targets 3.9, which is macOS's system version.

ShellCheck does not overlap with this — it models shell syntax, not the userland of the commands you
invoke, and was verified silent (exit 0) on every rule above.

**Nothing ran the test suite — now something does.** The base ships 20 suites and had no
runner, no CI and no hook; they were run by hand, one file at a time, when someone remembered.
Added `tests/run-all.sh` (`sh tests/run-all.sh [filter]`, ~10s for all of them), and the git-hooks
installer now also writes a `pre-commit` into the source repo that runs it when anything under
`private_dot_local/bin/`, `setup/` or `tests/` is staged. Docs- and config-only commits are not
taxed. Escape hatch for a deliberate WIP commit: `SKIP_BASE_TESTS=1 git commit …`.

Judge suites by EXIT CODE, not by grepping for a `PASS` line — the suites do not share one
convention (`test-git-snapshot.sh` ends in `passed 13, failed 0`), and an ad-hoc grep-based runner
reports it as failing while it is green. That misreport happened on the first whole-suite run.

**Fixed: a tracked symlink in the base had been dangling since the `naming-build-tasks` skill moved
to the private layer.** The move was deliberate; the base's pointer at it was simply not removed
with it. The only symptom was `chezmoi: stat …: no such file or directory` on stdout from
`chezmoi execute-template` / `chezmoi diff`, which silently corrupts the output of anything
capturing them. New `tests/test-repo-hygiene.sh` fails on any dangling TRACKED symlink.

`--check` remains STRICT by default (a KB with content and no generated output is drift).
`--if-present` downgrades "never generated" to a pass, and exists for the generic hook, which has
to work in a KB that has deliberately published nothing yet. A repo that always publishes should
gate with the strict form, which additionally catches a DELETED output.

---

## 2026-08-15

- **`chezmoi-overlay` is now a real script**, not a zsh function (`~/.local/bin/chezmoi-overlay`).
  It previously did not exist in non-interactive shells, so `ssh <host> 'zsh -ls'` reported
  "command not found". No action: the command behaves identically, and now also works over SSH and
  from scripts.
- **`nm-applet` no longer autostarts.** The fleet runs iwd + systemd-networkd + systemd-resolved, so
  the applet had nothing to manage; it is suppressed by `~/.config/autostart/nm-applet.desktop`
  (`Hidden=true`), which covers every WM rather than one config at a time. **ACTION only if a machine
  genuinely uses NetworkManager** — delete that file there.
- **`overlay-doctor` got stricter and more correct.** It now recognises required pieces authored as
  `.tmpl`, and enforces the disjointness rule it previously only stated: the same target *file*
  managed by both layers is now a `CONFLICT`. **ACTION:** re-run it; a machine that was quietly
  co-owning a file will now be told.

## 2026-08-01

- **Brewfile include direction corrected: the BASE includes the overlay's role file.** The earlier
  (superseded) shape had `Brewfile.role` `instance_eval` the base — the inversion. A machine still
  carrying the old shape double-evaluates. **ACTION:** in your overlay, `Brewfile.role` must contain
  *only* this domain's additions; delete any `instance_eval(.../chezmoi/Brewfile)` line from it.
  _(This is the change that reached a machine silently and had to be fixed by hand. It is the reason
  this changelog exists.)_

## 2026-07-25

- **The overlay must supply its own `.chezmoi.toml.tmpl`.** Overlay config is now rendered from a
  template the overlay provides, and it is enforced. **ACTION:** an older overlay without one is
  non-compliant — author it (the base's `overlay-skeleton/` shows the shape).
- **`Devel/mani.yaml.tmpl` is a required Tier-C overlay piece** (the fleet repo manifest).
  **ACTION:** author it in the overlay if missing; `overlay-doctor` will flag it.

## 2026-07-10

- **Private spell tier renamed** `personal.utf-8.add` → **`private.utf-8.add`**. **ACTION:** rename it
  in the overlay; the old name is no longer read.
- **Commit signing moved to the overlay.** The base no longer carries signing config. **ACTION:** the
  overlay's `gitconfig` must define `user.signingkey` (and `gpgsign` where this domain signs) — the
  doctor treats an identity without a `signingkey` as incomplete.
- **`overlay-doctor` added.** Run it after any base update to see whether the overlay still satisfies
  the current standard.

## 2026-07-09

- **The full leak-guard is overlay-owned**; the base ships only a generic pre-push floor. No action
  for a machine that already has the guard; a machine without one is unguarded **by design**
  (home-only), not broken.

## Earlier

Before this file existed, shape changes were communicated only by reading the diff. If you are
adopting a long-dormant machine, do not trust this file to be complete for that era — run
`overlay-doctor`, `chezmoi diff` and `chezmoi-overlay diff` and treat their output as authoritative.
