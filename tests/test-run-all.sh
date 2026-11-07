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
for tool in sh sed cat basename dirname mktemp xargs getconf rm mkdir date env uname; do
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

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
