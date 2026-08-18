# solnix riscv64 — Milk-V Jupiter (SpacemiT K1) driver-crib plan

Research + planning output for PS-MILKV-JUPITER. For each peripheral solnix
must drive on the physical Milk-V Jupiter (SpacemiT K1/M1, 8× X60 RV64GCVB +
RVV1.0, IMG PowerVR BXE-2-32), this names the specific NetBSD/FreeBSD source to
crib, the illumos KPI/shim it maps to, the K1-specific glue from the vendor DTS,
an effort estimate, and the priority order. No driver code is written here.

This is a **crib-doctrine** plan (same pattern as the ena NIC and the RISC-V MD
layer under `src/riscv/uts/`): reference-only BSD sources reimplemented in the
illumos ddi/kernel idiom against the OS-independent spec, not compiled or
shipped verbatim.

---

## 0. Ground truth: the authoritative K1 device map

The in-repo `src/riscv/uts/k1.dts` (and the compiled `k1_dtb.h`) is a **hand-
written subset from R-P14, predating the physical board, and it is WRONG on
several nodes.** The authoritative peripheral map is the SpacemiT vendor BSP
`arch/riscv/boot/dts/spacemit/k1-x.dtsi` (spacemit-com/linux-6.6, branch
`k1-bl-v2.2.y`) cross-checked against mainline Linux `v6.14` `k1.dtsi`. The
corrections that matter for driver work:

| Device | In-repo `k1.dts` (wrong/stale) | Real K1 (vendor `k1-x.dtsi`) | Consequence |
|---|---|---|---|
| Interrupt controller | APLIC @0xe0000000 + IMSIC @0xe0008000 (AIA) | **PLIC** `riscv,plic0` @0xe0000000, 0x0400_0000 window, `riscv,ndev=159` | The K1 is a **PLIC** SoC. solnix already has a PLIC driver. AIA is not present. |
| CPU count | 4 (`cpu@0..3`) | **8** (`cpu@0..7`), single cluster | SMP start must bring up 8 harts. |
| UART | `snps,dw-apb-uart` @0xd4017000 | `spacemit,pxa-uart` (mainline: `spacemit,k1-uart`/`intel,xscale-uart`) @0xd4017000, **reg-shift=2, reg-io-width=4** | 16550-family, 32-bit regs on 4-byte stride. Bind-string differs; register layout is compatible. |
| MMC/SD | `snps,dwcmshc-sdhci` / `snps,dw-mshc` | **`spacemit,k1-x-sdhci`** @0xd4280000 / d4280800 / **d4281000** (three controllers) | The K1 is **SDHCI-standard**, NOT dw-mmc. The R-P58/59 dwmmc driver is the **wrong IP** for this board (see §5). |

Real K1 register bases used below (from `k1-x.dtsi`):

```
CCU  (clock)        0xd4050000 (+ apmu 0xd4282800, apbc 0xd4015000, apbs 0xd4090000, ...)
RESET               0xd4050000 (same block as CCU; spacemit,k1x-reset)
PINCTRL             0xd401e000 (+ 0xd4019800, 0xd4019000, 0xd4282904)
PLIC                0xe0000000 (0x0400_0000), ndev=159
CLINT               0xe4000000
UART0 (console)     0xd4017000  reg-shift=2 reg-io-width=4  IRQ 42
SDHCI0/1/2          0xd4280000 / 0xd4280800 / 0xd4281000   IRQ 99/100/101
GbE eth0/eth1       0xcac80000 / 0xcac81000  (spacemit,k1x-emac)  IRQ 131/133
USB3 dwc3 core      0xc0a00000 (snps,dwc3)  IRQ 125; K1 glue @0xd4282bc8 IRQ 149
PCIe0 RC (dbi)      0xca000000; atu 0xca300000; cfg 0x8f000000; phy 0xc0b10000/0xc0b20000  IRQ 141/145
GPU (imggpu)        0xcac00000  (img,rgx)  IRQ 75   — PowerVR, no BSD driver
DPU/HDMI            spacemit,dpu / saturn (board display overlay dtsi, custom)
```

**First action for any bring-up**: regenerate `k1.dts`/`k1_dtb.h` as a faithful
subset of the *vendor* `k1-x.dtsi` (PLIC not AIA, 8 harts, `spacemit,k1-x-sdhci`,
the emac/dwc3/pcie/ccu nodes). Everything below assumes the corrected DTB.

