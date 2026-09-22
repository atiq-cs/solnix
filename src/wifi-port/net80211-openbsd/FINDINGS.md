# Vendoring OpenBSD `net80211`: what it costs, measured

> **ROUND-7 UPDATE (supersedes the round-6 "82 undefined / adapter .c not yet written" headline).** The
> GLDv3-downward stack adapter and the mbuf-allocation `.c` are now WRITTEN, TESTED, and LINKED, and the
> full driver module **links as a kmod**. An `ld -r` of the 18 net80211 objects + `n80211_crypto.c` + the
> four new adapters (`n80211_rbtree.c`, `n80211_mbuf.c`, `n80211_kcompat.c`, `n80211_stack.c`) + the
> driver's `iwx_mbuf.o` (24 objects, 0 compile errors) produces one ELF64 relocatable with **42 undefined
> symbols, EVERY ONE kernel-supplied-at-load, and 0 non-kernel symbols remaining** (each of the 42 verified
> against the illumos gate headers). The module's own internal cross-references -- the 43 blocking
> `ieee80211_*`, the crypto primitives, the mbuf allocation layer, the RBT node-cache backing, and the
> GLDv3-downward stack -- are all satisfied within the module. Reproduce + self-verify:
> `measure-gate.sh --self-test` (now also compiles the four adapters, does the full-module `ld -r`, runs the
> RB-tree and mbuf-alloc negative-controlled tests, and carries a module-link negative control that renames
> `ifmedia_add` to prove the check can report an unresolved adapter). Provenance of the four adapters is in
> `PROVENANCE.md`; the round-7 detail is in `../../docs/wifi-native-driver-plan.md` (the round-7 gate
> section). **Still NOT a load and NOT an attach** -- phase-3 locking (Finding 3 below), the `iwx_gld.c`
> attach wiring the BRIDGE points (`mac_register`/`mac_rx`/`mac_link_update`), and the HARDWARE gate all
> remain. iwx stayed green (build-check.sh exit 0) before AND after; no iwx-shared header was touched.
>
> **ROUND-6 UPDATE (supersedes the "12 of 18 / 250 errors" round-5 headline).** All **18 of 18** net80211
> `.c` files now compile to real ELF64 `.o` with **0 residual errors**. The six remaining cipher/pae files
> (`ieee80211_crypto_{wep,tkip,ccmp,bip}.c`, `ieee80211_pae_{input,output}.c`) were brought up with per-site
> mbuf patches that replace OpenBSD's fixed-cell output-segment allocator with a single contiguous
> `allocb`-backed write cursor (`compat/sys/n80211_cipher.h`). A self-contained **`n80211_crypto.c`** now
> DEFINES every crypto primitive the ciphers call (AES/RC4/MD5/SHA1/SHA256/HMAC/CMAC/AES-key-wrap/Michael),
> each verified against a published test vector (16/16, negative-controlled), and compiles as a real illumos
> kernel `.o`. An **`ld -r` partial link now succeeds**: 0 crypto primitives and 0 of the 43 blocking
> `ieee80211_*` remain undefined; the 82 that do are kernel primitives (load-time), the mbuf layer (DECL), and
> the GLDv3/stack adapters (DECL -- the Finding-2 wall). Reproduce + self-verify with
> `measure-gate.sh --self-test`. **Still NOT a kmod link and NOT a load** -- the GLDv3/stack adapter `.c`, the
> mbuf-allocation `.c`, phase-3 locking, and the HARDWARE gate remain. The round-6 detail is in
> `../../docs/wifi-native-driver-plan.md` (the 18/18 gate section).
>
> **ROUND-5 UPDATE (supersedes the "0 of 43" headline below).** The link gate has since moved
> **0 -> 27 -> 43 of 43** blocking `ieee80211_*` symbols resolved as real ELF .o global symbols, and
> the error surface **838 -> 436 -> 250**, with **12 of 18** `.c` files now compiling. All 43 are
> ELF-proven (`file` + `nm --print-size`): 38 text (sized 0x4a..0x1b73), 1 data (`state_name`), 4
> read-only (the rateset tables). Reproduce and self-verify with
> `measure-gate.sh --self-test` (carries a negative control: renaming `ieee80211_encap` drops the
> count to 42/43). **This does NOT mean the module links** -- resolving the 43 iwx needs is necessary,
> not sufficient; the 6 files still at errors (`ieee80211_crypto_{ccmp,tkip,wep,bip}.c`,
> `ieee80211_pae_{input,output}.c`) define net80211's own internals and their crypto primitives + DECL'd
> mbuf/stack adapters are still undefined. The round-5 work is recorded in
> `../../docs/wifi-native-driver-plan.md` (net80211-link gate section) and the numbered tables below
> are the round-3 baseline, kept for provenance. The "0 of 43" and "838" figures in this file are the
> round-3 measurement, correct when taken; do not cite them as current.

