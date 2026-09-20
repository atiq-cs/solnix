# No OpenSolaris fork has AX2xx — and what a native `iwx` driver would take

## 1. The fork survey: nothing to adopt

Searched every reachable OpenSolaris-family gate for a driver claiming AX200/AX201/AX210.

| fork | wifi drivers | newest Intel |
|---|---|---|
| `illumos/illumos-gate` | `arn ath atu ipw iwh iwi iwk iwn mwl rtw rum ural urtw wpi zyd` | **`iwn`** — 4965/5000/6000 |
| `omniosorg/illumos-omnios` | **identical set** | same |
| `TritonDataCenter/illumos-joyent` | **identical set** | same |
| `nexenta/illumos-nexenta` | + **`iwp`** | `iwp` = *"Intel(R) WiFi Link 6000 Driver"* — **same era as `iwn`** |
| Solaris 11.4 | `iwlwifi` as a **closed binary** | not source, not licensable |

`iwp` was the only driver outside the mainline set and looked promising until measured: 5,423 lines, header
says WiFi Link 6000. Same generation.

**Zero AX2xx PCI ids anywhere.** Checked `0x2723` (AX200), `0x2725` (AX210), `0x02f0`/`0x4df0`/`0x43f0`/`0xa0f0`
(AX201) against `iwn`, `iwh`, `iwk`, `wpi`, `arn`, `ath` — no match.

**Conclusion: there is nothing to adopt.** The OpenSolaris lineage stopped at the 6000 series, roughly 2010.

## 2. Why "native" is a genuinely different proposition from the port

The failed port tried to bring OpenBSD's *driver plus its network stack* onto illumos. That failed because
`ifmedia` and `ether_*` **do not exist on illumos** -- 88 errors and an interface the kernel never had, with
GLDv3 inverting the direction of control.

A native driver inverts the approach: **keep the device half of `iwx`, supply the 802.11 stack it expects,
and present GLDv3 upward.**

### The 802.11 route: (b), not (a) -- decided on measurement, do NOT re-attempt (a)

There were two candidate routes for the 802.11 layer, and this is the single most important architectural
decision in the project, so it is stated at the top rather than buried:

* **Route (a) -- adapt `iwx`'s `ieee80211_*` calls to illumos's OWN `net80211`.** This is the intuitive
  "keep illumos's stack" plan, and it is **REFUTED by measurement** (`src/wifi-port/iwx/STATUS.md`,
  `iwx_illumos.h`). Do not revisit it:
    - Of the 76 distinct `ieee80211_*` symbols `iwx` uses, **53 (70%) do not exist in illumos net80211 by
      name at all**; of the 48 it *calls*, **34 are absent** (the entire block-ack machinery, HT/VHT node
      predicates, `set_key`/`delete_key`, `release_node`, `inputm`, ...).
    - `struct ieee80211_node` has **109 members in OpenBSD, 55 in illumos, and ZERO shared member names** --
      illumos renamed every field `ni_*` to `in_*`, so all **182** `ni_*` accesses in `if_iwx.c` break, and
      it is **not a rename** because illumos has no equivalent for OpenBSD's RSN/block-ack/VHT node state.
      Only **17 of 56** `ic_*` field names exist on `ieee80211com`.
    - Where names *do* match, signatures diverge (`ieee80211_encap`, `ieee80211_begin_scan`).
* **Route (b) -- vendor OpenBSD's `net80211` alongside, as a self-contained 802.11 module, and present
  GLDv3 `mac_register` UPWARD.** This is the **CHOSEN architecture.** illumos's own `net80211` is left
  untouched; the driver binds to the vendored OpenBSD `net80211` below (`iwx_softc.sc_ic` is an OpenBSD
  `struct ieee80211com`) and to illumos GLDv3 above. The cost is real -- 24,665 lines of net80211 to bring
  up, measured at 838 compile errors with 0 of the 43 blocking `ieee80211_*` symbols yet resolved
  (`src/wifi-port/net80211-openbsd/FINDINGS.md`) -- but the semantic risk of route (a) is avoided entirely.

