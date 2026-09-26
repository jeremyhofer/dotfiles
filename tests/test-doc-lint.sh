#!/bin/sh
# Tests for doc-lint. Every case PLANTS a defect and asserts it is reported, or plants the
# near-miss and asserts it is not. The near-misses carry as much weight as the defects: a
# lint that fires on a correct document gets switched off, after which it guards nothing.
#
# The case that shaped the config design: a bare `ADR-0009` is AMBIGUOUS in a repository that
# cites several decision logs and CORRECT in a project citing its own. So the owner-prefix
# checks run only where the repository's config declares its owners.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
lint="$here/../private_dot_local/bin/executable_doc-lint"
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok:   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
assert_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (expected: $2)" ;; esac; }
assert_lacks() { case "$3" in *"$2"*) bad "$1 (did NOT expect: $2)" ;; *) ok "$1" ;; esac; }

_t=${TMPDIR:-/tmp}; _t=${_t%/}
tmp=$(mktemp -d "$_t/doc-lint-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

repo() {  # $1 name -> a fresh repo with docs/ tracked
  r="$tmp/$1"; mkdir -p "$r/docs"; git -C "$r" init -q
  echo "# real" > "$r/docs/real.md"
  echo "$r"
}
put() {   # $1 repo  $2 text -> write docs/t.md and stage it
  printf '%s\n' "$2" > "$1/docs/t.md"; git -C "$1" add -A
}
run() { (cd "$1" && python3 "$lint" 2>&1) || true; }

# --- universal checks, no config ---------------------------------------------------------
r=$(repo plain)
put "$r" "See [[some-memory-slug]] for why."
assert_has "a wikilink is reported" "[wikilink]" "$(run "$r")"
put "$r" "As recorded (memory some-slug-name), this holds."
assert_has "a parenthesised memory pointer is reported" "[memory-ptr]" "$(run "$r")"
put "$r" "The memory \`some-slug-name\` says so."
assert_has "a bare memory pointer is reported" "[memory-ptr]" "$(run "$r")"
put "$r" "Grounded in (memory: \`colon-form-slug\`) here."
assert_has "a (memory: \`slug\`) pointer is reported" "colon-form-slug" "$(run "$r")"
put "$r" "- **Memories:** \`bold-first-slug\`, \`second-slug\` and \`third-slug\`."
out=$(run "$r")
assert_has "a bold Memories: list's first item is reported" "bold-first-slug" "$out"
assert_has "a list's second item is reported" "second-slug" "$out"
assert_has "a list's third item is reported" "third-slug" "$out"
put "$r" "Memories \`only-slug\` shaped this; see also \`docs/real.md\`."
assert_lacks "a later code span that is not a list item is not a memory" "real.md" "$(run "$r")"
put "$r" "**Detection is now automatic rather than a memory:** \`some-tool\` runs it."
assert_lacks "the word memory ending a bold phrase is not a pointer" "some-tool" "$(run "$r")"
put "$r" "Syntax is \`[[slug-name]]\` and \`(memory a-b)\`, quoted."
assert_lacks "a quoted form is a mention, not a use" "[memory-ptr]" "$(run "$r")"
assert_lacks "a quoted wikilink is a mention, not a use" "[wikilink]" "$(run "$r")"
put "$r" "Read \`docs/missing.md\` next."
assert_has "an untracked path in a tracked directory is reported" "[dangling-path]" "$(run "$r")"
put "$r" "Read \`docs/real.md\` next."
assert_lacks "a tracked path is not reported" "[dangling-path]" "$(run "$r")"
put "$r" "See \`docs/real.md:32-37\` for the range."
assert_lacks "a line-range suffix is not part of the path" "[dangling-path]" "$(run "$r")"
put "$r" "See \`docs/real.md:89-106,143-196\` for both blocks."
assert_lacks "a comma list of lines and ranges is not part of the path" "[dangling-path]" "$(run "$r")"
put "$r" "See \`docs/missing.md:1,2,3-4\` for the lines."
assert_has "a missing path with a line list is still reported" "[dangling-path]" "$(run "$r")"
put "$r" "Run \`docs/real.md check\` to verify."
assert_lacks "a command argument in the span is not part of the path" "[dangling-path]" "$(run "$r")"
put "$r" "Run \`docs/missing.md check\` to verify."
assert_has "a missing path followed by an argument is still reported" "[dangling-path]" "$(run "$r")"
assert_has "no config is SAID, not implied to be full coverage" "no config found" "$(run "$r")"

# --- the owner-prefix checks are config-gated --------------------------------------------
put "$r" "Per ADR-0009, and per 0009 D1."
out=$(run "$r")
assert_lacks "without adr-owners a bare ADR is correct (a project citing itself)" "[bare-adr]" "$out"
assert_lacks "without adr-owners a bare number+decision is not reported" "[bare-adr-decision]" "$out"

r=$(repo owners)
printf 'adr-owners: ABC XYZ\nid-prefixes: ABC\nfrozen: docs/archive/\n' > "$r/.doc-lint"
put "$r" "Per ADR-0009, per ADR 0010, and per 0011 D1."
out=$(run "$r")
assert_has "with adr-owners a bare ADR is reported" "[bare-adr]" "$out"
assert_has "the space form is the same defect" "ADR 0010" "$out"
assert_has "a bare number+decision is reported" "[bare-adr-decision]" "$out"
assert_has "the fix names the configured owners" "ABC-ADR-" "$out"
put "$r" "Per ABC-ADR-0009 and XYZ-ADR-0010 D1, quoting \`ADR-0011\`."
out=$(run "$r")
assert_lacks "a prefixed citation passes" "[bare-adr]" "$out"
assert_lacks "a prefixed citation with a decision passes" "[bare-adr-decision]" "$out"
put "$r" "Covered by ABC-11/12/13."
assert_has "id shorthand is reported" "[id-shorthand]" "$(run "$r")"
put "$r" "Covered by ABC-11, 2026-09-04."
assert_lacks "an id followed by a date is not shorthand" "[id-shorthand]" "$(run "$r")"
mkdir -p "$r/docs/archive"; echo "Per ADR-0009." > "$r/docs/archive/old.md"; git -C "$r" add -A
assert_lacks "a frozen path is exempt from the reference-form checks" "archive/old.md" "$(run "$r")"

# --- session-path is config-supplied, and bare-in-prose only ------------------------------
r=$(repo sess)
printf 'session-path: /agent-state/(?!<)([A-Za-z0-9-]+)\n' > "$r/.doc-lint"
put "$r" "It lived in /agent-state/some-machine-slug until then."
assert_has "a bare configured session path is reported" "[session-path]" "$(run "$r")"
put "$r" "Run \`ls /agent-state/some-machine-slug\` to see it."
assert_lacks "a code-formatted session path is an operand, not a defect" "[session-path]" "$(run "$r")"

# --- ledger sections: a memory named in a ledger of absorbed memories is an identifier ------
r=$(repo ledger)
printf 'ledger-sections: Provenance\n' > "$r/.doc-lint"
put "$r" "$(printf '## Rule\n\nBody text.\n\n### Provenance\n\nAbsorbs: memory `some-old-slug`.\n\n#### Sub\n\nAlso memory `another-slug`.\n\n### After\n\nSee memory `later-slug`.')"
out=$(run "$r")
assert_lacks "a memory named in a ledger section is not reported" "some-old-slug" "$out"
assert_lacks "a ledger's sub-heading stays inside the ledger" "another-slug" "$out"
assert_has "the ledger ends at the next heading of its level" "later-slug" "$out"
r=$(repo noledger)
put "$r" "$(printf '### Provenance\n\nAbsorbs: memory `some-old-slug`.')"
assert_has "without ledger-sections the same line is reported" "some-old-slug" "$(run "$r")"

# --- the ratchet: only added lines block ---------------------------------------------------
r=$(repo ratchet)
printf 'adr-owners: ABC\n' > "$r/.doc-lint"
printf 'Old line citing ADR-0001.\n' > "$r/docs/t.md"
git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
printf 'Old line citing ADR-0001.\nNew clean line.\n' > "$r/docs/t.md"; git -C "$r" add -A
out=$( (cd "$r" && python3 "$lint" --added-only --blocking-only docs/t.md 2>&1) || true)
assert_lacks "--added-only ignores an inherited defect on an untouched line" "[bare-adr]" "$out"
printf 'Old line citing ADR-0001.\nNew line citing ADR-0002.\n' > "$r/docs/t.md"; git -C "$r" add -A
out=$( (cd "$r" && python3 "$lint" --added-only --blocking-only docs/t.md 2>&1) || true)
assert_has "--added-only reports a defect on an added line" "ADR-0002" "$out"
(cd "$r" && python3 "$lint" --added-only --blocking-only docs/t.md >/dev/null 2>&1) \
  && bad "a blocking finding exits non-zero" || ok "a blocking finding exits non-zero"

# --- spec decisions: a spec or plan names a durable home for each decision ----------------
# Enabled by spec-dirs:. Covers documents dated on or after spec-cutover:, reads the WHOLE staged
# document (a status change can finish a spec without touching its decisions), and treats a
# document moved out of spec-dirs, or deleted, as finished.
r=$(repo specs)
mkdir -p "$r/docs/specs" "$r/docs/adr" "$r/docs/register"
printf 'spec-dirs: docs/specs/\nspec-cutover: 2026-10-01\nown-prefix: ABC\nadr-dir: docs/adr/\nregister-dir: docs/register/\n' > "$r/.doc-lint"
echo "# A decision" > "$r/docs/adr/0007-a-decision.md"
echo "# A thing" > "$r/docs/register/ABC-0012-a-thing.md"
echo "# Guide" > "$r/docs/guide.md"
git -C "$r" add -A
git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
spec() {  # $1 filename  $2 content -> write docs/specs/$1, stage it, run the staged check on it
  printf '%s\n' "$2" > "$r/docs/specs/$1"; git -C "$r" add -A
  (cd "$r" && python3 "$lint" --added-only --blocking-only "docs/specs/$1" 2>&1) || true
}
unstage() { git -C "$r" rm -q --cached -r docs/specs >/dev/null 2>&1 || true; rm -rf "$r/docs/specs"; mkdir -p "$r/docs/specs"; }
body() {  # $1 status line  $2 decisions section body
  printf '# A spec\n\n%s\n\n## Goal\n\nText.\n\n## Decisions\n\n%s\n' "$1" "$2"
}
GOOD='- Use the own log — ADR-0007
- Cite another owner — XYZ-ADR-0003
- Track it — ABC-0012
- Write it down — docs/guide.md
- Share a helper — other:lib/x.sh
- Not yet placed — pending
- Not taken — dropped'

out=$(spec 2026-10-02-a.md "$(printf '# A spec\n\nStatus: draft\n\n## Goal\n\nText.\n')")
assert_has "a spec with no Decisions section is refused" "[spec-decisions]" "$out"
out=$(spec 2026-10-02-a.md "$(printf '# A spec\n\n## Decisions\n\nNone.\n')")
assert_has "a spec with no status line is refused" "[spec-status]" "$out"
out=$(spec 2026-10-02-a.md "$(body 'Status: draft' "$GOOD")")
assert_lacks "every home form is accepted in an open spec" "[spec-" "$out"
out=$(spec 2026-10-02-a.md "$(body 'Status: draft' '- Own log, missing — ADR-0099')")
assert_has "an own ADR id that does not resolve is refused" "ADR-0099" "$out"
out=$(spec 2026-10-02-a.md "$(body 'Status: draft' '- Own register, missing — ABC-0099')")
assert_has "an own register id that does not resolve is refused" "ABC-0099" "$out"
out=$(spec 2026-10-02-a.md "$(body 'Status: draft' '- A path, missing — docs/nope.md')")
assert_has "a path home that is not tracked is refused" "docs/nope.md" "$out"
echo "# other" > "$r/docs/specs/2026-10-03-other.md"
out=$(spec 2026-10-02-a.md "$(body 'Status: draft' '- Another spec — docs/specs/2026-10-03-other.md')")
assert_has "a spec cannot be a decision's home" "[spec-decisions]" "$out"
unstage
out=$(spec 2026-10-02-a.md "$(body 'Status: draft' '- Decided somewhere — TBD')")
assert_has "a home that fits no form is refused" "TBD" "$out"
out=$(spec 2026-10-02-a.md "$(body 'Status: draft' '- A decision with no home at all')")
assert_has "an entry with no home is refused" "[spec-decisions]" "$out"
out=$(spec 2026-10-02-a.md "$(body 'Status: draft' 'None.')")
assert_lacks "a section holding only None. is accepted" "[spec-" "$out"
out=$(spec 2026-10-02-a.md "$(body 'Status: draft' "$(printf 'None.\n- But also this — dropped')")")
assert_has "None. alongside an entry is refused" "[spec-decisions]" "$out"
out=$(spec 2026-10-02-a.md "$(body 'Status: executed 2026-10-04' "$GOOD")")
assert_has "a finished spec holding pending is refused" "[spec-pending]" "$out"
out=$(spec 2026-10-02-a.md "$(body 'Status: executed 2026-10-04' '- Not taken — dropped')")
assert_lacks "a finished spec with no pending home is accepted" "[spec-" "$out"
for st in '- **Status:** Executed, merged' '**Status**: abandoned' '> **Status (2026-10-05):** superseded' 'Status: ✅ executed'; do
  out=$(spec 2026-10-02-a.md "$(body "$st" '- Still open — pending')")
  assert_has "status markup '$st' reads as finished" "[spec-pending]" "$out"
done
out=$(spec 2026-10-02-a.md "$(body '**Status:** executing now' '- Still open — pending')")
assert_lacks "a status word that only starts like a finished one is not finished" "[spec-pending]" "$out"
unstage
out=$(spec 2026-09-01-old.md "$(printf '# Old spec\n\nNo section at all.\n')")
assert_lacks "a spec dated before the cutover is not checked" "[spec-" "$out"
unstage
printf '# Notes\n' > "$r/docs/specs/README.md"; git -C "$r" add -A
out=$( (cd "$r" && python3 "$lint" --added-only docs/specs/README.md 2>&1) || true)
assert_has "an undated file in spec-dirs is reported as advisory" "[spec-undated]" "$out"
unstage

# The whole document is read: finishing a spec by editing only its status line still refuses the
# pending entry on a line the commit does not touch.
printf '%s\n' "$(body 'Status: draft' '- Still open — pending')" > "$r/docs/specs/2026-10-06-b.md"
git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m b
printf '%s\n' "$(body 'Status: executed' '- Still open — pending')" > "$r/docs/specs/2026-10-06-b.md"; git -C "$r" add -A
out=$( (cd "$r" && python3 "$lint" --added-only --blocking-only docs/specs/2026-10-06-b.md 2>&1) || true)
assert_has "--added-only still refuses pending on an untouched line once finished" "[spec-pending]" "$out"
git -C "$r" checkout -q HEAD -- docs/specs/2026-10-06-b.md

# Moving a spec out of spec-dirs, or deleting it, finishes it.
mkdir -p "$r/docs/archive"; git -C "$r" mv docs/specs/2026-10-06-b.md docs/archive/2026-10-06-b.md
out=$( (cd "$r" && python3 "$lint" --added-only --blocking-only docs/archive/2026-10-06-b.md 2>&1) || true)
assert_has "moving a spec holding pending out of spec-dirs is refused" "[spec-pending]" "$out"
git -C "$r" reset -q --hard HEAD
git -C "$r" rm -q docs/specs/2026-10-06-b.md
out=$( (cd "$r" && python3 "$lint" --added-only --blocking-only 2>&1) || true)
assert_has "deleting a spec holding pending is refused" "[spec-pending]" "$out"
git -C "$r" reset -q --hard HEAD

# Configuration: off is said aloud, and a mistyped key is not silently ignored.
r2=$(repo nospec)
put "$r2" "Plain text."
assert_has "with no spec-dirs, doc-lint says the spec check is off" "spec check is off" "$(run "$r2")"
printf 'spec-dir: docs/specs/\n' > "$r2/.doc-lint"
assert_has "a mistyped spec- key is reported" "spec-dir" "$(run "$r2")"

echo ""
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
