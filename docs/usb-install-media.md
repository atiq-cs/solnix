# solnix x86_64 USB / ISO install media — how to build it, how to flash it, what is proven

**Status 2026-09-09d: FLASH `usb-image-20260909d/`.** It is the **first image containing all three
fixes**. `usb-image-20260909c/` was built from `49c111f765`, which predates `c2f9229e4f`, so it fixed
the ZFS race and **still flooded the login prompt** — the exact symptom reported as "no keyboard".
The "d" image is built from `740b1d6335`, which has `c2f9229e4f` as an ancestor.

## ⚠️ FLASH THIS FILE

```
artifacts/install-media/usb-image-20260909d/solnix-x86_64-usb.img
```

Built from commit **`740b1d6335`**. Three fixes, one image:

| fix | commit | in `b` | in `c` | in **`d`** |
|---|---|---|---|---|
| `RD_MB=340` — the EFI staging allocation fits the X1 | earlier | ✅ | ✅ | ✅ |
| `/dev` node staging — closes the ZFS race | `740b1d6335` | ❌ | ✅ | ✅ |
| **console-flood fix** — login was eating `/dev/dsk` names | `c2f9229e4f` | ❌ | ❌ | ✅ |
| **`solnix` boot branding** | `c2f9229e4f` | ❌ | ❌ | ✅ |

Measured on the shipped `d` bits, over **12 QEMU boots**:

| counter | rate | previous image |
|---|---|---|
| reaches `solnix console login:` (UEFI USB) | **8 / 8** | 8/8 on `c` |
| `failed to initialize ZFS library` | **0 / 8** | 0/8 on `c`, **4/8** on `b` |
| login-prompt flood (device names typed into `login`) | **0 / 8** | **8/8** on `c` — see the correction below |
| `panic[` / `failed to allocate` | **0 / 8** | 0/8 |
| BIOS / El Torito reaches login | **4 / 4** | 4/4 |

Zero failures on every counter, so there is no clustering to report — which matters, because
failures here are bursty rather than independent and that is why the UEFI arm is 8 runs and not 4.
Full per-run table, all verification commands, and an explicit list of what remains untested on
hardware: `artifacts/install-media/usb-image-20260909d/README.md`.

### ⚠️ Correction: the flood on image `c` was 8/8, not 3/8

The previously recorded "3 of 8" counted only runs where a device name landed immediately after the
literal `console login: ` on the same line. Counting the typed names themselves —
`grep -cE '^c[0-9]t[0-9A-Z]+d0'` — finds **9 or 10 device names in all eight** of image `c`'s shipped
logs. The symptom the maintainer reported was present on **every** `c` boot. Same recurring shape as
the other retractions in this file: a real measurement summarised one step too confidently, by a grep
sensitive to line breaks.

### A defect caught before the `d` build, worth remembering

`scripts/make-iso-usb.sh` step 0 **rewrites** `boot/loader.conf`, and its heredoc did not carry
`loader_brand` / `loader_menu_title`. `oi-make-livecd.sh` writes them on the illumos host, and the
assembler then overwrote the file — so half the branding fix would have been **silently reverted**
while the build log reported the rebrand as successful. One script undoing another's work with no
error anywhere: the same silent-no-op class as the `readlink` and `stat` bugs. Both keys are now in
the assembler's heredoc, plus a hard gate that fails the build if `menu.4th` still says
`Welcome to illumos`, or lacks `Welcome to solnix`, or `loader.conf` lacks `loader_brand="solnix"`.

**Superseded — do not flash.** `usb-image-20260909c/` (no console-flood fix, no branding),
`usb-image-20260909b/` (also missing the `/dev` staging fix; its 18-boot matrix is kept as the
reference), `usb-image-20260909/` (the pair that failed on the X1 at 820 MiB).

## The artifacts

**Current — use these:**

| file | bytes | sha256 |
|------|------:|--------|
| `artifacts/install-media/usb-image-20260909d/solnix-x86_64.iso` | 101,533,696 | `9b4a8213cea26c708dea2fad226af57f196480a21d0b053cd34b226663ef1f6f` |
| `artifacts/install-media/usb-image-20260909d/solnix-x86_64-usb.img` | 101,533,696 | `9b4a8213cea26c708dea2fad226af57f196480a21d0b053cd34b226663ef1f6f` |
| `artifacts/install-media/usb-image-20260909d/solnix-iso-tree.tar.gz` | 86,569,015 | `f365be41083fcdd011f44cc0cf376d11de345e2980444687a133ac78f997d926` |

