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
readonly DEF_LOCALE="en_US.UTF-8"   # neutral default; fully overridable at the prompt
readonly DEF_KEYMAP="us"

# Populated by the prompt phase.
DISK=""
PART_EFI=""
PART_LUKS=""
EFI_SIZE="$DEF_EFI_SIZE"
SWAP_SIZE=""          # empty = no swap
ROOT_SIZE=""          # empty = root takes all remaining space
SEPARATE_HOME="no"    # yes = a dedicated /home LV takes the leftover space
SYS_PROFILE="desktop" # desktop|server — gates fstrim.timer + LUKS discards
VG_NAME="vg"          # chosen collision-free in setup_lvm (multi-disk safety)
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

# Real reachability, not just link: route (ping an IP) AND DNS (ping a name).
route_ok() { ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; }
dns_ok()   { ping -c1 -W2 archlinux.org >/dev/null 2>&1; }

setup_network() {
    phase "Network detection"
    if network_up; then
        ok "Wired/active link detected."
    else
        warn "No active wired link — falling back to Wi-Fi (iwctl)."
        connect_wifi
    fi

    info "Verifying connectivity (route + DNS)..."
    local i
    for i in 1 2 3 4 5; do
        if route_ok && dns_ok; then
            ok "Network is up."
            return 0
        fi
        # A carrier can be up with no DHCP lease — nudge the ISO's networkd once.
        [[ $i -eq 2 ]] && { info "No connectivity yet — retrying DHCP..."; systemctl restart systemd-networkd 2>/dev/null || true; }
        sleep 2
    done

    # Distinguish the failure so the message is actionable.
    if route_ok; then
        die "Link and routing are up, but DNS resolution fails. Check /etc/resolv.conf and re-run."
    fi
    die "Still offline (no route). Connect a network (iwctl / dhcpcd) and re-run."
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

# Resolve a user-typed locale to the exact name in /etc/locale.gen, preferring
# the UTF-8 variant. Echoes the canonical name (e.g. en_US.UTF-8) or nothing.
# This is case-insensitive on input but always returns the file's real casing,
# and a bare "en_US" resolves to en_US.UTF-8 (never the ISO-8859-1 entry).
locale_canonical() {
    awk -v want="$1" '
        BEGIN { lw = tolower(want) }
        {
            line = $0; sub(/^#[ \t]*/, "", line)
            if (line == "") next
            split(line, f, /[ \t]+/); name = f[1]; cmap = toupper(f[2]); ln = tolower(name)
            if (ln == lw && cmap == "UTF-8") { print name; exit }                       # exact UTF-8
            if (ln == lw && exact == "") exact = name                                   # exact, any charmap
            if (index(ln, lw ".") == 1 && cmap == "UTF-8" && pref == "") pref = name     # <token>.UTF-8
        }
        END { if (pref != "") print pref; else if (exact != "") print exact }
    ' /etc/locale.gen
}

# Pick a locale, resolved to the canonical /etc/locale.gen name, with search.
choose_locale() {
    local reply term canon
    read -rp "Locale [$DEF_LOCALE] (type 's' to search): " reply || true
    reply="${reply:-$DEF_LOCALE}"
    while :; do
        if [[ "$reply" == "s" ]]; then
            read -rp "  search (e.g. de_DE, fr, en_): " term || true
            grep -iE -- "${term:-.}" /etc/locale.gen | sed -e 's/^#[[:space:]]*//' -e '/^[[:space:]]*$/d' | head -n 40 || true
            read -rp "  locale: " reply || true
            continue
        fi
        canon="$(locale_canonical "$reply" || true)"
        if [[ -n "$canon" ]]; then
            LOCALE="$canon"
            if [[ "$canon" != "$reply" ]]; then info "Using locale '$canon'."; fi
            return 0
        fi
        warn "'$reply' has no match in /etc/locale.gen. Type 's' to search."
        read -rp "  locale: " reply || true
    done
}

# Pick a console keymap, validated against localectl, with a search helper.
choose_keymap() {
    local reply term keymaps
    keymaps="$(localectl list-keymaps 2>/dev/null || true)"
    read -rp "Console keymap [$DEF_KEYMAP] (type 's' to search): " reply || true
    reply="${reply:-$DEF_KEYMAP}"
    while :; do
        if [[ "$reply" == "s" ]]; then
            read -rp "  search (e.g. uk, de, fr): " term || true
            printf '%s\n' "$keymaps" | grep -i -- "${term:-.}" | head -n 40 || true
            read -rp "  keymap: " reply || true
            continue
        fi
        # If localectl gave us a list, validate against it (literal, not regex);
        # otherwise accept.
        if [[ -z "$keymaps" ]] || printf '%s\n' "$keymaps" | grep -Fxq -- "$reply"; then
            KEYMAP="$reply"
            return 0
        fi
        warn "'$reply' isn't a known keymap. Type 's' to search."
        read -rp "  keymap: " reply || true
    done
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
    choose_locale
    choose_keymap

    # System profile — drives TRIM policy (README note: no discards on servers).
    echo
    echo "System profile:"
    echo "    1) Desktop / laptop / workstation — SSD TRIM enabled (fstrim.timer + LUKS discards)"
    echo "    2) Server — no automatic TRIM, no LUKS discards"
    local prof
    prompt_default prof "  Choice" "1"
    [[ "$prof" == "2" ]] && SYS_PROFILE="server" || SYS_PROFILE="desktop"

    # ucode auto-detect
    local vendor
    vendor="$( (grep -m1 vendor_id /proc/cpuinfo || true) | awk '{print $NF}')"
    case "$vendor" in
        GenuineIntel) UCODE="intel-ucode" ;;
        AuthenticAMD) UCODE="amd-ucode" ;;
        *) UCODE=""; warn "Unknown CPU vendor ('$vendor') — skipping microcode package." ;;
    esac
    # NOTE: keep this an `if`, not `[[ ... ]] && ok`. As the last statement of the
    # function the &&-list would return 1 when UCODE is empty and, under `set -e`,
    # abort the whole installer on any non-Intel/AMD CPU.
    if [[ -n "$UCODE" ]]; then ok "CPU microcode: $UCODE"; fi
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
    printf '\n  Hostname: %s    User: %s    Timezone: %s\n  Profile: %s    Microcode: %s\n\n' \
        "$HOSTNAME" "$USERNAME" "$TIMEZONE" "$SYS_PROFILE" "${UCODE:-none}"

    # Refuse if the target (or any partition of it) is mounted at a real path —
    # catches picking the live USB, or a leftover /mnt from a failed run. Active
    # swap ([SWAP]) is fine; the teardown handles it.
    if lsblk -nro MOUNTPOINT "$DISK" 2>/dev/null | grep -q '^/'; then
        die "$DISK has mounted partitions. Unmount them (or pick another disk) and re-run."
    fi

    local reply
    read -rp "Type the disk name '$bare' to confirm: " reply || true
    reply="${reply//[[:space:]]/}"                       # ignore stray pasted whitespace
    [[ "$reply" == "$bare" ]] || die "Name mismatch ('$reply' vs '$bare') — nothing was written."
    read -rp "Final check — type YES (uppercase) to ERASE $DISK: " reply || true
    [[ "$reply" == "YES" ]] || die "Not confirmed — nothing was written."
    ok "Confirmed. Proceeding."
}

