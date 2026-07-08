#!/bin/sh
# bootstrap-mac.sh — generic, publish-safe macOS setup core. Personal/work specifics are
# injected POST-chezmoi from the overlay's ~/.dotlocal/bootstrap.d/*.sh. This file lives in
# the PUBLIC dotfiles base and must contain ZERO personal-infra references (no private mounts,
# hosts, keys, stores, or machine names) — the publish-boundary invariant.
#
# Foundation (Xcode CLT + Homebrew) is domain-gated: on `personal` it auto-installs via the
# standard public methods; on `work` (managed/bespoke install) it checks + instructs. Domain
# is read from ~/.config/chezmoi/chezmoi.toml. Run this from a checkout of the base repo:
#   sh bootstrap-mac.sh     (chezmoi source = this repo; the overlay is set up by chezmoi).
set -eu

log() { printf '\n=== %s ===\n' "$1"; }
die() { printf 'bootstrap-mac: %s\n' "$1" >&2; exit 1; }

DOMAIN="$(sed -n 's/^[[:space:]]*domain[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$HOME/.config/chezmoi/chezmoi.toml" 2>/dev/null || echo personal)"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Foundation: Xcode CLT + Homebrew (domain-gated; standard public install = universal, not
#     a personal specific, so branching here is publish-safe). ---
ensure_foundation() {
  log "foundation (CLT + Homebrew) — domain=$DOMAIN"
  if ! xcode-select -p >/dev/null 2>&1; then
    if [ "$DOMAIN" = personal ]; then
      echo "installing CLT — confirm the GUI prompt, then re-run"; xcode-select --install || true; exit 0
    else
      die "Xcode CLT missing — install via the managed/bespoke method, then re-run (work)"
    fi
  fi
  echo "CLT present"
  if [ -x /opt/homebrew/bin/brew ] || command -v brew >/dev/null 2>&1; then
    echo "brew present"
  elif [ "$DOMAIN" = personal ]; then
    echo "installing Homebrew"; /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    die "Homebrew missing — install via the managed/bespoke method, then re-run (work)"
  fi
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
}

# --- brew bundle: base (this repo) + the domain's role fragment (from the overlay). ---
ensure_bundle() {
  log "brew bundle (base + role)"
  # --adopt: adopt an already-installed app into brew mgmt instead of erroring on conflict.
  HOMEBREW_CASK_OPTS="--adopt" brew bundle --file "$REPO_DIR/Brewfile"
  role="$HOME/.dotlocal/Brewfile.role"
  if [ -f "$role" ]; then
    HOMEBREW_CASK_OPTS="--adopt" brew bundle --file "$role"
  else
    echo "no role Brewfile at $role yet (overlay not applied?) — base only"
  fi
}

# --- default Node via fnm (per-project is the norm; a default LTS is convenient + mmdc needs a
#     node runtime). Idempotent. ---
ensure_node() {
  log "default Node (fnm)"
  command -v fnm >/dev/null 2>&1 || { echo "fnm not on PATH (did brew bundle run?) — skipping"; return 0; }
  if fnm ls 2>/dev/null | grep -qE 'v[0-9]'; then
    echo "fnm: node already installed"
  else
    fnm install --lts && echo "fnm: installed latest LTS"
  fi
  ver="$(fnm ls 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
  [ -n "$ver" ] && fnm default "$ver" >/dev/null 2>&1 && echo "fnm: default -> $ver"
}

# --- chezmoi: init/apply from THIS repo (its own location — no hardcoded source URL, so no
#     private-host reference). apply's run_once sets up the overlay + its private stores. ---
ensure_chezmoi() {
  log "chezmoi"
  # --no-pager: an apply/update diff must never block a near-unattended bootstrap in a pager.
  if [ -d "$HOME/.local/share/chezmoi/.git" ]; then
    chezmoi --no-pager update --verbose
  else
    chezmoi --no-pager init "$REPO_DIR" --apply --verbose
  fi
  # The overlay's setup run_once fires only on first apply; refresh it explicitly on re-runs.
  OSRC="$HOME/.local/share/chezmoi-overlay"; OCFG="$HOME/.config/chezmoi/overlay"
  if [ -d "$OSRC/.git" ] && [ -f "$OCFG/chezmoi.toml" ]; then
    echo "chezmoi: refreshing overlay (2nd instance)"
    git -C "$OSRC" pull --ff-only 2>/dev/null || true
    chezmoi --no-pager --config "$OCFG/chezmoi.toml" --source "$OSRC" \
      --persistent-state "$OCFG/chezmoistate.boltdb" --cache "$HOME/.cache/chezmoi/overlay" apply || true
  fi
}

# --- overlay extension stages: run ~/.dotlocal/bootstrap.d/*.sh (numbered, lexical) if present.
#     These are the personal/work specifics, all POST-chezmoi (the overlay deploys them). ---
run_bootstrapd() {
  d="$HOME/.dotlocal/bootstrap.d"
  if [ ! -d "$d" ]; then echo "no bootstrap.d — no overlay stages (core-only)"; return 0; fi
  for s in "$d"/*.sh; do
    [ -f "$s" ] || continue
    log "bootstrap.d: $(basename "$s")"
    sh "$s"
  done
}

main() {
  ensure_foundation
  ensure_bundle
  ensure_node
  ensure_chezmoi
  run_bootstrapd
  log "bootstrap-mac complete"
}
main "$@"
