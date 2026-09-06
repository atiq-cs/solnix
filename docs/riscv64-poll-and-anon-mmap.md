# poll(2), anonymous mmap, and what actually still blocks a compositor

This documents the syscalls added for a Wayland compositor's main loop, the
behavioural evidence for each, and -- more usefully -- the two pre-existing
kernel bugs that finding them exposed. One of those bugs is the real first wall
in front of `smallvil`, and it is neither `poll` nor `mmap`.

Companion docs: `riscv64-scanout-seam.md` (Gate B, the display),
`riscv64-libc-rust-abi-gap.md` (the measured ABI surface),
`milkv-cosmic-plan.md` (Gate A/B framing),
`riscv64-fpu-context-switch-spec.md` (the fix for the wall in section 5),
`riscv64-event-ports-sizing.md` (what `calloop` actually needs, section 7 item 2).

## 1. What is REAL, and what is still ENOSYS

Same tagging discipline as `src/riscv/libc/port/illumos_abi.c`: `[REAL]` means a
real path all the way to the kernel; `[ENOSYS]` means the facility genuinely does
not exist and says so rather than returning a plausible-looking answer.

| Facility | Tag | Where |
|---|---|---|
| `poll(2)` over sockets / pipes / tty / regular files / `/dev/fb` | **[REAL]** | `uts/uproc.c` `proc_poll`, `uts/unixsock.c` `unsock_poll` |
| `POLLIN`/`POLLOUT`/`POLLHUP`/`POLLERR`/`POLLNVAL`, level-triggered | **[REAL]** | `uts/uproc.c` `fd_ready` |
| poll timeout: `0` (immediate), `>0` (ms), `-1` (block) | **[REAL]** | `proc_poll`, deadline from `gethrtime()` |
| `mmap(MAP_ANON\|MAP_PRIVATE)`, zero-filled, multi-page | **[REAL]** | `uts/as.c` `as_anon_map`, `uts/uproc.c` `proc_mmap_anon` |
| `clock_gettime(CLOCK_MONOTONIC / CLOCK_REALTIME)` | **[REAL/BOOT-RELATIVE]** | `uts/syscall.c`; both read the `time` CSR. There is no time-of-day source on this platform, so REALTIME is monotonic-since-boot and says so rather than inventing an epoch |
| `munmap` | **[ENOSYS]** | no unmap primitive in the hat; the anon arena is a bump allocator reclaimed at process exit. Shipping a `munmap` that silently leaked would be worse than not having one |
| `select`/`pselect` | **[ENOSYS]** | not implemented. `poll` is the primitive; a `select` shim over it belongs in libc, not the kernel |
| `ppoll` (timespec + sigmask) | **[ENOSYS]** | syscall 73 is taken with `poll`'s flat-millisecond shape; the sigmask half is not implemented |
| file-backed `mmap` (other than `/dev/fb`) | **[ENOSYS]** | needs a real `seg_vn`; returns `ENODEV` |
| FP state preserved across a context switch | **[BROKEN, pre-existing]** | see section 5 -- the wall |
| `pthread_create` / threads | **[ENOSYS]** | see section 6 |
| `dlopen` | **[ENOSYS]** | see section 6 |

`poll` is syscall **73**. The riscv Linux ABI has no plain `poll` slot, only
`ppoll`, so 73 carries `poll`'s argument shape (a2 = timeout in milliseconds,
negative = block). That is the same trade already made for `sendmsg`/`recvmsg`:
the kernel entry point stays flat and total, and the richer POSIX shape belongs
in libc, which is where illumos puts it.

`MAP_ANON` is **0x100** on illumos, not Linux's 0x20. The kernel refuses 0x20
explicitly with `EINVAL` and a console line rather than treating it as a file
mapping of fd 0x20 -- a prior Rust binary tripped exactly this, and a silently
wrong mapping is far harder to diagnose than an error.

