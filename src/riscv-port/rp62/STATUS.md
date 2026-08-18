# solnix riscv64 -- STATUS

Phase: **R-P62** (complete, compile + qemu-verified: qemu-system-riscv64
-machine virt, -smp 2 regressions + the -smp 8 SMP boot; the K1-addressed boot
resolved + SDHCI wired for the K1 + real CCU pokes).
Next: **R-P63** (the K1 `spacemit,k1x-emac` 1GbE net -- from-scratch from the
Linux vendor driver, no BSD crib -- + the on-HW boot when the Milk-V Jupiter
box lands: flash `rp62/fw_payload_k1.elf` (or `fw_dynamic_k1.elf` + `unix.bin`)
+ the GPT `disk.img` on an SD card and boot the physical board).

Milestone: `bash rp62/kernel/build-kernel.sh`
  -> **282 PASS assertion lines, 0 real FAIL** (R-P61's 277 + the 5 new R-P62
     assertions).  Canonical capture is `rp62/qemu-boot.log` (the build +
     -smp 2 boot + the R-P62 supplementary proofs appended via tee); the raw
     -smp 8 SMP + K1 parse is `rp62/kernel/qemu-boot-smp8.log`.  Boots
     `-bios fw_payload.elf` ONLY (NO `-kernel`) against a combined GPT
     `disk.img`.

R-P61 boot RE-CONFIRMED before starting R-P62: the rp61 `-bios fw_payload.elf`
+ GPT root + DTB parse + 8-hart SMP boots clean under -smp 2 (real OpenSBI
v1.8.1, Domain0 Next Address 0x80200000, mlsetup complete, K1 DTB PARSE PROVEN,
SMP PROVEN, ROOT-PIVOT PROVEN, init pid 1 + interactive shell, 0 panics;
277 PASS / 0 real FAIL).

## R-P62 deliverables

### R-P62.1 (HEADLINE) -- K1-addressed boot / DTB-driven load base (RESOLVED)

The R-P61 open item was the K1 load address (K1 DRAM base 0x0 vs qemu-virt's
0x80000000).  **Root-caused + resolved.**

The kernel is a fully-linked **NON-PIE** image (kernel.lds PADDR = 0x80200000;
the solaris-target binutils has no `-pie`, so `unix.elf` carries ZERO
R_RISCV_RELATIVE relocs).  Its `_start` runs **position-independently** (medany
PC-relative) -- PROVEN: a fw_payload built with FW_PAYLOAD_OFFSET=0x400000 loads
the kernel at phys 0x80400000 and reaches `mlsetup complete`.  BUT its STORED
ABSOLUTE POINTERS (vnode-ops vtables, dispatch tables) are relocated to the link
base, so the shifted boot then FAULTS the instant it calls through such a
pointer (observed: `scause=0xc` at the LINKED VA `0xffffffc0802025e4` =
`ramfs_vop_getattr`, whose physical is unmapped when loaded elsewhere).  **So
the kernel MUST load at physical 0x80200000.**

This is NOT a K1 blocker: the K1 DRAM base is 0x0 but DRAM SPANS 8 GiB
(0x0 .. 0x2_0000_0000), so 0x80200000 (2 GiB in) is valid K1 DRAM.