**Superseded — the ZFS-fix image, kept for its logs:**

| file | bytes | sha256 |
|------|------:|--------|
| `artifacts/install-media/usb-image-20260909c/solnix-x86_64.iso` | 100,765,696 | `30e61f5c33419c180a58f95b759b9dd00bd0aa149765387f8bd723485618a6a6` |
| `artifacts/install-media/usb-image-20260909c/solnix-x86_64-usb.img` | 100,765,696 | `30e61f5c33419c180a58f95b759b9dd00bd0aa149765387f8bd723485618a6a6` |
| `artifacts/install-media/usb-image-20260909c/solnix-iso-tree.tar.gz` | 85,799,990 | `0bf5834d479d92db96e7d06982c03a65e138ae8c76a811395e54e77d8db7c440` |

**Superseded — the boot-fix image, kept because its 18-boot QEMU matrix is the reference:**

| file | bytes | sha256 |
|------|------:|--------|
| `artifacts/install-media/usb-image-20260909b/solnix-x86_64.iso` | 100,771,840 | `cc1c843556357ff544eec3dae7ca2c9939493b88c0759e4419cb222623b7b871` |
| `artifacts/install-media/usb-image-20260909b/solnix-x86_64-usb.img` | 100,771,840 | `cc1c843556357ff544eec3dae7ca2c9939493b88c0759e4419cb222623b7b871` |
| `artifacts/install-media/usb-image-20260909b/solnix-iso-tree.tar.gz` | 85,808,795 | `cca4fee3c73a1aadafd14b7cfddafb47ec2c5ddca05ce0aac7be3561a5438bf2` |

## The two X1 login-prompt faults

The "b" media reached the login prompt on real hardware and printed:

```
internal error: failed to initialize ZFS library
svc:/system/filesystem/local:default: WARNING: /usr/sbin/zfs mount -a failed: exit status 1
ttymon: open /dev/sad/user failed: No such file or directory
```

plus an endless `hid1: Invalid Report Descriptor` and **no working keyboard** — including an
external USB keyboard, while the keyboard worked fine at the loader's `ok` prompt.

### Root cause of the ZFS and `sad` faults: a hardcoded `/dev` allowlist

`oi-make-livecd.sh` staged `/dev` from a **13-name hardcoded list**, so the live ramdisk shipped
exactly **12** `/dev` entries. `libzfs_init(3lib)` opens `/dev/zfs`; `ttymon`/`autopush` open
`/dev/sad/user`. Neither was in the list.

The list was wrong in *both* directions — it also named `dlpi`, which does not exist on the build
host at all. That is the signature of hand-maintained state. Drivers already shipped **wholesale**
(whole kernel trees, an exact 215/215 match against the host); `/dev` did not. A present driver is
useless if the node userland opens is absent.

**The fix derives the set instead of naming it**: every `/dev` entry whose symlink target points into
`devices/pseudo/` is staged — 194 nodes, up from 12. Pseudo devices are drivers with no hardware
behind them, so they are identical on every machine. Both shapes are handled, which is where a naive
fix silently no-ops:

| node | shape |
|---|---|
| `/dev/zfs` | a bare **symlink** → `../devices/pseudo/zfs@0:zfs` |
| `/dev/sad` | a **directory** of symlinks → `admin`, `user` |

The old `[ -L ]` test is false for a directory, so merely appending `sad` to the list would have done
**nothing**. Hardware-instance links (`dsk/`, `rdsk/`, `net/`, `cfg/`, `term/`, NIC names) are
deliberately **not** staged: they encode the build host's own disk and NIC instance numbers, the same
per-machine-state class as shipping a populated `/etc/path_to_inst`. `devfsadm` regenerates those at
boot for the hardware actually present.

### It was a RACE, not permanent absence

This corrects the first diagnosis. On a failing-class boot, *after login*, `/dev/zfs` exists,
`zpool list` works, and `truss` shows `open("/dev/zfs", O_RDWR) = 3` **succeeding**. `devfsadm` does
create the nodes — just not before `filesystem/local` and `ttymon` want them. USB widens the window:
`scsa2usb` + `sd` enumerate more slowly than virtio's `blkdev`, which is why the fault showed on USB
boots and not on virtio/ahci/cdrom ones. **The X1 boots from USB.** Staging closes the race by
construction — a node in the ramdisk exists at time zero, so nothing can lose a race to `devfsadm`.

