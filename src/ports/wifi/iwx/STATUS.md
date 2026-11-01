# iwx port status: what compiles, what does not, and the measured route decision

**2026-10-26: the top three rows of the claim ladder are now measured on hardware (lixi); see them.** The rest of
this document is the original record.

Scope of this document: **two work sessions**, local cross-compile only, no hardware. It records what
was measured. Where it corrects the earlier plan -- or an earlier version of itself -- it says so,
because the earlier numbers are cited elsewhere in this repo and the correction needs to be findable
from the source, not only from here.

## Claim ladder -- stated exactly, because these are not the same thing

| stage | status | evidence |
|---|---|---|
| **`iwx_mbuf.c` compiles as an illumos kernel object** | **YES** | `gcc -m64 -c -D_KERNEL` -> ELF 64-bit relocatable, 13 text symbols, 7 undefined and all 7 genuine kernel entry points |
| **mbuf / mlist / cookie layers behave correctly** | **YES, tested** | **120 checks** pass; **13/13 sabotages caught**, each with a distinct failure count |
| **`if_iwx.c` compiles to an object file** | **YES** | `build/if_iwx_illumos.o`, ELF 64-bit relocatable x86-64, 263 text symbols. Real `-c` codegen, not `-fsyntax-only` |
| **the mbuf layer links** | **YES** | `ld -r` against a kernel-built `iwx_mbuf.o` resolves **all 11** `iwx_m_*`: 128 undefined -> 122 |
| **`iwx` links as a module** | **YES** | `ld -r` of net80211 + crypto + rbtree + mbuf + kcompat + stack + iwx_mbuf leaves **42 undefined, EVERY ONE kernel-supplied-at-load, 0 non-kernel remaining** (measure-gate.sh, negative-controlled). See ROUND 7 below. |
| **module loads** | **YES** (on lixi, the X1E Gen 5, from 2026-10-24) | under the n80211 giant-lock model (src/ports/wifi/net80211/n80211_giant.c), the same model as iwm; modinfo "iwx (Intel AX2xx (OpenBSD iwx))" |
| **attaches to the PCI device** | **YES** | AX211 8086:51f0, iwx0 attaches at boot (`hardware.wirelessIwx.attachAtBoot`), firmware so-a0-gf-a0 77 |
| **sees / associates with an AP** | **YES, WPA2-PSK, 2026-10-26** | `scan-wifi` lists the LAN; wpa-pmk -> in-kernel 4-way (fbt: recv_4way_msg1/3, send_4way_msg2/4, check_mic 0, 3x iwx_add_sta_key 0) -> DHCP on iwx0, ping 0% loss, ssh over iwx0 alone. Boot auto-join: `site/solnix-wifi-join-iwx` (`hardware.wirelessIwx.networks`), connected 12 s after the method started |

### Session-5 addition: phase-3 locking -- safe subset landed, coarse model refuted

This session applied phase-3 locking as the next rung. The headline is a **refutation**: the
locking model audited in `SPLNET-AUDIT.md`/`FINDINGS.md` cannot be implemented as a coarse
"hold `sc_lock` across each region" pass -- it deadlocks three different ways (sleep-under-lock on
8/15 driver regions, 3 nesting pairs, and a reachable net80211 AB/BA). The brief's one remaining
unverified premise -- that net80211's `ic_lock` is never held across a callback into the driver --
was **walked and found false** (`ieee80211_clean_nodes` -> `ic_updateprot` at `ieee80211_node.c:2338`
-> `iwx_updateprot` -> `iwx_add_task` -> `sc_lock`, i.e. `ic_lock -> sc_lock`, inverting the ISR's
`sc_lock -> ic_lock`). Rather than ship a partial coarse model (which would be *actively unsafe*:
ISR locked, 5 regions unlocked), only the **proven-safe, deadlock-free subset** landed:

* **`sc_lock` (`kmutex_t`) + `sc_cmd_cv` (`kcondvar_t`) added to `struct iwx_softc`** via a NEW
  header patch `patches/if_iwxvar.illumos.patch` -- the vendored `if_iwxvar.h` is read-only, so this
  uses the same patch discipline as `if_iwx.c`; `gen-illumos-src.sh` materialises
  `build/dev/pci/if_iwxvar.h` and `build-check.sh` puts `-Ibuild` first. **These fields are
  SCAFFOLDING for the fine-grained model, not yet referenced by driver code** -- measured: the
  generated `.c` compiles identically against the patched and unpatched header, so the fields are
  declared-and-ready, not load-bearing yet. (Kept now because the patch machinery for a read-only
  header is the awkward part, and the next rung needs exactly these.)
* **`iwx_init_task` lock-order inversion fixed** (`ioctl_rwl` before the `splnet` region), in
  `patches/if_iwx.illumos.patch`.
* **`IWX_SC_LOCK`/`IWX_SC_UNLOCK`/`IWX_SC_ASSERT_LOCKED` + `iwx_cmd_wait`/`iwx_cmd_wake`
  condvar-split declarations** added to `compat/sys/iwx_kernel.h`; `splnet`/`splx` and the 8
  `splassert` **stay no-ops** (converting them now would panic -- see `SPLNET-AUDIT.md`).

The driver still compiles to an object with **0 errors** (`build-check.sh --self-test` exit 0,
including with the new header fields) and the net80211 module still links (`measure-gate.sh`: 42
undefined, all kernel-supplied, 0 non-kernel). The concrete fine-grained model that *does* work is
sketched in "Next, in dependency order" step 3 below. Files changed this session: `STATUS.md`,
`SPLNET-AUDIT.md`, `../net80211/FINDINGS.md`, `compat/sys/iwx_kernel.h`, `gen-illumos-src.sh`,
`build-check.sh`, `patches/if_iwx.illumos.patch`, and the new `patches/if_iwxvar.illumos.patch`.

