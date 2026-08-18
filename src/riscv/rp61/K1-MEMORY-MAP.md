# SpacemiT K1 (Milk-V Jupiter) memory map -- R-P61 reference for R-P62

This is the K1 SoC MMIO / topology map the R-P61 scaffolding parses + documents,
so R-P62 can wire the real on-HW MMIO.  Sourced from mainline
`arch/riscv/boot/dts/spacemit/k1-x.dtsi`, OpenSBI `platform/generic/spacemit/k1.{c,h}`
(present in this tree under `rp61/opensbi/platform/generic/spacemit/`), and the
parallel Jupiter driver review.

## CORRECTED topology (vs the earlier wrong assumption)

The K1 is **PLIC + 8 harts + SDHCI** -- NOT AIA, NOT dw-mmc:

| Item            | K1 value                              | qemu-virt (for contrast) |
|-----------------|---------------------------------------|--------------------------|
| Harts           | **8** (2 clusters x 4 X60 cores)      | 1..N                     |
| ISA             | rv64imafdcv + RVV1.0 + Zbb            | rv64gc                   |
| Interrupt ctrl  | **PLIC** @ `0xe0000000` (159 devs)    | PLIC @ 0x0c000000        |
| Timer/IPI       | CLINT @ `0xe4000000`                  | CLINT @ 0x02000000       |
| Console UART    | **spacemit,pxa-uart** @ `0xd4017000`, reg-shift **2**, reg-io-width 4 (a 16550 variant) | ns16550 @ 0x10000000, shift 0 |
| Storage         | **SDHCI** @ `0xd4280000` (`spacemit,k1-sdhci`) -> `uts/sdhci.c` | virtio-blk |
| Memory          | `memory@0`, 8 GiB (8GB SKU) / 16 GiB  | @ 0x80000000             |

## SoC-internal register bases (from OpenSBI spacemit/k1.h, for R-P62 MMIO)

| Block                    | Base        | Notes                                   |
|--------------------------|-------------|-----------------------------------------|
| PMU_AP (AP MMU/PMU)      | `0xd4282800`| per-core wakeup/idle-cfg regs           |
| CCI-550 (cache coherent) | `0xd8500000`| 2-cluster snoop/DVM enable (boot needs) |
| C0 reset-vector lo/hi    | `0xd4282db0`/`0xd4282db4` | cluster0 warmboot addr     |
| C1 reset-vector lo/hi    | `0xd4282eb0`/`0xd4282c04` | cluster1 warmboot addr     |

## K1 Clock Control Unit (CCU) -- R-P61 shim; R-P62 fills the real writel()

The K1 gates device clocks per-peripheral; a device's MMIO does not respond
until its function-clock + APB-clock are enabled and its reset is deasserted.
The R-P61 `k1.c` shim records these (compile-phase no-op under qemu):

| CCU block | Base        | Purpose                                  |
|-----------|-------------|------------------------------------------|
| MPMU      | `0xd4050000`| main PLL / PMU                           |
| APBC      | `0xd4015000`| APB peripheral clocks (UART0 @ +0x00c)   |
| APBS      | `0xd4090000`| APB secure clocks                        |
| APMU      | `0xd4282800`| AP MMU/PMU (SDH0/SDHCI @ +0x054)         |

Per-device enable = `FN_EN (bit1) | APB_EN (bit0) | RST_DEASSERT (bit2)`.
The two first consumers wired: the console UART clock (APBC+0x00c) and the
SDHCI clock (APMU+0x054).  (Exact offsets/bit fields are the k1-x.dtsi clock
cell indices; R-P62 verifies against the board.)

## The two calibration knobs (hardware is never the ideal on paper)

  * **UART baud divisor** -- the pxa-uart clock-frequency (k1-x.dtsi reports
    ~14.857 MHz) sets the 16550 divisor; the exact input clock is board-specific
    and needs on-HW tuning (R-P62).
  * **SDHCI clock divider** -- the identification (~400 kHz) then transfer
    (~25/50 MHz) divisors depend on the SDH input clock the APMU gates; the exact
    divisor is measured on the board.

## Will the R-P60 fw_payload boot on the Jupiter?

The R-P60/R-P61 `fw_payload.elf` links OpenSBI at `FW_TEXT_START=0x80000000`
with the kernel embedded at `+0x200000`.  Three things must line up on the K1:

  1. **DTB** -- the Jupiter's u-boot/OpenSBI passes the board DTB in a1; the
     R-P57 walker (extended in R-P61) parses the K1 layout above.  ✅ parse proven.
  2. **UART** -- the K1 console is a 16550 variant (pxa-uart, shift 2); the
     kernel's console goes through the SBI legacy console, so OpenSBI owns the
     UART -- as long as the board's OpenSBI console is up, solnix prints.  The
     DTB-selected FDT_UART_PXA arm records shift-2 for a future raw-UART path.
  3. **Load address** -- the K1 DRAM base is `0x0` (NOT qemu-virt's
     `0x80000000`).  The fw_payload is linked at `0x80000000`.  **This is the
     open question for R-P62**: the K1 boots OpenSBI where the board's u-boot/BROM
     places it; the fw_payload FW_TEXT_START + FW_PAYLOAD_OFFSET must match the
     K1's load convention (the vendor OpenSBI for the K1 links to the K1 DRAM
     map).  The R-P60 qemu-virt fw_payload will NOT boot as-is on the K1 without
     relinking to the K1 load address (or using the board's own OpenSBI +
     fw_dynamic loading the kernel as a payload at the K1 address).  R-P62 builds
     the K1-addressed fw_payload / uses the vendor OpenSBI.
