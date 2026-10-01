#!/bin/sh
# Test hook-doctor: every acceptance criterion is a MANUFACTURED defect.
#
# WHY EACH ONE EXISTS. A coverage tool that cannot be made to report a hole is indistinguishable
# from a fleet that has none, and it fails in the direction that invites a false all-clear. So every
# case below breaks something real and asserts the tool NOTICES -- and the per-event cases assert it
# notices at the RESOLUTION its claim is stated at: one event disabled is named alone.
#
# The guard is git configured hooks. The global config here is a fixture rebuilt from the entries
# the SOURCE base gitconfig ships, and the fixture $HOME carries the SOURCE leak-guard,
# run-repo-gates and git-secret-scan, so the suite tests what this tree ships, not what this machine
# has applied. The guard's domain (markers, sensitive terms, policy with its probe-marker=) is a
# fixture with an invented vocabulary too: nothing here reads the machine's real ~/.dotlocal.
#
# Builds throwaway git repos; no network. Needs git 2.54+ and gitleaks.
#
# NOT `set -e`, deliberately. Half the assertions EXPECT hook-doctor to exit non-zero -- 1 on a
# found hole, 2 on refusing to report -- so `-e` would abort the run exactly when a case passes.
set -u
_TMP=${TMPDIR:-/tmp}; _TMP=${_TMP%/}
here=$(cd "$(dirname "$0")" && pwd)
base=$(cd "$here/.." && pwd)
doctor="$base/private_dot_local/bin/executable_hook-doctor"
tmp=$(mktemp -d "$_TMP/test-hook-doctor.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
fails=0

ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }
want() { # <label> <expected-substring> <actual>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain '$2'; got: $(printf '%s' "$3" | tr '\n' ' ' | cut -c1-300)" ;; esac
}
lacks() { # <label> <forbidden-substring> <actual>
  case "$3" in *"$2"*) bad "$1" "must not contain '$2'; got: $(printf '%s' "$3" | tr '\n' ' ' | cut -c1-300)" ;; *) ok "$1" ;; esac
}
# The caller's own global git config is shut out: its configured hooks would otherwise run on this
# suite's fixture commits, and read the machine's real guard files.
git_q() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

# fleet-decl is the SOURCE copy, never a deployed one (which can predate it).
mkdir -p "$tmp/srcbin"
ln -sf "$base/private_dot_local/bin/executable_fleet-decl" "$tmp/srcbin/fleet-decl"
PATH="$tmp/srcbin:$PATH"; export PATH
command -v gitleaks >/dev/null 2>&1 || { bad "gitleaks on PATH" "git-secret-scan refuses every commit without it"; exit 1; }

# --- fixtures -------------------------------------------------------------------------------------
fh="$tmp/home"; mkdir -p "$fh/.dotlocal" "$fh/.local/bin" "$fh/.config/gitleaks"
for s in leak-guard run-repo-gates git-secret-scan; do
  cp "$base/private_dot_local/bin/executable_$s" "$fh/.local/bin/$s"; chmod +x "$fh/.local/bin/$s"
done
[ -r "$base/dot_config/gitleaks/floor.toml" ] || { bad "the secret scan's floor config" "missing at $base/dot_config/gitleaks/floor.toml"; exit 1; }
cp "$base/dot_config/gitleaks/floor.toml" "$fh/.config/gitleaks/floor.toml"
printf '\\b(ZZP|ZZQ|ZZR)(-ADR)?-[0-9]+\n' > "$fh/.dotlocal/git-leak-markers"
printf 'hush-term|corp-secret\n' > "$fh/.dotlocal/git-leak-sensitive"
printf 'private-url=private-host\\.example\nprobe-marker=ZZP-9999\n' > "$fh/.dotlocal/git-leak-policy"
# Global configs rebuilt from the SHIPPED entries (not the whole base gitconfig, which would pull in
# its other hooks): the guard + runner entries, and separately the secret scan's.
: > "$tmp/gcfg"
git config --file "$base/dot_gitconfig" --get-regexp '^hook\.(publish-guard|repo-gates)-' > "$tmp/shipped-guard"
git config --file "$base/dot_gitconfig" --get-regexp '^hook\.secret-scan\.' > "$tmp/shipped-scan"
[ "$(wc -l < "$tmp/shipped-guard" | tr -d ' ')" = 12 ] && [ "$(wc -l < "$tmp/shipped-scan" | tr -d ' ')" = 2 ] \
  || { bad "shipped hook entries" "guard: $(cat "$tmp/shipped-guard") / scan: $(cat "$tmp/shipped-scan")"; exit 1; }
