#!/usr/bin/env bash
# Clone the installed disk into N independent VM directories so several
# recovery scenarios can run at once.
#
# Everything a running VM touches -- disk, OVMF vars, serial log, sockets,
# pidfile -- lives under $VM, so giving each scenario its own directory is
# enough to isolate them. The HTTP server is deliberately NOT duplicated: every
# guest reaches the host at 10.0.2.2:8123 through its own slirp instance, so one
# server on the host serves all of them with no port conflict.
#
#   ./test/parallel-setup.sh 31 32 33 34
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLDEN="$HERE/golden.qcow2"
ISO=$(ls "$HERE"/archlinux-*.iso | tail -1)
VARS_TPL=/usr/share/edk2/x64/OVMF_VARS.4m.fd

[ -f "$GOLDEN" ] || { echo "no golden image at $GOLDEN" >&2; exit 1; }

for n in "$@"; do
  d="$HERE/vm$n"
  rm -rf "$d"; mkdir -p "$d"
  # qcow2 backing file: each VM gets copy-on-write over the golden image, so
  # setup is instant and a scenario's damage cannot reach the others.
  qemu-img create -q -f qcow2 -F qcow2 -b "$GOLDEN" "$d/test.qcow2"
  cp "$VARS_TPL" "$d/OVMF_VARS.fd"; chmod u+w "$d/OVMF_VARS.fd"
  ln -sf "$ISO" "$d/$(basename "$ISO")"
  ln -sf "$HERE/www" "$d/www"
  # vmtest.sh extracts these from the ISO if missing; share the host's copies
  for f in vmlinuz-linux initramfs-linux.img; do
    [ -f "$HERE/$f" ] && ln -sf "$HERE/$f" "$d/$f"
  done
  echo "prepared $d (cow over golden)"
done
