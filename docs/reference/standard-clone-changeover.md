# Changing a repository from a bare container to a standard clone

For a machine that runs only the public dotfiles base: no private overlay, possibly no custom Claude
Code hooks, and Claude Code running inside a managed sandbox. Change one repository at a time,
starting with one you rarely touch. `docs/reference/repository-layouts.md` describes the layouts;
this page is the procedure for moving between them.

## Terms

- **Repository**: git's database of commits, branches and tags. In an ordinary checkout it lives in
  the `.git/` directory at the project's root.
- **Bare repository**: a repository with no files checked out next to it, only the database. A
  server's copy is bare. `git rev-parse --is-bare-repository` prints `true` for one.
- **Worktree**: a directory where one branch's files are checked out. An ordinary clone has one, the
  **main worktree**, at its root. `git worktree add` creates more, called **linked worktrees**, each
  on its own branch and all sharing one repository.
- **Bare container**: the layout being left. `<repo>/.git/` is a bare repository and every branch,
  the default one included, is a linked worktree beside it: `<repo>/main/`, `<repo>/<branch>/`.
  Nothing is checked out at `<repo>/` itself.
- **Standard clone**: the layout being moved to. `<repo>/` is the main worktree, on the branch you
  normally work on, and extra worktrees nest inside it at `<repo>/.worktrees/<name>`.
- **Untracked file**: a file in a worktree that git does not record. `git status` lists it.
- **Ignored file**: an untracked file matched by a `.gitignore`, by `.git/info/exclude` (a
  per-repository ignore list that is never committed) or by your global ignore file. `git status`
  hides it. Build output and installed dependencies are ignored, and so are many files that matter:
  `local.properties`, signing configuration, `.env` files, per-user IDE state. **A fresh clone has
  none of them.**
- **Sandbox**: a restriction the operating system places on a program, limiting which files it may
  read or write and which network hosts it may reach. Claude Code runs the commands it issues inside
  one. On a managed machine its rules are set by the people who administer the machine.

## Why

In a bare container no directory is "the project": every branch is a sibling directory, and the
container root holds no checkout. Android Studio and Xcode expect to open a project whose root is an
ordinary checkout, and they handle the bare layout poorly. Tools that keep shared data at "the main
worktree's root", such as a build cache, end up at the container root, outside every checkout. A
sandboxed tool that may write only the directory it was started in cannot reach the sibling
worktrees beside it. A standard clone puts the checkout, its caches and its extra worktrees under
one root, which is the layout these tools assume.

## The method in one paragraph

Nothing is converted in place. The container is renamed to `<repo>.old` and never modified again; a
fresh clone is made at the original path; everything the fresh clone lacks is restored by hand from
an inventory taken beforehand; the result is verified; and the old directory is deleted only after a
full working sitting in the new clone (a real stretch of work including a commit and a push).
Converting in place edits the only copy, so a mistake can destroy ignored data that exists nowhere
else. With the rename, going back is one `mv`.

**Do every git operation on the old container BEFORE renaming it.** A linked worktree records its
repository by absolute path, so after the rename every old worktree fails with
`fatal: not a git repository`. Its files stay readable, which is all the restore needs, but you can
no longer commit, stash or run `git status` there.

## 1. Before you start

- Close the repository in Android Studio and Xcode; stop Gradle daemons (`./gradlew --stop`) and any
  watcher, dev server or agent session working in it.
- Free disk for a second copy: the old directory stays until step 8.
- **Ignore `.worktrees/` in the repository's own `.gitignore`, before any worktree exists.** You
  will add it in the first commit after the clone (step 4); this is why it matters. Tools that walk
  a project tree, such as Nx, ESLint, Prettier and the IDEs, do not know that a nested directory is
  a separate checkout. Without the ignore they find a second copy of every source file under
  `.worktrees/`, and act on both copies. This was measured to break Nx, which saw the nested copies
  as additional projects. `git status` also lists each worktree as untracked, and a `git add -A`
  would stage it. A tool's own ignore list is a separate file from `.gitignore` (Prettier reads
  `.prettierignore`, ESLint reads its ignore patterns): check each one the repository uses.
- Optionally, also cover `.worktrees/` in your global ignore file, so repositories you have not
  converted yet behave. Git reads one global ignore file, named by `git config core.excludesfile`,
  and the base does not supply one. The repository's own `.gitignore` is the one that protects every
  clone and every teammate, so it is not optional.

