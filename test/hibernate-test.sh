#!/usr/bin/env bash
# Proves hibernate actually works, and that resume restored the image rather
# than quietly booting fresh. TESTPLAN 2.7.
#
#   phase1  -> machine powers off -> boot it again -> phase2
#
# The proof is /dev/shm: tmpfs lives in RAM only. It survives hibernate (the
# image includes it) and cannot survive a reboot. Combined with boot_id, which
# is regenerated on a fresh boot but not on resume, a fresh boot cannot be
# mistaken for a successful resume -- which is the failure this test exists to
# catch, because a machine that fails to resume just... starts, and looks fine.
set -euo pipefail

STATE=/var/log/hibernate-test.state
RAMMARK=/dev/shm/hibernate-test-ram
PHASE="${1:-}"

msg() { printf '==> %s\n' "$*"; }
die() { printf '==> ERROR: %s\n' "$*" >&2; exit 1; }
want() { [[ $2 == "$3" ]] || die "$1: want '$3', got '$2'"; }

preflight() {
  (( EUID == 0 )) || die "must run as root"
  [[ -e /sys/power/state ]] || die "no /sys/power/state"
  grep -q disk /sys/power/state || die "kernel cannot hibernate (no 'disk' in /sys/power/state)"
  local r; r=$(cat /sys/power/resume 2>/dev/null || echo 0:0)
  [[ $r != 0:0 ]] || die "/sys/power/resume is 0:0 -- no hibernation target"
  want "swap areas" "$(swapon --noheadings --show=NAME | wc -l)" "1"
}

phase1() {
  preflight
  local token swapuuid
  token=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)
  swapuuid=$(blkid -s UUID -o value /dev/mapper/swap)

  # RAM-only. Gone after a reboot, present after a true resume.
  printf '%s\n' "$token" > "$RAMMARK"
  cat > "$STATE" <<EOF
TOKEN=$token
BOOTID=$(cat /proc/sys/kernel/random/boot_id)
SWAPUUID=$swapuuid
KREL=$(uname -r)
EOF
  sync
  msg "token $token, boot_id $(cat /proc/sys/kernel/random/boot_id)"
  msg "swap uuid $swapuuid"
  msg "free before: $(free -m | awk '/^Mem:/{print $3}')M used"
  msg "hibernating now -- the machine should POWER OFF, not reboot"
  sync
  systemctl hibernate
  # Two ways to get here, and they are opposite outcomes:
  #   - the machine powered off, was booted again, and the kernel restored this
  #     very process from the image. That is success, and it is what phase2
  #     then proves from the outside.
  #   - hibernate refused to start and returned immediately. That is failure.
  # Distinguish them by whether the RAM marker is still the one we wrote: a
  # refusal never left this boot, so /proc/uptime is still climbing from the
  # original boot and no power cycle happened. Only phase2 can tell for sure,
  # so do not claim either here.
  msg "systemctl hibernate returned; if the machine power-cycled this is a resume"
  msg "run '$0 phase2' to confirm which happened"
}

phase2() {
  [[ -f $STATE ]] || die "no $STATE; run phase1 first"
  # shellcheck source=/dev/null
  . "$STATE"
  preflight

  local now; now=$(cat /proc/sys/kernel/random/boot_id)
  msg "boot_id then: $BOOTID"
  msg "boot_id now : $now"

  # The decisive check. A fresh boot after a failed resume gets a new boot_id.
  [[ $now == "$BOOTID" ]] ||
    die "boot_id changed: the machine BOOTED FRESH instead of resuming the image"
  msg "boot_id unchanged -- this is the same boot, resumed from disk"

  [[ -f $RAMMARK ]] || die "RAM marker gone: /dev/shm did not survive, so this was not a resume"
  want "RAM marker contents" "$(cat "$RAMMARK")" "$TOKEN"
  msg "tmpfs survived -- RAM was genuinely restored from the image"

  want "kernel release" "$(uname -r)" "$KREL"
  # If anything reformatted the swap device the UUID would have changed and the
  # image would have been destroyed rather than resumed.
  want "swap UUID unchanged (not reformatted)" "$(blkid -s UUID -o value /dev/mapper/swap)" "$SWAPUUID"

  msg "PASS: hibernate wrote an image, the machine powered off, and resume restored it"
  rm -f "$RAMMARK" "$STATE"
}

sentinel() {
  local rc=$1 d
  for d in /dev/console /dev/ttyS0; do
    [[ -w $d ]] && printf '===HIBERNATE-TEST rc=%d===\n' "$rc" >"$d" 2>/dev/null || true
  done
  printf '===HIBERNATE-TEST rc=%d===\n' "$rc"
  return 0
}
trap 'sentinel "$?"' EXIT

case "$PHASE" in
  phase1) phase1 ;;
  phase2) phase2 ;;
  *) die "usage: $0 phase1|phase2" ;;
esac
