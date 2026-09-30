#!/usr/bin/env bash
# Tests for memory-doctor.
#
# `stale` resolves work-item status from the per-repo registers (one file per entry under each
# canonical's `docs/register/`, read through the base `register` tool). It used to parse a single
# portfolio of markdown tables; when the register moved to one file per entry on 2026-09-22 that
# portfolio disappeared and `stale` could only die. The cases below assert that a KNOWN-closed item
# is found, because a stale check that finds nothing is indistinguishable from one that read nothing.

set -uo pipefail

DOC="$(cd "$(dirname "$0")/.." && pwd)/private_dot_local/bin/executable_memory-doctor"
pass=0; fail=0
# Assert against a captured string WITHOUT a pipeline. `printf ... | grep -q` reads the PIPELINE's
# status: grep -q exits on first match, printf takes SIGPIPE, and under `set -o pipefail` a
# successful match is reported as a failure. It is timing-dependent -- short strings usually finish
# first -- so it passes until it does not, on whichever machine is unlucky. A herestring has no
# pipeline and yields grep's own status.
has()  { grep -q  -- "$2" <<< "$1"; }
hasi() { grep -qi -- "$2" <<< "$1"; }
# Both strings on ONE line, in either order (budget prints the store first, integrity the label).
line_has() { local l; l=$(grep -- "$2" <<< "$1"); grep -q -- "$3" <<< "$l"; }
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

STORES="$TMP/projects"; STORE="$STORES/-test/memory"; mkdir -p "$STORE"
export MEMORY_DOCTOR_STORES="$STORES" MEMORY_DOCTOR_LOG="$TMP/reads.jsonl"

# Two registers, in the one-file-per-entry shape `register` reads. The second uses a prefix
# (XYZ) that no hard-coded list ever named.
mk_entry() { # <register dir> <id> <status> [closed]
  local dir="$1"; [ -n "${4:-}" ] && dir="$1/closed"; mkdir -p "$dir"
  printf -- '---\nid: %s\ntitle: entry %s\nstatus: %s\n---\n\n# %s\n' "$2" "$2" "$3" "$2" > "$dir/$2-x.md"
}
REG_MOD="$TMP/mod-repo/docs/register"; REG_KEY="$TMP/key-repo/docs/register"
mk_entry "$REG_MOD" ABC-0001 done closed
mk_entry "$REG_MOD" ABC-0002 active
mk_entry "$REG_KEY" XYZ-0003 done closed
export MEMORY_DOCTOR_REGISTERS="$REG_MOD:$REG_KEY"

mk_mem() { printf -- '---\nname: %s\nmetadata:\n  type: %s\n---\n\n%s\n' "$1" "$2" "$3" > "$STORE/$1.md"; }
mk_mem closed-journal project "Work on ABC-1 is finished."
mk_mem live-journal   project "Work on ABC-2 continues."
mk_mem both-journal   project "Touches ABC-1 and ABC-2."
mk_mem a-preference   feedback "ABC-1 is mentioned but this is not a project memory."
mk_mem key-journal    project "Project work on XYZ-0003 is finished."
printf -- '- [closed](closed-journal.md)\n- [live](live-journal.md)\n- [both](both-journal.md)\n- [pref](a-preference.md)\n- [key](key-journal.md)\n' > "$STORE/MEMORY.md"

printf '\n== stale: resolves status from the per-repo registers ==\n'
out=$(bash "$DOC" stale 2>&1)
has "$out" 'closed-journal' \
  && ok "flags a memory whose only cited row is done" \
  || bad "did not flag closed-journal" "a known-closed item was not found: the registers were not read"
has "$out" 'ABC-1=done' \
  && ok "resolves the unpadded legacy id ABC-1 to the padded entry ABC-0001" \
  || bad "did not resolve ABC-1 to ABC-0001" "memories written before the padding cite the short form"
has "$out" 'live-journal' \
  && bad "flagged a memory citing an ACTIVE row" "would send you to convert live work" \
  || ok "ignores a memory citing an active row"
has "$out" 'both-journal' \
  && bad "flagged a memory citing one done and one active row" "not every citation is closed" \
  || ok "ignores a memory with a mix of closed and open citations"