### Session-4 addition: the phase-1 illumos-side attach glue now compiles

`iwx_attach.c` (new, 515 lines) is the illumos half of the driver -- the piece the vendored OpenBSD
`if_iwx.c` does not and cannot contain. It **compiles to a real kernel object** (`build/iwx_attach.o`,
ELF64 relocatable, 20 text symbols, `build-check.sh` exit 0, negative-controlled: deleting the
`mac_register` call flips the gate to PROBLEM). It supplies:

* `_init`/`_fini`/`_info` + `modlinkage` + `DDI_DEFINE_STREAM_OPS` (all global `T` where required),
* `iwx_attach`/`iwx_detach`/`iwx_quiesce` doing `ddi_soft_state_*`, `pci_config_setup`,
  `ddi_regs_map_setup` (BAR0), the `ddi_intr_*` allocation skeleton, `ddi_create_minor_node`,
* `mac_alloc`/`mac_register`/`mac_unregister`/`mac_link_update` with a complete `mac_callbacks_t` vector,
  modelled on illumos `iwn` (`if_iwn.c:765-1136`, `:396`, `:7696-7749`).

**It references ZERO `ieee80211_*` symbols** (proven by the gate), so it builds **independently of the
net80211 link**. This settles the dependency-order question: the `mac_register`-UPWARD boundary is NOT
blocked on the 43-symbol net80211 gate. What the net80211 link DOES gate is the DOWNWARD bridge -- the
`mc_ioctl`/`mc_setprop`/`mc_getprop`/`mc_tx` callbacks, which on an illumos wifi driver route into
net80211 (iwn: `iwn_m_ioctl` -> `ieee80211_ioctl`, `if_iwn.c:4088`). In `iwx_attach.c` those are marked
`IWX_NET80211_GATED` and fail closed (`ENOTSUP`/`miocnak`) until a route-(b) OpenBSD-net80211 adapter
exists. They are stubs, tagged as such -- not implementations.

**Phase 2 (firmware + alive) verified at compile+structure level.** All handshake functions are real
text symbols in `build/if_iwx_illumos.o`: `iwx_read_firmware`, `iwx_load_firmware`, `iwx_start_fw`,
`iwx_load_ucode_wait_alive`, `iwx_run_init_mvm_ucode`, `iwx_fw_version_str`, `iwx_lookup_notif_ver`,
`iwx_lookup_cmd_ver`. The API-version contract is present and cited (all `upstream/if_iwx.c`):
`:1239` magic check (`IWX_TLV_UCODE_MAGIC`) -> `EINVAL`; `:1246` version string via
`IWX_UCODE_MAJOR/MINOR/API`; `:1365-1384` `IWX_UCODE_TLV_API_CHANGES_SET` capture with an `idx`
bound-check -> `EINVAL`; `:540`/`:10982` `iwx_lookup_notif_ver` arbitrates the alive-response struct
version; `:11013`/`:11037`/`:11049` only `IWX_ALIVE_STATUS_OK` (0xCAFE) sets `uc_ok`; `:4079`
`iwx_start_fw` returns `EINVAL` on `!uc_ok`. So a version mismatch degrades to a clean `EINVAL`
("could not load firmware"), not a crash. **True verification -- silicon accepts the blob, real
`IWX_ALIVE` interrupt -- is HARDWARE-GATED (the X1) and cannot be reached off-hardware.**

The error surface on `if_iwx.c` went **364 -> 30 -> 0** and it now produces an object file. **Nothing
links as a module and nothing loads.** "Compiles" is the second of seven rungs and the two that follow
are the expensive ones.

### Correction to this document's own previous version

The first version recorded **"`if_iwx.c` compiles: NO -- 30 errors at 24 lines"**, all mbuf-class. That
was correct when measured and is now **superseded**: the count is 0 and the file produces an object.
Annotated here rather than only replaced, because the 30 figure was cited in the round-2 brief, and a
reader who arrives at the old number needs to find the correction at its source rather than inherit it.

`hardware.wirelessIwx.enable` remains **`false`** (`configurations/base.nix:162`). Verified, with a
negative control confirming the grep can find an `enable = true`.

## The lever that took 30 errors to 0: alias the TYPE, never the FIELDS

The previous session left `struct mbuf` an **incomplete type** so every field access would be a compile
error at its own line. Right instinct, and it worked -- but it also made the five *pointer-assignment*
errors indistinguishable from the field errors, and the pointer assignments are not dangerous at all.

`compat/sys/mbuf.h` now does `#define mbuf msgb`, aliasing the struct **tag** to illumos's `mblk_t`.
Two measured facts make this sound rather than the very shortcut that file warns against:

* **No `sizeof(struct mbuf)` and no by-value use** anywhere in `if_iwx.c` or `if_iwxvar.h`. All 20
  occurrences of the tag are pointer declarations (8 prototypes, 5 locals, 2 struct members, 5
  definitions). A layout difference is therefore unobservable.
* **`struct msgb` has none of OpenBSD's field names**, so `m->m_len` is still a hard error, now phrased
  "struct msgb has no member named m_len". The incomplete type was only ever a means to that end; the
  alias keeps the end and drops the noise.

The invariant is now stated rather than implied: a **type** alias cannot change the meaning of an
assignment, a **field** alias can and does. `build-check.sh --self-test` carries a control
(`field-is-unmapped`) that compiles `m->m_len` and **requires it to fail**, so a field macro creeping in
later is caught here instead of on hardware.

30 -> 25 from the alias, 25 -> 1 from the 12 patched call sites, 1 -> 0 from declaring
`bus_dmamap_load_mbuf`.

## `upstream/` is read-only, so the rewrite is a patch

```
upstream/if_iwx.c  +  patches/if_iwx.illumos.patch  ->  build/if_iwx_illumos.c
                          (12 hunks)                        (generated, do not edit)
```

