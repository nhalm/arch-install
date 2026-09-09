#!/usr/bin/env bash
# Unattended Arch install, variant 2: LUKS2 + btrfs + snapper + GRUB with
# GRUB_ENABLE_CRYPTODISK. /boot lives inside the root subvolume and root is
# mounted through the btrfs default subvolume, so `snapper rollback` restores
# kernel and initramfs along with the OS.
# Env: DISK (required) TARGET_HOSTNAME USERNAME TZ LOCALE KEYMAP UCODE
#      EXTRA_PACKAGES CONFIRM=yes LUKS_PASSPHRASE USER_PASSWORD ROOT_PASSWORD
#      LUKS_PBKDF_MEMORY
# Usage: DISK=/dev/vda CONFIRM=yes ./arch-install-v2.sh [install|verify]
set -euo pipefail

if [[ ${HOSTNAME:-} == "$(uname -n)" ]]; then unset HOSTNAME; fi
DISK="${DISK:?set DISK, e.g. /dev/vda or /dev/nvme0n1}"
HOSTNAME="${TARGET_HOSTNAME:-${HOSTNAME:-asus}}"
USERNAME="${USERNAME:-nick}"
TZ="${TZ:-US/Central}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"
UCODE="${UCODE:-intel-ucode}"
EXTRA_PACKAGES="${EXTRA_PACKAGES-git}"
CONFIRM="${CONFIRM:-no}"
LUKS_PBKDF_MEMORY="${LUKS_PBKDF_MEMORY-524288}"
MODE="${1:-install}"

MNT="${MNT:-/mnt}"
MNT="${MNT%/}"
LOG=/tmp/arch-install.log
MAPPER=root
DEV=/dev/mapper/$MAPPER
MOPTS=rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2
ESP_GUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
LUKS_GUID=CA7D7CCB-63ED-4C53-861C-1742536059CC
KEYFILE=/etc/cryptsetup-keys.d/root.key
NESTED=(home var/log var/cache/pacman/pkg)
SNAPNUM=
SNAPSUB=

case "$DISK" in *nvme*|*mmcblk*|*loop*) P=p ;; *) P= ;; esac
ESP="${DISK}${P}1"
CRYPT="${DISK}${P}2"

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
  (( EUID == 0 )) || die "must run as root"
  [[ -d /sys/firmware/efi/efivars ]] || die "not booted in UEFI mode"
  # The installed system has none of the install-time tooling (gptfdisk,
  # arch-install-scripts, dosfstools), so `verify` must not demand it.
  local t tools=(cryptsetup btrfs blkid lsblk findmnt)
  if [[ $MODE != verify ]]; then
    tools+=(sgdisk mkfs.btrfs mkfs.fat pacstrap arch-chroot genfstab partprobe udevadm)
  elif [[ -n $MNT ]]; then
    tools+=(arch-chroot)
  fi
  for t in "${tools[@]}"; do
    command -v "$t" >/dev/null || die "missing tool: $t"
  done
  [[ -b $DISK ]] || die "DISK=$DISK is not a block device"
  [[ $(lsblk -dno TYPE "$DISK") == disk ]] || die "DISK=$DISK is not a whole disk"

  if [[ $MODE != verify ]]; then
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
}

banner() {
  msg "DISK=$DISK ESP=$ESP CRYPT=$CRYPT"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL "$DISK" || true
  cat <<EOF

  DESTRUCTIVE: every partition, filesystem and byte of data on
  $DISK will be erased.

  target: hostname=$HOSTNAME user=$USERNAME tz=$TZ locale=$LOCALE keymap=$KEYMAP ucode=$UCODE
  layout: GRUB cryptodisk, /boot inside the root subvolume, root via default subvolume

EOF
  [[ $CONFIRM == yes ]] || die "refusing without CONFIRM=yes in the environment"
}

