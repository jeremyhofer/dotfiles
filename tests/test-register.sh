#!/bin/sh
# Tests for `register`. It only READS, so the failures worth planting are wrong answers rather
# than missed defects: a filter that returns the wrong set, a count that disagrees with the
# store, a non-entry document counted as an entry, an index that breaks on a pipe in a title.
#
# The case that shaped the error handling: a wrong --root returning an empty list looks exactly
# like a register with nothing in it. Those are different answers and only one is ever true, so
# the tool refuses rather than printing nothing.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
reg="${REGISTER_BIN:-$here/../private_dot_local/bin/executable_register}"
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok:   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
assert_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (expected: $2)" ;; esac; }
assert_lacks() { case "$3" in *"$2"*) bad "$1 (did NOT expect: $2)" ;; *) ok "$1" ;; esac; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
r="$tmp/docs/register"; mkdir -p "$r/closed"

entry() {  # $1 dir  $2 id  $3 status  $4 title  $5 gate
  { echo "---"; echo "id: $2"; echo "title: $4"; echo "status: $3"
    [ -n "${5:-}" ] && echo "gate: $5"
    echo "owner: jeremy"; echo "verified: 2026-09-22"; echo "---"
    echo ""; echo "# $2 — $4"; echo ""; echo "## Next action"; echo "Do the thing."
  } > "$1/$2-slug.md"
}
run() { python3 "$reg" "$@" --root "$r" 2>&1 || true; }

entry "$r" "ABC-01" "active" "The first thing" ""
entry "$r" "ABC-02" "held"   "The second thing" "waiting on somebody"
entry "$r" "ABC-10" "idea"   "The tenth thing" ""
entry "$r/closed" "ABC-03" "done" "The finished thing" ""
echo "# not an entry" > "$r/README.md"

# --- list
out=$(run list)
assert_has "list includes an actionable entry" "ABC-01" "$out"
assert_has "list includes a closed entry by default" "ABC-03" "$out"
assert_lacks "a non-entry document is not listed" "README" "$out"
assert_has "list shows the title" "The first thing" "$out"

out=$(run list --open)
assert_lacks "--open excludes closed entries" "ABC-03" "$out"
assert_has "--open keeps actionable entries" "ABC-02" "$out"
out=$(run list --closed)
assert_has "--closed keeps finished entries" "ABC-03" "$out"
assert_lacks "--closed excludes actionable entries" "ABC-01" "$out"
out=$(run list --status held)
assert_has "--status selects" "ABC-02" "$out"
assert_lacks "--status excludes everything else" "ABC-01" "$out"
out=$(run list --match tenth)
assert_has "--match searches the title" "ABC-10" "$out"
assert_lacks "--match excludes non-matches" "ABC-01" "$out"
assert_has "--long shows the gate" "waiting on somebody" "$(run list --long --status held)"

# Ids sort NUMERICALLY, not lexically. Sorting as text puts 10 before 2, which is the same
# trap that has caused id double-allocation in this fleet.
out=$(run list --open | grep -o 'ABC-[0-9]*' | tr '\n' ' ')
case "$out" in "ABC-01 ABC-02 ABC-10 "*) ok "ids sort numerically, not lexically" ;;
  *) bad "ids sort numerically (got: $out)" ;; esac

# --- stats
# Squeeze the column padding before matching: asserting on exact spacing tests the format
# string rather than the count, and breaks the moment a wider number appears.
out=$(run stats | tr -s ' ')
assert_has "stats counts a status" "active 1" "$out"
assert_has "stats totals everything including closed" "total 4" "$out"
entry "$r" "ABC-11" "wibble" "An odd one" ""
assert_has "a status outside the vocabulary is named as such" "outside the vocabulary" "$(run stats)"
rm "$r/ABC-11-slug.md"

# --- show
assert_has "show prints the entry body" "Do the thing." "$(run show ABC-01)"
python3 "$reg" show ABC-99 --root "$r" >/dev/null 2>&1 && bad "show exits non-zero on an unknown id" || ok "show exits non-zero on an unknown id"

