# Account migration: kiwi (old) -> kiwi (new) (2026-10-17)

The `kiwi` burner `830118047484` is gone. A new account with the same profile name
replaces it. Measured 2026-10-17 ~15:00 UTC.

## new kiwi facts (verified)

* Profile `kiwi` (unchanged name; `~/.aws/config` region us-east-2), account
  **`505435643998`**, IAM user `kiwi`. `sts get-caller-identity` authenticates.
* vCPU quota (L-1216C47A): **32** standard on-demand. Metal (m5zn.metal, 48 vCPU)
  does not fit; KVM boot tests need a quota increase or a different host.
* Foreign tenant already present: `i-0386aaf95fb242f1a` (c7i.4xlarge, Name/Project
  `pcompress-dev`, launched 2026-10-17 14:50Z, keypair `pcompress-dev-20261017b`,
  SG `sg-043cdb61d414938b0` 22 <- 73.4.58.126/32). **Do not touch.** Its 16 vCPU
  leave 16 of the 32 for us.
* sg-guard audit us-east-2: CLEAN (3 SGs visible).
* No self AMIs or snapshots in any of the 7 publish regions; no solnix keypair or SG.

## What died with the old account

* Build-host AMIs: x86 `ami-0bd0fa73200305fd1` (COMPLETE: networks + flake nix
  build) and arm64 `ami-06583907ca11a0ab1`. **Never banked to R2.**
* The x86 26.11 DP AMI `ami-03aa9c007c77ba76d` + `snap-0a2f996b8485a3669`, and the 7
  regional DP AMIs. Their shares to `399683337503` (work) and `788352824872`
  (solnix-ami) died with the owner. A copy survives only if one of those accounts
  registered its own AMI from the shared snapshot while it existed (no profile here
  can check either account).
* SG `sg-0b7360f44dc00f99c`, keypair `solnix-baked` (the private key is on floki:
  `~/.ssh/solnix-lava.pem.AMI-BAKED-still-works`).
* `ecam-20261013-buildhost` (the aarch64 stream's host) and its work.

## What survived

* All source and fixes (git, local; the Codeberg push is still quota-blocked).
* R2 bank (independent of AWS): `https://s3.solnix.io/solnix-cache/ami/x86_64-20260911/`
  (HTTP 200 verified today, 1,268,766,279 B) and `ami/aarch64-proto-20260912/`.
  That x86 image is the 2026-09-11 base, older than the COMPLETE build host.
* Images on floki: installer `/home/gburd/streamX86IMG-out/solnix-x86_64-usb.img.gz`,
  x1ediag iterations 1-3 under `/home/gburd/streamX1EDIAG*-out/`.

## To rebuild

1. Recreate the operator SG (22 from 73.4.58.0/24 only) and import the `solnix-baked`
   public key.
2. Restore the x86 build host from the R2 bank (docs/account-migration-lava-to-hotdog.md
   path), bring it to the COMPLETE state per docs/solnix-buildhost-ami.md, and **bank the
   result to R2 this time** (scripts/ami-bank.sh, then read-back verify).
3. Rebuild the DP AMI from clean HEAD as before.

## Lesson

The rule in docs/durability-account-loss.md was not followed for the COMPLETE build
host or the DP AMI: both lived only in the account. Bank every AMI that took real work
to make, the day it is boot-verified.
