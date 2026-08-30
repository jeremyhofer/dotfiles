---
name: writing-zsh-commands
description: LOAD THIS BEFORE WRITING ANY SHELL COMMAND ON THIS MACHINE. The shell is zsh, not bash, and the differences fail SILENTLY — wrong output, not an error. Do NOT skip it because the command "looks simple" or because the shell is incidental to some larger task: the traps fire on one-liners (a glob that matches nothing, a loop over a variable, a `local` parameter named `path`, a directory whose name starts with `-`) and typically return an empty result, a zero count, or a false success rather than failing. If you are about to run Bash, this applies. Also use when a command fails with "no matches found", "bad option", "parse error near", or "command not found" for a tool that plainly exists (usually PATH clobbered by a variable named `path`), or when a command "worked" but returned nothing, matched nothing, counted zero, or reported success it should not have.
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

## 6. Bash-only constructs that are simply absent

`mapfile` / `readarray` do not exist (a loop over them silently does nothing), and `$PIPESTATUS`
is `$pipestatus`. If you genuinely need bash semantics, say so explicitly — `bash -c '…'` is the
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
it needs to be a real script on `PATH`, not a function.

## 8. SILENT — a recursive search skips whatever the repo ignores, and `rg` does NOT fix it

`rg` and the `grep` shim installed here are **both gitignore-aware by default**. So a plain
recursive search inside an ignored tree — `node_modules/`, build output, a vendored or preserved
directory, a `.superpowers/` checkout — reports **zero matches, by design, with no warning and exit
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
- **`command not found` only over SSH** — you are calling a shell function in a non-interactive
  shell (§7).
