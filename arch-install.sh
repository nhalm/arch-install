#!/usr/bin/env bash
# Unattended Arch install, variant 2: LUKS2 + btrfs + snapper + GRUB with
# GRUB_ENABLE_CRYPTODISK. /boot lives inside the root subvolume and root is
# mounted through the btrfs default subvolume, so `snapper rollback` restores
# kernel and initramfs along with the OS.
# A third partition holds LUKS2-encrypted swap sized for hibernation, so
# suspend-then-hibernate works and the image lands inside encryption.
# Env: DISK (required) TARGET_HOSTNAME USERNAME TZ LOCALE KEYMAP UCODE
#      EXTRA_PACKAGES CONFIRM LUKS_PASSPHRASE USER_PASSWORD ROOT_PASSWORD
#      LUKS_PBKDF_MEMORY LUKS_PBKDF_ITERATIONS LUKS_PBKDF_PARALLEL SWAP_SIZE_GIB
#      HIBERNATE_DELAY
# Usage: DISK=/dev/vda ./arch-install.sh [install|verify]   (CONFIRM=yes to skip the prompt)
#        MNT=/ ./arch-install.sh snapper                   (re-apply snapper config in place)
#        MNT=/ ./arch-install.sh power                     (re-apply sleep policy in place)
set -euo pipefail

if [[ ${HOSTNAME:-} == "$(uname -n)" ]]; then unset HOSTNAME; fi
MODE="${1:-install}"
if [[ $MODE == snapper || $MODE == power ]]; then DISK="${DISK-}"
else DISK="${DISK:?set DISK, e.g. /dev/vda or /dev/nvme0n1}"; fi
HOSTNAME="${TARGET_HOSTNAME:-${HOSTNAME:-asus}}"
USERNAME="${USERNAME:-nick}"
TZ="${TZ:-US/Central}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"
UCODE="${UCODE:-intel-ucode}"
EXTRA_PACKAGES="${EXTRA_PACKAGES-git}"
CONFIRM="${CONFIRM:-no}"   # yes = skip the prompt
# cryptsetup calibrates iterations to a ~2 s target using every thread and SIMD;
# GRUB's argon2 is scalar and single-threaded, so that 2 s becomes ~10 s at the
# boot prompt. Lowering memory alone does nothing -- the benchmark simply raises
# iterations to hit the same target, leaving identical wall time with less
# memory-hardness. Forcing iterations bypasses the benchmark. t=4 is the
# documented floor, and m=512Mi with t=4 is exactly RFC 9106's first recommended
# option: ~5x less work than the benchmark picks, at a standard security level.
# All three must be passed together or cryptsetup benchmarks anyway.
LUKS_PBKDF_MEMORY="${LUKS_PBKDF_MEMORY-524288}"
LUKS_PBKDF_ITERATIONS="${LUKS_PBKDF_ITERATIONS-4}"
LUKS_PBKDF_PARALLEL="${LUKS_PBKDF_PARALLEL-4}"
# >= MemTotal * 35/32: kernel/power/swap.c bytes_worst_compress() lets the
# compressed image EXPAND by 9%, so "swap = RAM" undershoots. Plus headroom for
# live paging now that zswap writes back here and this is the only swap area.
SWAP_SIZE_GIB="${SWAP_SIZE_GIB:-40}"
# Time spent suspended before escalating to hibernate. Counts from the moment
# the machine suspends, not from when it went idle.
HIBERNATE_DELAY="${HIBERNATE_DELAY:-30min}"

MNT="${MNT:-/mnt}"
MNT="${MNT%/}"
LOG=/tmp/arch-install.log
MAPPER=root
DEV=/dev/mapper/$MAPPER
MOPTS=rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2
ESP_GUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
LUKS_GUID=CA7D7CCB-63ED-4C53-861C-1742536059CC
KEYFILE=/etc/cryptsetup-keys.d/root.key
SWAPKEY=/etc/cryptsetup-keys.d/swap.key
SWAPMAPPER=swap
SWAPDEV=/dev/mapper/$SWAPMAPPER
NESTED=(home var/log var/cache/pacman/pkg)
SNAPNUM=
SNAPSUB=

case "$DISK" in *nvme*|*mmcblk*|*loop*) P=p ;; *) P= ;; esac
ESP="${DISK}${P}1"
CRYPT="${DISK}${P}2"
SWAPCRYPT="${DISK}${P}3"

msg()  { printf '==> %s\n' "$*"; }
warn() { printf '==> WARNING: %s\n' "$*" >&2; }
die()  { printf '==> ERROR: %s\n' "$*" >&2; exit 1; }

read_secret() {
  local var=$1 prompt=$2 a b
  if [[ -n ${!var:-} ]]; then return 0; fi
  [[ -t 0 || -e /dev/tty ]] || die "$var unset and no tty to prompt on"
  while :; do
    read -rsp "$prompt: " a </dev/tty; echo >&2
    read -rsp "$prompt (again): " b </dev/tty; echo >&2
    [[ -n $a && $a == "$b" ]] && break
    warn "empty or mismatched, try again"
  done
  printf -v "$var" '%s' "$a"
}

# Run a command inside the target. When verifying the running system there is
# no chroot to enter.
target() {
  if [[ -z $MNT ]]; then "$@"; else arch-chroot "$MNT" "$@"; fi
}

wait_for() {
  local i
  for i in $(seq 1 60); do
    [[ -b $1 ]] && return 0
    sleep 0.25
  done
  die "device did not appear: $1"
}

