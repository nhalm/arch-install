# Load-bearing decisions

Change any of these and rollback silently stops working.

| Decision | Why |
|---|---|
| Root fstab line has no `subvol=` | `fs/btrfs/super.c` `mount_subvol()` consults the btrfs default subvolume only when no explicit `subvol=`/`subvolid=` is given. `snapper rollback` works by repointing that default. An explicit `subvol=@` silently defeats it. |
| No `rootflags=subvol=` on the cmdline | Same mechanism. `util/grub.d/10_linux.in` injects it unconditionally; `grub-sync` strips it. |
| Mount by `subvol=`, never `subvolid=`, for non-root | Rollback creates a new subvolume with a new ID. A numeric ID then names the old root. |
| GRUB, not systemd-boot | systemd-boot cannot read btrfs — the Boot Loader Specification requires the ESP be firmware-readable (FAT), so a kernel there can never be in a snapshot. |
| `/usr/lib/snapper/plugins/10-grub` + `grub-boot-sync.service` | Arch's GRUB has no btrfs subvolume support: `grub-core/fs/btrfs.c` resolves from subvolid 5. openSUSE's `btrfs_relative_path` is a SUSE patch that never merged. These re-point the embedded prefix after a rollback. |
| `/var/lib/pacman` stays inside `@` | Excluding it leaves the package DB claiming versions the files on disk do not match. |
| `NUMBER_LIMIT` is a range (`10-20`) | A scalar is a degenerate range and silently disables `FREE_LIMIT`. |
| btrfs quotas OFF | `FREE_LIMIT` needs only `statvfs`. snapper 0.13.1 forces a full `quota_rescan` on every cleanup when quotas are on. |
| `ALLOW_USERS`/`SYNC_ACL` first in the key list | That ordering is what triggers `syncAcl()`. |
| LUKS keyfile in the initramfs | Without it GRUB and the initramfs each prompt. Keyfile is mode 000 inside the encrypted volume; a broken keyfile degrades to a second prompt, not an unbootable system. |
| `--ambit=classic` on the first rollback | `idToNum()` requires a path ending `/<N>/snapshot`; `@` is not one. Later rollbacks do not need it. |

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
