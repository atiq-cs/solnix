# The riscv64 illumos libc ABI surface Rust needs: measured gap table

Scope: what the solnix riscv64 userland must supply for `rustc` (and therefore
all of COSMIC) to link and run natively. This audits the claim in
`docs/cosmic-riscv64-feasibility.md` §1.4 against three primary sources rather
than restating it:

1. **The real illumos gate** (`usr/src/lib/...` mapfiles + bodies) for where each
   symbol actually lives and what it actually does.
2. **The solnix riscv64 kernel** (`src/riscv/uts/`) for whether the syscall
   behind each symbol exists.
3. **`nm --undefined-only` on the built riscv64 rlibs** for what Rust genuinely
   references, plus the `std` source for whether a failure is survivable.

Every REAL / STUB-OK / MISSING verdict below is traceable to one of those.

---

## 0. Three corrections to the §1.4 list

**(a) Six of the "illumos-libc-only" twelve are not in libc.** All seven
`__xnet_*` entries live in **libsocket** (and libxnet), not libc:
`lib/libsocket/common/mapfile-vers` exports them and
`lib/libsocket/socket/weaks.c` defines them. This matters because it changes what
we must build: they are not part of a libc port, they are a libsocket port.

**(b) The list is incomplete — the surface is 16 symbols, not 12.** Four more
illumos-libc-only symbols are referenced by `std`/`libc` and were missed:

| Missed symbol | Home (gate) | Why the study's link did not see it |
|---|---|---|
| `__major` | `libc/port/mapfile-vers`, `gen/mkdev.c` | referenced from the **libc crate**, not `std`; unreferenced by the study's probe binary |
| `__minor` | same | same |
| `__makedev` | same | same |
| `__tls_get_addr` | `libc/port/mapfile-vers` | **masked by the Linux cross host** — glibc's `ld-linux-riscv64-lp64d.so.1` supplies it, so the link succeeded. On illumos our `ld.so.1` must. Verified: `nm -D libc.so.6` shows it as `U`. |

`__tls_get_addr` is the significant one: it is the dynamic-TLS entry point, so it
is a **runtime-linker** deliverable, and cross-linking on Linux will keep hiding
it. Any future harvest must use `nm --undefined-only` on the rlibs, not the
linker's error list.

**(c) `__xnet_bind` does belong on the list.** A first harvest from linker output
showed only 11 symbols and appeared to exonerate it. That was an artifact of the
linker truncating its report (238 `undefined reference` lines, deduplicated and
capped). `nm --undefined-only` on `libstd.rlib` shows `__xnet_bind` undefined
like the other six. **Method note: trust `nm` on the rlibs, not linker stderr.**

---

## 1. The symbol gap table

Verdict column:
- **REAL** — we can implement genuine working behaviour with what exists today.
- **REAL (needs kernel)** — implementable, but a named kernel change lands first.
- **STUB-OK** — a link-satisfying stub is *honest* here, because the caller
  tolerates failure (documented per row).
- **MISSING** — no implementation possible now; the facility does not exist.

