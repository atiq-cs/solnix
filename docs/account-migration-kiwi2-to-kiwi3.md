# Account migration: kiwi (505435643998) -> kiwi (437803535746), 2026-10-23

The burner `505435643998` closed 2026-10-23 19:33 UTC (docs/account-expiry-kiwi2-20261023.md lists what survived).
A new account under the same profile name replaces it.

**This account expires 2026-10-30 19:14:53 UTC.** Bank anything that matters the day it is verified.

## Facts (verified 2026-10-23 20:25 UTC)

- Profile `kiwi`, account `437803535746`, IAM user `kiwi`, us-east-2.
- vCPU quota L-1216C47A is already 1152 in us-east-2, us-east-1, us-west-2, eu-west-1 and eu-central-1.
- SHARED: other tenants were running ~1032 vCPU in us-east-2, 80 in us-east-1 and 16 in us-west-2 at migration
  time. Touch only Project=solnix resources. Re-check free vCPU before a large or metal launch.
- Default VPC `vpc-03d813ac7ce964191`; subnet `subnet-01e4020d9df567be7` (us-east-2a).
- Ours:
  - SG `sg-04f36c6fddef7b370` (`solnix-ssh-20261023`): 22 from 73.4.58.0/24 only, added via sg-guard;
    the us-east-2 audit is clean.
  - keypair `solnix-baked` (`key-050600a0e13549949`), whose private key is
    `~/.ssh/solnix-lava.pem.AMI-BAKED-still-works`.

## Restore order

1. x86 build host from R2 `ami/x86_64-buildhost-20261017` (raw c1bd97b2) via scripts/ami-bank.sh restore.
2. x86 26.11 DP AMI dde2cbe from the floki bank (raw 1154686d), then copy it to the 4 other regions and verify one
   launch per region.
3. arm64 cross build host: x86 build host + 120 GiB data volume + the zfs streams in
   ~/solnix-bank/toolchain/arm64-buildhost-20261021.
4. Resume x1egpu and aa64d from their progress files.
