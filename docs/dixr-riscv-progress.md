# dixr readiness report -- RISC-V solnix on the Milk-V Jupiter (SpacemiT K1)

Target: solnix as a daily-driver with COSMIC on the Milk-V Jupiter (SpacemiT K1,
PowerVR BXE-2-32 GPU).  This session's work is board-independent (QEMU) because
the board is hardware-gated.

## 1. R-P63 baseline: BOOTS (y)

R-P63 boots like hardware under `qemu-system-riscv64 -M virt`, `-bios
fw_payload.elf` (OpenSBI + the embedded kernel, NO `-kernel`) against a combined
GPT `disk.img`.  Canonical evidence: `src/riscv-port/rp63/qemu-boot.log` --
484 PASS assertion lines, 0 real FAIL, 0 panics, `-smp 2` regressions +
`-smp 8` SMP.  Real-OS surface: OpenSBI fw_payload, GPT root by TYPE GUID,
DTB-driven devices, init/shell/27-coreutils/libc subset, persistent blockfs on
virtio-blk, dw-mmc + SDHCI, 8-hart SMP, K1 DTB (PLIC/SDHCI/pxa-uart), the
k1x-emac 1GbE net driver, and the compile+link-complete PowerVR BXE stack.

NOTE: R-P63 was NOT rebuilt this session -- the full rebuild is not reproducible
from git on a fresh node (missing kernel sources + gitignored prebuilt userland
artifacts; see BLOCKER in rp64/STATUS.md).  The baseline is the committed
canonical boot log.

## 2. The concrete advance landed this session -> R-P64 (graphics path)

**New capability: a virtio-gpu 2D display driver -- the RISC-V analog of the x86
drm-port's first scanout bring-up.**  This is the highest-leverage gap between
R-P63's headless minimal OS and the COSMIC daily-driver goal: R-P63 had NO
framebuffer/scanout/DRM node; COSMIC + llvmpipe (the software-render desktop the
Jupiter hardware assessment leads with) needs one to present into.  On QEMU the
DRM-scanout analog is virtio-gpu, exactly as virtio-blk is the QEMU analog of
the K1's SDHCI/dw-mmc block device.

Delivered (`src/riscv-port/rp64/kernel/`):
  * `virtio_gpu.c` + `virtio_gpu.h` -- the driver.  virtio-mmio transport
    identical to `virtio_blk.c` (probe/negotiate/split-virtqueue/kick/poll);
    the device layer is the virtio-gpu controlq + a 6-step scanout bring-up
    (GET_DISPLAY_INFO -> RESOURCE_CREATE_2D -> RESOURCE_ATTACH_BACKING ->
    SET_SCANOUT -> TRANSFER_TO_HOST_2D -> RESOURCE_FLUSH) + a `virtio_gpu_flush()`
    per-frame present + `virtio_gpu_fb()` framebuffer accessors.
  * `gpu_harness.c` + `start.S` + `harness.ld` + `build-gpu-harness.sh` -- a
    standalone bare-metal harness that runs the driver's EXACT bring-up path
    against QEMU's real `-device virtio-gpu-device`.

QEMU-verified: `qemu-system-riscv64 -M virt -device virtio-gpu-device` boots the
harness, which probes the GPU, negotiates, brings up the controlq, runs the
6-step scanout bring-up, draws a test pattern, and presents frames -- see
`src/riscv-port/rp64/kernel/gpu-qemu-boot.log` (the `[GPU:...]` markers +
`R-P64 PASS`).  A QMP screendump captured the LIVE scanout to
`src/riscv-port/rp64/kernel/scanout.png` (also `artifacts/riscv-virtio-gpu-scanout.png`):
a 1024x768 host display whose red/green/blue/white quadrants match the drawn
framebuffer byte-for-byte -- proof the guest fb reached the host scanout.  The
driver source compiles UNCHANGED into the kernel (direct map) or the harness
(`-DGPU_HARNESS`, identity map).  (QEMU flag: `-global
virtio-mmio.force-legacy=false` -- qemu 11 virt defaults virtio-mmio to legacy
v1; the driver, like virtio_blk.c, uses the modern v2 layout.)

