---
name: writing-zsh-commands
description: LOAD THIS BEFORE WRITING ANY SHELL COMMAND ON THIS MACHINE. The shell is zsh, not bash, and the differences fail SILENTLY — wrong output, not an error. Do NOT skip it because the command "looks simple" or because the shell is incidental to some larger task: the traps fire on one-liners (a glob that matches nothing, a loop over a variable, a `local` parameter named `path`, a directory whose name starts with `-`) and typically return an empty result, a zero count, or a false success rather than failing. If you are about to run Bash, this applies. Also use when a command fails with "no matches found", "bad option", "parse error near", or "command not found" for a tool that plainly exists (usually PATH clobbered by a variable named `path`), "Blocked: sleep", a command that hangs after its jobs have finished, or when a command "worked" but returned nothing, matched nothing, counted zero, or reported success it should not have.
---

# Writing shell commands under zsh

**The shell is zsh.** Most bash syntax works, but a handful of habits do not — and the dangerous
ones are the ones that **fail silently**, producing a plausible wrong answer instead of an error.

> **Do not gate reading this on the command looking hard.** The trap is that these fire on
> *short* commands — a one-line `ls` in a loop, a `local` parameter that happens to be named
> `path` — and the shell is usually incidental to whatever you were actually doing, so it never
> gets classified as "shell work" at all. That is the observed failure mode, not a hypothetical
> one: a session hit three of the traps below in a single sitting while treating each command as
> plumbing in service of some other goal, and diagnosed each one individually afterwards instead of
> recognising the class. **Two of the three were already documented here.** If you are about to run
> a shell command, you are in scope.

## The two failure classes, and why one is far worse

| | What it looks like | Cost |
| --- | --- | --- |
| **Loud** | `no matches found`, `bad option: -`, `parse error near` | Annoying. The command did not run, you notice immediately, you fix it. |
| **Silent** | An empty result, a loop that never iterates, a check that passes | **This is the one to fear.** It looks like an answer. A silent zsh failure inside a verification makes the verification *pass* — you then report something as confirmed that was never tested. |

Everything below is marked **LOUD** or **SILENT** so you know which you are dealing with.

## 1. SILENT — a variable holding several values is ONE word

zsh does **not** word-split unquoted parameters. This is the single most common way a bash habit
produces a wrong answer here:

```zsh
files="a.txt b.txt"
grep -n pattern $files        # ONE argument, the literal "a.txt b.txt" -> file not found
set -- $files; echo $#        # 1
```

**Use an array. Always, for multiple values:**

```zsh
files=(a.txt b.txt)
grep -n pattern "${files[@]}"   # two arguments, correct
set -- $files; echo $#          # 2
```

If you genuinely must split a string, `${=var}` forces it — but an array is almost always the
right answer instead.

**Why this one deserves real fear:** a `grep` over what you *think* is four files but is actually
one non-existent filename returns "no match", which reads exactly like "the thing you searched for
isn't there." That is a **false negative in a verification**, and it is indistinguishable from a
genuine clean result unless you check the argument count.

## 2. LOUD — an unmatched glob is a hard error, not a literal

In bash an unmatched glob is passed through as text. In zsh the command **does not run**:

```zsh
ls *.nonexistent          # zsh: no matches found: *.nonexistent   (bash: "ls: *.nonexistent")
```

**This includes globs inside option values**, which is the form that catches people out, because
it does not look like a glob:

```zsh
grep -r --include=*.md pattern .     # no matches found: --include=*.md
grep -r --include='*.md' pattern .   # correct — quote it
```

Rule: **quote any argument containing `*`, `?`, `[`, `~` or `^` that is meant for the command
rather than for the shell.** `find . -name '*.js'`, not `-name *.js`.

**`2>/dev/null` does NOT suppress this error**, which surprises everyone the first time:

```zsh
ls -d *.nope 2>/dev/null    # STILL prints "no matches found", exit 1
```

The shell fails while expanding the glob, *before* the command and its redirections ever run — so
there is no stderr to redirect yet. In bash the same line is silent, because there the glob is
passed through and it is `ls` that complains, with its stderr duly redirected.