## 2. Level-triggered, and why that is the whole design

This project has repeatedly been bitten by readiness bugs on illumos -- see
`cosmic-shell-session-layer.md`, and the `calloop-wayland-source` and
`wayland-client` timer-dispatch patches, all of which exist because a
level-triggered source never fired and clients hung at handshake.

So `proc_poll` holds **no per-fd state between calls**. `fd_ready()` recomputes
every answer from the current ring cursors (`d_wpos - d_rpos`), backlog depth,
queued-rights count and reference counts. There is no arrival edge to miss:

* a socket that **already** has buffered bytes reports readable on the **first**
  poll, not on the next write;
* the scan runs **before** any waiting, on every pass of the wait loop;
* polling twice without consuming returns readable twice, because the condition
  still holds.

`POLLIN` means "a read will not block", which **includes EOF**. A socket or pipe
whose peer has gone reports `POLLIN|POLLHUP`, because `read()` returns 0
immediately and an event loop watching only `POLLIN` must still learn the client
left. `POLLERR` is reported only where the kernel can really tell a write would
fail (all readers gone), never as a catch-all. `POLLNVAL` counts toward the return
value, as POSIX requires; a negative fd is ignored with `revents` cleared, which
is how `calloop` parks unused slots.

`/dev/fb` reports `POLLOUT` and deliberately **not** `POLLIN`: `read()` on it
returns 0 forever, so a compositor told "readable" would spin.

## 3. The evidence

`uts/user/polltest.c`, run as a boot gate by `/sbin/init`: **35 checks, 0
failed**, in a separately exec'd process. Not return codes -- observed behaviour:

* **Readiness transitions.** The same descriptor is polled before and after the
  peer writes and the answer must *change*; then the data is consumed and it must
  change back. A constant answer of either kind fails.
* **The level-triggered case.** Bytes are written *before* poll is ever called,
  and the first poll must see them; a second poll with the data unconsumed must
  still report readable; and the bytes must still be intact afterwards (poll must
  not consume).
* **The timeout really blocks.** Measured across the call with
  `CLOCK_MONOTONIC`: a 200 ms timeout took **203 ms**, and timeout 0 took 0 ms.
  "Returned 0" is identical for a poll that waited and one that returned
  instantly, and the difference is a compositor burning a core.
* **`timeout = -1` is woken by another process.** A forked child writes while the
  parent is blocked in poll; the parent returns `POLLIN` and the promised bytes
  are really there. This is the compositor's actual situation -- readiness comes
  from another address space scheduled independently.
* **Many fds at once.** Three descriptors, exactly one with data: poll returns 1
  and flags only that one. A poll that flagged everything would pass every
  single-fd check above and still be useless.
* **Anonymous mmap.** Checked zero-filled *first* (a recycled page would pass a
  write-then-read test while leaking data), then written and read back across all
  3 pages, then a second mapping proved distinct and non-overlapping, and Linux's
  `MAP_ANON` value proved refused.

### The negative control

`poll_negative_control()` pins the answer from **both** sides, so neither a
constant-yes nor a constant-no implementation can pass the file:

* **CONTROL A** -- an empty socket must not be `POLLIN`. This flips to FAIL if
  poll ever reports readiness unconditionally (the single most likely way this
  subsystem regresses into uselessness, and the way that makes a compositor spin).
* **CONTROL B** -- a socket with data must be `POLLIN`. Flips if poll ever
  reports unreadiness unconditionally.
* **CONTROL C** -- the two answers must *differ*, i.e. poll is reading real state
  rather than returning a constant.

Verified to be load-bearing rather than decorative: the mechanism was sabotaged
and the control did flip to FAIL while the positive checks still passed.

## 4. Pre-existing bug found: the idle thread on the shared runq

**This was the boot-flakiness root cause.** `uts/proc.c` had two guards meant to
keep the idle thread off the run queue:

```c
if (self->t_state != TS_IDLE)      /* thread_yield  */
if (self->t_state == TS_IDLE)      /* thread_preempt */
```

Neither could ever fire. `TS_IDLE` is declared in `tstate_t` but **nothing ever
assigns it**: `dispatch_init_cpu` marks the idle thread `TS_ONPROC`, and `swtch`
marks every incoming thread `TS_ONPROC`. So both guards were dead code, and every
`idle_body` yield published the idle thread onto the **one global** runq -- where a
different hart dequeued and resumed it while its owning hart was still executing
on that same stack and `kthread_t`. Two harts running one thread.

It presented far from the cause: a wild `sepc` (`0xfffffffffffffffc`, `0x0`),
`[disp] thread A/B context-switch FAILED`, or a stall anywhere later in the boot,
intermittently.

Fixed by testing **identity** rather than state (`self == idlethread[cpu]`), and
`TS_IDLE` is now commented as never-assigned so the mistake is not repeated.

Confirmed by mechanism, not correlation: a scratch-instrumented `runq_dequeue`
printed `DOUBLE-RUN: dequeued thread N is STILL curthread on cpu X while cpu Y
takes it`.

| Kernel | Clean boots |
|---|---|
| before the fix | **2/10** |
| only this guard changed | **8/10** |
| final kernel (poll + mmap + fix) | **6/6** |

This also reframes the "~5/6 boots" baseline the userland blobs were being judged
against: that was this race, not the blobs.

## 5. Pre-existing bug found: NO FP STATE IS SAVED ACROSS A SWITCH

**This is the real first wall for `smallvil`, and it is not `poll` or `mmap`.**

A hard-float (`lp64d`) probe (`uts/user/fptest.c`) forks. The parent stamps
`f0`-`f7` with `0x1111111122222222`, the child with `0x3333333344444444`; both
spin through several 100 Hz preemptions, then read the registers back. The parent
reads back `xor = 0x2222222266666666`, which is **exactly**
`PAT_PARENT ^ PAT_CHILD` -- the parent found the *child's* values in its own FP
registers. Reproducible 3/3 boots.

Mechanism, confirmed by inspection and consistent with the evidence:

* **zero** `fsd`/`fld`/`f[0-9]` instructions in `swtch.S`, `trap.S` or `copy.S`;
* **zero** `TF_F*` slots in `asm_frame.h` -- the trap frame has no FP area at all;
* `uts/fpu.c` **exists** (imported from `n-hys/illumos-gate`) but is in **no**
  build script;
* every trap log shows `sstatus = 0x...6120`, i.e. **FS=3 (Dirty)**: the FPU is
  enabled and accumulating state that nothing preserves.

Why it is the wall rather than a footnote: the Rust `riscv64gc-unknown-illumos`
target is **`lp64d`** (`"features": "+m,+a,+f,+d,..."`, `"llvm-abiname": "lp64d"`)
and llvmpipe is nothing but float. Two concurrent hard-float processes therefore
corrupt each other silently, and a software rasterizer produces **garbage pixels
rather than an error** -- the worst possible failure mode, and one that would be
blamed on Mesa or on the framebuffer seam for a long time.

This is why it hid until now: the entire existing userland is built
**soft-float** (`-march=rv64imac`, "soft-float ABI" in every ELF header), so
nothing has ever put a live value in an FP register.

**Deliberately not fixed here.** Wiring the FPU in, choosing where the FP state
lives, and choosing an FS-bit lazy-switch policy (save only when FS=Dirty, which
is the whole point of the FS field) is its own change, and it must be judged by
boot rate over several attempts rather than by inspection. Half-doing it would
produce exactly the kind of plausible-looking-but-wrong subsystem this project's
tagging discipline exists to prevent. `fptest.c` is the regression gate for it.

