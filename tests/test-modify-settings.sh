#!/bin/sh
# Test the modify_ script that manages ~/.claude/settings.json as a PARTIAL file: the base's own
# defaults, then an optional domain fragment's declared block, merged over whatever the live file
# holds. Pins the contract: live-only keys survive, the fragment wins over the base, declared arrays
# replace wholesale, retired hooks named by the fragment are stripped, and every failure (no jq, a
# broken fragment, unparseable input) changes as little as possible rather than writing something
# broken.
set -u
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../dot_claude/modify_settings.json"
TMP=$(mktemp -d "$_TMP/test-modify-settings.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
fail=0
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }

frag="$TMP/settings-declared"
cat > "$frag" <<'EOF'
#!/usr/bin/env bash
cat <<JSON
{
  "declared": {
    "editorMode": "emacs",
    "sandbox": { "enabled": true, "filesystem": { "allowWrite": ["~/granted"] } },
    "hooks": { "Stop": [ { "hooks": [ { "command": "${HOME}/keep.sh", "type": "command" } ] } ] }
  },
  "retiredHooks": ["old-hook.sh"]
}
JSON
EOF
run() { printf '%s' "$1" | CLAUDE_SETTINGS_FRAGMENT="$2" bash "$SCRIPT" 2>"$TMP/err"; }
val() { printf '%s' "$1" | jq -r "$2"; }

# A) no fragment: a fresh machine gets the base defaults only
out=$(run '' "$TMP/absent")
printf '%s' "$out" | jq -e . >/dev/null 2>&1 || { echo "FAIL: empty input must yield valid JSON"; fail=1; }
[ "$(val "$out" '.statusLine.type')" = "command" ] || { echo "FAIL: base must declare the status line"; fail=1; }
[ "$(val "$out" '.editorMode')" = "vim" ] || { echo "FAIL: base default editorMode missing"; fail=1; }
[ "$(val "$out" '.sandbox')" = "null" ] || { echo "FAIL: base must not declare a sandbox policy"; fail=1; }

# B) the fragment's declared block wins over the base; live-only keys survive; model is untouched
live='{"model":"opus","permissions":{"allow":["Bash(ls:*)"]},"sandbox":{"filesystem":{"allowWrite":["~/ad-hoc"],"denyRead":["~/secret"]}}}'
out=$(run "$live" "$frag")
[ "$(val "$out" '.editorMode')" = "emacs" ] || { echo "FAIL: fragment must win over the base default"; fail=1; }
[ "$(val "$out" '.model')" = "opus" ] || { echo "FAIL: live model must survive"; fail=1; }
[ "$(val "$out" '.permissions.allow | length')" = "1" ] || { echo "FAIL: live permissions.allow must survive"; fail=1; }
[ "$(val "$out" '.sandbox.filesystem.denyRead[0]')" = "~/secret" ] || { echo "FAIL: live-only nested key must survive"; fail=1; }
# declared arrays REPLACE: the ad-hoc live grant is gone, the declared one present
[ "$(printf '%s' "$out" | jq -c '.sandbox.filesystem.allowWrite')" = '["~/granted"]' ] \
  || { echo "FAIL: a declared array must replace the live one"; fail=1; }
[ "$(val "$out" '.statusLine.type')" = "command" ] || { echo "FAIL: base keys must still apply under a fragment"; fail=1; }

# C) retired hooks named by the fragment are stripped from every event; an emptied event is dropped
live='{"hooks":{"PreToolUse":[{"hooks":[{"command":"/x/old-hook.sh","type":"command"}]}],"Stop":[{"hooks":[{"command":"/x/old-hook.sh","type":"command"}]}]}}'
out=$(run "$live" "$frag")
[ "$(val "$out" '.hooks.PreToolUse')" = "null" ] || { echo "FAIL: an event left empty by retirement must be dropped"; fail=1; }
printf '%s' "$out" | jq -e '[.hooks[][].hooks[].command] | any(test("old-hook"))' >/dev/null \
  && { echo "FAIL: a retired hook survived"; fail=1; }
printf '%s' "$out" | jq -e '[.hooks.Stop[].hooks[].command] | any(endswith("/keep.sh"))' >/dev/null \
  || { echo "FAIL: the fragment's own hook must be present"; fail=1; }

# D) a fragment that fails or prints non-JSON is skipped with a warning; the base still applies
bad="$TMP/bad"; printf '#!/bin/sh\necho not-json\n' > "$bad"
out=$(run '{"keep":1}' "$bad")
[ "$(val "$out" '.keep')" = "1" ] || { echo "FAIL: a broken fragment must not lose live keys"; fail=1; }
[ "$(val "$out" '.editorMode')" = "vim" ] || { echo "FAIL: a broken fragment must not block the base"; fail=1; }
grep -q 'settings fragment' "$TMP/err" || { echo "FAIL: a broken fragment must be reported on stderr"; fail=1; }

# E) unparseable live input starts from an empty object rather than corrupting it
out=$(run '{not json' "$TMP/absent")
printf '%s' "$out" | jq -e . >/dev/null 2>&1 || { echo "FAIL: unparseable input must still yield valid JSON"; fail=1; }

# F) no jq on PATH: byte-identical passthrough
nojq="$TMP/nojq"; mkdir -p "$nojq"
for t in bash cat printf; do p=$(command -v "$t") && ln -s "$p" "$nojq/$t"; done
in='{"a":1}'
out=$(printf '%s' "$in" | PATH="$nojq" CLAUDE_SETTINGS_FRAGMENT="$frag" "$nojq/bash" "$SCRIPT")
[ "$out" = "$in" ] || { echo "FAIL: without jq the input must pass through byte-identical (got: $out)"; fail=1; }

[ "$fail" -eq 0 ] && echo PASS
exit "$fail"