has "$out" 'a-preference' \
  && bad "flagged a non-project memory" "only project journals expire this way" \
  || ok "ignores a feedback memory that merely mentions an id"

# `type:` is nested under `metadata:` in the documented schema, but 30 memories across this fleet
# declare it at the TOP LEVEL -- an older schema never migrated. `stale` anchored its match to two
# spaces and so silently skipped 10 project memories. Silently is the whole problem: this command
# emits a LIST, so a file it never examined is indistinguishable from one it cleared.
mk_toplevel() { printf -- '---\nname: %s\ntype: %s\n---\n\n%s\n' "$1" "$2" "$3" > "$STORE/$1.md"; }
mk_toplevel top-level-journal project "Work on ABC-1 is finished."
printf -- '- [tl](top-level-journal.md)\n' >> "$STORE/MEMORY.md"
out=$(bash "$DOC" stale 2>&1)
has "$out" 'top-level-journal' \
  && ok "sees a project memory whose type: is at the top level, not under metadata:" \
  || bad "missed a top-level type: memory" "anchoring to two spaces hid 10 project memories fleet-wide"
rm -f "$STORE/top-level-journal.md"

has "$out" 'key-journal' \
  && ok "reads a register whose prefix no fixed list names (XYZ)" \
  || bad "missed a closed XYZ entry" "a register keyed XYZ- must be read, not only the prefixes a fixed list assumed"

printf '\n== stale: refuses rather than reporting clean ==\n'
out=$(MEMORY_DOCTOR_REGISTERS="$TMP/nope" bash "$DOC" stale 2>&1); rc=$?
[ "$rc" -ne 0 ] && hasi "$out" 'refusing' \
  && ok "exits non-zero when no register can be read" \
  || bad "reported on unreadable registers" "rc=$rc: $(printf '%s' "$out" | head -1)"

# One unreadable register among readable ones: carry on, but SAY which one was not read. A silent
# skip would report that repo's memories as not stale when they were never checked.
out=$(MEMORY_DOCTOR_REGISTERS="$TMP/nope:$REG_MOD" bash "$DOC" stale 2>&1); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'REGISTER-UNREAD.*nope' \
  && ok "names an unreadable register and still reports from the rest" \
  || bad "an unreadable register was skipped silently or was fatal" "rc=$rc"

# Discovery with no override: each canonical's declared launch dir, read through fleet-decl. Stubbed
# here so the test does not depend on this machine's mani.yaml.
STUB="$TMP/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/fleet-decl" <<'EOF'
#!/bin/sh
case "$1" in
  --canonicals) printf 'alpha-canonical\nbeta-canonical\n' ;;
  --canonical)  case "$2" in alpha-canonical) echo mod-repo ;; beta-canonical) echo key-repo ;; esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/fleet-decl"
out=$(env -u MEMORY_DOCTOR_REGISTERS MEMORY_DOCTOR_DEVEL="$TMP" PATH="$STUB:$PATH" bash "$DOC" stale 2>&1); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'key-journal' \
  && ok "discovers the registers from each canonical's declared launch dir" \
  || bad "register discovery through fleet-decl failed" "rc=$rc: $(printf '%s' "$out" | head -2)"

# fleet-decl exit 2 means the declaration record is unreadable. Treating that as "no canonicals"
# would scan nothing and report nothing stale.
printf '#!/bin/sh\nexit 2\n' > "$STUB/fleet-decl"
out=$(env -u MEMORY_DOCTOR_REGISTERS PATH="$STUB:$PATH" bash "$DOC" stale 2>&1); rc=$?
[ "$rc" -ne 0 ] && hasi "$out" 'fleet record is unreadable' \
  && ok "refuses when the fleet declaration record is unreadable, and says so" \
  || bad "an unreadable fleet record was treated as an empty fleet" "rc=$rc"

printf '\n== usage: the load-bearing safety ==\n'
out=$(bash "$DOC" usage 2>&1); rc=$?
[ "$rc" -ne 0 ] && has "$out" 'not wired' \
  && ok "exits non-zero with no read log (never 'everything is unread')" \
  || bad "reported usage with no log" "rc=$rc"