`gen-illumos-src.sh` materialises it and **`build-check.sh` regenerates before every build**, so a stale
`build/` cannot be mistaken for a passing one. Verified byte-identical to the hand-edited version it was
extracted from (`cmp`).

Three ways this could silently ship an unpatched driver, each with a live control:

| failure | control | result |
|---|---|---|
| a `.patch` that is really prose (no `@@`) | feed it one | refused, exit 2 |
| a reversed / already-applied patch | feed it the reverse | refused, exit 1 |
| hunks that apply cleanly and change nothing | remove a line, add it back | refused, exit 1, `cmp` message |

Writing those found a **harness bug of exactly the shape this project keeps hitting**:
`hunks=$(grep -c '^@@' f || echo 0)` yields the **two-line string `"0\n0"`**, because `grep -c` prints
`0` *and* exits 1, so the following `[ -eq ]` died with "integer expected" and **the check was
unreachable**. The no-hunk case then failed via a later error, which read as a pass.

## The site with "no mechanical answer", answered -- and the refutation that shaped it

`m_pkthdr.ph_cookie` (`:10294`) carries the `ieee80211_node *` alongside a queued management frame. One
producer, one consumer (measured: `grep ph_cookie` = 1 line). `mblk_t` has no packet header.

`b_prev` is the obvious carrier and it is **refuted as a general-purpose one**: the kernel asserts it is
NULL on three paths -- `freeb` (`uts/common/io/stream.c:642`), `freemsg` (`:659`), `pullupmsg` (`:1586`).
On a DEBUG kernel a leftover cookie is an assertion failure; on a non-DEBUG kernel the `ASSERT` compiles
away and it is **silent**.

It is nevertheless sound in one **narrow window**, and `iwx_mcookie.h` records the argument: the cookie
lives only from enqueue to dequeue on `ic_mgtq`, a `struct mbuf_queue` this port owns which links with
`b_next` **only**; nothing in STREAMS ever sees the message, so none of the three asserting paths can
run. The consumer **clears as it reads** (`iwx_m_take_cookie` is the only read accessor, deliberately --
a peek that left the field set is the bug), so the frame leaves the window clean and those three
`ASSERT`s become a loud backstop instead of a hazard.

### Where a negative control caught a real bug in the port's own code

`iwx_mcookie.h` asserted that `ml_purge()` -- the path that frees a still-queued frame on
interface-down -- clears the cookie before `freemsg()`, "and it does". **It did not.** `iwx_mlist.h`
never touched `b_prev`. Consequence: `ifconfig down` with a management frame queued panics a DEBUG
kernel and silently corrupts on a non-DEBUG one. Fixed in `ml_purge()` and in `mq_enqueue()`'s drop path.

The instructive part is **how it was found**. The first version of the test walked the queue and
inspected the cookies *before* calling `ml_purge`, then checked the free count -- and it **passed
against the broken code**, because after the free there is nothing left to inspect. Only instrumenting
the stub's `freemsg()` (`iwx_test_saw_dirty_free`, mirroring the kernel's own `ASSERT`) made the
condition observable. The weak version is preserved in the test's comment as the shape to distrust:
*a check that inspects the input instead of the operation.*

## The `splnet()` audit -- done, and the standing framing was wrong

Full writeup: **`SPLNET-AUDIT.md`**. Summary, because the conclusion matters more than the detail.

**15 `splnet()` calls, 15 regions, 15 distinct functions** (verified: no function has two). The 31
`splx` are exit paths, not leaks -- one region with four `return`s has four `splx`.

The standing instruction was "audit every `splnet` region against `sc->ioctl_rwl`". That contains a
**wrong premise**: `ioctl_rwl` is held in **3 of 15** regions and in **none** of them does it exclude
the interrupt handler, because **`iwx_intr` never takes it** (measured: zero lock or `spl` calls in
`:11425-11562`). Its own comment (`:10501`) says what it is for -- serialising ioctl entrants against
each other. So **12 of 15 regions have no protection at all** under the no-op, and the other 3 protect
the wrong thing.

Mapping `splnet` to a mutex is **refuted by two observed mechanisms**, neither being the 15-vs-31
arithmetic previously offered:

1. **A `splnet` region sleeps.** `iwx_send_cmd` takes `splnet` at `:5849` and calls
   `tsleep_nsec(desc, PCATCH, "iwxcmd", 1s)` at `:5952`, releasing at `:5970`. As a mutex that is
   sleeping while holding an interrupt-cookie mutex -- a deadlock, not a style problem.
2. **The lock order is already inverted in the vendored source.** `iwx_ioctl` takes `ioctl_rwl`
   (`:10505`) *then* `splnet` (`:10512`); `iwx_init_task` takes `splnet` (`:12763`) *then* `ioctl_rwl`
   (`:12767`). Harmless for a priority level, textbook AB/BA for a lock.

**Consequence, stated plainly: with `splnet()` a no-op this driver has no mutual exclusion between its
interrupt handler and its task/timeout/ioctl paths.** The visible corruption is a torn TX command ring.
Unreachable before attach, and it **must** be fixed before load. `SPLNET-AUDIT.md` names the four
specific pieces of work and tags the fix **NOT IMPLEMENTED**.

## Route (b): what is actually left, measured at the link

The driver object's undefined symbols are the honest size of the remainder. **122** after the mbuf layer
is linked in, counted **by symbol**, not by `grep` line:

| class | count | work |
|---|---|---|
| **illumos already provides** | **20** | **zero.** Spot-verified in the headers: `ddi_get32`/`put32`/`put8`, `drv_usecwait` (`sys/ddi.h`), `panic`/`snprintf` (`sys/cmn_err.h`), `memcmp` (`sys/sunddi.h`), `mutex_enter`, `memmove` (`sys/systm.h:509`) |
| **`ieee80211_*`** | **43** | route (b) vendoring -- the bulk, unchanged |
| declared-only shims | **50** | `bus_dma*` 11, `pci_*` 11, `if_`/`ifq_` 7, `task_`/`timeout_` 7, `refcnt_` 5, `iwx_bsd_*`/`iwx_rw_*`/`iwx_fls` 8, `systq` 1 |
| named decisions | **9** | below |

The nine, each with its illumos answer identified but **not implemented**:

* `tsleep_nsec` + `wakeup` -> `cv_timedwait_sig` + `cv_broadcast`. **Coupled to the `splnet` audit**,
  not an independent item -- see `SPLNET-AUDIT.md` region 8.
* `loadfirmware` -> the `firmware_*(9F)` interfaces.
* `getmicrouptime` -> `gethrtime()` (`sys/time.h:361`, verified present).
* `ether_sprintf` -> **exists in illumos** (`sys/ethernet.h:147`) with a **different signature**:
  `struct ether_addr *` vs OpenBSD's `uint8_t *`. A name match that is not a drop-in, the same trap as
  `arpcom` below.
* `config_mountroot` -> DDI attach deferral. Plus `etheranyaddr`, `etherbroadcastaddr`, `_pagesize`.

`bus_dmamap_load_mbuf` is **declared only, on purpose** (`iwx_dma.h`), with its contract written down --
including that it must return **`EFBIG` specifically**, because the TX path treats `EFBIG` as "linearize
and retry" and any other errno as fatal. It fails at link with its own name rather than compiling
against a plausible stub, which is the right failure mode for a DMA path.

## Correction: the five API counts in the plan are line counts, not call sites

`docs/x1-wifi-iwx-port-plan.md` and `iwx_illumos.h` both cite these. Each is reproducible as
`grep -c '<pattern>' if_iwx.c` — a count of **matching lines**, with an **unanchored** pattern:

| cited | reproduces as | real call sites |
|---|---|---|
| `m_*` 309 | `grep -c 'm_'` = 309 | **31 calls / 48 tokens / 12 distinct APIs** |
| `ieee80211_*` 273 | `grep -c 'ieee80211_'` = 273 | 287 occurrences, **76 distinct symbols**, 48 functions |
| `if_*` 97 | `grep -c 'if_'` = 97 | **3 function calls** + ~70 struct-member reads |
| `bus_dmamap_*` 50 | `grep -c 'bus_dmamap_'` = 50 | 56 calls, 12 distinct |
| `task_*`/`timeout_*` 69 | `grep -cE 'task_\|timeout_'` = 69 | 32 calls, 8 distinct |

Unanchored `m_` matches `vm_size`, `rm_sta_cmd`, `um_tbs`, `EM_GROUP`, `im_interval`. There are 580 raw
`m_` occurrences in the file and **48** are mbuf tokens.

The mbuf layer is therefore **~12 functions**, not 309 sites — an order of magnitude smaller than budgeted.
The *hazard* the plan describes is real and unchanged; only the size was wrong.

## The 802.11 decision: route (b), and route (a) is refuted by measurement

Route (a) was "adapt to illumos net80211 — less code, more semantic risk". It is not less code.

**Symbol coverage.** Of 76 distinct `ieee80211_*` symbols `iwx` uses, **53 (70%) do not exist in illumos
net80211 by name at all**; of the 48 it *calls*, **34 are absent**. Missing wholesale: the entire block-ack
machinery (`addba_req_accept`/`refuse`, `addba_resp_accept`/`refuse`, `delba_request`, `rx_ba`, `tx_ba`,
`node_tx_ba_clear`), every HT/VHT node capability predicate, the standard rateset tables, `node_switch_bss`
(roaming), the crypto plumbing (`set_key`, `delete_key`, `get_txkey`, `get_rxkey`, `encrypt`),
`ieee80211_release_node` (the refcount drop, 9 sites) and `ieee80211_inputm` (the RX entry point).

**Object model.** The decisive number: `struct ieee80211_node` has **109 members in OpenBSD, 55 in illumos,
and ZERO shared member names.** illumos renamed every field `ni_*` → `in_*`, so all **182** `ni_*` accesses
in `if_iwx.c` break — and it is not a rename, because illumos has no equivalent for OpenBSD's RSN,
block-ack or VHT node state. On `ieee80211com`, only **17 of 56** `ic_*` field names exist.

**Signatures diverge where names match.** `ieee80211_encap` takes `struct ifnet *` on OpenBSD and
`ieee80211com_t *` on illumos. `ieee80211_begin_scan` takes `(struct ifnet *)` vs
`(ieee80211com_t *, boolean_t)`. A name match is not a semantics match.

**Route (b) measured, and one result contradicts the plan.** OpenBSD net80211 is 31 files / 742 KB /
**24,665 lines**. The plan expected route (b) to be "more code, far less risk". At the *header* level it is
also **less work**: staging the 13 headers (4,729 lines) took the 802.11 error surface on `if_iwx.c` to
**~4 real errors**. Route (b)'s cost is deferred to LINK time, where the 14 `.c` files need 106 `m_*` calls,
54 `splnet`/`splx`, 57 `timeout_*`, 29 `mq_*`, 18 `if_*`, 30 `malloc`/`free` and nine `<crypto/*.h>` headers
shimmed — roughly **3× the shim work already done**, and the honest estimate for that is **weeks, not days**.

## The mbuf layer: a real translation layer, not a `#define`

`struct mbuf` is aliased to `struct msgb` (see the lever section above); no **field** name is ever
`#define`d. The three differences that make a field mapping dangerous:

1. **Two sources of truth for length.** OpenBSD *stores* `m_len` and `m_pkthdr.len`; illumos *derives* both
   from `b_wptr - b_rptr`. `#define m_len ...` makes `m->m_len = len` (`if_iwx.c:5236`, `:4633`) write a
   length into a pointer.
