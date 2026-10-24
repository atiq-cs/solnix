# The riscv64 "preemption" heap corruption was a brk TLB bug (rvpre, 2026-10-24)

rvsrv (4706d6c) left one bug open: with the netd kernel thread, zlib's `example` took a U-mode store fault in newlib
`_free_r` in 3/6 boots, and 0/6 without netd. The working hypothesis was that user state (registers, FP state or the
user page mapping) was corrupted across a timer preemption. **That hypothesis is wrong.** Preemption is not needed at
all. The trigger is any TLB flush, and preemption only mattered because a context switch flushes the TLB.

The bug is in `as.c as_grow()`. A brk shrink lowered `a_brk` and left the pages above it mapped. The next grow then
mapped fresh zeroed pages over the still-valid leaves, with no `sfence.vma`. The process kept writing to the old
pages through its stale TLB entries until the next flush. After that it saw the new zero pages, and the heap data
written in between was gone.

All runs were under qemu 10.2.1 on lixr (`~/scratch/rvpkg/bin/qemu-system-riscv64`). floki was used for editing only.
Kernel diff vs HEAD 4706d6c: `/scratch/solnix/rvpre/uts.diff`. Changed and new files: `/scratch/solnix/rvpre/files/`.
Harness: `files/harness/`. Logs: lixr `~/scratch/rvpre/logs/`. Bank: `~/solnix-bank/riscv/2026-10-24-rvpre/`.

## Summary

| Step | Result |
|---|---|
| 1 repro | `-smp 1`, one register-only CPU hog next to `example`: **12/12 boots trap** on HEAD (no netd). 0 hogs: 0/6. The netd kernel with no hog: 12/12 at `-smp 1`, 6/6 at `-smp 2`. About 5 s per boot. |
| 2 mechanism | `as_grow` remaps a still-valid brk leaf with no TLB flush. Observed directly: `BRK REMAP va=0x40043000 old pa=0x9f744000 new pa=0x9f6bf000`. Control: a kernel that flushes the TLB on every tick and **never switches** traps 10/12 with no hog. |
| 3 fix | Shrink unmaps and frees the pages above the new break, then `sfence.vma`. Also a brk floor (`a_brkbase`). Fix vs base, 12 interleaved boots each: 0/12 vs 12/12 (1 hog); 0/12 vs 10/12 (tick-flush control); fix+netd 0/12 at `-smp 1` and 0/12 at `-smp 2`, vs netd 12/12. A deterministic test, `brktest`: base 9/9 FAIL, fix 9/9 PASS. |
| 4 netd back | netd is the default again. The idle-poll and waiter-poll fallback is deleted. Host TCP 100 sequential + **10 concurrent: 10/10 on 6/6 boots** (unix-final2 had 7, 10, 10, 8). UDP 50/50 6/6. check-all x6: 48/48 suite runs green, zlib 6/6. Gates 8/8 x6 at `-smp 4` and x2 at `-smp 64`. |
| 5 user pointers | `copyin`/`copyout` refuse any range outside user root slots 1 and 3, with EFAULT. Negative control `uptrtest` on the unchecked kernel: kernel text printed, a byte stored into kernel BSS and read back. With the check: all six probes EFAULT, PASS. |

## 1. Reproduction

The test program is `pkg/tests/zhog.c`, called as `zhog NHOG KIND NRUNS PROG ARGS`. It forks NHOG CPU hogs, runs PROG
NRUNS times in a row, then kills the hogs. The harness is `rp.sh TAG N KERNEL SMP NHOG KIND NRUNS`, which boots a pkginit
root and stops at `RVPKG DONE` or at the first `unexpected trap`.

Results on `unix-base` (HEAD 4706d6c, no netd), `-smp 1`, 3 runs of `example` per boot (`logs/r1.out`, `r2.out`, `r3.out`):

| hog | boots trapped |
|---|---|
| none | 0/6 |
| integer (stores to its stack) | 6/6 |
| register-only (`mul`/`addi`, no memory, no FP) | 5/6 |
| FP | 5/6 |
| sleeping in `read()` | 0/1 |

Every trap is the rvsrv fault: `sepc=0x4001bfce` (`_free_r+0x74`, `sd t1,24(a6)`).

