#!/usr/bin/env bash
# Host-side driver: boot the installed disk, answer GRUB's passphrase prompt,
# log in, and run a script inside the booted system.
#
#   ./test/drive-runtime.sh <script-name-in-www> [timeout]
#
# GRUB's prompt goes to the EFI console, not the serial port, and produces no
# serial output at all -- so there is nothing to wait for and the passphrase has
# to be typed blind, on a timer, through QMP. Once the kernel starts, the
# test-only console=ttyS0 makes the rest observable.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMTEST="$HERE/vmtest.sh"
LOG="$HERE/serial.log"
SCRIPT="${1:?usage: drive-runtime.sh <script-in-www> [timeout]}"
LIMIT="${2:-600}"
PASSPHRASE="${LUKS_PASSPHRASE:-vmtestluks}"
USERNAME="${USERNAME:-nick}"
USERPASS="${USER_PASSWORD:-vmtestuser}"
PORT="${PORT:-8123}"

say() { printf '>>> %s\n' "$*"; }

# Serve www if nothing is listening.
if ! curl -sf --max-time 2 "http://127.0.0.1:$PORT/$SCRIPT" >/dev/null; then
  say "starting http server for $HERE/www"
  setsid python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$HERE/www" \
    >/dev/null 2>&1 </dev/null &
  sleep 1
fi
curl -sf --max-time 3 "http://127.0.0.1:$PORT/$SCRIPT" >/dev/null ||
  { echo "cannot serve $SCRIPT" >&2; exit 1; }

"$VMTEST" stop >/dev/null 2>&1
say "booting the installed disk"
"$VMTEST" run >/dev/null

# OVMF with no display routes the firmware console to the serial port, so GRUB's
# passphrase prompt DOES appear in the log. Wait for it rather than guessing at a
# sleep -- a blind timer races the boot and silently mistypes the passphrase into
# whatever is on screen at the time.
say "waiting for GRUB's passphrase prompt"
start=$(date +%s)
until grep -aq 'Enter passphrase for' "$LOG" 2>/dev/null; do
  if ! pgrep -f qemu-system >/dev/null; then echo "qemu died before GRUB" >&2; exit 125; fi
  if [ $(( $(date +%s) - start )) -ge 180 ]; then
    echo "no GRUB passphrase prompt within 180s" >&2
    tail -20 "$LOG" | tr -d '\r' >&2; exit 124
  fi
  sleep 2
done
say "prompt reached; sending the passphrase"
sleep 1
"$VMTEST" key "$PASSPHRASE"

# argon2id in GRUB, then the kernel. The login prompt is the first thing that
# proves the passphrase was accepted and the system actually booted.
say "waiting for a login prompt (proves GRUB unlocked and the kernel came up)"
start=$(date +%s)
until grep -aq 'login:' "$LOG" 2>/dev/null; do
  if [ $(( $(date +%s) - start )) -ge "$LIMIT" ]; then
    echo "timeout waiting for login prompt" >&2
    tail -30 "$LOG" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' >&2
    exit 124
  fi
  sleep 3
done
say "login prompt reached"

# Wait for a string to appear AFTER a byte offset, so a prompt from an earlier
# failed attempt cannot satisfy the wait. Typing into a prompt that is not there
# yet is how the password ends up echoed at the next login prompt instead.
wait_for_after() {
  local pat=$1 from=$2 limit=${3:-90} start
  start=$(date +%s)
  until tail -c "+$from" "$LOG" 2>/dev/null | grep -aq "$pat"; do
    if [ $(( $(date +%s) - start )) -ge "$limit" ]; then
      echo "timeout waiting for '$pat'" >&2; return 1
    fi
    sleep 1
  done
}

# Root is locked by design, so go in as the user and escalate with sudo -S.
off=$(( $(wc -c < "$LOG") + 1 ))
"$VMTEST" send "$USERNAME" >/dev/null
wait_for_after 'Password:' "$off" 60 || exit 124
off=$(( $(wc -c < "$LOG") + 1 ))
"$VMTEST" send "$USERPASS" >/dev/null
# The shell prompt is the proof the password was accepted.
wait_for_after "@${HOSTNAME_EXPECT:-archvm}" "$off" 60 || {
  echo "login did not reach a shell" >&2; tail -12 "$LOG" | tr -d '\r' >&2; exit 124; }
say "logged in"
off=$(( $(wc -c < "$LOG") + 1 ))
"$VMTEST" send "echo $USERPASS | sudo -S curl -fsSL -o /tmp/t.sh http://10.0.2.2:$PORT/$SCRIPT && echo $USERPASS | sudo -S bash /tmp/t.sh" >/dev/null

say "running $SCRIPT in the guest"
start=$(date +%s)
until grep -aqE '===(RUNTIME|HIBERNATE-TEST|ROLLBACK-TEST|GUEST)-DONE rc=[0-9]+===' "$LOG" 2>/dev/null; do
  if ! pgrep -f qemu-system >/dev/null; then
    say "qemu exited (expected if the guest hibernated or powered off)"
    exit 0
  fi
  if [ $(( $(date +%s) - start )) -ge "$LIMIT" ]; then
    echo "timeout waiting for the guest script" >&2
    exit 124
  fi
  sleep 3
done
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tail -60
