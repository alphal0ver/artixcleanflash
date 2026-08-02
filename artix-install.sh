#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# Configuration
# Tuned specifically for: ThinkPad L540, Intel i5-4210M, HD 4600, Intel 7260
# wifi, 4GB RAM, single 128GB SATA SSD. No portability to other hardware
# intended - this is a private, single-machine install script.
# ==============================================================================
DISK="${DISK:-/dev/sda}"
HOSTNAME="alphalover"
USERNAME="betatester"
TIMEZONE="Asia/Ho_Chi_Minh"

# ==============================================================================
# Helper Functions
# ==============================================================================
log_step() { echo -e "\n\e[1;34m>>> $1\e[0m"; }
log_err()  { echo -e "\e[1;31mERROR:\e[0m $1" >&2; exit 1; }

# ==============================================================================
# Pre-flight Checks
# ==============================================================================
[[ $EUID -ne 0 ]]       && log_err "This script must be run as root."
[[ ! -d /sys/firmware/efi ]] && log_err "System not booted in UEFI mode."
[[ ! -b "$DISK" ]]       && log_err "Disk '$DISK' not found or is not a block device."

# The base ISO is much leaner than the desktop spins - several tools this
# script needs (partitioning, base-install helpers, filesystem formatters)
# aren't guaranteed to be present. Check everything up front in one pass
# instead of discovering each gap one failed command at a time.
declare -A REQUIRED_TOOLS=(
    [sgdisk]=gptfdisk
    [partprobe]=parted
    [basestrap]=artix-install-scripts
    [artix-chroot]=artix-install-scripts
    [fstabgen]=artix-install-scripts
    [mkfs.fat]=dosfstools
    [mkfs.ext4]=e2fsprogs
    [udevadm]=eudev
)
MISSING_PKGS=()
for tool in "${!REQUIRED_TOOLS[@]}"; do
    command -v "$tool" &>/dev/null || MISSING_PKGS+=("${REQUIRED_TOOLS[$tool]}")
done
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    # Dedup (multiple missing tools can map to the same package)
    mapfile -t MISSING_PKGS < <(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u)
    log_step "Missing tools detected - installing: ${MISSING_PKGS[*]}"
    pacman -Sy --noconfirm "${MISSING_PKGS[@]}" || log_err "Failed to install required tools. Check network/mirrors."
fi

