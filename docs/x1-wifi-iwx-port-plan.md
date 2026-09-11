# Porting AX2xx wifi to solnix: OpenBSD `iwx` is the right source, and it is weeks not hours

## The maintainer is right, and better-informed than I was

I said "no BSD to crib from". **Wrong.** OpenBSD has `if_iwx.c` — a native BSD-licensed driver for the
AX2xx generation, with **no LinuxKPI shim**. Measured from the OpenBSD tree:

| file | lines |
|---|---|
| `sys/dev/pci/if_iwx.c` | **12,884** |
| `sys/dev/pci/if_iwxreg.h` | **8,961** |
| total | **21,845** |

And it claims the right hardware: the device table contains `PCI_PRODUCT_INTEL_WL_22500_1` through
`_18`, which is the **AX200/AX201** family — the X1 Carbon's card. 70 references to the AX generation
throughout.

That is a far better starting point than Linux's `iwlwifi` mvm (~50k lines, LinuxKPI required) and it
is why the earlier "FreeBSD has nothing, so there is nothing to crib" conclusion was wrong. FreeBSD's
LinuxKPI path is the awkward one; **OpenBSD's is a clean BSD driver**.

## But it cannot go into today's image, and here is the measured reason

`iwx` is written against OpenBSD's kernel APIs. The call sites needing translation:

| API family | sites | maps to on illumos |
|---|---|---|
| `ieee80211_*` | **273** | illumos `net80211` — **exists, but is a different API** (it is FreeBSD-derived, OpenBSD's has diverged) |
| `m_*` (mbuf) | **309** | `mblk_t` / STREAMS — no 1:1 mapping |
| `if_*` (ifnet) | **97** | GLDv3 `mac_*` |
| `bus_dmamap_*` | **50** | `ddi_dma_*` |
| `task_*` / `timeout_*` | **69** | `ddi_taskq_*` / `timeout(9F)` |

**~750 call sites across two different 802.11 stacks.** illumos *has* `net80211` (14 files, including
`net80211_crypto_ccmp.c` and `net80211_ht.c`), so the stack exists — but OpenBSD's `ieee80211_*` and
illumos's are not the same interface, so the 273 sites are translation, not recompilation.

This is the crib-and-adapt doctrine at its largest scale in this project so far. Comparable prior work:
the aarch64 GICv3 port and the riscv64 kernel were each multi-week. **Weeks, not one build.**

## Firmware — a hard external dependency

Regardless of driver licence, AX2xx needs Intel's proprietary `iwlwifi-*.ucode` blobs loaded at runtime.
Those are redistributable but not open, and the driver is useless without the matching API version. Any
port must include a firmware-loading path and the blob must land on the media.

## Staged plan

1. **Vendor the OpenBSD source** into `src/wifi-port/iwx/` unmodified, with provenance — same pattern as
   `src/aarch64-arm64-gate-patches/` and the DRM port. Read-only reference.
2. **Write the shim layer** (`iwx_illumos.h`): mbuf→mblk, ifnet→GLDv3, `bus_dma`→`ddi_dma`,
   `task`/`timeout`. This is the bulk of the work and it is where a port either survives or dies.
3. **Decide the 802.11 question**: adapt `iwx`'s `ieee80211_*` calls to illumos `net80211`, or vendor
   OpenBSD's `net80211` too. The second is more code but far less semantic risk — worth measuring both
   before choosing.
4. **Firmware plumbing** + the blob on the media.
5. **Bring-up on the X1**, which is the only machine that can test it.

## What the maintainer can do this week instead

illumos ships **15** wifi drivers, and five are **USB**: `urtw`, `rum`, `ural`, `zyd`, `atu`. A USB
adapter with one of those chipsets works today with no porting:

* **`urtw`** — Realtek RTL8187/RTL8187B (common, cheap, widely sold as "RTL8187L")
* **`rum`** — Ralink RT2501USB / RT2601USB
* **`ural`** — Ralink RT2500USB
* **`zyd`** — ZyDAS ZD1211/ZD1211B

These are 802.11g-era, so expect ~20 Mbit rather than AX speeds — but they associate and route today.
A **USB-Ethernet dongle** remains the fastest, most boring option.

## Status

Vendoring and the shim design start now; **it is not in the installer image being built today**, and
saying otherwise would be the overclaiming this project has already had to retract three times.
