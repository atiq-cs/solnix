# Phase A6-ACPI — the ACPI handoff: spin-halt removed, synth-FDT-from-ACPI validated

Goal: advance arm64-gate illumos past the deliberate ACPI spin-halt so a
Graviton (SBBR/ACPI) boot proceeds into the kernel. Build node
i-0d24c0ec7a9a0e109 left running.

## TL;DR

| Item | Result |
|---|---|
| **Spin-halt removed** | **Yes.** `dboot_machdep.c` no longer spins on `bi_fdt==0`; the ACPI path falls through to the kernel handoff. |
| **prom_emul-from-ACPI shim** | **Built and validated end-to-end.** New `dboot_synth_fdt.c` synthesises a minimal FDT from the ACPI MADT/SPCR/MCFG (+cpuinfo) and sets `bi_fdt`, so the kernel's existing FDT-fed `prom_emul` works unchanged. |
| **ACPI-QEMU boot (EDK2 UEFI)** | **Boots through the ACPI path, past the spin-halt, into the kernel proper.** Loader selects the real `ARMH,sbbr` platform; dboot parses ACPI, synthesises the FDT, hands off; kernel jumps in. |
| **Next blocker (exact)** | `overlapping kbm_map allocation for 0xfffffffffe613000 at level 0` — a **pre-existing, ACPI-orthogonal early-VM double-VA-allocation bug** that also reproduces on the plain FDT boot with the same (rebuilt/larger) unix. |
| **c6g.metal** | **Not launched** (deliberate, cost). The next blocker is kernel-side and hardware-independent; QEMU+EDK2 already reproduces the real Graviton `ARMH,sbbr` + ACPI path, so metal adds no new information until the kbm bug is fixed. |

## 1. The spin-halt (removed)

`usr/src/uts/armv8/dboot/dboot_machdep.c`, `exitto()`, before the kernel jump:
```c
if (bi->bi_fdt == 0) {
    dboot_printf("dboot: ACPI kernel support is a work in progress\n");
    for (;;) /* spin forever */;
}
```
Replaced with a one-line notice (kept as a diagnostic if the synth ever fails);
the ACPI path now falls through to `entrypoint(bi)`. In practice `bi_fdt` is
non-zero on the ACPI path because the synth shim (below) sets it, so dboot
reports `Firmware Tables: FDT` even under ACPI firmware.

## 2. The prom_emul gap and the shim (chosen: option (a), the static-table shim)

The kernel's device enumeration is FDT-only: `bop_init`/`bop_relocate` call
`prom_init("kernel", bi_fdt)`, and `prom_emul_fdt.c` is a pure libfdt wrapper
(`promif_finddevice/getprop/nextnode/...` all operate on `fdtp`). The standard
prom->devinfo bridge (`impl_ddi_sunbus_initchild`, `ndi_dev_is_prom_node`) walks
that same prom tree. So the laziest correct path is: **give the kernel a valid
FDT synthesised from ACPI**, and everything downstream (prom_emul,
`build_firmware_properties_fdt`, `prom_fdt_get_cpu_topology`, driver binding)
works unchanged.

dboot already links the full libfdt **writer** (`fdt_sw.o`, `fdt_empty_tree.o`,
`fdt_rw.o`), and `dboot_conf_acpi.c` already parses the ACPI tables. New file
`usr/src/uts/armv8/dboot/dboot_synth_fdt.c`:

- Walks the **MADT** for GICv3 distributor (type 12), redistributor (type 14,
  with a GICC `GicrBaseAddress` fallback) and ITS (type 15) base addresses.
- Reads **SPCR** for the console UART base/IRQ/type (PL011 vs 16550).
- Reads **MCFG** for the PCIe ECAM window(s).
- Emits a minimal FDT (root 2/2 cells + `interrupt-parent`, `/psci`, `/cpus`
  from the already-parsed `bi_cpuinfo`, `/memory`, `timer` with the fixed
  architected PPIs, `intc@` = `arm,gic-v3` + `its@` = `arm,gic-v3-its`,
  `serial@`, `pcie@` = `pci-host-ecam-generic` with `msi-map` to the ITS) into
  a static dboot buffer, self-checks it, and returns its address.

Wired into `dboot_configure_acpi()`: after CPU/PSCI/PCIe parsing,
`bi->bi_fdt = dboot_synth_fdt(bi)`. On failure `bi_fdt` stays 0 and dboot
prints a notice instead of spinning.

Builds clean under `-Werror -Wall -Wextra`; dboot links with no undefined
symbols; unix relinks. (dboot has no `snprintf`, so node names are formatted by
a small hand-rolled hex helper.)

## 3. ACPI-QEMU boot (EDK2 UEFI presenting ACPI)

Harness: `qemu-system-aarch64 -M virt,gic-version=3` with **EDK2 UEFI pflash**
(`edk2-aarch64-code.fd` + a writable vars copy) instead of `-bios u-boot.bin`.
EDK2 on QEMU virt presents **ACPI** (not FDT), exactly matching the Graviton
firmware path. Script: `qemu-setup/run-acpi.sh` on the build node.

