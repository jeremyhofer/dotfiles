#!/bin/sh
# Test: overlay-doctor passes a complete overlay, fails (exit 1) on a missing/placeholder
# required file, requires ensure-keys iff gpgsign=true, and exit 2 when no overlay dir.
set -eu
# macOS sets TMPDIR WITH a trailing slash, so a naive "$_TMP/x.XXXXXX" yields a
# path containing "//". Harmless for file I/O and fatal the moment such a path is compared
# textually against one a tool reports back normalized. Strip it once, here.
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../setup/overlay-doctor"
tmp=$(mktemp -d "$_TMP/test-overlay-doctor.XXXXXX"); trap 'rm -rf "$tmp"' EXIT

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
  # Required pieces added to the doctor after this fixture was first written. Without them
  # Case A failed on a pristine tree, i.e. the suite was red and nobody noticed.
  mkdir -p "$ov/Devel"
  echo '[data]'              > "$ov/.chezmoi.toml.tmpl"
  echo 'projects: []'        > "$ov/Devel/mani.yaml.tmpl"
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

# ---- cross-layer safety (base <-> overlay), with a hermetic fake BASE_SRC ----
mkbase() { b="$1"; rm -rf "$b"; mkdir -p "$b/private_dot_local/bin" "$b/dot_config"; }  # clean, agrees w/ mk overlay

