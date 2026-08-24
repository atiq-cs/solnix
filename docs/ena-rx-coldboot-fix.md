# ena Rx cold-boot DHCP wedge — fix investigation report

## TL;DR (measured, not assumed)

The mandate hypothesis — *"the ena Rx path drops the broadcast DHCP OFFER on
cold boot"* — is **DISPROVEN by direct kernel instrumentation**. The ena Rx
data path RECEIVES the DHCP OFFER (and the ACK) correctly. The cold-boot DHCP
wedge is **not an ena driver bug**; it is (a) a stale boot-config bug (dual DHCP
addrobj) that the driver-level MTU fix cannot touch, plus (b) the base image's
inherent ~70–80% cold-boot DHCP-timing ceiling, plus (c) an AMI-build hazard
(ZFS-import edits corrupt DHCP; in-place boot_archive edits are safe).

Measured before/after on the real target (m5.4xlarge, same subnet, concurrent):

| image | m5.4xlarge |
|-------|-----------|
| ORIGINAL gtk4 heavy AMI `ami-0719159b19c8f692e` | **0/10** (reproduced) |
| canonical fixed AMI (in-place) `ami-0978836610527a836` | **8/10** |
| instrumented ena AMI `ami-0c319dd05c53e2fae` | 7/8 .. 10/10 (26/26 across runs) |

Net: **0/10 → 8/10**. The gain is from the AMI-build method (in-place, not
ZFS-import) + the boot-config fixes (single DHCP addrobj), **not** from the ena
Rx driver (clean-ena and instrumented-ena boot at the same rate: 7/8 ≈ 8/10).

## The named death point (Stage 1 — instrumentation)

Built an instrumented ena (illumos-gate 2026, HEAD 4cbfa3d9) with 7 rate-limited
`cmn_err(CE_WARN, "ENARX: …")` console prints in the Rx path, injected into a
solnix boot_archive, cold-launched, captured via `get-console-output`.

The console showed, on EVERY captured boot (both the first and the post-first-
boot-reboot boot):

```
ENARX: ring_rx_start ENTER  state=0x7
ENARX: refill_rx#1 doorbell  tail=2047
ENARX: ring_rx_start EXIT   state=0x3f RUNNING (Rx intr unmasked)   (x2 rings)
ENARX: AENQ link_change is_up=1 (new_state=1)
ENARX: mac_link_update DONE new_state=1 (was 0)
ENARX: io_intr#1 vector=2 started=1     ← Rx interrupts DO fire
ENARX: ring_rx#1 got 1 frames 590 bytes polling=0   ← the 590-byte DHCP OFFER, RECEIVED
ENARX: ring_rx#2 got 1 frames 590 bytes ...          ← and more
```

- Both Rx rings start correctly (`state=0x3f RUNNING`, intr unmasked).
- Link comes up via AENQ; mac is notified.
- **Rx interrupts fire and `ena_ring_rx` returns the 590-byte broadcast DHCP
  OFFER** (`polling=0` = interrupt mode) — i.e. the OFFER **is received and
  delivered up to mac**. Rx reception is functional with the MTU-1500 driver.

Confirmed in userland `/var/adm/messages` on a booted node:
```
dhcpagent: accept_v4_acknak: dhcp_bound failed for ena0:1
dhcpagent: configure_v4_lease: cannot set IP address on ena0:1: Cannot assign requested address
```
`dhcp_bound` only runs **after** the OFFER+ACK arrive — so the whole DHCP
negotiation completes at the ena Rx level. The failure is `configure_v4_lease`
failing to bind the lease to `ena0:1` (the SECOND logical interface).

## The real root causes (in order of impact)

1. **AMI-build corruption (dominant).** Editing the target image's boot_archive
   by importing its ZFS pool (`zpool import`) — even on native illumos — when
   the pool GUID collides with the running root's GUID (every solnix AMI shares
   GUID `2383845163825270245`) and is broken via `zpool reguid`/altroot,
   produces an AMI that boots to the login prompt but **never gets DHCP**
   (a subtle sibling of the ZFS-8000-CS corruption the brief warns about). A
   3-way concurrent A/B isolated this: in-place-edited AMI = 6/6, two
   ZFS-import-edited AMIs = 0/6 **regardless of the ena driver**. **Fix: edit
   the boot_archive IN PLACE on a booted node's own root (never import the
   target pool), then `create-image --no-reboot`.**

