# kiwi (505435643998) expired 2026-10-23 19:33 UTC: what was lost, what survives

The burner account that held this week's EC2 work closed at 19:33 UTC. Every AMI, snapshot and instance in it is gone.

## What survives, off-account (floki, read back)

| asset | floki path | sha256 |
|---|---|---|
| x86_64 26.11 DP image at dde2cbe (the AMI source) | `~/solnix-bank/ami/x86_64-dp-26.11-dde2cbe-20261023/solnix-base-raw.img.gz` | gz `e2fc2c31...`, raw `1154686d...` |
| x86 build host (OI, nix 2.24.15 + gate proto) | `~/solnix-bank/ami/x86_64-buildhost-20261017/` | per its SHA256SUMS |
| arm64 cross build host (root BE + bpools) | `~/solnix-bank/toolchain/arm64-buildhost-20261021/` | per its MANIFEST |
| aarch64 metal images (ecamfix, serialattach, bridgewin, nvmeintr) | `~/solnix-bank/ami/aarch64-6cd2521c1e-*/` | per each SHA256SUMS |
| installer images (a96bc76, a60b75a, e0c5f68, x1e-r2b, ...) | `~/solnix-bank/installer/x86_64-26.11-*/` | per each SHA256SUMS |

## What was lost

- The 5 regional dde2cbe AMIs (owner steps v4 named them; they were never made public), the d29d783 AMIs, and
  ami-0f04759550ba53ae0. Re-register from the banked raw image in the next account
  (docs/base-ami-rebuild-runbook.md: dd to a 20 GiB gp3 volume, snapshot, register uefi/ENA, /dev/xvda).
- The build-host AMIs ami-02365f53edd7fd297 (x86) and ami-0de86d0e2f52c0fed (arm64): rebuild from the banks above.
- In-flight work on two build hosts (terminated at 19:21): the X1E GPU image track (only a warm store; no i915-driver
  built; source edits are on floki in /scratch/solnix/x1egpu/tree) and the aarch64 post-mount observer track (the base
  only; its next step is in /scratch/solnix/aa64d/progress.txt).

## Next account, in order

1. Request the vCPU quota (L-1216C47A) in us-east-2 and the publish regions.
2. Restore the x86 build host from the bank; verify network + a build.
3. Re-register the dde2cbe AMI from the banked raw image; verify one launch per family; copy to the regions.
4. Resume x1egpu and aa64d from their progress files.
