#!/bin/sh
# test-wt-bootstrap.sh — contract tests for the worktree dependency-install hook.
#
# Never runs a real package manager: every "pnpm"/"npm"/"yarn"/"bun"/"uv" the tool sees here is
# a STUB placed on an isolated PATH that only records its own invocation (name + argv) to a log
# file and exits with a chosen code. That is what lets these tests assert EXACTLY which single
# command ran, in which order, and that a failing install's exit status survives -- without ever
# touching the network or resolving a real lockfile.
#
# PATH is restricted to the stub directory alone for every case (no system PATH at all), so a
# package manager that was not explicitly stubbed is genuinely absent -- matching the
# "not on PATH" case for real, rather than quietly falling through to whatever happens to be
# installed on the machine running the suite.
#
# Run: sh ~/.local/share/chezmoi/tests/test-wt-bootstrap.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
bs="$here/../private_dot_local/bin/executable_wt-bootstrap"
sh_bin=$(command -v sh)

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
n=0

# new_case -- sets up WD (the fake worktree), STUBS (isolated bin dir) and LOG (call record)
# for one test case. Every case gets fresh directories so cases cannot see each other's state.
new_case() {
  n=$((n + 1))
  WD="$work/wd$n"; STUBS="$work/stubs$n"
  mkdir -p "$WD" "$STUBS"
  LOG="$work/log$n"
  : > "$LOG"
}

# stub NAME [EXITCODE] -- installs a fake NAME on $STUBS that appends "NAME argv..." to $LOG
# and exits EXITCODE (default 0). Never invokes the real tool of that name.
stub() {
  name="$1"; code="${2:-0}"
  cat > "$STUBS/$name" <<STUBEOF
#!/bin/sh
printf '%s %s\n' "$name" "\$*" >> "$LOG"
exit $code
STUBEOF
  chmod +x "$STUBS/$name"
}

# run -- executes wt-bootstrap against $WD, PATH narrowed to $STUBS only. Sets $out (stdout +
# stderr merged) and $rc (exit status).
run() {
  out=$( (PATH="$STUBS"; export PATH; "$sh_bin" "$bs" -C "$WD") 2>&1 )
  rc=$?
}

calls() { cat "$LOG" 2>/dev/null; }

echo "== pnpm-lock.yaml -> pnpm install --frozen-lockfile, and only that =="
new_case; : > "$WD/pnpm-lock.yaml"; stub pnpm
run
eq "exits 0" "$rc" "0"
eq "runs exactly the pnpm frozen install" "$(calls)" "pnpm install --frozen-lockfile"

echo "== package-lock.json -> npm ci =="
new_case; : > "$WD/package-lock.json"; stub npm
run
eq "exits 0" "$rc" "0"
eq "runs exactly npm ci" "$(calls)" "npm ci"

echo "== yarn.lock -> yarn install --immutable =="
new_case; : > "$WD/yarn.lock"; stub yarn
run
eq "exits 0" "$rc" "0"
eq "runs exactly the yarn immutable install" "$(calls)" "yarn install --immutable"

echo "== bun.lock -> bun install --frozen-lockfile =="
new_case; : > "$WD/bun.lock"; stub bun
run
eq "exits 0" "$rc" "0"
eq "runs exactly the bun frozen install" "$(calls)" "bun install --frozen-lockfile"

echo "== bun.lockb (binary lockfile, no bun.lock) is recognized too =="
new_case; : > "$WD/bun.lockb"; stub bun
run
eq "exits 0" "$rc" "0"
eq "runs exactly the bun frozen install" "$(calls)" "bun install --frozen-lockfile"

echo "== uv.lock -> uv sync --frozen =="
new_case; : > "$WD/uv.lock"; stub uv
run
eq "exits 0" "$rc" "0"
eq "runs exactly the uv frozen sync" "$(calls)" "uv sync --frozen"

echo "== no lockfile at all -> no calls, exit 0 =="
new_case
run
eq "exits 0" "$rc" "0"
eq "nothing was invoked" "$(calls)" ""

echo "== two JS lockfiles -> refused as ambiguous, nothing runs =="
new_case; : > "$WD/pnpm-lock.yaml"; : > "$WD/package-lock.json"; stub pnpm; stub npm
run
[ "$rc" -ne 0 ] && ok "exits non-zero" || bad "exits non-zero (got 0)"
eq "neither package manager was invoked" "$(calls)" ""
case "$out" in
  *ambiguous*) ok "message says ambiguous" ;;
  *) bad "message says ambiguous (got: $out)" ;;
esac

echo "== a JS lockfile plus uv.lock -> both run, JavaScript first =="
new_case; : > "$WD/pnpm-lock.yaml"; : > "$WD/uv.lock"; stub pnpm; stub uv
run
eq "exits 0" "$rc" "0"
first=$(calls | sed -n '1p'); second=$(calls | sed -n '2p')
eq "pnpm ran first" "$first" "pnpm install --frozen-lockfile"
eq "uv ran second" "$second" "uv sync --frozen"

echo "== needed package manager missing from PATH -> non-zero, names it =="
new_case; : > "$WD/pnpm-lock.yaml"   # deliberately: no `stub pnpm`
run
[ "$rc" -ne 0 ] && ok "exits non-zero" || bad "exits non-zero (got 0)"
case "$out" in
  *pnpm*) ok "message names pnpm" ;;
  *) bad "message names pnpm (got: $out)" ;;
esac
eq "nothing was invoked (pnpm never existed to call)" "$(calls)" ""

echo "== a failing install's exit status is propagated =="
new_case; : > "$WD/package-lock.json"; stub npm 3
run
eq "wt-bootstrap exits with the failing install's own status" "$rc" "3"
eq "the failing install did run" "$(calls)" "npm ci"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
