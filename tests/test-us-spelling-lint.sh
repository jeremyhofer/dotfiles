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
lint="$here/../private_dot_local/bin/executable_us-spelling-lint"
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

printf 'An old colour stays.\nThe cancelled order and a catalogue.\n' > "$r/a.md"; git -C "$r" add -A
run "$r"
assert_clean "cancelled and catalogue are accepted by default"

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

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ] || exit 1
echo PASS
