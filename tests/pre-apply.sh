#!/bin/sh
# pre-apply -- before `chezmoi apply` deploys this source tree, run the suites that cover what the
# apply is about to change; a failure aborts the apply, so nothing is written to the machine.
#
# Run by chezmoi as the base's `hooks.apply.pre` (.chezmoi.toml.tmpl). chezmoi aborts the apply when
# a pre hook exits non-zero (measured with chezmoi 2.74: exit 1, no target written). Also runnable
# by hand: `sh tests/pre-apply.sh`. Its partner is tests/post-apply.sh, which runs EVERY suite after
# the apply, in the background.
#
# WHY ONLY SOME SUITES HERE. The apply waits on this script, and the whole set takes minutes. A
# change is judged here by the suites that read the paths it touches (tests/select-suites.sh, from
# tests/coverage.map), the same selection the commit gate makes: what the change can break stops
# the apply, and what it cannot break does not make the apply wait. The whole set still has to
# pass: tests/post-apply.sh runs it right after the apply, and records the pass that lets later
# applies skip. The same shape runs on every OS, macOS included, so no machine is judged by a
# different rule from another.
#
# WHAT "CHANGED" MEANS. The base is the newest tree in the pass ledger (below) for this OS that git
# still has. The changed paths are those that differ between that tree and the WORKING tree, plus
# untracked files, because the working tree, dirty edits included, is what an apply deploys. With no
# usable base (no ledger, or every entry names a tree git no longer has) every suite runs: nothing
# is known to have passed, so nothing can be left out. The same holds when git or the selector
# fails, because the selector's own rule is "all, never none" (tests/select-suites.sh) and a failure
# to ask must not read as "nothing to run". An empty change set, or a selection with no suite in
# it, passes with a line saying so.
#
# SKIPS, loudly and with exit 0, when a tool the suites need is not installed: on a fresh machine's
# first apply the tools arrive with or after that apply, and refusing it would leave the machine
# unable to bootstrap. The line names what is missing, so a machine that stays without it does not
# pass silently.
#
# The CHEZMOI_* variables chezmoi sets for a hook are removed first, so the suites run as they do at
# commit time rather than inside chezmoi's environment.
#
# A PASS IS NOT RE-EARNED. A clean source tree whose HEAD tree already passed every suite on this OS
# is not run again: the pass is recorded as `<tree> <os> <utc time>` in <git common dir>/pre-apply/
# passed, shared by every worktree and never committed. Only a FULL pass proves a tree, so this
# script records one only after running every suite on a clean tree that is still HEAD's
# afterwards; a selected-only pass proves the selected suites alone and records nothing, and a dirty
# tree is not HEAD's tree, so it is never skipped or recorded. tests/post-apply.sh writes the same
# ledger after its full run. A selected-only pass is remembered in the run history instead (below):
# the same clean tree, passed on this OS, is not run again, so an apply repeated seconds later (the
# private layer's settings re-merge applies a second time) costs nothing.
#
# WHAT THE COMMIT GATE ALREADY PASSED IS NOT RE-EARNED. The commit gate records each suite it ran and
# passed, on which OS and against which tree, in a machine-local ledger (tests/select-suites.sh, PASS
# CREDIT). A selected suite is credited and skipped when the ledger holds a pass of it for a tree
# whose difference from the working tree touches nothing the selector maps to that suite (the code
# marked GATE CREDIT below). A machine that never commits just runs its selection.
#
# PRE_APPLY_OS overrides `uname -s`, for the tests.
#
# Exit 0 the selected suites passed, or none was selected, or skipped (above); 1 a suite failed
# (the apply is aborted).
set -u
here=$(cd "$(dirname "$0")" && pwd)

# DOTFILES_SKIP_PRE_APPLY=1 skips the run, loudly, for the apply a suite itself depends on: a
# suite that needs a tool or configuration only this apply deploys cannot pass before it, and
# without this the machine could not take the change that fixes it. The next apply runs again.
if [ "${DOTFILES_SKIP_PRE_APPLY:-}" = 1 ]; then
  printf 'dotfiles pre-apply: SKIPPED by DOTFILES_SKIP_PRE_APPLY=1; the apply goes ahead untested.\n' >&2
  exit 0
fi

missing=""
for tool in git python3 uv jq yq gitleaks wt; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  printf 'dotfiles pre-apply: suites SKIPPED, not installed:%s. The apply goes ahead untested;\n' "$missing" >&2
  printf '  install them (the Brewfile, or the distribution packages) and the next apply runs the suites.\n' >&2
  exit 0
fi

