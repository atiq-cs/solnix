# Session record: substrate rebuild, two blockers cleared, and a verification reckoning

A long session that produced four platform advances and, more usefully, exposed a
class of problem worth naming: **work believed finished that wasn't.** Six separate
instances of it, several load-bearing. The verification habit earned more than the
feature work.

## Platform advances

| Advance | Evidence |
|---|---|
| **x86_64 base AMI rebuilt** in a new account | **21/21** cold launches measured (fresh launch + real SSH probe + terminate, three batches) |
| **aarch64 GICv3 blocker CLEARED on real silicon** | `artifacts/a6gic3-metal-console-GIC-CLEARED.txt`: 4 GICR regions, `mem = 134217728K`, `scsi_vhci0 is /scsi_vhci`, and **zero** `num_redistributors` panics |
| **aarch64 cross toolchain CAPTURED** | an AMI carrying the OmniOS root *and* the 150G gate tree on a non-deleting volume |
| **RISC-V Gate B (scanout) CLEARED** | a userland process mmaps `/dev/fb` and paints; a QMP screendump of the **host** display contains those pixels. Negative-controlled verifier |
| **COSMIC proven portable to riscv64** | libcosmic 359/359 rlibs EM_RISCV, 426 crates, **zero patches**; Mesa lavapipe 1124/1124; `cosmic-term` runs |
| **RISC-V ABI surface measured** | 16 symbols (not 12), 7 of them libsocket; 8/16 implemented for real |

## The six "believed done but wasn't" findings

1. **`scripts/metadata-shim.sh` was 222 lines of cargo build log in git HEAD** — clobbered
   two weeks earlier by a stray redirect. Nothing noticed because the machine building
   images still had the real file locally. A clean-checkout rebuild would have installed a
   cargo log as `/usr/lib/metadata` and produced an AMI that never gets a DHCP lease.
2. **Nine load-bearing COSMIC/illumos patches were untracked** — the calloop and
   wayland-client illumos fixes, softbuffer shm, session-shell-protocols, the riscv64 Rust
   target. Every one is a fix the working desktop depends on.
3. **A "verified" riscv64 libc patch carried three defects**, one an ABI break: an
   x86-FXSAVE-shaped fp union made `mcontext_t` 1088 bytes instead of 520 — a libc
   `ucontext_t` larger than the kernel's, i.e. a signal handler smashing the stack. Also a
   hunk header claiming 150 lines for a 162-line body, so `patch` silently dropped the
   `AV_RISCV_*` block *including* the RVV bit the doc promised.
4. **`trap.S` corrupted `t0` on every trap from S-mode** — `csrr t0, sscratch` used x5 as
   scratch before `sd x5, TF_T0(sp)` saved it. Measured 1/6 boots surviving before, 6/6
   after.
5. **`cmo.h` would raise an illegal instruction on any non-T-Head CPU** — T-Head cache ops
   selected at compile time. It had never fired only because `cmo.c` was in *no link line*:
   dead code hiding a latent trap.
6. **`_rp34`/`_rp35` held 93 sources existing nowhere else** — and I nearly gitignored them
   as stale duplicates on the strength of one identical file.

Plus a deleted `smallvil-illumos-timer-dispatch.patch` that looked superseded by a newer
calloop patch but was **complementary** (compositor side vs client side, different files).

## What actually prevents this

- **"Persisted to disk" is not "safe" — only committed is safe.** Two agents' artifacts
  were nearly lost this way; one was briefly reported lost because the harvest looked in
  the wrong repo. Agents must report FULL PATHS; the orchestrator must commit promptly.
- **A compiling probe is not a verified layout.** Assert sizes and offsets, and
  **negative-control the assertion** — re-inject the bug and confirm the check fails. The
  riscv64 libc layout assertions and the GICR walker harness are both kept in-repo for
  exactly this reason.
- **A test that cannot fail proves nothing.** The scanout verifier rejects a blank dump and
  a synthetically-sheared dump; only the real one passes. A 1-in-6 boot flake is precisely
  what a non-negative-controlled test reports as success.
- **A harness can test the right function and still miss the bug.** The GICR harness tested
  the coalescer but not the coalescer's *input path*, and a guard there discarded 63 of 64
  cpus. It now mirrors the guard, verified failing with the bug re-injected.
- **Check before dismissing.** Three findings (the complementary patch, the `_rp*` trees,
  the "lost" artifacts) came from comparing rather than assuming.
- **Snapshot a toolchain the moment it works, before first use.** See
  `docs/durability-account-loss.md`; the aarch64 toolchain AMI is that rule paying off.

## Honest state of the Milk-V goal

The desktop stack is **portable** — that is settled by cross-build, not argument. Two gates
remain and only one is on the critical path:

- **Gate B (scanout): CLEARED**, no hardware needed. Both halves exist and agree on the ABI.
- **Gate A (userland):** 8/16 ABI symbols real. The true next steps are **AF_UNIX sockets
  (1-2 weeks, not TCP/IP — a Wayland compositor is a UNIX-socket server first)** and the
  **`tp` collision** (RISC-V reserves `tp` for the userland thread pointer; our kernel uses
  it as the hart index, so Rust TLS cannot work until that moves to a CSR). TCP/IP is
  **off** the critical path.
- **The GPU is not part of this.** PowerVR BXE-2-32 has no open kernel driver path;
  the desktop composites on the CPU via llvmpipe and the display hardware only scans out.
  The K1 DTB declares the GPU node `status = "disabled"` to encode that honestly.

## Board readiness

Prerequisites are done and verified: the corrected K1 DTB (PLIC not AIA, 8 harts,
`spacemit,k1-x-sdhci`, the real SpaceMiT UART strings) and table-driven device matching.
Three things are needed from the hardware, and the second one changes a schedule:

1. **A USB-to-UART adapter on the K1 debug console.** Non-negotiable — every aarch64
   advance in this project came from reading a console.
2. **Does the stock vendor image boot?** It reveals whether U-Boot leaves a live
   framebuffer, which decides **3-5 days vs 2-3 weeks** for pixels on HDMI.
3. **Reachability** — driven directly, or via a handed-over runbook.
