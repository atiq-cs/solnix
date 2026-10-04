# aarch64: R2-restore -> metal reboot reproduced the CONFIRMED boot and ran PAST it (hotdog)

A fresh substrate (EC2 account `hotdog`, every prior durable artifact from the
`bene` account gone) was taken from zero to a booting aarch64 illumos on real
`c6g.metal` by restoring the R2-banked disk image. The boot reproduced
`docs/aarch64-gicv3-crs-metal-CONFIRMED.md` exactly and then advanced **past**
the point that doc was terminated at, refuting the "next blocker" it named.

## Headline results

1. **Durability proven end-to-end.** The R2 bank
   (`s3://solnix-cache/ami/aarch64-proto-20260912/illumos-disk.img.gz`, 286,011,323 B)
   survived the `bene` account loss and is reachable unauthenticated over HTTPS. A
   from-scratch `hotdog` account was taken to a booting metal instance using only
   that object. The campaign no longer depends on any live AWS account.

2. **The documented "next blocker" (`scsa,probe`) is a MISDIAGNOSIS.** The metal
   boot ran *past* `WARNING: failed to resolve 'scsa,probe' driver alias` to
   `scsi_vhci0 is /scsi_vhci` and into GIC distributor init. Those warnings are
   cosmetic. Confirmed two independent ways (below).

3. **GICD init measured on real silicon** (new data): `nredist=0x40` (64),
   `nregions=0x4`, `typer=0x17b041e maxsources=0x3df`.

## Substrate used

- **No self AMI/snapshot/volume existed in `hotdog`** — all `bene` artifacts
  (`snap-0e4d84a54c071e8fa`, `vol-0b229ada0d822ab5a`, `ami-04a384a52cfe7f52a`, the
  stopped build node) are gone with that account.
- **Did NOT rebuild** the toolchain or kernel. Restored the R2-banked disk image
  instead. Path:
  1. `t4g.medium` Ubuntu-24.04-arm64 helper (`i-083b282acace11e95`) with a 10 G
     gp3 data volume; user-data streamed the banked image straight onto the raw
     volume: `curl -fsSL <img.gz> | gunzip | dd of=/dev/nvme1n1 bs=1M`. `DD-RC=0`.
  2. Verified the GPT on the volume (`sgdisk -p`): p1 `loader` EF00 256 MiB, p2
     `zfs` BF01 7.7 GiB, p9 BF07 — the correct illumos boot layout.
  3. `create-snapshot` of the data volume (`snap-0572add652e1f0ab8`),
     `register-image --architecture arm64 --boot-mode uefi` ->
     `ami-05ba81187a661c6ab`.
  4. Terminated the helper, launched one `c6g.metal` (`i-07f6c01c6e212b72d`) from
     that AMI, read the console only via `aws ec2 get-console-output --latest`.

The transfer never used `zpool import`, `format`, or any chained disk probe. The
disk was identified by size/`sgdisk`, not c-node ordering. No instance was reached
over the illumos serial console.

## What was measured (10 console reads, ~2 h, monotonic, 1 EDK2 banner throughout)

Byte growth 12934 -> 14192 across 10 reads, **a single EDK2 banner the whole time**
(the reset-loop detector: a reset would reprint the banner). This is forward
progress, not the historical silent reset loop.

```
[A6GIC] ngicc=40 distinct_gicr_base=40 regions=4 stride=0x20000     # GICv3 multi-region
[A6CRS] crs_nwin=0x2 crs_have=0x1 necam=0x1 ecam0=0xc000000000 qemu=0x0   # SSDT _CRS fix
[A6KCON:BOP] / [A6KCON:BCONS]                                       # FR-poll fix
module .../unix / genunix / platmod
illumos Version arm64-gate-0-g6cd2521c1e 64-bit / DEBUG enabled
mem = 134217728K (0x2000000000)                                     # 128 GiB
root nexus = Amazon EC2 / pseudo0 is /pseudo
init_spec_child: parent=pseudo, bad spec (zconsnex)
WARNING: failed to resolve 'scsa,probe' driver alias -> nulldriver  # <-- CONFIRMED stopped HERE
WARNING: failed to resolve 'scsa,nodev' driver alias -> nulldriver
scsi_vhci0 at root
scsi_vhci0 is /scsi_vhci                                            # <-- NEW: past scsa,probe
[A6GICD:init-enter]                                                 # <-- NEW: GICD init
[A6GICD:walk1 nredist=0x40 nregions=0x4]
[A6GICD:walk2-done]
[A6GICD:redist-assigned]
[A6GICD:typer=0x17b041e maxsources=0x3df nredist=0x40]
[A6GICD:gicd-disabled]
```

Full capture: `artifacts/aarch64-a6/a6gicd-metal-console-hotdog-20261004.txt`.

