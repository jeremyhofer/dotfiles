#!/bin/sh
# Tests for wt-config-gen -- worktrunk's user config, generated from layered sources.
#
# WHAT IS AT RISK. The generated file is worktrunk's ONLY user config, so a bad run does not degrade a
# setting, it removes every setting -- including the leak-guard hook the private layer adds. So the
# arms that matter most are the refusals: a malformed layer, an unknown declaration, and an unreadable
# manifest must each leave the previous config untouched rather than write something smaller.
#
# Every case below is a VALID setup with ONE planted change, so a pass proves the tool noticed that
# change and not merely that it rejected a broken fixture.
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}   # explicit mktemp templates: macOS mktemp ignores TMPDIR
set -u
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
tool="$here/../private_dot_local/bin/executable_wt-config-gen"
decl="$here/../private_dot_local/bin/executable_fleet-decl"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok:   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1 -> $2"; }
command -v yq >/dev/null 2>&1 || { echo "wt-config-gen tests: yq absent, cannot run"; exit 1; }
command -v wt >/dev/null 2>&1 || { echo "wt-config-gen tests: wt absent, cannot run"; exit 1; }
# The shipped base.toml is a chezmoi template, so the arms that use it render it first.
command -v chezmoi >/dev/null 2>&1 || { echo "wt-config-gen tests: chezmoi absent, cannot run"; exit 1; }

tmp=$(mktemp -d "$_TMP/test-wt-config-gen.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"; cp "$decl" "$tmp/bin/fleet-decl"; chmod +x "$tmp/bin/fleet-decl"
# `wt config show` runs `claude plugin list --json`, which contacts Anthropic's API and a telemetry
# intake. A stub that fails keeps this suite off the network; worktrunk treats it as no plugin.
# Exported, not only in run(): the arms below that call `wt` directly need it too.
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/claude"; chmod +x "$tmp/bin/claude"
PATH="$tmp/bin:$PATH"; export PATH

base() { printf 'worktree-path = "{{ repo_path }}/.worktrees/{{ branch | sanitize }}"\n\n[list]\njson-schema = 2\n' > "$tmp/base.toml"; }
frag() { printf '[pre-start]\nguard = "hook-doctor check --path {{ worktree_path }} --quiet"\n' > "$tmp/frag.toml"; }
record() {  # $1 = the worktrunk block lines for project alpha (may be empty)
  { printf 'projects:\n  alpha:\n    path: internal/alpha/main\n    url: ssh://git@forge.example:3022/team/alpha.git\n'
    [ -n "$1" ] && printf '    worktrunk:\n%s\n' "$1"
    printf '  beta:\n    path: internal/beta\n    url: git@code.example.org:group/sub/beta.git\n'
    printf '    worktrunk:\n      layout: nested\n'
    printf '  gamma:\n    path: internal/gamma\n    url: https://code.example.org/org/gamma.git\n'
  } > "$tmp/mani.yaml"
}
# WT_GEN_WORKTREE_DIR_FILE points every run at a scratch path, absent unless an arm writes it, so the
# machine's own ~/.config/worktrunk/worktree-dir never reaches a case.
run() {  # prints exit status; output in $tmp/out, $tmp/err
  PATH="$tmp/bin:$PATH" WT_GEN_BASE="$tmp/base.toml" WT_GEN_FRAGMENT="$tmp/frag.toml" \
    WT_GEN_OUT="$tmp/config.toml" FLEET_RECORD="$tmp/mani.yaml" FLEET_DEVEL_ROOT="$tmp" \
    WT_GEN_WORKTREE_DIR_FILE="$tmp/worktree-dir" \
    sh "$tool" >"$tmp/out" 2>"$tmp/err"; echo $?
}
seed() { printf '# previous config\n' > "$tmp/config.toml"; }
# The body of one generated [projects."<id>"] table, from the file named.
table() { awk -v h="[projects.\"$2\"]" 'index($0,h)==1{f=1;next} /^\[/{f=0} f' "$1"; }
# render <data lines> <source file>: one source file rendered by chezmoi against a scratch config,
# so neither the machine's chezmoi config nor its state is read or written.
render() {
  printf 'sourceDir = "%s"\n[data]\n%s\n' "$src" "$1" > "$tmp/cz.toml"
  chezmoi --config "$tmp/cz.toml" --source "$src" --persistent-state "$tmp/cz.db" \
    execute-template < "$src/$2"
}
ON='    claudeWorktrees = true'; OFF='    claudeWorktrees = false'

# 1. the happy path: every layer present
base; frag; record '      layout: bare
      bootstrap: true'; seed
rc=$(run); c=$(cat "$tmp/config.toml")
[ "$rc" = 0 ] && ok "valid layers generate" || bad "valid layers generate" "rc=$rc $(cat "$tmp/err")"
case "$c" in *'[projects."forge.example:3022/team/alpha"]'*) ok "ssh:// url with port -> host:port/owner/repo";; *) bad "ssh id" "$c";; esac
case "$c" in *'[projects."code.example.org/group/sub/beta"]'*) ok "scp-style url with subgroups -> id";; *) bad "scp id" "$c";; esac
case "$c" in *'code.example.org/org/gamma'*) bad "project without a worktrunk block got an entry" "$c";; *) ok "no worktrunk block -> no entry";; esac
case "$c" in *'{{ repo_path }}/../{{ branch | sanitize }}'*) ok "layout bare -> sibling worktree path";; *) bad "layout bare" "$c";; esac
case "$c" in *'pre-start.bootstrap = "wt-bootstrap"'*) ok "bootstrap true -> blocking pre-start";; *) bad "bootstrap" "$c";; esac
case "$c" in *'guard = "hook-doctor'*) ok "private fragment included";; *) bad "fragment" "$c";; esac
wt --config "$tmp/config.toml" config show >/dev/null 2>&1 && ok "worktrunk parses the result" || bad "wt parse" "$(cat "$tmp/config.toml")"
# The installed worktrunk is the judge of the key: a clone whose remote is alpha's URL must see the
# generated bootstrap among its pre-start hooks. A key worktrunk derives differently (worktrunk 0.82
# keeps a scheme URL's port) matches nothing, silently, and no other arm here would notice.
git init -q "$tmp/alpha-clone" && git -C "$tmp/alpha-clone" remote add origin ssh://git@forge.example:3022/team/alpha.git
case "$(cd "$tmp/alpha-clone" && wt --config "$tmp/config.toml" hook show pre-start 2>&1)" in
  *bootstrap*) ok "worktrunk matches the generated key: a clone of alpha sees its bootstrap" ;;
  *) bad "worktrunk does not match the generated key for alpha" "$(cd "$tmp/alpha-clone" && wt --config "$tmp/config.toml" config show 2>&1 | grep -n Identifier)" ;;