---

## 1. Will the R-P60 fw_payload even boot on the Jupiter?

**Likely yes to the console, with two caveats.** The Jupiter boot chain is
U-Boot → OpenSBI (M-mode) → `booti a0=hartid a1=dtb` into the S-mode payload,
which is exactly the solnix fw_payload convention (R-P56). The two things that
decide whether it prints:

1. **Console UART** — solnix's ns16550 driver (`asy_nsuart.c` / `uart.c`) with
   `reg-shift=2, reg-io-width=4` matches the K1 `spacemit,pxa-uart` register
   layout (16550-family). The only gap is the FDT *bind string*: `fdt.c` looks
   for `snps,dw-apb-uart`; the real node is `spacemit,pxa-uart`. One-line fix:
   add the K1 compatible strings to the UART match list. Bases already agree
   (0xd4017000).
2. **PLIC** — the K1 uses a standard `riscv,plic0` at 0xe0000000, and solnix
   already drives PLIC (`plic.c`). The in-repo DTB models AIA (APLIC+IMSIC),
   which the real board does *not* use; boot must parse the real (PLIC) DTB.
   The `aia.c` path is not needed for the Jupiter.

**Caveat A — the clocks may already be on.** U-Boot/OpenSBI leave the console
UART and the boot medium clock-enabled, so a console banner and a first-stage
boot can happen *before* solnix touches the CCU. Any device solnix wants to
(re)initialize itself, though, needs the K1 clock/reset shim (§6).

**Caveat B — the boot medium.** The fw_payload prints, but to reach userland it
must read root off SDHCI (§5) — solnix *already has* an SDHCI-standard driver
(`uts/sdhci.c`) that the K1 `spacemit,k1-x-sdhci` is register-compatible with,
so this is wiring not a fresh port — not the R-P58/59 dwmmc driver (wrong IP),
and not virtio-blk (qemu-only). So "boots" = console + early kernel yes; "boots
to init" = needs §5 wiring + §6 (clocks).

Bottom line: **expect the corrected-DTB fw_payload to reach a console banner and
early kernel; reaching `/sbin/init` needs the K1 clock/reset shim + wiring the
existing SDHCI driver to the real controller.**

---

## Priority order (boot-critical → nice-to-have)

```
P0  K1 clocks/reset/pinctrl shim + console UART bind   (gates everything)      §6, §1
P1  SDHCI (eMMC/microSD root)                           (gates userland)        §5
P2  1GbE MAC (spacemit,k1x-emac)                        (updates/network)       §3
P3  PCIe root complex (k1x,dwc-pcie)                    (gates NVMe)            §2
P4  NVMe (M.2)                                          (fast storage)          §1-NVMe
P5  Framebuffer scanout (HDMI, no 3D)                   (visible SW desktop)    §7
P6  USB3 (DWC3 + xHCI)                                  (peripherals)           §4
--  GPU (PowerVR BXE) — SCOPE ONLY, do NOT port                                 §7
```

Rationale: clocks/console first (nothing runs without them); then a root medium
(SDHCL/eMMC — the on-board storage that makes the box self-contained); then
network (so it can pull updates/packages from the solnix cache); then PCIe+NVMe
(fast storage, and PCIe is the prerequisite for NVMe); then a framebuffer so a
software-rendered COSMIC is *visible* on the monitor; USB3 last.

---

## §6 — P0: K1 clocks / reset / pinctrl shim

**BSD crib:** none — the K1 CCU/reset/pinctrl are SpacemiT-custom
(`spacemit,k1x-clock`, `spacemit,k1x-reset`, `pinconf-single-aib`). BSD has no
K1 clock driver. The **only** reference is the Linux vendor driver
(`drivers/clk/spacemit/*`, `drivers/reset/*`, `drivers/pinctrl/spacemit/*` in
spacemit-com/linux-6.6). Do **not** port the full Linux CCU (a large clock-tree
framework); write a **minimal enable-only shim**.

