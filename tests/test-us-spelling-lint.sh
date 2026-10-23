#!/bin/sh
# Tests for us-spelling-lint. Every case PLANTS a British spelling and asserts it is reported,
# or plants the near-miss and asserts it is not. The near-misses carry as much weight as the
# defects: a gate that fires on a quotation, a code span or a general typo gets switched off.
#
# A "not reported" case asserts the tool EXITED 0, not merely that the output lacks the word.
# Otherwise a missing or crashing tool would pass every near-miss.
set -eu
# No machine-global git config, so none of its commit hooks fire in the scratch repositories.
. "$(dirname "$0")/git-isolate.sh"

here=$(cd "$(dirname "$0")" && pwd)
lint=${US_SPELLING_LINT_UNDER_TEST:-"$here/../private_dot_local/bin/executable_us-spelling-lint"}
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok:   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

_t=${TMPDIR:-/tmp}; _t=${_t%/}
tmp=$(mktemp -d "$_t/us-spelling-lint-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

out=""; rc=0
run() {  # $1 repo, rest args -> sets out, rc
  _r=$1; shift
  rc=0; out=$(cd "$_r" && python3 "$lint" "$@" 2>&1) || rc=$?
}
assert_reported() {  # $1 name  $2 expected substring
  case "$out" in
    *"$2"*) [ "$rc" -eq 1 ] && ok "$1" || bad "$1 (exit $rc, expected 1)" ;;
    *) bad "$1 (expected: $2; got: $out)" ;;
  esac
}
assert_clean() {  # $1 name
  if [ "$rc" -eq 0 ] && ! case "$out" in *"==>"*) true ;; *) false ;; esac; then ok "$1"
  else bad "$1 (exit $rc; output: $out)"; fi
}
repo() {  # $1 name -> a fresh repo
  r="$tmp/$1"; mkdir -p "$r"; git -C "$r" init -q; echo "$r"
}
commit_all() { git -C "$1" add -A; git -C "$1" commit -qm base; }

if ! command -v codespell >/dev/null 2>&1; then
  # The absent-codespell case builds its own PATH and runs even so.
  echo "SKIP: codespell not installed (only the absent-codespell case runs)"
  skip_rest=1
else
  skip_rest=0
fi

# --- absent codespell must be an error, never a silent pass --------------------------------
r=$(repo nocs)
printf 'The behaviour is odd.\n' > "$r/a.md"; git -C "$r" add -A
bin="$tmp/bin-nocs"; mkdir -p "$bin"
for tool in git python3; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
py=$(command -v python3)
rc=0; out=$(cd "$r" && PATH="$bin" "$py" "$lint" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then ok "absent codespell exits 2"; else bad "absent codespell exits 2 (got $rc: $out)"; fi
case "$out" in *codespell*) ok "absent codespell names the missing tool" ;; *) bad "absent codespell names the missing tool ($out)" ;; esac

if [ "$skip_rest" -eq 1 ]; then
  echo "passed $pass, failed $fail"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

# --- the dialect rule, on added lines only -------------------------------------------------
r=$(repo basic)
printf 'An old colour stays.\n' > "$r/a.md"; commit_all "$r"
printf 'An old colour stays.\nThe new behaviour is bad.\n' > "$r/a.md"; git -C "$r" add -A
run "$r"
assert_reported "an added British spelling is reported with path:line" "a.md:2: behaviour ==> behavior"
case "$out" in *"a.md:1:"*) bad "a pre-existing colour on an unchanged line is not reported" ;;
  *) ok "a pre-existing colour on an unchanged line is not reported" ;; esac
case "$out" in *"allow:"*"codespell:ignore"*) ok "the hint names both ways to allow a name" ;;
  *) bad "the hint names both ways to allow a name ($out)" ;; esac

printf 'An old colour stays.\nDo it whilst waiting; amongst friends; travelling.\n' > "$r/a.md"; git -C "$r" add -A
run "$r"
assert_reported "whilst comes from the extra dictionary" "whilst ==> while"
assert_reported "amongst comes from the extra dictionary" "amongst ==> among"
assert_reported "travelling comes from the extra dictionary" "travelling ==> traveling"