# ---------------------------------------------------------------------------
# Phase 5 — teardown + partition + encrypt
# ---------------------------------------------------------------------------
# Reinstall safety: tear down prior LUKS/LVM state **only on the target disk**,
# never on other drives (a VG named "vg" may exist elsewhere).
teardown_existing() {
    info "Clearing existing LVM/LUKS on $DISK only (reinstall safety)..."
    local dev vg holder

    # 1. swapoff any swap LV/partition that sits on this disk.
    while read -r dev; do
        [[ -n "$dev" ]] && swapoff "$dev" 2>/dev/null || true
    done < <(lsblk -pnro NAME,FSTYPE "$DISK" 2>/dev/null | awk '$2=="swap"{print $1}')

    # 2. deactivate VGs whose PV is a crypt device on this disk, then a VG that
    #    sits directly on a partition of this disk (LVM without LUKS).
    while read -r holder; do
        vg="$(pvs --noheadings -o vg_name "$holder" 2>/dev/null | tr -d ' ')"
        [[ -n "$vg" ]] && vgchange -an "$vg" 2>/dev/null || true
    done < <(lsblk -pnro NAME,TYPE "$DISK" 2>/dev/null | awk '$2=="crypt"||$2=="part"{print $1}')

    # 3. close crypt mappings backed by this disk.
    while read -r holder; do
        cryptsetup close "$(basename "$holder")" 2>/dev/null || true
    done < <(lsblk -pnro NAME,TYPE "$DISK" 2>/dev/null | awk '$2=="crypt"{print $1}')

    # 4. wipe old signatures on the partitions we are about to recreate.
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
    udevadm settle --timeout=15 2>/dev/null || true

    # Hard gate: don't touch a partition node until the kernel has created it,
    # otherwise mkfs/cryptsetup can race a slow udev (NVMe/USB) or a stale node.
    local p n
    for p in "$PART_EFI" "$PART_LUKS"; do
        for ((n = 0; n < 50; n++)); do [[ -b "$p" ]] && break; sleep 0.1; done
        [[ -b "$p" ]] || die "Partition $p never appeared after partitioning $DISK (udev/kernel did not settle)."
    done

    info "Formatting EFI ($PART_EFI)"
    mkfs.fat -F32 "$PART_EFI"

    info "Encrypting $PART_LUKS (LUKS2)"
    # Discards leak some metadata about used blocks — README says no discards on
    # servers. Desktop/laptop: enable for SSD TRIM; server: omit.
    local -a open_opts=()
    [[ "$SYS_PROFILE" != "server" ]] && open_opts=(--allow-discards --persistent)

    # Passphrase read from stdin via --key-file - (no ambiguous trailing '-');
    # --batch-mode skips the interactive "type YES" so the pipe doesn't hang.
    printf '%s' "$LUKS_PW" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$PART_LUKS"
    printf '%s' "$LUKS_PW" | cryptsetup open --key-file - "${open_opts[@]}" "$PART_LUKS" cryptlvm
    [[ -b /dev/mapper/cryptlvm ]] || die "cryptsetup open did not create /dev/mapper/cryptlvm."
    ok "Encrypted container opened as /dev/mapper/cryptlvm (profile: $SYS_PROFILE)"
}

