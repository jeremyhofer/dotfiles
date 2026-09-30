#!/usr/bin/env bash
# Claude Code status line — ~/.claude/statusline-command.sh
# Shown at the bottom of the Claude Code window.
#
# Color palette: Gruvbox dark.
# Icons: Nerd Font BMP glyphs (requires a Nerd Font).

input=$(cat)

# An optional usage-state writer, if installed, persists the usage slice of this payload for hooks
# that read it. Hooks receive no usage data of their own, so this render is their only source.
# Guarded and backgrounded-free: the writer is silent and always exits 0, and if it is missing the
# status line renders exactly as before.
if [ -x "$HOME/.local/bin/claude-usage-state" ]; then
  printf '%s' "$input" | "$HOME/.local/bin/claude-usage-state" >/dev/null 2>&1 || true
fi

# Model: short display name
model=$(echo "$input" | jq -r '.model.display_name // empty')

# Working directory: the LAST TWO path segments, not the basename.
#
# Under the bare-container repo layout a repo is <repo>/<branch>, so every session
# sits in a directory called after its branch and basename renders "main" for all of
# them -- the segment stops identifying anything. Two segments name the repo as well:
# "repo-a/main", "repo-b/feature-x". It also reads better for ordinary checkouts,
# where "org/repo-a" beats a bare "repo-a".
#
# $HOME collapses to ~ first, so a path directly under home shows "~/Devel" rather
# than leaking the account name as a segment.
# Two-spelling helpers. This file runs on both a GNU userland and a BSD/macOS one, and a
# GNU-only spelling does not DEGRADE there -- it errors and prints nothing. So a call guarded
# with 2>/dev/null silently yields an EMPTY STRING and the caller renders something wrong
# rather than failing. GNU first, BSD second: on each platform one branch errors and the
# other answers, and the caller never knows which.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
fmt_epoch()  { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null; }

path_tail() {
  local p="$1"
  case "$p" in
    "$HOME")   printf '~';     return ;;
    "$HOME"/*) p="~${p#"$HOME"}" ;;
  esac
  p="${p%/}"                                  # drop any trailing slash
  case "$p" in
    ''|'/') printf '%s' "${1:-}"; return ;;    # "" and "/" render as themselves
  esac
  local base="${p##*/}" parent="${p%/*}"
  if [ -z "$parent" ]; then
    printf '%s' "$base"                        # single segment, e.g. "/mnt" or "~"
  else
    printf '%s/%s' "${parent##*/}" "$base"
  fi
}

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
dir_name=$(path_tail "$cwd")

# Git branch
git_worktree=$(echo "$input" | jq -r '.workspace.git_worktree // empty')
if [ -n "$git_worktree" ]; then
  branch="$git_worktree"
elif [ -d "$cwd/.git" ] || git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git --no-optional-locks -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
            || git --no-optional-locks -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

# Context window: pre-computed % + raw token counts
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
used_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
max_tokens=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

# Effort level (reasoning models only)
effort=$(echo "$input" | jq -r '.effort.level // empty')

# This session's transcript. Its mtime is the last message actually written for THIS session, which
# is the prompt cache’s real TTL clock — see cache_state().
transcript=$(echo "$input" | jq -r '.transcript_path // empty')

