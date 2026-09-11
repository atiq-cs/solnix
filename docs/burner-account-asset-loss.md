# Three burner accounts, three stranded AMI recipes, and the fix

## The pattern, measured

`scripts/` contains one base-AMI script per **dead** burner account:

| script | size | account |
|---|---|---|
| `beef-make-base-ami.sh` | 13,182 B | gone |
| `ouch-make-base-ami.sh` | 12,379 B | gone |
| `bene-make-base-ami.sh` | 16,598 B | expired 2026-09-11 12:03 UTC |

Three forks of one procedure. Each was written when the previous account died, each drifted from the
others, and each left its AMIs behind. The response to losing an account has been *a new script*, not a
durable artifact.

⚠️ The standing rule already says **"AWS accounts = EC2 compute ONLY, never asset storage."** It was
applied to data and not to AMIs. An AMI is an asset. Three times.

## What actually died with `bene`

| AMI | what it was |
|---|---|
| `ami-014c4aaccd37b2356` | x86_64 base, 21/21 stages — **the** build substrate |
| `ami-054b0f50ccab2af88` | aarch64 toolchain + 150 G tree |
| `ami-07bf2618a9405302e` | fast-console aarch64 |

Confirmed unrecoverable: `describe-images` from `lava` returns `[]`, and sharing an AMI requires a working
call in the **owning** account. There is no public OpenIndiana/illumos AMI to fall back on. Also gone:
`dixi` and its GREEN `run_build.pl` "All stages succeeded" proof — though `modules/config/pgfarm.nix`
makes that configuration reproducible, which is the pattern working as intended.

## The fix, in two halves

**1. One parameterized recipe.** Not `lava-make-base-ami.sh` as a fourth copy. Account-specific values
(profile, region, keypair, SG) are inputs; the procedure is shared. A per-account wrapper is acceptable
only if it is thin enough to contain nothing worth drifting.

**2. Bank the output in R2.** `s3://solnix-cache/images/` already holds a 3.9 GiB `solnix-raw.img.gz`, so
the shape is proven. `scripts/ami-bank.sh` does export → compress → upload → **read-back verify** →
manifest.

⚠️ **Read-back verification is not optional.** `images/release-224-ena-mtufix/solnix-raw.img.gz` in that
bucket is **20 bytes** — a silently truncated upload that has sat there since August, with a successful
exit status behind it. A banked asset nobody has verified is not a banked asset.

## Test the restore, not just the backup

An unverified restore path is a guess. The open question is whether a raw image in R2 can be turned back
into a registered AMI in a *fresh* account — that involves `vmimport`, an IAM role, and an S3 staging
bucket in the target account. If that turns out not to work, the honest conclusion may be that the durable
asset is the **recipe plus a Hipster ISO pin**, not the image. Better to learn that now than during the
next expiry.
