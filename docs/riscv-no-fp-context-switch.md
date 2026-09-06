# RISC-V: the kernel saves no FP state across a context switch

The real first wall for running COSMIC on solnix RISC-V — not `poll(2)`, not
`mmap`. Found while assessing what still blocked `smallvil`.

## The bug

**Nothing preserves floating-point registers across a context switch.** Verified:

| check | result |
|---|---|
| `fsd`/`fld` in `swtch.S` | **0** |
| `fsd`/`fld` in `trap.S` | **0** |
| `TF_F*` slots in `asm_frame.h` | **0** |
| `uts/fpu.c` (imported from n-hys illumos-gate) | exists, **in no build script** |
| `sstatus` in every trap log | `0x...6120` → **FS=3 (Dirty)** |

So the FPU is enabled and accumulating dirty state that nothing saves or restores.

## The evidence (3/3 reproducible)

A hard-float `lp64d` probe forks. The parent stamps `f0`–`f7` with
`0x1111111122222222`, the child with `0x3333333344444444`. Both spin through
several 100 Hz preemptions. The parent then reads its own FP registers back and
xors against its expected value:

```
xor = 0x2222222266666666      == parent ^ child, exactly
```

**The parent found the child's values in its own floating-point registers.**
Logs: `/tmp/rvpoll/br-fp-{1,2,3}.log`. The probe is committed as
`src/riscv/uts/user/fptest.c` and is the regression gate for the fix; its header
comment records how to build it (standalone `-mabi=lp64d`, since the soft-float
libc slice cannot be linked against it).

## Why it hid until now

Our userland is built `-march=rv64imac` — **soft-float**. No user process has been
using the FPU, so nothing has ever noticed that its state is not preserved. The
kernel itself does not use FP either. The bug has been latent from the beginning.

## Why it is the wall for COSMIC

* The Rust `riscv64gc-unknown-illumos` target is **lp64d — hard float**.
* **llvmpipe is nothing but float math.** A software rasterizer is the single most
  FP-intensive thing we could possibly run.
* Two concurrent hard-float processes (a compositor and a client — exactly the
  Wayland model) would corrupt each other's FP registers **silently**. The
  symptom would be garbage pixels or wrong geometry, *not* an error message. That
  is a debugging nightmare: it would look like a renderer bug for weeks.

So this must be fixed before any hard-float userland is trusted, and certainly
before judging a compositor's output.

## What the fix involves (deliberately NOT half-done)

1. Wire `uts/fpu.c` into the build (it already exists, cribbed from illumos-gate).
2. Add FP register slots to the trap frame / thread state.
3. Implement an **FS lazy-switch policy** — the point of RISC-V's `sstatus.FS`
   field is to avoid saving FP state for threads that never touch the FPU: save
   only when FS is Dirty, and trap-on-first-use to restore. Doing this eagerly for
   every switch would be correct but needlessly slow.

> **The full implementation spec is `docs/riscv64-fpu-context-switch-spec.md`**, so
> none of this needs re-deriving. It refines the three steps above, and on two
> points it **corrects** them — both discovered by measuring rather than reading:
>
> * **Step 1 as written will not work.** `fpu.c` cannot simply be compiled: it
>   needs ~15 full-kernel headers this port does not have, plus the illumos
>   **ctxop** framework (`ctxop_allocate`/`ctxop_attach`), which does not exist
>   here at all, plus `assym.h`-generated offsets for `float.s`. The good news is
>   that **`uts/float.s` IS directly usable** — it is complete, pure asm, and needs
>   only two locally-defined offsets. The spec recommends porting `fpu.c`'s
>   *policy* by hand (~60 lines in the existing idiom) and reusing `float.s`.
> * **Step 2: NOT the trap frame.** The frame is exactly full (35 slots = 280 B
>   rounded to 288, and the single pad word is already `TF_CPUID`), so FP state
>   would grow `TF_SIZE` 288 → 552 and put 264 bytes of `fsd` on **every** trap —
>   every timer tick, every syscall — to save state the kernel never uses. Put it
>   behind **one pointer in `rv_context`** instead, saved/restored in `swtch()`
>   (C), which leaves both `swtch.S` and `trap.S` — the two files carrying
>   documented ordering hazards — completely untouched.
>
> The measurement that decides the design: **the linked kernel contains zero FP
> instructions and is itself soft-float ABI**. So pure lazy save/restore is
> available, and no kernel path (`copyin`, `memcpy`, the console) can clobber FP.
> The spec also covers what `fork` / `exec` / signal delivery each must do with FP
> state — `fork` sharing a pointer instead of copying would reintroduce this exact
> bug one level down.

That is its own change with its own risk to the dispatcher, and it **must be judged
by boot rate over several attempts**, not a single pass — the same discipline that
caught the `TS_IDLE` dispatcher race. Half-wiring it would be worse than leaving it
clearly documented as broken.

## A correction to the mission framing

`poll(2)` was described as the top item because "calloop uses poll." That is
**wrong on illumos**, and worth recording so the priority list is honest:

* `calloop` → `polling` 3.11 → `rustix::event::port` → **illumos event ports**
  (`port_create` / `port_associate` / `port_getn`).
* `wayland-backend`'s server side uses illumos's native **`epoll(5)` shim**.

So `poll(2)` is **necessary but not sufficient**: it is what libc and the
port/epoll shims sit on, not what calloop actually calls. A compositor on solnix
RISC-V will additionally need **event ports** (and/or the epoll shim) wired up.
That belongs on the Gate A list alongside the FP fix.

Sized in `docs/riscv64-event-ports-sizing.md`: **~4 days** for the five calls
`polling` actually uses, plus **1-2 days** for an `epoll(5)` shim over the same
associations (which is what the already-written
`src/drm-port/wayland-backend-illumos-epoll.patch` expects to find). Two findings
shrink it: `polling` uses event ports in **oneshot mode only** (it rejects level
and edge outright), and `calloop` already **emulates level-triggering in software**
for this backend because `supports_level()` is false for it — which is very likely
the mechanism behind the existing `calloop-wayland-source` / `wayland-client`
timer-dispatch patches. `port_associate` also takes plain `PollFlags`, i.e. the
same `POLLIN`/`POLLOUT`/`POLLHUP`/`POLLERR` bits `fd_ready()` already computes, so
the readiness core is done and `port_getn` is a new output shape over it rather
than new logic.
