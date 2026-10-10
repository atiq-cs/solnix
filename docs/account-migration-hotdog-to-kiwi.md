# Account migration: hotdog -> kiwi (2026-10-10)

`hotdog` (`170848442262`) expires today 14:43:47 UTC. `kiwi` replaces it as the EC2
build account. Set up and verified 2026-10-10 ~14:15 UTC; measured, not assumed.

## kiwi facts (verified)

* Profile `kiwi` (`~/.aws/config` region us-east-2, `~/.aws/credentials`), account
  **`830118047484`**, IAM user `kiwi`. `sts get-caller-identity` authenticates.
* us-east-2 reachable. **Fresh account:** no instances, no self AMIs, no snapshots, no
  keypairs; only the `default` SG at start.
* **sg-guard reads kiwi both ways:** `SG_GUARD_SELFTEST=1 AWS_PROFILE=kiwi
  scripts/sg-guard.sh audit us-east-2` flips DIRTY on the synthetic rule (the guard is not
  blind on this account); a plain audit is CLEAN (no real world-open rule).
* **vCPU quota: 32** standard on-demand (L-1216C47A) -- enough for a from-source build host,
  far below hotdog's 1152. Metal/high-mem quotas are 0-5: a bare-metal benchmark needs a
  quota-increase case first. Re-check `describe-instances` before every launch.

## What we created on kiwi

* SG `sg-0b7360f44dc00f99c` (`solnix-ssh-operator`): tcp/22 from `73.4.58.0/24` ONLY. Never
  a 0.0.0.0/0 rule (`SG_GUARD_SELFTEST=1` proves the guard; the real audit is CLEAN).
* Keypair `solnix-baked`: the public half of `~/.ssh/solnix-lava.pem.AMI-BAKED-still-works`.
  The banked AMIs log in as root with that private key regardless of account (auth is by the
  baked public key, not an AWS keypair record).

## In-repo

* `scripts/sg-guard.sh` already takes `AWS_PROFILE` explicitly (no default; 202208a7). Pass
  `AWS_PROFILE=kiwi`.
* Everything else reads `$AWS_PROFILE` or `--profile`.
* AGENTS.md and docs/account-expiry-hotdog.md name kiwi as the current account.

## Restoring the build AMIs from R2 (when a task needs them)

Both durable images answer HTTP 200 (verified 2026-10-10):

* x86_64: `https://s3.solnix.io/solnix-cache/ami/x86_64-20260911/solnix-base-raw.img.gz`
  (1,268,766,279 B) + MANIFEST.txt. Restore per docs/account-migration-lava-to-hotdog.md:
  a Linux helper + a >=21 GiB volume, `curl | gzip -dc > /dev/xvdX`, read-back the sha256
  (`b0f98e3c...`), snapshot, `register-image --boot-mode uefi` + ENA. NOTE the base AMI has
  no C toolchain (userland-incorporation rejects one); a build host needs `pkg update` +
  reboot + developer/gcc-14, then re-bank as the build AMI.
* aarch64: `.../ami/aarch64-proto-20260912/illumos-disk.img.gz` (286,011,323 B), restore
  per docs/aarch64-metal-r2-restore-reproduced.md. arm64/uefi.

## Standing rules unchanged

Shared account, re-check `describe-instances` before every launch, tag `solnix-*`, NEVER a
0.0.0.0/0 or ::/0 rule, terminate instances AND delete orphaned volumes (check the API, not
the report), `get-console-output --latest` is the only safe console read, never `zpool
import` over ssh. The cache (cache.solnix.io / s3.solnix.io) is on R2, independent of every
EC2 account. Work runs on EC2 or dixi, never floki (AGENTS.md).

## Foreign tenants on kiwi (do not touch)

Fresh account; none observed yet. Re-scan `describe-instances` and `describe-security-groups`
before each launch and record any that appear, as on hotdog (the osv-* world-open SG there).
