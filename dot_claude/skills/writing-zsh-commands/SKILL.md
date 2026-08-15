---
name: writing-zsh-commands
description: Use when composing any non-trivial shell command — anything with a variable holding multiple values, a glob, a pipeline whose exit status you check, a loop, an array, or a command run over SSH — and when a command fails with "no matches found", "bad option", "parse error near", or "command not found" on a remote host, or when a command "worked" but returned nothing, matched nothing, or reported success it should not have. The interactive shell here is zsh, not bash, and several bash habits fail silently rather than loudly.
---

# Writing shell commands under zsh

**The shell is zsh.** Most bash syntax works, but a handful of habits do not — and the dangerous
ones are the ones that **fail silently**, producing a plausible wrong answer instead of an error.

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

## How you can tell it went wrong

- **`no matches found: <thing>`** — an unquoted glob, often inside an option value (§2).
- **`bad option: -`** — `print`/`echo` ate your leading dash (§5).
- **A search returned nothing, and you are about to report "not present"** — check the argument
  count first (§1). This is the failure that corrupts conclusions rather than commands.
- **A check passed that you expected to fail** — suspect the pipeline exit status (§3) before
  believing it. A gate that cannot fail proves nothing.
- **`command not found` only over SSH** — you are calling a shell function in a non-interactive
  shell (§7).