**What the shim must do (and only that):** for each device solnix brings up,
ungate its clock and deassert its reset by writing the specific CCU/reset
registers the vendor DTS names. The DTS gives the exact clock/reset IDs per
device (e.g. SDHCI0 needs `CLK_SDH0`, `CLK_SDH_AXI`, `CLK_AIB` +
`RESET_SDH_AXI`, `RESET_SDH0`; emac0 needs `CLK_EMAC0_BUS`, `CLK_EMAC0_PTP` +
`RESET_EMAC0`; dwc3 needs `CLK_USB30` + `RESET_USB3_0`; pcie0 needs `CLK_PCIE0`
+ `RESET_PCIE0`). The shim is a table: `{device → (ccu_reg, bit), (reset_reg,
bit)}` extracted from the vendor `clk/spacemit` register maps, with two ops:
`k1_clk_enable(id)` and `k1_reset_deassert(id)`.

- **illumos mapping:** plain MMIO helpers over the CCU/reset windows
  (0xd4050000, 0xd4282800, ...). No ddi clock framework needed — solnix's
  kernel already maps device MMIO via the direct-map/`KVTOP`. Model it like the
  existing `dwmmc_set_clock()` register pokes, but reading the K1 CCU bit
  positions. Pinctrl: for the boot devices (SDHCI, UART, emac MDIO) U-Boot has
  usually already muxed the pads; the shim can start as a no-op and add specific
  pin-mux writes only if a device fails to respond.
- **Effort:** 3–5 days. The mechanical part (MMIO table) is small; the cost is
  *reading the vendor CCU driver to extract the correct register+bit per clock/
  reset ID*, and iterating on hardware when a device stays dark. This is the
  single most schedule-critical item because every other driver depends on it.
- **Risk:** medium. If U-Boot leaves everything the boot path needs already on,
  the shim is trivial for storage/console; each *new* device (emac, pcie, dwc3,
  gpu-dpu) adds one clock+reset entry that must be verified live.

## §1(console) — P0: console UART bind

**BSD crib:** none needed — solnix owns `asy_nsuart.c`/`uart.c` (ns16550,
reg-shift aware). This is the existing driver already used under qemu.
- **K1 glue:** add `spacemit,pxa-uart`, `spacemit,k1-uart`, `intel,xscale-uart`
  to the FDT UART match list in `fdt.c`; the driver already reads `reg-shift`/
  `reg-io-width` (2 / 4). Base 0xd4017000, IRQ 42 on the PLIC.
- **Effort:** 1–2 hours (compatible-string add + on-board console check).

---

## §5 — P1: SDHCI (eMMC / microSD root)

**Correction:** the K1 MMC IP is **`spacemit,k1-x-sdhci` — a standard SDHCI
(SD Host Controller) core, NOT dw-mmc / dw-mshc.** The R-P58/59 `dwmmc.c`
driver is the *wrong* controller for this board and cannot be reused as-is (its
register map, CLKDIV/FIFOTH/IDMAC layout is the Synopsys DesignWare *dw-mmc*
family, a different IP than SDHCI). The dwmmc work is still valuable for
dw-mmc boards (VisionFive 2), but the Jupiter needs an SDHCI driver.

**Good news: solnix already has one.** `src/riscv/uts/sdhci.c` (R-P14/15) is an
SDHCI-*standard* register-model block driver (SDHCI reset, the CMD0/8/ACMD41/2/
3/7/17 card-init + single-block read against the SDHCI-standard register map).
The K1 `spacemit,k1-x-sdhci` is SDHCI-register-compatible, so §5 is mostly
*wiring* the existing driver to real hardware, not a fresh port — a big effort
reduction vs a from-scratch dw-mmc replacement.

**BSD crib:**
- **FreeBSD** `sys/dev/sdhci/sdhci.c` (the generic SDHCI core: command FSM,
  ADMA2/SDMA, capabilities, clock/power) + `sys/dev/sdhci/sdhci_fdt.c` (the
  FDT attach + per-SoC quirk glue — the exact model for a `spacemit,k1-x-sdhci`
  attachment).
- **NetBSD** `sys/dev/sdmmc/sdhc.c` (SDHCI core) + `sys/dev/sdmmc/sdmmc.c` (the
  card-init/command layer) as the cross-check.
- The SD command set (CMD0/8/ACMD41/2/3/9/7/16/17/18/24/25) is already exercised
  by the dwmmc driver — that logic transfers; only the **register access layer**
  changes from dw-mmc offsets to SDHCI-standard offsets.