while IFS= read -r line; do git config --file "$tmp/gcfg" --add "${line%% *}" "${line#* }"; done < "$tmp/shipped-guard"
cp "$tmp/gcfg" "$tmp/gcfg-noscan"
while IFS= read -r line; do git config --file "$tmp/gcfg" --add "${line%% *}" "${line#* }"; done < "$tmp/shipped-scan"
: > "$tmp/gcfg-empty"
devel="$tmp/fleet"; mkdir -p "$devel"

manifest() { # <path under $devel>... -> a fixture manifest whose entries resolve (path + scope)
  printf 'projects:\n' > "$tmp/mani.yaml"
  for p in "$@"; do printf '  p%s:\n    path: %s\n    scope: %s\n' "$(basename "$p")" "$p" "$p" >> "$tmp/mani.yaml"; done
}
run() { # <global config> <args...> -> output, then " rc=<n>". RUNHOME and OVR_MARKER tune one call.
  gc=$1; shift
  HOME="${RUNHOME:-$fh}" GIT_CONFIG_GLOBAL="$gc" GIT_CONFIG_NOSYSTEM=1 \
    HOOK_DOCTOR_MARKER="${OVR_MARKER:-}" \
    HOOK_DOCTOR_MANIFEST="$tmp/mani.yaml" HOOK_DOCTOR_DEVEL_ROOT="$devel" \
    FLEET_RECORD="$tmp/mani.yaml" FLEET_DEVEL_ROOT="$devel" \
    HOOK_DOCTOR_CHEZMOI_SRC=/nonexistent HOOK_DOCTOR_OVERLAY_SRC=/nonexistent \
    sh "$doctor" "$@" 2>&1; printf ' rc=%s' "$?"
}
newrepo() { # <path under $devel> -> a repo with one commit
  d="$devel/$1"; mkdir -p "$d"; git_q init -q "$d"
  ( cd "$d" && printf 'x\n' > f && git_q add f && git_q commit -qm init ) >/dev/null 2>&1
  printf '%s' "$d"
}

printf 'hook-doctor acceptance criteria\n'

# --- P1: every event guarded -> GUARDED, exit 0 -------------------------------------------------
k=$(newrepo work/k); manifest work/k
before=$(cd "$k" && git_q count-objects -v | tr '\n' ' '; git_q status --porcelain; git_q for-each-ref; ls -l .git/index)
p1=$(run "$tmp/gcfg" check)
want "P1 all three events guarded" "GUARDED 1 " "$p1"
want "P1 exit 0" " rc=0" "$p1"

# --- P2: probing writes nothing to the repository ------------------------------------------------
after=$(cd "$k" && git_q count-objects -v | tr '\n' ' '; git_q status --porcelain; git_q for-each-ref; ls -l .git/index)
[ "$before" = "$after" ] && ok "P2 repository untouched (objects, index, refs, status)" || bad "P2 repository untouched" "before: $before / after: $after"

# --- P3: ONE event disabled locally -> DARK naming only that event, exit 1 ------------------------
git_q -C "$k" config hook.publish-guard-pre-push.enabled false
p3=$(run "$tmp/gcfg" check)
want "P3 one event disabled -> DARK" "DARK — fail-open" "$p3"
want "P3 names pre-push" "pre-push (planted" "$p3"
lacks "P3 does not name commit-msg" "commit-msg (planted" "$p3"
lacks "P3 does not name pre-commit" "pre-commit (planted" "$p3"
want "P3 exit 1" " rc=1" "$p3"
git_q -C "$k" config --unset hook.publish-guard-pre-push.enabled

