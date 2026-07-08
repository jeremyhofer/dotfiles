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
brew "lazygit"           # git TUI (LazyVim/snacks integration)
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

# --- nvim rendering / diagram / PDF / LaTeX tooling (parity with the Framework's pacman set;
#     tracked by personal-systems/parity). Inline image DISPLAY also needs a kitty-graphics
#     terminal (ghostty). ---
brew "ripgrep"
brew "fd"
brew "tree-sitter"       # brew's formula name (Arch calls it tree-sitter-cli)
brew "luarocks"
brew "imagemagick"
brew "ghostscript"
brew "tectonic"
brew "mermaid-cli"

# --- terminal + font (universal dev; ghostty is the fleet terminal, installable at work) ---
cask "ghostty"
cask "font-inconsolata-nerd-font"