The finding of record is `docs/riscv-no-fp-context-switch.md`; **the fix is fully
specified in `docs/riscv64-fpu-context-switch-spec.md`** so it need not be
re-derived: why `fpu.c` cannot simply be compiled (it needs the illumos ctxop
framework, which this port does not have) while `float.s` *is* directly usable, why
the FP state belongs behind one pointer in `rv_context` rather than in the trap
frame (the frame's alignment pad is already `TF_CPUID`, and the eager design would
put 264 bytes of `fsd` on every timer tick), the FS lazy-switch policy, and what
`fork`/`exec`/signal delivery each must do. One design-deciding measurement from
that doc is worth repeating here: **the linked kernel contains zero FP instructions
and is itself soft-float**, so pure lazy save/restore is available and no kernel
path can clobber FP.

## 6. Threads and dlopen, assessed honestly

Neither is implemented, and neither should be half-implemented. What each would
actually cost against *this* kernel's process/VM model:

### `pthread_create` / threads

The kernel already has most of the machinery, which makes this smaller than it
looks -- but three specific things are missing, and one of them is a correctness
trap:

1. **Multiple threads per address space.** `proc_t` has exactly one
   `p_thread` and one `p_uframe`. An LWP list per process is needed, each with its
   own user frame and kernel stack. The dispatcher itself already handles many
   kernel threads, so this is bookkeeping, not new mechanism. (~3-5 days)
2. **A thread-stack allocator.** Now trivial: `as_anon_map` (this change) is
   exactly the primitive, and `MAP_ANON` is what a real `pthread_create` uses for
   stacks. (~0, already done)
3. **`tp` per thread, and TLS.** `tp` already belongs to userland in U-mode (the
   split is resolved), and it is already saved/restored per context. Each LWP just
   needs its own TLS block. Static TLS would work; `__tls_get_addr` (dynamic TLS)
   still needs a DTV and is `[ENOSYS]`. (~2-3 days for static TLS)
4. **THE TRAP: FP state.** Section 5. Threads would *multiply* that corruption
   rather than expose it -- concurrent LWPs in one AS sharing FP registers with no
   save/restore. **Threads must not land before the FPU fix.**
5. **A second trap: the global `curproc`.** Every blocking path in `uproc.c` and
   `unixsock.c` restores `curproc` by hand after each `sleep_on`/`thread_yield`
   (`curproc = self;`), because `curproc` is one global. That idiom is already
   fragile with one thread per process and becomes untenable with several; it
   wants to be per-CPU/per-thread state. (~2-3 days, and worth doing first)

**Can a compositor work single-threaded? Yes -- and this is the useful scoping
result.** A Wayland compositor's main loop is single-threaded by design: it polls,
dispatches, renders, repeats. `smallvil` is single-threaded. Rust std tolerates a
single-threaded world: `available_parallelism` falls back to 1 (`pset_info` is
already `[REAL, subcode-limited]`), and `___errno` is tagged `[REAL/1THREAD]`
precisely because it is *correct today* and becomes wrong the moment threads land.
llvmpipe wants worker threads for speed but runs single-threaded
(`LP_NUM_THREADS=0`). So threads are a **performance** item, not a gate.

### `dlopen`

Genuinely large here, and further away than threads:

* `uts/elf.c` is **175 lines** and loads **`ET_EXEC` static only** -- it rejects
  `e_type != ET_EXEC` outright. No `PT_INTERP`, no `PT_DYNAMIC`, no `ET_DYN`/PIE
  relocation.
* There is **no `ld.so.1`** on riscv64. `dlopen` on illumos *is* the runtime
  linker; the syscall layer is the easy half.
* It needs `mmap` of a **file** at an offset with per-segment protections. We have
  anonymous mmap and one device mapping; file-backed `mmap` needs a real `seg_vn`
  (`[ENOSYS]` above), and the arena has no `munmap`.
* It needs the full RISC-V dynamic relocation set, `DT_*` processing, symbol
  binding, and `__tls_get_addr` + a DTV for dynamic TLS.

