# ena cold-boot DHCP wedge — root-cause verification

## Question posed
The committed ena MTU fix (commit 72311a0a6e, `ena_default_mtu_1500.patch`:
`ena->ena_mtu = min(ena->ena_max_mtu, ETHERMTU)`) claims 30/30 (100%) cold
launches, yet the orchestrator keeps hitting `Hostname: unknown` wedges
launching the gtk4-builder AMI. Did the fix not propagate, or is it incomplete?

## Verdict (proven, not assumed)
1. **The fix DID propagate.** Every live AMI ships the identical, FIXED ena
   driver in BOTH the on-disk root AND the boot_archive (the ramdisk illumos
   actually boots). Disassembly-proven `0x5dc` (1500). The "boot_archive is
   unfixed" hypothesis is **FALSE**.
2. **The fix is INCOMPLETE, and the README's numbers are misleading.** The
   residual ena cold-boot DHCP-OFFER-reception wedge is NOT eliminated. It is
   **not** instance-type-dependent in the way suspected (m5.large fails too on
   gtk4). It is **image-weight / boot-environment sensitive**: the light base
   AMI mostly boots (70–80%), the heavy gtk4 builder AMI **reliably fails
   (0/N)**. The README's 30/30 was measured only on small 2-vCPU types
   (m5.large / t3.large / c5.large) and does **not** hold on the orchestrator's
   m5.4xlarge (measured **7/10** even on the *working* base AMI).

## STEP 1 — FIXED/UNFIXED matrix (disassembly audit)

Method: OpenZFS-on-Linux offline import of each AMI's root + boot_archive.
illumos ena modules are Solaris-OSABI ELF; GNU `objdump --disassemble=<sym>`
returns nothing (silent). Correct method: `readelf -sW` for the symbol vaddr
(`ena_attach_device_init` @0x1e20, size 1231) + `.text` file-offset (0x800),
carve the bytes, `objdump -D -b binary -m i386:x86-64 --adjust-vma=0x1e20`.

The FIXED instruction sequence (min(max_mtu, 1500)):
```
2102: cmpl   $0x5dc,0x7ac(%r12)     ; ena_max_mtu vs 1500
210e: mov    $0x5dc,%eax             ; eax = 1500
2116: cmovbe 0x7ac(%r12),%eax        ; if max_mtu <= 1500, take max_mtu
211f: mov    %eax,0x280(%r12)        ; ena->ena_mtu = min(max_mtu,1500)
```

| AMI | root ena | boot_archive ena | ena md5 |
|-----|----------|------------------|---------|
| gtk4 builder `ami-0719159b19c8f692e` (FAILING) | **FIXED** 0x5dc | **FIXED** 0x5dc (byte-identical to root) | `0ff4e567…` |
| ena-fixed base `ami-0fd4acf5e378c3e25` | **FIXED** 0x5dc | **FIXED** 0x5dc (byte-identical) | `0ff4e567…` |
| claimed-100% `ami-0cc154959d7d945ce` | — | — | **AMI DEREGISTERED — cannot verify** |

The gtk4 and base ena are the **same binary** (identical md5). Both carry the
fix in the ramdisk. `ena_update_buf_sizes()` in illumos-gate confirms
`ena_rx_buf_sz` is derived from `ena_mtu` (not `ena_max_mtu`), so the fix does
shrink the Rx buffers — structurally complete for the "jumbo-Rx-buffer drops
broadcast" theory.

Note: the claimed-100% AMI no longer exists, so that specific 30/30 claim is
un-reverifiable.

## STEP 2 — measured cold-launch success (SSH-as-root reachable = network up)

Signal calibration: `Hostname: unknown` prints EARLY in device probe on
*every* boot (good and bad) — it is NOT the failure signal (the README implies
it is; that is misleading). The real signal is a DHCP lease: a successful boot
shows `Hostname: ip-172-31-x-y` (hostname from the lease) and is SSH-reachable
as root (the AMI trusts `chiuso-key`); a wedged boot stays `Hostname: unknown`
and port 22 never opens. Console does not echo the DHCP lease (post-login SMF
output goes to the SMF log), so SSH reachability is the only reliable metric.

| AMI | instance type | result |
|-----|---------------|--------|
| base `ami-0fd4acf5e378c3e25` | m5.large | ~4/5 (≈80%) |
| base `ami-0fd4acf5e378c3e25` | **m5.4xlarge** | **7/10 (70%)** |
| gtk4 `ami-0719159b19c8f692e` | m5.large | **0/15** |
| gtk4 `ami-0719159b19c8f692e` | **m5.4xlarge** | **0/10** |

- Faster CPU (16-vCPU m5.4xlarge) did NOT help gtk4 → not CPU-bound.
- A warm reboot of a wedged gtk4 did NOT recover it → dhcpagent is stuck in
  SELECTING; the ena Rx path never delivers the broadcast OFFER.
- Base and gtk4 launched concurrently in the same subnet, so the delta is the
  AMI, not the environment.

## Root cause of the residual wedge

Everything static is **identical** between the reliably-booting base and the
reliably-wedged gtk4 (ruled out one by one):
- ena driver binary — identical md5, both FIXED (0x5dc).
- `/usr/lib/useragent` + `/usr/lib/metadata` — identical md5.
- `/etc/ipf/ipf.conf` — identical (has the `port = 22 keep state` pass rule).
- `/etc/ipadm/ipadm.conf` — identical (dual DHCP addrobj `ena0/dhcp` +
  `ena0/v4`, `_dhcp=30,no`).
