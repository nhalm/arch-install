# Arch ISO VM harness

`vmtest.sh` boots `archlinux-2026.09.01-x86_64.iso` headless under QEMU/OVMF,
captures the serial console to a file, and runs a script fetched from the host.
Everything lives in `~/vm`. No sudo anywhere.

## ISO facts (read from the ISO, not guessed)

| thing | value | where it came from |
|---|---|---|
| volume label | `ARCH_202609` | ISO9660 primary volume descriptor, sector 16 offset 40 |
| search uuid | `2026-09-01-17-09-43-00` | `boot/2026-09-01-17-09-43-00.uuid` in the ISO, and `loader/entries/01-archiso-linux.conf` |
| kernel | `arch/boot/x86_64/vmlinuz-linux` | `bsdtar -xOf` |
| initramfs | `arch/boot/x86_64/initramfs-linux.img` | `bsdtar -xOf` |

The ISO's own boot entry is `archisobasedir=arch archisosearchuuid=<uuid>` — this
release identifies its media by **filesystem UUID, not label**. `archisolabel=`
still works as a fallback (`hooks/archiso` maps it to `/dev/disk/by-label/<label>`),
but the UUID is what the ISO ships with, so that is what the harness uses.
`vmtest.sh info` prints both, derived from whatever ISO is in `~/vm`.

## `script=` does not exist

There is no `script=` kernel parameter in archiso 2026.09. Verified three ways:

- `hooks/archiso` in the initramfs parses `archisobasedir`, `archisolabel`,
  `archisosearchuuid`, `copytoram`, `cow_*`, `checksum`, `verify`, `cms_verify`
  — nothing else.
- The airootfs squashfs has no handler: `usr/local/bin` holds only
  `Installation_guide`, `choose-mirror`, `livecd-sound`, and no unit under
  `etc/systemd/system` reads a script URL.
- Grepping inside a booted guest: `grep -rn "script=" /usr/lib/initcpio /etc/systemd`
  matches only unrelated shell variable assignments in
  `/usr/lib/initcpio/functions`.

### What is used instead: `systemd.run=`

`systemd-run-generator` is present, so a kernel argument turns into a transient
unit. The harness appends:

```
systemd.run="/usr/bin/bash -c 'exec >/dev/ttyS0 2>&1; echo ===GUEST-START===;
 systemctl start systemd-networkd.service systemd-resolved.service;
 systemctl start network-online.target;
 curl -fsS -4 --retry 20 --retry-delay 2 --retry-all-errors -o /root/guest.sh <URL>
 && bash /root/guest.sh; echo ===INSTALL-DONE rc=$?==='"
systemd.run_success_action=none systemd.run_failure_action=none
```

Three things that are load-bearing:

- **The unit must start networking itself.** `systemd.run=` units are ordered
  only after `basic.target`, and the generator's unit becomes the effective
  boot goal — `multi-user.target` is never reached, so `systemd-networkd` never
  starts on its own. Without the explicit `systemctl start`, curl fails with
  `(7) Failed to connect to 10.0.2.2 after 0 ms` for the whole retry window and
  the guest never gets a login prompt either. This cost two failed runs.
- **The unit must start `pacman-init.service` too** — the same trap one layer
  down, worth stating separately because the symptom points somewhere else
  entirely. `pacman-init.service` is `WantedBy=multi-user.target`, so on this
  boot path the live keyring is never initialised: `pacman-key --init` has not
  run, `/etc/pacman.d/gnupg` holds no keys, and `pacstrap -K` seeds the target
  keyring from that empty one. The install downloads all ~800 MiB and then dies
  at transaction commit with:

  ```
  warning: Public keyring not found; have you run 'pacman-key --init'?
  error: keyring is not writable          (x23)
  error: required key missing from keyring
  ==> ERROR: Failed to install packages to new root
  ```

  Nothing in that output mentions `multi-user.target`, and it reads convincingly
  like an ISO too old for the current signing keys — which is the wrong tree to
  bark up. It is neither the ISO's age nor the installer. Confirmed by running
  `pacman-key --init` by hand on a booted ISO: it exits 0 and populates a
  directory that was empty, i.e. nothing had run it. This cost one full cycle
  plus a wrong "fix" in `arch-install.sh` that had to be reverted.
- **No single quotes in the command.** The value is single-quoted inside a
  double-quoted kernel argument; the kernel keeps it as one parameter and
  systemd unquotes it once.

`run_success_action=none` keeps the VM alive after the script exits so the
serial console stays usable for poking around.

## Finish detection

The guest bootstrap always ends with `===GUEST-DONE rc=N===` on `/dev/ttyS0`.
Deliberately *not* `===INSTALL-DONE===`: `arch-install.sh` prints that itself
when the install finishes, so sharing the string would kill the VM out from
under any guest script that does further work afterwards -- re-verifying,
enabling a serial console, running a self-test. Cost one cycle to notice.
`vmtest.sh wait [secs]` polls `serial.log` for that and then kills qemu:

- sentinel found → exits with the guest's `N`
- overall timeout → `124`
- qemu died first → `125`

All three paths verified.

## Usage

