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
    # Dedup (multiple missing tools can map to the same package)
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
#
# IMPORTANT: this is -Sy (sync db only), not -Syu. The live session's root
# is a RAM-backed tmpfs overlay on top of the squashfs, not real disk -
# -Syu would upgrade every package already installed on the live media
# (including linux-headers), and on a 4GB machine there isn't enough RAM
# left in that overlay to extract a full kernel upgrade. -Sy + a targeted
# --needed install only touches the two packages we actually need.
pacman -Sy --noconfirm
pacman -S --noconfirm --needed artix-keyring archlinux-keyring
pacman-key --populate artix archlinux

log_step "Installing minimal base system..."
# Stage 1: just enough to get a bootable, chroot-able system. Everything
# else (networking, sway+waybar, audio, bootloader, zram) gets installed
# in Stage 2 via a plain `pacman -S` right after artix-chroot - see below.
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

    # dinit init system + system bus. Needed at this stage so the chroot
    # itself has an init/dbus present.
    dinit
    dbus dbus-dinit

    # IMPORTANT: seatd/seatd-dinit are installed HERE, in the same
    # basestrap call as "base", not later in Stage 2. The "base" meta
    # package itself requires the virtual "init-logind", and if nothing
    # satisfying it is present in the transaction, pacman silently
    # defaults to pulling in elogind-dinit to satisfy that requirement -
    # which then hard-conflicts with seatd-dinit (both provide
    # init-logind) the moment Stage 2 tries to add it. Listing
    # seatd-dinit alongside base up front means pacman satisfies base's
    # requirement with seatd from the very first transaction, so
    # elogind-dinit is never pulled in at all.
    seatd seatd-dinit

    # Core essentials - not desktop-specific, a base system needs these
    # regardless of what's layered on top later.
    grub efibootmgr sudo nano

    # base-devel deliberately left out - Chaotic-AUR (set up later, in the
    # chroot) covers prebuilt binaries for most AUR packages. If a package
    # isn't mirrored there and needs local building via yay/paru, install
    # it then: pacman -S base-devel
)
basestrap /mnt "${BASE_PKGS[@]}"

log_step "Generating fstab..."
fstabgen -U /mnt > /mnt/etc/fstab

log_step "Enabling SSD TRIM (discard) on root + swap..."
# Root is ext4 on a SATA SSD - enable online discard.
sed -i '\#[[:space:]]/[[:space:]].*ext4# s/relatime/relatime,discard/' /mnt/etc/fstab
# Swap partition - also enable discard.
sed -i '/none[[:space:]]\+swap/ s/defaults/defaults,discard/' /mnt/etc/fstab

# Note: zram's config file (/etc/zramen.conf) and the swappiness sysctl
# are written *inside* the chroot below, after the zramen package is
# actually installed in Stage 2 - writing them here (before the package
# exists) would just get silently overwritten once pacman installs its
# own default config on top.

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

    # Graphics: HD 4600 is handled by the generic "modesetting"/kms
    # driver inside mesa - no separate xf86-video-intel needed (it's
    # unmaintained and worse than modesetting on Haswell). No xorg
    # packages at all this time - sway is a Wayland compositor and
    # talks to the kernel (DRM/KMS) + libinput directly, no X server.
    mesa libinput vulkan-intel

    # (seatd/seatd-dinit already installed back in Stage 1's basestrap
    # call - see BASE_PKGS above. User is added to the 'seat' group
    # below so it can talk to seatd without extra setup.)

    # sway + the pieces sway does NOT bundle itself:
    #   swaybg     - wallpaper
    #   swayidle   - idle management (screen lock/off triggers)
    #   swaylock   - the lock screen itself
    #   waybar     - status bar
    #   wofi       - app launcher (rofi-equivalent for wayland)
    #   mako       - notification daemon
    #   grim/slurp - screenshot tool + region selector
    #   xorg-xwayland - lets plain X11 apps still run under sway
    sway swaybg swayidle swaylock waybar wofi mako grim slurp xorg-xwayland

    # Qt/GTK apps need these to render natively on Wayland instead of
    # falling back to a blurry XWayland bridge.
    qt5-wayland qt6-wayland

    # polkit + a polkit authentication agent - GUI apps (e.g. package
    # managers, some settings tools) need this to prompt for sudo
    # graphically instead of failing silently.
    polkit polkit-gnome

    # A terminal - kitty carried over as the default since it's a solid
    # choice either way; swap for foot/alacritty/whatever later.
    kitty

    # Audio: pipewire stack. No system-level dinit service for these -
    # they're user session daemons, launched explicitly via `exec` lines
    # in the sway config below (see the runtime-dir service + sway
    # config further down for why that's necessary without elogind).
    # pipewire-jack pinned explicitly (it satisfies the virtual 'jack'
    # dependency other packages want) so pacman doesn't stop to
    # interactively ask jack2-vs-pipewire-jack - it's the right pick
    # anyway since jack2 would be a redundant separate audio server
    # alongside pipewire.
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber

    # Pinned explicitly so pacman doesn't stop mid-install to ask which
    # of 8 providers satisfies some package's virtual 'ttf-font'
    # dependency - ttf-dejavu is a solid, lightweight, broadly-hinted
    # default. Swap/add nerd fonts later once you're theming waybar.
    ttf-dejavu
)
pacman -S --noconfirm --needed "${STAGE2_PKGS[@]}"

