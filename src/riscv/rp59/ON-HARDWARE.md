# R-P58/R-P59 -- ON-HARDWARE.md: first real-board boot checklist

R-P57 delivered the two real-hardware ENABLERS (the DTB parse + a GPT image);
R-P58 GENERALIZED the DTB use (PLIC/CLINT/console-UART/hart-count all now come
from the device tree, not hardcoded qemu-virt constants) and added a **dw-mmc
SD/eMMC driver skeleton** behind `bdev_strategy`.  R-P59 COMPLETED that driver's
HW bring-up (clock / FIFO / power / IDMAC-DMA) and made the GPT root-match by
partition TYPE GUID (so the root is found regardless of position).

This is the precise checklist for a FIRST real-board boot on the two mainstream
RISC-V dev boards: the **StarFive VisionFive 2** (JH7110, dw-mmc SD) and the
**SiFive HiFive Unmatched** (FU740, Cadence SDHCI / NVMe over PCIe).

Nothing below runs under qemu -- qemu-virt has no dw-mmc host -- so each item is
either DONE-in-qemu-and-portable or NEEDS-A-BOARD.

## 0. What already ports as-is (DONE, boot-verified under qemu)

  * The S-mode kernel image + the OpenSBI `fw_payload.elf` wrap (R-P56).
  * The DTB/FDT parser (`fdt.c`): the SAME walker reads a board's DTB with ITS
    addresses -- `/memory`, `/cpus`, `/soc/{virtio_mmio,plic,clint,serial,mmc}`.
  * Drive-from-DTB (R-P58.1): PLIC base (`plic_set_base`), console-UART base
    (`plic_set_uart_base`), CLINT base (reported; SBI-driven), and the SMP hart
    count (`smp_start(..., fi_nharts)`) all come from the DTB. A board's DTB
    drives the identical code with its own map.
  * The single GPT disk image + the kernel GPT parser (R-P57.2).
  * The full blockfs / buffer-cache / root-pivot chain above `bdev_strategy` --
    device-independent; a new `*_strategy` is the only new code (R-P58.2).

## 1. The SD-card image layout (GPT + fw_payload in the right partition)

Both boards' mask-ROM/first-stage boot from an SD card expect a GPT with
board-specific partition TYPE GUIDs for the boot chain, then a root partition.

### VisionFive 2 (JH7110) SD layout