printf 'An old colour stays.\nteh cat, a recieve typo.\n' > "$r/a.md"; git -C "$r" add -A
run "$r"
assert_clean "a general typo is not reported (the dialect rule only)"

printf 'An old colour stays.\nThe cancelled order, the cancelling clerk.\n' > "$r/a.md"; git -C "$r" add -A
run "$r"
assert_clean "cancelled and cancelling are accepted by default (American English uses both)"

printf 'An old colour stays.\nA new catalogue.\n' > "$r/a.md"; git -C "$r" add -A
run "$r"
assert_reported "catalogue is refused: the fleet writes catalog" "catalogue ==> catalog"

# --- places where names in use live ---------------------------------------------------------
r=$(repo masks)
printf '# T\n\n```sh\nopen\n```\n\nafter\n' > "$r/a.md"; commit_all "$r"
printf '# T\n\n```sh\nopen\nthe behaviour here\n```\n\nafter\n' > "$r/a.md"; git -C "$r" add -A
run "$r"
assert_clean "a fenced block is skipped (fence opened on an UNCHANGED line above)"

printf '# T\n\n```sh\nopen\n```\n\nafter\nbehaviour outside\n' > "$r/a.md"; git -C "$r" add -A
run "$r"
assert_reported "prose after a closed fence is checked again" "a.md:8: behaviour"

printf '# T\n\n```sh\nopen\n```\n\nafter\nUse `tier0-behaviour-probe` and `colour237` here.\n' > "$r/a.md"; git -C "$r" add -A
run "$r"
assert_clean "inline backtick spans are skipped"

printf '# T\n\n```sh\nopen\n```\n\nafter\nSee https://example.com/behaviour/colour?x=1 and [x](http://e.com/organise).\n' > "$r/a.md"; git -C "$r" add -A
run "$r"
assert_clean "URLs are skipped"

printf '# T\n\n```sh\nopen\n```\n\nafter\nUse `x` then the colour.\n' > "$r/a.md"; git -C "$r" add -A
run "$r"
assert_reported "prose beside a code span is still checked" "colour ==> color"

# --- suppression ----------------------------------------------------------------------------
r=$(repo suppress)
mkdir -p "$r/handoffs" "$r/docs"
printf 'x\n' > "$r/seed"; commit_all "$r"
printf 'The behaviour.\n' > "$r/handoffs/h.md"
printf 'The behaviour.\n' > "$r/docs/d.md"
git -C "$r" add -A
printf 'exclude: handoffs/\n' > "$r/.us-spelling-lint"
run "$r"
assert_reported "exclude: leaves non-excluded paths checked" "docs/d.md:1: behaviour"
case "$out" in *handoffs*) bad "exclude: prefix is not reported" ;; *) ok "exclude: prefix is not reported" ;; esac

printf 'allow: behaviour\n' > "$r/.us-spelling-lint"; run "$r"
assert_clean "allow: word is not reported"
printf 'allow: foo behaviour bar\n' > "$r/.us-spelling-lint"; run "$r"
assert_clean "allow: takes several words on a line"
printf 'allow: colour\n' > "$r/.us-spelling-lint"; run "$r"
assert_reported "allow: of another word does not hide this one" "behaviour ==> behavior"
rm "$r/.us-spelling-lint"

printf 'The behaviour. # codespell:ignore behaviour\n' > "$r/docs/d.md"
printf 'x\n' > "$r/handoffs/h.md"; git -C "$r" add -A
run "$r"
assert_clean "inline codespell:ignore comment is honored"