printf '{"ts":"%s","store":"-test","file":"closed-journal.md","tool":"Read","session":"s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MEMORY_DOCTOR_LOG"
out=$(bash "$DOC" usage 2>&1)
has "$out" 'WINDOW TOO SHORT' \
  && ok "declares the observation window too short" || bad "no short-window warning" ""
has "$out" 'count only' \
  && ok "withholds the unobserved LIST while the window is short" \
  || bad "listed unobserved files on a 0-day window" "that list reads as a finding when it is not"
has "$out" 'closed-journal.md' \
  && ok "still reports what WAS read" || bad "lost the real read counts" ""

printf '\n== budget ==\n'
i=1; : > "$STORE/MEMORY.md"
while [ $i -le 170 ]; do echo "- [m$i](m$i.md) entry" >> "$STORE/MEMORY.md"; i=$((i+1)); done
# Capture, THEN grep -- never pipe the command under test straight into `grep -q`. grep -q exits
# on the first match, the writer takes SIGPIPE, and `set -o pipefail` propagates that as the
# pipeline's status, so a SUCCESSFUL match reports failure. It is timing-dependent, so it passed on
# Linux (output completes before grep exits) and failed only on darwin -- the shape this suite
# exists to catch, found in the suite itself. Every other assertion here already captured first;
# this was the lone inconsistent one, and it was the one that broke.
out=$(bash "$DOC" budget 2>&1)
has "$out" 'OVER-BUDGET' \
  && ok "flags an over-budget index" || bad "did not flag 170 lines" ""

# A store that EXISTS but is empty used to be skipped by `[ -f MEMORY.md ] || continue`,
# so a canonical with no memories at all rendered exactly like a store that was never there.
# one session ran 18 days and 67 commits that way, invisible. Report it, and separately report a
# store that has memories but no index, because nothing in it loads at session start.
printf '\n== budget and integrity: an empty store and an unindexed store are reported ==\n'
ES="$TMP/estores"; mkdir -p "$ES/-empty/memory" "$ES/-noindex/memory" "$ES/-fine/memory"
echo 'a memory nothing indexes' > "$ES/-noindex/memory/lonely.md"
printf -- '- [f](f.md) x\n' > "$ES/-fine/memory/MEMORY.md"; echo body > "$ES/-fine/memory/f.md"
for sub in budget integrity; do
  out=$(MEMORY_DOCTOR_STORES="$ES" bash "$DOC" "$sub" 2>&1)
  line_has "$out" '-empty' 'ABSENT' \
    && ok "$sub reports an existing-but-empty store as ABSENT" \
    || bad "$sub omitted the empty store" "silence is indistinguishable from health"
  line_has "$out" '-noindex' 'NO-INDEX' \
    && ok "$sub reports a store with memories but no MEMORY.md" \
    || bad "$sub omitted the unindexed store" "none of its memories load at session start"
  line_has "$out" '-fine' 'ABSENT\|NO-INDEX' \
    && bad "$sub flagged a healthy store" "the new rows must not fire on a normal store" \
    || ok "$sub does not flag a normal store"
done

# ==================================================================================================
# integrity: wikilink resolution.
#
# These are the permanent historical controls for the 2026-08-30 fix. Before it, `integrity`
# reported 88 dangling wikilinks fleet-wide of which 70 were not defects: a link written [[foo-bar]]
# against a file named foo_bar.md, and a link that legitimately resolves in ANOTHER store (which is
# what the memory standard asks for instead of copying a memory into both). Reported as dangling, the first
# becomes 66 phantom repairs and the second invites exactly the duplication the ADR forbids.
#
# The last two cases matter most and are the reason a green run here was never evidence: the
# scanner's own pattern excluded underscores, so an underscored wikilink -- and an underscored
# index link -- were never EXAMINED at all. A check blind to part of its subject does not error, it
# reports clean. Assert the true-positive cases too: the point is a checker that is more accurate,
# not one that is merely quieter.
printf '\n== integrity: wikilinks resolve across stores and across -/_ spelling ==\n'
IS="$TMP/istores"; A="$IS/-store-a/memory"; B="$IS/-store-b/memory"; mkdir -p "$A" "$B"
echo 'underscored filename; links point at it with hyphens' > "$A/alpha_one.md"
cat > "$A/beta.md" <<'EOF'
[[alpha-one]] folds. [[gamma]] is cross-store. [[nope]] is real. [[under_score_missing]] is real.
EOF
printf -- '- [a](alpha_one.md) x\n- [b](beta.md) x\n- [ghost](ghost_gone.md) x\n' > "$A/MEMORY.md"
echo 'gamma lives in the other store' > "$B/gamma.md"
printf -- '- [g](gamma.md) x\n' > "$B/MEMORY.md"
out=$(MEMORY_DOCTOR_STORES="$IS" bash "$DOC" integrity 2>&1)