**And the obvious fix has a SILENT trap in it.** The `(N)` glob qualifier makes an unmatched glob
expand to nothing instead of erroring — but *nothing* means the argument disappears entirely:

```zsh
ls -d *.nope(N)     # exit 0, and prints "." — `ls -d` with no arguments lists the current dir
```

A loud failure has become a confident wrong answer. If you use `(N)`, capture into an array and
check it is non-empty before using it:

```zsh
matches=(*.nope(N))
(( ${#matches} )) || { echo "no matches"; return 1 }
```

**In Claude Code's Bash tool, bare glob qualifiers are OFF** (`nobareglobqual`), although plain zsh
and the interactive shell have them on. So `*(N)`, `*(/)` and `*(.)` do not act as qualifiers there:
they fail with `no matches found` or `bad pattern`. Measured 2026-09-26. Forms that do work in the
tool, each seen returning an empty match cleanly:

```zsh
(setopt nullglob; matches=(*.nope); print ${#matches})     # a subshell keeps the option local
(setopt extendedglob; matches=(*.nope(#qN)); print ${#matches})
```

Or list with `fd`, which has no glob semantics to trip over.

## 3. SILENT — `$?` after a pipeline is the LAST command's status

```zsh
false | true; echo $?      # 0  — the failure vanished
```

This is how a check ends up unable to fail. Two fixes:

```zsh
if grep -q pattern file; then ...    # put the test on the command whose result you mean
echo ${pipestatus[1]}                # zsh spells it $pipestatus, and it is 1-INDEXED
```

Never write `cmd | head && echo FOUND` and read it as "cmd succeeded" — `head` almost always
succeeds, so that prints FOUND regardless.

## 4. SILENT — arrays are 1-indexed

```zsh
arr=(first second)
echo $arr[1]      # first     (bash's ${arr[1]} is "second")
```

Off-by-one here does not error; it silently returns the neighbouring element.

## 5. LOUD — `print` and `echo` consume leading-dash arguments

```zsh
print '--- section ---'        # zsh: print: bad option: -
print -r -- '--- section ---'  # correct
```

Use `print -r --` whenever the text might begin with `-`. This bites constantly when formatting
output with dashed separators.

**The same trap applies to any command taking a PATH that begins with `-`**, and there it is much
quieter, because the command runs and reports something plausible rather than erroring:

```zsh
ls -A -weird-dirname          # treated as FLAGS, not a directory name
find -weird-dirname -name '*' # find reads it as an expression
ls -A ./-weird-dirname        # correct — the ./ prefix makes it unambiguously a path
```

Any directory whose name starts with `-` needs the `./` prefix (or `--` where the command supports
it). Watch for this with generated or encoded directory names, where a leading `-` is common and
not obvious from a distance. **The failure mode is the dangerous one: a count comes back `0`, which
reads as "nothing there" rather than "the command never looked."**

## 5b. SILENT — `path` is the same variable as `PATH`, and `local path=…` breaks the function

zsh ties several lowercase array variables to their familiar scalar counterparts: **`path`↔`PATH`**,
`fpath`, `cdpath`, `manpath`. They are the *same variable in two views*, so assigning the lowercase
name changes the real one.

```zsh
f() {
  local expect=$1 path=$2       # <-- just destroyed PATH for this function
  jq -n '{}' > /dev/null        # zsh: command not found: jq
}
```

The symptom is a burst of `command not found` for tools that obviously exist — and if the function's
failure branch is what records results, they turn into ordinary-looking test failures rather than
anything that points at `PATH`. Real instance: a test helper took `path` as a parameter name, and
every case using that helper failed while an adjacent helper taking `fp` passed, which reads as "the
code under test is broken" rather than "the harness broke itself."

**Never use `path`, `fpath`, `cdpath` or `manpath` as a variable name in zsh**, not even with
`local`. Pick anything else (`fp`, `target`, `dir`). Note that `typeset -h` can hide the tie, but
relying on that is worse than just renaming the variable — a reader has to know the special-cases
list to see that the code is safe.