# --- P4: the guard's command redefined locally -> DARK on that event ----------------------------
git_q -C "$k" config hook.publish-guard-pre-commit.command true
want "P4 command replaced -> DARK on pre-commit" "pre-commit (planted" "$(run "$tmp/gcfg" check)"
git_q -C "$k" config --unset hook.publish-guard-pre-commit.command

# --- P5: every hook for one event switched off at the event level -> DARK -----------------------
git_q -C "$k" config hook.commit-msg.enabled false
want "P5 hook.<event>.enabled=false -> DARK" "commit-msg (planted" "$(run "$tmp/gcfg" check)"
git_q -C "$k" config --unset hook.commit-msg.enabled

# --- P6: a refusal by something OTHER than the guard is not coverage -----------------------------
# The guard entry is off, and a local hook refuses only messages carrying the marker. The planted
# probe IS refused -- by the wrong thing -- and must still read DARK.
git_q -C "$k" config hook.publish-guard-commit-msg.enabled false
# git appends "$@" to a configured hook's command, so the logic sits in a function that receives it.
git_q -C "$k" config hook.lookalike.command 'f() { grep -q ZZP- "$1" && exit 1; exit 0; }; f'
git_q -C "$k" config --add hook.lookalike.event commit-msg
want "P6 non-guard refusal -> DARK" "commit-msg (planted rc=1, OTHER)" "$(run "$tmp/gcfg" check)"
git_q -C "$k" config --remove-section hook.lookalike
git_q -C "$k" config --unset hook.publish-guard-commit-msg.enabled

# --- P7: the repo's OWN refusing hook does not decide the verdict -------------------------------
# A traditional hook refusing everything used to make the dispatcher probe BLOCKED. The guard's
# verdict is about the guard; the probe excludes the repo's hooks.
mkdir -p "$k/.git/hooks"; printf '#!/bin/sh\nexit 1\n' > "$k/.git/hooks/commit-msg"; chmod +x "$k/.git/hooks/commit-msg"
want "P7 repo's own refusing hook -> still GUARDED" "GUARDED 1 " "$(run "$tmp/gcfg" check)"
rm -f "$k/.git/hooks/commit-msg"

# --- P8: a guard that refuses a CLEAN input -> BLOCKED, not DARK --------------------------------
# The leak-guard refuses to classify a repo when the fleet record is unusable: fail-closed.
printf 'projects: [unclosed\n' > "$tmp/unusable.yaml"
p8=$(HOME="$fh" GIT_CONFIG_GLOBAL="$tmp/gcfg" GIT_CONFIG_NOSYSTEM=1 FLEET_RECORD="$tmp/unusable.yaml" \
     FLEET_DEVEL_ROOT="$devel" sh "$doctor" check --path "$k" 2>&1; printf ' rc=%s' "$?")
want "P8 guard refusing clean input -> BLOCKED" "BLOCKED" "$p8"
lacks "P8 not reported DARK" "DARK" "$p8"

# --- I1: no configured entries -> refuse to report (exit 2), no per-repo findings ----------------
# If the fragment is not applied, every repo is dark at once. A tool that prints "N repos DARK"
# here has inverted its own severity and sends someone chasing N phantom repairs.
i1=$(run "$tmp/gcfg-empty" check)
want "I1 missing entries exits 2" " rc=2" "$i1"
want "I1 names the missing entry" "hook.publish-guard-commit-msg" "$i1"
lacks "I1 no per-repo findings" "SUMMARY:" "$i1"

# --- I2: missing leak-guard -> refuse to report ---------------------------------------------------
mv "$fh/.local/bin/leak-guard" "$tmp/lg.off"
want "I2 missing leak-guard exits 2" " rc=2" "$(run "$tmp/gcfg" check)"
mv "$tmp/lg.off" "$fh/.local/bin/leak-guard"

