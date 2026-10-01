#!/usr/bin/env zsh
# Test the chpwd leak-guard check in .chezmoitemplates/zshrc.guard-check.
#
# WHY THIS HAS A SUITE AT ALL. It is six lines, but its failure modes are both silent and opposite:
# never run (the guard is dark and nothing says so -- the exact defect class the guard exists for,
# one layer up) or run on every single directory change (becomes wallpaper, which is the same
# silence wearing a different hat). Neither shows up as an error, so neither is noticeable in use.
#
# Runs against a STUB hook-doctor so the assertions are about the caching and the invocation, not
# about the checker's verdicts, which test-hook-doctor.sh already covers.
set -u
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=${0:A:h}
frag="$here/../.chezmoitemplates/zshrc.guard-check"
tmp=$(mktemp -d "$_TMP/test-hd-chpwd.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
fails=0
ok()  { printf '  ok    %s\n' "$1" }
bad() { printf '  FAIL  %s\n     %s\n' "$1" "$2"; fails=$((fails+1)) }

mkdir -p "$tmp/stub"
printf '#!/bin/sh\necho ran >> "%s/calls"\necho "$*" >> "%s/args"\n' "$tmp" "$tmp" > "$tmp/stub/hook-doctor"
chmod +x "$tmp/stub/hook-doctor"
export PATH="$tmp/stub:$PATH"
export XDG_STATE_HOME="$tmp/state"

source "$frag" 2>/dev/null
calls() { [ -f "$tmp/calls" ] && wc -l < "$tmp/calls" | tr -d ' ' || echo 0 }

# A real repo to stand in; the function needs `git rev-parse --show-toplevel` to succeed.
repo="$tmp/repo"; mkdir -p "$repo"
git -c init.defaultBranch=main init -q "$repo"
cd "$repo"

# --- 1. it runs -----------------------------------------------------------------------------------
_hook_doctor_chpwd
[ "$(calls)" = 1 ] && ok "runs on first entry to a worktree" || bad "did not run" "calls=$(calls)"

# --- 1b. it asks for the one-directory, silent form of the check ----------------------------------
# `--quiet` is what keeps it silent when clean, which is the requirement for something that fires on
# a directory change; `--path` keeps it fast and independent of the manifest.
top=$(git rev-parse --show-toplevel)
[ "$(head -1 "$tmp/args")" = "check --path $top --quiet" ] && ok "invokes: check --path <worktree> --quiet" || bad "wrong invocation" "args=$(head -1 "$tmp/args")"

# --- 2. it is CACHED: further entries the same day must not re-run ---------------------------------
_hook_doctor_chpwd; _hook_doctor_chpwd; _hook_doctor_chpwd
[ "$(calls)" = 1 ] && ok "cached: 4 entries in one day = 1 invocation" || bad "ran again same day" "calls=$(calls)"

# --- 3. a STALE stamp must re-run. The manufactured red for the cache never expiring ---------------
stamp=$(ls "$XDG_STATE_HOME"/hook-doctor/*.checked 2>/dev/null | head -1)
if [ -n "$stamp" ]; then
  printf '19700101' > "$stamp"
  _hook_doctor_chpwd
  [ "$(calls)" = 2 ] && ok "stale stamp re-runs the check" || bad "stale stamp did NOT re-run" "calls=$(calls)"
else
  bad "no stamp file written" "cache cannot expire if it never records"
fi

# --- 4. outside a git repo it must be a no-op ------------------------------------------------------
cd "$tmp"
_hook_doctor_chpwd
[ "$(calls)" = 2 ] && ok "no-op outside a git repository" || bad "ran outside a repo" "calls=$(calls)"

# --- 5. hook-doctor absent must be a no-op, not an error -------------------------------------------
# A machine without it (or mid-bootstrap) must not get an error on every cd.
cd "$repo"
PATH=/usr/bin:/bin _hook_doctor_chpwd 2>"$tmp/err"
[ -s "$tmp/err" ] && bad "errored when hook-doctor is absent" "$(cat "$tmp/err")" || ok "silent no-op when hook-doctor is not installed"

printf '\n'
[ "$fails" -eq 0 ] && printf 'all chpwd checks passed\n' || printf '%s check(s) FAILED\n' "$fails"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
