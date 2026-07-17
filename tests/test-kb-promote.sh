#!/bin/sh
# Test: `kb promote <src> --type T --domain D [--tier N] [--sensitivity S] [--slug NAME]
#        [--date YYYY-MM-DD]` — the migration workhorse. Reads an existing memory file and
# scaffolds a valid KB record in the type's zone:
#   - name from --slug > src `name:` > filename; description + body carried over verbatim
#     (body minus its frontmatter block; wikilinks kept for later edge conversion);
#   - domain/tier/sensitivity from flags/defaults; status: active; updated from KB_DATE/--date.
# Rejects missing src / bad type / bad (unconfigured) domain / an existing slug.
# Run directly: `sh tests/test-kb-promote.sh`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }

d=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d"' EXIT
xdg="$d/xdg"; mkdir -p "$xdg/kb"
cat > "$xdg/kb/config.toml" <<EOF
[domain.devel]
repo = "$d/develrepo"
EOF
# run kb with the isolated config + a fixed KB_DATE (env prefixes are literal here, so they
# are honored as assignments and exported to the binary).
run() { XDG_CONFIG_HOME="$xdg" KB_ROOT="$d" KB_DATE=2026-07-15 sh "$KB" "$@"; }

# a source memory file (real memory shape: frontmatter + prose body with a [[wikilink]])
src="$d/src-verify.md"
{ printf '%s\n' '---' 'name: verify-before-asserting' \
    'description: "Cheap-falsify claims before flagging."' \
    'metadata:' '  node_type: memory' '  type: feedback' '---' \
    'Body line one, references [[some-related-record]].' 'Body line two.'; } > "$src"

# --- 1) basic promote: creates a valid record in the type's zone --------------
run promote "$src" --type standard --domain devel >/dev/null
f="$d/standards/verify-before-asserting.md"
[ -f "$f" ] || { echo "FAIL: promote did not create $f"; exit 1; }
grep -qx 'name: verify-before-asserting' "$f" || { echo "FAIL: name not derived from src name:"; exit 1; }
grep -q  '^type: standard$'              "$f" || { echo "FAIL: type not set"; exit 1; }
grep -qx 'domain: devel'                 "$f" || { echo "FAIL: domain not set from flag"; exit 1; }
grep -qx 'status: active'                "$f" || { echo "FAIL: status not active"; exit 1; }
grep -qx 'updated: 2026-07-15'           "$f" || { echo "FAIL: updated not stamped from KB_DATE"; exit 1; }
grep -q  'Cheap-falsify claims'          "$f" || { echo "FAIL: description not carried over"; exit 1; }
grep -q  'Body line one'                 "$f" || { echo "FAIL: body not carried over"; exit 1; }
grep -q  'Body line two'                 "$f" || { echo "FAIL: full body not carried over"; exit 1; }
grep -q  '\[\[some-related-record\]\]' "$f" || { echo "FAIL: body wikilink not preserved verbatim"; exit 1; }
grep -q  'node_type: memory'             "$f" && { echo "FAIL: src frontmatter leaked into promoted body"; exit 1; }
echo "ok:   promote scaffolds a valid record, body+description carried, src frontmatter stripped"

# defaults: tier 2, sensitivity internal
grep -qx 'tier: 2'              "$f" || { echo "FAIL: default tier should be 2"; exit 1; }
grep -qx 'sensitivity: internal' "$f" || { echo "FAIL: default sensitivity should be internal"; exit 1; }
echo "ok:   defaults tier:2 sensitivity:internal"

# --- 2) flags honored: --tier --sensitivity --slug --date --------------------
run promote "$src" --type context --domain devel \
    --tier 1 --sensitivity private --slug custom-slug --date 2026-01-02 >/dev/null
g="$d/context/custom-slug.md"
[ -f "$g" ] || { echo "FAIL: --slug override not honored (expected $g)"; exit 1; }
grep -qx 'tier: 1'            "$g" || { echo "FAIL: --tier not honored"; exit 1; }
grep -qx 'sensitivity: private' "$g" || { echo "FAIL: --sensitivity not honored"; exit 1; }
grep -qx 'updated: 2026-01-02' "$g" || { echo "FAIL: --date not honored"; exit 1; }
echo "ok:   --tier/--sensitivity/--slug/--date honored"

# --- 3) name fallback to filename when src has no name: ----------------------
nf="$d/no-name-field.md"
{ printf '%s\n' '---' 'description: x' 'type: context' '---' 'body'; } > "$nf"
run promote "$nf" --type context --domain devel >/dev/null
[ -f "$d/context/no-name-field.md" ] || { echo "FAIL: name should fall back to filename"; exit 1; }
echo "ok:   name falls back to filename"

# --- 4) rejections -----------------------------------------------------------
run promote "$d/does-not-exist.md" --type context --domain devel >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: missing src should fail"; exit 1; }
echo "ok:   missing src rejected"

run promote "$src" --type bogus --domain devel >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 2 ] || { echo "FAIL: bad type should exit 2, got ${rc:-0}"; exit 1; }
echo "ok:   bad type rejected"

run promote "$src" --type context --domain notconfigured >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 2 ] || { echo "FAIL: unconfigured domain should exit 2, got ${rc:-0}"; exit 1; }
echo "ok:   bad/unconfigured domain rejected"

# existing slug -> refuse (no clobber)
run promote "$src" --type standard --domain devel >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: existing slug should be refused"; exit 1; }
echo "ok:   existing slug refused"

# --- 5) a promoted clean-body record lints clean -----------------------------
clean="$d/clean.md"
{ printf '%s\n' '---' 'name: clean-fact' 'description: y' 'type: context' '---' 'Self-contained body, no links.'; } > "$clean"
run promote "$clean" --type context --domain devel >/dev/null
run lint "$d/context/clean-fact.md" >/dev/null 2>&1 \
  || { echo "FAIL: a promoted clean record should lint clean"; exit 1; }
echo "ok:   promoted clean record lints clean"

echo "PASS"
