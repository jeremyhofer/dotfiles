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
- **Director:** the standard coordinating seat, on every machine: the canonical that coordinates
  across projects and makes the one consolidated ask to the human (skill `fleet-messaging`'s hub),
  may request any canonical's lifecycle action, and grants the timing slot (`fleet-slot`). It is
  declared in the fleet record like any canonical. Its name is `director-canonical`, the default of
  the config keys `request-any`, `never-touch` and `slot-arbiter`; a domain that names it otherwise
  sets those keys. No tool needs it running: "Before a director runs" says what applies until then.
- **Hub:** on this page, the one canonical that can write the handoffs repository and runs `place`
  (below), named by the `hub` config key. Usually it is the director; a domain may give placing to
  another seat, and then this page's hub is the placing one. With no `hub` set, or none running, the
  human places.
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

### Before a director runs

A new machine runs sessions before its fleet record declares a director, and a declared director
may not be up yet. No tool refuses, waits on it, launches it or reports it missing on that account:

| The director's part | Until one runs |
| --- | --- |
| placing handoffs, where `hub` names it | canonicals stage as usual and each successor reads its staged copy; the human, or any session that can write the handoffs repository, runs `place`; `status`'s `handoff UNPLACED` lines are the reminder |
| granting the timing slot | with `slot-arbiter` unset and no director declared for this machine, `fleet-slot` has no arbiter and goes first come, first served: a request on a free slot takes it, and a release passes the slot to the next in the queue (recorded `first-come`); a waiting session watches `fleet-slot check`. A director that is declared but not running is still the arbiter: requests queue for it, and the human starts it (`fleet-canonicals up`) or grants from a terminal with `fleet-slot grant <holder> --as <arbiter>` |
| requesting another canonical's lifecycle action (`request-any`) | each canonical requests its own; another's is the human's, from a terminal |
| taking cross-project asks | the session asks the human itself, marked cross-project, and writes the ask into its handoff (skill `fleet-messaging`) |

`status` and `up` act only on what the record declares for this machine, so an undeclared director
is neither reported nor launched. Once declared, it is a canonical like any other: `status` reports
it `MISSING`, exit 1, until it is up.

## On-demand seats

A bare `up` starts every missing canonical unless the record or the config says otherwise. A seat
that should start only when someone asks sets `canonicalAutostart: false` in its fleet-record entry
(`docs/reference/fleet-manifest.md`); a machine that wants the opposite default sets
`autostart-default = false` in the config (table above) and marks each critical seat
`canonicalAutostart: true`. With neither set, every seat autostarts.

- `up` with no names starts the missing seats that autostart and prints a `skipped` line for each
  on-demand one. `up <name>...` starts the named seats whatever their key. `up --all` starts every
  missing seat. Names together with `--all` are refused.
- `status` prints a down on-demand seat as `off (on demand)` and counts it healthy: the exit status
  and the health check read only `MISSING`, `DUPLICATE` and `LIVE-UNLISTED` as unhealthy. A live
  on-demand seat is `OK`.
- Nothing acts on seats without naming them and starts an off one: `resume-at` runs a bare `up` after
  a usage reset and so skips it; `refresh`, `resume` and every queued request take a name. `dedupe`,
  `down --all`, `clean` and `wait-for-reset` start nothing, so they are unchanged.

## Where every file lives

| Path | Written by | Holds | Backed up |
| --- | --- | --- | --- |
| `~/.config/fleet-canonicals/config` | the private layer | the five settings below, the request queue's keys, and `fleet-slot`'s `slot-arbiter` ("Before a director runs") | with the private layer |
| `$FLEET_STATE/<name>.handoff` | `handoff --set`, `stage`, `place`, `--stub` | the pointer: the handoff's absolute path, then `# set-at <epoch seconds>` | no |
| `$FLEET_STATE/handoff-staging/YYYY-MM-DD-HHMM-<name>-park.md` (or `-checkpoint.md`) | `stage` | staged handoffs; `place` removes one only when its content is in a commit of the placed copy and no pointer names it | no |
| `$FLEET_STATE/stub-handoffs/YYYY-MM-DD-HHMMSS-<name>-stub.md` | `down`/`refresh --stub` | a generated "nothing to inherit" handoff; never placed | no |
| `$FLEET_STATE/requests/<id>.request.json` | `request` (written to a temp file, then renamed) | a queued lifecycle request: `id`, `time` (epoch seconds), `verb`, `name`, `reason`, `requester` | no |
| `$FLEET_STATE/requests/<id>.running.json`, `<id>.served.json` | `serve-requests` | the same request, while its verb runs and once it is done with; removed after seven days | no |
| `$FLEET_STATE/requests/<id>.result.json` | `serve-requests` | the outcome (`done`, `failed` or `refused`), the check that refused it, the verb's output; or `waiting`, with the time the wait began, while a request for a working session stays queued; removed after seven days | no |
| `$FLEET_STATE/requests/PAUSED` | the human | while it exists, the runner refuses every request | no |
| `$FLEET_STATE/requests-audit.jsonl` | `serve-requests` | one line per served request; the rate limits are counted from it. Outside `requests/`, so a grant to write the queue is not one to rewrite its history | no |
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
| `remote-control` | `FLEET_REMOTE_CONTROL` | `true`: `up`, `refresh` and `resume --fork` launch each canonical with `--remote-control <name>`, so it is reachable from the Claude app under its name; a canonical's manifest `canonicalRemoteControl` overrides it. A queued `resume` runs `claude respawn <id>`, which takes no other argument (Claude Code 2.1.319); whether a respawned session keeps Remote Control is unmeasured | `false`: no Remote Control |
| `autostart-default` | `FLEET_AUTOSTART_DEFAULT` | `true` or `false`: whether a bare `up` (and `resume-at`) starts a canonical whose fleet-record entry sets no `canonicalAutostart`. A value other than true or false is reported and treated as true, so a typo never keeps a critical seat down | `true`: every canonical autostarts, as before the key existed |
| `place-commit` | `FLEET_PLACE_COMMIT` | `true`: `place` commits the files it placed, and only those, in the repository holding `handoffs`; it never pushes | `false`: copies only |
| `stage-check` | `FLEET_STAGE_CHECK` | an executable `stage` runs as `<check> <draft>` before staging; non-zero refuses the draft and prints the check's output. Point it at a script that runs the handoffs repository's blocking commit gates on the draft, so a draft that `place`'s commit would refuse is refused while its author can fix it. One that is not an executable file refuses every `stage` | no check |

The request queue's keys (no variable overrides them; names are space- or comma-separated, and a
key set to nothing is an empty list, not the default):

