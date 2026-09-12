# The `splnet()` audit

`splnet()` is a **deliberate no-op** in `compat/sys/iwx_kernel.h`. This file discharges the
question the port plan left open: **is that safe, and what has to change before the driver runs
on hardware?**

Answer: the no-op is **correct for 14 of the 15 regions and wrong for one**, the mapping to a
mutex is **refuted with an observed mechanism** rather than on style grounds, and the real
replacement is **two illumos mutexes with a stated order**, not one lock standing in for `spl`.

## Counts, counted correctly

The plan cites "54 `splnet`/`splx`". That is `grep -c` over lines and it is not the surface.

| thing | line count | **call count** |
|---|---|---|
| `splnet()` | 15 | **15** |
| `splx(s)` | 31 | **31** |

Here the two agree, because every occurrence is a call. The asymmetry 15 vs 31 is **not** a
leak: `splx` restores a saved priority on each exit path, so one region with four `return`s has
four `splx`. **15 `splnet()` calls == 15 regions, in 15 distinct functions**, enumerated below.
Verified: no function contains two `splnet()` calls.

## What `splnet()` actually is, and why a mutex is the wrong shape

`splnet()` raises the **current CPU's** interrupt priority level to `IPL_NET` and returns the
previous level; `splx()` restores it. It blocks the *local* CPU from taking a network interrupt.
It does **not** exclude another CPU, and it is **not** recursive in the mutex sense — nesting is
handled by saving and restoring a value, so a region may be entered while already at `IPL_NET`
and this is normal and correct.

On illumos the equivalent of "the interrupt cannot run here" is a mutex initialised with the
interrupt's cookie (`ddi_get_iblock_cookie` / `MUTEX_DRIVER` with an iblock), which makes
`mutex_enter` raise the PIL as a side effect. That is the right primitive, but it cannot be
reached by `#define splnet() mutex_enter(&sc->sc_lock)`, and the reason is measurable:

### Refutation 1: a `splnet` region sleeps, with `PCATCH`

```
if_iwx.c:5849   s = splnet();                                       (iwx_send_cmd)
if_iwx.c:5952       err = tsleep_nsec(desc, PCATCH, "iwxcmd", SEC_TO_NSEC(1));
if_iwx.c:5970   splx(s);
```

`iwx_send_cmd` **sleeps for up to a second inside its `splnet` region**, waiting for the
firmware to answer, and it is interruptible (`PCATCH`). This is legal on OpenBSD because `spl`
is a priority level, and the sleeping thread's saved level is restored per-thread.

Under `#define splnet() mutex_enter(...)` this becomes **sleeping while holding an adaptive
mutex** — on illumos that is a hard error, not a performance problem: an interrupt-cookie mutex
raises the PIL, and `cv_wait`/`delay` at raised PIL deadlocks the CPU. There is no way to write
`splnet` as a mutex acquisition and keep this call site correct. **This alone refutes the mutex
mapping**; the arithmetic about 15 acquires vs 31 releases was never the real objection.

### Refutation 2: the two lock orders are already inverted in the vendored source

`sc->ioctl_rwl` is a real sleepable rwlock and it interacts with `splnet` in **both orders**:

```
iwx_ioctl      if_iwx.c:10505  rw_enter(&sc->ioctl_rwl, RW_WRITE|RW_INTR)
               if_iwx.c:10512  s = splnet();                       <- rwl, THEN spl
iwx_init_task  if_iwx.c:12763  int s = splnet();
               if_iwx.c:12767  rw_enter_write(&sc->ioctl_rwl);     <- spl, THEN rwl
```

With `spl` as a priority level this is harmless — a priority level is not a lock and cannot
participate in a cycle. Turn `splnet` into a lock and these two paths are a **textbook AB/BA
inversion between a driver mutex and a sleepable rwlock**, reachable whenever a firmware error
schedules `init_task` while an `ifconfig` is in `iwx_ioctl`. That is a hang on a laptop with no
serial console.

So: **`splnet` must not become a lock.** The mapping to a no-op is not laziness; it is the only
mapping that does not introduce a deadlock. What the no-op *loses* is the actual exclusion, and
that is what the table below accounts for.

## What the regions are protecting, region by region

The question for each region is: **which concurrent context does it exclude, and does something
else already exclude that context on illumos?**

Two facts frame every row:

* The interrupt handler `iwx_intr` (`:11425`) / `iwx_intr_msix` (`:11563`) is established at
  `IPL_NET` (`if_iwx.c:12352`, `:12355`) and takes **no lock of its own**. `splnet` is the
  *only* thing keeping it out of these regions.
* Eight functions carry `splassert(IPL_NET)` (`:3444 :3496 :4053 :6568 :8958 :9073 :9127
  :9248`) — an assertion that the caller is already at `IPL_NET`. These are the functions the
  regions exist to protect, and the assertion documents the contract machine-checkably. On
  illumos `splassert` is another no-op, so **that contract silently stops being checked**.