# ---------------------------------------------------------------------------
# Phase 6 — LVM + filesystems + mount
# ---------------------------------------------------------------------------
setup_lvm() {
    phase "LVM + filesystems"

    # Pick a VG name that doesn't collide with one on another disk (multi-drive).
    VG_NAME="vg"
    if vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ' | grep -qx "vg"; then
        local n=0
        while vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ' | grep -qx "vg${n}"; do n=$((n+1)); done
        VG_NAME="vg${n}"
        warn "A volume group 'vg' already exists (another disk); using '$VG_NAME'."
    fi

    pvcreate /dev/mapper/cryptlvm
    vgcreate "$VG_NAME" /dev/mapper/cryptlvm

    [[ -n "$SWAP_SIZE" ]] && lvcreate -L "$SWAP_SIZE" "$VG_NAME" -n swap
    if [[ "$SEPARATE_HOME" == "yes" ]]; then
        lvcreate -L "$ROOT_SIZE" "$VG_NAME" -n root
        lvcreate -l 100%FREE     "$VG_NAME" -n home
    else
        lvcreate -l 100%FREE     "$VG_NAME" -n root
    fi

    mkfs.ext4 "/dev/${VG_NAME}/root"
    [[ "$SEPARATE_HOME" == "yes" ]] && mkfs.ext4 "/dev/${VG_NAME}/home"
    [[ -n "$SWAP_SIZE" ]] && mkswap "/dev/${VG_NAME}/swap"

    info "Mounting target"
    mount "/dev/${VG_NAME}/root" /mnt
    mkdir -p /mnt/boot/efi
    if [[ "$SEPARATE_HOME" == "yes" ]]; then
        mkdir -p /mnt/home
        mount "/dev/${VG_NAME}/home" /mnt/home
    fi
    mount "$PART_EFI" /mnt/boot/efi
    [[ "$(findmnt -no FSTYPE /mnt/boot/efi 2>/dev/null)" == "vfat" ]] \
        || die "ESP is not mounted as vfat at /mnt/boot/efi."
    [[ -n "$SWAP_SIZE" ]] && swapon "/dev/${VG_NAME}/swap"
    ok "Filesystems mounted at /mnt (VG: $VG_NAME)"
}

