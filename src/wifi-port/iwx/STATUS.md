# iwx port status: what compiles, what does not, and the measured route decision

Scope of this document: **one work session**, local cross-compile only, no hardware. It records what was
measured. Where it corrects the earlier plan it says so, because the earlier numbers are cited elsewhere in
this repo and the correction needs to be findable from the source, not only from here.

## Claim ladder — stated exactly, because these are not the same thing

| stage | status | evidence |
|---|---|---|
| **`iwx_mbuf.c` compiles as an illumos kernel object** | **YES** | `gcc -m64 -c -D_KERNEL` → ELF 64-bit relocatable, 11 text symbols, 6 undefined and all 6 genuine STREAMS entry points |
| **mbuf translation layer behaves correctly** | **YES, tested** | 73 checks pass; **11/11 sabotages caught** |
| **`if_iwx.c` compiles** | **NO — 30 errors at 24 lines** | all 30 are mbuf-class, all 24 lines enumerated in `iwx_mbuf_adapter.h` |
| **`iwx` links** | **NO** | ~181 non-802.11 kernel calls plus OpenBSD net80211's 24,665 lines have declarations but no implementations |
| **module loads** | **NO** | no `_init`/`_info`/`_fini`, no `mac_register`, no DDI attach |
| **attaches to the PCI device** | **NO** | not attempted |
| **sees / associates with an AP** | **NO** | not attempted |

Progress is real and partial: the error surface on `if_iwx.c` went **364 → 30**, and the remaining 30 are
one named layer rather than a scatter. But **nothing links and nothing loads.** Do not read "compiles" as
anything more than the first of six stages.

`hardware.wirelessIwx.enable` remains **`false`** (`configurations/base.nix:162`). Verified, with a
negative control confirming the grep can find an `enable = true`.

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

`struct mbuf` is deliberately left an **incomplete type**, so every field access is a compile error at its
own line. The three differences that make a macro mapping dangerous:

1. **Two sources of truth for length.** OpenBSD *stores* `m_len` and `m_pkthdr.len`; illumos *derives* both
   from `b_wptr - b_rptr`. `#define m_len ...` makes `m->m_len = len` (`if_iwx.c:5236`, `:4633`) write a
   length into a pointer.
2. **`m_data` is reassigned into the middle of its own cluster** (`:5235`) to re-window an RX buffer onto a
   sub-frame. Moving `b_rptr` without `b_wptr` leaves a stale length and reads past the frame.
3. **Ownership.** `freemsg()` honours `db_ref`; `m_freem()` has no refcount.

`iwx_m_set_window()` also performs a bounds check a macro cannot: the frame length comes from the device, and
the unchecked form hands the 802.11 stack a window past the end of the DMA buffer.

**Test results** (`./run-mbuf-tests.sh`): 47 + 26 = **73 checks pass**, and **11/11 sabotages are caught**,
each of which had to *compile first* — see below.

The mbuf-list layer keeps `b_next` (separate packets) strictly apart from `b_cont` (segments of one packet);
conflating them concatenates frames into one corrupt oversized frame, and that specific sabotage is one of
the 11.

## Three harness bugs found — each would have manufactured a green run

Worth recording because all three are the "a check that cannot fail" shape, and two were in checks written
*during this session specifically to avoid it*.

1. **`local name=$1 d="$work/s_$name"`** — all words are expanded *before* `local` binds, and `$name` is
   exported in this shell as `nix-shell-env`, so **all 8 sabotages shared one directory** and each rebuild
   re-tested the previous binary. Fixed with separate assignments; isolation then *proven* by counting 8
   distinct directories.
2. **Three sabotages "passed" by failing to compile.** A build error is not a caught bug — it proves the
   compiler works. The runner now requires each sabotage to **compile and then fail**, reporting `INVALID`
   otherwise. Relatedly, `sed` died on a `||` inside one search string and that death was being scored as
   "caught"; substitution is now literal and asserts the needle occurs exactly once.
3. **The three mbuf-list controls were blind.** `#include "x.h"` resolves against the *including file's own
   directory* before any `-I`, so the patched header was never read. `-I` ordering cannot fix it.

And in `build-check.sh`, the first ablation control was invalid twice: `sort -un` gives numeric order which
`comm` rejects outright, and a no-compat build **dies fatally after one message** so its count goes *down*
(1 vs 30) — a fatal early exit and a clean build are indistinguishable by count alone. It now shadows a
single header and asserts no fatal error occurred.

## What is REAL, what is STUB, what is a KNOWN GAP