# --- configuration --------------------------------------------------------------------------
r=$(repo cfg)
printf 'x\n' > "$r/seed"; commit_all "$r"
printf '# a script\necho hi # the behaviour\n' > "$r/s.sh"; git -C "$r" add -A
run "$r"
assert_clean "a .sh file is not checked by default"
printf '# comment\ninclude: *.sh\n' > "$r/.us-spelling-lint"
run "$r"
assert_reported "include: *.sh brings shell files in" "s.sh:2: behaviour"
printf 'bogus: 1\n' > "$r/.us-spelling-lint"
run "$r"
case "$out" in *bogus*) [ "$rc" -eq 2 ] && ok "an unknown config key is an error (exit 2), named" || bad "an unknown config key exits 2 (got $rc)" ;;
  *) bad "an unknown config key is named in the error ($out)" ;; esac
rm "$r/.us-spelling-lint"
printf 'allow: behaviour\n' > "$tmp/other.cfg"
printf 'x\n' > "$r/b.md"; printf 'The behaviour.\n' > "$r/b.md"; git -C "$r" add -A
run "$r" --config "$tmp/other.cfg"
assert_clean "--config FILE is honored"
rc=0; out=$(cd "$r" && US_SPELLING_LINT_CONFIG="$tmp/other.cfg" python3 "$lint" 2>&1) || rc=$?
assert_clean "\$US_SPELLING_LINT_CONFIG is honored"
run "$r" --verbose
case "$out" in *"no config"*) ok "--verbose says that no config was found" ;; *) bad "--verbose says that no config was found ($out)" ;; esac
run "$r"
case "$out" in *"no config"*) bad "no nagging about config without --verbose" ;; *) ok "no nagging about config without --verbose" ;; esac

# --- --all, subdirectories, spaces, nothing staged ------------------------------------------
r=$(repo all)
mkdir -p "$r/sub dir"
printf 'Old behaviour.\n' > "$r/sub dir/my doc.md"
printf '```\nbehaviour\n```\n' > "$r/fenced.md"
commit_all "$r"
run "$r"
assert_clean "nothing staged exits 0 quietly"
[ -z "$out" ] && ok "nothing staged prints nothing" || bad "nothing staged prints nothing ($out)"
run "$r" --all
assert_reported "--all finds pre-existing text, path with spaces intact" "sub dir/my doc.md:1: behaviour"
case "$out" in *fenced.md*) bad "--all skips fenced blocks too" ;; *) ok "--all skips fenced blocks too" ;; esac

printf 'Old behaviour.\nNew colour.\n' > "$r/sub dir/my doc.md"; git -C "$r" add -A
run "$r/sub dir"
assert_reported "runs from a subdirectory, paths relative to the repository root" "sub dir/my doc.md:2: colour"
case "$out" in *"my doc.md:1:"*) bad "from a subdirectory, old lines stay unreported" ;; *) ok "from a subdirectory, old lines stay unreported" ;; esac

# --- an added line in a new file, and a deletion-only change --------------------------------
r=$(repo newfile)
printf 'one\ntwo behaviour\n' > "$r/n.md"; commit_all "$r"
printf 'one\n' > "$r/n.md"; git -C "$r" add -A
run "$r"
assert_clean "a change that only deletes a line is clean"

# --- hook modes: fleet membership, then the same engine --------------------------------------
# A stub fleet-decl answers per case from STUB_PROJECT_RC (the --project exit code) and
# STUB_TAGS (what `<path> tags` prints).
stub="$tmp/stubbin"; mkdir -p "$stub"
cat > "$stub/fleet-decl" <<'STUB'
#!/bin/sh
if [ "$1" = --project ]; then exit "${STUB_PROJECT_RC:-0}"; fi
if [ "$2" = tags ]; then [ -n "${STUB_TAGS:-}" ] || exit 1; echo "$STUB_TAGS"; exit 0; fi
exit 1
STUB
chmod +x "$stub/fleet-decl"
record="$tmp/mani.yaml"; echo "projects: {}" > "$record"
hookrun() {  # $1 repo, rest args; STUB_* and extra env come from the caller's environment
  _r=$1; shift
  rc=0; out=$(cd "$_r" && PATH="$stub:$PATH" FLEET_RECORD="${HOOK_RECORD:-$record}" python3 "$lint" "$@" 2>&1) || rc=$?
}
r=$(repo hookm)
printf 'x\n' > "$r/seed"; commit_all "$r"
printf 'The behaviour.\n' > "$r/a.md"; git -C "$r" add -A