**illumos mapping:** the same `*_strategy(blkno, buf, rw) → 0/-1` block seam the
dwmmc/vioblk drivers already present to `bdev_strategy`. Write `sdhci_strategy`
with that exact shape; `bdev_strategy` dispatches to it when the FDT walker
finds a `spacemit,k1-x-sdhci` node (mirroring how `dwmmc_set_base()` binds
today). No changes above the strategy seam — the existing blockfs/GPT/root-pivot
boots off SDHCI unchanged. illumos `usr/src/uts/common/io/sdcard` (sda/sdhost)
gives the strategy(9E)-shaped one-block-per-call model already followed.

**K1 glue:** three controllers (0xd4280000 eMMC, 0xd4280800, 0xd4281000 SD/µSD).
Enable `CLK_SDH*` + `CLK_SDH_AXI` and deassert `RESET_SDH_AXI`/`RESET_SDH*` via
the §6 shim before probe. The `spacemit,k1-x-sdhci` quirks (tuning, HS200/HS400
for eMMC) can be deferred — default-speed 1-bit/4-bit is enough to read root.

- **Effort:** 2–4 days. The existing `uts/sdhci.c` already implements the SDHCI-
  standard register model + SD card-init; the work is (a) bind it to the real
  `spacemit,k1-x-sdhci` node via the corrected DTB, (b) add the `*_strategy`
  dispatch + a write path (CMD24) alongside the existing read (CMD17), (c) the
  §6 clocks/reset, (d) any K1 `spacemit,k1-x-sdhci` quirk. FreeBSD `sdhci.c`
  fills gaps (SDMA/ADMA2, timing). Meaningfully less than the 4–6 d a fresh port
  would take.
- **Risk:** low. SDHCI is a well-specified standard core; the crib is mature and
  BSD-licensed; the seam already exists in solnix.

---

## §3 — P2: 1GbE MAC — `spacemit,k1x-emac`

**⚠️ Biggest single risk in this plan.** The K1 GbE MAC is **SpacemiT-custom
(`spacemit,k1x-emac`), NOT a Synopsys DesignWare DWMAC/stmmac.** Verified by
reading the vendor driver `drivers/net/ethernet/spacemit/k1x-emac.c` (~3000
lines, 0 references to stmmac/snps, its own `emac_tx_desc`/`emac_rx_desc`
DMA-descriptor rings, 307 register defines in `k1x-emac.h`). Therefore the clean
`dwc_gmac` crib does **not** apply — there is **no BSD driver for this MAC**.

**Consequence:** this is a **from-scratch port from the Linux vendor driver**,
the hardest driver in the plan. FreeBSD `sys/dev/dwc/if_dwc.c` (Synopsys
DWC_gmac) and NetBSD `sys/dev/ic/dwc_gmac.c` are **NOT usable** as the register-
level crib (wrong IP); they are useful only as a *structural* model for "how a
BSD Ethernet driver wires a descriptor-ring MAC to the network stack."

**What IS reusable:**
- **PHY:** the on-board PHY is a Motorcomm YT8531. **Already supported in both
  FreeBSD and NetBSD `mii`** (`MOTORCOMM YT8531` in `miidevs`), and `ukphy` is a
  fallback. The MDIO/MII management layer is standard IEEE 802.3 clause 22/45 —
  the MAC's MDIO register block drives it. So the PHY side is a known quantity.
- **illumos mapping:** GLDv3 (`mac_register`/`mac_rx`/`mac_tx`) is the target
  NIC KPI — the same framework the ena and vioif work targets. The DMA rings map
  to illumos `ddi_dma_*`; on this kernel, the direct-map + `KVTOP` pattern the
  vioblk/dwmmc drivers use for descriptor PAs applies. Cross-reference the ena
  crib (`~/ws/osv/bsd/sys/dev/ena` + the illumos ena) for the GLDv3 skeleton.

**Port plan:** read `k1x-emac.c`/`.h` for (a) the reset/clock/PHY-init sequence,
(b) the TX/RX descriptor-ring format and the DMA setup, (c) the register block
(MAC config, DMA control, interrupt status). Reimplement as an illumos GLDv3
driver: descriptor rings via `ddi_dma`, MII via the standard MDIO ops (YT8531),
IRQ 131/133 on the PLIC. Enable `CLK_EMAC0_BUS`/`CLK_EMAC0_PTP` + deassert
`RESET_EMAC0` (§6); the emac also has a K1 APMU config register
(`k1x,apmu-base-reg = 0xD4282800`, `ctrl-reg`/`dline-reg`) for the RGMII/RMII
mode + delay-line — a K1-specific quirk that must be programmed.