FIX (the anti-wedge minimum -- "read the load base, don't hardcode it"):
  * `locore.S _start` captures its ACTUAL physical load address PC-relative
    into `boot_load_pa` (a `.data` dword) before paging.
  * `mlsetup` (main.c) READS `boot_load_pa`, prints it, and compares it to the
    link base -- **load == link => LOUD "LOAD BASE OK"; mismatch => a LOUD
    WARNING** naming the fix (mk-fw-k1.sh) BEFORE the vtable fault, so an on-HW
    load-base mismatch is diagnosed, not a silent crash deep in boot (PROVEN:
    the shifted boot prints "R-P62 WARNING: load base != link base ... stored
    vtable pointers will fault otherwise" then faults).
  * The kernel is otherwise fully **DTB-driven** (RAM base/size, PLIC/CLINT/
    UART/SDHCI MMIO, hart count), so the SAME binary boots qemu-virt
    (DRAM@0x80000000) AND the K1 (DRAM@0x0, kernel@0x80200000).

K1 firmware recipes (`rp62/mk-fw-k1.sh`, both BUILT; the fw_payload boot-
verified under qemu):
  * **(A) `fw_payload_k1.elf`** -- OpenSBI@0x80000000 (valid K1 DRAM, within the
    +-2 GiB PCREL_HI20 range of the embedded payload) + FW_PAYLOAD_OFFSET=
    0x200000 -> kernel@0x80200000.  Identical to the qemu-virt build, so the
    SAME fw_payload works on the K1.  (FW_TEXT_START=0x0 + OFFSET=0x80200000 does
    NOT link -- the PC-relative `lla payload_bin` is >2 GiB -- documented.)
    BOOT-VERIFIED under qemu-virt: Domain0 Next Address 0x80200000, LOAD BASE OK,
    K1 DTB parse, ROOT-PIVOT, init pid 1.
  * **(B) `fw_dynamic_k1.elf`** -- OpenSBI@0x0 (K1 DRAM base), FW_DYNAMIC=y; the
    vendor u-boot SPL loads OpenSBI + the kernel (unix.bin @ 0x80200000)
    separately and passes the kernel address via `struct fw_dynamic_info` in a2
    (the K1's stock convention; no PC-relative embed).

Upgrade path (if a K1 ever forces load base != 0x80200000): rebuild the kernel
PIE with R_RISCV_RELATIVE + a `_start` reloc pass -- blocked today by the
solaris-target binutils lacking `-pie`.

### R-P62.2 (HEADLINE) -- SDHCI on the K1 (the illumos uts/sdhci.c seam)

The K1 MMC IP is `spacemit,k1-sdhci` -- a STANDARD SDHCI core, NOT the Synopsys
dw-mmc the R-P58/59 `dwmmc.c` targets.  Per the driver plan (docs/riscv-jupiter-
driver-plan.md sec 5) the existing illumos `uts/sdhci.c` (R-P14/15, an SDHCI-
standard register-model block driver) is register-compatible with the K1.

`kernel/sdhci.c` + `kernel/sdhci.h` (NEW): the SDHCI-standard core (reset,
CMD0/8/ACMD41/2/3/7/16 card-init, single-block PIO CMD17 read + CMD24 write),
trimmed to the `dwmmc.c` seam shape -- direct-map MMIO (KERNEL_DMAP_BASE + PA),
and the same `sdhci_set_base`/`sdhci_present`/`sdhci_probe`/`sdhci_strategy`
(blkno,buf,rw) block interface as dwmmc/vioblk.  Reuses the uts/sdhci.c register
map + SD command flow.

Wired **DTB-KIND-selected**:
  * `bdev_strategy` (vfs.c) dispatch order: virtio-blk (qemu) -> dw-mmc ->
    **SDHCI** -> RAM disk.  qemu-virt has no mmc node, so `sdhci_present()`
    stays 0 and the block layer ALWAYS uses virtio-blk -- REGRESSION-SAFE (the
    FULL ROOT-PIVOT still boots under qemu).
  * main.c binds by `fi_mmc_kind`: `FDT_MMC_DWMMC` (snps,dw-mshc) -> `dwmmc`;
    `FDT_MMC_SDHCI` (spacemit,k1-sdhci) -> `sdhci`.  The K1 no longer WRONGLY
    binds dw-mmc (the R-P58 code bound dwmmc on ANY mmc node).
COMPILE-phase for the K1 (qemu-virt has no SDHCI to run it, exactly like dwmmc):
`sdhci.o` compiles + links into `unix.elf`; the DTB-select keeps qemu on
virtio-blk (root-pivot boots).

### R-P62.3 -- K1 CCU real clock enables (from R-P61's shim)

`k1.c`'s `k1_ccu_enable()` (an R-P61 no-op poke) now does a REAL `writel()`
(KERNEL_DMAP_BASE + CCU PA) ungating the function+APB clock + deasserting the
reset for the console UART (APBC+0x00c) and SDHCI (APMU+0x054).  Guarded by
`k1_on_silicon` (set by `k1_set_silicon()` from the LIVE firmware DTB): under
qemu-virt the live DTB is qemu-virt (PLIC@0x0c000000), so `k1_on_silicon`=0 and
the writel is a no-op (a poke to 0xd4015000 would fault) -- PROVEN: "CCU pokes
stay dormant (regression-safe)".  On the Jupiter (PLIC@0xe0000000 + SDHCI) the
flag is 1 and the pokes FIRE (`k1_ccu_live_bringup()`, called from main() only
when the live DTB is the K1).  Two calibration knobs still need on-HW tuning
(the SDH clock divider + the UART baud divisor -- K1-MEMORY-MAP.md).

## Regression safety

The R-P24..R-P50 regressions run at -smp 2; the 8-hart bring-up is a dedicated
-smp 8 boot.  The K1 self-test (static blob) + the SDHCI/CCU device paths are
dormant on qemu-virt (no live device touched, DTB-selected off).  All 282
assertions green, 0 real FAIL.

## Files added/changed in rp62 (vs rp61)

  * `kernel/sdhci.c` + `kernel/sdhci.h` (NEW): the SDHCI-standard SD/eMMC driver
    for the K1 (spacemit,k1-sdhci), behind the bdev_strategy seam.
  * `kernel/vfs.c`: `bdev_strategy` dispatches to `sdhci_strategy` (DTB-selected).
  * `kernel/main.c`: reads `boot_load_pa` + the load==link diagnostic; binds the
    SD/eMMC driver by `fi_mmc_kind` (dwmmc vs sdhci); live-K1 detect + CCU pokes.
  * `kernel/locore.S`: captures the actual physical load base into `boot_load_pa`.
  * `kernel/k1.c`: real guarded `k1_writel()` CCU poke + `k1_set_silicon` +
    `k1_ccu_live_bringup`.
  * `kernel/build-kernel.sh`: compiles + links `sdhci.o`; the 5 R-P62 assertions.
  * `mk-fw-k1.sh` (NEW): builds the K1 `fw_payload_k1.elf` + `fw_dynamic_k1.elf`.
  * `fw_payload_k1.elf` + `fw_dynamic_k1.elf` (NEW): the K1-addressed firmware.
  * `K1-MEMORY-MAP.md`: the load-address question RESOLVED (R-P62 section).
  * `libc/build-libc.sh`: `L=$R/rp62/libc` (reseed fix).

The full-arc reference is `rp52/RISCV-PORT-SUMMARY.md`.
