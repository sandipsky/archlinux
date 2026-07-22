#!/usr/bin/env bash
# Generic minimal Arch installer for any PC/laptop (Intel or AMD).
# KDE desktop. NVIDIA driver optional.
set -e

read -p "EFI partition (e.g. /dev/nvme0n1p1): " EFI
read -p "ROOT partition (e.g. /dev/nvme0n1p2): " ROOT
read -p "Username: " USER
read -p "Full Name: " NAME
read -p "Password: " PASSWORD
read -p "Install NVIDIA driver? (y/N): " INSTALL_NVIDIA

### -------- FILESYSTEM --------
mkfs.fat -F32 "$EFI"
mkfs.ext4 -F "$ROOT"

mount -o noatime "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

### -------- BASE ARCH --------
pacman -Syy --noconfirm archlinux-keyring

# Both microcodes installed; the default mkinitcpio 'microcode' hook embeds
# the right one. Default 'kms' hook gives early KMS on any GPU.
pacstrap /mnt --noconfirm --needed \
base base-devel \
linux linux-headers \
linux-firmware \
networkmanager vim curl \
intel-ucode amd-ucode \
mesa vulkan-intel vulkan-radeon \
zram-generator \
power-profiles-daemon \
bluez bluez-utils \
pipewire wireplumber pipewire-alsa pipewire-pulse

genfstab -U /mnt >> /mnt/etc/fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
VIRT=$(systemd-detect-virt) || true

### -------- CHROOT SCRIPT --------
cat <<EOF > /mnt/next.sh
#!/usr/bin/env bash
set -e

### --- USER ---
useradd -m "$USER"
usermod -c "$NAME" "$USER"
usermod -aG wheel,video,audio,storage,power "$USER"
echo "$USER:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

### --- LOCALE / TIME ---
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/Asia/Kathmandu /etc/localtime
hwclock --systohc

### --- HOSTNAME ---
echo "archlinux" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 archlinux.localdomain archlinux
HOSTS

### --- VIRTUALBOX GUEST (when installing inside a VM) ---
if [[ "$VIRT" == "oracle" || "$VIRT" == "virtualbox" ]]; then
    pacman -S --noconfirm --needed virtualbox-guest-utils
    usermod -aG vboxsf "$USER"
    systemctl enable vboxservice.service
fi

### --- ZRAM ---
cat <<ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

### --- BOOTLOADER ---
# Installed EARLY so the system is always bootable, even if a later
# (network) step fails under set -e.
bootctl install --path=/boot

cat <<LOADER > /boot/loader/loader.conf
default arch.conf
timeout 0
console-mode keep
editor no
LOADER

cat <<ENTRY > /boot/loader/entries/arch.conf
title   ArchLinux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw quiet loglevel=3
ENTRY

### --- NVIDIA (driver only) ---
if [[ "$INSTALL_NVIDIA" == "y" || "$INSTALL_NVIDIA" == "Y" ]]; then
    pacman -S --noconfirm --needed \
        nvidia-open-dkms \
        nvidia-utils
fi

#FONTS
pacman -S --noconfirm --needed \
    noto-fonts \
    noto-fonts-emoji \
    noto-fonts-extra \
    ttf-liberation \
    noto-fonts-cjk \
    ttf-dejavu \
    otf-font-awesome \
    ttf-fira-sans \
    ttf-jetbrains-mono

#PROGRAMS
pacman -S --noconfirm --needed \
    firefox \
    vlc vlc-plugins-all \
    obs-studio \
    qbittorrent \
    gvfs-mtp \
    ffmpegthumbnailer \
    wget

### --- DESKTOP (KDE) ---
pacman -S --noconfirm --needed \
    plasma-meta \
    konsole \
    ark \
    dolphin \
    sddm

systemctl enable sddm.service

### --- SERVICES ---
systemctl enable NetworkManager bluetooth power-profiles-daemon fstrim.timer
systemctl --global enable pipewire pipewire-pulse wireplumber

systemctl mask NetworkManager-wait-online.service systemd-networkd-wait-online.service

echo "INSTALLATION COMPLETE"
EOF

chmod +x /mnt/next.sh
arch-chroot /mnt /next.sh
rm /mnt/next.sh

echo "DONE. You can reboot now."