# --- index
out=$(run index)
assert_has "index links an actionable entry relatively" "(ABC-01-slug.md)" "$out"
assert_has "index links a closed entry into closed/" "(closed/ABC-03-slug.md)" "$out"
assert_has "index carries the generated banner" "GENERATED" "$out"
entry "$r" "ABC-12" "idea" "A title with a | pipe in it" ""
assert_has "a pipe in a title is escaped so the table survives" "with a \\| pipe" "$(run index)"
rm "$r/ABC-12-slug.md"
run index --write "$tmp/out.md" >/dev/null
[ -s "$tmp/out.md" ] && ok "--write produces a file" || bad "--write produces a file"

# --- next
# The fixture is mixed width on purpose (ABC-01 .. ABC-10): as text, ABC-03 in closed/ and ABC-10
# both sort after ABC-02, and only a numeric read over closed/ too gives the true next id.
assert_has "next reads the highest id numerically" "ABC-11" "$(python3 "$reg" next --root "$r" 2>/dev/null)"
entry "$r/closed" "ABC-40" "done" "A closed high id" ""
assert_has "next counts closed entries -- an id is never reused" "ABC-41" "$(python3 "$reg" next --root "$r" 2>/dev/null)"
rm "$r/closed/ABC-40-slug.md"
out=$(python3 "$reg" next --root "$r" 2>/dev/null)
[ "$out" = "ABC-11" ] && ok "next prints only the id on stdout" || bad "next prints only the id on stdout (got: $out)"
m="$tmp/mixed"; mkdir -p "$m"
entry "$m" "ABC-9" "idea" "narrow" ""; entry "$m" "ABC-100" "idea" "wide" ""
assert_has "next on a mixed-width register takes the numeric max" "ABC-101" "$(python3 "$reg" next --root "$m" 2>/dev/null)"
assert_has "mixed widths are reported" "mixed width" "$(python3 "$reg" next --root "$m" 2>&1 >/dev/null)"
p4="$tmp/padded"; mkdir -p "$p4"; entry "$p4" "ABC-0007" "idea" "padded" ""
assert_has "the width is kept from the existing ids" "ABC-0008" "$(python3 "$reg" next --root "$p4" 2>/dev/null)"
w="$tmp/wrap"; mkdir -p "$w"; entry "$w" "ABC-99" "idea" "edge" ""
assert_has "outgrowing the width is reported" "wider than every existing id" "$(python3 "$reg" next --root "$w" 2>&1 >/dev/null)"
two="$tmp/two"; mkdir -p "$two"; entry "$two" "ABC-1" "idea" "a" ""; entry "$two" "XYZ-2" "idea" "b" ""
python3 "$reg" next --root "$two" >/dev/null 2>&1 && bad "two prefixes is an error" || ok "two prefixes is an error"

