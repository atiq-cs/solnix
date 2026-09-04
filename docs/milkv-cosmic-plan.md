# The Milk-V Jupiter COSMIC desktop: the revised plan

The COSMIC-on-riscv64 feasibility study (`docs/cosmic-riscv64-feasibility.md`)
changed the shape of this goal, so this supersedes the sequencing implied by
`docs/riscv-jupiter-driver-plan.md` (whose per-driver crib analysis remains
correct and is still the reference for board bring-up).

## What changed

The old assumption was that the desktop stack would be the hard part on RISC-V.
It is not. Cross-builds, not arguments:

| Component | State |
|---|---|
| Rust `riscv64gc-unknown-illumos` target | works (JSON + `-Zbuild-std`, full std in 13s) |
| libcosmic 1.0.0 | 359/359 rlibs EM_RISCV, 426 crates, **zero patches** |
| smithay (full backend set) | EM_RISCV rlib |
| Mesa lavapipe + llvmpipe | 1124/1124 targets, **zero patches** |
| `cosmic-term` | 58 MB riscv64 ELF that **runs** |
| Our existing illumos patch set | transfers unchanged (zero `target_arch` predicates) |

So the desktop is portable. Two things gate it, and they are independent of each
other, which is what makes the plan parallelisable.

## The two real gates

**Gate A -- the illumos riscv64 userland (libc + crt + a socket layer).** The
critical path. Measured properly in `docs/riscv64-libc-rust-abi-gap.md`, which
*corrected* the earlier 12-symbol framing:

* The ABI surface is **sixteen** symbols, not twelve (`__major`/`__minor`/
  `__makedev` come from the libc crate; `__tls_get_addr` was masked by glibc's
  `ld.so` during cross-linking and only appears on a native link).
* **Six of them are not libc at all** -- the `__xnet_*` set lives in **libsocket**.
  This is a libsocket port as much as a libc port.
* 8 of the 10 "required libraries" are **link-satisfying only** (`libposix4` is a
  compatlink to `librt`, itself a whole-library filter on libc). Only libsocket and
  libnsl need real code.
* **8 of the 16 are already implemented for real** (`src/riscv/libc/port/illumos_abi.c`,
  every entry tagged `[REAL]`/`[REAL/1THREAD]`/`[ENOSYS]`), and a real `println!()`
  binary links against them and gets far enough into std's init to call
  `stack_getbounds` successfully.
* **The true blocker underneath is bigger than libc: the kernel has no socket layer
  and no IP stack** (21 syscalls, none of illumos's nine socket calls; `vionet.c`
  sends one hand-built ARP frame). All seven `__xnet_*` are MISSING-AT-KERNEL, so
  they cannot honestly be implemented before that exists.

**And one kernel change is on the critical path right now: the `tp` collision.**
RISC-V reserves `tp` for the userland thread pointer; our kernel repurposes it as
the hart index (`uts/proc.c` does `mv tp, hartid`). Rust TLS cannot work until `tp`
belongs to userland and the hart id moves to a CSR. Cheap to fix now, expensive
after more code depends on it -- see `docs/riscv64-crt-rust-startup.md`.

**Gate B -- scanout (pixels on the monitor).** Needs **no hardware**: QEMU
virtio-gpu exercises the whole path, and our R-P64 `virtio_gpu.c` already does the
device half (QEMU-verified guest framebuffer -> host display). What is missing is
the OS half (a mmap-able framebuffer node) and the compositor half (a ~250-line
smallvil framebuffer backend). Contract fully specified in
`docs/riscv64-scanout-seam.md`.

## Sequencing (three independent tracks)

```
Track 1  Gate B: scanout seam in QEMU        no hardware   -> visible desktop path
Track 2  Gate A: riscv64 libc + crt          no hardware   -> native execution
Track 3  Board bring-up on the Jupiter       NEEDS BOARD   -> real silicon
```

Tracks 1 and 2 need no board and are the reason this is not blocked on hardware.

### Track 3 (the board) -- ordered, from `riscv-jupiter-driver-plan.md`

Prerequisites are **DONE**: the corrected K1 DTB (PLIC not AIA, 8 harts,
`spacemit,k1-x-sdhci`, the real SpaceMiT UART bind strings) and table-driven device
matching in `fdt.c`, both verified (dtc clean, DTB decompile-checked, riscv64
cross-compile clean).

| Checkpoint | Work | Effort |
|---|---|---|
| **"it prints"** | corrected DTB + console bind (done) -> fw_payload on the board -> console banner | ~1 wk |
| **"it reaches a shell"** | K1 clock/reset shim (§6, no BSD crib) + wire the existing `uts/sdhci.c` to `spacemit,k1-x-sdhci` -> boot off eMMC/microSD | ~2 wk |
| **"pixels on HDMI"** | inherit the U-Boot framebuffer if present (3-5 d) else port the custom SpaceMiT DPU (2-3 wk) | 1-3 wk |

Network (the custom `spacemit,k1x-emac`, no BSD crib, ~2-3 wk) is deliberately
deferred -- a USB-Ethernet dongle or offline work covers the gap.

## What we need from the hardware to proceed on Track 3

1. **A USB-to-UART serial adapter on the K1 debug UART.** Non-negotiable: the
   console is how every early-boot failure is diagnosed. (Every aarch64 advance
   this project made came from reading a console.)
2. **Whether the board boots its stock vendor image.** Confirms U-Boot/OpenSBI are
   healthy, and -- critically -- tells us whether U-Boot leaves a live framebuffer.
   That single fact decides 3-5 days vs 2-3 weeks for "pixels on HDMI".
3. **Reachability**: whether the board can be driven directly, or whether the
   maintainer runs a handed-over runbook.

## The GPU, stated plainly

The PowerVR BXE-2-32 will not be accelerating this desktop. No BSD driver exists;
Imagination's stack is proprietary (closed userspace + signed firmware); the open
Mesa `powervr` + kernel DRM are young and Linux-only. We do have the *userspace*
Vulkan driver linking with the BXE-2-32 device table (`libvulkan_powervr_mesa.so`,
zero-phantom, dlopen-able -- `src/drm-port/powervr/POWERVR-STATUS.md`), but the
kernel DRM node does not exist and would be a multi-quarter port.

**Therefore: llvmpipe software rendering + scanout-only display.** The K1 DTB
declares the GPU node `status = "disabled"` to encode this honestly. The user-visible
result is still a functionally-identical COSMIC desktop -- COSMIC's look and feel
comes from libcosmic/iced, not from the GPU -- it simply composites on the CPU.
RVV 1.0 could later accelerate the rasterizer (LLVM has RVV codegen; Mesa has no
riscv SIMD path yet), which is a speedup, not a gate. True GPU acceleration on
RISC-V is better pursued on a board with a Mesa-supported discrete GPU over PCIe.
