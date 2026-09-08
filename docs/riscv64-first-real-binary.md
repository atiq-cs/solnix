# The first real cross-compiled binary on the solnix riscv64 kernel

**Result: a statically linked riscv64 binary produced by a real toolchain against
a real third-party libc (newlib 4.5.0) executes on the solnix riscv64 kernel and
passes every check it makes.** Rung 1 of the task ladder is done, and so is rung
2 (real `printf`/`malloc`), because on this toolchain they are the same rung — see
§2. Rung 3 (Rust) is not, and §7 says exactly what stops it.

Everything below is traceable to a console log or a link map on disk. Where this
document contradicts an earlier claim in the tree, the contradiction is called out
explicitly and the measurement is given.

---

## 1. What ran, and the evidence it was real

Console excerpt (`/bin/newlibtest`, run as a boot gate by `/sbin/init`):

```
--- gate: REAL libc (newlib 4.5.0) on the solnix kernel ---
[fork] pid 1 -> child pid 22
[exec] /bin/newlibtest (75352 bytes) pid 22
[elf]   PT_LOAD vaddr=0x0000000040010000 filesz=59112 memsz=60656 perm=rwx
[newlibtest] start: argc=1 argv[0]=newlibtest
[newlibtest] ok 1: %ld = 1234567890123 (real libc)
[newlibtest] ok 2: malloc 1000+2000+4000 verified, brk heap at 0x4001f420
[newlibtest] ok 3: snprintf -> "sol-42-ff" (n=9)
[newlibtest] ok 4: strtol=-12345 qsort=1,7,23,42,99
[newlibtest] ok 5: %.3f = 3.142 (hard-float libc)
NEWLIBTEST PASS: real newlib libc.a on the solnix riscv64 kernel
```

The five checks are chosen so that **passing is only possible with a real libc**:

| # | Check | Why the toy libc cannot fake it |
|---|---|---|
| 1 | `%ld` of `1234567890123` | `user/libc.c`'s `printf` implements only `%d/%u/%x/%s` — it has no `l` length modifier at all. |
| 2 | `malloc(1000)+malloc(2000)+malloc(4000)`, each pattern-filled and read back after the others are allocated | exercises newlib's real `_malloc_r` (dlmalloc family) on top of `_sbrk` on top of the kernel's `brk(2)`. Overlapping blocks fail here. |
| 3 | `snprintf` return value | real stdio formatting engine, bounded write. |
| 4 | `strtol` + `qsort` | nothing anywhere in this tree implements either. |
| 5 | `%.3f` of a double | newlib's floating-point `vfprintf` path (`dtoa`), which is hard-float code. |

### Provenance: proven from the link map, not asserted

The acceptance criterion was to prove this is not the toy libc, because
accidentally re-linking `libc-riscv.a` would make a trivial result look like a
breakthrough. Three independent proofs, all from
`src/riscv/uts/user/newlibtest.map`:

1. **61 distinct newlib archive members are linked**, including
   `libc_a-vfprintf.o`, `libc_a-dtoa.o`, `libc_a-mallocr.o`, `libc_a-qsort.o`,
   `libc_a-strtol.o`, `libc_a-strcmp.o`, `libc_a-findfp.o`, `libc_a-impure.o`.
2. **Zero `libc-riscv.a` members are linked.** `printf`, `malloc`, `memset`,
   `strcmp`, `strlen` and `free` all resolve to `libc.a(libc_a-*.o)` under
   `/nix/store/326m521a9mipli339nmbzcgpglsj6py7-newlib-riscv64-none-elf-4.5.0.20241231/`.
3. **`nm --undefined-only newlibtest.elf` is empty** — a fully self-contained
   static binary. `readelf -h`: `ET_EXEC`, `RISC-V`, entry `0x40010000`,
   `Flags 0x5, RVC, double-float ABI`.

`build-newlibtest.sh` enforces 1 and 2 as **hard build failures**, so a future
mis-link cannot quietly produce a fake pass. That guard is negative-controlled in
§5.