# ---------------------------------------------------------------------------
# Phase 7 — mirrors + pacstrap + fstab
# ---------------------------------------------------------------------------
install_base() {
    phase "Mirror ranking + base install"

    if command -v reflector >/dev/null 2>&1; then
        local -a rfl=(--protocol https --sort rate --latest 20 --save /etc/pacman.d/mirrorlist)
        [[ -n "$GEO_COUNTRY" ]] && rfl=(--country "$GEO_COUNTRY" "${rfl[@]}")
        info "Ranking mirrors${GEO_COUNTRY:+ (country: $GEO_COUNTRY)}..."
        reflector "${rfl[@]}" 2>/dev/null || warn "reflector failed; keeping default mirrorlist."
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
    grep -qE '[[:space:]]/[[:space:]]' /mnt/etc/fstab \
        || die "genfstab produced no root (/) entry — aborting before an unbootable install."

    # Harden the vfat EFI mount (README.md:246-279): fmask=0137,dmask=0027.
    # genfstab emits real options (rw,relatime,fmask=0022,...) with no 'defaults'
    # token, so rewrite the vfat line's option field: drop any existing f/dmask,
    # then append the hardened pair. awk only rebuilds the matched line; every
    # other line (incl. comments) is printed byte-for-byte.
    awk -v OFS='\t' '
        $3=="vfat"{
            n=split($4,o,","); opts=""
            for(i=1;i<=n;i++) if(o[i] !~ /^(fmask|dmask)=/) opts=(opts==""?o[i]:opts","o[i])
            $4=opts",fmask=0137,dmask=0027"
        }
        {print}
    ' /mnt/etc/fstab > /mnt/etc/fstab.tmp && mv -f /mnt/etc/fstab.tmp /mnt/etc/fstab
    grep -qE '[[:space:]]vfat[[:space:]].*fmask=0137,dmask=0027' /mnt/etc/fstab \
        || die "Failed to apply EFI vfat hardening (fmask/dmask) to fstab."
    ok "Base system installed."
}