Not done (deferred, seam ready): linking `virtio_gpu.c` into `unix.elf` +
`run_virtio_gpu()` in `main.c` -- blocked by the R-P63-rebuild BLOCKER, not by
the driver.  A one-line add to `build-kernel.sh` + a `run_virtio_gpu()` call
after `run_virtio_blk()` once the build chain is reproducible.

## 3. K1 real-hardware readiness punch-list (for the day the board arrives)

What remains for solnix to boot + run COSMIC on the REAL Milk-V Jupiter.

### A. SD-card image -- build-ready? PARTIAL
  * `fw_payload_k1.elf` (recipe A: OpenSBI@0x80000000 + kernel@0x80200000,
    identical to the qemu-virt build) and `fw_dynamic_k1.elf` (recipe B:
    OpenSBI@0x0 + u-boot SPL loads the kernel separately) are BUILD-READY via
    `rp62/mk-fw-k1.sh` -- both boot-verified under QEMU.  Load-base issue
    RESOLVED (non-PIE kernel must load at phys 0x80200000, which is valid K1
    DRAM 2 GiB in; the kernel reads its actual load base from OpenSBI and loudly
    checks it).
  * `disk.img` (GPT root) is build-ready (the same combined GPT image R-P62/63
    boot under QEMU; root matched by TYPE GUID).
  * REMAINS: an actual SD-card layout for the Jupiter's boot ROM -- the K1 boot
    ROM expects a specific partition/offset scheme (BootROM -> SPL -> u-boot ->
    OpenSBI).  The exact flashing recipe (dd offsets, the u-boot env, the K1
    partition table) must be produced against the board's stock image; NOT yet
    written (board-gated).

### B. K1 FW blob dependency -- NOT satisfied (external blob)
  * The K1 boot chain needs the SpacemiT BootROM's expected first-stage
    (TF-A / the vendor SPL) + the DDR training blob.  These are SpacemiT-supplied
    binaries (the "FW blob"), not in this tree.  REMAINS: obtain the Jupiter's
    stock SPL + DDR blob (from the Bianbu/Milk-V vendor image) and confirm our
    OpenSBI+kernel chain-loads behind them.  Hard external dependency.

### C. Runtime register bring-up -- SCAFFOLDED, needs on-silicon calibration
  * The K1 CCU clock-ungate path (`k1.c` `k1_ccu_live_bringup`, guarded by
    `k1_on_silicon`) ungates UART0 (APBC+0x00c), SDHCI (APMU+0x054), and emac
    (APMU+0x03c) -- dormant under QEMU, fires on silicon.  The register bases /
    bit fields are from OpenSBI spacemit/k1.h + k1-x.dtsi.
  * REMAINS (calibration knobs -- hardware is never ideal on paper):
      - UART baud divisor (pxa-uart input clock ~14.857 MHz, board-specific)
      - SDHCI clock divider (~400 kHz ident -> ~25/50 MHz transfer)
      - RGMII tx/rx clock-delay (the SpacemiT PHY-timing glue; `rgmii-id` default)
      - the station MAC (fixed locally-administered until OTP/DTB local-mac-address)
      - the CCU offsets/bit fields verified against the live board
  * These are measured/tuned on first boot; the paths exist and are gated off
    under QEMU so they cannot regress the emulated boot.

### D. Console + storage on silicon -- READY, unverified
  * Console: the K1 console is a 16550-variant pxa-uart (shift 2) @0xd4017000;
    the kernel prints through the SBI legacy console, so as long as the board's
    OpenSBI console is up, solnix prints.  A DTB-selected raw-UART path
    (FDT_UART_PXA, shift-2) is recorded for when SBI isn't the console.
  * Storage: SDHCI (`sdhci.c`, `spacemit,k1-sdhci` @0xd4280000) is the R-P62
    root device on silicon (CMD17 read / CMD24 write), DTB-kind-selected; QEMU
    stays virtio-blk (regression-safe).  Needs the clock divider (C) on silicon.

### E. Networking on silicon -- READY, unverified
  * The k1x-emac 1GbE driver (`emac.c`, `spacemit,k1x-emac` @0xcac80000, PLIC
    IRQ 109) is compile+link-complete + DTB-selected + dormant under QEMU.
    Needs the RGMII delay + MAC (C) on silicon.  A GLDv3 mac-registration shim
    is the remaining software layer to make it a real illumos NIC (the
    net-device seam is in place for it).