| # | line | function | context | excludes | already excluded on illumos? |
|---|---|---|---|---|---|
| 1 | 3364 | `iwx_rx_ba_session_expired` | timeout callback | `iwx_intr` | **NO** |
| 2 | 3554 | `iwx_sta_rx_agg` | task (`ba_task`) | `iwx_intr` | **NO** |
| 3 | 3617 | `iwx_mac_ctxt_task` | task | `iwx_intr` | **NO** |
| 4 | 3644 | `iwx_phy_ctxt_task` | task | `iwx_intr` | **NO** |
| 5 | 3796 | `iwx_ba_task` | task | `iwx_intr` | **NO** |
| 6 | 4401 | `iwx_load_pnvm` | attach/init | `iwx_intr` | **NO** |
| 7 | 4509 | `iwx_run_init_mvm_ucode` | attach/init | `iwx_intr` | **NO** |
| 8 | 5849 | `iwx_send_cmd` | any, **sleeps** | `iwx_intr` | **NO** — and see below |
| 9 | 8219 | `iwx_add_task` | any | `iwx_intr` | **NO** |
| 10 | 8342 | `iwx_bgscan_done_task` | task | `iwx_intr` | **NO** |
| 11 | 9551 | `iwx_setkey_task` | task | `iwx_intr` | **NO** |
| 12 | 9641 | `iwx_newstate_task` | task | `iwx_intr` | **NO** |
| 13 | 10386 | `iwx_stop` | ioctl / init_task | `iwx_intr` | partly — callers hold `ioctl_rwl` (`rw_assert_wrlock`, `:10388`) |
| 14 | 10512 | `iwx_ioctl` | syscall | `iwx_intr` | partly — holds `ioctl_rwl` (`:10505`) |
| 15 | 12763 | `iwx_init_task` | task | `iwx_intr` | partly — takes `ioctl_rwl` (`:12767`) |

**The finding.** `sc->ioctl_rwl` is **not** a substitute for `splnet`, and the plan's framing
("audit every region against `ioctl_rwl`") contains a wrong premise. `ioctl_rwl` serialises
*ioctl-like entry points against each other* — its own comment says so: "Prevent processes from
entering this function while another process is tsleep'ing in it" (`:10501-10504`). It is held
in exactly **3 of the 15** regions, and in **none** of them does it exclude `iwx_intr`, because
the interrupt handler never takes it. **12 of 15 regions have no protection at all under the
no-op**, and the other 3 have protection against the wrong thing.

## Consequence, stated plainly

**With `splnet()` a no-op, this driver has no mutual exclusion between its interrupt handler and
its task/timeout/ioctl paths.** The corruption is a torn TX ring: `iwx_send_cmd` advances
`ring->cur`, `ring->cur_hw` and `ring->queued` (`:5946-5949`) and writes the hardware write
pointer, while `iwx_intr` walks the same ring to reap completions. These are not atomic and are
not ordered.

This is **not** reached at compile or link time and would not appear in any test that does not
run on hardware under load. It is exactly the class of bug that is cheap now and expensive on a
laptop with no serial console.

## The replacement, and why two locks

`sc_lock` — a `MUTEX_DRIVER` mutex created with the interrupt block cookie, so `mutex_enter`
raises the PIL to the interrupt's level and genuinely excludes `iwx_intr`:

* taken by `iwx_intr` / `iwx_intr_msix` for the whole handler;
* taken across regions 1-7 and 9-15 in place of `splnet`/`splx`;
* **order: `ioctl_rwl` before `sc_lock`, always** — the order `iwx_ioctl` already uses
  (`:10505` then `:10512`). `iwx_init_task` (`:12763`/`:12767`) uses the opposite order and
  **must be rewritten to take `ioctl_rwl` first**. This is a real change to the vendored logic
  and belongs in `patches/if_iwx.illumos.patch` with this file cited.

Region 8 (`iwx_send_cmd`) **cannot** use `sc_lock`, because it sleeps. It needs the standard
illumos split: `sc_lock` around the ring update (`:5851-5949`), then a `kcondvar_t` with
`cv_timedwait_sig` replacing `tsleep_nsec(desc, PCATCH, ...)` (`:5952`), the condvar waited on
with `sc_lock` held and dropped by `cv_timedwait_sig` itself. `PCATCH` maps to
`cv_timedwait_sig`'s interruptible form; the 1-second timeout maps to an absolute `lbolt`
deadline. The waker is `iwx_cmd_done`, which must `cv_broadcast` under `sc_lock`.

## STATUS

**AUDIT: COMPLETE. FIX: NOT IMPLEMENTED.** Tagged this way deliberately — the audit is the
deliverable this file claims, and the lock work is not done. Specifically not done:

1. `sc_lock` does not exist; `splnet`/`splx` remain no-ops in `compat/sys/iwx_kernel.h`.
2. The `iwx_init_task` lock-order inversion (`:12763` before `:12767`) is **not** fixed.
3. `iwx_send_cmd`'s `tsleep_nsec` is not converted to a condvar.
4. `splassert(IPL_NET)` is a no-op at 8 sites, so the contract is unchecked. It should become
   `ASSERT(mutex_owned(&sc->sc_lock))`, which restores the check with the same 8 call sites.

None of this is reachable before the driver attaches, and **all of it must land before it is
loaded on hardware.** `hardware.wirelessIwx.enable` stays `false`.