| # | Symbol | Home library (gate) | Our libc has it? | Kernel syscall behind it | Verdict | What it takes |
|---|---|---|---|---|---|---|
| 1 | `___errno` | **libc** `port/gen/errno.c` | **no** (has a plain `int errno` global, `rp48/libc/port/syscall.c:16`) | none (pure userland) | **REAL** | Real body is `return curthread->ul_errnop`. We are single-threaded, so `return &errno` is *correct today* and becomes wrong the moment threads land. Implemented; commented as such. |
| 2 | `getexecname` | **libc** `port/gen/getexecname.c` | **no** | none, but reads **`AT_SUN_EXECNAME` (2014)** from auxv | **REAL (needs kernel)** | Gate body is `___getauxptr(AT_SUN_EXECNAME)`. `uts/uproc.c` supplies only `AT_PAGESZ/ENTRY/UID/EUID/GID/EGID` — no execname. Add one auxv entry (kernel already has the exec path string). ~20 lines kernel + 15 libc. |
| 3 | `stack_getbounds` | **libc** `port/gen/stack.c` | **no** | none (reads per-thread stack record) | **REAL** | Gate body is `*sp = curthread->ul_ustack`. Kernel already fixes the bounds: `USTACK_TOP 0xfffff000`, `USTACK_PAGES 16` (64 KiB) in `uts/uproc.c`. **Must be real: `std` wraps it in `assert_eq!(... == 0)`** (`pal/unix/stack_overflow.rs:326`) — a stub returning -1 aborts every Rust program at startup. |
| 4 | `pset_info` | **libc** `port/sys/psetsys.c` | **no** | **`SYS_pset` (207)** — absent | **REAL (partial)** | Gate body is `_pset(PSET_INFO, ...)`. We need only the `PS_MYID`/`numcpus` case that `std::thread::available_parallelism` calls. Kernel already tracks CPUs (`ncpu_online` in `uts/main.c`, `SYS_ncpu` already wired into `rp48` libc), so the answer is real data, not a guess. Full `SYS_pset` (create/destroy/bind) is out of scope. |
| 5 | `__posix_getpwuid_r` | **libc** `port/gen/getpwnam_r.c` | **no**, but `getpwuid` exists (`rp41/libc/port/misc.c:273`, scans `/etc/passwd`) | none (file-backed) | **REAL** | Gate body is a POSIX-errno wrapper over `getpwuid_r` (returns errno rather than setting it). Our `/etc/passwd` scanner is the same "files" nsswitch backend reduced to one file, so a real reentrant wrapper over it is genuine. |
| 6 | `__major` | **libc** `port/gen/mkdev.c` | **no** | none (pure bit math) | **REAL** | Trivial and exact: shift/mask on `dev_t` per the versioned `major_t` encoding. |
| 7 | `__minor` | **libc** `port/gen/mkdev.c` | **no** | none | **REAL** | As above. |
| 8 | `__makedev` | **libc** `port/gen/mkdev.c` | **no** | none | **REAL** | As above. |
| 9 | `__tls_get_addr` | **libc** `port/mapfile-vers` (runtime linker surface) | **no** | none, but needs a TLS/DTV model | **MISSING** | Dynamic-TLS resolver. Needs a DTV per thread and `ld.so.1` TLS relocation handling. Our `ld.so.1` has no TLS support. **Masked by glibc when cross-linking** — will not surface until a native link. Real work, not a stub: returning a bogus address corrupts thread-local state silently. |
| 10 | `__xnet_socket` | **libsocket** `socket/socket.c:77` | **no** | `SYS_so_socket` (230) — **absent** | **MISSING** | See §2: there is no socket layer or IP stack in the kernel at all. |
| 11 | `__xnet_socketpair` | **libsocket** `socket/socketpair.c:78` | **no** | `SYS_so_socketpair` (231) — **absent** | **MISSING** (nearest-term of the seven) | `AF_UNIX` socketpair needs no IP stack — it is a bidirectional pipe. The kernel *already has pipes* (`proc_pipe`, `SYS_pipe2`). This is the one `__xnet_*` reachable without a network stack. |
| 12 | `__xnet_bind` | **libsocket** `socket/weaks.c:221` | **no** | `SYS_bind` (232) — **absent** | **MISSING** | Thin `_so_bind(..., SOV_XPG4_2)` shim. Needs the socket layer. |
| 13 | `__xnet_connect` | **libsocket** `socket/weaks.c:234` | **no** | `SYS_connect` (235) — **absent** | **MISSING** | Thin `_so_connect(..., SOV_XPG4_2)`. |
| 14 | `__xnet_sendto` | **libsocket** `socket/weaks.c:252` | **no** | `SYS_sendto` (242) — **absent** | **MISSING** | Thin `_so_sendto(..., MSG_XPG4_2)`. |
| 15 | `__xnet_getsockopt` | **libsocket** `socket/weaks.c:260` | **no** | `SYS_getsockopt` (245) — **absent** | **MISSING** | Thin `_so_getsockopt`, plus an SCTP special case. |
| 16 | `__xnet_getaddrinfo` | **libsocket** `common/mapfile-vers:90` | **no** | none directly; needs resolver + `/etc/hosts` | **MISSING** | Name resolution. Above the socket layer, so it is gated by everything in §2. |

### Summary count

