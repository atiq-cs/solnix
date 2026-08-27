# Phase A6-hw — real-Graviton leg: ACPI _CRS-derived PCIe ranges, drop virtio-mmio on hw, NVMe-over-PCIe, real c6g.metal boot

Build node i-0d24c0ec7a9a0e109 (18.216.236.141, m5.4xlarge) left **running**.
No git commit (orchestrator commits). No SG/0.0.0.0/0 changes.

## TL;DR

| Item | Result |
|---|---|
| **_CRS/MCFG real-ecam fix** | **Done + validated.** `dboot_synth_fdt.c` now parses the PCIe host-bridge `_CRS` straight out of the DSDT AML (via the FADT->DSDT pointer) and emits the *real* `ranges` (MEM32/IO/MEM64) instead of the QEMU-virt constants. MCFG already gave the ECAM base; the `_CRS` gives the outbound windows the pcierc `ranges` needs. |
| **Drop virtio-mmio on hw** | **Done.** virtio-mmio slots are now gated on a QEMU-virt OEM-ID check (`BOCHS`/`BXPC`/`QEMU`). Real Graviton (OEM `AMAZON`) emits **no** virtio-mmio; its boot disk is NVMe-over-PCIe enumerated through the pcie node. QEMU still gets its 32 slots (no regression). |
| **QEMU virtio-ACPI regression** | **PASS.** Same synth path still reaches `root on armpool/ROOT/braich` -> SMF -> `Hostname: braich`, zero panics. Diagnostic line now reports `qemu virtio-mmio, 3 _CRS wins`. |
| **QEMU NVMe-over-PCIe (cheap pre-metal)** | **The critical proof.** With an NVMe disk instead of virtio-blk: `ecam0 is /pcie@4010000000` (ranges from `_CRS`), the illumos EFI loader booted **from NVMe** (`Load Device .../NVMe(...)` -> `Trying ZFS` -> `currdev zfs:armpool/ROOT/braich`), kernel loaded `/platform/ARMH,sbbr/.../unix`, **`nvme0` attached (NVMe spec 1.4)**. Then a panic in `nvme_identify` (`invalid NS/format`) — a QEMU emulated-NVMe Identify quirk, **not** the synth/ranges. Proves NVMe-over-PCIe enumerates through the `_CRS`-derived pcie ranges. |
| **REAL c6g.metal boot** | **Real Graviton silicon reached.** c6g.metal `i-0bd9cbbfa5604da6b`, custom arm64/UEFI AMI from the illumos disk image. Console: **`Tianocore/EDK2 firmware version RELEASE 4.19.9`** (real Graviton UEFI), **`illumos/arm64 EFI loader, Revision 1.1`** ran, **Load Device is the real NVMe-over-PCIe EBS device** (`PcieRoot(0x0)/Pci(0x2,0x0)/.../NVMe(0x1,...)`), `Trying ZFS pool`. **Stall:** the loader's ZFS reader — `ZFS: i/o error - all block copies unavailable` / `can't read object set for dataset 54` / `can't open root filesystem`. Instance **terminated** promptly. |
| **How far on real silicon** | Real Graviton firmware -> **illumos EFI loader running** -> **real NVMe device read** (ESP loaded, ZFS labels/config read: it found dataset 54) -> **stall at the loader reading the ZFS object set** off the real NVMe. The **kernel did not run** on metal (loader could not hand off), so the synth-FDT `_CRS` fix itself is proven only in QEMU (loader-from-NVMe + kernel nvme attach), not yet on bare silicon. |

## 1. The fix (dboot_synth_fdt.c)

Three additions, all self-contained in the dboot synth file (no new dboot deps):