for v in $(env | sed -n 's/^\(CHEZMOI[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done

os=${PRE_APPLY_OS:-$(uname -s)}
src=$(cd "$here/.." && pwd)

# THE RECORD OF EACH RUN, so the wait an apply costs is measured rather than remembered: one line
# per run appended to pre-apply.history (UTC time, OS, the tree or "dirty", how many suites ran, or
# "all", or "skip" for a run that rested on an earlier pass, wall seconds, exit), and the run's
# per-suite times in pre-apply.last-profile.tsv (run-all.sh's RUN_ALL_PROFILE), both under
# ${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/ beside post-apply's. Recording can never refuse an
# apply: a state directory that cannot be written loses the record, not the apply.
sd=${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles
prof=""
mkdir -p "$sd" 2>/dev/null && [ -w "$sd" ] && prof="$sd/pre-apply.last-profile.tsv"
started=$(date +%s)
nrun=""   # what the history line says ran; empty means "all"
record() { # record <exit>
  [ -n "$prof" ] || return 0
  n=${nrun:-all}; [ -z "$nrun" ] && [ -n "${only:-}" ] && n=$(printf '%s\n' $only | grep -c .)
  printf '%s %s %s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$os" "${tree:-dirty}" "$n" \
    "$(( $(date +%s) - started ))" "$1" >> "$sd/pre-apply.history" 2>/dev/null || true
}

tree=""; ledger=""
# Anything git cannot answer leaves the ledger out of it: no ledger, no base, every suite runs.
gdir=$(git -C "$src" rev-parse --git-common-dir 2>/dev/null) || gdir=""
case $gdir in "") ;; /*) ledger="$gdir/pre-apply/passed" ;; *) ledger="$src/$gdir/pre-apply/passed" ;; esac
# Only a clean tree is HEAD's tree.
if [ -z "$(git -C "$src" status --porcelain 2>/dev/null)" ] && git -C "$src" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  tree=$(git -C "$src" rev-parse "HEAD^{tree}" 2>/dev/null) || tree=""
fi
if [ -n "$tree" ] && [ -n "$ledger" ] && [ -f "$ledger" ]; then
  when=$(grep "^$tree $os " "$ledger" | tail -n 1 | sed 's/^[^ ]* [^ ]* //')
  if [ -n "$when" ]; then
    printf 'dotfiles pre-apply: this tree already passed on %s at %s; skipped\n' "$os" "$when" >&2
    nrun=skip; record 0
    exit 0
  fi
fi

# A PASS OF THIS TREE IS NOT RE-EARNED EITHER, whatever suites it ran. The ledger above holds only
# full passes; a run that judged a selection and passed left no entry there, so a second apply of
# the same tree (the private layer's settings re-merge applies again, seconds after the first)
# would run the whole selection again. The run history is the account of those: a line for this OS,
# this exact clean tree and exit 0 is a pass. A "dirty" tree is no tree, a failed run is no pass,
# and a skip line is not itself a pass (the pass it rested on is still in the history).
if [ -n "$tree" ] && [ -f "$sd/pre-apply.history" ]; then
  when=$(awk -v o="$os" -v t="$tree" '$2 == o && $3 == t && $4 != "skip" && $6 == "0" { w = $1 } END { print w }' "$sd/pre-apply.history" 2>/dev/null)
  if [ -n "$when" ]; then
    printf 'dotfiles pre-apply: tree %s already passed on %s at %s; skipped\n' "$tree" "$os" "$when" >&2
    nrun=skip; record 0
    exit 0
  fi
fi

# The base: the newest ledger entry for this OS whose tree git still has (a pruned or rewritten
# history leaves entries naming trees that are gone, and a diff against one would fail). The sed
# program reverses the lines, since `tac` is not on macOS.
base=""
if [ -n "$ledger" ] && [ -f "$ledger" ]; then
  for cand in $(grep "^[0-9a-f]* $os " "$ledger" | sed 's/ .*//' | sed '1!G;h;$!d'); do
    if git -C "$src" cat-file -e "$cand^{tree}" 2>/dev/null; then base=$cand; break; fi
  done
fi

only=""   # the suites to run, space-separated; empty means every suite
if [ -n "$base" ]; then
  # Each git call is checked on its own: in a pipeline only the last command's status survives.
  if d1=$(git -C "$src" diff --name-only --no-renames "$base" 2>/dev/null) \
     && d2=$(git -C "$src" ls-files --others --exclude-standard 2>/dev/null); then
    changed=$(printf '%s\n%s\n' "$d1" "$d2" | sed '/^$/d' | sort -u)
    if [ -z "$changed" ]; then
      printf 'dotfiles pre-apply: nothing differs from the last full pass; no suite to run.\n' >&2
      exit 0
    fi
    # The selector's one summary line goes straight to stderr.
    if sel=$(printf '%s\n' "$changed" | sh "$here/select-suites.sh"); then
      if [ -z "$sel" ]; then
        printf 'dotfiles pre-apply: no suite reads the changed paths; none to run before the apply.\n' >&2
        exit 0
      fi
      only=$(printf '%s\n' "$sel" | tr '\n' ' ')
    else
      printf 'dotfiles pre-apply: the selector failed; running every suite.\n' >&2
    fi
  else
    printf 'dotfiles pre-apply: git could not list the changed paths; running every suite.\n' >&2
  fi
fi

# GATE CREDIT. The commit gate records each suite it ran and passed, on which OS, against the tree it
# tested (tests/select-suites.sh, PASS CREDIT), in <state dir>/gate-passed. A selected suite S is
# credited, and not run, when that ledger holds a pass of S on this OS for a tree T such that the
# paths differing between T and the working tree (untracked files included) are ones the selector does
# not map to S: the same mapping that chose S above, so the two cannot disagree about what S reads.
# A tree git no longer has, a selector that fails, and any entry for another OS credit nothing. Only
# the newest 25 distinct trees are weighed. Machines that never commit (no ledger) just run the
# selection. The run with no earlier full pass to compare with (every suite) is not credited: it
# exists to earn that pass.
credited=""
gl="$sd/gate-passed"
if [ -n "$only" ] && [ -f "$gl" ]; then
  # newest tree first, each once (awk reverses the file; `tac` is not on macOS)
  for T in $(awk -v o="$os" '$2 == o { l[++n] = $1 } END { for (i = n; i >= 1; i--) if (!(l[i] in s)) { s[l[i]] = 1; print l[i] } }' "$gl" | sed -n '1,25p'); do
    [ -n "$only" ] || break
    git -C "$src" cat-file -e "$T^{tree}" 2>/dev/null || continue
    d1=$(git -C "$src" diff --name-only --no-renames "$T" 2>/dev/null) || continue
    d2=$(git -C "$src" ls-files --others --exclude-standard 2>/dev/null) || continue
    selT=$(printf '%s\n%s\n' "$d1" "$d2" | sed '/^$/d' | sort -u | sh "$here/select-suites.sh" 2>/dev/null) || continue
    got=""; left=""
    for S in $only; do
      if grep -q "^$T $os $S " "$gl" && ! printf '%s\n' "$selT" | grep -qx "$S"; then got="$got $S"; else left="$left $S"; fi
    done
    if [ -n "$got" ]; then
      printf 'dotfiles pre-apply: credited%s from tree %s (passed at the commit gate on %s; nothing since touches what they read)\n' "$got" "$T" "$os" >&2
      only=${left# }
      credited="$credited$got"
    fi
  done
  if [ -n "$credited" ] && [ -z "$only" ]; then
    printf 'dotfiles pre-apply: every selected suite was credited; none to run before the apply.\n' >&2
    nrun=0; record 0
    exit 0
  fi
fi

t=${TMPDIR:-/tmp}; t=${t%/}
log=$(mktemp "$t/dotfiles-pre-apply.XXXXXX") || { echo "dotfiles pre-apply: no temp file for the log; apply refused" >&2; exit 1; }
if [ -n "$only" ]; then
  printf 'dotfiles pre-apply: running the suites the change reaches (%s) before the apply...\n' "${only% }" >&2
  # shellcheck disable=SC2086 # one suite name per word
  RUN_ALL_PROFILE=$prof sh "$here/run-all.sh" --only $only > "$log" 2>&1; rc=$?
else
  printf 'dotfiles pre-apply: no earlier full pass to compare with; running every suite (tests/run-all.sh) before the apply...\n' >&2
  RUN_ALL_PROFILE=$prof sh "$here/run-all.sh" > "$log" 2>&1; rc=$?
fi
record "$rc"
if [ "$rc" -eq 0 ]; then
  printf 'dotfiles pre-apply: %s\n' "$(tail -n 1 "$log")" >&2
  rm -f "$log"
  # Recorded only after a FULL run, and only if the tree is still clean and still the one that ran.
  if [ -z "$only" ] && [ -n "$tree" ] && [ -n "$ledger" ] \
     && [ -z "$(git -C "$src" status --porcelain 2>/dev/null)" ] \
     && [ "$(git -C "$src" rev-parse "HEAD^{tree}" 2>/dev/null)" = "$tree" ]; then
    mkdir -p "$(dirname "$ledger")" \
      && printf '%s %s %s\n' "$tree" "$os" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$ledger"
  fi
  exit 0
fi
printf '\ndotfiles pre-apply: a suite failed -- apply ABORTED, nothing was deployed:\n' >&2
grep -E '^(FAIL|run-all:)' "$log" | sed 's/^/  /' >&2
printf '\n  why, in full: %s\n' "$log" >&2
for s in $(sed -n 's/^FAIL   \([^ ]*\) .*/\1/p' "$log"); do
  printf '  re-run one:   sh %s/run-all.sh --only %s\n' "$here" "$s" >&2
done
exit 1
