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
`ifmedia` and `ether_*` **do not exist on illumos** — 88 errors and an interface the kernel never had, with
GLDv3 inverting the direction of control.

A native driver inverts the approach: **keep illumos's stack, write only the device half.**

| layer | native driver |
|---|---|
| 802.11 state machine, crypto, nodes, HT | **illumos `net80211`** — 12,981 lines, already there |
| MAC registration, TX/RX | **GLDv3 `mac_*`** — `iwn` uses 9 such calls |
| DMA, interrupts, register access | **`ddi_*`** — already shimmed in `iwx_illumos.h` |
| **firmware load, queues, commands, PHY** | **the only new code** |

Precedent: **`iwn` is 10,337 lines total; `iwh` is 6,603.** So a native Intel driver on this substrate is
roughly **7–11k lines**, not the 24,665-line stack port.

## 3. What we already have that carries over

* `openbsd-orig/if_iwx.c` — **not as code to compile, as the reference manual.** It documents the AX2xx
  firmware handshake, queue layout and command set. That knowledge is the expensive part and it is BSD-licensed.
* **Firmware names and selection logic** — `iwx-cc-a0-77` (AX200), `iwx-QuZ-a0-hr-b0-77` / `iwx-Qu-{b0,c0}-hr-b0-77`
  (AX201), chosen at attach from PCI id + revision (`if_iwx.c:12387-12421`).
* `pkgs/illumos/iwx-firmware.nix` — unfree-gated derivation, opt-in controlled both ways.
* `iwx_illumos.h` — the DMA/register/delay/taskq shims are **substrate-agnostic** and still useful.
* `iwx_mbuf.c` + 120 checks / 13/13 sabotages — **the mbuf work is wasted** on a native driver, which uses
  `mblk_t` directly. Keep the tests' *discipline*, discard the layer.

## 4. ⚠️ Three things that could sink this — resolve before writing code

**(a) `net80211` predates everything AX2xx is.** It has `net80211_ht.c` (802.11n) but **no VHT (11ac) and no HE
(11ax)**. An AX200 would associate at **11n rates** — a few hundred Mbit, not AX speeds. Acceptable, but it
must be said up front rather than discovered.

**(b) Crypto: CCMP/TKIP/WEP only.** WPA2 works. **WPA3/SAE needs GCMP and userland support that does not
exist** — so WPA3-only networks are out until `net80211` gains it.

**(c) The firmware API is the real risk.** AX2xx firmware is a *versioned contract*: the driver must speak the
exact API revision of the blob. `iwx` verifies it and refuses mismatches. This is where a from-scratch driver
most plausibly stalls, and it is not visible until hardware.

## 5. Plan, in dependency order

| phase | deliverable | gate |
|---|---|---|
| **0** | **Decide it is worth it** — 11n-only, WPA2-only, 7–11k lines | maintainer's call |
| **1** | `iwx` attaches to the PCI device: `ddi_attach`, BAR map, `mac_register`, `ieee80211_attach` | `prtconf` shows the driver bound; no traffic |
| **2** | **Firmware load + alive handshake** — the highest-risk step, so do it early | firmware accepted, alive notification received |
| **3** | Queues + command path (`iwx_send_cmd` equivalent, native locking) | device answers a no-op command |
| **4** | RX path → `net80211_input` | beacons visible in a scan |
| **5** | TX path + CCMP | associates with a WPA2 AP, passes traffic |

**Phase 2 before phase 3** deliberately: if the firmware handshake cannot be made to work, everything after it
is wasted, so it should fail early and cheaply.

## 6. Honest recommendation

This is a **real project** — comparable to the riscv64 kernel work, and it delivers **11n speeds on WPA2**.

The alternative costs about £15: a **USB-Ethernet dongle** (works today), or a USB wifi adapter matching
`urtw` (Realtek RTL8187), `rum`/`ural` (Ralink), `zyd` (ZyDAS) or `atu`. Those are 802.11g, so *slower* than a
native AX2xx driver would be — but available now, with zero risk.

**Recommendation: take the dongle for daily use, and treat the native driver as a deliberate project rather
than a blocker.** Phase 1 (attach) is cheap and would tell us a lot; phase 2 is where the real answer lives.