# --- I3: check --path over broken infrastructure -> exit 2, never a per-repo verdict -------------
want "I3 check --path refuses over missing entries" " rc=2" "$(run "$tmp/gcfg-empty" check --path "$k")"

# --- E1: notes + internal policies -> EXEMPT naming the policy, NOT DARK ------------------------
# The false alarm the design exists to avoid: markers are LEGAL in the program's own notes repository
# and in a private internal one. The expectation is derived per repo from `leakPolicy` in the fleet
# record, and the exemption is printed with the value that caused it.
en=$(newrepo work/en); ei=$(newrepo work/ei)
printf 'projects:\n  en:\n    path: work/en\n    scope: work/en\n    leakPolicy: notes\n  ei:\n    path: work/ei\n    scope: work/ei\n    leakPolicy: internal\n' > "$tmp/mani.yaml"
e1=$(run "$tmp/gcfg" check)
want "E1 notes policy is EXEMPT"    "leakPolicy=notes"    "$e1"
want "E1 internal policy is EXEMPT" "leakPolicy=internal" "$e1"
lacks "E1 neither is DARK"          "DARK —"              "$e1"

# --- D1: denominator -- a smaller manifest shrinks it; an unreadable one refuses ----------------
newrepo work/r2 >/dev/null; manifest work/k work/r2
d1a=$(run "$tmp/gcfg" list); manifest work/k; d1b=$(run "$tmp/gcfg" list)
n2=$(printf '%s' "$d1a" | grep -c 'mani.yaml:' || true); n1=$(printf '%s' "$d1b" | grep -c 'mani.yaml:' || true)
[ "$n1" -lt "$n2" ] && ok "D1 removing a project shrinks the denominator ($n2 -> $n1)" || bad "D1 denominator did not shrink" "$n2 -> $n1"
d1c=$(HOME="$fh" HOOK_DOCTOR_MANIFEST="$tmp/nonexistent.yaml" HOOK_DOCTOR_CHEZMOI_SRC=/nonexistent \
      HOOK_DOCTOR_OVERLAY_SRC=/nonexistent sh "$doctor" list 2>&1; printf ' rc=%s' "$?")
want "D1 unreadable manifest exits 2" " rc=2" "$d1c"

# D2: a worktree reachable both from the manifest and from the tool's own additions (the chezmoi
# sources) is listed once.
d2=$(HOME="$fh" GIT_CONFIG_GLOBAL="$tmp/gcfg" GIT_CONFIG_NOSYSTEM=1 HOOK_DOCTOR_MANIFEST="$tmp/mani.yaml" \
     HOOK_DOCTOR_DEVEL_ROOT="$devel" FLEET_RECORD="$tmp/mani.yaml" FLEET_DEVEL_ROOT="$devel" \
     HOOK_DOCTOR_CHEZMOI_SRC="$k" HOOK_DOCTOR_OVERLAY_SRC=/nonexistent sh "$doctor" list 2>&1)
[ "$(printf '%s\n' "$d2" | grep -c "^  $k ")" = 1 ] && ok "D2 a worktree from two sources is listed once" || bad "D2 listed once" "$(printf '%s' "$d2" | grep "$k" | tr '\n' '|')"

# --- B1: a bare CONTAINER root is SKIP, never a verdict ------------------------------------------
# In the bare-container layout the container root is a valid git context with no work tree; you pass
# through it on the way to every worktree, so a false verdict there would be frequent.
c7="$tmp/cont"; mkdir -p "$c7"; git_q init --bare -q "$c7/.bare"; printf 'gitdir: ./.bare\n' > "$c7/.git"
b1=$(run "$tmp/gcfg" check --path "$c7")
want "B1 bare container is SKIP" "SKIP" "$b1"
want "B1 exits 0" " rc=0" "$b1"
lacks "B1 not DARK" "DARK" "$b1"

