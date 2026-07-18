#!/usr/bin/env bash
#
# verify-install.sh — read-only PASS/FAIL audit of a system built by install.sh.
#
# Run this ON THE FRESHLY BOOTED target (not the live ISO). It re-checks every
# install-scope item from README.md — partition/LUKS/LVM layout, filesystems +
# fstab hardening, base packages, localization, user/sudo, services, and the
# whole mkinitcpio-UKI + systemd-boot chain — and prints PASS / FAIL / WARN per
# item plus a summary. Exit status is non-zero if anything FAILed.
#
# It is strictly READ-ONLY: it inspects state (findmnt, lsblk, blkid, cryptsetup
# luksDump/status, pvs/lvs, pacman -Q, systemctl is-enabled, objcopy, bootctl
# status) and never writes, mounts, enables, or formats anything.
#
# Scope = exactly what install.sh builds. Post-boot items (Secure Boot, nftables,
# sysctl, desktop env, apps, yay, TLP) are start.sh/core territory and NOT checked.
#
#   Usage:  sudo ./verify-install.sh
#
# NOTE: deliberate, correct divergences from the literal README are verified as
# the *intended* behavior, not flagged as failures:
#   - LV sizes are dynamic (swap=RAM, root=10%/100G cap, home=rest), not 32G/100G
#   - HOOKS prepends `base` (superset of the README line)
#   - cmdline uses root=UUID=<fs-uuid> instead of root=/dev/vg/root
#   - PRESETS=('default' 'fallback') so the fallback UKIs actually build
#   - sudo via /etc/sudoers.d/10-wheel drop-in, never editing /etc/sudoers
#   - fstrim.timer + LUKS discards only on the desktop profile

set -uo pipefail   # NOT -e: we want every check to run even after a failure.

# Re-exec under sudo so privileged reads (luksDump, blkid on raw parts, sudoers.d)
# work. Skip if already root or if sudo is unavailable (checks degrade to WARN).
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then exec sudo -- "$0" "$@"; fi
    printf 'Not running as root and sudo not found; privileged checks will WARN.\n\n' >&2
fi

# ---------------------------------------------------------------------------
C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'
C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'

