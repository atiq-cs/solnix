# solnix riscv64 -- R-P64 STATUS

Phase: **R-P64** (the graphics path -- a virtio-gpu 2D display driver, the
RISC-V analog of the x86 drm-port's first scanout bring-up, QEMU-verified via a
standalone bare-metal harness on `qemu-system-riscv64 -M virt -device
virtio-gpu-device`).

Baseline confirmed first: **R-P63 boots** (the canonical `rp63/qemu-boot.log`:
484 PASS assertion lines, 0 real FAIL, 0 panics -- the K1 `spacemit,k1x-emac`
1GbE driver + SDHCI + 8-hart SMP + GPT root + DTB parse, `-bios fw_payload.elf`
+ GPT `disk.img`, `-smp 2` regressions + `-smp 8` SMP).

## Why the graphics path (the highest-leverage gap toward COSMIC)

R-P19..R-P63 built a real minimal OS (OpenSBI fw_payload, GPT root, DTB devices,
init/shell/coreutils/libc subset, virtio-blk/SDHCI storage, k1x-emac net) and
the full PowerVR BXE-2-32 GPU stack (compile+link-complete, the Jupiter's exact
GPU).  The biggest gap between that and the COSMIC daily-driver goal is a
**display path**: R-P63 has NO framebuffer, NO scanout, NO DRM-analog.  COSMIC +
llvmpipe (the software-render desktop the Jupiter hardware assessment leads
with, since the PowerVR HW-accel path is multi-month) needs a framebuffer to
present into.  On QEMU the analog of a DRM scanout is **virtio-gpu** (exactly as
virtio-blk is the QEMU analog of the SDHCI/dw-mmc block device).  R-P64 brings
that up.

## R-P64 deliverable -- the virtio-gpu 2D display driver

`kernel/virtio_gpu.c` + `kernel/virtio_gpu.h` (NEW): a from-scratch virtio-gpu
driver over the qemu-virt virtio-mmio transport.  The MMIO transport is
deliberately identical to `virtio_blk.c` (R-P52/53) -- probe
MagicValue/Version==2/DeviceID, negotiate 0 features, one split virtqueue,
kick via QueueNotify, poll the used ring -- so it drops behind the same seam.
virtio-gpu differs only in the DEVICE layer: DeviceID==16, a controlq carrying
`virtio_gpu_ctrl` commands, and a host-visible framebuffer.

The 6-step scanout bring-up (`virtio_gpu_init`, virtio spec v1.2 sec 5.7):

  1. `GET_DISPLAY_INFO`        -- read scanout 0's preferred rect (w x h)
  2. `RESOURCE_CREATE_2D`      -- a B8G8R8X8 host resource
  3. `RESOURCE_ATTACH_BACKING` -- point it at our guest framebuffer (KVTOP(fb))
  4. `SET_SCANOUT`             -- bind the resource to display 0
  5. `TRANSFER_TO_HOST_2D`     -- copy guest fb into the host resource
  6. `RESOURCE_FLUSH`          -- present it

`virtio_gpu_flush()` is the per-frame present path (TRANSFER + FLUSH) a
compositor calls each frame.  `virtio_gpu_fb()`/`_width()`/`_height()` expose the
framebuffer -- the "DRM node" a console or a llvmpipe/Wayland compositor draws
into.

## QEMU verification -- the standalone R-P64 harness

Because the full R-P63 kernel rebuild needs the illumos riscv64 cross-toolchain
+ the whole R-P19..R-P63 userland artifact chain (NOT reproducible from git on a
fresh node -- see BLOCKER below), R-P64 proves the driver with a **standalone
bare-metal harness** that runs the driver's EXACT bring-up path against QEMU's
real virtio-gpu device:

  * `kernel/gpu_harness.c` -- M-mode, `-bios none`, no MMU/SBI, 16550 UART; calls
    `virtio_gpu_init()`, draws an RGBW-quadrant + diagonal test pattern, then
    `virtio_gpu_flush()` twice (proving the per-frame present path).
  * `kernel/start.S` + `kernel/harness.ld` -- entry/park/bss-zero, linked at
    0x80000000 (128 MiB, fb+rings in .bss).
  * `kernel/build-gpu-harness.sh` -- builds with a bare-metal
    `riscv64-unknown-elf` gcc (freestanding `-nostdlib`, no libc needed) and
    boots `qemu-system-riscv64 -M virt -device virtio-gpu-device`.