1. **`synth_scan_crs()`** — the DSDT is *not* in the XSDT, so it is reached via
   the FADT (`XDsdt`, else `Dsdt`). The PCIe root-bridge `_CRS` resource template
   is a fixed run of ACPI *large* address-space descriptors: it starts with a
   `WordAddressSpace` (0x88) of ResourceType `BusNumber` (2), followed by the
   memory/IO **producer** windows (`DWordAddressSpace` 0x87 / `QWordAddressSpace`
   0x8A). We locate the bus-number producer, then read each following descriptor's
   `(gran,min,max,translation,length)` fields directly from the AML byte stream —
   **no AML interpreter**. child = `min`, parent = `min + translation`, size =
   `length`. Producer is `general-flags bit0 == 0` (bit0 set = Consumer).
2. **`synth_is_qemu_virt()`** — reads the FADT (else MADT) `OemId`; QEMU/EDK2 stamp
   `BOCHS`/`BXPC`, real Nitro/Graviton stamps `AMAZON`. Used solely to gate the
   synthesised virtio-mmio block.
3. **pcie `ranges`** — emit the `_CRS`-parsed windows when found; fall back to the
   QEMU-virt fixed map only if the DSDT `_CRS` yields nothing (belt-and-suspenders
   for a QEMU-EDK2 with no parseable `_CRS`).

The virtio-mmio 32-slot block is now `if (qemu) { ... }`.

### Ground truth (c6g.medium, us-east-2, real Nitro ACPI)

```
OEM = AMAZON/AMZN ; MCFG ECAM base = 0x20000000, bus 0x00-0xff
DSDT PCI root-bridge _CRS producer windows:
  MEM32  child/parent 0x80000000     size 0x80000000     (2 GiB)   <- ena/nvme BARs
  IO     child 0x0  parent 0x1fff0000 size 0x10000
  MEM64  child/parent 0x400000000000 size 0x8000000000   (512 GiB)
NVMe 00:04.0 [1d0f:8061], ENA 00:05.0 [1d0f:ec20], serial 00:01.0
```
(vs the old QEMU-virt hardcode: MEM32 0x10000000, MEM64 0x8000000000, IO parent 0x3eff0000 — all wrong for Graviton.)

The parser was verified against this real DSDT by a Python mirror
(`a6hw-test_crs_parse.py` + `a6hw-graviton-DSDT.bin`): it extracts exactly those
three windows. On QEMU-EDK2 the same code found QEMU's own 3 `_CRS` windows and the
boot still reached multi-user — so the `_CRS`-derived ranges are correct on both.

## 2. QEMU validation (console evidence, build node)

- **virtio regression** (`run-acpi.sh`, EDK2/ACPI, virtio-blk): `dboot: synthesised
  FDT from ACPI (... 1 pcie rc, qemu virtio-mmio, 3 _CRS wins)` ->
  `/virtio_mmio@a003c00/vioblk.../blkdev@0,0 online` -> `root on armpool/ROOT/braich`
  -> `Hostname: braich`. Log: `/tmp/a6-hw-acpi-regr.log` (0 panics).
- **NVMe path** (`run-acpi-nvme.sh`, EDK2/ACPI, `-device nvme` + `nvme-ns`):
  `ecam0 is /pcie@4010000000` -> EFI loader `Load Device .../NVMe(...)` ->
  `Trying ZFS pool` / `currdev zfs:armpool/ROOT/braich` ->
  `Loading /platform/ARMH,sbbr/kernel/aarch64/unix` -> `nvme0: NVMe spec version 1.4`
  (**attached**) -> `panic: nvme0: programming error: invalid NS/format` in
  `nvme_identify`. Log: `/tmp/a6-hw-nvme.log`.
  The panic is QEMU's emulated-NVMe Identify (namespace format) tripping the illumos
  aarch64 nvme driver — orthogonal to the `_CRS`/ranges/attach path, which succeeded.

## 3. Real c6g.metal boot (console evidence)

AMI: `ami-027cf7199f7172a60` (arm64, `boot-mode uefi`, ENA), built from
`illumos-disk.img` via EBS volume `vol-04a319171529ff821` -> snapshot
`snap-02386571042c2d376`. Route (a): bare-metal boot the illumos EFI loader on the
real Graviton firmware. Console (`a6hw-metal-console-boot1.txt`, ANSI-stripped):

