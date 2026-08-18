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

## Will the fw_payload boot on the Jupiter?  (R-P62: RESOLVED)

The R-P60/R-P61 `fw_payload.elf` links OpenSBI at `FW_TEXT_START=0x80000000`
with the kernel embedded at `+0x200000` (kernel phys 0x80200000).  Three things
must line up on the K1:

  1. **DTB** -- the Jupiter's u-boot/OpenSBI passes the board DTB in a1; the
     R-P57 walker (extended in R-P61) parses the K1 layout above.  ✅ parse proven.
  2. **UART** -- the K1 console is a 16550 variant (pxa-uart, shift 2); the
     kernel's console goes through the SBI legacy console, so OpenSBI owns the
     UART -- as long as the board's OpenSBI console is up, solnix prints.  The
     DTB-selected FDT_UART_PXA arm records shift-2 for a future raw-UART path.
  3. **Load address** -- **R-P62 RESOLVED.**  The kernel is a fully-linked
     NON-PIE image (kernel.lds PADDR = 0x80200000; the solaris-target binutils
     has no `-pie`, so `unix.elf` carries ZERO R_RISCV_RELATIVE relocs).  Its
     `_start` runs position-independently (medany PC-relative -- proven: a
     fw_payload built with FW_PAYLOAD_OFFSET=0x400000 reaches `mlsetup complete`
     at phys 0x80400000), BUT its STORED ABSOLUTE POINTERS (vnode-ops vtables,
     dispatch tables) are relocated to the link base 0x80200000 -- so the shifted
     boot then faults the instant it calls through such a pointer (observed:
     `scause=0xc` at the LINKED VA `0xffffffc0802025e4` = `ramfs_vop_getattr`,
     whose physical is unmapped when loaded elsewhere).  **So the kernel MUST
     load at physical 0x80200000.**  This is NOT a K1 problem: the K1 DRAM base
     is 0x0 but DRAM SPANS 8 GiB (0x0 .. 0x2_0000_0000), so 0x80200000 (2 GiB in)
     is valid K1 DRAM.  R-P62 makes the kernel READ its actual load base from
     OpenSBI (captured PC-relative in `_start` -> `boot_load_pa`, printed +
     checked at mlsetup) so a mismatch is a LOUD diagnostic, not a silent fault.
     Two K1 firmware recipes (`mk-fw-k1.sh`, both built + the fw_payload boot-
     verified under qemu):
       * **(A) fw_payload_k1.elf** -- OpenSBI@0x80000000 (valid K1 DRAM, within
         the +-2 GiB PCREL_HI20 range of the embedded payload) + FW_PAYLOAD_OFFSET
         =0x200000 -> kernel@0x80200000.  Identical to the qemu-virt build, so
         the SAME fw_payload works on the K1.  (FW_TEXT_START=0x0 + OFFSET=
         0x80200000 does NOT link -- the PC-relative `lla payload_bin` is >2 GiB.)
       * **(B) fw_dynamic_k1.elf** -- OpenSBI@0x0 (K1 DRAM base) built FW_DYNAMIC=y;
         the vendor u-boot SPL loads OpenSBI + the kernel (unix.bin at 0x80200000)
         separately and passes the kernel address via `struct fw_dynamic_info` in
         a2.  This is the K1's stock convention and needs no PC-relative embed.
     Either way the kernel lands at 0x80200000; the DTB the firmware passes drives
     the rest of the K1 map, so ONE binary boots qemu-virt AND the Jupiter.
     (Upgrade path if the K1 ever forces a load base != 0x80200000: rebuild the
     kernel PIE with R_RISCV_RELATIVE + a `_start` reloc pass -- blocked today by
     the solaris-target binutils lacking `-pie`.)