The fault is therefore **intermittent**, and a single pass proves nothing. Measured with
`scripts/usb-rate.sh`:

| image | ZFS fault rate over USB boots |
|---|---|
| `usb-image-20260909b` | **4 of 8** |
| `usb-image-20260909c` | **0 of 8** |

### Build gates now enforce all of this

Every serious defect in this script's history was a **silent staging failure**, not a wrong decision:
no `readlink(1)` made `ln -sf ""` a no-op and shipped zero `/dev` nodes; no `stat(1)` made a size
gate always-false so the check after its `&&` never ran; illumos `xargs` split a tool list into
multiple `tar` streams and dropped entries after the split. So `oi-make-livecd.sh` section 5a now
**asserts the result** while the ramdisk is still mounted, and dies loudly:

1. 24 required `/dev` nodes exist (including `zfs` and `sad/user`)
2. driver-tree counts **equal** the build host's, per tree — measured from *inside* the mounted image
3. the console-input and zfs kernel modules are present
4. `path_to_inst` and `mnttab` ship at **0 bytes** (per-machine state must not ride along)
5. `/etc/solnix-autoinstall` is **absent** (autoinstall stays opt-in)

`scripts/dev-gate-negcontrol.sh` is the negative control: it sabotages each mechanism and asserts the
gate flips to FAIL. Result on-node: **6 detected, 0 missed**. A gate that cannot fail proves nothing.

## What is proven vs projected for the "c" image

**PROVEN in QEMU** (8/8 USB boots, `usb-image-20260909c/boot-logs/RESULTS.txt`):

* `zpool list` and `zfs list` run with no `internal error: failed to initialize ZFS library`
* 0 ZFS faults in 8 USB boots, against 4-in-8 on the "b" image with the same harness
* the staged nodes are reachable at runtime **and are demonstrably the staged ones**: `/dev/zfs`,
  `/dev/sad/user`, `/dev/sad/admin` and `/dev/kbd` all carry the **build** mtime, not the boot mtime
* `dev(7FS)` does **not** mount over `/dev` on live media (`mount -p` shows no `/dev` entry), so
  staging is not masked. This was the one objection that could have rendered the whole fix inert, and
  it is settled by measurement rather than by argument

**PROJECTED, not proven:**

* the `ttymon: open /dev/sad/user failed` error **never reproduced locally** in any run, though it is
  in the shipped "b" console log. The node is now present by construction, so the repair is inferred