# Account-wide rolling limits. THIS PAYLOAD IS THE ONLY PLACE THEY APPEAR -- no hook receives them,
# which is why claude-usage-state (above) exists to persist them for the ramp-down gates. Rendering
# them here closes the other half of that gap: the numbers the gates act on are now also visible to
# the human before a gate fires, rather than only in the message that says it already has.
#
# Present only for Claude.ai subscription accounts, and only after the first API response of a
# session, so every field is optional and the whole segment is omitted when absent -- never
# rendered as 0%, which would read as "plenty left" at exactly the wrong moment.
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# --- Helper: when the prompt cache goes cold -------------------------------------------------
# The reload band below says what walking away COSTS. This says WHEN that cost starts applying:
# the cache TTL is one hour, sliding, refreshed free on every read, so it expires an hour after
# this session's last request.
#
# PER SESSION, NOT GLOBAL. The cache is keyed by prompt prefix, so each session has its own entry
# and its own expiry; one session being busy does nothing for another's warmth. This line is
# rendered per session with that session's own payload, so switching agents in the TUI shows that
# agent's clock.
#
# MEASURED FROM THE TRANSCRIPT, NOT FROM NOW, and that distinction is the whole correctness of it.
# An earlier version used render time (`now + 1h`), which is only right when a render coincides
# with a request. It does not always: the status line re-renders for the session being DISPLAYED,
# so attaching to a long-idle agent would have redrawn "warm to <an hour from now>" for a cache
# that went cold hours ago -- confidently, and at exactly the moment the number is load-bearing.
# The transcript's mtime is the last time a message was actually written for THIS session, which
# is the real TTL clock and does not move when a session is merely looked at. Verified: an active
# session's transcript was 12s old while a live-but-idle one's was over five hours old.
#
# ABSOLUTE TIME, NEVER A COUNTDOWN. The status line renders on activity, not on a timer, so an
# idle session stops re-rendering entirely. A countdown would freeze at whatever it said when work
# stopped and rot into a lie -- reading "expires in 45m" an hour later. A wall-clock instant stays
# true however long the line sits frozen.
cache_state() {
  local base now target
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    base=$(file_mtime "$transcript")
  fi
  # No transcript path (older client, or an unreadable file): fall back to render time. That is the
  # weaker signal this helper exists to avoid, so it is a fallback rather than the default.
  [ -n "${base:-}" ] || base=$(date +%s)
  now=$(date +%s)
  target=$((base + 3600))
  # Emits the WHOLE phrase, not a bare time spliced after a fixed "warm to" label -- an earlier
  # version did that and rendered "warm to cold" for an expired cache.
  if [ "$target" -le "$now" ]; then
    printf 'cold'          # already expired -- say so, rather than printing a time in the past
  else
    printf 'warm to %s' "$(fmt_epoch "$target" '%H:%M' || printf '?')"
  fi
}

# --- Helper: format a token count. <1k → digits, <10k → 1 decimal k,
# <1M → integer k, ≥1M → integer (or 1-decimal) M ---
fmt_tokens() {
  local n="$1"
  if [ -z "$n" ] || [ "$n" = "null" ]; then
    printf ''
  elif [ "$n" -lt 1000 ]; then
    printf '%d' "$n"
  elif [ "$n" -lt 10000 ]; then
    awk -v n="$n" 'BEGIN { printf "%.1fk", n/1000 }'
  elif [ "$n" -lt 1000000 ]; then
    awk -v n="$n" 'BEGIN { printf "%dk", n/1000 + 0.5 }'
  else
    awk -v n="$n" 'BEGIN {
      m = n/1000000
      if (m < 10) printf "%.1fM", m
      else printf "%dM", m + 0.5
    }'
  fi
}

# --- ANSI 16-color codes (the terminal maps these to its configured palette) ---
# Using ANSI codes instead of truecolor hex so the terminal resolves them through
# your [colors.normal] / [colors.bright] config — guaranteeing the same
# rendering as your oh-my-zsh prompt (which uses the same ANSI codes).
# Bold + cyan/red here = whatever bold-cyan/bold-red looks like in your prompt.
RESET=$'\033[0m'
C_DIR=$'\033[1;36m'      # bold cyan — matches prompt dir ($fg_bold[cyan])
C_BRANCH=$'\033[1;31m'   # bold red  — matches prompt branch ($fg_bold[red])
C_MODEL=$'\033[1;35m'    # bold magenta — Claude model
C_CTX_LOW=$'\033[1;32m'  # bold green — context < 50%
C_CTX_MED=$'\033[1;33m'  # bold yellow — context 50-80%
C_CTX_HIGH=$'\033[1;31m' # bold red — context > 80% (same as branch)
C_EFFORT=$'\033[2;37m'   # dim white — effort indicator
C_DETAIL=$'\033[2;37m'   # dim white — secondary detail (token counts)
C_SEP=$'\033[37m'        # normal white (warm gray) — field separator
C_ICON=$'\033[2;37m'     # dim white — icons (quietly visible)

