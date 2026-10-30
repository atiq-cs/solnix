# Account migration: kiwi -> chef (2026-10-30)

kiwi (`437803535746`) closed 2026-10-30 19:14:53 UTC. Its inventory, banks and teardown are in
docs/account-expiry-kiwi-20261030.md. The new burner is **chef** (`AWS_PROFILE=chef`, account `842964983020`, IAM
user `chef`). Its expiry isn't known; plan for about 7 days.

## What chef has (set up 2026-10-30 18:00Z, all tagged Project=solnix)

| resource | id | notes |
|---|---|---|
| region | us-west-2 | same region as the solnix-ami images; default VPC `vpc-0adabad5bd331db77` |
| security group | `sg-0301764649ebed657` (solnix-ssh-floki) | tcp/22 from 73.4.58.0/24 only, added with `scripts/sg-guard.sh authorize` |
| key pair | `solnix-baked` | the public half of `~/.ssh/solnix-lava.pem.AMI-BAKED-still-works` |
| subnet | `subnet-064acdefef45256a3` (us-west-2a) | default subnet |
| OI build host | `i-01d1ea1c77d669434`, c5.4xlarge, 35.88.115.255 | from solnix-ami `ami-0e4a740ebfc5bec81` (shared to chef); 20G root + an empty 250G gp3 (c3t1d0) for a work pool; nix 2.24.15. Access: `sh /scratch/solnix/chef/bh.sh <timeout> '<cmd>'` |

Quotas: on-demand standard vCPU 1152 in us-west-2 and us-east-1, 1600 in us-east-2. Another tenant had one
c6id.4xlarge running in us-east-2 on day one.

## Images chef can launch (shared from solnix-ami)

- `ami-0e4a740ebfc5bec81`: the OI build host (`solnix-buildhost-x86-COMPLETE-20261017`).
- `ami-0e08aa06f629ffbac`: aarch64 v4. It boots on a c6g.large in about 3 min, and on metal (m4 lineage).
Share more with `AWS_PROFILE=solnix-ami aws ec2 modify-image-attribute --region <r> --image-id <ami> --launch-permission
'Add=[{UserId=842964983020}]'`. A copy in another region needs the Project=solnix tag before solnix-ami may modify it.

## What changed for scripts

Nothing in the repo defaults to kiwi. The track helpers under /scratch/solnix/*/ that named kiwi hosts are dead; use
/scratch/solnix/chef/bh.sh for the build host.
