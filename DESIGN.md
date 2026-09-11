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
| The default subvolume is set to a snapshot at install time | `snapper rollback`'s AUTO ambit needs `idToNum()` to parse the default subvolume path, which must end `/<N>/snapshot`; `@` does not. Booting from `@` would make the first rollback need `--ambit=classic`. `first_snapshot()` sets the default to `@/.snapshots/<N>/snapshot`, so every rollback is an ordinary one. |

## Re-applying

`snapper_setup()` runs everything through `target()`, which executes directly
when `MNT` is empty — and `MNT=/` collapses to empty. `./arch-install.sh snapper`
therefore re-applies the whole snapper configuration to a running system, so the
script stays the single source of truth for retention instead of only describing
the state at install time. `create-config` is skipped when the config exists.

## Cost

GRUB runs argon2id single-threaded in EFI: **~10 s of silent decrypt at every boot**,
measured on the target laptop. cryptsetup calibrates to 2 s using 4 threads and SIMD;
GRUB's argon2 is scalar C walking lanes sequentially.

The installer does not pin `--pbkdf-force-iterations`, so a machine that benchmarks
faster will pick a higher iteration count and pay proportionally more.

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

That is why the pattern is matched broadly rather than as the literal
`rootflags=subvol=` that `10_linux` emits today. `subvolid=` pins just as hard,
and a pattern that missed it would let `verify` print "all invariants hold" on a
machine where every future rollback silently does nothing. If this check is ever
edited, it is the last thing standing between that state and a clean bill of
health.
