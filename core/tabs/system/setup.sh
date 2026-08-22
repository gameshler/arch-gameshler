#!/usr/bin/env bash

. "$COMMON_SCRIPT"

set -euo pipefail

choose_installation() {

    local options=("AU" "AT" "BY" "BE" "BR" "BG" "CA" "CL" "CN" "CO" "CZ" "DK" "EC" "FI" "FR" "DE" "GR" "HK" "HU" "IS" "IN" "ID" "IR" "IE" "IL" "IT" "JP" "KZ" "LV" "LT" "LU" "MK" "NL" "NC" "NZ" "NO" "PL" "PT" "RO" "RU" "RS" "SG" "SK" "ZA" "KR" "ES" "SE" "CH" "TW" "TH" "TR" "UA" "GB" "US" "VN")

    printf "Please select your country:\n"

    local i=1
    for code in "${options[@]}"; do
        printf "%2d)%s " "$i" "$code"
        ((i++))
        if (((i - 1) % 10 == 0)); then printf "\n"; fi
    done
    printf "\n"

    local choice
    while :; do
        printf "Enter your choice (1-%d): " "${#options[@]}"
        read -r choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
            break
        fi
        echo "Invalid choice, please try again."
    done

    local index=$((choice - 1))
    COUNTRY_CODE="${options[$index]}"

    echo "You selected: $COUNTRY_CODE"
}

main() {

    printf "%b\n" "Checking System Package Manager and AUR"

    sudo "$PACKAGER" -Syu --noconfirm
    # pacman config
    printf "%b\n" "Configuring pacman"
    sudo sed -i -E \
        -e 's/^\s*#\s*(Color)/\1/' \
        -e 's/^\s*#\s*(ParallelDownloads\s*=)/\1/' \
        /etc/pacman.conf

    sudo sed -i -E '/^\s*#?\s*\[multilib\]/,/^\s*\[.*\]/ {
    s/^\s*#\s*(\[multilib\])/\1/
    s/^\s*#\s*(Include\s*=\s*\/etc\/pacman\.d\/mirrorlist)/\1/
}' /etc/pacman.conf

    if ! grep -q "^ILoveCandy" /etc/pacman.conf; then
        sudo sed -i '/^ParallelDownloads *=.*/a ILoveCandy' /etc/pacman.conf
    fi

    sudo "$PACKAGER" -Syyu --noconfirm

    install_packages \
        libreoffice-fresh vlc curl flatpak fastfetch p7zip unrar tar rsync \
        exfat-utils fuse-exfat flac jdk-openjdk gimp \
        base-devel mangohud lib32-mangohud \
        htop steam reflector python rust git

    choose_installation
    sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
    
    sudo reflector --verbose --protocol https -a 24 -c "$COUNTRY_CODE" --score 15 -f 5 -l 20 --sort rate --save /etc/pacman.d/mirrorlist
    echo "--verbose --protocol https --age 24 --country $COUNTRY_CODE --score 15 --fastest 5 --latest 20 --sort rate --save /etc/pacman.d/mirrorlist" | sudo tee /etc/xdg/reflector/reflector.conf > /dev/null
    
    sudo systemctl enable reflector.service
    sudo systemctl enable --now reflector.timer

    # mangohud config
    printf "%b\n" "Configuring MangoHud"
    mkdir -p "$HOME/.config/MangoHud" && cp /usr/share/doc/mangohud/MangoHud.conf.example "$HOME/.config/MangoHud/MangoHud.conf" || true
    config_file="$HOME/.config/MangoHud/MangoHud.conf"

    # Settings you want to enable
    settings_to_uncomment=(
        "gpu_stats"
        "gpu_temp"
        "gpu_core_clock"
        "gpu_mem_temp"
        "gpu_mem_clock"
        "gpu_power"
        "gpu_voltage"
        "cpu_stats"
        "cpu_temp"
        "cpu_power"
        "cpu_mhz"
        "fps"
        "frametime"
        "throttling_status"
        "frame_timing"
        "text_outline"
    )

    # Loop and uncomment each line that starts with the key (if commented)
    for setting in "${settings_to_uncomment[@]}"; do
        sed -i -E "s/^\s*#\s*(${setting})(\s*(=|$))/${setting}\2/" "$config_file"
    done

    printf "%b\n" "Setup completed successfully!"

}

main
