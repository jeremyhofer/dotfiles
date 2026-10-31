#!/usr/bin/env zsh
# Unit test for the status line's usage-window segment.
#
# Which rolling windows a Claude.ai plan has varies: a plan may carry a 5-hour and a 7-day window,
# or only the 7-day one, in which case the payload's rate_limits.five_hour arrives null. The
# failure this test exists to prevent is the segment rendering NOTHING when the 5-hour value is
# absent, which hides the only limit still in force.
set -u
HERE=${0:A:h}
LINE="$HERE/../dot_claude/statusline-command.sh"
[[ -f "$LINE" ]] || { print "FAIL: statusline not found at $LINE"; exit 1 }

fail=0
ok()  { print "ok:   $1" }
bad() { print "FAIL: $1"; fail=1 }

# Drive the real script's own helpers rather than copies, with every color and icon empty so the
# output is plain text. TZ is fixed so the reset renders the same everywhere.
render() {  # render <5h pct> <5h resets> <7d pct> <7d resets>
    TZ=UTC bash -c '
        C_ICON= C_DETAIL= C_CTX_LOW= C_CTX_MED= C_CTX_HIGH= RESET= ICON_WINDOW=W
        '"$(sed -n '/^fmt_epoch()/p' "$LINE")"'
        '"$(sed -n '/^usage_window_seg() {/,/^}/p' "$LINE")"'
        usage_window_seg "$@"
    ' _ "$@"
}

check() {  # check <expected> <description> <args...>
    local want=$1 what=$2; shift 2
    local got; got=$(render "$@")
    [[ "$got" == "$want" ]] && ok "$what -> '$got'" || bad "$what: got '$got', expected '$want'"
}

# 1794042000 is Sat 2026-11-07 09:00 UTC; 1793466000 is Sat 2026-10-31 17:00 UTC.
check 'W  42% · resets 17:00 · 7d 12%' 'both windows: 5-hour headline, 7-day trailing' \
      42 1793466000 12 1794042000
check 'W  3% 7d · resets Sat 09:00'   'only the 7-day window (5-hour null): it is the headline' \
      null null 3 1794042000
check 'W  0% 7d · resets Sat 09:00'   'a 0% weekly window still renders' \
      '' '' 0 1794042000
check 'W  42% · resets 17:00'         'only the 5-hour window' \
      42 1793466000 '' ''
check ''                              'no window at all renders nothing' \
      null null null null

# --- reload band: the cost of a cold prompt cache -------------------------------------------------
# With a 5-hour window the cost is a percentage of it; with none (five_hour null) there is nothing
# for a percentage to be a share of, so the cached depth is shown in tokens. The band thresholds are
# the same depth either way (5% and 10% of the window at each model's rate), so the word and color
# must not move when the unit does.
reload() {  # reload <model> <tokens> <5h pct> -> the segment, plain text
    bash -c '
        C_ICON= C_DETAIL= C_CTX_LOW=LOW: C_CTX_MED=MED: C_CTX_HIGH=HIGH: RESET= ICON_RELOAD=R
        '"$(sed -n '/^reload_seg() {/,/^}/p' "$LINE")"'
        reload_seg "$1" "$2" "$3" "CACHE"
    ' _ "$@"
}
rcheck() {  # rcheck <expected> <description> <args...>
    local want=$1 what=$2; shift 2
    local got; got=$(reload "$@")
    [[ "$got" == "$want" ]] && ok "$what -> '$got'" || bad "$what: got '$got', expected '$want'"
}
rcheck 'R  LOW:2.6% green · CACHE'  '5-hour window present: % of the window, as before' 'Opus 5' 260000 42
rcheck 'R  MED:5.2% amber · CACHE'  '5-hour window present, amber' 'Fable 5' 260000 42
rcheck 'R  HIGH:10.0% red · CACHE'  '5-hour window present, red' 'Opus 5' 1000000 42
rcheck 'R  LOW:260k green · CACHE'  'no 5-hour window (null): depth in tokens' 'Opus 5' 260000 null
rcheck 'R  LOW:260k green · CACHE'  'no 5-hour window (empty): depth in tokens' 'Opus 5' 260000 ''
rcheck 'R  MED:260k amber · CACHE'  'tokens form: same band as the percent form (Fable at 5.2% is amber)' 'Fable 5' 260000 null
rcheck 'R  MED:500k amber · CACHE'  'tokens form: 5% of Opus is 500k, the amber edge' 'Opus 5' 500000 null
rcheck 'R  LOW:499k green · CACHE'  'tokens form: just under the amber edge stays green' 'Opus 5' 499000 null
rcheck 'R  HIGH:1.0M red · CACHE'   'tokens form: 10% of Opus is 1M, the red edge, shown in millions' 'Opus 5' 1000000 null
rcheck 'R  MED:900k amber · CACHE'  'tokens form: Sonnet at 900k is 5.4%, amber' 'Sonnet 5' 900000 null
rcheck 'R  n/a · CACHE'             'unrecognized model renders n/a in either form' 'Mystery 1' 260000 null
rcheck 'R  n/a · CACHE'             'no token figure renders n/a' 'Opus 5' '' null

exit $fail
