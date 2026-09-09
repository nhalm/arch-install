#!/usr/bin/env bash
# Rollback test for arch-install-v2 (GRUB cryptodisk, /boot inside the root
# snapshot, openSUSE-style @/.snapshots/<N>/snapshot layout).
#
# The point of v2 is that `snapper rollback` restores the kernel and initramfs
# together with the OS. So this test damages /boot after the snapshot and then
# proves the restored kernel is the one that actually booted.
#
#   phase1 -> reboot -> phase2 -> reboot -> phase3 -> reboot -> phase4
set -euo pipefail

STATE=/var/log/rollback-test-v2.state
MARKER=/root/rt-marker
EXTRA=/root/rt-extra
DELME=/root/rt-delme
BOOTMARK=/boot/RT-POST-SNAP
PHASE="${1:-}"

msg()  { printf '==> %s\n' "$*"; }
die()  { printf '==> ERROR: %s\n' "$*" >&2; exit 1; }
want() { [[ $2 == "$3" ]] || die "$1: want '$3', got '$2'"; }

src_of()  { findmnt -no SOURCE "$1"; }
dev_of()  { local s; s=$(src_of "$1"); printf '%s' "${s%%[*}"; }
sub_of()  { local s; s=$(src_of "$1"); s=${s#*[}; printf '%s' "${s%]}"; }
default_sub() { btrfs subvolume get-default / | awk '{print $NF}'; }
subvol_id()   { btrfs subvolume show "$1" | awk -F: '/Subvolume ID:/{gsub(/[[:space:]]/,"",$2); print $2}'; }
snap_count()  { find /.snapshots -maxdepth 1 -mindepth 1 -regextype posix-extended -regex '.*/[0-9]+' | wc -l; }

# Tag every kernel line in the live grub.cfg so /proc/cmdline says which
# grub.cfg was actually read at boot. Without this a stale GRUB prefix that
# still resolves is indistinguishable from a correctly re-pointed one.
stamp_cfg() {
  local tok=$1
  sed -i -E "s/^([[:space:]]*linux[[:space:]]+\/.*)$/\1 rt=$tok/" /boot/grub/grub.cfg
  sed -i -E "s/ rt=[A-Za-z0-9]+ rt=$tok/ rt=$tok/" /boot/grub/grub.cfg
  grep -c "rt=$tok" /boot/grub/grub.cfg
}
cmdline_tok() { sed -n 's/.*\brt=\([A-Za-z0-9]*\).*/\1/p' /proc/cmdline; }

preflight() {
  (( EUID == 0 )) || die "must run as root"
  DEV=$(dev_of /)
  local rs; rs=$(sub_of /)
  [[ $rs =~ ^/@/\.snapshots/[0-9]+/snapshot$ ]] || die "root subvol is not a snapshot: $rs"
  want "root is the default subvolume" "${rs#/}" "$(default_sub)"
  want ".snapshots subvolume" "$(src_of /.snapshots)" "$DEV[/@/.snapshots]"
  want "/boot on btrfs"  "$(findmnt -no FSTYPE -T /boot/vmlinuz-linux)" "btrfs"
  want "/boot inside root subvol" "$(findmnt -no SOURCE -T /boot/vmlinuz-linux)" "$DEV[$rs]"
  [[ -f /etc/snapper/configs/root ]] || die "no snapper root config"
}

report() {
  msg "root subvol : $(sub_of /)   (default $(default_sub))"
  msg "grub stamp  : $(cat /efi/EFI/GRUB/root-subvol 2>/dev/null || echo MISSING)"
  msg "kernel      : $(uname -r)   cmdline token: $(cmdline_tok)"
  msg "grub prefix : $(strings /efi/EFI/GRUB/grubx64.efi | grep -m1 '^/@')"
  msg "snapshots   : $(snapper --no-dbus -c root list --columns number,type,description 2>/dev/null | tr '\n' '|')"
}

phase1() {
  preflight
  report
  local token snap oldsub

  token=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)
  TOKA="A$token"; TOKB="B$token"
  msg "stamping the pre-snapshot grub.cfg with $TOKA"
  stamp_cfg "$TOKA"

  printf '%s\n' "$token" > "$MARKER"
  printf '%s\n' "$token" > "$DELME"
  rm -f "$EXTRA" "$BOOTMARK"
  sync

  KSHA=$(sha256sum /boot/vmlinuz-linux | awk '{print $1}')
  ISHA=$(sha256sum /boot/initramfs-linux.img | awk '{print $1}')
  KREL=$(uname -r)
  oldsub=$(sub_of /)

  snap=$(snapper --no-dbus -c root create -p -d "rollback-test-v2 $token")
  [[ $snap =~ ^[0-9]+$ ]] || die "snapper create did not return a number: $snap"
  msg "snapshot $snap"
  want "marker inside snapshot" "$(cat "/.snapshots/$snap/snapshot$MARKER")" "$token"
  want "kernel inside snapshot" "$(sha256sum "/.snapshots/$snap/snapshot/boot/vmlinuz-linux" | awk '{print $1}')" "$KSHA"

  cat > "$STATE" <<EOF
TOKEN=$token
TOKA=$TOKA
TOKB=$TOKB
SNAP=$snap
KSHA=$KSHA
ISHA=$ISHA
KREL=$KREL
OLDSUB=$oldsub
OLDCOUNT=$(snap_count)
BOOTID=$(cat /proc/sys/kernel/random/boot_id)
EOF
  sync

  msg "damaging the live root and /boot"
  printf 'CORRUPTED\n' > "$MARKER"
  rm -f "$DELME"
  printf 'should not survive the rollback\n' > "$EXTRA"
  printf 'post-snapshot\n' > "$BOOTMARK"
  stamp_cfg "$TOKB"
  # break both boot images: if the rollback does not restore /boot, or GRUB
  # keeps reading the old subvolume, the machine cannot come back up.
  dd if=/dev/urandom of=/boot/initramfs-linux.img bs=1M count=8 conv=notrunc status=none
  dd if=/dev/urandom of=/boot/vmlinuz-linux bs=1M count=4 conv=notrunc status=none
  sync
  msg "damaged kernel sha: $(sha256sum /boot/vmlinuz-linux | awk '{print $1}')"

  msg "snapper rollback $snap"
  snapper --no-dbus -c root rollback "$snap"
  echo "NEWDEFAULT=$(default_sub)" >> "$STATE"
  sync
  report
  msg "phase1 done: reboot, then run '$0 phase2'"
}

phase2() {
  [[ -f $STATE ]] || die "no $STATE; run phase1 first"
  # shellcheck source=/dev/null
  . "$STATE"
  preflight
  report
  [[ $(cat /proc/sys/kernel/random/boot_id) != "$BOOTID" ]] || die "no reboot between phase1 and phase2"

  local newsub
  newsub=$(sub_of /)
  [[ $newsub != "$OLDSUB" ]] || die "root subvolume unchanged ($newsub): the rollback did not happen"

  want "booted grub.cfg token" "$(cmdline_tok)" "$TOKA"
  want "restored marker"       "$(cat "$MARKER" 2>/dev/null || echo MISSING)" "$TOKEN"
  want "restored deleted file" "$(cat "$DELME"  2>/dev/null || echo MISSING)" "$TOKEN"
  [[ ! -e $EXTRA ]]    || die "post-snapshot file survived the rollback: $EXTRA"
  [[ ! -e $BOOTMARK ]] || die "post-snapshot /boot file survived the rollback: $BOOTMARK"

  want "restored kernel sha"    "$(sha256sum /boot/vmlinuz-linux      | awk '{print $1}')" "$KSHA"
  want "restored initramfs sha" "$(sha256sum /boot/initramfs-linux.img | awk '{print $1}')" "$ISHA"
  want "running kernel release" "$(uname -r)" "$KREL"
  [[ -d /usr/lib/modules/$(uname -r) ]] || die "no /usr/lib/modules/$(uname -r) for the running kernel"
  modprobe -n loop >/dev/null 2>&1 || die "modprobe cannot resolve a module for the running kernel"

  want "grub prefix stamp" "$(cat /efi/EFI/GRUB/root-subvol)" "${newsub#/}"
  grep -q "${newsub#/}/boot/vmlinuz-linux" /boot/grub/grub.cfg ||
    die "grub.cfg does not point at the current subvolume ${newsub#/}"
  grep -q 'rootflags=subvol=' /boot/grub/grub.cfg && die "rootflags=subvol= is back in grub.cfg"
  strings /efi/EFI/GRUB/grubx64.efi | grep -q "${newsub#/}/boot/grub" ||
    die "core image prefix does not name ${newsub#/}"

  [[ -d /.snapshots/$SNAP/snapshot ]] || die "snapshot $SNAP missing"
  snapper --no-dbus -c root list --columns number | tr -d ' ' | grep -qx "$SNAP" ||
    die "snapper does not list snapshot $SNAP"

  msg "PHASE2 OK: rolled back across a broken kernel and booted the restored one"

  # ---- second rollback, back to the very first (install-time) snapshot ----
  local first
  first=$(snapper --no-dbus -c root list --columns number | tr -d ' ' | grep -E '^[0-9]+$' | sort -n | head -1)
  msg "second rollback, target $first"
  printf '%s\n' "second-$TOKEN" > "$MARKER"
  sync
  snapper --no-dbus -c root rollback "$first"
  cat >> "$STATE" <<EOF
BOOTID2=$(cat /proc/sys/kernel/random/boot_id)
SUB2=$newsub
FIRST=$first
DEFAULT2=$(default_sub)
EOF
  sync
  report
  msg "phase2 done: reboot, then run '$0 phase3'"
}

phase3() {
  # shellcheck source=/dev/null
  . "$STATE"
  preflight
  report
  [[ $(cat /proc/sys/kernel/random/boot_id) != "$BOOTID2" ]] || die "no reboot between phase2 and phase3"
  local sub3; sub3=$(sub_of /)
  [[ $sub3 != "$SUB2" ]] || die "second rollback did not move the root subvolume"
  want "grub prefix stamp" "$(cat /efi/EFI/GRUB/root-subvol)" "${sub3#/}"
  [[ -s /boot/vmlinuz-linux ]] || die "no kernel in the restored /boot"
  want "kernel sha after second rollback" "$(sha256sum /boot/vmlinuz-linux | awk '{print $1}')" "$KSHA"
  msg "PHASE3 OK: booted after a second rollback"

  # ---- delete the snapshot GRUB used to be anchored to, then reboot ----
  msg "snapshots before cleanup:"; snapper --no-dbus -c root list
  local cur n
  cur=${sub3#/@/.snapshots/}; cur=${cur%/snapshot}
  for n in $(snapper --no-dbus -c root list --columns number | tr -d ' ' | grep -E '^[0-9]+$'); do
    [[ $n == "$cur" ]] && continue
    msg "deleting snapshot $n"
    snapper --no-dbus -c root delete "$n" || msg "delete $n failed (in use?)"
  done
  msg "snapshots after cleanup:"; snapper --no-dbus -c root list
  btrfs subvolume list -t /
  cat >> "$STATE" <<EOF
BOOTID3=$(cat /proc/sys/kernel/random/boot_id)
SUB3=$sub3
EOF
  sync
  msg "phase3 done: reboot, then run '$0 phase4'"
}

phase4() {
  # shellcheck source=/dev/null
  . "$STATE"
  preflight
  report
  [[ $(cat /proc/sys/kernel/random/boot_id) != "$BOOTID3" ]] || die "no reboot between phase3 and phase4"
  want "root subvol survived cleanup" "$(sub_of /)" "$SUB3"
  want "kernel sha" "$(sha256sum /boot/vmlinuz-linux | awk '{print $1}')" "$KSHA"
  systemctl is-system-running --wait >/dev/null 2>&1 || msg "systemd degraded: $(systemctl is-system-running)"
  msg "PHASE4 OK: still boots after snapshot cleanup deleted the old snapshots"
}

sentinel() {
  local rc=$1 d
  for d in /dev/console /dev/ttyS0; do
    [[ -w $d ]] && printf '===ROLLBACK-TEST rc=%d===\n' "$rc" >"$d" 2>/dev/null || true
  done
  printf '===ROLLBACK-TEST rc=%d===\n' "$rc"
  return 0
}

DEV=""; TOKA=""; TOKB=""; KSHA=""; ISHA=""; KREL=""
trap 'sentinel "$?"' EXIT

case "$PHASE" in
  phase1) phase1 ;;
  phase2) phase2 ;;
  phase3) phase3 ;;
  phase4) phase4 ;;
  report) preflight; report ;;
  *) die "usage: $0 phase1|phase2|phase3|phase4|report" ;;
esac