preflight() {
  case $MODE in install | verify | snapper | power) ;; *) die "unknown mode: $MODE (install|verify|snapper|power)" ;; esac
  (( EUID == 0 )) || die "must run as root"
  [[ -d /sys/firmware/efi/efivars ]] || die "not booted in UEFI mode"
  if [[ ( $MODE == snapper || $MODE == power ) && -n $MNT ]]; then
    findmnt -M "$MNT" >/dev/null ||
      die "$MODE: MNT=$MNT is not mounted; use MNT=/ to re-apply on the running system"
  fi
  # The installed system has none of the install-time tooling (gptfdisk,
  # arch-install-scripts, dosfstools), so `verify` and `snapper` must not demand it.
  local t tools=(cryptsetup btrfs blkid lsblk findmnt)
  if [[ $MODE == install ]]; then
    tools+=(sgdisk mkfs.btrfs mkfs.fat pacstrap arch-chroot genfstab partprobe udevadm)
  elif [[ -n $MNT ]]; then
    tools+=(arch-chroot)
  elif [[ $MODE == snapper ]]; then
    tools+=(snapper systemctl)
  elif [[ $MODE == power ]]; then
    tools+=(systemctl)
  fi
  for t in "${tools[@]}"; do
    command -v "$t" >/dev/null || die "missing tool: $t"
  done
  [[ $MODE == snapper || $MODE == power ]] && return 0
  [[ -b $DISK ]] || die "DISK=$DISK is not a block device"
  [[ $(lsblk -dno TYPE "$DISK") == disk ]] || die "DISK=$DISK is not a whole disk"

  if [[ $MODE == install ]]; then
    local mounted sw
    mounted=$(lsblk -nro MOUNTPOINT "$DISK" | grep -c . || true)
    (( mounted == 0 )) || die "refusing: something on $DISK is mounted (live device?)"
    while read -r sw; do
      [[ -n $sw && $sw == /dev/* ]] || continue
      if lsblk -nro NAME "$DISK" | grep -qx "$(basename "$sw")"; then
        die "refusing: swap active on $DISK ($sw)"
      fi
    done < <(swapon --noheadings --show=NAME 2>/dev/null || true)
  fi

  local memkb
  memkb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  (( memkb >= 3500000 )) || warn "under 4G RAM: cryptsetup may silently weaken argon2id"

  # Refuse a swap that cannot hold the image BEFORE sgdisk --zap-all, not at the
  # first post-boot verify. The same arithmetic lives in verify(), but that runs
  # only with MNT empty -- so on a machine with more RAM than SWAP_SIZE_GIB
  # allows for, the install would complete cleanly, encrypt the whole disk, and
  # surface the problem when the only remaining fix is a reinstall.
  if [[ $MODE == install ]]; then
    local needgib
    needgib=$(( (memkb * 35 / 32 + 1048575) / 1048576 ))
    (( SWAP_SIZE_GIB >= needgib )) ||
      die "SWAP_SIZE_GIB=$SWAP_SIZE_GIB is too small for $(( memkb / 1048576 ))G of RAM:
    a hibernation image can EXPAND to MemTotal * 35/32 (kernel/power/swap.c
    bytes_worst_compress), so this machine needs >= ${needgib}G. Set
    SWAP_SIZE_GIB=$needgib or higher."
  fi
}

banner() {
  msg "DISK=$DISK ESP=$ESP CRYPT=$CRYPT SWAP=$SWAPCRYPT (${SWAP_SIZE_GIB}GiB)"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL "$DISK" || true
  cat <<EOF

  DESTRUCTIVE: every partition, filesystem and byte of data on
  $DISK will be erased.

  target: hostname=$HOSTNAME user=$USERNAME tz=$TZ locale=$LOCALE keymap=$KEYMAP ucode=$UCODE
  layout: GRUB cryptodisk, /boot inside the root subvolume, root via default subvolume

EOF
  [[ $CONFIRM == yes ]] && return 0
  [[ -e /dev/tty ]] || die "not a terminal and CONFIRM=yes not set"
  local reply
  read -r -p "  Erase $DISK and install? [y/N] " reply </dev/tty
  case $reply in
  [yY] | [yY][eE][sS]) ;;
  *) die "aborted" ;;
  esac
}

partition() {
  msg "partitioning $DISK"
  sgdisk --zap-all "$DISK"
  sgdisk -n1:1MiB:+1GiB -t1:"$ESP_GUID"  -c1:ESP       "$DISK"
  # luksFormat --sector-size 4096 refuses a device whose size is not a multiple
  # of 4096; GPT's 33-sector backup table leaves the last usable LBA off a
  # 4096-byte boundary, so round both container ends down. Starts are already
  # 2048-sector aligned by sgdisk, a multiple of the 4096 grain.
  local lss grain last end2 end3
  lss=$(lsblk -dno LOG-SEC "$DISK")
  grain=$(( 4096 / lss )); (( grain >= 1 )) || grain=1
  last=$(sgdisk -E "$DISK")
  end3=$(( last - ( (last + 1) % grain ) ))
  end2=$(( end3 - SWAP_SIZE_GIB * 1024 * 1024 * 1024 / lss ))
  end2=$(( end2 - ( (end2 + 1) % grain ) ))
  (( end2 > 0 )) || die "SWAP_SIZE_GIB=$SWAP_SIZE_GIB does not fit on $DISK"
  sgdisk -n2:0:"$end2"  -t2:"$LUKS_GUID" -c2:cryptroot "$DISK"
  sgdisk -n3:0:"$end3"  -t3:"$LUKS_GUID" -c3:cryptswap "$DISK"
  partprobe "$DISK"
  udevadm settle
  wait_for "$ESP"
  wait_for "$CRYPT"
  wait_for "$SWAPCRYPT"
  lsblk -o NAME,SIZE,TYPE,PARTTYPENAME "$DISK"
}

# All three of memory/iterations/parallel, or cryptsetup benchmarks anyway and
# the forced iteration count is ignored. See the LUKS_PBKDF_* comment above.
pbkdf_args() {
  local a=()
  [[ -n $LUKS_PBKDF_MEMORY ]] && a+=(--pbkdf-memory "$LUKS_PBKDF_MEMORY")
  if [[ -n $LUKS_PBKDF_ITERATIONS ]]; then
    a+=(--pbkdf argon2id
        --pbkdf-force-iterations "$LUKS_PBKDF_ITERATIONS"
        --pbkdf-parallel "$LUKS_PBKDF_PARALLEL")
  fi
  # Guard the printf: with both LUKS_PBKDF_* set empty -- the documented way to
  # opt out, which is why the [[ -n ]] tests above exist -- the array is empty
  # and `printf '%s\n' "${a[@]}"` still runs the format once, emitting a bare
  # newline. mapfile turns that into a one-element array holding "", which
  # cryptsetup then takes as a positional argument and luksFormat fails on a
  # confusing "wrong number of arguments" rather than anything pointing here.
  (( ${#a[@]} )) && printf '%s\n' "${a[@]}"
  return 0
}

luks() {
  local pbkdf=()
  mapfile -t pbkdf < <(pbkdf_args)
  msg "luksFormat $CRYPT ${pbkdf[*]:-}"
  printf '%s' "$LUKS_PASSPHRASE" |
    cryptsetup luksFormat --type luks2 --sector-size 4096 "${pbkdf[@]}" \
      --batch-mode --key-file - "$CRYPT"
  msg "opening $CRYPT as $MAPPER"
  printf '%s' "$LUKS_PASSPHRASE" |
    cryptsetup --allow-discards --persistent open --key-file - "$CRYPT" "$MAPPER"
  wait_for "$DEV"
  cryptsetup luksDump "$CRYPT" | grep -E 'Flags|sector|Cipher key|PBKDF|Memory' || true
}

filesystems() {
  msg "mkfs"
  mkfs.btrfs -L arch "$DEV"
  mkfs.fat -F32 -n ESP "$ESP"
}

subvolumes() {
  msg "creating subvolumes"
  mount "$DEV" "$MNT"
  btrfs subvolume create "$MNT/@"
  mkdir -p "$MNT/@/var/cache/pacman"
  local s
  for s in "${NESTED[@]}"; do btrfs subvolume create "$MNT/@/$s"; done
  btrfs subvolume list -t "$MNT"
  umount "$MNT"
}

mount_snapshots() {
  mount -o "$MOPTS,subvol=@/.snapshots" --mkdir "$DEV" "$MNT/.snapshots"
  chmod 750 "$MNT/.snapshots"
}

mount_tree() {
  local rootsub=$1 with_snap=${2:-} s
  msg "mounting root subvol=$rootsub"
  mount -o "$MOPTS,subvol=$rootsub" "$DEV" "$MNT"
  for s in "${NESTED[@]}"; do
    mount -o "$MOPTS,subvol=@/$s" --mkdir "$DEV" "$MNT/$s"
  done
  if [[ -n $with_snap ]]; then mount_snapshots; fi
  mount -o fmask=0077,dmask=0077 --mkdir "$ESP" "$MNT/efi"
  findmnt -R "$MNT" -o TARGET,SOURCE,FSTYPE
}

install_base() {
  timedatectl set-ntp true 2>/dev/null || true
  if command -v systemctl >/dev/null && systemctl list-unit-files reflector.service &>/dev/null; then
    msg "waiting for reflector"
    timeout 180 bash -c 'while systemctl is-active --quiet reflector.service; do sleep 2; done' || true
  fi
  # No zram-generator: zram is inert at 32G, inverts the LRU next to a real swap
  # area (nothing evicts it), and degrades hibernation entry by swapping into RAM
  # exactly when the kernel is freeing RAM for the image. zswap does the same
  # compression in front of the disk and can actually let go. See DESIGN.md.
  local pkgs=(base linux linux-firmware "$UCODE" btrfs-progs cryptsetup grub efibootmgr
              snapper snap-pac networkmanager sudo vim man-db man-pages
              pacman-contrib sof-firmware reflector thermald power-profiles-daemon
              fwupd smartmontools bluez bluez-utils terminus-font)
  if [[ -n $EXTRA_PACKAGES ]]; then
    local extra=()
    read -ra extra <<<"$EXTRA_PACKAGES"
    pkgs+=("${extra[@]}")
  fi
  msg "pacstrap: ${pkgs[*]}"
  pacstrap -K "$MNT" "${pkgs[@]}"
}

keyfile() {
  msg "initramfs keyfiles"
  local uuid swapuuid pbkdf=()
  mapfile -t pbkdf < <(pbkdf_args)
  uuid=$(blkid -s UUID -o value "$CRYPT")
  [[ -n $uuid ]] || die "could not read LUKS UUID from $CRYPT"
  install -d -m 700 "$MNT/etc/cryptsetup-keys.d"
  ( umask 377; dd if=/dev/urandom of="$MNT$KEYFILE" bs=512 count=8 status=none )
  chmod 000 "$MNT$KEYFILE"
  printf '%s' "$LUKS_PASSPHRASE" |
    cryptsetup luksAddKey "${pbkdf[@]}" --key-file - "$CRYPT" "$MNT$KEYFILE"
  # libcryptsetup tries PREFER slots before NORMAL, running each slot's full KDF
  # on the way. Without this the initramfs pays argon2id against the passphrase
  # slot before reaching the keyfile it actually has. GRUB honours only priority
  # 0 (grub-core/disk/luks2.c:677), so it still reaches slot 0 first.
  cryptsetup config --key-slot 1 --priority prefer "$CRYPT"

  # The hibernation image is a dump of RAM and therefore contains the dm-crypt
  # volume key for $CRYPT. Plaintext swap would not weaken the FDE, it would
  # defeat it -- anyone with the disk could read the key out of the image.
  ( umask 377; dd if=/dev/urandom of="$MNT$SWAPKEY" bs=512 count=8 status=none )
  chmod 000 "$MNT$SWAPKEY"
  # Keyfile in slot 0 so the initramfs unlock hits first try; the passphrase is
  # a recovery slot, so a broken keyfile still gets you swap -- cryptsetup falls
  # back to prompting on the console and the device appears. Note what it does
  # NOT get you: the resume job is bounded by resumeflags=x-systemd.device-timeout
  # (see write_fstab), and a human typing a passphrase will usually exceed it, so
  # that boot comes up with swap and without resume. The hibernation image is not
  # destroyed by this -- it stays unconsumed in swap. pbkdf2/1000 on purpose: the key is 4096
  # bits of urandom that exists only inside the already-unlocked root container,
  # so KDF hardening buys nothing.
  cryptsetup luksFormat --type luks2 --sector-size 4096 \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
    --batch-mode --key-file "$MNT$SWAPKEY" "$SWAPCRYPT"
  printf '%s' "$LUKS_PASSPHRASE" |
    cryptsetup luksAddKey "${pbkdf[@]}" --key-file "$MNT$SWAPKEY" \
      --new-keyfile - "$SWAPCRYPT"
  swapuuid=$(blkid -s UUID -o value "$SWAPCRYPT")
  [[ -n $swapuuid ]] || die "could not read LUKS UUID from $SWAPCRYPT"
  # No --allow-discards: the area is written by mkswap once and thereafter only
  # by paging, so there is no TRIM to recover and nothing to leak.
  cryptsetup open --key-file "$MNT$SWAPKEY" "$SWAPCRYPT" "$SWAPMAPPER"
  wait_for "$SWAPDEV"
  mkswap --label swap "$SWAPDEV"

  { printf 'root UUID=%s %s luks,discard\n' "$uuid" "$KEYFILE"
    printf '# Do NOT add the "swap" option below. systemd-cryptsetup-generator turns it\n'
    printf '# into ExecStartPost=/usr/lib/systemd/systemd-makefs swap /dev/mapper/swap,\n'
    printf '# which reformats the device on every boot and destroys the hibernation image.\n'
    printf '# x-initrd.attach keeps the mapping across the initrd -> host switch-root:\n'
    printf '# without it the generated unit gets Conflicts=umount.target, because\n'
    printf '# attach_in_initrd() special-cases only the names "root" and "usr".\n'
    printf 'swap UUID=%s %s luks,x-initrd.attach\n' "$swapuuid" "$SWAPKEY"
  } >"$MNT/etc/crypttab.initramfs"
  chmod 600 "$MNT/etc/crypttab.initramfs"
  cryptsetup luksDump "$CRYPT"     | grep -E '^[[:space:]]*[0-9]+: luks2' || true
  cryptsetup luksDump "$SWAPCRYPT" | grep -E '^[[:space:]]*[0-9]+: luks2' || true
}

configure() {
  msg "chroot configuration"
  {
    printf '#!/bin/bash\nset -euo pipefail\n'
    printf 'HOSTNAME=%q\nUSERNAME=%q\nTZ=%q\nLOCALE=%q\nKEYMAP=%q\nKEYFILE=%q\nSWAPKEY=%q\n' \
      "$HOSTNAME" "$USERNAME" "$TZ" "$LOCALE" "$KEYMAP" "$KEYFILE" "$SWAPKEY"
    cat <<'CHROOT_BODY'
# Every assertion below must say what failed. A bare `grep -q` under `set -e`
# exits silently, which turns a one-line mistake into an install that stops
# dead with no output at all -- verified the hard way.
die() { echo "==> ERROR: chroot: $*" >&2; exit 1; }

ln -sf /usr/share/zoneinfo/"$TZ" /etc/localtime
hwclock --systohc
sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
# locale-gen exits 0 having generated nothing if the sed above matched nothing,
# so a typo in LOCALE would otherwise fail silently. Anchored at the start only:
# glibc's locale.gen pads these lines with trailing spaces, so -x never matches.
grep -q "^${LOCALE} UTF-8" /etc/locale.gen ||
  die "$LOCALE is not enabled in /etc/locale.gen (typo in LOCALE?)"
locale-gen
echo "LANG=$LOCALE"   > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
# Legible console on a HiDPI panel -- which is exactly when RECOVERY.md is open.
echo "FONT=ter-124b"  >> /etc/vconsole.conf
echo "$HOSTNAME"      > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	$HOSTNAME.localdomain $HOSTNAME
HOSTS

sed -i "s|^FILES=.*|FILES=($KEYFILE $SWAPKEY)|" /etc/mkinitcpio.conf
# HOOKS deliberately unchanged. The 'resume' hook is NOT needed and must not be
# added: with the systemd hook, systemd-hibernate-resume-generator reads resume=
# off the cmdline and emits systemd-hibernate-resume.service bound to the swap
# device. The 'resume' hook belongs to the busybox/udev path this does not use.
sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
grep -q '^HOOKS=(base systemd keyboard' /etc/mkinitcpio.conf ||
  die "HOOKS= line was not rewritten in /etc/mkinitcpio.conf"
grep -q "^FILES=($KEYFILE $SWAPKEY)" /etc/mkinitcpio.conf ||
  die "FILES= does not list both keyfiles; swap would not unlock in the initramfs"
mkinitcpio -P
# The linux package's preset builds only 'default' on this release, but the
# fallback menu entry points at initramfs-linux-fallback.img. Build it the way
# the fallback preset would (-S autodetect: every module, not just this host's).
[[ -s /boot/initramfs-linux-fallback.img ]] ||
  mkinitcpio -k /boot/vmlinuz-linux -g /boot/initramfs-linux-fallback.img -S autodetect
# A warning on stderr is the wrong severity here. FILES= was asserted just above,
# so a keyfile missing from the image means mkinitcpio did not do what it was
# told -- and the consequence is silent: a missing root.key costs a second
# passphrase prompt, a missing swap.key costs swap and resume entirely, on a
# machine that otherwise boots perfectly.
for k in "$KEYFILE" "$SWAPKEY"; do
  lsinitcpio /boot/initramfs-linux.img | grep -q "${k#/}" ||
    die "$k is listed in FILES= but is not in the initramfs; mkinitcpio did not embed it"
done

# Arch ships systemd's upstream 90-systemd.preset unmodified plus a
# 99-default.preset of `disable *`, but never applies either: systemd.install
# post_install() hard-codes three enables and that is the whole of the distro's
# default-on policy. So `systemctl status` prints "preset: enabled" for units
# that are in fact disabled -- which is exactly how systemd-timesyncd went
# missing here.
#
# NEVER run `systemctl preset-all` on this system. The upstream preset would
# enable systemd-networkd and systemd-networkd-wait-online alongside
# NetworkManager (two managers racing the same links, plus a ~2 min boot hang
# waiting for a link networkd does not own), and systemd-homed against a /home
# that is a snapper-managed subvolume. verify() asserts systemd-networkd is not
# enabled as a tripwire for this.
systemctl enable NetworkManager
systemctl enable systemd-timesyncd.service
systemctl enable systemd-resolved.service
systemctl enable systemd-oomd.service
systemctl enable fstrim.timer
systemctl enable paccache.timer
systemctl enable reflector.timer
systemctl enable thermald.service
systemctl enable power-profiles-daemon.service
systemctl enable fwupd-refresh.timer
systemctl enable smartd.service
systemctl enable bluetooth.service
systemctl mask   passim.service
id -u "$USERNAME" >/dev/null 2>&1 || useradd -m -G wheel "$USERNAME"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL$/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
visudo -c >/dev/null
grep -q '^%wheel ALL=(ALL:ALL) ALL$' /etc/sudoers ||
  die "wheel sudo line not enabled; $USERNAME would have no way to escalate"
grep -q '^PRUNENAMES.*\.snapshots' /etc/updatedb.conf 2>/dev/null ||
  echo 'PRUNENAMES = ".snapshots"' >> /etc/updatedb.conf
CHROOT_BODY
  } >"$MNT/root/chroot-setup.sh"
  arch-chroot "$MNT" bash /root/chroot-setup.sh
  rm -f "$MNT/root/chroot-setup.sh"

  # /var/log is its own subvolume with no reaper; journald's default cap is 4G.
  install -Dm0644 /dev/stdin "$MNT/etc/systemd/journald.conf.d/00-size.conf" <<'EOF'
[Journal]
SystemMaxUse=512M
SystemMaxFileSize=64M
EOF

  install -Dm0644 /dev/stdin "$MNT/etc/systemd/resolved.conf.d/00-local.conf" <<'EOF'
[Resolve]
MulticastDNS=no
LLMNR=no
DNSOverTLS=opportunistic
EOF

  install -Dm0644 /dev/stdin "$MNT/etc/conf.d/pacman-contrib" <<'EOF'
PACCACHE_ARGS='-rk2'
EOF

  install -Dm0644 /dev/stdin "$MNT/etc/xdg/reflector/reflector.conf" <<'EOF'
--save /etc/pacman.d/mirrorlist
--protocol https
--latest 20
--age 12
--sort rate
EOF

  install -Dm0644 /dev/stdin "$MNT/etc/fwupd/fwupd.conf.d/99-local.conf" <<'EOF'
[fwupd]
P2pPolicy=nothing
EOF

  install -Dm0644 /dev/stdin "$MNT/etc/smartd.conf" <<'EOF'
DEVICESCAN -a -o on -S on -n standby,q -W 4,50,65 -m root -M exec /usr/share/smartmontools/smartd-runner
EOF

  # systemd-oomd's unit alone is a no-op on Arch: nothing ships ManagedOOM*
  # properties. Memory-pressure half only -- with a hibernation-sized swap,
  # SwapUsedLimit would fire far too late to help and false-positive on
  # legitimate paging.
  install -Dm0644 /dev/stdin "$MNT/etc/systemd/system/user@.service.d/10-oomd.conf" <<'EOF'
[Service]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
EOF

  # Must be outside arch-chroot: it bind-mounts the host's /etc/resolv.conf over
  # the target's, so ln -sf inside the chroot fails with EBUSY.
  ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
}

# Sleep policy. Deliberately systemd-only: this configures what happens once
# something suspends, not when to suspend. The idle ladder (dim, lock, screens
# off, suspend) belongs to whatever desktop is installed -- hypridle under
# Hyprland, powerdevil under KDE -- and lives in the dotfiles repo. Everything
# here survives a change of desktop untouched.
sleep_config() {
  msg "sleep policy (hibernate after $HIBERNATE_DELAY suspended)"
  install -Dm0644 /dev/stdin "$MNT/etc/systemd/sleep.conf.d/60-sleep.conf" <<EOF
[Sleep]
AllowSuspendThenHibernate=yes
# Counts from the moment the machine suspends, not from when it went idle.
# Both the lid and the desktop's idle timer feed the same timer.
HibernateDelaySec=$HIBERNATE_DELAY
# ACPI _BTP is available on this class of machine, so a genuinely low battery
# still hibernates early regardless of the delay above.
HibernateOnACPower=no
EOF

  install -Dm0644 /dev/stdin "$MNT/etc/systemd/logind.conf.d/60-lid.conf" <<'EOF'
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
HandleLidSwitchDocked=ignore
HandlePowerKey=suspend-then-hibernate
HandlePowerKeyLongPress=poweroff
HandleSuspendKey=suspend-then-hibernate
# ignore is already the default; written down so its absence is not mistaken
# for an oversight. IdleAction only fires once every session reports IdleHint,
# which no Wayland compositor sets -- the desktop owns idle, not logind.
IdleAction=ignore
InhibitDelayMaxSec=10
EOF
  # daemon-reload makes PID 1 re-read UNIT files; it does not make logind re-read
  # logind.conf.d. Without the reload, `power` mode writes the lid policy,
  # reports success, and the old policy stays live until the next reboot -- and
  # the sleep.conf half DOES take effect immediately (systemd-sleep reads it per
  # invocation), so the half-application is easy to miss. systemd-logind is
  # Type=notify-reload, so reloading is safe for live sessions.
  if [[ -z $MNT ]]; then
    systemctl daemon-reload
    systemctl reload systemd-logind 2>/dev/null ||
      warn "could not reload systemd-logind; lid policy applies at next reboot"
  fi
}

passwords() {
  msg "passwords"
  printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | arch-chroot "$MNT" chpasswd
  if [[ -n ${ROOT_PASSWORD:-} ]]; then
    printf 'root:%s\n' "$ROOT_PASSWORD" | arch-chroot "$MNT" chpasswd
  else
    arch-chroot "$MNT" passwd -l root >/dev/null
    msg "root account locked (no ROOT_PASSWORD); administer via $USERNAME + sudo"
  fi
}

# create-config errors out if the config already exists, so `snapper` mode has
# to detect that and fall through to set-config.
have_config() { target snapper --no-dbus -c "$1" get-config >/dev/null 2>&1; }

snapper_setup() {
  msg "snapper"
  if ! have_config root; then
    [[ ! -e $MNT/.snapshots ]] || die ".snapshots present before create-config"
    target snapper --no-dbus -c root create-config /
    findmnt -M "$MNT/.snapshots" >/dev/null 2>&1 || mount_snapshots
  fi

  # home's .snapshots is a nested subvolume inside @/home. `snapper rollback`
  # refuses any config whose SUBVOLUME is not / (doc s10.1), so @/home is never
  # swapped wholesale and the nesting hazard does not apply.
  have_config home || target snapper --no-dbus -c home create-config /home

  # Limits are ranges on purpose. Range::is_degenerated() is min==max, and
  # Cleaner::is_free_aware() returns false for a degenerate range, so a scalar
  # NUMBER_LIMIT silently switches FREE_LIMIT off (doc s6.1).
  target snapper --no-dbus -c root set-config \
    ALLOW_USERS="$USERNAME" \
    SYNC_ACL=yes \
    FREE_LIMIT=0.2 \
    TIMELINE_CREATE=yes \
    TIMELINE_CLEANUP=yes \
    TIMELINE_MIN_AGE=1800 \
    TIMELINE_LIMIT_HOURLY=2-6 \
    TIMELINE_LIMIT_DAILY=2-7 \
    TIMELINE_LIMIT_WEEKLY=0 \
    TIMELINE_LIMIT_MONTHLY=0 \
    TIMELINE_LIMIT_QUARTERLY=0 \
    TIMELINE_LIMIT_YEARLY=0 \
    NUMBER_CLEANUP=yes \
    NUMBER_MIN_AGE=1800 \
    NUMBER_LIMIT=10-20 \
    NUMBER_LIMIT_IMPORTANT=4-10 \
    EMPTY_PRE_POST_CLEANUP=yes \
    EMPTY_PRE_POST_MIN_AGE=1800

  target snapper --no-dbus -c home set-config \
    ALLOW_USERS="$USERNAME" \
    SYNC_ACL=yes \
    FREE_LIMIT=0.2 \
    TIMELINE_CREATE=yes \
    TIMELINE_CLEANUP=yes \
    TIMELINE_MIN_AGE=1800 \
    TIMELINE_LIMIT_HOURLY=2-6 \
    TIMELINE_LIMIT_DAILY=2-7 \
    TIMELINE_LIMIT_WEEKLY=0-4 \
    TIMELINE_LIMIT_MONTHLY=0 \
    TIMELINE_LIMIT_QUARTERLY=0 \
    TIMELINE_LIMIT_YEARLY=0 \
    NUMBER_CLEANUP=yes \
    NUMBER_MIN_AGE=1800 \
    NUMBER_LIMIT=5-10 \
    NUMBER_LIMIT_IMPORTANT=2-5 \
    EMPTY_PRE_POST_CLEANUP=yes \
    EMPTY_PRE_POST_MIN_AGE=1800

  install -Dm0644 /dev/stdin "$MNT/etc/snap-pac.ini" <<'EOF'
[root]
important_packages = ["linux", "linux-lts", "linux-firmware", "systemd", "systemd-libs", "glibc", "mkinitcpio", "nvidia", "mesa", "intel-ucode"]
important_commands = ["pacman -Syu", "pacman -Syyu", "pacman -Su"]
EOF

  # Upstream snapper-timeline.timer has no Persistent=, so a laptop that is
  # asleep across the hour boundary skips the snapshot and never catches up.
  install -Dm0644 /dev/stdin "$MNT/etc/systemd/system/snapper-timeline.timer.d/persistent.conf" <<'EOF'
[Timer]
Persistent=true
EOF

  [[ -n $MNT ]] || systemctl daemon-reload
  target systemctl enable snapper-timeline.timer snapper-cleanup.timer
  target snapper --no-dbus -c root get-config |
    grep -E 'TIMELINE_LIMIT_HOURLY|NUMBER_LIMIT|ALLOW_USERS|QGROUP|SYNC_ACL|FREE_LIMIT' || true
  target snapper --no-dbus -c home get-config |
    grep -E 'NUMBER_LIMIT|TIMELINE_LIMIT_WEEKLY|ALLOW_USERS' || true
}

grub_config() {
  msg "grub configuration"
  cat > "$MNT/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="rootfstype=btrfs zswap.enabled=1 resume=/dev/mapper/swap resumeflags=x-systemd.device-timeout=30s"
GRUB_CMDLINE_LINUX=""
GRUB_PRELOAD_MODULES="part_gpt"
GRUB_ENABLE_CRYPTODISK=y
GRUB_DISABLE_LINUX_UUID=true
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_OS_PROBER=true
GRUB_TERMINAL_INPUT=console
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
EOF

  # grub 2.14 has no btrfs subvolume support: 10_linux pins the running root
  # with rootflags=subvol=, and every path it emits (including the prefix baked
  # into core.efi) is absolute from subvolid 5, so it must be re-pointed
  # whenever the default subvolume moves.
  cat > "$MNT/usr/local/bin/grub-sync" <<'EOF'
#!/bin/bash
set -euo pipefail
stamp=/efi/EFI/GRUB/root-subvol
efi="/efi/EFI/GRUB/grubx64.efi /efi/EFI/BOOT/BOOTX64.EFI"
ifchanged=0
if [[ ${1:-} == --if-changed ]]; then ifchanged=1; shift; fi
t=${1:-/}
cur=$(btrfs subvolume get-default / | awk '{print $NF}')
stale=0
for f in $efi; do
  p=$(grep -aoE '\)/[^)]*/boot/grub' "$f" 2>/dev/null | head -1 || true)
  p=${p#)/}; p=${p%/boot/grub}
  [[ -n $p && $p != "$cur" ]] || continue
  stale=1
  if btrfs subvolume list / | awk '{print $NF}' | grep -qxF "$p"
  then echo "$f: prefix $p is stale, default is $cur" >&2
  else echo "$f: prefix $p names a deleted subvolume" >&2; fi
done
if (( ifchanged && !stale )) && [[ -r $stamp && $(cat "$stamp") == "$cur" ]] &&
   ! grep -q rootflags=subvol= /boot/grub/grub.cfg; then exit 0; fi
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB \
  --boot-directory="$t/boot" || echo "grub-install: nvram entry failed" >&2
grub-install --target=x86_64-efi --efi-directory=/efi --removable \
  --boot-directory="$t/boot"
if [[ $t == / ]]; then
  grub-mkconfig -o /boot/grub/grub.cfg
else
  n=${t%/snapshot}; n=${n##*/}
  sed -i -E "s#(/\.snapshots/)[0-9]+(/snapshot)#\1$n\2#g" "$t/boot/grub/grub.cfg"
fi
sed -i -E 's/ rootflags=subvol=[^ ]*//g
           s#root=/dev/dm-[0-9]+#root=/dev/mapper/root#g
           s/( root=[^ ]+) ro /\1 rw /' "$t/boot/grub/grub.cfg"
grep -q rootflags=subvol= "$t/boot/grub/grub.cfg" && { echo "rootflags= survived" >&2; exit 1; }
printf '%s\n' "$cur" >"$stamp"
EOF
  chmod 755 "$MNT/usr/local/bin/grub-sync"

  install -d -m 755 "$MNT/usr/lib/snapper/plugins"
  cat > "$MNT/usr/lib/snapper/plugins/10-grub" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ ${1:-} == rollback-post ]] || exit 0
t=/.snapshots/${5:?}/snapshot
[[ -f $t/boot/grub/grub.cfg ]] || exit 0
exec /usr/local/bin/grub-sync "$t"
EOF
  chmod 755 "$MNT/usr/lib/snapper/plugins/10-grub"

  cat > "$MNT/etc/systemd/system/grub-boot-sync.service" <<'EOF'
[Unit]
Description=Point GRUB at the current btrfs default subvolume
ConditionPathIsMountPoint=/efi
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/grub-sync --if-changed

[Install]
WantedBy=multi-user.target
EOF
  arch-chroot "$MNT" systemctl enable grub-boot-sync.service
}

write_fstab() {
  msg "fstab"
  genfstab -U "$MNT" >>"$MNT/etc/fstab"
  sed -i -E 's/,subvolid=[0-9]+//g; s/\bsubvolid=[0-9]+,//g' "$MNT/etc/fstab"
  awk 'BEGIN{OFS="\t"} $2=="/" && $3=="btrfs" {
         gsub(/,subvol=[^,[:space:]]+/,"",$4); gsub(/subvol=[^,[:space:]]+,/,"",$4) } {print}' \
    "$MNT/etc/fstab" >"$MNT/etc/fstab.new"
  mv "$MNT/etc/fstab.new" "$MNT/etc/fstab"
  # Swap is not active during the install, so genfstab emits nothing for it.
  # /dev/mapper/swap rather than UUID= to match root= and resume=, and because
  # crypttab.initramfs fixes the mapper name anyway.
  #
  # nofail is load-bearing, not decoration. Without it a swap container that
  # cannot be unlocked -- damaged LUKS header, wrong keyfile after a partial
  # restore -- blocks the boot for the full 90 s device timeout before giving
  # up, showing "A start job is running for /dev/mapper/swap" the whole time,
  # which reads exactly like a hung machine and invites a power cycle at the
  # worst possible moment. Measured: 196 s to a login prompt instead of ~100 s.
  #
  # nofail removes the HOST-side stall only. There is a second one in the
  # initramfs that nofail cannot reach: resume= makes
  # systemd-hibernate-resume-generator emit BindsTo=dev-mapper-swap.device on
  # systemd-hibernate-resume.service, which is ordered Before=local-fs-pre.target
  # -- so a swap device that never appears is waited on before the root
  # filesystem is even mounted. That is what the residual ~100 s was.
  # resumeflags=x-systemd.device-timeout=30s in GRUB_CMDLINE_LINUX_DEFAULT bounds
  # it. Note resumeflags= inherits rootflags= when unset, and grub-sync strips
  # rootflags=subvol= entirely, so nothing is inherited and it must be explicit.
  #
  # The budget is for DEVICE ENUMERATION, not the KDF -- the swap keyslot is
  # pbkdf2/1000 and costs well under a millisecond. 30 s rather than 10 s
  # because erring short has a worse failure than erring long: a spurious
  # timeout skips systemd-hibernate-resume, the machine boots fresh, and the
  # unconsumed image is left sitting in swap. That is intact, not destroyed
  # (swsusp rewrites page 0's signature to S1SUSPEND so a later swapon fails
  # rather than overwriting), but it is exactly the input to the untested
  # hibernate-then-rollback hazard. 30 s also leaves room for a human to type a
  # passphrase if the swap keyfile is ever unusable and cryptsetup falls back to
  # prompting.
  #
  # Resume itself is unaffected by fstab: it happens in the initramfs from
  # crypttab.initramfs and resume=, never from fstab.
  printf '%s\tnone\tswap\tdefaults,nofail\t0 0\n' "$SWAPDEV" >>"$MNT/etc/fstab"
  cat "$MNT/etc/fstab"
}

