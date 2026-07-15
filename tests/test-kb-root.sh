#!/bin/sh
# Test: KB-root resolution precedence (via the `kb debug-root` seam):
#   --kb-root flag  >  KB_ROOT env  >  ~/.config/kb/config.toml  >  discovery (cwd upward).
# Discovery matches a `kb.toml` file OR a `.kb/` dir marker; the resolved root is the
# directory holding the marker. Run directly: `sh tests/test-kb-root.sh`.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KB="$here/../private_dot_local/bin/executable_kb"
[ -f "$KB" ] || { echo "FAIL: base does not ship kb"; exit 1; }

d=$(mktemp -d "${TMPDIR:-/tmp}/kb.XXXXXX"); trap 'rm -rf "$d"' EXIT
# Empty XDG config so the config layer is skipped unless a case sets it explicitly.
emptyxdg="$d/empty-xdg"; mkdir -p "$emptyxdg"
kb() { XDG_CONFIG_HOME="$emptyxdg" sh "$KB" "$@"; }

# 1) discovery via kb.toml marker (resolved root = dir holding it)
mkdir -p "$d/mkb"; : > "$d/mkb/kb.toml"
( cd "$d/mkb" && kb debug-root ) | grep -qx "$d/mkb" || { echo "FAIL: discovery via kb.toml"; exit 1; }
echo "ok:   discovery finds kb.toml marker"

# 2) discovery via .kb/ dir marker, from a nested subdir (walk upward)
mkdir -p "$d/dkb/.kb" "$d/dkb/sub/deeper"
( cd "$d/dkb/sub/deeper" && kb debug-root ) | grep -qx "$d/dkb" || { echo "FAIL: discovery via .kb/ from nested dir"; exit 1; }
echo "ok:   discovery walks upward to .kb/ marker"

# 3) env overrides discovery
( cd "$d/mkb" && KB_ROOT="$d/envkb" kb debug-root ) | grep -qx "$d/envkb" || { echo "FAIL: env precedence over discovery"; exit 1; }
echo "ok:   KB_ROOT overrides discovery"

# 4) flag overrides env
KB_ROOT="$d/envkb" kb --kb-root "$d/flagkb" debug-root | grep -qx "$d/flagkb" || { echo "FAIL: flag precedence over env"; exit 1; }
echo "ok:   --kb-root overrides KB_ROOT"

# 5) config layer: top-level root, used when no flag/env and no discovery marker
xdg="$d/xdg"; mkdir -p "$xdg/kb"
cat > "$xdg/kb/config.toml" <<EOF
root = "$d/cfgdefault"

[instance.personal]
root = "$d/cfgpersonal"

[instance.work]
root = "$d/cfgwork"
EOF
( cd "$d" && XDG_CONFIG_HOME="$xdg" sh "$KB" debug-root ) | grep -qx "$d/cfgdefault" \
  || { echo "FAIL: config top-level root"; exit 1; }
echo "ok:   config top-level root resolves"

# 6) config named instance via --instance
( cd "$d" && XDG_CONFIG_HOME="$xdg" sh "$KB" --instance personal debug-root ) | grep -qx "$d/cfgpersonal" \
  || { echo "FAIL: config --instance personal"; exit 1; }
( cd "$d" && XDG_CONFIG_HOME="$xdg" sh "$KB" --instance work debug-root ) | grep -qx "$d/cfgwork" \
  || { echo "FAIL: config --instance work"; exit 1; }
echo "ok:   config named instances resolve"

# 7) env overrides config; flag overrides config
( cd "$d" && KB_ROOT="$d/envkb" XDG_CONFIG_HOME="$xdg" sh "$KB" debug-root ) | grep -qx "$d/envkb" \
  || { echo "FAIL: env should override config"; exit 1; }
( cd "$d" && XDG_CONFIG_HOME="$xdg" sh "$KB" --kb-root "$d/flagkb" debug-root ) | grep -qx "$d/flagkb" \
  || { echo "FAIL: flag should override config"; exit 1; }
echo "ok:   env and flag override config"

# 8) no root resolvable -> error on stderr, non-zero exit
( cd "$emptyxdg" && kb debug-root ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo "FAIL: unresolvable root should be non-zero"; exit 1; }
echo "ok:   unresolvable root errors non-zero"

echo "PASS"