STUB_PROJECT_RC=0 STUB_TAGS='[internal, web]' hookrun "$r" --hook pre-commit
assert_reported "hook pre-commit: a member repository is checked" "a.md:1: behaviour ==> behavior"
STUB_PROJECT_RC=1 hookrun "$r" --hook pre-commit
assert_clean "hook pre-commit: a repository not in the manifest is skipped"
[ -z "$out" ] && ok "a skipped repository prints nothing" || bad "a skipped repository prints nothing ($out)"
STUB_PROJECT_RC=0 STUB_TAGS='[internal, upstream]' hookrun "$r" --hook pre-commit
assert_clean "hook pre-commit: an upstream-tagged repository is skipped"
STUB_PROJECT_RC=0 STUB_TAGS='[upstreamish]' hookrun "$r" --hook pre-commit
assert_reported "hook pre-commit: tags match whole words only" "behaviour"
STUB_PROJECT_RC=2 hookrun "$r" --hook pre-commit
if [ "$rc" -eq 2 ]; then ok "hook: an unreadable manifest refuses (exit 2)"; else bad "hook: an unreadable manifest refuses (exit $rc)"; fi
case "$out" in *"manifest could not be read"*) ok "hook: the refusal says why" ;; *) bad "hook: the refusal says why ($out)" ;; esac
# A machine with no fleet: fleet-decl absent from PATH.
nof="$tmp/bin-nofleet"; mkdir -p "$nof"
for tool in git python3 codespell; do ln -s "$(command -v "$tool")" "$nof/$tool"; done
rc=0; out=$(cd "$r" && PATH="$nof" FLEET_RECORD="$record" "$(command -v python3)" "$lint" --hook pre-commit 2>&1) || rc=$?
assert_clean "hook: no fleet-decl on PATH exits 0 (a machine with no fleet)"
# A machine whose manifest file does not exist: fleet-decl itself would exit 2 here.
STUB_PROJECT_RC=2 HOOK_RECORD="$tmp/absent.yaml" hookrun "$r" --hook pre-commit
assert_clean "hook: no manifest file exits 0 even though fleet-decl would say exit 2"
# Non-hook mode ignores membership.
STUB_PROJECT_RC=1 hookrun "$r"
assert_reported "outside hook modes membership is not consulted" "behaviour"

# commit-msg
m="$tmp/msg"
msgrun() { STUB_PROJECT_RC=0 STUB_TAGS='[internal]' hookrun "$r" --hook commit-msg "$m"; }
printf 'Fix the thing\n\nThe behaviour changed.\n' > "$m"; msgrun
assert_reported "commit-msg: a British word in the message is reported" "commit message:3: behaviour ==> behavior"
printf 'Fix the thing\n\n# the behaviour here is a git comment\n' > "$m"; msgrun
assert_clean "commit-msg: a comment line is skipped"
printf 'Fix\n\n# ------------------------ >8 ------------------------\ndiff\n+the behaviour\n' > "$m"; msgrun
assert_clean "commit-msg: text below the scissors line is skipped"
printf 'Fix `behaviour` here\n' > "$m"; msgrun
assert_clean "commit-msg: a backtick span is skipped"
printf 'See https://example.com/behaviour now\n' > "$m"; msgrun
assert_clean "commit-msg: a URL is skipped"
printf 'The colour\n' > "$m"
printf 'allow: colour\n' > "$r/.us-spelling-lint"; msgrun
assert_clean "commit-msg: allow: from the repository config applies"
printf 'exclude: commit\n' > "$r/.us-spelling-lint"; msgrun
assert_reported "commit-msg: path excludes do not apply" "commit message:1: colour"
rm "$r/.us-spelling-lint"
STUB_PROJECT_RC=1 hookrun "$r" --hook commit-msg "$m"
assert_clean "commit-msg: a non-member is skipped"
# codespell missing, member repository.
nocs2="$tmp/bin-nocs2"; mkdir -p "$nocs2"
for tool in git python3; do ln -s "$(command -v "$tool")" "$nocs2/$tool"; done
cp "$stub/fleet-decl" "$nocs2/fleet-decl"
rc=0; out=$(cd "$r" && PATH="$nocs2" STUB_PROJECT_RC=0 FLEET_RECORD="$record" "$(command -v python3)" "$lint" --hook pre-commit 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then ok "hook: codespell missing in a member repository exits 2"; else bad "hook: codespell missing exits 2 (got $rc: $out)"; fi
case "$out" in *codespell*) ok "hook: the missing-codespell message names it" ;; *) bad "hook: the missing-codespell message names it ($out)" ;; esac
rc=0; out=$(cd "$r" && PATH="$nocs2" STUB_PROJECT_RC=1 FLEET_RECORD="$record" "$(command -v python3)" "$lint" --hook pre-commit 2>&1) || rc=$?
assert_clean "hook: codespell missing in a non-member exits 0"