```sh
./vmtest.sh info                 # iso, label, uuid
./vmtest.sh reset                # blank 20G qcow2 + fresh OVMF_VARS copy
./vmtest.sh boot                 # plain ISO boot, serial getty (log in as root, no password)
./vmtest.sh boot http://10.0.2.2:8123/guest.sh
./vmtest.sh wait 1800            # block for the sentinel
./vmtest.sh run                  # boot the installed disk, no ISO
./vmtest.sh cycle ./smoke-guest.sh 420   # reset + serve + boot + wait, one shot
./vmtest.sh send 'ls -l'         # type a line into the serial console
./vmtest.sh log 40               # tail serial.log
./vmtest.sh stop                 # kill qemu and the http server
```

`cycle` copies the given script to `www/guest.sh`, starts
`python3 -m http.server 8123 --bind 127.0.0.1 --directory ~/vm/www`, and boots
with `script url = http://10.0.2.2:8123/guest.sh`. 10.0.2.2 is the host under
user-mode networking, and it reaches a loopback-bound listener, so the server
never has to be exposed.

Overrides via env: `VM ISO SIZE MEM CPUS PORT TIMEOUT CODE VARS_TPL`.

## Files

| path | what |
|---|---|
| `vmtest.sh` | the harness |
| `archlinux-2026.09.01-x86_64.iso` | media |
| `vmlinuz-linux`, `initramfs-linux.img` | extracted for `-kernel`/`-initrd`; re-extracted when older than the ISO |
| `test.qcow2` | the 20G target disk |
| `OVMF_VARS.fd` | per-VM writable copy of `/usr/share/edk2/x64/OVMF_VARS.4m.fd` |
| `serial.log` | serial capture, truncated on each boot |
| `serial.sock` | serial console socket, for `send` |
| `www/guest.sh` | what the guest fetches |
| `smoke-guest.sh` | smoke test: partitions vda, writes an ESP, makes the disk bootable |

## QEMU shape

q35, `-cpu host`, KVM, 4 vCPU, 4G, `-display none -monitor none -no-reboot`.
OVMF split firmware: `OVMF_CODE.4m.fd` read-only on pflash unit 0, the per-VM
`OVMF_VARS.fd` on unit 1. Disk is virtio-blk (`vda`, bootindex=1), net is
virtio-net with slirp, plus virtio-rng so nothing stalls on entropy.

The ISO is attached as a **read-only virtio-blk device (`vdb`), not a cdrom** —
archiso resolves it by UUID so the device type does not matter, and it keeps
everything on one bus. `copytoram=n` is passed explicitly: with virtio the
`copytoram=auto` heuristic would otherwise copy the 1GB squashfs into RAM on
every boot.

Serial is a unix-socket chardev with `logfile=`, which gives both a capture file
and a writable console. QEMU discards anything still queued when the peer
disconnects, so `send` writes a byte at a time and lingers 0.5s before closing.

## Verified

- ISO boots to `archiso login:` on ttyS0; `root` with an empty password gets a
  shell (`SHELLPROOF root 7.2.2-arch1-1 airootfs`).
- Guest reaches the host at `10.0.2.2:8123`.
- `cycle` fetched and ran a host script, its output landed on the serial
  console, sentinel `===INSTALL-DONE rc=0===`.
- `reset` gives a 20G qcow2 (196K allocated) and an `OVMF_VARS.fd` byte-identical
  to the template; boots fine afterwards.
- `wait` returns the guest rc, 124 on timeout, 125 on qemu death.
- `smoke-guest.sh` partitioned `vda`, wrote an ESP, and `run` then booted that
  disk with no ISO attached — OVMF loaded `\EFI\BOOT\BOOTX64.EFI` and reached
  `UEFI Interactive Shell v2.2`.

## Did not work / notes

- `script=` — absent, see above.
- `blkid` on the ISO as a way to get the label: the draft used it, but it is not
  reliable for a file and the label is not what this ISO boots by anyway. The
  volume id is read straight out of the primary volume descriptor instead.
- `-nographic` conflicts with an explicit `-serial`; `-display none` is used.
- A stale `python3 -m http.server` on the same port will answer a naive
  readiness probe while serving the wrong directory. `serve_bg` writes a nonce
  file and checks it comes back, and dies if the bind failed.

## Writing break/rescue scripts: two traps

**Never let a check match text your own script printed.** Break scripts announce
what they expect (`echo "expect grub rescue>"`), so any check scanning the
serial log for a failure string can match the prediction instead of the failure.
That is a self-confirming false positive: the scenario proves its break worked
by reading its own console echo, silently and convincingly. Anchor failure
patterns at line start (`^grub rescue>`) — real prompts are always at line
start, predictions are mid-sentence — or record a byte offset after `vmtest.sh
run` and match with `tail -c +$off`, the way `drive-runtime.sh`'s
`wait_for_after()` already does. Measured against real phase logs: unanchored
matched the break script's own echo; anchored matched only the genuine prompts.

**`vmtest.sh send` garbles long command lines in the console echo** while
executing them correctly. It is a display artefact of byte-at-a-time writing, not
a delivery failure. The practical constraint: never parse the echoed command
text, only marker-framed output the guest itself produces
(`=====THING=====` … `=====THING-END=====`).
