#!/bin/sh
# Test which staged paths make the base's pre-commit run the suite.
#
# The hook is installed by run_onchange_install-git-hooks.sh.tmpl through install-test-gate, so the
# test reads that template's install-test-gate line and runs the same invocation against a scratch
# repository, rather than trusting a deployed copy. The repository's tests/run-all.sh always fails,
# so "the suite ran" is observable as a refused hook and "skipped" as exit 0.
#
# The rule under test: only documentation skips the suite (docs/ and the repository's own *.md
# files at the root). Everything else that deploys or is run has a suite that reads it, so a
# change there must not skip the gate.
set -u
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
base=$(cd "$here/.." && pwd)
tpl="$base/run_onchange_install-git-hooks.sh.tmpl"
tmp=$(mktemp -d "$_TMP/test-pre-commit-trigger.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

# The template's arguments after the repository: `--label ... --skip-var ...`.
args=$(sed -n 's|^sh "\$src/private_dot_local/bin/executable_install-test-gate" "\$src" ||p' "$tpl")
[ -n "$args" ] || { echo "FAIL: no install-test-gate invocation found in $tpl"; exit 1; }

# The generated hook runs the suite under git-staged-run: the SOURCE copy, put on PATH.
mkdir -p "$tmp/bin"; cp "$base/private_dot_local/bin/executable_git-staged-run" "$tmp/bin/git-staged-run"
PATH="$tmp/bin:$PATH"; export PATH

r="$tmp/repo"; git init -q "$r"
mkdir -p "$r/tests"; printf '#!/bin/sh\necho suite-ran; exit 1\n' > "$r/tests/run-all.sh"
# shellcheck disable=SC2086 # $args is the template's own word list
eval "sh \"$base/private_dot_local/bin/executable_install-test-gate\" \"\$r\" $args" >/dev/null \
  || { echo "FAIL: the template's install-test-gate invocation did not install"; exit 1; }
hook="$r/.git/hooks/pre-commit"
try() { # <path> -> rc of the hook with only that path staged
  git -C "$r" rm -q --cached -r . >/dev/null 2>&1 || true
  mkdir -p "$r/$(dirname "$1")"; echo x >> "$r/$1"
  git -C "$r" add -- "$1"
  (cd "$r" && env -u SKIP_BASE_TESTS sh "$hook" >/dev/null 2>&1); echo $?
}

echo "== the suite runs for anything that deploys or runs"
for p in private_dot_local/bin/executable_tool setup/overlay-doctor tests/test-x.sh \
         dot_claude/modify_settings.json dot_claude/skills/demo/SKILL.md dot_gitconfig \
         .chezmoitemplates/zshrc.x run_onchange_install-x.sh.tmpl overlay-skeleton/x.example \
         dot_zshrc.tmpl .chezmoi.toml.tmpl Brewfile; do
  [ "$(try "$p")" != 0 ] && ok "$p runs the suite" || bad "$p runs the suite" "the hook skipped it"
done

echo "== documentation alone skips it"
for p in docs/reference/x.md README.md AGENTS.md CLAUDE.md CHANGELOG.md; do
  [ "$(try "$p")" = 0 ] && ok "$p skips the suite" || bad "$p skips the suite" "the hook ran it"
done

[ "$fails" = 0 ] && { echo "PASS"; exit 0; }
echo "FAILED: $fails"; exit 1