- **Effort:** 2–3 weeks (10–15 days). This is a full NIC port from a Linux-only
  reference with no BSD crib, plus GLDv3 integration, plus the K1 APMU/delay-line
  quirk. The PHY being already-supported saves a few days.
- **Risk:** **high** — no BSD crib, custom DMA descriptor format, K1 RGMII
  delay-line tuning is board/hardware-sensitive (leave a calibration knob for
  the `ctrl-reg`/`dline-reg` delay values). Contingency: bring the box online
  via a USB3 Ethernet dongle (§4 + a USB-NIC driver) or NVMe-only offline until
  the MAC is done.

---

## §2 — P3: PCIe root complex — `k1x,dwc-pcie`

**BSD crib:**
- **FreeBSD** `sys/dev/pci/pci_dw.c` + `pci_dw.h` (the **Synopsys DesignWare
  PCIe base class** — "Base class for all Synopsys DesignWare PCI/PCIe drivers",
  Michal Meloun 2019: DBI config-space access, iATU viewport programming,
  link-up) + `sys/dev/pci/pci_dw_mv.c` (a **working platform-glue example** —
  the Marvell Armada DWC glue: reset/clock/PHY init + attach, exactly the shape
  the K1 glue takes). Plus `sys/dev/pci/pci_host_generic.c` for the ECAM/generic
  host-bridge + resource-manager wiring.
- **NetBSD** `sys/dev/pci/pci.c` (the MI PCI bus layer) as the config-space/
  enumeration cross-check; NetBSD's DesignWare glue lives under `sys/arch/*/fdt`
  per-SoC.

**illumos mapping:** illumos already has a full PCI/PCIe nexus
(`usr/src/uts/common/io/pci*`, `pcie`) and the `pci_config_*` config-space KPI.
The port is a **new host-bridge nexus** that presents the K1 DWC RC to that
existing PCI framework: implement DBI-based config reads/writes (the DesignWare
`pci_dw.c` pattern), program the iATU to map config/mem/IO windows, and register
the bridge so illumos's PCIe enumeration walks it. MSI: the DWC core's MSI
controller feeds the PLIC (IRQ 141/145) — map MSIs to PLIC lines.

**K1 glue (from the DTS):** DBI @0xca000000, iATU @0xca300000, config space
@0x8f000000, PHY @0xc0b10000/0xc0b20000, plus the K1 SoC-config addr
@0xd4282bcc. `max-link-speed=2` (Gen2), `num-lanes=1`, `num-viewport=8`. Bring-up
sequence: §6 enables `CLK_PCIE0` + deasserts `RESET_PCIE0`, then the combphy
(PCIe PHY) init, then the DWC link-up poll, then iATU windows, then enumerate.
The PCIe PHY (combphy, shared with USB3) init is the K1-specific hard part and
has no BSD crib — reference the Linux `k1x,dwc-pcie` + combphy vendor driver.

- **Effort:** 2–3 weeks (10–15 days). The DesignWare core crib (`pci_dw.c`) is
  clean and BSD-licensed; the cost is the illumos host-bridge nexus integration
  + the K1 combphy/reset/clock sequence (no crib) + MSI-to-PLIC. Gates NVMe.
- **Risk:** medium-high. The DWC core is well-cribbable; the combphy init and
  MSI plumbing are the uncertain parts. Leave the PHY tuning parameters as knobs.

---

## §1(NVMe) — P4: NVMe (M.2)

**BSD crib:**
- **FreeBSD** `sys/dev/nvme/nvme.c` + `nvme_ctrlr.c` + `nvme_ns.c` + `nvme_qpair.c`
  (the admin + I/O submission/completion queue machinery, controller identify,
  namespace discovery, the NVMe command set). The cleanest, best-documented
  crib in this plan — PCIe-standard, spec-faithful.
- **NetBSD** `sys/dev/ic/nvme.c` + `sys/dev/pci/nvme_pci.c` (the same design,
  MI core + PCI attach) as the cross-check and the "how a BSD kernel wires the
  admin/IO queues to the block layer" reference.

