#!/usr/bin/env bash
# Proves hibernate actually works, and that resume restored the image rather
# than quietly booting fresh. TESTPLAN 2.7.
#
#   phase1  -> machine powers off -> boot it again -> phase2
#
# Two different failures, and they need different evidence:
#
#   "it booted fresh instead of resuming" -- caught by /dev/shm (tmpfs is
#   RAM-only, survives a resume, cannot survive a reboot) plus boot_id, which is
#   regenerated on a fresh boot but not on a resume.
#
#   "it never slept at all" -- NOT caught by either of those, because both are
#   equally true of a machine that simply kept running. This is the likelier
#   failure: a missing resume target and a refused freeze both look like nothing
#   happening. phase2 therefore asks the kernel for evidence of a hibernation
#   cycle in dmesg before it checks anything else.
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
  # `systemctl hibernate` is ASYNCHRONOUS. It returns as soon as logind accepts
  # the request -- "The system will hibernate now!" in the journal -- long
  # before the kernel freezes tasks. Treating its return value as the outcome
  # reports a working hibernate as a failure, which is exactly what this test
  # did on its first run.
  local t0 t1 elapsed
  t0=$(date +%s)
  systemctl hibernate
  # If hibernation succeeds this process is frozen mid-sleep and the machine
  # powers off; the sleep only finishes on the other side of a power cycle.
  sleep 20
  t1=$(date +%s); elapsed=$(( t1 - t0 ))
  # A frozen process cannot observe wall time passing, so a large elapsed here
  # means the machine really did power off and come back. A short one means
  # hibernate never entered.
  (( elapsed > 60 )) ||
    die "still running ${elapsed}s after requesting hibernate -- entry failed"
  msg "resumed after ${elapsed}s of wall time -- the machine hibernated and came back"
  # Running phase2 here is a convenience, not the proof: every value it compares
  # was planted by this same process a minute ago and never left RAM. The wall
  # clock above is one heuristic and cannot tell "powered off for 40 s" from
  # "hibernate took 70 s to fail on a contended host". phase2's own dmesg check
  # is what makes this meaningful -- it asks the kernel, not the test.
  phase2
}

phase2() {
  [[ -f $STATE ]] || die "no $STATE; run phase1 first"
  # shellcheck source=/dev/null
  . "$STATE"
  preflight

  # FIRST: prove the machine actually slept. Everything below this point --
  # boot_id unchanged, the tmpfs marker present, uname -r unchanged -- is
  # equally true of a machine that NEVER SLEPT AT ALL. Those assertions rule out
  # a fresh boot being mistaken for a resume; they do nothing about the likelier
  # failure, which is "hibernate silently did nothing" (a missing resume target
  # and a refused freeze both produce exactly that). Only the kernel can emit
  # these lines, and only on the far side of a real hibernation cycle.
  local resumed
  resumed=$(dmesg 2>/dev/null |
            grep -acE 'PM: hibernation exit|PM: Image loading progress|Restarting tasks \.\.\. done' || true)
  (( resumed > 0 )) ||
    die "no kernel evidence of a hibernation cycle in dmesg -- this machine may never have slept.
    boot_id and the tmpfs marker cannot distinguish that from a resume, so they are not checked."
  msg "kernel confirms a hibernation cycle ($resumed matching dmesg lines)"

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
  echo "===HIBERNATE-TEST rc=0==="
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