has "$out" 'DANGLING-WIKILINK.*alpha-one' \
  && bad "called [[alpha-one]] dangling" "hyphen/underscore folding regressed: 66 phantom repairs return" \
  || ok "does not call [[alpha-one]] dangling when alpha_one.md exists"
has "$out" 'FOLD-ONLY' \
  && ok "counts fold-only links instead of listing them as work" \
  || bad "no FOLD-ONLY summary" "convention drift must stay visible without becoming a work list"
has "$out" 'XSTORE-WIKILINK.*gamma' \
  && ok "resolves [[gamma]] into the other store and says so" \
  || bad "did not report [[gamma]] as cross-store" "silence here invites a duplicate local copy"
has "$out" 'DANGLING-WIKILINK.*nope' \
  && ok "still reports a genuinely dangling link" \
  || bad "lost a true positive" "the fix must not just make the checker quieter"
has "$out" 'DANGLING-WIKILINK.*under_score_missing' \
  && ok "examines UNDERSCORED wikilinks at all (was invisible to the scan pattern)" \
  || bad "underscored wikilink not examined" "blind to its own subject: reports clean, never errors"
has "$out" 'DANGLING-INDEX.*ghost_gone' \
  && ok "examines UNDERSCORED index links at all (same blind spot)" \
  || bad "underscored index link not examined" "same class as above, in the index scan"

# A wikilink targets the other memory's `name:` SLUG, which is not always its filename -- 46
# memories across this fleet diverge. Indexing filenames alone reported those correctly-written
# links as dangling. Found by a session running this tool against its own store, after the fix above
# had already been shipped and announced: the same defect class, one layer in.
#
# The third case is the load-bearing one. The fix is a UNION of both keys, so resolving on `name:`
# ALONE would be the mirror-image bug -- and a suite that only tested the name: case would score
# that swap as correct.
printf '\n== integrity: wikilinks resolve on the `name:` slug AND the filename ==\n'
NS="$TMP/nstores"; N="$NS/-store-n/memory"; mkdir -p "$N"
printf -- '---\nname: the-slug-not-the-filename\n---\nbody\n' > "$N/some_file.md"
printf -- '---\nname: plain\n---\nbody\n' > "$N/plain.md"
cat > "$N/links.md" <<'EOF'
[[the-slug-not-the-filename]] targets a name:. [[plain]] targets a filename. [[absent]] is real.
EOF
printf -- '- [a](some_file.md) x\n- [b](plain.md) x\n- [c](links.md) x\n' > "$N/MEMORY.md"
out=$(MEMORY_DOCTOR_STORES="$NS" bash "$DOC" integrity 2>&1)

has "$out" 'DANGLING-WIKILINK.*the-slug-not-the-filename' \
  && bad "called a link dangling that matches the target's name: slug" "46 phantom repairs fleet-wide" \
  || ok "resolves a wikilink via the target's name: frontmatter"
has "$out" 'DANGLING-WIKILINK.*\[\[plain\]\]' \
  && bad "lost filename resolution while adding name: resolution" "the fix must be a UNION, not a swap" \
  || ok "still resolves a wikilink via the plain filename (union, not swap)"