**illumos mapping:** illumos ships a mature NVMe driver already
(`usr/src/uts/common/io/nvme/nvme.c`) built on the illumos `blkdev` framework —
so the *real* illumos KPI target is `blkdev`/`bd_*`. For solnix's minimal
riscv64 kernel, the immediate seam is the same `*_strategy(blkno, buf, rw)`
block dispatch the SDHCI/vioblk drivers use: implement `nvme_strategy` that
builds a single-block read/write NVMe I/O command, rings the submission queue
doorbell, and reaps the completion. The admin path (identify controller/
namespace, create I/O queues) runs once at attach. Memory: the NVMe queues +
PRP lists are DMA — use the direct-map/`KVTOP` PA pattern already in vioblk/
dwmmc.

**Dependency:** NVMe is a PCIe device — it **requires §2 (PCIe RC) first**. Once
PCIe enumerates the M.2 slot, the NVMe controller appears as a standard PCIe
function; the NVMe driver is then platform-independent (no K1-specific glue
beyond the PCIe path).

- **Effort:** 1–2 weeks (7–10 days) for a minimal single-namespace polled
  driver behind the strategy seam, *after* PCIe works. A full illumos `blkdev`
  integration (interrupts, multiple queues, NVMe-native partitioning) is more.
- **Risk:** low (the driver itself — spec-standard, best crib). The risk is
  entirely inherited from §2 (PCIe).

---

## §4 — P6: USB3 (DWC3 + xHCI)

**BSD crib:**
- **FreeBSD** `sys/dev/usb/controller/xhci.c` (the xHCI host-controller driver —
  ring/TRB management, port/device enumeration, the USB stack seam) +
  `sys/dev/usb/controller/dwc3/dwc3.c` (the **DWC3 core glue**: GCTL/GUSB2/GUSB3
  PHY config, host-mode select, reset — exactly the `snps,dwc3` core the K1
  uses).
- **NetBSD** `sys/dev/usb/xhci.c` as the cross-check.

**illumos mapping:** illumos has `xhci` already
(`usr/src/uts/common/io/usb/hcd/xhci`) built on USBA (the illumos USB
architecture). Porting the full USBA stack to the minimal riscv64 kernel is a
large effort; the realistic near-term target is the FreeBSD xhci + the illumos
xhci as references, with USBA as the eventual KPI. This is the biggest *stack*
port (USB device framework), which is why it is last.

**K1 glue:** the core is `snps,dwc3` @0xc0a00000 (IRQ 125) under a
`spacemit,k1-x-dwc3` wrapper @0xd4282bc8 (IRQ 149). §6 enables `CLK_USB30` +
deasserts `RESET_USB3_0`; then the combphy (`PHY_TYPE_USB3`, shared IP with the
PCIe PHY) + usb2phy init; then the DWC3 core init (GCTL host mode); then xHCI
runs on top. The combphy init is shared work with §2.

- **Effort:** 3–4 weeks (15–20 days) — dominated by the USB stack, not the DWC3
  glue. The DWC3 core-init crib is small; xHCI + a minimal device framework
  (hub, mass-storage or HID class) is the bulk.
- **Risk:** medium. Deferrable — USB3 is not on the boot path. A USB keyboard/
  mouse for the desktop and a USB-Ethernet fallback are the motivating use cases.

---

## §7 — GPU (PowerVR BXE-2-32) + framebuffer scanout

### GPU port — SCOPE ONLY, do NOT plan a port here

**Confirmed no-BSD-driver reality.** The Jupiter GPU is `img,rgx` @0xcac00000
(Imagination PowerVR B-series, BXE-2-32). Verified: **there is no NetBSD or
FreeBSD PowerVR driver anywhere** (FreeBSD `drm-kmod` is a LinuxKPI port of
Intel/AMD/Radeon DRM only; NetBSD `drm2` likewise — neither has PowerVR).
Imagination's stack is largely proprietary (closed `pvr` userspace + signed
firmware); the open Mesa `powervr` Vulkan driver + the `powervr` DRM kernel
driver are young and Linux-only. **A PowerVR port is explicitly out of scope for
this plan** — it is a multi-month (likely multi-quarter) effort or needs
Imagination's blob.

Three options, as required:
1. **llvmpipe / lavapipe software rendering — LEAD.** No GPU driver needed;
   COSMIC/Vulkan run on the CPU (proven on x86/aarch64 in solnix). RVV1.0 can
   later accelerate the software rasterizer for real speedups. This is the
   recommended path to a usable desktop.
