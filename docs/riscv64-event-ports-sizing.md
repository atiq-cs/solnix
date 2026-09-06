# Sizing: event ports, the interface `calloop` actually needs

This is a sizing estimate, not a design commitment. It exists because tracing the
real dependency chain corrected a working assumption: `poll(2)` is **not** what a
Wayland compositor's event loop calls on illumos. Event ports are, and they are
therefore newly on the critical path.

Companion: `docs/riscv64-poll-and-anon-mmap.md` (what `poll(2)` now provides, and
the `fd_ready()` readiness core this would reuse).

## 1. The traced dependency chain

Read out of the vendored crate sources, not inferred:

```
smithay / smallvil
  └─ calloop 0.14.4
       └─ polling 3.11.0          src/lib.rs cfg: illumos/solaris => mod port
            └─ rustix 1.1.4       src/backend/libc/event/syscalls.rs
                 └─ c::port_create / port_associate / port_dissociate / port_getn
```

and, separately, on the compositor's server side:

```
wayland-backend 0.3.17  src/rs/server_impl/common_poll.rs
  └─ rustix::event::epoll      (illumos ships a native epoll(5) shim over event ports)
```

The existing `src/drm-port/wayland-backend-illumos-epoll.patch` widens that crate's
`cfg` allowlist to include illumos precisely because illumos has real `epoll`, so
no bespoke event-ports backend was needed there. That patch is evidence the chain
above is the live one.

So the honest statement of where `poll(2)` sits: it is **necessary but not
sufficient**. It is what libc, hand-written loops, and the port/epoll shims
themselves are built on -- none of them can exist without it -- but no crate in the
compositor stack calls it directly.

## 2. The five entry points, and what each needs from this kernel

`polling`'s `port.rs` uses exactly five calls. That small surface is the good news.

| Call | What it must do | Cost against this kernel |
|---|---|---|
| `port_create()` | allocate a port object, return an fd | **Small.** A new fd kind in `p_fd[]` (there are already six: file, ramfs, SNFS, pipe, fb, socket) plus a fixed `porttab[]`, exactly like `pipetab[]`/`socktab[]`. |
| `port_associate(port, PORT_SOURCE_FD, fd, flags, user)` | record (fd, wanted-events, user cookie) on the port | **Small.** An association array per port. `flags` arrives as **`PollFlags`** -- literally `POLLIN\|POLLHUP\|POLLERR\|POLLPRI` for readable and `POLLOUT\|POLLHUP\|POLLERR` for writable (`polling/src/port.rs` `read_flags()`/`write_flags()`). Those are the bits `fd_ready()` already computes. |
| `port_dissociate(port, PORT_SOURCE_FD, fd)` | drop the association; `ENOENT` if absent | **Trivial.** `polling` explicitly tolerates `ENOENT`. |
| `port_getn(port, list, max, &n, timeout)` | return up to `max` fired events, blocking per timeout | **Moderate, and it is the whole job.** But it is `proc_poll`'s loop with a different output shape: scan the associations with `fd_ready()`, emit `port_event`s for those that fired. The timeout semantics (0 / >0 / block) are already implemented and already proven to actually block (measured 203 ms for a 200 ms request). |
| `port_send(port, PORT_SOURCE_USER, user)` | queue a user-generated event; this is calloop's ping/wakeup | **Small.** A user-event queue per port, drained by `port_getn` ahead of the fd scan. Needed for `LoopSignal`/`Ping`, so not optional. |

### The two findings that make this much smaller than it looks

**1. Oneshot only.** `polling`'s event-ports backend *rejects* anything but
`PollMode::Oneshot`:

```rust
if mode != PollMode::Oneshot {
    return Err(crate::unsupported_error(
        "this kind of event is not supported with event ports"));
}
```

Event ports are inherently oneshot -- an association fires once and is
automatically dissociated, and the consumer must re-associate. So the kernel does
**not** need to implement level- or edge-triggered association modes. It needs the
simplest of the three.

**2. `calloop` already emulates level-triggering in software for this exact case.**
`calloop/src/sys.rs`:

