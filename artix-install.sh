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
[[ $EUID -ne 0 ]]        && log_err "This script must be run as root."
[[ ! -d /sys/firmware/efi ]] && log_err "System not booted in UEFI mode."
[[ ! -b "$DISK" ]]        && log_err "Disk '$DISK' not found or is not a block device."

log_step "Checking for required tools..."
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
    if command -v "$tool" &>/dev/null; then
        echo "   OK: $tool"
    else
        echo "   MISSING: $tool (from package: ${REQUIRED_TOOLS[$tool]})"
        MISSING_PKGS+=("${REQUIRED_TOOLS[$tool]}")
    fi
done
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    mapfile -t MISSING_PKGS < <(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u)
    log_step "Installing missing packages: ${MISSING_PKGS[*]}"
    pacman -Sy --noconfirm "${MISSING_PKGS[@]}" || log_err "Failed to install required tools. Check network/mirrors."
    log_step "Re-checking after install..."
    for tool in "${!REQUIRED_TOOLS[@]}"; do
        command -v "$tool" &>/dev/null || log_err "$tool still not found after installing ${REQUIRED_TOOLS[$tool]}. Something is wrong - check manually."
    done
    echo "   All required tools now present."
else
    echo "   All required tools already present."
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

partprobe "$DISK"
udevadm settle

