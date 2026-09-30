---
name: cross-platform-tooling
description: Use when writing or editing any script, CLI or test harness that is deployed to more than one machine — anything in the dotfiles `bin/`, a hook, a bootstrap stage, a CI wrapper — and whenever reaching for `date`, `stat`, `sed -i`, `readlink -f`, `timeout`, `base64`, `mktemp`, `find -printf`, `grep -P` or `ps`. Also fires on the failure signatures: "illegal option -- c", "illegal option -- d", "unknown option -- r", "command not found: timeout", a value that is silently empty on one machine only, or a test suite that is green on the workstation and red on the Mac. Covers why GNU-only spellings ERROR rather than degrade, the two-spelling helper idiom, and the one case that is not a spelling problem at all.
---

# Writing tooling that is solid on Linux and darwin

A set of dotfiles is not one machine. A Linux workstation and a macOS machine can run **the same
deployed dotfiles**, so a script in `~/.local/bin` is a script on both — and the two ship
**different userlands**. GNU coreutils on one, BSD on the other.

The reason this needs a rule rather than care is in the next line.

## The rule in three lines

1. **A GNU-only spelling does not degrade on BSD — it ERRORS.** `stat -c` and `date -d` exit
   non-zero with `illegal option`. They do not print something slightly wrong; they print
   **nothing**. So a caller written as `x=$(stat -c %Y "$f" 2>/dev/null)` silently gets an empty
   string, and the failure surfaces somewhere else entirely, as a wrong decision rather than as an
   error.

   That distance between cause and symptom is the whole problem. **A real instance:** a
   freshness check used `stat -c %Y` as its fallback. On the Mac it returned nothing, so the
   check concluded "no timestamp" and **refused every input** — while the full test suite passed on
   the workstation. Nothing in the failure mentioned `stat`.

2. **Write the two-spelling helper once, at the top, and call it everywhere.** Never inline a
   platform-specific spelling at the call site, even "just this once":

   ```bash
   file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
   fmt_epoch()  { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null; }
   ```

   GNU first, BSD second, `|| ` between them. On each platform one branch errors out and the other
   answers, and the caller never knows which.

   **When you fix one instance, fix all of them in the same edit.** Leaving a broken spelling beside
   a fixed one is how the next reader learns the wrong idiom — and the one you left is usually in a
   display path, where being wrong is quiet. The same script had a *second* `date -d` in its
   status renderer that had been printing a raw integer where a timestamp belongs on darwin, since
   the day it was written, unnoticed.

3. **Run the suite on both machines, and assert by RUNNING the helper, not by grepping for a
   spelling.** A Linux-only run is structurally incapable of seeing this entire class. A test that
   greps for `stat -f` in the source passes on Linux while proving nothing works there.

   ```zsh
   mt=$(bash -c ". helpers.sh; file_mtime '$FILE'")
   [[ "$mt" == <-> ]] || bad "file_mtime did not resolve an mtime here: $mt"
   ```

   That assertion means "this works on whatever platform I am currently on", which is the only form
   of the check worth writing.

## Is your script even deployed there? Check, do not assume

A file in a chezmoi source goes to **every** machine that applies it unless `.chezmoiignore` gates
it. Before deciding a portability question is hypothetical, look in each source tree that could ship
the script:

```bash
grep -n 'your-script-name' <chezmoi-source-dir>/.chezmoiignore
```

No hit means it is on the Mac. Genuinely single-platform tooling belongs behind a gate — and gate
**both** the payload and the bootstrap stage that installs it, since gating only the payload is how
a macOS-only stage once ended up deployed on the Linux box.

## The divergences that actually bite

| Need | GNU | BSD / macOS |
| --- | --- | --- |
| file mtime as epoch | `stat -c %Y f` | `stat -f %m f` |
| format an epoch | `date -d @N +FMT` | `date -r N +FMT` |
| parse a time string | `date -d "STR" +%s` | `date -j -f FMT "STR" +%s` — **see below** |
| in-place edit | `sed -i` | `sed -i ''` (mandatory empty suffix) |
| canonical path | `readlink -f` | **present on macOS 13+** (verified on 26.5.2); absent on older — `cd "$(dirname f)" && pwd` if you support those |
| unwrapped base64 | `base64 -w0` | `base64` (no `-w`) |
| run with a time bound | `timeout` | absent — `gtimeout` only if coreutils installed |
| PCRE grep | `grep -P` | absent — use `grep -E` or `perl -ne` |
| skip empty input | `xargs -r` | **accepted on modern macOS** (verified) as a no-op, since skipping empty input is the default; historically an error |
| `find` output format | `find -printf` | absent — use `-exec stat` |

Everything in that table was **probed on a live macOS machine** (macOS 26.5.2, arm64) rather than
recalled, and two entries came back the opposite of the way they are usually reported — `readlink -f`
and `xargs -r` both work there now. That is the reason to probe rather than to trust a table like this
one, including this one: **an over-broad portability claim is worse than none**, because it sends you
to write an awkward workaround for a problem you do not have, and it costs you trust in the rows that
are real. Re-probe when a claim here matters to a decision.

**`sed -i` is the sharpest one on the list**, because it is the only entry that is silently
*destructive* rather than merely failing: on BSD, `sed -i 's/a/b/' f` consumes `s/a/b/` as the
backup suffix and then treats `f` as the script. Prefer writing to a temp file and moving it.

## The one that is NOT a spelling problem

`date -d` accepts **free-form** input. BSD `date -j -f` demands the format up front and has **no
free-form mode at all**. So this branch cannot be a translation — it has to *enumerate* the shapes
accepted, which is a deliberate narrowing of the input language on that platform. Say so in a
comment; a future reader will otherwise "simplify" it back.