| layer | native driver (route b) |
|---|---|
| 802.11 state machine, crypto, nodes, HT | **vendored OpenBSD `net80211`** (24,665 lines) -- illumos's own net80211 is NOT used |
| MAC registration, TX/RX | **GLDv3 `mac_*`** -- the mac_register-upward boundary; `iwn` uses 9 such calls |
| DMA, interrupts, register access, DDI attach | **`ddi_*`** -- shimmed in `iwx_illumos.h`; the DDI+GLDv3 attach glue is `src/wifi-port/iwx/iwx_attach.c` |
| **firmware load, queues, commands, PHY** | the vendored `if_iwx.c`, translated (mbuf layer done, compiles to a `.o`) |

> WARNING: **the `iwn`-style attach that calls illumos `ieee80211_attach(ieee80211com_t *)` does NOT apply
> to a route-(b) driver.** `iwx_softc.sc_ic` is an OpenBSD `struct ieee80211com` and cannot be passed to
> illumos's `ieee80211_attach`; the structs share nothing. `iwn` is the reference only for the *illumos
> side* of attach -- `ddi_regs_map_setup`, `pci_config_setup`, `mac_alloc`/`mac_register`, the module
> linkage, the `mac_callbacks` vector. The 802.11 attach for route (b) is OpenBSD's `ieee80211_ifattach`,
> and it links only once the vendored net80211 does.

Precedent for the device-half size: **`iwn` is 10,337 lines total; `iwh` is 6,603.** But route (b) also
carries the vendored 802.11 stack, so the total is larger than a from-scratch native driver would be -- the
tradeoff bought by not re-implementing block-ack, RSN and the HT node model against illumos's diverged API.

## 3. What we already have that carries over

* `openbsd-orig/if_iwx.c` — **not as code to compile, as the reference manual.** It documents the AX2xx
  firmware handshake, queue layout and command set. That knowledge is the expensive part and it is BSD-licensed.
* **Firmware names and selection logic** — `iwx-cc-a0-77` (AX200), `iwx-QuZ-a0-hr-b0-77` / `iwx-Qu-{b0,c0}-hr-b0-77`
  (AX201), chosen at attach from PCI id + revision (`if_iwx.c:12387-12421`).
* `pkgs/illumos/iwx-firmware.nix` — unfree-gated derivation, opt-in controlled both ways.
* `iwx_illumos.h` — the DMA/register/delay/taskq shims are **substrate-agnostic** and still useful.
* `iwx_mbuf.c` + 120 checks / 13/13 sabotages — **load-bearing under route (b)**, not wasted. `if_iwx.c` and
  the vendored net80211 both use OpenBSD `struct mbuf`; the translation layer maps it to `mblk_t` and is
  what took `if_iwx.c` from 364 errors to a `.o`. (This line previously said the mbuf work was "wasted on a
  native driver that uses `mblk_t` directly" -- that was the route-(a) view, superseded when route (b) was
  chosen: the OpenBSD-net80211 code does NOT use `mblk_t` directly, so the layer is essential.)

## 4. ⚠️ Three things that could sink this — resolve before writing code

**(a) `net80211` predates everything AX2xx is.** It has `net80211_ht.c` (802.11n) but **no VHT (11ac) and no HE
(11ax)**. An AX200 would associate at **11n rates** — a few hundred Mbit, not AX speeds. Acceptable, but it
must be said up front rather than discovered.

**(b) Crypto: CCMP/TKIP/WEP only.** WPA2 works. **WPA3/SAE needs GCMP and userland support that does not
exist** — so WPA3-only networks are out until `net80211` gains it.

**(c) The firmware API is the real risk.** AX2xx firmware is a *versioned contract*: the driver must speak the
exact API revision of the blob. `iwx` verifies it and refuses mismatches. This is where a from-scratch driver
most plausibly stalls, and it is not visible until hardware.

## 5. Plan, in dependency order -- with MEASURED status

Status is compile+structure only (no hardware). "compiles" means a real ELF kernel object against illumos
headers; it is NOT "links as a module" and NOT "runs". See `src/wifi-port/iwx/STATUS.md` for the full ladder.

