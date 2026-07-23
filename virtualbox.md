# VirtualBox Installation Guide (Arch Linux)

VirtualBox is not installed by `install.sh`. Follow this guide to install it manually when needed.

## 1. Install VirtualBox + host modules

This setup uses the regular `linux` kernel, so use the prebuilt host modules:

```bash
sudo pacman -S --needed virtualbox virtualbox-host-modules-arch
```

> If you ever switch to another kernel (e.g. `linux-lts`, `linux-zen`), use
> `virtualbox-host-dkms` instead of `virtualbox-host-modules-arch` and make sure
> the matching kernel headers package is installed.

## 2. Load the kernel modules

Load them now without rebooting:

```bash
sudo modprobe vboxdrv vboxnetadp vboxnetflt
```

Load them automatically at boot:

```bash
sudo tee /etc/modules-load.d/virtualbox.conf <<'EOF'
vboxdrv
vboxnetadp
vboxnetflt
EOF
```

## 3. Add your user to the vboxusers group

Required for USB passthrough to guests:

```bash
sudo gpasswd -a "$USER" vboxusers
```

Log out and back in for the group change to take effect.

## 4. (Optional) Extension Pack

Adds USB 2.0/3.0, VirtualBox RDP, and disk encryption. Install from the AUR:

```bash
yay -S virtualbox-ext-oracle
```

## 5. (Optional) Guest Additions ISO

To install Guest Additions inside non-Arch guests (e.g. Windows), install the ISO on the host:

```bash
sudo pacman -S --needed virtualbox-guest-iso
```

Then in the VM window: Devices → Insert Guest Additions CD image.

## Notes

- After a kernel upgrade, the modules are rebuilt/reinstalled automatically with
  `virtualbox-host-modules-arch`; you just need to reboot (or `modprobe vboxdrv` again).
- If Arch itself is running *inside* a VirtualBox VM, `install.sh` already handles that
  case: it detects VirtualBox and installs `virtualbox-guest-utils` automatically.
