# crt/startup: what a Rust riscv64 PIE needs from `src/riscv/csu/`

Measured against a real artifact, not inferred: the 1.4 MB EM_RISCV PIE produced
by building `fn main(){ println!() }` for `riscv64gc-unknown-illumos` (see
`docs/riscv64-libc-rust-abi-gap.md` for the symbol side). Every requirement below
comes from `readelf`/`nm` on that binary.

## What `src/riscv/csu/` has today

| File | Provides | State |
|---|---|---|
| `crt1.s` | `_start`: clears `ra`/`fp`, sets `gp` from `__global_pointer$`, loads argc/argv/envp off the initial stack into a0/a1/a2, aligns sp, `call _init`, `call main`, `SYS_exit` | **Real and correct for a static, freestanding, non-PIE binary.** Its own comment says the full Solaris model routes through `__fsr`/`__start` instead. |
| `crti.s` / `crtn.s` | `_init`/`_fini` prologue+epilogue brackets for the `.init`/`.fini` sections | **Real**, standard illumos csu shape. |
| `rp39/libc/port/libc_start.c` | `__libc_start(argc, argv, envp)`: sets `environ`, calls `_init()`, `exit(main(...))` | **Real** but explicitly "no TLS setup, no `__libc_csu_init` array walk beyond `_init`". |

That combination is exactly what the 27-coreutils userland needs, and it works
(R-P63 boots against it). It is **not** what a Rust PIE needs.

## What the Rust PIE actually requires

| Requirement | Evidence from the binary | Have it? | Gap |
|---|---|---|---|
| **`__libc_start_main`** | `nm -D` shows `U __libc_start_main@GLIBC_2.34` | **No.** We have `__libc_start`, a different contract (ours is called BY `_start` with 3 args; `__libc_start_main` is called by the compiler's `Scrt1.o` and itself receives `main`, `argc`, `argv`, `init`, `fini`, `rtld_fini`, `stack_end` and never returns) | Provide a real `__libc_start_main`, or ship our own `Scrt1.o` whose `_start` calls `__libc_start`. The latter is less work and is the illumos-shaped choice. |
| **PIE-capable `_start`** | `Type: DYN (Position-Independent Executable)`, 1292 × `R_RISCV_RELATIVE` | **No.** `crt1.s` is built `-fno-pie`, and there is no `Scrt1.o` (the PIE variant) at all. | Add an `Scrt1.s` (PIC `_start`). The 1292 RELATIVE relocs must be applied by `ld.so.1` before `_start`, which is a runtime-linker requirement, not a crt one. |
| **A TLS segment** | `PT_TLS` present: filesz 0x21, memsz 0x90; `.tdata` 33 B, `.tbss` 104 B; 8 TLS symbols incl. `std::thread::current::CURRENT` and the thread-local destructor list | **No.** `libc_start.c` says "no TLS setup" outright. | Set the thread pointer (`tp`/x4) to a per-thread TLS block laid out per the RISC-V TLS ABI (variant I: `tp` points just past the TCB, `.tdata` copied in, `.tbss` zeroed). ~50 lines, but it must agree with the kernel's `tp` handling — note `uts/proc.c` currently **repurposes `tp` as the hart index / curthread hook**, which directly conflicts. See "the tp collision" below. |
| **`.preinit_array` / `.init_array` / `.fini_array`** | all three present, 8 bytes = 1 entry each | **Partially.** `_init()` runs `.init` fragments only; nothing walks the arrays. | Walk `.preinit_array`, then `.init_array` (ascending) before `main`, and `.fini_array` (descending) at exit. ~30 lines in `libc_start.c`. |
| **`__tls_get_addr`** | required non-weak import: `U __tls_get_addr@GLIBC_2.27`, reached via an `R_RISCV_JUMP_SLOT` | **No** | See the gap doc. Note it is imported **even though this binary has zero dynamic-TLS relocations** (0 × `DTPMOD`/`DTPREL`, i.e. local-exec TLS) — so it must exist as a symbol regardless, though it need not be *called* for a static-TLS binary. That distinction lowers the urgency but not the requirement. |
| **28 `pthread_*` entry points** | `pthread_create/join/detach/self/key_create/setspecific/mutex_*/cond_*/attr_*/setname_np` | **No.** No LWP layer exists. | Rust `std` references these from `sys::thread` even for a single-threaded program (they are pulled in by `std`'s thread and sync modules, not by user code). A single-threaded shim can satisfy many (`mutex_lock` on a uniprocessor, `pthread_self` returning a constant) but `pthread_create` cannot be faked. |
| **`environ`** | `U environ`, `U __environ` | **Yes**, `libc_start.c` sets `environ` | Also export `__environ` as an alias. |
| **`BIND_NOW` / `FLAGS_1: NOW PIE`** | `DT_FLAGS BIND_NOW`, full RELRO | n/a to crt | A runtime-linker requirement: all 170 `JUMP_SLOT` relocations must be resolved eagerly at load. |

## The `tp` collision — the one design conflict worth flagging early

RISC-V reserves `tp` (x4) for the thread pointer, and the TLS ABI requires it to
point at the thread's TLS block. The solnix kernel currently uses `tp` for
something else: `uts/proc.c` keeps the **hart index** there ("we keep it in tp
(the thread pointer): rv_swtch saves/restores tp per thread"), and `uts/swtch.S`
documents `tp` as "per-thread; we repurpose as curthread hook".

Those two uses are incompatible. Before any TLS-using userland binary can run,
one of them must move. The conventional resolution is the illumos/Linux one: `tp`
belongs to userland TLS, and the kernel keeps its per-CPU/per-thread pointer in a
supervisor CSR (`sscratch` is already used for the kernel stack top on trap
entry; `sstatus`-swapped `sscratch` or a per-hart array indexed from a CSR is the
normal pattern). **This is a kernel change, and it is on the critical path for
Rust — it is not a libc detail.** It is cheap to do now and expensive to
retrofit once more code depends on the current meaning.

## Ordered crt work

| # | Item | Effort | Blocking? |
|---|---|---|---|
| 1 | Move the kernel's `tp` usage off `tp` (to a CSR/per-hart array); free `tp` for userland TLS | **1–2 d** | **Yes** — everything TLS waits on it |
| 2 | `Scrt1.s`: a PIC `_start` for PIE, plus `crt1.s` kept for static | **0.5 d** | Yes |
| 3 | TLS setup in libc startup: allocate the block, copy `.tdata`, zero `.tbss`, set `tp` | **1–2 d** | Yes |
| 4 | `.preinit_array`/`.init_array`/`.fini_array` walking | **0.5 d** | Yes |
| 5 | `__libc_start_main` (or keep `__libc_start` + our own Scrt1) + `__environ` alias | **0.5 d** | Yes |
| 6 | Single-threaded `pthread_*` shim (uniprocessor mutex/cond, real TSD via TLS, `pthread_create` = ENOSYS) | **3–5 d** | Yes for linking; `pthread_create` only for threads |
| 7 | Real LWP layer behind `pthread_create` | **weeks** | Only for threaded programs |

Items 1–5 are roughly **a week** and are what stands between "the binary links"
(already true) and "the binary reaches `main` on solnix".
