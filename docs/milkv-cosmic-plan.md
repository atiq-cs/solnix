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

> **UPDATE -- Gate A moved substantially.** The `tp` collision is **RESOLVED** (split by
> privilege: userland's TLS pointer in U-mode, the kernel's per-hart id in S-mode, swapped
> by `trap.S` into a trapframe slot that costs no memory; `this_cpu()` is still one register
> read). **AF_UNIX/SOCK_STREAM with SCM_RIGHTS is REAL** -- 18/18 checks across two
> processes with the received fd proven writable-through, negative-controlled. Five of the
> sixteen ABI symbols moved `[ENOSYS]` -> `[REAL]`. Three pre-existing kernel bugs were
> found and fixed on the way (second-fork COW dropping `PTE_COW`, the `copy_lofault`
> redirect ignoring `SPP`, `this_cpu()` masking instead of validating).
>
> **⚠️ REVISED PRIORITY -- the real first wall is FLOATING POINT.** The kernel saves NO
> FP state across a context switch (`docs/riscv-no-fp-context-switch.md`): zero fsd/fld in
> swtch.S/trap.S, no FP frame slots, and `uts/fpu.c` present but in no build script. Proven
> 3/3 by a fork probe where the parent read back exactly parent^child from its own f0-f7.
> It hid because our userland is soft-float (`-march=rv64imac`), but the Rust
> riscv64gc-unknown-illumos target is **lp64d hard-float** and llvmpipe is pure float math --
> so a compositor and its client would corrupt each other's FP registers SILENTLY, producing
> garbage pixels rather than an error. This must be fixed before any hard-float userland is
> trusted. The fix is `fpu.c` + FP frame slots + an FS lazy-switch policy (save when Dirty,
> trap on first use), judged by boot rate.
>
> **And a correction: `poll(2)` is necessary but NOT sufficient.** On illumos `calloop` goes
> `polling` 3.11 -> `rustix::event::port` -> **event ports** (`port_create`/
> `port_associate`/`port_getn`), and `wayland-backend`'s server side uses the native
> **`epoll(5)` shim**. poll(2) is what libc and those shims sit on, not what calloop calls --
> so **event ports** join the Gate A list.
>
> **STATUS: (1) and (2) are DONE. (3) is now the next binding constraint.**
>
> **(1) FP context switch -- ✅ DONE.** `FPTEST PASS`: three concurrent hard-float processes,
> all 32 registers + `fcsr`, across several preemptions, negative-controlled
> (`fp_swtch_enabled=0` makes it FAIL). This was the hard blocker -- every Rust binary is
> `lp64d` hard-float and llvmpipe is pure float math, so two processes would have corrupted
> each other *silently*.
>
> **(2) event ports -- ✅ DONE.** `PORTTEST PASS 24/24` from userland: oneshot semantics (a
> fired association does not re-fire while the fd is still readable), re-association updating
> rather than appending, `port_send` delivered with no fd ready (calloop's wakeup), the cookie
> round-tripping verbatim, HUP reported when only POLLIN was asked for, and a negative control
> proving an empty fd does not report readable. Syscalls 510-514.
>
> **(3) raise the 8-slot fd table** (`p_fd[8]`, and `NPOLLFD` 16) -- **now the next binding
> constraint.** A compositor holds a listener + 1-2 fds per client + the framebuffer + a port,
> so 8 is exhausted by roughly the third client. Note the event-port association table (8 per
> port) has the same ceiling and should be raised with it.
> **(4) `munmap` + file-backed `mmap`** -- both need a real `seg_vn`; the anon arena is a
> bump allocator with no reuse today.
> **(5) threads/`pthread_create`, `dlopen`, `__tls_get_addr`.**
>
> **`poll(2)` and anonymous `mmap` are DONE** -- `[REAL]`, 35/35 userland checks including
> the level-triggered case and a two-sided negative control, a 200 ms timeout measured at
> 203 ms, and `MAP_ANON` = 0x100 with Linux's 0x20 refused rather than misread
> (`docs/riscv64-poll-and-anon-mmap.md`).
>
> **Threads must NOT land before (1)** -- concurrent LWPs in one address space would multiply
> the FP corruption rather than expose it. Two scoping results worth having: a compositor
> **can** work single-threaded (`smallvil` is; Rust's `available_parallelism` already falls
> back to 1; llvmpipe runs at `LP_NUM_THREADS=0`), so threads are a **performance** item and
> not a gate; and a fully-static link avoids needing `dlopen` at all, provided the Mesa ICD
> is linked in rather than loaded at runtime -- a deliberate build-time choice, not a kernel
> feature. `dlopen` itself is weeks, not days: `uts/elf.c` is 175 lines and rejects anything
> but static `ET_EXEC`, and there is no `ld.so.1` on riscv64.
>
> **A fifth pre-existing kernel bug fell out and was FIXED: the idle thread was being
> published on the shared runq.** `thread_yield`/`thread_preempt` guarded it with
> `t_state == TS_IDLE` -- a value nothing ever assigns (`dispatch_init_cpu` and `swtch` both
> set `TS_ONPROC`), so both guards were dead code and every `idle_body` yield let another
> hart dequeue and resume the idle thread while its owning hart was still on that stack.
> Two harts, one thread. **This was the boot-flakiness root cause: 2/10 clean boots before,
> 8/10 with only that guard changed to compare identity, 6/6 on the final kernel** -- so the
> "~5/6 baseline" the committed userland blobs were judged against was this race, not the
> blobs. It presented as a wild `sepc` (`0xfffffffffffffffc`, `0x0`) or
> `[disp] thread A/B context-switch FAILED`, far from the cause.

**And one kernel change WAS on the critical path: the `tp` collision (now fixed).**
RISC-V reserves `tp` for the userland thread pointer; our kernel repurposes it as
the hart index (`uts/proc.c` does `mv tp, hartid`). Rust TLS cannot work until `tp`
belongs to userland and the hart id moves to a CSR. Cheap to fix now, expensive
after more code depends on it -- see `docs/riscv64-crt-rust-startup.md`.

**Gate B -- scanout (pixels on the monitor). CLEARED in QEMU.** Both halves exist:
* **OS half DONE** -- `/dev/fb` (`src/riscv-port/rp64/kernel/fb.c` + `fbio.h`): a
  userland process opens the node, reads the mode (1280x800, stride 5120,
  XRGB8888), mmaps 4000 KiB of real scanout memory, paints through the mapping and
  flushes; a QMP screendump of the **host** display contains those pixels. 13/13
  userland checks, 6/6 consecutive `-smp 4` boots. The verifier is
  **negative-controlled** (a blank dump and a sheared dump both fail), which is what
  makes the PNG evidence rather than decoration. Error paths validate rather than
  trust userland: oversized damage rects clamp, out-of-range origins are rejected,
  optional `FBIOSMODE` honestly returns ENOTSUP.
* **Compositor half WRITTEN + host-tested** --
  `src/riscv-port/rp64/compositor/fb_backend.rs` (775 lines), the smithay backend
  that renders into `/dev/fb` instead of DRM/KMS or a winit host window (smithay
  0.7.0 has no fbdev backend). Verified pin: **smithay 0.7.0 + winit 0.30.13** --
  the `DragMoved` drift that blocked smallvil is HEAD-only, so pinning the release
  avoids it rather than patching around it. 12/12 host tests, including that stride
  is honored not recomputed, and that it paints the same reference pattern as
  `fbtest.c` so the Rust and C halves provably agree on the ABI.

Running it *on* solnix is gated by Gate A, not by the display path.

**A correction to Gate A's critical path:** the gate for a compositor is **AF_UNIX
sockets (1-2 weeks), not TCP/IP**. A Wayland compositor is a UNIX-socket server
before it is anything else. The 1-3 month TCP/IP work does **not** belong on this
critical path. The kernel currently has 25 syscalls with no threads, sockets, anon
mmap or dlopen -- all four of which a libcosmic client needs.

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