esac

# 2. no fragment (a machine with no private layer) -> base + projects only
rm -f "$tmp/frag.toml"; seed; rc=$(run)
[ "$rc" = 0 ] && ! grep -q 'hook-doctor' "$tmp/config.toml" && ok "absent fragment is optional" || bad "absent fragment" "rc=$rc"
frag

# 2a. THE WORKTREE DIRECTORY. A nested project's worktree-path takes its directory from the one-line
# file the dotfiles render from the claudeWorktrees data flag (~/.config/worktrunk/worktree-dir),
# so a hand run gives what the apply's run gives. Absent, it is .worktrees: the flag-off value and the
# behavior before the file existed. A bare project's sibling path never depends on it.
nested_off='worktree-path = "{{ repo_path }}/.worktrees/{{ branch | sanitize }}"'
nested_on='worktree-path = "{{ repo_path }}/.claude/worktrees/{{ branch | sanitize }}"'
sibling='worktree-path = "{{ repo_path }}/../{{ branch | sanitize }}"'
beta=code.example.org/group/sub/beta; alpha=forge.example:3022/team/alpha
rm -f "$tmp/worktree-dir"; seed; rc=$(run)
[ "$rc" = 0 ] && [ "$(table "$tmp/config.toml" "$beta" | grep '^worktree-path')" = "$nested_off" ] \
  && ok "worktree-dir absent: a nested project's worktrees go under .worktrees/" \
  || bad "worktree-dir absent -> .worktrees" "rc=$rc $(table "$tmp/config.toml" "$beta")"