# --- Nerd Font icons ---
# Using bash $'\uXXXX' escape syntax so the source file stays plain ASCII
# (Claude's Write tool strips Private-Use-Area chars from literal $'...'
# strings; PUA is exactly where Nerd Font icons live, U+E000-F8FF).
# Bash decodes \uXXXX at runtime to the proper UTF-8 byte sequence.
ICON_DIR=$''        #  folder (Font Awesome)
ICON_BRANCH=$''     #  branch (Powerline)
ICON_MODEL=$''      #  microchip
ICON_CTX=$''        #  bar chart
ICON_EFFORT=$''     #  lightning bolt
ICON_RELOAD=$'\u27f3'  # ⟳ clockwise open circle arrow -- BMP, not Private Use Area,
                       # so it survives tools that strip PUA and renders without a Nerd Font.
ICON_WINDOW=$'\u23f1'  # \u23f1 stopwatch -- BMP, same reason as ICON_RELOAD.
SEP=$'│'              # │ box-drawing light vertical

# --- Build the line ---
parts=()

# Directory + branch
dir_seg="${C_ICON}${ICON_DIR}${RESET}  ${C_DIR}${dir_name}${RESET}"
if [ -n "$branch" ]; then
  dir_seg="${dir_seg}  ${C_ICON}${ICON_BRANCH}${RESET}  ${C_BRANCH}${branch}${RESET}"
fi
parts+=("$dir_seg")

# Model
[ -n "$model" ] && parts+=("${C_ICON}${ICON_MODEL}${RESET}  ${C_MODEL}${model}${RESET}")

# Context: " 42% · 84k/200k" with graded color on the percent
if [ -n "$used_pct" ]; then
  used_int=$(printf '%.0f' "$used_pct")
  if [ "$used_int" -lt 50 ]; then
    ctx_color="$C_CTX_LOW"
  elif [ "$used_int" -lt 80 ]; then
    ctx_color="$C_CTX_MED"
  else
    ctx_color="$C_CTX_HIGH"
  fi
  ctx_seg="${C_ICON}${ICON_CTX}${RESET}  ${ctx_color}${used_int}%${RESET}"
  # Append token detail if both numbers are available
  if [ -n "$used_tokens" ] && [ -n "$max_tokens" ] && [ "$max_tokens" != "null" ]; then
    ctx_seg="${ctx_seg} ${C_DETAIL}· $(fmt_tokens "$used_tokens")/$(fmt_tokens "$max_tokens")${RESET}"
  fi
  parts+=("$ctx_seg")
fi

# --- Rolling usage window: "N% of the 5-hour window spent, and when it resets" ---------------
# The 5-hour window is ACCOUNT-WIDE, not per-session: a second session working in parallel
# spends the same budget. That is precisely why it belongs on screen continuously rather than
# only inside the ramp-down hook's message, which by definition arrives once the budget is
# already nearly gone.
#
# Same convention as the reload band below -- the number is the payload and colour is only
# reinforcement -- with one addition: the reset time is rendered as plain wall-clock text, because
# "when can I work again" is the actual question, and an epoch stamp does not answer it.
#
# UNLIKE the reload band, this value DOES have gates attached (ramp-down hooks read the
# persisted copy written at the top of this file). Showing it here does not add a gate; it means
# the human can see the same number the gate will act on, before it acts.
if [ -n "$five_pct" ] && [ "$five_pct" != "null" ]; then
  five_int=$(printf '%.0f' "$five_pct")
  if [ "$five_int" -lt 50 ]; then
    win_color="$C_CTX_LOW"
  elif [ "$five_int" -lt 80 ]; then
    win_color="$C_CTX_MED"
  else
    win_color="$C_CTX_HIGH"
  fi
  win_seg="${C_ICON}${ICON_WINDOW}${RESET}  ${win_color}${five_int}%${RESET}"
  if [ -n "$five_resets" ] && [ "$five_resets" != "null" ]; then
    reset_hhmm=$(fmt_epoch "$five_resets" '%H:%M')
    [ -n "$reset_hhmm" ] && win_seg="${win_seg} ${C_DETAIL}· resets ${reset_hhmm}${RESET}"
  fi
  # Weekly window, dim: it is the limit that actually bites across a working week, but it moves
  # slowly enough to be detail rather than headline.
  if [ -n "$seven_pct" ] && [ "$seven_pct" != "null" ]; then
    win_seg="${win_seg} ${C_DETAIL}· 7d $(printf '%.0f' "$seven_pct")%${RESET}"
  fi
  parts+=("$win_seg")
