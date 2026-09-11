# Test plan — power strategy changes

What must pass before this branch is trusted on real hardware. Three tiers:
what runs anywhere, what needs a VM, and what needs the laptop.

Status column is filled in as tests run. `not run` means exactly that — this
file does not claim a test passed until it has.

---

## Tier 1 — no VM, no root, runs on any Arch box

| # | Test | Command | Status |
|---|---|---|---|
| 1.1 | Script parses | `bash -n arch-install.sh` | **pass** |
| 1.2 | Generator wiring: resume armed, swap not reformatted | `./test/generator-test.sh` | **pass** (11/11) |
| 1.3 | Every new package name resolves | `pacman -Si <pkgs>` | **pass** |
| 1.4 | Every unit name enabled actually exists | repo file lists | **pass** |
| 1.5 | Partition arithmetic aligns to 4096 at both ends | see §Tier 1 notes | **pass** |

### Tier 1 notes

**1.2** is the important one. systemd's generators are pure functions of a
crypttab and a cmdline, so `SYSTEMD_IN_INITRD=1` plus `SYSTEMD_CRYPTTAB=` /
`SYSTEMD_PROC_CMDLINE=` reproduces exactly what the initramfs would get, with no
reboot. It proves the two silent failures in this design:

- `resume=` absent → **zero** units generated, i.e. hibernate has no target and
  fails with nothing in the log pointing at the cause.
- the one-word `swap` option in crypttab → `ExecStartPost=systemd-makefs`, which
  reformats the swap device on every boot and destroys the image.

**1.5** mirrors `partition()`'s end2/end3 maths over `{512, 4096}` sector sizes
and 20G/930G/1T disks. Both container ends must land on the 4096-byte grain or
`luksFormat --sector-size 4096` refuses the device. Also confirms the
"does not fit" guard fires for 40 GiB on a 20G disk.

---

## Tier 2 — QEMU/OVMF VM

Needs `qemu-base` + `edk2-ovmf` and an Arch ISO in `test/`. See HARNESS.md.

| # | Test | How | Status |
|---|---|---|---|
| 2.1 | Clean install end to end | `./test/vmtest.sh cycle ./test/guest-install.sh 900` | not run |
| 2.2 | `verify` passes on the unmounted install | inside 2.1 | not run |
| 2.3 | Boots unattended to a login prompt | `vmtest.sh run` | not run |
| 2.4 | `verify` passes on the booted system (`MNT=/`) | in-guest | not run |
| 2.5 | Exactly one passphrase prompt, at GRUB | serial log | not run |
| 2.6 | zswap on, no zram device, one swap area | in-guest | not run |
| 2.7 | Hibernate and resume actually work | `hibernate-selftest` | not run |
| 2.8 | Swap survives a reboot unformatted | compare `mkswap` UUID | not run |
| 2.9 | `power` mode re-applies in place | `MNT=/ ./arch-install.sh power` | not run |
| 2.10 | Rollback still works with the new layout | `rollback-test.sh` 4 phases | not run |

**2.7** is the headline. Write a marker into RAM, hibernate, confirm the machine
actually powered off, boot, confirm the marker survived *and* that the kernel
came back from the image rather than booting fresh (`/sys/power/resume` consumed,
no fresh `boot_id`).

**2.8** guards the crypttab hazard from the other side: 1.2 proves the generator
does not emit `systemd-makefs`; this proves nothing else reformats it either.

---

## Tier 3 — recovery, against the new layout

Every scenario in RECOVERY.md was proven against the *old* two-partition layout.
Adding a third LUKS container and a `resume=` cmdline changes the environment
each recovery runs in, so they need re-proving. Each is: break it, confirm it
genuinely fails, recover it, then `verify`.

| # | RECOVERY.md § | What changes with the new layout | Status |
|---|---|---|---|
| 3.1 | §2 bad default subvolume | Recovery mounts subvolid 5 as before; swap container is untouched and irrelevant. Expect no change. | not run |
| 3.2 | §3 GRUB anchored to a deleted snapshot | `grub-sync` unchanged; cmdline now carries `resume=`, which the `rootflags=` sed must not eat. | not run |
| 3.3 | §4 destroyed kernel/initramfs | Restoring the initramfs must restore **both** keyfiles, or swap fails to attach and resume silently stops working. | not run |
| 3.4 | §5 corrupt `grub.cfg` | Regenerating must reproduce `resume=` and `zswap.enabled=1`, not just the root line. | not run |
| 3.5 | §6 `rootflags=subvol=` reintroduced | `verify` must still catch it, and must not be confused by the new cmdline entries. | not run |
| 3.6 | **new** — swap container header damaged | Machine should boot with no swap and no hibernate, degrading rather than failing. Recovery is `luksHeaderRestore` or re-`mkswap`. | not run |
| 3.7 | **new** — hibernate, then roll back, then resume | See below. | not run |

### 3.7 is the genuinely new hazard

A hibernation image is a snapshot of RAM, including the kernel's idea of what is
on disk. `snapper rollback` moves the filesystem underneath it. Resuming a stale
image onto a rolled-back filesystem means the kernel's cached metadata describes
a subvolume that is no longer the root — dirty pages written back over a tree
that has changed.

Sequence to test:

1. Hibernate with a known file present.
2. Boot the ISO instead of resuming; roll the default subvolume back to a
   snapshot taken *before* that file existed.
3. Boot normally. The kernel finds an unconsumed image in swap and resumes it.
4. Observe what happens to the filesystem.

Expected: corruption, or at best confusion. **If it does corrupt**, the fix is
the image guard from the hibernate report — a unit that refuses to resume an
image whose header does not match the current root, or that invalidates the
image whenever `snapper rollback` runs. That would be a new `rollback-post`
plugin alongside `10-grub`.

This interaction does not exist on a machine without rollback, so there is no
upstream guidance for it. It has to be established here.

---

## Running Tier 2

```sh
sudo pacman -S --needed qemu-base edk2-ovmf
curl -fsSLO https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
mv archlinux-x86_64.iso test/

# serve the installer next to the guest script, then run the cycle
cp arch-install.sh test/www/ 2>/dev/null || { mkdir -p test/www && cp arch-install.sh test/www/; }
./test/vmtest.sh cycle ./test/guest-install.sh 900
```

`cycle` exits with the guest's return code: 0 install+verify clean, 124 timeout,
125 qemu died.
