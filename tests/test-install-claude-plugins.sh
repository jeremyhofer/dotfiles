#!/bin/sh
# Tests for install-claude-plugins. A stub `claude` records calls; nothing real installs. The declaration
# is supplied through INSTALL_CLAUDE_PLUGINS_DECLARED, the same path the tool reads a fragment into.
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../private_dot_local/bin/executable_install-claude-plugins"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok:   $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1 -> $2"; }
DECL='{"extraKnownMarketplaces":{"cloudflare":{"source":{"source":"github","repo":"cloudflare/skills"}},"worktrunk":{"source":{"source":"github","repo":"max-sixty/worktrunk"}}},"enabledPlugins":{"cloudflare@cloudflare":true,"worktrunk@worktrunk":true,"old@x":false}}'
setup() {  # $1 known marketplaces json, $2 installed plugins json, $3 stub exit code for install, $4 live settings json (default: the declaration)
  H=$(mktemp -d); mkdir -p "$H/.claude/plugins" "$H/bin"
  printf '%s' "$DECL" > "$H/declared.json"
  printf '%s' "${4:-$DECL}" > "$H/.claude/settings.json"
  printf '%s' "$1" > "$H/.claude/plugins/known_marketplaces.json"
  printf '%s' "$2" > "$H/.claude/plugins/installed_plugins.json"
  printf '#!/bin/sh\necho "$*" >> "%s/calls"\ncase "$2" in install) exit %s;; esac\nexit 0\n' "$H" "$3" > "$H/bin/claude"
  chmod +x "$H/bin/claude"
}
run() { HOME=$H PATH="$H/bin:$PATH" INSTALL_CLAUDE_PLUGINS_DECLARED="$H/declared.json" sh "$script" >/dev/null 2>"$H/err"; echo $?; }

# 1. everything present -> no calls, exit 0
setup '{"cloudflare":{},"worktrunk":{}}' '{"plugins":{"cloudflare@cloudflare":[],"worktrunk@worktrunk":[]}}' 0
rc=$(run); [ "$rc" = 0 ] && [ ! -f "$H/calls" ] && ok "all present: no calls, rc 0" || bad "all present" "rc=$rc calls=$(cat $H/calls 2>/dev/null)"
# 2. worktrunk missing -> marketplace add + install, exit 0
setup '{"cloudflare":{}}' '{"plugins":{"cloudflare@cloudflare":[]}}' 0
rc=$(run); c=$(cat "$H/calls" 2>/dev/null | tr '\n' '|')
[ "$rc" = 0 ] && [ "$c" = "plugin marketplace add max-sixty/worktrunk|plugin install worktrunk@worktrunk|" ] && ok "missing: adds marketplace and installs" || bad "missing" "rc=$rc calls=$c"
# 3. a disabled (false) plugin is never installed
case "$c" in *old@x*) bad "disabled installed" "$c";; *) ok "disabled plugin not installed";; esac
# 4. install fails -> exit non-zero
setup '{"cloudflare":{},"worktrunk":{}}' '{"plugins":{"cloudflare@cloudflare":[]}}' 1
rc=$(run); [ "$rc" != 0 ] && ok "failed install exits non-zero" || bad "failed install" "rc=$rc"
# 5. THE 2026-09-23 SHAPE: a plugin enabled in the LIVE file but not declared (a removal this machine
#    has not applied) is NOT installed, and IS reported.
STALE='{"enabledPlugins":{"cloudflare@cloudflare":true,"worktrunk@worktrunk":true,"sentry@claude-plugins-official":true}}'
setup '{"cloudflare":{},"worktrunk":{}}' '{"plugins":{"cloudflare@cloudflare":[],"worktrunk@worktrunk":[]}}' 0 "$STALE"
rc=$(run); c=$(cat "$H/calls" 2>/dev/null | tr '\n' '|')
case "$c" in *sentry*) bad "undeclared live plugin installed" "$c";; *) ok "undeclared live plugin not installed";; esac
grep -q 'sentry@claude-plugins-official is enabled on this machine but NOT declared' "$H/err" && ok "undeclared live plugin reported" || bad "undeclared not reported" "$(cat $H/err)"
[ "$rc" = 0 ] && ok "a stale live entry does not fail the apply" || bad "stale entry rc" "rc=$rc"
# 6. an unreadable declaration refuses rather than installing from nothing
setup '{}' '{"plugins":{}}' 0; printf 'not json' > "$H/declared.json"
rc=$(run); [ "$rc" != 0 ] && [ ! -f "$H/calls" ] && ok "unreadable declaration: refuses, installs nothing" || bad "unreadable declaration" "rc=$rc calls=$(cat $H/calls 2>/dev/null)"
# 7. the fragment named on the command line is run and its "declared" block installed
setup '{"cloudflare":{},"worktrunk":{}}' '{"plugins":{"cloudflare@cloudflare":[]}}' 0
printf '#!/bin/sh\necho %s\n' "'{\"declared\": $DECL}'" > "$H/fragment"; chmod +x "$H/fragment"
rc=$(HOME=$H PATH="$H/bin:$PATH" sh "$script" "$H/fragment" >/dev/null 2>"$H/err"; echo $?); c=$(cat "$H/calls" 2>/dev/null | tr '\n' '|')
[ "$rc" = 0 ] && [ "$c" = "plugin install worktrunk@worktrunk|" ] && ok "a fragment argument is read and installed from" || bad "fragment argument" "rc=$rc calls=$c err=$(cat $H/err)"
# 8. nothing to read: a usage error, exit 2, nothing installed
setup '{}' '{"plugins":{}}' 0
rc=$(HOME=$H PATH="$H/bin:$PATH" sh "$script" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] && [ ! -f "$H/calls" ] && ok "no fragment and no declaration: usage, exit 2" || bad "no fragment" "rc=$rc"
echo "passed: $pass failed: $fail"; [ "$fail" -eq 0 ]