### F. The display path on silicon -- R-P64 gives the SOFTWARE analog; HW is PowerVR
  * R-P64's virtio-gpu driver is the QEMU display analog.  On the REAL Jupiter
    there is NO virtio-gpu -- the display is the PowerVR BXE-2-32 GPU (the stack
    is compile+link-complete in this tree, the Jupiter's exact GPU).
  * REMAINS for a framebuffer on silicon:
      - the PowerVR firmware blob (the RGX firmware the BXE loads -- an external
        IMG/SpacemiT binary, NOT in this tree; hard dependency, like the DDR blob)
      - a DRM/KMS modeset path OR the K1's simple-framebuffer (if u-boot leaves a
        `simple-framebuffer` DTB node, solnix can present into it with NO GPU
        driver -- the fastest first-pixels path on silicon, and the analog of
        R-P64's scanout).  Recommend: wire a `simple-framebuffer` consumer next
        (cheap, no PowerVR firmware) to get first pixels, then the PowerVR
        accelerated path (multi-month) for COSMIC compositing.
  * COSMIC itself runs on llvmpipe (software render) once ANY framebuffer exists
    (simple-framebuffer or the PowerVR KMS scanout) -- the x86/aarch64 COSMIC
    stack is already built; the RISC-V gap is the framebuffer + the userland
    breadth (a full libc + the Nix cross), not COSMIC itself.

### G. Userland breadth for the Nix/COSMIC stack -- the OTHER big gap
  * R-P63 has a 27-coreutils subset + a hand-grown libc.a, NOT a full libc, NOT
    a /bin/sh that can drive a Nix session, NOT a nixpkgs-illumos riscv64 cross.
  * REMAINS (independent of the board): a real libc (the illumos libc port to
    riscv64), the seed toolchain hosted ON solnix-riscv64, and a
    nixpkgs-illumos riscv64 cross so the COSMIC stack (already built for
    x86/aarch64) can be cross-built for riscv64.  This is the largest remaining
    software effort and is board-independent -- a good next QEMU rung after the
    framebuffer.

## Punch-list summary (the day the board is wired)

  1. Get the SpacemiT FW blobs (SPL + DDR training + PowerVR RGX firmware) from
     the Jupiter vendor image -- hard external dependency (B, F).
  2. Produce the SD-card flashing recipe (partitions/offsets/u-boot env) against
     the board's boot ROM (A).
  3. Boot `fw_payload_k1.elf` + `disk.img`; calibrate UART baud / SDHCI divider
     / RGMII delay / MAC on silicon (C, D, E).
  4. First pixels: a `simple-framebuffer` consumer (cheap) before the PowerVR
     accelerated path (F).
  5. Board-independent, in parallel: full libc + seed toolchain + nixpkgs riscv64
     cross so COSMIC/llvmpipe can be built for riscv64 (G).

## Reproducibility clarification (orchestrator)
The R-P64 agent flagged "R-P63 not reproducible from git" -- but that assessed only the SPARSE phase-delta
dir src/riscv-port/rp63/ (10 files, the K1 delta). The AUTHORITATIVE full RISC-V tree is src/riscv/ (330
.c/.S in git, incl src/riscv/uts/ = 116 files = the full kernel: locore/SMP/virtio_blk/sdhci/dwmmc/etc.).
The .gitignore correctly excludes only BUILD OUTPUTS (*.o, uts/unix, *.dtb, *.img, toolchain/). So R-P63 is
SUBSTANTIALLY in git. The genuine narrower gap: the exact rp63 BUILD WIRING (which src/riscv/ sources + the
seed toolchain build order) isn't a single reproducible `build.sh` from a clean checkout, and the prebuilt
seed userland (libc.a/ld.so.1 -- build outputs) must be rebuilt. FOLLOW-UP (before the K1 board): write a
reproducible src/riscv/build-all.sh (clean-checkout -> seed toolchain -> uts/unix + userland -> fw_payload +
disk.img) so R-P63/R-P64 rebuild deterministically -- and link virtio_gpu.c (R-P64) into unix.elf via that.