Estimate: **weeks, not days** -- and it is the same work as "run a dynamically
linked binary at all", so it is not `dlopen`-specific.

**Can a compositor work with static linking only? Yes, with one named caveat.**
Rust links statically by default and `-Zbuild-std` produces a static binary; the
target JSON does say `"dynamic-linking": true` and `"position-independent-executables": true`,
so a `crt-static` build (and likely an `ET_EXEC` rather than PIE link) is needed
to match what `elf.c` accepts. The caveat is **Mesa**: llvmpipe/lavapipe are
normally `dlopen`'d as a Vulkan/GL ICD, and
`src/drm-port/powervr/POWERVR-STATUS.md` describes the PowerVR driver as
"dlopen-able". A software-rendered compositor that links its rasterizer statically
avoids this; one that loads an ICD at runtime does not. That is a build-time
choice, so it does not need `dlopen` in the kernel -- but it must be made
deliberately.

## 7. So what actually stops `smallvil`, in order

1. **FP state across a context switch** (section 5). Hard blocker: the Rust target
   is `lp64d`. Everything else is downstream of this.
2. **The event mechanism is not `poll(2)`.** Worth stating plainly, because it
   corrects an assumption: `calloop` (which `smithay`/`smallvil` use) goes
   `calloop` -> `polling 3.11` -> `rustix::event::port` ->
   **`port_create`/`port_associate`/`port_getn`** on illumos -- **event ports**,
   not `poll`. `wayland-backend`'s server backend uses **`epoll`** (illumos has a
   native `epoll(5)` shim over event ports; `src/drm-port/wayland-backend-illumos-epoll.patch`
   already relies on that). So `poll(2)` is **necessary but not sufficient**: it is
   what libc, hand-written loops, and the port/epoll shims themselves sit on, and
   without it none of them can exist -- but a further `port_create`/
   `port_associate`/`port_getn` layer (or the `epoll` shim over it) is needed
   before `calloop` runs. That layer is a natural fit over `fd_ready()`, which
   already computes exactly the readiness those interfaces report.
   **Sized at ~4 days (+1-2 for the epoll shim) in
   `docs/riscv64-event-ports-sizing.md`**, which also records two findings that
   shrink it: `polling` uses event ports in **oneshot mode only**, and `calloop`
   already emulates level-triggering in software for exactly this backend.
3. **The fd table is 8 slots.** A compositor holds a listening socket plus one or
   two fds per client plus the framebuffer. `NPOLLFD` is capped at 16 for the same
   reason. Both are easy, but they are hard limits a real client will hit.
4. **A dynamic loader, or a deliberate fully-static build** (section 6).
5. **`munmap`** -- an allocator that maps and unmaps in a loop exhausts the bump
   arena. Needs the same `seg_vn` work as file-backed `mmap`.
6. **The poll wait is a yield loop**, not a per-object wait queue: a blocking poll
   costs a time slice per pass instead of zero cpu. Correct but not efficient; the
   upgrade is registering the poller on each polled object's wait channel, and
   `wakeup()` already runs at every readiness change with those channel addresses,
   so the hooks exist.

Items 3-6 are bounded and mechanical. Item 1 is the one that must be fixed before
any hard-float userland is trustworthy, and item 2 is the one that determines
whether `calloop` runs at all.

## 8. Reproducing

```sh
cd src/riscv/uts
user/build-user.sh          # regenerates user_elfs.h + libc-riscv.a + rootfs.img
./build-scanout.sh          # builds, boots, screendumps, verifies
```

Judge a userland regeneration by **boot rate across several attempts**, never one
pass -- a single pass previously misled an agent into blaming the compiler for
what turned out to be three kernel bugs (and this document adds two more).
`polltest` prints `POLLTEST PASS` with a check count; the boot is CLEAN when it
reaches `solnix-riscv login:`.