# --- folders: an entry's `folder:` artifact, in `list`, `show` and `health`
# These need a real repository, because `health` asks git when a folder last changed and because
# the repository root is where the type folders are read from. Every git call strips or sets its
# own identity so the fixture never depends on the machine running it.
g="$tmp/repo"; gr="$g/docs/register"; mkdir -p "$gr/closed"
gt() { git -C "$g" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
git init -q "$g"
fentry() {  # $1 id  $2 status  $3 folder-or-empty  $4 extra frontmatter line-or-empty  $5 body text
  { echo "---"; echo "id: $1"; echo "title: Title of $1"; echo "status: $2"; echo "owner: jeremy"
    echo "verified: 2026-09-22"; [ -n "${4:-}" ] && echo "$4"
    if [ -n "${3:-}" ]; then echo "artifacts:"; echo "  - spec:docs/specs/x.md"; echo "  - folder:$3"; fi
    echo "---"; echo ""; echo "# $1"; echo ""; echo "${5:-Body.}"
  } > "$gr/$1-slug.md"
}
fdoc() { mkdir -p "$(dirname "$g/$1")"; echo "# $1" > "$g/$1"; }

fentry ABC-0001 active docs/initiatives/ABC-0001-alpha/ "" "Names docs/plans/2026-01-01-shared.md here."
fentry ABC-0002 active docs/initiatives/ABC-0002-beta/ "" "Nothing."
fentry ABC-0003 active "" "" "No folder."
fentry ABC-0004 standing "" "cadence: weekly" "A standing one."
fentry ABC-0005 standing "" "cadence: annual" "Another standing one."
sed -i 's/^verified: .*/verified: 2026-01-01/' "$gr/ABC-0004-slug.md"
fdoc docs/initiatives/ABC-0001-alpha/README.md
echo "Files: specs/2026-01-01-a.md. Decision: ABC-ADR-0005 and docs/adr/0006-x.md; also docs/plans/2026-01-01-shared.md." >> "$g/docs/initiatives/ABC-0001-alpha/README.md"
fdoc docs/initiatives/ABC-0001-alpha/specs/2026-01-01-a.md
fdoc docs/initiatives/ABC-0001-alpha/research/2026-01-02-r.md
fdoc docs/initiatives/ABC-0002-beta/README.md
fdoc docs/initiatives/ABC-0002-beta/plans/2026-01-01-b.md
# repository-wide type folders: one shared by two initiatives' entries/READMEs, one named by only
# ABC-0001, one named by nobody, one named only by an ADR.
fdoc docs/plans/2026-01-01-shared.md
fdoc docs/specs/2026-01-01-solo.md
fdoc docs/runbooks/orphan-runbook.md
fdoc docs/reference/adr-only.md
fdoc docs/adr/0001-x.md
echo "Mentions adr-only.md only." >> "$g/docs/adr/0001-x.md"
echo "Also see 2026-01-01-shared.md" >> "$g/docs/initiatives/ABC-0002-beta/README.md"
echo "Covers 2026-01-01-solo.md" >> "$gr/ABC-0001-slug.md"
gt add -A >/dev/null
GIT_COMMITTER_DATE="2026-01-01T00:00:00" GIT_AUTHOR_DATE="2026-01-01T00:00:00" gt commit -q -m old
# ABC-0001 is touched now, so only ABC-0002's folder is stale.
echo more >> "$g/docs/initiatives/ABC-0001-alpha/specs/2026-01-01-a.md"
gt add -A >/dev/null; gt commit -q -m recent
grun() { python3 "$reg" "$@" --root "$gr" 2>&1 || true; }

out=$(grun list)
assert_has "list shows an entry's folder" "docs/initiatives/ABC-0001-alpha/" "$out"
line=$(printf '%s\n' "$out" | grep '^ABC-0003')
assert_has "list shows a placeholder for an entry with no folder" " - " "$line"
assert_has "list still shows the title" "Title of ABC-0001" "$out"

out=$(grun show ABC-0001)
assert_has "show prints the folder path" "folder: docs/initiatives/ABC-0001-alpha/" "$out"
assert_has "show groups files by type subdirectory" "specs/" "$out"
assert_has "show lists a file under its type" "2026-01-01-a.md" "$out"
assert_has "show lists another type" "research/" "$out"
assert_has "show lists the README as a root file" "README.md" "$out"
assert_has "show lists an ADR id the README names" "ABC-ADR-0005" "$out"
assert_has "show lists an ADR file the README names" "docs/adr/0006-x.md" "$out"
assert_lacks "show of an entry with no folder adds no folder section" "docs/initiatives" "$(grun show ABC-0003)"

out=$(grun health)
assert_has "health names an active entry whose folder is stale" "ABC-0002" "$(echo "$out" | grep -i 'no commit')"
assert_lacks "health leaves an active entry with a recent commit alone" "ABC-0001" "$(echo "$out" | grep -i 'no commit')"
assert_lacks "health leaves an entry with no folder out of the stale check" "ABC-0003" "$(echo "$out" | grep -i 'no commit')"
assert_has "health names a standing entry past its cadence" "ABC-0004" "$(echo "$out" | grep -i 'cadence')"
assert_lacks "health leaves a standing entry within its cadence" "ABC-0005" "$(echo "$out" | grep -i 'cadence')"
assert_has "health names a document only one initiative names" "docs/specs/2026-01-01-solo.md" "$(echo "$out" | grep -i 'one initiative')"
assert_lacks "health leaves a document two initiatives name" "2026-01-01-shared.md" "$out"
assert_has "health names a document nothing names" "docs/runbooks/orphan-runbook.md" "$(echo "$out" | grep -i 'named by nothing')"
assert_lacks "a document only an ADR names is neither list" "adr-only.md" "$out"
python3 "$reg" health --root "$gr" >/dev/null 2>&1 && ok "health exits 0 with findings" || bad "health exits 0 with findings"
# Near miss: a folder committed today is not stale, at the edge of the window.
echo x >> "$g/docs/initiatives/ABC-0002-beta/plans/2026-01-01-b.md"; gt add -A >/dev/null; gt commit -q -m touch
assert_lacks "a folder with a fresh commit is not stale" "ABC-0002" "$(grun health | grep -i 'no commit')"

# A hook exports GIT_DIR and GIT_INDEX_FILE naming ITS repository; they must not redirect the
# questions this tool asks git about the fixture's folders.
other="$tmp/other"; git init -q "$other"
echo x > "$other/f"; git -C "$other" add f
hookenv() { GIT_DIR="$other/.git" GIT_INDEX_FILE="$other/.git/index" python3 "$reg" "$@" --root "$gr" 2>&1 || true; }
out=$(hookenv health)
assert_has "in a hook's environment health still reads the fixture's own history" "docs/runbooks/orphan-runbook.md" "$out"
assert_lacks "in a hook's environment a fresh folder is still fresh" "ABC-0002" "$(echo "$out" | grep -i 'no commit')"
assert_has "in a hook's environment list still shows the fixture's folder" "docs/initiatives/ABC-0001-alpha/" "$(hookenv list)"
assert_has "in a hook's environment show still lists the fixture's files" "2026-01-01-a.md" "$(hookenv show ABC-0001)"
# A folder with NO commit of its own in a repository that has history: the other repository's
# history would answer differently if GIT_DIR leaked through, so plant one only the fixture lacks.
fentry ABC-0006 active docs/initiatives/ABC-0006-gamma/ "" "New."
mkdir -p "$g/docs/initiatives/ABC-0006-gamma"; echo r > "$g/docs/initiatives/ABC-0006-gamma/README.md"
assert_has "an uncommitted folder counts as having no commit" "ABC-0006" "$(grun health | grep -i 'no commit')"
assert_has "the same holds inside a hook's environment" "ABC-0006" "$(hookenv health | grep -i 'no commit')"

# --- relations, `related`, and the cross-entry health reports
# Each report is planted once and paired with a near miss that must stay quiet. The fixture is its
# own register, so the bodies here name no ids unless a case is about a mention.
rl="$tmp/rel/docs/register"; mkdir -p "$rl/closed"
rentry() {  # $1 id  $2 status  $3 title  $4 extra frontmatter (may hold newlines)  $5 body  $6 dir
  { echo "---"; echo "id: $1"; echo "title: $3"; echo "status: $2"; echo "owner: jeremy"
    echo "verified: ${ver:-2026-09-22}"; [ -n "${4:-}" ] && printf '%s\n' "$4"
    echo "---"; echo ""; echo "# $1"; echo ""; echo "${5:-Body.}"
  } > "${6:-$rl}/$1-slug.md"
}
rrun() { python3 "$reg" "$@" --root "$rl" 2>&1 || true; }
old=$(python3 -c 'import datetime;print(datetime.date.today()-datetime.timedelta(days=20))')
recent=$(python3 -c 'import datetime;print(datetime.date.today()-datetime.timedelta(days=10))')

rentry REL-01 active   "Parent initiative" "artifacts:
  - spec:docs/specs/zebra-notes.md"
rentry REL-02 active   "Child by scalar" "part-of: REL-01"
rentry REL-03 active   "Blocks two" "blocks:
  - REL-04
  - REL-05"
rentry REL-04 blocked  "Gated and typed" "gate: REL-03"
rentry REL-05 held     "Gated on a closed one" "gate: REL-06 finishing"
rentry REL-06 done    "The closed one" "" "Body." "$rl/closed"
rentry REL-07 active   "Child of a closed parent" "part-of: REL-06"
rentry REL-08 active   "Replaces the closed one" "supersedes: REL-06"
rentry REL-09 active   "Split off the parent" "split-from: REL-01"
rentry REL-10 dropped  "Duplicate of the parent" "duplicates: REL-01"
rentry REL-11 active   "Related to the parent" "relates: REL-01"
rentry REL-13 active   "Mentions a child in prose" "" "See REL-02 for the details."
rentry REL-14 active   "Child that mentions its parent" "part-of: REL-01" "Parent is REL-01."
ver=$old
rentry REL-15 standing "Overdue and reporting" "cadence: fortnightly
overdue: report"
rentry REL-17 standing "Overdue, not reporting" "cadence: fortnightly"
ver=$recent
rentry REL-16 standing "Recent and reporting" "cadence: fortnightly
overdue: report"
ver=
mv "$rl/REL-10-slug.md" "$rl/closed/"
rentry REL-19 done "Closed child of a closed parent" "part-of: REL-06" "Body." "$rl/closed"

# show: the relation an entry states, and the inverse of each kind, with the other entry's status
out=$(rrun show REL-02)
assert_has "show lists a stated scalar relation" "part-of" "$out"
assert_has "show gives the relation's target with its status" "[active]  Parent initiative" "$out"
out=$(rrun show REL-01)
assert_has "show derives children from part-of" "children" "$(echo "$out" | grep REL-02)"
assert_has "show derives split into from split-from" "split into" "$(echo "$out" | grep REL-09)"
assert_has "show derives duplicated by from duplicates" "duplicated by" "$(echo "$out" | grep REL-10)"
assert_has "show derives related by from relates" "related by" "$(echo "$out" | grep REL-11)"
assert_has "a derived row carries the other entry's status" "[dropped]" "$(echo "$out" | grep REL-10)"
assert_has "show derives superseded by" "superseded by" "$(rrun show REL-06 | grep REL-08)"
out=$(rrun show REL-04)
assert_has "show derives blocked by from blocks" "blocked by" "$(echo "$out" | grep REL-03)"
assert_has "show reads a block list (first item)" "blocks" "$(rrun show REL-03 | grep REL-04)"
assert_has "show reads a block list (second item)" "blocks" "$(rrun show REL-03 | grep REL-05)"
assert_lacks "an entry with no relations has no Relations block" "Relations" "$(rrun show REL-13)"
assert_lacks "a stated relation is not shown as an inverse on its own entry" "children" "$(rrun show REL-02)"

# related: ranked by matches, closed entries included, no match is an answer not an error
out=$(rrun related closed)
assert_has "related finds a title match in a closed entry" "REL-06" "$out"
assert_lacks "related leaves out an entry with no match" "REL-02" "$out"
out=$(rrun related child parent)
first=$(printf '%s\n' "$out" | head -1)
assert_has "related lists id, status, title and count" "(3)" "$first"
assert_has "related ranks the most matches first" "REL-14" "$first"
assert_has "related searches the body" "REL-13" "$(rrun related details)"
assert_has "related searches artifacts" "REL-01" "$(rrun related zebra)"
out=$(rrun related qqqqqq)
assert_has "related says so when nothing matches" "no match" "$out"
python3 "$reg" related qqqqqq --root "$rl" >/dev/null 2>&1 && ok "related exits 0 on no match" || bad "related exits 0 on no match"
python3 "$reg" related --root "$rl" >/dev/null 2>&1 && bad "related with no words is an error" || ok "related with no words is an error"

# health reports (unset the folder repo, so only these reports are in play)
out=$(rrun health)
assert_has "untyped-mention counts a mention with no relation" "[untyped-mention] 1 " "$out"
assert_lacks "untyped-mention does not count a mention already typed" "REL-14" "$out"
out=$(rrun health --mentions)
assert_has "--mentions lists the untyped mention" "REL-13 mentions REL-02" "$out"
assert_lacks "--mentions leaves a typed pair out" "REL-14 mentions" "$out"
out=$(rrun health)
assert_has "gate-closed names a held entry gated on a closed one" "[gate-closed] REL-05" "$out"
assert_lacks "gate-closed leaves a gate on an open entry alone" "[gate-closed] REL-04" "$out"
assert_has "gate-untyped names a gate absent from blocks" "[gate-untyped] REL-05" "$out"
assert_lacks "gate-untyped leaves a gate that is under blocks" "[gate-untyped] REL-04" "$out"
assert_has "child-of-closed names an open entry part-of a closed one" "[child-of-closed] REL-07" "$out"
assert_lacks "child-of-closed leaves a child of an open parent" "[child-of-closed] REL-02" "$out"
assert_lacks "child-of-closed leaves a closed child" "[child-of-closed] REL-19" "$out"
assert_has "standing-overdue names an overdue entry that reports" "REL-15: standing-overdue" "$out"
assert_lacks "standing-overdue leaves a fortnightly entry inside 14 days" "REL-16" "$out"
assert_lacks "an overdue entry without overdue: report keeps the ordinary line" "REL-17: standing-overdue" "$out"
assert_has "an overdue entry without overdue: report is still reported" "REL-17: standing," "$out"
python3 "$reg" health --root "$rl" >/dev/null 2>&1 && ok "health exits 0 with relation findings" || bad "health exits 0 with relation findings"

# Foreign ids: resolved through fleet-decl and a manifest when both are present, else unresolved.
rentry REL-18 active "Names other registers" "relates:
  - FOO-0003
  - OLDA-0007
  - OLDB-0009
supersedes: GAP-9"
if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q mikefarah; then
  mkdir -p "$tmp/bin" "$tmp/devel/foo/docs/register" "$tmp/devel/alpha/docs/register"
  cp "$here/../private_dot_local/bin/executable_fleet-decl" "$tmp/bin/fleet-decl"; chmod +x "$tmp/bin/fleet-decl"
  printf 'projects:\n  foo:\n    leakPrefix: FOO\n    leakPolicy: private\n    path: foo\n  alpha:\n    leakPrefix: "ALPHA, OLDA"\n    leakPolicy: private\n    path: alpha\n' > "$tmp/mani.yaml"
  rentry ALPHA-0007 done "Renamed entry" "" "Body." "$tmp/devel/alpha/docs/register"
  rentry ALPHA-0009 done "Other number" "" "Body." "$tmp/devel/alpha/docs/register"
  rentry FOO-0003 ready "Foreign entry" "" "Body." "$tmp/devel/foo/docs/register"
  frun() { PATH="$tmp/bin:$PATH" FLEET_RECORD="$tmp/mani.yaml" FLEET_DEVEL_ROOT="$tmp/devel" python3 "$reg" "$@" --root "$rl" 2>&1 || true; }
  out=$(frun show REL-18)
  assert_has "show resolves a foreign id through the manifest" "[ready]  Foreign entry" "$out"
  assert_has "show resolves an old prefix declared beside the new one, by number" "[done]  Renamed entry" "$out"
  assert_has "an old prefix that is not declared stays unresolved" "OLDB-0009" "$(echo "$out" | grep unresolved)"
  assert_lacks "an undeclared old prefix does not find the entry by number" "Other number" "$out"
  assert_lacks "a declared old prefix is not reported" "OLDA" "$(frun health)"
  assert_has "show marks an unknown prefix unresolved" "GAP-9" "$(echo "$out" | grep unresolved)"
  out=$(frun health)
  assert_has "unresolved-foreign counts the ids that do not resolve, by prefix" "[unresolved-foreign] GAP: 1 " "$out"
  assert_lacks "a foreign id that resolves is not reported" "FOO" "$out"
  rm "$tmp/devel/foo/docs/register/FOO-0003-slug.md"
  assert_has "a foreign id missing from its register is unresolved" "[unresolved-foreign] FOO: 1 " "$(frun health)"
else
  echo "skip: foreign-id resolution (needs the mikefarah yq)"
fi
out=$(FLEET_RECORD="$tmp/none.yaml" python3 "$reg" show REL-18 --root "$rl" 2>&1) && ok "show does not fail when the manifest is unreadable" || bad "show does not fail when the manifest is unreadable"
assert_has "an unreadable manifest leaves the foreign id unresolved" "FOO-0003" "$(echo "$out" | grep unresolved)"
out=$(PATH=/usr/bin:/bin FLEET_RECORD="$tmp/none.yaml" "$(command -v python3)" "$reg" health --root "$rl" 2>&1) && ok "health does not fail without fleet-decl" || bad "health does not fail without fleet-decl"
assert_has "without fleet-decl every foreign id is unresolved" "[unresolved-foreign] FOO: 1 " "$out"

# --- a wrong root is an ERROR, not an empty answer. Those look identical and only one is true.
python3 "$reg" list --root "$tmp/nope" >/dev/null 2>&1 && bad "a missing root exits non-zero" || ok "a missing root exits non-zero"
mkdir -p "$tmp/hollow"; echo "# nothing" > "$tmp/hollow/notes.md"
python3 "$reg" list --root "$tmp/hollow" >/dev/null 2>&1 && bad "a root with no entries exits non-zero" || ok "a root with no entries exits non-zero"

echo ""
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