### The exact link line

```
riscv64-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -mcmodel=medlow \
    -O2 -g -Wall -Wextra -fno-stack-protector -fno-pic \
    -isystem $NEWLIB/riscv64-none-elf/include -c newlibtest.c -o newlibtest.o
riscv64-none-elf-gcc  (same flags)                          -c newlib_glue.c -o newlib_glue.o
riscv64-none-elf-ld -T newlib.ld -Map=newlibtest.map -o newlibtest.elf \
    $NEWLIB/riscv64-none-elf/lib/crt0.o newlibtest.o newlib_glue.o \
    -L$NEWLIB/riscv64-none-elf/lib -lc -lm \
    $GCC/lib/gcc/riscv64-none-elf/14.3.0/libgcc.a
```

with

```
NEWLIB = /nix/store/326m521a9mipli339nmbzcgpglsj6py7-newlib-riscv64-none-elf-4.5.0.20241231
GCC    = /nix/store/c231v52nr5smrzgygvpk0cs1f0336z0l-riscv64-none-elf-gcc-14.3.0
```

**The compiler pin is unchanged.** newlib 4.5.0 is the libc that already ships
with the pinned `riscv64-none-elf` gcc 14.3.0; using it adds no new toolchain and
changes no version. `gcc -dumpversion` → `14.3.0`.

---

## 2. Why "a real toolchain binary" and "a real libc's printf/malloc" are one rung here

The brief lists them as rungs 1 and 2. With newlib they are inseparable: there is
no way to link `crt0.o` + `libc.a` and *not* get the real `printf` and the real
`malloc`, because they come out of the same archive. So rung 2 landed with rung 1.
What is *not* proven is a third thing the brief did not ask for and which no libc
here can supply: threads. See §7.

---

## 3. Two mechanisms discovered by measurement (neither was in the brief)

These matter more than the passing test, because they constrain all future riscv64
userland work.

### 3.1 newlib's shipped `libc.a` is `medlow`, so it cannot be linked at `0xC0010000`

Measured with `objdump -r` over the whole archive:

| Relocation | Count |
|---|---|
| `R_RISCV_HI20` (absolute, `lui` — medlow) | **1547** |
| `R_RISCV_PCREL_HI20` (pc-relative — medany) | **3** |

`medlow` addresses only the ±2 GiB window around 0, i.e. `[0, 0x7FFFFFFF]`. The
existing userland link base `0xC0010000` is outside it, so linking newlib there
fails outright:

```
relocation truncated to fit: R_RISCV_HI20 against symbol `errno'
    defined in .sbss section in libc.a(libc_a-reent.o)
