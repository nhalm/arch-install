# RECOVERY.md — bringing an `arch-install.sh` (v2) system back from the dead

Every command below was executed in the `~/vm/v2` VM against a real install of
`~/personal/arch-install/arch-install.sh` — §1–§11 against md5
`7587edfb40ce258f605fdfbd6d72d687`, §12 against `10d028005422f99d5cd2cd8bae448246`,
which adds the prefix checks §9 asked for —
Arch ISO `archlinux-2026.09.01-x86_64.iso`, grub 2:2.14-1, snapper 0.13.1-3,
linux 7.2.4-arch1-2. Four failure modes were induced, each confirmed
**not to boot** (or to boot **wrong**), then recovered. Nothing here is
paper-only; anything not executed is marked **UNTESTED**.

> [!WARNING]
> **Re-verification pending for the three-partition layout.** Every procedure
> below was executed against the two-partition layout that predates the
> hibernation swap. The addition of `/dev/vda3`, a second keyfile, and `resume=`
> on the kernel command line changes the environment each recovery runs in, and
> those runs have **not** been redone yet. `test/TESTPLAN.md` §Tier 3 tracks
> which scenarios still need re-proving and what specifically changes in each.
> Two are known to need edits rather than just a re-run: §4 must restore *both*
> keyfiles, and §5 must reproduce `resume=` and `zswap.enabled=1` rather than
> only the root line. Treat the rest as sound in outline and unconfirmed in
> detail until that work lands.

Replace `vmtestluks` with your passphrase and `/dev/vda` with your disk
(`/dev/nvme0n1` → partitions are `p1`/`p2`/`p3`).

---

## 0. The layout you are recovering

```
/dev/vda1  ESP, vfat, mounted at /efi          <- GRUB core image + stamp file
/dev/vda2  LUKS2 -> /dev/mapper/root, btrfs
/dev/vda3  LUKS2 -> /dev/mapper/swap, raw swap <- hibernation image lives here
```

**Three partitions, not two.** `vda3` is a second, independently-keyed LUKS2
container holding swap sized for a hibernation image. Four things follow that
matter during a recovery:

* **It is not needed to boot.** Nothing in the boot path depends on it. A
  damaged or missing swap container gives you a machine with no swap and no
  hibernate, which still boots — degraded, not dead. Do not let it distract you
  from a root-filesystem problem.
* **It has its own keyfile**, `/etc/cryptsetup-keys.d/swap.key`, which lives
  *inside the root filesystem*. So restoring a destroyed initramfs means
  restoring **both** keyfiles; miss the swap one and hibernation silently stops
  working while everything else looks fine.
* **The passphrase opens it too.** The keyfile is slot 0 and the passphrase is
  slot 1, so from the ISO `cryptsetup open /dev/vda3 swap` prompts and works
  exactly like the root container. You do not need the keyfile to rescue it.
* **Never run `mkswap` on it while an image is live.** That is the difference
  between "resume restored my session" and "the machine booted fresh and the
  session is gone". The same hazard is why `crypttab.initramfs` must not carry
  the `swap` option — see the comment there.

Inside the btrfs, from subvolid 5:

```
@                                 container, NOT the running root
@/home  @/var/log  @/var/cache/pacman/pkg      nested, mounted by subvol= in fstab
@/.snapshots                                   snapper's store
@/.snapshots/<N>/snapshot         <- one of these IS the running root
@/home/.snapshots/<N>/snapshot
```

Four facts that drive every recovery:

1. **Which subvolume boots is the btrfs *default subvolume*.** `fstab` has no
   `subvol=` on `/`, and there is no `rootflags=subvol=` on the cmdline. Get it
   wrong and the machine will not boot.
2. **`/boot` is not a mount.** It is a directory *inside* the root snapshot, on
   the encrypted btrfs. Kernel and initramfs are therefore inside every snapshot.
3. **GRUB resolves paths absolutely from subvolid 5** and has no btrfs subvolume
   support. Its prefix (baked into `\EFI\GRUB\grubx64.efi`) and every path in
   `grub.cfg` name a snapshot literally, e.g.
   `/@/.snapshots/19/snapshot/boot/grub`.
4. **`/efi/EFI/GRUB/root-subvol` is the stamp** — the subvolume `grub-sync` last
   pointed GRUB at. Reading it is the fastest way to learn what GRUB believes.

Two safety nets keep 3 in step with 1: `/usr/lib/snapper/plugins/10-grub`
(runs on `rollback-post`) and `grub-boot-sync.service` (runs at every boot,
`ExecStart=/usr/local/bin/grub-sync --if-changed`). Both live **inside the root
snapshot**, so they are themselves subject to rollback — see the finding in §6.

---

## 1. Triage: what kind of failure is this?

| What you see | What it means | Go to |
|---|---|---|
| GRUB asks for the passphrase, then `error: file '/@/.snapshots/N/snapshot/boot/grub/x86_64-efi/normal.mod' not found.` → `grub rescue>` | GRUB's embedded prefix names a subvolume that no longer exists | §3 |
| `grub>` prompt with no menu | `grub.cfg` is unreadable/corrupt; GRUB itself is fine | §5 |
| GRUB menu appears, `error: ... invalid magic number` when booting | kernel image inside the root snapshot is damaged | §4 |
| Menu boots, then `Failed to start Switch Root.` / `You are in emergency mode` / `Cannot open access to console, the root account is locked` | kernel and initramfs are fine; the **default subvolume** does not contain a root filesystem | §2 |
| Boots fine, but `findmnt -no SOURCE /` does not match `btrfs subvolume get-default /` | `rootflags=subvol=` is back on the cmdline — rollbacks are silently doing nothing | §6 |

