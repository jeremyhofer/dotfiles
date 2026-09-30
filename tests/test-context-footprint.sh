#!/usr/bin/env zsh
# Unit test for context-footprint. Everything the meter reads is redirected via
# $CONTEXT_FOOTPRINT_HOME / _ROOT / _STATE, so the suite measures a fixture tree and never the
# real machine -- a test that read the live ~/.claude would change its own expected numbers every
# time a skill was added.
set -u
HERE=${0:A:h}
TOOL="$HERE/../private_dot_local/bin/executable_context-footprint"
[[ -f "$TOOL" ]] || { print "FAIL: tool not found at $TOOL"; exit 1 }

fail=0
ok()  { print "ok:   $1" }
bad() { print "FAIL: $1"; fail=1 }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.claude/rules" "$T/home/.claude/skills/alpha" "$T/proj/.claude/skills"

# A three-deep import chain. Transitivity is the point: a real global CLAUDE.md can be 8 KB of its
# own text pointing at a 74 KB file that itself points somewhere else, so a meter that
# followed only one hop would under-report the single largest component in the system.
print -n 'AAAA\n@mid.md\n'            > "$T/home/.claude/CLAUDE.md"   # 12 bytes
print -n 'BBBBBBBB\n@deep.md\n'       > "$T/home/.claude/mid.md"      # 19 bytes
print -n 'CCCCCCCCCCCCCCCC\n'         > "$T/home/.claude/deep.md"     # 17 bytes
print -n 'RRRR\n'                     > "$T/home/.claude/rules/r.md"  # 5 bytes
print -n 'PPPPPPPP\n'                 > "$T/proj/CLAUDE.md"           # 9 bytes

cat > "$T/home/.claude/skills/alpha/SKILL.md" <<'SK'
---
name: alpha
description: hello
---
a body that must NOT be counted, because only the description is always-on
SK

slug="${T//\//-}-proj"
mkdir -p "$T/home/.claude/projects/$slug/memory"
print -n 'MMMM\n' > "$T/home/.claude/projects/$slug/memory/MEMORY.md"   # 5 bytes

# Reproduce the sandbox mask: a path that EXISTS but is not a readable directory. On the live
# machine ~/.claude/agents is a character device; here a plain file provokes the same branch.
print -n 'x' > "$T/home/.claude/agents"

run() { CONTEXT_FOOTPRINT_HOME="$T/home" CONTEXT_FOOTPRINT_ROOT="$T/proj" \
        CONTEXT_FOOTPRINT_STATE="$T/state.tsv" bash "$TOOL" "$@" 2>&1 }

out=$(run --no-delta)
# 35 = mid.md (18) + deep.md (17). One hop alone would be 18, so this number distinguishes a
# transitive walk from a single-level one -- which is the entire claim being made.
bytes_col() { print -r -- "$1" | awk -v pat="$2" '$0 ~ pat {for(i=1;i<=NF;i++) if($i ~ /%$/) {print $(i-1); exit}}' }
imp=$(bytes_col "$out" "its @imports")
[[ "$imp" == "35" ]] && ok "@imports are resolved TRANSITIVELY (18+17=35, not 18)" \
    || bad "import chain not resolved transitively, got '$imp': $out"

# The load-bearing assertion of the whole tool: an unreadable component must not read as zero.
[[ "$out" == *"agent descriptions"*"UNREADABLE"* ]] \
    && ok "an unreadable component reports UNREADABLE, not 0" || bad "masked dir counted as 0: $out"
[[ "$out" == *"LOWER BOUND"* ]] \
    && ok "an unreadable component downgrades the total to a lower bound" || bad "no lower-bound warning: $out"

# The description is 7 bytes; the body is ~73. Asserting the exact 7 is what makes this able to
# fail -- "the body does not appear in the output" was true of a tool that printed no bodies at all.
sk=$(bytes_col "$out" "skill descriptions")
[[ "$sk" == "7" ]] && ok "only the frontmatter description is counted, not the skill body" \
    || bad "skill bytes should be 7 (description only), got '$sk'"

# Report, do not gate: over budget still exits 0 unless --check is asked for explicitly.
CONTEXT_BUDGET_TOKENS=1 run --no-delta >/dev/null; rc=$?
(( rc == 0 )) && ok "over budget still exits 0 by default (reports, never gates)" || bad "default gated: rc=$rc"
CONTEXT_BUDGET_TOKENS=1 CONTEXT_FOOTPRINT_HOME="$T/home" CONTEXT_FOOTPRINT_ROOT="$T/proj" \
  CONTEXT_FOOTPRINT_STATE="$T/state.tsv" bash "$TOOL" --check --no-delta >/dev/null; rc=$?
(( rc == 1 )) && ok "--check exits 1 when over budget" || bad "--check did not fail over budget: rc=$rc"
CONTEXT_BUDGET_TOKENS=999999 CONTEXT_FOOTPRINT_HOME="$T/home" CONTEXT_FOOTPRINT_ROOT="$T/proj" \
  CONTEXT_FOOTPRINT_STATE="$T/state.tsv" bash "$TOOL" --check --no-delta >/dev/null; rc=$?
(( rc == 0 )) && ok "--check exits 0 when within budget" || bad "--check failed under budget: rc=$rc"

# Delta needs two runs. The first writes state and has nothing to compare against.
rm -f "$T/state.tsv"
run >/dev/null
out=$(run)
[[ "$out" == *"Unchanged since last run"* ]] && ok "a second identical run reports unchanged" \
    || bad "delta missed an unchanged tree: $out"
