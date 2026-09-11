#!/usr/bin/env bash
# Tier 3: break the install in each documented way, confirm it genuinely fails,
# then recover it. Run from the guest -- `break` phases from the booted system,
# `rescue` phases from the Arch ISO with the disk attached.
#
#   ./recovery-scenarios.sh break <n>     # from the booted system, then reboot
#   ./recovery-scenarios.sh rescue <n>    # from the ISO
#   ./recovery-scenarios.sh check         # after recovery, from the booted system
#
# Scenario numbers match RECOVERY.md sections where they exist. 6 and 7 are new
# and exist because of the swap partition.
set -euo pipefail

DISK="${DISK:-/dev/vda}"
P=""; case "$DISK" in *nvme*|*mmcblk*|*loop*) P=p ;; esac
CRYPT="${DISK}${P}2"
SWAPCRYPT="${DISK}${P}3"
PASS="${LUKS_PASSPHRASE:-vmtestluks}"
STATE=/var/log/recovery-scenario.state

msg() { printf '==> %s\n' "$*"; }
die() { printf '==> ERROR: %s\n' "$*" >&2; exit 1; }

# --- breaks, run from the booted system ------------------------------------
break_2() {  # RECOVERY.md §2 -- bad default subvolume
  msg "setting default subvolume to 5 (expect: emergency mode, locked root)"
  btrfs subvolume set-default 5 /
  btrfs subvolume get-default /
}

break_3() {  # §3 -- GRUB anchored to a deleted snapshot
  msg "creating a decoy subvolume, pointing GRUB at it, then deleting it"
  mkdir -p /.snapshots/99
  btrfs subvolume snapshot / /.snapshots/99/snapshot
  grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB \
    --boot-directory=/.snapshots/99/snapshot/boot
  grub-install --target=x86_64-efi --efi-directory=/efi --removable \
    --boot-directory=/.snapshots/99/snapshot/boot
  systemctl disable grub-boot-sync.service
  mv /usr/lib/snapper/plugins/10-grub /root/10-grub.disabled
  btrfs subvolume delete /.snapshots/99/snapshot
  msg "prefix now names a deleted subvolume; expect grub rescue>"
}

break_4() {  # §4 -- destroyed kernel and initramfs
  msg "destroying the kernel and BOTH initramfs images"
  dd if=/dev/urandom of=/boot/vmlinuz-linux bs=1M count=4 conv=notrunc status=none
  dd if=/dev/urandom of=/boot/initramfs-linux.img bs=1M count=8 conv=notrunc status=none
  sync
}

break_5() {  # §5 -- corrupt grub.cfg
  msg "corrupting grub.cfg (expect a bare grub> prompt)"
  printf 'this is not a grub config\n' > /boot/grub/grub.cfg
  sync
}

break_6() {  # §6 -- rootflags=subvol= reintroduced
  msg "regenerating grub.cfg with stock grub-mkconfig (reintroduces rootflags=)"
  grub-mkconfig -o /boot/grub/grub.cfg
  grep -c 'rootflags=subvol=' /boot/grub/grub.cfg || true
  msg "expect: boots, but runs a subvolume that is not the default"
}

break_7() {  # NEW -- swap LUKS header destroyed
  msg "destroying the swap container's LUKS header"
  swapoff -a || true
  cryptsetup close swap 2>/dev/null || true
  dd if=/dev/urandom of="$SWAPCRYPT" bs=1M count=4 conv=notrunc status=none
  sync
  msg "expect: boots fine, no swap, hibernate unavailable -- degraded, not dead"
}

break_8() {  # NEW -- hibernate, then roll back underneath the image
  # The hazard that does not exist without rollback: the image is a snapshot of
  # RAM including the kernel's cached view of the filesystem, and rollback moves
  # the filesystem. This writes a marker, hibernates, and leaves the machine
  # powered off with a live image in swap. rescue_8 then rolls back.
  local snap
  snap=$(snapper --no-dbus -c root list --columns number | tr -d ' ' |
         grep -E '^[0-9]+$' | sort -n | head -1)
  printf 'PRE-HIBERNATE\n' > /root/rollback-marker
  sync
  cat > "$STATE" <<EOF
ROLLBACK_TARGET=$snap
BOOTID=$(cat /proc/sys/kernel/random/boot_id)
SUBVOL_BEFORE=$(btrfs subvolume get-default / | awk '{print $NF}')
EOF
  sync
  msg "hibernating with an image live; rollback target is snapshot $snap"
  systemctl hibernate
  die "hibernate did not power the machine off"
}

# --- rescues, run from the Arch ISO ----------------------------------------
open_disk() {
  printf '%s' "$PASS" | cryptsetup open --key-file - "$CRYPT" root
  mount -o subvolid=5 /dev/mapper/root /mnt
}
close_disk() {
  umount -R /mnt 2>/dev/null || true
  cryptsetup close root 2>/dev/null || true
}

rescue_2() {
  open_disk
  local target
  target=$(btrfs subvolume list /mnt | awk '{print $NF}' |
           grep -E '^@/\.snapshots/[0-9]+/snapshot$' | sort -t/ -k3 -n | tail -1)
  msg "restoring default subvolume to $target"
  [[ -x /mnt/$target/usr/lib/systemd/systemd ]] || die "$target has no init; wrong target"
  btrfs subvolume set-default "/mnt/$target"
  btrfs subvolume get-default /mnt
  close_disk
}

rescue_8() {
  # Roll the default subvolume back while a hibernation image is sitting in
  # swap, then let the machine boot and try to resume onto it.
  open_disk
  local target
  target=$(btrfs subvolume list /mnt | awk '{print $NF}' |
           grep -E '^@/\.snapshots/[0-9]+/snapshot$' | sort -t/ -k3 -n | head -1)
  msg "rolling default subvolume back to $target while an image is live in swap"
  btrfs subvolume set-default "/mnt/$target"
  btrfs subvolume get-default /mnt
  close_disk
  msg "now boot normally and observe whether the kernel resumes the stale image"
}

case "${1:-}" in
  break)  "break_${2:?scenario number}" ;;
  rescue) "rescue_${2:?scenario number}" ;;
  check)  DISK=$DISK bash /root/arch-install.sh verify ;;
  *) die "usage: $0 break|rescue <n> | check" ;;
esac
