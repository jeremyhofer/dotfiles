#!/bin/sh
# Test the per-machine skill exclusion: a skill named in the skipSkills config value is ignored
# (neither its directory nor anything under it deploys), no other skill is, an unset value ignores
# nothing, and regenerating the config keeps the value, since a key added by hand to a generated
# config would otherwise be lost at the next `chezmoi init`.
set -eu
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
command -v chezmoi >/dev/null 2>&1 || { echo "SKIP: chezmoi not installed"; exit 0; }
tmp=$(mktemp -d "$_TMP/test-skip-skills.XXXXXX"); trap 'rm -rf "$tmp"' EXIT

render() {  # $1 = TOML data lines for a throwaway config; renders the source's .chezmoiignore
  printf 'sourceDir = "%s"\n[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n%s\n' "$src" "$1" > "$tmp/c.toml"
  chezmoi --config "$tmp/c.toml" --source "$src" --persistent-state "$tmp/s.db" \
    execute-template < "$src/.chezmoiignore"
}

out=$(render '    skipSkills = ["tuicr-code-review", "seo"]')
printf '%s\n' "$out" | grep -qx '.claude/skills/tuicr-code-review' || { echo "FAIL: a listed skill's directory is not ignored"; exit 1; }
printf '%s\n' "$out" | grep -qx '.claude/skills/tuicr-code-review/\*\*' || { echo "FAIL: a listed skill's contents are not ignored"; exit 1; }
printf '%s\n' "$out" | grep -qx '.claude/skills/seo' || { echo "FAIL: the second listed skill is not ignored"; exit 1; }
if printf '%s\n' "$out" | grep -q '^\.claude/skills/scratch-copies'; then echo "FAIL: an unlisted skill is ignored"; exit 1; fi

out=$(render '')
if printf '%s\n' "$out" | grep -q '^\.claude/skills/'; then echo "FAIL: skills ignored with skipSkills unset"; echo "$out" | grep '^\.claude/skills/'; exit 1; fi

# Regenerating the config keeps the value (and an unset value stays empty).
printf '[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n    skipSkills = ["seo"]\n' > "$tmp/old.toml"
cfg=$(chezmoi --config "$tmp/old.toml" --source "$src" --persistent-state "$tmp/s.db" \
  execute-template --init --no-tty < "$src/.chezmoi.toml.tmpl")
printf '%s\n' "$cfg" | grep -q 'skipSkills = \["seo"\]' || { echo "FAIL: init dropped skipSkills; got:"; echo "$cfg"; exit 1; }
printf '[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n' > "$tmp/old.toml"
cfg=$(chezmoi --config "$tmp/old.toml" --source "$src" --persistent-state "$tmp/s.db" \
  execute-template --init --no-tty < "$src/.chezmoi.toml.tmpl")
printf '%s\n' "$cfg" | grep -q 'skipSkills = \[\]' || { echo "FAIL: init did not write an empty skipSkills; got:"; echo "$cfg"; exit 1; }

echo PASS