**A LOUD sibling: `status` is read-only.** zsh keeps `$?` under a second name, `status`, so
`status=$(curl …)` fails with `read-only variable: status` and the script stops there. Seen in
scripts that capture an HTTP or job status. Use `rc`, `http_status`, `st`.

## 6. Bash-only constructs that are simply absent

`mapfile` / `readarray` do not exist (a loop over them silently does nothing), and `$PIPESTATUS`
is `$pipestatus`. Bash's indirect expansion is a LOUD `bad substitution`: `${!name}` (the value of
the variable whose name is in `name`) is `${(P)name}` in zsh, and `${!assoc[@]}` (an associative
array's keys) is `${(k)assoc}`. If you genuinely need bash semantics, say so explicitly — `bash -c '…'` is the
honest escape hatch, and is better than writing something that half-works.

## 7. Running commands on a remote host — heredoc, never nested quotes

```zsh
ssh host 'zsh -ls' <<'REMOTE'
cd ~/some/dir && ./do-thing
REMOTE
```

`ssh host 'zsh -c "…"'` nests three levels of quoting: local escaping breaks, and globs, `!` and
leading `=` detonate on the **remote** side. A single-quoted heredoc delimiter (`<<'REMOTE'`) means
zero local expansion, and `-ls` / `-s` read the script from stdin.

**A non-interactive shell never reads `.zshrc`**, so shell *functions and aliases do not exist over
SSH*. If something works when typed by hand but reports `command not found` remotely, that is why —
it needs to be a real script on `PATH`, not a function. The same goes for a `PATH` entry that only
`.zshrc` adds: a tool found interactively can be `command not found` over SSH (seen with `chezmoi`
over SSH to a Mac). Call it by full path, or use a login shell (`zsh -ls`) if `.zprofile` adds it.

## 8. SILENT — a recursive search skips whatever the repo ignores, and `rg` does NOT fix it

`rg` and the `grep` shim installed here are **both gitignore-aware by default**. So a plain
recursive search inside an ignored tree — `node_modules/`, build output, a vendored or preserved
directory, an agent tool's state checkout — reports **zero matches, by design, with no warning and exit
status 0**. Nothing distinguishes that from "the string genuinely is not there."

Measured from a repo root, one string living only inside a gitignored `node_modules/`:

| command | hits |
| --- | --- |
| `grep -rl PATTERN .` (the shim) | 1 |
| `rg -l PATTERN` | 1 |
| `rg -uu -l PATTERN` | **2** |
| `command grep -rl PATTERN .` | **2** |

**"Prefer `rg`" is not a mitigation for this** — that is the trap. `rg` is preferred here for speed,
and its gitignore-awareness is genuinely useful when searching *source*; but the two tools share
this blind spot exactly, so swapping one for the other changes nothing and feels like it should.

**What to do:** when the tree you are searching is or may be ignored, pass `rg -uu` (or
`--no-ignore`), or use `command grep -r`. Check `git check-ignore -v <path>` if unsure.

**And treat the result as a claim, not a finding:** "the search found nothing" inside an ignored
tree is *unverified*, not clean. This is the §1 failure in a different costume — the command
succeeded, the conclusion is wrong, and an audit that concludes "absent" from it is an audit
conducted with a tool blind to its own subject.

## 9. SILENT — `$var:something` eats the next letter (history modifiers), and QUOTES DON'T HELP

zsh applies **history modifiers** to an unbraced parameter expansion. `$ref:t` means "the tail of
`$ref`" — so writing a colon-separated argument built from a variable silently loses a character:

```
ref=22cc96be
echo "$ref:tests/foo.sh"     # -> 22cc96beests/foo.sh    the `t` is GONE
echo "${ref}:tests/foo.sh"   # -> 22cc96be:tests/foo.sh  correct
```

**Two things make this worse than it looks:**

- **Double quotes do NOT protect you.** This is the opposite of the usual instinct, and it is why
  the bug survives review — the line already looks quoted-and-safe.
- **It is not only `:t`.** `:h` `:r` `:e` `:a` and others are all modifiers, so `$ref:hooks/…`,
  `$ref:README`, `$ref:etc/…` and `$ref:api/…` break the same way, each eating its first letter.

**Where it actually bites:** `git` refspecs, which are colon-separated by design.
`git show "$ref:tests/x"` reads a path that does not exist; `git show` then fails with a message
about the mangled path, which reads like the file is missing rather than like a quoting bug.
`HEAD:tests/x` is fine because it is a literal — the trap needs a VARIABLE on the left.

**Rule: brace any parameter followed by a colon.** `"${ref}:path"`, always. If you are writing a
refspec, a `host:path` scp target, or anything else colon-delimited from a variable, the braces are
not optional style.

## 10. LOUD — a word starting with `=` is a command lookup (EQUALS expansion)

zsh expands `=word` to the full path of the command `word`, the same as `$(which word)`. So a
banner or separator that starts with `=` runs a lookup and fails:

```
echo === RESULT ===        # -> zsh: == not found     (the whole command dies)
echo "=== RESULT ==="      # correct: quoted
print -r -- '=== RESULT ==='
```

It is loud, which is the good news. The bad news is that it tends to sit in the middle of a long
compound command, so everything before it ran and everything after it did not. Quote any argument
that starts with `=`.

## 11. SILENT — backticks inside a double-quoted `git commit -m` RUN

Inside double quotes, `` `...` `` is command substitution in every POSIX shell, zsh included. A
commit message that cites code the usual markdown way, `-m "the fix is `uv tool install` once"`,
runs `uv tool install` and pastes its output (usually nothing) into the message. There is no error
and the exit status is 0; the message just silently loses the phrase. It is the sharpest of these
traps because it is found after the push, when fixing it needs a history rewrite.

Single-quoting `-m` is not the fix, because prose contains apostrophes. Feed the message on stdin
from a quoted heredoc instead:

```
git commit -F - <<'MSG'
subject line

The fix is `uv tool install` once from an unsandboxed shell.
MSG
```

The quoted delimiter (`<<'MSG'`) turns off every expansion inside, backticks and `$` alike.

## 12. SILENT — a git pathspec `dir/**/*.md` skips the files directly in `dir/`

Not zsh, but it fails the same way: a subset at exit 0. Without the `:(glob)` magic, git matches a
pathspec with `fnmatch` where `*` already crosses `/`, so `**/` demands one MORE directory level and
the top-level files drop out:

```
git ls-files -- 'docs/**/*.md'          # docs/sub/deep.md          (docs/top.md MISSING)
git ls-files -- 'docs/*.md'             # docs/sub/deep.md docs/top.md
git ls-files -- ':(glob)docs/**/*.md'   # docs/sub/deep.md docs/top.md
```

Use `docs/*.md` for the whole tree, or `:(glob)` when you want `**` to mean what it means in zsh.
A gate that enumerated with the first form once judged zero top-level documents and passed.

## 13. LOUD — a function cannot take a name that is already an alias

```zsh
g() { git status; }     # with `alias g=…` loaded:
# defining function based on alias `g'
# parse error near `()'
```

zsh expands the alias before it sees the `()`, so the definition itself is a syntax error. Even the
`function g { … }` form, which does define it, loses at call time, because the alias is expanded
first. Pick a name that is not an alias; `whence -w <name>` says what a name currently is. Seen in
test fixtures that used short helper names like `g`.

## 14. LOUD — `/tmp` is read-only inside the agent's Bash sandbox

`> /tmp/out.txt` fails with `read-only file system: /tmp/out.txt`. The sandbox gives each session a
writable scratch directory in `$TMPDIR`; write there (`"$TMPDIR/out.txt"`), and pass it to tools that
take a temp-directory flag. The most frequent trap in this list, and entirely avoidable.

## 15. LOUD — prose inside single quotes ends at its first apostrophe

`git commit -m 'don't stage it'` fails with `unmatched '`, because the apostrophe closes the string.
Backticks and double quotes in prose do the same inside their own quoting (§11). Anything longer
than a phrase goes in a quoted heredoc, which does no expansion at all:

```zsh
git commit -F - <<'MSG'
Don't stage it: the `build/` output is regenerated.
MSG
```

## 16. Bound every scan whose output size you do not know

`grep -o`, `rg`, `strings` or `cat` over a large or binary file can print megabytes into the session,
which costs context and can bury the one line you wanted. Bound it before running it:
`rg -m 20 --max-columns 200 …`, `… | head -50`, `wc -c` first when unsure. For a file you will query
more than once, extract once to a text file and search that.

## 17. SILENT — waiting: a bare `wait` never returns in the sandbox, and a leading `sleep` is refused

Inside the agent's Bash sandbox, the wrapper starts its network proxies (two `socat` processes) as
background jobs of the same shell your command runs in; `jobs -l` lists them. A bare `wait` waits for
every job, those included, so it hangs until the call's timeout kills it, and whatever follows it
never runs. Wait on the processes you started, by id:

```zsh
cmd-one & p1=$!; cmd-two & p2=$!
wait $p1 $p2
```

Waiting for something to finish is not a foreground `sleep`. The tool refuses a long leading
`sleep N` (`Blocked: sleep … followed by …`), and chaining shorter ones to get under the limit is
the same refusal deferred. Instead:

- **A command you start:** run it with `run_in_background: true`. You are told when it exits, and
  its output is captured to a file you can read any number of times.
- **A condition you wait for** (a server comes up, a file appears, a remote run ends): a
  background command that exits when the condition holds, `until <check>; do sleep 2; done`. Use
  the Monitor tool only when you want an event per occurrence rather than one at the end, and make
  its filter match the failure states too, or a crash reads as "still running".

## 18. LOUD — `rm` on a path built from a variable is refused, and should be

`rm -rf $B/build` is `rm -rf /build` the moment `B` is empty, and auto mode's permission check refuses it on sight ("Dangerous rm operation on
possibly-empty variable path"). That a variable happens to be set this time is exactly the
assumption the check exists to refuse, so do not argue with it. In order of preference:

- **Do not delete.** Give each run a fresh name and refuse one that exists
  (`[ -e "$d" ] && { echo "$d exists" >&2; exit 1; }`); let the session's scratch directory go
  with the session.
- **Name the path literally**, when it is one known directory.
- **Make an empty variable an error:** `rm -rf -- "${B:?}/${n:?}-origin.git"`. `${var:?}` stops
  the command when the variable is unset or empty.

`set -u` does not cover it: it catches an unset variable, not an empty one.

## How you can tell it went wrong

- **`no matches found: <thing>`** — an unquoted glob, often inside an option value (§2).
- **`bad option: -`** — `print`/`echo` ate your leading dash (§5).
- **A search returned nothing, and you are about to report "not present"** — check the argument
  count first (§1), then check whether the tree is gitignored (§8). This is the failure that
  corrupts conclusions rather than commands.
- **A path or ref in an error message is missing exactly one letter** (`…ests/`, `…ooks/`) — a
  colon after an unbraced variable ate it (§9).
- **A check passed that you expected to fail** — suspect the pipeline exit status (§3) before
  believing it. A gate that cannot fail proves nothing.
- **`zsh: <word> not found` where `<word>` is part of your own text** (`== not found`) — an
  argument starts with `=` (§10).
- **A commit message is missing a phrase you wrote in backticks** — command substitution ran
  inside a double-quoted `-m` (§11).
- **`command not found` only over SSH** — you are calling a shell function, or a tool whose `PATH`
  entry only `.zshrc` adds, in a non-interactive shell (§7).
- **`read-only variable: status`** — `status` is `$?` under another name (§5b).
- **`bad substitution`** on `${!…}` — bash indirect expansion; zsh spells it `${(P)…}` / `${(k)…}` (§6).
- **`defining function based on alias`** — the function name is an alias (§13).
- **`read-only file system: /tmp/…`** — write to `$TMPDIR` (§14).
- **`unmatched '`** — an apostrophe in prose closed a single-quoted string (§15).
- **A command that runs jobs in parallel finishes them but never prints what follows `wait`**, or a
  background task hits its time limit after its work is done — a bare `wait` (§17).
- **`Blocked: sleep …`** — wait in the background, not in the foreground (§17).
- **`Dangerous rm operation on possibly-empty variable path`** — do not delete, or guard with
  `${var:?}` (§18).
