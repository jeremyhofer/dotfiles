export PYENV_ROOT="$HOME/.pyenv"
#export PATH="$HOME/.cargo/bin:$PATH"
export PATH="$PYENV_ROOT/bin:$PATH"
export PATH="$PATH:$HOME/.local/bin"
export PATH="$PATH:$HOME/go/bin"
eval "$(pyenv init --path)"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm

if [ -f "$HOME/.personal/zprofile" ]; then
    source "$HOME/.personal/zprofile"
fi

if [ -f "$HOME/.work/zprofile" ]; then
    source "$HOME/.work/zprofile"
fi
