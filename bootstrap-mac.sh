#!/bin/sh
# bootstrap-mac.sh — generic, publish-safe macOS setup core. Personal/work specifics are
# injected POST-chezmoi from the overlay's ~/.dotlocal/bootstrap.d/*.sh. This file lives in
# the PUBLIC dotfiles base and must contain ZERO personal-infra references (no private mounts,
# hosts, keys, stores, or machine names) — the publish-boundary invariant.
#
# Foundation (Xcode CLT + Homebrew) is domain-gated: on `personal` it auto-installs via the
# standard public methods; on `work` it checks and instructs instead of installing. Domain
# is read from ~/.config/chezmoi/chezmoi.toml. Run this from a checkout of the base repo:
#   sh bootstrap-mac.sh     (chezmoi source = this repo; the overlay is set up by chezmoi).
#   sh bootstrap-mac.sh node chezmoi    (only the named stages, in the order given; the stages are
#                                        foundation, bundle, node, chezmoi, bootstrapd)
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
      die "Xcode CLT missing — this domain installs it outside this script; install it, then re-run"
    fi
  fi
  echo "CLT present"
  if [ -x /opt/homebrew/bin/brew ] || command -v brew >/dev/null 2>&1; then
    echo "brew present"
  elif [ "$DOMAIN" = personal ]; then
    echo "installing Homebrew"; /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    die "Homebrew missing — this domain installs it outside this script; install it, then re-run"
  fi
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
}

# --- brew bundle: base (this repo) + the domain's role fragment (from the overlay). ---
ensure_bundle() {
  log "brew bundle (base; base includes ~/.dotlocal/Brewfile.role if the overlay deployed one)"
  # The base Brewfile is the standalone standard and self-includes the machine's optional private
  # role file, so one bundle installs both. Before the overlay is applied that role file is absent
  # and this is base-only (re-run after the guarded apply to pick the role up). Cleanup mirrors this:
  #   brew bundle cleanup --file "$REPO_DIR/Brewfile"   (dry-run; add --force to apply)
  # --adopt: adopt an already-installed app into brew mgmt instead of erroring on conflict.
  HOMEBREW_CASK_OPTS="--adopt" brew bundle --file "$REPO_DIR/Brewfile"
}

# --- Is this machine switched to mise? miseActive in the [data] of the generated base chezmoi config,
#     the per-machine switch, never prompted; absent or false means not switched. On a new machine
#     this stage runs before chezmoi has written that config, so a new machine is never switched: it
#     takes the fnm path, as every machine did before mise, and is switched later by setting the key
#     and re-running. The rule is the same one wt-bootstrap applies, and reads with builtins only. ---
mise_switched() {
  cfg="$HOME/.config/chezmoi/chezmoi.toml"
  [ -f "$cfg" ] || return 1
  tab=$(printf '\t')
  while IFS=" $tab=" read -r key value _rest || [ -n "$key" ]; do
    if [ "$key" = miseActive ] && [ "$value" = true ]; then return 0; fi
  done < "$cfg"
  return 1
}

# --- The Node pin the apply's suites run under (tests/apply-suites.py reads the same one): [tools]
#     node in this repository's mise.toml, else .nvmrc while that file still exists. Both present and
#     disagreeing stops the bootstrap, naming both. Prints nothing when neither pins Node.
#     The mise.toml reader takes the way a pin is written, `node = "<version>"` (single quotes, a
#     quoted key and a trailing comment allowed) under a [tools] header, or `tools.node = "<version>"`
#     before any header. Any other value of that key, and a [tools.node] table, stop the bootstrap
#     rather than being guessed at, as apply-suites.py refuses them. Builtins only. ---
trim() {
  t=$1
  t=${t#"${t%%[![:space:]]*}"}
  printf '%s' "${t%"${t##*[![:space:]]}"}"
}

check_version() {  # check_version <value> <where>: prints the value without a leading v
  v=${1#v}
  case "$v" in
    '' | *[!0-9.]* | .* | *. | *..* | *.*.*.*) die "$2 holds '$1', not a version number" ;;
  esac
  printf '%s' "$v"
}

toml_node_pin() {
  f="$REPO_DIR/mise.toml"
  [ -f "$f" ] || return 0
  table=""
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(trim "$line")
    case "$line" in
      '#'* | '') continue ;;
      '['*)
        table=${line%%]*}; table=$(trim "${table#[}")
        case "$table" in
          tools.node | 'tools."node"') die "mise.toml pins Node in a [tools.node] table, which this reader cannot take: write node = \"<version>\" under [tools]" ;;
        esac
        continue ;;
    esac
    key=$(trim "${line%%=*}")
    case "$table/$key" in tools/node | 'tools/"node"' | "tools/'node'" | /tools.node) ;; *) continue ;; esac
    value=$(trim "${line#*=}")
    case "$value" in
      '"'*) q='"' ;;
      "'"*) q="'" ;;
      *) die "mise.toml's [tools] node is $value, which this reader cannot take: write it as node = \"<version>\"" ;;
    esac
    value=${value#"$q"}
    rest=$(trim "${value#*"$q"}")
    case "$rest" in '' | '#'*) ;; *) die "mise.toml's [tools] node line is not one this reader can take: $line" ;; esac
    check_version "${value%%"$q"*}" "mise.toml's [tools] node"
    return 0
  done < "$f"
}

