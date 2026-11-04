# Fleet sessions: roles, handoffs and setting up a machine

How a fleet of long-lived Claude Code sessions hands work from one session to the next, where every
file involved lives, what each session's Bash sandbox must be allowed to write, and how to set it
all up on a new machine. The tool is `fleet-canonicals` (`fleet-canonicals --help` lists every verb
and setting). The procedures it serves are skills: `parking-and-handoff` (ending a sitting),
`canonical-takeover` (launching and closing sessions), `fleet-messaging` (coordinating, with or
without cross-session messaging).

## Terms

- **Canonical:** a long-lived, named background session (`claude --bg -n <name>`) that owns one
  project. Its identity is the name, not the process: whoever holds the name inherits the project and
  anything queued to it. Names resolve newest-wins.
- **Fleet record:** the repository manifest (`~/Devel/mani.yaml`, read through `fleet-decl`) whose
  `canonical*` keys declare each canonical ([`fleet-manifest.md`](fleet-manifest.md)). A canonical
  exists because the record declares it, and runs on a machine because the record names that machine.
- **Hub:** the one canonical that can write the handoffs repository and runs `place` (below). A setup
  with a single canonical can make it its own hub; a setup can also have none, and then the human
  places.
- **The human:** the person who decides, approves, and runs the verbs that start and stop sessions.
- **Handoff:** a dated markdown file that tells a cold successor session what it needs to continue.
  Each handoff names the one it replaces on a `Supersedes` line, so the handoffs form a chain.
- **Pointer:** a small per-canonical file recording which handoff that canonical's next launch reads.
- **Staging:** a machine-local directory where a canonical that cannot write the handoffs repository
  leaves its handoff. **Placing** copies staged handoffs into the handoffs repository and repoints
  their pointers.
- **`$FLEET_STATE`:** the tool's state directory, default `~/.local/state/fleet-canonicals`
  (`$XDG_STATE_HOME/fleet-canonicals` where that variable is set).

## Roles

| Role | Writes | Never writes |
| --- | --- | --- |
| A canonical | its own project, its own scratch, and through the tool its pointer and staged handoffs in `$FLEET_STATE` | the handoffs repository, another project, another canonical's pointer |
| The hub | as a canonical, plus the handoffs repository (its own handoff, and placed ones) and, through `place`, the pointers of the handoffs it places | another project |
| The human | everything; also runs the session verbs (`up`, `refresh`, `down`, `dedupe`, `resume`, `clean`) from a plain terminal, and carries messages where sessions cannot message | |

**Why only the hub writes the handoffs repository.** A canonical's sandbox grants its own checkout,
not a shared one. One writer also means one session commits there, and placing is a checked step:
when placement was a hand copy, one placement left two dangling `Supersedes` links, one of them on a
live pointer. `place` refuses a handoff whose predecessor cannot be found.

## Where every file lives

| Path | Written by | Holds | Backed up |
| --- | --- | --- | --- |
| `~/.config/fleet-canonicals/config` | the private layer | the five settings below | with the private layer |
| `$FLEET_STATE/<name>.handoff` | `handoff --set`, `stage`, `place`, `--stub` | the pointer: the handoff's absolute path, then `# set-at <epoch seconds>` | no |
| `$FLEET_STATE/handoff-staging/YYYY-MM-DD-HHMM-<name>-park.md` (or `-checkpoint.md`) | `stage` | staged handoffs; `place` removes one only when its content is in a commit of the placed copy and no pointer names it | no |
| `$FLEET_STATE/stub-handoffs/YYYY-MM-DD-HHMMSS-<name>-stub.md` | `down`/`refresh --stub` | a generated "nothing to inherit" handoff; never placed | no |
| `$FLEET_STATE/<name>.tmproot` | each launch | the path of that launch's scratch root | no |
| `/tmp/c-<short>-XXXXXX` (`$FLEET_TMPROOT_PREFIX`) | each launch | the session's scratch root, passed as `CLAUDE_CODE_TMPDIR`; the session's `$TMPDIR` is `<root>/claude-<uid>`. `<short>` is the name without `-canonical`, cut to 8 characters, because a longer root is silently replaced by the shared default | no |
| the `handoffs` directory | the hub, `place` | committed handoffs | with its repository |
| `~/.claude/projects/` | Claude Code | transcripts; the tool only reads them, to find a resumed session's true start | no |
| `~/.claude/` (job directories, session rows) | the `claude` CLI that the tool calls to launch (`--bg`), delete a row (`rm`) and wake (`attach`) | Claude Code's own state | no |
| `~/.local/state/fleet-exchange/` | sessions passing a file to another session | one-off hand-offs; not used by the tool. On Linux the base ages each file out after 7 days unwritten; on macOS it installs no such rule | no |

