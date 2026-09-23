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
reg="$here/../private_dot_local/bin/executable_register"
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

# --- a wrong root is an ERROR, not an empty answer. Those look identical and only one is true.
python3 "$reg" list --root "$tmp/nope" >/dev/null 2>&1 && bad "a missing root exits non-zero" || ok "a missing root exits non-zero"
mkdir -p "$tmp/hollow"; echo "# nothing" > "$tmp/hollow/notes.md"
python3 "$reg" list --root "$tmp/hollow" >/dev/null 2>&1 && bad "a root with no entries exits non-zero" || ok "a root with no entries exits non-zero"

echo ""
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