## Why `scsa,probe` is cosmetic (two independent proofs)

1. **The QEMU A5 boot that reached a full interactive root shell prints the
   identical warnings** (`artifacts/aarch64-a5/qemu-console-a5.log:228,234-238`):
   `add_spec: No major number for fp`, `init_spec_child ... bad spec (zconsnex)`,
   `scsa,probe` and `scsa,nodev` -> `nulldriver`, then `scsi_vhci0 at root` and on
   to the shell. If these blocked boot, A5 could not have reached a login.
2. **This metal boot ran past them live** — the console shows `scsi_vhci0 is
   /scsi_vhci` and `[A6GICD:init-enter]` *after* the `scsa` warnings.

The warnings come from the proto-only image's synthesized `name_to_major` /
`driver_aliases` (`scripts/aa-fix-ntm.sh`); `scsa,probe`/`scsa,nodev` are
self-identifying SCSI pseudo-nodes that fall back to `nulldriver` harmlessly on
both QEMU and metal. The CONFIRMED doc named them the "next blocker" only because
the slow (~13 s/char) console had not yet emitted the next line when that instance
was terminated — `scsi_vhci0 at root` was one line away.

## The real next leg (named, not a blocker here)

GICD init runs ~19 `[A6GICD:*]` markers before `gicthree0 at root` -> `arm_gtmr0`
-> `NOTICE: Performing full ZFS device scan!`. `docs/aarch64-a6-gicd-bounded-await.md`
marks that leg **resolved** (the bounded `reg_await_clear4()` spin reaches the ZFS
scan with zero `await-timeout` lines). Two practical notes for the next run:

- **The markers cost ~2.5 h at 13 s/char.** This boot crawls through GICD purely
  because the `[A6GICD:*]` diagnostics are compiled in. A production boot test
  should build with them *out* (the resolved doc proved the bound, not the markers,
  is load-bearing) so the ZFS-scan -> root-mount leg is reachable in a sane window.
- The genuinely open question past GICD is the **PCIe/ENA/NVMe device probe under
  the SSDT-fed FDT** (`docs/aarch64-zfs-scan-is-pcie-enumeration.md`): does the ZFS
  scan reach `root on armpool/ROOT/braich` on metal, as it does on QEMU? That is the
  next decisive measurement — cheapest on a marker-free image.

## Reproduce from zero (no live account, no rebuild)

```sh
# 1. helper: stream the surviving R2 image onto a raw 10 G EBS volume
curl -fsSL https://s3.solnix.io/solnix-cache/ami/aarch64-proto-20260912/illumos-disk.img.gz \
  | gunzip | sudo dd of=/dev/nvmeXn1 bs=1M status=progress   # identify by size, not c-node
sudo sgdisk -p /dev/nvmeXn1   # expect p1 loader EF00, p2 zfs BF01, p9 BF07

# 2. snapshot that volume -> register arm64/uefi AMI
aws ec2 create-snapshot --volume-id <vol> ...
aws ec2 register-image --architecture arm64 --boot-mode uefi \
  --root-device-name /dev/sda1 \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"SnapshotId":"<snap>","VolumeType":"gp3","DeleteOnTermination":true}}]'

# 3. one c6g.metal from the AMI; read ONLY via get-console-output --latest
```

SG scoped to the operator /24 via `scripts/sg-guard.sh authorize` (guard refuses
world-open CIDRs; selftest + synthetic-DIRTY negative control both run clean).

## Correction to the record

`docs/aarch64-a6-mem-arena-diagnosis.md` ("NEXT blocker: GICv3 redistributor count
1 -> ... 16") and the stale `.kiro/specs/solnix-aarch64/tasks.md` A6 line are
**behind reality**. GICv3 (64 redistributors, 4 regions), SSDT `_CRS`, and the
arena are all CONFIRMED on metal; the boot is at device probe / GICD init, not GIC
topology. The authoritative frontier docs are
`docs/aarch64-gicv3-crs-metal-CONFIRMED.md` and this file.

## Resources (all terminated / auto-deleted)

| id | type | state |
|---|---|---|
| `i-083b282acace11e95` | `t4g.medium` helper | terminated (data vol auto-deleted) |
| `i-07f6c01c6e212b72d` | `c6g.metal` | terminated (root vol DeleteOnTermination=true) |

Kept (orchestrator decides whether to retain or delete): AMI `ami-05ba81187a661c6ab`
(arm64/uefi) + snapshot `snap-0572add652e1f0ab8` — the restored boot image, in-account
only. The *durable* copy is the R2 object, which this run proved still restores.

Keypair `solnix-aa-20261003`, SG `sg-068e29d600d8e9f59` (tcp/22 <- 73.4.58.0/24):
left in place for a follow-up run; delete if not resuming.
