#!/usr/bin/env bash
# Headless Arch ISO test harness. Boots archiso under QEMU/OVMF with a serial
# console captured to a log, optionally running a script fetched from the host.
set -euo pipefail

VM="${VM:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ISO="${ISO:-$(ls "$VM"/archlinux-*.iso 2>/dev/null | tail -1)}"
DISK="$VM/test.qcow2"
VARS="$VM/OVMF_VARS.fd"
CODE="${CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
VARS_TPL="${VARS_TPL:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"
KERNEL="$VM/vmlinuz-linux"
INITRD="$VM/initramfs-linux.img"
WWW="$VM/www"
LOG="$VM/serial.log"
SOCK="$VM/serial.sock"
PIDF="$VM/vm.pid"
HTTPPID="$VM/http.pid"

SIZE="${SIZE:-20G}"
MEM="${MEM:-4096}"
CPUS="${CPUS:-4}"
PORT="${PORT:-8123}"
TIMEOUT="${TIMEOUT:-1800}"
SENTINEL_RE='===INSTALL-DONE rc=[0-9]+==='

die() { echo "vmtest: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing: $1"; }

# --- ISO facts -------------------------------------------------------------
# The boot cmdline archiso expects lives in the ISO. Read it, never guess.
iso_uuid() { bsdtar -tf "$ISO" 2>/dev/null | sed -n 's|^boot/\(.*\)\.uuid$|\1|p' | head -1; }
iso_label() { python3 -c "

with open('$ISO','rb') as f: f.seek(16*2048); print(f.read(2048)[40:72].decode().rstrip())
"; }

extract() {
	[ -n "$ISO" ] && [ -f "$ISO" ] || die "no iso found in $VM"
	[ "$KERNEL" -nt "$ISO" ] && [ "$INITRD" -nt "$ISO" ] && return 0
	bsdtar -xOf "$ISO" arch/boot/x86_64/vmlinuz-linux >"$KERNEL"
	bsdtar -xOf "$ISO" arch/boot/x86_64/initramfs-linux.img >"$INITRD"
}

# --- lifecycle -------------------------------------------------------------
vm_running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

stop() {
	if vm_running; then kill "$(cat "$PIDF")" 2>/dev/null || true
		for _ in $(seq 50); do vm_running || break; sleep 0.1; done
		vm_running && kill -9 "$(cat "$PIDF")" 2>/dev/null || true
	fi
	rm -f "$PIDF" "$SOCK"
	if [ -f "$HTTPPID" ]; then kill "$(cat "$HTTPPID")" 2>/dev/null || true; rm -f "$HTTPPID"; fi
}

serve_bg() {
	mkdir -p "$WWW"
	[ -f "$HTTPPID" ] && kill "$(cat "$HTTPPID")" 2>/dev/null || true
	rm -f "$HTTPPID"
	# Fail loudly if the port is already taken: a stale server on the same port
	# will answer the readiness probe while serving the wrong directory.
	local nonce; nonce="$(date +%s%N)"
	echo "$nonce" >"$WWW/.nonce"
	setsid python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WWW" \
		>"$VM/http.log" 2>&1 </dev/null &
	local pid=$!
	echo "$pid" >"$HTTPPID"
	for _ in $(seq 50); do
		kill -0 "$pid" 2>/dev/null || die "http server died: $(tail -1 "$VM/http.log")"
		[ "$(curl -sf --max-time 2 "http://127.0.0.1:$PORT/.nonce" 2>/dev/null)" = "$nonce" ] && return 0
		sleep 0.2
	done
	die "http server did not come up on $PORT"
}

qemu_common=()
build_common() {
	qemu_common=(
		-accel kvm -machine q35,smm=off -cpu host -smp "$CPUS" -m "$MEM"
		-drive "if=pflash,format=raw,unit=0,readonly=on,file=$CODE"
		-drive "if=pflash,format=raw,unit=1,file=$VARS"
		-device virtio-rng-pci
		-drive "if=none,id=hd0,file=$DISK,format=qcow2"
		-device virtio-blk-pci,drive=hd0,bootindex=1
		-netdev "user,id=n0" -device virtio-net-pci,netdev=n0
		-chardev "socket,id=ser0,path=$SOCK,server=on,wait=off,logfile=$LOG,logappend=off"
		-serial chardev:ser0
		-display none -monitor none -no-reboot
	)
}

# --- subcommands -----------------------------------------------------------
cmd_reset() {
	stop
	rm -f "$DISK" "$VARS" "$LOG"
	qemu-img create -q -f qcow2 "$DISK" "$SIZE"
	cp "$VARS_TPL" "$VARS"
	chmod u+w "$VARS"
	echo "reset: blank $SIZE $DISK, fresh $VARS"
}

cmd_boot() {
	local url="${1:-}"
	[ -f "$DISK" ] || cmd_reset
	extract
	local uuid label append
	uuid="$(iso_uuid)"; label="$(iso_label)"
	[ -n "$uuid" ] || die "could not read archiso uuid from $ISO"

	append="archisobasedir=arch archisosearchuuid=$uuid copytoram=n"
	append+=" console=ttyS0,115200 console=tty0 rw"
	if [ -n "$url" ]; then
		# archiso 2026.09 has no script= parameter (no handler exists in the
		# initramfs hooks or the airootfs), so use systemd-run-generator, which
		# turns systemd.run= into a transient unit. That unit is only ordered
		# after basic.target, so it has to start networking itself before the
		# fetch. Keep the command free of single quotes: the whole value is
		# single-quoted inside the double-quoted kernel argument.
		local boot="exec >/dev/ttyS0 2>&1; echo ===GUEST-START===;"
		boot+=" systemctl start systemd-networkd.service systemd-resolved.service;"
		boot+=" systemctl start network-online.target;"
		boot+=" curl -fsS -4 --retry 20 --retry-delay 2 --retry-all-errors"
		boot+=" -o /root/guest.sh $url && bash /root/guest.sh;"
		boot+=" echo ===INSTALL-DONE rc=\$?==="
		append+=" systemd.run=\"/usr/bin/bash -c '$boot'\""
		append+=" systemd.run_success_action=none systemd.run_failure_action=none"
	fi
	echo "label=$label uuid=$uuid"
	echo "cmdline: $append"
	rm -f "$LOG" "$SOCK"
	build_common
	qemu-system-x86_64 "${qemu_common[@]}" \
		-drive "if=none,id=cd0,file=$ISO,format=raw,readonly=on" \
		-device virtio-blk-pci,drive=cd0 \
		-kernel "$KERNEL" -initrd "$INITRD" -append "$append" &
	echo $! >"$PIDF"
	echo "qemu pid $(cat "$PIDF"), serial log $LOG, socket $SOCK"
}

cmd_run() {
	[ -f "$DISK" ] || die "no disk; run reset+install first"
	rm -f "$LOG" "$SOCK"
	build_common
	qemu-system-x86_64 "${qemu_common[@]}" &
	echo $! >"$PIDF"
	echo "qemu pid $(cat "$PIDF"), serial log $LOG"
}

# Block until the sentinel appears, qemu exits, or the timeout expires.
# Exit status: the guest's rc on sentinel, 124 on timeout, 125 if qemu died.
cmd_wait() {
	local limit="${1:-$TIMEOUT}" start line rc
	start=$(date +%s)
	while :; do
		if line=$(grep -aoE "$SENTINEL_RE" "$LOG" 2>/dev/null | tail -1) && [ -n "$line" ]; then
			rc="${line##*rc=}"; rc="${rc%%=*}"
			echo "wait: $line"
			stop
			return "$rc"
		fi
		if ! vm_running; then echo "wait: qemu exited without sentinel" >&2; stop; return 125; fi
		if [ $(( $(date +%s) - start )) -ge "$limit" ]; then
			echo "wait: timeout after ${limit}s" >&2
			stop
			return 124
		fi
		sleep 1
	done
}

# Type a line into the guest's serial console. QEMU's socket chardev drops
# whatever is still in flight when the peer closes, so pace the write and
# linger before hanging up.
cmd_send() {
	[ -S "$SOCK" ] || die "no serial socket; is the vm running?"
	python3 -c "
import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
for ch in (sys.argv[2]+chr(13)).encode():
    s.sendall(bytes([ch])); time.sleep(0.004)
time.sleep(0.5); s.close()
" "$SOCK" "$*"
}

cmd_serve() { mkdir -p "$WWW"; exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WWW"; }

cmd_log() { tail -n "${1:-40}" "$LOG"; }

# reset -> serve -> boot with a script -> wait. The whole loop in one command.
cmd_cycle() {
	local script="${1:?usage: cycle <local-script> [timeout]}" limit="${2:-$TIMEOUT}"
	mkdir -p "$WWW"
	cp "$script" "$WWW/guest.sh"
	cmd_reset
	serve_bg
	cmd_boot "http://10.0.2.2:$PORT/guest.sh"
	cmd_wait "$limit"
}

need qemu-system-x86_64; need bsdtar; need qemu-img; need python3; need curl
case "${1:-}" in
reset) shift; cmd_reset "$@" ;;
extract) shift; extract; echo "extracted $KERNEL $INITRD" ;;
boot) shift; cmd_boot "$@" ;;
run) shift; cmd_run "$@" ;;
wait) shift; cmd_wait "$@" ;;
send) shift; cmd_send "$@" ;;
serve) shift; cmd_serve "$@" ;;
cycle) shift; cmd_cycle "$@" ;;
stop) shift; stop; echo "stopped" ;;
log) shift; cmd_log "$@" ;;
info) shift; echo "iso=$ISO"; echo "label=$(iso_label)"; echo "uuid=$(iso_uuid)" ;;
*) cat >&2 <<USAGE
usage: vmtest.sh <cmd>
  reset              blank $SIZE qcow2 + fresh OVMF_VARS
  boot [script-url]  boot the ISO headless (backgrounded)
  run                boot the installed disk
  wait [secs]        block for the sentinel; rc = guest rc, 124 timeout, 125 crash
  cycle <sh> [secs]  reset + serve + boot + wait, all in one
  send <text>        type a line into the serial console
  serve              foreground http server for $WWW
  stop | log [n] | info | extract
USAGE
exit 1 ;;
esac
