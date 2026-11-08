#!/bin/sh
# Test: .githooks/pre-push gates a push to the publish remote on setup/publish-check, and leaves
# every other push alone. Real `git push` runs, with core.hooksPath pointed at the hook, into local
# bare repositories; publish-check is a stub whose exit status the case sets, so a planted defect is
# a failing check, and its log shows whether it ran at all.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/git-isolate.sh"
HOOK="$HERE/../.githooks/pre-push"
_t=${TMPDIR:-/tmp}; _t=${_t%/}
T=$(mktemp -d "$_t/ppush.XXXXXX"); trap 'rm -rf "$T"' EXIT
fail=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
git init -q --bare "$T/forge.git"; git init -q --bare "$T/public.git"
g init -q -b main "$T/w"
mkdir -p "$T/w/setup" "$T/w/.githooks"
cp "$HOOK" "$T/w/.githooks/pre-push"
cat > "$T/w/setup/publish-check" <<'STUB'
#!/bin/sh
echo "publish-check ran: $*" >> "$PC_LOG"
exit "$(cat "$PC_RC")"
STUB
printf 'x\n' > "$T/w/f"
g -C "$T/w" add -A; g -C "$T/w" commit -q -m one
g -C "$T/w" remote add origin "$T/forge.git"
g -C "$T/w" remote add pub "$T/public.git"
g -C "$T/w" config dotfiles.publishRemote pub
export PC_LOG="$T/pc.log" PC_RC="$T/pc.rc"
push() { : > "$PC_LOG"; g -C "$T/w" -c core.hooksPath="$T/w/.githooks" push -q "$@" > "$T/out" 2>&1; }

echo 1 > "$PC_RC"
push pub main && bad "a push to the publish remote with a failing publish-check was accepted" \
  || ok "a push to the publish remote with a failing publish-check is refused"
[ -s "$PC_LOG" ] && ok "...and publish-check ran for it" || bad "publish-check did not run: $(cat "$T/out")"
git --git-dir="$T/public.git" rev-parse -q --verify refs/heads/main > /dev/null \
  && bad "the refused push still reached the publish remote" || ok "...and nothing reached the publish remote"

push origin main && ok "the same push to another remote passes though publish-check would fail" \
  || bad "a push to origin was refused: $(cat "$T/out")"
[ ! -s "$PC_LOG" ] && ok "...and publish-check did not run for it" || bad "publish-check ran for a forge push"

echo 0 > "$PC_RC"
push pub main && ok "a push to the publish remote with a passing publish-check goes through" \
  || bad "a passing publish-check still refused: $(cat "$T/out")"
grep -q -- '--remote pub' "$PC_LOG" && ok "...publish-check judged the publish remote" || bad "publish-check args: $(cat "$PC_LOG")"

echo 1 > "$PC_RC"; printf 'y\n' > "$T/w/f"; g -C "$T/w" commit -q -am two
push "$T/public.git" main && bad "a push by URL to the publish remote skipped the gate" \
  || ok "a push naming the publish remote by URL is gated too"

echo 0 > "$PC_RC"; g -C "$T/w" branch -q topic
push pub topic && bad "a non-main ref was published" || ok "only main is published"
[ ! -s "$PC_LOG" ] && ok "...refused before publish-check ran" || bad "publish-check ran for a refused ref"

g -C "$T/w" config --unset dotfiles.publishRemote; echo 1 > "$PC_RC"
push pub main && ok "with no publish remote configured nothing is gated" || bad "gated with no publish remote: $(cat "$T/out")"

[ "$fail" = 0 ] && { echo PASS; exit 0; } || { echo FAILURES; exit 1; }
