#!/usr/bin/env bash
# Tests for context-lint. A conforming fixture must pass clean; each planted defect must produce its
# own finding and fail the run, and the near-misses (a scoped rules file, an import inside a code
# span, a number that is a limit) must not.

set -u

LINT="$(cd "$(dirname "$0")/.." && pwd)/private_dot_local/bin/executable_context-lint"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

good() { # <dir> -- a conforming repository
  mkdir -p "$1/docs"
  printf '@AGENTS.md\n' > "$1/CLAUDE.md"
  cat > "$1/AGENTS.md" <<'EOF'
# widget

A small widget library. Private; owned by its maintainer.

## Tasks

Entry point: `just`. Live list: `just --list`.

## Layout

- `docs/adr/`: decisions.

## Deeper context

- Decisions in `docs/adr/` win over any summary. Read `docs/release.md` before a release.

## Rules

- Never publish from a dirty tree: the release script cannot tell.

## Writing here

**Prose voice: technical.**

## Testing

Tests need at most 2 workers.
EOF
}
run() { python3 "$LINT" "$1" 2>&1; }

printf '\n== a conforming repository ==\n'
d="$TMP/good"; good "$d"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && grep -q '0 blocking, 0 advisory' <<< "$out" \
  && ok "passes with nothing to report" || bad "conforming repo did not pass clean" "rc=$rc: $out"

printf '\n== CLAUDE.md does not import AGENTS.md ==\n'
d="$TMP/noimport"; good "$d"; printf '# widget\nSee AGENTS.md.\n' > "$d/CLAUDE.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[claude-import\] BLOCKING' <<< "$out" && ok "refused" || bad "missing import not caught" "$out"

printf '\n== no AGENTS.md ==\n'
d="$TMP/noagents"; good "$d"; rm "$d/AGENTS.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[agents-missing\]' <<< "$out" && ok "refused" || bad "missing AGENTS.md not caught" "$out"

printf '\n== a required section is missing, and one is out of order ==\n'
d="$TMP/sections"; good "$d"; sed '/^## Rules$/,/^- Never/d' "$d/AGENTS.md" > "$d/a.tmp" && mv "$d/a.tmp" "$d/AGENTS.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'missing required section `## Rules`' <<< "$out" && ok "a missing section is refused" || bad "missing section not caught" "$out"
d="$TMP/order"; good "$d"
python3 - "$d/AGENTS.md" <<'EOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
tasks = s[s.index("## Tasks"):s.index("## Layout")]
p.write_text(s.replace(tasks, "").replace("## Rules", tasks + "## Rules"))
EOF
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'out of order' <<< "$out" && ok "an out-of-order section is refused" || bad "order not checked" "$out"

printf '\n== an optional section before the required ones end ==\n'
d="$TMP/optional"; good "$d"
python3 - "$d/AGENTS.md" <<'EOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("## Layout", "## Architecture\n\nBulk writes must be scoped.\n\n## Layout", 1))
EOF
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'optional section `## Architecture`' <<< "$out" && ok "refused" || bad "early optional section not caught" "$out"

printf '\n== no title heading ==\n'
d="$TMP/title"; good "$d"; sed '1s/^# widget$/widget/' "$d/AGENTS.md" > "$d/a.tmp" && mv "$d/a.tmp" "$d/AGENTS.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[title\]' <<< "$out" && ok "refused" || bad "missing title not caught" "$out"

printf '\n== size, counting what an import pulls in ==\n'
d="$TMP/size"; good "$d"
awk 'BEGIN { for (i = 0; i < 190; i++) print "- filler line " i }' > "$d/docs/extra.md"
printf '@AGENTS.md\n\n@docs/extra.md\n' > "$d/CLAUDE.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[size\] BLOCKING' <<< "$out" && grep -q 'docs/extra.md' <<< "$out" \
  && ok "an import is counted, and the total is refused over 200 lines" || bad "import not counted toward the cap" "$out"
d="$TMP/bytes"; good "$d"
python3 -c 'print("- " + "x" * 15000)' >> "$d/AGENTS.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'bytes (cap 14000)' <<< "$out" && ok "long lines are refused by the byte cap" || bad "byte cap not enforced" "$out"

printf '\n== rules files: unscoped counted, scoped not ==\n'
d="$TMP/rules"; good "$d"; mkdir -p "$d/.claude/rules"
awk 'BEGIN { for (i = 0; i < 190; i++) print "- rule " i }' > "$d/.claude/rules/always.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'always.md' <<< "$out" && ok "an unscoped rules file counts toward the cap" || bad "unscoped rules not counted" "$out"
{ printf -- '---\npaths:\n  - "src/**"\n---\n'; cat "$d/.claude/rules/always.md"; } > "$d/.claude/rules/scoped.md"; rm "$d/.claude/rules/always.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'scoped.md' <<< "$out" && ok "a paths:-scoped rules file is not counted" || bad "scoped rules counted" "$out"

printf '\n== imports that do not resolve, and one that is only a mention ==\n'
d="$TMP/imports"; good "$d"; printf '@AGENTS.md\n\n@docs/missing.md\n' > "$d/CLAUDE.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '`@docs/missing.md` does not resolve' <<< "$out" && ok "a broken import is refused" || bad "broken import not caught" "$out"
d="$TMP/mention"; good "$d"; printf '@AGENTS.md\n\nUse `@docs/missing.md` to import. Mail me@example.com.\n' > "$d/CLAUDE.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ok "an import in a code span and an e-mail address are not imports" || bad "mention read as an import" "$out"

printf '\n== generated blocks ==\n'
d="$TMP/gen"; good "$d"
printf '@AGENTS.md\n\n<!-- nx configuration start-->\nNx things.\n<!-- nx configuration end-->\n' > "$d/CLAUDE.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ok "a generated block at the end of CLAUDE.md passes" || bad "trailing generated block refused" "$out"
printf 'Hand-written after the block.\n' >> "$d/CLAUDE.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[generated\] BLOCKING' <<< "$out" && ok "text after a generated block is refused" || bad "text after block not caught" "$out"
d="$TMP/genfirst"; good "$d"
python3 - "$d/AGENTS.md" <<'EOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("## Tasks", "<!-- nx configuration start-->\nNx.\n<!-- nx configuration end-->\n\n## Tasks", 1))
EOF
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'sits before the required sections' <<< "$out" && ok "a generated block before the required sections is refused" || bad "early block not caught" "$out"

printf '\n== volatile figures are advisory ==\n'
d="$TMP/volatile"; good "$d"; printf -- '- The suite currently has 412 tests, as of 2026.\n' >> "$d/AGENTS.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '\[volatile\] advisory' <<< "$out")" -eq 3 ] \
  && ok "a census, a date pin and \"currently\" are each reported, and the run still passes" || bad "volatile figures misreported" "rc=$rc: $out"

printf '\n== a nested context file ==\n'
d="$TMP/nested"; mkdir -p "$d"; printf '@AGENTS.md\n' > "$d/CLAUDE.md"; printf '# API conventions\n\n- One handler per file.\n' > "$d/AGENTS.md"
out=$(python3 "$LINT" --nested "$d" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "--nested passes a nested file without the root's sections" || bad "--nested demanded root sections" "$out"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'missing required section' <<< "$out" && ok "without --nested, the same directory is checked as a root" || bad "root checks skipped without --nested" "$out"
printf '# API\n' > "$d/CLAUDE.md"
out=$(python3 "$LINT" --nested "$d" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[claude-import\]' <<< "$out" && ok "--nested still requires the @AGENTS.md bridge" || bad "--nested skipped the bridge" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
