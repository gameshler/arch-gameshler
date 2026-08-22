#!/usr/bin/env bash

. "$COMMON_SCRIPT"

install_pkgs() {
    if ! command_exists nvm pnpm; then
        printf "%b\n" "Installing Packages..."

        # NVM
        NVM_VERSION="v0.40.7"
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

        # PNPM
        curl -fsSL https://get.pnpm.io/install.sh | sh -
        pnpm install -g bun
    else
        printf "%b\n" "Packages are already installed."
    fi
}

main() {
    install_pkgs
    install_packages --aur postman-bin
    printf "%b\n" "Installing Node.js v25 via nvm"
    nvm install 25
    nvm alias default 25

    dotfiles=(.gitignore .gitconfig)

    for dotfile in "${dotfiles[@]}"; do
        src="$FILES/$dotfile"
        dest="$HOME/$dotfile"
        if [ -f "$src" ]; then
            cp "$src" "$dest"
        else
            echo "Warning: $src not found, skipping."
        fi
    done

    . "$HOME/.bashrc" || true
}

main