partition() {
  msg "partitioning $DISK"
  sgdisk --zap-all "$DISK"
  sgdisk -n1:1MiB:+1GiB -t1:"$ESP_GUID"  -c1:ESP       "$DISK"
  # luksFormat --sector-size 4096 refuses a device whose size is not a multiple
  # of 4096; GPT's 33-sector backup table leaves the last usable LBA off a
  # 4096-byte boundary, so round it down.
  local lss grain last end
  lss=$(lsblk -dno LOG-SEC "$DISK")
  grain=$(( 4096 / lss )); (( grain >= 1 )) || grain=1
  last=$(sgdisk -E "$DISK")
  end=$(( last - ( (last + 1) % grain ) ))
  sgdisk -n2:0:"$end"   -t2:"$LUKS_GUID" -c2:cryptroot "$DISK"
  partprobe "$DISK"
  udevadm settle
  wait_for "$ESP"
  wait_for "$CRYPT"
  lsblk -o NAME,SIZE,TYPE,PARTTYPENAME "$DISK"
}

luks() {
  local pbkdf=()
  [[ -n $LUKS_PBKDF_MEMORY ]] && pbkdf=(--pbkdf-memory "$LUKS_PBKDF_MEMORY")
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
  local pkgs=(base linux linux-firmware "$UCODE" btrfs-progs cryptsetup grub efibootmgr
              snapper snap-pac zram-generator networkmanager sudo vim man-db man-pages)
  if [[ -n $EXTRA_PACKAGES ]]; then
    local extra=()
    read -ra extra <<<"$EXTRA_PACKAGES"
    pkgs+=("${extra[@]}")
  fi
  msg "pacstrap: ${pkgs[*]}"
  pacstrap -K "$MNT" "${pkgs[@]}"
}

keyfile() {
  msg "initramfs keyfile"
  local uuid pbkdf=()
  [[ -n $LUKS_PBKDF_MEMORY ]] && pbkdf=(--pbkdf-memory "$LUKS_PBKDF_MEMORY")
  uuid=$(blkid -s UUID -o value "$CRYPT")
  [[ -n $uuid ]] || die "could not read LUKS UUID from $CRYPT"
  install -d -m 700 "$MNT/etc/cryptsetup-keys.d"
  ( umask 377; dd if=/dev/urandom of="$MNT$KEYFILE" bs=512 count=8 status=none )
  chmod 000 "$MNT$KEYFILE"
  printf '%s' "$LUKS_PASSPHRASE" |
    cryptsetup luksAddKey "${pbkdf[@]}" --key-file - "$CRYPT" "$MNT$KEYFILE"
  printf 'root UUID=%s %s luks,discard\n' "$uuid" "$KEYFILE" >"$MNT/etc/crypttab.initramfs"
  chmod 600 "$MNT/etc/crypttab.initramfs"
  cryptsetup luksDump "$CRYPT" | grep -E '^[[:space:]]*[0-9]+: luks2' || true
}

