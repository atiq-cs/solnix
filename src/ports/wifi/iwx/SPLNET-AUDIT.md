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

> **CORRECTION (phase-3 implementation session, measured — supersedes the scope implied above).**
> This section presents `iwx_send_cmd` as *the* sleeping region and the phrase "this alone"
> reads as "region 8 is the only one that sleeps." **That scope is wrong.** Scanning every one of
> the 15 splnet regions' bodies for `tsleep`/`rw_enter`/`cv_wait` *inside* the `splnet()`/`splx()`
> bracket (brace-matched, not line-range) finds **THREE** regions that sleep inside the bracket,
> each traced to the ISR line that wakes it:
>
> | region | function | sleeps on | woken by (ISR) |
> |---|---|---|---|
> | 6 | `iwx_load_pnvm` (`:4401`) | `tsleep_nsec(&sc->sc_init_complete)` `:4419` | `iwx_notif_intr` `:11194` |
> | 7 | `iwx_run_init_mvm_ucode` (`:4509`) | `tsleep_nsec(&sc->sc_init_complete)` `:4538` | `iwx_notif_intr` `:11366` |
> | 8 | `iwx_send_cmd` (`:5849`) | `tsleep_nsec(desc, PCATCH)` `:5970` | `iwx_cmd_done` `:6079` |
>
> So the condvar split (`sc_cmd_cv`, `cv_timedwait_sig`) is needed for regions **6, 7 and 8**,
> not region 8 alone. The whole firmware bring-up handshake (`sc_fw`/`sc_uc`/`sc_init_complete`/
> `desc`, all woken by `iwx_notif_intr`) uses the same sleep-inside-splnet pattern. The
> conclusion "splnet must not become a blanket mutex" is unchanged and strengthened — there are
> three deadlock sites, not one.
>
> **And a second, worse problem the original audit missed entirely:** five further regions do not
> sleep *inside their own* bracket but *call a function that sleeps* while they would hold
> `sc_lock` — so a coarse "hold sc_lock across the region" is a deadlock for them too:
>
> | region | function | calls (sleeps) |
> |---|---|---|
> | 10 | `iwx_bgscan_done_task` | `iwx_mfp_leave` -> `tsleep_nsec(&sc->deauth_sent)` `:10407` |
> | 12 | `iwx_newstate_task` | `iwx_run`/`iwx_run_stop` -> `iwx_send_cmd` (sleeps) |
> | 13 | `iwx_stop` | `refcnt_finalize` (blocks until tasks drain), `iwx_mfp_leave` |
> | 14 | `iwx_ioctl` | `iwx_init` -> `tsleep_nsec(&ic->ic_state)` `:10279`; `iwx_stop` |
> | 15 | `iwx_init_task` | `iwx_init` (sleeps), `iwx_stop` |
>
> **Net: 8 of the 15 regions (6,7,8,10,12,13,14,15) cannot be "hold sc_lock across the region."**
> Only 6 can (regions 1,3,4,9,11, plus region 2 as a `_locked` callee). The audited coarse model
> is therefore refuted as an *implementation* even though its *direction* (restore ISR exclusion
> with an iblock mutex) is right. The correct shape is **fine-grained**: `sc_lock` taken only
> around the ISR-shared data windows (TX ring pointers, cmd-response slots, RX reorder buffers,
> device-register sequences), released before any sleeping call; the ioctl/init/stop paths keep
> their mutual exclusion on `ioctl_rwl`; regions 6/7/8 use the condvar split. See STATUS.md's
> "fine-grained locking model" section for the concrete sketch.
>
> There are also 3 `sc_lock` **nesting** self-deadlocks under a coarse non-recursive mutex
> (region 5 `iwx_ba_task` -> region 2 `iwx_sta_rx_agg`; region 14 `iwx_ioctl` -> region 13
> `iwx_stop`; region 15 `iwx_init_task` -> region 13 `iwx_stop`), fixed by `_locked` inner forms.
> (`iwx_newstate_task` only *mentions* `iwx_stop` in comments; not a real call.)

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

