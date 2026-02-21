#!/bin/sh -e

. "$COMMON_SCRIPT"

installRofi() {
    if ! command_exists rofi; then
        printf "%b\n" "Installing Rofi..."
        case "$PACKAGER" in
        pacman)
            sudo "$PACKAGER" -S --needed --noconfirm rofi
            ;;

        *)
            printf "%b\n" "Unsupported package manager: ""$PACKAGER"
            exit 1
            ;;
        esac
    else
        printf "%b\n" "Rofi is already installed."
    fi
}

setupRofiConfig() {
    printf "%b\n" "Copying Rofi configuration files..."
    if [ -d "$HOME/.config/rofi" ] && [ ! -d "$HOME/.config/rofi-bak" ]; then
        cp -r "$HOME/.config/rofi" "$HOME/.config/rofi-bak"
    fi
    mkdir -p "$HOME/.config/rofi"
    curl -sSLo "$HOME/.config/rofi/powermenu.sh" https://github.com/gameshler/dwm/raw/main/config/rofi/powermenu.sh
    chmod +x "$HOME/.config/rofi/powermenu.sh"
    curl -sSLo "$HOME/.config/rofi/config.rasi" https://github.com/gameshler/dwm/raw/main/config/rofi/config.rasi
    mkdir -p "$HOME/.config/rofi/themes"
    curl -sSLo "$HOME/.config/rofi/themes/nord.rasi" https://github.com/gameshler/dwm/raw/main/config/rofi/themes/nord.rasi
    curl -sSLo "$HOME/.config/rofi/themes/sidetab-nord.rasi" https://github.com/gameshler/dwm/raw/main/config/rofi/themes/sidetab-nord.rasi
    curl -sSLo "$HOME/.config/rofi/themes/powermenu.rasi" https://github.com/gameshler/dwm/raw/main/config/rofi/themes/powermenu.rasi
    curl -sSLo "$HOME/.config/rofi/repo-finder.sh" https://github.com/gameshler/dwm/raw/main/config/rofi/repo-finder.sh
    curl -sSLo "$HOME/.config/rofi/bookmarksmenu.sh" https://github.com/gameshler/dwm/raw/main/config/rofi/bookmarksmenu.sh

    chmod +x "$HOME/.config/rofi/repo-finder.sh"
    chmod +x "$HOME/.config/rofi/bookmarksmenu.sh"
}


installRofi
setupRofiConfig
