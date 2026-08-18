# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Personal Arch Linux installer scripts, run from the Arch live ISO. There is no build, lint, or test tooling — validate changes with `bash -n <script>` / `shellcheck`, and test real runs in a VirtualBox VM (both scripts auto-detect VirtualBox via `systemd-detect-virt` and install guest utils).

- `install.sh` — the main installer, **hardware-specific**: tuned for an ASUS TUF F15 with Intel 10th-gen i5 (iGPU: UHD, `i915`) and NVIDIA GTX 1650 (Optimus/hybrid graphics). Assumes UEFI + NVMe, Intel-only microcode, `vulkan-intel`, and NVIDIA is installed unconditionally.
- `install-minimal.sh` — generic minimal variant for any Intel/AMD machine; both microcodes, default mkinitcpio hooks, NVIDIA optional, always installs KDE.
- `README.md` — manual pre-install steps (Wi-Fi via `iwctl`, partitioning with `cfdisk`) that the scripts do NOT do; they expect EFI and root partitions to already exist and will **format** whatever partitions are entered.

## Script architecture (both installers)

Two-phase, single-file design:

1. **Live-ISO phase** (top of script): prompts for input, formats/mounts partitions, `pacstrap`s the base system, captures UUIDs.
2. **Chroot phase**: a `cat <<EOF > /mnt/next.sh` heredoc containing the entire in-system configuration, executed via `arch-chroot /mnt /next.sh`, then deleted.

Heredoc quoting is load-bearing:
- The outer `EOF` heredoc is **unquoted**, so `$USER`, `$PASSWORD`, `$ROOT_UUID`, `$VIRT`, etc. are expanded *at write time* by the live-ISO shell. Any literal `$` that must survive into next.sh needs escaping (see `\$(starship init zsh)` in the .zshrc block).
- Inner heredocs writing config files (`<<'ZRAM'`, `<<'NVUDEV'`, …) are mostly **quoted** to prevent expansion. When editing, check whether the block needs live-phase variables before choosing quoted vs. unquoted.

Ordering constraints inside next.sh (`install.sh`):
- The bootloader (`bootctl install` + loader entries) is set up **early on purpose** so the system stays bootable even if a later network/AUR step dies under `set -e`. Don't move package installs above it.
- `MODULES=` in mkinitcpio.conf is written twice: first `(i915)`, then overwritten with the full NVIDIA set `(i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm)` after the driver install. The single `mkinitcpio -P` after the NVIDIA section covers both; a pacman hook (`/etc/pacman.d/hooks/nvidia.hook`) keeps it rebuilt on upgrades.
- multilib is enabled before the NVIDIA/Wine sections because they pull `lib32-*` packages.
- yay is built as `$USER` (makepkg refuses root); AUR installs come after user + sudoers setup.

## Power-management design (install.sh)

Much of the git history is battery/boot tuning — treat these as intentional, interlocking settings:
- dGPU runtime power-off requires all three pieces together: `NVreg_DynamicPowerManagement=0x02` modprobe options, the udev rules in `80-nvidia-pm.rules` setting `power/control=auto` (matching `add|bind` because the driver binds in the initramfs before the rule exists), **and** audio codec power-save (`snd_hda_intel power_save=1`) — the comment notes it's needed for dGPU D3cold.
- Battery is capped at 80% via a oneshot systemd service writing `charge_control_end_threshold`, re-run after suspend/hibernate.
- Boot speed choices: `timeout 0` in systemd-boot, early KMS modules, zstd initramfs compression, `nowatchdog`/`mitigations=off` on the kernel cmdline, masked `*-wait-online` services.

## Conventions

- `set -e` throughout: any added command that may legitimately fail needs `|| true` (see existing uses).
- Passwordless sudo (`NOPASSWD`) and a permissive wheel polkit rule are deliberate choices for this single-user machine, not oversights.
- Keep `install-minimal.sh` generic — hardware-specific tuning belongs only in `install.sh`.