# --- H1: a local core.hooksPath is a WARNING: the guard is still GUARDED -------------------------
git_q -C "$k" config core.hooksPath .husky/_
h1=$(run "$tmp/gcfg" check)
want "H1 guard still GUARDED" "GUARDED 1 " "$h1"
want "H1 warned as HOOKSPATH-LOCAL" "HOOKSPATH-LOCAL (warning)" "$h1"
want "H1 warning alone exits 0" " rc=0" "$h1"
git_q -C "$k" config --unset core.hooksPath

# --- G1-G5: a repo's OWN gates, tracked vs actually run ------------------------------------------
g=$(newrepo work/g); mkdir -p "$g/tools/hooks"; printf '#!/bin/sh\nexit 0\n' > "$g/tools/hooks/pre-commit"
( cd "$g" && git_q add tools/hooks/pre-commit && git_q commit -qm gates ) >/dev/null 2>&1
manifest work/g
want "G1 tracked tools/hooks, nothing wired -> GATES-UNWIRED" "GATES-UNWIRED" "$(run "$tmp/gcfg" check)"
mkdir -p "$g/.git/hooks"; printf '#!/bin/sh\nexit 0\n' > "$g/.git/hooks/pre-commit"; chmod +x "$g/.git/hooks/pre-commit"
lacks "G2 wiring the shared hook clears it" "GATES-UNWIRED" "$(run "$tmp/gcfg" check)"
newrepo work/n >/dev/null; manifest work/n
lacks "G3 a repo tracking no gates is not reported" "GATES-UNWIRED" "$(run "$tmp/gcfg" check)"
t=$(newrepo work/t); mkdir -p "$t/.githooks"; printf '#!/bin/sh\nexit 0\n' > "$t/.githooks/pre-commit"
( cd "$t" && git_q add .githooks/pre-commit && git_q commit -qm gates ) >/dev/null 2>&1
manifest work/t
lacks "G4 tracked .githooks in a manifest repo is WIRED (run-repo-gates)" "GATES-UNWIRED" "$(run "$tmp/gcfg" check)"
# G6: check --path reports unwired gates too, as a warning that does not fail it (it gates worktree
# creation), and even under --quiet.
manifest work/g; rm -f "$g/.git/hooks/pre-commit"
g6=$(run "$tmp/gcfg" check --path "$g" --quiet)
want "G6 check --path --quiet names GATES-UNWIRED" "GATES-UNWIRED" "$g6"
want "G6 and still exits 0" " rc=0" "$g6"
# G5: listed WITHOUT a scope, so hook-doctor enumerates it but fleet-decl cannot resolve it and the
# runner will not run its gates.
printf 'projects:\n  pt:\n    path: work/t\n' > "$tmp/mani.yaml"
want "G5 same repo not resolvable in the manifest -> GATES-UNWIRED" "GATES-UNWIRED" "$(run "$tmp/gcfg" check)"

# --- H2: a GLOBAL core.hooksPath left over -> a machine-wide finding, exit 1 ----------------------
# It leaves the guard alone but silently hides every repo's own .git/hooks from git.
cp "$tmp/gcfg" "$tmp/gcfg-hp"; printf '[core]\n\thooksPath = %s\n' "$tmp/old-dispatcher" >> "$tmp/gcfg-hp"
manifest work/k
h2=$(run "$tmp/gcfg-hp" check)
want "H2 names the global core.hooksPath" "global core.hooksPath=$tmp/old-dispatcher" "$h2"
want "H2 exit 1" " rc=1" "$h2"
lacks "H2 absent without it" "global core.hooksPath=" "$(run "$tmp/gcfg" check)"