**Note on the console.** With the installer's defaults, `/dev/console` is the
last `console=` on the cmdline. In this harness that is `tty0`, so kernel
panics and the initramfs emergency shell appear on the **screen, not the serial
port**. Do not conclude "nothing happened" from a quiet serial log.

---

## 2. Bad default subvolume  — REPRODUCED, RECOVERED

### Break

Run in the healthy system:

```sh
btrfs subvolume set-default 5 /
```

`btrfs subvolume get-default /` then prints `ID 5 (FS_TREE)`.

### Confirmed failure

GRUB is unaffected (its paths are absolute), the kernel loads, and the
initramfs mounts `/dev/mapper/root` with no `subvol=` — landing on subvolid 5,
which holds only the directory `@`. Screen (`shot-break1.png`):

```
[FAILED] Failed to start Switch Root.
See 'systemctl status initrd-switch-root.service' for details.
You are in emergency mode. ...
Cannot open access to console, the root account is locked.
```

The machine never reaches a login prompt. Unrecoverable in place — the root
account is locked, so the emergency shell will not open.

### Recovery, from the Arch ISO (executed: `rescue1.sh`, `rescue-extras.sh`)

```sh
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL /dev/vda
```
```
NAME    SIZE FSTYPE      PARTLABEL
vda      20G
├─vda1    1G vfat        ESP
└─vda2   19G crypto_LUKS cryptroot
```

```sh
cryptsetup open /dev/vda2 root          # prompts for the passphrase
ls -l /dev/mapper/root                  # -> ../dm-0
```

Ask GRUB what it thinks the root is. Mount the ESP **outside** the btrfs tree,
so you do not leave a stray directory in subvolid 5:

```sh
mount --mkdir /dev/vda1 /esp
cat /esp/EFI/GRUB/root-subvol
```
```
@/.snapshots/19/snapshot
```
```sh
umount /esp
```

Now look at the filesystem:

```sh
mount -o subvolid=5 /dev/mapper/root /mnt
ls /mnt                                 # -> @        (nothing else belongs here)
btrfs subvolume list /mnt
btrfs subvolume get-default /mnt
```
```
ID 256 gen 98  top level 5   path @
ID 262 gen 119 top level 256 path @/.snapshots
ID 284 gen 122 top level 262 path @/.snapshots/19/snapshot
...
ID 5 (FS_TREE)                          <- the fault
```

Choose the target. Prefer the one the stamp names: GRUB's prefix and `grub.cfg`
already point there, so no chroot is needed. Otherwise list the candidates —
**`info.xml` dates are UTC**:

```sh
for d in /mnt/@/.snapshots/[0-9]*; do
  n=${d##*/}
  printf '  %s: %s | %s | init=%s\n' "$n" \
    "$(sed -n 's:.*<date>\(.*\)</date>.*:\1:p' "$d/info.xml" 2>/dev/null | head -1)" \
    "$(sed -n 's:.*<description>\(.*\)</description>.*:\1:p' "$d/info.xml" 2>/dev/null | head -1)" \
    "$([ -x "$d/snapshot/usr/lib/systemd/systemd" ] && echo yes || echo NO)"
done
```
```
8: 2026-09-09 15:48:53 | writable copy of #0 | init=yes
9: 2026-09-09 16:40:07 | timeline           | init=yes
```

`init=NO` means that subvolume cannot be a root — never set-default to it.

Sanity-check, then repoint. Both forms work:

```sh
ls /mnt/@/.snapshots/19/snapshot/usr/lib/systemd/systemd     # must exist
ls /mnt/@/.snapshots/19/snapshot/boot/vmlinuz-linux          # must exist

btrfs subvolume set-default /mnt/@/.snapshots/19/snapshot    # by path
# or, from `btrfs subvolume list` above:
btrfs subvolume set-default 284 /mnt                         # by numeric ID
btrfs subvolume get-default /mnt
```
```
ID 284 gen 122 top level 262 path @/.snapshots/19/snapshot
```

```sh
umount /mnt
cryptsetup close root
reboot
```

**Verified:** boots to `archvm login:` on the next try.

**After the reboot**, confirm the two agree:

```sh
findmnt -no SOURCE /                    # /dev/mapper/root[/@/.snapshots/19/snapshot]
btrfs subvolume get-default /           # ...path @/.snapshots/19/snapshot
cat /efi/EFI/GRUB/root-subvol           # @/.snapshots/19/snapshot
```

> **Do not set-default to `@`.** `@` looks like a root filesystem — `ls /mnt/@`
> shows `bin boot etc usr var …`, because it is the pre-first-snapshot install
> tree — but nothing has updated it since installation day. It will boot, and it
> will be wrong. UNTESTED as a boot; verified only that the directory tree exists.

---

## 3. Rollback leaves GRUB anchored to a deleted snapshot — REPRODUCED, RECOVERED

### Break

The safety nets normally prevent this, and they are *inside* the snapshot, so
they must be disabled **and then snapshotted** for the break to survive:

```sh
systemctl disable --now grub-boot-sync.service
mv /usr/lib/snapper/plugins/10-grub /root/10-grub.disabled
N=$(snapper -c root create -p -d break2-nets-disabled)   # -> 12
snapper -c root rollback $N
```
```
Ambit is classic.
Creating read-only snapshot of current system. (Snapshot 13.)
Creating read-write snapshot of snapshot 12. (Snapshot 14.)
Setting default subvolume to snapshot 14.
```

Default is now `@/.snapshots/14/snapshot`; the stamp still reads
`@/.snapshots/11/snapshot`. Reboot — **this still boots**, on the stale but
still-valid prefix (`/proc/cmdline` shows
`BOOT_IMAGE=/@/.snapshots/11/snapshot/boot/vmlinuz-linux` while
`findmnt /` shows the root is subvolume 14). Now delete the anchor, exactly as
snapper's own cleanup eventually would:

```sh
snapper -c root delete 11
```

### Confirmed failure

```
Enter passphrase for hd0,gpt2 (f0d52e36-...):
Attempting to decrypt master key...
Slot "0" opened
error: fs/btrfs.c:find_path:1890:file `/@/.snapshots/11/snapshot/boot/grub/x86_64-efi/normal.mod' not found.
Entering rescue mode...
grub rescue>
```

### Recovery A — from the `grub rescue>` prompt, no ISO (executed)

The LUKS volume is already unlocked at this point; it is device `crypto0`.

```
grub rescue> ls
(crypto0) (proc) (hd0) (hd0,gpt2) (hd0,gpt1)

grub rescue> ls (crypto0)/@/.snapshots/
9/ 13/ 10/ 12/ 14/
```

Repointing the prefix gets you a menu back:

```
grub rescue> set prefix=(crypto0)/@/.snapshots/14/snapshot/boot/grub
grub rescue> set root=crypto0
grub rescue> insmod normal
grub rescue> normal
```

**This is not sufficient by itself.** The `grub.cfg` you just loaded was written
before the rollback and still names the deleted snapshot:

```
error: fs/btrfs.c:find_path:1890:file `/@/.snapshots/11/snapshot/boot/vmlinuz-linux' not found.
error: loader/i386/linux.c:grub_cmd_initrd:1082:you need to load the kernel first.
```

So load the kernel by hand. Press `c` for the command line and type:

```
set root=crypto0
linux /@/.snapshots/14/snapshot/boot/vmlinuz-linux root=/dev/mapper/root rw rootfstype=btrfs
initrd /@/.snapshots/14/snapshot/boot/intel-ucode.img /@/.snapshots/14/snapshot/boot/initramfs-linux.img
boot
```

**Verified:** reached `archvm login:` ten seconds later. Add
`console=ttyS0,115200 console=tty0` only if you need a serial console.

This is a one-shot boot; the core image's prefix is still wrong. Make it
permanent from the running system:

```sh
sudo /usr/local/bin/grub-sync
```
```
Installing for x86_64-efi platform.
Installation finished. No error reported.        (x2: nvram entry + removable path)
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-linux
...
done
```
```sh
cat /efi/EFI/GRUB/root-subvol
# @/.snapshots/14/snapshot
strings /efi/EFI/GRUB/grubx64.efi | grep -oE 'snapshots/[0-9]+/snapshot/boot/grub'
# snapshots/14/snapshot/boot/grub
grep -m1 -E '^[[:space:]]+linux' /boot/grub/grub.cfg
# linux /@/.snapshots/14/snapshot/boot/vmlinuz-linux root=/dev/mapper/root rw ...
```

**Verified:** clean reboot afterwards.

### Recovery B — from the ISO, if you cannot use the GRUB prompt

Do §4's chroot mount set, then `arch-chroot /mnt /usr/local/bin/grub-sync`.
Executed as part of §4 and §5; it is the same single command.

### GRUB prompt quirks worth knowing

* Typed commands work over a serial console, but **Enter does not activate the
  highlighted menu entry** through OVMF's serial ConIn, and neither does
  `Ctrl-x` from the edit screen. `e` (edit) and `c` (command line) do work.
  On a real machine's keyboard this is a non-issue.
* Once `grub.cfg` has been read, GRUB's output goes to the **video console
  only** — errors after that point never reach the serial port.

---

## 4. Destroyed kernel/initramfs inside the snapshot — REPRODUCED, RECOVERED

### Break

With both safety nets disabled, from the ISO (or the running system):

```sh
dd if=/dev/urandom of=/mnt/@/.snapshots/14/snapshot/boot/vmlinuz-linux      bs=1M count=4 conv=notrunc
dd if=/dev/urandom of=/mnt/@/.snapshots/14/snapshot/boot/initramfs-linux.img bs=1M count=8 conv=notrunc
rm -f /mnt/@/.snapshots/14/snapshot/boot/initramfs-linux-fallback.img
```

### Confirmed failure

The menu appears; booting the entry gives (`shot-break3f.png`):

```
grub> linux /@/.snapshots/14/snapshot/boot/vmlinuz-linux root=/dev/mapper/root rw
error: loader/i386/linux.c:grub_cmd_linux:710:invalid magic number.
```

Both the default entry and everything under *Advanced options* point at the
same file, and the fallback image is gone, so no menu entry can boot.

### Recovery A — borrow a kernel from another snapshot (executed)