2. **`m_data` is reassigned into the middle of its own cluster** (`:5235`) to re-window an RX buffer onto a
   sub-frame. Moving `b_rptr` without `b_wptr` leaves a stale length and reads past the frame.
3. **Ownership.** `freemsg()` honours `db_ref`; `m_freem()` has no refcount.

`iwx_m_set_window()` also performs a bounds check a macro cannot: the frame length comes from the device, and
the unchecked form hands the 802.11 stack a window past the end of the DMA buffer.

**Two functions were added in session two, both because the mechanical translation was wrong:**

* **`iwx_m_shift_right(m, len, n)`** for `memmove(m->m_data + 2, m->m_data, hdrlen)` (`:5264`). The
  obvious translation gets the *bounds* right and the *length* wrong: the frame becomes 2 bytes longer,
  so `b_wptr` must move with it, or the caller's following `m_adj(m, 2)` (`:5265`) trims real payload off
  a length that never accounted for the pad. Both halves are checked, and the length half is the one a
  reviewer would not think to look for.
* **`iwx_m_at(m, offset, need)`** for `m0->m_data + offset` (`:10882`, `:10927`), which steps through
  several firmware responses packed in one RX buffer with `offset` advancing by a device-reported length.
  The interesting refusal is an offset **inside the cluster but past the received data** -- allocated but
  never written -- which bare pointer arithmetic accepts silently.

**Test results** (`./run-mbuf-tests.sh`): 71 + 26 + 23 = **120 checks pass**, and **13/13 sabotages are
caught**, each having had to *compile* first, and each failing with a **distinct** check/failure count so
no two are secretly the same test.

The mbuf-list layer keeps `b_next` (separate packets) strictly apart from `b_cont` (segments of one packet);
conflating them concatenates frames into one corrupt oversized frame, and that specific sabotage is one of
the 13.

## Five harness bugs found -- each would have manufactured a green run

All of the "a check that cannot fail" shape. The first three are from session one; the last two were
written in session two by someone who had just read the first three.

1. **`local name=$1 d="$work/s_$name"`** -- all words are expanded *before* `local` binds, and `$name` is
   exported in this shell as `nix-shell-env`, so **all 8 sabotages shared one directory** and each rebuild
   re-tested the previous binary. Fixed with separate assignments; isolation then *proven* by counting 8
   distinct directories.
2. **Three sabotages "passed" by failing to compile.** A build error is not a caught bug -- it proves the
   compiler works. The runner now requires each sabotage to **compile and then fail**, reporting `INVALID`
   otherwise. Relatedly, `sed` died on a `||` inside one search string and that death was being scored as
   "caught"; substitution is now literal and asserts the needle occurs exactly once.
3. **The three mbuf-list controls were blind.** `#include "x.h"` resolves against the *including file's own
   directory* before any `-I`, so the patched header was never read. `-I` ordering cannot fix it.
4. **`grep -c` prints `0` and exits `1`.** `$(grep -c '^@@' f || echo 0)` is the two-line string `"0\n0"`,
   so `[ "$hunks" -eq 0 ]` died with "integer expected" and the no-hunk check was **unreachable**. Same
   family as the line-count-vs-call-count errors this document already corrects, in a new shape.
5. **A check that matched its own explanation.** The "no unrewritten mbuf fields remain" grep matched the
   *rewrite comments*, which quote the old code (`"m->m_len = len" becomes...`). The first filter was
   `grep -v ILLUMOS`, wrong in **both** directions -- it would also have hidden a genuine unrewritten
   access on any line that happened to say ILLUMOS. It now greps a **comment-stripped** copy.

Also in session two: a negative control for the cookie fix **failed to compile** on the first two
attempts (a missing header, then a needle matching twice) and each time printed something that could have
been misread as a result. Both were caught only because the runner distinguishes INVALID from CAUGHT.

And in `build-check.sh`, the first ablation control was invalid twice: `sort -un` gives numeric order which
`comm` rejects outright, and a no-compat build **dies fatally after one message** so its count goes *down*
(1 vs 30) — a fatal early exit and a clean build are indistinguishable by count alone. It now shadows a
single header and asserts no fatal error occurred.

## What is REAL, what is STUB, what is a KNOWN GAP

| file | status |
|---|---|
| `iwx_mbuf.{h,c}` | **REAL**, 71 checks, 8 negative controls, compiles as a kernel object |
| `iwx_mlist.h` | **REAL**, 26 checks, 3 negative controls |
| `iwx_mcookie.h` | **REAL**, 23 checks, 2 negative controls. `ph_cookie` -> `b_prev`, sound only inside the enqueue/dequeue window; the argument and its three `ASSERT` citations are in the file and must be read before touching it |
| `iwx_mbuf_adapter.h` | **REAL** for the function mappings; records the decision taken at each patched site |
| `patches/if_iwx.illumos.patch` | **REAL**, 12 hunks. Regenerates `build/if_iwx_illumos.c` byte-identically; 3 no-op/prose controls |
| `iwx_dma.h` | **ENOSYS** -- `bus_dmamap_load_mbuf` declared only, contract written, fails at link by name |
| `compat/sys/iwx_bsdtypes.h` | **REAL** — `u_int8_t` and `uint8_t` are the same type |
| `compat/sys/tree.h` | **REAL** — OpenBSD RB/RBT vendored verbatim; illumos `sys/queue.h` has TAILQ/LIST/SLIST but no red-black tree |
| `compat/dev/pci/pcidevs.h` | **REAL** — 18 AX2xx IDs verified against OpenBSD's `pcidevs.h` |
| `compat/dev/pci/pcireg.h` | **REAL** — architectural PCI/PCIe constants |
| `compat/netinet/if_ether.h` | **REAL and load-bearing** — see the `arpcom` note below |
| `compat/net/if.h` | **REAL** struct + mblk FIFO; illumos has no driver-facing `ifnet` |
| `compat/sys/iwx_kernel.h` | mixed: `spl` is still a **deliberate no-op** (the blanket mutex mapping is refuted -- see `SPLNET-AUDIT.md`), now joined by the `IWX_SC_LOCK`/`IWX_CMD_WAIT` wrappers + `iwx_cmd_wait`/`iwx_cmd_wake` condvar-split **declarations** for the fine-grained model; the rest real declarations |
| `compat/sys/mbuf.h` | **REAL** — aliases the struct *tag* to `struct msgb` and defines no field; the alias is argued from measurement and guarded by the `field-is-unmapped` control |
| `compat/machine/bus.h`, `compat/dev/pci/pcivar.h`, `compat/net/if_media.h` | types real, functions **declared only** — they fail at LINK with their own names |
| `compat/net/bpf.h` | **KNOWN GAP, tagged** — `NBPFILTER=0` compiles out every tap, so monitor mode does not work and nothing pretends otherwise |

