# arch-install

Unattended Arch installer for the ASUS ExpertBook: LUKS2, btrfs, GRUB, working
`snapper rollback` including the kernel.

Pairs with [nhalm/dotfiles](https://github.com/nhalm/dotfiles), which takes over
after first boot.

## Run

From the Arch ISO:

```bash
curl -fsSLO https://raw.githubusercontent.com/nhalm/arch-install/main/arch-install.sh
chmod +x arch-install.sh
DISK=/dev/nvme0n1 CONFIRM=yes ./arch-install.sh
```

`/dev/vda` in a VM. Passphrase is prompted, or `LUKS_PASSPHRASE` for unattended.

| Variable | Default |
|---|---|
| `DISK` | required |
| `CONFIRM` | `no` — must be `yes` |
| `TARGET_HOSTNAME` | `asus` |
| `USERNAME` | `nick` |
| `TZ` | `US/Central` |
| `LOCALE` | `en_US.UTF-8` |
| `KEYMAP` | `us` |
| `LUKS_PASSPHRASE` | prompted |
| `LUKS_PBKDF_MEMORY` | `524288` |

Then:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nhalm/dotfiles/main/bootstrap.sh)
```

## Layout

```
/dev/DISK1  1G  vfat  /efi        ESP, GRUB binary only
/dev/DISK2      LUKS2 → btrfs
                @                      container
                @/.snapshots     →  /.snapshots
                @/home           →  /home
                @/var/log        →  /var/log
                @/var/cache/pacman/pkg
```

Root boots from the btrfs **default subvolume**, which is set to a snapshot at
install. `/boot` is an ordinary directory inside the snapshot, so the kernel and
initramfs roll back with everything else.

## Rollback

```bash
snapper --ambit=classic -c root rollback N   # first time
snapper -c root rollback N                   # thereafter
reboot
```

`snapper rollback N` and bare `snapper rollback` differ — the no-arg form commits
what you are running now. Always pass the number.

## Verify

```bash
DISK=/dev/nvme0n1 MNT=/ ./arch-install.sh verify
```

## Test

`test/` boots the installer in a QEMU UEFI VM. See `test/HARNESS.md`.

```bash
cd test && VM=$PWD ./vmtest.sh reset && ./vmtest.sh boot <url>
```