fi

# --- Reload band: "walking away right now costs N% of a 5-hour window" ------
# The prompt cache is a sliding window refreshed for free on every read, so continuous work never
# pays. Crossing an idle gap longer than the cache TTL rebuilds the whole context at 2x input
# price, once, in proportion to how deep the session is. That -- not context fill and not quota --
# is the only thing about a long session that costs real money.
#
#   reload % of a 5-hour window ~= depth / rate
#   rate: Fable 5 50k · Opus 5 100k · Sonnet 5 167k · Haiku 4.5 500k
#   < 5% green (ignore) · 5-10% amber (shed depth only at a natural boundary) · >= 10% red
#
# THE PERCENTAGE IS THE PAYLOAD; COLOUR IS REINFORCEMENT ONLY. The band word is printed as text
# for exactly that reason: a colour-only signal cannot be read by someone with limited colour
# vision, and cannot be verified by anyone from a screenshot or a copied line.
#
# NOTHING GATES ON THIS VALUE. No hook blocks, no auto-park, no injected instruction. It is
# ambient exposure -- it cannot know whether the user is about to walk away, and a gate calibrated
# from a single observation would manufacture confidence it has not earned.
#
# Matched on the model FAMILY, so "Opus 5 (1M context)" resolves like "Opus 5". An unrecognised
# model renders "n/a" rather than borrowing another model's rate: a wrong number here is worse
# than no number, because it reads exactly as authoritative as a right one.
case "$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')" in
  *fable*)  reload_rate=50000  ;;
  *opus*)   reload_rate=100000 ;;
  *sonnet*) reload_rate=167000 ;;
  *haiku*)  reload_rate=500000 ;;
  *)        reload_rate=       ;;
esac

if [ -n "$reload_rate" ] && [ -n "$used_tokens" ] && [ "$used_tokens" != "null" ]; then
  reload_pct=$(awk -v d="$used_tokens" -v r="$reload_rate" 'BEGIN { printf "%.1f", d/r }')
  # Band is derived from the SAME rounded value that is displayed, so the word can never
  # contradict the number on screen. The cost is deliberate: 4.99% renders "5.0% amber" rather
  # than "5.0% green" -- a reader can only act on what they can actually see, and a word that
  # disagrees with the number beside it is worse than half a percent of imprecision.
  band=$(awk -v p="$reload_pct" 'BEGIN { print (p < 5) ? "green" : (p < 10) ? "amber" : "red" }')
  case "$band" in
    green) band_color="$C_CTX_LOW"  ;;
    amber) band_color="$C_CTX_MED"  ;;
    *)     band_color="$C_CTX_HIGH" ;;
  esac
  parts+=("${C_ICON}${ICON_RELOAD}${RESET}  ${band_color}${reload_pct}%${RESET} ${C_DETAIL}${band} · $(cache_state)${RESET}")
else
  parts+=("${C_ICON}${ICON_RELOAD}${RESET}  ${C_DETAIL}n/a · $(cache_state)${RESET}")
fi

# Effort (reasoning models only)
[ -n "$effort" ] && parts+=("${C_ICON}${ICON_EFFORT}${RESET}  ${C_EFFORT}${effort}${RESET}")

# Join with subtle separator
printf '%s' "${parts[0]}"
for part in "${parts[@]:1}"; do
  printf '  %s%s%s  %s' "$C_SEP" "$SEP" "$RESET" "$part"
done
printf '\n'