The driver source compiles UNCHANGED into the kernel (KVTOP/KERNEL_DMAP_BASE
from `mmu_riscv.h`, the direct map) or the harness (`-DGPU_HARNESS`, identity
map, PA==VA under `-bios none` -- exactly how the kernel's early virtio_blk
probe uses the direct map for ring PAs).

Canonical capture: `kernel/gpu-qemu-boot.log` -- the `[GPU:...]` markers +
`R-P64 PASS`.  A `screendump.py` (QMP) captures the live scanout to a PPM/PNG:
`kernel/scanout.png` is the actual 1024x768 host display, whose R/G/B/W
quadrants match the drawn framebuffer byte-for-byte (verified) -- proof the
guest fb reached the host scanout through ATTACH_BACKING + TRANSFER_TO_HOST_2D
+ SET_SCANOUT + FLUSH.

NOTE on the QEMU flag: qemu 11 `-M virt` exposes virtio-mmio as legacy
(Version 1) by default; the driver (like `virtio_blk.c`) uses the modern
(Version 2) register layout, so the harness boots with
`-global virtio-mmio.force-legacy=false`.  The kernel's virtio_blk path uses
the same modern layout, so the same flag applies there.

## Wiring into the kernel (the seam is ready, not yet linked)

`virtio_gpu.c` is written to link into `unix.elf` exactly like `virtio_blk.c`:
add `$XGCC $CFLAGS -c virtio_gpu.c` to `build-kernel.sh`, add a
`run_virtio_gpu()` call after `run_virtio_blk()` in `main.c`, and (for the
DTB-discovered MMIO base on a real board) call `virtio_gpu_set_mmio_base()` from
the same FDT path that already feeds `virtio_blk_set_mmio_base()`.  That kernel
link is deferred until the R-P63 build chain is reproducible on the node (the
BLOCKER); the driver + the QEMU proof stand on their own.

## BLOCKER -- the R-P63 full kernel rebuild is not reproducible from git

The committed tree has the R-P63 kernel SOURCES for only 8 files
(`main.c`, `fdt.c`, `k1.c`, `emac.c`, `sdhci`-headers, `gen_k1_dtb.py`,
`build-kernel.sh`).  `build-kernel.sh` compiles ~35 `.c`/`.S` files
(`locore.S`, `sbi.c`, `hat.c`, `proc.c`, `disp.c`, `console.c`, `virtio_blk.c`,
`vfs.c`, ...) and links against prebuilt userland artifacts
(`rp40/libc/libc.a`, `rp38/ldso/ld.so.1`, `rp21/hello/hello.dyn`, the `.dyn`
coreutils) that are `.gitignore`d (`*.elf`, `*.img`, `**/toolchain/`, ...).
Those files existed only on the (since-wiped) node's `/root/riscv-port/`.  A
full rebuild therefore means reproducing the entire R-P19..R-P63 chain
(cross-toolchain -> libc -> ld.so.1 -> userland -> kernel), which is a
multi-hour, many-GB effort and off the critical path for the graphics rung.

Recommended fix (orchestrator): commit the R-P63 `rp63/kernel/*.c|*.S` full
source set + the `rp*/…` prebuilt userland artifacts needed by
`build-kernel.sh` (or a from-source `build-all.sh` that rebuilds them), so any
node can `bash build-kernel.sh` from git alone.  Until then the R-P64 harness is
the reproducible QEMU proof.