The settings in the config file, each overridable by an environment variable for one run:

| Key | Variable | Meaning | Unset |
| --- | --- | --- | --- |
| `handoffs` | `FLEET_HANDOFFS_DIR` | where `place` copies staged handoffs | `place` refuses; `status` skips its unplaced check |
| `handoffs-search` | `FLEET_HANDOFFS_SEARCH` | the tree searched for a placed copy (and for a predecessor) | the `handoffs` directory |
| `hub` | `FLEET_HUB` | the session that places; `stage` names it in its output | not named |
| `place-commit` | `FLEET_PLACE_COMMIT` | `true`: `place` commits the files it placed, and only those, in the repository holding `handoffs`; it never pushes | `false`: copies only |
| `stage-check` | `FLEET_STAGE_CHECK` | an executable `stage` runs as `<check> <draft>` before staging; non-zero refuses the draft and prints the check's output. Point it at a script that runs the handoffs repository's blocking commit gates on the draft, so a draft that `place`'s commit would refuse is refused while its author can fix it. One that is not an executable file refuses every `stage` | no check |

## The handoff lifecycle

**Why a pointer, not "the newest file".** Deriving the newest handoff from the disk was tried and
failed: two handoffs sharing a date sorted wrong, modification time was right only on the machine
that wrote them, and most file names carry no canonical's name. A path written into a launch script
inside the checkout failed worse: the update was a write a sandbox can refuse, and the launch then
quietly read the previous handoff. The pointer sits outside every repository and is set
explicitly. Its `set-at` stamp also lets `down` and `refresh` refuse to end a session whose
recorded handoff is older than the session, since that handoff cannot describe its work.

### The hub's own handoff

1. Read the current pointer: `fleet-canonicals handoff <hub>` prints the file the hub started from.
2. Write `<handoffs>/YYYY-MM-DD-HHMM-<hub>-park.md`, with a header stamp (`**Parked <date> <time>
   <zone>.**`) and, in the first 15 lines, ``Supersedes `<basename from step 1>`.``
3. Commit it in the handoffs repository; push as that repository's policy allows.
4. Record it: `fleet-canonicals handoff <hub> --set <handoffs>/<file>`. Type the path; `--set`
   checks only that the file exists, so a glob that matches several records the wrong one silently.
5. Read it back: `fleet-canonicals handoff <hub>` must print that path.
6. The human runs `fleet-canonicals refresh <hub>` from a terminal. `refresh` refuses inside the
   session it would stop, because the stop would kill the command before its relaunch.

### A peer's handoff

1. Read the current pointer: `fleet-canonicals handoff <name>`.
2. Write a draft anywhere the session can write, normally `$TMPDIR/handoff.md`, with the header
   stamp and ``Supersedes `<basename from step 1>` `` in its first 15 lines. Say in it that the
   handoff is staged and not yet placed.