first_snapshot() {
  msg "first snapshot"
  SNAPNUM=$(arch-chroot "$MNT" snapper --no-dbus -c root create --type single \
    --print-number --description "arch-install-v2 first root filesystem")
  SNAPNUM=${SNAPNUM//[$'\r\n\t ']/}
  [[ $SNAPNUM =~ ^[0-9]+$ ]] || die "unexpected snapper create output: '$SNAPNUM'"
  SNAPSUB="@/.snapshots/$SNAPNUM/snapshot"
  [[ -d $MNT/.snapshots/$SNAPNUM/snapshot ]] || die "snapshot $SNAPNUM missing"
  btrfs property set -ts "$MNT/.snapshots/$SNAPNUM/snapshot" ro false
  btrfs subvolume set-default "$MNT/.snapshots/$SNAPNUM/snapshot"
  btrfs subvolume get-default "$MNT"
}

# pacstrap -K runs pacman-key --init against $MNT/etc/pacman.d/gnupg, which
# leaves a gpg-agent (and keyboxd) alive with its socket inside the target.
# They keep $MNT busy, and v2 is the variant that has to unmount mid-install.
release_mnt() {
  local i
  gpgconf --homedir "$MNT/etc/pacman.d/gnupg" --kill all >/dev/null 2>&1 || true
  sync
  for i in $(seq 1 20); do
    umount -R "$MNT" 2>/dev/null && return 0
    sleep 0.5
  done
  warn "$MNT still busy; holders:"
  { ls -l /proc/[0-9]*/cwd /proc/[0-9]*/root /proc/[0-9]*/fd/* 2>/dev/null | grep -F "$MNT"
    command -v fuser >/dev/null && fuser -vm "$MNT"; } >&2 || true
  umount -R "$MNT"
}

remount_snapshot() {
  msg "remounting on $SNAPSUB"
  release_mnt
  mount_tree "$SNAPSUB" snap
}

bootloader() {
  msg "grub-install"
  arch-chroot "$MNT" /usr/local/bin/grub-sync
  grep -E '^[[:space:]]+(linux|initrd|cryptomount)' "$MNT/boot/grub/grub.cfg" | head -20 || true
  efibootmgr 2>/dev/null | grep -i GRUB ||
    warn "no GRUB EFI variable; removable path EFI/BOOT/BOOTX64.EFI must boot"
}

FAILURES=()
check() { local what=$1; shift; if ! "$@" >/dev/null 2>&1; then FAILURES+=("$what"); fi; }
checkv() { local what=$1 want=$2 got=$3; [[ $got == "$want" ]] || FAILURES+=("$what (want '$want', got '$got')"); }

verify() {
  msg "verify"
  FAILURES=()
  local got hooks tok t cfg fstab dflt num

  local R=${MNT:-/}
  findmnt -M "$R" >/dev/null || die "verify: $R is not mounted"
  fstab=$MNT/etc/fstab
  cfg=$MNT/boot/grub/grub.cfg

  local subvols
  subvols=$(btrfs subvolume list -t "$R" | awk 'NR>2{sub(/^<FS_TREE>\//,"",$4); print $4}')
  # @/home/.snapshots is what `snapper -c home create-config /home` produces.
  for t in @ @/home @/var/log @/var/cache/pacman/pkg @/.snapshots @/home/.snapshots; do
    grep -qx "$t" <<<"$subvols" || FAILURES+=("missing subvolume $t")
  done
  got=$(grep -c '^@/\.snapshots/[0-9]\+/snapshot$' <<<"$subvols" || true)
  (( got >= 1 )) || FAILURES+=("no snapshot subvolume under @/.snapshots")
  # Both configs also accumulate @/<cfg>/.snapshots/<N>/snapshot subvolumes.
  got=$(grep '\.snapshots' <<<"$subvols" |
        grep -cvE '^@(/home)?/\.snapshots(/[0-9]+/snapshot)?$' || true)
  checkv "no unexpected .snapshots subvolume" "0" "$got"

  dflt=$(btrfs subvolume get-default "$R" | awk '{print $NF}')
  [[ $dflt =~ ^@/\.snapshots/[0-9]+/snapshot$ ]] ||
    FAILURES+=("default subvolume is not a snapshot (got '$dflt')")
  got=$(findmnt -no SOURCE "$R")
  checkv "root mounted on the default subvolume" "$DEV[/$dflt]" "$got"
  got=$(btrfs property get -ts "$R" ro 2>/dev/null || true)
  checkv "root snapshot writable" "ro=false" "$got"

  got=$(awk '$2=="/" && $3=="btrfs"{print $4}' "$fstab")
  [[ -n $got ]] || FAILURES+=("no btrfs root line in fstab")
  case "$got" in *subvol=*|*subvolid=*) FAILURES+=("fstab root line pins a subvolume: $got") ;; esac
  for t in /.snapshots /home /var/log /var/cache/pacman/pkg; do
    got=$(awk -v m="$t" '$2==m{print $4}' "$fstab")
    case "$got" in *subvol=/@*) ;; *) FAILURES+=("fstab $t missing subvol= ($got)") ;; esac
  done
  got=$(grep -c 'subvolid' "$fstab" || true)
  checkv "fstab subvolid= count" "0" "$got"
  got=$(awk '$3=="btrfs"{print $(NF-1), $NF}' "$fstab" | sort -u | tr '\n' ';')
  checkv "fstab btrfs fsck fields" "0 0;" "$got"
  got=$(awk '$2=="/efi"{print $3}' "$fstab")
  checkv "esp mounted at /efi" "vfat" "$got"

  check "grub.cfg exists" test -s "$cfg"
  if [[ -s $cfg ]]; then
    grep -q 'cryptomount -u [0-9a-fA-F-]\{32,\}' "$cfg" || FAILURES+=("grub.cfg has no cryptomount")
    # LOAD-BEARING AND ALONE. Verified in a VM: of the checks that could in
    # principle catch a reintroduced root pin, only this one actually fires.
    # "root mounted on the default subvolume" reads live kernel and filesystem
    # state and never looks at grub.cfg -- and at the moment the pin is written
    # it is guaranteed to agree, because grub-mkconfig pins whatever subvolume
    # is currently mounted. It diverges only after a rollback has moved the
    # default and the machine has rebooted onto the stale pin, i.e. after the
    # damage. The kernel-path check passes too, since grub-mkconfig emits the
    # path correctly and only ADDS the token.
    #
    # So this grep is the whole net at the one moment the mistake is cheap to
    # fix. Matched broadly on purpose: `subvol=` is what 10_linux emits today,
    # but `subvolid=` pins just as hard and a pattern that missed it would let
    # verify report "all invariants hold" on a system where every future
    # rollback silently does nothing.
    grep -qE 'rootflags=[^ ]*subvol' "$cfg" &&
      FAILURES+=("grub.cfg has a rootflags= root pin (rollback would silently do nothing)")
    grep -q 'root=/dev/mapper/root' "$cfg" || FAILURES+=("grub.cfg lacks root=/dev/mapper/root")
    grep -q "linux[[:space:]]*/$dflt/boot/vmlinuz-linux" "$cfg" ||
      FAILURES+=("grub.cfg kernel path is not inside $dflt")
    grep -qE '(^|[[:space:]])(linux|initrd)[[:space:]]+/efi/' "$cfg" &&
      FAILURES+=("grub.cfg loads from the ESP")
  fi
  check "grubx64.efi" test -s "$MNT/efi/EFI/GRUB/grubx64.efi"
  check "BOOTX64.EFI" test -s "$MNT/efi/EFI/BOOT/BOOTX64.EFI"
  check "GRUB_ENABLE_CRYPTODISK" grep -qx 'GRUB_ENABLE_CRYPTODISK=y' "$MNT/etc/default/grub"
  check "grub modules in root subvol" test -d "$MNT/boot/grub/x86_64-efi"
  check "grub-sync helper" test -x "$MNT/usr/local/bin/grub-sync"
  got=$(cat "$MNT/efi/EFI/GRUB/root-subvol" 2>/dev/null || true)
  checkv "grub prefix stamp" "$dflt" "$got"
  for t in "EFI/GRUB/grubx64.efi" "EFI/BOOT/BOOTX64.EFI"; do
    got=$(grep -aoE '\)/[^)]*/boot/grub' "$MNT/efi/$t" 2>/dev/null | head -1 || true)
    got=${got#)/}; got=${got%/boot/grub}
    checkv "grub prefix in $t" "$dflt" "$got"
    [[ -z $got ]] || grep -qxF "$got" <<<"$subvols" ||
      FAILURES+=("grub prefix subvolume does not exist: $got")
  done
  check "snapper grub plugin" test -x "$MNT/usr/lib/snapper/plugins/10-grub"

  check "vmlinuz-linux" test -s "$MNT/boot/vmlinuz-linux"
  check "initramfs-linux.img" test -s "$MNT/boot/initramfs-linux.img"
  check "initramfs-linux-fallback.img" test -s "$MNT/boot/initramfs-linux-fallback.img"
  got=$(findmnt -no FSTYPE -T "$MNT/boot/vmlinuz-linux" 2>/dev/null || true)
  checkv "/boot on btrfs" "btrfs" "$got"
  check "no kernel on the ESP" test ! -e "$MNT/efi/vmlinuz-linux"

  got=$(stat -c '%a' "$MNT$KEYFILE" 2>/dev/null || true)
  checkv "keyfile mode" "0" "$got"
  check "crypttab.initramfs" grep -q "^root UUID=.* $KEYFILE " "$MNT/etc/crypttab.initramfs"
  check "mkinitcpio FILES=" grep -qx "FILES=($KEYFILE $SWAPKEY)" "$MNT/etc/mkinitcpio.conf"
  # FILES= listing both is asserted above; this asserts both were actually
  # EMBEDDED. Checking only root.key would pass an image missing swap.key, which
  # boots perfectly and silently has no swap and no resume.
  check "root keyfile in initramfs" target \
    bash -c "lsinitcpio /boot/initramfs-linux.img | grep -q cryptsetup-keys.d/root.key"
  check "swap keyfile in initramfs" target \
    bash -c "lsinitcpio /boot/initramfs-linux.img | grep -q cryptsetup-keys.d/swap.key"

  hooks=$(grep -E '^HOOKS=' "$MNT/etc/mkinitcpio.conf" || true)
  hooks=${hooks#HOOKS=(}
  hooks=${hooks%)}
  local have_systemd=0 have_sdencrypt=0 have_udev=0 have_encrypt=0
  for tok in $hooks; do
    case "$tok" in
      systemd)    have_systemd=1 ;;
      sd-encrypt) have_sdencrypt=1 ;;
      udev)       have_udev=1 ;;
      encrypt)    have_encrypt=1 ;;
    esac
  done
  (( have_systemd ))      || FAILURES+=("HOOKS missing systemd")
  (( have_sdencrypt ))    || FAILURES+=("HOOKS missing sd-encrypt")
  (( have_udev == 0 ))    || FAILURES+=("HOOKS contains udev")
  (( have_encrypt == 0 )) || FAILURES+=("HOOKS contains encrypt")

  check "snapper root config" test -f "$MNT/etc/snapper/configs/root"
  check "snapper SUBVOLUME=/" grep -qx 'SUBVOLUME="/"' "$MNT/etc/snapper/configs/root"
  got=$(findmnt -no SOURCE "$MNT/.snapshots" 2>/dev/null || true)
  checkv "/.snapshots source" "$DEV[/@/.snapshots]" "$got"
  got=$(stat -c '%a %U:%G' "$MNT/.snapshots" 2>/dev/null || true)
  checkv "/.snapshots perms" "750 root:root" "$got"
  num=${dflt#@/.snapshots/}; num=${num%/snapshot}
  check "snapshot info.xml" test -s "$MNT/.snapshots/$num/info.xml"
  check "pacman db inside the root snapshot" test -d "$MNT/var/lib/pacman/local"
  got=$(findmnt -no FSTYPE -T "$MNT/var/lib/pacman" 2>/dev/null || true)
  checkv "/var/lib/pacman on btrfs" "btrfs" "$got"
  got=$(findmnt -no SOURCE -T "$MNT/var/lib/pacman" 2>/dev/null || true)
  checkv "/var/lib/pacman inside the root subvolume" "$DEV[/$dflt]" "$got"

  got=$(target id -nG "$USERNAME" 2>/dev/null | tr ' ' '\n' | grep -cx wheel || true)
  checkv "$USERNAME in wheel" "1" "$got"
  got=$(target systemctl is-enabled NetworkManager 2>/dev/null || true)
  checkv "NetworkManager enabled" "enabled" "$got"
  for t in snapper-timeline.timer snapper-cleanup.timer grub-boot-sync.service; do
    got=$(target systemctl is-enabled "$t" 2>/dev/null || true)
    checkv "$t enabled" "enabled" "$got"
  done
  # Exactly those two snapper timers. snapper-boot competes with the snap-pac
  # pairs for NUMBER_LIMIT slots; snapper-backup needs a send/receive target.
  for t in snapper-boot.timer snapper-backup.timer; do
    got=$(target systemctl is-enabled "$t" 2>/dev/null || true)
    [[ $got != enabled ]] || FAILURES+=("$t is enabled")
  done
  check "timeline timer Persistent drop-in" \
    test -s "$MNT/etc/systemd/system/snapper-timeline.timer.d/persistent.conf"
  check "vconsole.conf" test -s "$MNT/etc/vconsole.conf"

  # --- swap, hibernation, zswap -------------------------------------------
  got=$(target pacman -Q zram-generator 2>/dev/null | awk '{print $1}' || true)
  checkv "zram-generator not installed" "" "$got"
  check "no zram-generator.conf" test ! -e "$MNT/etc/systemd/zram-generator.conf"
  check "zswap enabled on cmdline" grep -q 'zswap\.enabled=1' "$MNT/etc/default/grub"
  check "resume= on cmdline" grep -q "resume=$SWAPDEV" "$MNT/etc/default/grub"
  # Bounds the initrd-side wait on the swap device. Without it an unopenable
  # swap container stalls the boot ~90 s BEFORE the root filesystem is mounted,
  # where nofail cannot help. See the comment in write_fstab().
  check "resumeflags device timeout" \
    grep -q 'resumeflags=x-systemd\.device-timeout=' "$MNT/etc/default/grub"
  # 10_linux emits `rw` unconditionally; a second one in the variable duplicates it
  got=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$MNT/etc/default/grub" |
        tr ' ' '\n' | grep -cx rw || true)
  checkv "no duplicate rw on cmdline" "0" "$got"
  if [[ -s $cfg ]]; then
    check "zswap enabled in grub.cfg" grep -q 'zswap\.enabled=1' "$cfg"
    check "resume= in grub.cfg" grep -q "resume=$SWAPDEV" "$cfg"
  fi
  got=$(awk '$3=="swap"{print $1}' "$fstab")
  checkv "fstab swap entry" "$SWAPDEV" "$got"
  # Without nofail an unopenable swap container costs 90 s of boot time looking
  # exactly like a hang. See the comment in write_fstab().
  got=$(awk '$3=="swap"{print $4}' "$fstab" | tr ',' '\n' | grep -cx nofail || true)
  checkv "fstab swap has nofail" "1" "$got"
  check "crypttab swap entry" grep -q "^swap UUID=.* $SWAPKEY " "$MNT/etc/crypttab.initramfs"
  # The single word `swap` in the options field would make
  # systemd-cryptsetup-generator add ExecStartPost=systemd-makefs, reformatting
  # the device every boot and destroying the hibernation image.
  got=$(awk '$1=="swap"{print $4}' "$MNT/etc/crypttab.initramfs" 2>/dev/null |
        tr ',' '\n' | grep -cx swap || true)
  checkv "crypttab swap has no 'swap' option" "0" "$got"
  check "crypttab swap has x-initrd.attach" \
    grep -q '^swap UUID=.*x-initrd\.attach' "$MNT/etc/crypttab.initramfs"
  got=$(stat -c '%a' "$MNT$SWAPKEY" 2>/dev/null || true)
  checkv "swap keyfile mode" "0" "$got"
  # The resume hook belongs to the busybox path; systemd-hibernate-resume-generator
  # does this job here. Its presence would mean someone cargo-culted it in.
  got=$(grep -E '^HOOKS=' "$MNT/etc/mkinitcpio.conf" | tr ' ()' '\n\n\n' | grep -cx resume || true)
  checkv "no resume hook in HOOKS" "0" "$got"

  # --- sleep policy --------------------------------------------------------
  check "sleep.conf.d drop-in"  test -s "$MNT/etc/systemd/sleep.conf.d/60-sleep.conf"
  check "logind.conf.d drop-in" test -s "$MNT/etc/systemd/logind.conf.d/60-lid.conf"
  check "HibernateDelaySec" \
    grep -qx "HibernateDelaySec=$HIBERNATE_DELAY" "$MNT/etc/systemd/sleep.conf.d/60-sleep.conf"
  check "HibernateOnACPower=no" \
    grep -qx 'HibernateOnACPower=no' "$MNT/etc/systemd/sleep.conf.d/60-sleep.conf"
  check "HandleLidSwitch" \
    grep -qx 'HandleLidSwitch=suspend-then-hibernate' "$MNT/etc/systemd/logind.conf.d/60-lid.conf"

  # --- services that must be enabled ---------------------------------------
  for t in systemd-timesyncd.service systemd-resolved.service systemd-oomd.service \
           fstrim.timer paccache.timer reflector.timer thermald.service \
           power-profiles-daemon.service fwupd-refresh.timer smartd.service \
           bluetooth.service; do
    got=$(target systemctl is-enabled "$t" 2>/dev/null || true)
    checkv "$t enabled" "enabled" "$got"
  done
  # Tripwire: Arch never applies systemd presets, so `systemctl preset-all` would
  # enable systemd-networkd alongside NetworkManager and hang boot on
  # networkd-wait-online.
  got=$(target systemctl is-enabled systemd-networkd.service 2>/dev/null || true)
  [[ $got != enabled ]] || FAILURES+=("systemd-networkd is enabled (was preset-all run?)")
  check "oomd user@ drop-in" \
    test -s "$MNT/etc/systemd/system/user@.service.d/10-oomd.conf"
  check "journald size drop-in" test -s "$MNT/etc/systemd/journald.conf.d/00-size.conf"
  check "resolv.conf symlink" test -L "$MNT/etc/resolv.conf"

  local c k
  check "snapper home config" test -f "$MNT/etc/snapper/configs/home"
  check "snapper home SUBVOLUME" grep -qx 'SUBVOLUME="/home"' "$MNT/etc/snapper/configs/home"
  got=$(sed -n 's/^SNAPPER_CONFIGS="\(.*\)"$/\1/p' "$MNT/etc/conf.d/snapper" 2>/dev/null |
        tr ' ' '\n' | sort | tr '\n' ' ' || true)
  checkv "SNAPPER_CONFIGS" "home root " "$got"

  got=$(target pacman -Q snap-pac 2>/dev/null | awk '{print $1}' || true)
  checkv "snap-pac installed" "snap-pac" "$got"
  got=$(find "$MNT/usr/share/libalpm/hooks" -name '*snap-pac*' 2>/dev/null | wc -l || true)
  checkv "snap-pac alpm hooks" "3" "$got"
  check "snap-pac.ini" test -s "$MNT/etc/snap-pac.ini"
  got=$(grep -c '^important_packages' "$MNT/etc/snap-pac.ini" 2>/dev/null || true)
  checkv "snap-pac.ini important_packages" "1" "$got"
  # v1's 04-bootbackup.hook mirrors /boot into the root subvolume because there
  # /boot is FAT outside the snapshot. Here it is inside, so the hook is wrong.
  got=$(find "$MNT/etc/pacman.d/hooks" -name '*bootbackup*' 2>/dev/null | wc -l || true)
  checkv "no /boot mirror hook" "0" "$got"

  cfgval() { sed -n "s/^$2=\"\(.*\)\"\$/\1/p" "$MNT/etc/snapper/configs/$1" 2>/dev/null; }
  for c in root home; do
    # A scalar limit is a degenerate range, and Cleaner::is_free_aware() returns
    # false for one -- FREE_LIMIT would be read but never applied (doc s6.1).
    for k in NUMBER_LIMIT NUMBER_LIMIT_IMPORTANT TIMELINE_LIMIT_HOURLY TIMELINE_LIMIT_DAILY; do
      got=$(cfgval "$c" "$k" || true)
      [[ $got =~ ^[0-9]+-[0-9]+$ ]] || FAILURES+=("$c $k is not a range: '$got'")
    done
    checkv "$c FREE_LIMIT" "0.2" "$(cfgval "$c" FREE_LIMIT)"
    checkv "$c SYNC_ACL" "yes" "$(cfgval "$c" SYNC_ACL)"
    checkv "$c NUMBER_CLEANUP" "yes" "$(cfgval "$c" NUMBER_CLEANUP)"
    checkv "$c NUMBER_MIN_AGE" "1800" "$(cfgval "$c" NUMBER_MIN_AGE)"
    checkv "$c TIMELINE_CREATE" "yes" "$(cfgval "$c" TIMELINE_CREATE)"
    checkv "$c TIMELINE_CLEANUP" "yes" "$(cfgval "$c" TIMELINE_CLEANUP)"
    checkv "$c EMPTY_PRE_POST_CLEANUP" "yes" "$(cfgval "$c" EMPTY_PRE_POST_CLEANUP)"
    checkv "$c EMPTY_PRE_POST_MIN_AGE" "1800" "$(cfgval "$c" EMPTY_PRE_POST_MIN_AGE)"
    # QGROUP off: FREE_LIMIT needs only statvfs, while snapper 0.13.1 forces a
    # full quota_rescan on every space-aware cleanup run (doc s8).
    checkv "$c QGROUP empty" "" "$(cfgval "$c" QGROUP)"
    got=$(cfgval "$c" ALLOW_USERS || true)
    tr ' ' '\n' <<<"$got" | grep -qx "$USERNAME" ||
      FAILURES+=("$c ALLOW_USERS lacks $USERNAME (got '$got')")
  done
  checkv "root NUMBER_LIMIT" "10-20" "$(cfgval root NUMBER_LIMIT)"
  checkv "root NUMBER_LIMIT_IMPORTANT" "4-10" "$(cfgval root NUMBER_LIMIT_IMPORTANT)"
  checkv "home NUMBER_LIMIT" "5-10" "$(cfgval home NUMBER_LIMIT)"
  checkv "home NUMBER_LIMIT_IMPORTANT" "2-5" "$(cfgval home NUMBER_LIMIT_IMPORTANT)"
  checkv "root TIMELINE_LIMIT_WEEKLY" "0" "$(cfgval root TIMELINE_LIMIT_WEEKLY)"
  checkv "home TIMELINE_LIMIT_WEEKLY" "0-4" "$(cfgval home TIMELINE_LIMIT_WEEKLY)"
  if command -v getfacl >/dev/null; then
    got=$(getfacl -pn "$MNT/.snapshots" 2>/dev/null |
          sed -n "s/^user:$(target id -u "$USERNAME" 2>/dev/null):\(.*\)$/\1/p" || true)
    checkv "SYNC_ACL entry on /.snapshots" "r-x" "$got"
  fi
  if btrfs qgroup show "${MNT:-/}" >/dev/null 2>&1; then
    FAILURES+=("btrfs quotas are enabled")
  fi

  local dump
  dump=$(cryptsetup luksDump "$CRYPT")
  grep -q 'Flags:.*allow-discards' <<<"$dump" || FAILURES+=("LUKS allow-discards flag")
  grep -q 'PBKDF:[[:space:]]*argon2id' <<<"$dump" || FAILURES+=("LUKS PBKDF argon2id")
  grep -q 'sector:[[:space:]]*4096' <<<"$dump" || FAILURES+=("LUKS 4096 sector size")
  got=$(grep -cE '^[[:space:]]*[0-9]+: luks2' <<<"$dump" || true)
  checkv "LUKS keyslots (passphrase + keyfile)" "2" "$got"
  # Forced iterations, not the benchmark's pick: see the LUKS_PBKDF_* comment.
  # The benchmark on a modern CPU lands around 21 at 512 MiB, which costs ~10 s
  # in GRUB's scalar single-threaded argon2 instead of ~2 s.
  if [[ -n $LUKS_PBKDF_ITERATIONS ]]; then
    # Not an awk range: `0: luks2` matches the end pattern too, which collapses
    # the range to a single line and silently yields nothing.
    got=$(awk '/^[[:space:]]*0: luks2/{f=1; next}
               f && (/^[[:space:]]*[0-9]+: luks2/ || /^[A-Za-z]/) {exit}
               f && /Time cost:/ {print $3; exit}' <<<"$dump")
    checkv "LUKS slot 0 argon2 time cost" "$LUKS_PBKDF_ITERATIONS" "$got"
  fi

  local swapdump
  swapdump=$(cryptsetup luksDump "$SWAPCRYPT" 2>/dev/null || true)
  [[ -n $swapdump ]] || FAILURES+=("swap container is not LUKS2: $SWAPCRYPT")
  if [[ -n $swapdump ]]; then
    grep -q 'sector:[[:space:]]*4096' <<<"$swapdump" || FAILURES+=("swap LUKS 4096 sector size")
    got=$(grep -cE '^[[:space:]]*[0-9]+: luks2' <<<"$swapdump" || true)
    checkv "swap LUKS keyslots (keyfile + passphrase)" "2" "$got"
  fi
  # Proves the swap container is not the root container by another name, which
  # would mean the hibernation image lands on top of the filesystem.
  got=$(blkid -s UUID -o value "$SWAPCRYPT" 2>/dev/null || true)
  [[ -n $got && $got != "$(blkid -s UUID -o value "$CRYPT" 2>/dev/null)" ]] ||
    FAILURES+=("swap and root LUKS UUIDs are not distinct")

  if [[ -z $MNT ]]; then
    # Runtime-only: meaningless against a chroot.
    #
    # verify otherwise reads grub.cfg on disk and never /proc/cmdline, so a
    # kernel ALREADY RUNNING under a stale pin is invisible to it the moment the
    # on-disk file is repaired -- which grub-boot-sync.service does automatically
    # on the next boot. Observed: a machine booted with rootflags=subvol= in
    # force while verify reported all invariants hold, because the file had just
    # been healed underneath it. Harmless in that case (the pin matched the
    # default), but it is exactly the state this design cannot tolerate, and the
    # on-disk check cannot see it.
    got=$(tr ' ' '\n' </proc/cmdline | grep -c '^rootflags=.*subvol' || true)
    checkv "running kernel has no root pin on its cmdline" "0" "$got"
    checkv "zswap compressor" "zstd" "$(cat /sys/module/zswap/parameters/compressor 2>/dev/null || true)"
    check "no zram block device" test ! -e /sys/block/zram0
    got=$(swapon --noheadings --show=NAME 2>/dev/null | wc -l)
    checkv "exactly one swap area" "1" "$got"
    # swapon reports the resolved device (/dev/dm-0), not the mapper symlink,
    # so both sides have to be resolved or this can never match.
    got=$(readlink -f "$(swapon --noheadings --show=NAME 2>/dev/null | head -1)" 2>/dev/null || true)
    checkv "swap area is the LUKS mapping" "$(readlink -f "$SWAPDEV" 2>/dev/null || echo "$SWAPDEV")" "$got"
    # 0:0 means the kernel has no hibernation target and hibernate would fail.
    got=$(cat /sys/power/resume 2>/dev/null || echo 0:0)
    [[ $got != 0:0 ]] || FAILURES+=("/sys/power/resume is unset; hibernate has no target")
    got=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    got=$(( got * 35 / 32 ))                       # worst-case image expansion
    local swapkb
    swapkb=$(swapon --noheadings --show=SIZE --bytes 2>/dev/null | head -1)
    swapkb=$(( ${swapkb:-0} / 1024 ))
    (( swapkb >= got )) ||
      FAILURES+=("swap ${swapkb}kB < worst-case image ${got}kB (MemTotal * 35/32)")
  fi

  if (( ${#FAILURES[@]} )); then
    printf '==> VERIFY FAIL: %s\n' "${FAILURES[@]}" >&2
    die "verify failed: ${FAILURES[0]}"
  fi
  msg "verify: all invariants hold"
}

verify_mount() {
  [[ -z $MNT ]] && return 0
  findmnt -M "$MNT" >/dev/null && return 0
  [[ -n ${LUKS_PASSPHRASE:-} ]] || die "verify: $MNT not mounted and no LUKS_PASSPHRASE to open $CRYPT"
  if [[ ! -b $DEV ]]; then
    printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open --key-file - "$CRYPT" "$MAPPER"
    wait_for "$DEV"
  fi
  if [[ ! -b $SWAPDEV ]]; then
    printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open --key-file - "$SWAPCRYPT" "$SWAPMAPPER" ||
      warn "could not open $SWAPCRYPT; swap checks will fail"
  fi
  local d
  d=$(mount -o "$MOPTS,subvolid=5" "$DEV" "$MNT" && btrfs subvolume get-default "$MNT" | awk '{print $NF}')
  umount "$MNT"
  mount_tree "$d" snap
}

finish() {
  msg "unmounting"
  release_mnt
  cryptsetup close "$SWAPMAPPER" 2>/dev/null || true
  cryptsetup close "$MAPPER"
  msg "install complete; reboot and remove the install medium"
}

main() {
  preflight
  if [[ $MODE == verify ]]; then
    verify_mount
    verify
    return 0
  fi
  if [[ $MODE == snapper ]]; then
    snapper_setup
    return 0
  fi
  if [[ $MODE == power ]]; then
    sleep_config
    return 0
  fi
  banner
  read_secret LUKS_PASSPHRASE "LUKS passphrase"
  read_secret USER_PASSWORD  "password for user $USERNAME"
  partition
  luks
  filesystems
  subvolumes
  mount_tree @
  install_base
  keyfile
  configure
  passwords
  snapper_setup
  sleep_config
  grub_config
  write_fstab
  first_snapshot
  remount_snapshot
  bootloader
  verify
  cp -f "$LOG" "$MNT/var/log/arch-install.log" 2>/dev/null || true
  chmod 600 "$MNT/var/log/arch-install.log" 2>/dev/null || true
  finish
}

sentinel() {
  local rc=$1 d
  printf '===INSTALL-DONE rc=%d===\n' "$rc"
  for d in /dev/console /dev/ttyS0; do
    if [[ -w $d ]]; then printf '===INSTALL-DONE rc=%d===\n' "$rc" >"$d" 2>/dev/null || true; fi
  done
  return 0
}

on_exit() {
  local rc=$1
  if [[ -d $MNT/var/log ]] && findmnt -M "$MNT" >/dev/null 2>&1; then
    cp -f "$LOG" "$MNT/var/log/arch-install.log" 2>/dev/null || true
    chmod 600 "$MNT/var/log/arch-install.log" 2>/dev/null || true
    sync
  fi
  sentinel "$rc"
}

# main must not be the condition of an `if`, or the operand of `||`: bash
# suppresses errexit for the whole of such a command, including every function
# it calls, so a failed pacstrap would run the rest of the install anyway.
# Redirect through a process substitution instead of a pipeline and let the
# EXIT trap carry the status out.
: >"$LOG"
trap 'on_exit "$?"' EXIT
exec > >(tee -a "$LOG") 2>&1
main