```rust
let level_triggered = if poller.supports_level() && !force_fallback_lt {
    None
} else {
    Some(RefCell::new(HashMap::new()))   // software LT emulation
};
```

`supports_level()` is false for the event-ports backend, so calloop keeps its own
map of level-triggered sources and re-arms them itself. **This is the mechanism the
project's existing `calloop-wayland-source` and `wayland-client` timer-dispatch
patches were working around**, and it is worth connecting the two: those patches
exist because level-triggered readiness did not propagate correctly. A kernel whose
readiness answers are genuinely level-triggered at the source (which `fd_ready()`
now is, by construction and with a negative control proving it) makes that
emulation correct rather than merely present.

## 3. Why `fd_ready()` is the right foundation

The readiness policy is the hard, bug-prone part of any of these interfaces, and it
is done. `uproc.c`'s `fd_ready(p, fd)` already:

* returns exactly the `POLLIN`/`POLLOUT`/`POLLHUP`/`POLLERR`/`POLLNVAL` bit set
  `port_associate` speaks in -- no translation layer needed;
* covers every fd kind that exists (AF_UNIX socket, pipe both ends, tty, regular
  file, `/dev/fb`);
* is **level-triggered by construction** -- it holds no state between calls and
  recomputes from live ring cursors, so there is no arrival edge for a port
  implementation to miss;
* is negative-controlled, so a regression to a constant answer fails a test rather
  than silently spinning a compositor.

`port_getn` is therefore "loop the associations calling `fd_ready`, emit events,
reuse `proc_poll`'s timeout/wait" -- not new readiness logic. That is the reason
this is a days-scale item rather than a weeks-scale one.

## 4. Estimate

| Piece | Estimate |
|---|---|
| port object + fd kind + `port_create`/`close` | 0.5 d |
| `port_associate` / `port_dissociate` (oneshot only) | 0.5 d |
| `port_getn` over `fd_ready()` + timeout reuse | 1-1.5 d |
| `port_send` + user-event queue | 0.5 d |
| userland test (readiness transitions, oneshot re-arm, timeout actually blocks, user events, negative control) | 1 d |
| **total** | **~4 days** |

Then either:

* **`epoll(5)` shim** over the same associations, for `wayland-backend`'s server
  side -- `epoll_create`/`ctl`/`wait` map onto the port object almost directly, and
  illumos itself implements epoll this way. **~1-2 days on top**, and it is what
  the existing `wayland-backend-illumos-epoll.patch` expects to find; or
* **patch `wayland-backend` to use event ports directly**, which is strictly more
  work than the shim and abandons an already-written patch. Not recommended.

## 5. Caveats that must be stated

* **The fd table is 8 slots.** A port is itself an fd, and a compositor holds a
  listening socket, one or two fds per client, and the framebuffer. This limit
  binds before event ports do, and raising it is a prerequisite rather than a
  follow-up. `NPOLLFD` is capped at 16 for the same reason.
* **The wait is still a yield loop.** `proc_poll` costs a time slice per pass
  rather than zero cpu, and `port_getn` inheriting that inherits the same ceiling.
  For a compositor that is idle most of the time this is the difference between a
  sleeping and a spinning machine, so the wait-channel upgrade (register the waiter
  on each polled object's channel; `wakeup()` already runs at every readiness
  change with those addresses) is more urgent for ports than it was for `poll`.
* **`PORT_SOURCE_FD` and `PORT_SOURCE_USER` only.** illumos also has
  `PORT_SOURCE_TIMER`, `_ALERT`, `_AIO`, `_FILE` (FEN). `polling` uses only the
  two, so the others should be **refused with `ENOTSUP`**, not stubbed -- FEN in
  particular is a whole filesystem-notification subsystem and a fake would be
  worse than an honest refusal.
* **This is all downstream of the FP fix.** Per
  `docs/riscv64-fpu-context-switch-spec.md`, no hard-float userland is trustworthy
  until FP state is preserved across a switch, and every Rust binary is hard-float
  (`lp64d`). Event ports would let `calloop` run; FP is what lets it run
  *correctly*. Order matters: FP first.