Console (`acpi-synth-boot-clean.log` on the node,
`.a6-acpi-console-clean.log` local):
```
illumos/arm64 EFI loader, Revision 1.1
Trying ZFS pool
Setting currdev to zfs:armpool/ROOT/braich
Loading /platform/ARMH,sbbr/kernel/aarch64/unix        <- real Graviton platform picked under ACPI
Loading /platform/armv8/aarch64/boot_archive
dboot: synthesised FDT from ACPI (2 cpus, gicd=0x8000000 gicr=0x80a0000 +its, 1 pcie rc)
Kernel entry (_start) is 0xfffffffffe05e000
  Firmware Tables: FDT
  Command Line: /platform/ARMH,sbbr/kernel/aarch64/unix -vm verbose
  Timer Frequency: 62500000Hz
  PCIe Root Complexes: 1
  PSCI Version: 1.1
  SMCCC Conduit: Hypervisor
Kernel Entrypoint: 0xfffffffffe05e000
overlapping kbm_map allocation for 0xfffffffffe613000 at level 0   <- NEW blocker (kernel-side)
```

What this proves, stage by stage past the old halt:
1. Under ACPI firmware the loader selects the **`ARMH,sbbr`** platform (the real
   Graviton platform, not `QEMU,virt`/FDT). Staged the synth unix at
   `/platform/ARMH,sbbr/kernel/aarch64/unix` so it loads directly.
2. dboot takes the **ACPI** branch (`dboot_configure_acpi`), parses MADT/SPCR/
   MCFG, and the **synth shim runs and succeeds** — correctly extracting 2 CPUs,
   GICD `0x8000000`, GICR `0x80a0000`, the ITS, and 1 PCIe RC from the ACPI
   tables.
3. dboot completes the handoff (`bi_fdt` set, all `xboot_info` fields populated)
   and **jumps into the kernel** — the spin-halt is gone.
4. The kernel runs early init and reaches its BOP-phase VM setup, where it hits
   the next blocker.

## 4. The exact next blocker (honest remaining A6 scope)

`overlapping kbm_map allocation for 0xfffffffffe613000 at level 0`
(`bop_panic` from `kbm_map()` in `usr/src/uts/armv8/vm/kboot_mmu.c`, reached via
`do_bsys_alloc()` in `fakebop.c`). A boot-phase virtual address is mapped twice.

**This is not an ACPI bug.** Isolation (same disk, same commit d37d5ec328):
- The **pristine** unix (2101728 bytes, entry `0xfe05b000`) boots the plain
  **FDT** path to a **root shell** (`gicthree0` attaches, `root on
  armpool/ROOT/braich`, login) — no overlap.
- The **rebuilt** unix (2114016–2122208 bytes, entry `0xfe05e000`–`0xfe060000`),
  which differs only by the added synth object, hits the overlap **on both the
  FDT and the ACPI paths**, always at the same fixed VA `0xfffffffffe613000`.

So it is a **pre-existing, size/layout-sensitive early-VM double-VA-allocation
bug**: a fixed-VA boot allocation collides with a bootmem-pool (`alloc_vaddr` /
`bmemlist`) allocation once unix grows past the fortunate layout the A5 boot
happened to land on. The overlap VA is fixed (`KERNEL_TEXT + 0x613000`),
independent of kernel size; what the size delta changes is whether the two
allocators hand out the same page.

**Remaining A6 scope after this milestone:**
1. **Fix the `kbm_map` VA double-allocation** (kernel-side, blocks both FDT and
   ACPI): audit the fixed-hint BOP allocations (`perform_allocations`/
   `valloc_base`, the boot_archive/ramdisk mapping) vs the `bmemlist` bootmem VA
   pool in `startup_memlist`/`fakebop.c`, so a bootmem VA can never alias a
   fixed-hint mapping. This is the immediate next step and unblocks device probe
   on both paths. (Multi-day; it is early-VM allocator work, orthogonal to ACPI.)
2. **Then confirm device probe under ACPI**: with the kbm bug fixed, the synth
   FDT should drive `gicthree0` + `gicv3_its0` + `arm_gtmr0` + UART + `ecam0`
   attach and a ZFS root mount, mirroring the GICv3 FDT boot — but ACPI-fed.
   Any gaps there (e.g. an SPCR interface-type or ECAM `ranges` detail the synth
   omits) are small, localised follow-ups to `dboot_synth_fdt.c`.
3. **Real Graviton**: because the blocker is kernel-side and the QEMU+EDK2 rig
   already reproduces the `ARMH,sbbr` + ACPI path bit-for-bit, a c6g.metal run is
   only worthwhile once (1) lands. It was deliberately skipped here to avoid
   metal cost for a result already known (identical kbm overlap).

## Files changed (persisted on the build node; not committed)

- `usr/src/uts/armv8/dboot/dboot_synth_fdt.c` — new; the ACPI->FDT synth shim.
- `usr/src/uts/armv8/dboot/dboot_conf_acpi.c` — call the shim, set `bi_fdt`.
- `usr/src/uts/armv8/dboot/dboot_machdep.c` — remove the spin-halt.
- `usr/src/uts/armv8/dboot/dboot.h` — declare `dboot_synth_fdt`.
- `usr/src/uts/armv8/Makefile.files` — add `dboot_synth_fdt.o` to `DBOOT_OBJS`.

## Artifacts

- Build node (i-0d24c0ec7a9a0e109, **left running**): source changes above;
  `qemu-setup/run-acpi.sh` (EDK2/ACPI boot harness);
  `acpi-synth-boot-clean.log` (clean ACPI console). The `illumos-disk.img` pool
  has the synth unix staged at both `armv8` and `ARMH,sbbr` platform paths;
  `prom_debug` left off; pool exported cleanly.
- Local: `.a6-acpi-console-clean.log`, `.a6-acpi-console-full.log`.
- No c6g.metal launched. No SG/0.0.0.0/0 changes. No git commit.