| Verdict | Count | Symbols |
|---|---|---|
| **REAL** (implementable now) | 6 | `___errno`, `stack_getbounds`, `pset_info`, `__posix_getpwuid_r`, `__major`/`__minor`/`__makedev` (counting mkdev trio as 3 → 8 rows, 6 distinct facilities) |
| **REAL (needs a small kernel change)** | 1 | `getexecname` (one auxv entry) |
| **MISSING (real facility absent)** | 8 | 7 × `__xnet_*` + `__tls_get_addr` |

So: **9 of 16 are reachable now** (8 REAL + `getexecname`), and **7 of 16 are
gated on a socket/IP stack** that does not exist, plus `__tls_get_addr` gated on
TLS in the runtime linker.

---

## 2. The honest blocker behind all seven `__xnet_*`

**There is no socket layer, and no IP stack, anywhere in the solnix riscv64
kernel.** Verified by grep across `src/riscv/uts/` and
`src/riscv-port/*/kernel/`: zero occurrences of `sockaddr`, `struct socket`,
`so_state`, `tcp_`, or `ip_output`.

The syscall dispatcher (`uts/syscall.c`) implements **21** syscalls:
`write read openat lseek close pipe2 dup3 sync remount getpid brk fork execve
wait4 exit kill rt_sigaction rt_sigreturn setuid setgid getuid` (+ two
report/debug traps and `chdir/getcwd/ncpu` reachable from the rp48 libc). None
of illumos's nine socket syscalls (230–245) is among them.

What networking *does* exist is one raw-frame device path: `uts/vionet.c`
transmits a single hand-built ARP frame with polled completions, explicitly "no
GLDv3 binding, no mac/mergeable-rx", and `rp63/kernel/emac.c` is a K1 MAC
register driver. That is a NIC bring-up proof, not a network stack.

**Therefore any `__xnet_*` "implementation" that is not preceded by a socket
layer is necessarily a stub, and would be a lie to report otherwise.** The
ordered work is: AF_UNIX socket layer → `socketpair`/`bind`/`connect` for local
sockets → a TCP/IP stack → `getaddrinfo` resolver. That is the multi-week item.

**One exception worth noting:** `__xnet_socketpair` for `AF_UNIX` is a
bidirectional pipe, and the kernel already has pipes (`proc_pipe`). It is the
only one of the seven reachable without an IP stack, and it is the one Rust's
own test/process plumbing hits first.

---

## 3. The illumos-only libraries: which need real code

The study lists `-lsocket -lposix4 -lnsl -lumem -lsendfile -llgrp -lssp
-lresolv` (+`-lmd -lmp`). On illumos several of these are *filter* libraries
whose symbols are actually in libc — so the honest question per library is
"real objects, or a link-time redirection?" Answered from the gate's
`Makefile.com`/`mapfile-vers`:

| Library | What it really is (gate evidence) | For us |
|---|---|---|
| **libposix4** | **Not a library at all.** `lib/librt/Makefile.com` creates it as a `COMPATLINKS` symlink to `librt.so.1`. | **STUB-OK** — a symlink/empty `.so`. Nothing to implement. |
| **librt** (what libposix4 points at) | **Whole-library filter on libc**: `DYNFLAGS += -F libc.so.1`, 75 symbols, **zero objects**. Every symbol resolves in libc at runtime. | **STUB-OK as a library**, but the 75 symbols (timers, `sem_*`, `mq_*`, `clock_nanosleep`) must eventually exist *in libc*. |
| **libsocket** | **Real objects** (`INETOBJS + SOCKOBJS`) plus 7 `FILTER = libc.so.1` lines for byte-order/`inet_*` helpers. | **REAL code needed** — this is where the seven `__xnet_*` live. Gated by §2. |
| **libnsl** | **Real objects** + 8 FILTER lines. | **REAL code needed** eventually; `std` links it but the demanded symbols are the `__xnet_*`/resolver set, so it follows §2. |
| **libumem** | **Real**, 18 `.c` files — a full slab allocator. | **STUB-OK for now, honestly**: `std` links it only to get a malloc-compatible allocator. Our libc already has a first-fit `malloc`. Not a correctness gap, a performance one. |
| **libsendfile** | **Real**, one object (`sendfile.o`). | **STUB-OK** — `std` does not call `sendfile` on illumos; the libc crate declares it. Would need the syscall to be real. |
| **liblgrp** | **Real**, one object (`lgrp.o`). NUMA topology. | **STUB-OK** — declared by the libc crate, not called by `std`. Meaningless on the single-node K1. |
| **libresolv** | Real (BIND resolver). | **STUB-OK until DNS matters** — gated by §2 anyway. |
| **libmd / libmp** | Real (message digests / multiprecision). | **STUB-OK** — transitive; nothing in `std`'s path calls them. |
| **libssp** | GCC stack-protector runtime. | **STUB-OK or real-cheap** — satisfied by `-fno-stack-protector`, or by 3 real functions (`__stack_chk_fail` etc.). |

