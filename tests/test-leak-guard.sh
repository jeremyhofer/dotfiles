#!/bin/sh
# Test leak-guard: the MECHANISM, against a fixture domain with an invented vocabulary.
#
# The guard's patterns, allow rules and push policy are the domain's own files under ~/.dotlocal, so
# nothing here may read the machine's real ones: every case runs under a temp $HOME whose
# .dotlocal holds a fixture markers file, sensitive file, allow file and policy file. The cases
# assert behaviour (diff-based scanning, line numbers, token naming without leaking the pattern,
# allowlist anchoring, escape neutralisation, push delta, fail-closed paths), which holds for any
# vocabulary. What a particular domain's real patterns say is that domain's own suite to test.
#
# Fixture vocabulary: markers are ZZP/ZZQ/... program ids (optionally the -ADR form); the sensitive
# gate blocks hush-term, corp-secret, corp.example, VAULTHOST and `nin`; the allow rule exempts one
# generated lockfile line shape; a push destination is private when it matches the policy's
# private-url. Builds throwaway git repos; no network.
set -eu
# macOS sets TMPDIR WITH a trailing slash, so a naive "$_TMP/x.XXXXXX" yields a
# path containing "//". Harmless for file I/O and fatal the moment such a path is compared
# textually against one a tool reports back normalized. Strip it once, here.
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
base=$(cd "$here/.." && pwd)

# THE fleet-decl UNDER TEST IS THE ONE IN THIS SOURCE TREE, not whatever is deployed.
#
# A `command -v` check cannot see a stale copy: the tool is present, just older than the verbs these
# cases exercise, so "present" passes and the assertions fail with a usage message. Testing source
# code against a deployed dependency reports on a combination that exists on no machine. A
# fixture-local PATH entry pointing at the source copy removes the possibility.
_srcbin=$(mktemp -d "$_TMP/srcbin.XXXXXX")
_fd="$base/private_dot_local/bin/executable_fleet-decl"
[ -f "$_fd" ] || { echo "FAIL: fleet-decl source not found at $_fd"; exit 1; }
ln -sf "$_fd" "$_srcbin/fleet-decl"
PATH="$_srcbin:$PATH"; export PATH
guard="$base/private_dot_local/bin/executable_leak-guard"
runner="$base/private_dot_local/bin/executable_run-repo-gates"
[ -f "$guard" ] && [ -f "$runner" ] || { echo "FAIL: guard or runner source missing under $base"; exit 1; }
tmp=$(mktemp -d "$_TMP/test-leak-guard.XXXXXX"); trap 'rm -rf "$tmp" "$_srcbin"' EXIT
# Shut out the caller's global git config: its configured hooks would otherwise answer for the
# fixture repositories. Cases that need configured hooks set their own GIT_CONFIG_GLOBAL.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# The fixture domain the guard reads (point $HOME at $tmp).
mkdir -p "$tmp/.dotlocal"
printf '# fixture markers: program ids, optionally in the -ADR form\n\\b(ZZP|ZZQ|ZZR|ZZS|ZZT|ZZU)(-ADR)?-[0-9]+\n' \
  > "$tmp/.dotlocal/git-leak-markers"