- baked DHCP lease `/etc/dhcp/ena0.dhc` — present in BOTH (base works anyway).
- SMF repository network-service enabled-state — verified via the working
  base's `svccfg` against gtk4's `repository.db`: all of network/physical,
  ip-interface-management, useragent, metadata, network/service,
  milestone/network are `enabled=true` in gtk4 too.
- boot_archive contents — byte-identical file set except gtk4 carries one extra
  `kernel/drv/amd64/ena.stock.bak` (a backup left by `oi-inject-ena.sh`; benign).

With identical content, the difference is a **boot-environment / timing
interaction with the Nitro ena backend**: on the heavy gtk4 image (60 GB root,
89 MB boot_archive, 5 ZFS filesystems) the ena attach → first DHCP DISCOVER
happens at a point where the Nitro backend does not deliver the broadcast DHCP
OFFER to the driver's Rx queue — reliably. The MTU/Rx-buffer fix reduced this
from the old ~29% to ~70–80% on the light base, but did **not** eliminate the
underlying ena Rx cold-boot reception problem, and on the heavy gtk4 image it
manifests as ~100% failure.

This matches the standing analysis in `docs/design-mtu-policy.md`
(2026-08-08 finding): today's illumos ena has real Rx limitations
(`rx_sgl_max=1`, jumbo Rx latches fatal, ring-realloc under load latches fatal
0x21). The 1500 default is the right value but does not fix the Rx *reception*
reliability on cold boot.

## The stale shim (contributing, present on both)

`/usr/lib/metadata` is the OLD OpenIndiana **Xen-HVM** shim (its own comment
says "will NOT get a NIC on Nitro (c5/m5)"). At runtime on ena it:
- creates the dual DHCP addrobj (`ipadm create-addr -T dhcp ena0/dhcp` then
  falls to `ena0/v4`) — the dual-addrobj the earlier findings flagged as a
  collision risk;
- runs `dladm set-linkprop -p mtu=1400 ena0`, which fails `ENOTSUP` (harmless —
  MTU stays 1500, so the ena fix holds);
- waits only `-w 30` for the lease.

It is identical on both AMIs, so it is not the base-vs-gtk4 differentiator, but
it is stale/wrong for Nitro and should be replaced by the current
metadata-shim (single addrobj, no mtu=1400) — see FINDINGS doc.

## Canonical AMI — status: NOT produced (honest)

Goal was one AMI cold-launching ≥9/10 on m5.4xlarge with disassembly-proven
FIXED boot_archive ena. Not delivered because:
- No existing AMI meets ≥9/10 on m5.4xlarge (best is base at 7/10).
- Re-injecting the (already-FIXED) ena into a new boot_archive would change
  nothing — the boot_archive ena is already FIXED and identical.
- The real fix is a **deeper ena Rx change** (source-level), requiring a gate
  rebuild + offline boot_archive inject + disassembly verify. The offline ZFS
  helper was terminated mid-investigation (external cost-hygiene), and this
  exceeds the tool budget for this pass.
- **Do NOT RW-mount an illumos ZFS root from OpenZFS-on-Linux for boot-critical
  edits** — it corrupts the pool (`ZFS-8000-CS`, verified the hard way). Edit
  the boot_archive as a raw gzip'd cpio only (the `oi-inject-ena.sh`
  `--archive-offline` method), never via `zfs` write.

## What the committed patch/README must say (correction required)

`pkgs/illumos/patches/ena-default-mtu-1500.README.md` currently claims **30/30
(100%)** with a table of m5.large / t3.large / c5.large — all 2-vCPU types.
That number is real but **only for small instances**, and even there it is not
100% under repeat measurement (base m5.large ≈ 4/5). It is **70% on
m5.4xlarge** and **0% on the gtk4 builder AMI**. The README must state:
- the fix is **boot-safe-MTU only**, not a full cure for the cold-boot DHCP-OFFER
  reception wedge;
- measured rates: base ≈ 80% (m5.large) / 70% (m5.4xlarge); heavy images
  (gtk4 builder) ≈ 0% — reliably wedged;
- the residual cause is the ena Rx reception path (per
  `docs/design-mtu-policy.md`), not the MTU default;
- the "30/30" headline is not reproducible on the orchestrator's m5.4xlarge and
  must not be cited as "solved."

## Recommended next actions
1. Correct the README as above (numbers + scope). No code change needed for the
   correction itself.
2. Replace the stale Xen-era `/usr/lib/metadata` with the current single-addrobj
   Nitro shim in the builder image (removes the dual-addrobj + mtu=1400 cruft).
3. The durable fix is source-level in the ena Rx path (compare illumos-gate
   `ena_rx.c` reception/broadcast handling + FreeBSD `if_ena` Rx init); rebuild
   the module, inject into boot_archive (offline cpio method), re-snapshot,
   register a new AMI, and disassembly-verify before trusting it. This needs a
   fresh ZFS helper and a gate build — budget a dedicated pass.
4. Interim: the orchestrator should launch the builder with a **bounded
   relaunch** (terminate + relaunch on `Hostname: unknown` at ~3 min) rather
   than treating it as a per-boot lottery — but note that gtk4 is ~0%, so
   relaunch alone will not converge for that specific AMI until the ena Rx fix
   or a lighter builder image lands.