3. Stage it: `fleet-canonicals stage <name> "$TMPDIR/handoff.md"` (add `--kind checkpoint` for a
   checkpoint). The tool copies it to `$FLEET_STATE/handoff-staging/<stamp>-<name>-park.md`, points
   `<name>` at that copy with a fresh `set-at`, and prints `staged`, `pointer` and `place it with`
   lines. It refuses a draft with no `Supersedes` line naming the current handoff, printing the
   line to add, and never overwrites a staged file. When `stage-check` is configured it runs that
   check on the draft first and refuses on a non-zero exit, printing the check's findings: fix the
   draft and stage again. Nothing is staged and no pointer moves on a refusal. The draft can then
   be discarded.
4. The human runs `fleet-canonicals refresh <name>`. The successor reads the staged copy: placing
   is not a prerequisite for continuity.
5. Later, on **the same machine**, the hub runs `fleet-canonicals place --dry-run`, then `place`.
   It copies each staged handoff of a declared canonical into `handoffs` under the same name,
   commits them when `place-commit` is on, and repoints every pointer that named the staging copy,
   keeping its `set-at` (a fresh stamp would let the next `refresh` accept a handoff that does not
   describe the successor's work). It reports `BROKEN-CHAIN` for a handoff whose predecessor is
   neither in `handoffs-search` nor placed in the same run, and `NEEDS-JUDGMENT` for a staged file
   that is not a canonical's dated handoff; either leaves exit status 1, and the file in staging.
   Last, on every run, it removes each staging copy that nothing can need: one whose exact content
   is in a commit of its same-named placed copy (any commit, so a placed copy amended later still
   counts) and that no pointer names. It prints `removed` per file (`would remove` on a dry run)
   and one `kept <n>` line for copies whose content is in no commit, which a dry run lists one by
   one. Those hold text the handoffs repository never received, usually edits a canonical made to
   its staged handoff after it was placed; the hub judges them.

`place` reads only this machine's `$FLEET_STATE`. A canonical on a machine where the hub does not
run is placed by whoever can write a clone of the handoffs repository there, usually the human.

### What the successor reads

A launch resolves the pointer and composes the first prompt from the record: `You are <name>,
<canonicalIdentity>. Read <handoff> first and follow it. Confirm takeover in one line before
starting work.` The path is fixed at launch, so a successor started before `place` reads the
staging copy. `place` keeps that copy while any pointer names the handoff, which is until the
successor parks a newer one.

A launch refuses a pointer whose file is gone, and a missing pointer, before anything starts:
`up` prints `REFUSED <name> handoff for <name> points at a missing file: <path>` (or `no handoff
recorded`), on a dry run too, and `refresh` and `down` refuse in their handoff check, before
stopping the session, even with `--force`. `--stub` writes a new handoff and is not refused.

### What is machine-local until placed

Everything in `$FLEET_STATE`: pointers, staged handoffs and stubs, on one disk and in no backup.
A staged handoff survives a session recycle, not a lost disk. So a park whose handoff is staged
says so in the handoff itself, and the hub's sitting includes placing. `fleet-canonicals status`
prints a `handoff UNPLACED` line for each staged handoff with no same-named copy in
`handoffs-search` (or a `> **PLACED**` or `> **SUPERSEDED**` blockquote in its first 20 lines,
written by whoever placed it under another name), and exits 1 while any remain.

### Stubs break the chain

`down` or `refresh` with `--stub` points the canonical at a stub in `$FLEET_STATE/stub-handoffs/`.
The next staged handoff must name that stub on its `Supersedes` line, and since stubs are never
placed, `place` then reports it `BROKEN-CHAIN`. When the stub is the only missing link, place it
with `fleet-canonicals place --accept-broken-chain`, which still prints the gap. The flag accepts
every broken link in that run, so read `place --dry-run` first.

## Sandbox and permissions

Claude Code's Bash sandbox lets a command write little beyond the session's working directory and
its scratch root, plus the paths a settings file adds under `sandbox.filesystem.allowWrite`. Every
path below is derived from the tool's defaults; where `XDG_STATE_HOME` or a `FLEET_*` variable
moves one, the entry moves with it.

| Role | Must write (why) | Must not need | Reads |
| --- | --- | --- | --- |
| Every canonical | `~/.local/state/fleet-canonicals` (`stage` and `handoff --set` write staging and the pointer); its own checkout (the working directory, granted already); its scratch root `/tmp/c-…` (granted already as `$TMPDIR`) | the handoffs repository; other projects; anything under `~/.claude`; `/tmp` beyond its own root | the config file; the fleet record; `$FLEET_STATE` |
| The hub, in addition | the handoffs repository, working tree and `.git` (its own handoff, `place`'s copy and commit; no entry needed when that repository is its working directory), plus whatever that repository's commit hooks write | | `handoffs-search`; `$FLEET_STATE/handoff-staging/` |
| Sessions that pass files (messaging mode only) | `~/.local/state/fleet-exchange` | | the same directory |
| The human's terminal | not sandboxed: `~/.claude` (the `claude` CLI's job directories and rows), `/tmp/c-…` roots (made at launch, removed by `down`, `refresh`, `dedupe`, `clean`), `$FLEET_STATE` (`.tmproot` records, stubs) | | `~/.claude/projects` (transcripts) |

**The session verbs run outside the sandbox.** A launch must create a job directory under
`~/.claude`, which Claude Code keeps unwritable from sandboxed Bash even when `~/.claude` is
granted; a sandboxed `up` once failed with `EROFS` there. Stopping a session signals another
session's process, which a sandboxed shell may not be able to see. So `up`, `refresh`, `down`,
`dedupe`, `resume`, `resume-at` and `clean` run from a plain terminal or from a session that runs the
command outside its sandbox; do not grant `~/.claude` to make them fit. `status`, `list`, `handoff`,
`stage` and `place` run inside it.

**Where the entries go.** In a settings file, as `~/...` paths:

```json
{ "sandbox": { "filesystem": { "allowWrite": ["~/.local/state/fleet-canonicals"] } } }
```

The hub adds its handoffs repository (`"~/Devel/coordination"`) if that is not its working
directory; a fleet that passes files adds `"~/.local/state/fleet-exchange"`. User settings
(`~/.claude/settings.json`) cover every session; a project's `.claude/settings.local.json` covers one.
A private layer declares them in its settings fragment or per project with `claudeLocalSettings`
([`private-layer.md`](private-layer.md)); a declared array replaces the live one, so list every
entry. On a machine without one, edit the file by hand. Managed settings outrank both, and if they
refuse the entry, the canonicals there cannot stage and the human runs `stage` for them.

If the handoffs repository signs its commits and the sandbox blocks Unix sockets, the hub's `place`
cannot reach the signing agent; allow that socket or run `place` from a terminal.

## Setting up a new machine

Each step says what output proves it worked. Do them in order: a later step's check depends on an
earlier one.

1. **Prerequisites.** The base applied (`fleet-canonicals` and `fleet-decl` on `PATH`), `jq`, and a
   Claude Code with background sessions. Check: `claude agents --json` prints a JSON array.
2. **Declare the canonicals in the record.** Each project entry that has one sets `canonical`,
   `canonicalIdentity`, `canonicalLaunchDir` (relative to `~/Devel`), `canonicalLaunchModel` and
   `canonicalMachines`. Run `hostname` on this machine first and list exactly what it prints: the
   match is whole and case-sensitive, and a mismatch makes the canonical silently unexpected here.
   On macOS, compare it with `scutil --get HostName`; if that is unset, `hostname` can change with
   the network. **The model is declared** because a launch with no `--model` takes the account's
   saved default, which one `/model` pick in any session rewrites for every later launch. Check:
   `fleet-decl --check` exits 0, and `fleet-canonicals list` shows `[runs on: <this hostname>]` for
   each.
3. **Write the config file** (the private layer deploys it; on a machine without one, by hand):

   ```ini
   # ~/.config/fleet-canonicals/config
   handoffs = ~/Devel/coordination/handoffs
   handoffs-search = ~/Devel/coordination
   hub = coordination-canonical
   place-commit = true
   # optional: the handoffs repository's gates, run on each draft at `stage`
   stage-check = ~/Devel/coordination/tools/check-handoff-draft
   ```

   `place-commit = true` requires `handoffs` to be inside a git repository. Check:
   `fleet-canonicals place --dry-run` prints `nothing to place` or `would place` lines. `no
   handoffs directory is configured`, `no handoffs directory at` or `is not inside a git repository`
   names the key that is wrong. With `stage-check` set, run the check by hand on a copy of a
   handoff with one defect planted that the handoffs repository's commit gates refuse: it must exit
   non-zero naming the defect, and exit 0 on the unaltered handoff.
4. **Add the sandbox entries** from the table above. Check, in a session started after the change:
   `touch ~/.local/state/fleet-canonicals/.probe && rm ~/.local/state/fleet-canonicals/.probe`
   succeeds. Run it once before the change too, after `mkdir -p ~/.local/state/fleet-canonicals`
   from a terminal: it should fail there with `Read-only file system` or `Operation not permitted`,
   which is what shows the check can tell the two apart.
5. **Optionally, add the domain's halves of the skills** at `~/.dotlocal/skills/<skill>.md` for
   `parking-and-handoff`, `canonical-takeover`, `fleet-messaging` and `kb-tier0-writes`: the hub's
   name, the handoffs repository, whether messaging exists, who places on this machine and when.
   Each completes its skill and does not restate it. Check: the skill's last section names the file,
   and a session that loads the skill quotes it.
6. **Accept workspace trust** in each `canonicalLaunchDir` by starting `claude` there once
   interactively; Claude Code refuses a background launch in an untrusted directory. Check:
   `claude-trust-check` exits 0 (1 lists what is still untrusted; 3 means the state is unknown).
7. **Seed each canonical's first handoff.** A launch needs a pointer to a file that exists. Write a short starting handoff (what the project is, where its tracked state
   lives) where it persists, then `fleet-canonicals handoff <name> --set <path>`. Check:
   `fleet-canonicals handoff <name>` prints that path, and `fleet-canonicals up --dry-run <name>`
   prints `would start`, not `REFUSED`.
