# MTU policy for cloud NICs (ena/vioif/…) — adaptive, evidence-based

**Status: design + lesson. The boot-safe default (1500) is shipped; the
adaptive raise-after-DHCP is the follow-on (dispatched).**

## The lesson (why this doc exists)

We shipped a solnix EC2 AMI whose `ena` NIC defaulted its MTU to the **device
maximum (jumbo, 9216)** at driver attach. On many Nitro backends a receive
queue programmed with jumbo-sized Rx buffers **does not reliably deliver small
broadcast frames** (notably the DHCP OFFER) on cold boot — so the interface
came up link-up + TX-working but **never received a DHCP reply**, never got a
lease, and the instance was unreachable. Fresh cold-launch success was ~29%.

**Two compounding traps:**
1. Defaulting to the device max MTU instead of a boot-safe MTU.
2. `ena_m_setprop` returning `ENOTSUP` for `MAC_PROP_MTU`, so the MTU **could
   not be lowered at runtime** — `ifconfig ena0 mtu 1400` silently failed.
   The default was effectively permanent.

**Do not make either mistake again.** A cloud NIC must (a) boot at a MTU that
reliably completes DHCP, and (b) support changing the MTU at runtime.

## The policy: boot safe, then raise per-instance

MTU is **not** a fixed constant — it depends on the instance type and network
path. The correct behavior maximizes MTU per host **without breaking boot**:

1. **At driver attach: default to 1500 (`ETHERMTU`), clamped to the device
   max.** This is boot-safe everywhere — DHCP always completes. (Matches
   FreeBSD `if_ena` and Linux `ena`, which both come up at 1500 and negotiate
   up.) *(Shipped: `pkgs/illumos/patches/ena-default-mtu-1500.patch`.)*

2. **Make `MAC_PROP_MTU` settable at runtime** (`ena_m_setprop` +
   `ena_m_propinfo` must handle `MAC_PROP_MTU`: validate against
   `[ETHERMIN, ena_max_mtu]`, reprogram the Rx/Tx buffer sizes / re-init the
   IO queues, update `ena_mtu`). Without this, no adaptive raise is possible.
   *(Follow-on: `pkgs/illumos/patches/ena-runtime-mtu.patch`.)*

3. **After the network is up (post-DHCP), raise the MTU to the maximum the
   instance's path actually supports** — a first-boot service, gated on a
   working lease, sets the MTU based on **evidence**, not assumption:
   - Query the device max (`ena_max_mtu`, exposed via a link property /
     `dladm show-linkprop -p mtu ena0` "possible" range).
   - Query the instance type from IMDS
     (`http://169.254.169.254/latest/meta-data/instance-type`).
   - Choose the MTU by policy (below), verify connectivity still works at the
     new MTU (a small ping/probe to the default gateway or IMDS), and **roll
     back to 1500 if the probe fails** — so a bad path never wedges the box.
   *(Follow-on service: first-boot `solnix-mtu` in `modules/config/`.)*

## Evidence-based MTU table (EC2, within-VPC)

AWS supports jumbo frames (**9001**) within a VPC on most current instance
types; some paths (internet gateway, some older/smaller types, cross-region,
VPC-peering-without-jumbo) are limited to **1500**. So the policy is:

| Instance class | Path | MTU to set (after boot) |
|----------------|------|-------------------------|
| Nitro, jumbo-capable (m5/m6i/c5/c6i/c7i/r5/r6i/…, `.metal`) | within-VPC | **9001** (AWS VPC jumbo), clamp to `ena_max_mtu` |
| Any instance | traffic via internet gateway / peered-without-jumbo | **1500** |
| Detected-unsupported / probe fails | — | **1500** (safe fallback) |
| Unknown / can't reach IMDS | — | **1500** (safe default already at boot) |

The device may report `ena_max_mtu` = 9216; AWS's *supported* within-VPC MTU
is **9001**. Set `min(9001, ena_max_mtu)` when jumbo is chosen, never the raw
device max blindly (that was the original bug).

**Verification before committing a raise:** after setting the candidate MTU,
probe reachability (ping the gateway / fetch IMDS). Only keep it if the probe
succeeds; otherwise revert to 1500. Boot reliability always wins over jumbo.

## Generalization to other clouds / NICs

The same rule applies to any cloud/virtual NIC (GCP `gve`, Azure `mlx`/`hn`,
KVM `vioif`, Xen): **boot at 1500, make MTU runtime-settable, raise to the
path-supported maximum after the network is verified up.** Never bake the
device-max MTU as the attach default; never ship a NIC whose MTU can't be
changed at runtime.

## Files
- `pkgs/illumos/patches/ena-default-mtu-1500.patch` — boot-safe default (shipped).
- `pkgs/illumos/patches/ena-runtime-mtu.patch` — make `MAC_PROP_MTU` settable
  (follow-on).
- `modules/config/mtu.nix` + a first-boot `solnix-mtu` SMF service — the
  evidence-based post-DHCP raise (follow-on).

## Finding (2026-08-08): today's illumos ena can't do jumbo RX -> 1500 is the RIGHT value, not just safe
The adaptive machinery is built + ready (runtime-settable MAC_PROP_MTU + the evidence-based
first-boot service), BUT on the tested Nitro backends a real jumbo RECEIVE at 9001 LATCHES the ENA
fatal-error bit: `rx_sgl_max=1` means a single ~12KB Rx buffer, and the first ~8KB receive wedges the
NIC (DHCP completes at 9001 but the first big receive dies). So on TODAY's illumos ena, 1500 is not
just boot-safe -- it's the only reliable MTU, and the first-boot service correctly probes-then-settles
at 1500 (its 8KB jumbo round-trip probe fails -> revert). ALSO: driving the driver's only ring-realloc
primitive (ena_reset, an error-recovery path, illumos 16391) under an active data path latches fatal
0x21 -> so runtime MTU change returns EBUSY when the link is UP (applies at a clean stopped/attach
state, like i40e/igb). NET: the patch + service AUTO-ENABLE jumbo on any driver that supports a
verified live resize + jumbo RX; on the current ena they keep 1500. When a newer ena driver fixes
jumbo RX (rx_sgl / scatter-gather), jumbo turns on automatically with no further work.
Patches: ena-default-mtu-1500.patch (attach default), ena-runtime-mtu.patch (runtime-settable +
EBUSY-when-up). Service: modules/config/mtu.nix + scripts/solnix-mtu.sh.
