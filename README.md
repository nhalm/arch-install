# arch-install — Arch Linux with LUKS2, btrfs, snapper, and a rollback that restores the kernel

One script that installs Arch Linux on an encrypted disk: **LUKS2** full-disk
encryption, **btrfs** subvolumes, **snapper** snapshots, and **GRUB** with
`GRUB_ENABLE_CRYPTODISK`. `snapper rollback N` restores the kernel, the
initramfs and `grub.cfg` along with the rest of the system, then boots what it
restored.

Written for and tested on an **ASUS ExpertBook**. The one hardware-specific
default is `UCODE=intel-ucode`; set `UCODE=amd-ucode` on AMD.

> [!WARNING]
> **It erases the entire target disk.** Every partition and every byte on
> `DISK` is destroyed. The script prints the disk it is about to wipe and waits
> for `y`.

Pairs with [nhalm/dotfiles](https://github.com/nhalm/dotfiles), which takes over
after first boot.

## Snapper rollback that includes the kernel

The usual Arch setup keeps `/boot` on the FAT ESP for systemd-boot, outside
every btrfs snapshot: a rollback restores the OS and leaves yesterday's kernel
and initramfs in place. This layout:

- `/boot` is a directory **inside** the root subvolume, on the encrypted btrfs.
- Root is mounted through the btrfs **default subvolume** — `/` has no `subvol=`
  in `fstab` and no `rootflags=subvol=` on the kernel command line.
- `snapper rollback N` repoints that default subvolume, so kernel, initramfs,
  modules, `/boot/grub/grub.cfg` and the OS all move together.
- GRUB reads btrfs and LUKS2 directly, so the encrypted `/boot` is reachable at
  boot. A snapper plugin and `grub-boot-sync.service` re-point GRUB's embedded
  prefix at the new subvolume after a rollback.

Cost: GRUB runs argon2id single-threaded in EFI, **~10 s of silent decrypt at
every boot**.

[DESIGN.md](DESIGN.md) has the decisions and the code references behind them.

## What it installs

| | |
|---|---|
| Encryption | LUKS2, argon2id, 4096-byte sectors, `--allow-discards`, keyfile in the initramfs so the passphrase is asked once, by GRUB |
| Filesystem | btrfs, `compress=zstd:3`, subvolumes for `/home`, `/var/log`, `/var/cache/pacman/pkg`, `/.snapshots` |
| Boot | GRUB at `EFI/GRUB` and the removable `EFI/BOOT/BOOTX64.EFI`, 3-second menu, `sd-encrypt` initramfs hooks |
| Snapshots | snapper configs for `root` and `home`, `snap-pac`, timeline and cleanup timers, timeline `Persistent=true` so a laptop catches up after sleep |
| System | NetworkManager, zram (`min(ram/2, 8192)`, zstd), `wheel` sudo, locked root, `git`, `vim`, man pages |

## Requirements

- UEFI, x86_64, Secure Boot off
- A spare USB stick for the Arch ISO
- An internet connection from the ISO
- 4 GB RAM or more — below that cryptsetup may silently weaken argon2id, and the
  script warns
- A disk you are willing to erase

## ASUS ExpertBook

| | |
|---|---|
| Boot menu | `Esc` or `F2` at power-on |
| Secure Boot | off |
| Disk | `nvme0n1`, ~953G |
| Microcode | `intel-ucode` |

Everything else in the script is generic UEFI x86_64.

## Install

**0. Check your data is elsewhere.** The disk is destroyed.

```bash
cd ~/dotfiles && git status --short && git log origin/main..HEAD --oneline
for d in ~/work ~/dev ~/personal; do
  for r in $d/*/; do
    [ -d "$r/.git" ] && git -C "$r" status --porcelain | grep -q . && echo "DIRTY $r"
    [ -d "$r/.git" ] && [ -n "$(git -C "$r" log '@{u}..' --oneline 2>/dev/null)" ] && echo "UNPUSHED $r"
  done
done
ls ~/.config/zsh/local.zsh 2>/dev/null && echo "^ gitignored, machine-local, copy it out"
```

1Password holds the SSH keys, so confirm you can sign in on another device.

**1. Write the ISO** (on another machine, or before wiping)

```bash
curl -fsSLO https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
lsblk                                    # find the USB, e.g. /dev/sdb
sudo dd if=archlinux-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**2. Boot it** from the firmware boot menu, with Secure Boot off.

**3. Network.** Ethernet works unattended. Wi-Fi:

```bash
iwctl
   station wlan0 scan
   station wlan0 get-networks
   station wlan0 connect <SSID>
   exit
ping -c1 archlinux.org
```

**4. Confirm the disk.** Getting this wrong destroys the wrong device.

```bash
lsblk -o NAME,SIZE,MODEL
```

**5. Run it.**

```bash
curl -fsSLO https://raw.githubusercontent.com/nhalm/arch-install/main/arch-install.sh
chmod +x arch-install.sh
DISK=/dev/nvme0n1 ./arch-install.sh
```

It prints what it will destroy and asks `[y/N]`, then asks for the LUKS
passphrase and your user password, twice each. Roughly 5-15 minutes depending
on mirrors. It ends with:

```
==> verify: all invariants hold
==> unmounting
==> install complete; reboot and remove the install medium
===INSTALL-DONE rc=0===
```

On any other ending, read `/tmp/arch-install.log`.

**6. Reboot, remove the USB.**

```bash
reboot
```

**7. First boot.** GRUB appears, then:

```
Enter passphrase for hd0,gpt2 (...):
Attempting to decrypt master key...
```

**Then roughly ten seconds of nothing.** That is GRUB running argon2id, which
has no progress indicator. Wait for `Slot "0" opened`; the kernel loads next.
It costs the same ten seconds at every boot.

Log in as your user at the console.

**8. Network again.**

```bash
nmcli device wifi connect <SSID> --ask
```

**9. Dotfiles.**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nhalm/dotfiles/main/bootstrap.sh)
```

**10. Sign in to 1Password** and enable its SSH agent. GitHub access and commit
signing both go through it.

**11. Re-run setup**, for the steps that need GitHub and the agent.

```bash
cd ~/dotfiles && ./setup.sh
```

**12. Check it.** The installer lived on the ISO's ramdisk, so fetch it again:

```bash
curl -fsSLO https://raw.githubusercontent.com/nhalm/arch-install/main/arch-install.sh
chmod +x arch-install.sh
sudo DISK=/dev/nvme0n1 MNT=/ ./arch-install.sh verify
sudo snapper -c root list
sudo btrfs subvolume get-default /
```

`verify` ends with `==> verify: all invariants hold`, or prints every failed
invariant and exits non-zero. `get-default` must print a path of the form
`@/.snapshots/N/snapshot`.

**13. Back up the LUKS header.**

```bash
sudo cryptsetup luksHeaderBackup /dev/nvme0n1p2 --header-backup-file luks-header.img
```

A damaged header is the one failure this project cannot recover from: without
it the data is gone, passphrase or not. Copy the file off the machine. It is as
sensitive as the disk — anyone with the header and the passphrase can decrypt
the disk, and it still works after you change the passphrase.

## Rollback

```bash
sudo snapper -c root list
sudo snapper -c root rollback N
reboot
```

`snapper rollback N` makes snapshot `N` the new root. Bare `snapper rollback`
takes the system you are running now and commits it as the new root. Pass the
number.

After the reboot both of these must name the same snapshot:

```bash
sudo btrfs subvolume get-default /   # ID 278 ... path @/.snapshots/14/snapshot
findmnt -no SOURCE /                 # /dev/mapper/root[/@/.snapshots/14/snapshot]
```

## Modes

| Mode | Command | Effect |
|---|---|---|
| `install` (default) | `DISK=/dev/nvme0n1 ./arch-install.sh` | Erases `DISK` and installs |
| `verify` | `sudo DISK=/dev/nvme0n1 MNT=/ ./arch-install.sh verify` | Read-only; re-checks every invariant of the layout, prints each failure and exits non-zero |
| `snapper` | `sudo MNT=/ ./arch-install.sh snapper` | Re-applies the snapper configuration in place, idempotently |

## Environment variables

| Variable | Default |
|---|---|
| `DISK` | required for `install` and `verify`, e.g. `/dev/nvme0n1`, `/dev/vda` |
| `CONFIRM` | `no`; `yes` runs without the prompt |
| `MNT` | `/mnt`; `/` for the running system |
| `TARGET_HOSTNAME` | `asus` |
| `USERNAME` | `nick` |
| `USER_PASSWORD` | prompted |
| `ROOT_PASSWORD` | unset, root stays locked; `wheel` has sudo |
| `LUKS_PASSPHRASE` | prompted |
| `LUKS_PBKDF_MEMORY` | `524288` (KiB) |
| `UCODE` | `intel-ucode`; `amd-ucode` on AMD |
| `EXTRA_PACKAGES` | `git`, space-separated, appended to `pacstrap` |
| `TZ` | `US/Central` |
| `LOCALE` | `en_US.UTF-8` |
| `KEYMAP` | `us` |

## Layout

```
nvme0n1p1  1G  vfat  /efi         ESP, GRUB core image and prefix stamp
nvme0n1p2      LUKS2 → btrfs
                @                       container
                @/.snapshots      →  /.snapshots
                @/.snapshots/N/snapshot   the running root, and the btrfs default subvolume
                @/home            →  /home
                @/home/.snapshots
                @/var/log         →  /var/log
                @/var/cache/pacman/pkg
```

The default subvolume is set to a snapshot at install time, so the very first
boot already runs from a snapshot and the first rollback is an ordinary one.

## Change snapper retention

Edit the `set-config` values in `snapper_setup()`, then re-apply in place:

```bash
sudo MNT=/ ./arch-install.sh snapper
sudo snapper --no-dbus -c root get-config
```

`verify` pins the same values, so change both.

## If it will not boot

[RECOVERY.md](RECOVERY.md) — five failure modes, each reproduced in a VM and
recovered with the commands shown: a bad default subvolume, GRUB anchored to a
deleted snapshot, a destroyed kernel, a corrupt `grub.cfg`, and a
`rootflags=subvol=` that boots but silently disables rollback.

Root is locked, so the emergency shell will not open: recovery runs from the
Arch ISO, except the GRUB-prefix case, which is fixable from the `grub rescue>`
prompt with no ISO.

## Test

`test/` boots the installer in a QEMU UEFI VM. See [test/HARNESS.md](test/HARNESS.md).

Put an Arch ISO in `test/`, then:

```bash
./test/vmtest.sh cycle ./some-guest-script.sh    # reset + serve + boot + wait
```

`rollback-test.sh` proves the headline claim on a live install: it snapshots,
destroys `/boot`, rolls back, reboots, and checks the running kernel is the
restored one. It runs in four phases with a reboot between each:

```bash
sudo ./rollback-test.sh phase1   # reboot, then phase2, phase3, phase4
sudo ./rollback-test.sh report
```
