# Phase A6-vm — early-VM `kbm_map` overlapping-VA bug: located, fixed, validated

Build node i-0d24c0ec7a9a0e109 (18.216.236.141, m5.4xlarge) left **running**.
No git commit (orchestrator commits). No SG/0.0.0.0/0 changes.

## TL;DR

| Item | Result |
|---|---|
| **kbm overlap located** | `bop_panic` in `kbm_map()` (uts/armv8/vm/kboot_mmu.c) — leaf PTE already VALID → double VA map. |
| **Colliding pair** | (1) **dboot** `read_elf64`→`get_progmemory`→`map_pages` maps the kernel writable PT_LOAD segment's **full page-rounded `p_memsz` (incl. BSS)**. (2) **kernel krtld** `kobj_segbrk(&_edata/&_etext)`→`BOP_ALLOC(pva)`→`do_bsys_alloc`→`kbm_map` grows the kernel from the (unaligned) `_edata`/`_etext` cursors, whose page-round-up lands **inside dboot's page-rounded image map** → conflict (old PA ≠ new PA). |
| **Why size-sensitive** | The alias only occurs when a growth cursor sits mid-page and its round-up hits the last page dboot mapped; that page boundary shifts with unix size, so the fortunate (pristine) layout missed it and the larger (rebuilt) layout hit it. |
| **Fix** | `usr/src/uts/common/krtld/kobj.c`, `attr_val()` — page-align `_etext` and `_edata` **up** (aarch64-guarded) so kobj growth always starts on the first page dboot did **not** map. One-block change. |
| **FDT path** | **Full success.** Fresh (fixed) unix (entry `0xfe05e000`, the larger one that panicked) reaches `root on armpool/ROOT/braich` (zfs), device attach (`gicthree0`, `gicv3_its0`, `arm_gtmr0`, `ecam0`/pcie), SMF milestones, `Hostname: braich`. **No kbm overlap. No regression** (pristine baseline still boots identically). |
| **ACPI path** | **Past the kbm overlap.** dboot synth-FDT ok → entry → **no kbm overlap** → past `synthetic_bootaux` → reaches `prom_emul` device enumeration. Exact **next** blocker below. |

## What maps `0xfffffffffe613000` (the two colliding parties)

`0xfffffffffe613000 = KERNEL_TEXT + 0x613000`, which is **inside the kernel image's `.bss`** (below `_end = 0xfe6156d8`).

1. **dboot (boot loader)** — `usr/src/uts/armv8/dboot/dboot_elf_loader.c:read_elf64()` calls
   `get_progmemory(base, size=p_memsz)` (`standalloc.c`) → `resalloc(RES_CHILDVIRT)` → `map_pages`
   (`dboot_standalloc.c`) into `ptbl_high` (TTBR1). For the writable segment
   (`p_vaddr=0xfe154000`, `p_memsz=0x4c16d8`) this maps every page up to
   `base + roundup(p_memsz, PAGESIZE) = 0xfe616000` — the whole BSS, including `0xfe613000`.

2. **kernel krtld** — `usr/src/uts/common/krtld/kobj.c`:
   `attr_val()` sets `_edata = _data + p_memsz` (= `_end`, **not page-aligned**) and `_etext = _text + p_memsz`.
   Then the standalone module loader and `kobj_alloc` call
   `kobj_segbrk(&_edata/&_etext, ...)` → `pva = P2ROUNDUP(*spp, alloc_pgsz)` → `BOP_ALLOC(ops, (caddr_t)pva, ...)`
   (kobj.c:4268) → `do_bsys_alloc(virthint=pva)` → `kbm_map(pva)`.
   `kobj_segbrk` is the **only** explicit-VA `BOP_ALLOC` caller in the KERNEL_TEXT range.

Runtime trace (instrumented) at the panic:

```
dboot map base=0xfe154000 size=0x4c16d8 mapend=0xfe616000        <- dboot maps thru BSS
attr_val _edata=0xfe6126d8 (raw, mid-page)                       <- kernel growth cursor
segbrk spp=0xfe612db0 pva=P2ROUNDUP(...)=0xfe613000 size=0x400    <- rounds up into dboot's map
overlap va=0xfe613000 oldpa=0x40623000 newpa=0x40642000          <- SAME VA, DIFFERENT PA => real conflict
```

`kbm_map()` (kboot_mmu.c) panics on any already-valid leaf PTE (unlike dboot's `map_pages`,
which tolerates an *equivalent* remap). So the kernel re-mapping a dboot-mapped BSS page to a
different PA is a genuine double-allocation, correctly caught.

## The fix (applied, persisted)

`usr/src/uts/common/krtld/kobj.c`, end of `attr_val()`'s PT_LOAD loop, aarch64-guarded:

