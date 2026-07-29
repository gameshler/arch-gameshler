#!/usr/bin/env bash

set -euo pipefail

# auto-mount.sh — prepare and persistently mount a *secondary* drive.
#
# This is for the extra drives in a machine, not the one Arch was installed on.
# Flow: pick a device -> (format + label it, if blank or you choose to) ->
# create a mount point -> write a UUID-based /etc/fstab entry (with `nofail`
# so a missing drive can never wedge boot) -> mount it and verify.

msg() { printf "%b\n" "$*"; }
die() {
    printf "%b\n" "ERROR: $*" >&2
    exit 1
}

# Fail early on a missing tool instead of half-way through a destructive step.
require_tools() {
    local t
    for t in lsblk blkid findmnt mount mkfs.ext4 partprobe; do
        command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found."
    done
}

# Refuse to touch a device that backs the running system: if the device or any
# of its children is mounted at a real path, or is an active swap, it is off
# limits. This is what keeps the tool off the Arch install disk (/, /boot, swap).
assert_not_in_use() {
    local dev="$1" mp

    while read -r mp; do
        [[ "$mp" == /* ]] && die "$dev (or a partition of it) is mounted at '$mp'. Pick another drive."
    done < <(lsblk -nro MOUNTPOINT "$dev" 2>/dev/null)

    local kn
    while read -r kn; do
        [[ -z "$kn" ]] && continue
        if swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "/dev/$kn"; then
            die "/dev/$kn on $dev is an active swap. swapoff it first, or pick another drive."
        fi
    done < <(lsblk -nro KNAME "$dev" 2>/dev/null)
}

# List candidate drives/partitions and read a validated selection into $partition.
select_drive() {
    clear
    msg "Available drives and partitions:"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID | grep -v 'loop'
    printf "\n"
    msg "Enter the drive/partition to set up (e.g., sdb1, nvme1n1p1, or a whole disk sdb):"
    read -r drive_name
    drive_name="${drive_name#/dev/}"           # accept either 'sdb1' or '/dev/sdb1'
    [[ -b "/dev/$drive_name" ]] || die "'/dev/$drive_name' is not a block device."
    partition="/dev/${drive_name}"
    NAME="$drive_name"                          # basename; lsblk -no NAME emits tree glyphs

    assert_not_in_use "$partition"

    # Formatting a whole disk that still holds partitions silently wipes them —
    # surface that so it can't happen by accident.
    if [[ "$(lsblk -dnro TYPE "$partition" 2>/dev/null)" == "disk" ]]; then
        local kids
        kids="$(lsblk -nro NAME "$partition" 2>/dev/null | tail -n +2 | tr '\n' ' ')"
        [[ -n "${kids// /}" ]] && msg "Note: $partition is a whole disk containing partitions: ${kids}"
    fi
}

# Format + label the device, unless it already carries a filesystem the user
# wants to keep. Leaves the device with a fresh fs and $LABEL set.
maybe_format() {
    local existing
    existing="$(lsblk -dnro FSTYPE "$partition" 2>/dev/null || true)"

    if [[ -n "$existing" ]]; then
        msg "$partition already has a '$existing' filesystem."
        read -rp "Reuse it as-is without formatting? [Y/n]: " reply || true
        [[ "${reply,,}" == "n" || "${reply,,}" == "no" ]] || return 0
    else
        msg "$partition has no filesystem — it must be formatted before it can be mounted."
    fi

    # Destructive: everything on $partition will be erased.
    local confirm
    read -rp "This ERASES all data on $partition. Type '$NAME' to confirm: " confirm || true
    [[ "$confirm" == "$NAME" ]] || die "Confirmation did not match. Aborting."

    local fs
    read -rp "Filesystem type [ext4/xfs/btrfs] (default ext4): " fs || true
    fs="${fs:-ext4}"
    case "$fs" in
        ext4|xfs|btrfs) ;;
        *) die "Unsupported filesystem '$fs'." ;;
    esac
    command -v "mkfs.$fs" >/dev/null 2>&1 || die "mkfs.$fs not found (install the $fs tools)."

    local label
    while :; do
        read -rp "Volume label (letters/digits/_/-, max 16): " label || true
        [[ "$label" =~ ^[A-Za-z0-9_-]{1,16}$ ]] && break
        msg "Invalid label. Use 1-16 chars from letters, digits, '_' or '-'."
    done

    msg "Formatting $partition as $fs (label: $label)..."
    case "$fs" in
        ext4)  sudo mkfs.ext4 -q -L "$label" "$partition" ;;
        xfs)   sudo mkfs.xfs -q -f -L "$label" "$partition" ;;
        btrfs) sudo mkfs.btrfs -q -f -L "$label" "$partition" ;;
    esac

    LABEL="$label"
    sudo partprobe "$partition" 2>/dev/null || true
    sudo udevadm settle --timeout=15 2>/dev/null || true
}

# Resolve the UUID and filesystem type used for the fstab entry.
get_uuid_fstype() {
    UUID="$(sudo blkid -s UUID -o value "$partition" 2>/dev/null || true)"
    FSTYPE="$(lsblk -dnro FSTYPE "$partition" 2>/dev/null || true)"
    [[ -n "$UUID" ]]   || die "Could not read a UUID from $partition."
    [[ -n "$FSTYPE" ]] || die "Could not determine the filesystem type of $partition."
}

# Prompt for and fully validate the mount point BEFORE anything destructive runs.
# The /etc/fstab collision check lives here rather than in update_fstab: formatting
# first and only then discovering the path is taken would leave a wiped drive and
# no entry. Nothing here touches the device.
choose_mount_point() {
    read -rp "Enter the mount point path (e.g., /mnt/data): " mount_point || true
    [[ "$mount_point" == /* ]] || die "Mount point must be an absolute path."
    if awk -v mp="$mount_point" '$1 !~ /^#/ && $2 == mp {found=1} END{exit !found}' /etc/fstab 2>/dev/null; then
        die "$mount_point is already a mount point in /etc/fstab. Choose a different path."
    fi
}

# Create the directory. Runs after formatting; purely local and non-destructive.
create_mount_point() {
    if [[ ! -d "$mount_point" ]]; then
        msg "Creating mount point $mount_point..."
        sudo mkdir -p "$mount_point"
    elif [[ -n "$(ls -A "$mount_point" 2>/dev/null)" ]]; then
        msg "Warning: $mount_point already exists and is not empty; mounting will hide its contents."
    fi
}

# Append a UUID-based entry with `nofail` so a missing/failed secondary drive
# cannot block boot. Idempotent: skips if the UUID is already listed. (The mount
# point was checked in choose_mount_point, before the format.)
update_fstab() {
    if grep -qsE "UUID=${UUID}[[:space:]]" /etc/fstab; then
        msg "An /etc/fstab entry for UUID=$UUID already exists — leaving it untouched."
        return 0
    fi
    # NOTE: the mount-point collision check ran in choose_mount_point, before the
    # format. Only the UUID check belongs here — the UUID isn't known until after.

    # xfs/btrfs are not fsck'd at boot -> pass 0; ext-family -> pass 2.
    local pass=2
    [[ "$FSTYPE" == xfs || "$FSTYPE" == btrfs ]] && pass=0

    # Timestamped backup: a fixed .bak is overwritten on the second run, so the
    # "backup" would already contain the first run's edit and lose the original.
    local backup
    backup="/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
    msg "Backing up /etc/fstab to $backup and adding the entry..."
    sudo cp /etc/fstab "$backup"
    printf '# %s -> %s (%s)\nUUID=%s %s %s defaults,nofail 0 %s\n' \
        "/dev/$NAME" "$mount_point" "${LABEL:-no-label}" \
        "$UUID" "$mount_point" "$FSTYPE" "$pass" | sudo tee -a /etc/fstab >/dev/null

    msg "Added to /etc/fstab:"
    msg "  UUID=$UUID $mount_point $FSTYPE defaults,nofail 0 $pass"
}

mount_drive() {
    msg "Mounting $partition at $mount_point..."
    # `|| true`: under `set -e` a failing mount would abort here, so the die()
    # below (and its "the fstab entry was kept" hint) would never be reached.
    # Let it fail, then report through the findmnt check.
    sudo mount "$mount_point" || true
    if findmnt -no TARGET "$mount_point" >/dev/null 2>&1; then
        msg "Drive mounted successfully at $mount_point."
    else
        die "Failed to mount $partition at $mount_point (the /etc/fstab entry was kept for inspection)."
    fi
}

main() {
    UUID="" FSTYPE="" LABEL="" NAME="" partition="" mount_point=""
    require_tools
    select_drive
    choose_mount_point
    maybe_format
    get_uuid_fstype
    create_mount_point
    update_fstab
    mount_drive
}

main
