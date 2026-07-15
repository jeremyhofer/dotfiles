#!/bin/sh
# Test: `kb lint` fails loud (exit 1, per-file `path: reason` on stderr) on:
#   (a) missing required frontmatter / invalid enums
#   (b) an edge target (related/depends-on/supersedes) that resolves to no record `name`
#   (c) a `[[` wikilink in the body (prose must be self-contained)
#   (d) a duplicate `name`
#   (e) a `sensitivity: restricted` record not under an encrypted (.age) path
# and exits 0 on a clean KB. Run directly: `sh tests/test-kb-lint.sh`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }
kb() { sh "$KB" "$@"; }

newkb() { d=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); mkdir -p "$d/context"; printf '%s' "$d"; }

# valid record body with an overridable edge line ($1=name, $2=extra-line)
emit() { # file name extra
  { printf '%s\n' '---' "name: $2" 'description: x' 'type: context' 'sensitivity: internal' \
      'tier: 2' 'status: active' "$3" 'updated: 2026-07-15' '---' 'body text'; } > "$1"
}

# (b) dangling edge -> exit 1, reason names the target
d=$(newkb); emit "$d/context/a.md" a 'depends-on: [ghost]'
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: dangling edge should exit 1, got ${rc:-0}"; exit 1; }
KB_ROOT="$d" kb lint 2>&1 | grep -q 'ghost' || { echo "FAIL: reason should name the dangling target 'ghost'"; exit 1; }
echo "ok:   dangling edge caught, target named"

# fix the edge -> clean (exit 0)
sed -i 's/\[ghost\]/[]/' "$d/context/a.md"
KB_ROOT="$d" kb lint >/dev/null 2>&1 || { echo "FAIL: valid KB should lint clean"; exit 1; }
echo "ok:   valid KB lints clean"

# a resolvable edge -> clean
d=$(newkb); emit "$d/context/a.md" a 'depends-on: [b]'; emit "$d/context/b.md" b 'related: []'
KB_ROOT="$d" kb lint >/dev/null 2>&1 || { echo "FAIL: resolvable edge should lint clean"; exit 1; }
echo "ok:   resolvable edge lints clean"

# (a) invalid enum -> exit 1
d=$(newkb); emit "$d/context/a.md" a 'related: []'; sed -i 's/^type: context$/type: bogus/' "$d/context/a.md"
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
d=$(newkb); emit "$d/context/a.md" a 'related: []'; sed -i 's/^sensitivity: internal$/sensitivity: restricted/' "$d/context/a.md"
KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: restricted in plaintext .md should exit 1, got ${rc:-0}"; exit 1; }
KB_ROOT="$d" kb lint 2>&1 | grep -qi 'restricted' || { echo "FAIL: reason should mention 'restricted'"; exit 1; }
mv "$d/context/a.md" "$d/context/a.md.age"
KB_ROOT="$d" kb lint >/dev/null 2>&1 || { echo "FAIL: encrypted .md.age should be skipped (opaque), lint clean"; exit 1; }
echo "ok:   restricted-path rule enforced (plaintext flagged; ciphertext skipped)"

# (e') a plaintext restricted record must be flagged even when an ANCESTOR dir merely
# contains the substring ".age" (suffix check, not substring).
base=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$base"' EXIT
root="$base/notes.agenda"; mkdir -p "$root/context"
emit "$root/context/a.md" a 'related: []'; sed -i 's/^sensitivity: internal$/sensitivity: restricted/' "$root/context/a.md"
KB_ROOT="$root" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: restricted plaintext under a '.age'-substring dir should still be flagged, got ${rc:-0}"; exit 1; }
echo "ok:   restricted check is a .md.age suffix, not a substring"

echo "PASS"
