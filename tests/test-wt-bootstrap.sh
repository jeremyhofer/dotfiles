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
# HOME is a fresh directory per case too, so whether the machine is switched to mise is decided
# only by the chezmoi config a case writes there (switch_mise), never by the real machine's.
# "mise" is a stub like the others, which also prints a chosen `mise ls` answer; the real mise is
# never run, so nothing is ever installed.
#
# Run: sh ~/.local/share/chezmoi/tests/test-wt-bootstrap.sh
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}   # explicit mktemp templates: macOS mktemp ignores TMPDIR
set -u

here=$(cd "$(dirname "$0")" && pwd)
bs="$here/../private_dot_local/bin/executable_wt-bootstrap"
sh_bin=$(command -v sh)

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

work=$(mktemp -d "$_TMP/test-wt-bootstrap.XXXXXX")
trap 'rm -rf "$work"' EXIT
n=0

# new_case -- sets up WD (the fake worktree), STUBS (isolated bin dir) and LOG (call record)
# for one test case. Every case gets fresh directories so cases cannot see each other's state.
new_case() {
  n=$((n + 1))
  WD="$work/wd$n"; STUBS="$work/stubs$n"; HOME_DIR="$work/home$n"
  mkdir -p "$WD" "$STUBS" "$HOME_DIR"
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

# stub_mise ANSWER [EXITCODE] -- a fake mise that records its call like stub() and prints ANSWER
# (a `mise ls` table, one row per line) to stdout.
stub_mise() {
  printf '%s\n' "$1" > "$STUBS/mise.answer"
  cat > "$STUBS/mise" <<STUBEOF
#!/bin/sh
printf 'mise %s\n' "\$*" >> "$LOG"
while IFS= read -r line; do [ -n "\$line" ] && printf '%s\n' "\$line"; done < "$STUBS/mise.answer"
exit ${2:-0}
STUBEOF
  chmod +x "$STUBS/mise"
}

# switch_mise VALUE -- writes the case's generated chezmoi config with miseActive = VALUE.
switch_mise() {
  mkdir -p "$HOME_DIR/.config/chezmoi"
  printf '[data]\n    domain = "personal"\n    miseActive = %s\n' "$1" > "$HOME_DIR/.config/chezmoi/chezmoi.toml"
}

# run -- executes wt-bootstrap against $WD, PATH narrowed to $STUBS only and HOME to the case's
# own. Sets $out (stdout + stderr merged) and $rc (exit status).
run() {
  out=$( (PATH="$STUBS"; HOME="$HOME_DIR"; export PATH HOME; unset XDG_CONFIG_HOME; "$sh_bin" "$bs" -C "$WD") 2>&1 )
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

# --- mise: a switched machine reports a missing version, and never installs it -------------
missing_row='node    26.13.0 (missing)  /w/.nvmrc  26.13.0'
asked='mise ls --current --missing --no-header'
installs() { grep -c '^mise install' "$LOG"; }
reports() { printf '%s\n' "$out" | grep -c "mise install"; }

echo "== switched to mise, a pinned version not installed -> one report line naming mise install =="
new_case; switch_mise true; : > "$WD/package-lock.json"; stub npm; stub_mise "$missing_row"
run
eq "exits 0 (the report does not fail the hook)" "$rc" "0"
eq "mise was asked which versions are missing, then npm ci ran" "$(calls)" "$asked
npm ci"
eq "mise install was never run" "$(installs)" "0"
eq "exactly one line names mise install" "$(reports)" "1"
case "$out" in
  *"node@26.13.0"*) ok "the report names the missing version" ;;
  *) bad "the report names the missing version (got: $out)" ;;
esac
eq "the report comes before the install" "$(printf '%s\n' "$out" | sed -n '1p' | grep -c 'mise install')" "1"

echo "== switched to mise, nothing missing -> asked once, nothing reported =="
new_case; switch_mise true; stub_mise ""
run
eq "exits 0" "$rc" "0"
eq "mise was asked, and nothing else ran" "$(calls)" "$asked"
eq "nothing was printed" "$out" ""

echo "== not switched (no chezmoi config), mise on PATH -> mise never called, as before =="
new_case; stub_mise "$missing_row"
run
eq "exits 0" "$rc" "0"
eq "nothing was invoked" "$(calls)" ""
eq "nothing was printed" "$out" ""

echo "== miseActive = false, mise on PATH -> mise never called, as before =="
new_case; switch_mise false; : > "$WD/package-lock.json"; stub npm; stub_mise "$missing_row"
run
eq "exits 0" "$rc" "0"
eq "only npm ci ran" "$(calls)" "npm ci"
eq "only the install line was printed" "$out" "wt-bootstrap: npm ci"

echo "== switched, mise ls fails -> says so, installs still run, exit 0 =="
new_case; switch_mise true; : > "$WD/package-lock.json"; stub npm; stub_mise "" 2
run
eq "exits 0" "$rc" "0"
eq "mise was asked, then npm ci ran" "$(calls)" "$asked
npm ci"
case "$out" in
  *"could not list"*) ok "the failure is reported" ;;
  *) bad "the failure is reported (got: $out)" ;;
esac