# `name:` is read indentation-agnostically, matching `type:`. It is top-level in every store today,
# so an anchored `^name:` works -- and would keep working right until the schema nests it the way
# `type:` already is, at which point the union silently loses its name half and reverts to the
# defect fixed earlier the same day, with NO error. Correct-by-accident is not correct.
printf -- '---\nmetadata:\n  name: nested-slug\n---\nbody\n' > "$N/nested_file.md"
printf -- '[[nested-slug]]\n' >> "$N/links.md"
printf -- '- [n](nested_file.md) x\n' >> "$N/MEMORY.md"
out2=$(MEMORY_DOCTOR_STORES="$NS" bash "$DOC" integrity 2>&1)
has "$out2" 'DANGLING-WIKILINK.*nested-slug' \
  && bad "a name: nested under metadata: was not read" "the union silently loses its name half" \
  || ok "reads name: at any indentation, not only column 0"

has "$out" 'DANGLING-WIKILINK.*absent' \
  && ok "still reports a link matching neither filename nor name:" \
  || bad "lost a true positive" "resolving on more keys must not silence real dangles"
# The fixture has no hyphen/underscore divergence at all, so ANY FOLD-ONLY line here is the
# name:-hit leaking into the fold bucket. Adding name: keys to the map did exactly that until an
# exact-name branch was put ahead of it (measured on a real store: 66 -> 68,
# both additions character-for-character identical to their target's name:). This matters beyond
# the count: FOLD-ONLY exists to size ONE pending decision -- hyphens or underscores -- so padding
# it with links that decision would never touch makes it stop measuring what it is read for.
has "$out" 'FOLD-ONLY' \
  && bad "an exact name: hit was counted as FOLD-ONLY" "inflates the count used to size the rename decision" \
  || ok "an exact name: slug is not counted as a folded link"

# A store may index a whole family with ONE collective entry carrying a glob. Those files are
# reachable -- a reader of the index sees the pointer -- so counting them as orphans reports
# "invisible" files that are not. Measured on a real store: 21 reported, 6 real.
#
# The true-positive case below is the one that matters. Any glob in the index must not become a
# blanket amnesty for every unindexed file in the store, which is the obvious way to get this
# wrong and would score green against the first assertion alone.
printf '\n== integrity: a glob index entry indexes the family it names ==\n'
CS="$TMP/cstores"; C="$CS/-store-c/memory"; mkdir -p "$C"
: > "$C/arc-one-handoff.md"; : > "$C/arc-two-handoff.md"; : > "$C/indexed-alone.md"; : > "$C/nobody-points-here.md"
printf -- '- Arc handoffs live in `arc-*-handoff.md` — increment history only\n- [alone](indexed-alone.md) x\n' > "$C/MEMORY.md"
out=$(MEMORY_DOCTOR_STORES="$CS" bash "$DOC" integrity 2>&1)

has "$out" 'ORPHAN.*arc-one-handoff' \
  && bad "a glob-indexed file was called an orphan" "reported 21 invisible files where 6 were" \
  || ok "a file matching a glob index entry is not an orphan"
has "$out" 'COLLECTIVE-INDEX' \
  && ok "reports collective coverage as its own line, not silently" \
  || bad "no COLLECTIVE-INDEX line" "silence here hides that the index is glob-based"
has "$out" 'ORPHAN.*nobody-points-here' \
  && ok "still reports a genuinely unindexed file" \
  || bad "a glob amnestied an unrelated file" "one glob must not excuse the whole store"
has "$out" 'ORPHAN.*indexed-alone' \
  && bad "an individually-indexed file was called an orphan" "regressed the original check" \
  || ok "an individually-indexed file is still not an orphan"

