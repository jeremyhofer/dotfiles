#!/bin/sh
# select-suites -- staged paths in, suite names out: the suites in tests/ that read those paths, as
# tests/coverage.map declares them. The commit gate runs only these, and so does the apply's pre
# hook (tests/pre-apply.sh) for the paths that differ from the last full pass; every suite runs
# right after the apply (tests/post-apply.sh), so a suite skipped at commit still runs.
#
#   sh tests/select-suites.sh         < paths   print the selected suite file names, one per line
#   sh tests/select-suites.sh --run   < paths   run them with tests/run-all.sh --only (none: exit 0)
#   sh tests/select-suites.sh --check           the map against the tracked tree (see below)
#
# Paths are repository-relative, one per line, as `git diff --cached --name-only --no-renames`
# prints them (deleted paths included). One line on stderr says what was selected and why.
#
# THE FAIL-SAFE IS "ALL", NEVER "NONE". A path in the map's shared core (the runner, the git
# isolation every suite sources, this selector, the hook generator and runner, the gitconfig) runs
# every suite. So does a path that no suite claims and no exemption names, which is how a new file
# is gated before anyone has mapped it. A staged suite file selects itself. An exempt path selects
# only the whole-tree checks whose globs match it. Documentation alone never reaches here: the
# commit gate skips a commit that stages nothing else.
#
# WHY ONE MAP FILE, NOT A HEADER IN EACH SUITE. The core, the exemptions and the whole-tree checks
# are not facts about any one suite, so they need a central file anyway; one file with one format
# keeps "what covers X?" a single grep, and the check below reads it in one pass.
#
# --check REFUSES (exit 1), naming each finding:
#   * a tracked file that no suite claims, the core does not hold and no exemption names;
#   * a suite with no line in the map, and a line naming a suite that does not exist;
#   * a glob that matches no tracked file (a rename leaves the old glob behind);
#   * a suite whose text names a tracked path (`dir/file`, or a tool as `executable_<name>`) that it
#     does not claim: it reads a file a change to which would not run it. A name that is only
#     fixture text is declared with `refs`.
# It reads the index (`git ls-files`), so under the commit gate it judges what is staged.
#
# Exit 0 done; 1 --check found rot; 2 usage, or a map line this cannot parse (the gate refuses
# rather than guess). POSIX sh and awk only.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
map="$here/coverage.map"

mode=select
case "${1:-}" in
  '') ;;
  --run) mode=run ;;
  --check) mode=check ;;
  -h|--help) sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  *) printf 'select-suites: unknown argument %s\n' "$1" >&2; exit 2 ;;
esac
[ -f "$map" ] || { printf 'select-suites: no map at %s\n' "$map" >&2; exit 2; }

suites=""
for t in "$here"/test-*.sh "$here"/test-*.py; do
  [ -f "$t" ] || continue
  suites="$suites${suites:+
}$(basename "$t")"
done
SELECT_SUITES_LIST=$suites; export SELECT_SUITES_LIST