**Net:** of the ten libraries, **eight are link-satisfying only** for the
Rust-startup path (`libposix4`, `librt`, `libumem`, `libsendfile`, `liblgrp`,
`libresolv`, `libmd`, `libmp`, `libssp`), and **two need real code**
(`libsocket`, `libnsl`) — both blocked on the socket layer, not on libc.

That is a genuinely encouraging result: the *library* list is far less work than
it looks. The hard part is concentrated in exactly one place, §2.

---

## 4. What `std` tolerates — why some stubs are honest and others are not

Read from the `std` source, because "is a stub acceptable?" is decided by the
caller, not by us:

| Symbol | Call site | If it fails |
|---|---|---|
| `stack_getbounds` | `pal/unix/stack_overflow.rs:326`, inside `assert_eq!(... == 0)` | **process aborts at startup.** Must be REAL. |
| `___errno` | every errno read in `std`/`libc` | **wrong errno everywhere**, silently. Must be REAL. |
| `__tls_get_addr` | dynamic TLS access | **silent memory corruption** if wrong. Must be REAL. |
| `pset_info` | `thread/unix.rs:290`, `available_parallelism` | returns `Err(UNKNOWN_THREAD_COUNT)`; callers fall back to 1. Survivable. |
| `getexecname` | `paths/unix.rs:309`, `env::current_exe` | returns `Err`. Survivable. |
| `__posix_getpwuid_r` | `env::home_dir` | returns `None`. Survivable. |
| `__xnet_*` | all networking | networking fails. Survivable for a non-networked program; fatal for anything that opens a socket. |

This is the line between an honest stub and a dishonest one, and it is why
`stack_getbounds` is implemented for real below while `__xnet_*` are left as
explicitly-failing `ENOSYS` rather than plausible-looking fakes.

---

## 5. Ordered remaining work, with estimates

| # | Item | Effort | Notes |
|---|---|---|---|
| 1 | `AT_SUN_EXECNAME` in the kernel auxv + `getexecname` | **~0.5 d** | Kernel already has the path string; one auxv slot. |
| 2 | `SYS_pset` (PSET_INFO subcode only) | **~0.5 d** | Kernel already counts CPUs. |
| 3 | Thread-aware `___errno` + `stack_getbounds` when threads land | **~1 d** | Correct today single-threaded; revisit with the first LWP. |
| 4 | `libssp` real (3 functions) + the 8 stub libraries as real empty filters | **~1 d** | Mechanical. |
| 5 | **AF_UNIX socket layer** (`socketpair`, then `bind`/`connect`/`send`/`recv` on local sockets) | **1–2 w** | Reuses the existing pipe machinery. Unlocks `__xnet_socketpair` and most of Rust's process plumbing. |
| 6 | TLS/DTV in `ld.so.1` + `__tls_get_addr` | **1–2 w** | Required before any threaded Rust program. Hidden by cross-linking today. |
| 7 | **TCP/IP stack + GLDv3 NIC binding** | **1–3 mo** | The real blocker. `vionet.c`/`emac.c` give the frame layer; everything above is missing. |
| 8 | `getaddrinfo`/resolver + `/etc/hosts`, `libnsl`/`libresolv` real | **2–3 w** | After 7. |
| 9 | `libumem` real slab allocator | **2–4 w** | Performance, not correctness. Defer. |

**Critical path to "a Rust program runs":** items 1–4 (~3 days) get a
*non-networked, single-threaded* Rust binary linking against a real libc.
Items 5–6 get threads and local sockets. Item 7 is what "COSMIC networking"
waits on, and it is the honest multi-month piece.