Scope: **one work session**, local cross-compile only, no hardware, no EC2. This file records what
was measured after vendoring the 31 upstream files into `orig/`. It is the round-3 companion to
`../iwx/STATUS.md` and `../iwx/SPLNET-AUDIT.md` and it **does not repeat** their findings.

Where it contradicts the brief that commissioned it, it says so, because the maintainer is deciding
whether to keep investing here and an honest wall is worth more than optimistic half-code.

## The ladder — unchanged by this session, stated exactly

| stage | status | evidence |
|---|---|---|
| `if_iwx.c` compiles to an object | **YES** (unchanged) | `iwx/build/if_iwx_illumos.o`, 220,928 B, ELF64 relocatable, 263 text symbols, 128 undefined |
| mbuf layer links | **YES** (unchanged) | 120 checks, 13/13 sabotages, re-run this session |
| **3 of 18 net80211 `.c` files compile to objects** | **YES, NEW** | `ieee80211_amrr.o` (2 T), `ieee80211_ra.o` (22 T), `ieee80211_ra_vht.o` (22 T) |
| **the other 15 compile** | **NO — 838 errors** | table below |
| **the 43 undefined 802.11 symbols** | **0 of 43 resolved** | `comm` of provided-vs-needed is EMPTY |
| module links | **NO** | still 122 undefined after the mbuf layer |
| loads | **NO** | no `_init`/`mac_register`/DDI attach |
| attaches | **NO** | not attempted |
| sees / associates with an AP | **NO** | not attempted |

**The headline is a refutation.** Three files now produce real objects and **not one of the 43
blocking symbols is among them.** The 46 symbols those objects define are the rate-adaptation and
AMRR APIs, and `if_iwx.c` calls **none** of them (measured: zero `ieee80211_ra*` / `ieee80211_amrr*`
in the driver's undefined list, and the only near-miss tokens in the source are
`ieee80211_rateset`/`ieee80211_radiotap`, which are types). The cheap files are cheap **because**
they are the ones the driver does not need.

## What the 43 symbols actually require

All 43 live in **7** of the 18 `.c` files, and those 7 are the expensive ones:

⚠️ `../iwx/STATUS.md` says "14 `.c` files" throughout. That count is **wrong** — there are **18**
(`ls orig/*.c` = 18, `orig/*.h` = 13, total 31). Corrected here rather than only superseded, per
this project's rule that a stale number must be annotated at the source a reader will reach.

| file | of the 43 it defines | lines | errors against illumos |
|---|---|---|---|
| `ieee80211.c` | 15 | 1,507 | 92 |
| `ieee80211_node.c` | 8 | 3,611 | 25 |
| `ieee80211_input.c` | 6 | 3,652 | 109 |
| `ieee80211_output.c` | 5 | 2,303 | 127 |
| `ieee80211_crypto.c` | 5 | 682 | 46 |
| `ieee80211_proto.c` | 3 | 1,463 | 14 |
| `ieee80211_ioctl.c` | 1 | 990 | 18 |
| **total** | **43** | **14,208** | **431** |

(3 of the 43 are the `ieee80211_std_rateset_11{a,b,g}` constants, defined in `ieee80211.c:891-897`.)

And those 7 do not stand alone: `ieee80211_crypto.c` dispatches to `_ccmp/_tkip/_wep/_bip`
(1,804 lines, 349 errors) and the RSN state machine `ieee80211_proto.c` drives `_pae_input/_pae_output`
(1,838 lines, 55 errors). The realistic unit is **~17,850 lines** and **835 of the 838 errors**.

## The error surface: 838, and where it comes from

Measured per file, each with its own log. Reproduce with:

```sh
cd src/wifi-port
UTS=/home/gburd/src/illumos-gate/usr/src/uts
gcc -m64 -fsyntax-only net80211-openbsd/orig/<f>.c \
    -D_KERNEL -ffreestanding -nostdinc \
    -include sys/iwx_prelude.h -include sys/mbuf.h \
    -Inet80211-openbsd/compat -Iiwx/compat -Iiwx \
    -I$UTS/common -I$UTS/intel -I$UTS/i86pc -Wno-format
```