## Two hazards found in the compat layer that would not have failed loudly

**`struct arpcom`.** illumos *also* has one, and its `ac_enaddr` is a `struct ether_addr` where OpenBSD's is
`uint8_t[6]`. `if_iwx.c:12113` casts an `ifnet *` to `arpcom *`, which is valid only if `ifnet` is the first
member — true in OpenBSD, **false in illumos**. The `memcpy` would have been the same 6 bytes and "worked",
while reading the MAC from the wrong offset. OpenBSD's layout is now defined explicitly.

**`splnet()` is mapped to a no-op, on purpose**, and that decision is now **audited rather than asserted**.
Session one's version of this paragraph said "what actually provides mutual exclusion in `iwx` is
`sc->ioctl_rwl`" and justified the refusal by an acquire/release count of 15 vs 31. **Both were wrong**, and
the correction is in `SPLNET-AUDIT.md`: `ioctl_rwl` never excludes the interrupt handler because `iwx_intr`
does not take it, and the real refutation is that a `splnet` region **sleeps** (`:5849` -> `tsleep_nsec` at
`:5952`) while the two lock orders are **already inverted** between `iwx_ioctl` and `iwx_init_task`. The
audit is **DONE**; the fix is **NOT IMPLEMENTED** and is still the largest un-discharged correctness risk.

## Reproducing

```sh
cd src/ports/wifi/iwx
./gen-illumos-src.sh         # upstream + patch -> build/if_iwx_illumos.c
./run-mbuf-tests.sh          # 120 checks + 13 negative controls; exit 0 = CLEAN
./build-check.sh --self-test # regenerate, compile to .o, + 8 negative controls; exit 0 = OK
```

`build-check.sh` regenerates the derived source first (so a stale `build/` cannot pass), asserts the driver
reaches a real **object file** rather than only `-fsyntax-only`, asserts no OpenBSD mbuf field access
survives in the generated source *and* that all 9 translation entry points are actually called (so deleting
a site is not scored as translating it), and asserts `upstream/` is unmodified (byte-identical; `git
diff` empty).

## Next, in dependency order

⚠️ **Step 1 has been MEASURED and its sizing was too low. Read
`../net80211/FINDINGS.md` before acting on this list.** net80211 is now vendored
(`src/ports/wifi/net80211/orig/`, 31 files, read-only, provenance recorded) and its error
surface against illumos measured at **838**. Results that change this list:

* **0 of the 43 blocking symbols are resolved.** Three files (`ieee80211_amrr.c`, `ieee80211_ra.c`,
  `ieee80211_ra_vht.c`) now compile to **real objects**, and the 46 symbols they define include
  **none** of the 43 -- they are the cheap files precisely because `iwx` does not call them.
* **The mbuf layer is the bottleneck, at 8.4x.** net80211 needs **487** source lines rewritten
  against the mbuf translation layer, versus **58** for `if_iwx.c`. The type alias holds (0
  by-value, 0 `sizeof` across 198 tag uses -- re-verified), but the field-access volume is the cost.
* **`ifmedia` and `ether_*` do not exist on illumos in any form** (checked in the gate, not
  assumed), and `ieee80211_ioctl` -- one of the 43 -- is 536 lines / 36 `SIOC` cases of an OpenBSD
  wireless ioctl ABI illumos userland does not speak. Scheduler and timer models **do** map; the
  network-stack model does not.
* **The locking picture improved.** None of net80211's 24 `splnet` regions sleeps (detector
  negative-controlled against `iwx_send_cmd`, where it does fire), so those 24 **can** become a
  mutex -- unlike this driver's region 8. But a new hazard is worse than the torn TX ring: the ISR
  path `iwx_intr` -> `iwx_notif_intr` -> `iwx_rx_mpdu_mq` -> `iwx_rx_frame` ->
  `ieee80211_find_rxnode`/`ieee80211_release_node` mutates an **unserialised red-black tree** under
  the `splnet` no-op.

Also corrected there: this document's **"14 `.c` files"** is wrong -- net80211 has **18** `.c` and
**13** `.h`. The 31-file and 24,665-line totals are right.