Any other snapshot's `/boot` is intact and, if it is the same kernel version as
`/usr/lib/modules` in the default subvolume, it will boot straight into the
real system. Press `c` at the menu:

```
set root=crypto0
linux /@/.snapshots/12/snapshot/boot/vmlinuz-linux root=/dev/mapper/root rw rootfstype=btrfs
initrd /@/.snapshots/12/snapshot/boot/intel-ucode.img /@/.snapshots/12/snapshot/boot/initramfs-linux.img
boot
```

**Verified:** `archvm login:` after 10 s, with

```
findmnt -no SOURCE /   -> /dev/mapper/root[/@/.snapshots/14/snapshot]
cat /proc/cmdline      -> BOOT_IMAGE=/@/.snapshots/12/snapshot/boot/vmlinuz-linux ...
modprobe -n loop       -> ok
```

i.e. the *damaged* root is running, off a healthy kernel from a sibling
snapshot. From there run the §4B chroot body without the chroot.

### Recovery B — chroot from the Arch ISO (executed: `rescue3.sh`)

This is the full mount set for this layout. It is the part most likely to be
wrong on paper, so here it is exactly as run.

```sh
cryptsetup open /dev/vda2 root

# 1. discover which subvolume is the root, from the top level
mount -o subvolid=5 /dev/mapper/root /mnt
btrfs subvolume get-default /mnt
#   ID 278 gen 91 top level 262 path @/.snapshots/14/snapshot
D=$(btrfs subvolume get-default /mnt | awk '{print $NF}')
umount /mnt

# 2. remount that subvolume AS the root
MOPTS=rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2
mount -o "$MOPTS,subvol=$D" /dev/mapper/root /mnt

# 3. every nested subvolume, by subvol= (never subvolid=)
mount -o "$MOPTS,subvol=@/home"                 --mkdir /dev/mapper/root /mnt/home
mount -o "$MOPTS,subvol=@/var/log"              --mkdir /dev/mapper/root /mnt/var/log
mount -o "$MOPTS,subvol=@/var/cache/pacman/pkg" --mkdir /dev/mapper/root /mnt/var/cache/pacman/pkg
mount -o "$MOPTS,subvol=@/.snapshots"           --mkdir /dev/mapper/root /mnt/.snapshots

# 4. the ESP
mount -o fmask=0077,dmask=0077 --mkdir /dev/vda1 /mnt/efi
```

There is **no `/boot` mount** — check that:

```sh
findmnt -R /mnt -o TARGET,SOURCE,FSTYPE
```
```
TARGET                      SOURCE                                      FSTYPE
/mnt                        /dev/mapper/root[/@/.snapshots/14/snapshot] btrfs
├─/mnt/home                 /dev/mapper/root[/@/home]                   btrfs
├─/mnt/var/log              /dev/mapper/root[/@/var/log]                btrfs
├─/mnt/var/cache/pacman/pkg /dev/mapper/root[/@/var/cache/pacman/pkg]   btrfs
├─/mnt/.snapshots           /dev/mapper/root[/@/.snapshots]             btrfs
└─/mnt/efi                  /dev/vda1                                   vfat
```
```sh
findmnt -no SOURCE -T /mnt/boot/grub
# /dev/mapper/root[/@/.snapshots/14/snapshot]     <- inside the root subvol. Correct.
```

Rebuild. The kernel package is in the on-disk cache, so **no network is
needed** — the `@/var/cache/pacman/pkg` subvolume you just mounted holds it:

```sh
arch-chroot /mnt
  pacman -U --noconfirm /var/cache/pacman/pkg/linux-7.2.4.arch1-2-x86_64.pkg.tar.zst
  mkinitcpio -P
  # this release's `linux` preset builds only `default`; build the fallback the
  # way the installer does (arch-install.sh:269)
  [ -s /boot/initramfs-linux-fallback.img ] ||
    mkinitcpio -k /boot/vmlinuz-linux -g /boot/initramfs-linux-fallback.img -S autodetect
  /usr/local/bin/grub-sync
  exit
```

> Use the exact filename, not `linux-*.pkg.tar.zst` — that glob also matches
> `linux-api-headers` and all thirteen `linux-firmware-*` packages. It works,
> but it reinstalls 563 MiB for no reason. Confirmed by running it.

Expected tail:

```
==> Creating zstd-compressed initcpio image: '/boot/initramfs-linux.img'
==> Initcpio image generation successful
Installing for x86_64-efi platform.
Installation finished. No error reported.
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-linux
Found initrd image: /boot/intel-ucode.img /boot/initramfs-linux.img
Found fallback initrd image(s) in /boot:  intel-ucode.img initramfs-linux-fallback.img
done
```

Check and leave:

```sh
file /mnt/boot/vmlinuz-linux
#   Linux kernel x86 boot executable, bzImage, version 7.2.4-arch1-2 ...
ls -l /mnt/boot                     # all four images present, fresh mtimes
cat /mnt/efi/EFI/GRUB/root-subvol   # @/.snapshots/14/snapshot
grep -m1 -E '^[[:space:]]+linux' /mnt/boot/grub/grub.cfg

sync
umount -R /mnt
cryptsetup close root
reboot
```

**Verified:** boots. The restored `vmlinuz-linux` sha256 matched the
pre-damage value exactly (`ffcb6e46…`).

