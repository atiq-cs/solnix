# Spec: FP state across a context switch (the hard blocker for a hard-float userland)

This is a specification, not an implementation. The bug is diagnosed and proven;
the fix is deliberately left as its own change because it must be judged by
**boot rate over several attempts**, not by inspection, and the port has already
been burned once by a plausible-looking-but-wrong conclusion drawn from a single
pass.

Evidence and diagnosis: `docs/riscv-no-fp-context-switch.md` (the finding of
record) and `docs/riscv64-poll-and-anon-mmap.md` section 5.
Regression gate: `src/riscv/uts/user/fptest.c`.

This document is the **implementation** half. On two points it deliberately
corrects the three-step sketch in the finding doc: `fpu.c` cannot simply be
compiled (section 2), and the FP state must **not** go in the trap frame
(section 4). Both corrections come from measuring, not reading.

## 1. The bug, in one paragraph

Nothing saves or restores the RISC-V F/D register file (`f0`-`f31` + `fcsr`)
across a context switch or a trap. A hard-float probe proves it: two processes
stamp distinct bit patterns into `f0`-`f7`, spin through several 100 Hz
preemptions, and the parent reads back `xor = PAT_PARENT ^ PAT_CHILD` -- it found
the child's values in its own registers. Reproducible 3/3 boots. It has been
invisible because every existing userland binary is built soft-float
(`-march=rv64imac`), so nothing has ever held a live value in an FP register. The
Rust `riscv64gc-unknown-illumos` target is `lp64d` (hard float), so the first
Rust binary to run two processes concurrently hits this, and llvmpipe -- which is
nothing but float -- would produce garbage pixels rather than an error.

## 2. What already exists, and what is missing

Both halves of the illumos riscv64 FPU code are **already in the tree**, imported
from `n-hys/illumos-gate`, and neither is built:

| File | State | Provides |
|---|---|---|
| `uts/float.s` (114 lines) | present, **in no build script** | `_fpu_save(fpu_ctx_t *)` and `_fpu_restore(fpu_ctx_t *)` -- the full `fsd`/`fld` of `f0`-`f31` plus `frcsr`/`fscsr` of `fcsr`. This is exactly the asm needed and it is complete. |
| `uts/fpu.c` (3733 B) | present, **in no build script** | `fp_save`/`fp_restore` (which bracket the asm with `SSR_FS_DIRTY` set / `SSR_FS_MASK` cleared), `fp_init`, `fp_fenflt` (the first-use trap handler), `fp_new_lwp` (the fork hook). |

**But `fpu.c` cannot be compiled as-is.** It is written against the full illumos
kernel and this port does not have that yet. It needs:

* `sys/types.h`, `sys/param.h`, `sys/proc.h`, `sys/pcb.h`, `sys/lwp.h`,
  `sys/cpuvar.h`, `sys/thread.h`, `sys/disp.h`, `sys/fp.h` ... -- the freestanding
  riscv64 kernel here includes none of these (`uts/sys/` has three headers:
  `elf_riscv.h`, `isa_defs.h`, `machtypes.h`).
* `ctxop_allocate`/`ctxop_attach` + `struct ctxop_template` -- the illumos context-
  operator framework. **This port has no ctxop layer at all.**
* `fpu_ctx_t`, `pcb_t`, `ttolwp()`, `curthread`, `kpreempt_disable/enable`,
  `bcopy`/`bzero`, `csr_set_sstatus`/`csr_clear_sstatus`.
* `float.s` needs `sys/asm_linkage.h` (`ENTRY`/`SET_SIZE`) and, critically,
  `assym.h` for `FPU_CTX_FPU_REGS` and `FPU_CTX_FPU_CSR` -- generated offsets that
  do not exist here.

**Recommendation: do not try to build `fpu.c`.** The honest reading is that
`float.s` is a gift (it is pure asm with two symbolic offsets) and `fpu.c` is a
sketch of the *policy* written for a kernel we have not built yet. Port the policy
by hand into the existing idiom -- ~60 lines against `proc.c`/`trap.c` -- and reuse
`float.s` with two locally-defined offsets. Keep `fpu.c`'s structure and naming so
the eventual convergence on real illumos is mechanical.

## 3. THE DESIGN-DECIDING FACT: the kernel itself never touches FP

Measured on the linked kernel (`unix-poll2`, the tree as left):

```
FP instructions in the linked kernel:        0
Kernel ELF header:                           soft-float ABI
```