```bash
parse_time() {
  local at="$1" f
  date -d "$at" +%s 2>/dev/null && return 0
  for f in '%Y-%m-%dT%H:%M:%S' '%Y-%m-%d %H:%M:%S' '%Y-%m-%d %H:%M' '%Y-%m-%d' '%H:%M:%S' '%H:%M'; do
    date -j -f "$f" "$at" +%s 2>/dev/null && return 0
  done
  return 1
}
```

**Most-specific format first, and that ordering is load-bearing.** BSD `date` parses greedily and
will accept a *prefix*, so a loose format tried early matches part of a fuller string and returns
the **wrong instant, successfully**. Assert both directions: a real time parses, and junk is still
refused.

## The SECOND thing that is not a spelling problem: macOS asks a HUMAN for consent

Some operations on macOS are gated by **TCC** (Transparency, Consent and Control) — the privacy
system behind the "«app» would like to…" dialogs. Local network access, Full Disk Access, Files and
Folders, screen recording. The grant is per **responsible process**, not per user, and it is
answered by a human in the GUI session.

Three consequences, and each one has produced a wrong diagnosis:

**1. The same command succeeds for you and fails for your daemon.** Your terminal has been granted;
a freshly installed LaunchAgent has not. So a check that passes interactively fails on a schedule,
with no configuration difference to find — because the difference is not in the configuration.

**2. The prompt is INVISIBLE over SSH, and it blocks silently.** It appears in the Aqua session,
where nobody is looking, and until it is answered the operation just fails. From an SSH shell there
is nothing to see: no log line, no error naming consent, no indication a dialog exists. Hours can
go into debugging a network-volume-unreadable check whose blocker is a dialog sitting unanswered on
a screen in another room.

**3. `launchctl asuser` DOES NOT REPRODUCE IT, which is the trap.** It looks like the right
differential — run the command in the launchd context — but it runs attributed to the CALLING
session, so it inherits the caller's grant and SUCCEEDS. That success is not evidence the agent can
do the thing; it is evidence the probe was not measuring the agent. It read as "not a permissions
problem" and sent the whole investigation the wrong way.

**How to apply, and the order matters:**

- **Ask about consent EARLY when building anything on the Mac that a daemon will run** — before
  debugging its logic. "Does this touch a network volume, the disk broadly, or another host on the
  LAN, and has this specific binary ever been granted that?" is a five-second question and one of
  the few failure modes that cannot be diagnosed from where an agent usually stands.
- **Treat an unreproducible failure as a statement about the PROBE.** If a probe cannot reproduce
  the failure, establish that it can *observe* that failure mode at all before concluding the
  failure is not there. A negative from an instrument that cannot detect the thing is not a
  negative.
- **Make the failure carry its cause.** Capture the underlying tool's stderr into the message:
  `Operation not permitted` names consent immediately, where a generic "could not connect" sends
  you hunting mounts and networks. A check that says *no* without saying *why* is barely better
  than one that did not run, because the condition is often gone by the time you re-run it.
- **An installer cannot grant consent, so it must SAY SO.** A script that deploys a daemon needing
  a TCC grant should print the one-time human step, or it silently produces something that looks
  installed and cannot work. That is indistinguishable from a healthy install until the first time
  anyone reads the output closely.

Nothing here is a spelling difference or a flag to translate. It is a platform where a correct,
well-tested, correctly-deployed program can still be refused — by design — and the refusal is
delivered to a human rather than to your logs.

## The test harness is tooling too

The suite itself must run on both machines, or the whole rule collapses at the point it matters. The
common blocker is `timeout`, which is coreutils and simply absent on macOS. Resolve it, with a real
fallback rather than a skip:

```zsh
if   (( $+commands[timeout] ));  then BOUND=(timeout)
elif (( $+commands[gtimeout] )); then BOUND=(gtimeout)
else BOUND=(perl -e 'alarm shift @ARGV; exec @ARGV')
fi
```

perl is present on every macOS by default. **Keep the bound real**: a skipped hang-guard is how a
regression hangs the suite forever instead of failing it — and a suite that hangs reports the same
thing as one that was never run.

## Do not "fix" it by installing GNU coreutils on the Mac

It is the first idea everyone has, and it trades a portability bug for an **undeclared dependency on
a machine whose bootstrap does not install it** — so the script now works on the machine you tested
and breaks on the next one provisioned, with nothing recording why. If a GNU tool is genuinely
required, it goes in that machine's Brewfile *and* the script checks for it and fails loudly by
name. Two spellings in a helper is cheaper than either.

## Verification: prove the red on the platform the fix is for

A portability fix verified only on the machine that already worked has verified nothing. The
control is:

1. Run the suite on **both** machines and record each result.
2. When something fails on one, **establish the baseline before claiming a regression** — run the
   *pre-change* suite on that same machine. Failures present at the parent commit are pre-existing,
   and saying so accurately is the difference between a real finding and a false alarm.
3. Plant each fix back out **on the platform it was written for** and watch the specific assertion
   go red there. A fix seen green on both machines but never seen red on either is of unknown value.

## Architecture, as opposed to userland

Less common, but real once you touch Homebrew paths: Apple Silicon prefixes at `/opt/homebrew`,
Intel at `/usr/local`. Never hardcode either — ask `brew --prefix`, or resolve the binary with
`command -v`. This is the axis "multi-arch" literally names; the userland split above is the one
that actually causes the outages.

---

If `~/.dotlocal/skills/cross-platform-tooling.md` exists, read it: it is this domain's half (which
machines these are, where the script-deployment gates live, and the dated incidents behind the
cases above). If it does not, the generic content above is the whole picture.