# A store may be a deliberate pre-conversion UNDO COPY, kept by copying rather than moving, not a live
# store. Findings against one are worse than noise: acting on them means editing a copy that exists
# precisely to stay frozen. one repo had both, and its only "dangling wikilink" fleet-wide was in
# the archive. Opt-in by MARKER, because the tool cannot tell an archive from a live store by name.
#
# The visible-skip assertion is the load-bearing one: a silent skip is how a store stops being
# checked without anyone deciding to stop checking it.
printf '\n== integrity: an archive store is skipped, and says so ==\n'
AS="$TMP/astores"; mkdir -p "$AS/-live/memory" "$AS/-arch/memory"
printf -- '- [a](a.md)\n' > "$AS/-live/memory/MEMORY.md"; printf 'see [[gone-forever]]\n' > "$AS/-live/memory/a.md"
printf -- '- [b](b.md)\n' > "$AS/-arch/memory/MEMORY.md"; printf 'see [[also-gone]]\n' > "$AS/-arch/memory/b.md"
touch "$AS/-arch/memory/.memory-archive"
out=$(MEMORY_DOCTOR_STORES="$AS" bash "$DOC" integrity 2>&1)

has "$out" 'DANGLING-WIKILINK.*also-gone' \
  && bad "reported a finding against a marked archive" "acting on it would edit a frozen undo copy" \
  || ok "a store marked .memory-archive is not scanned"
has "$out" 'ARCHIVE-SKIPPED' \
  && ok "the skip is reported, not silent" \
  || bad "archive skipped silently" "a silent skip is how a store stops being checked unnoticed"
has "$out" 'DANGLING-WIKILINK.*gone-forever' \
  && ok "the LIVE store beside it is still scanned" \
  || bad "the marker silenced an unmarked store too" "one archive must not mute the fleet"

# ------------------------------------------------------------------------------------------------
# A MISSING OR EMPTY STORES ROOT MUST NOT RENDER AS A CLEAN FLEET.
#
# MEMORY_DOCTOR_STORES names the ROOT that CONTAINS the per-project stores, not a single store.
# Pass it a store NAME -- an easy and natural mistake -- and the glob matches nothing, every
# subcommand scans zero stores, and the output is byte-indistinguishable from a genuinely clean
# fleet at exit 0. Reported 2026-08-30 by a session that briefly recorded a store as
# verified-clean on the strength of such a run; it was caught because the output looked too terse,
# which is not a mechanism.
#
# This is the tool's own FAIL LOUD principle applied to the input that feeds EVERY subcommand. It
# already dies on a missing read log and a missing portfolio for exactly this reason.
MISSING="$TMP/definitely-not-a-stores-root"
out=$(MEMORY_DOCTOR_STORES="$MISSING" bash "$DOC" integrity 2>&1); rc=$?
[ "$rc" -ne 0 ] \
  && ok "integrity exits non-zero when the stores root does not exist" \
  || bad "integrity reported clean at exit 0 with a nonexistent stores root" \
        "indistinguishable from a healthy fleet, in the direction that hides every finding"
hasi "$out" 'stores root' \
  && ok "the message names the stores root as the problem" \
  || bad "died without naming the cause" "the caller cannot tell this from an unrelated failure"

out=$(MEMORY_DOCTOR_STORES="$MISSING" bash "$DOC" budget 2>&1); rc=$?
[ "$rc" -ne 0 ] \
  && ok "budget also refuses a nonexistent stores root" \
  || bad "budget rendered an empty table at exit 0" "every subcommand reads this root, not just one"

# The subtler half: the root EXISTS but holds no stores. Distinct condition, still not "clean".
EMPTY="$TMP/empty-stores-root"; mkdir -p "$EMPTY/some-project"   # a project dir with no memory/
out=$(MEMORY_DOCTOR_STORES="$EMPTY" bash "$DOC" integrity 2>&1); rc=$?
[ "$rc" -ne 0 ] \
  && ok "a root containing zero stores is loud, not silent" \
  || bad "zero stores matched and it reported clean" \
        "a zero count and a nonexistent root must not render identically"