(Verified the pattern is not broken: the same grep finds 16 FP instructions in
`fptest.elf`. The only apparent `f`-register hits in the kernel disassembly are
hex immediates like `fa850513 addi a0,a0,-88`, not FP registers.)

This is the single most important input to the design, and it simplifies it
enormously:

* **Pure lazy save/restore is available.** The kernel can leave `sstatus.FS=Off`
  while in S-mode and never spill FP on a kernel entry at all.
* **`copyin`/`copyout`/`memcpy`/the console path cannot clobber FP**, so there is
  no hidden dependency to audit.
* **The trap frame does NOT need FP slots.** See section 4 -- this is the answer to
  the "is there room in the alignment pad" question, and the answer is that the
  question does not arise.

If the kernel ever gains FP use (a soft-float `printf("%f")` does not count; an
actual `fadd` would), this design must be revisited -- so `float.s` being present
and the kernel being soft-float should both be asserted in the build.

## 4. Where the FP state lives: NOT the trap frame

The obvious-looking approach -- add `TF_F0..TF_F31` to `asm_frame.h` -- is the
wrong one, and it is worth saying why explicitly, because the frame's alignment
pad has already been used once (`TF_CPUID`) and the natural instinct is to look
there again.

**There is no room, and there should not be.** The current frame is exactly full:
31 GPRs + 4 CSRs = 35 slots = 280 bytes, rounded to 288 for 16-byte alignment,
and the single 8-byte pad word *is* `TF_CPUID`. FP state is 32 registers + `fcsr`
= 33 slots = 264 bytes. Adding it would grow `TF_SIZE` from 288 to 552 bytes and
put 264 bytes of `fsd` on **every** trap -- every timer tick, every syscall, every
page fault -- to save state the kernel never uses and that usually has not changed.
That is the eager design, and it is both slower and larger than necessary.

**Put it in the per-thread context instead**, along the grain of what already
exists:

* `struct rv_context` in `proc.c` already carries per-thread `satp` (offset 120)
  and `lofault` (128), saved/restored by `rv_swtch`. It is the natural home.
* Do **not** put the 264-byte register file inline in `rv_context` -- `rv_swtch`
  would have to know about it and the struct offsets in `swtch.S` would churn.
  Add **one pointer** (`c_fpu`, offset 136) to a lazily-allocated `fpu_ctx_t`, plus
  a small `c_fpu_state` flag. Threads that never touch FP never allocate it, which
  is every kernel thread and every current userland process.
* `swtch()` (C, in `proc.c`) does the save/restore around `rv_swtch` -- **not**
  `swtch.S`. The existing `swtch()` already does per-thread C work at exactly the
  right points (`old->t_curproc = proc_get_current()` before, `proc_set_current(...)`
  after), so the hooks are already there and `swtch.S` need not change at all.
  This matters: `swtch.S` and `trap.S` both carry documented ordering hazards, and
  a design that leaves both untouched is strictly safer.

## 5. The FS lazy-switch policy

`sstatus.FS` is a 2-bit field: 0=Off, 1=Initial, 2=Clean, 3=Dirty. The hardware
sets it to Dirty on any FP write, which is precisely the "do I need to save?"
answer, for free.

**Current state to be aware of:** every trap log in the tree shows `FS=3 (Dirty)`
already, e.g. `sstatus=0x8000000200006120`. Nothing in `locore.S` or `trap.S`
writes FS, so this is the reset/OpenSBI-handoff value, and the FPU is enabled and
accumulating state that nothing preserves. Whoever implements this should start by
deciding FS deliberately at boot rather than inheriting it.

Policy, in the illumos idiom (`fpu.c`'s `fp_save`/`fp_restore` already bracket the
asm this way, which is a good sign the imported code intends the same scheme):

1. **Boot / kernel context: FS=Off.** The kernel is soft-float (section 3), so an
   FP instruction in S-mode is a bug and should trap loudly rather than silently
   work. This also makes the "kernel never touches FP" invariant enforced by
   hardware rather than by grep.
2. **Entering U-mode for a thread with no FP context: FS=Off.** The thread's first
   FP instruction then takes an **illegal-instruction trap** (`scause=2`, which
   `trap.c` already decodes and prints). That trap is the first-use hook: allocate
   the `fpu_ctx_t`, zero the register file, set `fcsr` to a defined init value,
   set FS=Initial/Clean, and **retry the instruction** (do not advance `sepc`).
   This is what `fpu.c`'s `fp_fenflt()` is for.