`snap-pac` fires inside the chroot, so the repair itself leaves a `pre`/`post`
snapshot pair — expected, not a fault.

---

## 5. Corrupt `grub.cfg` — REPRODUCED, RECOVERED

### Break

```sh
head -c 4096 /dev/urandom > /boot/grub/grub.cfg
```

### Confirmed failure

GRUB loads (the prefix is fine), fails to parse the config, and drops to the
full command shell — note `grub>`, **not** `grub rescue>`:

```
Minimal BASH-like line editing is supported. ...
grub>
```

### Recovery — chroot from the ISO (executed: `rescue4b.sh`)

Same mount set as §4B, then one command:

```sh
arch-chroot /mnt /usr/local/bin/grub-sync
head -3 /mnt/boot/grub/grub.cfg
#   #
#   # DO NOT EDIT THIS FILE
#   #
grep -m1 -E '^[[:space:]]+linux' /mnt/boot/grub/grub.cfg
#   linux /@/.snapshots/19/snapshot/boot/vmlinuz-linux root=/dev/mapper/root rw ...
grep -c 'rootflags=subvol=' /mnt/boot/grub/grub.cfg
#   0                                <- grub-sync stripped it; must be 0
```

**Verified:** boots.

You should also be able to boot once from the `grub>` prompt with the
`set root` / `linux` / `initrd` / `boot` lines from §3 — the prompt is right
there and `grub.cfg` is not consulted — and then run
`sudo /usr/local/bin/grub-sync`. **UNTESTED for this scenario**: the four lines
were proven in §3 and §4, not from this particular `grub>` prompt.

---

## 6. `rootflags=subvol=` reintroduced — REPRODUCED (boots, silently wrong), RECOVERED

This is the failure `DESIGN.md` is built to avoid, and it does not announce
itself.

### Break

Anything that regenerates `grub.cfg` without `grub-sync` — most obviously a
user running the documented Arch command directly:

```sh
grub-mkconfig -o /boot/grub/grub.cfg
```

`util/grub.d/10_linux.in` injects `rootflags=subvol=` unconditionally:

```sh
grep -c rootflags=subvol= /boot/grub/grub.cfg      # 3
grep -m1 -E '^[[:space:]]+linux' /boot/grub/grub.cfg
#  linux /@/.snapshots/14/snapshot/boot/vmlinuz-linux root=/dev/mapper/root rw \
#        rootflags=subvol=@/.snapshots/14/snapshot ...
```

At this instant nothing is wrong — it pins the subvolume that is already
running. The damage appears at the next rollback:

```sh
snapper -c root rollback 12
#   Creating read-only snapshot of current system. (Snapshot 18.)
#   Creating read-write snapshot of snapshot 12. (Snapshot 19.)
#   Setting default subvolume to snapshot 19.
btrfs subvolume get-default /       # ID 284 ... path @/.snapshots/19/snapshot
```

### Confirmed failure — it boots, and the rollback did nothing

```sh
btrfs subvolume get-default /
#   ID 284 gen 104 top level 262 path @/.snapshots/19/snapshot
findmnt -no SOURCE /
#   /dev/mapper/root[/@/.snapshots/14/snapshot]        <- NOT the rollback target
cat /root/which-root
#   MARK-SNAPSHOT14                                    <- pre-planted marker
cat /proc/cmdline
#   ... rootflags=subvol=@/.snapshots/14/snapshot ...
```

The default subvolume moved; the cmdline overrode it. Every subsequent
`snapper rollback` would report success and change nothing.

### Detection

Three commands, compared by eye — this is exactly how the mismatch above was
spotted:

```sh
btrfs subvolume get-default /                     # ID 284 ... path @/.snapshots/19/snapshot
findmnt -no SOURCE /                              # /dev/mapper/root[/@/.snapshots/14/snapshot]
grep -c rootflags=subvol= /boot/grub/grub.cfg     # 3   -- must be 0
```

The path in `get-default` and the bracketed subvolume in `findmnt` must be the
same. Or just run `arch-install.sh verify`, which checks both — executed
against this exact broken state in §12.

### Recovery (executed)

Run `grub-sync` **against the subvolume that should be running**, which is what
the `10-grub` plugin does:

```sh
sudo /usr/local/bin/grub-sync /.snapshots/19/snapshot
```
```
Installing for x86_64-efi platform.
Installation finished. No error reported.
Installing for x86_64-efi platform.
Installation finished. No error reported.
```
```sh
cat /efi/EFI/GRUB/root-subvol
#   @/.snapshots/19/snapshot
grep -c rootflags=subvol= /.snapshots/19/snapshot/boot/grub/grub.cfg
#   0
strings /efi/EFI/GRUB/grubx64.efi | grep -oE 'snapshots/[0-9]+/snapshot/boot/grub'
#   snapshots/19/snapshot/boot/grub
```

Reboot. **Verified:**

```
btrfs subvolume get-default /  -> ID 284 ... @/.snapshots/19/snapshot
findmnt -no SOURCE /           -> /dev/mapper/root[/@/.snapshots/19/snapshot]
cat /proc/cmdline              -> no rootflags=subvol=
```

Plain `sudo /usr/local/bin/grub-sync` (no argument) also strips `rootflags=`,
but it points GRUB at the *currently running* root, not at the default — so it
cures the symptom and leaves you booting the wrong snapshot. Pass the target.