| Key | Default | Meaning |
| --- | --- | --- |
| `request-max-age` | `600` | seconds after which a queued request is refused as stale |
| `request-limit-canonical` | `3` | lifecycle actions (run, whether they succeeded or failed) per canonical in a rolling hour |
| `request-limit-fleet` | `auto` | the same, for every canonical together; `auto` is max(10, 2 × the seats the record declares for this machine), so one refresh round plus one recovery per seat fits |
| `request-usage-threshold` | `85` | the 7-day usage percent at which `up`, `refresh`, `resume` and `init` are refused |
| `request-usage-exempt` | none | canonicals that may still be started above the threshold |
| `request-any` | `director-canonical` | requesters who may request any canonical's action; everyone else, only their own |
| `never-touch` | `director-canonical` | canonicals the queue never acts on, for any verb, whoever asks; refused at `request` too |
| `allow-self-refresh` | `false` | `true` lets a canonical request its own `refresh` (see "Requesting a lifecycle action") |
| `request-idle-states` | `done,idle,waiting` | the `claude agents --json` states that do not count as working; any other state refuses a stop |

## The handoff lifecycle

**Why a pointer, not "the newest file".** Deriving the newest handoff from the disk was tried and
failed: two handoffs sharing a date sorted wrong, modification time was right only on the machine
that wrote them, and most file names carry no canonical's name. A path written into a launch script
inside the checkout failed worse: the update was a write a sandbox can refuse, and the launch then
quietly read the previous handoff. The pointer sits outside every repository and is set
explicitly. Its `set-at` stamp also lets `down` and `refresh` refuse to end a session whose
recorded handoff is older than the session, since that handoff cannot describe its work.

