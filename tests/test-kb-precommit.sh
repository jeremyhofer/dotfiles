#!/bin/sh
# Test: `kb install-hooks` wires a repo-local pre-commit that runs `kb lint`, so a
# malformed record physically cannot land. The hook is generic: it composes with any
# global hooks router (which chains to a repo's own pre-commit) and also works standalone.
# This test isolates from any ambient global core.hooksPath by pinning the repo's own
# hooks dir locally. Run: `sh tests/test-kb-precommit.sh`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }
kb() { sh "$KB" "$@"; }

command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }

r=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$r"' EXIT
git -C "$r" init -q
# isolate: pin this repo's own hooks dir (override any ambient global core.hooksPath) and
# disable signing so the throwaway commit does not depend on a signing key.
git -C "$r" config core.hooksPath "$r/.git/hooks"
git -C "$r" config user.email t@example.invalid
git -C "$r" config user.name  tester
git -C "$r" config commit.gpgsign false

# make `kb` reachable on PATH for the hook (production: it deploys to ~/.local/bin/kb)
bin="$r/bin"; mkdir -p "$bin"
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$KB" > "$bin/kb"; chmod +x "$bin/kb"

# install + mark the repo as a KB (discovery/kb-root marker)
kb install-hooks "$r" >/dev/null || { echo "FAIL: install-hooks errored"; exit 1; }
[ -x "$r/.git/hooks/pre-commit" ] || { echo "FAIL: pre-commit hook not installed/executable"; exit 1; }
grep -qF 'kb-precommit (generated)' "$r/.git/hooks/pre-commit" || { echo "FAIL: hook missing marker"; exit 1; }
: > "$r/kb.toml"
echo "ok:   install-hooks writes an executable, marked pre-commit hook"

# a malformed record (missing required fields) -> commit BLOCKED
mkdir -p "$r/context"; printf '%s\n' '---' 'name: x' 'type: context' '---' > "$r/context/x.md"
git -C "$r" add -A
( cd "$r" && PATH="$bin:$PATH" git commit -q -m bad ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: commit of malformed record was not blocked"; exit 1; }
echo "ok:   malformed record blocks the commit"

# the block cites the offending file / a validation reason
out=$( ( cd "$r" && PATH="$bin:$PATH" git commit -q -m bad ) 2>&1 || true )
printf '%s' "$out" | grep -qi 'x\.md\|required\|missing' || { echo "FAIL: block did not report a reason"; echo "$out"; exit 1; }
echo "ok:   block reports the offending record"

# fix it (scaffold a valid record) -> commit SUCCEEDS
rm "$r/context/x.md"
KB_ROOT="$r" KB_DATE=2026-07-15 kb new context x >/dev/null
git -C "$r" add -A
( cd "$r" && PATH="$bin:$PATH" git commit -q -m ok ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL: commit of a valid KB should succeed, got ${rc:-0}"; exit 1; }
echo "ok:   valid KB commits cleanly"

# re-install is idempotent (marker present -> no refusal)
kb install-hooks "$r" >/dev/null 2>&1 || { echo "FAIL: re-install should be idempotent"; exit 1; }
echo "ok:   re-install is idempotent"

# a foreign (non-kb) pre-commit is not clobbered
r2=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$r" "$r2"' EXIT
git -C "$r2" init -q
printf '#!/bin/sh\nexit 0\n' > "$r2/.git/hooks/pre-commit"; chmod +x "$r2/.git/hooks/pre-commit"
kb install-hooks "$r2" >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: should refuse to clobber a foreign pre-commit"; exit 1; }
grep -qF 'kb-precommit' "$r2/.git/hooks/pre-commit" && { echo "FAIL: foreign hook was overwritten"; exit 1; }
echo "ok:   foreign pre-commit preserved"

echo "PASS"