```

**Resolution: link the real-libc program at `0x40010000`** (`user/newlib.ld`).
That is Sv39 level-2 slot 1, and `hat_as_newroot()` (`hat_riscv.c`) copies only
slots 0, 2 and 256..511 into a new process root, *deliberately* leaving slots 1
and 3 free for user mappings. So slot 1 is a genuinely free user slot that also
happens to lie inside medlow's reach. The kernel's boot-time `ALIAS_VA` proof page
is also at `0x40000000`, but only in the **kernel** root, which is never a process
root — no collision, and the boots confirm it.

The user stack stays where the kernel puts it (`0xfffff000`, slot 3); stack access
is `sp`-relative and needs no absolute relocation, so splitting text/data/heap
into slot 1 and the stack into slot 3 is harmless.

**Implication:** any future real-libc userland either links in slot 1, or the libc
gets rebuilt `-mcmodel=medany`. This is a fork in the road worth deciding
deliberately, and it is invisible until someone tries to link a stock libc.

### 3.2 A real-libc userland is necessarily HARD-FLOAT

`riscv64-none-elf-gcc -print-multi-lib` → `.;` — **exactly one multilib**, and
`readelf -A libc.a` reports
`rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zifencei2p0...`, i.e. `lp64d`.

There is no soft-float newlib to link against. So every other program in this
userland is soft-float `rv64imac`, `fptest` was the *one* hard-float program — and
now any program built against a real libc joins it. **The kernel's FP context
switch is a prerequisite for a real-libc userland, not an optional extra.** Check
5 (`%.3f`) exercises FP from inside library code rather than from hand-written
assembly, which is a meaningfully stronger test than `fptest` alone.

---

## 4. The OS port layer: every symbol tagged

newlib demands a small, *measured* OS port — obtained by linking with no port at
all and reading the undefined list, not by guessing. Eleven symbols, in
`src/riscv/uts/user/newlib_glue.c`:

| Symbol | Tag | Backing / what a stub costs |
|---|---|---|
| `_write` | **REAL** | `SYS_write` (64). Console for fd 1/2, vfs file for fd ≥ 3. |
| `_read` | **REAL** | `SYS_read` (63). |
| `_close` | **REAL** | `SYS_close` (57). |
| `_lseek` | **REAL** | `SYS_lseek` (62). |
| `_getpid` | **REAL** | `SYS_getpid` (172). |
| `_exit` | **REAL** | `SYS_exit` (93). |
| `_sbrk` | **REAL** | `SYS_brk` (214). The load-bearing one: newlib's `malloc` sits on it. The kernel's `brk` is the absolute-address form, so the increment arithmetic lives in the glue. |
| `_fstat` | **STUB** | The kernel has **no `stat`/`fstat` at all**. Returns `S_IFCHR` unconditionally, so newlib treats every stream as a character device. Cost: no stream is block-buffered, and any program needing a file's real size/mode gets a wrong answer. Honest fix: a real `fstat` over the vfs layer. |
| `_isatty` | **STUB** | Always 1. Same reason; genuinely true for fds 0/1/2. |
| `_kill` | **ENOSYS** | The kernel *has* `kill(2)` (129), but wiring `abort()` to it would make a libc-internal assertion failure look like a signal death. Fails explicitly instead; `abort()` falls through to `_exit`. |
| `_open` | **ENOSYS** | Deliberately not wired to `openat(2)`. Wiring it is a few lines, but `fopen()` then needs working `fstat` to buffer correctly. Left explicit so nobody mistakes a stub for a port. |

`__trunctfdf2` also appeared undefined; it is `libgcc`'s (128-bit long-double
conversion, pulled by newlib's float formatting) and is satisfied by linking
`libgcc.a`. Not a gap.

**7 REAL, 2 STUB, 2 ENOSYS.** No stub is reported as an implementation.

---

## 5. Negative controls

A test that cannot fail proves nothing. Both mechanisms were sabotaged and both
checks flipped.

**NC1 — break the kernel dependency.** `_sbrk` altered to return `-1` (as if
`brk(2)` did not exist), everything else identical:

```
[newlibtest] ok 1: %ld = 1234567890123 (real libc)
[newlibtest] FAIL 2: malloc returned NULL (a=0x0 b=0x0 c=0x0)
[newlibtest] ok 3: snprintf -> "sol-42-ff" (n=9)
[newlibtest] ok 4: strtol=-12345 qsort=1,7,23,42,99
assertion "Balloc succeeded" failed: file "../.././newlib/libc/stdlib/mprec.c", line 783
[exit] pid 22 exit(1)
```

No `NEWLIBTEST PASS` line. Note the last line: **newlib's own `mprec.c`
assertion fires**, which is additional evidence that real upstream libc code is
executing and reacting to a real allocator failure. The other six gates stayed
green, confirming the gates are independent.

**NC2 — break provenance.** Relinking against the toy `libc-riscv.a` instead of
newlib fails at link time (`undefined reference to 'errno'`, ×many — the toy libc
has no `errno`, no `_impure_ptr`, no stdio). And injecting a `libc-riscv.a` line
into the link map makes the build's own guard fire:

```
FATAL: the TOY libc (libc-riscv.a) got linked in.
rc=1
```

So the provenance assertion is not decorative.

---

## 6. Gate rate over 8 runs, and a doc claim this work refutes

### 6.1 The rate

`cd src/riscv/uts && bash build-scanout.sh`, 8 consecutive runs:

| Run | SOCKTEST | POLLTEST | PORTTEST | FPTEST | MINIWL | SCANOUT | NEWLIBTEST |
|---|---|---|---|---|---|---|---|
| 1 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| 2 | *(all fail together — see below)* | | | | | | |
| 3 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| 4 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| 5 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| 6 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| 7 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| 8 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |

**7/8 for all seven gates, including the new one. No existing gate regressed.**

Run 2 is the known general flake, and its signature confirms it rather than
assuming it: the console stops at **line 178 of 546**, inside the *kernel*
dispatcher self-test (`thread B: round 3 (ctx-switch to A)`), which is
**before any userland program is exec'd at all**. A boot that never reaches
userland cannot have been broken by a userland program.

### 6.2 The regeneration breakage: root-caused and FIXED (was: "refuted")

This section previously reported that regenerating the userland broke the miniwl
gate and concluded it was "a latent `sscratch`/kernel-stack-top bug on the fork
path". The bisection stands, the conclusion was **half right**: it is a real
kernel bug and it is an `sscratch` bug, but it is **not on the fork path**. The
mechanism has now been observed and fixed. Two claims made here are also
withdrawn as unmeasurable; see below.

#### What was actually wrong

`_trap_entry` (`trap.S`) discriminates a trap-from-U from a trap-from-S using
**only** `sscratch != 0`:

```
csrrw sp, sscratch, sp
bnez  sp, 1f            /* nonzero => "came from U-mode" */
```

That is sound only if `sscratch` is zero for every S-mode instruction. It was
not. The entry swap parks the interrupted `sp` **in `sscratch`** and the original
code left it there for the entire duration of `trap()`. So any trap taken while
`trap()` was running — the clock tick that arrives after a preemptive `swtch`,
or any nested S-mode exception — saw a nonzero `sscratch`, was **misclassified as
a trap from U-mode**, and built its frame at the parked value, which is a **user**
stack address. The first store of the frame is `sd ra,0(sp)` at `0x8020019e`,
which then faults with `scause=0xf` and a user-address `stval`. That is exactly
the reported signature.

The same missing invariant has a second victim, `usermode_entry`, which sets
`sscratch` in its first instruction and then runs ~31 more instructions loading
the user GPR set before `sret`. Its `csrw sstatus` has already cleared `SPP` by
then, so a misclassified trap in that window snapshots an `sstatus` with `SPP=0`
and its `sret` drops to **U-mode at a kernel PC**.

#### The mechanism, observed

Captured with QEMU's own `-d int` trap log — a true observer: it lives on the
QEMU side, adds no kernel code and perturbs no kernel timing, which matters here
because the bug is a race (`/tmp/qtrace.log`, two **consecutive** records):

```
riscv_cpu_do_interrupt: async:1 cause:0x5  epc:0x802002ae  desc=s_timer
riscv_cpu_do_interrupt: async:0 cause:0xc  epc:0x802002ae  tval:0x802002ae  desc=exec_page_fault
```

`0x802002ae` disassembles inside `usermode_entry`, 12 bytes past the `csrw
sstatus,t0` that clears `SPP`:

```
802002a2: csrw sstatus,t0    <- SPP:=0, SPIE:=1, SUM:=1
802002aa: csrw sepc,t0
802002ae: ld   ra,0(a0)      <- timer lands HERE, still S-mode, sscratch nonzero
802002b2: ld   sp,8(a0)      <- past here, x2 is the USER sp
```

A timer arrives at `0x802002ae`; the very next trap is an **instruction** page
fault at that same address with `sepc == stval` and `SPP=0` — the kernel `sret`ed
to its own PC in U-mode. This also **resolves a contradiction the old text could
not**: `SPP=0` together with a kernel `sepc` is impossible for an ordinary fault.
It is not an inconsistency in the report, it is the *signature* of this bug.

#### Why regeneration looked like the cause (it is not)

The race window is a fixed instruction count. Regenerating the userland changes
program sizes and instruction counts, and therefore the **phase of the clock**
relative to that window — nothing more. **The committed `user_elfs.h` was a lucky
phase, not a correct kernel.** So this was never about the compiler (blamed
first, wrongly) and never about the committed build outputs (blamed second, also
wrongly). It is a third thing: a trap-vector reentrancy bug that a rebuild merely
re-rolls the dice on.

#### The fix

Two instructions in `trap.S`, restoring the invariant the vector already assumed:

1. `_trap_entry`: `csrw sscratch, zero` immediately after the parked `sp` has
   been read out into `TF_SP`. After that point `sscratch == 0` for every S-mode
   instruction, which is what makes the `bnez` discriminator sound. **This is the
   load-bearing half.**
2. `usermode_entry`: clear `sstatus.SIE` before touching `sscratch`, closing the
   commit window. Free on exit — `sret` restores the U-mode interrupt state from
   `SPIE`, which the same function sets to 1, so userland still runs with
   interrupts enabled.

#### Negative controls (both halves tested separately)

| Kernel | MINIWL / all 7 gates | Signature |
|---|---|---|
| Both fixes | **PASS 10/12** (2 runs lost to the pre-existing pre-boot flake) | no trap in any of 12 |
| **NC2**: remove *only* the `_trap_entry` `csrw sscratch, zero` | **FAIL 4/4** | `sepc=0x8020019e stval=0xffffecb0 sstatus=0x200040020`, at miniwl right after its fork — **bit-identical to the original report** |
| **NC1**: remove *only* the `usermode_entry` SIE clear | PASS 4/4 | — |

NC2 flipping 4/4 to the exact documented signature is what pins causation to the
`_trap_entry` half. NC1 passing 4/4 says the `usermode_entry` window is a
genuine-but-narrower hole that this workload does not reliably hit; it is kept
because the window is real and the guard is one instruction.

#### ⚠️ The pre-boot flake is BURSTY, not uniformly random (measured separately)

Independent re-measurement by the orchestrator, after a full `build-user.sh`
regeneration, hit **1/4** — then **8/8** immediately afterwards with no change to
the tree, then **4/4 loaded and 4/4 idle**. Overall 17/20, but the three failures
were **consecutive**.

That distribution matters more than the ratio. "Judge a flaky thing by RATE over
several attempts" implicitly assumes the attempts are INDEPENDENT, and these are
not: failures arrive in bursts, so a 4-run sample taken inside a burst reports
25% and one taken outside reports 100%. Both are real measurements of the same
tree. Two consequences:

* A small sample can indict a good change or exonerate a bad one. Prefer >=8 runs
  and, if failures cluster, report the CLUSTERING rather than averaging it away.
* Host CPU load is NOT the trigger — 4/4 under six spinning load generators and
  4/4 idle. So the burst source is still unidentified; it is not simply "the dev
  box was busy".

Failure signature is unchanged and remains distinguishable from any userland bug:
exactly 178 log lines, **zero `[exec]`**, dying inside the kernel dispatcher
thread test before any userland runs, with interleaved output
(`thread A: round 3thread B: round 3`) showing two harts writing the console
concurrently. That interleaving is the most concrete lead on the flake so far.

#### Measured rate after the fix (full regeneration, 12 runs)

`bash user/build-user.sh` (full regeneration) then `bash build-scanout.sh`:

* **10/12 runs: all seven gates PASS** (SOCKTEST, POLLTEST, PORTTEST, FPTEST,
  MINIWL, NEWLIBTEST, SCANOUT), 544-line console.
* **2/12 runs: the pre-existing flake described in §6.1** — console stops at line
  178 inside the kernel dispatcher self-test, **zero** userland programs exec'd,
  and no trap report. It fails every gate *together* because it never reaches
  userland, which is the documented signature of that flake and is unrelated to
  this fix.
* **0/12 runs: the `sscratch` trap.** Before the fix it was deterministic on a
  regenerated tree.

#### Two claims from the old §6.2 withdrawn

* "regenerated, **zero** newlib, stock unmodified `build-user.sh` → MINIWL FAIL"
  **cannot have been a boot.** `rootfs.c` references `newlibtest_elf[]` and
  `newlibtest_elf_len`; a stock `build-user.sh` run rewrites `user_elfs.h`
  *without* those, so the kernel fails to **compile** (`error: 'newlibtest_elf'
  undeclared`). That row was a build failure, not a gate failure.
* "the failure is identical every time" and "lands immediately after miniwl forks
  its client" — **not identical**. Reproduced twice with different victims: once
  at the R-P12 pipes/dup2 gate (`scause=0xf`, `stval=0xffffed20`), once inside
  `usermode_entry` (`scause=0xc`, `sepc=stval=0x802002ae`). The variation is the
  tell that it is a race; a layout bug would land in the same place every time.
  (It *is* reliably at miniwl in the NC2 configuration, which is presumably what
  was originally sampled.)

#### Regeneration is re-enabled

`build-user.sh` now chains `build-newlibtest.sh` at the end, so a plain
`bash user/build-user.sh` is a **complete** regeneration that compiles — the two
scripts are no longer a trap for anyone touching userland. §8's surgical splice
is kept (it makes `build-newlibtest.sh` idempotent and separately runnable), but
it is no longer load-bearing and its banner no longer warns off regeneration.

---

## 7. What blocks the next rung (Rust), with the mechanism

Rung 3 was a trivial Rust binary. It does **not** work yet, and the blocker is not
the one the ABI-gap doc leads with.

1. **newlib is not the illumos libc.** The 16-symbol illumos ABI surface in
   `docs/riscv64-libc-rust-abi-gap.md` (`___errno`, `stack_getbounds`,
   `__xnet_*`, …) is what `rustc`'s `riscv64gc-unknown-illumos` target expects.
   newlib supplies **none** of those names — it is a different libc with a
   different ABI. So this result does not shorten that list; it proves the
   *kernel* is adequate, which is a different and previously open question.
2. **`stack_getbounds` is still fatal for Rust.** `std` wraps it in
   `assert_eq!(... == 0)`, so a stub aborts every Rust program at startup. That is
   unchanged by this work.
3. **No threads, and `__tls_get_addr` is still absent.** newlib here is
   single-threaded; its `__malloc_lock` is a no-op. Anything threaded needs the
   TLS/DTV work.
4. **`medlow` vs `medany` now applies to Rust too.** Rust compiles `medany` by
   default, so a Rust binary can link at `0xC0010000` — but if it links against a
   `medlow` C libc, the libc side is what constrains the base. §3.1 must be
   decided before mixing them.

**The honest summary:** the kernel's syscall surface is adequate for a real libc
that was not written to its limitations. The remaining work is a *libc port*
question (illumos ABI names, `stack_getbounds`, TLS), not a kernel-syscall
question.

---

## 8. How this avoids the regeneration regression (historical; now fixed)

**Status: the regeneration regression described here is FIXED (§6.2), and
`build-user.sh` now chains `build-newlibtest.sh` so a plain `bash
user/build-user.sh` is a complete regeneration.** The surgical behaviour below is
kept because it makes `build-newlibtest.sh` idempotent and runnable on its own,
not because regeneration is still dangerous.

When §6.2's breakage was live, the build here was deliberately **surgical**:

* `src/riscv/uts/user/build-newlibtest.sh` (new) builds `newlibtest.elf`, then
  **replaces only `init_elf[]`** (which must change — the gate call lives in
  `init.c`) and **appends `newlibtest_elf[]`** to the committed `user_elfs.h`.
  The other ten programs keep their committed bytes exactly.
* `build-user.sh` **chains** `build-newlibtest.sh` as its final step, so one
  command regenerates everything and the result compiles (`rootfs.c` needs
  `newlibtest_elf[]`).
* The rootfs member is added with `tar -r`, not by hand-splicing 512-byte blocks.
  An earlier version of the script scanned for a zero block to find the archive
  end; embedded ELF contents contain long zero runs, so it found a false end and
  cut `rootfs.img` from 450560 to 82944 bytes, losing 13 of 14 members. The script
  now asserts the member count only ever grows.

Once the `sscratch` fork bug is fixed, fold this into `build-user.sh` and delete
the splice.

**Update:** the bug is fixed (it was a trap-vector reentrancy bug, not a fork
bug) and the chaining is done. The splice itself is retained deliberately, per
the note above.

---

## 9. Files

New, under `src/riscv/uts/user/`:

| File | Purpose |
|---|---|
| `newlibtest.c` | the real-libc probe, 5 checks, one verdict line |
| `newlib_glue.c` | the OS port layer, every symbol tagged REAL/STUB/ENOSYS |
| `newlib.ld` | link script at `0x40010000` (§3.1), provides `__global_pointer$`, `__bss_start`, `_end` |
| `build-newlibtest.sh` | surgical builder + the provenance assertions |

Modified:

| File | Change |
|---|---|
| `src/riscv/uts/user/init.c` | `newlib_gate()`, run **last** so the newest gate cannot perturb the six established ones |
| `src/riscv/uts/rootfs.c` | `/bin/newlibtest` vfile entry + `vfile_len[12]` |
| `src/riscv/uts/user_elfs.h` | `init_elf` replaced in place, `newlibtest_elf` appended; no other program's bytes touched |

Reproduce:

```
cd src/riscv/uts
bash user/build-newlibtest.sh      # build + splice + provenance asserts
bash build-scanout.sh              # boot; check the console log for NEWLIBTEST PASS
```

---

## 10. Ordered remaining work

| # | Item | Effort | Why it is next |
|---|---|---|---|
| ~~1~~ | ~~Fix the `sscratch`/kernel-stack-top fork bug (§6.2)~~ | **DONE** | Was a trap-vector reentrancy bug in `_trap_entry`, not a fork bug: `sscratch` was left holding the interrupted `sp` across `trap()`, breaking the vector's own from-U discriminator. Fixed + negative-controlled in §6.2; `build-user.sh` regeneration re-enabled and measured 10/12 (2 losses are the unrelated pre-boot flake). |
| 2 | Real `fstat`/`stat` syscall over the vfs layer | **0.5–1 d** | Turns the two remaining STUBs REAL and lets newlib buffer stdio correctly; prerequisite for `fopen`. |
| 3 | Wire `_open` to `openat(2)` | **~2 h** | Trivial once 2 lands; gives real file I/O through a real libc. |
| 4 | Decide `medlow`-in-slot-1 vs rebuilding libc `medany` (§3.1) | **0.5 d decision, 1 d if rebuilding** | Every future real-libc program inherits this choice. |
| 5 | `stack_getbounds` REAL + the illumos ABI names | **~1 d** | The actual gate on Rust; kernel already fixes the stack bounds. |
| 6 | `AF_UNIX`/`__xnet_socketpair` and the rest of `docs/riscv64-libc-rust-abi-gap.md` §5 | as documented there | Unchanged by this work. |
| 7 | TLS/DTV + `__tls_get_addr` | **1–2 w** | Required before any threaded Rust program. |

Items 1–3 are small, well-diagnosed, and each removes a named stub or a named
trap.

---

## 11. The pre-boot flake, quantified

Separately from anything above, a boot occasionally dies **before userland**:
the console stops at line 178 of 546, inside the kernel dispatcher self-test
(`thread B: round 3 (ctx-switch to A)`), with **zero** `[exec]` lines and **no**
trap report. Because it never reaches userland it fails all seven gates
*together*, which is its distinguishing signature — any single-gate failure is a
real bug, not this.

Measured rate on the fixed kernel: **2 of 12** runs (`/tmp/fixrate-console-5.log`,
`/tmp/final-console-6.log`). It predates the §6.2 fix and is unaffected by it.
It is the next thing to chase for anyone who wants a green run every time; it is
also why gates here must be judged by rate rather than by a single pass.