---

## 7. Finishing up

Re-arm the safety nets if a rescue or a rollback left them off:

```sh
install -D -m 755 /root/10-grub.disabled /usr/lib/snapper/plugins/10-grub
systemctl enable grub-boot-sync.service
systemctl is-enabled grub-boot-sync.service        # enabled
```

Executed from the ISO chroot (`arch-chroot /mnt systemctl enable …`, paths
prefixed with `/mnt`), and confirmed afterwards in the booted system:
`is-enabled` → `enabled`, `ls -l /usr/lib/snapper/plugins/` → `10-grub`.

Then let the installer grade the result — it runs read-only in this mode:

```sh
DISK=/dev/vda MNT=/ bash arch-install.sh verify
```
```
==> verify
==> verify: all invariants hold
```

**Verified** on the system after all four recoveries, with the shipped
`arch-install.sh` (md5 `7587edfb40ce258f605fdfbd6d72d687`).

---

## 8. Findings

### The safety nets are inside the snapshot, so a rollback re-arms them

Disabling `grub-boot-sync.service` and moving `10-grub` aside, then rolling back
to a snapshot taken **before** the disable, silently restored both — and the
restored `grub-boot-sync.service` then re-pointed GRUB at the new default on the
next boot. This is good behaviour (the net is hard to lose), but it means:

* you cannot disable the net "for one rollback" without snapshotting first, and
* a rollback to an old snapshot resurrects whatever `/usr/local/bin/grub-sync`
  and `/etc/default/grub` looked like then.

Discovered the hard way: the first attempt at §3 failed to break anything.

### A stale-but-valid prefix boots, and hides the problem

Between "the default moved" and "the old snapshot was deleted", the machine
boots normally off the old snapshot's `grub.cfg` and kernel while running the
new root — `/proc/cmdline` names snapshot 11, `findmnt /` says 14. Everything
works until snapper's cleanup deletes 11, which may be days later. Comparing
the stamp with the default is the cheap way to see it coming — and
`arch-install.sh verify` already does exactly that comparison
(`arch-install.sh:582-583`):

```sh
cat /efi/EFI/GRUB/root-subvol                # @/.snapshots/11/snapshot
btrfs subvolume get-default / | awk '{print $NF}'   # @/.snapshots/14/snapshot
```

### `verify` catches both silent states — CONFIRMED BY EXECUTION

The claim above was originally read out of the source. It has since been
executed against a live, broken system (see §12).

* `checkv "root mounted on the default subvolume"` compares `findmnt -no SOURCE /`
  with the default subvolume — the §6 mismatch.
* `grep -q 'rootflags=subvol=' "$cfg"` — §6's `grub.cfg`.
* `checkv "grub prefix stamp" "$dflt" "$got"` compares `/efi/EFI/GRUB/root-subvol`
  with the default — the §3 stale-anchor state.

The stamp check alone was not enough, because `grub-sync` writes that file
itself. `verify` now also reads the prefix **embedded in the core images** —
`/efi/EFI/GRUB/grubx64.efi` and `/efi/EFI/BOOT/BOOTX64.EFI` — and requires both
to name the default subvolume and that subvolume to exist. A hand-run
`grub-install` desynchronises stamp from prefix, and only the new check sees it.

---

## 9. Suggested changes to `arch-install.sh` — recommendations only, nothing changed

1. **Ship this runbook on the ESP.** The ESP is the one thing readable from any
   rescue environment without unlocking LUKS. Writing
   `/efi/EFI/GRUB/RECOVERY.txt` at install time — twenty lines: partition roles,
   `cryptsetup open`, `mount -o subvolid=5`, `set-default`, the chroot mount
   set — costs nothing and is available exactly when the system will not boot.
   The stamp file already proves the pattern works.

2. **Stamp more than the subvolume name.** `/efi/EFI/GRUB/root-subvol` was the
   single most useful artefact in every scenario. Adding the numeric subvolume
   ID and the kernel version next to it would let a rescuer choose a target and
   sanity-check module/kernel agreement without mounting the btrfs at all.

3. **DONE — `verify` reads the real prefix, not just the stamp.** See §12.

4. **DONE — `grub-sync --if-changed` fires on a stale or dangling prefix.** See §12.

5. **Consider a second GRUB entry pinned to `--removable`'s own prefix, or a
   menu entry per snapshot.** In §4 no menu entry could boot, yet three sibling
   snapshots held a working kernel a few keystrokes away at the `grub>` prompt.
   `grub-btrfs` generates exactly these entries. Out of scope for the installer
   as it stands, but it is the difference between "type six lines from memory at
   a GRUB prompt" and "press down-arrow".

6. **Nothing in the recovery path argued for changing the layout itself.** The
   default-subvolume design, `/boot` inside the snapshot, and `grub-sync` all
   behaved as `DESIGN.md` claims, including the `rootflags=subvol=` hazard,
   which reproduced precisely as documented.

---

## 10. Scenario status

