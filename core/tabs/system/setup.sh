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
        if (( (i-1) % 10 == 0 )); then printf "\n"; fi
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
    printf "%b\n" "Installing packages"
    gpu_type=$(lspci | grep -E "VGA|3D|Display")
    case "$gpu_type" in
    *NVIDIA* | *GeForce*)
        echo "Installing NVIDIA drivers: nvidia-lts"
        sudo "$PACKAGER" -S --noconfirm --needed nvidia-lts
        ;;
    *Radeon* | *AMD*)
        echo "Installing AMD drivers: xf86-video-amdgpu"
        sudo "$PACKAGER" -S --noconfirm --needed vulkan-radeon lib32-vulkan-radeon
        ;;
    *Integrated\ Graphics\ Controller*)
        echo "Installing Intel drivers:"
        sudo "$PACKAGER" -S --noconfirm --needed libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa
        ;;
    *Intel\ Corporation\ UHD*)
        echo "Installing Intel UHD drivers:"
        sudo "$PACKAGER" -S --noconfirm --needed libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa
        ;;
    *)
        echo "Unknown GPU type: $gpu_type"
        ;;
    esac

    install_packages "$PACKAGER" \
        libreoffice-fresh vlc curl flatpak fastfetch p7zip unrar tar rsync \
        exfat-utils fuse-exfat flac jdk-openjdk gimp \
        base-devel mangohud lib32-mangohud corectrl openssh \
        htop steam reflector git

    choose_installation
    sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
    sudo reflector --verbose --protocol https -a 48 -c $COUNTRY_CODE --score 5 -f 5 -l 20 --sort rate --save /etc/pacman.d/mirrorlist
    systemctl enable --now reflector.timer

    if echo "${gpu_type}" | grep -E "NVIDIA|GeForce"; then
        # check if flatpak is installed
        printf "%b\n" "Setting up GreenWithEnvy"
        flatpak --user remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        flatpak --user install flathub com.leinardi.gwe
        flatpak update
    elif echo "${gpu_type}" | grep 'VGA' | grep -E "Radeon|AMD"; then
        # corectrl autostart setup
        printf "%b\n" "Setting up corectrl autostart"
        mkdir -p "$HOME/.config/autostart"
        cp /usr/share/applications/org.corectrl.CoreCtrl.desktop "$HOME/.config/autostart/org.corectrl.CoreCtrl.desktop" || true
    fi

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

    # NVM install
    printf "%b\n" "Installing NVM"
    export NVM_VERSION="v0.40.3"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | PROFILE="$HOME/.bash_profile" bash

    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

    printf "%b\n" "Installing Node.js v25 via nvm"
    nvm install 25
    nvm alias default 25

    # pnpm global tools
    printf "%b\n" "Installing pnpm"
    curl -fsSL https://get.pnpm.io/install.sh | sh -
    export PNPM_HOME="$HOME/.local/share/pnpm"

    echo 'export PNPM_HOME="$HOME/.local/share/pnpm"' >>"$HOME/.bashrc"
    echo '[[ ":$PATH:" == *":$PNPM_HOME:"* ]] || export PATH="$PNPM_HOME:$PATH"' >>"$HOME/.bashrc"

    echo 'export PNPM_HOME="$HOME/.local/share/pnpm"' >>"$HOME/.bash_profile"
    echo '[[ ":$PATH:" == *":$PNPM_HOME:"* ]] || export PATH="$PNPM_HOME:$PATH"' >>"$HOME/.bash_profile"

    cat >>"$HOME/.bash_profile" <<'EOF'

if [ -d "$HOME/.nvm" ]; then
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    nvm use default 2>/dev/null || true
fi

EOF

    . "$HOME/.bashrc" || true

    # Dotfiles array
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

    printf "%b\n" "Setup completed successfully!"

    exec bash -l
}

main
