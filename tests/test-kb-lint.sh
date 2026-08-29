#!/bin/sh
# Test: `kb lint` fails loud (exit 1, per-file `path: reason` on stderr) on:
#   (a) missing required frontmatter / invalid enums
#   (b) an edge target (related/depends-on/supersedes) that resolves to no record `name`
#   (c) a `[[` wikilink in the body (prose must be self-contained)
#   (d) a duplicate `name`
#   (e) a `sensitivity: restricted` record not under an encrypted (.age) path
# and exits 0 on a clean KB. Run directly: `sh tests/test-kb-lint.sh`.
set -eu
# sedi EXPR FILE -- in-place edit, portably. Deliberately NOT the GNU in-place flag: on
# BSD/macOS that form consumes the EXPRESSION as the backup suffix and then treats the file
# as the script, which is silently destructive rather than merely failing. Temp-file + mv
# behaves identically on both userlands.
# macOS sets TMPDIR WITH a trailing slash, so a naive "$_TMP/x.XXXXXX" yields a
# path containing "//". Harmless for file I/O and fatal the moment such a path is compared
# textually against one a tool reports back normalized. Strip it once, here.
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
sedi() { _e=$1; _f=$2; sed "$_e" "$_f" > "$_f.sedi.$$" && mv "$_f.sedi.$$" "$_f"; }

here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }
kb() { sh "$KB" "$@"; }

newkb() { d=$(mktemp -d "$_TMP/kb.XXXXXX"); mkdir -p "$d/context"; printf '%s' "$d"; }

# valid record body with an overridable edge line ($1=file, $2=name, $3=extra-line)
emit() { # file name extra
  { printf '%s\n' '---' "name: $2" 'description: x' 'type: context' 'domain: universal' \
      'sensitivity: internal' 'tier: 2' 'status: active' "$3" 'updated: 2026-07-15' '---' 'body text'; } > "$1"
}

# (b) dangling edge -> exit 1, reason names the target
d=$(newkb); emit "$d/context/a.md" a 'depends-on: [ghost]'
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: dangling edge should exit 1, got ${rc:-0}"; exit 1; }
KB_ROOT="$d" kb lint 2>&1 | grep -q 'ghost' || { echo "FAIL: reason should name the dangling target 'ghost'"; exit 1; }
echo "ok:   dangling edge caught, target named"

# fix the edge -> clean (exit 0)
sedi 's/\[ghost\]/[]/' "$d/context/a.md"
KB_ROOT="$d" kb lint >/dev/null 2>&1 || { echo "FAIL: valid KB should lint clean"; exit 1; }
echo "ok:   valid KB lints clean"

# a resolvable edge -> clean
d=$(newkb); emit "$d/context/a.md" a 'depends-on: [b]'; emit "$d/context/b.md" b 'related: []'
KB_ROOT="$d" kb lint >/dev/null 2>&1 || { echo "FAIL: resolvable edge should lint clean"; exit 1; }
echo "ok:   resolvable edge lints clean"

# (a) invalid enum -> exit 1
d=$(newkb); emit "$d/context/a.md" a 'related: []'; sedi 's/^type: context$/type: bogus/' "$d/context/a.md"
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: invalid enum should exit 1, got ${rc:-0}"; exit 1; }
echo "ok:   invalid enum caught"

# (a) missing required field -> exit 1
d=$(newkb); { printf '%s\n' '---' 'name: a' 'type: context' '---' 'body'; } > "$d/context/a.md"
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: missing required field should exit 1, got ${rc:-0}"; exit 1; }
echo "ok:   missing required field caught"