# ------------------------------------------------------------------------------------------------
# THE SAME VISIBLE-SKIP RULE, FOR EVERY OTHER SUBCOMMAND.
#
# `stores()` has always hidden archives from all four commands, but only `integrity` ever SAID so.
# So `budget`, `stale` and `usage` rendered a partial fleet as a complete one at exit 0 -- the
# tool's own headline failure (a zero-store scan must not look like a healthy fleet) scaled down to
# a subset. `budget` is the worst of the three: an archive is frozen, so its index can never be
# condensed and the row can never return by being fixed, leaving a reader who diffs the table
# against a directory listing to guess between "skipped on purpose" and "never seen".
#
# The two assertions are deliberately different questions. ARCHIVE-SKIPPED is the one that goes red
# on the unfixed tool; the no-scan check guards the opposite regression -- a future edit that makes
# the skip visible by scanning the archive and labelling it.
printf '\n== budget/stale/usage also report the archive they skipped ==\n'
for sub in budget stale usage; do
  out=$(MEMORY_DOCTOR_STORES="$AS" bash "$DOC" "$sub" 2>&1)
  has "$out" 'ARCHIVE-SKIPPED' \
    && ok "$sub reports the archive it skipped" \
    || bad "$sub skipped the archive silently" "a partial fleet must not render as a complete one"
  # Any mention of the archive OTHER than on its skip line means it was actually scanned.
  arch_seen=$(grep -- '-arch' <<< "$out" | grep -v 'ARCHIVE-SKIPPED')
  [ -z "$arch_seen" ] \
    && ok "$sub does not scan the archive itself" \
    || bad "$sub produced output for a frozen archive" "acting on it would edit an undo copy"
  # Only `budget` tabulates every live store unconditionally; `stale` and `usage` print a store
  # only when it HAS a finding, so a clean live store is correctly absent from those two and
  # asserting otherwise would test the fixture rather than the tool.
  if [ "$sub" = budget ]; then
    has "$out" '-live' \
      && ok "$sub still sees the live store beside it" \
      || bad "$sub muted the unmarked store too" "one archive must not mute the fleet"
  fi
done

# ------------------------------------------------------------------------------------------------
# STALE-PATH is driven by a patterns file, not a hard-coded list of retired paths. A missing file
# must be SAID, never skipped silently: a silent skip is how a check stops running unnoticed.
printf '\n== integrity: stale-path check reads a patterns file ==\n'
SP="$TMP/spstores"; SPM="$SP/-sp/memory"; mkdir -p "$SPM"
printf -- '- [cites](cites-old.md)\n- [clean](clean.md)\n' > "$SPM/MEMORY.md"
printf -- '---\nname: cites-old\n---\nSee old/tree/x for details.\n' > "$SPM/cites-old.md"
printf -- '---\nname: clean\n---\nNothing retired here.\n' > "$SPM/clean.md"
printf '# retired trees\n\nold/tree\n' > "$TMP/stale-paths"
out=$(MEMORY_DOCTOR_STORES="$SP" MEMORY_DOCTOR_STALE_PATHS="$TMP/stale-paths" bash "$DOC" integrity 2>&1); rc_with=$?
line_has "$out" 'STALE-PATH' 'cites-old' \
  && ok "reports a memory citing a path listed in the patterns file" \
  || bad "STALE-PATH not reported for a listed pattern" "$out"
has "$out" 'STALE-PATH.*clean\.md' \
  && bad "a memory citing nothing retired was flagged" "" \
  || ok "does not flag a memory that cites no listed path"
has "$out" 'STALE-PATH.*stale-paths' \
  && ok "names the patterns file in the finding" \
  || bad "finding does not name the patterns file" "$out"

out=$(MEMORY_DOCTOR_STORES="$SP" MEMORY_DOCTOR_STALE_PATHS="$TMP/absent-patterns" bash "$DOC" integrity 2>&1); rc=$?
hasi "$out" 'stale-path check skipped.*absent-patterns' \
  && ok "a missing patterns file prints one skip line naming where to create it" \
  || bad "missing patterns file was skipped silently" "$out"
[ "$(grep -ci 'stale-path check skipped' <<< "$out")" -eq 1 ] \
  && ok "the skip line is printed exactly once" \
  || bad "skip line count is not 1" "$out"
has "$out" 'STALE-PATH  ' \
  && bad "reported STALE-PATH with no patterns file" "" \
  || ok "no STALE-PATH findings without a patterns file"
[ "$rc" -eq "$rc_with" ] \
  && ok "the skip does not change the exit status" \
  || bad "exit status changed by a missing patterns file" "with=$rc_with without=$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
