#!/bin/sh
# Test: adopt-audit flags a would-change deployed file whose content matches NEITHER source (exit 1),
# and passes when the deployed content matches source (exit 0). Stubs `chezmoi` on PATH so no real
# chezmoi/source is needed. No overlay is configured, so only the base comparison is exercised.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../setup/adopt-audit"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-adopt-audit.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/bin"

# Stub chezmoi: `status` reports one would-change target (.foo); `cat` echoes the base-source content
# (from $FAKE_BASE, exported by each case); everything else is a no-op (e.g. overlay `managed`).
cat > "$tmp/bin/chezmoi" <<'STUB'
#!/bin/sh
case "$1" in
  status) printf ' M .foo\n' ;;
  cat)    [ -n "${FAKE_BASE:-}" ] && printf '%s' "$FAKE_BASE" ;;
  *)      : ;;
esac
STUB
chmod +x "$tmp/bin/chezmoi"

run() { HOME="$tmp/home" PATH="$tmp/bin:$PATH" FAKE_BASE="$1" sh "$script" 2>&1; }

# Case A — deployed .foo is FOREIGN (differs from base source) -> UNCAPTURED, exit 1.
printf 'FOREIGN work content\n' > "$tmp/home/.foo"
out=$(run 'BASE generic content') && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL(A): expected exit 1 (uncaptured), got ${rc:-0}"; echo "$out"; exit 1; }
echo "$out" | grep -q 'UNCAPTURED  .foo' || { echo "FAIL(A): foreign file not flagged"; echo "$out"; exit 1; }
echo "ok:   foreign content flagged (exit 1)"

# Case B — deployed .foo MATCHES base source -> captured, clean, exit 0.
printf 'BASE generic content' > "$tmp/home/.foo"
out=$(run 'BASE generic content') && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(B): expected exit 0 (clean), got ${rc:-0}"; echo "$out"; exit 1; }
echo "ok:   captured content passes (exit 0)"

echo "PASS"
