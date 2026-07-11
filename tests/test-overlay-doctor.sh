#!/bin/sh
# Test: overlay-doctor passes a complete overlay, fails (exit 1) on a missing/placeholder
# required file, requires ensure-keys iff gpgsign=true, and exit 2 when no overlay dir.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../setup/overlay-doctor"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-overlay-doctor.XXXXXX"); trap 'rm -rf "$tmp"' EXIT

mk() { # build a COMPLETE, compliant fake overlay source at $1
  ov="$1"; rm -rf "$ov"
  mkdir -p "$ov/dot_dotlocal/ssh" "$ov/dot_dotlocal/bootstrap.d" \
           "$ov/dot_config/nvim/spell" "$ov/private_dot_local/bin"
  printf '[user]\n\tsigningkey = ~/.ssh/x.pub\n[commit]\n\tgpgsign = false\n' > "$ov/dot_dotlocal/gitconfig"
  echo 'me ssh-ed25519 AAAA' > "$ov/dot_dotlocal/allowed_signers"
  echo 'export FOO=bar'      > "$ov/dot_dotlocal/zshenv.tmpl"
  : > "$ov/dot_config/nvim/spell/private.utf-8.add"
  echo 'base = ...; instance_eval(base)' > "$ov/dot_dotlocal/Brewfile.role"
  echo 'Host example'        > "$ov/dot_dotlocal/ssh/config"
  echo '#!/bin/sh'           > "$ov/dot_dotlocal/bootstrap.d/10-x.sh"
}

# Case A — complete overlay -> exit 0
mk "$tmp/ov"
OVERLAY_SRC="$tmp/ov" sh "$script" >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(A): complete overlay should pass, got ${rc:-0}"; exit 1; }
echo "ok:   complete overlay passes (exit 0)"

# Case B — missing required (Brewfile.role) -> exit 1, flagged
mk "$tmp/ov"; rm "$tmp/ov/dot_dotlocal/Brewfile.role"
out=$(OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL(B): missing required should exit 1, got ${rc:-0}"; echo "$out"; exit 1; }
echo "$out" | grep -q 'MISSING .*Brewfile.role' || { echo "FAIL(B): not flagged"; echo "$out"; exit 1; }
echo "ok:   missing required flagged (exit 1)"

# Case C — placeholder sentinel in a required file -> exit 1, flagged PLACEHOLDER
mk "$tmp/ov"; printf '# FIXME(overlay-doctor): fill me\n' >> "$tmp/ov/dot_dotlocal/ssh/config"
out=$(OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL(C): placeholder should exit 1, got ${rc:-0}"; echo "$out"; exit 1; }
echo "$out" | grep -q 'PLACEHOLDER .*ssh/config' || { echo "FAIL(C): placeholder not flagged"; echo "$out"; exit 1; }
echo "ok:   placeholder flagged (exit 1)"

# Case D — gpgsign=true but no ensure-keys -> exit 1, mentions ensure-keys
mk "$tmp/ov"; printf '[user]\n\tsigningkey = ~/.ssh/x.pub\n[commit]\n\tgpgsign = true\n' > "$tmp/ov/dot_dotlocal/gitconfig"
out=$(OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL(D): gpgsign=true needs ensure-keys, got ${rc:-0}"; echo "$out"; exit 1; }
echo "$out" | grep -q 'ensure-keys' || { echo "FAIL(D): ensure-keys not flagged"; echo "$out"; exit 1; }
echo "ok:   gpgsign=true requires ensure-keys (exit 1)"

# Case E — no overlay source dir -> exit 2
out=$(OVERLAY_SRC="$tmp/nope" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 2 ] || { echo "FAIL(E): missing overlay dir should exit 2, got ${rc:-0}"; echo "$out"; exit 1; }
echo "ok:   missing overlay dir -> exit 2"

echo "PASS"