> **CORRECTION (phase-3 session): this "taken across regions 1-7 and 9-15" prescription is
> refuted — see the correction block after Refutation 1 and STATUS.md's fine-grained model.**
> 8 of 15 regions cannot hold `sc_lock` across the region (3 sleep inside, 5 call sleeping
> functions), and 3 more nest. The text below is kept for the reasoning trail; the *direction*
> (iblock mutex restores ISR exclusion) is right, the *granularity* (whole-region) is wrong.

`sc_lock` — a `MUTEX_DRIVER` mutex created with the interrupt block cookie, so `mutex_enter`
raises the PIL to the interrupt's level and genuinely excludes `iwx_intr`:

* taken by `iwx_intr` / `iwx_intr_msix` for the whole handler;
* ~~taken across regions 1-7 and 9-15 in place of `splnet`/`splx`~~ — **WRONG, see correction**:
  taken only around the ISR-shared data windows inside the 6 safe regions (1,3,4,9,11 + region 2
  as a `_locked` callee); the other 8 regions use the condvar split or stay on `ioctl_rwl`;
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

**AUDIT: COMPLETE. FIX: PARTIALLY IMPLEMENTED (safe subset only); the coarse model is
REFUTED and the fine-grained model is NOT YET IMPLEMENTED.** Updated in the phase-3 session.

Landed (the proven-safe, deadlock-free subset):

1. `sc_lock` (`kmutex_t`) and `sc_cmd_cv` (`kcondvar_t`) **now exist** on `struct iwx_softc`,
   added via `patches/if_iwxvar.illumos.patch` (the vendored header is read-only, so this uses
   the same patch discipline as `if_iwx.c`; `gen-illumos-src.sh` materialises
   `build/dev/pci/if_iwxvar.h`). The driver still compiles to an object with 0 errors.
   **They are SCAFFOLDING, not yet referenced by driver code** -- the `.c` compiles identically
   with or without the patched header (measured), because the fine-grained model that *uses*
   them is the next rung. They are declared now so that rung starts from a buildable base.
2. The `iwx_init_task` lock-order inversion **is fixed**: `ioctl_rwl` is now taken *before* the
   `splnet` region, matching `iwx_ioctl`. In `patches/if_iwx.illumos.patch`.
3. `compat/sys/iwx_kernel.h` gains the `IWX_SC_LOCK`/`IWX_SC_UNLOCK`/`IWX_SC_ASSERT_LOCKED`
   wrappers and the `iwx_cmd_wait`/`iwx_cmd_wake` condvar-split primitive **declarations**
   (the `tsleep_nsec`->`cv_timedwait_sig` mapping for regions 6/7/8). `splnet`/`splx` **stay
   no-ops** — deliberately, because a blanket mapping is refuted (see the correction after
   Refutation 1).

**NOT** landed, and why — the coarse model deadlocks:

4. The per-region `sc_lock` wraps are **not** applied. 8 of 15 regions cannot hold `sc_lock`
   across the region (regions 6/7/8 sleep inside; 10/12/13/14/15 call sleeping functions), and
   3 nest. Shipping a *partial* coarse model would be **actively unsafe**: the ISR would take
   `sc_lock` while 5 regions mutate ISR-shared state unlocked. The correct fix is fine-grained
   (STATUS.md).
5. `iwx_send_cmd`/`iwx_load_pnvm`/`iwx_run_init_mvm_ucode`'s `tsleep_nsec` is **not** yet
   converted to the condvar split — the primitive is declared but the call sites await the
   fine-grained model (they must take `sc_lock` for the ring/doorbell window, then
   `iwx_cmd_wait` which drops it across the wait).
6. The 8 `splassert(IPL_NET)` are **left as no-ops on purpose**. Converting them to
   `ASSERT(mutex_owned(&sc->sc_lock))` now would **panic**: they sit in `iwx_auth`/`iwx_run`/
   `iwx_run_stop`/`iwx_load_firmware`/`iwx_flush_sta`/`iwx_sta_rx_agg_*` — paths that call
   `iwx_send_cmd` (sleep) and so cannot hold `sc_lock`. The fine-grained model must decide what
   each should assert (likely `ioctl_rwl`-held, or nothing); only then do they convert.