printf '.worktrees\n' > "$tmp/worktree-dir"; seed; rc=$(run)
[ "$rc" = 0 ] && [ "$(table "$tmp/config.toml" "$beta" | grep '^worktree-path')" = "$nested_off" ] \
  && ok "worktree-dir .worktrees (the flag off): unchanged" \
  || bad "worktree-dir .worktrees" "rc=$rc $(table "$tmp/config.toml" "$beta")"
printf '.claude/worktrees\n' > "$tmp/worktree-dir"; seed; rc=$(run)
[ "$rc" = 0 ] && [ "$(table "$tmp/config.toml" "$beta" | grep '^worktree-path')" = "$nested_on" ] \
  && ok "worktree-dir .claude/worktrees (the flag on): a nested project's worktrees go under .claude/worktrees/" \
  || bad "worktree-dir .claude/worktrees" "rc=$rc $(table "$tmp/config.toml" "$beta")"
[ "$(table "$tmp/config.toml" "$alpha" | grep '^worktree-path')" = "$sibling" ] \
  && ok "worktree-dir .claude/worktrees: a bare project keeps its sibling path" \
  || bad "bare project unaffected by worktree-dir" "$(table "$tmp/config.toml" "$alpha")"
# A value that is not a plain relative directory is refused, and the old config stays: it is written
# into a TOML string, and a worktree path outside the repository would undo the layout's point.
for v in '../elsewhere' '/abs/worktrees' 'a"b' '' 'x/../y'; do
  printf '%s\n' "$v" > "$tmp/worktree-dir"; seed; rc=$(run)
  if [ "$rc" != 0 ] && [ "$(cat "$tmp/config.toml")" = "# previous config" ] && grep -q 'worktree-dir' "$tmp/err"; then
    ok "worktree-dir '$v' is refused, naming the file, and the old config stays"
  else bad "worktree-dir '$v' refused" "rc=$rc $(cat "$tmp/err")"; fi
done
rm -f "$tmp/worktree-dir"

# 2b. a container declaration implies the bare layout. An entry that declares a bare container (a
# `container:` block, or a `clone:` that runs fleet-repo) says so twice otherwise, and forgetting the
# second is silent: worktrunk's default is the nested layout, so new worktrees land inside the
# default branch's checkout. An explicit worktrunk.layout still wins.
{ printf 'projects:\n'
  printf '  withblock:\n    path: c/withblock/main\n    url: https://code.example.org/org/withblock.git\n    container:\n      branches: default\n'
  printf '  withclone:\n    path: c/withclone/main\n    url: https://code.example.org/org/withclone.git\n    clone: fleet-repo clone withclone\n'
  printf '  withlegacy:\n    path: c/withlegacy/main\n    url: https://code.example.org/org/withlegacy.git\n    clone: git-clone-worktree --mani-project withlegacy\n'
  printf '  override:\n    path: c/override/main\n    url: https://code.example.org/org/override.git\n    container: {}\n    worktrunk:\n      layout: nested\n'
  printf '  plainclone:\n    path: c/plainclone\n    url: https://code.example.org/org/plainclone.git\n    clone: git clone https://code.example.org/org/plainclone.git c/plainclone\n'
  printf '  mentions:\n    path: c/mentions\n    url: https://code.example.org/org/mentions.git\n    clone: echo not-fleet-repo-really\n'
} > "$tmp/mani.yaml"
seed; rc=$(run); c=$(cat "$tmp/config.toml")
[ "$rc" = 0 ] && ok "a manifest of container declarations generates" || bad "container manifest generates" "rc=$rc $(cat "$tmp/err")"
sect() { printf '%s\n' "$c" | awk -v h="[projects.\"$1\"]" 'index($0,h)==1{f=1;next} /^\[/{f=0} f'; }
case "$(sect code.example.org/org/withblock)" in *'/../{{ branch'*) ok "a container: block -> sibling worktree path";; *) bad "container block implies bare" "$c";; esac
case "$(sect code.example.org/org/withclone)" in *'/../{{ branch'*) ok "clone: fleet-repo -> sibling worktree path";; *) bad "fleet-repo clone implies bare" "$c";; esac
case "$(sect code.example.org/org/withlegacy)" in *'/../{{ branch'*) ok "clone: git-clone-worktree (the shim) -> sibling worktree path";; *) bad "legacy clone implies bare" "$c";; esac
case "$(sect code.example.org/org/override)" in *'.worktrees/'*) ok "an explicit worktrunk.layout overrides the implication";; *) bad "explicit layout wins" "$c";; esac
case "$c" in *plainclone*) bad "an ordinary clone: line got an entry" "$c";; *) ok "an ordinary clone: line implies nothing";; esac
case "$c" in *org/mentions*) bad "a clone: line merely containing the word got an entry" "$c";; *) ok "only a command WORD fleet-repo counts, not a substring";; esac
record '      layout: bare
      bootstrap: true'

