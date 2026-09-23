#!/bin/sh
# Tests for comment-lint. Every case PLANTS a defect and asserts the tool reports it, or
# plants the near-miss and asserts it does not.
#
# WHY IT IS SHAPED THIS WAY: a check that has only ever been seen green is of unknown
# value. Observing a red once, by hand, retires that objection for one afternoon; a file
# of plants retires it for every future edit to the patterns, which is when the gate is
# most likely to quietly stop working.
#
# The fixtures live in heredocs, and their bodies are therefore invisible to the scanner
# under test -- it skips heredoc bodies, because a here-document is data being emitted and
# not prose about the code. That is what lets this file plant a violation of the standard
# it enforces without becoming a finding against itself. The property is load-bearing
# enough to be asserted below rather than assumed.
#
# The tool is a SINGLE FILE on purpose. It is installed on every machine this repo reaches,
# and each repository that gates on it calls it by name rather than carrying a copy -- so a
# rule tuned here takes effect everywhere at the next apply, instead of drifting per repo.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
lint="$here/../private_dot_local/bin/executable_comment-lint"
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok:   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

# assert_has <label> <needle> <output>
assert_has() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (expected to find: $2)" ;;
  esac
}

assert_lacks() {
  case "$3" in
    *"$2"*) bad "$1 (did NOT expect: $2)" ;;
    *) ok "$1" ;;
  esac
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/comment-lint-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q .
git config user.email t@example.invalid
git config user.name Test
git config commit.gpgsign false

cat > .comment-lint-markers <<'EOF'
# test vocabulary
(ZED|QUX)-(ADR-)?[0-9]+|private/tree
EOF

# --- the planted file. Every line is a deliberate defect or a deliberate near-miss. -----
cat > planted.py <<'EOF'
"""Module under test.

Wired up for ZED-12 and the private/tree layout.
Superseded by Task 8 (Phase 4.5a), which also covers Step 3.
Scope note: this task does not handle the empty case, as discussed.
Reads /home/someone/notes/thing.txt at the time of writing.
The fixture below has 4 rows, as of 2026-01-01.
A literal `ZED-12` and a quoted "QUX-3" are named, not relied on.
One entry per requested strategy, as requested by the caller.
"""

MARKER = "ZED-99"  # a string literal is code, not commentary

# On some earlier day this broke, which is why the guard exists.
EOF

cat > clean.sh <<'SH'
#!/bin/sh
# A comment with no defects at all: it says why, and names nothing outside this file.
cat <<'INNER'
# ZED-77 inside a here-document is emitted data, not prose about the code.
INNER
SH

# Two file types whose comments were silently skipped until 2026-09-23: Typst, where `#` opens
# CODE and `//` a comment, and .gitignore, found by name. An unrecognised extension is a quiet
# no-op, which is correct for the tool and invisible in a gate, so each type gets a case.
printf '// Task 3 decides the layout\n#set page(width: 10cm)\n' > doc.typ
printf '# Task 4 added this\nbuild/\n' > .gitignore

git add -A

out=$(python3 "$lint" planted.py clean.sh 2>&1 || true)
typ=$(python3 "$lint" doc.typ .gitignore 2>&1 || true)
assert_has "a Typst // comment is linted" "[plan-identifier] doc.typ:1" "$typ"
assert_lacks "a Typst # line is code, not a comment" "doc.typ:2" "$typ"
assert_has "a .gitignore comment is linted" "[plan-identifier] .gitignore:1" "$typ"

assert_has "program-marker fires on a bare record id" "[program-marker] planted.py:3" "$out"
assert_has "program-marker fires on a bare private tree name" "private/tree" "$out"
assert_has "plan-identifier fires on a task number" "\`Task 8\`" "$out"
assert_has "plan-identifier fires on a dotted phase number" "\`Phase 4.5a\`" "$out"
assert_has "session-deixis fires on this-task" "\`this task\`" "$out"
assert_has "session-deixis fires on a clause-final as-discussed" "\`as discussed\`" "$out"
assert_has "personal-path fires on a named home directory" "[personal-path] planted.py:6" "$out"
assert_has "stale-hedge fires on a self-dating sentence" "at the time of writing" "$out"
assert_has "stale-count fires on a census" "\`4 rows\`" "$out"
assert_has "stale-count fires on an as-of date" "as of 2026" "$out"