2. **Dumb-framebuffer / KMS scanout for HDMI without 3D** (below) — makes the
   software-rendered desktop *visible* on the physical monitor.
3. **The long game** — port the Linux Mesa `powervr` + the `powervr` DRM
   (young, Linux-only, hard). Not recommended now.

**Recommendation: llvmpipe (SW render) + a dumb-framebuffer scanout.**

### Framebuffer scanout — the "PIXELS on HDMI" plan

This is what makes a software-rendered COSMIC *visible* on the box's monitor
without any 3D. The K1 drives HDMI through a **SpacemiT-custom Display
Processing Unit (DPU / "saturn", `spacemit,dpu`)** — the scanout engine that
reads a framebuffer from RAM and drives the HDMI PHY. Like the emac, **the DPU
is custom and has no BSD driver**; it is defined in a board display-overlay
dtsi (not the base `k1-x.dtsi`).

Two sub-options for scanout:

- **(a) Inherit the U-Boot / OpenSBI framebuffer (simplest).** If U-Boot already
  configures the DPU + HDMI and leaves a live framebuffer (many K1 boards show a
  boot logo), solnix can treat it as a pre-initialized "simple-framebuffer": map
  the framebuffer PA, learn width/height/stride/format from the (U-Boot-provided
  or hard-coded) mode, and blit the software-rendered desktop into it. **Crib:**
  FreeBSD `sys/dev/vt/hw/simplefb/simplefb.c` (the `simple-framebuffer` DT
  consumer) + `sys/dev/vt/hw/fb/vt_early_fb.c` (the early-FB console) —
  reimplemented as an illumos framebuffer/`gfxp`/`vgatext`-style console + a
  `/dev/fb` the compositor can mmap. **illumos mapping:** the `sys/visual_io.h`
  / framebuffer device interface (the same seam `gfx_private`/`vgatext` use).
  **Effort: 3–5 days** — if U-Boot leaves a usable framebuffer, this is a
  map-and-blit exercise, no DPU programming.

- **(b) Program the DPU + HDMI from scratch (harder).** If there is no inherited
  framebuffer, solnix must init the DPU scanout registers + the HDMI PHY itself.
  No BSD crib — the only reference is the Linux vendor DPU driver
  (`drivers/gpu/drm/spacemit/*`) + `spacemit-dpu.h`. This is a real custom-
  display-controller port: mode-set, plane/framebuffer base, HDMI PHY bring-up.
  §6 enables `CLK_DPU_MCLK` + the HDMI clocks + deasserts the DPU/HDMI resets.
  **Effort: 2–3 weeks** — comparable to the emac (custom IP, Linux-only ref).

- **Recommendation:** try **(a) first** — cheapest path to visible pixels. Fall
  back to **(b)** only if U-Boot leaves no usable framebuffer. In both cases the
  desktop itself renders in software (llvmpipe); scanout only moves finished
  pixels to HDMI.

- **Risk:** medium. (a) depends on U-Boot leaving a framebuffer in a known
  format; (b) is a full custom-DPU port. Leave the mode (resolution/stride/
  format) as a configurable knob — U-Boot's default mode varies by board/monitor.

---

## Effort + priority summary

| Pri | Device | BSD crib | illumos KPI seam | Effort | Risk |
|-----|--------|----------|------------------|--------|------|
| P0 | K1 clocks/reset/pinctrl shim | none (Linux vendor CCU ref) | MMIO helpers over CCU/reset windows | 3–5 d | med |
| P0 | Console UART bind | none (own ns16550) | existing `asy_nsuart`/`fdt.c` | 1–2 h | low |
| P1 | SDHCI eMMC/SD | **have `uts/sdhci.c`**; gaps from FreeBSD `sdhci.c`+`sdhci_fdt.c`; NetBSD `sdhc.c` | `*_strategy` → `bdev_strategy` | 2–4 d | low |
| P2 | 1GbE MAC (k1x-emac) | **none** (custom; Linux `k1x-emac.c` only); PHY YT8531 in BSD `mii` | GLDv3 `mac_*` + `ddi_dma` | 2–3 wk | **high** |
| P3 | PCIe RC (k1x,dwc-pcie) | FreeBSD `pci_dw.c`+`pci_dw_mv.c`+`pci_host_generic.c` | illumos PCI/PCIe nexus + `pci_config_*` | 2–3 wk | med-high |
| P4 | NVMe (M.2) | FreeBSD `nvme.c`/`nvme_ctrlr.c`; NetBSD `ic/nvme.c` | `blkdev`/`*_strategy` | 1–2 wk (post-PCIe) | low |
| P5 | Framebuffer scanout (HDMI) | FreeBSD `simplefb.c`+`vt_early_fb.c`; else Linux DPU only | `visual_io`/`/dev/fb` | 3–5 d (inherit) / 2–3 wk (from scratch) | med |
| P6 | USB3 (DWC3+xHCI) | FreeBSD `xhci.c`+`dwc3/dwc3.c`; NetBSD `xhci.c` | USBA / xhci | 3–4 wk | med |
| — | GPU (PowerVR BXE) | **none exists** — do NOT port | (llvmpipe SW render) | out of scope | — |

