# solnix hardware readiness — honest status (2026-07-29)

Answering the maintainer's four questions without hype. Where something is
QEMU-proven vs silicon-proven vs not-done, it says so.

## 1. RISC-V / Milk-V Jupiter2 (SpaceMiT K1, 8× RVA22 + RVV1.0) — arriving ~1 week

**"software-complete (flashable K1 image)" means:** the generic RISC-V kernel +
userland is a real OS (SMP, preemption, VM/COW, libc, signals, pipes, multi-user
login, persistent on-disk FS, AIA/APLIC+IMSIC model, FDT device discovery, ELF/
syscalls) — ALL verified against boot logs, but **under QEMU `virt`**. The K1-
specific pieces (board DTB, dw-apb-uart driver, sdhci probe, MMIO maps, the
`solnix-k1.img` boot-chain layout) were written and proven against MODELS, not
real K1 silicon.

**Will it use ALL Jupiter2 hardware day-1? NO.** Honest gap on real silicon:
- **DDR/PMIC/clock init**: from SpaceMiT vendor U-Boot + OpenSBI blobs (we consume,
  don't write). Must be assembled + tested on the board.
- **RVV1.0 vector state** in ctx-switch: NOT done. Design doc calls it "the single
  biggest K1-specific kernel item."
- **dw-apb-uart at live shift=2 MMIO / real sdhci-eMMC block driver**: probe+model
  only, not silicon-validated.
- **ethernet, USB, PCIe, GPU/display, thermal, RVV**: essentially no drivers.

**Realistic ~1-week outcome:** boot to **serial console + single/multi-user off
SD/eMMC** = FIRST illumos on real RISC-V silicon (huge milestone). "All hardware"
(net/USB/PCIe/display/RVV) is months of driver work per the design doc's 6–12+ mo
estimate. Plan: console-bootable first, then drivers one peripheral at a time.
**R-P16 (physical bring-up) starts when the board arrives** — needs: SpaceMiT
U-Boot+OpenSBI for K1, real board DTB, `-DK1_SILICON` recompile, then iterate on
console → storage → net.

## 2. Install media — CDROM ISOs + USB images, ALL platforms, "The Solnix OS"

**Status: NOT built yet** (Phase 2.5 backlog T2.13 ISO + T2.7 installer). This is
required work, not done. Per platform:
- **x86_64**: most straightforward — illumos has the DC (distro constructor) +
  loader; a hybrid ISO/USB (boot via loader → ramdisk → installer → ZFS root) is
  the standard illumos path. Highest priority, most mature tooling.
- **aarch64**: needs the EFI/U-Boot boot path + our aarch64 kernel + a UEFI-
  bootable ISO/USB. Kernel boots (A8 qualified); media not built.
- **sparcv9**: OpenBoot/OBP `boot net`/`boot cdrom` path (Sun VTOC + `bootlst`);
  boots to SMF on sun4u. Media not built.
- **riscv64**: U-Boot `booti` from SD/eMMC/USB; ISO is less relevant (RISC-V boards
  boot from SD/eMMC/NVMe, not CD). USB/SD image is the deliverable.

Deliverable: an installer + media build (distro-constructor-style) producing, per
platform, a bootable ISO (where meaningful) + a `dd`-able USB/SD image that installs
"The Solnix Operating System" to a ZFS root. This is a dedicated Phase-2.5 track.

## 3. aarch64 hardware box (evaluating: UpTimeLab compute blades)

Our aarch64 kernel is qualified under QEMU (A8: boots multi-user + ssh) via Rich
Lowe's arm64-gate. For REAL aarch64 server hardware, the kernel needs the same
class of SoC bring-up as RISC-V: **GICv3** (arm64-gate/IPD-24 has GICv2, GICv3 =
"No" in the design matrix), **ACPI or SBBR/EBBR** firmware, and SoC drivers.
- **UpTimeLab blades** (Ampere/Neoverse-class, typically): server-grade, GICv3 +
  ACPI/SBBR — which is exactly the firmware model illumos aarch64 does NOT yet
  fully support (it does EBBR/IR FDT, not ACPI). So a Neoverse/GICv3/ACPI blade
  would need the GICv3 + ACPI bring-up first (the CH-1 ARM-server kernel port in
  the cloud-hardware spec, GICv3/ACPI/SBBR, ~est. months).
- **Recommendation**: for fastest day-1, prefer an aarch64 board that boots via
  **U-Boot/EBBR + FDT + GICv2/GICv3-with-DT** (e.g. many Rockchip/RK3588,
  SolidRun HoneyComb/LX2160 which is FDT+GICv3, or a Raspberry Pi 4/5 for a cheap
  bring-up target) over an ACPI-only server blade — matches illumos aarch64's
  current FDT firmware assumptions. If the UpTimeLab blades are ACPI/SBBR-only,
  they're a longer bring-up; if they can boot DT/EBBR, much closer to day-1.
- Need the blade's exact SoC + firmware model (ACPI vs DT, GIC version) to judge.
  Happy to assess a specific SKU.

## 4. Prior art: hayashin/illumos-gate RISC-V (Bitbucket)

We are NOT the first to attempt illumos-on-RISC-V. Our port was written FRESH
(NetBSD sys/arch/riscv structure + arm64-gate precedent + RISC-V/SBI specs),
WITHOUT consulting hayashin's tree — so there's likely reusable work there,
especially real-hardware lessons (their effort targeted SiFive HiFive/Unmatched).
**BLOCKER**: bitbucket.org/hayashin/illumos-gate is auth-gated — the dev-box can't
anonymously clone the repo or wiki (Auth failed). To harvest it we need EITHER
maintainer Bitbucket credentials/access, OR a maintainer-provided clone/tarball.
**Value if obtained**: their `uts/riscv` MD layer (locore/trap/mlsetup), syscall/
ABI glue, DT/driver specifics, and any HiFive/Unmatched real-silicon fixes could
de-risk the Jupiter2 bring-up. HIGH PRIORITY to compare before R-P16 hardware work.
ACTION NEEDED FROM MAINTAINER: grant repo access or drop a clone at a path/URL the
dev-box can read.
