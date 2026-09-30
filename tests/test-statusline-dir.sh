#!/usr/bin/env zsh
# Unit test for the status line's working-directory segment.
#
# The segment renders the LAST TWO path segments. The failure it exists to prevent is
# specific: under the bare-container repo layout every session sits in a directory
# named after its branch, so a basename-only segment renders "main" for every one of them and
# stops identifying anything.
set -u
HERE=${0:A:h}
LINE="$HERE/../dot_claude/statusline-command.sh"
[[ -f "$LINE" ]] || { print "FAIL: statusline not found at $LINE"; exit 1 }

fail=0
ok()  { print "ok:   $1" }
bad() { print "FAIL: $1"; fail=1 }

# Drive the real script's own helper rather than a copy, so the test cannot pass
# against a function that has drifted from the one the status line actually calls.
render() {  # render <cwd>
    HOME=/home/tester bash -c '
        input="{}"
        '"$(sed -n '/^path_tail() {/,/^}/p' "$LINE")"'
        path_tail "$1"
    ' _ "$1"
}

check() {  # check <cwd> <expected> <description>
    local got; got=$(render "$1")
    [[ "$got" == "$2" ]] && ok "$3 ($1 -> $got)" \
        || bad "$3: $1 -> '$got', expected '$2'"
}

# The motivating case: two sessions whose basenames are identical and whose
# two-segment renders are not. If these ever collide again, the segment is useless.
check /home/tester/Devel/org/repo-a/main   repo-a/main   "bare-container worktree names its repo"
check /home/tester/Devel/org/repo-b/main   repo-b/main     "a second repo is distinguishable"
[[ "$(render /home/tester/Devel/org/repo-a/main)" != "$(render /home/tester/Devel/org/repo-b/main)" ]] \
    && ok "two sessions on the same branch render differently" \
    || bad "two sessions collide - the segment identifies nothing"

# Ordinary checkouts: checkouts outside the bare-container layout.
check /home/tester/Devel/org/repo-a           org/repo-a  "ordinary checkout keeps org context"

# $HOME collapses, so the account name is never a rendered segment.
check /home/tester/Devel                          '~/Devel'       "path under home collapses to tilde"
check /home/tester                                '~'             "home itself renders as tilde"
[[ "$(render /home/tester/Devel)" != *tester* ]] \
    && ok "account name does not leak into the segment" \
    || bad "account name leaked: $(render /home/tester/Devel)"

# Degenerate inputs. A status line must never abort the way a bare basename call would.
check /                                           /               "root renders as itself"
check /mnt                                        mnt             "single top-level segment"
check ''                                          ''              "empty cwd renders empty, does not error"
check /home/tester/Devel/                         '~/Devel'       "trailing slash ignored"

(( fail )) && { print "\nFAILURES"; exit 1 }
print "\nALL PASS"
