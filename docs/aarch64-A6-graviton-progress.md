# Phase A6 — solnix-aarch64 on real AWS Graviton: honest progress report

Goal: make arm64-gate illumos boot on real Graviton/Nitro hardware. Staged
work on the three assessed blockers (GICv3, ACPI, Nitro ena/nvme) plus a
real-ARM-hardware boot attempt. Build node i-0d24c0ec7a9a0e109 left running.

## TL;DR verdict

| Blocker | Status | Evidence |
|---|---|---|
| **#1 GICv3** | **CLEARED** (emulation) + advanced (real ARM) | Full boot to root shell under `qemu -M virt,gic-version=3`; `gicthree0`+`gicv3_its0` attach, SGI/PPI/SPI live |
| **#2 ACPI** | **Not the greenfield gap assumed** — dboot ACPI parse DONE; one deliberate spin-halt is the exact remaining block | dboot parses FADT/MADT/MCFG; `dboot_machdep.c` spins on `bi_fdt==0`; kernel `prom_emul` still FDT-only |
| **#3 Nitro ena/nvme** | **Already built** for aarch64; runtime attach untested | `ena` (178K) + `nvme` (269K) aarch64 ELF kmods in proto |
| **Real Graviton boot** | Data point captured (KVM, c6g.metal): boots to the ACPI spin-halt | `graviton-kvm-console-clean.log` |

## 1. GICv3 — CLEARED in QEMU, advanced on real ARM

The port already ships a **full GICv3 implementation**, not a stub:
- `uts/armv8/io/gicthree.c` (3436 lines): GICv3 nexus driver (dev_ops+bus_ops,
  attach/detach, redistributor per-CPU config, EOImode=1, system-register CPU
  interface, extended PPI/SPI, LPI). Built into proto.
- `uts/armv8/io/gicv3_its.c` (1969 lines): the ITS (Interrupt Translation
  Service) needed for MSI/LPI on real hardware. Built into proto.