# Case F — overlay carries an exact_ directory (a deletion vector) -> exit 1, flagged.
mk "$tmp/ov"; mkbase "$tmp/base"; mkdir -p "$tmp/ov/exact_dot_somewhere"
out=$(OVERLAY_SRC="$tmp/ov" BASE_SRC="$tmp/base" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL(F): exact_ should exit 1, got ${rc:-0}"; echo "$out"; exit 1; }
echo "$out" | grep -qi 'exact_' || { echo "FAIL(F): exact_ not flagged"; echo "$out"; exit 1; }
echo "ok:   destructive exact_ attribute flagged (exit 1)"

# Case G — base + overlay co-own ~/.local with CONFLICTING attrs (base plain vs overlay private_) -> exit 1.
mk "$tmp/ov"; b="$tmp/base"; rm -rf "$b"; mkdir -p "$b/dot_local/bin" "$b/dot_config"
out=$(OVERLAY_SRC="$tmp/ov" BASE_SRC="$b" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL(G): attr conflict should exit 1, got ${rc:-0}"; echo "$out"; exit 1; }
echo "$out" | grep -q "CONFLICT.*'.local'" || { echo "FAIL(G): .local conflict not flagged"; echo "$out"; exit 1; }
echo "ok:   co-owned dir attribute conflict flagged (exit 1)"

# Case H — clean fake base + complete overlay, agreeing attrs -> exit 0, NO false-positive CONFLICT.
mk "$tmp/ov"; mkbase "$tmp/base"
out=$(OVERLAY_SRC="$tmp/ov" BASE_SRC="$tmp/base" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(H): clean cross-layer should exit 0, got ${rc:-0}"; echo "$out"; exit 1; }
if echo "$out" | grep -q 'CONFLICT'; then echo "FAIL(H): false-positive CONFLICT"; echo "$out"; exit 1; fi
echo "ok:   clean cross-layer passes, no false positive (exit 0)"


# Case E — required pieces authored as chezmoi TEMPLATES (.tmpl) are still provisioned.
# The real home overlay holds Brewfile.role.tmpl and ssh/config.tmpl, and the doctor reported
# BOTH as MISSING on a fully-provisioned overlay, exiting 1. An audit that cries wolf on a
# correct setup is worse than none: it trains you to ignore it.
mk "$tmp/ovt"
mv "$tmp/ovt/dot_dotlocal/Brewfile.role" "$tmp/ovt/dot_dotlocal/Brewfile.role.tmpl"
mv "$tmp/ovt/dot_dotlocal/ssh/config"    "$tmp/ovt/dot_dotlocal/ssh/config.tmpl"
out=$(OVERLAY_SRC="$tmp/ovt" sh "$script" 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL(E): .tmpl-authored overlay reported non-compliant (exit $rc)"; echo "$out"; exit 1; }
echo "$out" | grep -q 'MISSING' && { echo "FAIL(E): .tmpl pieces flagged MISSING"; echo "$out"; exit 1; }
echo "ok:   required pieces authored as .tmpl are recognised"

# Case F — the SAME TARGET FILE owned by both layers must be flagged.
# The header promises "their managed sets must stay disjoint", but only directory ATTRIBUTES
# were ever compared -- a co-owned FILE sailed through as last-apply-wins with no diagnostic,
# which is precisely the silent-loss class this section exists to prevent.
mk "$tmp/ovf"
bs="$tmp/basef"; mkdir -p "$bs/dot_config/demo" "$tmp/ovf/dot_config/demo"
echo 'base version'    > "$bs/dot_config/demo/thing.conf"
echo 'overlay version' > "$tmp/ovf/dot_config/demo/thing.conf"
out=$(OVERLAY_SRC="$tmp/ovf" BASE_SRC="$bs" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL(F): co-owned file not flagged (exit ${rc:-0})"; echo "$out"; exit 1; }
echo "$out" | grep -q "co-owned" || { echo "FAIL(F): no co-owned file message"; echo "$out"; exit 1; }
echo "ok:   the same target file owned by both layers is flagged"

# Case G — chezmoi METADATA present in both trees is not a collision (it is never a target).
mk "$tmp/ovg"; bs2="$tmp/baseg"; mkdir -p "$bs2"
printf 'README.md\n' > "$bs2/.chezmoiignore"; printf 'README.md\n' > "$tmp/ovg/.chezmoiignore"
out=$(OVERLAY_SRC="$tmp/ovg" BASE_SRC="$bs2" sh "$script" 2>&1) && rc=0 || rc=$?
echo "$out" | grep -q 'co-owned file' && { echo "FAIL(G): metadata false-positived"; echo "$out"; exit 1; }
echo "ok:   chezmoi metadata in both trees is not a collision"

# Case H — a file both trees carry but BOTH .chezmoiignore (agent context, repo docs) is not a
# collision: it is never deployed, so there is nothing to win last. This false-positived on the
# real trees (CLAUDE.md) the moment case F's check went in.
mk "$tmp/ovh"; bs3="$tmp/baseh"; mkdir -p "$bs3"
printf 'CLAUDE.md\n' > "$bs3/.chezmoiignore"; printf 'CLAUDE.md\n' > "$tmp/ovh/.chezmoiignore"
echo 'ctx' > "$bs3/CLAUDE.md"; echo 'ctx' > "$tmp/ovh/CLAUDE.md"
out=$(OVERLAY_SRC="$tmp/ovh" BASE_SRC="$bs3" sh "$script" 2>&1) && rc=0 || rc=$?
echo "$out" | grep -q 'co-owned file' && { echo "FAIL(H): ignored file reported as a collision"; echo "$out"; exit 1; }
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(H): unexpected non-zero exit ${rc:-0}"; echo "$out"; exit 1; }
echo "ok:   a file both trees ignore is not a collision"

# Case I — the destructive summary must not present template control lines as removal targets,
# and must say whether a guarded entry applies HERE. It printed '{{ if ... }}' / '{{ end }}' as
# if they were paths, in the one summary whose job is to warn before a deletion.
mk "$tmp/ovi"
printf '.dotlocal/always\n{{ if not .someFlag }}\n.dotlocal/guarded\n{{ end }}\n' > "$tmp/ovi/.chezmoiremove"
out=$(OVERLAY_SRC="$tmp/ovi" sh "$script" 2>&1) || true
echo "$out" | grep -q 'removes.*{{' && { echo "FAIL(I): template control line shown as a target"; echo "$out"; exit 1; }
echo "$out" | grep -q 'removes.*\.dotlocal/always.*ALWAYS' || { echo "FAIL(I): unguarded entry not marked ALWAYS"; echo "$out"; exit 1; }
echo "$out" | grep -q 'removes.*\.dotlocal/guarded.*ONLY IF' || { echo "FAIL(I): guarded entry not marked conditional"; echo "$out"; exit 1; }
echo "ok:   destructive summary distinguishes always-removed from conditional"

# --- Tier S: the skills layer (ADR-promised check that was never built) ---

mkskills() { # $1=base $2=overlay : a base skill pointing at an overlay fragment
  mkdir -p "$1/dot_claude/skills/demo" "$2/dot_dotlocal/skills"
  printf -- '---\nname: demo\n---\nGeneric half.\nIf `~/.dotlocal/skills/demo.md` exists, read it.\n' \
    > "$1/dot_claude/skills/demo/SKILL.md"
}

# Case J — a base skill whose fragment the overlay supplies: reported OK, non-gating.
mk "$tmp/ovj"; bj="$tmp/basej"; mkskills "$bj" "$tmp/ovj"
echo 'domain half' > "$tmp/ovj/dot_dotlocal/skills/demo.md"
out=$(OVERLAY_SRC="$tmp/ovj" BASE_SRC="$bj" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(J): satisfied fragment should not gate (exit ${rc:-0})"; echo "$out"; exit 1; }
echo "$out" | grep -q 'Tier S.*demo' || { echo "FAIL(J): skills tier not reported"; echo "$out"; exit 1; }
echo "ok:   Tier S reports a satisfied hybrid fragment"

# Case K — the fragment is MISSING: warned, but not a hard failure (per the ADR: an optional
# capability's missing fragment is not fatal; the public half still stands alone).
mk "$tmp/ovk"; bk="$tmp/basek"; mkskills "$bk" "$tmp/ovk"
out=$(OVERLAY_SRC="$tmp/ovk" BASE_SRC="$bk" sh "$script" 2>&1) && rc=0 || rc=$?
echo "$out" | grep -q 'WARN.*demo.md' || { echo "FAIL(K): missing fragment not warned"; echo "$out"; exit 1; }
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(K): missing fragment must warn, not gate (exit ${rc:-0})"; echo "$out"; exit 1; }
echo "ok:   a missing hybrid fragment warns without gating"

# Case L — a PUBLIC base skill carrying this domain's private vocabulary is a hard failure.
# The vocabulary is read from the overlay at runtime, so the public base never embeds it.
mk "$tmp/ovl"; bl="$tmp/basel"; mkskills "$bl" "$tmp/ovl"
echo 'domain half' > "$tmp/ovl/dot_dotlocal/skills/demo.md"
printf '# vocab\nSEKRITHOST\n' > "$tmp/ovl/dot_dotlocal/git-leak-markers"
printf 'ssh SEKRITHOST for the thing\n' >> "$bl/dot_claude/skills/demo/SKILL.md"
out=$(OVERLAY_SRC="$tmp/ovl" BASE_SRC="$bl" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL(L): private vocab in a public skill must gate (exit ${rc:-0})"; echo "$out"; exit 1; }
echo "ok:   private vocabulary in a public base skill is a hard failure"
echo "PASS"
