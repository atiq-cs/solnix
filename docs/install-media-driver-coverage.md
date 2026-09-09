# Policy: install media ships the full driver set

**Requirement (maintainer, 2026-09-09):** a single installer image should carry all available device
drivers, so it boots on whatever hardware someone tries it on.

## Status: already satisfied for drivers — measured, not assumed

`scripts/oi-make-livecd.sh:150` copies whole trees, not a curated list:

```
COPY_DIRS="
  platform/i86pc/kernel
  kernel
  usr/kernel
  ...
```

Verified against the **shipped** `usb-image-20260909b` ramdisk. ⚠️ **The counts below were first
measured by matching NUL-delimited names in the raw image bytes, and that instrument was wrong.**
Re-measured the correct way -- `lofiadm` + `mount` the UFS image and `diff` the actual directory
listings against the build host's -- coverage is **EXACT**:

| tree | build host | shipped ramdisk | difference |
|---|---|---|---|
| `kernel/drv/amd64` | **215** | **215** | none |
| `kernel/strmod/amd64` | 32 | 32 | none |
| `kernel/misc/amd64` | 69 | 69 | none |
| `platform/i86pc/kernel/drv/amd64` | 15 | 15 | none |
| `kernel/fs/amd64` | 21 | 21 | none |

`diff` of the two listings is **empty**: every driver the build host has, the media has.

About `eedev`: the byte-grep scored it missing, giving a "215 of 216" figure. Direct inspection of
the build host finds **no** `/kernel/drv/amd64/eedev`, and no `eedev` in `/etc/name_to_major` or
`/etc/driver_aliases`. Whatever the true story, the question is **moot**: the host-vs-ramdisk diff is
empty, so there is nothing that could be added. This disagreement is recorded rather than resolved.

**The lesson is the instrument, not the number.** Grepping bytes from outside an image is
approximate; mounting it and listing directories is exact. `oi-make-livecd.sh` now enforces equality
from **inside** the mounted ramdisk (gate (ii) of section 5a) and fails the build on ANY difference,
so this can no longer be a matter of opinion. A negative control confirms the gate fires when a
single driver is removed (215 vs 214).

Plus the platform/STREAMS/misc trees above. The full kernel tree is only **~40 MiB**
(`/kernel` 37.0 + `/platform/i86pc/kernel` 2.8), which is why this is affordable inside the ramdisk.

**So "ship all drivers" is not the gap.** `nvme`, `ahci`, `xhci`, `ehci`, `uhci`, `usbkbm`, `kbtrans`,
`conskbd`, `e1000g`, `bnxe` are all present — consistent with the X1 boot, where `nvme` attached and
`blkdev0` came online.

## The real gaps, and they are different problems

### 1. `/dev` nodes are a hardcoded 12-name allowlist — **FIXED in `usb-image-20260909c`**

`oi-make-livecd.sh:450` created exactly 12 `/dev` symlinks. Drivers being present does nothing if the
device node the userland opens is absent — which is precisely the `libzfs` (`/dev/zfs`) and `ttymon`
(`/dev/sad/user`) failures on the X1.

The allowlist is gone. The node set is now **derived**: every `/dev` entry whose symlink target points
into `devices/pseudo/` is staged (194 nodes, up from 12), handling both the bare-symlink shape
(`/dev/zfs`) and the directory-of-symlinks shape (`/dev/sad/{admin,user}`). Hardware-instance links
(`dsk/`, `rdsk/`, `net/`, NIC names) are deliberately excluded as per-machine state. Details and the
measured before/after fault rate: `artifacts/install-media/usb-image-20260909c/README.md`.

Note the fault was a **race**, not permanent absence: `devfsadm` does create these nodes, just after
`filesystem/local` and `ttymon` want them, and slower USB enumeration widens the window. Staging
closes it by construction.

### 2. illumos simply has no driver for some hardware

Measured on the build host: **zero** wifi drivers (`iwn`, `ath`, `iwh`, `ipw`, … none present), and for
graphics only `vgatext`. No amount of "include all available drivers" helps here, because they do not
exist to include. An X1 Carbon will therefore have **no wifi** and **no accelerated graphics** regardless
of media policy — use USB-Ethernet, and expect console/VGA text.

### 3. ~~`eedev` is missing~~ — ⚠️ MY DETECTION METHOD WAS UNRELIABLE, not the copy

I reported `eedev` as the one driver missing (215/216). **That was a measurement artifact.** `eedev`
does exist on the build host at `/kernel/drv/amd64/eedev`, and in the shipped ramdisk it appears **10
times as a raw substring but never NUL-delimited** — so my NUL-boundary matcher scored it absent while
`nvme` (424 hits) and `conskbd` (93) matched cleanly.

Searching for NUL-delimited names in a raw UFS image is a *heuristic*, not an inventory. Short names and
names embedded in longer strings behave differently, and a filesystem image is not a symbol table. The
215/216 figure should be read as **"at least 215 of 216, by a lossy method"** — the coverage conclusion
stands, the precision does not.

**This strengthens the case for the verification step rather than weakening it:** the right check runs
*inside* the built image (mount it, `ls /kernel/drv/amd64`, diff against the host) and fails the build on
a mismatch. Grepping bytes from outside is exactly the sort of approximate instrument that produced this
error.

## Standing requirements for future media

1. **Keep copying whole kernel trees.** Do not "optimise" the ramdisk by curating drivers — the 40 MiB
   is affordable and the coverage is the point.
2. **Verify, do not assume.** Assert the built ramdisk contains every driver the build host has, and
   **fail the build loudly** on a mismatch. The comment at `:476` claimed "~252 drivers" and was
   *approximately* right, which is how `eedev` went unnoticed.
3. **Apply the same principle to `/dev`.** A hardcoded node list is the same class of bug as a curated
   driver list — and it is the one actually biting.
4. ⚠️ **Respect the size ceiling.** The X1's largest free block below 4 GiB is **816,119,808 B**, and the
   loader stages the *uncompressed* `boot_archive` there. Current media is 356,515,840 B (43.7%). Adding
   content is fine; every rebuild must re-measure `gzip -dc boot_archive | wc -c` and report it. Note the
   compressed size is **not** a proxy — 480 MB of zeros once hid this entirely.
5. **State per-arch coverage honestly.** This all concerns x86_64. aarch64 and riscv64 media do not
   exist yet.