The bad `a6` values **repeat exactly across boots**: `0x03000000c5228b99` four times, `0x030c30008d2da716` four times,
and `0x914a600a9604063e` three times. The hog's registers are not leaking in, because a register-only hog does as well as
any other. The garbage is deterministic content from `example`'s own data. That pointed away from saved register state
and toward memory.

The netd kernel with no hog traps 12/12 at `-smp 1` and 6/6 at `-smp 2` (`logs/r7.out`, `logs/rates-s3.out`). The
smallest fast repro is either kernel at `-smp 1`, about 5 s per boot, at a rate near 100 %.

## 2. Mechanism

**The code** (HEAD `as.c`, `as_grow`):

```c
if (newbrk <= as->a_brk) {
    as->a_brk = newbrk;   /* shrink: keep pages, lower brk */
    return (as->a_brk);
}
...
for (p = oldtop; p < newtop; p += PAGESIZE) {   /* oldtop = roundup(a_brk) */
    pa = page_alloc();                          /* zeroed */
    hat_as_map(as->a_root, p, pa, PTE_R | PTE_W);   /* overwrites a VALID leaf; no sfence.vma */
```

newlib's `free()` trims the heap with `sbrk(-n)` when the top chunk passes the trim threshold. `example` does this when
`deflateEnd` and `inflateEnd` free their ~256 KiB windows. The next `malloc` grows the break again. On that grow, the
field that is wrong is **the level-0 leaf PTE for each brk page between the lowered break and the old top**. It is
rewritten to point at a new page while this hart's TLB still holds the old translation.

* User stores after the regrow go to the OLD physical page, through the TLB.
* The next `sfence.vma` drops the stale entry. In the base kernel that is `swtch.S`'s `csrw satp; sfence.vma`, which
  runs on every context switch. After it, the process reads the NEW page, which is all zero.
* newlib's chunk headers and free-list links written in that window disappear. `_free_r` then follows a free-list `fd`
  that came from stale or never-initialised memory (`ld a6,16(a4)`), and the store `sd t1,24(a6)` faults.
* The old pages also leak until exit.

**Observed, not inferred.**

1. `-DRVPRE_BRKCHK` (an observer in `as_grow`, `unix-brkchk`, `logs/r4.out`) prints a remap of a still-valid leaf on
   **every** boot, with or without a hog: `[rvpre] BRK REMAP va=0x0000000040043000 old pa=0x000000009f744000 new
   pa=0x000000009f6bf000`, and the next three pages likewise. Those boots trap 3/4 with a hog and 0/2 without one.
2. **The deciding control.** `-DRVPRE_TICKFLUSH` (`unix-tickflush`) adds one `sfence.vma` to the timer interrupt. It
   never preempts and never switches, and it ran with no hog: **10/12 boots trap** at the same `sepc` and with the same
   `stval` values (`rates-s3.out`). HEAD under the same conditions traps 0/6. So a TLB flush alone reproduces the bug,
   and no context switch is needed.
3. A flush at syscall **entry** (`-DRVPRE_SYSFLUSH`) gave 0/6. That fits the mechanism: the flush runs before
   `as_grow` rewrites the PTE, so the TLB is clean when the new mapping lands, and the process uses the new page from
   the start. Only a flush that comes after post-regrow stores exposes the bug.
4. A deterministic guest test, `pkg/tests/brktest.c`. It grows the break by 4 pages, fills them, shrinks by 4, grows by
   4, writes a pattern, then `usleep`s so the switch flushes the TLB, and reads the pattern back. With one hog, so the
   sleep really switches: base **9/9 `BRKTEST FAIL 16320 of 16384 bytes lost after a TLB flush (b[0]=0x0)`**. The other
   64 bytes are pattern bytes whose value is 0. Fix 9/9 PASS (`logs/r9.out`). With no hog, the base kernel passes the
   readback, because nothing flushes: this is the test's internal negative control.

**Why netd mattered.** netd yields in a loop, so the run queue is never empty. Every 10 ms tick therefore calls
`thread_preempt`, and every preemption flushes the TLB through `rv_swtch`. Without netd, a lone `example` on an idle
system was almost never switched out between a regrow and its `free()`. The curproc-mismatch result from rvsrv (0
mismatches) is consistent with this: a syscall never acted on the wrong process.

