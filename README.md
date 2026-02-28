# Arch Install

1. [Introduction](#Introduction)

   - Pre-requisites & Checklist
   - Preparing the USB & Booting the Installer

2. [Disk Partitioning](#Disk-Partitioning)

   - Wiping and Partitioning the Drives
   - Creating Encrypted Volume and LVM Setup
   - Mounting the Partitions

3. [System Bootstrapping](#System-Bootstrapping)

   - Pacman Setup and System Base Installation
   - Basic Configuration (Timezone, Locale, Users)

4. [Unified Kernel Image (UKI) Setup](#Unified-Kernel-Image)

   - [Dracut UKI](#Dracut-UKI)
   - [Mkinitcpio UKI](#Mkinitcpio-UKI)

5. [SecureBoot Configuration](#SecureBoot-Configuration)

   - Enabling SecureBoot in BIOS
   - Signing EFI Binaries with `sbctl`
   - SecureBoot Key Enrollment

6. [Firewall Configuration](#Firewall-Configuration)

   - Installing and Configuring `nftables`
   - Configuring Kernel Network Parameters

7. [Password Manager](#Password-Manager)

   - KeePassXC Installation
   
8. [Desktop Environment](#Desktop-Environment-Setup)

   - [KDE Plasma](#KDE-Plasma)
   - [Arch DWM](#Arch-DWM)

9. [Applications and Packages](#Applications-and-Packages)

    - Essential Applications 
    - Yay AUR Helper Setup
    - System Configuration and Tweaks

10. [Additional Tools and Configurations](#Additional-Tools-and-Configuration)
    - CoreCtrl, MangoHud, and Node.js Setup
    - Github SSH Setup and Global Node Modules

# Introduction

This guide provides a step-by-step installation for a secure, encrypted Arch Linux system running under UEFI with optional Secure Boot support and a choice between KDE Plasma or DWM environments.

**Pre-requisites**

Before you begin, ensure:
- Your system supports **UEFI** and **Secure Boot**.
- You can enroll your own Secure Boot keys.
- You are aware of manufacturer firmware features or potential backdoors.

## Preparing the Installation Media

Download the latest official [Archlinux ISO](https://archlinux.org/download/) and flash it to a USB drive:

    sudo dd if=/path/to/file.iso of=/dev/sdX status=progress
    sync

Reboot and boot the USB through UEFI mode. If Secure Boot is enabled, disable it temporarily in BIOS for installation.

## Connecting to Wi-Fi (Optional)

If on a laptop, start `iwctl`:

    iwctl
    station wlan0 connect SSID
    # Enter password when prompted
    exit

## Disk Partitioning

> [!NOTE]  
> Adjust device paths (/dev/nvme0n1, /dev/sda, etc.) as appropriate for your system. Use `lsblk` to confirm.

**Wiping and Creating the Partition Table**

Wipe existing data and create a new GPT:

```bash
wipefs -fa /dev/nvme0n1
gdisk /dev/nvme0n1
```
**Example Layout:**

| Partition     | Description            | Mount Point   | Size       | Type Code
| ------------- |----------------------  |-------------  |------------|----------
| /dev/nvme0n1p1| EFI System Partition   | /dev/vg/root  | 1024MB (1G)| EF00
| /dev/nvme0n1p2| LUKS2 Encrypted Volume | /             | Remaining  | 8309

Format the EFI partition:

```bash
mkfs.fat -F32 /dev/nvme0n1p1
```

**Creating Encrypted Volume and LVM**

> The `allow discards` & `persistent` tags are not to be used if you are setting up a server,
> also dont enable fstrim.timer

```bash
cryptsetup luksFormat --type luks2 /dev/nvme0n1p2
cryptsetup open --allow-discards --persistent /dev/nvme0n1p2 cryptlvm
```

Create and configure LVM inside the encrypted container:

```bash
pvcreate /dev/mapper/cryptlvm
vgcreate vg /dev/mapper/cryptlvm
lvcreate -L 32G vg -n swap
lvcreate -l 100%FREE vg -n root
mkfs.ext4 /dev/vg/root
```

**Mounting Partitions**

```bash
mount /dev/vg/root /mnt
mkswap /dev/vg/swap
swapon /dev/vg/swap
mkdir -p /mnt/boot/efi
mount /dev/nvme0n1p1 /mnt/boot/efi
```

> [!NOTE]  
> If you have additional storage drives, repeat the process as needed.
> you can use `auto-mount.sh` later, make sure to use `wipefs`, `gdisk` and `mkfs`
> if the drive has data dont use neither wipefs nor gdisk

    mkfs.ext4 -L Storage /dev/nvme1n1p1
    mkdir -p /mnt/storage
    mount /dev/nvme1n1p1 /mnt/storage

Editing /etc/fstab later to assign uuid's (use `blkid /mnt/storage` to get the uuid)

```
UUID=YOUR_UUID   /mnt/storage    ntfs-3g or ext4       defaults,noatime 0 2

```

```
blkid -s UUID -o value /dev/nvme0n1p1 >> /etc/fstab
```

load the `/etc/fstab`:

```
mount -a
```

> Note: if you have an sda make sure to install `ntfs-3g`
> If later after booting into the system you cant write to the drive unless with sudo:

```
sudo chown -R $USER:$USER /mnt/storage # you can use `whoami` to check your system name
```

## System Bootstrapping

**Pacman Key Setup**

Initialize and populate keys:

```bash
pacman-key --init
pacman-key --populate
```

**Base System Installation**

Install essential packages:

> [!IMPORTANT]  
> UCODE package depends on your cpu whether its amd or intel 

> Choose this if you are going with Dracut UKI

```bash
pacstrap /mnt base linux linux-firmware linux-lts amd-ucode sudo vim nano konsole lvm2 dracut sbsigntools iwd git ntfs-3g efibootmgr binutils networkmanager pacman
```

> Choose this if you are going with mkinitcpio UKI

```bash
pacstrap /mnt base linux linux-firmware linux-lts amd-ucode sudo vim lvm2 sbsigntools git ntfs-3g efibootmgr binutils networkmanager pacman
```

Generate `fstab`:

```bash
genfstab -U /mnt >> /mnt/etc/fstab
```

Edit `fstab`:

```bash
vim /mnt/etc/fstab 

# Change fmask(0137) and dmask(0027) value RWX based on this table
```

**Building Blocks:(The 4-2-1 Rule)**
> Every permission digit is just the sum of these three numbers:

| Value         | Permision              | Symbol   
| ------------- |----------------------  |-------------  
| 4             | Read                   | `r`   
| 2             | Write                  | `w`   
| 1             | Execute                | `x`   

**Permissions Reference Table** 

| Permision        | Octal Value (chmod)  | fmask/dmask Value | Symbol       
| ---------------- |----------------------|-------------------|-----------
| Full Access      | 7 (4+2+1)            | 0                 | `rwx`
| Read & Write     | 6 (4+2)              | 1                 | `rw-`  
| Read & Execute   | 5 (4+1)              | 2                 | `r-x`  
| Read Only        | 4 (4)                | 3                 | `r--`  
| Write & Execute  | 3 (2+1)              | 4                 | `-wx`  
| Write Only       | 2 (2)                | 5                 | `-w-`  
| Execute Only     | 1 (1)                | 6                 | `--x`  
| No Access        | 0                    | 7                 | `---`  

**Permision Order**
- First Digit: USER (Owner)
- Second Digit: The Group
- Third Digit: Other

**System Configuration**
  
```bash
arch-chroot /mnt
passwd # root password
```

Set timezone and locale:

```bash
ln -sf /usr/share/zoneinfo/<Region>/<city> /etc/localtime
hwclock --systohc
vim /etc/locale.gen # uncomment locales you want
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf

```

Keyboard layout and hostname:

```bash
vim /etc/vconsole.conf
    	KEYMAP=us
    	FONT=Lat2-Terminus16
    	FONT_MAP=8859-1
echo "myhostname" > /etc/hostname
```

Host File Setup:

```bash
vim /etc/hosts
   127.0.0.1   localhost
   ::1         localhost
   127.0.1.1   hostname.localdomain   hostname 
```

Create user and configure sudo:

```bash
useradd -m username
passwd username
visudo
    	%wheel	ALL=(ALL) ALL # Uncomment this line
usermod -aG wheel username
```

Enable essential services:

```bash
systemctl enable NetworkManager fstrim.timer
```

## Unified Kernel Image

> [!IMPORTANT]  
> Choose only one to create the UKI

### Dracut UKI

> Integrate UKI builds with dracut and pacman hooks for auto-regeneration on kernel updates.

**Dracut Configuration**

Configuring Dracut to hook into pacman:

Dracut Install:

```bash
vim /usr/local/bin/dracut-install.sh

    	#!/usr/bin/env bash

    	mkdir -p /boot/efi/EFI/Linux

    	while read -r line; do
    		if [[ "$line" == 'usr/lib/modules/'+([^/])'/pkgbase' ]]; then
    			kver="${line#'usr/lib/modules/'}"
    			kver="${kver%'/pkgbase'}"

    			dracut --force --uefi --kver "$kver" /boot/efi/EFI/Linux/bootx64.efi
    		fi
    	done
```

Dracut Remove:

```bash
vim /usr/local/bin/dracut-remove.sh

    	#!/usr/bin/env bash
     	rm -f /boot/efi/EFI/Linux/bootx64.efi
chmod +x /usr/local/bin/dracut-*
```

**Pacman Hook Configuration**

```bash
mkdir /etc/pacman.d/hooks
```

Dracut Install Hook: 

```bash
 vim /etc/pacman.d/hooks/90-dracut-install.hook

    	[Trigger]
    	Type = Path
    	Operation = Install
    	Operation = Upgrade
    	Target = usr/lib/modules/*/pkgbase

    	[Action]
    	Description = Updating linux EFI image
    	When = PostTransaction
    	Exec = /usr/local/bin/dracut-install.sh
    	Depends = dracut
    	NeedsTargets
```

Dracut Remove Hook:

```bash
vim /etc/pacman.d/hooks/60-dracut-remove.hook

    	[Trigger]
    	Type = Path
    	Operation = Remove
    	Target = usr/lib/modules/*/pkgbase

    	[Action]
    	Description = Removing linux EFI image
    	When = PreTransaction
    	Exec = /usr/local/bin/dracut-remove.sh
    	NeedsTargets
```

**Kernel Argument Configuration**

```bash
blkid -s UUID -o value /dev/nvme0n1p2 >> /etc/dracut.conf.d/cmdline.conf
vim /etc/dracut.conf.d/cmdline.conf
    	kernel_cmdline="rd.luks.uuid=luks-YOUR_UUID rd.lvm.lv=vg/root root=/dev/mapper/vg-root rootfstype=ext4 rootflags=rw,relatime"
```

Dracut flags: 

```bash
vim /etc/dracut.conf.d/flags.conf
    	compress="zstd"
    	hostonly="no"
```

**Generate Linux Image**

```bash
pacman -S linux
```

> [!NOTE]  
> You should have `bootx64.efi` within your `/efi/EFI/Linux/`,
> you can check for bootx64.efi to make sure its setup correctly `ls -alh /boot/efi/EFI/Linux`

**UEFI Boot Entry**

```bash
efibootmgr --create --disk /dev/nvme0n1 --part 1 --label "Arch Linux" --loader 'EFI\Linux\bootx64.efi' --unicode
```
Check and reorder entries as needed:

```bash
efibootmgr
efibootmgr -b INDEX -B # removes previous uefi arch boot entries 
```

reboot and login to your system.

### Mkinitcpio UKI

**Hooks**

```bash
vim /etc/mkinitcpio.conf
   HOOKS=(systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)
```

**systemd boot configuration**

```bash
bootctl install

# set timeout to 4 if you need a bootmenu 

vim /boot/efi/loader/loader.conf
    default         arch-linux.efi
    timeout         0
    console-mode    auto
    editor          no
```

**Kernel Configuration**

```bash
blkid -s UUID -o value /dev/nvme0n1p2 >> /etc/kernel/cmdline

rd.luks.name=YOUR_UUID=cryptlvm root=/dev/vg/root rootfstype=ext4 rw quiet bgrt_disable 
```

Edit linux preset:

```bash
vim /etc/mkinitcpio.d/linux.preset 
   # uncomment
      ALL_config="/etc/mkinitcpio.conf"
      ALL_kver="/boot/vmlinuz-linux"
      PRESETS=('default')
      default_uki="/boot/efi/EFI/Linux/arch-linux.efi"
      default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
      fallback_uki="/boot/efi/EFI/Linux/arch-linux-fallback.efi"
      fallback_options="-S autodetect"
```
```bash
vim /etc/mkinitcpio.d/linux-lts.preset
   # uncomment
      ALL_config="/etc/mkinitcpio.conf"
      ALL_kver="/boot/vmlinuz-linux-lts"
      PRESETS=('default')
      default_uki="/boot/efi/EFI/Linux/arch-linux-lts.efi"
      default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
      fallback_uki="/boot/efi/EFI/Linux/arch-linux-lts-fallback.efi"
      fallback_options="-S autodetect"
```

**Generate UKI**

```bash
mkinitcpio -P

systemctl enable systemd-boot-update.service
```

**Exit chroot**

```bash
umount -R /mnt

reboot
```

## SecureBoot Configuration

Enable Setup Mode in BIOS and erase old keys. Use sbctl to sign binaries.

```bash
pacman -S sbctl
```
Ensure Secure Boot is in Setup Mode:

```bash
sbctl status
      Installed:      ✘ Sbctl is not installed
      Setup Mode:     ✘ Enabled
      Secure Boot:    ✘ Disabled
```

```bash
sbctl create-keys
# Dracut
sbctl sign -s /boot/efi/EFI/Linux/bootx64.efi

# mkinitcpio
sbctl sign -s /boot/efi/EFI/Linux/arch-linux.efi
sbctl sign -s /boot/efi/EFI/Linux/arch-linux-lts.efi
```

> [!NOTE]  
> make sure db.key and db.pem are available `ls /var/lib/sbctl/keys/db`, 
> Not needed for mkinitcpio UKI

**Dracut Secure Boot Configuration:** 

```bash
vim /etc/dracut.conf.d/secureboot.conf
    	uefi_secureboot_cert="/var/lib/sbctl/keys/db/db.pem"
    	uefi_secureboot_key="/var/lib/sbctl/keys/db/db.key"
```

> [!IMPORTANT]  
> Fix needed for sbctl's pacman hook. Creating the following file will overshadow the real one,
> Not needed if you are using mkinitcpio UKI

```bash
 vim /etc/pacman.d/hooks/zz-sbctl.hook
    	[Trigger]
    	Type = Path
    	Operation = Install
    	Operation = Upgrade
    	Operation = Remove
    	Target = boot/*
    	Target = efi/*
    	Target = usr/lib/modules/*/vmlinuz
    	Target = usr/lib/initcpio/*
    	Target = usr/lib/**/efi/*.efi*

    	[Action]
    	Description = Signing EFI binaries...
    	When = PostTransaction
    	Exec = /usr/bin/sbctl sign /boot/efi/EFI/Linux/bootx64.efi
```

Enroll previously generated keys:
```bash
sbctl enroll-keys --microsoft
```
> [!IMPORTANT]
> Reboot the system. Enable only UEFI boot and Secure Boot in BIOS and set BIOS password,

ensure secure boot is active:

```bash
sbctl status
      Installed:	✓ sbctl is installed
      Owner GUID:	YOUR_GUID
      Setup Mode:	✓ Disabled
      Secure Boot:	✓ Enabled
```

## Firewall Configuration

Use `nftables` for modern firewall management.

```
pacman -S nftables
```

Edit the `/etc/nftables.conf`. Proposed firewall rules:

- drop all forwarding traffic (we're not a router),
- allow loopback (127.0.0.0)
- allow ICMP for v4 and v6 (you can turn it off, but for v6 it will disable [SLAAC](<https://wiki.archlinux.org/title/IPv6#Stateless_autoconfiguration_(SLAAC)>)),
- allow returning packets for established connections,
- ssh protection
- block all else.

```bash
#!/usr/bin/nft -f

destroy table inet filter
table inet filter {
  chain input {
    type filter hook input priority filter
    policy drop

    ct state invalid drop comment "early drop of invalid connections"
    ct state {established, related} accept comment "allow tracked connections"
    iif lo accept comment "allow from loopback"
    ip protocol icmp accept comment "allow icmp"
    meta l4proto ipv6-icmp accept comment "allow icmp v6"
    meter ssh_conn_limit { ip saddr timeout 30s limit rate 6/minute } counter jump ssh_check
    tcp dport 22 accept comment "allow SSH"
    tcp dport 80 accept comment "allow HTTP"
    tcp dport 443 accept comment "allow HTTPS"
    pkttype host limit rate 5/second counter reject with icmpx type admin-prohibited
    counter
  }

  chain ssh_check {
    tcp dport 22 counter accept comment "SSH passed brute-force check"
  }

  chain forward {
    type filter hook forward priority filter
    policy drop
  }
}
```

Enable the nftables service and list loaded rules for confirmation:

```bash
systemctl enable --now nftables

nft list ruleset
```

## Kernel parameters

Since firewall allows ICMP traffic, it may be a good idea to disable some network options. Edit your `/etc/sysctl.d/90-network.conf`:

```bash
# Do not act as a router
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Disable ICMP redirect
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Do not send ICMP redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
```

Load your new rules with:

```bash
sysctl --system
```

## Password Manager

Install KeePassXC:

```bash
pacman -S keepassxc
```

## Desktop Environment Setup

### KDE Plasma

```bash
sudo pacman -Syu
sudo pacman -S plasma
```

Create login script /kde_plasma.sh:

```bash
vim /kde_plasma.sh

#!/bin/bash
/usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland
```

Make it executable: 

```bash
chmod +x kde_plasma.sh
```

### Arch DWM

```bash
git clone https://git.suckless.org/dwm
git clone https://git.suckless.org/st
sudo pacman -Sy xorg-server xorg-xinit libx11 libxinerama libxft webkit2gtk
```

Compile and install both `st` and `dwm`:

```bash
cd st && sudo make clean install
cd ../dwm && sudo make clean install
```

create `.xinitrc`:

```bash
vim .xinitrc

exec dwm 
```

Edit `.bash_profile` 

```bash
startx
```

# System Automation 

Run the full setup using: 

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gameshler/arch-gameshler/main/start.sh)
```

## Applications and Packages

Install core applications:

```bash
sudo pacman -S firefox libreoffice-fresh vlc curl flatpak fastfetch p7zip unrar tar rsync exfat-utils fuse-exfat flac jdk-openjdk gimp steam vulkan-radeon lib32-vulkan-radeon base-devel kate mangohud lib32-mangohud corectrl openssh dolphin telegram-desktop discord visual-studio-code-bin --needed --noconfirm
```

### AUR Helper yay installation:

```bash
mkdir opt
cd /opt
git clone https://aur.archlinux.org/yay-bin.git
sudo chown -R "$USER": ./yay-bin
cd yay-bin
makepkg --noconfirm -si
```

## Additional Tools and Configuration

### Pacman Customization:

```bash
sudo vim /etc/pacman.conf
```

- Uncomment `Color`, `ParallelDownloads`
- Add: `ILoveCandy` for visual style
 
Update:

```bash
sudo pacman -Sy
```

#### enabling multilib:

uncomment the following lines:

```bash
[multilib]
Include = /etc/pacman.d/mirrorlist
```

Update:

```bash
sudo pacman -Syyu
```

### TLP (optional - Laptop specific)

> Battery Life Optimization

```bash
pacman -S tlp

systemctl enable tlp.service
systemctl mask systemd-rfkill.socket
systemctl mask systemd-rfkill.service
```

### corectrl (optional):

More info: [corectrl Wiki](https://gitlab.com/corectrl/corectrl/-/wikis/Setup)

Enable corectrl at startup:

```
cp /usr/share/applications/org.corectrl.CoreCtrl.desktop ~/.config/autostart/org.corectrl.CoreCtrl.desktop
```

> note: if the command above isnt working you need to make a new file for auto starting:

```
mkdir ~/.config/autostart # then run the above command
```

### mangohud configuration:

```
cp /usr/share/doc/mangohud/MangoHud.conf.example ~/.config/MangoHud/MangoHud.conf

```

> Edit ~/.config/MangoHud/MangoHud.conf to suit your preferences.

### Nodejs

I use nvm to manage the installed versions of Node.js on my machine. This allows me to easily switch between Node.js versions depending on the project I'm working in.

See installation instructions [here](https://github.com/nvm-sh/nvm#installing-and-updating).

OR run this command (make sure v0.40.3 is still the latest)

```
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
```

Now that nvm is installed, you can install a specific version of node.js and use it:

```
nvm install 22
nvm use 22
node --version
```

### Github SSH Setup

- Follow [this guide](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent) to setup an ssh key for github
- Follow [this guide](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account) to add the ssh key to your github account

### Global Modules

There are a few global node modules I use a lot:

> install in your development directory

- license
  - Auto generate open source license files
- gitignore
  - Auto generate `.gitignore` files base on the current project type

```
pnpm install -g license gitignore
```
