#!/bin/sh
action="${1}"
domain="${2}"

if [ "$action" = "D" ] || [ "$action" = "S" ] || [ "$action" = "R" ]; then
    projects=""

    if [ "$domain" = "h" ]; then
        projects="X alacritty editorconfig i3 git nvim ssh tmux yamllint zsh personal"
    elif [ "$domain" = "w" ]; then
        projects="editorconfig git nvim ssh tmux yamllint zsh work"
    else
        echo "Valid Domains: h (home) w (work)"
        exit 1
    fi

    # shellcheck disable=SC2086
    stow --dotfiles -t "$HOME" "-$action" $projects
else
    echo "Valid Commands: S (stow) R (restow) D (delete)"
    exit 1
fi