| file | errors | | file | errors |
|---|---|---|---|---|
| `ieee80211_output.c` | 127 | | `ieee80211_pae_output.c` | 38 |
| `ieee80211_crypto_tkip.c` | 119 | | `ieee80211_crypto_bip.c` | 29 |
| `ieee80211_input.c` | 109 | | `ieee80211_node.c` | 25 |
| `ieee80211_crypto_ccmp.c` | 102 | | `ieee80211_ioctl.c` | 18 |
| `ieee80211_crypto_wep.c` | 99 | | `ieee80211_pae_input.c` | 17 |
| `ieee80211.c` | 92 | | `ieee80211_proto.c` | 14 |
| `ieee80211_crypto.c` | 46 | | `regdomain`/`rssadapt` | 2 / 1 |
| | | | `amrr` / `ra` / `ra_vht` | **0 / 0 / 0** |

**838 total.** For scale, `if_iwx.c` — one 12,884-line file — started at 364 and took two sessions
to reach 0.

Classified (classifier negative-controlled: each bucket matches a synthetic member of its own class
and is confirmed **not** to match a member of another):

| class | errors | share |
|---|---|---|
| **mbuf** (`struct msgb has no member`, `mtod`, `m_*`, `MGET`/`MCLGET`/`M_PREPEND`) | **501** | **60%** |
| `ifmedia` / `IFM_IEEE80211_*` | 88 | 10% |
| crypto primitives (`AES_*`, `rc4_*`, `HMAC_*`, `michael_*`, `aes_key_wrap`, `CMAC`) | 55 | 7% |
| `ifnet` / `ifreq` / `ether_*` / `if_*` | 40 | 5% |
| `struct llc` (LLC/SNAP encapsulation header, absent on illumos) | 21 | 3% |
| remainder (`ISSET`, `suser`, `explicit_bzero`, `timingsafe_bcmp`, `ratecheck`, `arc4random*`, `IPTOS_DSCP_*`, `m_tag`, …) | 133 | 16% |

## Finding 1 — the mbuf invariant HOLDS, and it is not the relief it sounds like

The brief asked whether the `#define mbuf msgb` type alias survives contact with net80211, since a
by-value use or a `sizeof` would make a layout difference observable. **Re-verified across all 31
files, and it holds:**

| property | if_iwx.c (previously) | vendored net80211 (this session) |
|---|---|---|
| `struct mbuf` tag occurrences | 20 | **198** |
| by-value / array declarations | 0 | **0** |
| `sizeof(struct mbuf)` | 0 | **0** |

So the *type* alias is still sound. But the invariant's other half — **never alias a field** — is
where the cost is, and net80211 accesses mbuf fields at a scale `if_iwx.c` never did:

Counted on comment-stripped copies, by occurrence of the named token — not by `grep -c` on lines,
which is the error this project has corrected three times:

| access | if_iwx.c | net80211 |
|---|---|---|
| `->m_len` | (12 sites, all rewritten) | **148** |
| `->m_pkthdr` (of which `m_pkthdr.len` 74, `.ph_cookie` 5, `.ether_vtag` 1) | | **80** |
| `->m_next` | | **37** |
| `->m_type` / `->m_flags` / `->m_ext` / `->m_data` | | 16 / 16 / 12 / 2 |
| **all `->m_*` field arrows** | | **311** |
| `mtod()` | (via adapter) | **130** |
| `m_*()` calls | **31 calls / 12 APIs** | **106 calls / 12 APIs** |
| **source lines needing an mbuf rewrite** | **58** | **487** |

⚠️ The `m_pkthdr.<member>` counts are a **subset** of the 80 `->m_pkthdr` arrows, not additional to
them. Adding them would double-count, which is how the first draft of this table reached a wrong 351.

**487 versus 58 — 8.4×.** The mbuf layer that `iwx/STATUS.md` calls "the place ports die" was
built for 58 lines and produced 12 patch hunks over two sessions. Every one of those 487 lines is
the same class of decision: `m->m_len = x` cannot become a macro (it would write a length into
`b_wptr`), `mtod(m, T*)` must become a bounds-checked window, and OpenBSD's *stored* length versus
illumos's *derived* `b_wptr - b_rptr` has to be reconciled per site.

Concentration by file (comment-stripped; `m_pkthdr.` and `mtod(` counted as the distinct things
they are, not as `grep -c 'm_'` lines):

```
ieee80211_input.c        96 lines     ieee80211_crypto_wep.c     79
ieee80211_crypto_tkip.c  93           ieee80211_output.c         72
ieee80211_crypto_ccmp.c  83           ieee80211_pae_output.c     23
```