# ---------------------------------------------------------------------------
# Phase 8+9 — chroot configuration (config, users, UKI, bootloader)
# ---------------------------------------------------------------------------
configure_system() {
    phase "System configuration (chroot)"

    local luks_uuid root_uuid
    luks_uuid="$(blkid -s UUID -o value "$PART_LUKS" || true)"
    root_uuid="$(blkid -s UUID -o value "/dev/${VG_NAME}/root" || true)"
    [[ -n "$luks_uuid" ]] || die "Could not read LUKS UUID from $PART_LUKS"
    [[ -n "$root_uuid" ]] || die "Could not read root filesystem UUID"

    # Only NON-SECRET values cross into the chroot environment. Passwords are set
    # afterwards via a stdin pipe, so they never touch env, disk, or logs.
    export CH_TZ="$TIMEZONE" CH_LOCALE="$LOCALE" CH_KEYMAP="$KEYMAP" \
           CH_HOST="$HOSTNAME" CH_USER="$USERNAME" CH_PROFILE="$SYS_PROFILE" \
           CH_LUKS_UUID="$luks_uuid" CH_ROOT_UUID="$root_uuid"

    arch-chroot /mnt /usr/bin/env bash -euo pipefail <<'CHROOT'
# --- timezone / clock ---
ln -sf "/usr/share/zoneinfo/$CH_TZ" /etc/localtime
hwclock --systohc

# --- locale: uncomment the exact entry whose first field == the canonical name
#     (CH_LOCALE came from locale_canonical, so it matches /etc/locale.gen verbatim) ---
awk -v L="$CH_LOCALE" '
    { c = $0; sub(/^#[ \t]*/, "", c); split(c, f, /[ \t]+/); if (f[1] == L) sub(/^#[ \t]*/, "", $0) }
    { print }
' /etc/locale.gen > /etc/locale.gen.tmp && mv -f /etc/locale.gen.tmp /etc/locale.gen
awk -v L="$CH_LOCALE" '$0 !~ /^#/ && $1 == L { found = 1 } END { exit found ? 0 : 1 }' /etc/locale.gen \
    || { echo "locale '$CH_LOCALE' is not enabled in /etc/locale.gen" >&2; exit 1; }
locale-gen
echo "LANG=${CH_LOCALE}" > /etc/locale.conf

# --- console keymap/font ---
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

# --- user (password set later, outside this heredoc) ---
useradd -m -G wheel "$CH_USER"

# --- sudo for wheel via drop-in (never edit /etc/sudoers directly) ---
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# --- services (fstrim only when not a server) ---
systemctl enable NetworkManager
[ "$CH_PROFILE" != "server" ] && systemctl enable fstrim.timer

# --- mkinitcpio HOOKS: sd-encrypt before lvm2 before filesystems (Arch wiki) ---
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf

# --- kernel cmdline: unlock LUKS by UUID, find root by filesystem UUID ---
echo "rd.luks.name=${CH_LUKS_UUID}=cryptlvm root=UUID=${CH_ROOT_UUID} rootfstype=ext4 rw quiet bgrt_disable" > /etc/kernel/cmdline

# --- UKI presets for linux + linux-lts (single 'default' image, README form) ---
cat > /etc/mkinitcpio.d/linux.preset <<'PRESET'
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default')
default_uki="/boot/efi/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
PRESET

cat > /etc/mkinitcpio.d/linux-lts.preset <<'PRESET'
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-lts"
PRESETS=('default')
default_uki="/boot/efi/EFI/Linux/arch-linux-lts.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
PRESET

# --- build the UKIs into the ESP ---
mkdir -p /boot/efi/EFI/Linux
mkinitcpio -P

# Hard gate: mkinitcpio can print errors yet exit 0 on some preset mistakes.
# Refuse to finish with a machine that has no bootable kernel image.
for u in /boot/efi/EFI/Linux/arch-linux.efi /boot/efi/EFI/Linux/arch-linux-lts.efi; do
    [ -s "$u" ] || { echo "UKI $u was not produced by mkinitcpio — aborting." >&2; exit 1; }
done

# --- systemd-boot: install to the ESP we chose; tolerate a chroot without
#     writable EFI variables (falls back to plain file install). ---
if ! bootctl --esp-path=/boot/efi install; then
    echo "bootctl couldn't write EFI variables in chroot; installing loader files only." >&2
    bootctl --esp-path=/boot/efi --no-variables install
fi
[ -f /boot/efi/EFI/systemd/systemd-bootx64.efi ] \
    || { echo "systemd-boot loader was not installed to the ESP — aborting." >&2; exit 1; }
cat > /boot/efi/loader/loader.conf <<LOADER
default         arch-linux.efi
timeout         0
console-mode    auto
editor          no
LOADER
systemctl enable systemd-boot-update.service
CHROOT

    # Set passwords WITHOUT env/heredoc exposure: piped to chpasswd over stdin,
    # invisible to /proc/<pid>/environ, shell traces, and disk.
    printf 'root:%s\n' "$ROOT_PW"           | arch-chroot /mnt chpasswd
    printf '%s:%s\n' "$USERNAME" "$USER_PW" | arch-chroot /mnt chpasswd

    ok "System configured, UKIs generated, systemd-boot installed."
}

# ---------------------------------------------------------------------------
# Phase 10 — finish
# ---------------------------------------------------------------------------
finish() {
    phase "Finishing up"

    # Scrub secrets from the environment.
    unset ROOT_PW USER_PW LUKS_PW

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