if [[ "$DISK" =~ ^/dev/(nvme[0-9]+n[0-9]+|mmcblk[0-9]+|loop[0-9]+)$ ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="${DISK}"
fi

EFI_PART="${PART_PREFIX}1"
SWAP_PART="${PART_PREFIX}2"
ROOT_PART="${PART_PREFIX}3"

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
echo "-> Using the live ISO's default mirrorlists."

log_step "Ensuring up-to-date keyrings..."
pacman -Sy --noconfirm
pacman -S --noconfirm --needed artix-keyring archlinux-keyring
pacman-key --populate artix archlinux

log_step "Installing minimal base system..."
BASE_PKGS=(
    base linux-lts linux-firmware-intel intel-ucode
    dinit dbus dbus-dinit
    seatd seatd-dinit
    grub efibootmgr sudo nano
)
basestrap /mnt "${BASE_PKGS[@]}"

log_step "Generating fstab..."
fstabgen -U /mnt > /mnt/etc/fstab

log_step "Enabling SSD TRIM (discard) on root + swap..."
# NOTE: these edits assume fstabgen emitted the usual 'relatime' (ext4) /
# 'defaults' (swap) options. We verify the edit actually landed rather than
# failing silently if a future fstabgen ever changes its default wording.
sed -i '\#[[:space:]]/[[:space:]].*ext4# s/relatime/relatime,discard/' /mnt/etc/fstab
if ! grep 'ext4' /mnt/etc/fstab | grep -q 'discard'; then
    echo "   WARNING: could not confirm 'discard' was added to the root fstab entry - check /mnt/etc/fstab manually."
fi

sed -i '/none[[:space:]]\+swap/ s/defaults/defaults,discard/' /mnt/etc/fstab
if ! grep 'swap' /mnt/etc/fstab | grep -q 'discard'; then
    echo "   WARNING: could not confirm 'discard' was added to the swap fstab entry - check /mnt/etc/fstab manually."
fi

# ==============================================================================
# System Configuration (Chroot)
# ==============================================================================
log_step "Configuring system (chroot)..."

printf '%s\n' "$HOSTNAME" > /mnt/etc/install_hostname
printf '%s\n' "$USERNAME" > /mnt/etc/install_username
printf '%s\n' "$TIMEZONE" > /mnt/etc/install_timezone

artix-chroot /mnt /bin/bash << 'EOF'
set -euo pipefail

HOSTNAME="$(cat /etc/install_hostname)"
USERNAME="$(cat /etc/install_username)"
TIMEZONE="$(cat /etc/install_timezone)"

echo "-> Stage 2: installing everything beyond the minimal base..."
# Full upgrade (-Syu), not just a database sync (-Sy), to avoid partial
# upgrades: syncing the db without upgrading already-installed packages can
# leave newly-installed packages linked against libraries that are older
# than what they expect.
pacman -Syu --noconfirm

STAGE2_PKGS=(
    networkmanager networkmanager-dinit wpa_supplicant
    zramen zramen-dinit
    mesa libinput vulkan-intel
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    ttf-dejavu
)
pacman -S --noconfirm --needed "${STAGE2_PKGS[@]}"

echo "-> Configuring zram (zramen)..."
cat > /etc/zramen.conf << 'ZRAMEN_EOF'
ZRAM_SIZE=50
ZRAM_COMP_ALGORITHM=zstd
ZRAM_PRIORITY=32767
ZRAMEN_SWAPON_DISCARD=both
ZRAMEN_EOF

if [[ -f /etc/dinit.d/zramen ]]; then
    if ! grep -q "zramen.conf" /etc/dinit.d/zramen 2>/dev/null; then
        echo "   WARNING: /etc/dinit.d/zramen does not reference zramen.conf as expected."
    fi
else
    echo "   WARNING: /etc/dinit.d/zramen not found - zramen-dinit may not have installed correctly."
fi

echo "-> Tuning swappiness for zram..."
# vm.swappiness up to 200 requires Linux 5.8+ (linux-lts qualifies); on
# older kernels values above 100 are clamped back down to 100.
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-zram.conf << 'SYSCTL_EOF'
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
mkdir -p /etc/dinit.d/boot.d
enable_svc() {
    local svc="$1"
    if [[ -e "/etc/dinit.d/$svc" ]]; then
        ln -sf "/etc/dinit.d/$svc" /etc/dinit.d/boot.d/
        echo "   enabled: $svc"
    else
        echo "   WARNING: /etc/dinit.d/$svc not found, skipping."
    fi
}
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
enable_svc seatd
enable_svc_try networkmanager NetworkManager
enable_svc zramen

echo "-> Setting up Chaotic-AUR..."
pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com \
    || pacman-key --recv-key 3056513887B78AEB --keyserver keys.openpgp.org
pacman-key --lsign-key 3056513887B78AEB
pacman -U --noconfirm \
    'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
    'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
if ! grep -q '\[chaotic-aur\]' /etc/pacman.conf; then
    cat >> /etc/pacman.conf << 'CHAOTIC_EOF'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
CHAOTIC_EOF
fi
# Full upgrade after adding the new repo, not just a sync - same
# partial-upgrade reasoning as above.
pacman -Syu --noconfirm

echo "-> Creating user '$USERNAME'..."
useradd -m -G wheel,seat -s /bin/bash "$USERNAME"

echo "-> Setting up XDG_RUNTIME_DIR for user..."
# The inner \$uid and \$( ) are escaped so they land in the service file
# literally and are evaluated by /bin/sh at boot time via `id -u`, rather
# than being baked in as a fixed UID captured during installation. This
# keeps the service correct even if the account is ever recreated with a
# different UID.
cat > /etc/dinit.d/runtime-dir << RUNTIMEDIR_EOF
type = scripted
command = /bin/sh -c 'uid=\$(id -u ${USERNAME}) && mkdir -p /run/user/\$uid && chown ${USERNAME}:${USERNAME} /run/user/\$uid && chmod 0700 /run/user/\$uid'
RUNTIMEDIR_EOF
enable_svc runtime-dir

# Source .bashrc and export XDG_RUNTIME_DIR in bash_profile so user
# applications (Caelestia/Wayland/PipeWire) know where sockets are
cat >> "/home/$USERNAME/.bash_profile" << 'PROFILE_EOF'
[[ -f ~/.bashrc ]] && . ~/.bashrc
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
PROFILE_EOF
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bash_profile"

echo "-> Setting up user-level dinit instance for PipeWire..."
USER_DINIT_D="/home/$USERNAME/.config/dinit.d"
mkdir -p "$USER_DINIT_D"

# 'boot' is the target dinit brings up by default when started as a plain
# user instance. Using direct depends-on lines (rather than a waits-for.d
# directory of symlinks) - dinit still starts pipewire before wireplumber/
# pipewire-pulse since those two declare their own depends-on = pipewire.
cat > "$USER_DINIT_D/boot" << 'DINIT_BOOT_EOF'
type = internal
depends-on = pipewire
depends-on = wireplumber
depends-on = pipewire-pulse
DINIT_BOOT_EOF

cat > "$USER_DINIT_D/pipewire" << 'DINIT_PW_EOF'
type = process
command = /usr/bin/pipewire
restart = true
smooth-recovery = true
DINIT_PW_EOF

cat > "$USER_DINIT_D/wireplumber" << 'DINIT_WP_EOF'
type = process
command = /usr/bin/wireplumber
depends-on = pipewire
restart = true
smooth-recovery = true
DINIT_WP_EOF

cat > "$USER_DINIT_D/pipewire-pulse" << 'DINIT_PWP_EOF'
type = process
command = /usr/bin/pipewire-pulse
depends-on = pipewire
restart = true
smooth-recovery = true
DINIT_PWP_EOF

chown -R "$USERNAME:$USERNAME" "$USER_DINIT_D"

# Start the user dinit instance from .bash_profile, once XDG_RUNTIME_DIR is
# set and the socket dir exists (both handled above/by the runtime-dir
# service). Poll for the pipewire socket instead of a fixed sleep, so we
# don't race a slow boot chain before handing off to Hyprland.
cat >> "/home/$USERNAME/.bash_profile" << 'PROFILE_EOF'
if ! pgrep -u "$(id -u)" -x dinit >/dev/null 2>&1; then
    dinit --user -q &
    disown
fi

for _ in $(seq 1 50); do
    [[ -S "$XDG_RUNTIME_DIR/pipewire-0" ]] && break
    sleep 0.1
done

if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    dbus-run-session start-hyprland
fi
PROFILE_EOF
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bash_profile"

echo "-> Configuring sudo..."
install -m 440 /dev/null /etc/sudoers.d/wheel
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
visudo -cf /etc/sudoers.d/wheel || { echo "   ERROR: /etc/sudoers.d/wheel failed syntax check!" >&2; exit 1; }

echo "-> Setting up realtime audio scheduling (rtprio)..."
groupadd -f realtime
usermod -aG realtime,audio,video "$USERNAME"
mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/99-realtime-audio.conf << 'LIMITS_EOF'
@realtime - rtprio 95
@realtime - memlock unlimited
@realtime - nice -19
LIMITS_EOF
EOF

log_step "Setting passwords..."
printf 'root:%s\n'            "$PASSWORD" | artix-chroot /mnt chpasswd
printf '%s:%s\n' "$USERNAME"  "$PASSWORD" | artix-chroot /mnt chpasswd

rm -f /mnt/etc/install_hostname /mnt/etc/install_username /mnt/etc/install_timezone

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
echo "  - Log in at the tty1 prompt."
echo "  - Wifi: nmcli device wifi connect <SSID> password <password>"
echo "  - Verify zram:   zramctl"
echo "  - Verify audio limits: ulimit -r -l"
