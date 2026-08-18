# solnix riscv64 -- STATUS

Phase: **R-P63** (complete, compile + qemu-verified: qemu-system-riscv64
-machine virt, -smp 2 regressions + the -smp 8 SMP boot; the K1
`spacemit,k1x-emac` 1GbE NIC driver from-scratch, compiled + linked +
DTB-selected + dormant-under-qemu, exactly like SDHCI in R-P62).
Next: **R-P64** (the on-HW boot when the Milk-V Jupiter box lands -- flash
`rp63/fw_payload_k1.elf` + the GPT `disk.img` on an SD card and boot the
physical board: the SDHCI root + the k1x-emac 1GbE come live, calibrate the
RGMII clock-delay + the SDH divisor + the UART baud on the silicon).

Milestone: `bash rp63/kernel/build-kernel.sh`
  -> **286 PASS assertion lines, 0 real FAIL** (R-P62's 282 + the 4 new R-P63
     assertions).  Canonical capture is `rp63/qemu-boot.log` (the full build +
     the -smp 2 boot + the -smp 8 SMP + K1 parse + all assertions).  Boots
     `-bios fw_payload.elf` ONLY (NO `-kernel`) against a combined GPT
     `disk.img`.

R-P62 boot RE-CONFIRMED before starting R-P63: the rp62 `-bios fw_payload.elf`
+ GPT root + DTB parse + K1-addressed load base (LOAD BASE OK) + SDHCI +
8-hart SMP boots clean under -smp 2 (282 PASS / 0 real FAIL in
`rp62/qemu-boot.log`).

## R-P63 deliverables

### R-P63.1 (HEADLINE) -- the k1x-emac driver (the K1 1GbE MAC)

