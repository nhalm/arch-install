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
| 2.1 | Clean install end to end | `./test/vmtest.sh cycle ./test/guest-install.sh 1800` | **pass** |
| 2.2 | `verify` passes on the unmounted install | inside 2.1 | **pass** — `all invariants hold` |
| 2.3 | Boots unattended to a login prompt | `vmtest.sh run` | **pass** |
| 2.4 | Runtime checks on the booted system | `drive-runtime.sh guest-runtime.sh` | **pass** — 31/31 |
| 2.5 | Exactly one passphrase prompt, at GRUB | serial log | **pass** — one blind `key` send unlocks and boots |
| 2.6 | zswap on, no zram device, one swap area | in 2.4 | **pass** |
| 2.7 | Hibernate and resume actually work | `hibernate-selftest` | not run |
| 2.8 | Swap survives a reboot unformatted | compare `mkswap` UUID | **pass** — stable UUID, no `systemd-makefs` in the unit |
| 2.9 | `power` mode re-applies in place | `MNT=/ ./arch-install.sh power` | **pass** — 6/6, idempotent, lid policy untouched |
| 2.10 | Rollback still works with the new layout | `rollback-test.sh` 4 phases | **pass** — all 4 phases; cmdline intact after 3 rollbacks |

**2.7** is the headline. Write a marker into RAM, hibernate, confirm the machine
actually powered off, boot, confirm the marker survived *and* that the kernel
came back from the image rather than booting fresh (`/sys/power/resume` consumed,
no fresh `boot_id`). `/dev/shm` is the marker: tmpfs is RAM-only, so it survives
a resume and cannot survive a reboot — which is what stops a failed resume from
being mistaken for a successful one, since a machine that fails to resume simply
boots and looks healthy.

**Status: entry PROVEN, resume PARTIAL, post-resume stability FAILS in this VM.
The automated test could not have reported any of this — see the correction
below.**

> [!WARNING]
> **The 2.7 automation was broken in three ways, found by audit, not by running
> it.** Every hibernate run timing out at 124 was a harness bug, not a system
> result: `drive-runtime.sh` waited for `===HIBERNATE-TEST-DONE rc=N===`, which
> no script emits — `hibernate-test.sh` prints `===HIBERNATE-TEST rc=N===` with
> no `-DONE`. The wait could never match. The driver also never read the `rc=`
> digit, so once the name was fixed a *failing* run would have read as a
> finished one. And `--resumed` waited for the shell prompt, which is text that
> flushes from *before* the freeze, so it proved a resume happened but not that
> a shell was ready for the command it then typed.
>
> Worse, `phase2` could not fail for the reason it claimed. `boot_id` unchanged,
> the `/dev/shm` marker present and `uname -r` unchanged are *all equally true
> of a machine that never slept*. They rule out a fresh boot being mistaken for
> a resume — the inverse, and rarer, failure. `phase2` now asks the kernel for
> evidence of a hibernation cycle in `dmesg` before trusting anything else.
>
> The findings below therefore rest on manual observation — qemu exiting, log
> sizes, buffered output flushing — and not on this test, which was incapable of
> producing them.

Established, with journal evidence from the guest:

* **Hibernate entry works.** `systemd-logind: The system will hibernate now!`,
  `user.slice: Unit now frozen`, `systemd-sleep: Performing sleep operation
  'hibernate'`, then the machine powers itself off. Reproduced many times.
* **The image is written and read back.** The next boot runs `Resume from
  hibernation` in the initrd, the serial log is ~4 KB rather than the ~20 KB a
  fresh boot produces, and output buffered *before* the freeze flushes on the
  far side carrying the pre-hibernate `boot_id`. Memory is genuinely restored.
* **The machine then powers off ~20 s later.** Cleanly: no panic, no oops, no
  call trace, and **journald records nothing at all** for the resumed portion of
  that boot. The failure is therefore early in resume, before userspace logging
  is running again.

Reproduced with `test/www/plainhib.sh` — three lines, `systemctl hibernate` with
nothing pending across the freeze — so it is **not** an artifact of
`hibernate-test.sh` holding an in-flight async sleep operation, which was the
first and most obvious suspect.

**Everything the installer controls is verified correct**, which is what makes
this worth separating out: `resume=` on the cmdline (1.2 proves it is what arms
the unit), the crypttab entry without the destructive `swap` option, the unit
ordering at runtime (swap attached -> resume attempted -> `swapon`), the swap
size against the `35/32` worst case, and `/sys/power/resume` populated at
runtime. None of the remaining failure is in that surface.

**Leading hypothesis, UNVERIFIED: a QEMU S4-resume limitation rather than an
installer defect.** Consistent with a clean power-off, no kernel errors, and
nothing logged. Not proven, and deliberately not asserted — `/sys/power/disk`
reads `[platform]`, so S4 *is* advertised, and an earlier confident theory about
QEMU (`disable_s4`) turned out to be wrong when actually checked.

**This must be tested on the real laptop before hibernation is relied on.** If
it reproduces there, hibernate-resume is unusable as shipped and the escalation
policy should fall back to plain suspend until it is fixed. If it does not, this
is a harness limitation and nothing more.

**2.10 detail.** All four phases passed against the three-partition layout:
rolled back across a deliberately destroyed kernel and both initramfs images and
booted the restored one (`/proc/cmdline` carries the *pre-snapshot* `rt=` token,
proving GRUB read the restored `grub.cfg` rather than a stale one that still
resolved), survived a second rollback, and still booted after cleanup deleted
eight snapshots -- the state that produces `grub rescue>` in RECOVERY.md §3.

