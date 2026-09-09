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

Verified against the **shipped** `usb-image-20260909b` ramdisk (extracted the UFS image and matched
NUL-delimited names against the build host's actual driver inventory):

| | count |
|---|---|
| drivers in `/kernel/drv/amd64` on the build host | **216** |
| of those present in the shipped 340 MiB ramdisk | **215** |
| missing | `eedev` (1) |

Plus 15 platform drivers, 32 STREAMS modules, 69 misc modules. The full kernel tree is only **~40 MiB**
(`/kernel` 37.0 + `/platform/i86pc/kernel` 2.8), which is why this is affordable inside the ramdisk.

**So "ship all drivers" is not the gap.** `nvme`, `ahci`, `xhci`, `ehci`, `uhci`, `usbkbm`, `kbtrans`,
`conskbd`, `e1000g`, `bnxe` are all present — consistent with the X1 boot, where `nvme` attached and
`blkdev0` came online.

## The real gaps, and they are different problems

### 1. `/dev` nodes are a hardcoded 12-name allowlist

`oi-make-livecd.sh:450` creates exactly 12 `/dev` symlinks. Drivers being present does nothing if the
device node the userland opens is absent — which is precisely the `libzfs` (`/dev/zfs`) and `ttymon`
(`/dev/sad/user`) failures on the X1. See `docs/x1-dev-node-allowlist.md`.

**This is the item that needs the "ship everything" treatment**, not the drivers.

### 2. illumos simply has no driver for some hardware

Measured on the build host: **zero** wifi drivers (`iwn`, `ath`, `iwh`, `ipw`, … none present), and for
graphics only `vgatext`. No amount of "include all available drivers" helps here, because they do not
exist to include. An X1 Carbon will therefore have **no wifi** and **no accelerated graphics** regardless
of media policy — use USB-Ethernet, and expect console/VGA text.

### 3. `eedev`

One driver missing from the copy. Trivial, but it shows the copy is not literally complete, so a
verification step is warranted rather than trusting the comment.

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
