#!/bin/sh
# test-run-all.sh -- how the runner treats a `uv run --script` suite: it runs one, reports a failing
# one, and SKIPs visibly (never a silent green) when uv is not installed.
#
# The runner is copied beside stand-in suites in a scratch directory, with a stand-in `uv` first on
# PATH for the run/fail cases, so no network or real uv is needed.
set -u
here=$(cd "$(dirname "$0")" && pwd)
pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (no '$3' in: $2)"; fi; }

t=${TMPDIR:-/tmp}; t=${t%/}
w=$(mktemp -d "$t/test-run-all.XXXXXX") || exit 1
trap 'rm -rf "$w"' EXIT
mkdir "$w/tests" "$w/fakebin" "$w/nouv"
cp "$here/run-all.sh" "$here/git-isolate.sh" "$here/git-isolated.gitconfig" "$w/tests/" 2>/dev/null

# A stand-in uv: `uv run --script FILE` records that it ran and exits with the code the file names.
cat > "$w/fakebin/uv" <<'SH'
#!/bin/sh
[ "$1" = run ] && [ "$2" = --script ] || exit 97
echo "uv ran $3"
exit "$(sed -n 's/^# exit=//p' "$3")"
SH
chmod +x "$w/fakebin/uv"
printf '#!/usr/bin/env -S uv run --script\n# exit=0\n' > "$w/tests/test-good.py"
printf '#!/usr/bin/env -S uv run --script\n# exit=3\n' > "$w/tests/test-bad.py"

# A PATH with the POSIX tools the runner uses but no uv (a real uv may live in /usr/bin).
for tool in sh sed cat basename dirname mktemp xargs getconf rm mkdir date env uname grep awk; do
  p=$(command -v "$tool" 2>/dev/null) && ln -s "$p" "$w/nouv/$tool"
done

out=$(PATH="$w/fakebin:$PATH" sh "$w/tests/run-all.sh" good 2>&1); rc=$?
has "a uv suite is run through uv" "$out" "PASS   test-good.py"
[ "$rc" -eq 0 ] && ok "passing uv suite exits 0" || no "passing uv suite exits 0 (rc $rc)"

out=$(PATH="$w/fakebin:$PATH" sh "$w/tests/run-all.sh" bad 2>&1); rc=$?
has "a failing uv suite is reported" "$out" "FAIL   test-bad.py (exit 3)"
[ "$rc" -eq 1 ] && ok "failing uv suite exits 1" || no "failing uv suite exits 1 (rc $rc)"

out=$(PATH="$w/nouv" sh "$w/tests/run-all.sh" good 2>&1); rc=$?
has "without uv the suite is SKIPped visibly" "$out" "SKIP   test-good.py (uv not installed)"
[ "$rc" -eq 2 ] && ok "all suites skipped is not a green run (exit 2)" || no "all skipped exits 2 (rc $rc)"