# (c) [[ in body -> exit 1
d=$(newkb); emit "$d/context/a.md" a 'related: []'
printf '%s\n' 'see [[other]] for more' >> "$d/context/a.md"
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: [[ in body should exit 1, got ${rc:-0}"; exit 1; }
echo "ok:   [[ in prose caught"

# (d) duplicate name -> exit 1
d=$(newkb); emit "$d/context/a.md" dup 'related: []'; emit "$d/context/b.md" dup 'related: []'
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: duplicate name should exit 1, got ${rc:-0}"; exit 1; }
KB_ROOT="$d" kb lint 2>&1 | grep -qi 'dup' || { echo "FAIL: duplicate reason should name 'dup'"; exit 1; }
echo "ok:   duplicate name caught"

# (e) restricted in a plaintext .md -> exit 1 (must be encrypted at rest). Once it is
#     encrypted (.md.age ciphertext) it is opaque to lint and skipped.
d=$(newkb); emit "$d/context/a.md" a 'related: []'; sedi 's/^sensitivity: internal$/sensitivity: restricted/' "$d/context/a.md"
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: restricted in plaintext .md should exit 1, got ${rc:-0}"; exit 1; }
KB_ROOT="$d" kb lint 2>&1 | grep -qi 'restricted' || { echo "FAIL: reason should mention 'restricted'"; exit 1; }
mv "$d/context/a.md" "$d/context/a.md.age"
KB_ROOT="$d" kb lint >/dev/null 2>&1 || { echo "FAIL: encrypted .md.age should be skipped (opaque), lint clean"; exit 1; }
echo "ok:   restricted-path rule enforced (plaintext flagged; ciphertext skipped)"

# (e') a plaintext restricted record must be flagged even when an ANCESTOR dir merely
# contains the substring ".age" (suffix check, not substring).
base=$(mktemp -d "$_TMP/kb.XXXXXX"); trap 'rm -rf "$base"' EXIT
root="$base/notes.agenda"; mkdir -p "$root/context"
emit "$root/context/a.md" a 'related: []'; sedi 's/^sensitivity: internal$/sensitivity: restricted/' "$root/context/a.md"
KB_ROOT="$root" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: restricted plaintext under a '.age'-substring dir should still be flagged, got ${rc:-0}"; exit 1; }
echo "ok:   restricted check is a .md.age suffix, not a substring"

# (f) a non-kebab-case name (here with an underscore + uppercase) is flagged
d=$(newkb); emit "$d/context/a.md" a 'related: []'; sedi 's/^name: a$/name: Bad_Name/' "$d/context/a.md"
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: non-kebab name should exit 1, got ${rc:-0}"; exit 1; }
KB_ROOT="$d" kb lint 2>&1 | grep -qi 'name' || { echo "FAIL: reason should mention the invalid name"; exit 1; }
echo "ok:   non-kebab name caught"

# (g) a section AFTER `### Provenance` is rejected. `kb project` renders a tier-0 body by replacing
# provenance through end-of-file with a pointer, so a section filed after it silently never reaches
# any session while looking perfectly correct in the source. Both directions are asserted: the
# violation is caught, and provenance-as-the-last-section passes.
d=$(newkb); emit "$d/context/a.md" a 'related: []'
printf '\n### Provenance\n\nAdopted 2026-01-01.\n' >> "$d/context/a.md"
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL: provenance as the last section should pass, got ${rc:-0}"; exit 1; }

printf '\n### A rule filed after provenance\n\nThis would never reach a session.\n' >> "$d/context/a.md"
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: a section after Provenance should exit 1, got ${rc:-0}"; exit 1; }
KB_ROOT="$d" kb lint 2>&1 | grep -qi 'provenance' || { echo "FAIL: reason should name the provenance ordering rule"; exit 1; }
echo "ok:   a section filed after Provenance is caught"

# `####` and deeper are subsections OF the provenance and must stay legal, or every amendment
# log in the tier-0 set would be a lint failure.
d=$(newkb); emit "$d/context/a.md" a 'related: []'
printf '\n### Provenance\n\nAdopted.\n\n#### Amended 2026-02-02\n\nDetail.\n' >> "$d/context/a.md"
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL: '#### Amended' under Provenance must stay legal, got ${rc:-0}"; exit 1; }
echo "ok:   amendment subsections under Provenance stay legal"

echo "PASS"
