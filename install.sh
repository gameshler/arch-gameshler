#!/usr/bin/env bash
#
# install.sh — automated Arch Linux base install (ISO-run companion to start.sh)
#
# Takes a machine from a blank disk to a rebootable, LUKS2-encrypted Arch system
# using the mkinitcpio UKI + systemd-boot path documented in README.md, then hands
# off to start.sh for post-boot setup (firewall, dwm, dotfiles, ...).
#
# Run from a booted Arch live ISO:
#   bash <(curl -fsSL https://raw.githubusercontent.com/gameshler/archsetup/main/install.sh)
#
# Scope: partition -> encrypt -> LVM -> pacstrap -> chroot config -> UKI/boot.
# Out of scope: Secure Boot/sbctl, dracut, anything post-first-boot.

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
readonly C_RESET=$'\e[0m'
readonly C_BOLD=$'\e[1m'
readonly C_BLUE=$'\e[34m'
readonly C_GREEN=$'\e[32m'
readonly C_YELLOW=$'\e[33m'
readonly C_RED=$'\e[31m'

CURRENT_PHASE="startup"

info()  { printf '%s==>%s %s\n'      "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
ok()    { printf '%s  ✓%s %s\n'      "$C_GREEN"       "$C_RESET" "$*"; }
warn()  { printf '%s  !%s %s\n'      "$C_YELLOW"      "$C_RESET" "$*" >&2; }
die()   { printf '\n%sinstall failed during phase: %s%s\n%s%s%s\n' \
             "$C_RED$C_BOLD" "$CURRENT_PHASE" "$C_RESET" "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
phase() { CURRENT_PHASE="$1"; printf '\n%s########## %s %s\n' "$C_BOLD" "$1" "$C_RESET"; }

# On any unexpected error, print the recovery commands (README.md:170-175) so a
# partial LUKS/LVM state can be torn down before retrying.
on_err() {
    local exit_code=$?
    [[ $exit_code -eq 0 ]] && return 0
    printf '\n%s##### install aborted (exit %s) during: %s #####%s\n' \
        "$C_RED$C_BOLD" "$exit_code" "$CURRENT_PHASE" "$C_RESET" >&2
    cat >&2 <<'EOF'

If disks were already touched, tear down the partial state before retrying:

    swapoff -a
    umount -R /mnt        2>/dev/null || true
    vgchange -an          2>/dev/null || true
    cryptsetup close cryptlvm 2>/dev/null || true

Then re-run the installer.
EOF
}
trap on_err EXIT

# ---------------------------------------------------------------------------
# Defaults (all overridable at the prompts) — mirror README.md
# ---------------------------------------------------------------------------
readonly DEF_EFI_SIZE="1G"
readonly DEF_TIMEZONE="Europe/London"
readonly DEF_LOCALE="en_GB.UTF-8"
readonly DEF_KEYMAP="us"

# Populated by the prompt phase.
DISK=""
PART_EFI=""
PART_LUKS=""
EFI_SIZE="$DEF_EFI_SIZE"
SWAP_SIZE=""          # empty = no swap
ROOT_SIZE=""          # empty = root takes all remaining space
SEPARATE_HOME="no"    # yes = a dedicated /home LV takes the leftover space
HOSTNAME=""
USERNAME=""
TIMEZONE=""
GEO_COUNTRY=""        # ISO country code from geo-IP, for mirror ranking
LOCALE=""
KEYMAP=""
UCODE=""
ROOT_PW=""
USER_PW=""
LUKS_PW=""

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# Partition device name for a whole-disk device: nvme0n1 -> nvme0n1p1, sda -> sda1.
part_name() {
    local disk="$1" num="$2" p=""
    case "$disk" in
        *nvme*|*mmcblk*|*loop*) p="p" ;;
    esac
    printf '%s%s%s' "$disk" "$p" "$num"
}

# Total RAM in whole GiB (rounded up) — used to suggest a swap size.
ram_gib() {
    local kib
    kib="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
    echo $(( (kib + 1048575) / 1048576 ))
}

# Size of a whole-disk device in whole GiB.
disk_gib() {
    local bytes
    bytes="$(blockdev --getsize64 "$1" 2>/dev/null || echo 0)"
    echo $(( bytes / 1073741824 ))
}

# Prompt with a default: prompt_default VAR "Question" "default"
prompt_default() {
    local __var="$1" question="$2" default="$3" reply=""
    read -rp "$question [$default]: " reply || true
    printf -v "$__var" '%s' "${reply:-$default}"
}

# Prompt for a non-empty value (loops until given).
prompt_required() {
    local __var="$1" question="$2" reply=""
    while :; do
        read -rp "$question: " reply || true
        [[ -n "$reply" ]] && break
        warn "A value is required."
    done
    printf -v "$__var" '%s' "$reply"
}

# Prompt for a hidden password with confirmation (loops until they match).
prompt_password() {
    local __var="$1" label="$2" p1="" p2=""
    while :; do
        read -rsp "$label password: " p1; echo
        [[ -z "$p1" ]] && { warn "Password cannot be empty."; continue; }
        read -rsp "$label password (again): " p2; echo
        [[ "$p1" == "$p2" ]] && break
        warn "Passwords did not match — try again."
    done
    printf -v "$__var" '%s' "$p1"
}

# ---------------------------------------------------------------------------
# Phase 1 — preflight
# ---------------------------------------------------------------------------
preflight() {
    phase "Preflight checks"

    [[ $EUID -eq 0 ]] || die "This script must run as root (from the Arch live ISO)."
    [[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. Enable UEFI in firmware and re-boot the ISO."
    command -v pacstrap >/dev/null 2>&1 || die "pacstrap not found — are you on the Arch live ISO?"

    info "Syncing clock (timedatectl set-ntp true)"
    timedatectl set-ntp true || warn "Could not enable NTP; continuing."
    ok "Running as root, UEFI confirmed."
}

# ---------------------------------------------------------------------------
# Phase 2 — network auto-detect (ethernet vs wifi)
# ---------------------------------------------------------------------------
network_up() {
    # True if any non-loopback interface reports a live carrier.
    local iface carrier
    for iface in /sys/class/net/*; do
        [[ "$(basename "$iface")" == "lo" ]] && continue
        carrier="$iface/carrier"
        [[ -r "$carrier" ]] || continue
        [[ "$(cat "$carrier" 2>/dev/null)" == "1" ]] && return 0
    done
    return 1
}

connect_wifi() {
    command -v iwctl >/dev/null 2>&1 || die "No network and iwctl unavailable."

    local wdev
    wdev="$(iwctl device list 2>/dev/null | awk '/station/{print $2; exit}')"
    if [[ -z "$wdev" ]]; then
        local cand
        for cand in /sys/class/net/wl*; do
            [[ -e "$cand" ]] || continue
            wdev="$(basename "$cand")"
            break
        done
    fi
    [[ -n "$wdev" ]] || die "No wireless device found. Plug in Ethernet and re-run."

    info "Using wireless device: $wdev"
    iwctl station "$wdev" scan || true
    sleep 2
    iwctl station "$wdev" get-networks || true

    local ssid wpw
    prompt_required ssid "Wi-Fi SSID"
    read -rsp "Wi-Fi passphrase: " wpw; echo

    info "Connecting to '$ssid'..."
    if ! iwctl --passphrase "$wpw" station "$wdev" connect "$ssid"; then
        die "Wi-Fi connection failed. Re-run and re-check the SSID/passphrase."
    fi
    unset wpw
}

setup_network() {
    phase "Network detection"
    if network_up; then
        ok "Wired/active link detected."
    else
        warn "No active wired link — falling back to Wi-Fi (iwctl)."
        connect_wifi
    fi

    info "Verifying connectivity..."
    for _ in 1 2 3 4 5; do
        if ping -c1 -W2 archlinux.org >/dev/null 2>&1; then
            ok "Network is up."
            return 0
        fi
        sleep 2
    done
    die "Still offline. Connect a network manually (iwctl / dhcpcd) and re-run."
}

# ---------------------------------------------------------------------------
# Phase 3 — interactive prompts (the only manual input)
# ---------------------------------------------------------------------------
# Best-effort timezone guess from the public IP (needs network). Returns a valid
# zone on stdout, or non-zero if it can't determine one.
detect_timezone() {
    local tz="" url
    for url in "https://ipapi.co/timezone" "https://ipinfo.io/timezone"; do
        tz="$(curl -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')"
        [[ -n "$tz" && -f "/usr/share/zoneinfo/$tz" ]] && { printf '%s' "$tz"; return 0; }
    done
    return 1
}

# Loop a search helper until the user names a valid zone. Seeds with $1.
resolve_timezone() {
    local reply="$1" term
    while :; do
        if [[ "$reply" == "s" || "$reply" == "l" ]]; then
            read -rp "  search (e.g. London, Almaty, New_York): " term || true
            timedatectl list-timezones | grep -i -- "${term:-.}" | head -n 40 || true
            read -rp "  timezone: " reply || true
            continue
        fi
        if [[ -f "/usr/share/zoneinfo/$reply" ]]; then
            TIMEZONE="$reply"
            return 0
        fi
        warn "'$reply' is not a valid zone. Type 's' to search by city."
        read -rp "  timezone: " reply || true
    done
}

choose_timezone() {
    local detected reply
    detected="$(detect_timezone || true)"

    if [[ -n "$detected" ]]; then
        GEO_COUNTRY="$(curl -fsSL --max-time 5 https://ipapi.co/country 2>/dev/null | tr -d '[:space:]')"
        read -rp "Timezone — detected '$detected'. Enter to accept, type another, or 's' to search: " reply || true
        reply="${reply:-$detected}"
    else
        warn "Couldn't auto-detect your timezone."
        read -rp "Timezone [$DEF_TIMEZONE] (type 's' to search by city): " reply || true
        reply="${reply:-$DEF_TIMEZONE}"
    fi
    resolve_timezone "$reply"
}

# Best-effort ISO country code from the timezone, for reflector mirror ranking.
country_from_tz() {
    case "$1" in
        Europe/London) echo "GB" ;;
        Europe/Paris)  echo "FR" ;;
        Europe/Berlin) echo "DE" ;;
        Asia/Almaty)   echo "KZ" ;;
        America/New_York|America/Chicago|America/Denver|America/Los_Angeles) echo "US" ;;
        *) echo "" ;;
    esac
}

# Disk layout — beginner-friendly and small-disk-safe. Auto adapts to any disk;
# Custom gives full control. Swap is optional in both modes.
configure_layout() {
    local dsize sug_swap mode ans root_g

    dsize="$(disk_gib "$DISK")"
    sug_swap="$(ram_gib)"
    (( sug_swap > 8 )) && sug_swap=8          # keep the suggestion small-disk friendly

    echo
    info "Disk: $DISK (~${dsize} GiB)"
    echo "  How should the disk be laid out?"
    echo "    1) Auto   — 1 GiB boot, optional swap, the rest for your system (recommended)"
    echo "    2) Custom — pick swap and root sizes, and an optional separate /home"
    prompt_default mode "  Choice" "1"

    EFI_SIZE="$DEF_EFI_SIZE"

    # --- swap (both modes; 0 = none) ---
    echo
    echo "  Swap is disk space used as backup memory. Enter 0 to skip it."
    while :; do
        prompt_default ans "  Swap size in GiB (0 = none)" "$sug_swap"
        [[ "$ans" =~ ^[0-9]+$ ]] || { warn "Enter a whole number of GiB."; continue; }
        (( ans == 0 )) && SWAP_SIZE="" || SWAP_SIZE="${ans}G"
        break
    done

    if [[ "$mode" == "2" ]]; then
        prompt_default ans "  Separate /home partition? (y/N)" "N"
        case "${ans,,}" in
            y|yes) SEPARATE_HOME="yes" ;;
            *)     SEPARATE_HOME="no" ;;
        esac
        if [[ "$SEPARATE_HOME" == "yes" ]]; then
            while :; do
                prompt_default root_g "  Root (/) size in GiB" "20"
                [[ "$root_g" =~ ^[0-9]+$ ]] && (( root_g > 0 )) && { ROOT_SIZE="${root_g}G"; break; }
                warn "Enter a whole number of GiB."
            done
            echo "  /home will use the remaining space."
        else
            ROOT_SIZE=""      # root takes the rest
        fi
    else
        SEPARATE_HOME="no"
        ROOT_SIZE=""          # root takes the rest
    fi

    # --- sanity: make sure the fixed pieces fit, leaving room for root ---
    local swap_g="${SWAP_SIZE%G}"; swap_g="${swap_g:-0}"
    local root_need="${ROOT_SIZE%G}"; root_need="${root_need:-0}"
    local fixed=$(( 1 + swap_g + root_need ))     # EFI(1) + swap + any fixed root
    if (( dsize > 0 && fixed + 1 > dsize )); then
        die "Requested layout (~${fixed} GiB) won't fit on a ~${dsize} GiB disk. Reduce swap/root and re-run."
    fi
}

gather_input() {
    phase "Configuration prompts"

    info "Available disks:"
    lsblk -dpno NAME,SIZE,MODEL | grep -vE 'loop|sr0' || true
    echo
    while :; do
        prompt_required DISK "Target disk (e.g. /dev/vda or just vda)"
        [[ "$DISK" != /dev/* && -b "/dev/$DISK" ]] && DISK="/dev/$DISK"
        [[ -b "$DISK" ]] && break
        warn "'$DISK' is not a block device. Pick one from the list above."
    done

    PART_EFI="$(part_name "$DISK" 1)"
    PART_LUKS="$(part_name "$DISK" 2)"

    configure_layout

    echo
    prompt_required HOSTNAME "Hostname"
    prompt_required USERNAME "Username"
    echo
    prompt_password ROOT_PW "Root"
    prompt_password USER_PW "User ($USERNAME)"
    echo
    prompt_password LUKS_PW "Disk encryption (LUKS)"

    echo
    choose_timezone
    prompt_default LOCALE "Locale" "$DEF_LOCALE"
    prompt_default KEYMAP "Keymap" "$DEF_KEYMAP"

    # ucode auto-detect
    local vendor
    vendor="$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $NF}')"
    case "$vendor" in
        GenuineIntel) UCODE="intel-ucode" ;;
        AuthenticAMD) UCODE="amd-ucode" ;;
        *) UCODE=""; warn "Unknown CPU vendor ('$vendor') — skipping microcode package." ;;
    esac
    [[ -n "$UCODE" ]] && ok "CPU microcode: $UCODE"
}

# ---------------------------------------------------------------------------
# Phase 4 — wipe-confirmation gate
# ---------------------------------------------------------------------------
confirm_wipe() {
    phase "Confirm disk wipe"
    local bare="${DISK##*/}"

    printf '%s%s\n  EVERYTHING on %s will be ERASED.%s\n\n' "$C_YELLOW" "$C_BOLD" "$DISK" "$C_RESET"
    echo "  Planned layout:"
    printf '    %s   EFI System Partition   %s   (FAT32, /boot/efi)\n' "$PART_EFI" "$EFI_SIZE"
    printf '    %s   LUKS2 encrypted container (rest of disk)\n' "$PART_LUKS"
    if [[ -n "$SWAP_SIZE" ]]; then
        printf '        - vg-swap   %s\n' "$SWAP_SIZE"
    else
        printf '        - (no swap)\n'
    fi
    if [[ "$SEPARATE_HOME" == "yes" ]]; then
        printf '        - vg-root   %s   (ext4, /)\n' "$ROOT_SIZE"
        printf '        - vg-home   rest       (ext4, /home)\n'
    else
        printf '        - vg-root   rest       (ext4, /  — includes /home)\n'
    fi
    printf '\n  Hostname: %s    User: %s    Timezone: %s\n  Microcode: %s\n\n' \
        "$HOSTNAME" "$USERNAME" "$TIMEZONE" "${UCODE:-none}"

    local reply
    read -rp "Type the bare disk name ('$bare') to proceed, anything else aborts: " reply || true
    [[ "$reply" == "$bare" ]] || die "Confirmation mismatch — no changes were written to any disk."
    ok "Confirmed. Proceeding."
}

# ---------------------------------------------------------------------------
# Phase 5 — teardown + partition + encrypt
# ---------------------------------------------------------------------------
teardown_existing() {
    info "Clearing any existing LVM/LUKS on the target (reinstall safety)..."
    swapoff -a 2>/dev/null || true

    # Deactivate any VG whose PV lives on this disk, then close a lingering mapping.
    local vg
    while read -r vg; do
        [[ -n "$vg" ]] && vgchange -an "$vg" 2>/dev/null || true
    done < <(pvs --noheadings -o vg_name 2>/dev/null | awk '{$1=$1};1' | sort -u)

    cryptsetup close cryptlvm 2>/dev/null || true

    # Wipe old signatures on the partitions we are about to recreate.
    wipefs -fa "$PART_EFI" 2>/dev/null || true
    wipefs -fa "$PART_LUKS" 2>/dev/null || true
}

partition_disk() {
    phase "Partition + encrypt"
    teardown_existing

    info "Writing GPT layout to $DISK"
    wipefs -fa "$DISK"
    sgdisk --zap-all "$DISK"
    sgdisk --new=1:0:+"$EFI_SIZE" --typecode=1:EF00 --change-name=1:EFI "$DISK"
    sgdisk --new=2:0:0            --typecode=2:8309 --change-name=2:cryptlvm "$DISK"
    partprobe "$DISK" 2>/dev/null || true
    sleep 1

    info "Formatting EFI ($PART_EFI)"
    mkfs.fat -F32 "$PART_EFI"

    info "Encrypting $PART_LUKS (LUKS2)"
    printf '%s' "$LUKS_PW" | cryptsetup luksFormat --type luks2 "$PART_LUKS" -
    printf '%s' "$LUKS_PW" | cryptsetup open --allow-discards --persistent "$PART_LUKS" cryptlvm -
    ok "Encrypted container opened as /dev/mapper/cryptlvm"
}

# ---------------------------------------------------------------------------
# Phase 6 — LVM + filesystems + mount
# ---------------------------------------------------------------------------
setup_lvm() {
    phase "LVM + filesystems"

    pvcreate /dev/mapper/cryptlvm
    vgcreate vg /dev/mapper/cryptlvm

    [[ -n "$SWAP_SIZE" ]] && lvcreate -L "$SWAP_SIZE" vg -n swap
    if [[ "$SEPARATE_HOME" == "yes" ]]; then
        lvcreate -L "$ROOT_SIZE" vg -n root
        lvcreate -l 100%FREE     vg -n home
    else
        lvcreate -l 100%FREE     vg -n root
    fi

    mkfs.ext4 /dev/vg/root
    [[ "$SEPARATE_HOME" == "yes" ]] && mkfs.ext4 /dev/vg/home
    [[ -n "$SWAP_SIZE" ]] && mkswap /dev/vg/swap

    info "Mounting target"
    mount /dev/vg/root /mnt
    mkdir -p /mnt/boot/efi
    if [[ "$SEPARATE_HOME" == "yes" ]]; then
        mkdir -p /mnt/home
        mount /dev/vg/home /mnt/home
    fi
    mount "$PART_EFI" /mnt/boot/efi
    [[ -n "$SWAP_SIZE" ]] && swapon /dev/vg/swap
    ok "Filesystems mounted at /mnt"
}

# ---------------------------------------------------------------------------
# Phase 7 — mirrors + pacstrap + fstab
# ---------------------------------------------------------------------------
install_base() {
    phase "Mirror ranking + base install"

    local country
    country="$GEO_COUNTRY"
    [[ -n "$country" ]] || country="$(country_from_tz "$TIMEZONE")"
    if command -v reflector >/dev/null 2>&1; then
        info "Ranking mirrors${country:+ (country: $country)}..."
        if [[ -n "$country" ]]; then
            reflector --country "$country" --protocol https --sort rate \
                --save /etc/pacman.d/mirrorlist 2>/dev/null \
                || warn "reflector failed; using default mirrorlist."
        else
            reflector --protocol https --sort rate --latest 20 \
                --save /etc/pacman.d/mirrorlist 2>/dev/null \
                || warn "reflector failed; using default mirrorlist."
        fi
    fi

    # mkinitcpio UKI package set (README.md:237), minus Secure Boot + base-devel.
    local -a pkgs=(
        base linux linux-firmware linux-lts
        lvm2 vim sudo git networkmanager
        efibootmgr ntfs-3g binutils systemd-ukify
    )
    [[ -n "$UCODE" ]] && pkgs+=("$UCODE")

    info "pacstrap: ${pkgs[*]}"
    pacstrap -K /mnt "${pkgs[@]}"

    info "Generating fstab"
    genfstab -U /mnt >> /mnt/etc/fstab

    # Harden the vfat EFI mount (README.md:246-279): fmask=0137,dmask=0027.
    sed -i -E '/[[:space:]]vfat[[:space:]]/ s/(fmask=[0-9]+|dmask=[0-9]+),?//g; /[[:space:]]vfat[[:space:]]/ s/defaults/defaults,fmask=0137,dmask=0027/' \
        /mnt/etc/fstab
    ok "Base system installed."
}

# ---------------------------------------------------------------------------
# Phase 8+9 — chroot configuration (config, users, UKI, bootloader)
# ---------------------------------------------------------------------------
configure_system() {
    phase "System configuration (chroot)"

    local luks_uuid
    luks_uuid="$(blkid -s UUID -o value "$PART_LUKS")"
    [[ -n "$luks_uuid" ]] || die "Could not read LUKS UUID from $PART_LUKS"

    # Export values consumed by the heredoc below.
    export CH_TZ="$TIMEZONE" CH_LOCALE="$LOCALE" CH_KEYMAP="$KEYMAP" \
           CH_HOST="$HOSTNAME" CH_USER="$USERNAME" \
           CH_LUKS_UUID="$luks_uuid" \
           CH_ROOT_PW="$ROOT_PW" CH_USER_PW="$USER_PW"

    arch-chroot /mnt /usr/bin/env bash -euo pipefail <<'CHROOT'
# --- timezone / clock ---
ln -sf "/usr/share/zoneinfo/$CH_TZ" /etc/localtime
hwclock --systohc

# --- locale ---
sed -i "s/^#\s*\(${CH_LOCALE}\)/\1/" /etc/locale.gen
grep -q "^${CH_LOCALE}" /etc/locale.gen || echo "${CH_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${CH_LOCALE}" > /etc/locale.conf

# --- console keymap/font (README.md:302-305) ---
cat > /etc/vconsole.conf <<VCONSOLE
KEYMAP=${CH_KEYMAP}
FONT=Lat2-Terminus16
FONT_MAP=8859-1
VCONSOLE

# --- hostname + hosts ---
echo "$CH_HOST" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${CH_HOST}.localdomain   ${CH_HOST}
HOSTS

# --- users / passwords ---
echo "root:${CH_ROOT_PW}" | chpasswd
useradd -m -G wheel "$CH_USER"
echo "${CH_USER}:${CH_USER_PW}" | chpasswd

# --- sudo for wheel via drop-in (never edit /etc/sudoers directly) ---
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# --- services ---
systemctl enable NetworkManager fstrim.timer

# --- mkinitcpio HOOKS for systemd + sd-encrypt + lvm2 (README.md:468) ---
sed -i 's/^HOOKS=.*/HOOKS=(systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf

# --- systemd-boot ---
bootctl install
cat > /boot/efi/loader/loader.conf <<LOADER
default         arch-linux.efi
timeout         0
console-mode    auto
editor          no
LOADER

# --- kernel cmdline (README.md:488) ---
echo "rd.luks.name=${CH_LUKS_UUID}=cryptlvm root=/dev/vg/root rootfstype=ext4 rw quiet bgrt_disable" > /etc/kernel/cmdline

# --- UKI presets for linux + linux-lts (README.md:494-514) ---
cat > /etc/mkinitcpio.d/linux.preset <<'PRESET'
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default' 'fallback')
default_uki="/boot/efi/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
fallback_uki="/boot/efi/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
PRESET

cat > /etc/mkinitcpio.d/linux-lts.preset <<'PRESET'
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-lts"
PRESETS=('default' 'fallback')
default_uki="/boot/efi/EFI/Linux/arch-linux-lts.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
fallback_uki="/boot/efi/EFI/Linux/arch-linux-lts-fallback.efi"
fallback_options="-S autodetect"
PRESET

# Ensure the EFI/Linux dir exists, then build the UKIs.
mkdir -p /boot/efi/EFI/Linux
mkinitcpio -P

systemctl enable systemd-boot-update.service
CHROOT

    ok "System configured, UKIs generated, systemd-boot installed."
}

# ---------------------------------------------------------------------------
# Phase 10 — finish
# ---------------------------------------------------------------------------
finish() {
    phase "Finishing up"

    # Scrub secrets from the environment.
    unset ROOT_PW USER_PW LUKS_PW CH_ROOT_PW CH_USER_PW

    info "Unmounting"
    swapoff -a 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true

    trap - EXIT
    cat <<EOF

${C_GREEN}${C_BOLD}Base install complete.${C_RESET}

After you reboot and log in as '${USERNAME}', run the post-install setup:

    ${C_BOLD}bash <(curl -fsSL https://raw.githubusercontent.com/gameshler/archsetup/main/start.sh)${C_RESET}

EOF
    local reply
    read -rp "Reboot now? [y/N]: " reply || true
    if [[ "${reply,,}" == "y" ]]; then
        info "Rebooting..."
        reboot
    else
        info "Reboot manually when ready:  reboot"
    fi
}

# ---------------------------------------------------------------------------
main() {
    preflight
    setup_network
    gather_input
    confirm_wipe
    partition_disk
    setup_lvm
    install_base
    configure_system
    finish
}

main "$@"
