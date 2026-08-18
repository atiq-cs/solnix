# R-P57.3 -- the real-HW block backend (the R-P58 plan)

R-P57's DTB parse + GPT image are the real-hardware enablers.  The last
qemu-specific piece is the *block device*: qemu-virt gives us **virtio-blk**;
real RISC-V boards do not.  This documents the block-backend abstraction that is
already in place and the concrete driver R-P58 must add.

## The abstraction is already there: `bdev_strategy`

Every block read/write in the kernel -- the blockfs superblock, inodes, the
free-block bitmap, file data blocks, the buffer cache, the MBR/GPT probe --
routes through ONE seam in `vfs.c`:

    bdev_strategy(unsigned long blkno, unsigned char *buf, int rw)

which today dispatches:

    if (virtio_blk_present())
        return virtio_blk_strategy(blkno + blockfs_part_base, buf, rw);
    else
        <RAM-disk fallback>            /* bdev0[], 128 KiB */

`virtio_blk_strategy(blkno, buf, rw)` transfers ONE 512-byte sector via the
qemu-virt virtio-mmio split virtqueue (probe -> negotiate -> descriptor/avail/
used rings -> kick QueueNotify -> poll/IRQ the used ring).  It is a strategy(9E)
-shaped entry point: the block layer above it knows nothing about virtio.

**Consequence:** a real-HW block driver is a NEW `*_strategy` function with the
SAME `(blkno, buf, rw) -> 0/err` signature, selected in `bdev_strategy` by a
runtime probe.  No blockfs / buffer-cache / GPT code changes.

## Which real-HW driver R-P58 needs

The two mainstream RISC-V dev boards and their root media:

| board                 | root controller            | DTB compatible string(s)                 |
|-----------------------|----------------------------|------------------------------------------|
| SiFive HiFive Unmatched | Cadence SDHCI (SD) / NVMe over PCIe | `sifive,fu740-c000-ccache`; `cdns,sd4hc`; PCIe `pci-host-ecam-generic` |
| StarFive VisionFive 2 | dw-mmc (SD/eMMC)           | `starfive,jh7110-mmc` / `snps,dw-mshc`   |
| qemu `-machine virt`  | virtio-blk (done)          | `virtio,mmio`                            |

Two candidate paths, both behind `bdev_strategy`:

### Option A -- SD/MMC (dw-mmc), the VisionFive 2 / most-SoC path

The Synopsys DesignWare MMC host (`snps,dw-mshc`, the JH7110's controller) is the
most common RISC-V SoC SD path.  A minimal PIO driver:

  1. FDT: match `snps,dw-mshc` / `starfive,jh7110-mmc` under `/soc`, read its
     `reg` base (the R-P57 `fdt.c` walker already extracts `reg` bases -- add the
     node-name/compatible match).
  2. Card init: CMD0 (idle) -> CMD8 (IF cond) -> ACMD41 (OCR, wait ready) ->
     CMD2/CMD3 (CID/RCA) -> CMD9 (CSD, capacity) -> CMD7 (select) -> CMD16 (set
     512-byte block len).
  3. `mmc_strategy(blkno, buf, rw)`: CMD17 (READ_SINGLE) / CMD24 (WRITE_SINGLE)
     with the FIFO drained/filled in PIO (no DMA needed for the milestone).
  4. `bdev_strategy` probes mmc first, then virtio, then the RAM disk.

Crib: the SD Physical Layer Simplified Spec (command set) + Linux
`drivers/mmc/host/dw_mmc.c` (register map: CMD, CMDARG, RINTSTS, STATUS, FIFO) +
U-Boot `drivers/mmc/` (a smaller PIO reference).

### Option B -- NVMe over PCIe, the Unmatched fast path

NVMe is simpler *as a protocol* than SD but needs a PCIe root-complex bring-up
first (ECAM config space, BAR assignment) -- heavier for a first cut:

  1. FDT: match `pci-host-ecam-generic`, map ECAM, enumerate for class 0x0108
     (NVMe); read BAR0 (the controller registers).
  2. NVMe init: set CC.EN, create the admin SQ/CQ, `IDENTIFY`, create ONE I/O
     SQ/CQ pair.
  3. `nvme_strategy(blkno, buf, rw)`: submit a READ (opcode 0x02) / WRITE (0x01)
     I/O command, ring the SQ doorbell, poll the CQ phase bit.

Crib: the NVMe 1.4 base spec (sec 3 registers, sec 5 admin, sec 6 I/O commands)
+ the PCIe ECAM layout + Linux `drivers/nvme/host/pci.c`.

## R-P58 recommendation

Start with **Option A (dw-mmc PIO)**: SD/MMC is the near-universal RISC-V SoC
root medium, needs no PCIe bring-up, and a single-block PIO read/write is small.
The R-P57 GPT parser + DTB walker already give the partition base and (with a
node match added) the controller MMIO base -- so the mmc driver drops straight
into `bdev_strategy` and the existing blockfs/root-pivot boots on real SD.  The
on-HW proof: the SAME fw_payload.elf + GPT image on an SD card in a VisionFive 2.
