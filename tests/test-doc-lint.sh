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
put "$r" "Syntax is \`[[slug-name]]\` and \`(memory a-b)\`, quoted."
assert_lacks "a quoted form is a mention, not a use" "[memory-ptr]" "$(run "$r")"
assert_lacks "a quoted wikilink is a mention, not a use" "[wikilink]" "$(run "$r")"
put "$r" "Read \`docs/missing.md\` next."
assert_has "an untracked path in a tracked directory is reported" "[dangling-path]" "$(run "$r")"
put "$r" "Read \`docs/real.md\` next."
assert_lacks "a tracked path is not reported" "[dangling-path]" "$(run "$r")"
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

echo ""
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
