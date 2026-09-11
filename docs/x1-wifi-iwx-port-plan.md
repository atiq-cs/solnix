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

## Correction measured while building `usb-image-20260911j`: the 15 drivers are NOT ON THE MEDIA

The section above says a USB adapter with an `urtw`/`rum`/`ural`/`zyd`/`atu` chipset "works today with
no porting". That is true of illumos-the-project. It is **not** true of solnix's media, and the
difference matters to anyone about to buy a dongle.

Measured inside the SHIPPED ramdisk of `usb-image-20260911j` (extracted from the finished `.iso` and
lofi-mounted, not read from a build log):

| probe | result |
|---|---|
| 802.11 drivers in `kernel/drv/amd64` (`arn ath atu ipw iwh iwi iwk iwn mwl rtw rum ural urtw wpi zyd pcwl pcan`) | **ZERO** |
| `kernel/misc/amd64/net80211` (the 802.11 framework) | **present** |
| total drivers in the ramdisk | 215 |
| `wificonfig(8)` | **absent** |
| `dladm`, `ipadm`, `dhcpagent` | present |

The media ships the whole driver tree of the build host and passes a host-vs-ramdisk equality gate, so
this is not a staging shortfall -- **the OpenIndiana build host itself has no 802.11 drivers installed**,
and the `hipster` catalog on it offers none: a full `pkg list -a` contains no `driver/network/` entry for
any of the 15 names (only `pcwl`/`pcan`, both obsolete PCMCIA, neither installed nor in the ramdisk).
`net80211` is present only because it belongs to `system/kernel`.

WARNING on instrument choice: `pkg search -r` returned **empty even for `e1000g`**, a driver that is
demonstrably installed. It is a dead instrument on this host, and an earlier draft of this note nearly
concluded "no wifi packages exist at all" from it. `pkg list -a` is the one that works. This is the same
measure-the-wrong-object failure that produced the original "illumos has zero wifi drivers" claim from
grepping an EC2 VM's `/kernel/drv/amd64`.

### So the honest buying advice is

1. **USB-Ethernet is the only thing that works on this media today.** Verified present in the shipped
   ramdisk: `axf` (ASIX AX88772 -- the chipset in most cheap USB2 dongles) and `usbecm` (CDC-ECM /
   standards-class adapters). Wired NICs `atge`, `e1000g`, `igb`, `rge` are there too. **Buy an
   AX88772-based USB-Ethernet dongle**; it should attach with no work.
2. **A USB wifi dongle needs a driver-staging step first.** Even holding an `urtw`-class chipset, the
   driver is neither on the media nor in the build host's catalog, so it must be built from
   illumos-gate source and staged. Smaller than the `iwx` port, but **not** "works today".

Both statements are about `usb-image-20260911j` specifically. Media built from a host that *does* have
the wifi driver packages installed would ship them, because the driver-coverage gate copies whatever the
host has -- so "install the wifi packages on the build host, rebuild" is the cheapest experiment if a
USB wifi dongle is the goal.
