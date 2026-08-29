#!/bin/sh
# Test: `kb install-hooks` wires a repo-local pre-commit that runs `kb lint` AND both
# derived-output freshness checks (`project --check`, `index --check`) against the
# ACTUAL KB root (resolved + embedded at install time, so it works even when the KB is
# nested below the git top level), so a malformed record cannot land. The hook is generic:
# it composes with any global hooks router and also works standalone. Regression coverage:
#   - the embedded `--kb-root` must precede the subcommand (else it is silently ignored),
#   - non-record markdown at the repo root (e.g. README) must NOT be linted,
#   - a KB nested below the git top level must still be validated,
#   - a KB that publishes NO derived outputs must still be able to commit (they are opt-in;
#     a freshness gate that bricks a fresh KB would just get uninstalled),
#   - but once a KB DOES publish an index, a stale one must block the commit.
# The test isolates from any ambient global core.hooksPath by pinning the repo's own hooks
# dir. Run: `sh tests/test-kb-precommit.sh`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }
kb() { sh "$KB" "$@"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }

# init_repo DIR -- a git repo isolated from any ambient global hooks + signing.
init_repo() {
  git -C "$1" init -q
  git -C "$1" config core.hooksPath "$1/.git/hooks"
  git -C "$1" config user.email t@example.invalid
  git -C "$1" config user.name  tester
  git -C "$1" config commit.gpgsign false
}
# make `kb` reachable on PATH for the hook (production: it deploys to ~/.local/bin/kb)
mk_kb_shim() { mkdir -p "$1"; printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$KB" > "$1/kb"; chmod +x "$1/kb"; }

# ---------- KB == repo root, with a non-record README present ----------
r=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$r"' EXIT
init_repo "$r"
bin="$r/bin"; mk_kb_shim "$bin"
printf '# project readme\nnot a KB record\n' > "$r/README.md"   # must be ignored by lint

KB_ROOT="$r" kb install-hooks "$r" >/dev/null || { echo "FAIL: install-hooks errored"; exit 1; }
hook="$r/.git/hooks/pre-commit"
[ -x "$hook" ] || { echo "FAIL: pre-commit hook not installed/executable"; exit 1; }
grep -qF 'kb-precommit (generated)' "$hook" || { echo "FAIL: hook missing marker"; exit 1; }
# the flag MUST precede the subcommand, else kb ignores it
grep -qE 'kb --kb-root "[^"]+" lint' "$hook" || { echo "FAIL: hook has --kb-root after the subcommand (would be ignored)"; exit 1; }
grep -qE 'kb --kb-root "[^"]+" project --check' "$hook" || { echo "FAIL: hook does not run project --check"; exit 1; }
grep -qE 'kb --kb-root "[^"]+" index --check' "$hook" || { echo "FAIL: hook does not run index --check"; exit 1; }
echo "ok:   install-hooks writes a marked hook with --kb-root before the subcommand"
echo "ok:   hook runs all three checks (lint + both freshness checks)"

# malformed record -> blocked
mkdir -p "$r/context"; printf '%s\n' '---' 'name: x' 'type: context' '---' > "$r/context/x.md"
git -C "$r" add -A
( cd "$r" && PATH="$bin:$PATH" git commit -q -m bad ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: malformed record commit not blocked"; exit 1; }
out=$( ( cd "$r" && PATH="$bin:$PATH" git commit -q -m bad ) 2>&1 || true )
printf '%s' "$out" | grep -qi 'x\.md\|required\|missing' || { echo "FAIL: block did not report a reason"; echo "$out"; exit 1; }
# the README must NOT be among the reported violations
printf '%s' "$out" | grep -qi 'README' && { echo "FAIL: README was linted as a record"; exit 1; }
echo "ok:   malformed record blocks; README is not linted"

# fix -> commit succeeds (valid record + README coexist)
rm "$r/context/x.md"; KB_ROOT="$r" KB_DATE=2026-07-15 kb new context x >/dev/null
git -C "$r" add -A
( cd "$r" && PATH="$bin:$PATH" git commit -q -m ok ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL: valid KB commit should succeed, got ${rc:-0}"; exit 1; }
echo "ok:   valid KB (alongside a README) commits cleanly"
echo "ok:   a KB publishing no derived outputs is not blocked by the freshness gate"

# ---------- once an index IS published, a stale one blocks ----------
# The gate's whole purpose. Plant the shape that actually drifted in production: one edited
# description, index not regenerated. It must block, and name the drifted file.
KB_ROOT="$r" kb index >/dev/null
git -C "$r" add -A
( cd "$r" && PATH="$bin:$PATH" git commit -q -m 'publish index' ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL: committing a freshly generated index should succeed"; exit 1; }
echo "ok:   a current published index commits cleanly"

fx="$r/context/x.md"
sed 's/^description:.*/description: "planted drift"/' "$fx" > "$fx.new" && mv "$fx.new" "$fx"
git -C "$r" add -A
out=$( ( cd "$r" && PATH="$bin:$PATH" git commit -q -m 'stale index' ) 2>&1 || true )
( cd "$r" && PATH="$bin:$PATH" git commit -q -m 'stale index' ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: stale index did not block the commit"; exit 1; }
printf '%s' "$out" | grep -q 'sources-of-truth.md' || { echo "FAIL: block did not name the drifted file; got: $out"; exit 1; }
echo "ok:   a stale published index blocks the commit, naming the drifted file"

# regenerating clears it -- the gate is satisfiable, not merely obstructive
KB_ROOT="$r" kb index >/dev/null
git -C "$r" add -A
( cd "$r" && PATH="$bin:$PATH" git commit -q -m 'regenerated' ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL: regenerating the index should clear the gate"; exit 1; }
echo "ok:   regenerating the index clears the gate"

# ---------- KB nested BELOW the git top level ----------
r2=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$r" "$r2"' EXIT
init_repo "$r2"
bin2="$r2/bin"; mk_kb_shim "$bin2"
kbroot="$r2/kb"; mkdir -p "$kbroot"; : > "$kbroot/kb.toml"
KB_ROOT="$kbroot" kb install-hooks "$r2" >/dev/null || { echo "FAIL: nested install-hooks errored"; exit 1; }
grep -qF "$kbroot" "$r2/.git/hooks/pre-commit" || { echo "FAIL: hook did not embed the nested KB root"; exit 1; }
# a malformed record in the nested KB must block a commit made from the git top level
mkdir -p "$kbroot/context"; printf '%s\n' '---' 'name: y' 'type: context' '---' > "$kbroot/context/y.md"
git -C "$r2" add -A
( cd "$r2" && PATH="$bin2:$PATH" git commit -q -m bad ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: nested-KB malformed record not blocked (hook did not target the KB)"; exit 1; }
echo "ok:   hook validates a KB nested below the git top level"

# ---------- guards ----------
KB_ROOT="$r" kb install-hooks "$r" >/dev/null 2>&1 || { echo "FAIL: re-install should be idempotent"; exit 1; }
echo "ok:   re-install is idempotent"

r3=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$r" "$r2" "$r3"' EXIT
init_repo "$r3"
printf '#!/bin/sh\nexit 0\n' > "$r3/.git/hooks/pre-commit"; chmod +x "$r3/.git/hooks/pre-commit"
KB_ROOT="$r3" kb install-hooks "$r3" >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: should refuse to clobber a foreign pre-commit"; exit 1; }
grep -qF 'kb-precommit' "$r3/.git/hooks/pre-commit" && { echo "FAIL: foreign hook overwritten"; exit 1; }
echo "ok:   foreign pre-commit preserved"

echo "PASS"