Extra assertions were added for the new cmdline entries, because `grub-sync`
regenerates `grub.cfg` on every rollback and applies a `sed` that strips
`rootflags=subvol=` from the same line. After three rollbacks: `resume=` and
`zswap.enabled=1` both still present (x3 each), `rootflags=subvol=` still absent,
`rw` still appearing exactly once, and `/sys/power/resume` still populated. Had
that `sed` been eating the new entries, hibernation would have stopped working
silently after the first rollback.

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
| 3.1 | §2 bad default subvolume | **pass.** `set-default 5` → `Failed to start Switch Root` / `You are in emergency mode` / `Cannot open access to console, the root account is locked` — the documented unrecoverable-in-place state. ISO rescue verified the target had both an init and a kernel before repointing; final boot reached a login prompt. Swap container irrelevant as predicted. | **pass** |
| 3.2 | §3 GRUB anchored to a deleted snapshot | **pass.** Break gave `grub rescue>` with `normal.mod not found` — *after* a successful passphrase unlock, now warned about in RECOVERY.md §3. `grub-sync` repaired prefix `@/.snapshots/99/snapshot` → `@/.snapshots/1/snapshot`, stamp agreed, both safety nets re-armed and confirmed to have actually run. `resume=` survived on all 3 kernel lines. | **pass** |
| 3.3 | §4 destroyed kernel/initramfs | **pass.** GRUB failed with `invalid magic number` on *both* the default and fallback entries (captured by screendump — GRUB writes to gfxterm, not serial). After `pacman -S linux` + `mkinitcpio -P` in an ISO chroot, **both keyfiles returned** — the break damaged `/boot`, not `mkinitcpio.conf`, so `FILES=` survived and re-embedded them. Booted; `resume=` x3 intact. | **pass** |
| 3.4 | §5 corrupt `grub.cfg` | **pass.** Break gave a bare `grub>` (`can't find command \`this'`), so GRUB read the file and failed on its contents. `grub-sync` from an ISO chroot regenerated it **complete**: `resume=` x3, `zswap.enabled=1` x3, `rootflags=subvol=` x0, `cryptomount` x4. Booted after rescue. | **pass** |
| 3.5 | §6 `rootflags=subvol=` reintroduced | **pass.** Stock `grub-mkconfig` injected it on all 3 entries, pinning the live subvolume. `verify` failed with exactly one error (`grub.cfg has rootflags=subvol=`, exit 1). `resume=`/`zswap` untouched — the damage is narrow, not broad. `grub-sync` repaired it and `verify` passed clean; `--if-changed` also repairs it, so a reboot self-heals. **Re-run with full probing showed only ONE of three candidate checks fires** — the net is a single grep, now broadened to catch `subvolid=` too and documented in DESIGN.md as load-bearing. | **pass** |
| 3.6 | **new** — swap container header damaged | **pass, after a fix.** Boots with root intact, swap absent, `/sys/power/resume` `0:0`. But without `nofail` it first stalls the full 90 s device timeout — 196 s to a login prompt, looking exactly like a hang. `nofail` added to the fstab swap entry, with an invariant. | **pass** |
| 3.7 | **new** — hibernate, then roll back, then resume | See below. | not run |

### 3.7: researched instead of tested, and the answer is a paragraph

Not run — it needs a working resume to arm it. But it was researched, and the
conclusion is that the plugin this section originally proposed should **not** be
built.

**The hazard class is old and upstream is blunt about it.** The kernel's
hibernation docs: *"If you touch anything on disk between suspend and resume …
kiss your data goodbye."* `power_down()` spins forever rather than let a machine
keep running with an armed image. An LKML thread from 2008 asked for exactly
this invalidation and the answer was "mkswap the partition from a boot script,
after checking whether to resume". The rollback-shaped instance appears to be
undocumented anywhere — openSUSE ships snapper rollback *and* hibernation and
says nothing about the interaction — but it is an instance, not a new class.

**Why no plugin.** A `rollback-post` snapper plugin leaks on exactly the side
that matters: in the ISO-rollback sequence this section describes, the plugin
cannot run at all. And on a live system with swap active there is provably no
image to invalidate, because `swapon` already cleared it. It would buy the
intersection of two unlikely conditions, and add a third instance of the
"safety net lives inside the snapshot" pattern RECOVERY.md §8 already warns
about.

**What was done instead:**

* RECOVERY.md §6a — disarm the image by hand before rolling back from outside
  the running system. `swapon` then `swapoff` is the correct supported
  mechanism: it rewrites ten bytes of signature and touches nothing else.
  `mkswap` changes the UUID and would break `crypttab.initramfs`.
* `verify` asserts swap is **active**, reframed as a hibernation-safety
  invariant rather than tidiness — an inactive swap has not disarmed anything.

**And a trade worth knowing about, created by the 3.6 fixes.** `nofail` plus the
device timeouts make a missing swap container non-fatal, and therefore also
non-invalidating: resume is skipped, `swapon` never runs, and an image stays
armed while the filesystem changes. That is a likelier route into this hazard
than a deliberate rollback, and systemd#32021 shows the precondition (LUKS2
swap, device timeout) happening to real people. The trade is still correct — a
196 s stall indistinguishable from a hang is worse — but it is recorded in
`write_fstab()`'s comment rather than left implicit.

**Two non-problems, confirmed in kernel source, so nobody re-derives them:** a
resume that is attempted and fails still disarms the image, because
`swsusp_check()` restores the original signature before reading anything; and
hybrid-sleep never leaves an armed image on a running system.

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
