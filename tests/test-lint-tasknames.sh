#!/bin/sh
# Test lint-tasknames against fixtures: the vocabulary is read from a naming-build-tasks skill under
# $HOME, a colon-separated task name is an ERROR (exit 1), a name whose verb is in the vocabulary is
# clean (exit 0), and a missing skill is a READER ERROR (exit 2) rather than a clean run. Last, the
# repo's own skill must still parse into the categories the tool needs, so an edit to the skill's
# tables cannot silently leave the linter with an empty vocabulary.
set -eu
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
tool="$here/../private_dot_local/bin/executable_lint-tasknames"
skill_src="$here/../dot_claude/skills/naming-build-tasks/SKILL.md"
tmp=$(mktemp -d "$_TMP/test-lint-tasknames.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

h="$tmp/home"; mkdir -p "$h/.claude/skills/naming-build-tasks"
cat > "$h/.claude/skills/naming-build-tasks/SKILL.md" <<'MD'
| `build` | produce artifacts |
| `check` · `verify` · `validate` | the triad |
MD
lint() { env -i PATH="$PATH" HOME="$1" python3 "$tool" "$2" 2>&1; }

r="$tmp/clean"; mkdir -p "$r"
printf '{"scripts": {"build-app": "true", "verify-types": "true"}}\n' > "$r/package.json"
out=$(lint "$h" "$r") || { echo "FAIL: clean repo did not exit 0"; echo "$out"; exit 1; }

r="$tmp/colon"; mkdir -p "$r"
printf '{"scripts": {"build:app": "true"}}\n' > "$r/package.json"
out=$(lint "$h" "$r") && rc=0 || rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL: expected exit 1 for a colon-separated name, got $rc"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'separator' || { echo "FAIL: finding does not name the separator rule"; echo "$out"; exit 1; }

out=$(lint "$tmp/no-skill-home" "$tmp/clean") && rc=0 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: expected exit 2 with no skill, got $rc"; echo "$out"; exit 1; }

# The repo's own skill parses into the vocabulary (both row shapes).
cats=$(python3 -B - "$tool" "$skill_src" <<'PY'
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("lt", sys.argv[1])
spec = importlib.util.spec_from_loader("lt", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
m.SKILL_CANDIDATES = [Path(sys.argv[2])]
cats, _ = m.load_categories()
print(" ".join(sorted(cats)))
PY
) || { echo "FAIL: the repo's naming-build-tasks skill did not parse"; exit 1; }
for c in build check verify validate; do
  case " $cats " in *" $c "*) ;; *) echo "FAIL: category '$c' missing from the parsed skill: $cats"; exit 1 ;; esac
done

echo PASS