| # | Scenario | Reproduced | Confirmed unbootable | Recovered | Evidence |
|---|---|---|---|---|---|
| 1 | Bad default subvolume (`set-default 5`) | yes | yes — `Failed to start Switch Root`, root account locked | yes, ISO + `set-default` | `shot-break1.png`, `rescue1.sh` |
| 2 | Rollback → GRUB prefix names a deleted snapshot | yes | yes — `grub rescue>` | yes, twice: at the GRUB prompt, and permanently with `grub-sync` | `shot-break2.png`, `shot-rescue-normal.png` |
| 3 | Kernel + initramfs destroyed inside the snapshot | yes | yes — `invalid magic number` | yes, ISO chroot + `pacman -U` + `mkinitcpio -P` + `grub-sync`; also by borrowing a sibling snapshot's kernel | `shot-break3f.png`, `break3.sh`, `rescue3.sh` |
| 4a | Corrupt `grub.cfg` | yes | yes — bare `grub>` | yes, ISO chroot + `grub-sync` | `shot-break4b.png`, `rescue4b.sh` |
| 4b | `rootflags=subvol=` reintroduced | yes | **boots, silently wrong root** | yes, `grub-sync <target>` | §6, marker file proof |

Not attempted: LUKS header damage / `cryptsetup luksHeaderRestore`, a
btrfs-level corruption needing `btrfs check --repair` or `btrfs restore`, a
lost passphrase, and a damaged ESP needing GRUB reinstalled from scratch onto a
fresh FAT partition. All four are real risks on this layout and are **UNTESTED**
here.

---

## 11. Harness used (all under `~/vm/v2`, `VM` pinned)

| file | what |
|---|---|
| `rec-run.sh` | boots `test.qcow2` like `vmtest.sh run`, plus a QMP socket |
| `rec-shot.sh` | QMP `screendump` → PNG; the only way to see a panic, since `/dev/console` is `tty0` |
| `rec-boot.sh` | boot + feed the passphrase + classify BOOTED / FAILED / NO-LOGIN, with a screenshot |
| `rec-login.sh` | log in on an already-running guest and run root commands |
| `rec-key.sh` | raw keystrokes with no trailing CR — needed to reach GRUB's `c` and `e` |
| `rec-iso.sh` | boot the ISO with the disk attached and run a host-served script |
| `rec-stop.sh` | kill qemu and the HTTP server |
| `break3.sh`, `rescue1.sh`, `rescue3.sh`, `rescue4b.sh`, `rescue-extras.sh` | the scenario scripts, each printing every command it runs |

qcow2 checkpoints: `good-postfullproof4`, `good-after-scenario2`,
`good-after-all-recoveries` — that disk is now `keep-recovered.qcow2`, since §12
reinstalled `test.qcow2` from blank. `test.qcow2` carries `green-newinstaller`
(`qemu-img snapshot -l` reports nothing while qemu holds the image).

---

## 12. The prefix checks — REPRODUCED, DETECTED, SELF-REPAIRED

Three changes landed in `arch-install.sh` after §9. Everything below was executed
against a **fresh install from a blank disk** by the changed installer (md5
`10d028005422f99d5cd2cd8bae448246`), after the full clean cycle passed, on the
`~/vm/v2` harness. The default subvolume there is `@/.snapshots/8/snapshot`.

### What the core image actually holds

One string, the same in both core images:

```sh
grep -aoE '[)]/[^)]*/boot/grub' /efi/EFI/GRUB/grubx64.efi
# )/@/.snapshots/8/snapshot/boot/grub
grep -aoE '[)]/[^)]*/boot/grub' /efi/EFI/BOOT/BOOTX64.EFI
# )/@/.snapshots/8/snapshot/boot/grub
```

The full string is `(cryptouuid/<luks-uuid>)/@/.snapshots/8/snapshot/boot/grub`.
`grep -a` reads it straight out of the binary — no `binutils`, no `strings`, so
the check works on a base install.

### Break: a hand-run `grub-install` desynchronises the stamp from the prefix

`grub-install` cannot target a snapper snapshot directly — they are read-only
(`cannot backup .../acpi.mod: Read-only file system`). Make a writable subvolume
of the same path shape and point GRUB at it, leaving the stamp alone:

```sh
mkdir -p /.snapshots/99
btrfs subvolume snapshot / /.snapshots/99/snapshot
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB \
  --boot-directory=/.snapshots/99/snapshot/boot
grub-install --target=x86_64-efi --efi-directory=/efi --removable \
  --boot-directory=/.snapshots/99/snapshot/boot
```

```
### stamp still says @/.snapshots/8/snapshot; prefixes say:
/efi/EFI/GRUB/grubx64.efi )/@/.snapshots/99/snapshot/boot/grub
/efi/EFI/BOOT/BOOTX64.EFI )/@/.snapshots/99/snapshot/boot/grub
```

`verify` catches it. The stamp check stays silent the whole time — it is
checking the file `grub-sync` wrote, not the binary GRUB will run:

```
==> VERIFY FAIL: grub prefix in EFI/GRUB/grubx64.efi (want '@/.snapshots/8/snapshot', got '@/.snapshots/99/snapshot')
==> VERIFY FAIL: grub prefix in EFI/BOOT/BOOTX64.EFI (want '@/.snapshots/8/snapshot', got '@/.snapshots/99/snapshot')
```

### Break: the prefix subvolume is deleted — §3, one reboot early

```sh
btrfs subvolume delete /.snapshots/99/snapshot
```

At this instant `stamp == default` and `grub.cfg` has no `rootflags=`, so the
**old** `--if-changed` had nothing to react to and exited 0. The machine was one
reboot from §3's `grub rescue>`. The shipped helper now says so and repairs it:

```
### the shipped grub-sync --if-changed on the DANGLING prefix
/efi/EFI/GRUB/grubx64.efi: prefix @/.snapshots/99/snapshot names a deleted subvolume
/efi/EFI/BOOT/BOOTX64.EFI: prefix @/.snapshots/99/snapshot names a deleted subvolume
Installing for x86_64-efi platform.
Installation finished. No error reported.
...
### prefixes after the self-repair
/efi/EFI/GRUB/grubx64.efi )/@/.snapshots/8/snapshot/boot/grub
/efi/EFI/BOOT/BOOTX64.EFI )/@/.snapshots/8/snapshot/boot/grub
==> verify: all invariants hold
```

### The boot-time net, end to end

A prefix that is *already* dangling at power-on is beyond anything running on
the system. What the check removes is the **window** §8 describes: the days
between the prefix going stale and `snapper cleanup` deleting what it names.
Armed with the safety nets **enabled** — unlike §3, which had to disable them:

```
### armed: default=@/.snapshots/8/snapshot stamp=@/.snapshots/8/snapshot prefix=)/@/.snapshots/99/snapshot/boot/grub
enabled
-rwxr-xr-x 1 root root 246 Sep  9 15:26 /usr/lib/snapper/plugins/10-grub
```

Reboot: the machine comes up on the stale-but-valid prefix, and the service
repairs it unprompted.

```
Sep 09 15:33:28 archvm grub-sync[1673]: /efi/EFI/GRUB/grubx64.efi: prefix @/.snapshots/99/snapshot is stale, default is @/.snapshots/8/snapshot
Sep 09 15:33:28 archvm grub-sync[1673]: /efi/EFI/BOOT/BOOTX64.EFI: prefix @/.snapshots/99/snapshot is stale, default is @/.snapshots/8/snapshot
Sep 09 15:33:31 archvm systemd[1]: Finished Point GRUB at the current btrfs default subvolume.

### prefixes now
/efi/EFI/GRUB/grubx64.efi )/@/.snapshots/8/snapshot/boot/grub
/efi/EFI/BOOT/BOOTX64.EFI )/@/.snapshots/8/snapshot/boot/grub
```

Then `btrfs subvolume delete /.snapshots/99/snapshot` — the step that produced
`grub rescue>` in §3 — and reboot again:

```
OUTCOME=BOOTED
```

The old check could not have done this: the stamp equalled the default
throughout.

### `verify` on the `rootflags=subvol=` states, executed

§8 claimed this from source; `verify` had only ever run on a repaired system.
Executed. First the break alone, no rollback:

```sh
grub-mkconfig -o /boot/grub/grub.cfg
grep -c rootflags=subvol= /boot/grub/grub.cfg   # 3
DISK=/dev/vda MNT=/ bash arch-install.sh verify
```
```
==> VERIFY FAIL: grub.cfg has rootflags=subvol=
==> ERROR: verify failed: grub.cfg has rootflags=subvol=
```

Then the full §6 silent state — nets disabled and snapshotted, rollback, reboot,
so the machine is running a subvolume that is not the default and cannot tell:

```
ID 276 gen 66 top level 262 path @/.snapshots/11/snapshot
/dev/mapper/root[/@/.snapshots/8/snapshot]
3
BOOT_IMAGE=/@/.snapshots/8/snapshot/boot/vmlinuz-linux ... rootflags=subvol=@/.snapshots/8/snapshot ...
MARK-PRE-ROLLBACK-ROOT
```
```
==> VERIFY FAIL: root mounted on the default subvolume (want '/dev/mapper/root[/@/.snapshots/11/snapshot]', got '/dev/mapper/root[/@/.snapshots/8/snapshot]')
==> VERIFY FAIL: grub.cfg has rootflags=subvol=
==> VERIFY FAIL: grub.cfg kernel path is not inside @/.snapshots/11/snapshot
==> VERIFY FAIL: grub prefix stamp (want '@/.snapshots/11/snapshot', got '@/.snapshots/8/snapshot')
==> VERIFY FAIL: grub prefix in EFI/GRUB/grubx64.efi (want '@/.snapshots/11/snapshot', got '@/.snapshots/8/snapshot')
==> VERIFY FAIL: grub prefix in EFI/BOOT/BOOTX64.EFI (want '@/.snapshots/11/snapshot', got '@/.snapshots/8/snapshot')
==> VERIFY FAIL: snapper grub plugin
==> VERIFY FAIL: /var/lib/pacman inside the root subvolume (want '/dev/mapper/root[/@/.snapshots/11/snapshot]', got '/dev/mapper/root[/@/.snapshots/8/snapshot]')
==> VERIFY FAIL: grub-boot-sync.service enabled (want 'enabled', got 'disabled')
```

`verify` fails, loudly, on the state that boots. Recovery is §6's, unchanged.

### Evidence

`~/vm/v2`: `fullproof5.out` (full clean cycle), `proof-change13.log`,
`proof-change1-boot.log`, `proof-change2a.log`, `proof-change2b.log`, and the
break scripts `www/f1-desync.sh` … `www/f5-silent.sh`. qcow2 checkpoint
`green-newinstaller` is the fresh install immediately after the clean cycle;
`keep-recovered.qcow2` holds the §1–§11 disk with its own checkpoints.