# `corp\.example` is in the vocabulary because the ALLOWLIST cases need a real sensitive term to
# exempt; `nin` is a term that a string-escape artifact can spell (see the neutralisation cases).
printf 'hush-term|corp-secret|corp\\.example|\\bVAULTHOST\\b|\\bnin\\b\n' > "$tmp/.dotlocal/git-leak-sensitive"
cat > "$tmp/.dotlocal/git-leak-allow" <<'EOF'
# fixture allow rule: one generated lockfile line shape, in one file name, at any depth
(.*/)?package-lock\.json: *"resolved": "https://registry\.corp\.example/api/packages/acme/npm/[^"]*",?
EOF
cat > "$tmp/.dotlocal/git-leak-policy" <<'EOF'
# fixture policy
private-url=(^/srv/private-git/|^ssh://git@private\.example:2222/|private-host\.example|:~owner/(alpha|beta)($|\.git))
probe-marker=ZZP-9999
EOF

newrepo() { d="$tmp/$1"; mkdir -p "$d"; git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t; echo "$d"; }
stage() { printf '%s' "$2" > "$1/f.txt"; git -C "$1" add f.txt; }

# PER-REPO DECLARATIONS COME FROM THE FLEET RECORD, not from the repo's own git config.
# These helpers write that record, so each case declares its repo the way a real fleet does.
#
# The distinction is not cosmetic. A switch the guarded repo can set for itself is not a guard: a
# repo-local `leakguard.policy=internal` or `leakguard.disable=true` used to make the guard exit 0
# before scanning. All three declarations (policy, disable, prefix) are now read from the record,
# which the working session does not own.
#
# A repo with NO entry here is not in the record at all, which is the strictest treatment and
# exactly what an unset value produced before. Several cases below rely on that.
export FLEET_RECORD="$tmp/rec.yaml" FLEET_DEVEL_ROOT="$tmp"
# One seed entry: a record holding only `projects:` is UNUSABLE to fleet-decl (exit 2), which makes
# the guard refuse everything, so a first case expecting a block would pass for that reason alone.
printf 'projects:\n  seed:\n    scope: seed\n' > "$FLEET_RECORD"
_decl() { # repo-dir key value
  _n=$(basename "$1")
  grep -q "^  $_n:" "$FLEET_RECORD" 2>/dev/null \
    || printf '  %s:\n    scope: %s\n' "$_n" "$_n" >> "$FLEET_RECORD"
  printf '    %s: %s\n' "$2" "$3" >> "$FLEET_RECORD"
}
setpolicy() { _decl "$1" leakPolicy "$2"; }
setdisable() { _decl "$1" leakDisable true; }
setprefix() { _decl "$1" leakPrefix "$2"; }
# Run the guard in a repo under the fixture domain: gate <repo> <mode> [args...]
gate() { _r=$1; shift; HOME="$tmp" sh -c "cd '$_r' && sh '$guard' \"\$@\"" guard "$@"; }

# 1) sensitive content in an UNSET-policy repo (treated public) -> BLOCK
r=$(newrepo pub); stage "$r" "uses hush-term here"
if gate "$r" pre-commit; then echo "FAIL: sensitive not blocked in public repo"; exit 1; fi

# 2) same content in a PRIVATE-policy repo -> ALLOW
r=$(newrepo priv); setpolicy "$r" private; stage "$r" "uses hush-term here"
if ! gate "$r" pre-commit; then echo "FAIL: sensitive blocked in private repo"; exit 1; fi

# 3) MARKER in a private repo -> STILL BLOCK (markers block everywhere but notes/internal repos)
r=$(newrepo privm); setpolicy "$r" private; stage "$r" "see ZZQ-69 for detail"
if gate "$r" pre-commit; then echo "FAIL: marker not blocked in private repo"; exit 1; fi

# 4) marker + sensitive in a NOTES-policy repo -> ALLOW (no-op)
r=$(newrepo notes); setpolicy "$r" notes; stage "$r" "ZZQ-69 hush-term VAULTHOST"
if ! gate "$r" pre-commit; then echo "FAIL: notes policy should be exempt"; exit 1; fi

# 4b) marker + sensitive in an INTERNAL-policy repo -> ALLOW (no-op, like notes)
r=$(newrepo internal); setpolicy "$r" internal; stage "$r" "ZZQ-69 hush-term VAULTHOST"
if ! gate "$r" pre-commit; then echo "FAIL: internal policy should be exempt like notes"; exit 1; fi

# 5) disable hatch (declared in the record) -> ALLOW even a public repo with a leak
r=$(newrepo hatch); setdisable "$r"; stage "$r" "hush-term leak"
if ! gate "$r" pre-commit; then echo "FAIL: disable hatch ignored"; exit 1; fi

# 5b) the repo's OWN git config cannot grant itself any of the three. Each was once read with
# `git config --get`, which searches repo-local config first.
r=$(newrepo selfgrant); stage "$r" "ZZQ-69 hush-term"
git -C "$r" config leakguard.policy internal; git -C "$r" config leakguard.disable true
if gate "$r" pre-commit; then echo "FAIL: a repo-local config granted the repo an exemption"; exit 1; fi

# 6) commit-msg mode: marker in the message -> BLOCK
# (msg file named distinctly from the "msg" repo dir itself, else the printf
# redirect collides with the repository directory newrepo just created)
r=$(newrepo msg); printf 'fix ZZQ-69 thing\n' > "$tmp/msg.txt"
if gate "$r" commit-msg "$tmp/msg.txt"; then echo "FAIL: marker in message not blocked"; exit 1; fi

# 7) self-match: staging the pattern FILE names must not trip the guard
r=$(newrepo self); printf '(ZZQ|ZZP)-[0-9]+\n' > "$r/git-leak-markers"; git -C "$r" add git-leak-markers
if ! gate "$r" pre-commit; then echo "FAIL: pattern file self-matched"; exit 1; fi

# 8) path-ignore: a LICENSE carrying a sensitive term must NOT trip
r=$(newrepo lic); printf 'other recipients hush-term\n' > "$r/LICENSE"; git -C "$r" add LICENSE
if ! gate "$r" pre-commit; then echo "FAIL: LICENSE not path-ignored"; exit 1; fi

# 8b) DIFF-BASED: editing a file with PRE-EXISTING leak content, adding only a CLEAN line ->
# ALLOW (scan the staged diff, not the whole blob). Commit the pre-existing leak first (the
# test repo has no installed hook, so a raw commit is fine).
r=$(newrepo diffbased); printf 'pre-existing hush-term line\n' > "$r/doc.md"
git -C "$r" add doc.md; git -C "$r" -c commit.gpgsign=false commit -q --no-verify -m base
printf 'pre-existing hush-term line\na clean added line\n' > "$r/doc.md"; git -C "$r" add doc.md
if ! gate "$r" pre-commit; then echo "FAIL: diff-based should allow a clean edit to a file with pre-existing leaks"; exit 1; fi

# 8c) DIFF-BASED: adding a NEW leak line to that same file -> BLOCK
printf 'pre-existing hush-term line\na clean added line\na new corp-secret leak\n' > "$r/doc.md"; git -C "$r" add doc.md
if gate "$r" pre-commit; then echo "FAIL: diff-based should block a newly-added leak line"; exit 1; fi

# 8d) OUTPUT names the matched TOKEN (not the whole line), and never leaks the pattern vocabulary
r=$(newrepo token); stage "$r" "the marker ZZQ-69 is here"
out=$(gate "$r" pre-commit 2>&1 || true)
printf '%s' "$out" | grep -q 'ZZQ-69' || { echo "FAIL: block output should name the matched token ZZQ-69"; exit 1; }
printf '%s' "$out" | grep -q 'ZZP' && { echo "FAIL: block output leaked the pattern vocabulary"; exit 1; }

# 8e) LINE NUMBERS: a token is reported at its real new-file line (proving it's the STAGED
# addition, not a pre-existing match). `ZZQ-42` on line 2 of a new file -> "...:2:...ZZQ-42".
r=$(newrepo lineno); printf 'clean first line\nhas ZZQ-42 here\n' > "$r/n.txt"; git -C "$r" add n.txt
out=$(gate "$r" pre-commit 2>&1 || true)
printf '%s' "$out" | grep -qE 'n\.txt:2:.*ZZQ-42' || { echo "FAIL: should report ZZQ-42 at n.txt line 2"; exit 1; }

# --- pre-push mode ---
mkpush() { # $1 repo: make one commit whose content/message is $2/$3; echo the sha
  d="$1"; printf '%s' "$3" > "$d/p.txt"; git -C "$d" add p.txt
  # --no-verify: this is TEST SETUP creating fixture content; skip any globally installed hook so
  # the suite does not depend on the machine's live guard state.
  HOME="$tmp" git -C "$d" -c commit.gpgsign=false commit -q --no-verify -m "$2"
  git -C "$d" rev-parse HEAD; }
Z=0000000000000000000000000000000000000000
push() { # <repo> <local sha> <remote sha> <remote name> <url> -> the guard's pre-push verdict
  printf 'refs/heads/main %s refs/heads/main %s\n' "$2" "$3" | gate "$1" pre-push "$4" "$5"; }

# 9) push to a PUBLIC url (not matching the policy) with sensitive content -> BLOCK
r=$(newrepo push_pub); sha=$(mkpush "$r" "ok msg" "has hush-term content")
if push "$r" "$sha" "$Z" origin https://public.example/x/y; then echo "FAIL: sensitive pushed to public not blocked"; exit 1; fi

# 10) same push to a PRIVATE url (matches the policy) -> ALLOW
r=$(newrepo push_priv); setpolicy "$r" private; sha=$(mkpush "$r" "ok msg" "has hush-term content")
if ! push "$r" "$sha" "$Z" priv git@private-host.example:x; then echo "FAIL: sensitive to private url wrongly blocked"; exit 1; fi

# 11) multi-pushurl 'all' remote incl. a public url -> BLOCK sensitive even if the named url is private
r=$(newrepo push_multi); setpolicy "$r" private
git -C "$r" remote add all /srv/private-git/x.git; git -C "$r" config --add remote.all.pushurl /srv/private-git/x.git; git -C "$r" config --add remote.all.pushurl https://public.example/x/y
sha=$(mkpush "$r" "ok" "hush-term content")
if push "$r" "$sha" "$Z" all /srv/private-git/x.git; then echo "FAIL: multi-pushurl public leg not blocked"; exit 1; fi

# 12) MARKER in a pushed commit MESSAGE to a private url -> STILL BLOCK
r=$(newrepo push_mark); setpolicy "$r" private; sha=$(mkpush "$r" "fix ZZQ-69" "clean content")
if push "$r" "$sha" "$Z" priv git@private-host.example:x; then echo "FAIL: marker in pushed message not blocked"; exit 1; fi

# 13) unresolved/unresolvable destination (no pushurl, no remote.url, empty passed-in url) on a
# PRIVATE-policy repo -> still BLOCK sensitive content. Destination keying must fail CLOSED (treat
# as public) when it can't resolve any url at all, not fail OPEN just because the private-policy
# repo would otherwise allow sensitive content.
r=$(newrepo push_unresolved); setpolicy "$r" private
sha=$(mkpush "$r" "ok msg" "has hush-term content")
if push "$r" "$sha" "$Z" '' ''; then echo "FAIL: unresolved destination did not fail closed"; exit 1; fi

# 16b) pre-push scans only the DELTA (base..HEAD), not whole history: sensitive content in an
# ALREADY-pushed commit (at/behind the base) must NOT re-block an otherwise clean push.
r=$(newrepo push_delta_ok)
old_sha=$(mkpush "$r" "old" "has hush-term content")        # already-pushed leak
mkpush "$r" "new clean" "totally clean content" >/dev/null  # clean delta on top
new_sha=$(git -C "$r" rev-parse HEAD)
if ! push "$r" "$new_sha" "$old_sha" origin https://public.example/x/y; then
  echo "FAIL: pre-push re-blocked an already-pushed leak that sits OUTSIDE the delta"; exit 1; fi

# 16c) the mirror: a NEW leak INSIDE the delta must still BLOCK. Without this arm 16b could be
# satisfied by a guard that never blocks anything on push.
r=$(newrepo push_delta_bad)
base_sha=$(mkpush "$r" "base" "clean content")
mkpush "$r" "adds leak" "now has hush-term content" >/dev/null
head_sha=$(git -C "$r" rev-parse HEAD)
if push "$r" "$head_sha" "$base_sha" origin https://public.example/x/y; then
  echo "FAIL: pre-push did not block a NEW leak inside the delta"; exit 1; fi

# 18) missing markers pattern file must fail CLOSED: with git-leak-markers absent from HOME (the
# sensitive file still there, so the domain IS configured), a marker staged in an (implicitly public)
# repo must still BLOCK -- a gate that can't run is a reason to block, not a reason to pass.
nomarkhome="$tmp/nomark-home"; mkdir -p "$nomarkhome/.dotlocal"
cp "$tmp/.dotlocal/git-leak-sensitive" "$nomarkhome/.dotlocal/git-leak-sensitive"
cp "$tmp/.dotlocal/git-leak-policy"    "$nomarkhome/.dotlocal/git-leak-policy"
# (git-leak-markers deliberately NOT copied -- simulates missing/partial apply)
r=$(newrepo nomark); stage "$r" "see ZZQ-69 for detail"
if HOME="$nomarkhome" sh -c "cd '$r' && sh '$guard' pre-commit"; then echo "FAIL: missing markers pattern file failed OPEN (allowed a marker)"; exit 1; fi

# 19) an INACTIVE gate (sensitive, in a private repo) must NOT be forced to fail closed just because
# its file happens to also be missing -- only ACTIVE gates require their pattern file.
nosenshome="$tmp/nosens-home"; mkdir -p "$nosenshome/.dotlocal"
cp "$tmp/.dotlocal/git-leak-markers" "$nosenshome/.dotlocal/git-leak-markers"
cp "$tmp/.dotlocal/git-leak-policy"  "$nosenshome/.dotlocal/git-leak-policy"
# (git-leak-sensitive deliberately NOT copied)
r=$(newrepo nosens); setpolicy "$r" private; stage "$r" "uses hush-term here"
if ! HOME="$nosenshome" sh -c "cd '$r' && sh '$guard' pre-commit"; then echo "FAIL: inactive sensitive gate wrongly blocked on its own missing pattern file"; exit 1; fi

# --- private-url classification, against the fixture policy ---

# 20) a destination in the policy's explicit per-repo list keys PRIVATE
r=$(newrepo push_listed_priv); setpolicy "$r" private; sha=$(mkpush "$r" "ok msg" "has hush-term content")
if ! push "$r" "$sha" "$Z" origin git@git.example.test:~owner/alpha; then echo "FAIL: a listed per-repo destination wrongly blocked (should key private)"; exit 1; fi

# 21) a local-path destination matching the policy keys PRIVATE
r=$(newrepo push_path); setpolicy "$r" private; sha=$(mkpush "$r" "ok msg" "has hush-term content")
if ! push "$r" "$sha" "$Z" origin /srv/private-git/x.git; then echo "FAIL: local private path wrongly blocked (should key private)"; exit 1; fi

# 22) a destination on the SAME host/account but NOT in the list must not match -> keys PUBLIC ->
# sensitive blocked (proves the list is end-anchored per repo, not a host-wide grant)
r=$(newrepo push_listed_pub); sha=$(mkpush "$r" "ok msg" "has hush-term content")
if push "$r" "$sha" "$Z" origin git@git.example.test:~owner/gamma; then echo "FAIL: an unlisted repo on the same account wrongly keyed private"; exit 1; fi
r=$(newrepo push_listed_prefix); sha=$(mkpush "$r" "ok msg" "has hush-term content")
if push "$r" "$sha" "$Z" origin git@git.example.test:~owner/alpha-extra; then echo "FAIL: a listed name with a suffix wrongly keyed private"; exit 1; fi

# 23) an unrelated public destination keys PUBLIC -> sensitive blocked
r=$(newrepo push_other); sha=$(mkpush "$r" "ok msg" "has hush-term content")
if push "$r" "$sha" "$Z" origin https://public.example/x/y; then echo "FAIL: public destination wrongly keyed private"; exit 1; fi

# 24) PERF + line-number fidelity on a LARGE added file. The original scan forked two
# greps PER INPUT LINE (~14s for a single 3.3k-line file; minutes across a fresh repo's
# first push, where every commit is legitimately new -- which read as a hang). This pins
# the batched behavior: a 4k-line add must still name the token at its real line, fast.
r=$(newrepo perf); i=0; : > "$r/big.txt"
while [ "$i" -lt 4000 ]; do printf 'clean line %s\n' "$i" >> "$r/big.txt"; i=$((i+1)); done
printf 'and a ZZQ-77 marker at the end\n' >> "$r/big.txt"
git -C "$r" add big.txt
start=$(date +%s)
out=$(gate "$r" pre-commit 2>&1 || true)
elapsed=$(( $(date +%s) - start ))
printf '%s' "$out" | grep -qE 'big\.txt:4001:.*ZZQ-77' || { echo "FAIL: perf case should report ZZQ-77 at big.txt line 4001"; exit 1; }
[ "$elapsed" -le 5 ] || { echo "FAIL: 4k-line scan took ${elapsed}s (>5s) -- per-line fork regression"; exit 1; }

# 24b) MULTIPLE hits on ONE line are still deduped, sorted, and reported together on a
# single output line (the batched scan groups per line rather than emitting per match).
r=$(newrepo multitok); stage "$r" "ZZQ-77 then ZZQ-12 then ZZQ-77 again"
out=$(gate "$r" pre-commit 2>&1 || true)
printf '%s' "$out" | grep -qE 'f\.txt:1:.*marker: ZZQ-12 ZZQ-77 $' || { echo "FAIL: multi-token line should report deduped+sorted 'ZZQ-12 ZZQ-77'"; exit 1; }
[ "$(printf '%s' "$out" | grep -c 'f\.txt:1:')" = 1 ] || { echo "FAIL: multi-token line should produce exactly one output line"; exit 1; }

# 24c) BOTH gates hitting the same line report marker first, then sensitive.
r=$(newrepo bothgates); stage "$r" "ZZQ-77 uses hush-term here"
out=$(gate "$r" pre-commit 2>&1 || true)
printf '%s' "$out" | grep -qE 'f\.txt:1:  marker: ZZQ-77 +sensitive: hush-term' || { echo "FAIL: both gates on one line should report 'marker: ... sensitive: ...'"; exit 1; }

# --- sensitive ALLOWLIST (git-leak-allow): a narrow, path-anchored exemption ---
# Context: a package manager writes the registry's resolved tarball URL into the lockfile, so a repo
# installing a first-party package cannot otherwise commit its own lockfile. Every case below pins
# that the exemption is NARROW -- the failure mode to fear is an allowlist that quietly permits more
# than the one generated line it was written for.

# The exact line a package manager generates (kept in one place so every case below shares it).
LOCKLINE='      "resolved": "https://registry.corp.example/api/packages/acme/npm/%40acme%2Fcore/-/1.1.0/core-1.1.0.tgz",'
stagefile() { printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"; }

# 25) SEEN TO FAIL -- the baseline control. With NO allow file, the lockfile line BLOCKS.
# Without this, a green case 26 would be indistinguishable from a sensitive pattern that
# never matched the line in the first place.
noallowhome="$tmp/noallow-home"; mkdir -p "$noallowhome/.dotlocal"
cp "$tmp/.dotlocal/git-leak-markers"   "$noallowhome/.dotlocal/git-leak-markers"
cp "$tmp/.dotlocal/git-leak-sensitive" "$noallowhome/.dotlocal/git-leak-sensitive"
cp "$tmp/.dotlocal/git-leak-policy"    "$noallowhome/.dotlocal/git-leak-policy"
# (git-leak-allow deliberately NOT copied)
r=$(newrepo allow_baseline); stagefile "$r" package-lock.json "$LOCKLINE"
if HOME="$noallowhome" sh -c "cd '$r' && sh '$guard' pre-commit"; then echo "FAIL: lockfile registry URL should BLOCK with no allowlist (baseline control)"; exit 1; fi

# 26) WITH the allow file, that same line in package-lock.json is exempt -> ALLOW
r=$(newrepo allow_hit); stagefile "$r" package-lock.json "$LOCKLINE"
if ! gate "$r" pre-commit; then echo "FAIL: allowlisted lockfile registry URL wrongly blocked"; exit 1; fi

# 26b) ...at any depth (a workspace package's own lockfile)
r=$(newrepo allow_nested); mkdir -p "$r/apps/web"; stagefile "$r" apps/web/package-lock.json "$LOCKLINE"
if ! gate "$r" pre-commit; then echo "FAIL: nested package-lock.json not allowlisted"; exit 1; fi

# 27) PATH ANCHORING: the identical line in a NON-lockfile must still BLOCK. This is the
# property that separates "one generated line in one file" from a bare content exemption.
r=$(newrepo allow_wrongpath); stagefile "$r" notes.md "$LOCKLINE"
if gate "$r" pre-commit; then echo "FAIL: allow rule leaked outside package-lock.json"; exit 1; fi

# 28) WHOLE-LINE: a line that merely CONTAINS the allowed shape, with a different host, is not
# described by the rule and must still BLOCK.
r=$(newrepo allow_wronghost)
stagefile "$r" package-lock.json '      "resolved": "https://other.corp.example/api/packages/acme/npm/x/-/x-1.0.0.tgz",'
if gate "$r" pre-commit; then echo "FAIL: allow rule matched a host its pattern does not name"; exit 1; fi

# 29) PER-LINE, NOT PER-FILE: an allowlisted lockfile that ALSO adds an unrelated sensitive
# line must still BLOCK, and must report the leak (not the exempt line).
r=$(newrepo allow_perline)
printf '%s\n  "note": "provisioned with hush-term"\n' "$LOCKLINE" > "$r/package-lock.json"
git -C "$r" add package-lock.json
out=$(gate "$r" pre-commit 2>&1 || true)
printf '%s' "$out" | grep -qE 'package-lock\.json:2:.*hush-term' || { echo "FAIL: exempting one line must not exempt the whole file (expected a hit at line 2)"; exit 1; }
printf '%s' "$out" | grep -q 'package-lock\.json:1:' && { echo "FAIL: the allowlisted line 1 should not be reported"; exit 1; }

# 30) MARKERS ARE NOT ALLOWLISTABLE. A marker embedded INSIDE the URL still satisfies the
# allow rule whole-line (so the sensitive gate is exempt) -- the markers gate must fire anyway.
r=$(newrepo allow_marker)
stagefile "$r" package-lock.json '      "resolved": "https://registry.corp.example/api/packages/acme/npm/ZZQ-69/-/x-1.0.0.tgz",'
out=$(gate "$r" pre-commit 2>&1 || true)
printf '%s' "$out" | grep -q 'ZZQ-69' || { echo "FAIL: markers must NOT be allowlistable -- ZZQ-69 on an exempt line should still block"; exit 1; }
# ...and the sensitive gate WAS exempted on that same line. Without this, the case above
# would also pass if the allow rule had simply failed to match -- green for the wrong reason,
# proving nothing about the markers gate.
printf '%s' "$out" | grep -q 'corp\.example' && { echo "FAIL: sensitive gate should have been exempted on the allowed line (case proves nothing otherwise)"; exit 1; }

# 31) LINE NUMBERS SURVIVE AN EXEMPTION. The guard blanks allowed records rather than dropping
# them; if it dropped them, every reported line after the first exemption would be off by one.
r=$(newrepo allow_lineno)
printf '{\n%s\n  "clean": true,\n  "leak": "hush-term"\n}\n' "$LOCKLINE" > "$r/package-lock.json"
git -C "$r" add package-lock.json
out=$(gate "$r" pre-commit 2>&1 || true)
printf '%s' "$out" | grep -qE 'package-lock\.json:4:.*hush-term' || { echo "FAIL: leak should be reported at line 4; blanking must preserve record count"; exit 1; }

# 32) COMMIT MESSAGES GET NO ALLOWLISTING (no path to key on) -> BLOCK
r=$(newrepo allow_msg); printf 'chore: pin %s\n' "$LOCKLINE" > "$tmp/allowmsg.txt"
if gate "$r" commit-msg "$tmp/allowmsg.txt"; then echo "FAIL: commit message must not be allowlistable"; exit 1; fi

# 33) PRE-PUSH honors the allowlist the same way pre-commit does (public destination).
r=$(newrepo allow_push)
printf '%s\n' "$LOCKLINE" > "$r/package-lock.json"; git -C "$r" add package-lock.json
HOME="$tmp" git -C "$r" -c commit.gpgsign=false commit -q --no-verify -m "add lockfile"
sha=$(git -C "$r" rev-parse HEAD)
if ! push "$r" "$sha" "$Z" origin https://public.example/x/y; then echo "FAIL: pre-push should honor the allowlist"; exit 1; fi

# 34) ESCAPED-NEWLINE ARTIFACT -> ALLOW. Generated single-line files encode line breaks as literal
# "\n"; "...pull it.\n\nIn the end" contains the chars "nIn", which a case-insensitive `nin` branch
# flags although the rendered text has a line break there, not the token. Without neutralisation
# every regeneration of such a file re-trips the gate.
r=$(newrepo esc_fp); stage "$r" 'over the string, grip it, and pull it.\n\nIn the next step'
if ! gate "$r" pre-commit; then echo "FAIL: escaped-newline artifact (nIn) wrongly blocked"; exit 1; fi

# 34b) UNC PATH SURVIVES NEUTRALIZATION -> BLOCK. "\\NIN\share" carries the real token after a
# DOUBLED backslash (a literal backslash, not an escape); the neutralization order ('\\' first, then
# \n/\t/\r) must keep it matchable.
r=$(newrepo esc_unc); stage "$r" 'mount \\NIN\share for backups'
if gate "$r" pre-commit; then echo "FAIL: UNC \\\\NIN leak eaten by escape neutralization"; exit 1; fi

# 34c) ESCAPED TAB before a token -> the token itself still matches ("\tNIN on" must
# not let the \t eat into detection of the adjacent real token).
r=$(newrepo esc_tab); stage "$r" 'first column:\tNIN holds the archive'
if gate "$r" pre-commit; then echo "FAIL: token after escaped tab not blocked"; exit 1; fi

# ---------------------------------------------------------------------------------------
# NO GUARD CONFIGURED: the mechanism ships in the public base and is wired on every machine, so a
# domain that supplies no pattern file must see it do nothing at all. These arms are new with that
# behaviour.
# ---------------------------------------------------------------------------------------
# N1) neither pattern file exists -> a commit carrying a marker AND a sensitive term PASSES.
# $HOME has no .dotlocal at all here, and the record is the fixture one (the repo is strict).
noguardhome="$tmp/noguard-home"; mkdir -p "$noguardhome"
r=$(newrepo noguard); stage "$r" "see ZZQ-69 and hush-term"
if ! HOME="$noguardhome" sh -c "cd '$r' && sh '$guard' pre-commit"; then echo "FAIL: a domain with no pattern files was refused (it configured no guard)"; exit 1; fi
printf 'fix ZZQ-69 thing\n' > "$tmp/noguard-msg.txt"
if ! HOME="$noguardhome" sh -c "cd '$r' && sh '$guard' commit-msg '$tmp/noguard-msg.txt'"; then echo "FAIL: no-guard commit-msg refused"; exit 1; fi
r2=$(newrepo noguard_push); sha=$(mkpush "$r2" "msg ZZQ-69" "content ZZQ-69 hush-term")
if ! printf 'refs/heads/main %s refs/heads/main %s\n' "$sha" "$Z" | HOME="$noguardhome" sh -c "cd '$r2' && sh '$guard' pre-push origin https://public.example/x/y"; then echo "FAIL: no-guard pre-push refused"; exit 1; fi
# an EMPTY .dotlocal directory is still "no pattern file"
mkdir -p "$noguardhome/.dotlocal"
if ! HOME="$noguardhome" sh -c "cd '$r' && sh '$guard' pre-commit"; then echo "FAIL: an empty ~/.dotlocal was treated as a configured guard"; exit 1; fi

# N2) THE CONTROL for N1: the same repo and the same staged content, with only a markers file added,
# BLOCKS. Without it N1 would also pass if the guard never blocked anything.
guardedhome="$tmp/guarded-home"; mkdir -p "$guardedhome/.dotlocal"
cp "$tmp/.dotlocal/git-leak-markers" "$guardedhome/.dotlocal/git-leak-markers"
if HOME="$guardedhome" sh -c "cd '$r' && sh '$guard' pre-commit" 2>&1; then echo "FAIL: same content passed once a markers file existed (N1's control)"; exit 1; fi
# (Either file alone activates it: case 18 above is the sensitive-file-only form.)

# N3) "configured" is decided by EXISTENCE, not content: an emptied markers file is a configured
# domain whose gate cannot run, which refuses. Treating it as "no guard" would turn a truncated file
# into a silent off switch.
emptyhome="$tmp/empty-home"; mkdir -p "$emptyhome/.dotlocal"; : > "$emptyhome/.dotlocal/git-leak-markers"
if HOME="$emptyhome" sh -c "cd '$r' && sh '$guard' pre-commit" 2>/dev/null; then echo "FAIL: an EMPTY markers file was treated as no guard (must fail closed)"; exit 1; fi

# N4) A PRESENT-BUT-PATTERNLESS file (only comments and blank lines, such as a scaffold left behind)
# is a trap if the refusal is vague: it activates the guard, fails closed on every commit, and the
# old message ("missing/empty") did not say which file or what to do. The refusal stays (N3), but
# must name the file, say it holds no patterns, and give both fixes.
commhome="$tmp/comment-home"; mkdir -p "$commhome/.dotlocal"
printf '# only a comment\n\n   \n# and another\n' > "$commhome/.dotlocal/git-leak-markers"
cp "$tmp/.dotlocal/git-leak-policy" "$commhome/.dotlocal/git-leak-policy"
r=$(newrepo commentonly); stage "$r" "innocent text"
cout="$tmp/comment-out.txt"
if HOME="$commhome" sh -c "cd '$r' && sh '$guard' pre-commit" 2> "$cout"; then
  echo "FAIL: a comment-only markers file did not refuse (must fail closed)"; exit 1; fi
for want in "$commhome/.dotlocal/git-leak-markers" "no patterns" "delete the file" "add a pattern"; do
  grep -qF -- "$want" "$cout" || { echo "FAIL: comment-only refusal does not say '$want':"; cat "$cout"; exit 1; }
done
# and the ABSENT form says missing, not "no patterns", so the two causes stay distinguishable
HOME="$nomarkhome" sh -c "cd '$r' && sh '$guard' pre-commit" 2> "$cout" || true
grep -qF "is missing" "$cout" || { echo "FAIL: absent markers file refusal does not say it is missing:"; cat "$cout"; exit 1; }

# CONFIGURED-HOOK FIXTURE. The guard runs as git configured hooks from the base gitconfig. The
# fixture's global config is rebuilt from the SHIPPED entries (extracted, not hand-copied, so a
# changed entry is what gets tested) and $HOME carries the SOURCE guard and runner under
# ~/.local/bin, so these cases test what this tree ships -- never `git config --global`, which would
# touch the real machine. The whole base gitconfig is deliberately not included: it would pull in
# every other hook it declares.
mkdir -p "$tmp/.local/bin"
cp "$guard"  "$tmp/.local/bin/leak-guard"
cp "$runner" "$tmp/.local/bin/run-repo-gates"
: > "$tmp/gcfg"
git config --file "$base/dot_gitconfig" --get-regexp '^hook\.(publish-guard|repo-gates)-' > "$tmp/shipped-hooks"
[ "$(wc -l < "$tmp/shipped-hooks" | tr -d ' ')" = 12 ] || { echo "FAIL: expected 12 shipped hook lines (6 entries x command+event), got: $(cat "$tmp/shipped-hooks")"; exit 1; }
while IFS= read -r line; do
  git config --file "$tmp/gcfg" --add "${line%% *}" "${line#* }"
done < "$tmp/shipped-hooks"
cgit() { # $1 repo, rest: git args, under the configured hooks and nothing else global
  d="$1"; shift; HOME="$tmp" GIT_CONFIG_GLOBAL="$tmp/gcfg" GIT_CONFIG_NOSYSTEM=1 git -C "$d" -c commit.gpgsign=false "$@"; }

# 14) composition: the configured guard AND the repo's own traditional .git/hooks/<name> both run,
# natively, on a real commit -- and a leak is still refused.
r=$(newrepo chain); mkdir -p "$r/.git/hooks"
printf '#!/bin/sh\necho CHAINED >> "%s/chain-proof"\n' "$tmp" > "$r/.git/hooks/pre-commit"; chmod +x "$r/.git/hooks/pre-commit"
stage "$r" "clean content"
cgit "$r" commit -q -m clean || { echo "FAIL: clean commit refused under the configured hooks"; exit 1; }
grep -q CHAINED "$tmp/chain-proof" || { echo "FAIL: the repo's own .git/hooks/pre-commit did not run beside the configured guard"; exit 1; }
stage "$r" "hush-term leak"
if cgit "$r" commit -q -m leak 2>/dev/null; then echo "FAIL: leak not refused by the configured guard on a real commit"; exit 1; fi

# 14b) the shipped entries fire on a real commit with NO guard configured: they pass, and say nothing.
mkdir -p "$noguardhome/.local/bin"; cp "$tmp/.local/bin/leak-guard" "$tmp/.local/bin/run-repo-gates" "$noguardhome/.local/bin/"
r=$(newrepo chain_noguard); stage "$r" "ZZQ-69 hush-term"
out=$(HOME="$noguardhome" GIT_CONFIG_GLOBAL="$tmp/gcfg" GIT_CONFIG_NOSYSTEM=1 git -C "$r" -c commit.gpgsign=false commit -q -m "ZZQ-69 message" 2>&1) \
  || { echo "FAIL: a commit was refused by the shipped hooks in a domain with no guard: $out"; exit 1; }
[ -z "$out" ] || { echo "FAIL: the no-guard path was not silent: $out"; exit 1; }
sed -i.bak "s/\$HOME/\$HOME/" /dev/null 2>/dev/null || true

# --- 35) PROJECT HOOKS: run-repo-gates runs the worktree's own .husky/<name> ---------------------
# The guard is its own configured hook and runs whatever the project hook does. These arms keep the
# properties the runner promises on top of that: node_modules/.bin on PATH, a loud skip with no
# dependencies, the hook's arguments and stdin, and HUSKY=0 skipping the project hook only.
bridgerepo() { # $1 name -> echoes path; a record entry so the runner will run its hooks
  d=$(newrepo "$1"); mkdir -p "$d/.husky" "$d/node_modules/.bin"; _decl "$d" tags "[internal]"; echo "$d"; }

# 35a) A repo with NO .husky/commit-msg is still guarded on the commit-msg event.
r=$(bridgerepo br_nofile); stage "$r" "clean content"
if cgit "$r" commit -q -m "see ZZQ-69 for detail" 2>/dev/null; then
  echo "FAIL: marker in commit message ACCEPTED with no .husky/commit-msg present"; exit 1
fi

# 35b) the project's own hook runs, with node_modules/.bin on PATH
r=$(bridgerepo br_runs)
printf '#!/bin/sh\nprintf HOOKRAN >> "%s/bridge-proof"\ncommand -v fakebin > "%s/bridge-path" || true\n' "$tmp" "$tmp" > "$r/.husky/pre-commit"
printf '#!/bin/sh\nexit 0\n' > "$r/node_modules/.bin/fakebin"; chmod +x "$r/node_modules/.bin/fakebin"
stage "$r" "clean content"
cgit "$r" commit -q -m "clean message" || { echo "FAIL: clean commit refused in the project-hook arm"; exit 1; }
grep -q HOOKRAN "$tmp/bridge-proof" || { echo "FAIL: run-repo-gates did not run .husky/pre-commit"; exit 1; }
grep -q 'node_modules/.bin/fakebin' "$tmp/bridge-path" || { echo "FAIL: run-repo-gates did not prepend node_modules/.bin to PATH"; exit 1; }

# 35c) a FAILING project hook aborts the commit
r=$(bridgerepo br_fails)
printf '#!/bin/sh\nexit 7\n' > "$r/.husky/pre-commit"
stage "$r" "clean content"
if cgit "$r" commit -q -m "clean message" 2>/dev/null; then
  echo "FAIL: commit succeeded although the project pre-commit exited non-zero"; exit 1
fi

# 35d) NO node_modules: the project hook is SKIPPED LOUDLY and the guard still runs.
# The guard is a boundary control whose failure is silent; the project hooks are quality gates
# whose absence is visible in the diff.
r=$(bridgerepo br_nodeps); rm -rf "$r/node_modules"; printf '{}\n' > "$r/package.json"
printf '#!/bin/sh\nprintf SHOULDNOTRUN >> "%s/bridge-skip-proof"\n' "$tmp" > "$r/.husky/pre-commit"
stage "$r" "clean content"
out=$(cgit "$r" commit -q -m "clean message" 2>&1) || { echo "FAIL: no-node_modules commit was refused (should warn and skip)"; exit 1; }
printf '%s' "$out" | grep -q 'skipped' || { echo "FAIL: no-node_modules skip was SILENT (no warning on stderr)"; exit 1; }
[ -f "$tmp/bridge-skip-proof" ] && { echo "FAIL: the project hook ran with no node_modules"; exit 1; }
stage "$r" "hush-term leak"
if cgit "$r" commit -q -m "clean message" 2>/dev/null; then
  echo "FAIL: guard did not run in a worktree with no node_modules"; exit 1
fi

# 35e) pre-push: the project hook receives git's real ref line on stdin, on a real push
r=$(bridgerepo br_push)
printf '#!/bin/sh\ncat >> "%s/bridge-stdin"\n' "$tmp" > "$r/.husky/pre-push"
sha=$(mkpush "$r" "ok msg" "clean content")
git init -q --bare "$tmp/br_push_remote.git"
cgit "$r" push -q "$tmp/br_push_remote.git" HEAD:refs/heads/main 2>/dev/null || { echo "FAIL: clean pre-push refused"; exit 1; }
grep -q "$sha" "$tmp/bridge-stdin" || { echo "FAIL: .husky/pre-push did not receive git's ref line on stdin"; exit 1; }

# 35f) HUSKY=0 skips the PROJECT hook only -- never the fleet guard. --no-verify remains the one
# way past the guard.
r=$(bridgerepo br_husky0)
printf '#!/bin/sh\nprintf SHOULDNOTRUN >> "%s/bridge-husky0-proof"\n' "$tmp" > "$r/.husky/pre-commit"
stage "$r" "clean content"
HUSKY=0 cgit "$r" commit -q -m "clean message" || { echo "FAIL: clean commit refused under HUSKY=0"; exit 1; }
[ -f "$tmp/bridge-husky0-proof" ] && { echo "FAIL: HUSKY=0 did not skip the project hook"; exit 1; }
stage "$r" "hush-term leak"
if HUSKY=0 cgit "$r" commit -q -m "clean message" 2>/dev/null; then
  echo "FAIL: HUSKY=0 skipped the leak-guard -- it must skip the project hook ONLY"; exit 1
fi

# 35g) NEGATIVE CONTROL: the composition discriminates rather than refusing everything.
r=$(bridgerepo br_control)
printf '#!/bin/sh\nexit 0\n' > "$r/.husky/pre-commit"
stage "$r" "totally clean content"
if ! cgit "$r" commit -q -m "a clean message"; then
  echo "FAIL: a clean commit was refused (refuse-everything)"; exit 1
fi
# (Inert and silent at a bare container root is asserted in test-run-repo-gates.sh.)

# ---------------------------------------------------------------------------------------
# OWN-PREFIX EXEMPTION: a repo may carry the identifiers of the program it HOSTS, and no
# others. The permission is granted by the fleet record, never by repo-local config -- a rule a
# guarded repo can grant itself is not a guard.
#
# The negative cases below are the ones that matter. The cheap implementation exempts the
# whole markers gate once any rule matches, which the foreign-prefix cases catch; and an exemption
# mechanism that fails OPEN when its own config is missing unguards every repo at once, silently,
# which the unreadable-record cases catch.
# ---------------------------------------------------------------------------------------

# 20) own prefix in a repo the record grants it to -> ALLOW
r=$(newrepo ownp); setprefix "$r" ZZP; stage "$r" "| ZZP-10 | a row in the project that owns it |"
if ! gate "$r" pre-commit; then
  echo "FAIL: own prefix blocked in the repo the record grants it to"; exit 1; fi

# 20b) own prefix in the PROGRAM-ADR form -> ALLOW (the optional ADR group is still own)
r=$(newrepo ownp_adr); setprefix "$r" ZZP; stage "$r" "see ZZP-ADR-0003 for the rationale"
if ! gate "$r" pre-commit; then
  echo "FAIL: own program-ADR marker blocked in its own repo"; exit 1; fi

# 21) own prefix in the COMMIT MESSAGE -> ALLOW (a message describing the row is the same reference)
r=$(newrepo ownp_msg); setprefix "$r" ZZP; printf 'register: add ZZP-10\n' > "$tmp/own-msg.txt"
if ! gate "$r" commit-msg "$tmp/own-msg.txt"; then
  echo "FAIL: own prefix blocked in a commit message"; exit 1; fi

# 22) FOREIGN prefix in a repo that HAS a grant -> STILL BLOCK. This is the case that proves
#     the exemption is scoped to one prefix rather than disabling the gate.
r=$(newrepo ownp_foreign); setprefix "$r" ZZP; stage "$r" "cross-reference to ZZQ-69 here"
if gate "$r" pre-commit; then
  echo "FAIL: a foreign prefix was allowed in a repo that has an own-prefix grant"; exit 1; fi

# 22b) two grants must not cross-apply: the ZZR repo may not carry ZZP
r=$(newrepo ownr_cross); setprefix "$r" ZZR; stage "$r" "see ZZP-10 for detail"
if gate "$r" pre-commit; then
  echo "FAIL: one repo's grant exempted another repo's prefix"; exit 1; fi

# 23) own-looking prefix in a repo with NO grant -> BLOCK
r=$(newrepo norule); stage "$r" "| ZZP-10 | nothing grants this repo anything |"
if gate "$r" pre-commit; then
  echo "FAIL: a prefix was exempted in a repo with no grant"; exit 1; fi

# 23b) MULTI-PREFIX GRANT, for a repo mid-rename. Both prefixes are granted, which is what lets such
#      a repo write the one sentence recording its own rename.
r=$(newrepo ownboth_new); setprefix "$r" ZZS,ZZT; stage "$r" "| ZZS-04 | the renamed register |"
if ! gate "$r" pre-commit; then
  echo "FAIL: the FIRST prefix of a multi-prefix grant was blocked"; exit 1; fi

r=$(newrepo ownboth_old); setprefix "$r" ZZS,ZZT; stage "$r" "this register was ZZT-04 until the rename"
if ! gate "$r" pre-commit; then
  echo "FAIL: the SECOND prefix of a multi-prefix grant was blocked"; exit 1; fi

# 23c) THE ARM THAT MATTERS: a multi-prefix grant must not become a blanket exemption. A repo
#      granted two prefixes still blocks every OTHER prefix. Without this, "grant a list" and
#      "disable the gate for this repo" are indistinguishable from the passing cases above.
r=$(newrepo ownboth_foreign); setprefix "$r" ZZS,ZZT; stage "$r" "cross-reference to ZZQ-69 here"
if gate "$r" pre-commit; then
  echo "FAIL: a multi-prefix grant exempted a prefix it does not name"; exit 1; fi

# 23d) a single-prefix grant did not silently gain its neighbours' prefixes
r=$(newrepo ownp_notS); setprefix "$r" ZZP; stage "$r" "see ZZS-04 for detail"
if gate "$r" pre-commit; then
  echo "FAIL: a single-prefix repo was granted a prefix from another repo's grant"; exit 1; fi

# 23e) text that merely LOOKS like a prefix list is not parsed as one
r=$(newrepo ownboth_comment); stage "$r" "the word mid-rename-01 is not an id"
if ! gate "$r" pre-commit; then
  echo "FAIL: ordinary hyphenated text was treated as a marker"; exit 1; fi

# 24) the exemption is MARKERS-ONLY: a sensitive term is still blocked on a line that also
#     carries the repo's own prefix.
r=$(newrepo ownp_sens); setprefix "$r" ZZP; stage "$r" "ZZP-10 covers the hush-term rotation"
if gate "$r" pre-commit; then
  echo "FAIL: the own-prefix exemption leaked into the sensitive gate"; exit 1; fi

# 25) a repo DECLARED in the record but granted no prefix -> fail closed.
r=$(newrepo ownp_nogrant); setpolicy "$r" strict; stage "$r" "| ZZP-10 |"
if gate "$r" pre-commit; then
  echo "FAIL: a project with no leakPrefix granted an exemption"; exit 1; fi

# 26) the RECORD ITSELF UNREADABLE -> REFUSE, and refuse LOUDLY rather than falling back.
#     This is the dangerous failure: an unreadable record means every repo is unclassifiable at
#     once, so a guard that treated it as "nothing declared" would silently drop to its default
#     fleet-wide, on every commit, with nothing to see.
r=$(newrepo recbroken); stage "$r" "| ZZP-10 |"
printf 'projects: [not a map\n' > "$tmp/broken.yaml"
out=$(HOME="$tmp" FLEET_RECORD="$tmp/broken.yaml" sh -c "cd '$r' && sh '$guard' pre-commit" 2>&1) && {
  echo "FAIL: an unreadable record did not refuse"; exit 1; }
case "$out" in
  *"record is unusable"*) : ;;
  *) echo "FAIL: refused without saying the record was unusable: $out"; exit 1 ;;
esac
out=$(HOME="$tmp" FLEET_RECORD="$tmp/absent.yaml" sh -c "cd '$r' && sh '$guard' pre-commit" 2>&1) && {
  echo "FAIL: a missing record did not refuse"; exit 1; }

# 26a) a repo ABSENT from the record gets the strictest treatment, which is what an unset
#      declaration produced before. This is the ordinary case, and it must NOT be a refusal.
r=$(newrepo notinrecord); stage "$r" "| ZZP-10 |"
if gate "$r" pre-commit; then
  echo "FAIL: a repo absent from the record was granted an exemption"; exit 1; fi

echo PASS
