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
  printf '# Documents\n\nNothing yet.\n' > "$1/docs/README.md"
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

printf '\n== the docs/ layout ==\n'
d="$TMP/docs"; good "$d"; mkdir -p "$d/docs/adr" "$d/docs/research" "$d/docs/seo"
printf '# Documents\n\n- `adr/`: decisions.\n- `research/`: investigations.\n- `seo/`: search data.\n- `primer.md`: the ads primer.\n' > "$d/docs/README.md"
printf 'x\n' > "$d/docs/primer.md"; printf 'x\n' > "$d/docs/research/2026-09-01-sweep.md"
python3 - "$d/AGENTS.md" <<'EOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("- `docs/adr/`: decisions.", "- `docs/adr/`: decisions. `docs/seo/`: search-console exports.", 1))
EOF
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ! grep -q '\[docs-' <<< "$out" && ok "an indexed tree with a declared domain directory passes" || bad "conforming docs tree refused" "$out"
rm "$d/docs/README.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-index\].*no docs/README.md' <<< "$out" && ok "a docs tree without an index is refused" || bad "missing index not caught" "$out"
printf '# Documents\n\n- `adr/`, `research/`, `seo/`.\n' > "$d/docs/README.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'does not name `primer.md`' <<< "$out" && ok "a loose document the index does not name is refused" || bad "unindexed loose document not caught" "$out"
printf '# Documents\n\n- `adr/`, `research/`, `seo/`, `misc/`.\n- `primer.md`.\n' > "$d/docs/README.md"; mkdir -p "$d/docs/misc"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-layout\].*docs/misc' <<< "$out" && ! grep -q 'docs/seo' <<< "$out" \
  && ok "an undeclared subdirectory is refused, a declared one is not" || bad "layout check wrong" "$out"
rmdir "$d/docs/misc"; printf 'x\n' > "$d/docs/research/sweep-notes.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-dated\].*sweep-notes.md' <<< "$out" && ok "an undated research note is refused" || bad "undated note not caught" "$out"
rm "$d/docs/research/sweep-notes.md"; mkdir -p "$d/docs/research/2026-09-28-spike-results"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ok "a dated research directory passes" || bad "dated directory refused" "$out"

printf '\n== docs/ entries come from the git index in a work tree ==\n'
d="$TMP/docs-git"; good "$d"; mkdir -p "$d/docs/adr"; printf 'x\n' > "$d/docs/adr/0001-x.md"
printf '# Documents\n\n- `adr/`: decisions.\n' > "$d/docs/README.md"
git -C "$d" init -q && git -C "$d" add -A
mkdir -p "$d/docs/portfolio/FIN"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'portfolio' <<< "$out" && ok "an untracked empty subdirectory is not refused" || bad "untracked leftover directory refused" "$out"
printf 'x\n' > "$d/docs/portfolio/FIN/row.md"; git -C "$d" add docs/portfolio
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-layout\].*docs/portfolio' <<< "$out" && ok "the same subdirectory with a tracked file is refused" || bad "tracked undeclared directory not caught" "$out"
git -C "$d" rm -rq --cached docs/portfolio; rm -rf "$d/docs/portfolio"
mkdir -p "$d/docs/research"; printf 'x\n' > "$d/docs/research/2026-09-01-a.md"; git -C "$d" add docs/research
printf '# Documents\n\n- `adr/`: decisions.\n- `research/`: investigations.\n' > "$d/docs/README.md"
printf 'x\n' > "$d/docs/research/loose-notes.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'loose-notes' <<< "$out" && ok "an untracked undated research note is not refused" || bad "untracked undated note refused" "$out"
git -C "$d" add docs/research/loose-notes.md
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-dated\].*loose-notes.md' <<< "$out" && ok "a staged undated research note is refused" || bad "staged undated note not caught" "$out"

printf '\n== retired homes and document types outside docs/ ==\n'
d="$TMP/retired"; good "$d"; mkdir -p "$d/docs/claude"; printf 'x\n' > "$d/docs/claude/arch.md"
printf '# Documents\n\n- `claude/`: the manual.\n' > "$d/docs/README.md"
python3 - "$d/AGENTS.md" <<'EOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("- `docs/adr/`: decisions.", "- `docs/adr/`: decisions. `docs/claude/`: the manual.", 1))
EOF
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-retired\].*docs/claude' <<< "$out" && ok "docs/claude/ is refused even when declared" || bad "declared docs/claude/ passed" "$out"
rm -rf "$d/docs/claude"; mkdir -p "$d/docs/agents"; printf 'x\n' > "$d/docs/agents/a.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-retired\].*docs/agents' <<< "$out" && ok "docs/agents/ is refused" || bad "docs/agents/ passed" "$out"
rm -rf "$d/docs/agents"; printf '# Documents\n\nNothing yet.\n' > "$d/docs/README.md"
mkdir -p "$d/tools/.superpowers/x"; printf 'x\n' > "$d/tools/.superpowers/x/s.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-retired\].*tools/.superpowers' <<< "$out" && ok "a .superpowers path anywhere is refused" || bad "nested .superpowers passed" "$out"
rm -rf "$d/tools"; mkdir -p "$d/research"; printf 'x\n' > "$d/research/2026-09-01-a.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-outside\].*research' <<< "$out" && ok "a top-level research/ is refused" || bad "top-level research/ passed" "$out"
rm -rf "$d/research"
mkdir -p "$d/goals/research" "$d/packages/x/docs" "$d/policies"
printf 'x\n' > "$d/goals/research/2026-09-01-a.md"; printf 'x\n' > "$d/packages/x/docs/guide.md"; printf '{}\n' > "$d/policies/allow.json"
printf '{"name":"x"}\n' > "$d/packages/x/package.json"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ! grep -q '\[docs-' <<< "$out" && ok "nested research/, a publishable package docs/ tree and top-level policies/ pass" || bad "near-miss refused" "$out"
git -C "$d" init -q && git -C "$d" add -A
mkdir -p "$d/research"; printf 'x\n' > "$d/research/2026-09-01-a.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'docs-outside' <<< "$out" && ok "an untracked top-level research/ in a work tree passes" || bad "untracked top-level research/ refused" "$out"
git -C "$d" add research
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-outside\].*research' <<< "$out" && ok "a tracked top-level research/ is refused" || bad "tracked top-level research/ passed" "$out"

printf '\n== a docs/ tree below the root only inside a publishable package ==\n'
d="$TMP/nesteddocs"; good "$d"
mkdir -p "$d/packages/pub/docs" "$d/frontend/docs/design" "$d/tools/x/docs"
printf '{"name":"pub","private":false}\n' > "$d/packages/pub/package.json"; printf 'x\n' > "$d/packages/pub/docs/guide.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'docs-nested' <<< "$out" && ok "a publishable package's docs/ passes" || bad "publishable package docs refused" "$out"
printf '{"name":"fe","private":true}\n' > "$d/frontend/package.json"; printf 'x\n' > "$d/frontend/docs/design/diff.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-nested\].*frontend/docs.*private package' <<< "$out" && ok "a private package's docs/ is refused" || bad "private package docs passed" "$out"
rm -rf "$d/frontend"; printf 'x\n' > "$d/tools/x/docs/notes.md"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && grep -q '\[docs-nested\].*tools/x/docs.*no package.json' <<< "$out" && ok "a docs/ tree with no package.json above it is refused" || bad "unowned nested docs passed" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
