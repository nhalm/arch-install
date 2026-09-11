# Load-bearing decisions

Change any of these and rollback silently stops working.

| Decision | Why |
|---|---|
| Root fstab line has no `subvol=` | `fs/btrfs/super.c` `mount_subvol()` consults the btrfs default subvolume only when no explicit `subvol=`/`subvolid=` is given. `snapper rollback` works by repointing that default. An explicit `subvol=@` silently defeats it. |
| No `rootflags=subvol=` on the cmdline | Same mechanism. `util/grub.d/10_linux.in` injects it unconditionally; `grub-sync` strips it. Verified in a VM: a hand-run `grub-mkconfig` reintroduces it on every menu entry and pins whatever subvolume happened to be current, after which rollbacks silently do nothing. It does **not** disturb `resume=` or `zswap.enabled=1` — those live in `GRUB_CMDLINE_LINUX_DEFAULT` and are reproduced faithfully — so the damage is narrow, single-purpose and invisible. `verify` catches it, and `grub-boot-sync.service` repairs it on the next boot because `grub-sync --if-changed` tests for `rootflags=subvol=` as well as for a stale prefix. |
| Mount by `subvol=`, never `subvolid=`, for non-root | Rollback creates a new subvolume with a new ID. A numeric ID then names the old root. |
| GRUB, not systemd-boot | systemd-boot cannot read btrfs — the Boot Loader Specification requires the ESP be firmware-readable (FAT), so a kernel there can never be in a snapshot. |
| `/usr/lib/snapper/plugins/10-grub` + `grub-boot-sync.service` | Arch's GRUB has no btrfs subvolume support: `grub-core/fs/btrfs.c` resolves from subvolid 5. openSUSE's `btrfs_relative_path` is a SUSE patch that never merged. These re-point the embedded prefix after a rollback. |
| The prefix is read back out of `grubx64.efi`/`BOOTX64.EFI`, not from the ESP stamp | `/efi/EFI/GRUB/root-subvol` is written by `grub-sync` itself, so it cannot detect a hand-run `grub-install`. GRUB boots from the prefix compiled into the core image; once the subvolume that prefix names is deleted the next boot is `grub rescue>`, with nothing left running to notice. `--if-changed` re-syncs on a stale or missing prefix, and `verify` fails on one. |
| `/var/lib/pacman` stays inside `@` | Excluding it leaves the package DB claiming versions the files on disk do not match. |
| `NUMBER_LIMIT` is a range (`10-20`) | A scalar is a degenerate range and silently disables `FREE_LIMIT`. |
| btrfs quotas OFF | `FREE_LIMIT` needs only `statvfs`. snapper 0.13.1 forces a full `quota_rescan` on every cleanup when quotas are on. |
| `ALLOW_USERS`/`SYNC_ACL` first in the key list | That ordering is what triggers `syncAcl()`. |
| LUKS keyfile in the initramfs | Without it GRUB and the initramfs each prompt. Keyfile is mode 000 inside the encrypted volume; a broken keyfile degrades to a second prompt, not an unbootable system. |
| No `swap` option in `crypttab.initramfs` | One word. `systemd-cryptsetup-generator` turns it into `ExecStartPost=systemd-makefs swap`, which reformats the device on every boot and destroys any hibernation image. Proven in `test/generator-test.sh`. |
| `x-initrd.attach` on the swap crypttab entry | Without it the generated unit gets `Conflicts=umount.target`, because `attach_in_initrd()` special-cases only the names `root` and `usr` — the mapping would be torn down at switch-root. |
| `nofail` on the fstab swap line | An unopenable swap container otherwise blocks the host boot for the full 90 s device timeout, showing "A start job is running for /dev/mapper/swap" — indistinguishable from a hang, and an invitation to power-cycle. |
| `resumeflags=x-systemd.device-timeout=` on the cmdline | The second, independent stall. `resume=` makes the hibernate-resume unit `BindsTo` the swap device *inside the initramfs*, ordered before the root filesystem mounts, where `nofail` cannot reach. Budget is for device enumeration, not the KDF (pbkdf2/1000, sub-millisecond). `resumeflags=` inherits `rootflags=` when unset and `grub-sync` strips that entirely, so it must be explicit. |
| No `resume` hook in `HOOKS` | It belongs to the busybox/udev path. With the `systemd` hook, `systemd-hibernate-resume-generator` reads `resume=` and emits the unit; adding the hook is cargo-culting. |
| Swap keyslots inverted: keyfile 0, passphrase 1 | Opposite to root, deliberately. The initramfs unlock hits slot 0 first, so it never pays a KDF for a slot it has no key for. |
| zram dropped for zswap | zram is inert at 32 GB (observed: 4 KB of data against an 8 G ceiling), inverts the LRU next to a real swap area because nothing evicts it, and degrades hibernation *entry* — freeing RAM for the image evicts pages into zram, which is RAM. Fedora concede the last point in their own SwapOnZRAM proposal. zswap compresses in front of the disk and can let go. |
| The default subvolume is set to a snapshot at install time | `snapper rollback`'s AUTO ambit needs `idToNum()` to parse the default subvolume path, which must end `/<N>/snapshot`; `@` does not. Booting from `@` would make the first rollback need `--ambit=classic`. `first_snapshot()` sets the default to `@/.snapshots/<N>/snapshot`, so every rollback is an ordinary one. |