**⚠️ NOT FIXED, NOT EXPLAINED — the keyboard.** QEMU presents a PS/2 keyboard (`kb8042`) on every
storage bus, so **no QEMU boot exercises the X1's USB-HID input path** (`hid → usbkbm → kbtrans →
conskbd → wc`). `/dev/kbd` and `/dev/mouse` are now staged, which *might* help if a missing `conskbd`
node was the cause, but that is untested speculation — do not read the `/dev` fix as a keyboard fix.
Two hypotheses were **refuted** by mounting the shipped media and looking:

* `/etc/path_to_inst` pinning a PS/2 keyboard the X1 lacks — the shipped file was **already 0 bytes**
  (see `docs/x1-path-to-inst-hypothesis.md`, annotated REFUTED)
* missing STREAMS modules — `usbkbm`, `kbtrans`, `consconfig`, `consconfig_dacf`, `hid`, `conskbd`
  and `consms` were **all already present**

The next experiment worth running: QEMU with `-device usb-kbd` on the xhci bus, which *would* exercise
the real HID chain. Not yet attempted.

## Autoinstall is OFF by default — how to opt in

This image never writes to a disk unasked, and build gate 5 fails the build if
`/etc/solnix-autoinstall` is ever present by default. Opting in is a deliberate act performed **on the
flashed media**, not in the build:

```sh
# with the media's root filesystem mounted, as root:
echo auto     > /etc/solnix-autoinstall   # install to the first non-media disk found
echo c1t1d0   > /etc/solnix-autoinstall   # or name the target disk explicitly
```

With that file present, `site/solnix-live` runs `solnix-install` unattended **and destroys the target
disk**. It is the keyboard-free install path — which is exactly why it must be opt-in.

## The size constraint, re-measured

```
gzip -dc boot_archive | wc -c   =   356,515,840 B   (340.0 MiB)
X1 Carbon's measured ceiling    =   816,119,808 B   (778.3 MiB)
=> 43.7% of ceiling, 438.3 MiB of headroom
```

**Unchanged from "b"**: 194 extra symlinks cost **zero** bytes of raw size. `RD_MB=340` is kept. That
figure is what the EFI loader asks firmware for as one contiguous block below 4 GiB, so it is the
acceptance metric for real-hardware boot (gzipped: 84,575,931 B).

**Superseded — kept only for comparison, do NOT flash** (this is the pair that failed on the X1):

| file | bytes | sha256 |
|------|------:|--------|
| `artifacts/install-media/usb-image-20260909/solnix-x86_64.iso` | 104,761,344 | `19d838554b392bd15ddc8da80ccb6ee05770b6d88ea444b704f28c43cbe1ae6d` |
| `artifacts/install-media/usb-image-20260909/solnix-x86_64-usb.img` | 104,761,344 | `19d838554b392bd15ddc8da80ccb6ee05770b6d88ea444b704f28c43cbe1ae6d` |

In each pair the two files are **byte-identical on purpose** (same sha256 — that is not a mistake): an
isohybrid image *is* simultaneously a valid ISO9660 CD image and a valid partitioned disk image, so
one file serves both. The `.img` name exists so the deliverable is unambiguous. Unlike the older
July artifacts, this `.img` **does** carry a real partition table, so the name does not over-promise:

```
$ dd if=solnix-x86_64-usb.img bs=512 skip=1 count=1 | head -c 8
EFI PART                       <- GPT header present at LBA 1
$ fdisk -l solnix-x86_64-usb.img
Disklabel type: gpt
...img1     64 195755  195692 95.6M Microsoft basic data     <- the ISO9660 data
...img2 195756 203947    8192     4M EFI System              <- the ESP, EFI/BOOT/BOOTX64.EFI
```

`SHA256SUMS` sits beside them. Verify before flashing:

```sh
cd artifacts/install-media/usb-image-20260909d && sha256sum -c SHA256SUMS
```

⚠️ **`*.iso` and `*.img` are gitignored** (`.gitignore:9` and `:6`), so these two files **cannot be
committed** and will not survive a fresh clone. `SHA256SUMS` and the boot logs under `boot-logs/`
*are* committable and are the durable record. Rebuild with the recipe below.

⚠️ **Do not use the older files in `artifacts/install-media/`** (`solnix-x86_64-usb.img`,
`solnix-x86_64-minimal-usb.img`, `solnix-x86_64-graphical-usb.img`, dated 2026-07-29/30). They are
MBR-only pre-fix outputs, their provenance is unrecorded, and `solnix-x86_64-minimal.iso` in the
repo root is a **broken symlink**. Only the `usb-image-20260909*/` pairs below were built and tested by
a recorded run — and of those, only `usb-image-20260909d/` carries all three fixes.

## Flashing to a USB stick

```sh
cd artifacts/install-media/usb-image-20260909d     # <-- the "d" dir: the only one with all three fixes
sha256sum -c SHA256SUMS                            # must print: OK
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

Because the image is smaller (96 MiB) than any real stick, the tail of the stick is left as-is;
that is harmless, and `dd` does not need to fill the device.

## The X1 Carbon staging failure, and the fix

The maintainer flashed `usb-image-20260909/solnix-x86_64-usb.img` and booted a Lenovo X1 Carbon. It
got **further than QEMU could have promised** — illumos logo, EFI loader executing, media read — and
then:

```
Loading /platform/i86pc/amd64/boot_archive...
failed to allocate 859832320 bytes for staging area: 9
Can not load environment module: out of memory
No rootfs module provided, aborting
ok
```

**Mechanism, traced through the gate source rather than guessed.**
`usr/src/boot/efi/loader/copy.c:196` `efi_loadaddr()` calls
`BS->AllocatePages(AllocateMaxAddress, EfiLoaderData, pages, &paddr)` with `paddr = UINT32_MAX`, so
it demands **contiguous pages below 4 GiB**. It `stat()`s the file, so it asks for the
**UNCOMPRESSED** size: `boot_archive` was 88,570,656 B gzipped but **859,832,320 B** raw — byte for
byte the number in the error. Status `9` = `EFI_OUT_OF_RESOURCES`. Everything after is downstream of
the failed staging. This is **not** the NVMe risk; it fails before any disk driver loads.