```c
#if defined(__aarch64__)
	/* dboot maps the kernel image in whole pages; align kobj growth
	 * cursors up so kobj_segbrk() never re-enters a dboot-mapped page. */
	_etext = (caddr_t)P2ROUNDUP((uintptr_t)_etext, (uintptr_t)PAGESIZE);
	_edata = (caddr_t)P2ROUNDUP((uintptr_t)_edata, (uintptr_t)PAGESIZE);
#endif
```

Because the segment base is page-aligned, `roundup(_data + p_memsz)` equals dboot's
`base + roundup(p_memsz)` mapend exactly — so growth always begins on the first page dboot
did not map. Builds clean under `-Werror`. Persisted:
`src/aarch64-arm64-gate-patches/a6-vm-kbm-edata-align.patch` (+ `a6-vm-combined.patch` for the full A6 diff).

## Validation (console evidence, QEMU)

- **FDT (GICv3, `run-gicv3-usernet.sh`):** fresh unix entry `0xfe05e000` →
  **no `overlapping kbm_map`** → `gicthree0`/`gicv3_its0`/`arm_gtmr0`/`ecam0` attach →
  `root on armpool/ROOT/braich fstype zfs` → SMF `[ ... starting ]` milestones → `Hostname: braich`.
- **Pristine baseline (unchanged unix):** still boots to the same shell — **no regression**.
- **ACPI (EDK2 UEFI, `run-acpi.sh`):** dboot `synthesised FDT from ACPI (2 cpus, ...)` → entry `0xfe05e000` →
  **no `overlapping kbm_map`** → past `synthetic_bootaux` → into `prom_emul` device enumeration.

### Two ACPI-only issues surfaced *after* the kbm fix (both bounded)

1. **`krtld: failed to open '/platform/ARMH,sbbr/kernel/aarch64/unix'`** (then NULL data-abort).
   Cause: `kobj_init`→`synthetic_bootaux(whoami)` re-reads unix by its cmdline path from the
   boot_archive ramdisk to synthesise phdrs; the archive only contained `/platform/armv8/.../unix`,
   not the `ARMH,sbbr` platform path. **Worked around for the test** by staging unix at
   `/platform/ARMH,sbbr/kernel/aarch64/unix` inside the boot_archive. A proper fix is either
   (a) build/ship the archive with the `ARMH,sbbr` unix path, or (b) have krtld fall back to the
   canonical `armv8` path when the platform-specific path is absent.

2. **EXACT NEXT ACPI BLOCKER:** `panic: assertion failed: prop != NULL, prom_emul_fdt.c:63`
   (`get_phandle()` `VERIFY3P(prop != NULL)`). The synthesised FDT nodes lack a `phandle`
   property that `prom_emul` requires when walking the tree. **Fix is a localised follow-up in
   `dboot_synth_fdt.c`:** emit a `phandle` (and matching `linux,phandle`) property on every node
   prom_emul enumerates (root/cpus/memory/timer/intc/its/serial/pcie), not just the GIC.
   Not attempted here (separate scope, past tool budget).

## Test-harness note (for the next agent)

The boot_archive is a **gzip'd `cpio -H odc` (magic `070707`)** image; its `.hash` file is the
**SHA1 of the uncompressed cpio**. Repacking with illumos `cpio -oc` yields **newc (`070701`)**,
which krtld cannot read → `krtld could neither locate nor resolve symbols`. Always use `cpio -H odc`
and rewrite the `.hash` (`openssl sha1 <uncompressed.img>`). dboot-loaded unix (ZFS path) **and**
the archive unix must be the **same** binary or `synthetic_bootaux`'s phdrs won't match dboot's map.

Staging recipe (node):
```
lofiadm -la illumos-disk.img; zpool import -d /dev/dsk -R /a armpool -f
mount -F zfs armpool/ROOT/braich /a/root
cp <proto>/platform/armv8/kernel/aarch64/unix /a/root/platform/{armv8,ARMH,sbbr}/kernel/aarch64/unix
# archive: extract, replace unix+genunix, `find . | cpio -H odc | gzip -9`, write sha1(uncompressed) to .hash
umount /a/root; zpool export armpool; lofiadm -d /dev/dsk/c2t1d0p0
# then run-gicv3-usernet.sh (FDT) or run-acpi.sh (ACPI)
```
Original pristine archive recoverable from `/tmp/ba.img` (sha1 `761319243604b825dc38ef6fc87077ede21890c1`).

## Files

- **Fix:** `usr/src/uts/common/krtld/kobj.c` (`attr_val`, aarch64) — persisted to
  `src/aarch64-arm64-gate-patches/a6-vm-kbm-edata-align.patch`.
- Node tree clean of debug instrumentation (verified). A6-ACPI changes untouched.
- Progress log on node: `/tmp/a6-vm-progress.txt`.