**A seat that has never launched has no handoff to point at**, so `up` refuses it like any other
seat without one. `fleet-canonicals init <name>` is the way in: it requires the seat fully declared
for this machine with no `fleet-decl --check` finding on its project, refuses a name that has a pointer or a
transcript under its launch directory (a seat that has run has a real handoff somewhere, and a
generated one would hide it), then writes a first-launch handoff from the record into the stub
directory, records the pointer, and with `--up` launches.

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

A launch resolves the pointer and composes the first prompt from the record: `This session is <name>,
<canonicalIdentity>. The previous session's handoff is at <handoff>: read it first and resume the
work it describes. Reply with one line confirming you have resumed, then begin.` The path is fixed at launch, so a successor started before `place` reads the
staging copy. `place` keeps that copy while any pointer names the handoff, which is until the
successor parks a newer one.

A launch refuses a pointer whose file is gone, and a missing pointer, before anything starts:
`up` prints `REFUSED <name> handoff for <name> points at a missing file: <path>` (or `no handoff
recorded`), on a dry run too, and `refresh` and `down` refuse in their handoff check, before
stopping the session, even with `--force`. `--stub` writes a new handoff and is not refused.

A launch also refuses a handoff from anywhere but the staging directory, the `--stub` directory or
the configured `handoffs` and `handoffs-search` trees, a symbolic link, and a path that climbs out
of those with `..`. Where the handoff sits in a git repository it must be committed and unchanged
since its last commit, so a successor reads what passed that repository's gates. A staged copy is
in no repository and gets the location check alone: requiring a commit would make every relaunch
wait on the hub's `place`.

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
command outside its sandbox; do not grant `~/.claude` to make them fit. `clean` refuses inside the
Linux sandbox by itself (below). A session inside its sandbox requests `up`, `down`, `refresh` or
`resume` through the queue instead (below). `status`, `list`, `handoff`, `stage` and `place` run
inside it.

**Inside a sandbox, the list of live sessions can be wrong, and every session verb trusts it.** The
tool reads `claude agents --json` (active sessions) and, for some checks, `--all` (stopped ones
too). Measured on a macOS work machine, 2026-11-04, whose sandbox `allowUnixSockets` names only
specific sockets: in the human's terminal the list was complete and current, while inside a
session the active list was empty, or held only one session started by hand, and `--all` listed
the others with stale states (`failed` where the terminal said `done`). The likely cause, not
confirmed, is that the sandbox cannot reach the session service's socket, under
`/private/tmp/cc-daemon-*` there, and the CLI falls back to judging liveness itself.

**A sandbox that reaches the socket still gets an incomplete list.** The active list leaves out any
job whose state reads `done` or `failed` while its process runs, from a terminal as well. A terminal
finds those processes through Claude Code's pid records (`status` reports them `LIVE-UNLISTED`; `up`
refuses them). Inside the Linux sandbox `/proc` shows only the sandbox's own processes, so that
check finds nothing, while other seats' roots under `/tmp` stay visible. Measured on a Linux
workstation whose sandbox allows every socket, 2026-11-09 00:04, inside a session, with two seats
`done` and running and four `working`, each verb in its `--dry-run` form:

| Verb, run inside the sandbox | What it did |
| --- | --- |
| `status` | reported the four `working` seats `OK` and the two `done` ones `MISSING` |
| `up --dry-run` | would have started a second session for each of the two |
| `dedupe --dry-run`, `down --dry-run <a done seat>` | found nothing to close (`not running`) |
| `clean --dry-run`, before it learned the pid-record check | would have removed a `done` seat's root, while keeping every listed one's |
| `clean`, since | refuses: other sessions' processes are hidden from the sandbox |

A refusal or a dry run changes nothing; none of the verbs was run for real.

So the verbs in the paragraph above stay the human's, run from a terminal, and a session's own
`status` is a hint, never a finding: where it disagrees with the terminal, the terminal is right.

### The session-state snapshot

**On a machine that runs the snapshot timer, a sandboxed `status` reads the terminal's view.**
`fleet-canonicals snapshot`, run every 15 seconds outside every sandbox by
`fleet-canonicals-snapshot.timer` (macOS: the `local.dotfiles.fleet-canonicals-snapshot`
LaunchAgent), merges `claude agents --json`, Claude Code's pid records in `~/.claude/sessions/`
(each pid checked against the process table) and the daemon roster `~/.claude/daemon/roster.json`
into `$FLEET_STATE/sessions.json`. Each seat declared for the machine is `live` (any source shows it
running), `dead` (every source was read and none shows it) or `unknown` (none shows it and a source
that could have could not be read). Every field of those Claude Code files is read as optional:
they are undocumented, and a field missing on an older version reads as no evidence, not as dead.
The verb refuses inside a sandbox, where it would report hidden sessions as dead.

