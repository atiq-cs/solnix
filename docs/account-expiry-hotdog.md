# Account expiry: hotdog (2026-10-10 14:43:47 UTC)

The `hotdog` burner account (`170848442262`, profile `hotdog`, us-east-2) expires
**Sat 2026-10-10 14:43:47 UTC**. Prepared 2026-10-09 21:00 UTC; inventory measured,
not assumed.

## What solnix has in hotdog (measured)

| resource | id | durable copy | action |
|---|---|---|---|
| running instances | none ours | -- | nothing to stop. The 11 running instances are other tenants' (libdb-*, libumem-*, libxtc-*, undo-*, noxu-*, dbsql-*); not ours, not touched |
| aarch64 boot AMI | `ami-05ba81187a661c6ab` (`solnix-aarch64-ssdt-fixed-202610032129`) | `https://s3.solnix.io/solnix-cache/ami/aarch64-proto-20260912/illumos-disk.img.gz` (286,011,323 B, HTTP 200 on 2026-10-09) | none: re-register from R2 in the next account (docs/aarch64-metal-r2-restore-reproduced.md) |
| its snapshot | `snap-0572add652e1f0ab8` | same | none |
| keypair | `solnix-aa-20261003` | the private key is local; AWS keypair records are recreated per account | none |
| security group | `sg-068e29d600d8e9f59` (tcp/22 <- 73.4.58.0/24) | recreated per account (never 0.0.0.0/0) | none |
| x86_64 build AMI | none in hotdog now (the 2026-09-18 restore is gone) | `https://s3.solnix.io/solnix-cache/ami/x86_64-20260911/solnix-base-raw.img.gz` (1,268,766,279 B, 200) + MANIFEST.txt (200) | none |
| volumes, S3 buckets | none ours | -- | none |

Nothing solnix depends on lives only in hotdog. The current work (the X1 "dixi",
bhost on the dev box, KVM) uses no EC2 at all. The cache (cache.solnix.io,
s3.solnix.io) is independent of every EC2 account.

## What breaks at expiry, and the fix

- `scripts/sg-guard.sh` defaults `AWS_PROFILE` to `hotdog`. After expiry it can
  no longer read any account. The script must never pass on an unreadable account:
  check `sts get-caller-identity` first and fail. It now requires an explicit
  `AWS_PROFILE` (no default), so a stale default can't make it look clean.
- Every other script reads `$AWS_PROFILE` or takes `--profile`.
- No other profile in ~/.aws/config authenticates today (default, numa, ouch, cracker,
  beef, chiuso, mala: no credentials; cache: InvalidClientTokenId). **There is no
  replacement EC2 account yet.** EC2 work (aarch64 in the cloud, SPARC/T-series
  rentals, metal benchmarks) waits for the maintainer to provide one.

## When the next account arrives

1. `aws --profile <new> sts get-caller-identity`; check the region; `SG_GUARD_SELFTEST=1
   AWS_PROFILE=<new> scripts/sg-guard.sh` must flip DIRTY (proves the guard can read it).
2. Create the operator SG (tcp/22 from the operator's /24 only) and a keypair, or reuse
   the baked public key (`~/.ssh/solnix-lava.pem.AMI-BAKED-still-works`).
3. Restore AMIs from R2 only when a task needs them: aarch64 per
   docs/aarch64-metal-r2-restore-reproduced.md, x86_64 per
   docs/account-migration-lava-to-hotdog.md. Read back sha256 from the written bytes.
4. Record the new account here and in the AGENTS.md AWS rules (quota, foreign tenants).
