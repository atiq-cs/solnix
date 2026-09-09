# solnix x86_64 USB / ISO install media — how to build it, how to flash it, what is proven

**Status 2026-09-09: a real, flashable pair of artifacts exists and boots under QEMU/OVMF.**
Nothing here has ever been booted on physical hardware. Read
"[What is UNVERIFIED on real hardware](#what-is-unverified-on-real-hardware)" before flashing.

## The artifacts

| file | bytes | sha256 |
|------|------:|--------|
| `artifacts/install-media/usb-image-20260909/solnix-x86_64.iso` | 104,761,344 | `19d838554b392bd15ddc8da80ccb6ee05770b6d88ea444b704f28c43cbe1ae6d` |
| `artifacts/install-media/usb-image-20260909/solnix-x86_64-usb.img` | 104,761,344 | `19d838554b392bd15ddc8da80ccb6ee05770b6d88ea444b704f28c43cbe1ae6d` |

The two files are **byte-identical on purpose**: the isohybrid ISO *is* the disk image. The `.img`
name exists so the deliverable is unambiguous, and `SHA256SUMS` sits beside them. Verify before
flashing:

```sh
cd artifacts/install-media/usb-image-20260909 && sha256sum -c SHA256SUMS
```

⚠️ **`*.iso` and `*.img` are gitignored** (`.gitignore:9` and `:6`), so these two files **cannot be
committed** and will not survive a fresh clone. `SHA256SUMS` and the boot logs under `boot-logs/`
*are* committable and are the durable record. Rebuild with the recipe below.

⚠️ **Do not use the older files in `artifacts/install-media/`** (`solnix-x86_64-usb.img`,
`solnix-x86_64-minimal-usb.img`, `solnix-x86_64-graphical-usb.img`, dated 2026-07-29/30). They are
MBR-only pre-fix outputs, their provenance is unrecorded, and `solnix-x86_64-minimal.iso` in the
repo root is a **broken symlink**. Only the `usb-image-20260909/` pair below was built and tested by
a recorded run.

## Flashing to a USB stick

```sh
# 1. IDENTIFY THE TARGET. Get this wrong and you erase the wrong disk, silently and completely.
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS      # find the stick, e.g. sdb / 32G / USB
# 2. Make sure nothing on it is mounted.
sudo umount /dev/sdb?* 2>/dev/null || true
# 3. Write it. NOTE the device name caveat below.
sudo dd if=solnix-x86_64-usb.img of=/dev/sdb bs=4M status=progress oflag=direct conv=fsync
sudo sync
```

**The device-name caveat, spelled out.** `of=` must be the **whole device** (`/dev/sdb`), never a
partition (`/dev/sdb1`) — writing to a partition leaves the MBR/GPT and the ESP unwritten and the
stick will not boot. Device letters are **assignment-order, not stable**: `/dev/sdb` can be your
internal disk on the next boot, or on a machine with a different disk count. Confirm with `lsblk`
immediately before each `dd`, matching on SIZE + MODEL + `TRAN=usb`, not on a remembered letter.
On macOS the equivalent is `/dev/rdiskN` (raw node) after `diskutil unmountDisk`. There is no undo.

Because the image is smaller (100 MiB) than any real stick, the tail of the stick is left as-is;
that is harmless, and `dd` does not need to fill the device.

## What boots — measured, in QEMU only

All rows are `scripts/qemu-boottest.sh` runs on the exact artifact above. "reaches login" means the
serial console printed `solnix console login:`. Logs in
`artifacts/install-media/usb-image-20260909/boot-logs/`.

| # | firmware | media + attachment | result | log |
|---|----------|--------------------|--------|-----|
| 1 | **UEFI** (OVMF) | `.img` as virtio-blk **disk** | **PASS** — reaches login | `qemu-uefi-usbimg-virtio.clean.txt` |
| 2 | **UEFI** (OVMF) | `.img` on a real **USB bus** (xhci + usb-storage) | **PASS** — reaches login | `qemu-uefi-usbimg-usbbus.clean.txt` |
| 3 | **UEFI** (OVMF) | `.iso` as CD-ROM | **PASS** — reaches login | `qemu-uefi-iso.clean.txt` |
| 4 | **BIOS** | `.iso` as CD-ROM (El Torito) | **PASS** — reaches login | `qemu-bios-iso.clean.txt` |
| 5 | **BIOS** | `.img` as a **disk** (USB-stick path) | **FAIL — zero console output** | `qemu-bios-usbimg.clean.txt` |
| 6 | UEFI | `.img` as **NVMe** | boots, then **panics in `nvme`** | (smoke image) |