assert_lacks "Step N is deliberately not a plan identifier" "Step 3" "$out"
assert_lacks "a backticked marker is a mention, not a use" "planted.py:8" "$out"
assert_lacks "a marker in a string literal is code, not commentary" "planted.py:11" "$out"
assert_lacks "provenance about a past event is permitted" "planted.py:13" "$out"
assert_lacks "'per requested' is not deixis" "per requested" "$out"
assert_lacks "'as requested by' is a modifier, not deixis" "as requested" "$out"
assert_lacks "a clean file yields nothing" "clean.sh" "$out"

# --- exit status and the advisory split ------------------------------------------------
if python3 "$lint" planted.py >/dev/null 2>&1; then
  bad "a blocking finding exits non-zero"
else
  ok "a blocking finding exits non-zero"
fi

cat > advisory_only.py <<'EOF'
# The table holds 12 entries.
EOF
git add -A
if python3 "$lint" advisory_only.py >/dev/null 2>&1; then
  ok "an advisory-only finding exits zero"
else
  bad "an advisory-only finding exits zero"
fi
adv=$(python3 "$lint" --blocking-only advisory_only.py 2>&1 || true)
assert_lacks "--blocking-only drops the advisory category" "12 entries" "$adv"

# --- the ratchet -----------------------------------------------------------------------
git add -A
git commit -qm "baseline"

# An untouched pre-existing defect must NOT be reported under --added-only, and the same
# defect on a line this commit adds must be.
printf '# Introduced for Task 99.\n' >> planted.py
git add planted.py
ratchet=$(python3 "$lint" --added-only planted.py 2>&1 || true)
assert_has "--added-only reports a defect on an added line" "Task 99" "$ratchet"
assert_lacks "--added-only ignores an inherited defect" "\`Task 8\`" "$ratchet"

# The staged blob, not the working tree: a defect staged and then reverted on disk must
# still be caught, or a partial add slips past the gate.
printf '# Also for Task 77.\n' >> planted.py
git add planted.py
sed '$d' planted.py > planted.tmp && mv planted.tmp planted.py
staged=$(python3 "$lint" --added-only planted.py 2>&1 || true)
assert_has "--added-only reads the staged blob, not the working tree" "Task 77" "$staged"

# --- the vocabulary is configuration, and its absence is loud ---------------------------
rm .comment-lint-markers
git add -A
noVocab=$(COMMENT_LINT_MARKERS=/nonexistent python3 "$lint" planted.py 2>&1 || true)
assert_has "an unconfigured vocabulary says so" "INACTIVE" "$noVocab"
assert_lacks "an unconfigured vocabulary reports no marker" "[program-marker]" "$noVocab"
assert_has "the other categories still run without a vocabulary" "plan-identifier" "$noVocab"

# A pattern may begin with `#`: reading every `#`-line as a comment once discarded such a
# pattern silently and fell through to the next config source.
printf '# numbered references\n#[0-9]+\n' > hashvocab
printf '# see #12 for the reason\nx = 1\n' > hashref.py
git add -A
hashOut=$(python3 "$lint" --markers hashvocab hashref.py 2>&1 || true)
assert_has "a pattern starting with # is read as a pattern" "[program-marker] hashref.py:1" "$hashOut"
printf '# only a comment here\n' > emptyvocab
emptyOut=$(python3 "$lint" --markers emptyvocab hashref.py 2>&1 || true)
assert_has "a vocabulary file with no pattern says so" "holds no pattern" "$emptyOut"

# --- the same tree twice must produce the same bytes -----------------------------------
# Not a nicety. Findings are de-duplicated through a set, and a set iterates in hash order,
# which Python salts per process -- so an ordering key that does not cover the whole record
# makes the tool disagree with itself between runs over an unchanged tree. That shipped once
# and was found only by diffing two builds and discovering the diff was the tool, not the
# change. Any comparison of one version against another is worthless while it can recur.
# The two runs are given DIFFERENT hash seeds deliberately. Left to chance the two
# processes often salt the same way and the defect passes -- measured 1 run in 5 when the
# broken key was reinstated on purpose. Fixing the seeds to two known-different values turns
# a detector that usually notices into one that always does.
one=$(PYTHONHASHSEED=1 python3 "$lint" planted.py 2>/dev/null || true)
two=$(PYTHONHASHSEED=2 python3 "$lint" planted.py 2>/dev/null || true)
if [ "$one" = "$two" ]; then
  ok "two runs over the same tree produce identical output"
else
  bad "output is not deterministic between runs"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