echo "-> Configuring zram (zramen)..."
# zramen reads its settings from environment variables, loaded from this
# file by its dinit service (NOT /etc/conf.d/zramen - that path doesn't
# exist, zramen has no conf.d convention). zstd gives a much better
# compression ratio than the lz4 default, which matters a lot on 4GB of
# RAM; the dual-core Haswell CPU has enough headroom for it. Size is 50%
# of RAM (2GB raw, more once compressed) since 4GB is tight. Priority
# 32767 is zramen's own default (max) - it guarantees zram is always
# used before the disk swap partition, matching "use RAM before disk".
cat > /etc/zramen.conf << 'ZRAMEN_EOF'
ZRAM_SIZE=50
ZRAM_COMP_ALGORITHM=zstd
ZRAM_PRIORITY=32767
ZRAMEN_SWAPON_DISCARD=both
ZRAMEN_EOF

# Sanity check: confirm the dinit service actually points at this file.
# If Artix's packaging uses a different path than expected, this warns
# loudly instead of silently configuring the wrong file.
if [[ -f /etc/dinit.d/zramen ]]; then
    if ! grep -q "zramen.conf" /etc/dinit.d/zramen 2>/dev/null; then
        echo "   WARNING: /etc/dinit.d/zramen does not reference zramen.conf as expected."
        echo "            Check its actual env-file path with: cat /etc/dinit.d/zramen"
        echo "            and move /etc/zramen.conf there if it differs."
    fi
else
    echo "   WARNING: /etc/dinit.d/zramen not found - zramen-dinit may not have installed correctly."
fi

echo "-> Tuning swappiness for zram..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-zram.conf << 'SYSCTL_EOF'
# Higher swappiness makes sense when the primary swap target is
# fast zram rather than disk. Adjust down if things feel less snappy.
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
enable_svc seatd
enable_svc_try connman connmand
enable_svc zramen

# No display manager (ly kept causing tty/getty conflicts that were a pain
# to pin down reliably across dinit versions). tty1's default agetty
# (already enabled out of the box, nothing to configure) gives a plain
# username/password prompt on its own - .bash_profile below auto-starts
# sway right after a successful login.

echo "-> Setting up Chaotic-AUR (prebuilt binary packages, no compiling needed)..."
# keyserver.ubuntu.com is occasionally flaky - fall back to keys.openpgp.org
# rather than letting one unreachable keyserver stall the whole install.
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
pacman -Sy --noconfirm

echo "-> Creating user '$USERNAME'..."
# 'seat' group added here so the user can talk to seatd without extra
# setup - required for sway to get GPU/input access without logind.
useradd -m -G wheel,seat -s /bin/bash "$USERNAME"