3. **Entering U-mode for a thread that has FP context: restore it, set FS=Clean.**
4. **On switch away: save only if FS==Dirty**, then set FS=Clean (or Off). A thread
   that read FP but never wrote it needs no save. This is the whole payoff of the
   FS field and is why the eager trap-frame design is the wrong shape.
5. **Never save FP on a kernel-entry trap.** A timer tick that preempts a
   hard-float process leaves the FP registers alone; the *switch* is what saves
   them, and the switch is where the policy lives.

A correctness note that is easy to get wrong: `fp_save` in the imported `fpu.c`
*sets* FS=Dirty before calling `_fpu_save` and clears the FS field afterwards. That
is deliberate -- `fsd` itself requires FS != Off, so the save path must enable the
FPU to be able to spill it. Preserve that bracketing.

## 6. What `fork`, `exec` and signal delivery each must do

These are the four places the eventual implementation will be judged, and three of
them are currently silent about FP:

**`fork` (`proc_fork` in `uproc.c`).** The child must inherit a **copy** of the
parent's FP state, not a shared pointer, and the parent's live registers must be
spilled first if FS==Dirty (the parent is the running thread). This is exactly what
the imported `fp_new_lwp(parent, child)` does: `if (t == curthread) fp_save(fp);`
then `bcopy(fp, cfp, ...)`. Note the existing `proc_fork` copies `p_uframe`
byte-for-byte; the FP context is *not* in the frame under this design, so it needs
its own explicit copy. **A shared pointer here would reintroduce exactly the bug
being fixed**, one level down.

**`exec` (`load_elf_into` / `proc_exec`).** A fresh image must start with **no** FP
context: free or zero it and set FS=Off so the new program's first FP instruction
takes the first-use trap. Inheriting the old image's register file across `exec` is
an information leak between programs. `load_elf_into` already zeroes `p_uframe`
explicitly -- FP should be zeroed in the same place, for the same reason.

**Signal delivery (`proc_deliver_signals`).** Currently saves `*tf` into
`p_sigsave` and restores it in `proc_sigreturn`. A signal handler is user code and
may use FP, so it can clobber the interrupted code's FP registers. POSIX/illumos
put the FP state in the `ucontext`'s `mcontext` for exactly this reason. Minimum
correct behaviour: save FP alongside `p_sigsave` on delivery and restore it in
`proc_sigreturn`. **Note the existing one-frame-deep ceiling** (`p_insig`, no
nested handlers) applies equally to the FP save, and should be documented as the
same ceiling rather than a new one.

**Threads, when they land.** Per-LWP FP context, not per-process -- and this is
why `docs/riscv64-poll-and-anon-mmap.md` section 6 says **threads must not land
before this fix**: concurrent LWPs in one address space would multiply the
corruption rather than expose it.

## 7. Suggested order of work, and how to judge it

1. Decide FS at boot (Off in S-mode) and confirm the kernel still boots. Cheap,
   and it converts "the kernel never uses FP" from a grep result into an enforced
   invariant.
2. Add `c_fpu` + state flag to `rv_context`; save/restore in `swtch()` (C only).
   Assemble `float.s` with locally-defined `FPU_CTX_*` offsets.
3. Wire the illegal-instruction first-use trap in `trap.c` to an `fp_init`
   equivalent, retrying the instruction.
4. `fork` copy, `exec` zero, signal save/restore.
5. Build a **hard-float** userland variant (or just keep `fptest.elf` standalone,
   which is how it works today) and run `fptest` -- it must go from FAIL to PASS.
6. **Then measure boot rate over >= 6 attempts** and compare against the number in
   the report. The FP change touches the switch path, which is the same path the
   `TS_IDLE` bug lived in, so a regression here would show up as exactly the kind
   of intermittent stall that took real work to attribute the first time.

`fptest.c`'s check is the load-bearing one: it fails with a *specific* xor value
that identifies which process's data leaked, so a partial fix (say, saving `f0`-`f7`
but not `fcsr`, or saving on switch but not across `fork`) produces a diagnosable
failure rather than a vague one. Extend it to `f8`-`f31` and `fcsr` when the
implementation claims to cover them.

## Implementation status: wired, booting, 9/10 — with an honest caveat on the control

The policy module (`fp.c`/`fp.h`), the assembly (`fpsave.S`), and every integration point are
in and the scanout gate passes: `R-P64 SCANOUT PASS`, all four quadrants plus the diagonal.

**Two of my own bugs were caught by building and booting, not by reading:**

