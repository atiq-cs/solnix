# The riscv64 pre-boot flake: cpu-slot aliasing when OpenSBI's boot hart is not hart 0

Status: **mechanism observed, root cause fixed, negative-controlled with a
deterministic test.** All seven gates still pass.

The flake killed all seven riscv64 gates *together* on a minority of boots. Its
signature was precise: the console stopped at exactly **178 lines**, **zero
`[exec]`** lines, no trap report, dying inside the kernel's A/B dispatcher
self-test before any userland process ran. Because it never reached userland it
failed every gate at once, which is what distinguished it from any real
single-gate bug.

It was the fourth culprit blamed for this symptom class. The first three -- a gcc
version skew, committed build outputs, and (correctly, for a *different* trap) a
trap-vector reentrancy bug -- are recorded in `riscv64-first-real-binary.md`.

---

## 1. The mechanism

`startup_dispatch()` hardcoded the boot hart into dispatcher cpu slot 0:

```c
startup_dispatch(void)
{
        dispatch_init_cpu(0);           /* the bug */
```

But **OpenSBI runs a boot-hart lottery.** On `qemu virt -smp 4` the S-mode
payload is entered on hart 0 only about two thirds of the time; the rest of the
time it is hart 1, 2 or 3. Measured over 30 samples
(`/tmp/flake/lot30.txt`): hart 0 x22, hart 1 x4, hart 2 x2, hart 3 x2.

When the lottery picks hart 2, three things are simultaneously true:

1. the boot hart (hart 2) calls `dispatch_init_cpu(0)` and claims
   `curthread[0]` / `idlethread[0]`, leaving **its own slot 2 empty**;
2. `start_secondaries()` skips only `h == boot_hartid`, so the **real hart 0** is
   released via SBI HSM into `smp_secondary_dispatch(0)`, which calls
   `dispatch_init_cpu(0)` and claims the **same slot**;
3. `startup_dispatch()` calls `smp_dispatch_open()` immediately before
   `thread_ab_selftest()`, so hart 0 enters the shared runq exactly while the A/B
   test is running.

Two harts now own one dispatcher slot. The kill is the unconditional restore at
the end of every secondary dispatch in `smp_secondary_dispatch`:

```c
curthread[cpu] = self;          /* idle is current again */
```

Real hart 0 executes that on slot 0 while the boot hart is running a thread on
slot 0. `curthread[0]` becomes `idlethread[0]`. The boot hart's next `swtch()`
then hits its own early-out:

```c
new = runq_dequeue();                   /* runq empty -> NULL */
if (new == 0)
        new = idlethread[cpu];          /* == curthread[cpu] now */
if (new == old)
        return;                         /* "only ourselves runnable" */
```

`swtch()` **returns** -- and the one caller that must never be returned to is
`thread_exit`:

```
80205cde:  jal  swtch          # must not return
80205ce2:  wfi
80205ce6:  wfi                 <-- wedged here forever
80205cea:  j    80205ce2
```

The boot hart spins in `thread_exit`'s dead-end `wfi` loop inside a dying A/B
thread. It never returns to `startup_dispatch`, so `smp_selftest`,
`startup_root`, the vfs mount and all of userland never happen. Console output
stops mid-A/B-test at line 178.

## 2. How it was observed (QEMU-side only, no kernel printfs)

Deliberately **no instrumentation was added to the kernel.** This is a race, and
an instrument that changes timing is not an observer -- adding console output to a
bug whose symptom is console interleaving is especially likely to move it. All
observation is QEMU-side and happens strictly *after* the guest has wedged, so it
cannot perturb the race.

`preboot-flake-catch.py` boots in a loop watching for the exact signature (the
A/B test printed its last "round 3" and then never printed
`[disp] thread A/B context-switch`), then issues QMP `stop` to freeze the VM and
dumps every hart's registers plus the dispatcher and lock words out of guest
memory. It caught the flake twice in 26 attempts. Both dumps say the same thing:

| | `regs-15` (bootHart=2) | `regs-26` (bootHart=1) |
|---|---|---|
| wedged hart | CPU#2 (= the boot hart) | CPU#1 (= the boot hart) |
| wedged pc | `0x80205ce6` = `thread_exit+0x38` | same |
| other harts | all at `0x8020613a` (secondary idle `wfi`) | same |
| `runq_head` / `runq_tail` | 0 / 0 | 0 / 0 |
| `idlethread[0..3]` | `c00 a00 0 b00` | `a00 0 e00 d00` |
| `curthread[0..3]` | `c00 a00 0 b00` -- **identical** | `a00 0 e00 d00` -- **identical** |
| all locks | free | free |

Two independent confirmations in that table:

* `curthread[] == idlethread[]` in every slot is the clobber, caught in the act.
* **The empty slot is always the boot hart's own slot** -- slot 2 in the
  bootHart=2 dump, slot 1 in the bootHart=1 dump. That is the aliasing itself:
  the boot hart went into slot 0 instead of its own.

No lock was held and no trap was pending, which rules out a deadlock or a fault
and leaves only "`swtch()` returned when it must not have".

## 3. Why it was bursty

The brief's warning that this bug is bursty rather than uniformly random
(measured 1/4, then 8/8 on an identical tree, then 4/4 and 4/4) has a mechanical
explanation: **the trigger is not per-run random, it is the OpenSBI boot-hart
lottery**, which is sticky across consecutive QEMU invocations on the same host.
Nonzero boot harts therefore arrive in clusters, and the failures cluster with
them. Host CPU load is irrelevant, which matches the earlier measurement of 4/4
under six spinning load generators.

`bootHart != 0` is **necessary but not sufficient**: the clobber must also land
inside the A/B window. Every one of the six recorded 178-line failures had a
nonzero boot hart, while plenty of nonzero-boot-hart runs passed
(`nc1-console-1..4` = harts 3, 2, 3, 1, all pass). That gap between necessary and
sufficient *is* the flakiness.

## 4. What was ruled out

Negative results, recorded so nobody re-spends on them:

* **The interleaved console output is a red herring.** It was the brief's most
  concrete lead, and it is real -- but it also occurs on `bootHart=0` runs that
  **pass** (`/tmp/flake/base/console-2.log`, `console-3.log` show both the
  character-level interleaving and the A,A,A/B,B,B ordering, and reach `login:`).
  Secondaries legitimately pull the A/B threads off the shared runq, and the
  dispatcher self-test's output does not take `main.c`'s `console_lock` (that
  lock is `static` and used only by `main.c`'s own printers). So the interleaving
  is a cosmetic consequence of genuine SMP, harmless on its own. It is a symptom
  of concurrency, not of the bug.
* **Host CPU load** -- previously measured 4/4 loaded and 4/4 idle. Not retested.
* **`-icount` as a lever for *this* bug.** Deterministic icount pins the boot
  hart to 0, which removes the precondition entirely; shift 0..6 all pass. Shifts
  7 and 8 do stall, but at line 200 with a different shape (in vionet), so they
  are a third bug, not this one.
* **Forcing the boot hart via an OpenSBI FDT domain node.** Tried
  `/chosen/opensbi-domains` with `boot-hart`; OpenSBI v1.7 rejects a partial root
  domain override (`sanitize_domain: domain-root next booting stage address 0x0
  can't execute`, then `init_coldboot: domain finalize failed`). Not pursued
  further because the slot check below made it unnecessary.

## 5. The fix

`dispatch_init_cpu(0)` becomes `dispatch_init_cpu(startup_boot_hartid)`. The boot
hart id cannot be recovered from `tp` inside `startup`: locore deliberately
leaves `tp` at 0 for the boot hart (seeding it early destabilized the boot -- see
the `this_cpu()` comment in `proc.c`), so it is carried across the MD/MI seam
explicitly, the same way `startup_ncpu` already is.

* `src/riscv/uts/startup.c` -- new `int startup_boot_hartid`;
  `startup_dispatch()` uses it instead of a literal 0.
* `src/riscv/uts/main.c` -- sets `startup_boot_hartid` from `boot_cpu.bc_hartid`
  (range-checked against `MAXCPU`) before calling `startup()`.
* `src/riscv/uts/proc.c` -- `smp_selftest` compares the hart that ran the proof
  thread against the real boot hartid instead of testing `> 0`. That test was
  wrong in both directions once the boot hart can be nonzero: it reported a
  genuine cross-hart dispatch onto hart 0 as "boot hart only", and on a
  nonzero-boot-hart run it would have reported the boot hart's own dispatch as a
  cross-hart success.

## 6. The deterministic test -- `hart-slot-check.py`

**The flake's crash rate is a bad test and must not be used as one.** Reinstating
the bug and booting 40 times produced **zero** crashes
(`/tmp/flake/nc.txt`) -- the burstiness the brief warned about, arriving exactly
when it would have been most misleading. A crash-rate negative control here can
silently exonerate a broken kernel.

So the check targets the **precondition** instead of the crash. Aliasing is a
static fact about kernel state on every boot, crash or not:

```
cd src/riscv/uts && python3 hart-slot-check.py 12 4
```

It boots in a loop, waits for the SMP proof line (by which point every hart has
been through `dispatch_init_cpu`), freezes the VM with QMP `stop`, reads
`idlethread[]` and `curthread[]` out of guest memory, and classifies each run:

* **ALIASED** -- the boot hart's own slot is NULL while slot 0 is populated: two
  harts share slot 0.
* **CLEAN** -- one populated slot per live hart, including the boot hart's.
* **SKIP** -- `bootHart == 0`, uninformative by construction (slot 0 legitimately
  *is* the boot hart's slot).

Exit status is nonzero if any informative run was ALIASED, so it works as a gate.

### Negative control

| kernel | result |
|---|---|
| `dispatch_init_cpu(0)` (bug reinstated) | **ALIASED 5, SKIP 7** -- 5 of 5 informative runs aliased |
| `dispatch_init_cpu(startup_boot_hartid)` (fixed) | **CLEAN 2, SKIP 14** -- zero aliased |

A second, larger fixed-kernel run gave CLEAN 2 / SKIP 4 out of 6. The check flips
100% of the time on informative runs in both directions, which is what makes it
trustworthy where the crash rate is not.

Companion tool `preboot-flake-catch.py` (the observer from section 2) is kept for
the next bug of this shape: it turns "the console stopped" into a full per-hart
register and dispatcher-state dump without touching the guest.

## 7. Crash-rate evidence, for completeness

Judged by rate as well, over >= 8 runs as the brief requires -- but read section 6
first, because these numbers are the *weaker* evidence.

| kernel | runs | flake hits | nonzero boot harts seen |
|---|---|---|---|
| before fix | 26 | **2** (both `bootHart != 0`) | yes |
| before fix (separate batch) | 10 | **1** (`bootHart = 2`) | yes |
| after fix | 40 | **0** | 9 |

Gates after the fix: `bash build-scanout.sh` exits 0 with SOCKTEST, POLLTEST,
PORTTEST, FPTEST, MINIWL, NEWLIBTEST and FBTEST all PASS plus SCREENDUMP VERIFY
PASS. The gcc 14.3.0 pin is untouched.

---

## 8. A DIFFERENT bug found while looking -- captured, NOT fixed

Caught by the same observer and left alone deliberately, so it does not get
tangled with the fix above.

Signature: console stops at **166 lines** (not 178), `bootHart = 0`, dying in
`startup_cyclic` rather than the dispatcher test.

Register dump (`/tmp/flake/catch/regs-7.txt`):

* `CPU#0 pc = 0x80201c64` = `timer_intr+0x2e`, the
  `amoswap.w.aq (callout_lock)` acquire spin;
* `scause = 0x8000000000000005` -- an S-mode **timer** interrupt;
* `sepc = 0x80201f48` -- inside `callout_schedule`, **past** its
  `callout_lock_enter()`;
* every other hart still spinning on `smp_dispatch_ready`, so this is **not**
  cross-hart.

That is a **same-hart self-deadlock**. `callout_lock` is a plain test-and-set
spinlock, `clock_start()` has already set `SSTATUS_SIE`, and `callout_selftest()`
(the last thing the 166-line console prints) calls `callout_schedule` with
interrupts enabled. The 100 Hz timer fires while the lock is held and
`timer_intr` re-enters the same lock, which can never be released.

The fix is to disable S-mode interrupts across the `callout_lock` critical
sections in `timer.c` (the illumos shape is a spin lock at a raised PIL). It is
**not** applied here: it is a separate defect with a distinct signature, and the
brief's rule is to capture a newly-found blocker precisely rather than chain a
second repair.

Note that the sibling lock is *not* affected for the same reason:
`runq_lock` is also held with interrupts on, but the only re-entry path is
`timer_intr -> thread_preempt -> thread_yield -> runq_enqueue`, and `trap.c`
calls `thread_preempt` only when the trap came from U-mode
(`(sstatus & SSTATUS_SPP) == 0`), which never holds while kernel code holds
`runq_lock`.

## 9. Tools

Both live in `src/riscv/uts/` and are pure QEMU-side observers -- no kernel
change, no added console output, all observation after the guest has settled or
wedged.

| tool | what it does |
|---|---|
| `hart-slot-check.py N [smp]` | deterministic aliasing check (section 6). Exit nonzero on ALIASED. |
| `preboot-flake-catch.py N [smp]` | boot until the exact 178-line signature, then dump all harts' registers + dispatcher/lock words (section 2). |

Both honour `$KERNEL` (default `unix-scanout`), `$NM`, and `$OUT`, and resolve
`riscv64-none-elf-nm` from `$NM`, then `PATH`, then the nix store -- resolved
rather than hardcoded because the symbol addresses must come from the same binary
being booted, and a stale `nm` would report a clean slot table for a broken
kernel.