> **ROUND 6 (measured):** all **18 of 18** net80211 `.c` compile to real ELF64 `.o` with 0 errors, a
> self-contained `n80211_crypto.c` (AES/RC4/MD5/SHA1/SHA256/HMAC/CMAC/AES-key-wrap/Michael, 16 published
> vectors, negative-controlled) resolves every cipher primitive, and an `ld -r` partial link SUCCEEDS with
> 0 crypto + 0 of the 43 blocking `ieee80211_*` undefined. The 82 still-undefined symbols are kernel
> primitives (load-time), the mbuf layer (`iwx_m_*`/`n80211_m_*`, DECL), and the GLDv3/stack adapters
> (`ether_*`/`ifmedia_*`/`if_*`/`timeout_*`/`_rb_*`, DECL -- the Finding-2 wall). Step 1 below is therefore
> COMPILE-COMPLETE; what remains for a kmod link is step 2's adapter `.c` plus the mbuf-allocation `.c`.
> See `../net80211/measure-gate.sh --self-test` and the plan's 18/18 gate section. Still NOT a
> kmod link and NOT a load.
>
> **ROUND 7 (measured): the full module LINKS as a kmod.** The DECL halves are now WRITTEN and TESTED --
> `n80211_rbtree.c` (the 7 `_rb_*`, a from-scratch CLRS red-black tree, 2000 seq + 200k churn +
> negative control), `n80211_mbuf.c` (the `n80211_m_*` allocation half, byte-verified + leak-checked +
> negative control), `n80211_kcompat.c` (`timeout_*`/`task_*`/`malloc`/`suser`/... -> DDI/kmem), and
> `n80211_stack.c` (the GLDv3-downward stack, REAL/BRIDGE/DEAD-PATH tagged per function). An `ld -r` of the
> 18 net80211 objects + crypto + these four + the driver's `iwx_mbuf.o` (24 objects, 0 compile errors)
> leaves **42 undefined, EVERY ONE kernel-supplied-at-load, 0 non-kernel remaining** -- i.e. the module
> LINKS with only symbols the running kernel resolves at load. `measure-gate.sh --self-test` reports this
> with a live module-link negative control. **Still NOT a load and NOT an attach:** phase-3 locking
> (SPLNET-AUDIT + FINDINGS Finding 3), the `iwx_gld.c` attach wiring the BRIDGE points, and the HARDWARE
> gate remain. iwx stayed green throughout.

Steps 1 and 5 of the previous version are **done** (mbuf call sites rewritten; `splnet` audited). What
remains, sized by the link measurement above:

1. **Vendor OpenBSD net80211's `.c` files** and shim their OpenBSD-kernel calls. **43 undefined
   symbols**, and it is the bulk of the remaining work. Route (b) is decided on measurement; route (a) is
   refuted and must not be revisited. **VENDORED AND MEASURED: 838 errors, 0 of 43 resolved.** See
   `../net80211/FINDINGS.md`, which also prices an unmeasured alternative (net80211 as a
   self-contained module presenting `mac_register` upward, rather than shimmed call-by-call into the
   illumos stack) that the maintainer should weigh before committing weeks.
2. **Implement the declared-only shims** -- `iwx_dma.c`, `iwx_pci.c`, `iwx_kcompat.c`. **50 symbols**,
   enumerated by class above. `bus_dmamap_load_mbuf` is the one with a written contract and the one that
   must return `EFBIG` distinctly.