None of this is reachable before the driver attaches, and **all of it must land before it is
loaded on hardware.** `hardware.wirelessIwx.enable` stays `false`.

## Extended into net80211 -- see `../net80211/FINDINGS.md`

net80211 is now vendored and its `spl` usage audited on the same terms. Three results **narrow
this file's conclusions rather than repeat them**:

1. **Refutation 1 does not generalise.** This file refutes the mutex mapping because
   `iwx_send_cmd` sleeps inside its `splnet` region. Measured across net80211's **24** regions:
   **none of them sleeps** (no `tsleep`/`msleep`/`rw_enter`/`M_WAITOK`). The detector was
   negative-controlled against `iwx_send_cmd`, where it does fire. So net80211's 24 regions **can**
   become a mutex; only this driver's region 8 cannot.
2. **One region would self-deadlock as a mutex.** `ieee80211_newstate` takes `splnet` and calls
   `ieee80211_free_allnodes`, which takes it again. `spl` nests by saving an integer; a
   non-recursive mutex does not. 1 of 24, and it needs an `_locked` inner form -- a change to
   vendored logic, so it belongs in a patch with that file cited.
3. **A hazard worse than the torn TX ring.** This file names a torn TX command ring as the visible
   corruption. The traced ISR path `iwx_intr` (`:11425`) -> `iwx_notif_intr` (`:11551`) ->
   `iwx_rx_mpdu_mq` (`:10935`) -> `iwx_rx_frame` (`:5342`) -> `ieee80211_find_rxnode` /
   `ieee80211_release_node` reaches net80211's node cache, which is a **red-black tree** mutated by
   `RBT_INSERT`/`RBT_REMOVE` inside `splnet` regions and walked by five more. Under the no-op that
   is an **unserialised RB tree mutated from an interrupt handler**. A torn ring corrupts a frame; a
   torn tree corrupts pointers and panics later, elsewhere.

Also: **4 more `splassert(IPL_NET)`** (`ieee80211_node.c:1244`, `:1277`, `:1305`, `:2133`) join the
8 here in silently ceasing to be checked, and `:2133` is the one guarding `RBT_REMOVE`.

The proposed model there is `ioctl_rwl` -> `sc_lock` -> `ic_lock`, and it carries **one unverified
premise** (that `ic_lock` is never held across a callback into the driver via `ic_newstate` /
`ic_send_mgmt` / `ic_set_key` / `ic_ampdu_rx_start`). Until that is walked, it is a proposal and not
a design. **Both fixes remain NOT IMPLEMENTED.**

> **UPDATE (phase-3 session): the premise is now WALKED, and it is FALSE.** A brace-matched,
> region-aware sweep of all 24 net80211 splnet regions for `ic->ic_*(` callbacks *inside* the
> bracket found exactly one — and it sinks the order: `ieee80211_clean_nodes` holds `splnet`
> (-> `ic_lock`) and calls `ic->ic_updateprot(ic)` at `ieee80211_node.c:2338`, whose driver
> handler `iwx_updateprot` (`if_iwx.c:3695`) calls `iwx_add_task` (region 9) which takes
> `sc_lock`. That is `ic_lock -> sc_lock`, the **opposite** of the ISR's `sc_lock -> ic_lock`
> (`iwx_intr` -> `ieee80211_find_rxnode`/`release_node`). Reached from the node-cache timeout
> (`ieee80211_node_cache_timeout`, `node.c:127` -> `:131`), which holds no `sc_lock`. **AB/BA
> deadlock, reachable on any multi-CPU box in RUN state.** The proposed order cannot hold as
> stated. The fix is to break that one edge — defer the `ic_updateprot` callback out from under
> `ic_lock` — detailed in `../net80211/FINDINGS.md` and STATUS.md's fine-grained model.
