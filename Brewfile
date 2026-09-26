# Base Brewfile — the portable, publish-safe dev core. Consumed by bootstrap-mac.sh
# (`brew bundle --file Brewfile`) on EVERY Mac (personal + work). Keep it strictly to tools
# that any dev machine — including a managed work Mac — can and should install. Anything
# personal-only, preference, personal-infra, or not-installable-at-work belongs in the
# overlay's Brewfile.role, which THIS file includes at the bottom (see the role-layer block
# there). The direction matters and this comment used to state it backwards: the base is the
# entrypoint and the role file EXTENDS it. Reading it the other way suggests a Mac with no
# overlay installs nothing, when in fact it installs exactly this core -- which is the whole
# reason the base is the standalone standard.
#
# node is installed PER-PROJECT via fnm, NOT as a brew formula — do not add `brew "node"`.
#
# REQUIRED marker: a `brew "formula"` line whose trailing comment contains the whole word
# REQUIRED means apply itself, or a hook that runs on every commit, fails closed without it —
# not merely "useful". `run_before_check-required-brew-tools.sh.tmpl` greps for this marker and
# refuses `chezmoi apply` on a Mac where a REQUIRED formula is missing, naming the fix
# (`brew bundle --file Brewfile`) instead of letting the failure surface later, unexplained,
# inside whatever script first needed the tool. Mark a formula this way only when its absence
# actually breaks something that way — most tools here are merely useful, not REQUIRED.

# --- CLI dev core ---
brew "chezmoi"
brew "git"               # Homebrew's git, not Apple's bundled one, which lags by several releases: every
                         # machine runs the same current git (Arch gets it from pacman). ~/.zshenv and
                         # ~/.zprofile put brew's bin ahead of /usr/bin; GUI apps and launchd jobs still see Apple's.
brew "gh"
brew "git-delta"         # git diff/pager syntax highlighting (gitconfig [core] pager + [interactive] diffFilter)
brew "gitleaks"          # secret scanner: the gitconfig secret-scan hook refuses every commit without it
brew "lazygit"           # git TUI (LazyVim/snacks integration)
# tuicr isn't in homebrew-core; this is the author's own tap. `trusted: true` declaratively trusts it
# so `brew bundle` loads + installs tuicr with no separate `brew trust` step (Homebrew otherwise refuses
# formulae from an untrusted third-party tap). Arch installs it from the official 'extra' repo.
tap "agavra/tap", trusted: true
brew "agavra/tap/tuicr"  # code-review TUI (git/jj), vim keys — local + PR/MR review
brew "mani"              # multi-repo manager: declarative sync (mani sync) + run across repos (mani exec)
brew "worktrunk"         # git worktree manager (wt): create/switch/list/merge, parallel-agent isolation
brew "fnm"               # node version manager (per-project node)
brew "uv"                # python
brew "direnv"            # per-directory env (.envrc)
brew "tmux"
brew "neovim"
brew "fzf"               # fuzzy finder (zsh fzf plugin)
brew "thefuck"           # command corrector (zsh plugin)
brew "tree"              # directory tree listing
brew "just"              # task runner
brew "age"               # file encryption (generic)
brew "jq"                # JSON processor (scripts / CLI)
brew "yq"                # YAML processor. REQUIRED, not optional: the publish-boundary git hook
                         # reads the fleet repo manifest through it on every commit and fails
                         # CLOSED when it is absent, so a machine without it cannot commit at all.
                         # Homebrew's `yq` is mikefarah's Go implementation, which is the dialect
                         # that hook expects. On Arch the equivalent package is `go-yq`; the
                         # similarly-named `yq` there is a different program with incompatible
                         # syntax, so the two platforms declare different package NAMES for the
                         # same tool.
brew "watch"             # periodic command re-runner (not shipped on macOS)
brew "shellcheck"        # shell script linter
brew "shfmt"             # shell script formatter
brew "findutils"         # GNU find/xargs (gfind/gxargs; macOS ships only BSD find)

# --- nvim rendering / diagram / PDF / LaTeX tooling (parity with the Framework's pacman set;
#     tracked by personal-systems/parity). Inline image DISPLAY also needs a kitty-graphics
#     terminal (ghostty). ---
brew "ripgrep"
brew "fd"
brew "tree-sitter"       # nvim's parser runtime; the separate tree-sitter-cli (grammar builder) is NOT needed
brew "luarocks"
brew "imagemagick"
brew "ghostscript"
brew "tectonic"
brew "mermaid-cli"

# --- terminal + font (universal dev; ghostty is the fleet terminal, installable at work) ---
cask "ghostty"
cask "font-inconsolata-nerd-font"

# --- machine-local role layer (optional) ---
# This base is the standalone standard: `brew bundle --file Brewfile` installs the shared core on
# any Mac (a machine with no overlay gets exactly this). If the machine's overlay has deployed a
# private role Brewfile, include it here so ONE command installs both and `brew bundle cleanup`
# sees the union — same base-includes-overlay pattern as ~/.ssh/config's `Include ~/.dotlocal/ssh/config`
# and the gitconfig include. The overlay's role file adds; it never reaches back into this base.
role = File.expand_path("~/.dotlocal/Brewfile.role")
instance_eval(File.read(role)) if File.exist?(role)