# --- end to end: real git commits through the configured hooks ---------------------------------
gv=$(git --version | sed 's/[^0-9.]//g')
case "$gv" in
  2.5[4-9]*|2.[6-9]*|[3-9].*) e2e=1 ;;
  *) e2e=0; echo "SKIP: git $gv lacks configured hooks (needs 2.54+); end-to-end cases not run" ;;
esac
if [ "$e2e" -eq 1 ]; then
  r=$(repo e2e)
  home="$tmp/e2ehome"; mkdir -p "$home/.local/bin"
  cp "$lint" "$home/.local/bin/us-spelling-lint"; chmod +x "$home/.local/bin/us-spelling-lint"
  cfg="$home/gitconfig"; : > "$cfg"
  git config --file "$cfg" hook.us-spelling-pre-commit.command '"$HOME/.local/bin/us-spelling-lint" --hook pre-commit'
  git config --file "$cfg" hook.us-spelling-pre-commit.event pre-commit
  git config --file "$cfg" hook.us-spelling-commit-msg.command '"$HOME/.local/bin/us-spelling-lint" --hook commit-msg'
  git config --file "$cfg" hook.us-spelling-commit-msg.event commit-msg
  git config --file "$cfg" user.name t; git config --file "$cfg" user.email t@example.com
  git config --file "$cfg" commit.gpgsign false
  gc() { rc=0; out=$(cd "$r" && HOME="$home" GIT_CONFIG_GLOBAL="$cfg" PATH="$stub:$PATH" FLEET_RECORD="$record" STUB_PROJECT_RC=0 STUB_TAGS='[internal]' git "$@" 2>&1) || rc=$?; }
  printf 'The behaviour.\n' > "$r/a.md"; git -C "$r" add -A
  gc commit -m "add a"
  if [ "$rc" -ne 0 ]; then ok "e2e: a commit adding a British word in a .md is refused"; else bad "e2e: staged British word refused (exit 0: $out)"; fi
  case "$out" in *"a.md:1: behaviour"*) ok "e2e: the refusal names the word" ;; *) bad "e2e: the refusal names the word ($out)" ;; esac
  printf 'The behavior.\n' > "$r/a.md"; git -C "$r" add -A
  gc commit -m "add a"
  if [ "$rc" -eq 0 ]; then ok "e2e: with the word fixed the commit succeeds"; else bad "e2e: fixed commit succeeds ($out)"; fi
  printf 'more\n' >> "$r/a.md"; git -C "$r" add -A
  gc commit -m "the behaviour"
  if [ "$rc" -ne 0 ]; then ok "e2e: a British word in -m is refused"; else bad "e2e: British -m refused (exit 0)"; fi
  case "$out" in *"commit message:1: behaviour"*) ok "e2e: the message refusal names the word" ;; *) bad "e2e: the message refusal names the word ($out)" ;; esac
  gc commit -m "the behavior"
  if [ "$rc" -eq 0 ]; then ok "e2e: an American -m succeeds"; else bad "e2e: American -m succeeds ($out)"; fi
fi

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ] || exit 1
echo PASS