`kernel/emac.c` + `kernel/emac.h` (NEW): a from-scratch illumos driver for the
SpacemiT K1 `spacemit,k1x-emac` 1GbE MAC (the Milk-V Jupiter's on-board NIC).
The k1x-emac is a Synopsys DesignWare GMAC-family MAC (the DW-GMAC MAC block @
0x0000 + a DMA engine @ 0x1000 with descriptor rings) wrapped with SpacemiT
glue (a small PHY-interface / clock-mux register block).  Cribbed from the
Linux vendor driver `drivers/net/ethernet/spacemit/k1x_emac.c` -- **NO BSD
crib** (the DW-GMAC MAC/DMA/descriptor model is well-known):

  * **MAC init**: DW-GMAC DMA soft-reset (BUS_MODE.SWR, self-clearing), station
    MAC address (ADDR0_HIGH/LOW), the SpacemiT PHY-interface select (RGMII for
    the Jupiter 1GbE PHY), MAC config (full-duplex GMII, RE|TE, jabber-disable,
    burst), frame filter.
  * **TX + RX DMA descriptor rings**: the DW-GMAC "normal" descriptor format
    (des0 status/OWN, des1 control+length, des2 buffer phys, des3 next-desc
    phys), chained rings statically allocated in the kernel image (their phys
    is KVTOP(va) under the direct map, which the DMA reads); RX handed to the
    DMA (OWN), TX filled on `emac_tx`.
  * **RX/TX paths**: `emac_tx` copies a frame into the current TX buffer, marks
    FS|LS|IC|OWN, kicks the TX poll demand; `emac_rx` polls the current RX
    descriptor (OWN cleared = DMA done), copies the frame out (frame-length
    from des0), recycles the descriptor + kicks the RX poll demand.
  * **MII/MDIO PHY access**: `mdio_read`/`mdio_write` over GMAC_GMII_ADDR/DATA
    (busy-poll), a PHY scan (addresses 0..31), auto-negotiation restart.
  * **the interrupt handler**: `emac_intr` reads DMA_STATUS, acks (write-1-
    clear) the normal/abnormal summary so the PLIC line deasserts (routed via
    the K1 PLIC, DTB-driven like the rest -- `fi_net_irq`).

Wired behind a minimal **net-device abstraction** (`emac_set_base`/`emac_probe`/
`emac_present`/`emac_tx`/`emac_rx`/`emac_intr`) -- the shape a later illumos
GLDv3 mac-registration shim (mac_register -> mc_start/mc_tx/mac_rx/mc_getcapab)
can adopt with no change to the register/DMA core, exactly as the dwmmc/sdhci
block seam is for storage.  GLDv3 is not up in this port yet, so this
net-device seam is the storage seam's networking analogue.

COMPILE-phase for the K1 (qemu-virt has no k1x-emac to run it, exactly like
sdhci/dwmmc): `emac.o` compiles + links into `unix.elf` (emac_probe/emac_tx/
emac_rx/emac_intr + the rings/buffers are in the readelf symbol table).

### R-P63.2 -- DTB-driven NIC select, dormant-under-qemu (REGRESSION-SAFE)

  * `fdt.c`/`fdt.h`: the SAME forward-walk FDT parser now captures an
    `ethernet@`/`gmac@`/`emac@` node's `compatible` (-> `FDT_NET_K1X_EMAC` for
    `spacemit,k1x-emac`), `reg` base (`fi_net_base`), and `interrupts` PLIC
    number (`fi_net_irq`).
  * `main.c`: after the SDHCI bind + the K1 CCU live-bringup, binds the NIC by
    `fi_net_kind`: `FDT_NET_K1X_EMAC` -> `emac_set_base` + `emac_probe`.
    qemu-virt has NO `ethernet@` node (`fi_net_base == 0`), so
    `emac_set_base()` is never called, `emac_present()` stays 0, NO k1x-emac
    MMIO is ever touched, and the FULL R-P62 boot (root-pivot on virtio-blk)
    is unbroken under qemu -- DTB-selected off, dormant, regression-safe
    (PROVEN: "no ethernet@ node in the DTB ... the k1x-emac driver stays
    dormant, no MMIO touched").

### R-P63.3 -- the K1 DTB carries the NIC node + the SAME walker parses it

`gen_k1_dtb.py` (+ the regenerated `k1_dtb.h`) now emits `ethernet@cac80000`
(`spacemit,k1x-emac`, PLIC IRQ 109, phy-mode rgmii-id).  `run_k1_fdtest`
(k1.c) parses it through the SAME `fdt_discover()` the live boot uses and
asserts the NIC topology (base 0xcac80000 + `FDT_NET_K1X_EMAC`), proving the
DTB-driven NIC select end-to-end (PROVEN: "K1 NIC PARSE PROVEN").

### R-P63.4 -- the K1 CCU emac clock-enable (from R-P62's SDHCI clock)

`k1.c`'s `k1_ccu_live_bringup()` now ungates the k1x-emac NIC clock
(APMU+0x03c) with the SAME guarded `k1_writel()` (gated by `k1_on_silicon`,
set from the LIVE firmware DTB), so it is a no-op under qemu-virt (not K1
silicon) and the writel FIRES on the Jupiter before `emac_probe()` touches the
MAC MMIO -- exactly like R-P62's SDHCI clock (APMU+0x054).  The CCU shim in
`run_k1_fdtest` also prints the emac-clock enable (compile-phase).

### virtio-net qemu-runnable proof -- DEFERRED (documented, per the task)

The optional live virtio-net path (a real RX/TX of an ARP/loopback frame under
qemu to prove the net-device seam end-to-end) was NOT added: a full virtio-net
split-virtqueue driver (feature negotiation + RX/TX buffer rings + a way to
inject/receive a frame + a qemu `-device virtio-net-device`) is a second
~500-line driver, not the "cheap" bar the task set.  The R-P63 deliverable is
the k1x-emac compile-proof + the DTB-select + the dormant-under-qemu clean
boot -- exactly like SDHCI in R-P62 (compile-phase; the real frames flow on
the Jupiter).  The net-device seam (emac_set_base/probe/present/tx/rx/intr) is
in place, so a later virtio-net sibling behind the SAME seam is an add-on when
a qemu-runnable net proof is wanted.

## Regression safety

The R-P24..R-P50 regressions run at -smp 2; the 8-hart bring-up is a dedicated
-smp 8 boot.  The K1 self-test (static blob) + the SDHCI/CCU/emac device paths
are dormant on qemu-virt (no live device touched, DTB-selected off).  All 286
assertions green, 0 real FAIL.

## Files added/changed in rp63 (vs rp62)

  * `kernel/emac.c` + `kernel/emac.h` (NEW): the k1x-emac 1GbE MAC driver for
    the K1 (spacemit,k1x-emac), behind the net-device seam.
  * `kernel/fdt.c` + `kernel/fdt.h`: the FDT walker captures an ethernet@ node
    (`fi_net_base`/`fi_net_irq`/`fi_net_kind`, `FDT_NET_K1X_EMAC`).
  * `kernel/main.c`: binds the NIC by `fi_net_kind` (FDT_NET_K1X_EMAC -> emac);
    dormant under qemu (no ethernet@ node).
  * `kernel/k1.c`: the K1 CCU emac clock-enable (APMU+0x03c) in
    `k1_ccu_live_bringup` + the shim; `run_k1_fdtest` asserts the k1x-emac node.
  * `kernel/gen_k1_dtb.py` + `kernel/k1_dtb.h`: the K1 DTB now carries
    `ethernet@cac80000` (spacemit,k1x-emac, PLIC IRQ 109).
  * `kernel/build-kernel.sh`: compiles + links `emac.o`; the 4 R-P63
    assertions; reseed fix -- `K`/`U`/the libc call/the coreutils artifacts
    all repointed rp62 -> rp63 (the reseed had left them pointing at rp62).
  * `libc/build-libc.sh`: `L=$R/rp63/libc` (reseed fix).

The full-arc reference is `rp52/RISCV-PORT-SUMMARY.md`.

## Calibration knobs still open on the Jupiter (hardware is never ideal on paper)

  * The RGMII tx/rx clock-delay (the SpacemiT glue PHY-timing block) -- the
    exact delay-line config is board-specific; `phy-mode = "rgmii-id"` in the
    DTB is the default, tuned on the silicon.
  * The station MAC address -- `emac_probe()` uses a fixed locally-administered
    MAC until the board OTP / the DTB `local-mac-address` supplies the real
    per-board address.
  * The SDH clock divider + the UART baud divisor (carried over from R-P62).
