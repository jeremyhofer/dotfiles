# Base Brewfile — the portable, publish-safe dev core. Consumed by bootstrap-mac.sh
# (`brew bundle --file Brewfile`) on EVERY Mac (personal + work). Keep it strictly to tools
# that any dev machine — including a managed work Mac — can and should install. Anything
# personal-only, preference, personal-infra, or not-installable-at-work belongs in the
# overlay's Brewfile.role (which instance_eval's this file).
#
# node is installed PER-PROJECT via fnm, NOT as a brew formula — do not add `brew "node"`.

# --- CLI dev core ---
brew "chezmoi"
brew "git"
brew "gh"
brew "git-delta"         # git diff/pager syntax highlighting (gitconfig [core] pager + [interactive] diffFilter)
brew "lazygit"           # git TUI (LazyVim/snacks integration)
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
brew "watch"             # periodic command re-runner (not shipped on macOS)
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