3. **Phase-3 locking -- the audited COARSE model is REFUTED; a FINE-GRAINED model is the real
   remaining work.** (Phase-3 session, measured.) Landed only the proven-safe, deadlock-free
   subset; see `SPLNET-AUDIT.md` for the full correction and the per-region evidence.

   **Why the coarse model ("hold `sc_lock` across regions 1-7, 9-15") cannot ship:**
   * **8 of the 15 driver regions sleep under the lock.** Regions 6/7/8 (`iwx_load_pnvm`,
     `iwx_run_init_mvm_ucode`, `iwx_send_cmd`) `tsleep_nsec` *inside* the bracket (woken by the
     ISR at `:11194`/`:11366`/`:6079`); regions 10/12/13/14/15 call sleeping functions
     (`iwx_mfp_leave`/`iwx_init`/`iwx_stop`/`refcnt_finalize`) while they would hold `sc_lock`.
     Sleeping on an iblock-cookie mutex deadlocks the CPU. (The audit flagged only region 8.)
   * **3 nesting self-deadlocks** under a non-recursive mutex: region 5 -> region 2, region 14
     -> region 13, region 15 -> region 13.
   * **An AB/BA deadlock with net80211**, reachable on any multi-CPU box in RUN state: the
     node-cache timeout (`ieee80211_node.c:127`->`:131`) -> `ieee80211_clean_nodes` holds
     `ic_lock` and calls `ic->ic_updateprot(ic)` (`:2338`) -> driver `iwx_updateprot`
     (`if_iwx.c:3695`) -> `iwx_add_task` -> `sc_lock`, i.e. `ic_lock -> sc_lock`; while the ISR
     runs `sc_lock -> ic_lock` (`iwx_intr` -> `ieee80211_find_rxnode`/`release_node`). The
     FINDINGS.md premise "`ic_lock` is never held across a callback into the driver" is **false**.

   **Landed this session (safe, gates stay green):** `sc_lock`+`sc_cmd_cv` on `struct iwx_softc`
   (header patch `patches/if_iwxvar.illumos.patch`); the `IWX_SC_LOCK`/`IWX_CMD_WAIT` wrappers +
   `iwx_cmd_wait`/`iwx_cmd_wake` condvar-split *declarations* in `compat/sys/iwx_kernel.h`; the
   `iwx_init_task` order inversion fixed (`ioctl_rwl` before the `splnet` region). `splnet`/`splx`
   stay no-ops; the 8 `splassert` stay no-ops (converting them now would panic -- their functions
   sleep and cannot hold `sc_lock`).

   **The FINE-GRAINED model to implement next (concrete enough to start from):**
   * **Locks:** `sc->ioctl_rwl` (existing sleepable rwlock, serialises ioctl/init/stop entrants) ->
     `sc->sc_lock` (new iblock `MUTEX_DRIVER`, guards ISR-shared data) -> `ic->ic_lock` (new iblock
     `MUTEX_DRIVER` in net80211, guards the node-cache RB tree + BA/scan state). Order as written.
   * **`sc_lock` is taken NARROWLY**, only around the ISR-shared data windows, never across a sleep
     or a sub-call that sleeps: the TX command-ring pointers (`ring->cur`/`cur_hw`/`queued` + the
     `IWX_HBUS_TARG_WRPTR` write), the `sc_cmd_resp_pkt[]`/`sc_cmd_resp_len[]` slots, the RX reorder
     buffers, and the `sc_flags` bit updates. The ISR (`iwx_intr`/`iwx_intr_msix`) holds `sc_lock`
     for its ring/notif reaping.
   * **Regions that sleep (6,7,8) use the condvar split:** take `sc_lock` for the ring/doorbell
     write, then `iwx_cmd_wait(sc, chan, intr, nsecs)` which `cv_timedwait_sig(&sc->sc_cmd_cv,
     &sc->sc_lock, ...)` -- dropping `sc_lock` across the wait so the ISR can run. The ISR waker
     (`iwx_cmd_done` for `desc`; `iwx_notif_intr` for `sc_init_complete`) calls
     `iwx_cmd_wake(sc, chan)` -> `cv_broadcast(&sc->sc_cmd_cv)` under `sc_lock`. The existing
     `while()` predicate loops absorb the shared-condvar broadcast correctly.
   * **Regions that only call sleeping functions (10,12,13,14,15) do NOT hold `sc_lock` across the
     region.** Their mutual exclusion is `ioctl_rwl` (which they already take). They take `sc_lock`
     only for the specific field mutations, releasing it before `iwx_init`/`iwx_stop`/etc. Note
     `iwx_stop`'s `refcnt_finalize` must drain tasks with NO lock held.
   * **Nesting fixed with `_locked` inner forms:** `iwx_stop_locked`/`iwx_sta_rx_agg_locked`
     (caller holds `sc_lock`), outer wrappers acquire. net80211's `ieee80211_free_allnodes` gets
     the same split (its 1 self-nest from `ieee80211_newstate`).
   * **Break the net80211 AB/BA edge (REQUIRED):** `ieee80211_clean_nodes` must not call
     `ic_updateprot` while holding `ic_lock`. **Chosen fix: defer the callback.** Set a
     `need_updateprot` flag under `ic_lock`, drop `ic_lock` (`splx`), then call
     `ic->ic_updateprot(ic)` -- so the callback (and thus the driver's `sc_lock` acquisition) is
     never nested under `ic_lock`. Rationale: it is a 1-site change, keeps the driver handler
     unchanged, and removes the only `ic_lock`-held-across-callback edge the sweep found; the
     alternative (make the driver post a lock-free task) spreads the change across every
     `ic_update*` handler for no benefit. Belongs in a patch to `ieee80211_node.c`.
   * **`splassert(IPL_NET)` conversions happen LAST, per site**, to whatever lock that site then
     actually holds (`sc_lock` for ISR-reachable ones, `ioctl_rwl` for the init/stop ones), not a
     blanket `mutex_owned(&sc->sc_lock)`.

   This is more work than a mechanical `splnet`->`mutex` pass -- it is the per-field data-race
   analysis the coarse model skipped -- but it is the only model that does not deadlock. **Must
   land before the module is ever loaded**, not before it links.
4. **The 9 named decisions** above (`loadfirmware`, `getmicrouptime`, `ether_sprintf`'s signature mismatch,
   `config_mountroot`, ...).
5. **GLDv3 + DDI attach**: `_init`/`_info`/`_fini`, `mac_register`, `driver_aliases`. **Largely
   DONE** in `iwx_attach.c` (session 4): `_init`/`_fini`/`_info` + `modlinkage`, DDI
   attach/detach/quiesce, `pci_config_setup`, `ddi_regs_map_setup` (BAR0), the `ddi_intr_*`
   skeleton, `mac_alloc`/`mac_register`/`mac_unregister`/`mac_link_update` with a full
   `mac_callbacks_t`, all compiling to a real kernel `.o`. `driver_aliases` emitted as
   `IWX_PCI_ALIASES` (`compat/dev/pci/pcidevs.h`, 18 IDs). **Remaining:** merge the skeleton
   `struct iwx_il_softc` into the real `struct iwx_softc` once net80211 links (the `ponytail:`
   note in `iwx_attach.c`), and replace the `IWX_NET80211_GATED` mc_ callbacks with the real
   OpenBSD-net80211 bridge.
6. Only then: load, attach, and read the firmware-selection path (`if_iwx.c:12387-12421`).

Steps 1-2 are the bulk. On the evidence here that is **weeks**, and the plan's "weeks, not one build"
estimate is confirmed rather than overturned. What has changed across the sessions is that the 802.11
route is decided on measurement, the mbuf layer -- the one the plan called the place ports die -- exists,
is tested, and **links**, the full module **links as a kmod** (42 undefined, all kernel-supplied), the
GLDv3/DDI attach glue is written and compiles, and the locking model is now not just audited but
**partially implemented and, where the audit was wrong, refuted with a traced mechanism**.

**The phase-3 locking headline (this session):** the audited coarse model does **not** work -- it
deadlocks on 8 of 15 driver regions (sleep-under-lock), on 3 nesting pairs, and on a reachable AB/BA
with net80211 (`ic_updateprot` under `ic_lock` vs the ISR's `sc_lock`->`ic_lock`). The brief's one
remaining unverified premise (`ic_lock` never held across a driver callback) was walked and found
**false**. Only the proven-safe subset landed (lock fields, condvar primitive, order-inversion fix);
the fine-grained model is sketched concretely above as the next rung. What has *not* changed is that
**nothing loads and nothing attaches** -- and now there is a precise, mechanism-backed reason the
coarse shortcut to "loadable" would have been a multi-CPU deadlock, not a shortcut.
