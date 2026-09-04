# Two pre-existing RISC-V kernel bugs, found by the scanout work

Neither is a scanout bug. The scanout seam was simply the first code to exercise
these paths hard enough to expose them, which is the useful lesson: a new
subsystem is a test of the old ones.

## 1. `trap.S` corrupted `t0` on every trap from S-mode

**The bug.** The trap entry did `csrr t0, sscratch` — using x5 as scratch — *before*
`sd x5, TF_T0(sp)` had saved it. So the frame stored the already-clobbered value,
and the restore path handed the interrupted code a corrupted `t0`.

**Why it was brutal.** Any interruptible kernel path holding a live value in `t0`
was silently miscompiled *at runtime*: the register came back wrong after any
interrupt. The failure surfaces as a wild-pointer dereference or a nonsense value
far away from the trap, with nothing pointing at the trap handler. There is no
compile-time signal and no assertion that fires.

**The fix** is an ordering constraint, now enforced and commented in place: save
`x5` into `TF_T0(sp)` first, and only then use `t0` as scratch for the `sscratch`
read. The comment in `trap.S` states the constraint explicitly so a future edit
does not reintroduce it by "tidying" the register order.

**Measured effect: 1/6 boots survived before, 6/6 after** (`-smp 4`).

## 2. `cmo.h` raised an illegal instruction on any non-T-Head CPU

**The bug.** The T-Head custom cache-maintenance ops (raw `.long`-encoded
opcode-0xb custom-0 instructions: `thead.dcache.clean/inval/flush`, `thead.sync`)
were selected at **compile** time. A custom-opcode instruction a CPU does not
implement raises ILLEGAL INSTRUCTION, so a kernel built for T-Head dies the moment
any driver touches the DMA path on a non-T-Head part — including QEMU's default
rv64.

**Why it had never fired.** `cmo_selftest()` was declared but never called, and
`cmo.c` was in **no link line at all**. The code was dead, so the latent trap was
invisible. The scanout work was the first to link and exercise it.

**The fix.** Both backends now compile, and `cmo_dma_wb()`/`cmo_dma_inv()` dispatch
on a `cmo_backend` chosen **once at boot from the devicetree** (T-Head ops on the
T-Head lineage — C906/C910/the K1's X60 — versus standard `zicbom` where the DT's
`riscv,isa` advertises it). One image therefore boots QEMU *and* the Milk-V
Jupiter, which is precisely what we need: the K1's X60 is T-Head-derived, but every
QEMU test run is not.

## The transferable lesson

Both bugs were **latent because nothing exercised them**: one needed an
interruptible path holding a live `t0`, the other needed `cmo.c` to actually be
linked. Neither would have been found by reading the code, and both would have been
maddening to diagnose on real Milk-V hardware, where the only instrument is a
serial console. Finding them in QEMU — where a boot is 30 seconds and can be
repeated six times to measure a flake rate — is worth far more than finding them on
the board.

This is also why the scanout verifier is **negative-controlled** (a blank dump and
a synthetically-sheared dump must both fail; only the real one may pass). A test
that cannot fail proves nothing, and a 1-in-6 boot flake is exactly the kind of
thing a non-negative-controlled test reports as success.