print -n 'EXTRA-BYTES-HERE\n' >> "$T/proj/CLAUDE.md"
out=$(run)
[[ "$out" == *"Delta since last run: +17"* ]] && ok "delta reports the exact byte growth" \
    || bad "delta wrong after adding 17 bytes: $out"

# A skill reachable from two load paths is one skill. Double-counting it would inflate the very
# component the demote-to-a-skill argument is measured against.
ln -s "$T/home/.claude/skills/alpha" "$T/proj/.claude/skills/alpha-link"
out2=$(run --no-delta)
a=$(bytes_col "$out"  "skill descriptions")
b=$(bytes_col "$out2" "skill descriptions")
[[ "$a" == "$b" ]] && ok "a symlinked skill is counted once, not twice" \
    || bad "symlinked skill double-counted: $a then $b"

out=$(run --json --no-delta)
print -r -- "$out" | jq -e '.total_bytes and .components and .unreadable_components == 1' >/dev/null 2>&1 \
    && ok "--json emits parseable output with the unreadable count" || bad "bad json: $out"

# --- plugin-delivered context (added 2026-09-19) -------------------------------------------------
# Until this date the meter did not look under ~/.claude/plugins/cache at all, so ~14 KB of
# always-on context was missing from a TOTAL that presented itself as a measurement.

mkdir -p "$T/home/.claude/plugins/cache/mkt/onplug/1.0.0/skills/pskill" \
         "$T/home/.claude/plugins/cache/mkt/onplug/1.0.0/commands" \
         "$T/home/.claude/plugins/cache/mkt/offplug/1.0.0/skills/oskill"

cat > "$T/home/.claude/plugins/cache/mkt/onplug/1.0.0/skills/pskill/SKILL.md" <<'SK'
---
name: pskill
description: 123456789
---
body text that must not count
SK
cat > "$T/home/.claude/plugins/cache/mkt/onplug/1.0.0/commands/pcmd.md" <<'CM'
---
name: pcmd
description: 1234
---
CM
cat > "$T/home/.claude/plugins/cache/mkt/offplug/1.0.0/skills/oskill/SKILL.md" <<'SK'
---
name: oskill
description: THIS-MUST-NOT-BE-COUNTED-IT-IS-DISABLED
---
SK

cat > "$T/home/.claude/settings.json" <<'ST'
{
  "enabledPlugins": {
    "onplug@mkt": true,
    "offplug@mkt": false
  }
}
ST

out=$(run --no-delta)
ps=$(bytes_col "$out" "plugin skills")
[[ "$ps" == "11" ]] && ok "an ENABLED plugin's skill description is counted (9 chars + leading space + newline)" \
    || bad "plugin skill bytes should be 11, got '$ps': $out"
[[ "$out" != *"THIS-MUST-NOT-BE-COUNTED"* ]] && (( ps == 11 )) \
    && ok "a DISABLED plugin is not counted (cached on disk, absent from context)" \
    || bad "disabled plugin leaked into the total: $out"
pc=$(bytes_col "$out" "plugin cmds/agents")
[[ "$pc" == "6" ]] && ok "a plugin command description is counted" \
    || bad "plugin cmd bytes should be 6, got '$pc': $out"

# A symlinked skill DIRECTORY. find without -L does not descend into one, so these definitions
# used to vanish silently -- not reported unreadable, simply absent. Four real skills were.
mkdir -p "$T/external/linked"
cat > "$T/external/linked/SKILL.md" <<'SK'
---
name: linked
description: 1234567
---
SK
before=$(bytes_col "$(run --no-delta)" "skill descriptions")
ln -s "$T/external/linked" "$T/home/.claude/skills/linked"
after=$(bytes_col "$(run --no-delta)" "skill descriptions")
(( after - before == 9 )) && ok "a skill behind a symlinked DIRECTORY is counted (find -L)" \
    || bad "symlinked skill dir not counted: $before -> $after (expected +9)"

# The hook-injection channel: output is computed, so it is measured by running the hook.
mkdir -p "$T/home/.claude/plugins/cache/mkt/onplug/1.0.0/hooks"
cat > "$T/home/.claude/plugins/cache/mkt/onplug/1.0.0/hooks/hooks.json" <<'HK'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          { "type": "command", "command": "printf INJECTED-12345" }
        ]
      }
    ]
  }
}
HK
out=$(run --no-delta)
hb=$(bytes_col "$out" "plugin hook injection")
[[ "$hb" == "14" ]] && ok "a plugin SessionStart hook's injected output is measured" \
    || bad "hook injection should be 14 bytes, got '$hb': $out"

# Opting out must not report zero. A zero here is a lie shaped like a measurement.
out=$(CONTEXT_FOOTPRINT_HOME="$T/home" CONTEXT_FOOTPRINT_ROOT="$T/proj" \
      CONTEXT_FOOTPRINT_STATE="$T/state.tsv" bash "$TOOL" --no-hook-probe --no-delta 2>&1)
[[ "$out" == *"plugin hook injection"*"UNREADABLE"* || "$out" == *"not probed"* ]] \
    && ok "--no-hook-probe reports the hook channel UNMEASURED, never 0" \
    || bad "--no-hook-probe reported a hook row as zero/absent: $out"

(( fail )) && { print "FAILURES"; exit 1 }
print "ALL PASS"