echo "-> Setting up XDG_RUNTIME_DIR (no elogind/systemd to do this for us)..."
# On systemd or elogind systems, XDG_RUNTIME_DIR (a per-user directory
# for sockets - pipewire, wireplumber, wayland itself all need this) is
# created automatically at login via a PAM module. We deliberately have
# neither elogind nor systemd, so nothing does this automatically -
# without it, pipewire/wireplumber simply have nowhere to put their
# sockets and fail to connect, which looks like a pipewire problem but
# isn't one.
#
# Rather than reaching for a per-user service manager (dinit --user or
# similar) just to recreate what's normally a one-line mkdir, this is a
# tiny dinit boot service that creates a static /run/user/<uid> for our
# one known user, correctly owned and permissioned, before the login
# prompt even appears. /run is already a tmpfs (standard on Artix), so
# this is recreated fresh on every boot - nothing to clean up.
USER_UID="$(id -u "$USERNAME")"
cat > /etc/dinit.d/runtime-dir << RUNTIMEDIR_EOF
type = scripted
command = /bin/sh -c 'mkdir -p /run/user/${USER_UID} && chown ${USERNAME}:${USERNAME} /run/user/${USER_UID} && chmod 0700 /run/user/${USER_UID}'
RUNTIMEDIR_EOF
enable_svc runtime-dir

echo "-> Setting up auto-launch sway for '$USERNAME'..."
# After you type your username/password at the tty1 login prompt, this
# starts sway automatically - only on tty1, only if no Wayland session
# is already running. Wrapped in dbus-run-session so sway gets its own
# working session bus (needed by waybar, mako, polkit-gnome, etc.)
# without relying on systemd's user-session bus activation.
cat > "/home/$USERNAME/.bash_profile" << 'PROFILE_EOF'
if [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then
    # Created at boot by the runtime-dir dinit service (no elogind/
    # systemd present to do this automatically) - just point at it here.
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=sway
    export MOZ_ENABLE_WAYLAND=1
    export QT_QPA_PLATFORM=wayland
    exec dbus-run-session sway
fi
PROFILE_EOF
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bash_profile"

# Minimal starting sway config: default keybindings/workspaces via
# sway's own bundled default (copied from /etc/sway/config on first
# run if none exists), plus wiring in waybar as the bar and wofi as
# the launcher so you have working basics before you rice it further.
mkdir -p "/home/$USERNAME/.config/sway"
cat > "/home/$USERNAME/.config/sway/config" << 'SWAYCONF_EOF'
# Start from sway's own defaults, then override just what we care
# about right now. See `man 5 sway` for the full option list, and
# /etc/sway/config for the full commented reference.
include /etc/sway/config.d/*

set $mod Mod4
set $term kitty
set $menu wofi --show drun

bindsym $mod+Return exec $term
bindsym $mod+d exec $menu
bindsym $mod+Shift+q kill
bindsym $mod+Shift+c reload
bindsym $mod+Shift+e exec swaynag -t warning -m 'Exit sway?' -B 'Yes' 'swaymsg exit'

# floating toggle + minimize-equivalent (scratchpad)
bindsym $mod+Shift+space floating toggle
bindsym $mod+Shift+minus move scratchpad
bindsym $mod+minus scratchpad show

bar {
    swaybar_command waybar
}

output * bg #1d1f21 solid_color
exec swaybg -c '#1d1f21'
exec mako
exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

# Pipewire has to be started explicitly here - on a systemd or elogind
# system this happens automatically via user-session bus activation,
# but we have neither, so nothing launches these on its own. Order
# doesn't matter much (they connect over sockets once up), but
# wireplumber (session/policy manager) after pipewire (the daemon
# itself) is the conventional order.
exec pipewire
exec wireplumber
exec pipewire-pulse
SWAYCONF_EOF
mkdir -p "/home/$USERNAME/.config/waybar"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"

echo "-> Configuring sudo..."
install -m 440 /dev/null /etc/sudoers.d/wheel
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel

echo "-> Setting up realtime audio scheduling (rtprio) for pipewire..."
# Lightweight alternative to running the rtkit-daemon: grant the audio
# group real-time scheduling + memlock directly via PAM limits. Pipewire
# picks this up automatically without needing an extra system service.
groupadd -f realtime
usermod -aG realtime,audio,video "$USERNAME"
mkdir -p /etc/security/limits.d
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
echo "  - You'll get a plain login prompt on tty1; log in and sway starts automatically."
echo "  - Wifi: connmanctl enable wifi; connmanctl scan wifi; connmanctl connect <service>"
echo "  - Verify zram:   zramctl        (should show a ~2GB zstd device, priority 32767)"
echo "  - Verify swap order: swapon --show   (zram should be listed above the disk partition)"
echo "  - If a service didn't start, check: dinitctl list"
echo "  - Sway keys to know: \$mod=Super. Super+Enter=terminal, Super+d=launcher,"
echo "    Super+Shift+space=float toggle, Super+minus=scratchpad hide/show."
