#!/usr/bin/env bash
# Runtime checks on the BOOTED install. Run inside the guest after a normal
# boot, not from the ISO. Covers TESTPLAN 2.4, 2.6, 2.8 and 2.9.
#
#   ./test/vmtest.sh run          # boot the installed disk
#   ./test/vmtest.sh send 'curl -fsSL http://10.0.2.2:8123/guest-runtime.sh | bash'
set -uo pipefail

PASS=0 FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
want() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

echo "== swap and zswap =="
want "exactly one swap area" "$(swapon --noheadings --show=NAME | wc -l)" "1"
# swapon reports /dev/dm-N, not the mapper symlink -- resolve both sides.
want "swap is the LUKS mapping" "$(readlink -f "$(swapon --noheadings --show=NAME | head -1)")" "$(readlink -f /dev/mapper/swap)"
want "no zram device" "$(test -e /sys/block/zram0 && echo yes || echo no)" "no"
want "zswap enabled" "$(cat /sys/module/zswap/parameters/enabled 2>/dev/null)" "Y"
want "zswap compressor" "$(cat /sys/module/zswap/parameters/compressor 2>/dev/null)" "zstd"
want "zswap shrinker" "$(cat /sys/module/zswap/parameters/shrinker_enabled 2>/dev/null)" "Y"

echo "== hibernation is actually armed =="
r=$(cat /sys/power/resume 2>/dev/null || echo 0:0)
[[ $r != 0:0 ]] && ok "/sys/power/resume set ($r)" || bad "/sys/power/resume unset — hibernate has no target"
want "disk in /sys/power/state" "$(grep -c disk /sys/power/state)" "1"
want "hibernate-resume unit armed" \
  "$(systemctl is-active systemd-hibernate-resume.service >/dev/null 2>&1 && echo yes || \
     systemctl show systemd-hibernate-resume.service -p LoadState --value)" "loaded"
# The image must fit. MemTotal * 35/32 is the kernel's worst-case expansion.
mem=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
need=$(( mem * 35 / 32 ))
have=$(( $(swapon --noheadings --show=SIZE --bytes | head -1) / 1024 ))
(( have >= need )) && ok "swap ${have}kB >= worst-case image ${need}kB" \
                   || bad "swap ${have}kB < worst-case image ${need}kB"

echo "== the swap device was not reformatted =="
# If something re-ran mkswap, the UUID changes and any image is gone.
want "swap has a stable UUID" "$(blkid -s UUID -o value /dev/mapper/swap >/dev/null 2>&1 && echo yes || echo no)" "yes"
want "no systemd-makefs in the swap unit" \
  "$(systemctl cat systemd-cryptsetup@swap.service 2>/dev/null | grep -c systemd-makefs)" "0"

echo "== sleep policy =="
want "effective HibernateDelaySec" \
  "$(systemd-analyze cat-config systemd/sleep.conf | sed -n 's/^HibernateDelaySec=//p' | tail -1)" "30min"
want "effective HibernateOnACPower" \
  "$(systemd-analyze cat-config systemd/sleep.conf | sed -n 's/^HibernateOnACPower=//p' | tail -1)" "no"
want "effective HandleLidSwitch" \
  "$(systemd-analyze cat-config systemd/logind.conf | sed -n 's/^HandleLidSwitch=//p' | tail -1)" "suspend-then-hibernate"
want "logind reports hibernate possible" "$(systemctl hibernate --dry-run >/dev/null 2>&1 && echo yes || echo no)" "yes"

echo "== services =="
for u in systemd-timesyncd.service systemd-resolved.service systemd-oomd.service \
         fstrim.timer paccache.timer reflector.timer thermald.service \
         power-profiles-daemon.service fwupd-refresh.timer smartd.service bluetooth.service; do
  want "$u enabled" "$(systemctl is-enabled "$u" 2>/dev/null)" "enabled"
done
# is-enabled exits non-zero for a disabled unit, so the || would append a
# second line to its output. Take the first.
want "systemd-networkd NOT enabled" "$( { systemctl is-enabled systemd-networkd.service 2>/dev/null || echo disabled; } | head -1)" "disabled"
want "NTP actually synchronising" "$(timedatectl show -p NTP --value)" "yes"

echo "== no duplicate rw on the live cmdline =="
want "rw appears once" "$(tr ' ' '\n' </proc/cmdline | grep -cx rw)" "1"
want "zswap.enabled=1 on live cmdline" "$(grep -c 'zswap.enabled=1' /proc/cmdline)" "1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
echo "===RUNTIME-DONE rc=$(( FAIL > 0 ))==="
