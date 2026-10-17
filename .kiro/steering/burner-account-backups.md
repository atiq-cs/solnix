# Burner accounts: back up off-account, the day it works

The EC2 build accounts (kiwi and its predecessors: hotdog, lava, bene, mala,
chiuso, beef, ouch, numa) are **burners that live about 7 days**. Closing the
account deletes everything in it: AMIs, snapshots, volumes, keypairs, security
groups, and any share it granted to another account (a share dies with its
owner). This has cost real work at least five times; the last loss (kiwi
830118047484, 2026-10-17) took both build-host AMIs and all the 26.11 DP AMIs,
none of which had been backed up.

## The rule

**Anything that took more than an hour to produce, or that someone else depends
on, is backed up OFF the account the same day it is verified.** Not "before the
account closes": the close date is not announced reliably and can come early.

Two backup locations, both outside every AWS account:

| Location | What goes there | How |
|---|---|---|
| **floki** `/home/gburd/solnix-bank/<kind>/<name>/` | Everything below, always. 2+ TB free. | copy, then `sha256sum` both ends and compare |
| **R2 bank** `s3://solnix-cache/ami/<name>/` (`https://s3.solnix.io`) | Disk images of AMIs (the restore path reads from here) | `scripts/ami-bank.sh bank <ami>` then `ami-bank.sh verify <prefix>` |

The R2 bank is the infra team's bucket that we are allowed to write under
`ami/` with the sops credential (`secrets/s3-cache.yaml`); it is not account
scoped. Never under `images/` (that prefix is write-denied, measured).

## What counts as important

* Every **boot-verified AMI**: build hosts (x86 COMPLETE, arm64), the published
  DP/cloud AMIs, any metal-boot-proven image. Back up the raw disk image (`dd` of
  the root volume, gzip), not just the AMI id: an AMI id is worthless once the
  account closes.
* Every **installer/USB image** handed to the maintainer (already on floki under
  `streamX86IMG-out`, `streamX1EDIAG*-out`; keep it that way).
* **Toolchains and sysroots** that take hours to rebuild (aarch64 cross gate env,
  riscv64 seed, the from-source gcc closure): snapshot AND copy a tarball off.
* **Build/test evidence** a decision rests on (serial logs, screendumps,
  hand-back reports): copy to floki before terminating the host.

Source never needs this: it is in git. A recipe is not a backup when the thing
it rebuilds takes hours.

## Verify by read-back

An upload's exit status is not proof (a 20-byte "image" in R2 exited 0). After
every backup, read the copy back and compare its sha256 with the source. Record
the sha256 and the restore command next to the artifact (a `MANIFEST.txt`).

## Restore first, rebuild second

When a new burner arrives, restore from the bank before rebuilding anything:
`docs/account-migration-kiwi-to-kiwi2.md` lists what to recreate, and
`scripts/ami-bank.sh restore <prefix>` registers a banked image in the current
account. Then request vCPU quota in every region we publish to (the default 32
does not fit a metal host); the request goes through `aws service-quotas
request-service-quota-increase`, quota code `L-1216C47A`.
