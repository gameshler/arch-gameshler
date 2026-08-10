# archsetup Technical Specification

> **State anchor.** This document describes the repository at commit `3e0ceae`
> on branch `gameshler/install-sh`, verified 2026-07-26 against a full read of
> every tracked shell script. It is *descriptive*: it records how the code
> behaves today, with file/line citations (paths are relative to the repo root).
> Where a capability that a comparable tool (christitustech/linutil) has is
> deliberately absent here, it is called out in
> [§13 Future compatibility](#13-future-compatibility), not implied to exist.

## 1. Product definition

archsetup is a two-stage, terminal-driven toolkit for building and configuring a
single-user, encrypted Arch Linux workstation.

The product consists of:

- **A base installer** (`install.sh`): run once from a booted Arch live ISO. It
  takes a blank disk to a rebootable, LUKS2-encrypted, LVM-backed Arch system
  booted by a mkinitcpio Unified Kernel Image (UKI) + systemd-boot.
- **A read-only verifier** (`verify-install.sh`): run once on the freshly booted
  target. It audits every install-scope item and prints PASS / FAIL / WARN.
- **A post-install toolkit**: a bootstrap (`start.sh`) that fetches the repo and
  launches a filesystem-tree menu (`core/main.sh`), which runs individual task
  scripts under `core/tabs/` for firewall, dotfiles, desktop environment,
  applications, and system maintenance.
- **A shared shell library** (`core/tabs/common-script.sh`) that centralizes
  package-manager, AUR-helper, Flatpak, and init-system behavior for the task
  scripts.
- **Dotfiles** (`files/`) shipped to the user's home by two task scripts.

**Scope of "Arch."** archsetup targets Arch Linux specifically. Unlike a
distro-agnostic tool, it hardcodes `pacman` and an AUR helper (`yay`). The shared
library detects and *asserts* pacman (`core/tabs/common-script.sh:145`); on any
other distribution it exits. Portability across package managers is a non-goal
([§3](#3-non-goals)).

## 2. Goals

archsetup must:

1. Automate the full manual install documented in `README.md` — partition,
   LUKS2, LVM, pacstrap, chroot config, UKI + systemd-boot — prompting only for
   the human-specific inputs (disk, hostname, user, passwords, timezone, locale,
   keymap, profile).
2. Never write to disk until the operator passes an explicit, identity-checked
   wipe confirmation.
3. Handle secrets (passwords, LUKS passphrase) only over stdin pipes — never in
   environment, argv, disk, or logs.
4. Produce an installed system whose boot chain is *verified* at install time
   (UUIDs embedded in the UKI, sudoers parse-tested, loader entry present) rather
   than assumed.
5. Provide an independent read-only audit (`verify-install.sh`) that re-checks
   the same install-scope invariants after first boot.
6. Present post-install tasks through one discoverable menu, where adding a task
   is a matter of adding a script file, not editing the menu program.
7. Reuse shared package/AUR/service behavior in `common-script.sh` instead of
   duplicating it across task scripts.
8. Keep each task script idempotent where practical — safe to re-run.

## 3. Non-goals

archsetup is not:

- **A multi-distribution tool.** It is Arch + pacman + `yay` only. There is no
  package-manager abstraction beyond a pacman assertion.
- **A metadata-driven catalog.** There is no TOML schema, no preconditions
  engine, no task-flag system, and no multi-select execution. The "catalog" is
  the directory tree under `core/tabs/`, navigated by name.
- **A Secure Boot / sbctl automation.** `install.sh` explicitly leaves Secure
  Boot manual (`install.sh:13`); the README covers it by hand.
- **A configuration-management daemon.** Everything runs once, interactively,
  and exits.
- **A backup mechanism.** The installer erases the chosen disk; the operator is
  responsible for backups.
- **A guarantee that every task script runs on every machine.** Task scripts
  validate their own preconditions at runtime (e.g. GPU detection in
  `core/tabs/system/gpu-driver.sh`) and exit on unsupported states.

## 4. System architecture

### 4.1 Repository layout

| Path | Responsibility |
| --- | --- |
| `install.sh` | Stage-1 base installer (ISO-run). 1047 lines, `bash`, `set -euo pipefail`. |
| `verify-install.sh` | Stage-1 read-only audit (target-run). 383 lines, `bash`, `set -uo pipefail` (no `-e`, so every check runs). |
| `start.sh` | Stage-2 bootstrap: downloads the repo tarball, launches the menu. |
| `core/main.sh` | Stage-2 menu: recursive filesystem browser + script runner. |
| `core/tabs/` | 29 task scripts in four category directories, plus the shared library. |
| `core/tabs/common-script.sh` | Shared library: package manager, AUR helper, Flatpak, init system. |
| `files/` | Shipped dotfiles: `.bashrc`, `.gitconfig`, `.gitignore`, `starship.toml`. |
| `README.md` | The manual install guide the automation replaces, plus run commands. |
| `LICENSE` | Project license. |

`.context/` holds working scratch (a todos file and pasted-text attachments) and
is **not** part of the product surface.

### 4.2 The two stages

```
Stage 1 (live ISO, root)                Stage 2 (installed system, user)
────────────────────────                ────────────────────────────────
install.sh   ── reboot ──▶  first boot  ──▶  start.sh ──▶ core/main.sh
                                                              │
verify-install.sh (optional audit)                           ├── core/tabs/security/*
                                                              ├── core/tabs/system/*
                                                              ├── core/tabs/apps/**/*
                                                              └── core/tabs/utils/*
```

Stage 1 and Stage 2 share no runtime state. Stage 2 discovers what Stage 1 built
only through the installed system itself (and, for the verifier, the non-secret
install record at `/var/log/archsetup-install.log`, `install.sh:962`).

### 4.3 Stage-1 install flow (`install.sh:1118` `main`)

Ordered phases, each gated so a failure aborts before the next:

1. `start_logging` — tee the whole run to `/var/log/archsetup-install-<ts>.log`,
   ANSI stripped from the file (`install.sh:1092`).
2. `preflight` — assert root + UEFI, assert every destructive-phase tool exists,
   sync the clock (`install.sh:218`).
3. `setup_network` — auto-detect a wired carrier, else fall back to `iwctl` Wi-Fi;
   verify real route + DNS reachability (`install.sh:285`).
4. `gather_input` — the only interactive phase: disk, deterministic layout,
   hostname/username (regex-validated), passwords, timezone/locale/keymap (with
   search helpers), profile, microcode auto-detect (`install.sh:467`).
5. `confirm_wipe` — show disk identity (model+size+serial) and planned layout;
   require typing the bare disk name **and** `YES`; refuse a disk with mounted
   partitions (`install.sh:540`).
6. `partition_disk` — sets `DESTRUCTIVE_STARTED=1`, tears down prior LUKS/LVM on
   the target disk only, writes GPT (ESP + LUKS), formats ESP, LUKS2-formats and
   opens `cryptlvm` (`install.sh:620`).
7. `setup_lvm` — collision-free VG name, create PV/VG/LVs, mkfs, mount `/mnt`,
   and *prove* `/mnt` is the freshly created root LV before continuing
   (`install.sh:661`).
8. `install_base` — rank mirrors (reflector, with rollback on empty result),
   pacstrap the base set, `genfstab -U`, harden the ESP vfat line
   (`fmask=0137,dmask=0027`) (`install.sh:744`).
9. `configure_system` — one `arch-chroot` heredoc: timezone, locale, vconsole,
   hostname/hosts, user, sudoers drop-in (parse-tested via `visudo` + live
   `sudo -l`), services, mkinitcpio HOOKS, kernel cmdline, UKI presets
   (`default` + `fallback`), build + validate UKIs (embed-check both UUIDs),
   install systemd-boot + loader.conf. Passwords set afterward via `chpasswd`
   over stdin (`install.sh:952`).
10. `finish` — write the non-secret install record, copy the transcript into the
    target, scrub secrets from env, unmount, offer reboot (`install.sh:1008`).

On any non-zero exit, `on_err` (`install.sh:51`) prints the transcript path and,
only if `DESTRUCTIVE_STARTED=1`, the teardown recovery commands.

### 4.4 Stage-2 runtime flow (`start.sh` → `core/main.sh`)

1. `start.sh` exports `TEMP_DIR` (a fresh `mktemp -d`) and
   `INSTALL_DIR=$HOME/Downloads/archsetup`, downloads
   `github.com/gameshler/archsetup` (`main` branch) into `TEMP_DIR`, moves it to
   `INSTALL_DIR`, `chmod +x` all `*.sh`, and runs `core/main.sh` (`start.sh:5`).
2. `core/main.sh` exports `FILES`, `TABS_DIR`, `COMMON_SCRIPT`, and
   `SSH_PORT=2351` (`core/main.sh:6`). `TEMP_DIR` and `INSTALL_DIR` are inherited
   from `start.sh`.
3. `choose_directory` lists the current directory (top level shows category
   directories only; deeper levels show subdirectories and `*.sh` files),
   sorted, with an Exit/Back sentinel (`core/main.sh:20`).
4. Selecting a directory descends; selecting a script runs it with `bash "$path"`
   and pauses for Enter (`core/main.sh:70`).
5. On exit, `cleanup` removes `TEMP_DIR` and `INSTALL_DIR` (`core/main.sh:22`).

## 5. Stage-1: base installer (`install.sh`)

### 5.1 Inputs

All input is collected in `gather_input`/`confirm_wipe` before anything
destructive. Defaults mirror the README (`install.sh:84`): EFI 1 GiB, timezone
`Europe/London`, locale `en_GB.UTF-8`, keymap `us` — all overridable.

Validated inputs:

- **Disk** — must be a whole disk or loop device, not a partition
  (`install.sh:482`). Accepts `/dev/vda` or bare `vda`.
- **Hostname** — RFC-style regex, 1–63 chars (`install.sh:498`).
- **Username** — `^[a-z_][a-z0-9_-]{0,31}$` (`install.sh:501`).
- **Passwords** — root, user, LUKS: entered twice, must match, non-empty
  (`install.sh:182`).
- **Timezone / locale / keymap** — resolved against `/usr/share/zoneinfo`,
  `/etc/locale.gen`, and `localectl list-keymaps`, each with a search helper.
- **Profile** — `desktop` or `server`; gates `fstrim.timer` and LUKS discards.

### 5.2 Deterministic disk layout (`configure_layout`, `install.sh:429`)

No layout prompts. Computed from disk + RAM:

| Region | Size |
| --- | --- |
| ESP (FAT32, `/boot/efi`) | 1 GiB |
| swap LV | = total RAM (whole GiB, rounded up); omitted if < 1 GiB |
| root LV (ext4, `/`) | 10% of disk, capped at 100 GiB, floor 1 GiB |
| home LV (ext4, `/home`) | remaining space |

A fit check aborts if the fixed regions leave no room for `/home`
(`install.sh:460`).

### 5.3 Encryption, LVM, boot (invariants)

- **LUKS2** on partition 2, opened as `/dev/mapper/cryptlvm`. Discards
  (`--allow-discards --persistent`) only on the desktop profile
  (`install.sh:648`).
- **LVM**: single PV on `cryptlvm`, VG named `vg` (or `vg0`, `vg1`… if `vg`
  already exists on another disk) (`install.sh:665`).
- **Boot**: mkinitcpio UKI with HOOKS ordering `… sd-encrypt lvm2 filesystems
  fsck`; kernel cmdline references the LUKS container by UUID and root by
  filesystem UUID; `PRESETS=('default' 'fallback')` so both kernels
  (`linux`, `linux-lts`) build a pruned and a recovery image — four UKIs total
  (`install.sh:867`). systemd-boot installed to the ESP, `loader.conf` default
  `arch-linux.efi`, `timeout 3`, `editor no`.

### 5.4 Base package set (`install.sh:93`)

`base linux linux-firmware linux-lts lvm2 vim sudo git networkmanager efibootmgr
ntfs-3g binutils systemd-ukify` plus the detected microcode (`intel-ucode` /
`amd-ucode`, or none).

### 5.5 Install-time validation gates

The installer refuses to finish on a silently broken system. It hard-fails if:
genfstab produced no root entry; ESP hardening didn't apply; locale isn't
enabled; sudoers drop-in fails `visudo -c`, `/etc/sudoers` doesn't include
`sudoers.d`, or `sudo -l` doesn't resolve the user to an all-commands policy; the
HOOKS line didn't set as expected; the cmdline is missing a UUID; any of the four
UKIs is missing/empty; or the systemd-boot loader or its `loader.conf` default is
absent (`install.sh:742`–`install.sh:930`).

### 5.6 Secret handling (`install.sh:652`, `install.sh:952`)

Only non-secret values (`CH_TZ`, `CH_HOST`, UUIDs, …) cross into the chroot
environment. LUKS passphrase is piped to `cryptsetup --key-file -`; root and user
passwords are piped to `chpasswd` over stdin *after* the chroot heredoc, so no
password ever appears in the environment, argv, disk, or the transcript.
`finish` unsets `ROOT_PW USER_PW LUKS_PW` (`install.sh:1015`).

## 6. Stage-1: verifier (`verify-install.sh`)

Run on the booted target. **Strictly read-only** — it inspects state (`findmnt`,
`lsblk`, `blkid`, `cryptsetup luksDump/status`, `pvs`/`lvs`, `pacman -Q`,
`systemctl is-enabled`, `objcopy`, `bootctl status`) and never writes, mounts,
enables, or formats (`verify-install.sh:11`).

- **Self-elevates** via `exec sudo` if not root; degrades privileged checks to
  WARN if sudo is unavailable (`verify-install.sh:33`).
- **Auto-detects** the booted layout (ESP, root source, VG, LUKS backing device,
  disk) and reads profile/username from the install record
  (`verify-install.sh:82`).
- **Section coverage** mirrors install scope exactly: A. partition/LUKS/LVM,
  B. filesystems + fstab hardening, C. base packages + microcode,
  D. localization + identity, E. user + sudo, F. services, G. boot chain (HOOKS,
  cmdline UUID cross-checks, four UKIs with embedded-UUID checks, systemd-boot +
  loader.conf), H. install artifacts.
- **Exit status** is non-zero if any check FAILs (`verify-install.sh:420`).
- **Scope boundary**: post-boot items (Secure Boot, nftables, sysctl, desktop,
  apps, yay, TLP) are explicitly *not* checked (`verify-install.sh:16`).

The header documents the deliberate divergences from the literal README that are
verified as *intended* (dynamic LV sizes, `base`-prefixed HOOKS, `root=UUID=`,
`('default' 'fallback')` presets, sudoers drop-in, profile-gated discards)
(`verify-install.sh:20`).

## 7. Stage-2: catalog and menu

### 7.1 The catalog is the filesystem

There is no manifest. The menu (`core/main.sh` `choose_directory`) enumerates the
live tree under `core/tabs/`:

- **Top level** shows category directories only (`apps/`, `security/`, `system/`,
  `utils/`).
- **Deeper levels** show subdirectories and `*.sh` files, sorted.
- A selected `*.sh` is executed with `bash "$path"`.

Adding a task is therefore: drop an executable `*.sh` into the appropriate
category directory. No registration step exists.

### 7.2 Category directories (29 task scripts)

| Category | Scripts |
| --- | --- |
| `apps/browsers/` | brave, brave-origin, chrome, firefox, librewolf, thorium |
| `apps/communication-apps/` | discord, slack, telegram, zoom |
| `apps/developer-tools/` | cursor, githubdesktop, neovim, vscode |
| `apps/dwm/` | bash-setup, dwm-setup, ghostty-setup, rofi-setup |
| `security/` | nftables, ssh, ufw |
| `system/` | dev-setup, gpu-driver, setup, system-cleanup, system-update, virtualisation |
| `utils/` | auto-mount, docker-setup |

Notable task scripts beyond simple installers:

- `system/setup.sh` — the heavy first-run configurator: `pacman.conf` tweaks
  (Color, ParallelDownloads, multilib, ILoveCandy), a 54-country reflector
  mirror menu, a broad package set, and MangoHud config (`system/setup.sh`).
- `security/nftables.sh` / `security/ufw.sh` — mutually exclusive firewall
  choices; both also write `/etc/sysctl.d/90-network.conf` hardening.
- `utils/auto-mount.sh` — self-contained secondary-drive formatter/mounter (see
  [§8.2](#82-sourcing-the-shared-library)).
- `apps/dwm/*` — clone/configure the author's dwm rice, pulling most configs from
  `github.com/gameshler/dwm` over `curl`, not from `files/`.

### 7.3 Menu constraints and known limitations

- Selection is by list index, re-read from the tree on each render — a script's
  position can shift if files are added.
- `bash "$path"` runs every task script under `bash` regardless of its shebang
  (`core/main.sh:70`). A `#!/bin/sh -e` script therefore does **not** get its
  `-e` applied when launched from the menu (the shebang is bypassed). Scripts
  must not depend on their own shebang flags when run this way.
- There is no search, no multi-select, no per-task confirmation layer, and no
  preview — confirmation and safety live inside each script.

## 8. Task-script contract

### 8.1 Interpreter (mixed, by design)

The census at `3e0ceae`: 23 task scripts are `#!/bin/sh -e` (POSIX), 10 files are
`#!/usr/bin/env bash` + `set -euo pipefail`, and 1 (`apps/dwm/dwm-setup.sh`) is
bare `#!/bin/sh`.

Convention:

- Prefer `#!/bin/sh -e` + POSIX shell for straightforward install-and-configure
  tasks (the majority: browsers, most `security/`, `system/`, `utils/` scripts).
- Use `#!/usr/bin/env bash` + `set -euo pipefail` only when Bash features are
  required (arrays, `[[ ]]`, `local`), e.g. `system/setup.sh`,
  `system/dev-setup.sh`, `apps/dwm/bash-setup.sh`, `utils/auto-mount.sh`, plus
  the Stage-1 scripts and `core/main.sh`.

Because the menu launches scripts with `bash` (`core/main.sh:70`), a task script
must be correct both when run directly (honoring its shebang) and when run under
bash from the menu.

### 8.2 Sourcing the shared library

All 29 task scripts source the shared library with `. "$COMMON_SCRIPT"` (e.g.
`core/tabs/security/nftables.sh:3`) **except one**: `utils/auto-mount.sh`, which
is fully self-contained (its own helpers, no pacman dependency). `$COMMON_SCRIPT`
is exported by `core/main.sh:8`.

**Sourcing has side effects.** `common-script.sh` runs
`check_package_manager "pacman"` and `check_init_manager 'systemctl rc-service
sv'` at source time (`core/tabs/common-script.sh:145`). Sourcing therefore sets
`PACKAGER` and `INIT_MANAGER`, prints a "Using … " line, and **exits the script**
if pacman is absent. A task script that sources the library inherits this
pacman-only gate for free. (This is also why `auto-mount.sh`, which must run on
any drive layout, does not source it.)

### 8.3 Environment contract

Variables a task script may rely on, and where each is set. They are only
guaranteed when the script is launched through the Stage-2 chain
(`start.sh` → `core/main.sh` → `bash "$path"`), not when run standalone —
`neovim.sh:6` explicitly guards against an unset `TEMP_DIR`.

| Variable | Set by | Value / use |
| --- | --- | --- |
| `TEMP_DIR` | `start.sh:6` | Scratch dir. Used by `neovim.sh`, `bash-setup.sh`, `dwm-setup.sh` for clones/downloads. |
| `INSTALL_DIR` | `start.sh:7` | `$HOME/Downloads/archsetup`; repo root at runtime. |
| `FILES` | `core/main.sh:6` | `$INSTALL_DIR/files` (dotfile source). |
| `TABS_DIR` | `core/main.sh:7` | `$INSTALL_DIR/core/tabs`. |
| `COMMON_SCRIPT` | `core/main.sh:8` | `$TABS_DIR/common-script.sh`. |
| `SSH_PORT` | `core/main.sh:9` | `2351`; consumed by `security/ssh.sh`, `security/nftables.sh`, `security/ufw.sh`. |
| `PACKAGER`, `INIT_MANAGER`, `HELPER` | set on sourcing `common-script.sh` | package manager, init tool, AUR helper. |

### 8.4 Privilege

Scripts run unprivileged and apply `sudo` per privileged command
(`sudo systemctl enable …`, `sudo make install`, `sudo tee …`), never by running
the whole script as root. Some scripts wrap a batch of root work in
`sudo bash -c '…'` (e.g. `security/nftables.sh:36`). There is no configurable
escalation tool; `sudo` is hardcoded.

### 8.5 Idempotency

The prevailing pattern guards installs behind a capability check so re-running is
safe: `if ! command_exists X; then install_packages X; else echo "already
installed"; fi` (e.g. `security/ssh.sh`, `apps/browsers/firefox.sh`,
`system/gpu-driver.sh`, `utils/docker-setup.sh`). `install_packages` uses
`pacman -S --needed --noconfirm`. Config-writing scripts lean on idempotent
`sed`/`grep -q` edits (e.g. `system/setup.sh`, `security/ssh.sh`) or explicit
`.bak`/`-bak` backups before overwrite (`ghostty-setup.sh`, `rofi-setup.sh`,
`auto-mount.sh`). New scripts should follow these patterns.

### 8.6 Runtime validation

Preconditions are checked *in the script*, not by metadata. Examples:
`system/gpu-driver.sh` detects the GPU vendor via `lspci` and exits on an
unsupported card; `security/nftables.sh` exits if it can't determine the default
route interface; `virtualisation.sh` warns and continues if `/dev/kvm` is absent.
Scripts must stop on unsupported or ambiguous states rather than proceed blindly.

## 9. Shared library (`common-script.sh`)

`core/tabs/common-script.sh` (147 lines, `#!/usr/bin/env bash`) provides:

| Function | Purpose | Called by (examples) |
| --- | --- | --- |
| `command_exists` | True if all named commands are on `PATH`. | nearly every task script |
| `check_package_manager` | Sets `PACKAGER`; exits if none of the candidates exist. Runs with `pacman` at source time. | (auto, on source) |
| `check_aur_helper` | Sets `HELPER` to `yay`/`paru`; bootstraps `yay-bin` from the AUR if neither exists. | `system/system-update.sh:54`; `install_packages --aur` |
| `check_flatpak` | Installs Flatpak and adds the Flathub remote if missing. | `install_packages --flatpak` |
| `install_packages [--official\|--aur\|--flatpak] pkgs…` | Installs via pacman (default), the AUR helper, or Flatpak. | most task scripts |
| `check_init_manager` | Sets `INIT_MANAGER` from `systemctl`/`rc-service`/`sv`. | (auto, on source) |
| `is_service_active` | Init-agnostic service-active check. | `apps/dwm/dwm-setup.sh:109` |

The bottom of the file (`core/tabs/common-script.sh:145`) unconditionally runs
`check_package_manager "pacman"` and `check_init_manager …`, which is why
sourcing it asserts an Arch/pacman host.

## 10. Configuration and dotfiles

`files/` ships four dotfiles, consumed by exactly two task scripts:

- `apps/dwm/bash-setup.sh` — appends `files/.bashrc` and `files/starship.toml`
  into `~/.local/share/bash/`, then symlinks them to `~/.bashrc` and
  `~/.config/starship.toml` (backing up an existing `~/.bashrc` to `.bashrc.bak`)
  (`apps/dwm/bash-setup.sh:14`).
- `system/dev-setup.sh` — copies `files/.gitignore` and `files/.gitconfig` to
  `$HOME` (`system/dev-setup.sh:30`).

Other config-writing scripts (`dwm-setup.sh`, `ghostty-setup.sh`,
`rofi-setup.sh`) fetch their configs from `github.com/gameshler/dwm` over `curl`
rather than from `files/`. There is no configuration file for archsetup itself
and no automation/config interface — every run is interactive.

The one machine-written record is the **install record**
(`/var/log/archsetup-install.log`, mode 600, no secrets, `install.sh:962`),
consumed by the verifier to recover the profile and username.

## 11. Quality requirements

Descriptive of the conventions the code follows today; there is currently **no
CI enforcing them** (see [§13](#13-future-compatibility)).

- **Bash scripts** use `set -euo pipefail` and are expected to pass
  `shellcheck -S warning`. Failing command substitutions under `pipefail` are
  guarded with `|| true` (pervasive in `install.sh`).
- **POSIX `#!/bin/sh -e` scripts** should pass ShellCheck and remain free of
  bashisms.
- **The installer** validates its own output at every destructive step
  ([§5.5](#55-install-time-validation-gates)) — this in-script gating is the
  primary correctness mechanism.
- **The verifier** is the acceptance test for a Stage-1 install: a clean
  `verify-install.sh` run (exit 0, zero FAIL) means the system matches spec.
- **Testing** is done in VMs / loop-backed disks (the installer accepts loop
  devices for exactly this, `install.sh:482`).

## 12. Acceptance criteria for a new task script

A Stage-2 task script is complete when:

1. It lives in the correct category directory under `core/tabs/` and is
   executable.
2. It sources `common-script.sh` when it needs package/AUR/Flatpak/service
   helpers, and uses `install_packages` rather than calling `pacman` directly.
3. Its interpreter matches its needs: `#!/bin/sh -e` unless it requires Bash, in
   which case `#!/usr/bin/env bash` + `set -euo pipefail`.
4. It is idempotent — guarded by capability checks so re-running causes no damage
   or duplication.
5. It validates its own runtime preconditions and exits on unsupported states.
6. It applies `sudo` only to the commands that need it.
7. It embeds no secrets and logs no sensitive input.
8. It passes ShellCheck (and `checkbashisms` for POSIX scripts).
9. It runs correctly both standalone and when launched with `bash` from the menu
   ([§7.3](#73-menu-constraints-and-known-limitations)).

An install-scope change to `install.sh` is complete when `verify-install.sh`
reports zero FAIL against a freshly installed VM, and any deliberate divergence
from the README is reflected in the verifier's intended-divergence list.

## 13. Future compatibility

Capabilities intentionally absent today, listed so the spec doesn't imply them:

- **No CI / automated gate.** ShellCheck and `checkbashisms` are conventions, not
  enforced. A CI job running both across all `*.sh`, plus a VM smoke test of
  `install.sh` → `verify-install.sh`, would make
  [§11](#11-quality-requirements) enforceable.
- **No metadata catalog.** Descriptions, task-effect flags, preconditions, and
  multi-select all live (if at all) inside scripts. A future manifest could
  surface them in the menu without changing the script model.
- **No multi-distribution support.** The pacman/`yay` assertion is load-bearing.
  Portability would require a real package-manager abstraction in
  `common-script.sh`.
- **No Secure Boot automation.** Left manual by design (`install.sh:13`); a
  future `sbctl` phase could extend Stage 1.

Any such extension should preserve the two-stage model and the
filesystem-as-catalog convention rather than hard-code new behavior into
`core/main.sh`.