Row 2 is the closest analogue to a USB stick in a laptop and it passes. The UEFI chain, quoted from
row 1:

```
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
illumos/amd64 EFI loader, Revision 1.1
   Load Path: \EFI\BOOT\BOOTX64.EFI
   Load Device: ...HD(2,GPT,...,0x2FCAC,0x2000)
Setting currdev to disk0p2:
Loading unix... / Loading /platform/i86pc/amd64/boot_archive...
root on /ramdisk:a fstype ufs
[solnix] live-installer service starting (fs writable, devfsadm done)
solnix console login:
```

**Boot rate: 8/8.** Row 1 repeated eight times (`boot-logs/uefi-1.txt` … `uefi-8.txt`), each
reaching login with zero panics. Zero failures, so there is no failure-clustering to report — which
matters because flakiness in this project is bursty and a 4-run sample has lied before.

### Row 5 — BIOS booting the `.img` off USB does NOT work, and it is not a regression

Zero bytes of console output. The mechanism was measured, not guessed: the first 4 bytes of the
image's MBR are `00 00 00 00`, i.e. **there is no MBR boot code**, only the `0x55AA` signature.
`xorriso` writes MBR boot code only when handed syslinux's `isohdpfx.bin`, which this build does not
have. Verified against the **old** `-isohybrid-gpt-basdat` output as an A/B: it has the same
all-zero MBR and it also produces zero output, so this gap **predates** the current flags rather
than being caused by them. BIOS users should burn the `.iso` to a CD/DVD (row 4, passes) or use a
UEFI machine. Fix, if wanted later: pass `-isohybrid-mbr .../isohdpfx.bin` to `xorriso`.

### The `nvme` panic (row 6) is a QEMU artifact, not an image defect

Attaching the image as an emulated NVMe disk boots the kernel and then dies in
`nvme_identify`/`nvme_init`/`nvme_attach`:

```
panic[cpu0]/thread=...: nvme1: programming error: invalid NS/format in cmd ...
```

illumos's `nvme` driver rejects QEMU's NVMe emulation. `scripts/qemu-boottest.sh` therefore
defaults to **virtio** and documents this; the `nvme` bus is selectable only to reproduce the panic.
This says nothing about real NVMe hardware.

## Is a GPT required? — measured, and the answer is NO

The `.img` **does** carry a real GPT (`EFI PART` at LBA 1; partition 2 is a 4 MiB `EFI System`
holding `EFI/BOOT/BOOTX64.EFI`), and `make-iso-usb.sh` now hard-gates on that magic. But the GPT is
**not what makes UEFI boot work**, and that was established by destroying it rather than by
reasoning:

| experiment | result | log |
|---|---|---|
| zero the **primary** GPT header (LBA 1) | still boots — firmware used the **backup** GPT at end of disk; `Load Device: ...HD(2,GPT,...)` | `expt-nogpt-uefi.clean.txt` |
| zero **both** primary and backup GPTs | **still boots** — firmware fell back to the **El Torito** EFI entry: `Load Device: PciRoot(0x0)/Pci(0x3,0x0)/CDROM(0x1)` | `expt-nogpt-both-uefi.clean.txt` |

So on OVMF the ISO9660 + El Torito EFI entry is **sufficient on its own**; the GPT is belt-and-braces
that gives firmware a second, more conventional way in. The honest statement for real hardware:
**UEFI boot of this media can rely on either the GPT ESP or the El Torito EFI entry, and OVMF
accepts both independently.** Which path an X1 Carbon's firmware prefers is untested. Keeping the
GPT is still worth it: firmware that only enumerates GPT partitions on USB media has a path, and
firmware that only honours El Torito also has one.

## What the media does once it boots