# --- M1-M3: several worktrees, probed in parallel ------------------------------------------------
# Results are collected per worktree and must land on the RIGHT worktree, in the same order, however
# many run at once. M1 caught a real defect: a tab-separated result with an empty field (no local
# hooksPath) shifted every later field, reporting clean repos as core.hooksPath=WIRED.
m1=$(newrepo work/m1); m2=$(newrepo work/m2); m3=$(newrepo work/m3)
# m1 tracks gates and has them wired, so a shifted field would surface as core.hooksPath=WIRED --
# the exact shape of the defect.
mkdir -p "$m1/tools/hooks"; printf '#!/bin/sh\nexit 0\n' > "$m1/tools/hooks/pre-commit"
( cd "$m1" && git_q add tools/hooks/pre-commit && git_q commit -qm gates ) >/dev/null 2>&1
mkdir -p "$m1/.git/hooks"; printf '#!/bin/sh\nexit 0\n' > "$m1/.git/hooks/pre-commit"; chmod +x "$m1/.git/hooks/pre-commit"
git_q -C "$m2" config core.hooksPath .husky/_
git_q -C "$m3" config hook.publish-guard-commit-msg.enabled false
manifest work/m1 work/m2 work/m3
mp=$(HOOK_DOCTOR_JOBS=4 run "$tmp/gcfg" check)
want "M1 the warning names the repo that set core.hooksPath" "m2 — core.hooksPath=.husky/_" "$mp"
lacks "M1 no field shifted into core.hooksPath" "core.hooksPath=WIRED" "$mp"
lacks "M1 m1 is not warned" "m1 — core.hooksPath" "$mp"
want "M2 the dark repo is the one with the disabled entry" "m3 — planted" "$mp"
ms=$(HOOK_DOCTOR_JOBS=1 run "$tmp/gcfg" check)
[ "$ms" = "$mp" ] && ok "M3 one job and four jobs give the identical report" || bad "M3 report depends on parallelism" "$(printf '%s' "$ms" | tr '\n' ' ' | cut -c1-200) VS $(printf '%s' "$mp" | tr '\n' ' ' | cut -c1-200)"

# --- S1-S5: the global secret scan, probed on pre-commit ------------------------------------------
# Separate from the guard: a planted fake token must be refused BY git-secret-scan, with the guard
# and the repo's own gates switched off, and a clean input must pass.
manifest work/k
s1=$(run "$tmp/gcfg" check)
want "S1 the scan is live -> SCANNED" "SCANNED 1 " "$s1"
lacks "S1 no scan finding" "SCAN-DARK" "$s1"
git_q -C "$k" config hook.secret-scan.enabled false
s2=$(run "$tmp/gcfg" check)
want "S2 scan disabled locally -> SCAN-DARK" "SCAN-DARK" "$s2"
want "S2 names the repo" "work/k — planted" "$s2"
want "S2 exit 1" " rc=1" "$s2"
lacks "S2 the guard is still GUARDED" "DARK — fail-open" "$s2"
git_q -C "$k" config --unset hook.secret-scan.enabled
git_q -C "$k" config hook.secret-scan.command true
want "S3 scan command replaced -> SCAN-DARK" "SCAN-DARK" "$(run "$tmp/gcfg" check)"
git_q -C "$k" config --unset hook.secret-scan.command
# A refusal by something other than the scan is not coverage.
git_q -C "$k" config hook.secret-scan.enabled false
# It refuses ONLY staged content carrying a token-shaped string, so the clean input passes and the
# planted one is refused -- by the wrong thing.
git_q -C "$k" config hook.lookalike.command 'git diff --cached | grep -q "gh""p_" && exit 1; exit 0'
git_q -C "$k" config --add hook.lookalike.event pre-commit
s4=$(run "$tmp/gcfg" check)
want "S4 non-scan refusal -> SCAN-DARK naming OTHER" "rc=1, OTHER" "$s4"
lacks "S4 not counted as scanned" "SCANNED 1 " "$s4"
git_q -C "$k" config --remove-section hook.lookalike
git_q -C "$k" config --unset hook.secret-scan.enabled
s5=$(run "$tmp/gcfg-noscan" check)
want "S5 no global scan entry -> a machine-wide finding" "SCAN-OFF" "$s5"
want "S5 exit 1" " rc=1" "$s5"
mv "$fh/.config/gitleaks/floor.toml" "$fh/.config/gitleaks/floor.toml.off"
s6=$(run "$tmp/gcfg" check)
want "S6 a scan refusing a clean input -> SCAN-BLOCKED, not SCAN-DARK" "SCAN-BLOCKED" "$s6"
mv "$fh/.config/gitleaks/floor.toml.off" "$fh/.config/gitleaks/floor.toml"

