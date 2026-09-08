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

### 6.2 Refuted: "regeneration under the pin measures 6/6"

`build-user.sh`'s banner and the surrounding docs state that regenerating the
userland under the gcc 14.3.0 pin measures 6/6, the old breakage having been three
now-fixed kernel bugs. **Measured, that is no longer true.** Bisected, one boot
each:

| Configuration | MINIWL |
|---|---|
| Committed `user_elfs.h`, untouched | **PASS** (twice) |
| `bash user/build-user.sh` regeneration, `newlibtest` embedded but its gate call **removed** | **FAIL** |
| `bash user/build-user.sh` regeneration, **zero** newlib involvement, stock unmodified script, same pinned gcc | **FAIL** |

So **any** full regeneration breaks the miniwl gate, independent of this work and
independent of the compiler. The failure is identical every time and lands
immediately after miniwl forks its client:

```
[fork] pid 20 -> child pid 21
  [ok] fork the client
[trap] exception: scause=0x000000000000000f (store page fault)
       sepc=0x000000008020019e stval=0x00000000ffffecb0 sstatus=0x0000000200040020
[trap] unexpected trap -> parking hart.
```

Decoded: `sepc 0x8020019e` is `sd ra,0(sp)` — the **first store in `_trap_entry`**
(`trap.S`). `sstatus.SPP = 0`, so the trap came from U-mode. `stval 0xffffecb0` is
a **user** stack address (`USTACK_TOP 0xfffff000`, 64 KiB stack), and
`0xffffecb0 + 288 (TF_SIZE) = 0xffffedd0` is the `sp` the store used. So on that
trap **`sscratch` held a user `sp` where it must hold the per-process kernel stack
top**, and the kernel stored a trap frame onto the user stack.

That is a latent `sscratch`/kernel-stack-top bug on the fork path, exposed by any
change to userland size or layout. It is a real kernel bug, it is **not** a
compiler skew, and it deserves its own fix. It is out of scope here, so this work
routes around it (§8) rather than papering over it.

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

## 8. How this avoids the regeneration regression (do not undo)

Because §6.2 shows a full regeneration breaks miniwl, the build here is
deliberately **surgical**:

* `src/riscv/uts/user/build-newlibtest.sh` (new) builds `newlibtest.elf`, then
  **replaces only `init_elf[]`** (which must change — the gate call lives in
  `init.c`) and **appends `newlibtest_elf[]`** to the committed `user_elfs.h`.
  The other ten programs keep their committed bytes exactly.
* `build-user.sh` is left **unmodified** (git-clean), so nobody inherits the
  regeneration failure from this change.
* The rootfs member is added with `tar -r`, not by hand-splicing 512-byte blocks.
  An earlier version of the script scanned for a zero block to find the archive
  end; embedded ELF contents contain long zero runs, so it found a false end and
  cut `rootfs.img` from 450560 to 82944 bytes, losing 13 of 14 members. The script
  now asserts the member count only ever grows.

Once the `sscratch` fork bug is fixed, fold this into `build-user.sh` and delete
the splice.

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
| 1 | Fix the `sscratch`/kernel-stack-top fork bug (§6.2) | **0.5–1 d** | Unblocks `build-user.sh` regeneration, which is currently a trap for anyone touching userland. Fully diagnosed above; the fix is in `trap.S`/fork. |
| 2 | Real `fstat`/`stat` syscall over the vfs layer | **0.5–1 d** | Turns the two remaining STUBs REAL and lets newlib buffer stdio correctly; prerequisite for `fopen`. |
| 3 | Wire `_open` to `openat(2)` | **~2 h** | Trivial once 2 lands; gives real file I/O through a real libc. |
| 4 | Decide `medlow`-in-slot-1 vs rebuilding libc `medany` (§3.1) | **0.5 d decision, 1 d if rebuilding** | Every future real-libc program inherits this choice. |
| 5 | `stack_getbounds` REAL + the illumos ABI names | **~1 d** | The actual gate on Rust; kernel already fixes the stack bounds. |
| 6 | `AF_UNIX`/`__xnet_socketpair` and the rest of `docs/riscv64-libc-rust-abi-gap.md` §5 | as documented there | Unchanged by this work. |
| 7 | TLS/DTV + `__tls_get_addr` | **1–2 w** | Required before any threaded Rust program. |

Items 1–3 are small, well-diagnosed, and each removes a named stub or a named
trap.