log_step "Security Check"
read -rs -p "Enter a password for root and user '$USERNAME': " PASSWORD; echo
read -rs -p "Confirm password: "                                  PASSWORD2; echo
[[ "$PASSWORD" != "$PASSWORD2" ]] && log_err "Passwords do not match."
[[ -z "$PASSWORD" ]]              && log_err "Password cannot be empty."
[[ ${#PASSWORD} -lt 8 ]]          && log_err "Password must be at least 8 characters."

log_step "Safety Check"
echo -e "\e[1;31mWARNING: This will completely WIPE all data on $DISK.\e[0m"
read -p "Are you sure you want to proceed? [y/N]: " confirm
[[ "${confirm,,}" != "y" ]] && log_err "Installation aborted by user."

# ==============================================================================
# Disk Partitioning
# ==============================================================================
log_step "Partitioning $DISK..."

umount -R /mnt 2>/dev/null || true
swapoff -a    2>/dev/null || true

sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System"  "$DISK"
sgdisk -n 2:0:+4G   -t 2:8200 -c 2:"Linux swap"  "$DISK"
sgdisk -n 3:0:0     -t 3:8300 -c 3:"Linux root"   "$DISK"

# Wait for the kernel to re-read the new partition table
partprobe "$DISK"
udevadm settle

# Derive partition names: NVMe/MMC/loop need a 'p' separator (e.g. nvme0n1p1)
# Not relevant on this laptop's SATA SSD (/dev/sda), kept for safety anyway.
if [[ "$DISK" =~ ^/dev/(nvme[0-9]+n[0-9]+|mmcblk[0-9]+|loop[0-9]+)$ ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="${DISK}"
fi

EFI_PART="${PART_PREFIX}1"
SWAP_PART="${PART_PREFIX}2"
ROOT_PART="${PART_PREFIX}3"

# Verify partitions exist before proceeding
for part in "$EFI_PART" "$SWAP_PART" "$ROOT_PART"; do
    [[ ! -b "$part" ]] && log_err "Partition $part not found after partitioning."
done

# ==============================================================================
# Formatting & Mounting
# ==============================================================================
log_step "Formatting partitions..."
mkfs.fat -F32 "$EFI_PART"
mkswap         "$SWAP_PART"
mkfs.ext4 -F  "$ROOT_PART"

log_step "Mounting partitions..."
mount          "$ROOT_PART" /mnt
mount --mkdir  "$EFI_PART"  /mnt/boot/efi
swapon         "$SWAP_PART"

# ==============================================================================
# Base Installation
# ==============================================================================
log_step "Mirrors..."
# reflector doesn't understand Artix's split mirrorlists (mirrorlist-arch,
# mirrorlist-system, mirrorlist-world, mirrorlist-galaxy), so it's skipped.
echo "-> Using the live ISO's default mirrorlists."

log_step "Ensuring up-to-date keyrings..."
# Artix pulls packages from both its own repos and Arch's (via world/galaxy),
# so both keyrings need to be current and populated.
pacman -Syu --noconfirm artix-keyring archlinux-keyring
pacman-key --populate artix archlinux

log_step "Installing minimal base system..."
# Stage 1: just enough to get a bootable, chroot-able system. Everything
# else (networking, XFCE, audio, bootloader, zram) gets installed in
# Stage 2 via a plain `pacman -S` right after artix-chroot - see below.
# This is a checkpoint, not a technical requirement: pacman already runs
# package scriptlets inside a real chroot() whenever --root != "/", so
# basestrap and a later `artix-chroot ... pacman -S` behave identically
# under the hood. Splitting it just makes the install easier to debug
# and easier to tweak the desktop package list without repartitioning.
BASE_PKGS=(
    # Base + kernel. linux-lts for stability on old hardware. intel-ucode
    # hardcoded since this is always an Intel CPU. linux-firmware-intel
    # only (not the full linux-firmware) since it's the only vendor here.
    base linux-lts linux-firmware-intel intel-ucode

    # dinit init system + session/login tracking (elogind) + system bus.
    # Needed at this stage so the chroot itself has an init/dbus present.
    dinit elogind-dinit
    dbus dbus-dinit
)
basestrap /mnt "${BASE_PKGS[@]}"

log_step "Generating fstab..."
fstabgen -U /mnt > /mnt/etc/fstab

log_step "Enabling SSD TRIM (discard) on root + swap..."
# Root is ext4 on a SATA SSD - enable online discard.
sed -i '\#[[:space:]]/[[:space:]].*ext4# s/relatime/relatime,discard/' /mnt/etc/fstab
# Swap partition - also enable discard.
sed -i '/none[[:space:]]\+swap/ s/defaults/defaults,discard/' /mnt/etc/fstab

# Note: zram's config file (/etc/conf.d/zramen) and the swappiness sysctl
# are written *inside* the chroot below, after the zramen package is
# actually installed in Stage 2 - writing them here (before the package
# exists) would just get silently overwritten once pacman installs its
# own default /etc/conf.d/zramen on top.

# ==============================================================================
# System Configuration (Chroot)
# ==============================================================================
log_step "Configuring system (chroot)..."

# Write config values to files inside /mnt rather than passing PASSWORD
# through the environment (env vars are visible in /proc/<pid>/environ)
printf '%s\n' "$HOSTNAME" > /mnt/etc/install_hostname
printf '%s\n' "$USERNAME" > /mnt/etc/install_username
printf '%s\n' "$TIMEZONE" > /mnt/etc/install_timezone

artix-chroot /mnt /bin/bash << 'EOF'
set -euo pipefail

HOSTNAME="$(cat /etc/install_hostname)"
USERNAME="$(cat /etc/install_username)"
TIMEZONE="$(cat /etc/install_timezone)"

echo "-> Stage 2: installing everything beyond the minimal base..."
pacman -Sy --noconfirm

STAGE2_PKGS=(
    # Networking: connman instead of NetworkManager - lighter daemon,
    # handles both the wired I217-V and the Intel 7260 wifi fine via
    # connmanctl. wpa_supplicant backs the wifi authentication.
    connman connman-dinit wpa_supplicant

    # zram (compressed RAM swap) on top of the disk swap partition -
    # zram is used first (default priority is already maximum), disk
    # swap is only the fallback once zram fills up.
    zramen zramen-dinit

    # Bootloader + essentials
    grub efibootmgr sudo nano

    # Graphics: HD 4600 is handled by the generic "modesetting" driver
    # inside mesa - no separate xf86-video-intel needed (it's
    # unmaintained and worse than modesetting on Haswell).
    # xf86-input-libinput drives both the Synaptics touchpad and TrackPoint.
    xorg-server mesa xf86-input-libinput

    # XFCE desktop, no xfce4-goodies (optional bloat). xfce4-power-manager
    # is NOT part of that bloat though - it's a separate package and it's
    # what handles lid-close/battery/brightness keys on this laptop.
    xfce4 xfce4-power-manager

    # ly: TUI login manager, no GTK greeter process needed
    ly ly-dinit

    # Audio: pipewire stack. No system dinit service needed - XFCE
    # launches it via XDG autostart entries when you log in.
    pipewire pipewire-alsa pipewire-pulse wireplumber
)
pacman -S --noconfirm --needed "${STAGE2_PKGS[@]}"

echo "-> Configuring zram (zramen)..."
# zramen reads its settings from this env file. zstd gives a much better
# compression ratio than the lz4 default, which matters a lot on 4GB of
# RAM; the dual-core Haswell CPU has enough headroom for it. Size is 50%
# of RAM (2GB raw, more once compressed) since 4GB is tight. Priority
# 32767 is zramen's own default (max) - it guarantees zram is always
# used before the disk swap partition, matching "use RAM before disk".
# Written here, after zramen is installed, so pacman's own default
# config doesn't clobber it.
cat > /etc/conf.d/zramen << 'ZRAMEN_EOF'
ZRAM_SIZE=50
ZRAM_COMP_ALGORITHM=zstd
ZRAM_PRIORITY=32767
ZRAMEN_SWAPON_DISCARD=both
ZRAMEN_EOF

echo "-> Tuning swappiness for zram..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-zram.conf << 'SYSCTL_EOF'
# Higher swappiness makes sense when the primary swap target is
# fast zram rather than disk. Adjust down if XFCE feels less snappy.
vm.swappiness = 130
SYSCTL_EOF

echo "-> Setting timezone..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

echo "-> Configuring locale..."
sed -i 's/^#\s*\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "-> Setting hostname..."
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

echo "-> Installing GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

echo "-> Enabling services..."
# dinit's control socket isn't running inside the chroot (no /run tmpfs
# for a live daemon yet), and dinitctl --offline has been unreliable on
# recent live ISOs, so services are enabled the way the workaround does
# it: symlink the service straight into /etc/dinit.d/boot.d/.
mkdir -p /etc/dinit.d/boot.d
enable_svc() {
    local svc="$1"
    if [[ -e "/etc/dinit.d/$svc" ]]; then
        ln -sf "/etc/dinit.d/$svc" /etc/dinit.d/boot.d/
        echo "   enabled: $svc"
    else
        echo "   WARNING: /etc/dinit.d/$svc not found, skipping."
        echo "            Check the real name with: ls /etc/dinit.d/"
    fi
}
# connman's dinit service file may be named "connman" or "connmand"
# depending on package version - try both, whichever exists wins.
enable_svc_try() {
    for name in "$@"; do
        if [[ -e "/etc/dinit.d/$name" ]]; then
            enable_svc "$name"
            return
        fi
    done
    echo "   WARNING: none of [$*] found in /etc/dinit.d/ - skipping."
}

enable_svc dbus
enable_svc elogind
enable_svc_try connman connmand
enable_svc zramen
enable_svc_try ly

echo "-> Creating user '$USERNAME'..."
useradd -m -G wheel -s /bin/bash "$USERNAME"

echo "-> Configuring sudo..."
install -m 440 /dev/null /etc/sudoers.d/wheel
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel

echo "-> Setting up realtime audio scheduling (rtprio) for pipewire..."
# Lightweight alternative to running the rtkit-daemon: grant the audio
# group real-time scheduling + memlock directly via PAM limits. Pipewire
# picks this up automatically without needing an extra system service.
groupadd -f realtime
usermod -aG realtime,audio,video "$USERNAME"
cat > /etc/security/limits.d/99-realtime-audio.conf << 'LIMITS_EOF'
@realtime - rtprio 95
@realtime - memlock unlimited
@realtime - nice -19
LIMITS_EOF
EOF

# Set passwords OUTSIDE the heredoc to avoid exposing them in the chroot env.
# chpasswd reads "user:pass" from stdin — nothing hits the process table.
log_step "Setting passwords..."
printf 'root:%s\n'            "$PASSWORD" | artix-chroot /mnt chpasswd
printf '%s:%s\n' "$USERNAME"  "$PASSWORD" | artix-chroot /mnt chpasswd

# Clean up temp files used to pass config into chroot
rm -f /mnt/etc/install_hostname /mnt/etc/install_username /mnt/etc/install_timezone

# Scrub the password from memory as best bash allows
PASSWORD=""
PASSWORD2=""

log_step "Syncing disks..."
sync

echo -e "\n\e[1;32m==================================\e[0m"
echo -e "\e[1;32m       Install Complete!           \e[0m"
echo -e "\e[1;32m==================================\e[0m"
echo "Next steps:"
echo "  1. umount -R /mnt"
echo "  2. Remove the installation USB"
echo "  3. reboot"
echo ""
echo "After reboot:"
echo "  - ly should give you a TUI login prompt; log in and pick the XFCE session."
echo "  - Wifi: connmanctl enable wifi; connmanctl scan wifi; connmanctl connect <service>"
echo "  - Verify zram:   zramctl        (should show a ~2GB zstd device, priority 32767)"
echo "  - Verify swap order: swapon --show   (zram should be listed above the disk partition)"
echo "  - If a service didn't start, check: dinitctl list"