## 2. Inventory: what would a fresh clone not have?

Save this as `inventory.sh` anywhere outside the repository and run `bash inventory.sh <repo>` for
each container, saving the output (`bash inventory.sh ~/src/app > ~/app-inventory.txt`). It only
reads, apart from a `git fetch`, which updates remote-tracking refs (git's local record of where each
remote's branches were at the last fetch) so the comparisons are current. It runs under macOS's
bash 3.2 and Linux bash alike.

```bash
#!/usr/bin/env bash
# inventory.sh <container> -- read-only apart from a fetch. Prints what a fresh clone lacks.
set -u
c=${1:?usage: bash inventory.sh <path-to-container>}
c=${c%/}
if [ -d "$c/.git" ]; then g="$c/.git"
elif [ -f "$c/.git" ]; then
  gd=$(sed -n 's/^gitdir: //p' "$c/.git")
  case $gd in /*) g=$gd ;; *) g="$c/$gd" ;; esac   # the pointer may be absolute or relative
else echo "no .git in $c" >&2; exit 1; fi
G() { git --git-dir="$g" "$@"; }

echo "######## $c   (bare: $(G rev-parse --is-bare-repository))"
G fetch --all --quiet || echo "!! fetch failed: the remote comparisons below may be stale"

echo "-- remotes:"; G remote -v | sed 's/^/   /'
echo "-- remote-tracking refs: $(G for-each-ref refs/remotes | wc -l | tr -d ' ')   (0: see the note below)"
echo "-- local branches: name | upstream | commits on NO remote"
for b in $(G for-each-ref --format='%(refname:short)' refs/heads); do
  printf '   %s | %s | %s\n' "$b" "$(G for-each-ref --format='%(upstream:short)' "refs/heads/$b")" \
    "$(G rev-list --count "$b" --not --remotes)"
done
echo "-- stashes: $(G rev-list --walk-reflogs --count refs/stash 2>/dev/null || echo 0)"
echo "-- tags not on origin:"
comm -23 <(G tag | sort) <(G ls-remote --tags --refs origin | sed 's#.*refs/tags/##' | sort) | sed 's/^/   /'
echo "-- repository-local config (remote.* and branch.* omitted):"
G config --local --list | grep -v -e '^remote\.' -e '^branch\.' | sed 's/^/   /'
echo "-- hooks (not samples):"
ls "$g/hooks" 2>/dev/null | grep -v '\.sample$' | sed 's/^/   /'
echo "-- extra entries in the git directory:"
ls -A "$g" | grep -v -x -e HEAD -e config -e description -e hooks -e info -e logs -e objects \
  -e refs -e packed-refs -e worktrees -e FETCH_HEAD -e ORIG_HEAD -e index -e COMMIT_EDITMSG | sed 's/^/   /'
echo "-- info/exclude (non-comment lines):"
grep -v -e '^#' -e '^$' "$g/info/exclude" 2>/dev/null | sed 's/^/   /'
echo "-- container root entries:"
ls -A "$c" | sed 's/^/   /'

# each linked worktree (the bare repository's own entry is skipped)
G worktree list --porcelain |
  awk '/^worktree /{p=substr($0,10)} /^bare$/{p=""} /^$/{if(p!="")print p; p=""} END{if(p!="")print p}' |
  while IFS= read -r w; do
    echo "-- worktree $w"
    echo "   branch: $(git -C "$w" branch --show-current)"
    echo "   modified, staged or untracked (not ignored):"
    git -C "$w" status --short | sed 's/^/      /'
    echo "   ignored (common regenerable directories hidden):"
    git -C "$w" status --short --ignored | sed -n 's/^!! //p' |
      grep -v -E '(^|/)(node_modules|build|\.gradle|\.cxx|Pods|DerivedData|\.build|\.nx|dist|coverage)/$' |
      sed 's/^/      /'
  done
```

How to read it:

- **commits on NO remote** counts commits on a branch that no remote-tracking ref contains. `0`
  means a fresh clone can get the branch from the server; anything else exists only here.
- **remote-tracking refs: 0** happens when a container was made with a plain `git clone --bare`,
  which records no remote-tracking refs, so every branch reads as unpushed. Compare by hand with
  `git ls-remote origin <branch>` against `git --git-dir=<repo>/.git rev-parse <branch>`.
- **stashes** are shared by all worktrees of a repository and do not survive the move. Deal with
  them now (step 3).
- **hooks** that are not samples were installed by something: a tool such as husky, lefthook or
  pre-commit, a build step, or you. Note which.
- **extra entries in the git directory** are state other tools keep there. `modules/` means the
  repository has submodules; a fresh clone needs `git submodule update --init`. Anything else, find
  out what wrote it before deciding.
- **ignored**, per worktree, is the list the restore works from. The script hides common build and
  dependency directories; everything it shows needs a decision in step 3. Directories are shown
  collapsed (`config/` rather than each file in it).

## 3. Decide each item: push, carry, restore, regenerate or leave

| Inventory line | Decision |
| --- | --- |
| A branch with commits on no remote | **Push it** where the team's conventions allow personal branches on the remote. Otherwise **carry it**: step 4 fetches it straight from the old directory, no push needed. Or **leave it** in `.old` if it is finished with. |
| A branch at `0` | Nothing to do; the clone's remote has it. Recreate a worktree for it only if you want one. |
| Modified or staged files in a worktree | Commit them to their branch now (then that branch is "a branch with commits on no remote"), or stash and resolve below. |
| A stash | Apply it in a worktree and commit it to a branch, or save it: `git -C <repo>/<branch> stash show -p 'stash@{0}' > ~/stash-0.patch`. Do this before the rename. |
| A tag not on origin | Push it (`git push origin <tag>`), or carry it in step 4. |
| Repository-local config | Re-set what you chose deliberately (`user.email` for a work identity, say) with `git config` in the new clone. **Never carry `core.bare`.** |
| A hook | Re-run whatever installed it, in the new clone, after dependencies are installed. Do not copy hook files: installers often write absolute paths into them, which point at the old layout. |
| `info/exclude` lines | Append the ones you added yourself to the new clone's `.git/info/exclude`. |
| An ignored file | **Restore** when it cannot be recreated cheaply: `local.properties`, keystores and signing properties, `.env` files, `GoogleService-Info.plist` or `google-services.json` if the team distributes them by hand, Xcode `xcuserdata/` (your schemes and breakpoints), local data. **Regenerate** build output and dependencies. **Leave** anything you do not recognise: it stays in `.old`. |

Credentials need their file mode kept: copy with `cp -a` (or `cp -p`), never by opening and saving.

## 4. The changeover

For a repository at `~/src/app` whose working branch is `main` (substitute your own):

```sh
cd ~/src
git --git-dir=app/.git remote -v          # note every remote's name and URL
mv app app.old                            # from here on, app.old is only read
git clone <origin-url> app                # the URL `origin` showed above
cd app
git switch main                           # only if the clone landed on another branch
```

**A very large repository** (a long history, or a monorepo with many branches) can be cloned for one
branch only, which downloads far less:

```sh
git clone --single-branch --branch main <origin-url> app
```

A single-branch clone fetches only that branch, so `git fetch` later also fetches only that branch.
To work on another, fetch it by name (`git fetch origin feature-x:refs/remotes/origin/feature-x`),
or widen the clone with `git remote set-branches origin '*'` followed by `git fetch origin`. If the
repository is very large because of its history, a partial clone (`--filter=blob:none`) is a further
option; it defers downloading file contents until they are needed, so it needs the remote reachable
afterwards.

Then, inside `~/src/app`:

```sh
git remote add <name> <url>                              # each remote other than origin
git fetch ../app.old/.git 'refs/heads/my-branch:refs/heads/my-branch'   # carry a local-only branch
git fetch ../app.old/.git 'refs/tags/my-tag:refs/tags/my-tag'           # carry a local-only tag
git submodule update --init --recursive                  # only if the inventory showed modules/
git rev-parse --is-bare-repository                       # must print false
```

`git fetch <path>` reads another repository on disk directly, so a branch or tag that was never
pushed comes across without touching the server. The old bare repository still works for this after
the rename; only its worktrees broke.

Make the first commit in the new clone the one that adds `.worktrees/` to `.gitignore` (step 1),
before any worktree is made.

If this machine lists its repositories in a mani manifest (`docs/reference/fleet-manifest.md`),
update the entry in the same sitting. `path:` names the clone root (`app`, not `app/main`); declare
the branch you work on with mani's `branch:` key; and remove the `clone:`, `container:`,
`worktrees:` and `worktrunk: layout: bare` lines. For example:

```yaml
projects:
  app:
    path: src/app
    url: git@example.com:team/app.git
    branch: main
```

Then run `wt-config-gen`, so worktrunk stops placing this repository's worktrees as siblings. Until
the CHANGELOG entry announcing standard-clone support in `fleet-repo`, do not run `fleet-repo clone`
or `fleet-repo check` on a converted entry: it is written for the bare shape. After a `git pull` of
the base, read the CHANGELOG to see whether that entry has landed.

## 5. Restore from the inventory

Work through the inventory's ignored files and the decisions from step 3. Everything that lived in
the old default-branch worktree (`app.old/main/`) goes to the same relative path under the clone
root. Paste this helper into the shell first (it works in zsh and bash, and never overwrites):

```sh
OLDWT=~/src/app.old/main     # the old worktree you are copying from
NEW=~/src/app                # where its files go
restore() {
  src="$OLDWT/$1"; dst="$NEW/$1"
  if [ -e "$dst" ] || [ -L "$dst" ]; then echo "exists, skipped: $dst"; return 1; fi
  mkdir -p "$(dirname "$dst")" && cp -a "$src" "$dst" && echo "restored: $1"
}
restore local.properties
restore app/keystore.properties
restore 'MyApp.xcodeproj/xcuserdata'      # quote any path with spaces or glob characters
```

For files that lived in another branch's worktree (`app.old/feature-x/`), make that worktree first
(step 6), then point the helper at it: `OLDWT=~/src/app.old/feature-x`,
`NEW=~/src/app/.worktrees/feature-x`.

Then the regenerated half:

- install dependencies from the lockfile (`npm ci`, `pod install`, `bundle install`, and so on);
- re-run each hook installer the inventory pointed to;
- re-set the repository-local config you chose to keep;
- open the project in its IDE once (step 6), which regenerates the IDE's own state.

**Files every new worktree needs** (`local.properties` is the usual one) can be listed in a
`.worktreeinclude` file at the clone root, one ignore-style pattern per line. With the base's
worktrunk configuration, `wt switch --create` then copies each listed file that is also ignored into
the new worktree. The file can be committed if the team shares the convention, or kept local and
hidden by adding `.worktreeinclude` to `.git/info/exclude`.

## 6. Worktrees and the IDEs

**Worktrees now live inside the clone**, at `<repo>/.worktrees/<name>`. The base's worktrunk
configuration places them there for any repository that is not a bare container; nothing per
repository is needed.

```sh
cd ~/src/app
wt switch --create feature-y     # new branch and worktree at .worktrees/feature-y, and cd into it
wt switch feature-x              # an existing branch: makes its worktree if needed, and cd into it
wt list                          # every worktree with its branch and state
```

`wt switch` changes directory only from an interactive shell, because it is a shell function; in a
script, use `command wt switch <branch> --no-cd` and `cd` yourself. For a branch that exists on more
than one remote, create the local branch first (`git branch --track feature-x origin/feature-x`),
since git will not guess between remotes.

**Removing a worktree.** From a terminal, with the branch landed:
`wt remove --no-hooks --foreground <name>`. From inside a Claude Code session that entered the
worktree with its `EnterWorktree` tool, leave with `ExitWorktree` set to `keep`, never `remove`, and
then run that `wt remove` command from a terminal. The `remove` action deletes the directory without
the checks `wt remove` makes, and the base does not exempt the `wt remove` command from the sandbox,
so a session cannot run it for you.

**Android Studio** (Unverified: confirm on your installed version):

- Open the clone root, or the Gradle root inside it if the Android project is a subdirectory.
- Open a worktree as its own project (File > Open, `.worktrees/<name>`). Each gets its own `.idea/`
  state, Gradle sync and `local.properties`, which is where `.worktreeinclude` earns its keep.
- Keep the main project from indexing the nested worktrees: Settings > Editor > File Types >
  "Ignored Files and Folders", add `.worktrees`. It applies to every project, which is what you
  want. If the IDE offers to register `.worktrees/<name>` as an extra git root, decline.

**Xcode** (Unverified: confirm on your installed version):

- Open the `.xcodeproj`, `.xcworkspace` or `Package.swift` in the clone root, and for a worktree the
  one under `.worktrees/<name>`, as a separate window.
- Xcode keys DerivedData (its build folder, under `~/Library/Developer/Xcode/DerivedData/`) by the
  project's path, so each worktree builds from scratch the first time and keeps its own copy. Delete
  a worktree's DerivedData folder when you remove the worktree.
- Pods and other installed dependencies are per worktree: run `pod install` (or the equivalent) in
  each.
- Check that no folder reference or synchronized group points at the repository root; one that did
  would pull `.worktrees/` into the project.

**Claude Code**, if you use it there: a background session moves itself into a new worktree before
its first edit by default. A repository where it should edit the checkout it was started in can set
that in `.claude/settings.local.json`, which is never committed:

```json
{ "worktree": { "bgIsolation": "none" } }
```

The setting was observed working by the author on Claude Code 2.1.296. On an older version it may be
ignored without any message, so check `claude --version` first, and confirm the behaviour once.

## 7. Verify

In the new clone:

```sh
git rev-parse --is-bare-repository          # false
git status                                  # clean, on the branch you expect
git branch -vv                              # every carried branch present, upstreams as expected
git tag | wc -l                             # matches the old count, plus or minus what you chose
git -C ~/src/app check-ignore -v .worktrees/probe   # prints the rule that ignores it
```

Then compare what you restored against the old files (`cmp` each restored file with its original, or
`diff -r` a restored directory), build and run the app from the IDE, run the test suite, and make one
commit and push from the new clone, so signing and hooks are proven rather than assumed. If the
repository uses a tree-walking tool such as Nx, run it with a worktree present:
`wt switch --create convert-probe`, then check that the tool still sees one copy of each project and
that `git -C ~/src/app status` does not list `.worktrees/`. Remove the probe as described in step 6,
and delete its branch.

## 8. Delete the old directory only after a full working sitting

Keep `<repo>.old` until you have worked in the new clone through a full sitting that included a
commit and a push: it is the only copy of anything the inventory missed. Before deleting it, re-read
the saved inventory and confirm each item is in the clone, on the server, or deliberately left. Then
delete the directory (for example `~/src/app.old`) with your usual tool.

Remove the old paths from Android Studio's and Xcode's recent-projects lists, and delete the old
worktrees' DerivedData folders; both still point at paths that no longer exist.

## Sandboxes that deny secret-shaped files

A managed machine's sandbox may carry **read-denies** on files whose names look like secrets:
`.npmrc`, `.env` and similar. A read-deny makes those files invisible to every command Claude Code
runs, whatever their contents. This interacts badly with git. A checkout, a worktree creation or a
branch switch writes every tracked file in the target branch, and if a repository tracks a file with
one of those names, git must read or replace it. The operation then fails partway, in the sandbox
only, leaving a half-populated worktree. A terminal outside the sandbox does not see the problem.

This has not been measured on every managed machine, so treat the list below as **candidates to
measure**, not a recipe. For each, try it on a throwaway worktree first and record whether the
operation completes and whether the secret-shaped files end up intact.

1. **Claude Code's own worktree creation** (the `EnterWorktree` tool, or a subagent started with
   worktree isolation). It may create the worktree by a path that does not hit the deny. Unmeasured.
2. **Run checkout operations from a terminal**, outside the sandbox: `wt switch --create <name>`,
   then start the session inside the new worktree. Likely to work, since the deny does not apply
   there. The cost is that a session cannot make its own worktrees.
3. **A sandbox exemption**, if the machine's policy allows one for the specific git commands. Ask
   whoever owns the policy; do not edit the managed settings yourself.
4. **A sparse checkout** (git's feature for checking out only some paths of a branch) that excludes
   the secret-shaped files, set up from a terminal. It must be set up from a terminal because
   configuring it inside the sandbox fails: git has to lock `.git/config` to enable it, and the
   sandbox does not allow that write. Once set up, whether later operations inside the sandbox honour
   it is unmeasured.
5. **Ask the policy owners for a narrower rule**: deny reads of the files in the project root only,
   or only untracked ones, rather than the name everywhere. This is a request to a person, not
   something to engineer around.

Whichever you choose, do not copy the secret-shaped files out of the repository to dodge the deny:
the deny exists on purpose, and routing around it is a decision for the policy owners.