**The ceiling is now measured, not assumed.** `memmap` at the `ok` prompt lists the machine's
`ConventionalMemory` regions; the largest below 4 GiB is 199,248 pages at physical `0x100000` =
**816,119,808 B (778.3 MiB)**. So the request missed by **43,712,512 B (41.7 MiB, 5.1%)** — a
near-miss, which is why resizing the ramdisk is the right fix rather than patching the loader.

⚠️ Use **`memmap`**, not `smap`, for this question. `smap` collapses several EFI types into one and
merges adjacent runs; its `base=0x58000000 len=0x200000` line is a small unrelated 2 MiB region and
reading it as the ceiling caused one wrong stand-down. Full transcription in
`docs/x1-memmap-analysis.md`.

**The ramdisk was 4.2x oversized.** `oi-make-livecd.sh` defaulted `RD_MB=820` while the populated
UFS held only **195.0 MiB** (measured two ways: superblock + cylinder-group summary of the shipped
image, and `df -k` on the mounted image during the build). The gzipped size hid it completely — the
extra ~480 MB was zeros, so it compressed to nothing and the media size looked fine.

**The fix**, in `scripts/oi-make-livecd.sh`:

| knob | was | now | why |
|---|---:|---:|---|
| `RD_MB` (minimal) | 820 | **340** | 356,515,840 B: holds 195.0 MiB with 135 MiB of fs slack, and leaves 438.3 MiB of headroom inside the X1's 778.3 MiB block |
| `RD_MB` (graphical) | 900 | **500** | would have failed identically or worse; **UNTESTED**, see below |
| `RD_NBPI` (`newfs -i`) | default 2048 | **8192** | inode tables cost ~20 MB to hold 3,369 inodes out of 160,000; keeps a >10x margin and gives back ~15 MB |
| `RD_MAX_RAW_MB` | — | **560** | new hard gate on the uncompressed size |
| `RD_MIN_FREE_MB` / `RD_MIN_FREE_INODES` | — | **32 / 5000** | new hard gates so a tight `RD_MB` can never silently ship a full or truncated live root |

Measured result, verified by extracting `boot_archive` from the shipped `.iso` itself:

```sh
$ xorriso -indev solnix-x86_64.iso -osirrox on \
      -extract /platform/i86pc/amd64/boot_archive /tmp/ba
$ gzip -dc /tmp/ba | wc -c
356515840          # <-- what the loader asks EFI for. Ceiling is 816,119,808.
```

| | uncompressed | vs the X1's 778.3 MiB block |
|---|---:|---|
| old media | 859,832,320 B (820.0 MiB) | **41.7 MiB OVER** → refused |
| new media | **356,515,840 B (340.0 MiB)** | 438.3 MiB spare, uses 43.7% |

The three new gates were **negative-controlled** on the build host — each flips to FAIL when its
threshold is moved past the real value (`RD_MAX_RAW_MB=100` → fail, `RD_MIN_FREE_MB=200` → fail,
`RD_MIN_FREE_INODES=50000` → fail), so they are not checks that cannot fail.

⚠️ **QEMU cannot validate this fix, only guard against regression.** OVMF hands out a clean
low-4 GiB map and accepted the old 820 MiB image 8/8 times. The X1 itself is the only instrument
that can confirm the allocation now succeeds.

### The 2026-09-09b boot matrix — 18/18 PASS

All runs `scripts/qemu-boottest.sh` on `usb-image-20260909b/`, logs in its `boot-logs/`
(`RESULTS.txt` has the per-run counts, `*.clean.txt` the ANSI-stripped consoles):

| runs | firmware | media + attachment | result |
|---:|---|---|---|
| 8 | UEFI (OVMF) | `.img` as virtio-blk disk | **8/8 login**, 0 panic |
| 2 | UEFI (OVMF) | `.img` on a real USB bus (xhci + usb-storage) | **2/2 login**, 0 panic |
| 4 | UEFI (OVMF) | `.iso` as CD-ROM | **4/4 login**, 0 panic |
| 4 | BIOS | `.iso` as CD-ROM (El Torito) | **4/4 login**, 0 panic |

`failed to allocate` appears **0 times in all 18**. Zero failures, so there is no clustering to
report — which matters because flakiness here is bursty and a 4-run sample has lied before; that is
why the UEFI arm is 8 runs and not 4. Row 5 of the older matrix (BIOS booting the `.img` off USB)
was not retested: it fails for an unrelated, already-measured reason (no MBR boot code), below.

