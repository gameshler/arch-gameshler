#!/bin/sh -e

. "$COMMON_SCRIPT"

install_brave_origin() {
    if ! command_exists brave-origin && ! command_exists com.brave.Browser; then
        printf "%b\n" "Installing Brave..."
        install_packages --aur brave-origin-bin
    else
        printf "%b\n" "Brave Origin Browser is already installed."
    fi
}

install_brave_origin
