# Recreating dixa (c6gd.metal) from the solnix aa64h AMI

Track aa64h, 2026-10-28 (supersedes the aa64g AMIs). The owning account is solnix-ami (788352824872). All AMIs below are private.

## The AMIs

All are copies of one verified image: raw sha256 `0709fc1003f9fbd83f39ddc2932d0ec470cca13af06e5b3e5ea1fdee407ba78c`, banked at
floki `~/solnix-bank/ami/aarch64-6cd2521c1e-aa64h-20261028/aa64h-f1.img.gz` (gz `6c1dd822...`). It is the aa64g image with two ena
fixes in the kernel (p8: a failed attach no longer panics; p10: an admin command that completed during an overlong sleep no longer
reports a timeout). Userland, nix and the toplevel are byte-identical to aa64g's.

| region | AMI | snapshot | boot-tested |
|---|---|---|---|
| us-west-2 (source) | `ami-0b6fd0122d717338d` | `snap-057192876ab9ea234` | c6gd.metal x2 (v5, v6) via a kiwi share; the same image as kiwi AMI f1 (c6gd.metal x4 v1-v4, c6g.metal x1) |
| us-east-1 | `ami-09bf62de40f951648` | `snap-06d644b60cc43cdb7` | c6gd.metal x1 (ue1, us-east-1c), via a temporary kiwi share (removed) |
| us-east-2 | `ami-0a72d5edb489ce63d` | `snap-0276007bb785ae9e8` | no (copy of the verified image) |
| eu-west-1 | `ami-0daed1d3a87f8345d` | `snap-0968d061fd9db10d2` | no |
| eu-central-1 | `ami-039038c46eb50c6b6` | `snap-048797f8e25b0ee49` | no |

These are arm64, UEFI, ENA, with root device `/dev/sda1` (10 GiB gp3). The images carry the `Project=solnix` tag.

## Give the work account access (pick one)

- **Share** (solnix-ami can do this): run
  `AWS_PROFILE=solnix-ami aws ec2 modify-image-attribute --region us-east-1 --image-id ami-09bf62de40f951648 --launch-permission "Add=[{UserId=<WORK_ACCT>}]"`.
  A shared AMI's snapshot does not have to be shared for a launch.
- **Public**: this is the account owner's step ("block public access for AMIs" is on). Not attempted.

## Launch dixa (us-east-1, in the work account)

```
aws ec2 run-instances --region us-east-1 \
  --image-id ami-09bf62de40f951648 --instance-type c6gd.metal \
  --key-name <YOUR_KEY> \
  --network-interfaces "DeviceIndex=0,SubnetId=<SUBNET_IN_us-east-1c>,Groups=<SG_22_FROM_YOUR_/24>,AssociatePublicIpAddress=true" \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=10,VolumeType=gp3,DeleteOnTermination=true}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=dixa}]"
```

- **Capacity:** from 18:00Z to 18:22Z on 2026-10-27, kiwi got `InsufficientInstanceCapacity` for c6gd.metal in every us-east-1
  AZ (1a 1b 1c 1d 1f) and with no AZ given. At 18:22Z a launch got through in us-east-1b. If the work account sees the same
  error, retry, or try another AZ (c6gd.metal is offered in 1a 1b 1c 1d 1f). dixa does not have to sit in 1c next to werk for
  the image's sake. A root volume bigger than 10 GiB works; the pool does not auto-grow, though. (2026-10-28 03:50Z: us-east-1c had capacity.)
- **The key** comes from IMDS (the site/aa64-ec2-key service writes `/root/.ssh/authorized_keys`), so any EC2 keypair works.
  Then `ssh root@<public-ip>`.
- **Timing:** the first cycle is the boot-archive self-reboot. ssh answers about 15-20 minutes after launch, on the second cycle.
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

## Fixed in this image: the c6gd.metal ena admin timeout (aa64g: 2 of 6 launches)

- **Mechanism (measured, aa64h observer boot o4):** ena polls its admin queue; it never waits for an interrupt (the ITS plays no
  part). The poll loop slept `delay(1 ms)`, then judged the 500 ms deadline without reading the completion queue again. One sleep
  returned after 685.6 ms while Create CQ 17's response was already in the queue (CQ head 113->114 = SQ tail 114, device ready).
  So a completed command was reported as `timed out waiting for admin response`, the attach failed, and the DEBUG kernel panicked
  at `list.c:88` on the cleanup path. Console writes were ruled out as the cause of the long sleep (max hold 1 ms, 0 UART drops).
  What held the thread for 685 ms is not identified.
- **Fixes:** p10 reads the queue once more when the deadline passes, and succeeds if the command completed. p8 makes a failed
  attach clean up without the panic.
- **Measured with this image:** 6/6 fresh c6gd.metal launches (4 kiwi + 2 solnix-ami, us-west-2) plus 1 in us-east-1 reached
  login on the first full-ena cycle with every check passing, 0 admin timeouts, 0 panics. Expect ssh about 15-20 minutes after
  launch (UEFI on c6gd.metal takes about 10 minutes per boot).
- **If ssh has not answered after 40 minutes,** read the console with `aws ec2 get-console-output --latest`.

## Not in this image

- No `solnix-rebuild` and no module-system toplevel for aarch64. nix runs single-user (no nix-daemon).
- No dump device configured.
- The pool is a 10 GiB root. Put data on the instance-store disks: `zpool create data c2t1d0 c3t1d0`. Instance store is
  wiped on stop/terminate.