| phase | deliverable | gate | measured status |
|---|---|---|---|
| **0** | **Decide it is worth it** — 11n-only, WPA2-only | maintainer's call | **DONE** (yes) |
| **1** | attach: `ddi_attach`, BAR map, `mac_register` (GLDv3), 802.11 attach | `prtconf` shows the driver bound | **illumos side COMPILES** — `iwx_attach.c` -> kernel `.o`, `_init`/`_fini`/`_info` + `mac_alloc`/`mac_register`/`ddi_regs_map_setup`/`pci_config_setup` all resolve as undefined kernel symbols. 802.11 attach (`ieee80211_ifattach`) is GATED on the net80211 link. |
| **2** | **Firmware load + alive handshake** — highest-risk, done early | firmware accepted, alive notification received | **COMPILES** — `iwx_read_firmware`/`iwx_start_fw`/`iwx_load_ucode_wait_alive` are real text symbols in `if_iwx_illumos.o`; the API-version contract (magic, `IWX_UCODE_TLV_API_CHANGES_SET`, `iwx_lookup_notif_ver`, `IWX_ALIVE_STATUS_OK` -> `uc_ok`, `EINVAL` on mismatch) is present. **Acceptance/alive-interrupt is HARDWARE-GATED (the X1).** |
| **3** | Queues + command path (`iwx_send_cmd`, native locking) | device answers a no-op command | code compiles; the `splnet`->mutex locking fix is audited but NOT implemented (`SPLNET-AUDIT.md`) |
| **4** | RX path → 802.11 input | beacons visible in a scan | GATED on net80211 link + hardware |
| **5** | TX path + CCMP | associates with a WPA2 AP, passes traffic | GATED on net80211 link + hardware |

**Phase 2 before phase 3** deliberately: if the firmware handshake cannot be made to work, everything after it
is wasted, so it should fail early and cheaply.

### The TWO gates route (b) must clear (they are independent)

Route (b) has two distinct walls, and confusing them muddies the plan:

1. **The net80211-LINK gate.** The vendored OpenBSD net80211 must compile and LINK, resolving the **43
   blocking `ieee80211_*` symbols** `if_iwx.c` needs. Measured: **0 of 43 resolved**, 838 errors, 3 of 18
   `.c` files compile (`src/wifi-port/net80211-openbsd/FINDINGS.md`). This is weeks of work, dominated by the
   mbuf layer (487 rewrite lines, 8.4x what `if_iwx.c` needed). **The phase-1 GLDv3 attach `.o` builds
   INDEPENDENTLY of this gate** (it references 0 `ieee80211_*` symbols, proven by `build-check.sh`). What the
   net80211 link gates is the DOWNWARD bridge: the `mac_callbacks` (`mc_ioctl`/`mc_setprop`/`mc_getprop`) that
   an illumos wifi driver routes into net80211. In `iwx_attach.c` those are marked `IWX_NET80211_GATED` and
   fail closed until an OpenBSD-net80211 adapter exists.
2. **The HARDWARE gate.** Everything above phase 1's compile is unverifiable without the X1's AX2xx. In
   particular phase 2's true test — the firmware being *accepted by the silicon* and a real `IWX_ALIVE`
   interrupt arriving — cannot happen off-hardware. The code is structured so that on the X1 a version
   mismatch yields a clean `EINVAL` ("could not load firmware") rather than a crash; that is the most the
   compile can guarantee.

## 6. Honest recommendation

This is a **real project** — comparable to the riscv64 kernel work, and it delivers **11n speeds on WPA2**.

The alternative costs about £15: a **USB-Ethernet dongle** (works today), or a USB wifi adapter matching
`urtw` (Realtek RTL8187), `rum`/`ural` (Ralink), `zyd` (ZyDAS) or `atu`. Those are 802.11g, so *slower* than a
native AX2xx driver would be — but available now, with zero risk.

**Recommendation: take the dongle for daily use, and treat the native driver as a deliberate project rather
than a blocker.** Phase 1 (attach) is cheap and would tell us a lot; phase 2 is where the real answer lives.