## Re-applying

`snapper_setup()` runs everything through `target()`, which executes directly
when `MNT` is empty — and `MNT=/` collapses to empty. `./arch-install.sh snapper`
therefore re-applies the whole snapper configuration to a running system, so the
script stays the single source of truth for retention instead of only describing
the state at install time. `create-config` is skipped when the config exists.

## Cost

GRUB runs argon2id single-threaded in EFI. Left at the benchmarked cost that was
**~10 s of silent decrypt at every boot**, measured on the target laptop:
cryptsetup calibrates to 2 s using 4 threads and SIMD, and GRUB's argon2 is
scalar C walking lanes sequentially. With the forced iteration count below it is
**~2 s** — modelled from that measurement, not yet stopwatched on hardware.

The installer now pins `--pbkdf-force-iterations 4` with `--pbkdf-memory 524288`
and `--pbkdf-parallel 4`, which is exactly RFC 9106's first recommended option.
Left to benchmark, `cryptsetup` calibrates to a 2 s target using every thread and
SIMD, and GRUB — scalar, single-threaded — pays about 5x that. Lowering the
memory alone does nothing: the benchmark raises the iteration count to hit the
same target, so you get identical wall time with less memory-hardness. All three
parameters must be passed together or the benchmark runs anyway.

## Rejected

**archinstall.** Six of nine requirements are unexpressible: root is always pinned with
`subvol=` (`installer.py:446`), no `GRUB_ENABLE_CRYPTODISK` anywhere in the tree, no
`set-default`, no `--pbkdf-memory`, busybox hooks forced when no HSM is chosen
(`installer.py:857`), no root keyfile. `custom_commands` cannot compensate — it runs
chrooted and before `genfstab()` (`guided.py:181-184`).

## The one check that is alone

`verify`'s `grep -qE 'rootflags=[^ ]*subvol'` against `grub.cfg` is the entire
safety net for a reintroduced root pin, at the moment when that mistake is still
cheap to fix. Verified in a VM by breaking the system and counting which checks
fire: exactly one does.

The two that look like they should help cannot:

* `checkv "root mounted on the default subvolume"` compares `findmnt -no SOURCE /`
  against the btrfs default. Both read live kernel and filesystem state; neither
  reads `grub.cfg`. And at the moment the pin is written it is *guaranteed* to
  agree, because `grub-mkconfig` pins whatever subvolume is currently mounted.
  It diverges only after a rollback has moved the default and the machine has
  rebooted onto the stale pin — after the damage.
* The kernel-path check passes as well: `grub-mkconfig` emits the path correctly
  and only *adds* the `rootflags=` token.

Rebooting does not deepen the net either, which is sharper than it first looks.
`grub-mkconfig` pins whatever subvolume is *currently mounted*, so pin == default
from the moment the mistake is made and stays that way across reboots. The other
checks have nothing to catch until the default actually **moves** — and the
window before it moves is precisely the window in which the mistake is sitting
there silently waiting to eat the next rollback. Verified by breaking it,
rebooting, and confirming only the one check fires; and by then moving the
default by hand, after which `verify` returns nine failures and the net is
genuinely deep.

`verify` also now reads `/proc/cmdline`, not only `grub.cfg`. Observed during
that test: a machine running with `rootflags=subvol=` in force while `verify`
reported all invariants hold, because `grub-boot-sync.service` had repaired the
on-disk file during that same boot. Harmless there — the pin matched the default
— but a file-only check cannot see a stale pin a running kernel is already
obeying.

That is also why the pattern is matched broadly rather than as the literal
`rootflags=subvol=` that `10_linux` emits today. `subvolid=` pins just as hard,
and a pattern that missed it would let `verify` print "all invariants hold" on a
machine where every future rollback silently does nothing. If this check is ever
edited, it is the last thing standing between that state and a clean bill of
health.