## ⚠️ Testing in QEMU REQUIRES `-cpu host` (or `-cpu Haswell`), not the default

**Read this before believing any QEMU failure.** With QEMU's default CPU model the media does not
boot, and the failure looks exactly like a broken image. It is not. Two distinct symptoms have been
observed, both cured by the CPU model alone:

| CPU model | symptom | verdict |
|-----------|---------|---------|
| `-cpu qemu64` (default) | `ld.so.1: mount: fatal: /lib/libc.so.1: hardware capability (CA_SUNW_HW_1) unsupported: 0x8  [ SEP ]`, repeating | libc needs `AV_386_SEP` (sysenter); qemu64 does not advertise it |
| `-cpu qemu64` (default) | `WARNING: init(8) exited on fatal signal 9: restarting automatically`, in a loop | the default CPU also lacks `xsave` (CPUID.0xD=0), which SIGKILLs PID 1 |
| **`-cpu host`** (KVM) | **boots to login** | what every PASS below used |
| `-cpu Haswell` | boots (slow, TCG) | the no-KVM fallback |

Both symptoms are **QEMU CPU-model artifacts, not image defects**: real X1 Carbon silicon has SEP
and xsave, as does EC2. `scripts/qemu-boottest.sh` picks `-cpu host -accel kvm` automatically
whenever `/dev/kvm` is writable and falls back to `-cpu max` otherwise, so it sidesteps this
silently — which is precisely why the trap is worth writing down: a hand-rolled `qemu-system-x86_64`
command line will hit it and the error message blames libc.

Evidence: `boot-logs/expt-cpu-qemu64.clean.txt` (default CPU, my artifact, init SIGKILL loop, never
reaches login) versus every PASS row below (`-cpu host`, reaches login).

## What boots — measured, in QEMU only (the older 2026-09-09 pair)

