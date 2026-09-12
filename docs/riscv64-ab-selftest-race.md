# The `[disp] thread A/B context-switch FAILED` flake is the A/B TEST's bug, not the dispatcher's

**Status: mechanism OBSERVED, with a dose-response curve and a negative control.
Not fixed here** — a precisely-named cause is the deliverable; the fix is a
one-line ordering change whose blast radius touches the R-P13 SMP proof, so it
should be its own change.

This flake has been carried as "known pre-existing, non-fatal" through several
rounds, most recently in `docs/k3-first-boot-runbook.md` §7 ("baseline at HEAD
`MAXCPU=8`/`-smp 8` 5/10 runs, this tree `MAXCPU=16`/`-smp 16` 4/10 … not a
regression"). That framing is correct about it not being a regression and wrong
about it being mysterious. It is a **race in the test**, it **scales with hart
count**, and at the K3's 16 harts it is the most frequent failure in the tree.

⚠️ Everything below is measured **under QEMU**, which is used here for absence of
regression only. It says nothing about whether the K3 boots.

## The mechanism

`startup_dispatch()` (`src/riscv/uts/startup.c:380-389`) does this, in order:

```c
smp_dispatch_open();      /* releases all 15 secondaries into the shared runq */
thread_ab_selftest();     /* then runs the two-thread ping-pong proof */
smp_selftest();
```

`thread_ab_selftest()` (`src/riscv/uts/proc.c:770-800`) creates threads A and B,
then yields as the boot-hart idle thread until `ab_done`, and finally asserts:

```c
if (ab_rounds_a == AB_ROUNDS && ab_rounds_b == AB_ROUNDS && ab_done)
```

But `smp_dispatch_open()` has **already** released every secondary hart into
`smp_secondary_dispatch()`, which pulls from the **one global runq** that A and B
were just enqueued on. So A and B can be dequeued and run by **any** of the 15
idle secondaries, concurrently with the boot hart's own yield loop. The counters
`ab_rounds_a`/`ab_rounds_b` are plain `volatile int`s incremented by whichever
hart happens to run the thread.

The assertion is therefore a **race**, not a proof: it demands an exact count of
3+3 from a workload that multiple harts are free to interleave.

## The evidence

**Console corruption is the visible fingerprint.** Failing runs show two harts
writing the console inside one line — the console spinlock serialises whole
`sbi_console_puts` calls, not a multi-call print sequence:

```
tthread B: round 1 (ctx-switch to A)
thread B: round 2 (ctx-switch thre[disp] thread A/B context-switch FAILED
[smp] enqueue a thread on the shatad A: round 2 (ctx-switch to B)
```

**Failing runs are short of rounds, and it is arbitrary which thread loses:**

| run | `thread A: round` lines | `thread B: round` lines | verdict |
|---|---|---|---|
| 1 | 3 | 3 | ok |
| 5 | 3 | 3 | ok |
| 2 | 2 | 3 | FAILED |
| 4 | 2 | 3 | FAILED |
| 10 | 3 | 2 | FAILED |
| 15 | 2 | 1 | FAILED |
| 16 | 3 | 2 | FAILED |

**Dose-response.** Same kernel binary, same host, 10 runs per cell, `-machine
virt`:

| `-smp` | secondaries that can steal | `dispFAILED` |
|---|---|---|
| 1 | 0 | **0/10** |
| 2 | 1 | 1/10 |
| 4 | 3 | 1/10 |
| 8 | 7 | 2/10 |
| 16 | 15 | **4/10** |

**`-smp 1` is the negative control**: with no secondary harts there is nobody to
steal from the runq, and the flake vanishes (0/10). The rate then rises
monotonically with the number of thieves. That is the mechanism observed, not a
plausible story — the standard this project holds after a symptom was blamed on a
compiler, then on committed binaries, and was a dead comparison all along.

Larger samples agree: 3/36 at `-smp 4` (8%) vs 11/37 at `-smp 16` (30%).

**It clusters, so a small sample lies.** Run-order at `-smp 16`, `X` = flake:

```
.X.X.....X....XX      (16-run batch)
XXX..X..              (an earlier 8-run batch, same tree)
```

A 4-run window inside the leading `XXX` reports 75%; the next four report 0%.
Both honest, both wrong. This is the bursty-sample hazard in
`docs/working-with-subagents.md`, reproduced exactly.

## Why it is not fatal today, and why that changes on the K3

The A/B test is a **proof of scheduling**, not a dependency of boot: the console
line is printed, `startup_dispatch` continues, and all seven gates still pass —
which is why it has been shrugged off. Two reasons to stop shrugging:

1. **On the K3 it is 16 harts, not 4.** 30% vs 8% turns a curiosity into the
   thing the maintainer sees on his first real boot, and
   `docs/k3-first-boot-runbook.md` §6 tells him to report where output stops.
   A `FAILED` line in the `[disp]` block will read as a K3 hardware problem and
   send him down the wrong path. That is a real cost, on hardware, this week.
2. **A test that fails 30% of the time cannot detect a regression.** It is the
   only in-tree check on `swtch()`, so its noise is exactly the shape that hides
   a genuine dispatcher bug — the same class as
   `docs/riscv64-preboot-flake.md`'s original defect.

## The suspected fix (NOT applied)

Move `smp_dispatch_open()` to **after** `thread_ab_selftest()`, so the A/B
ping-pong runs single-hart and its exact-count assertion is sound, and the
multi-hart proof stays where it belongs — in `smp_selftest()`, which is designed
for it and reports which hart ran the work (`smp_ran_on_hart`).

This is one line, but it reorders SMP bring-up, so it wants its own change and
its own gate run rather than being smuggled in here. Verification should be the
dose-response table above, re-measured: the fix predicts **0/10 at every `-smp`
value**, not merely a lower rate at 16.

An alternative — make the assertion tolerate multi-hart interleaving (`>=` and a
per-thread completion flag) — is worse: it weakens the only scheduling proof in
order to accommodate a test-ordering mistake.

## Not the same thing as the `swtch`/`fp_switch` park

Separately observed at `-smp 16`, ~2/37 runs, and **not** explained by the above:
a hart parks with a `scause` that is not a valid cause code but a **kernel text
address**:

```
[trap] exception: scause=0x0000000080205e7e (unknown exception)
       sepc=0x000000008020eb36 stval=0x0
```

Resolved against the linked kernel: `0x8020eb36 = fp_switch+10`,
`0x80205e2e = swtch+52`, `0x80205e7e = swtch+132`. A corrupted `scause` around
the context-switch/FP-save path is a **different and more serious** signature
than the counter race — the kernel survives (one hart parks, boot reaches
`login:`), so it has been invisible to every pass/fail gate.

Deliberately **not** chased here, per the one-fix-at-a-time rule. Recorded with
its evidence so it is not rediscovered from scratch: logs `/tmp/rv2-pr-16-*.log`,
`/tmp/rv2-post-virt-16.log`.