# --- N1-N3: the probe marker is the DOMAIN's: a probe-marker= line in git-leak-policy -------------
# The probe plants a token the domain's markers match. Nothing in the tool knows any domain's
# vocabulary, so a marker baked into it would be wrong for every domain but one.
manifest work/k
cp "$fh/.dotlocal/git-leak-policy" "$tmp/policy.keep"
# The marker is named in a DARK finding ("planted <marker> not refused"), so one event is switched off
# to make the tool say which token it planted.
git_q -C "$k" config hook.publish-guard-pre-push.enabled false
want "N1 control: the policy's own marker is the one planted" "planted ZZP-9999 not refused" "$(run "$tmp/gcfg" check)"
sed 's/^probe-marker=.*/probe-marker=ZZQ-8888/' "$tmp/policy.keep" > "$fh/.dotlocal/git-leak-policy"
n1=$(run "$tmp/gcfg" check)
want "N1 a different probe-marker in git-leak-policy is the one planted" "planted ZZQ-8888 not refused" "$n1"
OVR_MARKER=ZZR-7777; n1b=$(run "$tmp/gcfg" check); OVR_MARKER=
want "N1b HOOK_DOCTOR_MARKER overrides the policy line" "planted ZZR-7777 not refused" "$n1b"
git_q -C "$k" config --unset hook.publish-guard-pre-push.enabled
cp "$tmp/policy.keep" "$fh/.dotlocal/git-leak-policy"

# N2: no probe-marker= line -> the tool refuses to report (infrastructure incomplete), never a verdict
grep -v '^probe-marker=' "$tmp/policy.keep" > "$fh/.dotlocal/git-leak-policy"
n2=$(run "$tmp/gcfg" check)
want "N2 no probe-marker -> MISSING"          "MISSING  probe-marker=" "$n2"
want "N2 exit 2"                              " rc=2" "$n2"
lacks "N2 no per-repo findings"               "SUMMARY:" "$n2"
n2p=$(run "$tmp/gcfg" check --path "$k")
want "N2 check --path refuses too"            " rc=2" "$n2p"
want "N2 check --path says why"               "infrastructure incomplete" "$n2p"

# N3: a probe marker the domain's markers do NOT match would be let through by a healthy guard and
# read every repo DARK at once; it is reported as missing infrastructure instead.
sed 's/^probe-marker=.*/probe-marker=QQQ-1/' "$tmp/policy.keep" > "$fh/.dotlocal/git-leak-policy"
n3=$(run "$tmp/gcfg" check)
want "N3 a marker the patterns do not match -> MISSING" "does not match git-leak-markers" "$n3"
want "N3 exit 2"                                         " rc=2" "$n3"
cp "$tmp/policy.keep" "$fh/.dotlocal/git-leak-policy"
want "N3 control: the restored policy reads GUARDED"     "GUARDED 1 " "$(run "$tmp/gcfg" check)"

