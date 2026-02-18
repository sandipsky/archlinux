#!/usr/bin/env bash
set -e

read -p "EFI partition (e.g. /dev/nvme0n1p1): " EFI
read -p "ROOT partition (e.g. /dev/nvme0n1p2): " ROOT
read -p "Enter NTFS D Drive partition: " HOME_DEV
read -p "Username: " USER
read -p "Full Name: " NAME
read -p "Password: " PASSWORD

### -------- FILESYSTEM --------
mkfs.fat -F32 "$EFI"
mkfs.ext4 -F "$ROOT"

mount -o noatime "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

### -------- BASE ARCH --------
pacman -Syy --noconfirm archlinux-keyring

pacstrap /mnt --noconfirm --needed \
base base-devel \
linux linux-headers \
linux-firmware \
networkmanager vim git curl \
intel-ucode \
dkms \
iptables-nft \
zram-generator \
power-profiles-daemon \
bluez bluez-utils \
pipewire wireplumber pipewire-alsa pipewire-pulse \

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
sed -i 's/^%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

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

### --- VIRTUALBOX DETECTION ---
if [[ "$VIRT" == "oracle" || "$VIRT" == "virtualbox" ]]; then
    echo "VirtualBox detected. Installing guest utilities..."
    pacman -S --noconfirm --needed virtualbox-guest-utils
    usermod -aG vboxsf "$USER"
    systemctl enable vboxservice.service
fi

### --- KVM / LIBVIRT STACK ---
echo "Installing KVM / libvirt virtualization stack..."
pacman -S --noconfirm --needed \
    qemu-full \
    virt-manager \
    virt-viewer \
    dnsmasq \
    vde2 \
    openbsd-netcat \
    ebtables \
    libguestfs \
    swtpm

usermod -aG libvirt "$USER"
systemctl enable libvirtd.service
virsh net-autostart default || true

### --- ZRAM ---
cat <<ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

### --- NVIDIA ---
pacman -S --noconfirm \
nvidia-open \
nvidia-utils \
nvidia-settings \
libva-nvidia-driver \
opencl-nvidia

### --- MKINITCPIO / NVIDIA ---
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(systemd autodetect modconf block filesystems keyboard)/' /etc/mkinitcpio.conf

mkinitcpio -P

### --- MULTILIB ---
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
pacman -Syy --noconfirm

### --- AUR (yay) ---
cd /tmp
sudo -u "$USER" git clone https://aur.archlinux.org/yay.git
cd yay
sudo -u "$USER" makepkg -sri --needed --noconfirm
cd /
rm -rf /tmp/yay


### --- NTFS ROOT PASSWORD FIX ---
cat <<'POLKIT' > /etc/polkit-1/rules.d/49-nopasswd_global.rules
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKIT

chmod 644 /etc/polkit-1/rules.d/49-nopasswd_global.rules

if [[ -n "$HOME_DEV" ]]; then
    mkdir -p /mnt/HOME
    HOME_UUID=$(blkid -s UUID -o value "$HOME_DEV")
    echo "UUID=$HOME_UUID /mnt/HOME auto nosuid,nodev,nofail,x-gvfs-show 0 0" >> /etc/fstab
    mount -a
else
    echo "No separate /home drive specified, skipping..."
fi

### --- BATTERY CHARGE THRESHOLD ---
cat <<'BATTERY' > /etc/systemd/system/battery-charge-threshold.service
[Unit]
Description=Set battery charge threshold
After=multi-user.target
StartLimitBurst=0

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo 80 > /sys/class/power_supply/BAT1/charge_control_end_threshold'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BATTERY

### --- ZSH / STARSHIP ---
pacman -S --noconfirm --needed \
zsh \
zsh-syntax-highlighting \
zsh-autosuggestions \
starship

# Set zsh as default shell for user
chsh -s /bin/zsh "$USER"

cat <<'ZSHRC' > /home/$USER/.zshrc
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

HISTFILE=~/.history
HISTSIZE=10000
SAVEHIST=50000

setopt inc_append_history

eval "\$(starship init zsh)"

export PATH="\$PATH:\$HOME/.local/bin"
ZSHRC

chown $USER:$USER /home/$USER/.zshrc

### --- WINE / GAMING STACK ---
pacman -S --noconfirm --needed \
wine-staging wine-mono wine-gecko \
giflib lib32-giflib \
libpng lib32-libpng \
libldap lib32-libldap \
gnutls lib32-gnutls \
mpg123 lib32-mpg123 \
openal lib32-openal \
v4l-utils lib32-v4l-utils \
libpulse lib32-libpulse \
libgpg-error lib32-libgpg-error \
libgcrypt lib32-libgcrypt \
alsa-plugins lib32-alsa-plugins \
alsa-lib lib32-alsa-lib \
libjpeg-turbo lib32-libjpeg-turbo \
sqlite lib32-sqlite \
libxcomposite lib32-libxcomposite \
libxinerama lib32-libxinerama \
ncurses lib32-ncurses \
ocl-icd lib32-ocl-icd \
libxslt lib32-libxslt \
libva lib32-libva \
gtk3 lib32-gtk3 \
gst-plugins-base-libs lib32-gst-plugins-base-libs \
gst-libav \
vulkan-intel lib32-vulkan-intel \
lib32-mesa \
python-protobuf

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
    vlc vlc-plugins-all \
    obs-studio \
    qbittorrent \
    lutris \
    gvfs-mtp \
    ntfs-3g \
    ffmpegthumbnailer \
    wget

### --- DEVELOPMENT STACK ---
pacman -S --noconfirm --needed \
    nodejs-lts-iron \
    npm \
    jdk21-openjdk 

sudo -u "$USER" npm install -g @angular/cli --prefix=/home/$USER/.local

#AUR APPS
sudo -u "$USER" yay -S google-chrome visual-studio-code-bin neofetch --noconfirm --needed

### --- BOOTLOADER ---
bootctl install --path=/boot

cat <<LOADER > /boot/loader/loader.conf
default arch.conf
timeout 0
editor no
LOADER

cat <<ENTRY > /boot/loader/entries/arch.conf
title   ArchLinux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw quiet loglevel=3 rd.udev.log_level=3
ENTRY

### --- SERVICES ---
systemctl enable NetworkManager bluetooth power-profiles-daemon fstrim.timer
systemctl enable battery-charge-threshold.service
systemctl --global enable pipewire pipewire-pulse wireplumber

echo "INSTALLATION COMPLETE"
EOF

chmod +x /mnt/next.sh
arch-chroot /mnt /next.sh
rm /mnt/next.sh

echo "DONE. You can reboot now."
