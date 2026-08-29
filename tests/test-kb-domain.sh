#!/bin/sh
# Test: the `domain` dimension (domain and tier are orthogonal record dimensions).
#   (a) `kb new` scaffolds `domain: universal` by default.
#   (b) `kb lint` requires `domain` and validates it is `universal` or a configured
#       `[domain.<slug>]` config slug; an unknown domain -> exit 1, reason names it.
#   (c) `kb project` selection is `tier` AND `domain`: bare = tier-0 universal;
#       `--domain <slug>` = that domain's tier-1 slice, output repo resolved from
#       config `[domain.<slug>] repo` (or --out).
# Run directly: `sh tests/test-kb-domain.sh`.
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
set_field() { sedi "s|^$2:.*|$2: $3|" "$1"; }

# --- (a) kb new defaults domain to universal ---------------------------------
d=$(mktemp -d "$_TMP/kb.XXXXXX"); trap 'rm -rf "$d"' EXIT
KB_ROOT="$d" KB_DATE=2026-07-15 kb new context sample >/dev/null
grep -qx 'domain: universal' "$d/context/sample.md" || { echo "FAIL: kb new should default domain: universal"; exit 1; }
echo "ok:   kb new defaults domain: universal"

# --- config with a configured domain (isolated XDG) --------------------------
xdg="$d/xdg"; mkdir -p "$xdg/kb"
repo="$d/develrepo"; mkdir -p "$repo"
cat > "$xdg/kb/config.toml" <<EOF
[instance.personal]
root = "$d"

[domain.devel]
repo = "$repo"
EOF

# --- (b) lint: domain validation ---------------------------------------------
# universal always valid (no config needed already covered); a configured slug is valid.
KB_ROOT="$d" KB_DATE=2026-07-15 kb new context devel-fact >/dev/null
set_field "$d/context/devel-fact.md" domain devel
XDG_CONFIG_HOME="$xdg" KB_ROOT="$d" kb lint >/dev/null 2>&1 \
  || { echo "FAIL: a configured domain slug should lint clean"; exit 1; }
echo "ok:   configured domain slug lints clean"

# an unknown domain -> exit 1, reason names the domain
set_field "$d/context/devel-fact.md" domain bogusdomain
XDG_CONFIG_HOME="$xdg" KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: unknown domain should exit 1, got ${rc:-0}"; exit 1; }
XDG_CONFIG_HOME="$xdg" KB_ROOT="$d" kb lint 2>&1 | grep -q 'bogusdomain' \
  || { echo "FAIL: lint should name the invalid domain"; exit 1; }
set_field "$d/context/devel-fact.md" domain devel   # restore
echo "ok:   unknown domain flagged, named"

# missing domain field -> exit 1 (required)
{ printf '%s\n' '---' 'name: nodomain' 'description: x' 'type: context' \
    'sensitivity: internal' 'tier: 2' 'status: active' 'related: []' \
    'depends-on: []' 'supersedes: []' 'updated: 2026-07-15' '---' 'body'; } > "$d/context/nodomain.md"
XDG_CONFIG_HOME="$xdg" KB_ROOT="$d" kb lint >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -eq 1 ] || { echo "FAIL: missing domain should exit 1, got ${rc:-0}"; exit 1; }
XDG_CONFIG_HOME="$xdg" KB_ROOT="$d" kb lint 2>&1 | grep -q "domain" \
  || { echo "FAIL: lint should report missing domain"; exit 1; }
rm -f "$d/context/nodomain.md"
echo "ok:   missing domain caught"

# --- (c) project selection = tier AND domain ---------------------------------
# universal tier-0 rule; devel tier-1 fact; devel tier-2 detail
KB_ROOT="$d" KB_DATE=2026-07-15 kb new standard uni-rule >/dev/null
set_field "$d/standards/uni-rule.md" tier 0; set_field "$d/standards/uni-rule.md" status active
printf 'Universal always-on rule.\n' >> "$d/standards/uni-rule.md"

set_field "$d/context/devel-fact.md" tier 1; set_field "$d/context/devel-fact.md" status active
printf 'Devel domain fact.\n' >> "$d/context/devel-fact.md"

KB_ROOT="$d" KB_DATE=2026-07-15 kb new context devel-detail >/dev/null
set_field "$d/context/devel-detail.md" domain devel
set_field "$d/context/devel-detail.md" tier 2; set_field "$d/context/devel-detail.md" status active
printf 'Devel long-tail detail.\n' >> "$d/context/devel-detail.md"

# bare project: tier-0 universal only
XDG_CONFIG_HOME="$xdg" KB_ROOT="$d" kb project >/dev/null
a="$d/index/projections/AGENTS.md"
grep -q 'Universal always-on rule.' "$a" || { echo "FAIL: bare project missing tier-0 universal"; exit 1; }
grep -q 'Devel domain fact.'        "$a" && { echo "FAIL: devel tier-1 leaked into bare (universal) projection"; exit 1; }
echo "ok:   bare project = tier-0 universal only"

# --domain devel: tier-1 devel slice, written to the config repo, excludes universal + tier-2
XDG_CONFIG_HOME="$xdg" KB_ROOT="$d" kb project --domain devel >/dev/null
da="$repo/AGENTS.md"
[ -f "$da" ] || { echo "FAIL: --domain devel should write AGENTS.md into the configured repo ($repo)"; exit 1; }
grep -q 'Devel domain fact.'        "$da" || { echo "FAIL: --domain devel missing its tier-1 fact"; exit 1; }
grep -q 'Universal always-on rule.' "$da" && { echo "FAIL: universal record leaked into devel projection"; exit 1; }
grep -q 'Devel long-tail detail.'   "$da" && { echo "FAIL: devel tier-2 leaked into tier-1 projection"; exit 1; }
echo "ok:   --domain devel = tier-1 devel slice into the configured repo"

# --out overrides the config repo
out="$d/staging"; mkdir -p "$out"
XDG_CONFIG_HOME="$xdg" KB_ROOT="$d" kb project --domain devel --out "$out" >/dev/null
grep -q 'Devel domain fact.' "$out/AGENTS.md" || { echo "FAIL: --out should override the config repo"; exit 1; }
echo "ok:   --out overrides the configured domain repo"

echo "PASS"
