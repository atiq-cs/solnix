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

## UPDATE (2026-07-29): grounded R-P16 timeline from n-hys analysis
Full analysis: artifacts/hayashin-priorart/analysis/n-hys-adoption-analysis.md.
Corrected, HONEST estimate (supersedes earlier optimism):
- **Console + storage-boot on Jupiter2/K1 ≈ 4–5 weeks** of focused work.
- **+ networking ≈ 10–11 weeks.**
- Board arrives ~1 week: near-term realistic = early serial-console bring-up
  (U-Boot/OpenSBI handoff + real DTB + CMO + poll-console), NOT a usable system
  day-1. A storage-booting system is ~a month out; networked ~2.5 months.
Key correction: K1 is T-Head X60 — needs **cache-maintenance ops (CMO)** for
non-coherent DMA; `asm/t-head.h` is the #1 adopt (blocks ALL K1 DMA: MMC+eth).
Adopt from n-hys (CDDL): krtld R_RISCV_*, of_utils/promif FDT, copyin/out, FPU
ctxop, sendsig, locks; UART asy_nsuart (adopt-mostly); EMAC as NIC template
(K1=dwmac/stmmac, rewrite reg layer). KEEP ours: AIA (n-hys=100% PLIC), ctx-switch,
sdhci (closer to K1 dwcmshc-sdhci than their Allwinner SMHC). RVV1.0 = still net-new
(n-hys float-only); their float ctxop is the structure RVV extends.

## EC2 AMI cold-boot: the ena data-path blocker (root-caused, honest)
The desktop AMI fails to network on a clean cold launch. Root-caused (all verified on live cold instances):
- FIXED: ipfilter's default-deny ruleset DROPPED the IMDSv2 token PUT response (curl code 000 with ipf on;
  code 200 after a `pass in ... from 169.254.169.254` rule). The shim + ipf.conf now pass IMDS.
- ARCHITECTURALLY IMPOSSIBLE (the key finding): static-IP-from-IMDS cannot bootstrap. EC2 IMDS at
  169.254.169.254 only answers packets sourced from the instance's REAL VPC private IP -- a self-assigned
  link-local is rejected (verified: curl --interface <link-local> -> code 000; from the real DHCP IP ->
  code 200). To ask IMDS for the IP you must ALREADY have the IP -- genuine chicken-and-egg. The
  static-from-IMDS approach is impossible; static-from-DHCP-OFFER is the only in-OS static path.
- THE REAL BLOCKER = the ena DRIVER, not the shim: on failing boots dhcpagent gets NO DHCP OFFER at all
  (dhcpinfo empty, console "Hostname: unknown", IPv4LL 169.254.0.1) -- the ena data path is dead, not just
  the DHCP config. No in-OS action recovers a wedged agent (delete/create-addr, refresh, restart
  network/physical all fail); fresh-boot DHCP is a high-variance dice-roll (batches of 0/3, 4/4). Reboots
  don't reliably help because the ena path stays dead. The deterministic fix belongs in the ena driver
  (the illumos ena data-path / interrupt / reset handling on cold boot), NOT the metadata shim.
- The shim (scripts/metadata-shim.sh) does what IS fixable: single-addrobj (collapse the dual-DHCP
  conflict), the ipf IMDS pass rule, wait ~100s for DHCP then set the deterministic default route
  (gw = subnet base+1), recover the assigned IP statically from the DHCP OFFER via dhcpinfo, bounded reboot
  (cap 4) only if there's no OFFER.
- AMIs (from the failing ami-000a59cf344644604): v4 ami-095543f0de750dc33 (static-from-OFFER + bounded
  reboot), v3 ami-0870478cf2ea34604, v2 ami-03081d83a7d0bd410, v1 ami-0d91ba781fc5e637f.
=> HONEST STATE: the AMI is not reliably cold-launchable because of the ena driver's cold-boot data-path
unreliability -- a DRIVER bug, not shim-fixable + not further-iterable at the AMI layer. The VIEWABLE-desktop
demo runs on a BUILD NODE (reachable), which is the usable path today. Next: the illumos ena driver cold-boot
data-path fix (crib the FreeBSD if_ena reset/interrupt bring-up) -- a kernel-driver task, separate from the
image work. docs/AMI-ENA-COLDBOOT-FINDINGS.md has the full analysis.
