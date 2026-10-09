#!/bin/sh
# Test that ~/.zshenv points mani at ~/Devel/mani.yaml as a FALLBACK: `mani` run outside the
# manifest's tree finds it, a directory with its own mani.yaml still uses that one, nothing is set
# when ~/Devel/mani.yaml does not exist, and a MANI_CONFIG already in the environment is kept.
# mani reads MANI_CONFIG only when no mani.yaml is found at or above the current directory (measured
# on v0.32.1), which is what makes exporting it safe; the mani cases below re-check that per version.
set -eu
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
command -v chezmoi >/dev/null 2>&1 || { echo "SKIP: chezmoi not installed"; exit 0; }
command -v zsh >/dev/null 2>&1 || { echo "SKIP: zsh not installed"; exit 0; }
tmp=$(mktemp -d "$_TMP/test-mani-config.XXXXXX"); trap 'rm -rf "$tmp"' EXIT

printf 'sourceDir = "%s"\n[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n' "$src" > "$tmp/c.toml"
chezmoi --config "$tmp/c.toml" --source "$src" --persistent-state "$tmp/s.db" \
  execute-template < "$src/dot_zshenv.tmpl" > "$tmp/zshenv"

home=$tmp/home; mkdir -p "$home/Devel" "$tmp/elsewhere" "$tmp/local/sub"
mani_config() {  # $1 = value to preset, or empty; prints MANI_CONFIG after sourcing the rendered file
  HOME=$home MANI_CONFIG=$1 zsh -f -c '[ -n "$MANI_CONFIG" ] || unset MANI_CONFIG; source "$1"; print -r -- "${MANI_CONFIG-}"' _ "$tmp/zshenv"
}

got=$(mani_config '')
[ -z "$got" ] || { echo "FAIL: MANI_CONFIG set ($got) though ~/Devel/mani.yaml does not exist"; exit 1; }

printf 'projects:\n  home-proj:\n    path: home-proj\n' > "$home/Devel/mani.yaml"
got=$(mani_config '')
[ "$got" = "$home/Devel/mani.yaml" ] || { echo "FAIL: MANI_CONFIG is '$got', expected $home/Devel/mani.yaml"; exit 1; }

got=$(mani_config /elsewhere/mani.yaml)
[ "$got" = /elsewhere/mani.yaml ] || { echo "FAIL: a preset MANI_CONFIG was replaced by '$got'"; exit 1; }

if command -v mani >/dev/null 2>&1; then
  printf 'projects:\n  local-proj:\n    path: local-proj\n' > "$tmp/local/mani.yaml"
  list() {  # $1 = directory to run mani from
    (cd "$1" && HOME=$home zsh -f -c 'source "$1"; mani list projects' _ "$tmp/zshenv" 2>&1)
  }
  out=$(list "$tmp/elsewhere")
  printf '%s\n' "$out" | grep -q home-proj || { echo "FAIL: mani outside any manifest tree did not find ~/Devel/mani.yaml"; printf '%s\n' "$out"; exit 1; }
  out=$(list "$tmp/local/sub")
  printf '%s\n' "$out" | grep -q local-proj || { echo "FAIL: a local mani.yaml lost to MANI_CONFIG"; printf '%s\n' "$out"; exit 1; }
  if printf '%s\n' "$out" | grep -q home-proj; then echo "FAIL: MANI_CONFIG overrode a local mani.yaml"; exit 1; fi
fi

echo PASS