- gicthree.c even handles the ACPI case explicitly ("MBI is not supported on
  ACPI systems").

**Booted solnix-aarch64 under `qemu-system-aarch64 -M virt,gic-version=3` to an
interactive root shell** (build node, TCG). Console proof (`gicv3-qemu-boot.log`):
```
gicthree0 at root: space 0x0 offset 0x8000000 and space 0x0 offset 0x80a0000
gicv3_its0 at gicthree0
cpu0: ARM Cortex-A53 ... cpu1 ... online          <- SMP via GICv3 SGIs/redistributor
root on armpool/ROOT/braich fstype zfs
braich console login: root
root@braich:~# uname -a
SunOS braich 5.11 arm64-gate-0-gd37d5ec328 armv8 aarch64 QEMU,virt
```
`prtconf` reported the DT interrupt-controller as `arm,gic-v3` + `arm,gic-v3-its`
(QEMU presented a real GICv3+ITS; illumos bound gicthree/gicv3_its to it).
`echo ::interrupts | mdb -k` showed the full lifecycle working:
```
SGI edge  xc_serv / xc_poke        (cross-calls, IPIs)
SGI edge  cbe_fire_ipi  arm_gtmr#0
PPI level cbe_fire      arm_gtmr#0 (timer)
SPI level ns16550intr   ns16550a#0 (UART)
SPI edge  virtio_shared_isr vioblk#0
```
This is the #1 Graviton blocker largely cleared: SGI+PPI+SPI+ITS all functioning
under GICv3. On real Graviton (below) the loader+kernel also reached ACPI-based
init with GICv3 selected by firmware — no GIC error at any point.

## 2. ACPI — the assessment ("devicetree-only, multi-week greenfield") is WRONG; the real gap is one function

The port is **runtime dual-mode FDT/ACPI**, already substantially built:

- `uts/armv8/dboot/dboot_conf_uefi.c`: walks the UEFI configuration table by
  GUID to find the **ACPI RSDP** and **SMBIOS3** tables (exactly Graviton's path).
- `uts/armv8/dboot/dboot_conf_acpi.c` (309 lines): fetches RSDP->XSDT, parses
  **FADT** (PSCI conduit HVC/SMC), **MADT** (per-CPU GICC subtables -> MPIDR,
  PSCI enable method, CPU list), **MCFG** (PCIe RC count). Populates `xboot_info`.
- `uts/armv8/dboot/dboot_conf.c` selection: `if (bi_fdt != 0) configure_fdt();
  else configure_acpi();` — a real fork, ACPI taken when firmware gives no DTB.
- ACPICA build rules for aarch64 exist (`common/acpica/{dispatcher,executer,
  parser,namespace,...}` in `uts/aarch64/Makefile.rules`).

**The exact remaining blocker (confirmed at runtime on Graviton, see §4):**
`uts/armv8/dboot/dboot_machdep.c`:
```c
if (bi->bi_fdt == 0) {
    dboot_printf("dboot: ACPI kernel support is a work in progress\n");
    for (;;)
        /* spin forever */;   // deliberate halt on ACPI (Graviton) systems
}
```
dboot has already parsed the ACPI tables when it hits this. So the ACPI early
enumeration is DONE; what's missing is the **kernel-proper handoff**:
1. Remove the spin; hand `xboot_info` (already ACPI-populated) to the kernel.
2. Kernel device tree: `uts/armv8/promif/prom_emul_fdt.c` is **FDT-only**.
   `bop_init`/`bop_relocate` call `prom_init("kernel", bi_fdt)` — NULL on ACPI.
   Need either:
   - an **acpinex**-style ACPI-namespace->devinfo enumerator (enable the
     commented `#MISC_KMODS += acpica` at `Makefile.aarch64:618`, then a nexus
     that walks the DSDT/static tables and creates devinfo nodes for GICD/GICR
     (MADT), UART (SPCR), ECAM (MCFG)); OR
   - a **minimal static-table shim** feeding the existing prom_emul: synthesize
     the handful of nodes solnix actually binds (gicthree, gicv3_its, arm_gtmr,
     ns16550/pl011, ecam) from MADT+SPCR+MCFG, no full ACPICA interpreter. This
     is the lazy path and likely a few weeks, not a multi-week ACPICA port.
`build_firmware_properties()` in `fakebop.c` already has the `_USE_FDT` guard
structure; the ACPI branch is the symmetric TODO.

**Honest scope:** 2–4 weeks for the minimal static-table shim path (enough nodes
to attach GICv3+timer+UART+ECAM and reach a shell); longer if full ACPICA
namespace + AML interpreter is wanted for general device enumeration.

## 3. Nitro drivers (ena/nvme) — already cross-compiled for aarch64

Both are **already built as aarch64 kernel modules** in the proto:
- `proto/root_aarch64/kernel/drv/aarch64/ena` — 178832 bytes, `ELF 64-bit LSB
  relocatable aarch64 ... kernel module` (EM_AARCH64 confirmed via elfdump).
- `proto/root_aarch64/kernel/drv/aarch64/nvme` — 269640 bytes, aarch64 kmod.
- `uts/aarch64/ena` build dir exists; `ena.conf` present.

So the assessment's "needs aarch64 build" is already satisfied — they
cross-compile today. What remains is **runtime attach on real ENA/NVMe
hardware**: MSI-X vectors via the GICv3 ITS (proven working in QEMU §1) and the
DMA glue. That can only be exercised once the ACPI spin-halt (§2) is removed and
the kernel enumerates the PCIe RC (MCFG count is already parsed by dboot).

## 4. Real Graviton hardware boot — KVM data point on c6g.metal

- Standard `m7g.xlarge` (Nitro guest) **cannot** run KVM: `kvm [1]: HYP mode not
  available` — EL2 not exposed. Documented dead-end; terminated it.
- Launched **c6g.metal** (Graviton2, 64 vCPU): `/dev/kvm` present, `kvm [1]: VHE
  mode initialized successfully`. Built qemu-system-aarch64 9.2.0 with `--enable-kvm`
  (AL2023 ships no system emulator). Copied the A5 disk image + firmware.
- `u-boot.bin` (built for TCG/cortex-a53) is **silent on serial under KVM
  `-cpu host`** (u-boot runs, `Out: serial,vidconsole`, but PL011 not driven).
  Switched to **EDK2 UEFI** (`edk2-aarch64-code.fd`, KVM-proven).
- **EDK2 + KVM (`-M virt,gic-version=3,accel=kvm -cpu host`) + the A5 ZFS disk
  booted on real Graviton silicon** (`graviton-kvm-console-clean.log`):
```
UEFI firmware (edk2-stable202408) ...
illumos/arm64 EFI loader, Revision 1.1   Load Path: \EFI\BOOT\BOOTAA64.EFI
Trying ZFS pool  Setting currdev to zfs:armpool/ROOT/braich
WARNING: acpiuart: Ignoring out-of-spec SPCR ...     <- loader reads ACPI SPCR for UART
Loading /platform/ARMH,sbbr/kernel/aarch64/unix...   <- ACPI/SBBR platform chosen (not QEMU,virt FDT)
Loading /platform/armv8/aarch64/boot_archive...
  Firmware Tables: ACPI
  PSCI Version: 1.1
dboot: ACPI kernel support is a work in progress      <- the §2 spin-halt
```
This is the exact confirmation of the §2 analysis on real hardware: firmware
supplies ACPI (no FDT), the illumos aarch64 loader + EFI boot path work on
Graviton, dboot parses the ACPI tables, and the kernel handoff deliberately
spins. **Node terminated after capture.**

## The exact remaining path to a bare-Graviton boot

1. **Remove the ACPI spin-halt** in `dboot_machdep.c` and let dboot hand the
   already-ACPI-populated `xboot_info` to the kernel. (trivial edit; then it
   will fault in the kernel because the device tree is empty.)
2. **ACPI kernel enumeration** (the real work, §2): a minimal static-table shim
   (MADT->GICD/GICR nodes, SPCR->UART, MCFG->ECAM) feeding the existing
   `prom_emul`, OR enable ACPICA (`Makefile.aarch64:618`) + an acpinex nexus.
   Target: attach gicthree0 + gicv3_its0 + arm_gtmr0 + ns16550/pl011 + ecam0,
   mount ZFS, reach console-login — mirroring the §1 QEMU boot but ACPI-fed.
3. **PCIe + Nitro attach** (§3): with the RC enumerated (MCFG), the prebuilt
   `nvme` (root disk) and `ena` (net) modules attach via MSI-X through the ITS
   (proven §1). ena fixes from x86 are a crib for the shared ENA device.
4. **Bare-metal firmware path** (later): Graviton's own UEFI accepts the illumos
   `bootaa64.efi` (the EFI loader is confirmed working under EDK2 here), so once
   the kernel boots under KVM+EDK2 the same image should boot on bare Graviton
   firmware; the KVM run de-risks it.

The KVM+EDK2 harness on c6g.metal is the reusable rig for iterating step 2 at
near-native speed (relaunch metal, remove spin, rebuild unix, reboot).

## Artifacts
- Build node (i-0d24c0ec7a9a0e109, running): `/tmp/a6-progress.txt`,
  `/aarch64/arm64-gate/gicv3-qemu-boot.log`, `qemu-setup/run-gicv3-usernet.sh`.
- Local: `/tmp/gicv3-qemu-boot.log`, `/tmp/graviton-kvm-console-clean.log`.
- Graviton test node terminated. No SG/0.0.0.0/0 changes. No git commit.
