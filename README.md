# Arch Linux installation Guide

# Connecting to the internet
### NOTE: If you have wired connection you can skip this stage
## Connecting to Wi-FI
```
iwctl
device list
```
```
station <devicename> scan            
station <devicename> get-networks
station <devicename> connect <SSID>   
```
### Now check connection
```
ping google.com
```

# Disk partitioning
```
lsblk
```
## It will show your disks in your system, note down the disk head number without partition example /dev/sda (for HDD) or /dev/nvme0n1 (for SSD) by your disk
```
cfdisk /dev/sda
OR
cfdisk /dev/nvme0n1
```

## NOTE: Create something like this one EFI partiion and one Root partition
| Partition   | Mount point   | Size            | Type             |
| ---------   | ------------- | --------------- | ---------------- |
| /dev/sda1   | /mnt/boot     | at least 1GB    | EFI system       |
| /dev/sda2   | /mnt          | Remainder       | Linux filesystem |


## Note: If you want to use my script to automate installation from here and relax
```
curl https://raw.githubusercontent.com/sandipsky/archlinux/main/install.sh -0 install.sh
sh install.sh
```

## After Installation reboot and install your Preferred DE or use below script to install hyprland
```
git clone https://github.com/sandipsky/dotfiles
cd dotfiles
sh install.sh
```