All rows are `scripts/qemu-boottest.sh` runs on the **superseded** 2026-09-09 artifact, **with
`-cpu host`**. Kept because the mechanisms (CPU model, GPT-vs-El-Torito, `nvme` panic) are unchanged
by the ramdisk resize; for the current media see [the 18/18 matrix above](#the-2026-09-09b-boot-matrix--1818-pass).
"reaches login" means the serial console printed `solnix console login:`. Logs in
`artifacts/install-media/usb-image-20260909/boot-logs/`.

| # | firmware | media + attachment | result | log |
|---|----------|--------------------|--------|-----|
| 1 | **UEFI** (OVMF) | `.img` as virtio-blk **disk** | **PASS** — reaches login | `qemu-uefi-usbimg-virtio.clean.txt` |
| 2 | **UEFI** (OVMF) | `.img` on a real **USB bus** (xhci + usb-storage) | **PASS** — reaches login | `qemu-uefi-usbimg-usbbus.clean.txt` |
| 3 | **UEFI** (OVMF) | `.iso` as CD-ROM | **PASS** — reaches login | `qemu-uefi-iso.clean.txt` |
| 4 | **BIOS** | `.iso` as CD-ROM (El Torito) | **PASS** — reaches login | `qemu-bios-iso.clean.txt` |
| 5 | **BIOS** | `.img` as a **disk** (USB-stick path) | **FAIL — zero console output** | `qemu-bios-usbimg.clean.txt` |
| 6 | UEFI | `.img` as **NVMe** | boots, then **panics in `nvme`** | (smoke image) |
| 7 | UEFI | `.img` as virtio disk, **default `-cpu qemu64`** | **FAIL — `init(8)` SIGKILL loop** | `expt-cpu-qemu64.clean.txt` |

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
confusion. `make-iso-usb.sh` is the assembler. Verified rc=0 for both on 2026-09-09b; the staging
tarball measured 85,808,795 B, sha256
`cca4fee3c73a1aadafd14b7cfddafb47ec2c5ddca05ce0aac7be3561a5438bf2`. (Stage 1 does **not** need a
>=200 GiB root: the 2026-09-09b build ran entirely in the base AMI's 20 GiB `rpool`, using <2 GiB.
On `ami-014c4aaccd37b2356` an extra `--block-device-mappings` volume may not even enumerate — only
`c1t1d0` appeared — and it does not grow `rpool` either way; see `docs/base-ami-rebuild-runbook.md`.)

⚠️ **Check the size lines the build prints**, because they are the real-hardware acceptance metric:

```
live root: 199698KB used / 341558KB total / 138445KB avail (RD_MB=340 nbpi=8192)
live root inodes: 3369 used / 38679 free
boot_archive: 84581412 bytes gzipped, 356515840 bytes UNCOMPRESSED (what the EFI loader stages below 4GB)
```

The build now **fails** rather than shipping an oversized or over-full ramdisk (`RD_MAX_RAW_MB`,
`RD_MIN_FREE_MB`, `RD_MIN_FREE_INODES`). Do not raise `RD_MB` "to be safe" — padding it is precisely
what broke the X1.

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

## The graphical (live Xfce) ISO — separate artifact, boots, NOT rebuilt by this run

⚠️ **The graphical ISO is UNTESTED against the staging bug and must not be flashed to the X1 yet.**
The artifact below predates the `RD_MB` fix and was built at `RD_MB=900`, so its uncompressed
`boot_archive` is larger than the 820 MiB the X1 already refused — it would fail identically or
worse. `oi-make-livecd.sh` now defaults graphical to `RD_MB=500`, but **no graphical media has been
rebuilt or booted since**, so that number is a projection from the minimal build's measurements
(~195 MiB minimal + ~177 MiB Xfce closure = ~372 MiB of content), not a measurement. Rebuild with
`GRAPHICAL=1` and check the printed `boot_archive: ... UNCOMPRESSED` line before trusting it.

`artifacts/install-media/solnix-x86_64-graphical.iso` (231,247,872 B, sha256 `cd3c8302e5ada09d…`,
dated 2026-07-30) is a **different, older** artifact than the pair above. It was **not** rebuilt
here, so it does not carry the three `make-iso-usb.sh` fixes or the `readlink` ramdisk fix. It was
re-tested as-is under OVMF/UEFI with `-cpu host` (`boot-logs/expt-graphical-uefi.clean.txt`):

```
illumos/amd64 EFI loader, Revision 1.1 -> Loading unix... -> Booting...
[solnix] starting live Xfce desktop (Xvfb software framebuffer)...
[solnix] live Xfce desktop launching on :0 (Xvfb pid 579)
[solnix] SESSION-STILL-UP-CHECK (t+85s):
  solnix 599 597 ... xfce4-sess      <- SAME pid as at t+25s
  solnix 609 599 ... xfsettingsd     <- SAME pid
  solnix 618 599 ... xfce4-panel     <- SAME pid
  root   579   1 ... Xvfb
```

**PASS**: the session comes up and *stays* up — same three pids across the 60 s window, which is the
real pass condition. `CA_SUNW_HW_1` = 0, `panic[` = 0.

The log's own last line says `SESSION-VERDICT: xfce4-session GONE`, and that is a **false negative**,
not a failure: the check greps `xfce4-session` but `ps` truncates the argument to `xfce4-sess`, and
pid 599 is demonstrably alive in the very snapshot above. `oi-make-livecd.sh:1484` already greps
`xfce4-sess`, so the bug is fixed in the script and only persists in this pre-fix July media. Do not
read that line as a regression.

Still true of the graphical ISO: no GPT (it is a pre-fix build), so treat its `-usb.img` sibling as
BIOS/El-Torito-only, and rebuild it with `VARIANT=graphical scripts/make-iso-usb.sh` before shipping
it as a USB image.

## What is UNVERIFIED on real hardware

**No solnix image has ever booted on any non-EC2 physical machine, including this one.** Every
result above is QEMU with OVMF or SeaBIOS. Specifically untested:

- **Booting to login on a Lenovo X1 Carbon, or any physical laptop.** Partially answered now: on the
  X1 the firmware *did* load `BOOTX64.EFI`, enumerate the USB stick (`lsdev` showed it as `disk1`,
  `(removable) ISO9660`), and read the filesystem — then refused the 820 MiB staging allocation. With
  340 MiB the request is 438 MiB inside the machine's measured largest low block, but **that boot has
  not been run yet**. Everything after staging on real hardware remains unverified.
- **The graphical variant, at any size.** Its `RD_MB` default is now 500 (was 900, which would have
  hit the same wall), but **no graphical media was rebuilt or booted** for the 2026-09-09b run —
  only the minimal variant was. Tagged **UNTESTED**; the `RD_MAX_RAW_MB`/`df`/inode gates are what
  protect it, and they will fail the build loudly rather than ship an unbootable image.
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