**This is the single largest number in this document.** It is not a wall in the sense of
"impossible"; it is a wall in the sense of "the same work again, eight times over, in the one layer
that has already needed two negative controls to catch two real bugs in its own code."

## Finding 2 — the network-stack model does not map, and it is not the mbufs

Three OpenBSD subsystems net80211 is built on **do not exist on illumos in any form**, verified by
searching the gate rather than assumed:

**`ifmedia` — absent entirely.** `find $UTS/common/net -name 'if_media*'` returns nothing. net80211
calls 6 `ifmedia_*` functions and `ieee80211_media_init` registers **40 media entries** across 13
`IFM_IEEE80211_*` families (11a/b/g/n/ac/ax, HT/VHT/HE MCS, adhoc/hostap/monitor/ibss). This is
88 errors, and 3 of the 43 blocking symbols are `ieee80211_media_{init,change,status}` — so it
cannot be skipped. GLDv3's equivalent is `mac_prop_info` / `MAC_PROP_*`, a **different model**:
ifmedia is a driver-owned list of (type, subtype, instance) tuples queried by `SIOCGIFMEDIA`,
whereas GLDv3 properties are a get/set callback keyed by property id. There is no table to
translate; the 40 entries have to be re-expressed as property handlers.

**`ether_*` — absent.** `ether_ifattach`, `ether_ifdetach`, `ether_ioctl`, `ether_addmulti`,
`ether_delmulti`, `ether_output` are not in the gate. On illumos those responsibilities sit in
GLDv3 (`mac_register`, `mac_multicst`, the `mac_callbacks` vector) — again a callback model, not
a call-down model.

**`struct ifnet` — 80 references, into a struct the port invented.** `iwx/compat/net/if.h` already
records why: illumos has no driver-facing `ifnet`, so the port defines a local one with the **11
fields `if_iwx.c` touches**. net80211 touches fields that struct does not have — `if_link_state`,
`if_capabilities`, `if_baudrate`, `if_priority`, `if_mtu`, `if_hdrlen`, `if_imcasts` — plus
`struct ifreq`'s `ifr_data`/`ifr_mtu`/`ifr_flags`. And `ieee80211_ioctl` is **536 lines / 36 `SIOC`
cases**, of which `SIOCS80211*`/`SIOCG80211*` are OpenBSD's own wireless ioctl ABI. illumos
userland (`dladm`, `wpa_s` via `WPA_DOOR`) does not issue them. Porting the 802.11 ioctl path is
therefore **not** a shim: it is a decision to either (a) expose an ABI no illumos tool speaks, or
(b) rewrite 536 lines against `mac_prop`. `ieee80211_ioctl` is one of the 43.

**Verdict on the brief's question.** The brief asked whether vendoring drags in a scheduler, timer
or network-stack model that does not map. Answer, with numbers:

* **scheduler: NO.** No net80211 `splnet` region sleeps (see Finding 3). Nothing here needs a
  thread model illumos lacks.
* **timers: NO, and cheaper than feared.** 78 `timeout_*` calls / 7 distinct APIs
  (`timeout_del` 32, `timeout_set` 18, `timeout_add_sec` 11, `timeout_pending` 6,
  `timeout_add_usec` 5, `timeout_add_msec` 5, `timeout_initialized` 1) plus 3 `task_*`. These map
  onto `timeout(9F)`/`untimeout(9F)` and `ddi_taskq_*` with real semantics — a genuine shim, and a
  small one. `iwx/compat/sys/timeout.h` already exists.
* **network stack: YES, and this is the wall.** `ifmedia` (88 errors, 40 media entries, 3 of the
  43 symbols), `ether_*` (absent), `struct ifnet` (80 refs into an invented struct), and a
  536-line / 36-case ioctl ABI illumos userland does not speak. This is not shimmable at the
  function level, because GLDv3 **inverts the direction of control**: OpenBSD's driver calls down
  into the stack (`if_input`, `if_start`, `ifq_dequeue`), GLDv3's stack calls *into* the driver
  (`mac_rx` is a push, `mac_tx` is a callback). `iwx/compat/net/if.h` already documents this for
  the driver's own 3 call sites and keeps a real mblk FIFO that "stays empty in normal operation."
  net80211 adds 80 more references and 4 more stack entry points on the same fault line.