| file | status |
|---|---|
| `iwx_mbuf.{h,c}` | **REAL**, 47 checks, 8 negative controls, compiles as a kernel object |
| `iwx_mlist.h` | **REAL**, 26 checks, 3 negative controls |
| `iwx_mbuf_adapter.h` | **REAL** for the 12 function mappings; **enumerates** the 27 field sites it deliberately does not map |
| `compat/sys/iwx_bsdtypes.h` | **REAL** — `u_int8_t` and `uint8_t` are the same type |
| `compat/sys/tree.h` | **REAL** — OpenBSD RB/RBT vendored verbatim; illumos `sys/queue.h` has TAILQ/LIST/SLIST but no red-black tree |
| `compat/dev/pci/pcidevs.h` | **REAL** — 18 AX2xx IDs verified against OpenBSD's `pcidevs.h` |
| `compat/dev/pci/pcireg.h` | **REAL** — architectural PCI/PCIe constants |
| `compat/netinet/if_ether.h` | **REAL and load-bearing** — see the `arpcom` note below |
| `compat/net/if.h` | **REAL** struct + mblk FIFO; illumos has no driver-facing `ifnet` |
| `compat/sys/iwx_kernel.h` | mixed: `spl` is a **deliberate no-op**, the rest real declarations |
| `compat/sys/mbuf.h` | **STUB BY DESIGN** — `struct mbuf` incomplete on purpose |
| `compat/machine/bus.h`, `compat/dev/pci/pcivar.h`, `compat/net/if_media.h` | types real, functions **declared only** — they fail at LINK with their own names |
| `compat/net/bpf.h` | **KNOWN GAP, tagged** — `NBPFILTER=0` compiles out every tap, so monitor mode does not work and nothing pretends otherwise |

## Two hazards found in the compat layer that would not have failed loudly

**`struct arpcom`.** illumos *also* has one, and its `ac_enaddr` is a `struct ether_addr` where OpenBSD's is
`uint8_t[6]`. `if_iwx.c:12113` casts an `ifnet *` to `arpcom *`, which is valid only if `ifnet` is the first
member — true in OpenBSD, **false in illumos**. The `memcpy` would have been the same 6 bytes and "worked",
while reading the MAC from the wrong offset. OpenBSD's layout is now defined explicitly.

**`splnet()` is mapped to a no-op, on purpose.** It raises the interrupt priority level on the *current CPU*;
it does not exclude another CPU. What actually provides mutual exclusion in `iwx` is `sc->ioctl_rwl`. Mapping
`splnet` to `mutex_enter` would add a second lock taken in 15 places and released in 31 (the counts differ
because `splx` restores from nested saves) — a recursive-entry panic and a lock-order inversion waiting to
happen. **Consequence: every `splnet` region must be audited to confirm it sits inside `sc_lock`. That audit
is NOT done.** It is the largest un-discharged correctness risk in what exists so far.

## Reproducing

```sh
cd src/wifi-port/iwx
./run-mbuf-tests.sh          # 73 checks + 11 negative controls; exit 0 = CLEAN
./build-check.sh --self-test # error surface + 4 negative controls; exit 0 = OK
```

`build-check.sh` asserts every residual error is an *enumerated* site, not merely that the count is low, and
that `openbsd-orig/` is unmodified (it is byte-identical; `git diff` is empty).

## Next, in dependency order

1. **Rewrite the 24 mbuf sites** to call `iwx_mbuf.c`. Groups A–H in `iwx_mbuf_adapter.h`; group H
   (`m_pkthdr.ph_cookie` carrying the `ieee80211_node *`, `:10294`) has **no mechanical answer** and needs a
   side table or a prepended control block.
2. **Implement the declared-only shims** — `iwx_dma.c`, `iwx_pci.c`, `iwx_kcompat.c`, `iwx_gld.c`. ~181 calls.
3. **Vendor OpenBSD net80211's 14 `.c` files** and shim their 300-odd OpenBSD-kernel calls. The big one.
4. **GLDv3 + DDI attach**: `_init`/`_info`/`_fini`, `mac_register`, `driver_aliases` (already emitted as
   `IWX_PCI_ALIASES`).
5. **Audit every `splnet` region** against `sc_lock` before running on hardware.
6. Only then: load, attach, and read the firmware-selection path (`if_iwx.c:12387-12421`).

Steps 2–3 are the bulk. On the evidence here that is **weeks**, and the plan's "weeks, not one build"
estimate is confirmed rather than overturned. What has changed is that the 802.11 route is now decided on
measurement, and the mbuf layer — the one the plan called the place ports die — exists, is tested, and is
the smallest of the remaining problems rather than the largest.
