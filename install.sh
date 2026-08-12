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

# LVM tools inherit start_logging's transcript pipe and warn about a "leaked" fd
# on every pvcreate/vgcreate/lvcreate. Cosmetic, not a real leak — silence it.
export LVM_SUPPRESS_FD_WARNINGS=1

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
DESTRUCTIVE_STARTED=0   # flips to 1 once we begin writing to the disk (partition_disk)
LOG=""                  # full-run transcript path (set in start_logging)
LOG_FIFO=""             # named pipe feeding the transcript writer
LOG_PID=""              # PID of the transcript writer, so stop_logging can wait on it
LOG_HOLD=""             # read-write fd keeping the pipe open, so writes never block
ORIG_OUT=""             # saved terminal fds, restored by stop_logging to seal the pipe
ORIG_ERR=""

info()  { printf '%s==>%s %s\n'      "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
ok()    { printf '%s  ✓%s %s\n'      "$C_GREEN"       "$C_RESET" "$*"; }
warn()  { printf '%s  !%s %s\n'      "$C_YELLOW"      "$C_RESET" "$*" >&2; }
die()   { printf '\n%sinstall failed during phase: %s%s\n%s%s%s\n' \
             "$C_RED$C_BOLD" "$CURRENT_PHASE" "$C_RESET" "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
phase() { CURRENT_PHASE="$1"; printf '\n%s########## %s %s\n' "$C_BOLD" "$1" "$C_RESET"; }

# On any unexpected error, print the recovery commands so a partial LUKS/LVM
# state can be torn down before retrying.
on_err() {
    local exit_code=$?
    # The FIFO itself is disposable; the transcript file it fed is what matters.
    [[ -n "${LOG_FIFO:-}" ]] && rm -f "$LOG_FIFO" 2>/dev/null
    [[ $exit_code -eq 0 ]] && return 0
    printf '\n%s##### install aborted (exit %s) during: %s #####%s\n' \
        "$C_RED$C_BOLD" "$exit_code" "$CURRENT_PHASE" "$C_RESET" >&2
    if [[ -n "${LOG:-}" ]]; then
        printf 'Full transcript of this run (read before rebooting the ISO): %s\n' "$LOG" >&2
    fi
    # Nothing is written before partition_disk, so teardown only applies after it.
    if [[ "${DESTRUCTIVE_STARTED:-0}" == "1" ]]; then
        cat >&2 <<'EOF'

The disk was already being written to. Tear down the partial state before retrying:

    swapoff -a
    umount -R /mnt        2>/dev/null || true
    vgchange -an          2>/dev/null || true
    cryptsetup close cryptlvm 2>/dev/null || true

Then re-run the installer.
EOF
    else
        printf '\n%s\n' "Nothing was written to the disk. Fix the issue above and re-run." >&2
    fi
}
trap on_err EXIT

# ---------------------------------------------------------------------------
# Defaults (all overridable at the prompts) — mirror README.md
# ---------------------------------------------------------------------------
readonly DEF_EFI_SIZE="1G"
readonly DEF_TIMEZONE="Europe/London"
readonly DEF_LOCALE="en_GB.UTF-8"
readonly DEF_KEYMAP="us"

# Base package set (README.md:262), minus Secure Boot + base-devel. Declared here
# so write_install_log can record it and verify-install.sh can audit against the
# recorded list, rather than keeping a second copy that silently drifts.
readonly -a BASE_PKGS=(
    base linux linux-firmware linux-lts
    lvm2 vim sudo git networkmanager
    efibootmgr ntfs-3g binutils systemd-ukify
)

# Same reasoning as BASE_PKGS: crossed into the chroot as CH_HOOKS and recorded.
readonly MKINITCPIO_HOOKS="base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck"

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

# Prompt for a value that must match a regex (loops until it does).
# prompt_matching VAR "Question" '^regex$' "hint shown on mismatch"
prompt_matching() {
    local __var="$1" question="$2" regex="$3" hint="$4" reply=""
    while :; do
        read -rp "$question: " reply || true
        [[ "$reply" =~ $regex ]] && break
        warn "$hint"
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

    # gather_input is interactive; under `curl … | bash` every read hits EOF and
    # prompt_required would spin forever. Refuse now, and name the working form.
    [[ -t 0 ]] || die "stdin is not a terminal — this installer is interactive. Run: bash <(curl -fsSL <url>)"

    # A mid-partition "command not found" would leave the disk half-written.
    local tool missing=()
    for tool in sgdisk cryptsetup mkfs.fat mkfs.ext4 mkswap wipefs partprobe \
                udevadm blkid lsblk pvcreate vgcreate lvcreate vgs pvs \
                genfstab pacstrap arch-chroot curl awk; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    (( ${#missing[@]} == 0 )) || die "Missing required tools: ${missing[*]}. Boot the official Arch ISO and re-run."

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
    # awk's early 'exit' can SIGPIPE iwctl (or iwctl exits non-zero with no
    # adapter); under pipefail that would abort before the wl* fallback runs.
    wdev="$(iwctl device list 2>/dev/null | awk '/station/{print $2; exit}')" || wdev=""
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
# Best-effort timezone guess from the public IP. Echoes a valid zone, or non-zero.
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
        # '|| GEO_COUNTRY=""' is required: curl -f exits non-zero on 429/5xx and,
        # under pipefail, would fail this assignment and abort the installer.
        GEO_COUNTRY="$(curl -fsSL --max-time 5 https://ipapi.co/country 2>/dev/null | tr -d '[:space:]')" || GEO_COUNTRY=""
        # Geo-IP can return an HTML error body; only a real ISO code may reach reflector.
        [[ "$GEO_COUNTRY" =~ ^[A-Za-z][A-Za-z]$ ]] || GEO_COUNTRY=""
        read -rp "Timezone — detected '$detected'. Enter to accept, type another, or 's' to search: " reply || true
        reply="${reply:-$detected}"
    else
        warn "Couldn't auto-detect your timezone."
        read -rp "Timezone [$DEF_TIMEZONE] (type 's' to search by city): " reply || true
        reply="${reply:-$DEF_TIMEZONE}"
    fi
    resolve_timezone "$reply"
}

# Resolve a user-typed locale to the exact /etc/locale.gen name, preferring UTF-8.
# Case-insensitive in, the file's real casing out; bare "en_US" never resolves to
# the ISO-8859-1 entry.
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
        # Validate against localectl's list when we have one (literal, not regex).
        if [[ -z "$keymaps" ]] || printf '%s\n' "$keymaps" | grep -Fxq -- "$reply"; then
            KEYMAP="$reply"
            return 0
        fi
        warn "'$reply' isn't a known keymap. Type 's' to search."
        read -rp "  keymap: " reply || true
    done
}

# Deterministic layout (no prompts, matches README's swap/root/home form): swap =
# total RAM, root = 10% of the disk capped at 100 GiB, /home = the rest. Shown in
# the wipe confirmation before anything is written.
configure_layout() {
    local dsize swap_g root_g

    dsize="$(disk_gib "$DISK")"          # whole GiB (floored)

    # Fixed 1 GiB ESP: holds all four UKIs (~50-120 MiB each) with headroom, and
    # more is wasteful for the personal-workstation case this installer targets.
    EFI_SIZE="$DEF_EFI_SIZE"

    # swap = total RAM (whole GiB, rounded up), so a hibernation image would fit.
    # No resume= is set, though: hibernation is out of scope (swap is inside LUKS).
    swap_g="$(ram_gib)"
    if (( swap_g >= 1 )); then SWAP_SIZE="${swap_g}G"; else SWAP_SIZE=""; fi

    # root = 10% of the disk, capped at 100 GiB (a 10 TB disk still gets 100 GiB).
    root_g=$(( dsize / 10 ))
    (( root_g > 100 )) && root_g=100
    (( root_g < 1 ))   && root_g=1       # guard tiny / undetected disks
    ROOT_SIZE="${root_g}G"

    # /home takes whatever remains.
    SEPARATE_HOME="yes"

    echo
    info "Disk: $DISK (~${dsize} GiB) — automatic layout:"
    printf '    EFI   %s\n    swap  %s   (= RAM)\n    root  %s   (10%% of disk, capped at 100G)\n    home  rest of the disk\n' \
        "$EFI_SIZE" "${SWAP_SIZE:-none}" "$ROOT_SIZE"

    # Fit check: EFI + swap + root must leave at least ~1 GiB for /home.
    local fixed=$(( 1 + swap_g + root_g ))
    if (( dsize > 0 && fixed + 1 > dsize )); then
        die "Auto layout (EFI 1 + swap ${swap_g} + root ${root_g} = ${fixed} GiB) leaves no room for /home on a ~${dsize} GiB disk. Use a larger disk."
    fi
    if (( root_g < 15 )); then
        warn "root is only ${root_g} GiB (10% of a small disk) — the base install fits but may fill quickly."
    fi
}

gather_input() {
    phase "Configuration prompts"

    info "Available disks:"
    lsblk -dpno NAME,SIZE,MODEL | grep -vE 'loop|sr0' || true
    echo
    local dtype
    while :; do
        prompt_required DISK "Target disk (e.g. /dev/vda or just vda)"
        [[ "$DISK" != /dev/* && -b "/dev/$DISK" ]] && DISK="/dev/$DISK"
        if [[ -b "$DISK" ]]; then
            # Whole disk only: against e.g. /dev/sda1, sgdisk/wipefs would hit the
            # parent and part_name would build bogus children. Loop devices are
            # allowed so file-backed VM testing works.
            dtype="$(lsblk -dnro TYPE "$DISK" 2>/dev/null | head -n1)" || dtype=""
            [[ "$dtype" == "disk" || "$dtype" == "loop" ]] && break
            warn "'$DISK' is a ${dtype:-non-disk device}, not a whole disk. Enter the whole disk (e.g. /dev/vda), not a partition."
            continue
        fi
        warn "'$DISK' is not a block device. Pick one from the list above."
    done

    PART_EFI="$(part_name "$DISK" 1)"
    PART_LUKS="$(part_name "$DISK" 2)"

    configure_layout

    echo
    # Validate before anything destructive — a bad hostname/username would
    # otherwise only surface deep inside the chroot, long after the wipe.
    prompt_matching HOSTNAME "Hostname" \
        '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$' \
        "Hostname must be 1-63 chars: letters/digits/hyphens, no leading/trailing hyphen."
    prompt_matching USERNAME "Username" \
        '^[a-z_][a-z0-9_-]{0,31}$' \
        "Username must start with a lowercase letter or _, then lowercase/digits/_/- (max 32)."
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
    # Keep this an `if`, not `[[ ... ]] && ok`: as the function's last statement an
    # &&-list returns 1 when UCODE is empty, aborting the installer under set -e.
    if [[ -n "$UCODE" ]]; then ok "CPU microcode: $UCODE"; fi
}

# ---------------------------------------------------------------------------
# Phase 4 — wipe-confirmation gate
# ---------------------------------------------------------------------------
confirm_wipe() {
    phase "Confirm disk wipe"
    local bare="${DISK##*/}"

    # Model + size + serial, not just the path — a name match alone is too weak a
    # gate before an irreversible wipe.
    local model size serial
    model="$(lsblk -dno MODEL  "$DISK" 2>/dev/null | head -n1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    size="$(lsblk -dno SIZE    "$DISK" 2>/dev/null | head -n1)"
    serial="$(lsblk -dno SERIAL "$DISK" 2>/dev/null | head -n1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    printf '%s%s\n  EVERYTHING on %s (%s%s%s) will be ERASED.%s\n\n' \
        "$C_YELLOW" "$C_BOLD" "$DISK" "${size:-unknown size}" "${model:+, $model}" "${serial:+, S/N $serial}" "$C_RESET"
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

    # Catches picking the live USB, or a leftover /mnt from a failed run. Active
    # swap ([SWAP]) is fine; the teardown handles it.
    if lsblk -nro MOUNTPOINT "$DISK" 2>/dev/null | grep -q '^/'; then
        die "$DISK has mounted partitions. Unmount them (or pick another disk) and re-run."
    fi

    local reply
    read -rp "Type the disk name '$bare' to confirm: " reply || true
    reply="${reply//[[:space:]]/}"                       # ignore stray pasted whitespace
    [[ "$reply" == "$bare" ]] || die "Name mismatch ('$reply' vs '$bare') — nothing was written."
    read -rp "Final check — type YES (uppercase) to ERASE $DISK (${size:-?}${model:+, $model}): " reply || true
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
        # pvs on a non-PV (an old EFI/NTFS partition here) exits non-zero; under
        # pipefail that aborts teardown — the exact case a reinstall hits.
        vg="$(pvs --noheadings -o vg_name "$holder" 2>/dev/null | tr -d ' ')" || vg=""
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
    DESTRUCTIVE_STARTED=1        # from here on, the disk is being rewritten
    teardown_existing

    info "Writing GPT layout to $DISK"
    wipefs -fa "$DISK"
    sgdisk --zap-all "$DISK"
    sgdisk --new=1:0:+"$EFI_SIZE" --typecode=1:EF00 --change-name=1:EFI "$DISK"
    sgdisk --new=2:0:0            --typecode=2:8309 --change-name=2:cryptlvm "$DISK"
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle --timeout=15 2>/dev/null || true

    # Don't touch a partition node before the kernel creates it, or mkfs/cryptsetup
    # can race a slow udev (NVMe/USB) or hit a stale node.
    local p n
    for p in "$PART_EFI" "$PART_LUKS"; do
        for ((n = 0; n < 50; n++)); do [[ -b "$p" ]] && break; sleep 0.1; done
        [[ -b "$p" ]] || die "Partition $p never appeared after partitioning $DISK (udev/kernel did not settle)."
    done

    info "Formatting EFI ($PART_EFI)"
    mkfs.fat -F32 "$PART_EFI"

    info "Encrypting $PART_LUKS (LUKS2)"
    # Discards leak metadata about used blocks, so servers omit them; desktops and
    # laptops enable them for SSD TRIM.
    local -a open_opts=()
    [[ "$SYS_PROFILE" != "server" ]] && open_opts=(--allow-discards --persistent)

    # --key-file - reads the passphrase from stdin (no ambiguous trailing '-');
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

    # -q: mke2fs's progress counter redraws with backspaces (0x08) that are
    # invisible on a tty but land as literal ^H in the transcript, which only
    # strips ANSI colour.
    mkfs.ext4 -q "/dev/${VG_NAME}/root"
    [[ "$SEPARATE_HOME" == "yes" ]] && mkfs.ext4 -q "/dev/${VG_NAME}/home"
    [[ -n "$SWAP_SIZE" ]] && mkswap "/dev/${VG_NAME}/swap"

    info "Mounting target"
    mount "/dev/${VG_NAME}/root" /mnt
    # Prove /mnt is the LV we just created before pacstrap writes to it.
    [[ "$(findmnt -no SOURCE /mnt 2>/dev/null)" == "/dev/mapper/${VG_NAME}-root" ]] \
        || die "/mnt is not the freshly created root LV (/dev/mapper/${VG_NAME}-root) — refusing to continue."
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
        # reflector can exit 0 yet leave an empty list (over-narrow --country,
        # transient mirror JSON), and pacstrap would then fail cryptically
        # post-wipe. Back up first, roll back unless real Server lines landed.
        cp -f /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.installsh.bak 2>/dev/null || true
        if reflector "${rfl[@]}" 2>/dev/null && grep -q '^[[:space:]]*Server' /etc/pacman.d/mirrorlist; then
            ok "Mirrorlist ranked."
        else
            warn "reflector failed or produced no mirrors; restoring the default mirrorlist."
            cp -f /etc/pacman.d/mirrorlist.installsh.bak /etc/pacman.d/mirrorlist 2>/dev/null || true
        fi
    fi
    grep -q '^[[:space:]]*Server' /etc/pacman.d/mirrorlist \
        || die "No usable pacman mirrors in /etc/pacman.d/mirrorlist — check the network and re-run."

    local -a pkgs=("${BASE_PKGS[@]}")
    [[ -n "$UCODE" ]] && pkgs+=("$UCODE")

    info "pacstrap: ${pkgs[*]}"
    pacstrap -K /mnt "${pkgs[@]}"

    info "Generating fstab"
    genfstab -U /mnt >> /mnt/etc/fstab
    grep -qE '[[:space:]]/[[:space:]]' /mnt/etc/fstab \
        || die "genfstab produced no root (/) entry — aborting before an unbootable install."

    # Harden the vfat EFI mount (README.md:276): fmask=0137,dmask=0027. genfstab
    # emits real options with no 'defaults' token, so rewrite the option field —
    # drop any existing f/dmask, append the hardened pair. awk rebuilds only the
    # matched line; everything else is printed byte-for-byte.
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

    # Only NON-SECRET values cross into the chroot environment; passwords are set
    # afterwards over a stdin pipe, never touching env, disk, or logs.
    export CH_TZ="$TIMEZONE" CH_LOCALE="$LOCALE" CH_KEYMAP="$KEYMAP" \
           CH_HOST="$HOSTNAME" CH_USER="$USERNAME" CH_PROFILE="$SYS_PROFILE" \
           CH_LUKS_UUID="$luks_uuid" CH_ROOT_UUID="$root_uuid" \
           CH_HOOKS="$MKINITCPIO_HOOKS"

    arch-chroot /mnt /usr/bin/env bash -euo pipefail <<'CHROOT'
# --- timezone / clock ---
ln -sf "/usr/share/zoneinfo/$CH_TZ" /etc/localtime
# Non-fatal: a read-only or absent RTC (some VMs) must not abort a good install.
hwclock --systohc || echo "warning: could not sync the hardware clock; continuing." >&2

# --- locale: uncomment the entry whose first field == CH_LOCALE, which came from
#     locale_canonical and so matches /etc/locale.gen verbatim ---
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
# A malformed drop-in, or a /etc/sudoers missing the includedir, leaves a system
# where the user cannot escalate. Validate both before handing off.
visudo -cf /etc/sudoers.d/10-wheel >/dev/null \
    || { echo "sudoers drop-in /etc/sudoers.d/10-wheel failed validation — aborting." >&2; exit 1; }
grep -Eq '^[[:space:]]*@?includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers \
    || { echo "/etc/sudoers does not include /etc/sudoers.d — wheel sudo would not apply; aborting." >&2; exit 1; }
# Definitive escalation test: a real parse of the LIVE, fully-included sudoers
# (not a text heuristic), so a broken policy fails here and not after first boot.
sudo -l -U "$CH_USER" 2>/dev/null | grep -Eq '\(ALL[^)]*\)[[:space:]]+ALL' \
    || { echo "sudo policy does not grant '$CH_USER' admin rights (sudo -l parse failed) — aborting." >&2; exit 1; }

# --- services (fstrim only when not a server) ---
systemctl enable NetworkManager
[ "$CH_PROFILE" != "server" ] && systemctl enable fstrim.timer

# --- mkinitcpio HOOKS: sd-encrypt before lvm2 before filesystems (Arch wiki) ---
# sed only substitutes an existing uncommented HOOKS= line. If the format ever
# drifts the substitution is a silent no-op and the initramfs is unbootable, so
# assert the result rather than trust it.
sed -i "s|^HOOKS=.*|HOOKS=($CH_HOOKS)|" /etc/mkinitcpio.conf
grep -qxF "HOOKS=($CH_HOOKS)" /etc/mkinitcpio.conf \
    || { echo "mkinitcpio HOOKS line was not set as expected (unexpected mkinitcpio.conf format) — aborting." >&2; exit 1; }
# Guard the constant's order too: lvm2 before sd-encrypt writes cleanly and still
# yields an unbootable initramfs.
grep -Eq '^HOOKS=\(base systemd .*sd-encrypt.*lvm2.*filesystems' /etc/mkinitcpio.conf \
    || { echo "mkinitcpio HOOKS order is wrong (need sd-encrypt before lvm2 before filesystems) — aborting." >&2; exit 1; }

# --- kernel cmdline: unlock LUKS by UUID, find root by filesystem UUID ---
echo "rd.luks.name=${CH_LUKS_UUID}=cryptlvm root=UUID=${CH_ROOT_UUID} rootfstype=ext4 rw quiet bgrt_disable" > /etc/kernel/cmdline
# A wrong or empty UUID here bakes a silently unbootable image, so check first.
grep -q "$CH_LUKS_UUID" /etc/kernel/cmdline && grep -q "$CH_ROOT_UUID" /etc/kernel/cmdline \
    || { echo "kernel cmdline is missing the expected LUKS/root UUID — aborting." >&2; exit 1; }

# --- UKI presets for linux + linux-lts (README form) ---
# Each kernel builds TWO images: the pruned 'default' UKI, and a 'fallback' one
# (-S autodetect => autodetect skipped, so every module is packed) for when the
# pruned image can't find or mount root. The README lists fallback_uki but leaves
# PRESETS=('default'), so it would never build that fallback; setting both here is
# a deliberate divergence.
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

# --- build the UKIs into the ESP ---
mkdir -p /boot/efi/EFI/Linux
mkinitcpio -P

# mkinitcpio can print errors yet exit 0 on some preset mistakes, so refuse to
# finish with no bootable kernel image. All four UKIs bake in the same
# /etc/kernel/cmdline, so the embed check below applies to every one of them.
for u in /boot/efi/EFI/Linux/arch-linux.efi          /boot/efi/EFI/Linux/arch-linux-fallback.efi \
         /boot/efi/EFI/Linux/arch-linux-lts.efi      /boot/efi/EFI/Linux/arch-linux-lts-fallback.efi; do
    [ -s "$u" ] || { echo "UKI $u was not produced by mkinitcpio — aborting." >&2; exit 1; }
    # Beyond "the .efi exists": prove each UKI embeds both UUIDs in its .cmdline
    # PE section (objcopy ships with binutils, installed above). An unreadable
    # section only warns — a present-but-wrong cmdline is the real hazard.
    # `|| emb=""` is load-bearing: without it a failing objcopy would abort the
    # chroot under `set -euo pipefail` instead of reaching that warning.
    emb="$(objcopy -O binary --only-section=.cmdline "$u" /dev/stdout 2>/dev/null | tr -d '\0')" || emb=""
    if [ -n "$emb" ]; then
        case "$emb" in *"$CH_LUKS_UUID"*) ;; *)
            echo "UKI $u does not embed the expected LUKS UUID in its cmdline — aborting." >&2; exit 1 ;; esac
        case "$emb" in *"$CH_ROOT_UUID"*) ;; *)
            echo "UKI $u does not embed the expected root UUID in its cmdline — aborting." >&2; exit 1 ;; esac
    else
        echo "warning: could not read the .cmdline section from $u; skipping embed check." >&2
    fi
done

# --- systemd-boot: install to the ESP we chose; tolerate a chroot without
#     writable EFI variables (falls back to plain file install). ---
if ! bootctl --esp-path=/boot/efi install; then
    echo "bootctl couldn't write EFI variables in chroot; installing loader files only." >&2
    bootctl --esp-path=/boot/efi --no-variables install
fi
[ -f /boot/efi/EFI/systemd/systemd-bootx64.efi ] \
    || { echo "systemd-boot loader was not installed to the ESP — aborting." >&2; exit 1; }
# The non-zero timeout is deliberate: with `timeout 0` the menu is only reachable
# by holding Space, making the fallback UKIs unusable exactly when they're needed.
cat > /boot/efi/loader/loader.conf <<LOADER
default         arch-linux.efi
timeout         3
console-mode    auto
editor          no
LOADER
grep -q '^default[[:space:]]*arch-linux.efi' /boot/efi/loader/loader.conf \
    || { echo "loader.conf was not written to the ESP with the expected default — aborting." >&2; exit 1; }
# Enabling a unit the target doesn't ship would abort the run over a non-critical service.
if [ -e /usr/lib/systemd/system/systemd-boot-update.service ]; then
    systemctl enable systemd-boot-update.service
else
    echo "warning: systemd-boot-update.service not present in target; skipping enable." >&2
fi

# Confirm systemd-boot parses a real entry off the ESP (no EFI variables needed).
# Informational only: bootctl can be terse in an offline chroot, and the .cmdline
# embed check above is the deterministic gate.
if bootctl --esp-path=/boot/efi list 2>/dev/null | grep -q 'arch-linux\.efi'; then
    echo "bootctl: arch-linux.efi boot entry present on the ESP." >&2
else
    echo "warning: bootctl list did not report an arch-linux.efi entry; verify after first boot." >&2
fi
CHROOT

    # Piped to chpasswd over stdin, so invisible to /proc/<pid>/environ, shell
    # traces, and disk.
    printf 'root:%s\n' "$ROOT_PW"           | arch-chroot /mnt chpasswd
    printf '%s:%s\n' "$USERNAME" "$USER_PW" | arch-chroot /mnt chpasswd

    ok "System configured, UKIs generated, systemd-boot installed."
}

# Record the disk, layout, identity, and boot artifacts that produced this system,
# for later debugging. Best-effort and never secret: a logging failure must not
# fail an otherwise successful install.
write_install_log() {
    local logf="/mnt/var/log/archsetup-install.log" mirror_src
    mkdir -p /mnt/var/log 2>/dev/null || return 0

    if [[ -n "$GEO_COUNTRY" ]]; then
        mirror_src="reflector --country $GEO_COUNTRY"
    else
        mirror_src="reflector (country undetected) or preserved default mirrorlist"
    fi

    {
        echo   "# archsetup install.sh — install record (no secrets)"
        echo   "timestamp:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'disk:          %s (size=%s model=%s serial=%s)\n' \
            "$DISK" \
            "$(lsblk -dno SIZE   "$DISK" 2>/dev/null | head -n1)" \
            "$(lsblk -dno MODEL  "$DISK" 2>/dev/null | head -n1 | sed -e 's/^ *//' -e 's/ *$//')" \
            "$(lsblk -dno SERIAL "$DISK" 2>/dev/null | head -n1 | sed -e 's/^ *//' -e 's/ *$//')"
        echo   "efi_part:      $PART_EFI ($EFI_SIZE)"
        echo   "luks_part:     $PART_LUKS"
        echo   "vg_name:       $VG_NAME"
        echo   "swap:          ${SWAP_SIZE:-none}"
        echo   "root_size:     ${ROOT_SIZE:-rest of VG}"
        echo   "separate_home: $SEPARATE_HOME"
        echo   "profile:       $SYS_PROFILE"
        echo   "microcode:     ${UCODE:-none}"
        echo   "hostname:      $HOSTNAME"
        echo   "username:      $USERNAME"
        echo   "timezone:      $TIMEZONE"
        echo   "locale:        $LOCALE"
        echo   "keymap:        $KEYMAP"
        echo   "mirror_src:    $mirror_src"
        # Read back by verify-install.sh instead of it keeping its own copies.
        echo   "packages:      ${BASE_PKGS[*]}"
        echo   "hooks:         $MKINITCPIO_HOOKS"
        echo   "boot_uki:      $(for f in /mnt/boot/efi/EFI/Linux/*.efi; do [ -e "$f" ] && printf '%s ' "${f#/mnt}"; done)"
        echo   "loader:        $([ -f /mnt/boot/efi/EFI/systemd/systemd-bootx64.efi ] && echo present || echo MISSING)"
    } > "$logf" 2>/dev/null || return 0
    chmod 600 "$logf" 2>/dev/null || true
    ok "Install record written to /var/log/archsetup-install.log (on the new system)."
}

# ---------------------------------------------------------------------------
# Phase 10 — finish
# ---------------------------------------------------------------------------
finish() {
    phase "Finishing up"

    # Record what we built (while /mnt is still mounted) before tearing it down.
    write_install_log

    # Scrub secrets from the environment.
    unset ROOT_PW USER_PW LUKS_PW

    # Print the hand-off BEFORE sealing the transcript, so the copy on the target
    # ends with the completion banner rather than mid-teardown.
    cat <<EOF

${C_GREEN}${C_BOLD}Base install complete.${C_RESET}

After you reboot and log in as '${USERNAME}', run the post-install setup:

    ${C_BOLD}bash <(curl -fsSL https://raw.githubusercontent.com/gameshler/archsetup/main/start.sh)${C_RESET}

EOF

    # The ISO's copy is on tmpfs and vanishes on reboot, so keep one on the target.
    # stop_logging must come first, or the copy is a truncated snapshot of a
    # still-open tee pipe.
    local saved=""
    if [[ -n "$LOG" ]]; then
        stop_logging
        if [[ -f "$LOG" ]] && mkdir -p /mnt/var/log 2>/dev/null \
           && cp -f "$LOG" /mnt/var/log/ 2>/dev/null; then
            # Match the install record's 600: same non-secret identity data
            # (disk serial, hostname, username), no reason to be world-readable.
            chmod 600 "/mnt/var/log/$(basename "$LOG")" 2>/dev/null || true
            saved="/var/log/$(basename "$LOG")"
        fi
    fi

    info "Unmounting"
    swapoff -a 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true

    trap - EXIT
    if [[ -n "$saved" ]]; then
        info "Install transcript saved on the new system: $saved"
    elif [[ -n "$LOG" ]]; then
        warn "Could not copy the transcript onto the target; it stays at $LOG on this ISO (lost on reboot)."
    fi
    local reply
    read -rp "Reboot now? [y/N]: " reply || true
    if [[ "${reply,,}" == "y" ]]; then
        info "Rebooting..."
        reboot
    else
        info "Reboot manually when ready:  reboot"
    fi
}

# Tee the whole run (stdout+stderr) to a timestamped transcript so a fast-scrolling
# or failed run can be read back. Colour stays on the terminal but is stripped from
# the file, keeping it greppable. finish() copies it onto the target on success; on
# failure it stays on the ISO to be read before rebooting.
start_logging() {
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    LOG="/var/log/archsetup-install-${ts}.log"
    if ! : > "$LOG" 2>/dev/null; then
        LOG=""
        warn "Could not open a transcript in /var/log; continuing without one."
        return 0
    fi

    LOG_FIFO="$(mktemp -u /tmp/archsetup-log.XXXXXX)"
    if ! mkfifo -m 600 "$LOG_FIFO" 2>/dev/null; then
        LOG="" LOG_FIFO=""
        warn "Could not create the transcript pipe; continuing without a transcript."
        return 0
    fi

    exec {ORIG_OUT}>&1 {ORIG_ERR}>&2
    # A real background job, deliberately NOT a process substitution: bash cannot
    # `wait` on one, so finish() would copy a half-written file. A named pipe plus
    # a job PID lets stop_logging wait for a definite EOF-and-exit.
    { tee "/dev/fd/$ORIG_OUT" < "$LOG_FIFO" \
        | sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG"; } &
    LOG_PID=$!
    # Hold the pipe open read-write first: with no reader present `exec 1>fifo`
    # blocks forever, hanging the installer if the writer job failed to come up.
    exec {LOG_HOLD}<>"$LOG_FIFO"
    exec 1>"$LOG_FIFO" 2>&1
    info "Full transcript of this run: $LOG"
}

# Seal the transcript: restore the terminal fds, dropping the last references to
# the pipe's write end so the writer sees EOF, then wait for it. $LOG is only
# complete and safe to copy after this returns.
stop_logging() {
    [[ -n "$LOG_PID" ]] || return 0
    # The leading 1 is required: bare `>&word` is bash's `&>word` shorthand
    # (redirect both streams to a *file*) unless the fd number is explicit.
    exec 1>&"$ORIG_OUT" 2>&"$ORIG_ERR"
    exec {ORIG_OUT}>&- {ORIG_ERR}>&- {LOG_HOLD}>&-
    wait "$LOG_PID" 2>/dev/null || true
    ORIG_OUT="" ORIG_ERR="" LOG_PID=""
    rm -f "$LOG_FIFO" 2>/dev/null || true
    LOG_FIFO=""
}

# ---------------------------------------------------------------------------
main() {
    start_logging
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