**Total to a networked, storage-backed, HDMI-visible SW desktop (P0–P5):**
roughly **7–10 weeks** of focused work, dominated by the two custom-IP ports
(emac, PCIe) and gated first by the small-but-critical clock/reset shim.

---

## The three biggest risks

1. **The 1GbE MAC is custom (`spacemit,k1x-emac`), not DWMAC.** The single
   biggest surprise vs the PS-MILKV-JUPITER assumption. There is no BSD crib; it
   is a ~3000-line from-scratch port from the Linux vendor driver, plus the K1
   RGMII delay-line quirk (`ctrl-reg`/`dline-reg`) that needs hardware tuning.
   The YT8531 PHY being already in BSD `mii` is the only relief. **Contingency:
   a USB3 Ethernet dongle** (once §4 exists) or NVMe-offline bring-up until the
   MAC is done. This should shape the schedule — do NOT assume `dwc_gmac`.

2. **The K1 clock/reset complexity gates everything.** The CCU/reset/pinctrl are
   custom with no BSD reference; the minimal enable-only shim is small but every
   device adds a clock+reset entry that must be verified on live hardware, and
   getting a register+bit wrong leaves a device silently dark. Mitigated by
   U-Boot likely leaving the console + boot medium already clocked, so the
   critical path (console + SDHCI) may need very little shim.

3. **The PowerVR reality — no 3D acceleration for the foreseeable future.** No
   BSD driver, proprietary Imagination stack, young Linux-only Mesa `powervr`.
   The desktop must be software-rendered (llvmpipe), and even *visible* pixels
   depend on either inheriting the U-Boot framebuffer or a from-scratch port of
   the custom SpacemiT DPU (no crib). Lead with llvmpipe + framebuffer-inherit;
   treat any GPU/DPU port as a separate multi-month effort, not part of this plan.

Secondary: **the corrected DTB is a prerequisite** — the in-repo `k1.dts`/
`k1_dtb.h` model AIA+4 harts+dw-mmc, but the real K1 is PLIC+8 harts+SDHCI.
Regenerate the embedded DTB from the vendor `k1-x.dtsi` before any bring-up, or
every driver binds against the wrong topology.

---

## Sources

- SpacemiT vendor BSP: `spacemit-com/linux-6.6` branch `k1-bl-v2.2.y`,
  `arch/riscv/boot/dts/spacemit/k1-x.dtsi` (authoritative peripheral map);
  `drivers/net/ethernet/spacemit/k1x-emac.c`/`.h` (custom MAC).
- Mainline Linux `v6.14` `arch/riscv/boot/dts/spacemit/k1.dtsi` (PLIC/CLINT/UART
  cross-check).
- FreeBSD `sys/dev/{nvme,sdhci,dwc,pci,usb/controller,vt}` (BSD cribs, verified
  present at cgit.freebsd.org HEAD).
- NetBSD `sys/dev/{ic/nvme.c,ic/dwc_gmac.c,ic/dwc_mmc.c,sdmmc/sdhc.c,usb/xhci.c,
  pci/pci.c,mii/miidevs}` (cross-checks, verified present on the trunk mirror).
- solnix existing: `src/riscv/uts/` (fdt.c, plic.c, asy_nsuart.c, vioblk.c,
  vionet.c, sdhci.c), `src/riscv/rp59/kernel/dwmmc.c` (the `*_strategy` seam),
  `src/riscv/bsd-ref/` (crib doctrine).