8. **First `status`.** Check: one `<name> MISSING` line per canonical declared for this machine, exit
   1. A canonical with no line has a `canonicalMachines` that does not match `hostname`; exit 2
   (`could not run: claude agents --json`) is step 1.
9. **First `up`,** from a terminal. `fleet-canonicals up --dry-run` prints `would start <name>
   <dir> (<model>)` for each; a `REFUSED` line is an incomplete declaration or a missing handoff
   (step 7), and says which. Then `fleet-canonicals up` prints `starting` lines and `started <n>`
   and exits 0; a `FAILED <name> launch exited <n>` line is the launch itself failing, often a
   sandboxed `up` (see "Sandbox and permissions"). Check: `fleet-canonicals status`
   shows `OK (<id>, started <time>)` for each, and each session's first reply confirms takeover.

### Where hooks or messaging are absent

- **No scratch-cleanup hook:** nothing removes a session's `/tmp/c-…` root when the session ends
  outside `down`, `refresh` or `dedupe` (a crash, a daemon restart, a fork), and on macOS the base
  installs no rule that ages them. Run `fleet-canonicals clean --dry-run`, then
  `fleet-canonicals clean`, from a terminal now and then. It keeps any root a running session may
  own, any root younger than 10 minutes, and anything not of the exact shape, and exits 2 without
  removing anything when it cannot read the sessions list.
- **No ramp-down hook:** nothing interrupts a session at a usage threshold; the human calls the
  park (skill `parking-and-handoff`).
- **No messaging:** coordination goes through handoff files and the human (skill `fleet-messaging`,
  no-messaging mode). Nobody tells the hub a handoff is staged: the human asks it to place, and
  `status`'s `handoff UNPLACED` lines are the reminder.