The JH7110 boot ROM -> SPL (u-boot-spl) -> OpenSBI+u-boot -> our fw_payload.
The vendor GPT partition-type GUIDs the ROM/SPL look for:

    partition 1  type 2E54B353-1271-4842-806F-E436D6AF6985  u-boot-spl (SPL)
    partition 2  type 5B193300-FC78-40CD-8002-E86C45580B47  u-boot / OpenSBI FIT
    partition 3  (our root)  the v3-blockfs root partition (Linux-data GUID ok)

  Steps:
  1. Build/obtain the JH7110 `u-boot-spl.bin.normal.out` + the `u-boot.itb`
     (OpenSBI + u-boot FIT) from the StarFive VisionFive2 u-boot tree, OR replace
     the u-boot payload with our OpenSBI `fw_payload.elf` (converted to the FIT /
     raw the SPL loads).
  2. Write the SPL to partition 1, the fw payload to partition 2, dd our
     `disk.img` root partition contents into partition 3 (or lay the whole GPT
     out with our root at the same LBA the kernel's GPT parser finds).
  3. `sgdisk`/`sfdisk` sets the type GUIDs; the kernel's GPT parser (R-P59)
     matches the root by its partition TYPE GUID (solnix-root
     2E54B353-1271-4842-806F-000000000002 or the Linux riscv64-root
     72EC70A6-CF74-40E6-BD49-4BDA08E8F224), so the root is found REGARDLESS of
     its position among the boot/data partitions -- no need to place it first.
     Give the root partition one of those type GUIDs; if a board uses a
     different root GUID, add it to `ROOT_GUIDS[]` in vfs.c (one line).

### HiFive Unmatched (FU740) SD layout

The FU740 ZSBL -> FSBL (from a specific GPT partition GUID) -> OpenSBI+u-boot.

    partition 1  type 5B193300-FC78-40CD-8002-E86C45580B47  FSBL
    partition 2  type 2E54B353-1271-4842-806F-E436D6AF6985  u-boot / OpenSBI
    partition 3  (our root)

  Same three steps; the FU740 also boots from an NVMe/PCIe or SPI-flash chain
  (see the NVMe alternative in section 4).

## 2. The board's OpenSBI / u-boot chain

  * VisionFive 2: mask ROM -> u-boot-SPL (DDR init) -> OpenSBI (M-mode) +
    u-boot proper (S-mode) -> loads the next payload. Our `fw_payload.elf`
    (OpenSBI generic + kernel payload @ 0x80200000) can either REPLACE the
    vendor OpenSBI+u-boot (boot our fw_payload directly from SPL) or be loaded
    BY u-boot (`bootm`/`booti` at 0x80200000). The kernel's S-mode entry +
    `a0=hartid`, `a1=dtb` convention is what OpenSBI/u-boot already provide.
  * HiFive Unmatched: ZSBL -> FSBL -> OpenSBI+u-boot -> our fw_payload, same
    two options.
  * BOTH hand the kernel a DTB in `a1` -- the R-P57 parser + the R-P58
    drive-from-DTB code consume it unchanged. VERIFY the board DTB's node names
    match the `fdt.c` matches (`serial@`, `mmc@`/`sdhci@`, `plic`, `clint`); if a
    board uses a different unit name, add a `startswith()` alias (one line).

## 3. The dw-mmc driver (R-P58.2) activated by the DTB

The dw-mmc driver (`dwmmc.c`) is COMPILED + LINKED and bound to the
DTB-discovered mmc base. To ACTIVATE it on a board:

  1. Confirm the board DTB has an `mmc@<base>` (VisionFive 2: `snps,dw-mshc` /
     `starfive,jh7110-mmc`) node -- `fdt.c` already extracts its `reg` base into
     `fi_mmc_base`; `main()` calls `dwmmc_set_base(fi_mmc_base)` +
     `dwmmc_probe()`. On qemu `fi_mmc_base==0` so it stays dormant.
  2. On-HW bring-up (R-P59 CLOSED the R-P58 skeleton gaps; these are now in
     dwmmc.c and only need a board to RUN):
     - CLOCK (DONE, R-P59): `dwmmc_set_clock()` programs CLKSRC/CLKDIV, gates +
       re-enables the card clock (CLKENA), and latches with the clock-update
       command (`CMD_UPDATE_CLOCK_ONLY`) -- ~400 kHz for identification, then a
       switch to ~25 MHz after card select.  The CLKDIV_400K / CLKDIV_25M
       divisors are ciu_clk-dependent -- VERIFY/tune them against the board's
       ciu_clk (the one physical-clock calibration knob a minimal model can't
       compute; card clock = ciu_clk / (2 * CLKDIV), CLKDIV=0 = bypass).
     - FIFO THRESHOLD (DONE, R-P59): `FIFOTH` (RX/TX watermarks + DMA burst) is
       programmed and CTRL FIFO_RESET is a discrete reset step.  FIFO_DEPTH is
       assumed 128 words -- confirm against the board's FIFO depth.
     - VOLTAGE/POWER (DONE + follow-up): `PWREN` + `CTYPE` bus width are set and
       the `UHS_REG` 1.8V voltage-switch register is defined; the CMD11 UHS
       voltage switch to 1.8V (needed only for UHS-I speeds) + board PMIC /
       card-detect / write-protect GPIOs remain board-specific (often already
       done by u-boot); default-speed 3.3V needs no switch.
     - DMA (DONE, R-P59): a complete IDMAC descriptor-ring transfer path (BMOD /
       DBADDR / a FS|LD|OWN descriptor, the buffer PA via the kernel direct-map
       KVTOP) is compiled behind `-DDWMMC_USE_DMA=1`; PIO is the default.  Build
       with DWMMC_USE_DMA=1 for throughput once PIO boots.
     - RESPONSE PARSING (follow-up): CMD2/CMD9 long responses are issued but the
       CSD capacity decode is unused by the single-sector path; decode CSD only
       if you need the device size (e.g. for the GPT backup header).
     - INTERRUPTS (follow-up): the FSM busy-polls; an interrupt-completion path
       (RINTSTS via the PLIC) is the remaining maturity item.
  3. TEST on the board: boot to the kernel, watch for `[R-P58.2] dw-mmc SD host
     base from the DTB: 0x...` + `binding the dw-mmc driver; probing the card`,
     then the root-pivot reading `/sbin/init` off SD via `dwmmc_strategy`
     (CMD17). If `dwmmc_probe()` returns 0, instrument which init command
     failed (each `dwmmc_cmd` returns -1 on RINTSTS error/timeout).

## 4. Alternative: NVMe over PCIe (HiFive Unmatched fast path)

NVMe is simpler as a protocol but needs a PCIe root-complex bring-up first
(ECAM config space walk, BAR assignment) -- heavier for a first cut. Behind the
same `bdev_strategy` seam:

  1. `fdt.c`: match `pci-host-ecam-generic`, map ECAM, enumerate class 0x0108.
  2. NVMe init: `CC.EN`, admin SQ/CQ, `IDENTIFY`, one I/O SQ/CQ pair.
  3. `nvme_strategy(blkno, buf, rw)`: READ (0x02)/WRITE (0x01), ring the SQ
     doorbell, poll the CQ phase bit.

Crib: NVMe 1.4 base spec (sec 3/5/6) + the PCIe ECAM layout + Linux
`drivers/nvme/host/pci.c`. Recommended AFTER the dw-mmc SD path (SD needs no
PCIe bring-up).

## 5. First-boot verification order (on the board)

  1. Serial console shows the OpenSBI banner -> `Domain0 Next Address
     0x80200000` -> the solnix S-mode entry (same as qemu).
  2. `[R-P57.1] parsing the DTB` with the BOARD's addresses (NOT the qemu-virt
     0x1000_1000 / 0x0c00_0000) -- the DTB DISCOVERY line will now MISMATCH the
     hardcoded qemu-virt map (expected + fine: it means the parser read the real
     board tree). RAM base/size + hart count should be the board's.
  3. `[R-P58.1] PLIC base from the DTB: 0x...` (board PLIC), `console UART base
     from the DTB: 0x...` (board UART), `DTB /cpus hart count = N`, and N harts
     come up.
  4. `[R-P58.2] dw-mmc SD host base from the DTB: 0x...` + the card probe.
  5. The GPT parse finds the root partition BY ITS TYPE GUID (R-P59 -- not a
     hardcoded LBA / first-non-empty entry, so boot/data partitions may precede
     it); the root-pivot reads init/sh off SD via `dwmmc_strategy`; the shell
     prompt appears on the board's UART.

Each of steps 2-5 is exactly what R-P58 boot-verified under qemu (with the
qemu-virt map + virtio-blk); the ONLY board deltas are the DTB addresses (auto,
via the parser) and the dw-mmc clock/power gaps in section 3.