# --only runs exactly the named suites (the commit gate's selector hands it its list).
printf '#!/bin/sh\nexit 0\n' > "$w/tests/test-one.sh"; printf '#!/bin/sh\nexit 1\n' > "$w/tests/test-two.sh"
out=$(PATH="$w/fakebin:$PATH" sh "$w/tests/run-all.sh" --only test-one.sh 2>&1); rc=$?
has "--only runs the named suite" "$out" "PASS   test-one.sh"
case "$out" in *test-two.sh*|*test-good.py*) no "--only runs nothing else ($out)" ;; *) ok "--only runs nothing else" ;; esac
[ "$rc" -eq 0 ] && ok "--only: a passing selection exits 0" || no "--only: a passing selection exits 0 (rc $rc)"
out=$(PATH="$w/fakebin:$PATH" sh "$w/tests/run-all.sh" --only test-one.sh test-two.sh 2>&1); rc=$?
has "--only: a failing named suite is reported" "$out" "FAIL   test-two.sh (exit 1)"
[ "$rc" -eq 1 ] && ok "--only: a failing selection exits 1" || no "--only: a failing selection exits 1 (rc $rc)"
out=$(PATH="$w/fakebin:$PATH" sh "$w/tests/run-all.sh" --only test-one.sh test-gone.sh 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "--only naming a missing suite exits 2" || no "--only naming a missing suite exits 2 (rc $rc: $out)"
out=$(PATH="$w/nouv" sh "$w/tests/run-all.sh" --only test-good.py 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "--only: every named suite skipped is not a green run (exit 2)" || no "--only all skipped exits 2 (rc $rc)"

# ---- the serial marker: a suite whose second line is `# run-all: serial` runs alone, after the
# parallel batch. Each fixture suite records the window (start end, whole seconds) it ran in.
# The scenario is run twice: with the real runner, and with a copy whose marker test is disabled
# (the plant), which must show an overlap, or the check could not tell serial from parallel.
rec="$w/rec"
mkfix() { # <name> <serial|plain>
  { printf '#!/bin/sh\n'; [ "$2" = serial ] && printf '# run-all: serial\n'
    printf 'mkdir -p "%s"; s=$(date +%%s); sleep 2; e=$(date +%%s); echo "$s $e" > "%s/%s"\n' "$rec" "$rec" "$1"
  } > "$w/ser/test-$1.sh"
}
mkdir "$w/ser"
cp "$w/tests/run-all.sh" "$w/tests/git-isolate.sh" "$w/tests/git-isolated.gitconfig" "$w/ser/"
mkfix par1 plain; mkfix par2 plain; mkfix par3 plain; mkfix ser1 serial; mkfix ser2 serial
# overlap_of <runner dir>: run the five fixtures; print "overlap" when a marked window overlaps any
# other window or a marked one starts before an unmarked one ended, else "none".
serial_verdict() {
  rm -rf "$rec"
  RUN_ALL_JOBS=5 sh "$1/run-all.sh" >/dev/null 2>&1
  for n in par1 par2 par3 ser1 ser2; do [ -s "$rec/$n" ] || { echo "missing:$n"; return; }; done
  awk -v d="$rec" 'BEGIN {
    split("par1 par2 par3 ser1 ser2", nm, " ")
    for (i = 1; i <= 5; i++) { getline line < (d "/" nm[i]); split(line, a, " "); s[nm[i]] = a[1]; e[nm[i]] = a[2] }
    r = "none"
    for (i = 4; i <= 5; i++) for (j = 1; j <= 5; j++) if (j != i) {
      # the windows overlap when each starts before the other ends (whole-second clock, so a shared
      # boundary second is not an overlap)
      if (s[nm[i]] < e[nm[j]] && s[nm[j]] < e[nm[i]]) r = "overlap"
    }
    print r }'
}
v=$(serial_verdict "$w/ser")
[ "$v" = none ] && ok "marked suites overlap no other suite and not each other" || no "marked suites ran alone (verdict: $v)"
sed 's/grep -qxF .# run-all: serial./grep -qxF "# never matches"/' "$w/tests/run-all.sh" > "$w/ser/mutant.sh"
if cmp -s "$w/tests/run-all.sh" "$w/ser/mutant.sh"; then no "serial plant changed nothing"; else
  mkdir "$w/mut"; cp "$w/ser"/test-*.sh "$w/ser/git-isolate.sh" "$w/ser/git-isolated.gitconfig" "$w/mut/"
  cp "$w/ser/mutant.sh" "$w/mut/run-all.sh"
  v=$(serial_verdict "$w/mut")
  [ "$v" = overlap ] && ok "without the serial scheduling the windows overlap (the check can fail)" || no "plant: expected overlap, got $v"
fi
# a marked suite still reports like any other
mkdir "$w/one"; cp "$w/ser/run-all.sh" "$w/ser/git-isolate.sh" "$w/ser/git-isolated.gitconfig" "$w/one/"
printf '#!/bin/sh\n# run-all: serial\necho SERIALBAD\nexit 4\n' > "$w/one/test-sbad.sh"
out=$(sh "$w/one/run-all.sh" 2>&1); rc=$?
has "a failing serial suite is reported" "$out" "FAIL   test-sbad.sh (exit 4)"
has "a failing serial suite's output is replayed" "$out" "| SERIALBAD"
[ "$rc" -eq 1 ] && ok "a failing serial suite exits 1" || no "failing serial suite exits 1 (rc $rc)"
out=$(sh "$w/one/run-all.sh" sbad 2>&1); has "a filter that matches only a serial suite still runs it" "$out" "test-sbad.sh"

# ---- the profile: RUN_ALL_PROFILE=<file> gets one `suite<TAB>wall_s<TAB>cpu_s<TAB>exit` line per suite.
mkdir "$w/prof"; cp "$w/ser/run-all.sh" "$w/ser/git-isolate.sh" "$w/ser/git-isolated.gitconfig" "$w/prof/"
printf '#!/bin/sh\nsleep 4\n' > "$w/prof/test-sleeper.sh"
printf '#!/bin/sh\ne=$(( $(date +%%s) + 2 ))\nwhile [ "$(date +%%s)" -lt "$e" ]; do :; done\n' > "$w/prof/test-spinner.sh"
printf '#!/bin/sh\nexit 7\n' > "$w/prof/test-failer.sh"
pf="$w/profile.tsv"
RUN_ALL_JOBS=3 RUN_ALL_PROFILE="$pf" sh "$w/prof/run-all.sh" >/dev/null 2>&1
if [ -s "$pf" ]; then
  [ "$(awk "END{print NR}" "$pf")" = 3 ] && ok "profile: one line per suite" || no "profile: one line per suite ($(cat "$pf"))"
  tab=$(printf '\t')
  [ "$(awk -F"$tab" "NF == 4" "$pf" | awk "END{print NR}")" = 3 ] && ok "profile: four tab-separated fields" || no "profile: four tab-separated fields ($(cat "$pf"))"
  longest() { awk -F"$tab" -v c="$1" '$c + 0 > m { m = $c + 0; n = $1 } END { print n }' "$pf"; }
  [ "$(longest 2)" = test-sleeper.sh ] && ok "profile: the sleeper has the longest wall time" || no "profile: wall column ($(cat "$pf"))"
  [ "$(longest 3)" = test-spinner.sh ] && ok "profile: the spinner has the longest CPU time" || no "profile: cpu column ($(cat "$pf"))"
  [ "$(awk -F"$tab" '$1 == "test-failer.sh" { print $4 }' "$pf")" = 7 ] && ok "profile: a failing suite records its exit code" || no "profile: exit column ($(cat "$pf"))"
else
  no "profile: RUN_ALL_PROFILE wrote no file"; no "profile: one"; no "profile: two"; no "profile: three"; no "profile: four"
fi
rm -f "$pf"
RUN_ALL_JOBS=3 sh "$w/prof/run-all.sh" >/dev/null 2>&1
[ ! -e "$pf" ] && ok "profile: unset, nothing is written" || no "profile: file written while unset"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