prog='
function glob2re(g,   out, i, c) {
  out = "^"
  for (i = 1; i <= length(g); i++) {
    c = substr(g, i, 1)
    if (c == "*") {
      if (substr(g, i + 1, 1) == "*") { out = out ".*"; i++ } else out = out "[^/]*"
    } else if (c == "?") out = out "[^/]"
    else if (index(".+(){}$|", c)) out = out "[" c "]"
    else if (index("^[]\\", c)) out = out "\\" c
    else out = out c
  }
  return out "$"
}
function err(msg) { printf "select-suites: %s\n", msg > "/dev/stderr"; bad_map = 1 }
BEGIN {
  ns = split(ENVIRON["SELECT_SUITES_LIST"], all, "\n")
  for (i = 1; i <= ns; i++) exists[all[i]] = 1
}
phase == "map" {
  sub(/#.*/, "")
  if (NF == 0) next
  kind = $1; owner = ""; first = 2
  if (kind == "tree" || kind == "refs") { owner = $2; first = 3 }
  else if (kind != "core" && kind != "exempt") { owner = $1; kind = "suite" }
  if (owner != "" && !(owner in exists)) { err(FILENAME ":" FNR ": names no suite in tests/: " owner); next }
  if (NF < first) { err(FILENAME ":" FNR ": a line with no globs"); next }
  if (owner != "") hasline[owner] = 1
  for (i = first; i <= NF; i++) {
    n++; ekind[n] = kind; eowner[n] = owner; eglob[n] = $i; ere[n] = glob2re($i); eline[n] = FNR
  }
  next
}
# claim(p): 1 when a suite claims p, the core holds it, or p is a suite file itself.
function suitefile(p,   s) {
  if (p !~ /^tests\/test-[^\/]*$/) return ""
  s = substr(p, 7); return s
}
phase == "paths" && mode != "check" {
  p = $0; if (p == "") next
  npaths++
  claimed = 0
  s = suitefile(p)
  if (s != "") { if (s in exists) sel[s] = 1; claimed = 1 }
  for (i = 1; i <= n; i++) {
    if (p !~ ere[i]) continue
    if (ekind[i] == "core") { if (!every) why = p " is in the shared core"; every = 1; claimed = 1 }
    else if (ekind[i] == "suite") { sel[eowner[i]] = 1; claimed = 1 }
    else if (ekind[i] == "tree") sel[eowner[i]] = 1
  }
  if (!claimed) for (i = 1; i <= n; i++) if (ekind[i] == "exempt" && p ~ ere[i]) { claimed = 1; break }
  if (!claimed) { if (!every) why = p " is claimed by no suite and named by no exemption"; every = 1 }
  next
}
phase == "paths" && mode == "check" {
  p = $0; if (p == "") next
  ntracked++; tracked[ntracked] = p
  next
}
phase == "suite" {
  f = FILENAME; sub(/.*\//, "", f)
  text[f] = text[f] "\n" $0
  next
}
function covered_by(s, p,   i) {
  for (i = 1; i <= n; i++)
    if (p ~ ere[i] && (ekind[i] == "core" || ((ekind[i] == "suite" || ekind[i] == "tree" || ekind[i] == "refs") && eowner[i] == s))) return 1
  return 0
}
# names(t, w): 1 when t contains w as a whole name (not inside a longer path or word).
function names(t, w,   rest, at, before, after) {
  rest = t
  while ((at = index(rest, w)) > 0) {
    before = at > 1 ? substr(rest, at - 1, 1) : ""
    after = substr(rest, at + length(w), 1)
    if (before !~ /[A-Za-z0-9_.-]/ && after !~ /[A-Za-z0-9_.-]/) return 1
    rest = substr(rest, at + length(w))
  }
  return 0
}
END {
  if (bad_map) exit 2
  if (mode != "check") {
    if (every) {
      for (i = 1; i <= ns; i++) if (all[i] != "") print all[i]
      printf "select-suites: every suite (%d): %s\n", ns, why > "/dev/stderr"
      exit 0
    }
    k = 0
    for (i = 1; i <= ns; i++) if (all[i] in sel) { print all[i]; k++ }
    if (k == 0) printf "select-suites: no suite reads the %d staged path(s)\n", npaths > "/dev/stderr"
    else printf "select-suites: %d of %d suites for %d staged path(s)\n", k, ns, npaths > "/dev/stderr"
    exit 0
  }
  rot = 0
  for (t = 1; t <= ntracked; t++) {
    p = tracked[t]; claimed = 0
    s = suitefile(p); if (s != "") claimed = 1
    for (i = 1; i <= n && !claimed; i++)
      if ((ekind[i] == "core" || ekind[i] == "suite" || ekind[i] == "exempt") && p ~ ere[i]) claimed = 1
    if (!claimed) { printf "  unclaimed: %s -- no suite claims it and no exemption names it\n", p; rot++ }
  }
  for (i = 1; i <= n; i++) {
    hit = 0
    for (t = 1; t <= ntracked && !hit; t++) if (tracked[t] ~ ere[i]) hit = 1
    if (!hit) { printf "  dead glob: line %d, %s %s%s -- matches no tracked file\n", eline[i], ekind[i], (eowner[i] != "" ? eowner[i] " " : ""), eglob[i]; rot++ }
  }
  for (i = 1; i <= ns; i++) if (all[i] != "" && !(all[i] in hasline)) { printf "  no line: %s -- every suite declares what it reads\n", all[i]; rot++ }
  for (s in text) {
    for (t = 1; t <= ntracked; t++) {
      p = tracked[t]
      if (p !~ /\// || p ~ /^tests\//) continue
      w = p
      if (!names(text[s], w)) {
        if (p !~ /^private_dot_local\/bin\/executable_/) continue
        w = p; sub(/.*\//, "", w)
        if (!names(text[s], w)) continue
      }
      if (!covered_by(s, p)) { printf "  unclaimed read: %s names %s but does not claim it (claim it, or `refs` if it is fixture text)\n", s, p; rot++ }
    }
  }
  if (rot) { printf "select-suites --check: %d finding(s) in %s\n", rot, map; exit 1 }
  printf "select-suites --check: the map covers all %d tracked files\n", ntracked
}'

case $mode in
  check)
    command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --git-dir >/dev/null 2>&1 \
      || { printf 'select-suites: --check needs %s to be a git checkout\n' "$root" >&2; exit 2; }
    # shellcheck disable=SC2046 # suite file names carry no blanks (run-all.sh relies on that too)
    git -C "$root" ls-files | awk -v mode=check -v map="$map" "$prog" phase=map "$map" phase=paths - \
      phase=suite $(printf '%s\n' "$suites" | sed "s|^|$here/|")
    ;;
  select)
    awk -v mode=select "$prog" phase=map "$map" phase=paths -
    ;;
  run)
    names=$(awk -v mode=select "$prog" phase=map "$map" phase=paths -) || exit $?
    [ -n "$names" ] || exit 0
    # shellcheck disable=SC2086 # one suite name per word
    exec sh "$here/run-all.sh" --only $names
    ;;
esac
