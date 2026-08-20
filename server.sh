#!/usr/bin/env bash
set -e

# Arch Linux server installer for a VirtualBox VM — a headless Docker host.
# Sibling of arch.sh (the bare-metal installer), stripped to server bits:
# no GUI/audio/bluetooth/linux-firmware, just sshd, docker and zsh/starship.
#
# Run as root from the Arch live ISO booted inside the VM:
#   curl -LO https://raw.githubusercontent.com/sandipsky/dotfiles/main/vm.sh
#   bash vm.sh
#
# Works with either VM firmware: EFI enabled in the VM settings gets
# systemd-boot on GPT, the VirtualBox default (BIOS) gets GRUB on MBR.

if [[ $EUID -ne 0 ]]; then
    echo "Run this as root from the Arch live ISO." >&2
    exit 1
fi

echo "Disks:"
lsblk -dpno NAME,SIZE,MODEL
echo

read -p "Target disk (default /dev/sda): " DISK
DISK=${DISK:-/dev/sda}
read -p "Username: " USER
read -p "Password: " PASSWORD
read -p "This ERASES $DISK completely. Continue? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

### -------- FIRMWARE / PARTITIONS --------
if [[ -d /sys/firmware/efi/efivars ]]; then
    FIRMWARE="efi"
else
    FIRMWARE="bios"
fi

# /dev/sda -> sda1, /dev/nvme0n1 -> nvme0n1p1
case "$DISK" in
    *[0-9]) PART="${DISK}p" ;;
    *)      PART="$DISK"    ;;
esac

wipefs -af "$DISK"
if [[ "$FIRMWARE" == "efi" ]]; then
    parted -s "$DISK" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB \
        set 1 esp on \
        mkpart root ext4 513MiB 100%
    udevadm settle
    EFI="${PART}1"
    ROOT="${PART}2"
    mkfs.fat -F32 "$EFI"
    mkfs.ext4 -F "$ROOT"
    mount -o noatime "$ROOT" /mnt
    mkdir -p /mnt/boot
    mount "$EFI" /mnt/boot
else
    parted -s "$DISK" \
        mklabel msdos \
        mkpart primary ext4 1MiB 100% \
        set 1 boot on
    udevadm settle
    ROOT="${PART}1"
    mkfs.ext4 -F "$ROOT"
    mount -o noatime "$ROOT" /mnt
fi

### -------- BASE ARCH --------
pacman -Syy --noconfirm archlinux-keyring

VIRT=$(systemd-detect-virt) || true

# linux-firmware is skipped on purpose — VirtualBox emulates no hardware that
# needs firmware blobs (mkinitcpio's "possibly missing firmware" warnings are
# harmless). No base-devel/yay either: everything here is in the official repos.
EXTRA=()
if [[ "$FIRMWARE" == "bios" ]]; then
    EXTRA+=(grub)
fi
if [[ "$VIRT" == "oracle" ]]; then
    EXTRA+=(virtualbox-guest-utils-nox)
fi

pacstrap /mnt --noconfirm --needed \
    base linux \
    sudo vim git curl wget less htop \
    openssh \
    zram-generator \
    zsh zsh-syntax-highlighting zsh-autosuggestions starship \
    docker docker-buildx docker-compose \
    "${EXTRA[@]}"

genfstab -U /mnt >> /mnt/etc/fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT")

### -------- CHROOT SCRIPT --------
cat <<EOF > /mnt/next.sh
#!/usr/bin/env bash
set -e

### --- USER ---
# docker group: run docker without sudo (group exists via the package's sysusers).
useradd -m -G wheel,docker "$USER"
echo "$USER:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd
# Passworded sudo from the start — unlike arch.sh there is no follow-up
# install script that needs a temporary NOPASSWD.
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

### --- LOCALE / TIME ---
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/Asia/Kathmandu /etc/localtime
hwclock --systohc

### --- HOSTNAME ---
echo "docker-vm" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 docker-vm.localdomain docker-vm
HOSTS

### --- ZRAM ---
cat <<ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

### --- NETWORK (systemd-networkd: DHCP on any wired NIC, no NetworkManager) ---
cat <<NETWORK > /etc/systemd/network/20-wired.network
[Match]
Type=ether

[Network]
DHCP=yes
NETWORK

### --- DNS (same fix as install.sh: prefer known-good resolvers globally) ---
mkdir -p /etc/systemd/resolved.conf.d
cat <<RESOLVED > /etc/systemd/resolved.conf.d/10-global-dns.conf
[Resolve]
DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
Domains=~.
RESOLVED
# The stub-resolv.conf symlink is made by vm.sh after this chroot exits —
# arch-chroot bind-mounts the live ISO's resolv.conf over this one.

### --- BOOTLOADER ---
if [[ "$FIRMWARE" == "efi" ]]; then
    bootctl install --esp-path=/boot

    cat <<LOADER > /boot/loader/loader.conf
default arch.conf
timeout 1
console-mode keep
editor no
LOADER

    cat <<ENTRY > /boot/loader/entries/arch.conf
title   ArchLinux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw
ENTRY
else
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub
    grub-install --target=i386-pc "$DISK"
    grub-mkconfig -o /boot/grub/grub.cfg
fi

### --- ZSH / STARSHIP ---
chsh -s /bin/zsh "$USER"

cat <<'ZSHRC' > /home/$USER/.zshrc
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

HISTFILE=~/.history
HISTSIZE=10000
SAVEHIST=50000

setopt inc_append_history

PROMPT_EOL_MARK=''

eval "\$(starship init zsh)"

export PATH="\$PATH:\$HOME/.local/bin"
ZSHRC

chown $USER:$USER /home/$USER/.zshrc

### --- VIRTUALBOX GUEST ---
# Guest modules (vboxguest/vboxsf) are in the mainline kernel; the -nox
# package is just the userspace tools. VBoxService also syncs the clock,
# so timesyncd is only enabled when running under something else.
if [[ "$VIRT" == "oracle" ]]; then
    usermod -aG vboxsf "$USER"
    systemctl enable vboxservice.service
else
    systemctl enable systemd-timesyncd.service
fi

### --- SERVICES ---
systemctl enable systemd-networkd systemd-resolved sshd docker.service fstrim.timer
systemctl mask systemd-networkd-wait-online.service

echo "INSTALLATION COMPLETE"
EOF

chmod +x /mnt/next.sh
arch-chroot /mnt /next.sh
rm /mnt/next.sh

# arch-chroot bind-mounts the live ISO's resolv.conf into the chroot, so the
# stub symlink has to be made out here, after those mounts are gone.
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

echo "DONE. Power off, detach the ISO, then boot the VM."
echo
echo "SSH over VirtualBox NAT needs a port forward — on the host:"
echo "  VBoxManage modifyvm \"<vm-name>\" --natpf1 \"ssh,tcp,,2222,,22\""
echo "  ssh -p 2222 $USER@localhost"
echo "Drive its Docker from the host with:"
echo "  docker context create docker-vm --docker \"host=ssh://$USER@localhost:2222\""