**The brief's candidates, checked by this evidence:**

* FP save and restore and `sstatus.FS`: not involved. The register-only hog never touches FP, and the tick-flush
  control never switches.
* `t0`/`tp`/`gp` clobbering and `sscratch`: not involved, for the same reason. The tick-flush trap path is the ordinary
  one, unchanged apart from one `sfence.vma`.
* A missing `sfence.vma`: **yes**, but in `as_grow`, not on the switch path. `swtch.S` flushes correctly. Its flush is
  what exposed the stale entry that `as_grow` left behind.

## 3. Fix

In `as.c`, illumos style. The shape follows illumos `brk_internal()`, which calls `as_unmap()` on a shrink.

* A shrink unmaps each page wholly above the new break (`hat_as_unmap`), then `page_free`s it. That drops only this
  AS's share of a COW page, through `p_ref`. Then it does `sfence.vma`. brk is always a syscall of the process whose AS
  is live on this hart, the same reasoning `proc_munmap` uses. After this, a grow can never land on a valid leaf.
* New field `a_brkbase`, set by `as_setbrk` at exec and copied by `as_copy` and `as_cow_copy`. A brk below it is
  refused. Without the floor, a negative `sbrk` could now unmap the program's own data and bss.
* The observer and control knobs (`RVPRE_TICKFLUSH` in trap.c, `RVPRE_SYSFLUSH` in syscall.c) are left in as `#ifdef`
  instruments, default off. The brk observer was removed.

**Rates** (`logs/rates-s3.out`, 12 boots each, interleaved, 3 `example` runs per boot):

| config | base | fix |
|---|---|---|
| `-smp 1`, 1 register-only hog | 12/12 trap | **0/12**, 12/12 `ZHOG DONE 3/3` |
| tick-flush control, no hog | 10/12 trap | **0/12** |
| netd, `-smp 1`, no hog | 12/12 trap | **0/12** |
| netd, `-smp 2`, no hog | (6/6 trap, r7.out) | **0/12** |

## 4. netd back as the default

* `inet.c`: netd is created unconditionally; the `RVSRV_NETD` ifdefs are gone. `net_sleep` no longer polls lwIP
  itself, and `inet_idle_poll` is deleted.
* `proc.c`: the two idle loops (`idle_body` and `smp_secondary_dispatch`) are back to their 6bf1cc4 form.
* Kernel `unix-s4n` (`logs/rates-s4.out`, `logs/rates-s4b.out`), 6 boots each:
  * UDP 50/50 byte-exact, 6/6.
  * TCP 100 sequential + **10 concurrent byte-exact, 6/6**. Concurrent was 10/10 in 0.1 s every boot, and the guest
    reported `served 110 connections, 0 bad` every boot.
  * The zlib repro with netd: 12/12 boots clean at `-smp 1` and `-smp 4`.
  * Gates 8/8 x6 at `-smp 4`, and 8/8 x2 at `-smp 64` with 64 online.
  * check-all x6: libc 6 (now including `brktest`), zlib 3, sbase 31, dash 16, ncurses 2, less 3, vfd 3, fs 28.
    **48/48 suite runs `failed=0`.**
* So the rvsrv concurrent-TCP shortfall on `unix-final2` (7, 10, 10 and 8 of 10) was the cost of the polling
  workaround, as suspected. It is gone with netd back.

## 5. User-pointer range check

**Before.** Syscalls hand user pointers straight to `copyin`/`copyout`, and those only catch an unmapped page. Every
address space maps the kernel image and all DRAM (identity, no `PTE_U`), and S-mode with SUM can touch them. So a
U-mode pointer into the kernel was simply used.

**The change** (`copy.S`): a `URANGE` macro at the entry of `copyin` and `copyout`. It returns -1 (EFAULT) through
`_copy_efault`, before `copy_lofault` is armed, unless `[uaddr, uaddr+n)` is non-wrapping and lies inside one Sv39 root
slot that is 1 or 3. That is `hat_user_range_ok`'s rule, and the illumos analog is the `kernelbase` compare at the top
of `copyin`.