`status`, `up` and `clean` use a snapshot no older than `snapshot-max-age` (45 seconds): a live seat
the listing omits reads `LIVE-UNLISTED`, an unknown one `UNKNOWN (<why>)` and never `MISSING`, and
`up` refuses to start either. A stale snapshot makes them refuse, naming the timer. A missing one
(the timer not enabled yet) gives a one-line note and the direct reads these verbs made before. The
request runner refuses every request while the snapshot is stale and refuses starting a seat it
reads as `unknown`.

**Context use.** For each live seat the snapshot also records `context`: the prompt size of the
seat's last main-thread reply, read from its transcript (`input_tokens` + `cache_read_input_tokens` +
`cache_creation_input_tokens` of that entry's `message.usage`), against its context window, as
`tokens`, `window`, `percent`, `sessionId` and `at`. The transcript records only the bare model id,
so the window comes from the seat's declared `canonicalLaunchModel`: one ending in `[1m]` is
1,000,000 tokens, any other the config key `context-window` (200,000 by default). `status` appends
`context 72.8% (728k of 1000k)` to a seat's line, `context ?` when no figure can be read, and the
word `CONTEXT-HIGH` at `context-flag-pct` (50 by default) or more. Jeremy asked on 2026-11-10 for
seats to be refreshed proactively above 50%, and the director's sweep acts on that word. The flag
is advisory: it does not change `status`'s exit code.

`refresh` stops the seat and then waits for a snapshot taken after the stop, up to 30 seconds
(`FLEET_REFRESH_SNAPSHOT_WAIT`), before its `up`. The snapshot current at the stop still lists the
stopped process, and `up` would refuse on it; on 2026-11-10 that left a refreshed seat down. The
wait is skipped when there is no snapshot or it already shows the seat dead. If no new snapshot
arrives, `refresh` refuses, names the timer, and leaves the seat stopped for `up` once it has run.

### Requesting a lifecycle action

**A session requests `up`, `down`, `refresh`, `resume` or `init` instead of running it.** A
requested `init` runs `init --up`, and only a `request-any` requester can ask for it, since the seat
has no session of its own to ask with.
`fleet-canonicals request <verb> <name> --reason <text>` writes one file into
`$FLEET_STATE/requests/`, which a canonical can already write (the table above); it runs nothing.
`fleet-canonicals serve-requests`, started every minute outside every sandbox by a systemd user
timer (Linux) or a LaunchAgent (macOS), reads the queue and runs the plain verb, so the verb's own
pre-flight and handoff gate still apply, and a request is served within about two minutes. It reads
the sessions list from outside the sandbox, where the list is reliable. `resume` runs `claude
respawn` on the canonical's last session, the documented restart of a stopped one.

