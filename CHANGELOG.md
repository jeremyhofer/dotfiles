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

## 2026-08-31

**The zsh prompt now carries a one-character machine tag** — `[<tag>]` normally, `[ssh:<tag>]`
when the shell is an SSH session. Not an ACTION: the base ships the mechanism plus a generic fallback (the
first character of the short hostname), so it works with no overlay change.

**Optional overlay input:** the hostname → letter mapping is personal, so it is not in the published
base. Your private layer may set `FLEET_TAG` before the prompt is built to choose the letter.

Two things about the shape, so nobody "improves" them back: it is a bracketed LETTER rather than a
colour, because colour does not survive a monochrome terminal, a screenshot, a recording or a theme
change, and it is the first cue to fail a reader with a colour-vision or single-eye difference — the
colour here is decoration on top of a cue that already works without it. And SSH costs nothing: a
remote shell renders its prompt on the REMOTE host, so it tags itself correctly with no forwarding
and no client-side logic.

---

## 2026-08-30

**BREAKING IF YOU DO NOT PULL — the nvim `snacks` fork pin moved off sourcehut, and there is a
date on it.** sourcehut's terms now prohibit LLM-produced content and that forge is being vacated on
**2026-09-10**. This pin was the only thing in these dotfiles that would actually break: lazy.nvim
clones it on every machine, so left alone it fails on the next plugin install or on any fresh
machine — and it presents as *"Neovim is broken"* rather than as a forge shutting down, which is why
it earns a loud entry rather than a quiet fix.

It points at **github** rather than the self-hosted forge deliberately: this is cloned on a work
laptop where no personal account can be logged in, so the URL has to resolve as an anonymous,
unauthenticated HTTPS clone. That is the same constraint that already puts the public base there.
The `pending-upstream` branch was pushed to the github fork first — swapping the URL alone would
have failed on a missing branch, or, with the branch line dropped, silently fallen back to plain
upstream and reintroduced the image bug with nothing on screen to say why.

**Also nvim: the puppeteer browser-resolution block was deleted by accident and restored in the same
window.** If you pulled between those two commits, pull again. Without that block, puppeteer
downloads its own vendored Chrome (~150 MB) outside package management instead of using an
already-installed browser for mermaid rendering.

**ACTION (any machine you drive non-interactively — macOS especially) — `chezmoi-overlay` now
resolves the chezmoi binary itself, and an earlier "nothing pending" reading may have been false.**
It used to `exec chezmoi` bare. Over ssh on a Homebrew machine `/opt/homebrew/bin` is not on the
PATH that `.zshenv` builds, so the wrapper was reachable and its dependency was not: exit 127.

The quiet shape of that failure is why this is code rather than a note. A caller that FILTERS the
output — grepping for diff headers to see what is pending — gets an empty result and reads it as
"nothing pending, machine in sync", which is the exact inverse of the truth. Measured on the darwin
CI node: the overlay was three commits behind and reported no pending changes. It now resolves via
`command -v`, falls back to the usual prefixes, and exits 127 naming the PATH it searched.

*What to do:* re-run `chezmoi-overlay diff` and trust that reading rather than an earlier one taken
from a non-interactive shell.

**New: `ui-shot` and the `visual-review` skill — and `ui-shot` is already FROZEN.** It renders a page
headless and always produces TWO captures: the whole page, and the changed region at native scale.
The second is the entire point — a full-page screenshot rendered into a transcript is scaled down,
so a 1px border or a subtle divider is simply not present in what the reviewer sees, and "I looked
at it" becomes false confidence rather than a lie.

**Pulling this downloads nothing.** It resolves the PROJECT's playwright (shallowest `node_modules`
searching down from the repo root, which covers the three layouts in use) and fails loudly rather
than installing or falling back to a global one — so on a machine with no project playwright it is
simply inert. There is deliberately no `--headed`: a visible window is an unrequested interruption
of whoever is at the keyboard.

FROZEN on the day it landed, and the freeze is in the script's own header: **do not add flags.**
Visual-review tooling belongs in a shipped package that projects depend on, with its guiding skill
riding along, not developed globally here. What settled it: two projects independently asked for
authentication, and auth is irreducibly project-specific — a global tool cannot hold per-project
auth, route matrices or viewport sets. Keep using it; it works and was validated against real pages.
But a new capability belongs in the package. Known gaps left for it to inherit: authentication,
per-project route/viewport matrices, forced-colors emulation, and a combined index across runs.

**`overlay-doctor` gained a Tier V advisory check for `allowedSignersFile`, and it NEVER gates.**
`allowed_signers` is a shared asset — every signing repo on a machine points at the same file, so
one absent or empty copy degrades signature VERIFICATION everywhere at once, silently.

Advisory rather than required, deliberately: signing is legitimately disabled where an agent sandbox
cannot reach `~/.ssh` at all, and requiring signers there would turn a correct setup into a hard
failure — the cry-wolf outcome this doctor already avoids elsewhere. Three outcomes: no
`allowedSignersFile` configured reports `info`; a value pointing at a missing file reports
`advisory`; a file present but with no principal lines also reports `advisory`, because a
comments-only file looks populated and verifies nothing. **On a machine where signing is off by
design, a line here is the expected output, not something to fix.**

**`portability-lint` gained a bash 3.2 rule.** `empty-array-nounset` — under `set -u`, bash 3.2
aborts on `"${arr[@]}"` when the array is empty. macOS ships bash 3.2, so this is a macOS-only abort
that a Linux run cannot reproduce and a reviewer cannot see.

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
`--strict` fails on warnings too. Ten rules at the time of writing, each probed against a real macOS userland rather
than recalled — the table has GROWN since, and `portability-lint --list` is the live source
rather than this list: the in-place sed flag (no portable spelling exists — use temp-file + mv), `\t` inside a
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

**New: `kb` enforces a size budget on the Tier-0 projection — opt-in, and per KB.** Set
`projection_max_bytes` in that KB's own `kb.toml`. No key means no check, so nothing changes for a
KB that does not set one — and separate instances (personal, work) can carry different ceilings.
`kb project` prints usage as a percentage; `kb project --check` treats over-budget as drift, so a
generated pre-commit refuses the commit that pushes it over.

It checks the **freshly rendered** projection, not the committed file. Checking the committed one
would pass the very change that pushes it over, since the committed file is by definition the
pre-change size.

Bytes rather than tokens, deliberately: bytes are exact and free to measure, while a token count is
an estimate that varies by tokenizer — and a budget that is precise about the wrong unit invites
arguing with it. Why it exists at all: the projection loads into EVERY session at startup, so its
size is a tax paid per session forever, and it only ever grows because every amendment adds and none
subtracts. The point is not the number, it is the forced choice — adding a rule means deciding what
leaves.

**The git-hooks installer now clears inherited `GIT_*` variables before running the suite.** Git
exports `GIT_DIR`, `GIT_INDEX_FILE` and friends into a hook, and everything the hook runs inherits
them — `GIT_DIR` in particular makes ANY directory look like a repo, so a test asserting "this is
not a repo" fails. Measured: a suite reported failing during a real commit while passing standalone.
A gate that cries wolf gets disabled, so they are cleared.

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