# --- N4: NOT-CONFIGURED -- a domain with no pattern files has no guard to probe ------------------
# The leak-guard passes every commit there by design, so reporting "DARK" would be a false alarm on
# every such machine. Exit 0 everywhere, and silent where it runs on every directory change.
nh="$tmp/nohome"; mkdir -p "$nh/.local/bin"; cp "$fh/.local/bin/"* "$nh/.local/bin/"
RUNHOME=$nh; n4=$(run "$tmp/gcfg" check); n4p=$(run "$tmp/gcfg" check --path "$k"); n4q=$(run "$tmp/gcfg" check --path "$k" --quiet); RUNHOME=
want "N4 check says NOT-CONFIGURED"                 "NOT-CONFIGURED" "$n4"
want "N4 check exits 0"                             " rc=0" "$n4"
lacks "N4 check reports no per-repo verdicts"       "DARK" "$n4"
want "N4 check --path says NOT-CONFIGURED"          "NOT-CONFIGURED" "$n4p"
want "N4 check --path exits 0"                      " rc=0" "$n4p"
[ "$n4q" = " rc=0" ] && ok "N4 check --path --quiet prints nothing, exits 0" || bad "N4 quiet" "got: $n4q"
RUNHOME=$nh; n4e=$(run "$tmp/gcfg" explain NOT-CONFIGURED); RUNHOME=
want "N4 explain knows the verdict"                 "git-leak-markers" "$n4e"
# control: ONE pattern file is enough to make the domain configured, and then it is judged
mkdir -p "$nh/.dotlocal"; cp "$fh/.dotlocal/git-leak-sensitive" "$nh/.dotlocal/"
RUNHOME=$nh; n4c=$(run "$tmp/gcfg" check); RUNHOME=
lacks "N4 control: a pattern file makes it configured" "NOT-CONFIGURED" "$n4c"
want  "N4 control: and the incomplete rest is refused" " rc=2" "$n4c"

# --- N5: gates the repository's hooks directory runs natively are reported WIRED -----------------
# A repo whose core.hooksPath is its own tracked hooks directory (husky's .husky/_ is the usual one)
# has its gates run by git, so nothing is unwired -- even where run-repo-gates would skip them (no
# node_modules) or does not know the repo. `WIRED natively` is not printed on its own, so it is
# observed by the ABSENCE of GATES-UNWIRED, with controls that must report it.
w=$(newrepo work/w); mkdir -p "$w/.husky/_"; printf '#!/bin/sh\nexit 0\n' > "$w/.husky/pre-commit"; printf '{}\n' > "$w/package.json"
( cd "$w" && git_q add .husky/pre-commit package.json && git_q commit -qm gates ) >/dev/null 2>&1
manifest work/w
want "N5 control: tracked husky gate, nothing native, no node_modules -> GATES-UNWIRED" "GATES-UNWIRED" "$(run "$tmp/gcfg" check)"
git_q -C "$w" config core.hooksPath .husky/_
want "N5 control: core.hooksPath set but no pre-commit file -> still GATES-UNWIRED"    "GATES-UNWIRED" "$(run "$tmp/gcfg" check)"
printf '#!/bin/sh\nexit 0\n' > "$w/.husky/_/pre-commit"
want "N5 control: a pre-commit that is not executable (git skips it) -> GATES-UNWIRED"  "GATES-UNWIRED" "$(run "$tmp/gcfg" check)"
chmod +x "$w/.husky/_/pre-commit"
n5=$(run "$tmp/gcfg" check)
lacks "N5 core.hooksPath=.husky/_ with an executable pre-commit -> WIRED natively" "GATES-UNWIRED" "$n5"
lacks "N5 check --path agrees" "GATES-UNWIRED" "$(run "$tmp/gcfg" check --path "$w")"
# a hooks directory that is NOT the tracked gates' own does not count
git_q -C "$w" config core.hooksPath .other; mkdir -p "$w/.other"; printf '#!/bin/sh\nexit 0\n' > "$w/.other/pre-commit"; chmod +x "$w/.other/pre-commit"
want "N5 an unrelated hooks directory is not the gates' -> GATES-UNWIRED" "GATES-UNWIRED" "$(run "$tmp/gcfg" check)"
# .githooks as the hooks directory
git_q -C "$w" config core.hooksPath .githooks; mkdir -p "$w/.githooks"; printf '#!/bin/sh\nexit 0\n' > "$w/.githooks/pre-commit"; chmod +x "$w/.githooks/pre-commit"
( cd "$w" && git_q add .githooks/pre-commit && git_q commit -qm githooks ) >/dev/null 2>&1
lacks "N5 core.hooksPath=.githooks with an executable pre-commit -> WIRED natively" "GATES-UNWIRED" "$(run "$tmp/gcfg" check)"

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'all hook-doctor acceptance criteria met\n'; else printf '%s criterion/criteria FAILED\n' "$fails"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