echo "== switched, mise not on PATH -> one line naming it, exit 0 =="
new_case; switch_mise true
run
eq "exits 0" "$rc" "0"
case "$out" in
  *"mise not found on PATH"*) ok "the message names mise" ;;
  *) bad "the message names mise (got: $out)" ;;
esac

# --- several -C directories: each is installed in the order given -------------------------
# These stubs also record the directory they ran in (its basename), so the order of DIRECTORIES
# is asserted, not only the order of commands.
stub_pwd() {  # NAME [EXITCODE]
  name="$1"; code="${2:-0}"
  cat > "$STUBS/$name" <<STUBEOF
#!/bin/sh
printf '%s %s @%s\n' "$name" "\$*" "\${PWD##*/}" >> "$LOG"
exit $code
STUBEOF
  chmod +x "$STUBS/$name"
}
# runm ARGS... -- like run, but with the arguments given (-C DIR, repeated).
runm() {
  out=$( (PATH="$STUBS"; HOME="$HOME_DIR"; export PATH HOME; unset XDG_CONFIG_HOME
          "$sh_bin" "$bs" "$@") 2>&1 )
  rc=$?
}

echo "== two -C directories -> both installed, in the order given =="
new_case; mkdir "$WD/front" "$WD/other"; : > "$WD/package-lock.json"; : > "$WD/front/pnpm-lock.yaml"; : > "$WD/other/uv.lock"
stub_pwd npm; stub_pwd pnpm; stub_pwd uv
runm -C "$WD" -C "$WD/front" -C "$WD/other"
eq "exits 0" "$rc" "0"
eq "root, then front, then other" "$(calls | tr '\n' '|')" "npm ci @wd$n|pnpm install --frozen-lockfile @front|uv sync --frozen @other|"
case "$out" in
  *"$WD/front"*) ok "messages name the directory" ;;
  *) bad "messages name the directory (got: $out)" ;;
esac

echo "== the order given is the order run (reversed) =="
new_case; mkdir "$WD/front"; : > "$WD/package-lock.json"; : > "$WD/front/pnpm-lock.yaml"
stub_pwd npm; stub_pwd pnpm
runm -C "$WD/front" -C "$WD"
eq "front first, then root" "$(calls | tr '\n' '|')" "pnpm install --frozen-lockfile @front|npm ci @wd$n|"

echo "== a failure in the first directory stops the rest, with that exit status =="
new_case; mkdir "$WD/front"; : > "$WD/package-lock.json"; : > "$WD/front/pnpm-lock.yaml"
stub_pwd npm 3; stub_pwd pnpm
runm -C "$WD" -C "$WD/front"
eq "exits with the failing install's status" "$rc" "3"
eq "the second directory never ran" "$(calls | tr '\n' '|')" "npm ci @wd$n|"

echo "== a failure in the second directory propagates its status =="
new_case; mkdir "$WD/front"; : > "$WD/package-lock.json"; : > "$WD/front/pnpm-lock.yaml"
stub_pwd npm; stub_pwd pnpm 4
runm -C "$WD" -C "$WD/front"
eq "exits with the second install's status" "$rc" "4"
eq "both ran" "$(calls | tr '\n' '|')" "npm ci @wd$n|pnpm install --frozen-lockfile @front|"

echo "== with several -C, a missing directory is reported and skipped; the rest still install =="
new_case; mkdir "$WD/other"; : > "$WD/package-lock.json"; : > "$WD/other/uv.lock"; stub_pwd npm; stub_pwd uv
runm -C "$WD" -C "$WD/nosuchdir" -C "$WD/other"
eq "exit status is unaffected" "$rc" "0"
eq "the directories around it were installed" "$(calls | tr '\n' '|')" "npm ci @wd$n|uv sync --frozen @other|"
case "$out" in
  *"wt-bootstrap: $WD/nosuchdir: not a directory here, skipped"*) ok "the skip is reported, naming the directory" ;;
  *) bad "the skip is reported, naming the directory (got: $out)" ;;
esac
new_case; : > "$WD/package-lock.json"; stub_pwd npm
runm -C "$WD/nosuchdir" -C "$WD"
eq "a missing first directory is skipped too" "$rc" "0"
eq "and the next one installs" "$(calls | tr '\n' '|')" "npm ci @wd$n|"

echo "== a single missing -C is still refused, exit 1 =="
new_case; stub npm
runm -C "$WD/nosuchdir"
eq "exits 1" "$rc" "1"
case "$out" in
  *"not a directory: $WD/nosuchdir"*) ok "message names the directory" ;;
  *) bad "message names the directory (got: $out)" ;;
esac

echo "== an ambiguous second directory is refused and named =="
new_case; mkdir "$WD/front"; : > "$WD/front/pnpm-lock.yaml"; : > "$WD/front/package-lock.json"; stub_pwd pnpm; stub_pwd npm
runm -C "$WD" -C "$WD/front"
[ "$rc" -ne 0 ] && ok "exits non-zero" || bad "exits non-zero (got 0)"
case "$out" in
  *"$WD/front"*ambiguous*|*ambiguous*"$WD/front"*) ok "message names the directory" ;;
  *) bad "message names the directory (got: $out)" ;;
esac

echo "== a single -C prints no directory prefix (unchanged output) =="
new_case; : > "$WD/package-lock.json"; stub npm
run
eq "output is exactly the one action line" "$out" "wt-bootstrap: npm ci"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