configure() {
  msg "chroot configuration"
  {
    printf '#!/bin/bash\nset -euo pipefail\n'
    printf 'HOSTNAME=%q\nUSERNAME=%q\nTZ=%q\nLOCALE=%q\nKEYMAP=%q\nKEYFILE=%q\n' \
      "$HOSTNAME" "$USERNAME" "$TZ" "$LOCALE" "$KEYMAP" "$KEYFILE"
    cat <<'CHROOT_BODY'
ln -sf /usr/share/zoneinfo/"$TZ" /etc/localtime
hwclock --systohc
sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE"   > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME"      > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	$HOSTNAME.localdomain $HOSTNAME
HOSTS

sed -i "s|^FILES=.*|FILES=($KEYFILE)|" /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
grep -q '^HOOKS=(base systemd keyboard' /etc/mkinitcpio.conf
grep -q "^FILES=($KEYFILE)" /etc/mkinitcpio.conf
mkinitcpio -P
# The linux package's preset builds only 'default' on this release, but the
# fallback menu entry points at initramfs-linux-fallback.img. Build it the way
# the fallback preset would (-S autodetect: every module, not just this host's).
[[ -s /boot/initramfs-linux-fallback.img ]] ||
  mkinitcpio -k /boot/vmlinuz-linux -g /boot/initramfs-linux-fallback.img -S autodetect
lsinitcpio /boot/initramfs-linux.img | grep -q "cryptsetup-keys.d/root.key" ||
  echo "==> WARNING: keyfile not found in initramfs; expect two passphrase prompts" >&2

cat > /etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
ZRAM

systemctl enable NetworkManager
id -u "$USERNAME" >/dev/null 2>&1 || useradd -m -G wheel "$USERNAME"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL$/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
visudo -c >/dev/null
grep -q '^%wheel ALL=(ALL:ALL) ALL$' /etc/sudoers
grep -q '^PRUNENAMES.*\.snapshots' /etc/updatedb.conf 2>/dev/null ||
  echo 'PRUNENAMES = ".snapshots"' >> /etc/updatedb.conf
CHROOT_BODY
  } >"$MNT/root/chroot-setup.sh"
  arch-chroot "$MNT" bash /root/chroot-setup.sh
  rm -f "$MNT/root/chroot-setup.sh"
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

snapper_setup() {
  msg "snapper"
  [[ ! -e $MNT/.snapshots ]] || die ".snapshots present before create-config"
  arch-chroot "$MNT" snapper --no-dbus -c root create-config /
  mount_snapshots

  # home's .snapshots is a nested subvolume inside @/home. `snapper rollback`
  # refuses any config whose SUBVOLUME is not / (doc s10.1), so @/home is never
  # swapped wholesale and the nesting hazard does not apply.
  arch-chroot "$MNT" snapper --no-dbus -c home create-config /home

  # Limits are ranges on purpose. Range::is_degenerated() is min==max, and
  # Cleaner::is_free_aware() returns false for a degenerate range, so a scalar
  # NUMBER_LIMIT silently switches FREE_LIMIT off (doc s6.1).
  arch-chroot "$MNT" snapper --no-dbus -c root set-config \
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

  arch-chroot "$MNT" snapper --no-dbus -c home set-config \
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

  arch-chroot "$MNT" systemctl enable snapper-timeline.timer snapper-cleanup.timer
  arch-chroot "$MNT" snapper --no-dbus -c root get-config |
    grep -E 'TIMELINE_LIMIT_HOURLY|NUMBER_LIMIT|ALLOW_USERS|QGROUP|SYNC_ACL|FREE_LIMIT' || true
  arch-chroot "$MNT" snapper --no-dbus -c home get-config |
    grep -E 'NUMBER_LIMIT|TIMELINE_LIMIT_WEEKLY|ALLOW_USERS' || true
}

grub_config() {
  msg "grub configuration"
  cat > "$MNT/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="rw rootfstype=btrfs zswap.enabled=0"
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
ifchanged=0
if [[ ${1:-} == --if-changed ]]; then ifchanged=1; shift; fi
t=${1:-/}
cur=$(btrfs subvolume get-default / | awk '{print $NF}')
if (( ifchanged )) && [[ -r $stamp && $(cat "$stamp") == "$cur" ]] &&
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
    grep -q 'rootflags=subvol=' "$cfg" && FAILURES+=("grub.cfg has rootflags=subvol=")
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
  check "mkinitcpio FILES=" grep -qx "FILES=($KEYFILE)" "$MNT/etc/mkinitcpio.conf"
  check "keyfile in initramfs" target \
    bash -c "lsinitcpio /boot/initramfs-linux.img | grep -q cryptsetup-keys.d/root.key"

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
  check "zram-generator.conf" test -s "$MNT/etc/systemd/zram-generator.conf"
  check "vconsole.conf" test -s "$MNT/etc/vconsole.conf"

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
  local d
  d=$(mount -o "$MOPTS,subvolid=5" "$DEV" "$MNT" && btrfs subvolume get-default "$MNT" | awk '{print $NF}')
  umount "$MNT"
  mount_tree "$d" snap
}

finish() {
  msg "unmounting"
  release_mnt
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
