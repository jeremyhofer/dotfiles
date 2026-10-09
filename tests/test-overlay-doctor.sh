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
# The manifest check reads a DEPLOYED record; point every case at a clean one so the suite never
# depends on this machine's own manifest.
printf 'projects:\n  alpha:\n    scope: internal/alpha\n    leakPolicy: private\n' > "$tmp/mani-clean.yaml"
FLEET_RECORD="$tmp/mani-clean.yaml"; export FLEET_RECORD

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
  cp "$here/../overlay-skeleton/dot_gitignore_global.example" "$ov/dot_gitignore_global"
  # A layer that ships a manifest must carry the trigger that regenerates worktrunk's config from it.
  printf '#!/bin/sh\n# {{ include "Devel/mani.yaml.tmpl" | sha256sum }}\nwt-config-gen\n' \
    > "$ov/run_onchange_after_generate-worktrunk-config.sh.tmpl"
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

# --- Tier T: a layer that ships an input to a base mechanism carries the trigger that re-runs it --
# The base re-runs its generators only when ITS inputs change; an input the layer ships reaches the
# deployed file and never the generated one unless the layer's own run_onchange_ script hashes it.
tcase() { # tcase <label> <expect-rc> <grep-pattern-or-empty>
  out=$(OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) && rc=0 || rc=$?
  [ "${rc:-0}" -eq "$2" ] || { echo "FAIL($1): expected exit $2, got ${rc:-0}"; echo "$out"; exit 1; }
  [ -z "$3" ] || echo "$out" | grep -q "$3" || { echo "FAIL($1): '$3' not reported"; echo "$out"; exit 1; }
  echo "ok:   $1"
}
mk "$tmp/ov"; rm "$tmp/ov/run_onchange_after_generate-worktrunk-config.sh.tmpl"
tcase "T1 manifest without the worktrunk trigger is missing" 1 'MISSING .*generate-worktrunk-config'
mk "$tmp/ov"; printf '#!/bin/sh\nwt-config-gen\n' > "$tmp/ov/run_onchange_after_generate-worktrunk-config.sh.tmpl"
tcase "T2 a trigger that does not hash the manifest is missing" 1 'MISSING .*does not hash Devel/mani.yaml'
mk "$tmp/ov"; echo '[projects."x"]' > "$tmp/ov/dot_dotlocal/worktrunk.toml"
tcase "T3 a worktrunk fragment the trigger does not hash is missing" 1 'MISSING .*does not hash dot_dotlocal/worktrunk.toml'
mk "$tmp/ov"; mkdir -p "$tmp/ov/dot_dotlocal/claude"; printf '#!/bin/sh\necho {}\n' > "$tmp/ov/dot_dotlocal/claude/executable_settings-declared"
tcase "T4 a settings fragment without the merge trigger is missing" 1 'MISSING .*merge-claude-settings'
printf '#!/bin/sh\n# {{ include "dot_dotlocal/claude/executable_settings-declared" | sha256sum }}\n' > "$tmp/ov/run_onchange_after_merge-claude-settings.sh.tmpl"
tcase "T5 a fragment declaring no plugins needs no plugin installer (opt-in)" 0 ''
printf '#!/bin/sh\necho "{\"enabledPlugins\": {}}"\n' > "$tmp/ov/dot_dotlocal/claude/executable_settings-declared"
tcase "T6 a fragment declaring plugins without the installer trigger is missing" 1 'MISSING .*install-claude-plugins'
cp "$tmp/ov/run_onchange_after_merge-claude-settings.sh.tmpl" "$tmp/ov/run_onchange_after_install-claude-plugins.sh.tmpl"
tcase "T7 ...and with it passes" 0 ''
mk "$tmp/ov"; echo 'skill_externals: []' > "$tmp/ov/dot_dotlocal/skill-externals.yaml"
tcase "T8 a skill-externals list without its trigger is missing" 1 'MISSING .*sync-skill-externals'
mk "$tmp/ov"; mkdir -p "$tmp/ov/tests"; echo '#!/bin/sh' > "$tmp/ov/tests/run-all.sh"
tcase "T9 a test suite without a gate is advised, not failed (opt-in: no custom hooks on some machines)" 0 'NOTE .*install-test-gate'