```
Tianocore/EDK2 firmware version RELEASE 4.19.9        <- REAL Graviton UEFI
illumos/arm64 EFI loader, Revision 1.1
  Load Device: PcieRoot(0x0)/Pci(0x2,0x0)/Pci(0x0,0x0)/Pci(0x1,0x0)/Pci(0x0,0x0)/
               NVMe(0x1,...)/HD(1,GPT,...)          <- REAL NVMe-over-PCIe
Trying ZFS pool
ZFS: i/o error - all block copies unavailable         <- STALL
ZFS: can't read object set for dataset 54
ZFS: can't open root filesystem
... Failed to find bootable partition
```

The illumos EFI loader **runs on real Graviton silicon** and **reads the real
NVMe-over-PCIe device** (it loaded `loader64.efi` from the ESP and read the ZFS pool
config far enough to name `dataset 54`), then the loader's ZFS reader fails reading
the pool **object set** off the real NVMe (`all block copies unavailable`).

### Exact stall / diagnosis

The same `illumos-disk.img` boots cleanly under QEMU-EDK2 (loader -> kernel ->
multi-user), so the pool/labels are structurally sound; on real Graviton EDK2 the
loader reads the ESP and the ZFS *config* (dataset 54) but fails the ZFS *object set*
data read. This is a **loader-stage ZFS/EFI-block-read issue on real NVMe** (or a
disk-image->EBS conversion artifact), **not** the synth-FDT `_CRS` change — the
kernel never ran on metal. Confirmed not a sector-size mismatch (EBS NVMe is 512-byte
logical, matching the image). Fixing the illumos aarch64 EFI loader's ZFS read on real
NVMe is a **separate loader-side task** from the synth-FDT/ACPI work; it gates reaching
the kernel (and therefore testing the `_CRS` fix) on bare silicon.

## Remaining for a full bare-Graviton kernel boot (honest scope)

1. **Loader ZFS-on-real-NVMe read** (blocks the kernel handoff on metal): the loader
   reads the ESP + pool config but not the object set off real NVMe. Options: debug the
   aarch64 EFI loader's EFI-block-read path for large ZFS offsets on Nitro NVMe, or
   stage the kernel + boot_archive on the FAT ESP and boot via the loader's non-ZFS path
   to sidestep the loader ZFS reader entirely. Once the loader hands off, the kernel's
   `_CRS`-driven NVMe/ENA attach (already proven under QEMU) gets exercised on silicon.
2. **ENA at boot on silicon**: not yet observed (kernel never ran on metal). Under QEMU
   the pcie node + ITS MSI path is proven; ena binds `pciex1d0f,ec20` (matches the real
   `1d0f:ec20`). Confirm after (1).

## Files (persisted; not committed)

- **Fix (full file):** `src/aarch64-arm64-gate-patches/dboot_synth_fdt.c`
  (also identical on the node at
  `usr/src/uts/armv8/dboot/dboot_synth_fdt.c`).
- **Diff:** `src/aarch64-arm64-gate-patches/a6-hw-crs-synth-fdt.patch`.
- **Real Graviton console:** `src/aarch64-arm64-gate-patches/a6hw-metal-console-boot1.txt`.
- **Ground truth + parser check:** `a6hw-graviton-DSDT.bin`, `a6hw-test_crs_parse.py`.
- Node harness: `qemu-setup/run-acpi-nvme.sh` (NVMe QEMU boot);
  logs `/tmp/a6-hw-acpi-regr.log`, `/tmp/a6-hw-nvme.log`; progress `/tmp/a6-hw-progress.txt`.

## AWS resources

- c6g.metal `i-0bd9cbbfa5604da6b`: **terminated**.
- c6g.medium `i-0f9c12c4d00779ad9` (ground truth): terminated at wrap-up.
- Volume/snapshot/AMI (`vol-04a319171529ff821` / `snap-02386571042c2d376` /
  `ami-027cf7199f7172a60`): cleaned up at wrap-up.
- Build node `i-0d24c0ec7a9a0e109`: **left running**.
- No SG / 0.0.0.0/0 changes.
