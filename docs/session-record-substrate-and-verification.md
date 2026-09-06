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
- **A correlation is not a mechanism.** "The working boot does X right where the broken
  one dies" felt like evidence and was not: the two boots were running *different
  drivers* (QEMU virt attaches `gictwo0`/GICv2; the metal path is `gicthree.c`), so the
  comparison was meaningless. Before building on a cross-environment comparison, confirm
  both sides execute the same code. And **decode numbers rather than pattern-matching
  them** -- the "byte-wide writes" were QEMU decomposing one 32-bit store into four
  `writeb` log lines, and every "bad offset" decoded to a single value: QEMU's own
  `num_irq` bound.
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

## Later round: six pre-existing kernel bugs, all found by new code exercising old code

The pattern is consistent enough to state as a rule: **a new subsystem is a test of the
old ones.** None of these would have been found by reading the code.

| bug | found by | effect |
|---|---|---|
| `trap.S` corrupted `t0` on every S-mode trap | the scanout work | 1/6 boots -> 6/6 |
| `cmo.h` illegal instruction on non-T-Head CPUs | the scanout work | dead code hid a latent trap |
| second-fork COW dropped `PTE_COW` (`hat_riscv.c`) | the AF_UNIX work | userland rebuilds broke |
| `copy_lofault` ignored `SPP` (`trap.c`) | the AF_UNIX work | wrong-privilege fault recovery |
| `this_cpu()` masked instead of validating (`proc.c`) | the `tp` split | unsafe once userland writes `tp` |
| **dead `TS_IDLE` test let two harts run one thread** | the poll work | **2/10 boots -> 8/10 -> 6/6** |
| **no FP state saved across a context switch** | assessing smallvil | would corrupt llvmpipe SILENTLY |

The last two are the most instructive. The `TS_IDLE` race closed a **three-step
misdiagnosis chain** — the same boot flakiness was blamed on a gcc version skew (I committed
that), then on the committed userland blobs, and was actually a dispatcher bug all along.
Each explanation was plausible; none was verified against a mechanism. The rule now recorded
in the source: **distrust a plausible explanation until the mechanism has been observed.**

The FP bug is worse than it sounds. It hid because our userland is soft-float, but Rust's
riscv64 illumos target is hard-float and llvmpipe is pure float math — so a compositor and
its client would corrupt each other's FP registers **silently**, producing garbage pixels
rather than an error. It would have looked like a renderer bug for weeks.

## The instrument was the bug: ~13 seconds per character

The aarch64 console emitted **~13 s/char** because `boot_uart_putchar()` waited for a TXFE
flag that never sets on Graviton, burning its full 1,000,000-iteration cap on every byte. A
prior boot spent **2.5 hours** printing ~670 characters of debug markers.

Two lessons:

* **A capped poll on a condition that never occurs is not "bounded" — it is a fixed cost.**
  Prefer removing an unnecessary wait to capping it; size any necessary cap to the physical
  event rather than to a round number.
* **The debug instrument was perturbing the system by hours, so it was never a passive
  observer.** That invalidated a queued A/B experiment (removing 19 markers also removed
  ~2.5h of settle time from the middle of `gicv3_init`), and it made a "stall" ambiguous —
  at 13 s/char a single devinfo line costs ~10 minutes, so a boot that looked hung may
  simply have been printing.

## My own error rate, and what it says about the arrangement

Agents corrected me repeatedly this session, and the corrections were substantive:

* the "lost" riscv64 artifacts (they were untracked in a repo I hadn't checked);
* the byte-wide-GICD hypothesis (I compared two boots running *different GIC drivers*);
* the gcc-skew explanation for the userland breakage (three kernel bugs, not the compiler);
* "calloop uses poll" (on illumos it uses **event ports** via `polling`/`rustix`);
* my FP-fix sketch (`fpu.c` needs a ctxop framework this port lacks; the trap frame is
  exactly full so FP belongs in `rv_context`).

The common thread: **I was reliably wrong where I reasoned from general knowledge instead of
tracing the actual dependency or measuring the actual value.** The corrections all came from
agents that measured. Briefs should therefore keep saying "refuting this is a good outcome"
and "get evidence before fixing" — those two sentences produced most of the value here.