P=0; F=0; W=0
pass() { printf '  [%sPASS%s] %s\n' "$C_GREEN" "$C_RESET" "$1"; P=$((P+1)); }
fail() { printf '  [%sFAIL%s] %s\n' "$C_RED"   "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf '         %s→%s %s\n' "$C_RED" "$C_RESET" "$2"; F=$((F+1)); }
warn() { printf '  [%sWARN%s] %s\n' "$C_YELLOW" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf '         %s→%s %s\n' "$C_YELLOW" "$C_RESET" "$2"; W=$((W+1)); }
sect() { printf '\n%s== %s ==%s\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET"; }

# assert "desc" <0|1> ["detail on fail"]  — 0 => PASS, non-0 => FAIL
assert() { if [[ "$2" == "0" ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

# ---------------------------------------------------------------------------
# Auto-detect the layout this system actually booted from.
# ---------------------------------------------------------------------------
REC="/var/log/archsetup-install.log"

EFI_PART="$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)"
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
VG="$(lvs --noheadings -o vg_name,lv_name 2>/dev/null | awk '$2=="root"{print $1; exit}' | tr -d ' ')"
[[ -z "$VG" ]] && VG="vg"
LUKS_PART="$(cryptsetup status cryptlvm 2>/dev/null | awk '/device:/{print $2}')"
DISK="$(lsblk -no PKNAME "$EFI_PART" 2>/dev/null | head -n1)"
[[ -n "$DISK" ]] && DISK="/dev/$DISK"

PROFILE="$(awk -F: '/^profile:/{gsub(/[[:space:]]/,"",$2); print $2}' "$REC" 2>/dev/null || true)"
USER_NAME="$(awk -F: '/^username:/{gsub(/[[:space:]]/,"",$2); print $2}' "$REC" 2>/dev/null || true)"
[[ -z "$USER_NAME" ]] && USER_NAME="$(awk -F: '$3>=1000 && $3<65534 && $1!="nobody"{print $1; exit}' /etc/passwd)"

printf '%sinstall.sh verification — %s%s\n' "$C_BOLD" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET"
printf 'Detected: disk=%s  efi=%s  luks=%s  vg=%s\n' "${DISK:-?}" "${EFI_PART:-?}" "${LUKS_PART:-?}" "$VG"
printf '          profile=%s  user=%s\n' "${PROFILE:-unknown}" "${USER_NAME:-unknown}"

# ---------------------------------------------------------------------------
sect "A. Partitioning, encryption, LVM"

if [[ -n "$EFI_PART" && -b "$EFI_PART" ]]; then
    assert "ESP present and is a block device ($EFI_PART)" 0
    [[ "$(lsblk -no FSTYPE "$EFI_PART" 2>/dev/null)" == "vfat" ]] \
        && pass "ESP is vfat" || fail "ESP is vfat" "got '$(lsblk -no FSTYPE "$EFI_PART")'"
    [[ "$(lsblk -no PARTLABEL "$EFI_PART" 2>/dev/null)" == "EFI" ]] \
        && pass "ESP partition label is 'EFI'" || warn "ESP partition label is 'EFI'" "got '$(lsblk -no PARTLABEL "$EFI_PART")'"
else
    fail "ESP present at /boot/efi" "nothing mounted at /boot/efi"
fi

if [[ -n "$LUKS_PART" && -b "$LUKS_PART" ]]; then
    if cryptsetup luksDump "$LUKS_PART" 2>/dev/null | grep -qiE '^Version:[[:space:]]*2'; then
        pass "LUKS container is LUKS2 ($LUKS_PART)"
    else
        fail "LUKS container is LUKS2" "luksDump did not report Version: 2 (need root?)"
    fi
    [[ "$(lsblk -no PARTLABEL "$LUKS_PART" 2>/dev/null)" == "cryptlvm" ]] \
        && pass "LUKS partition label is 'cryptlvm'" || warn "LUKS partition label is 'cryptlvm'" "got '$(lsblk -no PARTLABEL "$LUKS_PART")'"
else
    fail "LUKS partition detected (cryptlvm mapping open)" "cryptsetup status cryptlvm found no backing device"
fi

# discards flag must match the recorded profile (README: no discards on servers)
if flags="$(cryptsetup status cryptlvm 2>/dev/null | awk '/flags:/{ $1=""; print }')"; then
    if [[ "$PROFILE" == "server" ]]; then
        echo "$flags" | grep -qi discards \
            && fail "server profile: LUKS discards DISABLED" "found 'discards' flag on a server" \
            || pass "server profile: LUKS discards disabled"
    elif [[ "$PROFILE" == "desktop" ]]; then
        echo "$flags" | grep -qi discards \
            && pass "desktop profile: LUKS discards enabled" \
            || fail "desktop profile: LUKS discards enabled" "no 'discards' flag on a desktop"
    else
        warn "LUKS discards flag (profile unknown, informational)" "flags:$flags"
    fi
fi

# PV / VG / LVs
pvs --noheadings -o pv_name 2>/dev/null | grep -q '/dev/mapper/cryptlvm' \
    && pass "physical volume is on /dev/mapper/cryptlvm" || fail "physical volume is on /dev/mapper/cryptlvm"
for lv in root home swap; do
    if lvs --noheadings -o lv_name "$VG" 2>/dev/null | tr -d ' ' | grep -qx "$lv"; then
        pass "logical volume ${VG}/${lv} exists"
    else
        [[ "$lv" == "swap" ]] && warn "logical volume ${VG}/swap exists" "no swap LV (RAM<1GiB or intentional)" \
                              || fail "logical volume ${VG}/${lv} exists"
    fi
done
if lvs --noheadings -o lv_name "$VG" 2>/dev/null | tr -d ' ' | grep -qx swap; then
    swapon --show=NAME --noheadings 2>/dev/null | grep -q "${VG}-swap\|/dev/mapper/${VG}-swap\|/dev/${VG}/swap" \
        && pass "swap is active" || fail "swap is active" "swap LV exists but swapon shows it inactive"
fi

# ---------------------------------------------------------------------------
sect "B. Filesystems & fstab"

[[ "$ROOT_SRC" == "/dev/mapper/${VG}-root" ]] \
    && pass "/ is the LVM root LV (/dev/mapper/${VG}-root)" || fail "/ is /dev/mapper/${VG}-root" "got '$ROOT_SRC'"
[[ "$(findmnt -no FSTYPE / 2>/dev/null)" == "ext4" ]] && pass "/ is ext4" || fail "/ is ext4"
if findmnt /home >/dev/null 2>&1; then
    [[ "$(findmnt -no FSTYPE /home 2>/dev/null)" == "ext4" ]] && pass "/home mounted, ext4" || fail "/home is ext4"
else
    warn "/home is a separate mount" "no separate /home (single-root layout)"
fi
[[ "$(findmnt -no FSTYPE /boot/efi 2>/dev/null)" == "vfat" ]] && pass "/boot/efi is vfat" || fail "/boot/efi is vfat"

if [[ -r /etc/fstab ]]; then
    grep -qE '[[:space:]]/[[:space:]]' /etc/fstab && pass "fstab has a root (/) entry" || fail "fstab has a root (/) entry"
    grep -qE '^UUID=' /etc/fstab && pass "fstab uses UUIDs (genfstab -U)" || warn "fstab uses UUIDs"
    grep -qE '[[:space:]]vfat[[:space:]].*fmask=0137,dmask=0027' /etc/fstab \
        && pass "ESP fstab hardening fmask=0137,dmask=0027" || fail "ESP fstab hardening (fmask=0137,dmask=0027)"
else
    fail "/etc/fstab readable"
fi

# ---------------------------------------------------------------------------
sect "C. Base packages"

for p in base linux linux-firmware linux-lts lvm2 vim sudo git networkmanager \
         efibootmgr ntfs-3g binutils systemd-ukify; do
    pacman -Qq "$p" >/dev/null 2>&1 && pass "package $p" || fail "package $p installed"
done
vendor="$(awk -F': ' '/vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
case "$vendor" in
    GenuineIntel) want=intel-ucode ;;
    AuthenticAMD) want=amd-ucode ;;
    *) want="" ;;
esac
if [[ -n "$want" ]]; then
    pacman -Qq "$want" >/dev/null 2>&1 && pass "microcode $want (matches $vendor)" \
        || fail "microcode $want installed" "CPU is $vendor but $want is missing"
else
    warn "microcode package" "unknown CPU vendor '$vendor' — none expected"
fi

# ---------------------------------------------------------------------------
sect "D. Localization & identity"

tgt="$(readlink /etc/localtime 2>/dev/null)"
[[ "$tgt" == /usr/share/zoneinfo/* ]] && pass "timezone set ($tgt)" || fail "/etc/localtime -> zoneinfo" "got '$tgt'"

lang="$(awk -F= '/^LANG=/{print $2}' /etc/locale.conf 2>/dev/null)"
if [[ -n "$lang" ]]; then
    pass "/etc/locale.conf LANG=$lang"
    locale -a 2>/dev/null | grep -qiE "^${lang//./\\.}$|^${lang%%.*}\.utf8$" \
        && pass "locale $lang generated (locale -a)" || fail "locale $lang generated" "run locale -a to inspect"
    grep -qE "^[[:space:]]*${lang//./\\.}([[:space:]]|$)" /etc/locale.gen \
        && pass "locale.gen entry for $lang uncommented" || warn "locale.gen entry uncommented"
else
    fail "/etc/locale.conf sets LANG"
fi

if [[ -r /etc/vconsole.conf ]]; then
    grep -qE '^KEYMAP=..*'          /etc/vconsole.conf && pass "vconsole KEYMAP set"            || fail "vconsole KEYMAP set"
    grep -qx 'FONT=Lat2-Terminus16' /etc/vconsole.conf && pass "vconsole FONT=Lat2-Terminus16"  || fail "vconsole FONT=Lat2-Terminus16"
    grep -qx 'FONT_MAP=8859-1'      /etc/vconsole.conf && pass "vconsole FONT_MAP=8859-1"       || fail "vconsole FONT_MAP=8859-1"
else
    fail "/etc/vconsole.conf present"
fi

host="$(cat /etc/hostname 2>/dev/null)"
[[ -n "$host" ]] && pass "/etc/hostname = $host" || fail "/etc/hostname non-empty"
if [[ -n "$host" ]]; then
    grep -qE "^127\.0\.1\.1[[:space:]]+${host}\.localdomain[[:space:]]+${host}\b" /etc/hosts \
        && pass "/etc/hosts has 127.0.1.1 $host.localdomain $host" || fail "/etc/hosts 127.0.1.1 line for $host"
fi
grep -qE '^127\.0\.0\.1[[:space:]]+localhost' /etc/hosts && pass "/etc/hosts localhost line" || fail "/etc/hosts localhost line"

# ---------------------------------------------------------------------------
sect "E. User & sudo"

if [[ -n "$USER_NAME" ]] && id "$USER_NAME" >/dev/null 2>&1; then
    pass "user '$USER_NAME' exists"
    id -nG "$USER_NAME" 2>/dev/null | tr ' ' '\n' | grep -qx wheel \
        && pass "'$USER_NAME' is in group wheel" || fail "'$USER_NAME' in wheel"
    [[ -d "/home/$USER_NAME" ]] && pass "home dir /home/$USER_NAME exists" || fail "home dir /home/$USER_NAME"
else
    fail "target user exists" "could not resolve a non-root user"
fi

DROPIN=/etc/sudoers.d/10-wheel
if [[ -f "$DROPIN" ]]; then
    pass "sudoers drop-in $DROPIN exists"
    [[ "$(stat -c '%a' "$DROPIN" 2>/dev/null)" == "440" ]] && pass "drop-in mode 440" || fail "drop-in mode 440" "got $(stat -c '%a' "$DROPIN" 2>/dev/null)"
    grep -qE '^%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL' "$DROPIN" \
        && pass "drop-in grants %wheel ALL=(ALL:ALL) ALL" || fail "drop-in %wheel policy line"
    if command -v visudo >/dev/null 2>&1; then
        visudo -cf "$DROPIN" >/dev/null 2>&1 && pass "visudo -c validates the drop-in" || fail "visudo -c validates the drop-in"
    fi
else
    fail "sudoers drop-in $DROPIN exists" "install.sh should have created it"
fi
grep -qE '^[[:space:]]*@?includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers 2>/dev/null \
    && pass "/etc/sudoers includes /etc/sudoers.d" || fail "/etc/sudoers @includedir /etc/sudoers.d"
if [[ -n "$USER_NAME" ]] && command -v sudo >/dev/null 2>&1; then
    sudo -l -U "$USER_NAME" 2>/dev/null | grep -qE '\(ALL[^)]*\)[[:space:]]+ALL' \
        && pass "sudo -l confirms '$USER_NAME' resolves to admin policy" || fail "sudo -l admin policy for '$USER_NAME'"
fi

# ---------------------------------------------------------------------------
sect "F. Services"

systemctl is-enabled NetworkManager >/dev/null 2>&1 && pass "NetworkManager enabled" || fail "NetworkManager enabled"
case "$PROFILE" in
    server)  systemctl is-enabled fstrim.timer >/dev/null 2>&1 \
                 && fail "server: fstrim.timer NOT enabled" "enabled on a server profile" \
                 || pass "server: fstrim.timer disabled" ;;
    desktop) systemctl is-enabled fstrim.timer >/dev/null 2>&1 \
                 && pass "desktop: fstrim.timer enabled" || fail "desktop: fstrim.timer enabled" ;;
    *)       systemctl is-enabled fstrim.timer >/dev/null 2>&1 \
                 && warn "fstrim.timer enabled (profile unknown)" || warn "fstrim.timer disabled (profile unknown)" ;;
esac
if [[ -e /usr/lib/systemd/system/systemd-boot-update.service ]]; then
    systemctl is-enabled systemd-boot-update.service >/dev/null 2>&1 \
        && pass "systemd-boot-update.service enabled" || warn "systemd-boot-update.service enabled"
fi

# ---------------------------------------------------------------------------
sect "G. Boot chain (mkinitcpio UKI + systemd-boot)"

HOOKS_RE='^HOOKS=\(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck\)'
grep -qE "$HOOKS_RE" /etc/mkinitcpio.conf 2>/dev/null \
    && pass "HOOKS line matches expected order (base…sd-encrypt lvm2 filesystems fsck)" \
    || fail "HOOKS line" "got: $(grep '^HOOKS=' /etc/mkinitcpio.conf 2>/dev/null)"

CMDLINE_FILE=/etc/kernel/cmdline
cml="$(cat "$CMDLINE_FILE" 2>/dev/null)"
luks_uuid="$(grep -oE 'rd\.luks\.name=[0-9a-fA-F-]+' <<<"$cml" | cut -d= -f2)"
root_uuid="$(grep -oE 'root=UUID=[0-9a-fA-F-]+'      <<<"$cml" | cut -d= -f3)"
grep -q '=cryptlvm' <<<"$cml"        && pass "cmdline maps LUKS to cryptlvm (rd.luks.name)" || fail "cmdline rd.luks.name=…=cryptlvm"
grep -q 'root=UUID='  <<<"$cml"      && pass "cmdline uses root=UUID= (robust divergence)"   || fail "cmdline root=UUID="
grep -q 'rootfstype=ext4' <<<"$cml"  && pass "cmdline rootfstype=ext4"                        || fail "cmdline rootfstype=ext4"
grep -q 'bgrt_disable' <<<"$cml"     && pass "cmdline has 'quiet bgrt_disable'"               || warn "cmdline quiet bgrt_disable"

if [[ -n "$luks_uuid" && -n "$LUKS_PART" ]]; then
    [[ "$luks_uuid" == "$(blkid -s UUID -o value "$LUKS_PART" 2>/dev/null)" ]] \
        && pass "cmdline LUKS UUID matches $LUKS_PART" || fail "cmdline LUKS UUID matches the LUKS partition"
fi
if [[ -n "$root_uuid" ]]; then
    [[ "$root_uuid" == "$(blkid -s UUID -o value "/dev/${VG}/root" 2>/dev/null)" ]] \
        && pass "cmdline root UUID matches ${VG}/root filesystem" || fail "cmdline root UUID matches the root fs"
fi
grep -q 'rd.luks.name=' /proc/cmdline 2>/dev/null \
    && pass "running kernel booted with the LUKS cmdline (/proc/cmdline)" || warn "/proc/cmdline shows rd.luks.name" "kernel may have booted a different entry"

# Presets: both must build default + fallback
for pf in /etc/mkinitcpio.d/linux.preset /etc/mkinitcpio.d/linux-lts.preset; do
    if [[ -r "$pf" ]]; then
        grep -qE "^PRESETS=\('default' 'fallback'\)" "$pf" \
            && pass "${pf##*/}: PRESETS=('default' 'fallback')" || fail "${pf##*/} builds the fallback" "PRESETS is not ('default' 'fallback')"
    else
        fail "${pf##*/} present"
    fi
done

# The four UKIs must exist, be non-empty, and embed both UUIDs
LINUXDIR=/boot/efi/EFI/Linux
have_objcopy=0; command -v objcopy >/dev/null 2>&1 && have_objcopy=1
for u in arch-linux.efi arch-linux-fallback.efi arch-linux-lts.efi arch-linux-lts-fallback.efi; do
    f="$LINUXDIR/$u"
    if [[ -s "$f" ]]; then
        pass "UKI $u present ($(du -h "$f" 2>/dev/null | cut -f1))"
        if [[ $have_objcopy -eq 1 && -n "$luks_uuid" && -n "$root_uuid" ]]; then
            emb="$(objcopy -O binary --only-section=.cmdline "$f" /dev/stdout 2>/dev/null | tr -d '\0')"
            if [[ -n "$emb" ]]; then
                { [[ "$emb" == *"$luks_uuid"* ]] && [[ "$emb" == *"$root_uuid"* ]]; } \
                    && pass "  └ $u embeds both LUKS+root UUIDs in .cmdline" \
                    || fail "  └ $u embeds both UUIDs" "embedded cmdline missing a UUID"
            else
                warn "  └ $u .cmdline section unreadable" "objcopy returned nothing"
            fi
        fi
    else
        fail "UKI $u present and non-empty" "$f missing or zero bytes"
    fi
done

# systemd-boot loader + loader.conf
[[ -f /boot/efi/EFI/systemd/systemd-bootx64.efi ]] \
    && pass "systemd-boot loader installed on the ESP" || fail "systemd-bootx64.efi on the ESP"
LC=/boot/efi/loader/loader.conf
if [[ -r "$LC" ]]; then
    grep -qE '^default[[:space:]]+arch-linux\.efi' "$LC" && pass "loader.conf default = arch-linux.efi" || fail "loader.conf default arch-linux.efi"
    grep -qE '^timeout[[:space:]]+0'                "$LC" && pass "loader.conf timeout 0"                || warn "loader.conf timeout 0"
    grep -qE '^editor[[:space:]]+no'                "$LC" && pass "loader.conf editor no"                || warn "loader.conf editor no"
else
    fail "loader.conf present on the ESP"
fi
if command -v bootctl >/dev/null 2>&1; then
    bootctl --esp-path=/boot/efi status 2>/dev/null | grep -qi 'systemd-boot' \
        && pass "bootctl reports systemd-boot installed" || warn "bootctl status" "EFI vars may be inaccessible; verify at the loader menu"
fi

# ---------------------------------------------------------------------------
sect "H. Install artifacts"

if [[ -f "$REC" ]]; then
    pass "install record $REC present"
    [[ "$(stat -c '%a' "$REC" 2>/dev/null)" == "600" ]] && pass "install record mode 600" || warn "install record mode 600" "got $(stat -c '%a' "$REC" 2>/dev/null)"
else
    warn "install record $REC present" "install.sh writes this; absent if logging failed"
fi
ls /var/log/archsetup-install-*.log >/dev/null 2>&1 \
    && pass "run transcript copied to /var/log" || warn "run transcript in /var/log" "copied only on a successful finish"

# ---------------------------------------------------------------------------
printf '\n%s================ SUMMARY ================%s\n' "$C_BOLD" "$C_RESET"
printf '  %sPASS %3d%s    %sFAIL %3d%s    %sWARN %3d%s\n' \
    "$C_GREEN" "$P" "$C_RESET" "$C_RED" "$F" "$C_RESET" "$C_YELLOW" "$W" "$C_RESET"
if [[ $F -eq 0 ]]; then
    printf '  %s%sAll checks passed. System matches the install.sh spec.%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    exit 0
else
    printf '  %s%s%d check(s) FAILED — review the FAIL lines above.%s\n' "$C_BOLD" "$C_RED" "$F" "$C_RESET"
    exit 1
fi
