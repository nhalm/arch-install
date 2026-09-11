#!/usr/bin/env bash
# Proves the hibernate/resume wiring without a VM, a reboot, or root.
#
# systemd's generators are pure functions of their input: point them at a
# crypttab and a cmdline via SYSTEMD_CRYPTTAB / SYSTEMD_PROC_CMDLINE, run them
# with SYSTEMD_IN_INITRD=1, and they emit exactly the units the initramfs would
# get at boot. So the two silent-failure modes in this design -- "hibernate has
# no target" and "swap is reformatted on every boot" -- are both testable here.
#
# Usage: ./test/generator-test.sh
set -euo pipefail

CRYPTGEN=/usr/lib/systemd/system-generators/systemd-cryptsetup-generator
RESUMEGEN=/usr/lib/systemd/system-generators/systemd-hibernate-resume-generator
SWAPUUID=11111111-2222-3333-4444-555555555555
ROOTUUID=00000000-0000-0000-0000-000000000000
KEYFILE=/etc/cryptsetup-keys.d/root.key
SWAPKEY=/etc/cryptsetup-keys.d/swap.key
SWAPDEV=/dev/mapper/swap

PASS=0 FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
want() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

for g in "$CRYPTGEN" "$RESUMEGEN"; do
  [[ -x $g ]] || { echo "missing generator: $g" >&2; exit 1; }
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# The crypttab arch-install.sh writes, and the one-word mistake it warns about.
cat >"$T/crypttab.good" <<EOF
root UUID=$ROOTUUID $KEYFILE luks,discard
swap UUID=$SWAPUUID $SWAPKEY luks,x-initrd.attach
EOF
sed 's/luks,x-initrd.attach/luks,swap/' "$T/crypttab.good" >"$T/crypttab.bad"

run_cryptgen() {
  local tab=$1 out=$2
  mkdir -p "$out"
  SYSTEMD_IN_INITRD=1 SYSTEMD_CRYPTTAB="$tab" "$CRYPTGEN" "$out" "$out" "$out" 2>/dev/null
}
run_resumegen() {
  local cmdline=$1 out=$2
  mkdir -p "$out"
  SYSTEMD_IN_INITRD=1 SYSTEMD_PROC_CMDLINE="$cmdline" "$RESUMEGEN" "$out" "$out" "$out" 2>/dev/null
}

echo "== crypttab: the swap unit the initramfs would get =="
run_cryptgen "$T/crypttab.good" "$T/good"
U=$T/good/systemd-cryptsetup@swap.service
if [[ -f $U ]]; then
  ok "swap unit generated"
  # The whole point of the x-initrd.attach option.
  want "no systemd-makefs (would reformat swap every boot)" \
       "$(grep -c 'systemd-makefs' "$U" || true)" "0"
  want "no Conflicts=umount.target (mapping survives switch-root)" \
       "$(grep -c '^Conflicts=umount.target' "$U" || true)" "0"
  # systemd-escape emits \x2d for each dash, so match it literally.
  want "BindsTo the swap device" \
       "$(grep -Fc "BindsTo=dev-disk-by\\x2duuid-$(systemd-escape "$SWAPUUID")" "$U" || true)" "1"
else
  bad "swap unit generated"
fi

echo "== crypttab: the 'swap' option is genuinely destructive =="
run_cryptgen "$T/crypttab.bad" "$T/bad"
B=$T/bad/systemd-cryptsetup@swap.service
if [[ -f $B ]]; then
  # If this ever stops being true the warning in keyfile() can be relaxed.
  want "'swap' option adds systemd-makefs" \
       "$(grep -c 'systemd-makefs' "$B" || true)" "1"
  want "'swap' option adds Conflicts=umount.target" \
       "$(grep -c '^Conflicts=umount.target' "$B" || true)" "1"
else
  bad "bad-crypttab unit generated (test itself is broken)"
fi

echo "== resume=: armed by the cmdline, and only by the cmdline =="
run_resumegen "root=/dev/mapper/root rootfstype=btrfs zswap.enabled=1 resume=$SWAPDEV" "$T/with"
want "hibernate-resume.service pulled into sysinit.target" \
     "$(test -L "$T/with/sysinit.target.wants/systemd-hibernate-resume.service" && echo yes || echo no)" "yes"
want "resume unit BindsTo dev-mapper-swap.device" \
     "$(grep -rc 'BindsTo=dev-mapper-swap.device' "$T/with" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')" "1"
want "swap device job timeout is infinite" \
     "$(grep -rc 'JobTimeoutSec=infinity' "$T/with" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')" "1"

run_resumegen "root=/dev/mapper/root rootfstype=btrfs" "$T/without"
want "no resume= means no units at all (hibernate would have no target)" \
     "$(find "$T/without" -type f -o -type l | wc -l)" "0"

echo "== the resume hook is not involved =="
# HOOKS must not gain 'resume': that belongs to the busybox/udev path. The unit
# above is what does the work, and it came from the generator, not a hook.
want "vendor unit orders itself before any mount" \
     "$(grep -c '^Before=local-fs-pre.target' /usr/lib/systemd/system/systemd-hibernate-resume.service || true)" "1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