# --- Tier P: every overlay file carries a reason to be private, or is reported as a candidate to move
# to the base. ADVISORY: it never changes the exit code, so an overlay written before the list existed
# keeps passing while its report doubles as the list of what to move.
mk "$tmp/ov"
out=$(OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(P1): no reason list must not fail the doctor, got ${rc:-0}"; echo "$out"; exit 1; }
echo "$out" | grep -q 'Tier P.*no PRIVATE-REASONS' || { echo "FAIL(P1): missing list not reported"; echo "$out"; exit 1; }
echo "ok:   no reason list is reported, not failed"

mk "$tmp/ov"
printf '# target-glob<TAB>reason<TAB>why\n.dotlocal/gitconfig\tidentity\tname and signing key\n.dotlocal/ssh/*\tinfra\thome hosts\n' > "$tmp/ov/PRIVATE-REASONS"
printf 'PRIVATE-REASONS\n' > "$tmp/ov/.chezmoiignore"
out=$(OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(P2): unreasoned files must not fail the doctor, got ${rc:-0}"; echo "$out"; exit 1; }
echo "$out" | grep -q 'UNREASONED  .dotlocal/Brewfile.role' || { echo "FAIL(P2): unlisted file not reported"; echo "$out"; exit 1; }
echo "$out" | grep -q 'UNREASONED  .dotlocal/gitconfig' && { echo "FAIL(P2): listed file reported"; echo "$out"; exit 1; }
echo "$out" | grep -q 'UNREASONED  .dotlocal/ssh/config' && { echo "FAIL(P2): glob-listed file reported"; echo "$out"; exit 1; }
echo "$out" | grep -q 'UNREASONED  PRIVATE-REASONS' && { echo "FAIL(P2): the ignored list itself counted"; echo "$out"; exit 1; }
echo "ok:   unlisted files reported; listed, glob-listed and ignored ones are not"

printf '.dotlocal/Brewfile.role\tpreference\tnot a reason\n' >> "$tmp/ov/PRIVATE-REASONS"
out=$(OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) && rc=0 || rc=$?
echo "$out" | grep -q "BADREASON   .dotlocal/Brewfile.role.*preference" || { echo "FAIL(P3): unknown reason not reported"; echo "$out"; exit 1; }
echo "$out" | grep -q 'UNREASONED  .dotlocal/Brewfile.role' && { echo "FAIL(P3): bad-reason file also counted as unlisted"; echo "$out"; exit 1; }
echo "ok:   a reason outside the five is reported"

# Tier P and the collision check read TARGET paths: a source's `.tmpl` suffix is not part of the target,
# and a `.`-prefixed source entry (the repository's .gitignore) is never deployed.
mk "$tmp/ov"
printf '.dotlocal/zshenv\tsecrets\tx\n' > "$tmp/ov/PRIVATE-REASONS"
printf 'PRIVATE-REASONS\n' > "$tmp/ov/.chezmoiignore"
printf 'node_modules\n' > "$tmp/ov/.gitignore"
out=$(OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) || true
echo "$out" | grep -q 'UNREASONED  .dotlocal/zshenv' && { echo "FAIL(P4): a .tmpl source not matched by its target"; echo "$out"; exit 1; }
echo "$out" | grep -q 'UNREASONED  \.gitignore$' && { echo "FAIL(P4): a dot-prefixed source entry counted"; echo "$out"; exit 1; }
echo "ok:   a .tmpl source is matched by its target; dot-prefixed source entries are not deployed"
mk "$tmp/ovt"; bst="$tmp/baset"; mkdir -p "$bst/dot_config/demo" "$tmp/ovt/dot_config/demo"
echo 'base' > "$bst/dot_config/demo/thing.conf"
echo 'overlay' > "$tmp/ovt/dot_config/demo/thing.conf.tmpl"
out=$(OVERLAY_SRC="$tmp/ovt" BASE_SRC="$bst" sh "$script" 2>&1) && rc=0 || rc=$?
echo "$out" | grep -q "co-owned file '.config/demo/thing.conf'" || { echo "FAIL(P5): a plain file and a template of the same target not flagged"; echo "$out"; exit 1; }
echo "ok:   a plain file in one layer and a template of the same target in the other are a collision"

# --- Machine assessment (advisory): versions, tools and capabilities, never values or private paths.
fakebin="$tmp/fakebin"; mkdir -p "$fakebin"
printf '#!/bin/sh\n[ "$1" = "--version" ] && { echo "git version 2.50.1"; exit 0; }\nexec %s "$@"\n' "$(command -v git)" > "$fakebin/git"; chmod +x "$fakebin/git"
out=$(OVERLAY_SRC="$tmp/nope" sh "$script" --machine 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(M1): --machine must run without an overlay and exit 0, got ${rc:-0}"; echo "$out"; exit 1; }
echo "$out" | grep -q 'machine assessment' || { echo "FAIL(M1): no assessment section"; echo "$out"; exit 1; }
echo "ok:   --machine runs with no overlay"
out=$(PATH="$fakebin:$PATH" OVERLAY_SRC="$tmp/nope" sh "$script" --machine 2>&1) || true
echo "$out" | grep -q 'git .*2\.50\.1.*older than 2\.54' || { echo "FAIL(M2): an old git not flagged"; echo "$out"; exit 1; }
echo "ok:   a git older than 2.54 is flagged (configured hooks skipped)"
out=$(OVERLAY_SRC="$tmp/nope" sh "$script" --machine 2>&1) || true
echo "$out" | grep -q 'configured hooks fire *yes' || { echo "FAIL(M3): configured hooks not seen firing on this git"; echo "$out"; exit 1; }
echo "ok:   configured hooks are seen firing"
out=$(ASSESS_TOOLS="git no-such-tool-ccx" OVERLAY_SRC="$tmp/nope" sh "$script" --machine 2>&1) || true
echo "$out" | grep -q 'missing *no-such-tool-ccx' || { echo "FAIL(M4): a missing tool not reported"; echo "$out"; exit 1; }
echo "ok:   a missing tool is reported"
printf '{"permissions":{"deny":["SECRETVALUE-ccx"]},"hooks":{},"env":{"X":"SECRETVALUE-ccx"}}\n' > "$tmp/managed.json"
out=$(ASSESS_MANAGED_SETTINGS="$tmp/managed.json" OVERLAY_SRC="$tmp/nope" sh "$script" --machine 2>&1) || true
echo "$out" | grep -q 'managed settings keys *env hooks permissions' || { echo "FAIL(M5): managed key names not listed"; echo "$out"; exit 1; }
echo "$out" | grep -q 'SECRETVALUE' && { echo "FAIL(M5): a managed value leaked into the report"; echo "$out"; exit 1; }
echo "ok:   managed settings key names listed, values never"
out=$(OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) || true
mk "$tmp/ov"; out=$(OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) || true
echo "$out" | grep -q 'machine assessment' || { echo "FAIL(M6): the full run does not include the assessment"; echo "$out"; exit 1; }
echo "$out" | grep -q "$HOME" && { echo "FAIL(M6): the home directory appears in the report"; echo "$out"; exit 1; }
echo "ok:   the full run includes the assessment, with no home-directory paths"

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

# Case G2 — a chezmoi SCRIPT of the same name in both trees is not a collision: a run_ script is
# executed by its own instance and deployed nowhere. This false collision failed the real, correct
# overlay (both trees carry run_onchange_after_generate-worktrunk-config.sh.tmpl).
mk "$tmp/ovs"; bs4="$tmp/bases"; mkdir -p "$bs4"
echo '#!/bin/sh' > "$bs4/run_onchange_after_generate-x.sh.tmpl"
echo '#!/bin/sh' > "$tmp/ovs/run_onchange_after_generate-x.sh.tmpl"
out=$(OVERLAY_SRC="$tmp/ovs" BASE_SRC="$bs4" sh "$script" 2>&1) && rc=0 || rc=$?
echo "$out" | grep -q 'co-owned file' && { echo "FAIL(G2): same-named run_ scripts false-positived"; echo "$out"; exit 1; }
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(G2): same-named run_ scripts should not fail the doctor, got ${rc:-0}"; echo "$out"; exit 1; }
echo "ok:   same-named run_ scripts in both trees are not a collision"

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

# ---- the manifest's schema, through fleet-decl --check on the deployed record ----
mk "$tmp/ovm"
printf 'projects:\n  alpha:\n    scope: internal/alpha\n' > "$tmp/mani-bad.yaml"
out=$(FLEET_RECORD="$tmp/mani-bad.yaml" OVERLAY_SRC="$tmp/ovm" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL(M1): a manifest finding must gate (exit ${rc:-0})"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'policy-missing' || { echo "FAIL(M1): the finding is not named"; echo "$out"; exit 1; }
echo "ok:   a manifest schema finding gates, and is named"
out=$(FLEET_RECORD="$tmp/no-such.yaml" OVERLAY_SRC="$tmp/ovm" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(M2): an undeployed manifest must not gate (exit ${rc:-0})"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'manifest' || { echo "FAIL(M2): an undeployed manifest must be reported"; echo "$out"; exit 1; }
echo "ok:   an undeployed manifest is reported, not gated"

# ---- the global gitignore carries every base default (the skeleton's example is the list) ----
mk "$tmp/ovg2"; grep -vx '.envrc' "$tmp/ovg2/dot_gitignore_global" > "$tmp/gi" && mv "$tmp/gi" "$tmp/ovg2/dot_gitignore_global"
out=$(OVERLAY_SRC="$tmp/ovg2" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL(G1): a missing default ignore must gate (exit ${rc:-0})"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q '\.envrc' || { echo "FAIL(G1): the missing line is not named"; echo "$out"; exit 1; }
echo "ok:   a global gitignore missing a base default gates, naming the line"
# The report must be actionable: it prints the exact lines to append, and appending exactly those
# brings the overlay to the default set. (The drift went unnoticed when it only named each line.)
mk "$tmp/ovg4"; grep -vxE '\.envrc|\.worktrees/' "$tmp/ovg4/dot_gitignore_global" > "$tmp/gi" && mv "$tmp/gi" "$tmp/ovg4/dot_gitignore_global"
out=$(OVERLAY_SRC="$tmp/ovg4" sh "$script" 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out" | grep -q 'fix: append these lines to dot_gitignore_global' || { echo "FAIL(G4): no fix is given for missing defaults"; echo "$out"; exit 1; }
printf '%s\n' "$out" | awk '/fix: append these lines/ {f=1; next} f && /^    [^ ]/ {sub(/^    /, ""); print; next} f {exit}' > "$tmp/append.txt"
[ "$(wc -l < "$tmp/append.txt" | tr -d ' ')" -eq 2 ] || { echo "FAIL(G4): expected exactly the 2 missing lines to be printed"; cat "$tmp/append.txt"; exit 1; }
cat "$tmp/append.txt" >> "$tmp/ovg4/dot_gitignore_global"
out=$(OVERLAY_SRC="$tmp/ovg4" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(G4): appending the printed lines did not satisfy the check (exit ${rc:-0})"; echo "$out"; exit 1; }
echo "ok:   the missing defaults are printed as lines to append, and appending them satisfies the check"
mk "$tmp/ovg3"; rm "$tmp/ovg3/dot_gitignore_global"
out=$(OVERLAY_SRC="$tmp/ovg3" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL(G2): no global gitignore must gate (exit ${rc:-0})"; echo "$out"; exit 1; }
echo "ok:   an overlay with no global gitignore gates"
# ---- Tier H: the leak-guard is the base's; a domain enables it by supplying its pattern files ----
mk "$tmp/ovh1"
out=$(OVERLAY_SRC="$tmp/ovh1" sh "$script" 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out" | grep -q 'Tier H: leak-guard not configured' || { echo "FAIL(H1): an overlay with no pattern files is not reported as unconfigured"; echo "$out"; exit 1; }
echo "ok:   Tier H: no pattern files reads as not configured"
mk "$tmp/ovh2"; printf '\\bZZP-[0-9]+\n' > "$tmp/ovh2/dot_dotlocal/git-leak-markers"
printf 'private-url=^/srv/private/\nprobe-marker=ZZP-999\n' > "$tmp/ovh2/dot_dotlocal/git-leak-policy"
out=$(OVERLAY_SRC="$tmp/ovh2" sh "$script" 2>&1) && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(H2): a configured guard must not gate (exit ${rc:-0})"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'OK .*Tier H: leak-guard configured' || { echo "FAIL(H2): a configured guard is not reported"; echo "$out"; exit 1; }
echo "ok:   Tier H: pattern files read as configured"
mk "$tmp/ovh3"; printf '\\bZZP-[0-9]+\n' > "$tmp/ovh3/dot_dotlocal/git-leak-markers"
printf 'private-url=^/srv/private/\n' > "$tmp/ovh3/dot_dotlocal/git-leak-policy"
out=$(OVERLAY_SRC="$tmp/ovh3" sh "$script" 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out" | grep -q 'advisory .*Tier H.*probe-marker' || { echo "FAIL(H3): a configured guard without a probe marker is not flagged"; echo "$out"; exit 1; }
echo "ok:   Tier H: a configured guard without probe-marker= is flagged"
# ---- Tier H: a pattern file that exists but holds no pattern refuses every commit once deployed ----
mk "$tmp/ovh4"; printf '# a scaffold comment\n\n   \n# another\n' > "$tmp/ovh4/dot_dotlocal/git-leak-markers"
printf 'private-url=^/srv/private/\nprobe-marker=ZZP-999\n' > "$tmp/ovh4/dot_dotlocal/git-leak-policy"
out=$(OVERLAY_SRC="$tmp/ovh4" sh "$script" 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out" | grep -q 'WARN .*Tier H.*git-leak-markers.*no patterns' || { echo "FAIL(H4): a comment-only markers file is not flagged"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'delete it' || { echo "FAIL(H4): the flag does not give the fix"; echo "$out"; exit 1; }
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(H4): the flag is advisory and must not gate (exit ${rc:-0})"; echo "$out"; exit 1; }
echo "ok:   Tier H: a comment-only pattern file is flagged with its fix"
# a zero-byte sensitive file is the same trap; a populated markers file beside it is not flagged
mk "$tmp/ovh5"; printf '\\bZZP-[0-9]+\n' > "$tmp/ovh5/dot_dotlocal/git-leak-markers"; : > "$tmp/ovh5/dot_dotlocal/git-leak-sensitive"
printf 'private-url=^/srv/private/\nprobe-marker=ZZP-999\n' > "$tmp/ovh5/dot_dotlocal/git-leak-policy"
out=$(OVERLAY_SRC="$tmp/ovh5" sh "$script" 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out" | grep -q 'WARN .*Tier H.*git-leak-sensitive.*no patterns' || { echo "FAIL(H5): an empty sensitive file is not flagged"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'WARN .*Tier H.*git-leak-markers.*no patterns' && { echo "FAIL(H5): a populated markers file was flagged"; echo "$out"; exit 1; }
echo "ok:   Tier H: only the patternless file is flagged"
# ---- Tier H: the overlay's own repository should be declared in the fleet record ----
# Undeclared means strict-by-default: legitimate internal content is let through only while the
# patterns stay narrow. The doctor says so at CONSIDER level and leaves the choice to the machine.
mk "$tmp/ovd1"; printf '\\bZZP-[0-9]+\n' > "$tmp/ovd1/dot_dotlocal/git-leak-markers"
printf 'private-url=^/srv/private/\nprobe-marker=ZZP-999\n' > "$tmp/ovd1/dot_dotlocal/git-leak-policy"
out=$(OVERLAY_SRC="$tmp/ovd1" FLEET_DEVEL_ROOT="$tmp" sh "$script" 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out" | grep -q 'CONSIDER .*overlay repository is not declared in the fleet record' || { echo "FAIL(D1): an undeclared overlay is not flagged"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'leakPolicy: internal' || { echo "FAIL(D1): the note does not say how to declare it"; echo "$out"; exit 1; }
[ "${rc:-0}" -eq 0 ] || { echo "FAIL(D1): the note must not gate (exit ${rc:-0})"; echo "$out"; exit 1; }
echo "ok:   Tier H: an undeclared overlay repository is a CONSIDER note, not a failure"
printf 'projects:\n  alpha:\n    scope: internal/alpha\n    leakPolicy: private\n  ovl:\n    scope: ovd1\n    leakPolicy: internal\n' > "$tmp/mani-decl.yaml"
out=$(FLEET_RECORD="$tmp/mani-decl.yaml" OVERLAY_SRC="$tmp/ovd1" FLEET_DEVEL_ROOT="$tmp" sh "$script" 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out" | grep -q 'CONSIDER .*overlay repository' && { echo "FAIL(D2): a declared overlay is still flagged"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'OK .*overlay repository is declared in the fleet record' || { echo "FAIL(D2): a declared overlay is not confirmed"; echo "$out"; exit 1; }
echo "ok:   Tier H: a declared overlay repository is not flagged"
printf 'projects:\n  ovl:\n    scope: ovd1\n' > "$tmp/mani-nopolicy.yaml"
out=$(FLEET_RECORD="$tmp/mani-nopolicy.yaml" OVERLAY_SRC="$tmp/ovd1" FLEET_DEVEL_ROOT="$tmp" sh "$script" 2>&1) || true
printf '%s\n' "$out" | grep -q 'CONSIDER .*declares no leakPolicy' || { echo "FAIL(D3): an entry without leakPolicy is not flagged"; echo "$out"; exit 1; }
echo "ok:   Tier H: an overlay entry with no leakPolicy is flagged"
printf 'not: a record\n' > "$tmp/mani-bad.yaml"
out=$(FLEET_RECORD="$tmp/mani-bad.yaml" OVERLAY_SRC="$tmp/ovd1" FLEET_DEVEL_ROOT="$tmp" sh "$script" 2>&1) || true
printf '%s\n' "$out" | grep -q 'WARN .*fleet record is unreadable' || { echo "FAIL(D4): an unreadable record is not reported as such"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'CONSIDER .*not declared' && { echo "FAIL(D4): an unreadable record was reported as undeclared"; echo "$out"; exit 1; }
echo "ok:   Tier H: an unreadable record is reported, not guessed at"
# ---- a configured hook that is switched off reads as configured but disabled, naming the switch ----
# `ai-coauthor` is wired in the base gitconfig and opted out with ai-coauthor.enabled=false. Listing
# it bare read as "the disable did not take".
cat > "$tmp/gc-hooks" <<'EOF2'
[hook "ai-coauthor"]
	command = true
	event = prepare-commit-msg
[hook "other-hook"]
	command = true
	event = pre-commit
EOF2
out=$(GIT_CONFIG_GLOBAL="$tmp/gc-hooks" OVERLAY_SRC="$tmp/nope" sh "$script" --machine 2>&1) || true
printf '%s\n' "$out" | grep -q 'global configured hooks.*ai-coauthor' || { echo "FAIL(K1): fixture hooks not listed"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep 'global configured hooks' | grep -q 'disabled' && { echo "FAIL(K1): an enabled hook is shown as disabled"; echo "$out"; exit 1; }
printf '[ai-coauthor]\n\tenabled = false\n' >> "$tmp/gc-hooks"
out=$(GIT_CONFIG_GLOBAL="$tmp/gc-hooks" OVERLAY_SRC="$tmp/nope" sh "$script" --machine 2>&1) || true
printf '%s\n' "$out" | grep 'global configured hooks' | grep -q 'ai-coauthor (disabled by ai-coauthor.enabled=false)' || { echo "FAIL(K2): a disabled ai-coauthor is not shown as disabled"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep 'global configured hooks' | grep -q 'other-hook' || { echo "FAIL(K2): the other hook vanished from the list"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep 'global configured hooks' | grep 'other-hook (' && { echo "FAIL(K2): an unrelated hook was annotated"; echo "$out"; exit 1; }
printf '[hook "other-hook"]\n\tenabled = false\n' >> "$tmp/gc-hooks"
out=$(GIT_CONFIG_GLOBAL="$tmp/gc-hooks" OVERLAY_SRC="$tmp/nope" sh "$script" --machine 2>&1) || true
printf '%s\n' "$out" | grep 'global configured hooks' | grep -q 'other-hook (disabled by hook.other-hook.enabled=false)' || { echo "FAIL(K3): git's own hook.<name>.enabled=false is not shown"; echo "$out"; exit 1; }
echo "ok:   a configured hook that is switched off is listed as disabled, naming the setting"
# ---- Tier W: workspace trust is advisory and prints names, never a path -------------------------
# A stub claude-trust-check stands in for the real one: it answers by exit status and prints names.
mk "$tmp/ov"; mkdir -p "$tmp/trbin"
stub_trust() { # $1 exit status, $2 stdout
  printf '#!/bin/sh\n[ "${1:-}" = --names-only ] || exit 9\nprintf "%%s" "%s"\nexit %s\n' "$2" "$1" > "$tmp/trbin/claude-trust-check"
  chmod +x "$tmp/trbin/claude-trust-check"
}
stub_trust 0 ""
out=$(PATH="$tmp/trbin:$PATH" OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out" | grep -q 'OK .*Tier W' || { echo "FAIL(W1): all-trusted not reported"; echo "$out"; exit 1; }
stub_trust 1 "alpha
beta"
out=$(PATH="$tmp/trbin:$PATH" OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL(W2): untrusted directories changed the exit status to $rc"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'Tier W: 2 project(s) still need.*alpha beta' || { echo "FAIL(W2): count and names not reported"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'accept the trust prompt' || { echo "FAIL(W2): no fix line"; echo "$out"; exit 1; }
stub_trust 3 ""
out=$(PATH="$tmp/trbin:$PATH" OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out" | grep -q 'Tier W: workspace trust is unknown' || { echo "FAIL(W3): unknown not reported"; echo "$out"; exit 1; }
rm -f "$tmp/trbin/claude-trust-check"
# Absent by construction: on a machine where the base is applied the real tool is on PATH, so drop
# every PATH directory that holds one rather than assuming the machine has none.
notool=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do [ -x "$d/claude-trust-check" ] || printf '%s:' "$d"; done)
notool=${notool%:}
out=$(PATH="$notool" OVERLAY_SRC="$tmp/ov" sh "$script" 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out" | grep -q 'Tier W' && { echo "FAIL(W4): reported without the tool on PATH"; echo "$out"; exit 1; }
echo "ok:   Tier W: trust reported as advisory (all trusted, names needing a click, unknown, absent tool)"
echo "PASS"