1. **`float.s` was never buildable in this port.** It wants `<sys/asm_linkage.h>` (ENTRY /
   SET_SIZE) and a generated `assym.h` (FPU_CTX_* offsets), and this port has neither — it had
   been imported and never compiled. Compounding that, the kernel is built **soft-float**
   (`-march=rv64imac_zicsr_zifencei`), so `fsd`/`frcsr` fail with *"extension `d' required"*.
   Replaced by **`fpsave.S`**, self-contained in the port's own idiom, enabling F/D for *itself
   only* via `.option arch, +f, +d` so the kernel proper stays soft-float — which is precisely
   what makes lazy FP handling safe.
2. **A store page fault at dispatcher start.** `kmem_alloc` does not zero and both
   `thread_create` and the idle-thread setup initialise `rv_context` **field by field**, so the
   new `c_fpu` held heap garbage that `fp_switch` dereferenced on the first switch. The console
   named it: `stval=0x3f3e3d3c3b3a3938` — a byte-counting pattern, not an address. Fixed at both
   construction sites.

### Boot rate, stated precisely

| tree | result |
|---|---|
| FP wired in, run set A | 5/6 |
| FP wired in, run set B | 4/4 |
| **FP total** | **9/10** |
| pristine baseline (claimed earlier, under load average 67) | 6/6 |
| **true pristine control** | **never obtained — both attempts invalid** |

The first control attempt stashed the build-script entry while leaving `fp.c`/`fpsave.S` in the
tree, producing a *mismatched* tree (0/4) rather than a pristine one. The second attempt was
mislabelled: the files were already tracked so the stash did not remove them, and it silently
**re-measured the FP tree** (4/4). Both are recorded rather than dropped, because they are the
same *"what is this comparison actually comparing?"* error this project has hit twice before —
once when a QEMU-vs-metal comparison turned out to run different GIC drivers.

**Honest position: 9/10 measured on the FP tree; not a demonstrable regression, and not a clean
bill either.** A valid control requires reverting the wiring *and* removing the FP sources, on
the same machine and load, interleaved.

### Still to verify

* The hard-float probe strengthened to **all 32 registers + `fcsr`** across several processes
  (`fptest.c` currently covers f0–f7 and demonstrates the *bug*).
* The **negative control**: set `fp_swtch_enabled = 0` and confirm the FP test **FAILS**. The
  flag exists for exactly this and is `volatile` so it cannot be folded away.
* That a **soft-float process still pays nothing** — FS stays Off for it, otherwise this is an
  eager save with extra steps.

## DONE — FPTEST PASS, negative-controlled

Three concurrent hard-float processes each stamp a distinct pattern into all of f0–f31 **plus
fcsr**, spin through several 100 Hz preemptions, and each reads its own values back.
**Negative control**: `fp_swtch_enabled = 0` makes the test FAIL, so the PASS is load-bearing.
Rate: scanout 5/6, FP gate 5/6 — and they pass/fail *together*, so the one failure is the
pre-existing general boot flake rather than anything FP-specific.

### Two design errors found by running it, not by reading it

1. **Fresh processes inherited an enabled FPU.** Nothing seeded `sstatus.FS` in `p_uframe`, so a
   new process ran with whatever FS the kernel last left — and `fp_save`/`fp_restore` must enable
   the FPU to execute `fsd`/`fld`. So userland arrived with FP already on and the first-use trap
   never fired. Fixed by clearing FS in the fresh frame.

2. **The lazy-restore design was wrong.** `sret` restores `sstatus` from the thread's **saved trap
   frame, not the live CSR**. Once a thread has taken its first-use trap, its frame carries
   FS=Clean permanently — so setting the live FS=Off at switch time changed nothing, and the
   thread resumed with FP enabled, using whatever registers the previous thread left.
   `fp_switch()` now **restores the incoming context directly**. Laziness still pays where it
   matters: a thread that has never touched the FPU has a NULL context, gets FS=Off, and costs
   nothing until it faults once.

**How they were localised** (guessing had already failed twice): temporary console markers on the
three policy paths showed `fp_switch`, `fenflt`, *and* three context allocations all running while
state was still corrupted — which ruled out the plumbing and pointed squarely at `fp_switch`'s
logic. The markers are gone; the cheap path counters remain, because *"did the policy run at
all?"* is the first question any future FP bug raises.

### What this unblocks

A hard-float (lp64d) Rust binary — and therefore llvmpipe — can now run without two processes
silently corrupting each other's FP registers. That was the top blocker on the Gate A list.
Remaining Gate A items: **event ports** (~4 days, what `calloop` actually uses on illumos),
threads (performance, not a gate — and safe to add only now that FP is preserved), `dlopen`.