node_pin() {
  from_toml=$(toml_node_pin) || exit 1
  from_nvmrc=""
  if [ -f "$REPO_DIR/.nvmrc" ]; then
    from_nvmrc=$(check_version "$(trim "$(cat "$REPO_DIR/.nvmrc")")" .nvmrc) || exit 1
  fi
  if [ -n "$from_toml" ] && [ -n "$from_nvmrc" ] && [ "$from_toml" != "$from_nvmrc" ]; then
    die "mise.toml pins Node $from_toml but .nvmrc pins $from_nvmrc; make them agree, or delete .nvmrc, then re-run"
  fi
  if [ -n "$from_toml" ]; then printf '%s mise.toml' "$from_toml"
  elif [ -n "$from_nvmrc" ]; then printf '%s .nvmrc' "$from_nvmrc"
  fi
}

# --- default Node (per-project is the norm; a default is convenient + mmdc needs a node runtime).
#     Through mise on a machine switched to it, else through fnm. Idempotent. The pin is read
#     first, so a pin that cannot be read stops the stage before anything is installed. ---
ensure_node() {
  pin_and_file=$(node_pin) || exit 1
  pin=${pin_and_file%% *}
  pin_file=${pin_and_file#* }
  if mise_switched; then ensure_node_mise; else ensure_node_fnm; fi
}

# The global default Node is whatever the mise settings drop-ins name (~/.config/mise/conf.d; a
# domain's sets it, the base's sets none). Both installs run from $HOME, so no project's mise.toml
# or pin file is read, and an untrusted one cannot refuse them. This is the deliberate install:
# nothing else installs a version on a switched machine.
ensure_node_mise() {
  log "default Node (mise)"
  command -v mise >/dev/null 2>&1 || { echo "mise not on PATH (did brew bundle run?) — skipping"; return 0; }
  if (cd "$HOME" && mise install); then
    echo "mise: the global default tools are installed"
  else
    echo "mise could not install the global default tools; the apply's pin is still installed below" >&2
  fi
  # The apply's suites run under the Node this repository pins (node_pin), so it is installed
  # before the guarded apply below.
  if [ -n "$pin" ]; then
    (cd "$HOME" && mise install "node@$pin") || die "mise could not install Node $pin ($pin_file), which the apply's suites need"
    echo "mise: installed the $pin_file pin $pin"
  fi
}

ensure_node_fnm() {
  log "default Node (fnm)"
  command -v fnm >/dev/null 2>&1 || { echo "fnm not on PATH (did brew bundle run?) — skipping"; return 0; }
  if fnm ls 2>/dev/null | grep -qE 'v[0-9]'; then
    echo "fnm: node already installed"
  else
    fnm install --lts && echo "fnm: installed latest LTS"
  fi
  ver="$(fnm ls 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
  [ -n "$ver" ] && fnm default "$ver" >/dev/null 2>&1 && echo "fnm: default -> $ver"
  # The apply's suites run under the Node this repository pins (node_pin), and the pre-apply hook
  # refuses the apply when fnm lacks it (tests/apply-suites.py), so it is installed before the
  # guarded apply below.
  if [ -n "$pin" ] && ! fnm exec --using="$pin" node --version >/dev/null 2>&1; then
    fnm install "$pin" || die "fnm could not install Node $pin ($pin_file), which the apply's suites need"
    echo "fnm: installed the $pin_file pin $pin"
  fi
}

# --- chezmoi: init/apply from THIS repo (its own location — no hardcoded source URL, so no
#     private-host reference). apply's run_once sets up the overlay + its private stores. ---
ensure_chezmoi() {
  log "chezmoi (sync source, then GUARDED apply)"
  # Set up / refresh the SOURCE only — the apply is the guarded step below, never a raw apply that
  # could clobber uncaptured config (see setup/README.md). The guarded apply gates on adopt-audit
  # (capture-before-clobber), backs up every would-change file, shows the diff, and confirms.
  if [ -d "$HOME/.local/share/chezmoi/.git" ]; then
    git -C "$HOME/.local/share/chezmoi" pull --ff-only 2>/dev/null || true
  else
    chezmoi --no-pager init "$REPO_DIR" --verbose   # init config + source; NO apply here
  fi
  # Refresh the overlay source if present (2nd instance); its apply also happens in the guarded step.
  OSRC="$HOME/.local/share/chezmoi-overlay"
  [ -d "$OSRC/.git" ] && git -C "$OSRC" pull --ff-only 2>/dev/null || true
  # GUARDED apply: adopt-audit gate -> backup -> diff -> confirm -> apply base then overlay.
  sh "$REPO_DIR/setup/chezmoi-safe-apply"
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
  if [ $# -eq 0 ]; then set -- foundation bundle node chezmoi bootstrapd; fi
  for stage in "$@"; do
    case "$stage" in
      foundation|bundle|node|chezmoi|bootstrapd) ;;
      *) die "unknown stage: $stage (foundation, bundle, node, chezmoi, bootstrapd)" ;;
    esac
  done
  for stage in "$@"; do
    case "$stage" in
      foundation) ensure_foundation ;;
      bundle) ensure_bundle ;;
      node) ensure_node ;;
      chezmoi) ensure_chezmoi ;;
      bootstrapd) run_bootstrapd ;;
    esac
  done
  log "bootstrap-mac complete"
}
main "$@"