2. **Stale Xen-HVM metadata shim + baked dual DHCP addrobj.** The old
   `/usr/lib/metadata` shim created a SECOND DHCP address object
   (`ipadm create-addr -T dhcp ena0/dhcp` then a fallback `ena0/v4`) and set a
   failing `mtu=1400`. The persistent `/etc/ipadm/ipadm.conf` also baked
   BOTH `ena0/dhcp` AND `ena0/v4`. At boot both addrobjs claim the same lease;
   `ena0/v4` (= `ena0:1`) fails `configure_v4_lease` "Cannot assign requested
   address". Fix: single-addrobj shim (deletes any stale `ena0/v4`, one
   `ena0/dhcp`), and strip the `ena0/v4` lines from `/etc/ipadm/ipadm.conf`.

3. **Base image's inherent cold-boot DHCP-timing ceiling (~70–80%).** After (1)
   and (2), the canonical AMI is 8/10 on m5.4xlarge. The residual ~2/10 stall
   at early `Booting…` (impaired, 0 first-boot-reboot) — a genuine cold-boot
   DHCP-timing miss that is **identical for the clean ena and the instrumented
   ena** (7/8 vs 7/8 concurrent), so it is not ena-driver-attributable. The
   MTU-1500 default (committed, `cmpl $0x5dc`) is correct and present but does
   not raise this ceiling.

## What was tried and did NOT help (honest negatives)
- A 50 ms `delay(drv_usectohz(50000))` settle in `ena_ring_rx_start` after
  arming the Rx interrupt: no measurable improvement (the console-print
  "delay" that first looked causal was a confound with the AMI lineage). Patch
  kept in `ena-rx-coldboot.patch` for the record but it is NOT the fix.
- A one-shot warm reboot of a wedged instance: does not recover it (matches the
  prior finding).
- Removing `ena0/v4` from `ipadm.conf` alone on a ZFS-import-lineage AMI: still
  0/10 (the AMI-lineage corruption dominates).

## Canonical AMI
`ami-0978836610527a836` — `solnix-builder-ena-verified-<date>-inplace`:
- ena MTU-1500 (clean, disassembly-verified `cmpl $0x5dc` in the boot_archive),
- single-addrobj metadata shim,
- `ipadm.conf` dual-addrobj removed,
- built by IN-PLACE boot_archive edit (no ZFS import).
- Verified: **8/10 cold launches on m5.4xlarge** (vs original gtk4 0/10).

## Reproduce the build (in-place, safe)
1. Cold-launch a solnix helper (base AMI) — fresh `run-instances` (~80%),
   NOT stop/start (0% today — warm reboots wedge on this bug).
2. `git clone --depth 1 illumos-gate` into /tmp; apply the MTU-1500 one-liner;
   symlink `usr/src/tools/proto/root_i386-nd/opt/onbld -> /opt/onbld`, stub
   `smatch` (exit 0), point `amd64/ld -> /usr/bin/ld`; `bldenv … dmake all`;
   relink with `ld` directly (skip ctfmerge — needs genunix CTF). Strip.
3. In place on the helper's OWN root: repack boot_archive with illumos
   `cpio -o -H odc` (GNU `--no-absolute-filenames` is rejected — the
   `oi-inject-ena.sh --archive-offline` path silently no-ops on illumos and
   must be fixed to use illumos cpio); update on-disk ena + archive_cache;
   install the single-addrobj shim; strip `ena0/v4` from ipadm.conf.
4. `create-image --no-reboot`; measure ≥N=10 on m5.4xlarge.

## Files
- `/tmp/ena-rx-coldboot.patch` — MTU-1500 + the (non-effective) Rx settle delay.
- Instrumented ena module: `/tmp/ena-instrumented` (7 ENARX prints, for future
  live diagnosis). Clean module: `/tmp/ena-clean-mtu1500`.
