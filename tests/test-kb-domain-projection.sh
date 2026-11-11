#!/usr/bin/env bash
# Test: `kb project --domain D` writes ONE file, CLAUDE.local.md: a generated-file header, then
# one pointer line per Tier-1 record of the domain (name, description, a path a session in another
# repository can open), and the full text of a record only when it declares `inline: true` (the
# record's own statement that a fresh session needs it). The sensitivity ceiling applies as for
# Tier-0. The file is capped by `domain_projection_max_bytes` in kb.toml: `kb project --domain`
# refuses to write an over-cap file, and `kb project --check` (the commit gate) refuses an
# over-cap one AND a stale one, for every domain slice present on disk. Temp KB roots only.
# Run: `bash tests/test-kb-domain-projection.sh`.
set -eu
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
sedi() { _e=$1; _f=$2; sed "$_e" "$_f" > "$_f.sedi.$$" && mv "$_f.sedi.$$" "$_f"; }
here=$(cd "$(dirname "$0")" && pwd)
KB=${KB_UNDER_TEST:-$here/../private_dot_local/bin/executable_kb}   # override: plant a defect in a copy
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }

d=$(mktemp -d "$_TMP/kb.XXXXXX"); trap 'rm -rf "$d"' EXIT
home=$(dirname "$d"); base=$(basename "$d")
xdg="$d/xdg"; mkdir -p "$xdg/kb"
printf '[domain.devel]\nrepo = "%s/repo"\n' "$d" > "$xdg/kb/config.toml"
kbp() { HOME=$home XDG_CONFIG_HOME=$xdg KB_ROOT=$d sh "$KB" "$@"; }
set_field() { sedi "s|^$2:.*|$2: $3|" "$1"; }
mk() { # slug description [sensitivity] [inline]
  KB_DATE=2026-07-15 kbp new context "$1" >/dev/null
  f="$d/context/$1.md"
  set_field "$f" domain devel; set_field "$f" tier 1; set_field "$f" status active
  set_field "$f" description "$2"
  [ -z "${3:-}" ] || set_field "$f" sensitivity "$3"
  [ -z "${4:-}" ] || { awk '{print} /^status:/{print "inline: true"}' "$f" > "$f.t" && mv "$f.t" "$f"; }
  printf 'BODY-%s\n' "$1" >> "$f"
}
fail() { echo "FAIL: $1"; exit 1; }
out="$d/index/projections/domains/devel/CLAUDE.local.md"

mk fact-a "Mail routing facts. Read when changing mail delivery."
mk fact-b "Standing client rule. Read at the start of any session." "" inline
mk fact-p "Private detail. Read when touching secrets." private
kbp project >/dev/null   # Tier-0 (empty) so the bare --check below judges only the domain slices

# --- pointer line format ---
kbp project --domain devel >/dev/null 2>&1 || fail "project --domain devel should succeed"
[ -f "$out" ] || fail "CLAUDE.local.md not written at $out"
head -3 "$out" | grep -qi 'generated' || fail "header must say the file is generated"
head -5 "$out" | grep -q 'kb project --domain devel' || fail "header must give the regenerate command"
n=$(grep -c '^- .*fact-a' "$out" || true)
[ "$n" = 1 ] || fail "fact-a must have exactly one pointer line, found $n"
line=$(grep '^- .*fact-a' "$out")
case "$line" in *"Mail routing facts. Read when changing mail delivery."*) ;; *) fail "line lacks the description: $line" ;; esac
case "$line" in *"~/$base/context/fact-a.md"*) ;; *) fail "line lacks the ~-relative path ~/$base/context/fact-a.md: $line" ;; esac
echo "ok:   one pointer line per record: name, description, ~-relative path"

# --- full text only for a qualifying record ---
grep -q 'BODY-fact-a' "$out" && fail "a pointer-only record's body leaked into the projection"
grep -q 'BODY-fact-b' "$out" || fail "an 'inline: true' record's full text is missing"
[ "$(grep -c '^- .*fact-b' "$out")" = 1 ] || fail "an inline record still gets exactly one pointer line"
echo "ok:   full text only for inline: true"

# --- sensitivity ceiling ---
grep -q 'fact-p' "$out" && fail "a private record appeared under the default (internal) ceiling"
kbp project --domain devel --max-sensitivity private --out "$d/priv" >/dev/null 2>&1 || fail "private-ceiling run failed"
grep -q 'fact-p' "$d/priv/CLAUDE.local.md" || fail "--max-sensitivity private should include the private record"
echo "ok:   sensitivity ceiling respected"

# --- fresh passes ---
kbp project --check >/dev/null 2>&1 || fail "a fresh domain projection should pass project --check"
kbp project --domain devel --check >/dev/null 2>&1 || fail "a fresh domain projection should pass --domain --check"
echo "ok:   fresh projection passes the check"

# --- stale refused by the check ---
set_field "$d/context/fact-a.md" description "Changed description. Read always."
kbp project --check >/dev/null 2>&1 && fail "a stale domain projection must be refused by project --check"
kbp project --check 2>&1 | grep -q 'devel/CLAUDE.local.md' || fail "the drift message must name the stale file"
kbp project --domain devel >/dev/null 2>&1   # regenerate
kbp project --check >/dev/null 2>&1 || fail "regenerated projection should pass again"
echo "ok:   stale domain projection refused, regenerated one passes"

# --- over cap: refused by project, and by the check ---
printf 'domain_projection_max_bytes = 6000\n' > "$d/kb.toml"
kbp project --domain devel >/dev/null 2>&1 || fail "under the cap must succeed"
size=$(wc -c < "$out" | tr -d ' ')
printf 'domain_projection_max_bytes = 200\n' > "$d/kb.toml"
kbp project --check >/dev/null 2>&1 && fail "the check must refuse an over-cap domain projection even when fresh"
kbp project --check 2>&1 | grep -q 'OVER' || fail "the check must say OVER the cap"
rm -f "$out"
kbp project --domain devel >"$d/stdout" 2>"$d/stderr" && fail "project --domain must refuse an over-cap projection"
[ -f "$out" ] && fail "a refused over-cap projection was still written"
grep -q '200' "$d/stderr" && grep -q "$size" "$d/stderr" || fail "refusal must name the size ($size) and the cap (200): $(cat "$d/stderr")"
echo "ok:   over-cap refused by project and by the check, naming size and cap"

# --- lint validates the optional inline field ---
kbp lint >/dev/null 2>&1 || fail "records with inline: true should lint clean"
set_field "$d/context/fact-b.md" inline maybe
kbp lint >/dev/null 2>&1 && fail "inline: maybe must fail lint"
kbp lint 2>&1 | grep -q 'inline' || fail "lint must name the invalid inline field"
echo "ok:   lint rejects a non-boolean inline"

echo "PASS"