# 2c. a hook table opened by base AND fragment is merged into one table, not refused: each layer may
# have its own reason to run something at worktree creation.
printf '\n[pre-start]\ncopy-files = "true"\n' >> "$tmp/base.toml"; frag; seed; rc=$(run); c=$(cat "$tmp/config.toml")
[ "$rc" = 0 ] && ok "a hook table shared by base and fragment generates" || bad "shared hook table generates" "rc=$rc $(cat "$tmp/err")"
[ "$(grep -c '^\[pre-start\]' "$tmp/config.toml")" = 1 ] && ok "the shared hook table is opened once" || bad "one [pre-start]" "$c"
pre=$(printf '%s\n' "$c" | awk '/^\[pre-start\]/{f=1;next} /^\[/{f=0} f')
case "$pre" in *'copy-files = "true"'*'guard = "hook-doctor'*) ok "both layers' hooks are inside it";; *) bad "merged hooks" "$pre";; esac
wt --config "$tmp/config.toml" config show >/dev/null 2>&1 && ok "worktrunk parses the merged result" || bad "wt parse merged" "$c"
base

# 2d. END TO END, with the base.toml this repository SHIPS: a new worktree gets the files the default
# worktree lists in .worktreeinclude, and only those; without a list the hook does nothing, silently.
# Rendered with the flag off, as every machine has it until the flag is turned on there.
real="$tmp/base-off.toml"
render "$OFF" dot_config/worktrunk/base.toml.tmpl > "$real" 2>"$tmp/render.err" \
  || bad "the shipped base.toml.tmpl renders" "$(cat "$tmp/render.err")"
rm -f "$tmp/frag.toml"; seed
rc=$(PATH="$tmp/bin:$PATH" WT_GEN_BASE="$real" WT_GEN_FRAGMENT="$tmp/frag.toml" WT_GEN_OUT="$tmp/config.toml" \
  FLEET_RECORD="$tmp/none.yaml" WT_GEN_WORKTREE_DIR_FILE="$tmp/worktree-dir" sh "$tool" >"$tmp/out" 2>"$tmp/err"; echo $?)
