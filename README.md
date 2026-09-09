# arch-install

Unattended Arch installer for the ASUS ExpertBook: LUKS2, btrfs, GRUB, working
`snapper rollback` including the kernel.

Pairs with [nhalm/dotfiles](https://github.com/nhalm/dotfiles), which takes over
after first boot.

## Before you wipe anything

The disk is destroyed. Confirm these are elsewhere:

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

Also: 1Password holds your SSH keys, so make sure you can sign in on another
device. Nothing else on this machine is a credential — no private keys on disk.

## Step by step

**1. Write the ISO** (on another machine, or before wiping)

```bash
curl -fsSLO https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
lsblk                                    # find the USB, e.g. /dev/sdb
sudo dd if=archlinux-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**2. Boot it.** ASUS: `Esc` or `F2` at power-on for the boot menu, pick the USB.
Secure Boot must be off (it already is).

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

Expect `nvme0n1`, ~953G.

**5. Run it.**

```bash
curl -fsSLO https://raw.githubusercontent.com/nhalm/arch-install/main/arch-install.sh
chmod +x arch-install.sh
DISK=/dev/nvme0n1 ./arch-install.sh
```

It prints what it will destroy and asks `[y/N]`, then asks for the LUKS
passphrase twice. One
yay-style PKGBUILD prompt does not appear here — this stage is pacman only.
Takes roughly 5-15 minutes depending on mirrors. Ends with:

```
==> verify: all invariants hold
===INSTALL-DONE rc=0===
```

Anything else, stop and read `/var/log/arch-install.log`.

**6. Reboot, remove the USB.**

```bash
reboot
```

**7. First boot.** GRUB appears, then:

```
Enter passphrase for hd0,gpt2 (...):
Attempting to decrypt master key...
```

**Then roughly ten seconds of nothing.** That is GRUB running argon2id; it has no
progress indicator. Not a hang. Then `Slot "0" opened` and the kernel loads.

Log in as your user at the console.

**8. Network again**, since NetworkManager has no saved connections:

```bash
nmcli device wifi connect <SSID> --ask
```

**9. Dotfiles.**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nhalm/dotfiles/main/bootstrap.sh)
```

**10. Sign in to 1Password** and enable its SSH agent. Nothing can reach GitHub or
sign a commit until this is done — no private key exists on disk by design.

**11. Re-run setup.** Steps needing GitHub or the agent were skipped the first time.

```bash
cd ~/dotfiles && ./setup.sh
```

**12. Check it.**

The installer lived on the ISO's ramdisk, so fetch it again:

```bash
curl -fsSLO https://raw.githubusercontent.com/nhalm/arch-install/main/arch-install.sh
chmod +x arch-install.sh
sudo DISK=/dev/nvme0n1 MNT=/ ./arch-install.sh verify
snapper -c root list
btrfs subvolume get-default /
```

`get-default` must name a `.../N/snapshot` path, not subvolid 5.

## Environment variables

| Variable | Default |
|---|---|
| `DISK` | required |
| `CONFIRM` | prompts; `yes` skips the prompt |
| `TARGET_HOSTNAME` | `asus` |
| `USERNAME` | `nick` |
| `TZ` | `US/Central` |
| `LOCALE` | `en_US.UTF-8` |
| `KEYMAP` | `us` |
| `LUKS_PASSPHRASE` | prompted |
| `LUKS_PBKDF_MEMORY` | `524288` |

`/dev/vda` in a VM.

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
