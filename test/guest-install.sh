#!/usr/bin/env bash
# Guest script for `vmtest.sh cycle`. Runs a full install on /dev/vda, then
# verifies it. The VM has 4G RAM, so swap is sized for that, not for the laptop:
# 6 GiB clears MemTotal * 35/32 (~4.4 GiB worst-case compressed image) with room
# for paging. 40 GiB would not fit on the 20G test disk at all -- partition()
# dies with "does not fit", which is itself worth seeing once.
set -euo pipefail

: "${DISK:=/dev/vda}"
: "${SWAP_SIZE_GIB:=6}"
: "${LUKS_PASSPHRASE:=vmtestluks}"
: "${USER_PASSWORD:=vmtestuser}"
: "${TARGET_HOSTNAME:=archvm}"
export DISK SWAP_SIZE_GIB LUKS_PASSPHRASE USER_PASSWORD TARGET_HOSTNAME
export CONFIRM=yes

cd /root
curl -fsSL -o arch-install.sh "${INSTALLER_URL:-http://10.0.2.2:8123/arch-install.sh}"
chmod +x arch-install.sh
md5sum arch-install.sh

./arch-install.sh install

echo "=== re-verify against the unmounted install ==="
./arch-install.sh verify

echo "=== layout as installed ==="
lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL "$DISK"

# --- TEST-ONLY: make the installed system reachable over the serial port ------
# Real hardware has a screen; this VM does not. The installer deliberately does
# not configure a serial console, so without this the machine boots into total
# silence and nothing after this point can be observed or driven. Everything
# below touches only console plumbing -- no swap, no sleep policy, no verify
# invariant. GRUB's own passphrase prompt still goes to the EFI console and is
# answered with `vmtest.sh key`, not by this.
echo "=== enabling serial console on the installed system (test only) ==="
MOPTS=rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2
printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open --key-file - "${DISK}2" root
d=$(mount -o "$MOPTS,subvolid=5" /dev/mapper/root /mnt && \
    btrfs subvolume get-default /mnt | awk '{print $NF}')
umount /mnt
mount -o "$MOPTS,subvol=$d" /dev/mapper/root /mnt
for s in home var/log var/cache/pacman/pkg; do
  mount -o "$MOPTS,subvol=@/$s" --mkdir /dev/mapper/root "/mnt/$s"
done
mount -o "$MOPTS,subvol=@/.snapshots" --mkdir /dev/mapper/root /mnt/.snapshots
mount -o fmask=0077,dmask=0077 --mkdir "${DISK}1" /mnt/efi

sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT="|GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200 |' \
  /mnt/etc/default/grub
grep GRUB_CMDLINE_LINUX_DEFAULT /mnt/etc/default/grub
arch-chroot /mnt systemctl enable serial-getty@ttyS0.service
arch-chroot /mnt /usr/local/bin/grub-sync
grep -c 'console=ttyS0' /mnt/boot/grub/grub.cfg

umount -R /mnt
cryptsetup close swap 2>/dev/null || true
cryptsetup close root
echo "=== serial console enabled; the installed disk is now drivable ==="