The live media comes up on a UFS ramdisk root and starts the `site/solnix-live` SMF service, which
runs `devfsadm`, prints the visible disks, and then leaves a **console login**. Root has an **empty
password** by design (`oi-make-livecd.sh` clears it so a failed boot is recoverable).

Verified interactively on the real artifact, by driving the serial console
(`scripts/qemu-serial-drive.py`, log `qemu-uefi-login.clean.txt`):

```
solnix console login: root
root@solnix:~# id; uname -a; ls -l /usr/sbin/solnix-install
uid=0(root) gid=0(root)
SunOS solnix 5.11 illumos-68259130da i86pc i386 i86pc
-r-xr-xr-x   1 root  root  49486 /usr/sbin/solnix-install
```

There is **no interactive installer TUI on this media**. `solnix-install` is a command you run from
that root shell. An automatic install happens only if `/etc/solnix-autoinstall` exists on the media
(set `AUTOINSTALL_DISK=` when building) — deliberately **not** set here, so the media cannot erase a
disk on its own.

### A full install from the media, and the installed disk booting on its own

Done inside QEMU on the real artifact, to a blank 20 GiB second virtual disk
(`qemu-uefi-install2.clean.txt`, then `qemu-uefi-diskboot.clean.txt`):

```sh
# from the live media's root shell; c2t0d0 is the SECOND disk, not the media
SOLNIX_POOL=rpool SOLNIX_ALLOW_RPOOL=1 /usr/sbin/solnix-install c2t0d0
#   -> MARKER-INSTALL-RC=0
#   === boot_archive OK: 26972401 bytes ... ===
#   bootblock written for /dev/rdsk/c2t0d0s1, 280 sectors starting at 1024
#   === DONE: solnix installed on c2t0d0 (pool rpool, BE rpool/ROOT/solnix-1) ===
```

Then booting **that disk alone** under OVMF, with the media detached:

```
Setting currdev to zfs:rpool/ROOT/solnix-1:
root on rpool/ROOT/solnix-1 fstype zfs
solnix console login:
```

`console login:` = 1, `panic[` = 0, `makeutx failed` = 0.

**Pick the target disk by looking, never from this document.** The second virtio disk enumerated as
`c2t0d0`, not the `c1t1d0` that was assumed; `solnix-install`'s own guard caught it
(`FATAL: target disk c1t1d0 not present`). Run `ls /dev/rdsk | head -40` and exclude the media's own
disk. From a running ZFS-root host, `SOLNIX_POOL` must **not** equal the running root pool — there
is a `[ "$POOL" = "$ROOTPOOL" ] && die` guard; the pool name is not load-bearing for boot because
the loader follows the pool's `bootfs` property.

## Rebuilding from scratch

Two stages: an illumos host builds the staging tree, a Linux box wraps it. ~5 minutes plus ~1.

```sh
# Stage 1 — on an illumos build host (EC2: ami-014c4aaccd37b2356, c5.4xlarge, >=200 GiB root)
scp scripts/oi-make-livecd.sh scripts/solnix-install root@HOST:/var/tmp/
ssh root@HOST 'nohup /usr/bin/bash /var/tmp/oi-make-livecd.sh > /var/tmp/livecd-build.log 2>&1 &'
# poll /var/tmp/livecd-build.log; it ends with "=== DONE: staging tree ... ==="
scp root@HOST:/var/tmp/solnix-media/solnix-iso-tree.tar.gz /tmp/usb-image/

# Stage 2 — on Linux, with xorriso + mtools + mkfs.vfat
scripts/make-iso-usb.sh /tmp/usb-image/solnix-iso-tree.tar.gz /tmp/usb-image
#   -> /tmp/usb-image/solnix-x86_64.iso + solnix-x86_64-usb.img
```

`oi-make-livecd.sh` emits a **staging tree + tarball, not an `.iso`** — a long-standing source of
confusion. `make-iso-usb.sh` is the assembler. Verified rc=0 for both on 2026-09-09; the staging
tarball measured 87,671,797 B, sha256
`2ae3af3d89ac0cbd19abb26b85b7deccaa2a7acd4f9ad2ac6286fef550535580`.

Testing:

```sh
scripts/qemu-boottest.sh disk /tmp/usb-image/solnix-x86_64-usb.img /tmp/u.log 240 uefi virtio
scripts/qemu-boottest.sh disk /tmp/usb-image/solnix-x86_64-usb.img /tmp/u.log 240 uefi usb
scripts/qemu-boottest.sh iso  /tmp/usb-image/solnix-x86_64.iso     /tmp/b.log 240 bios
grep -c 'console login:' /tmp/u.log     # 1 = reached login
```

### Three defects fixed in `make-iso-usb.sh`, which had never been run before this

1. **`loader.conf` was written through a quoted heredoc** (`<<'EOF'`) containing
   `console="${SOLNIX_CONSOLE:-ttya,text}"`. That literal shell text was written into the file; the
   illumos loader has no parameter expansion, and it said so on the console —
   `console ttyb is invalid! ... no valid consoles!`. Now an unquoted heredoc, and the order is
   `text,ttya` because a laptop has no `ttya` at all while QEMU/EC2 still need the serial capture.
2. **`-isohybrid-gpt-basdat` produced no GPT at all** — measured: LBA 1 all zeros, MBR-only.
   Replaced with `-appended_part_as_gpt`, plus a hard gate that greps `EFI PART` at LBA 1 and exits
   non-zero. The gate is a real negative control: it fails on the old image, passes on the new one.
3. **`stat -c%s` → `wc -c`.** illumos has no `stat(1)` at all, and a `stat`-based size gate has
   already silently evaluated to zero elsewhere in this project. Also `VARIANT` now defaults to
   empty, so the outputs are exactly `solnix-x86_64.iso` / `solnix-x86_64-usb.img`.

## What is UNVERIFIED on real hardware

**No solnix image has ever booted on any non-EC2 physical machine, including this one.** Every
result above is QEMU with OVMF or SeaBIOS. Specifically untested:

- **Booting on a Lenovo X1 Carbon, or any physical laptop.** No claim is made. QEMU/OVMF success
  does not transfer: real firmware differs in USB enumeration, Secure Boot, and boot-entry
  preference.
- **Secure Boot.** `loader64.efi` is unsigned, so Secure Boot must be **disabled** in firmware or
  the machine will refuse to load it. Untested either way.
- **Real laptop hardware**: the framebuffer/`text` console on real graphics, the X1's NVMe SSD
  (only QEMU's emulation was tried, and illumos *panicked* on that), the trackpad, internal
  keyboard, wifi, and suspend. None exercised.
- **BIOS/CSM boot from a USB stick** — measured FAIL in QEMU (row 5), do not expect it to work.
- **An install onto real physical disks.** The install proof is a virtio disk in QEMU.
- **The declarative install path** (`SELF_INSTALL=0`: a nix-built toplevel, closure copy,
  generation-1 registration, `switch-to-configuration`). The proven path is `SELF_INSTALL=1`, which
  copies the live root. Same gap as recorded in `docs/install-media-first-real-install.md`.
- **The three EC2 boot fixes** from `docs/base-ami-rebuild-runbook.md` (offline `boot_archive` edit,
  single-DHCP-addrobj shim, `pit_is_broken=1`) are inherited here because the media is built from a
  root that carries them. `pit_is_broken=1` is an **EC2/Nitro** workaround; whether it is right,
  harmless, or wrong on an X1 Carbon is **untested**.

Tags used deliberately: rows 1-4 and the install/disk-boot are **VERIFIED-in-QEMU-UEFI** or
**VERIFIED-in-QEMU-BIOS**; everything about physical hardware is **UNVERIFIED-on-real-hardware**.

## If it does not boot on the X1

The single most useful thing is the **exact** first failing message, photographed or transcribed.
Useful discriminators:

- Firmware boot menu shows no entry for the stick → the ESP/El Torito was not found: check Secure
  Boot is off and legacy/CSM is off, and try the firmware's one-shot boot menu (F12).
- `illumos/amd64 EFI loader` appears, then it stops → the loader ran; the failure is later (console
  or `boot_archive`). Add `-v` and photograph the last 20 lines.
- Nothing at all after the vendor logo → firmware never loaded `BOOTX64.EFI`; the GPT-vs-El-Torito
  question above becomes the thing to test, by re-writing the stick from the `.iso` name instead.