[ "$rc" = 0 ] && ok "the shipped base.toml generates" || bad "shipped base generates" "rc=$rc $(cat "$tmp/err")"
c2="$tmp/c2"; mkdir -p "$c2"
(
  export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 HOME="$tmp/home"; : > "$GIT_CONFIG_GLOBAL"; mkdir -p "$HOME"
  git init -q -b main "$c2/src" && git -C "$c2/src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  git clone -q --bare "$c2/src" "$c2/box/.git"
  git -C "$c2/box" worktree add -q main main
  printf 'local.properties\n.worktreeinclude\nbuild/\n' >> "$c2/box/.git/info/exclude"
  printf 'sdk.dir=/opt/sdk\n' > "$c2/box/main/local.properties"; mkdir -p "$c2/box/main/build"; : > "$c2/box/main/build/out"
  cd "$c2/box/main" || exit 1
  # No path setting here: the shipped default must put a worktree beside the others in a container
  # whose bare repository is named .git, with nothing declared for it.
  wt --config "$tmp/config.toml" -y switch --create quiet --no-cd > "$tmp/e2e-quiet" 2>&1
  printf 'local.properties\n' > .worktreeinclude
  wt --config "$tmp/config.toml" -y switch --create listed --no-cd > "$tmp/e2e-listed" 2>&1
  # A plain clone with the same shipped default: the worktree nests under .worktrees/.
  git clone -q "$c2/src" "$c2/plain" && cd "$c2/plain" \
    && wt --config "$tmp/config.toml" -y switch --create nested --no-cd > "$tmp/e2e-plain" 2>&1
  # An OLD-shape container (.bare behind a pointer file) still works for worktree creation when the
  # sibling path is set explicitly, which is what wt-config-gen writes for a declared bare container.
  git clone -q --bare "$c2/src" "$c2/old/.bare" && printf 'gitdir: ./.bare\n' > "$c2/old/.git" \
    && git -C "$c2/old" worktree add -q main main && cd "$c2/old/main" \
    && wt --config "$tmp/config.toml" --config-set "worktree-path = \"{{ repo_path }}/../{{ branch | sanitize }}\"" -y switch --create sib --no-cd > "$tmp/e2e-old" 2>&1
) >/dev/null 2>&1
[ -d "$c2/box/quiet" ] && [ -d "$c2/box/listed" ] && [ ! -e "$c2/box/.git/.worktrees" ] \
  && ok "shipped default, bare repository named .git: a worktree is a sibling of main, never inside .git" \
  || bad "sibling in a .git container" "$(cat "$tmp/e2e-quiet"; ls -A "$c2/box" "$c2/box/.git" 2>&1 | tr '\n' ' ')"
[ -d "$c2/plain/.worktrees/nested" ] && [ ! -e "$c2/nested" ] \
  && ok "shipped default, ordinary clone: a worktree nests under .worktrees/" \
  || bad "nested in a plain clone" "$(cat "$tmp/e2e-plain" 2>&1; ls -A "$c2" "$c2/plain" 2>&1 | tr '\n' ' ')"
[ -d "$c2/old/sib" ] && ok "old-shape .bare container with the explicit sibling path: still a sibling" \
  || bad "old-shape container sibling" "$(cat "$tmp/e2e-old" 2>&1; ls -A "$c2/old" | tr '\n' ' ')"
[ ! -e "$c2/box/quiet/local.properties" ] && [ -d "$c2/box/quiet" ] && ! grep -qi 'nothing copied' "$tmp/e2e-quiet" \
  && ok "without .worktreeinclude: nothing copied, nothing said" || bad "no list -> silent no-op" "$(cat "$tmp/e2e-quiet")"
[ "$(cat "$c2/box/listed/local.properties" 2>/dev/null)" = "sdk.dir=/opt/sdk" ] \
  && ok "with .worktreeinclude: the listed file reaches the new worktree" || bad "listed file copied" "$(cat "$tmp/e2e-listed")"
[ ! -e "$c2/box/listed/build" ] && ok "an ignored file it does not list stays behind" || bad "unlisted not copied" "$(ls -A "$c2/box/listed")"

# 2e. THE FLAG, RENDERED. claudeWorktrees reaches worktrunk through one chezmoi partial
# (.chezmoitemplates/worktrunk.worktree-dir); base.toml.tmpl's standard-clone default, the one-line
# worktree-dir file that wt-config-gen and fleet-repo read, and the regeneration trigger all render
# it. Each rendering is checked against both values of the flag, and against a config written before
# the flag existed, which must read as off.
top() { grep '^worktree-path = ' "$1"; }
base_line_off='worktree-path = "{% if repo_path is endingwith(\"/.git\") %}{{ repo_path }}/../{{ branch | sanitize }}{% else %}{{ repo_path }}/.worktrees/{{ branch | sanitize }}{% endif %}"'
base_line_on='worktree-path = "{% if repo_path is endingwith(\"/.git\") %}{{ repo_path }}/../{{ branch | sanitize }}{% else %}{{ repo_path }}/.claude/worktrees/{{ branch | sanitize }}{% endif %}"'
render "$ON" dot_config/worktrunk/base.toml.tmpl > "$tmp/base-on.toml" 2>"$tmp/render.err" \
  || bad "base.toml.tmpl renders with the flag on" "$(cat "$tmp/render.err")"
