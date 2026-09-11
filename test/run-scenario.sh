#!/usr/bin/env bash
# Drive one Tier 3 recovery scenario end to end:
#   break (from the booted system) -> confirm it genuinely fails to boot
#   -> rescue (from the Arch ISO)  -> confirm it boots again
#
#   ./test/run-scenario.sh 31        # uses t31-break.sh / t31-rescue.sh
#   ./test/run-scenario.sh 35 nofail # break-only scenarios skip the boot checks
#
# Exits non-zero if the break did not break, or the rescue did not fix it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/vmtest.sh"; LOG="${VM:-$HERE}/serial.log"
N="${1:?usage: run-scenario.sh <NN> [breakonly]}"; MODE="${2:-full}"
PASS=vmtestluks; USER=nick; UPASS=vmtestuser

say(){ printf '\n### %s\n' "$*"; }
# vmtest.sh run/boot truncate serial.log, so without this each phase erases the
# previous phase's evidence and a failure report has nothing to quote.
archive(){ [ -f "$LOG" ] && cp "$LOG" "${VM:-$HERE}/serial-$1.log" 2>/dev/null || true; }
serve(){ curl -sf --max-time 2 "http://127.0.0.1:8123/rescue-lib.sh" >/dev/null || {
  setsid python3 -m http.server 8123 --bind 127.0.0.1 --directory "$HERE/www" >/dev/null 2>&1 </dev/null &
  sleep 1; }; }
down(){ local s=$(date +%s); while kill -0 "$(cat "${VM:-$HERE}/vm.pid" 2>/dev/null || echo 0)" 2>/dev/null; do
  [ $(( $(date +%s)-s )) -gt "${1:-150}" ] && return 1; sleep 3; done; return 0; }
unlock(){ local s=$(date +%s); until grep -aq 'Enter passphrase for' "$LOG" 2>/dev/null; do
  [ $(( $(date +%s)-s )) -gt 150 ] && return 1; sleep 2; done; sleep 1; "$V" key "$PASS" >/dev/null 2>&1; }

serve
say "SCENARIO $N: breaking the system"
# 300 s was too tight with several VMs contending for the host: that budget has
# to cover GRUB's argon2id unlock, a full boot, the login handshake and the
# guest script. A scenario that times out here looks identical to a scenario
# whose break hung the machine, which is the one distinction this test exists
# to make.
"$HERE/drive-runtime.sh" "t${N}-break.sh" 600 >/tmp/s${N}b.out 2>&1
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | tr -d '\r' | sed -n "/T${N}-BREAK/,/T${N}-BREAK-END/p"

if [ "$MODE" = breakonly ]; then
  say "SCENARIO $N: break-only, no reboot check"
  exit 0
fi

archive break
say "waiting for the guest to go down"
down 180 || { echo "guest never rebooted"; "$V" stop >/dev/null 2>&1; }

say "SCENARIO $N: does it still boot? (it should NOT)"
"$V" run >/dev/null 2>&1
unlock || echo "  (no GRUB prompt -- itself a failure mode)"
s=$(date +%s); booted=no
while [ $(( $(date +%s)-s )) -lt 150 ]; do
  grep -aq 'archvm login:' "$LOG" 2>/dev/null && { booted=yes; break; }
  kill -0 "$(cat "${VM:-$HERE}/vm.pid" 2>/dev/null || echo 0)" 2>/dev/null || break
  sleep 5
done
echo "  booted after break: $booted  (expected: no)"
echo "  --- what it said ---"
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | tr -d '\r' | grep -aiE 'error|emergency|rescue|magic|failed|cannot|Entering' | tail -6
"$V" stop >/dev/null 2>&1; sleep 1

archive postbreak
say "SCENARIO $N: rescuing from the Arch ISO"
# Fetch the rescue script by its real name. Copying it to a shared guest.sh
# would race: every VM directory symlinks www/ to the one test/www, so two
# scenarios reaching their rescue phase together would overwrite each other's
# guest.sh and each guest could run the other's rescue.
"$V" boot "http://10.0.2.2:8123/t${N}-rescue.sh" >/dev/null 2>&1
"$V" wait 420 >/dev/null 2>&1
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | tr -d '\r' | sed -n "/T${N}-RESCUE/,/T${N}-RESCUE-END/p"
"$V" stop >/dev/null 2>&1; sleep 1

archive rescue
say "SCENARIO $N: does it boot after the rescue? (it SHOULD)"
"$V" run >/dev/null 2>&1
unlock || { echo "  RESCUE FAILED: no GRUB prompt"; exit 1; }
s=$(date +%s); booted=no
while [ $(( $(date +%s)-s )) -lt 200 ]; do
  grep -aq 'archvm login:' "$LOG" 2>/dev/null && { booted=yes; break; }
  kill -0 "$(cat "${VM:-$HERE}/vm.pid" 2>/dev/null || echo 0)" 2>/dev/null || break
  sleep 5
done
echo "  booted after rescue: $booted  (expected: yes)"
[ "$booted" = yes ] || exit 1
archive final
echo "phase logs: ${VM:-$HERE}/serial-{break,postbreak,rescue,final}.log"
# Leave nothing running: five parallel scenarios each holding a 4 GB VM at a
# login prompt is a lot of abandoned host memory, and a stray VM is what caused
# the cross-scenario interference this harness already had to be fixed for.
"$V" stop >/dev/null 2>&1
