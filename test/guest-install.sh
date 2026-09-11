#!/usr/bin/env bash
# Guest script for `vmtest.sh cycle`. Runs a full install on /dev/vda, then
# verifies it. The VM has 4G RAM, so swap is sized for that, not for the laptop:
# 6 GiB clears MemTotal * 35/32 (~4.4 GiB worst-case compressed image) with room
# for paging. 40 GiB would not fit on the 20G test disk at all -- partition()
# dies with "does not fit", which is itself worth seeing once.
set -euo pipefail

: "${DISK:=/dev/vda}"
: "${SWAP_SIZE_GIB:=6}"
: "${LUKS_PASSPHRASE:=vmtestluks}"
: "${USER_PASSWORD:=vmtestuser}"
: "${TARGET_HOSTNAME:=archvm}"
export DISK SWAP_SIZE_GIB LUKS_PASSPHRASE USER_PASSWORD TARGET_HOSTNAME
export CONFIRM=yes

cd /root
curl -fsSL -o arch-install.sh "${INSTALLER_URL:-http://10.0.2.2:8123/arch-install.sh}"
chmod +x arch-install.sh
md5sum arch-install.sh

./arch-install.sh install

echo "=== re-verify against the unmounted install ==="
./arch-install.sh verify

echo "=== layout as installed ==="
lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL "$DISK"