render '' dot_config/worktrunk/base.toml.tmpl > "$tmp/base-unset.toml" 2>"$tmp/render.err" \
  || bad "base.toml.tmpl renders with no flag in the config" "$(cat "$tmp/render.err")"
[ "$(top "$real")" = "$base_line_off" ] && ok "base.toml, flag off: the standard-clone default is .worktrees/, the bare sibling unchanged" \
  || bad "base.toml flag off" "$(top "$real")"
[ "$(top "$tmp/base-on.toml")" = "$base_line_on" ] && ok "base.toml, flag on: the standard-clone default is .claude/worktrees/, the bare sibling unchanged" \
  || bad "base.toml flag on" "$(top "$tmp/base-on.toml")"
cmp -s "$real" "$tmp/base-unset.toml" && ok "base.toml, a config without the flag renders exactly as flag off" \
  || bad "base.toml unset == off" "$(diff "$real" "$tmp/base-unset.toml" | head -5)"
[ "$(grep -cE '\[%|%\]|chezmoi:template' "$real")" = 0 ] \
  && ok "base.toml: the chezmoi directive and delimiters are gone from the rendered file" \
  || bad "rendered base.toml is clean" "$(grep -nE '\[%|%\]|chezmoi:template' "$real")"
for v in "$OFF:.worktrees" "$ON:.claude/worktrees" ":.worktrees"; do
  out=$(render "${v%%:*}" dot_config/worktrunk/worktree-dir.tmpl 2>&1); want=${v#*:}
  [ "$out" = "$want" ] && [ "$(render "${v%%:*}" dot_config/worktrunk/worktree-dir.tmpl | wc -l | tr -d ' ')" = 1 ] \
    && ok "worktree-dir renders one line, $want, for data '${v%%:*}'" || bad "worktree-dir for '${v%%:*}'" "$out"
done
trig=run_onchange_after_generate-worktrunk-config.sh.tmpl
t_off=$(render "$OFF" "$trig" 2>&1); t_on=$(render "$ON" "$trig" 2>&1); t_unset=$(render '' "$trig" 2>&1)
[ -n "$t_off" ] && [ "$t_off" != "$t_on" ] && ok "the regeneration trigger's text changes when the flag flips, so the apply re-runs wt-config-gen" \
  || bad "trigger differs on a flag flip" "$(printf '%s\n' "$t_off" | head -12)"
[ "$t_off" = "$t_unset" ] && ok "the trigger renders the same with the flag off and with no flag" || bad "trigger unset == off" "$t_unset"
# The flag has one reader: no template other than the partial (and the config template that declares
# it) reads claudeWorktrees, so the mapping from the flag to a directory exists once.
readers=$(cd "$src" && git ls-files --cached --others --exclude-standard -- '*.tmpl' '.chezmoitemplates/*' | while IFS= read -r f; do
  grep -lE '\.claudeWorktrees|"claudeWorktrees"' "$f"; done | LC_ALL=C sort | tr '\n' ' ')
[ "$readers" = ".chezmoi.toml.tmpl .chezmoitemplates/worktrunk.worktree-dir " ] \
  && ok "only the partial reads the flag (and the config template declares it)" || bad "the flag's readers" "$readers"
# chezmoi init carries the flag forward: a value set by hand in the generated config survives.
for v in true false; do
  printf '[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n    claudeWorktrees = %s\n' "$v" > "$tmp/old.toml"
  cfg=$(chezmoi --config "$tmp/old.toml" --source "$src" --persistent-state "$tmp/cz.db" \
    execute-template --init --no-tty < "$src/.chezmoi.toml.tmpl" 2>&1)
  printf '%s\n' "$cfg" | grep -qx "    claudeWorktrees = $v" && ok "chezmoi init keeps claudeWorktrees = $v" || bad "init keeps $v" "$cfg"
done
printf '[data]\n    domain = "personal"\n    overlayRepo = ""\n    dpi = "120"\n' > "$tmp/old.toml"
cfg=$(chezmoi --config "$tmp/old.toml" --source "$src" --persistent-state "$tmp/cz.db" \
  execute-template --init --no-tty < "$src/.chezmoi.toml.tmpl" 2>&1)
printf '%s\n' "$cfg" | grep -qx '    claudeWorktrees = false' && ok "chezmoi init writes claudeWorktrees = false when it was never set" || bad "init default false" "$cfg"

# 2f. END TO END WITH THE FLAG ON: the real worktrunk, the base rendered with the flag on and the
# worktree-dir file saying .claude/worktrees, as an apply on such a machine leaves them. A standard
# clone's new worktree nests under .claude/worktrees/ by the base's default; a bare container's is
# still a sibling (the bare branch is untouched); and a project the manifest declares nested gets
# .claude/worktrees/ from its own table, shown with the base left off so only the table can put it
# there.
printf '.claude/worktrees\n' > "$tmp/worktree-dir"
printf 'projects:\n  plain2:\n    path: c/plain2\n    url: https://code.example.org/org/plain2.git\n    worktrunk:\n      layout: nested\n' > "$tmp/mani2.yaml"
gen() {  # $1 base, $2 output, $3 manifest
  PATH="$tmp/bin:$PATH" WT_GEN_BASE="$1" WT_GEN_FRAGMENT="$tmp/frag.toml" WT_GEN_OUT="$2" \
    FLEET_RECORD="$3" FLEET_DEVEL_ROOT="$tmp" WT_GEN_WORKTREE_DIR_FILE="$tmp/worktree-dir" sh "$tool" >"$tmp/out" 2>"$tmp/err"; echo $?
}
rc=$(gen "$tmp/base-on.toml" "$tmp/config-on.toml" "$tmp/none.yaml")
[ "$rc" = 0 ] && ok "the base rendered with the flag on generates" || bad "flag-on base generates" "rc=$rc $(cat "$tmp/err")"
rc=$(gen "$real" "$tmp/config-table.toml" "$tmp/mani2.yaml")
[ "$rc" = 0 ] && ok "flag-off base with a nested project and worktree-dir on generates" || bad "table config generates" "rc=$rc $(cat "$tmp/err")"
(
  export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 HOME="$tmp/home"; : > "$GIT_CONFIG_GLOBAL"; mkdir -p "$HOME"
  cd "$c2/plain" && wt --config "$tmp/config-on.toml" -y switch --create claudeon --no-cd > "$tmp/e2e-on" 2>&1
  cd "$c2/box/main" && wt --config "$tmp/config-on.toml" -y switch --create sibon --no-cd > "$tmp/e2e-sibon" 2>&1
  git clone -q "$c2/src" "$c2/plain2" && git -C "$c2/plain2" remote set-url origin https://code.example.org/org/plain2.git \
    && cd "$c2/plain2" && wt --config "$tmp/config-table.toml" -y switch --create bytable --no-cd > "$tmp/e2e-table" 2>&1
) >/dev/null 2>&1
[ -d "$c2/plain/.claude/worktrees/claudeon" ] && [ ! -e "$c2/plain/.worktrees/claudeon" ] \
  && ok "flag on, ordinary clone: a worktree nests under .claude/worktrees/" \
  || bad "flag on, nested under .claude/worktrees" "$(cat "$tmp/e2e-on" 2>&1; ls -A "$c2/plain" 2>&1 | tr '\n' ' ')"
[ -d "$c2/box/sibon" ] && [ ! -e "$c2/box/.git/.claude" ] \
  && ok "flag on, bare repository named .git: still a sibling of main" \
  || bad "flag on, bare sibling" "$(cat "$tmp/e2e-sibon" 2>&1; ls -A "$c2/box" 2>&1 | tr '\n' ' ')"
[ -d "$c2/plain2/.claude/worktrees/bytable" ] && [ ! -e "$c2/plain2/.worktrees/bytable" ] \
  && ok "worktree-dir on, a project declared nested: its own table puts the worktree under .claude/worktrees/" \
  || bad "nested table honors worktree-dir" "$(cat "$tmp/e2e-table" 2>&1; ls -A "$c2/plain2" 2>&1 | tr '\n' ' ')"
rm -f "$tmp/worktree-dir"
frag

# 3. no manifest at all -> base + fragment, stated
mv "$tmp/mani.yaml" "$tmp/mani.away"; seed; rc=$(run)
[ "$rc" = 0 ] && grep -q 'no manifest' "$tmp/err" && ok "absent manifest degrades, and says so" || bad "absent manifest" "rc=$rc $(cat "$tmp/err")"
mv "$tmp/mani.away" "$tmp/mani.yaml"

# --- refusals: each must exit non-zero AND leave the previous config untouched
refused() {  # $1 label
  rc=$(run)
  if [ "$rc" != 0 ] && [ "$(cat "$tmp/config.toml")" = "# previous config" ]; then ok "$1"; else bad "$1" "rc=$rc $(cat "$tmp/err")"; fi
}
seed; printf 'stray = 1\n[pre-start]\nx = "y"\n' > "$tmp/frag.toml"; refused "fragment with a top-level key is refused"
frag; seed; printf '[list]\nfull = true\n' > "$tmp/frag.toml"; refused "fragment redefining a base table is refused"
grep -q 'opened by more than one source' "$tmp/err" && grep -q 'frag.toml' "$tmp/err" \
  && ok "the duplicate is named with its source, not left to worktrunk's line number" \
  || bad "duplicate message names the source" "$(cat "$tmp/err")"
frag; seed; printf '[pre-start]\ncopy-files = "other"\n' >> "$tmp/base.toml"; printf '[pre-start]\ncopy-files = "x"\n' > "$tmp/frag.toml"
refused "a hook name defined by two sources is refused"
grep -q 'pre-start.copy-files' "$tmp/err" && ok "the doubly-defined hook is named" || bad "doubly-defined hook named" "$(cat "$tmp/err")"
base
frag; seed; printf 'projects: [\n' > "$tmp/mani.yaml"; refused "unreadable manifest is refused, not treated as empty"
seed; record '      layout: sideways'; refused "unknown worktrunk value is refused"
seed; record '      bootsrap: true'; refused "unknown worktrunk key is refused"
seed; record '      layout: bare'; printf '[list\n' > "$tmp/base.toml"; refused "a result worktrunk cannot parse is refused"
base

# A write that fails must FAIL, not report success. A read-only output directory makes the copy
# fail; the old script, under set -e, carried on past the failed `cp && mv` and printed "wrote".
frag; record ''; mkdir -p "$tmp/ro"; printf '# previous config\n' > "$tmp/ro/config.toml"; chmod 555 "$tmp/ro"
rc=$(PATH="$tmp/bin:$PATH" WT_GEN_BASE="$tmp/base.toml" WT_GEN_FRAGMENT="$tmp/frag.toml" \
  WT_GEN_OUT="$tmp/ro/config.toml" FLEET_RECORD="$tmp/mani.yaml" FLEET_DEVEL_ROOT="$tmp" \
  sh "$tool" >"$tmp/out" 2>"$tmp/err"; echo $?)
chmod 755 "$tmp/ro"
if [ "$rc" -ne 0 ] && ! grep -q 'wrote' "$tmp/err" && grep -q '# previous config' "$tmp/ro/config.toml"; then
  ok "an unwritable output fails, says so, and leaves the old config"
else bad "unwritable output" "rc=$rc $(cat "$tmp/err")"; fi

# --help prints usage and writes nothing (it used to run a real regeneration).
seed; rc=$(PATH="$tmp/bin:$PATH" WT_GEN_OUT="$tmp/config.toml" sh "$tool" --help >"$tmp/out" 2>"$tmp/err"; echo $?)
if [ "$rc" -eq 0 ] && grep -q 'usage' "$tmp/out" && grep -q '# previous config' "$tmp/config.toml"; then
  ok "--help prints usage and does not regenerate"
else bad "--help" "rc=$rc"; fi
seed; rc=$(sh "$tool" --bogus >"$tmp/out" 2>"$tmp/err"; echo $?)
[ "$rc" -eq 2 ] && ok "an unknown argument is refused (exit 2)" || bad "unknown argument" "rc=$rc"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
