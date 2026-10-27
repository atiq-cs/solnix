# Recreating dixa (c6gd.metal) from the solnix aa64g AMI

Track aa64g, 2026-10-27. The owning account is solnix-ami (788352824872). All AMIs below are private.

## The AMIs

All are copies of one verified image: raw sha256 `c97190582b017b42544310cea56f900730d0665594fdbd19f8e30c71147b2539`, banked at
floki `~/solnix-bank/ami/aarch64-6cd2521c1e-aa64g-20261027/aa64g-1.img.gz`.

| region | AMI | snapshot | boot-tested |
|---|---|---|---|
| us-west-2 (source) | `ami-04aac43c39f0f1c51` | `snap-0aeb615e60e6ed050` | c6gd.metal x2 (sa1, sa2) + c6g.metal x1 (c6), via a kiwi share |
| us-east-1 | `ami-033513d87a591a75a` | `snap-08090e05b4aa1ed95` | c6gd.metal x1 (ue1, us-east-1b, all checks pass on cycle 3) + c6g.metal x1 (ue1g, us-east-1c, cycle 2), via a temporary kiwi share (removed) |
| us-east-2 | `ami-0b6b59a4b1a37ccb0` | `snap-077a938c090bd76fc` | no (copy of the verified image) |
| eu-west-1 | `ami-089c89a4d4911304f` | `snap-010f432b3d3e2228d` | no |
| eu-central-1 | `ami-041232c4cf05b5fe9` | `snap-0ef5ebf815ec423f2` | no |

These are arm64, UEFI, ENA, with root device `/dev/sda1` (10 GiB gp3). The images carry the `Project=solnix` tag.

## Give the work account access (pick one)

- **Share** (solnix-ami can do this): run
  `AWS_PROFILE=solnix-ami aws ec2 modify-image-attribute --region us-east-1 --image-id ami-033513d87a591a75a --launch-permission "Add=[{UserId=<WORK_ACCT>}]"`.
  A shared AMI's snapshot does not have to be shared for a launch.
- **Public**: this is the account owner's step ("block public access for AMIs" is on). Not attempted.

## Launch dixa (us-east-1, in the work account)

```
aws ec2 run-instances --region us-east-1 \
  --image-id ami-033513d87a591a75a --instance-type c6gd.metal \
  --key-name <YOUR_KEY> \
  --network-interfaces "DeviceIndex=0,SubnetId=<SUBNET_IN_us-east-1c>,Groups=<SG_22_FROM_YOUR_/24>,AssociatePublicIpAddress=true" \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=10,VolumeType=gp3,DeleteOnTermination=true}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=dixa}]"
```

- **Capacity:** from 18:00Z to 18:22Z on 2026-10-27, kiwi got `InsufficientInstanceCapacity` for c6gd.metal in every us-east-1
  AZ (1a 1b 1c 1d 1f) and with no AZ given. At 18:22Z a launch got through in us-east-1b. If the work account sees the same
  error, retry, or try another AZ (c6gd.metal is offered in 1a 1b 1c 1d 1f). dixa does not have to sit in 1c next to werk for
  the image's sake. A root volume bigger than 10 GiB works; the pool does not auto-grow, though.
- **The key** comes from IMDS (the site/aa64-ec2-key service writes `/root/.ssh/authorized_keys`), so any EC2 keypair works.
  Then `ssh root@<public-ip>`.
- **Timing:** the first cycle is the boot-archive self-reboot. ssh answers about 20 minutes after launch, on the second cycle.
  Watch progress with `aws ec2 get-console-output --latest` and look for `console login:`. The console now works after boot, so SMF
  lines and the login prompt show there.

## What you get

- **Instance-store NVMe:** both 1.73 TB disks (`c2t1d0`, `c3t1d0` on `/pcie@e000000000`) attach. `format` lists them, and zpool
  create, write, scrub and destroy all work. There are two ITS instances: gicv3_its0 for the EBS/ENA root complex and gicv3_its1 for
  the instance store. Each disk has 64 MSI-X vectors, and there are 0 missed interrupts. On the old kernel, dixa's `nvme1`/`nvme2`
  timed out and went `down`.
- **Software:** nix 2.24.15, with `/run/current-system` set to a solnix-system-aarch64 derivation. `scripts/ami-registry-check.sh`
  gives `REGISTRY_FETCH_OK`, and a local `nix-build` works.
- **Tools:** curl, wget, fetch, git, tree, top, htop, nano, vi/nvi and man.
- **Shell:** bash 5.2.37 with readline 8.2 is root's login shell.
- Your user is not created: the image has root only. Add one with `useradd -m -s /run/current-system/sw/bin/bash gburd`.
  `/etc/shells` is absent, which illumos permits.

## Known issue: on c6gd.metal, ena attach failed on 2 of 6 launches; the box recovered by itself both times

- **What happens:** the boot runs ena's full 32-queue attach (the second cycle, after the boot-archive reboot), and right after
  nvme1/nvme2 attach, ena0's admin queue times out:
  `timed out waiting for admin response` / `failed to create Tx CQ 17` (or `Rx CQ 18`) / `attach sequence failed`.
- **What the kernel does:** the DEBUG kernel then panics at `list.c:88`. That is the known ena cleanup bug,
  docs/aarch64-nvme-intr-metal-result.md, "Second bug".
- **Measured rate:**
  - c6gd.metal: 2 of 6 launches (sa1 in us-west-2, ue1 in us-east-1);
  - c6g.metal: 0 of 3 here, and 0 of 7 in aa64nix.
- **Recovery:** both times the box reset about 12 minutes later, and the next cycle came up with every check passing. So expect
  ssh at about 20 minutes, or about 37 minutes in the bad case.
- **If ssh has not answered after 45 minutes,** read the console with `aws ec2 get-console-output --latest`. A `list.c` panic
  there means you wait for the reset, or `aws ec2 reboot-instances`.
- **Cause:** unknown. The admin command gets no reply. It is seen only on c6gd, after the second root complex's NVMe attach.
  This is a hypothesis and has not been tested. It is the next aarch64 bug to chase.

## Not in this image

- No `solnix-rebuild` and no module-system toplevel for aarch64. nix runs single-user (no nix-daemon).
- No dump device configured.
- The pool is a 10 GiB root. Put data on the instance-store disks: `zpool create data c2t1d0 c3t1d0`. Instance store is
  wiped on stop/terminate.