**A second, smaller wall: crypto.** 55 errors from **29 distinct primitives / 94 calls**, counted
with mutually-exclusive family patterns (`/tmp/cryptocount.py`, so no primitive is counted twice):
`rc4_*` 19, `AES_CMAC_*` 14, `HMAC_SHA1_*` 14, `AES_Encrypt` 12, `HMAC_SHA256_*` 12,
`arc4random*` 10, `michael_*` 5, `aes_key_wrap*` 4, `HMAC_MD5_*` 3, `AES_Setkey` 1. illumos **has** AES (`common/crypto/aes/`),
arcfour (`common/crypto/arcfour/`), MD5/SHA1/SHA2 (`uts/common/sys/`) — but with **different
APIs**, and it has **no** `AES_CMAC` (needed by BIP/management-frame protection), **no** Michael
MIC (TKIP), and **no** AES key wrap (needed by the RSN 4-way handshake). Those three must be
written or vendored. They are small, self-contained and testable — the *least* risky item on this
page — but they are not free, and `struct rc4_ctx` being an incomplete type is currently 4 of the
19 "field has incomplete type" errors.

## Finding 3 — the locking hazard, extended into net80211 as required

`../iwx/SPLNET-AUDIT.md` audited `if_iwx.c`'s 15 regions. This extends it, and the result
**partly contradicts** the fear in the brief.

**Counted correctly** (the brief's "54 more `splnet`/`splx` sites" is right as a *sum* and wrong as
a region count): **24 `splnet()` calls, 30 `splx()`, 4 `splassert(IPL_NET)`**. 24 + 30 = 54. There
are **24 regions in 23 functions** — `ieee80211_newstate` has two.

The 24, enumerated:

| file | functions taking `splnet` |
|---|---|
| `ieee80211_node.c` (10) | `inact_timeout`, `setup_node`, `find_txnode`, **`find_rxnode`**, **`release_node`**, `free_allnodes`, `clean_cached`, `clean_nodes`, `clean_inactive_nodes`, `iterate_nodes` |
| `ieee80211_proto.c` (7) | `gtk_rekey_timeout`, `sa_query_timeout`, `tx_ba_timeout`, `rx_ba_timeout`, `newstate` **×2**, `rtm_80211info_task` |
| `ieee80211_input.c` (2) | `defrag_timeout`, `input_ba_gap_timeout` |
| `ieee80211_ra.c` (2) | `ra_add_stats_ht`, `ra_choose` |
| `ieee80211_ra_vht.c` (2) | `ra_vht_add_stats`, `ra_vht_choose` |
| `ieee80211_pae_output.c` (1) | `eapol_timeout` |

### The good news, and it is real: none of the 24 sleeps

`SPLNET-AUDIT.md`'s **Refutation 1** — that `iwx_send_cmd` sleeps inside its `splnet` region and
therefore `splnet` cannot become a mutex — **does not generalise to net80211.** Checked every one
of the 24 for `tsleep`/`tsleep_nsec`/`msleep`/`rw_enter`/`M_WAITOK`: **zero hits.**

The detector was negative-controlled: run on `if_iwx.c`'s `iwx_send_cmd`, it **does** report
`tsleep_nsec`. So it can fire, and its silence on the 24 is a measurement rather than a broken
check.

**Consequence: these 24 regions CAN become `mutex_enter(&ic->ic_lock)` with an interrupt block
cookie.** That is a genuinely better position than the driver's own regions, one of which cannot.

### The one that would self-deadlock

Exactly **1 of 24** nests: `ieee80211_newstate` takes `splnet` and calls `ieee80211_free_allnodes`,
which takes `splnet` again. On OpenBSD that is correct and normal — `spl` nests by saving and
restoring an integer. As a **non-recursive** illumos mutex it is an immediate self-deadlock.

The fix is the standard one (an `_locked` inner function, with the outer form asserting
`!mutex_owned`), and it is a **change to vendored logic**, so it belongs in a patch file with this
document cited — same discipline as the `iwx_init_task` order inversion.