The audit (grep):
* Every user access in the linked syscall paths goes through `copyin`/`copyout`. That covers `ns_abspath`,
  `argsnap_copy`, pipes, sockets, `fb_ioctl`, nanosleep, wait4, poll and ports.
* `sendsig.c`, with its direct `copyout_noerr`, is not linked.
* No kernel-internal caller passes a kernel pointer to `copyin`/`copyout`.

**Negative control** (`pkg/tests/uptrtest.c`). It uses raw `ecall`s, because libc's fd layer stages `pipe()`'s array
in a user buffer. K is an unused `secondary_stacks` slot. Results from `logs/r12.out` and `rates-s5.out`:

| probe | `unix-s4n` (no check) | `unix-s5` (check) |
|---|---|---|
| `write(1, 0x80200000, 16)` | 16, kernel text printed | -14 |
| `read(pipe, K, 1)` | 1, stored into kernel BSS | -14 |
| `pipe2(K+8)` | 0, fd pair written into the kernel | -14 |
| `nanosleep(K+64)` | 0, timespec read from the kernel | -14 |
| `openat(AT_FDCWD, 0x80200000)` | -2, path parsed from kernel text | -14 |
| `write(1, 0x7ffffff8, 16)` (crosses out of slot 1) | -14 (unmapped) | -14 |
| round trip: store `'K'` at K via read, load it back via write | **LEAK** | refused |
| positive control (the same calls on user buffers) | OK | OK |

`uptrtest` is added to `libc.checks` with K = 0x804a8000, the last `secondary_stacks` slot, which is unused below
`-smp 64`.

**Rates on `unix-s5`** (`logs/rates-s5.out`, 6 boots each):
* `uptrtest` 6/6 PASS. The control, `unix-s4n`, failed 6/6, and all 6 showed `LEAK`.
* Nothing regressed: UDP 6/6, TCP 100+10 6/6 (`served 110, 0 bad` x6), zlib repro 12/12 clean, gates 8/8 x6 at
  `-smp 4` and x2 at `-smp 64`, and check-all x6 48/48.

## Final tree

`unix-final` is built from the delivered tree. Its md5 is 43fad944, byte-identical to `unix-s5`. Results
(`logs/final.out`):
* check-all x2 with the new libc suite: 16/16 suite runs green, libc `passed=7`, which includes `brktest` and
  `uptrtest`.
* **Negative control of the two new checks:** the libc suite on `unix-base` (HEAD) failed both, 2/2.
  * `brktest`: `16320 of 16384 bytes lost`.
  * `uptrtest`: `LEAK at 0x804a8000`.
  * Every other libc check passed.

## What is left / not checked

* SMP hazards seen while reading `swtch()`, not shown to cause anything here:
  * `thread_yield` publishes the thread on the shared runq **before** `rv_swtch` saves its context, so another hart
    can resume a stale `t_ctx`. illumos holds `t_lock` across that window.
  * `curproc` in uproc.c and `copy_lofault` in swtch.S are single globals for all harts.
  * `swtch()` uses the pre-switch `cpu` after `rv_swtch`.
  * None of them showed up at the rates above, including `-smp 64` gates. They are worth their own track.
* brk shrink frees whole pages only: a break inside a page keeps that page, which is correct.
* `RVPRE_SYSFLUSH` and `RVPRE_TICKFLUSH` are left as default-off instruments. Delete them if they are not wanted.
* The harness quirk: zhog execs `argv[4]` with `argv=&argv[4]`, so the program's argv[0] is its path. `example`
  therefore got `"example"` as argv[1]. That is harmless: it is a filename either way.

## Committed tree (orchestrator, 2026-10-24)

The instrument switches used to find the bug are removed before commit: RVPRE_TICKFLUSH (trap.c) and RVPRE_SYSFLUSH
(syscall.c), and rvsrv's RVSRV_CURPROC_CHECK (syscall.c, uproc.c proc_check_current) and RVSRV_SABOTAGE_ALIAS
(hat_riscv.c). They were default-off. The committed tree built on lixr as unix-clean (md5 56536bed, the same 3
warnings as the tested build): gates 8/8 on 2 boots at -smp 4, check-all x2 16/16 suite runs green (libc 7/7 incl.
brktest and uptrtest). Banked: ~/solnix-bank/riscv/2026-10-24-rvpre/clean/.