The runner cannot tell who wrote a file; a request records who it claims to be from (the calling
session's name, read from `CLAUDE_CODE_SESSION_ID` and the status-line usage file, else `--as`), so
the checks bound what any request can do, and every outcome is in a result file and the audit log.
No notification is sent. The runner refuses, in this order, a request that:

- is malformed, names a verb other than the four, or carries an option such as `--force` or
  `--stub`;
- arrives while `requests/PAUSED` exists, or is older than `request-max-age`;
- names a canonical on `never-touch`, or one the fleet record does not declare for this machine;
- names a canonical other than its requester, from a requester not on `request-any`;
- asks a canonical's own `refresh`, unless `allow-self-refresh = true`. A session that runs
  `refresh` on itself is killed at the stop, and the harness crash-respawns the same session with
  `--resume`, reporting OK and refreshed nothing (measured 2026-08-29). Whether a runner outside the
  session wins that race is unmeasured; the key is how the measurement is run on purpose;
- shares its canonical with an older request in the same pass or one marked running (a runner that
  died mid-verb leaves one; remove it by hand);
- would exceed `request-limit-canonical` or `request-limit-fleet` in the past hour;
- is `up`, `refresh`, `resume` or `init` while the highest current `seven_day_pct` in
  `$XDG_RUNTIME_DIR/claude-usage/*.json` is at or above `request-usage-threshold` and the canonical
  is not exempt (a file whose `seven_day_resets_at` has passed is skipped; with no files, usage is
  not checked);
- is `up`, `resume` or `init` where `claude-trust-check` reports the canonical's project untrusted, or
  cannot read the trust state;
- names a canonical with no live row in `claude agents --json` while a live process holds the name:
  a Claude Code pid record under `~/.claude/sessions/` names it and its pid is running (on Linux,
  the same process, by the record's `procStart` against `/proc/<pid>/stat`). Measured 2026-11-08:
  a canonical resumed after the supervisor's idle stop ran idle while the listing had its job as
  `done`, so `up` would have started a second session and `resume` respawned a running one. `up`
  and `resume` stay refused. A `down` or `refresh` waits instead of being refused, unless every
  live pid record for the name says `idle` and the session's transcript shows its last turn ended;
  then the process is treated as the session (see below), and a transcript that cannot be read
  refuses;
- is `down` or `refresh` while the session's listing or transcript cannot be read; or is `resume`
  while the session is running. For `resume`, running means a process: a live pid record holds the
  name, or the daemon roster lists a worker for the session, or the roster cannot be read. A
  session still listed with no process behind it, in any state (an idle stop often leaves one
  `blocked`), is resumed, and the result says `done` only once a process holds it again.

**A request for a working session waits** rather than being refused: when the only check that
fails is that the session's listed state is not in `request-idle-states` or its transcript's last
turn has not ended, the request stays queued, its result file says `waiting`, and each pass checks
it again from the start. It is served once the session is idle, or refused as stale at
`request-max-age`, naming the wait. A waiting pass writes no audit line, so it does not count
against the rate limits. This is what lets a session request its own refresh: it is working when
it writes the request, and the runner serves a new request within seconds.

**A session listed `blocked` with no `waitingFor` is treated as idle only on evidence that it
parked.** Claude Code's agent view gives that state to a session whose last turn asked its human
something, and it keeps a stopped session listed that way after an idle stop. A `down` or `refresh`
is served for one in two cases. First, a live process whose own pid record says `idle`, with a
handoff pointer set after the session started. Second, a session that is provably stopped, which
means no live pid record holds the name and the daemon's roster (`~/.claude/daemon/roster.json`,
`FLEET_DAEMON_ROSTER`) lists no worker for it, with a handoff pointer naming a placed file
(under `handoffs-search`, else `handoffs`) set after it started. Anything else waits: a busy
record, a roster worker, an unreadable roster, a pointer that is older than the session or names a
staged draft, or a real `waitingFor`. Pid records and the roster are both undocumented files.
A change to the pid records' format would make them read as "no live process", leaving the roster
as the only guard. A roster that cannot be read waits.

**A `working` row with no `waitingFor` is treated as idle only on two signals.** A turn end
sometimes writes no final job state, so the listing keeps saying `working` for an idle session
(seen for over an hour). A `down` or `refresh` is served for one when every live pid record for
its session says exactly `idle` (`shell` means a background shell still runs, `busy` a turn) and
its transcript's last turn ended. With no record, any other status or a turn in progress, the
request waits, and the reason says which signal failed.

**A seat whose job went `done` while its process lives.** The live listing omits a `done` job
(`claude agents --json --all` keeps it), so there is no row to stop. Run from a terminal,
`fleet-canonicals refresh` and `down` treat the live process, found through its pid record, as
the session: the same self-refusal, handoff gate and worktree warning apply, then the process is
stopped and its job removed, and `refresh` launches as declared. The output carries a `note` line
saying the seat was unlisted because its job is done.

A keep-alive, which would hold a canonical up against an idle stop, is not built; the runner has
the check's place for it and no hold can exist yet.

**Where the entries go.** In a settings file, as `~/...` paths:

```json
{ "sandbox": { "filesystem": { "allowWrite": ["~/.local/state/fleet-canonicals"] } } }
```

The hub adds its handoffs repository (`"~/Devel/coordination"`) if that is not its working
directory; a fleet that passes files adds `"~/.local/state/fleet-exchange"`. User settings
(`~/.claude/settings.json`) cover every session; a project's `.claude/settings.local.json` covers one,
including every session started in a subdirectory of it, and a subdirectory's own
`.claude/settings.json` covers a session started there. A private layer declares them in its settings
fragment, per project with `claudeLocalSettings`, or per directory with `claudeDirSettings`
([`private-layer.md`](private-layer.md)); a declared array replaces the live one, so list every
entry. Where several canonicals start in subdirectories of one repository, the root's
`settings.local.json` is shared by all of them, and Claude Code saves there an approval from any of
them: put each session's entries in its own directory's file, keep the root's to what every session
may have, and run `claude-project-settings check`, which reports a permission rule saved there as
drift: declare one a seat needs in that seat's own file, and remove each from the root's (skill
`claude-config-layers`, §5a). On a machine without one, edit the file by hand. Managed settings outrank both, and if they
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
   hub = director-canonical
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
8. **First `status`.** Check: one `<name> MISSING` line per canonical declared for this machine (a
   canonical set not to autostart reads `off (on demand)` and does not count), exit 1. A canonical with no line has a `canonicalMachines` that does not match `hostname`; exit 2
   (`could not run: claude agents --json`) is step 1.
9. **First `up`,** from a terminal. `fleet-canonicals up --dry-run` prints `would start <name>
   <dir> (<model>)` for each; a `REFUSED` line is an incomplete declaration or a missing handoff
   (step 7), and says which. Then `fleet-canonicals up` prints `starting` lines and `started <n>`
   and exits 0; a `FAILED <name> launch exited <n>` line is the launch itself failing, often a
   sandboxed `up` (see "Sandbox and permissions"). Check: `fleet-canonicals status`
   shows `OK (<id>, started <time>)` for each, and each session's first reply confirms takeover.
10. **Optionally, enable the request runner** ("Requesting a lifecycle action"), from a terminal; it
    needs `uv` on `PATH`. Its requests directory is inside `~/.local/state/fleet-canonicals`, which
    step 4 granted; a machine that granted only part of that directory adds
    `~/.local/state/fleet-canonicals/requests`. Its canonicals must be declared in a fleet record
    for this machine (step 2): the runner acts on nothing else. Then:
    - Linux: `systemctl --user enable --now fleet-canonicals-requests.timer`. Check:
      `systemctl --user list-timers fleet-canonicals-requests.timer` shows a next run within a
      minute, and `journalctl --user -u fleet-canonicals-requests.service` shows a pass.
    - macOS: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.dotfiles.fleet-canonicals-requests.plist`.
      Check: `launchctl print gui/$(id -u)/local.dotfiles.fleet-canonicals-requests` shows
      `run interval = 60 seconds`; its output goes to `~/Library/Logs/fleet-canonicals-requests.log`.
    - Where the LaunchAgent cannot be loaded (a managed Mac may refuse it): run
      `fleet-canonicals serve-requests --loop` in a tmux pane outside every sandbox. It serves the
      queue, then again every 60 seconds (`--interval SECONDS` changes that) until `Ctrl-C` or
      SIGTERM, which end it with status 0 between passes. A pass that fails is reported on stderr
      and the loop goes on. It does not survive a reboot or a closed pane; it is a fallback.

    Then prove a refusal from inside a session: `fleet-canonicals request up <a name declared for
    another machine> --reason probe --as <name>` must exit 1 naming the machine, and a request for
    a canonical that is running and working must come back refused with check `working` in its
    result file. Pause the runner with `touch ~/.local/state/fleet-canonicals/requests/PAUSED`;
    disable it with `systemctl --user disable --now fleet-canonicals-requests.timer` or `launchctl
    bootout gui/$(id -u)/local.dotfiles.fleet-canonicals-requests`.
11. **Enable the session-state snapshot** ("The session-state snapshot"), from a terminal:
    - Linux: `systemctl --user enable --now fleet-canonicals-snapshot.timer`. Check:
      `jq .takenAtIso ~/.local/state/fleet-canonicals/sessions.json` moves every 15 seconds.
    - macOS: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.dotfiles.fleet-canonicals-snapshot.plist`.
      Check the same file; output goes to `~/Library/Logs/fleet-canonicals-snapshot.log`.

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