⚠️ **The first version of this nesting check was wrong and reported 3 false nests**
(`clean_cached`, `clean_inactive_nodes`, `inact_timeout`). It scanned a *line range* after each
`splnet`, and the range ran past the end of the function into the **definition** of the next one —
so `void ieee80211_clean_nodes(...)` was scored as a *call* to `ieee80211_clean_nodes`. Replaced by
brace-matched function-body extraction with **both** controls: a positive one (a body that really
does call another region's function is found) and a negative one (an extracted body provably does
not contain the following function's definition). The real count is **1**, not 4.

### The new hazard this vendoring introduces, and it is worse than the torn TX ring

`SPLNET-AUDIT.md` names a torn TX command ring as the visible corruption under the `splnet` no-op.
Vendoring adds a worse one, and the ISR path to it is traced rather than assumed:

```
iwx_intr            if_iwx.c:11425   (established at IPL_NET, takes NO lock)
  -> iwx_notif_intr        :11551
     -> iwx_rx_mpdu_mq     :10935
        -> iwx_rx_frame    :5342 / :5009
           -> ieee80211_find_rxnode   ieee80211_node.c:2062  s = splnet()
           -> ieee80211_release_node  ieee80211_node.c:2165  s = splnet()
           -> ieee80211_inputm        ieee80211_input.c
```

`find_rxnode` looks up, and `release_node` can **free**, a node in `ic->ic_tree` — a **red-black
tree** (`RBT_*`, from the OpenBSD `sys/tree.h` this port vendored precisely because illumos has
none). Inside `splnet` regions the tree is mutated by `RBT_INSERT` (`setup_node`), `RBT_REMOVE`
(`ieee80211_free_node`, which is why it carries `splassert(IPL_NET)` at `:2133`) and walked by
`RBT_MIN`/`RBT_NEXT`/`RBT_FOREACH` in five more.

With `splnet()` a no-op, **an unserialised red-black tree is mutated from an interrupt handler
while timeout callbacks walk it.** A torn ring corrupts a frame; a torn RB tree corrupts pointers
and takes the machine down at a random later moment — on a laptop with no serial console.

The 4 `splassert(IPL_NET)` (`ieee80211_node.c:1244`, `:1277`, `:1305`, `:2133`) are OpenBSD's own
machine-checked statement of this contract, and on illumos `splassert` is a no-op, so **the
contract silently stops being checked** — the same loss `SPLNET-AUDIT.md` records for the driver's
8 sites, in the file where the data structure is a tree.

### Proposed locking model — stated explicitly, NOT IMPLEMENTED

The brief demanded either a proposed model addressing the sleep and the inversion, or an extended
audit leaving the no-op. This is the model; **it is not implemented**, and the no-op stands.

1. **`ic->ic_lock`** — `MUTEX_DRIVER` with the iwx interrupt block cookie, covering the node cache
   (`ic_tree`, `ic_nnodes`, `ic_scangen`) and the BA/scan state. All 24 regions become
   `mutex_enter`/`mutex_exit`. Legal precisely because **none of them sleeps** (measured above).
2. **`ieee80211_newstate` must be de-nested** before (1) is safe: split
   `ieee80211_free_allnodes` into a `_locked` inner form. 1 site.
3. **Order: `sc->ioctl_rwl` -> `sc->sc_lock` -> `ic->ic_lock`.** `ic_lock` is innermost and is
   never held across a call back into the driver.
4. **`iwx_intr` must take `sc_lock` and `ic_lock`** — today it takes nothing, which is why
   `ioctl_rwl` never excluded it (`SPLNET-AUDIT.md`'s central finding).
5. **The 4 `splassert(IPL_NET)` become `ASSERT(mutex_owned(&ic->ic_lock))`**, restoring the
   machine-checked contract at the same 4 sites.
6. **Region 8 of the driver audit (`iwx_send_cmd`) is unaffected** and still needs the condvar
   split; it is not a net80211 region.

⚠️ **Unresolved and NOT hand-waved:** rule 3 says `ic_lock` is never held across a call back into
the driver, and **that is not yet verified.** net80211 calls the driver through `ic_newstate`,
`ic_send_mgmt`, `ic_set_key`, `ic_ampdu_rx_start` and others; if any of those is invoked with
`ic_lock` held and the driver's handler takes `sc_lock`, the order in rule 3 inverts. Checking it
means walking every `ic->ic_*(` indirect call inside the 24 regions. **That work is not done**, and
until it is, this model is a proposal and not a design.

**STATUS: AUDIT EXTENDED. FIX NOT IMPLEMENTED. MODEL PROPOSED BUT ONE PREMISE UNVERIFIED.**
`hardware.wirelessIwx.enable` stays `false`.

## What compiles, what does not — REAL / STUB / PROBE

| item | status |
|---|---|
| `orig/` (31 files, 24,665 lines) | **REAL** upstream, read-only (`chmod a-w`, write attempt confirmed refused), provenance in `PROVENANCE.md` |
| `ieee80211_amrr.c` -> `.o` | **REAL OBJECT**, 2 text symbols, 0 undefined |
| `ieee80211_ra.c` -> `.o` | **REAL OBJECT**, 22 text symbols, 3 undefined (`ieee80211_std_ratesets_11n`, `memset`, `panic`) |
| `ieee80211_ra_vht.c` -> `.o` | **REAL OBJECT**, 22 text symbols, 3 undefined (`..._11ac`, `memset`, `panic`) |
| `ieee80211_rssadapt.c` | 1 error (`ratecheck`) — one shim from compiling |
| `ieee80211_regdomain.c` | 2 errors, both in `ieee80211_regdomain.h:757/766` |
| the other 13 `.c` | round-3: **DO NOT COMPILE**, 835 errors. **ROUND 6: all compile** (18/18, 0 errors). |
| `compat/` (16 headers) | round-3 PROBE STUBS. **ROUND 6:** the crypto headers back a REAL shim (below); the mbuf/cipher adapters (`n80211_mbuf.h`, `n80211_cipher.h`) are REAL; the GLDv3/stack shims (`n80211_stack.h`) stay DECL (Finding 2 wall). |
| `n80211_crypto.c` | **ROUND 6 -- REAL kernel `.o`.** AES/RC4/MD5/SHA1/SHA256/HMAC/CMAC/AES-key-wrap/Michael, all primitives defined `T`; 16 published test vectors pass (`-DN80211_CRYPTO_TEST`), negative-controlled (sabotage AES sbox[0] -> 8 vectors FAIL). |
| `n80211_cipher.h` | **ROUND 6 -- REAL.** Single-buffer write cursor + input `b_cont` read walker; no mbuf field aliased; used by the 4 cipher patches + BIP tail-append. |
| the 43 blocking symbols | round-3: 0 of 43. **ROUND 6: 43 of 43 resolved; `ld -r` links with 0 crypto + 0 of the 43 undefined.** |

The 3 objects and the 2 near-misses are 2,086 lines of the 24,665 (8.5%), and they are the 5 files
with **no mbuf use at all** — which is the same finding as Finding 1, seen from the other side.

## Harness bugs found this session — each would have manufactured a green run

The count is now **11** across three sessions (5 in `iwx/STATUS.md`, 3 more noted there, 3 here).
All the same shape: *a check that cannot fail.*

1. **`grep -v '\*'` matched a comment.** The by-value-mbuf check filtered out any line containing
   `*` to exclude pointer declarations — and so also excluded `struct mbuf m0;  /* comment with a
   * in it */`. A synthetic probe with two by-value declarations reported only **1 of 2**. Fixed by
   comment-stripping every file first (`/tmp/strip.py`, line-count-preserving, verified 31/31), then
   re-running: the probe now finds 2/2 and the real tree reports 0. **The "invariant holds" result
   in Finding 1 is from the fixed version.**
2. **A whole-tree error total of `0`, printed as a pass.** Capturing gcc's output into a shell
   variable and piping it hit `Argument list too long`; every `grep -c` in the loop died, `$e` was
   empty, and the script printed `TOTAL error surface: 0` — a **fake clean build across the whole
   tree**. Rewritten to write per-file log *files*. The real total is 838.
3. **A line-range "call" that was a definition.** The `splnet` nesting check (Finding 3) scanned
   past the end of each function and scored the *next function's definition* as a call to itself,
   reporting **3 false nests**. Replaced with brace-matched extraction plus a positive and a
   negative control. Real count: 1.

Also: `grep -ohE '->m_...'` silently consumed `->` as a command-line option (`invalid option --
'>'`) and produced empty output that read as "no field accesses." Fixed with `-e`; the corrected
count is **311** field arrows. A fourth: the first draft of the Finding 1 table reported **351** by
adding the 80 `m_pkthdr.<member>` counts to the 80 `->m_pkthdr` arrows they are a *subset* of —
caught by re-deriving every number from the source before publishing, not by review. And the 4-way
error classifier was cross-controlled — each bucket
matches a synthetic member of its own class and is confirmed **not** to match another's — because
an over-broad pattern would have inflated the mbuf share, which is the number this document leans
on hardest.

## Both harnesses re-run this session

```
./run-mbuf-tests.sh   -> exit 0.  71 + 26 + 23 = 120 checks pass; 13/13 sabotages
                         caught, each compiled first, each with a distinct failure count.
./build-check.sh --self-test -> exit 0.  0 residual errors, 220,928-byte object,
                         263 text symbols, openbsd-orig/ clean, all 8 negative controls live.
```

Both green. But `build-check.sh` was observed to exit **1** earlier in the same session, on an
**unchanged port**, and the reason is worth recording because it is a live gate weakness:

```
dirty-detect control: git porcelain returned NOTHING for the whole port dir
                      -- cannot distinguish clean from broken
```

That control tests the "`openbsd-orig/` must be unmodified" check by asking git for *any* change
under `iwx/`, on the tacit assumption that something there is always dirty. Session two's work is
now committed, so at the start of this session `iwx/` was clean, the control had **no input**, and
the gate correctly announced that one of its own controls could not fire. It then passed again
later only because **editing `STATUS.md` and `SPLNET-AUDIT.md` re-dirtied the directory.**

So the control's verdict depends on **whether unrelated files happen to be dirty** — it is green
while you are working and red the moment the tree is clean, which is backwards. It is a **false
alarm about a real hole**: the check it guards asks the right question, but the guard proves nothing
when there is nothing to see. Fixing it properly means what the SG-guard lesson in
`docs/working-with-subagents.md` prescribes — a **test hook** that injects a synthetic dirty path,
rather than relying on incidental dirt. Named here rather than silenced, because a control that has
been quietly weakened is exactly the failure mode this project keeps paying for.

## Honest sizing

`iwx/STATUS.md` estimated route (b) at "roughly 3× the shim work already done ... weeks, not days."
Measured against the actual files:

| dimension | if_iwx.c (done) | net80211 (to do) | ratio |
|---|---|---|---|
| lines | 12,884 | 24,665 (17,850 for the needed subset) | 1.4-1.9× |
| starting error surface | 364 | **838** | **2.3×** |
| mbuf lines needing rewrite | 58 | **487** | **8.4×** |
| `splnet` regions | 15 | 24 | 1.6× |
| `timeout_*` calls | 32 | 78 | 2.4× |
| absent subsystems | `ifnet` (invented locally) | `ifnet` + **`ifmedia`** + **`ether_*`** + 3 crypto primitives | — |

The 3× estimate is **confirmed on most axes and too low on the one that matters** — the mbuf layer,
at 8.4×, in the code that has already needed two negative controls to find two real bugs in its own
translation.

## The recommendation, and the alternative worth pricing

**The 43 symbols are not resolvable incrementally.** They are spread across 7 files that transitively
need 13 of the 18, and 60% of the error surface is in the one layer whose per-site cost is highest.
There is no subset that both compiles and contains any of the 43.

Before committing weeks, the cheaper thing to price is a question this session did **not** answer,
because it was out of scope and route (a) was refuted only for *adapting to* illumos net80211:

> Can OpenBSD net80211 sit **on top of** GLDv3 as a self-contained module — its own `ifnet`,
> its own media table, its own node cache — presenting `mac_register` upward and the
> `ic_*` callback vector downward to `iwx`, with illumos's own net80211 untouched?

That reframes the 88 `ifmedia` errors and the 80 `ifnet` references as *one* adapter written once,
instead of the stack integration the current shim path implies. It does **not** reduce the 487 mbuf
lines, which remain the floor on any route.

**This is a hypothesis, not a plan, and it is not measured.** It is recorded because the alternative
the brief assumed — shim net80211's OpenBSD-kernel calls one by one — has now been measured at 838
errors across four absent subsystems, and the maintainer should see both before choosing.

## Reproducing

```sh
cd src/wifi-port
UTS=/home/gburd/src/illumos-gate/usr/src/uts

# error surface, per file (writes a log per file -- never aggregate via $(...))
for f in net80211-openbsd/orig/*.c; do
  gcc -m64 -fsyntax-only "$f" -D_KERNEL -ffreestanding -nostdinc \
      -include sys/iwx_prelude.h -include sys/mbuf.h \
      -Inet80211-openbsd/compat -Iiwx/compat -Iiwx \
      -I$UTS/common -I$UTS/intel -I$UTS/i86pc -Wno-format \
      > /tmp/n80logs/$(basename $f).log 2>&1
  printf '%-26s %s\n' "$(basename $f)" "$(grep -c 'error:' /tmp/n80logs/$(basename $f).log)"
done

# the 3 that reach a real object
for b in ieee80211_amrr ieee80211_ra ieee80211_ra_vht; do
  gcc -m64 -c -o /tmp/$b.o net80211-openbsd/orig/$b.c \
      -D_KERNEL -ffreestanding -nostdinc -include sys/iwx_prelude.h \
      -include sys/mbuf.h -Inet80211-openbsd/compat -Iiwx/compat -Iiwx \
      -I$UTS/common -I$UTS/intel -I$UTS/i86pc -Wno-format
done

# and confirm they resolve NONE of the 43
nm iwx/build/if_iwx_illumos.o | awk '$1=="U"{print $2}' | grep '^ieee80211' | sort -u > /tmp/need
nm /tmp/ieee80211_*.o | awk '$2=="T"{print $3}' | sort -u > /tmp/have
comm -12 /tmp/have /tmp/need        # empty
```

Harness re-runs: `cd iwx && ./run-mbuf-tests.sh && ./build-check.sh --self-test`.
