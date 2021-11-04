export PYENV_ROOT="$HOME/.pyenv"

typeset -U PATH path
path=("$PYENV_ROOT/bin", "$HOME/.cargo/bin", "$path[@]", "$HOME/.local/bin")
export PATH

eval "$(pyenv init --path)"
eval "$(pyenv virtualenv-init -)"

# opam configuration
test -r /home/jhofer/.opam/opam-init/init.sh && . /home/jhofer/.opam/opam-init/init.sh > /dev/null 2> /dev/null || true
