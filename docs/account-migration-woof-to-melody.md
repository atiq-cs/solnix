# Account migration: woof -> melody (2026-11-10)

woof (`176550300114`) expires 2026-11-10 18:43:17Z. The new burner is **melody** (`AWS_PROFILE=melody`, account
`683788466730`, IAM user `melody`), which expires **2026-11-17 12:05:17Z**. Everything below is in us-west-2 and tagged
`Project=solnix`. Another tenant runs 17 instances in us-east-2: never touch anything without that tag.

## What melody has

| resource | id | notes |
|---|---|---|
| VPC / subnet | `vpc-0ea918739680d2848` / `subnet-070ed4baedd462b98` (us-west-2a) | the default VPC |
| security group | `sg-0227c24d0453b8c84` (solnix-builder-sg) | tcp/22 from every `scripts/operator-cidrs.txt` network plus werk 44.197.214.234/32, added with `scripts/sg-guard.sh authorize`; audit CLEAN |
| key pair | `melody-solnix-20261110` | ed25519, private half on floki `/scratch/solnix-bank/melody-20261110/` (0600) |
| solnix x86 AMI | `ami-0956c16a8642d6424` (snap `snap-04999ef95b64a7817`) | woof's `ami-0ff69777412bd235e`: raw-p3, toplevel zihdyi9g |
| OI build host AMI | `ami-057a2254dbec4e4a6` (snap `snap-0f8cfd920213e0a90`) | woof's `ami-031699fcf31595dcd`: OI hipster 2026.10 cloud image + ena, for kernel-nd (/scratch/solnix/lixi11/OI-CLOUDIMAGE-ON-EC2.md) |
| x86 queue builder | `i-0b4b7877e91b77f5f`, m5.2xlarge (8 vCPU, 32 GB), 120 GB gp3 | nodename `solnix-melody`, host key SHA256:ce/CqMei..., keyid `ssh-eb12c5f982a1` |

Quotas: on-demand standard 1152 vCPU, spot 32 vCPU (as woof).

## How the images moved

An org service control policy denies `ec2:ModifyImageAttribute` in the burners, so an AMI can't be shared to another
account. A snapshot can be (`modify-snapshot-attribute --create-volume-permission`). So: share the snapshot from the
old account, `copy-snapshot` in the new one (the copy is the new account's own and survives the old one), then
`register-image` with the old image's settings (x86_64, uefi, ena, hvm, root /dev/xvda). Do it before the old
account closes.

## A builder from the solnix AMI

The AMI boots with nodename `solnix`, no swap, and none of the builder's tools. woof's setup steps, now one script
(the melody run: floki /tmp/melody-setup.sh):

1. A unique nodename (`/etc/nodename` and `uname -S`), set again by run-builder.sh at every start: base.nix applies
   hostName "solnix" at boot, and publish-gate refuses a host named after the distro.
2. A 48 GB swap zvol, in `/etc/vfstab`. A cmake recipe that ignores `--cores` (cmakeB's `-j16`) exhausted woof's 16 GB
   without it.
3. git `insteadOf` from git.solnix.io to Codeberg for solnix and solnix-pkgs.
4. jq, python3 and GNU grep from the cache, rooted.
5. main's gates and builder script; builder.env as woof's, with this host's agent id and publish id.
6. The SMF manifest, installed disabled; enrol the host key (`solnix-builder-identity enroll ... --send`), ask infra
   for tier 2 and the maintainer-fleet group, then enable.
