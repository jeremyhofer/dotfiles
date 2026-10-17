#!/bin/sh
# test-claude-usage-report.sh -- contract tests for claude-usage-report.
#
# Builds fixture transcripts in a temp tree (CLAUDE_PROJECTS_DIR) and asserts exact figures. The
# cases that matter: a streamed message is written as several records with cumulative usage and must
# count once at each field's maximum; subagent transcripts count apart from the main session; a
# worktree cwd folds into its repository; and no message text ever reaches the output.
#
# Clock: CLAUDE_USAGE_NOW (epoch seconds) is "now"; 2026-10-17T12:00:00Z. TZ is pinned.
#
# Run: sh ~/.local/share/chezmoi/tests/test-claude-usage-report.sh
set -u
TOOL="$(cd "$(dirname "$0")/.." && pwd)/private_dot_local/bin/executable_claude-usage-report"

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (no '$3' in: $2)"; fi; }
lacks() { if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 ('$3' present)"; else ok "$1"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }

w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
export HOME="$w/home" CLAUDE_PROJECTS_DIR="$w/projects" CLAUDE_USAGE_HISTORY="$w/history.jsonl"
export CLAUDE_USAGE_NOW=1792238400 TZ=UTC
mkdir -p "$HOME" "$CLAUDE_PROJECTS_DIR"

# Fixture builder. rec FILE ID MODEL TS OUT CR IN CC [CWD] [SIDECHAIN_AGENT]
cat > "$w/mk.py" <<'PY'
import json, sys
f, mid, model, ts, out, cr, inp, cc = sys.argv[1:9]
cwd = sys.argv[9] if len(sys.argv) > 9 else ""
agent = sys.argv[10] if len(sys.argv) > 10 else ""
r = {"type": "assistant", "timestamp": ts, "sessionId": "sess1",
     "message": {"id": mid, "model": model,
                 "content": [{"type": "text", "text": "SECRETPLANT-do-not-print"}],
                 "usage": {"input_tokens": int(inp), "output_tokens": int(out),
                           "cache_creation_input_tokens": int(cc),
                           "cache_read_input_tokens": int(cr)}}}
if cwd: r["cwd"] = cwd
if agent: r["isSidechain"] = True; r["agentId"] = agent
open(f, "a").write(json.dumps(r) + "\n")
PY
rec() { python3 "$w/mk.py" "$@"; }

A="$CLAUDE_PROJECTS_DIR/-home-a"; B="$CLAUDE_PROJECTS_DIR/-home-b"
mkdir -p "$A/sess1/subagents" "$B"
WT="$HOME/Devel/a/.worktrees/w1/sub"
# Project A, main session: m1 streamed in 3 records, out peaks in the MIDDLE one (max, not last).
rec "$A/sess1.jsonl" m1 claude-opus 2026-10-16T10:00:00Z 10 1000 1 0 "$WT"
rec "$A/sess1.jsonl" m1 claude-opus 2026-10-16T10:00:01Z 100 2000 5 300 "$WT"
rec "$A/sess1.jsonl" m1 claude-opus 2026-10-16T10:00:02Z 50 2000 5 300 "$WT"
rec "$A/sess1.jsonl" m2 claude-sonnet 2026-10-16T11:00:00Z 20 500 2 0 "$HOME/Devel/a"
rec "$A/sess1.jsonl" syn '<synthetic>' 2026-10-16T11:30:00Z 0 0 0 0 "$HOME/Devel/a"
printf 'this is not json {{{\n{"type":"assistant","timestamp":"2026-10-16T11:40:00Z"}\n{"type":"user","message":{"content":"SECRETPLANT-user"}}\n' >> "$A/sess1.jsonl"
# Subagents of that session.
rec "$A/sess1/subagents/agent-x1.jsonl" m3 claude-sonnet 2026-10-16T10:30:00Z 7 100 0 0 "$WT" x1
rec "$A/sess1/subagents/agent-x1.jsonl" m3 claude-sonnet 2026-10-16T10:30:01Z 7 150 0 0 "$WT" x1
printf '{"agentType":"Explore","description":"SECRETPLANT-meta"}\n' > "$A/sess1/subagents/agent-x1.meta.json"
rec "$A/sess1/subagents/agent-x2.jsonl" m4 claude-haiku 2026-10-16T10:40:00Z 3 10 0 0 "$WT" x2
# Project C: a cwd below a repository root (it has a .git entry) folds up to the root.
C="$CLAUDE_PROJECTS_DIR/-home-c"; mkdir -p "$C" "$HOME/Devel/c/.git" "$HOME/Devel/c/pkg/deep"
rec "$C/s3.jsonl" c1 claude-opus 2026-10-16T09:00:00Z 5 5 0 0 "$HOME/Devel/c/pkg/deep"
rec "$C/s3.jsonl" c2 claude-opus 2026-10-16T09:01:00Z 5 5 0 0 "$HOME/Devel/c/.worktrees/x/pkg"
# Project B has no cwd (falls back to the key name): one record in window, one ten days ago.
rec "$B/s2.jsonl" b1 claude-opus 2026-10-14T20:00:00Z 1000 4000 0 0
rec "$B/s2.jsonl" b2 claude-opus 2026-10-05T10:00:00Z 9999 9999 9 9

# History: 10-16 starts at 40%, ends at 55%; 10-15 has two lines.
python3 - "$CLAUDE_USAGE_HISTORY" <<'PY'
import json, sys, calendar, time
def ep(s): return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
rows = [("2026-10-15T09:00:00Z", 10, 30), ("2026-10-15T20:00:00Z", 80, 38),
        ("2026-10-16T08:00:00Z", 20, 40), ("2026-10-16T18:00:00Z", 60, 55)]
with open(sys.argv[1], "w") as f:
    for t, five, seven in rows:
        f.write(json.dumps({"ts": ep(t), "five_hour_pct": five, "seven_day_pct": seven}) + "\n")
    f.write("garbage\n")
PY

# jq-less extraction from the JSON output: js 'python expr over d' [args...]
js() { e=$1; shift; python3 "$TOOL" --json "$@" | python3 -c "import json,sys; d=json.load(sys.stdin); print($e)"; }

echo "claude-usage-report:"

# 1) Dedup: m1 counts once at the per-field max; project A main = m1 + m2.
eq "dedup: output max, not sum or last" "$(js "d['projects']['~/Devel/a']['main']['output']")" 120
eq "dedup: cache-read" "$(js "d['projects']['~/Devel/a']['main']['cache_read']")" 2500
eq "dedup: cache-creation" "$(js "d['projects']['~/Devel/a']['main']['cache_creation']")" 300
eq "dedup: input" "$(js "d['projects']['~/Devel/a']['main']['input']")" 7
eq "dedup: messages (synthetic, no-usage skipped)" "$(js "d['projects']['~/Devel/a']['main']['messages']")" 2

# 2) Subagent split, spawn count, project fold.
eq "split: subagent output" "$(js "d['projects']['~/Devel/a']['subagent']['output']")" 10
eq "split: subagent cache-read (max of cumulative)" "$(js "d['projects']['~/Devel/a']['subagent']['cache_read']")" 160
eq "split: subagent messages" "$(js "d['projects']['~/Devel/a']['subagent']['messages']")" 2
eq "split: distinct subagents" "$(js "d['projects']['~/Devel/a']['subagents_spawned']")" 2
eq "fold: worktree cwd merged into repo (one project row for A)" "$(js "sorted(d['projects'])")" "['-home-b', '~/Devel/a', '~/Devel/c']"
eq "fold: subdirectory and worktree both reach the .git root" "$(js "d['projects']['~/Devel/c']['main']['messages']")" 2
eq "fold: model mix" "$(js "d['projects']['~/Devel/a']['models']")" "{'claude-haiku': 1, 'claude-opus': 1, 'claude-sonnet': 2}"
eq "fallback: no cwd uses key name" "$(js "d['projects']['-home-b']['main']['output']")" 1000

# 3) Windows.
eq "window: default 7 days excludes the 10-day-old record" "$(js "d['projects']['-home-b']['main']['messages']")" 1
eq "window: --days 30 includes it" "$(js "d['projects']['-home-b']['main']['messages']" --days 30)" 2
eq "window: --since 2026-10-15 drops B" "$(js "sorted(d['projects'])" --since 2026-10-15)" "['~/Devel/a', '~/Devel/c']"
eq "window: --since 2026-10-14 keeps B" "$(js "sorted(d['projects'])" --since 2026-10-14)" "['-home-b', '~/Devel/a', '~/Devel/c']"

# 4) Days, local time.
eq "days: UTC buckets" "$(js "sorted(d['days'])")" "['2026-10-14', '2026-10-16']"
eq "days: UTC totals for 10-16 (main out)" "$(js "d['days']['2026-10-16']['main']['output']")" 130
eq "days: local time (Tokyo moves B to 10-15)" "$(TZ=Asia/Tokyo js "sorted(d['days'])")" "['2026-10-15', '2026-10-16']"

# 5) Subagent groups.
eq "types: Explore from meta.json" "$(js "d['subagents']['by_type']['Explore']['count']")" 1
eq "types: missing meta is unknown" "$(js "d['subagents']['by_type']['unknown']['count']")" 1
eq "types: tokens per type" "$(js "d['subagents']['by_type']['Explore']['output']")" 7
eq "types: by model" "$(js "d['subagents']['by_model']['claude-haiku']['output']")" 3

# 6) Sessions: top by cache-read + output, subagents included.
eq "sessions: ranked by cache-read + output" "$(js "[s['session'] for s in d['sessions']]")" "['s2', 'sess1', 's3']"
eq "sessions: rank figure includes subagents" "$(js "d['sessions'][1]['cache_read_plus_output']")" 2790
eq "sessions: subagent count" "$(js "d['sessions'][1]['subagents']")" 2
eq "sessions: first timestamp" "$(js "d['sessions'][1]['first']")" 2026-10-16T10:00:00Z
eq "sessions: last timestamp" "$(js "d['sessions'][1]['last']")" 2026-10-16T11:00:00Z
eq "sessions: model mix" "$(js "d['sessions'][1]['models']")" "{'claude-haiku': 1, 'claude-opus': 1, 'claude-sonnet': 2}"
eq "sessions: all listed (under 10)" "$(js "len(d['sessions'])")" 3

# 7) History.
eq "history: first seven-day on 10-16" "$(js "d['limits']['2026-10-16']['seven_day_first']")" 40
eq "history: last seven-day on 10-16" "$(js "d['limits']['2026-10-16']['seven_day_last']")" 55
eq "history: delta" "$(js "d['limits']['2026-10-16']['seven_day_delta']")" 15
eq "history: max five-hour on 10-15" "$(js "d['limits']['2026-10-15']['five_hour_max']")" 80
rm -f "$CLAUDE_USAGE_HISTORY"
eq "history absent: json null" "$(js "d['limits']")" None
out=$(python3 "$TOOL"); rc=$?
eq "history absent: exit 0" "$rc" 0
has "history absent: one-line note" "$out" "no usage history"

# 8) Human output.
has "human: project row" "$out" "~/Devel/a"
has "human: thousands separator" "$out" "2,500"
has "human: explains cache-read" "$out" "cache-read"
has "human: states the blind spot" "$out" "price"
lacks "human: no transcript text" "$out" "SECRETPLANT"
all=$(python3 "$TOOL" --days 30; python3 "$TOOL" --json --days 30)
lacks "no text anywhere (json too, meta description too)" "$all" "SECRETPLANT"

# 9) Robustness and usage.
eq "malformed lines do not fail the run" "$(python3 "$TOOL" >/dev/null 2>&1; echo $?)" 0
python3 "$TOOL" --bogus >/dev/null 2>&1; eq "bad flag exits 2" "$?" 2
CLAUDE_PROJECTS_DIR="$w/nothing" python3 "$TOOL" >/dev/null 2>&1; eq "missing root exits 0" "$?" 0

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ] && echo PASS
[ "$fail" -eq 0 ]
