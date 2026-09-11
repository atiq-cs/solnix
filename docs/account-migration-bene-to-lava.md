# Account migration: `bene` -> `lava`

`bene` expired **2026-09-11 12:03 UTC**. New burner: **`lava`**, account `769093516156`, `us-east-2`.

## Working substrate in `lava`

| item | value |
|---|---|
| profile | `lava` |
| region | `us-east-2` |
| keypair | **`solnix-lava`** (private key `~/.ssh/solnix-lava.pem`, mode 600) |
| SG | **`sg-0d7ce9a7390bfadfe`** — tcp/22 from `73.4.58.0/24` **only** |
| running instances | **none** (verified across us-east-2/us-east-1/us-west-2) |

## ⚠️ What is stranded in `bene`, and the honest cost

AMIs are account-scoped. All three were confirmed **invisible from `lava`** (`describe-images` returns
`[]`), and because `bene`'s credentials are dead they can no longer be shared or copied — an AMI share
requires a working call *in the owning account*.

| AMI | what it was |
|---|---|
| `ami-014c4aaccd37b2356` | x86_64 base, 21/21 stages — **the** build substrate |
| `ami-054b0f50ccab2af88` | aarch64 toolchain + the 150 G tree |
| `ami-07bf2618a9405302e` | fast-console aarch64 |

**There is no public OpenIndiana/illumos AMI** to fall back on — checked. So the x86_64 substrate must be
rebuilt with `scripts/oi-make-ami.sh` from a Hipster ISO: the full 21-stage bootstrap, which is the same
work as the original bring-up rather than a copy.

Also stranded: **`dixi`** (`i-07c88ea73b9986887`) and its GREEN `run_build.pl` "All stages succeeded"
state. The *configuration* is declarative and committed (`modules/config/pgfarm.nix`,
`configurations/pgfarm.nix`), so it is reproducible — but the running host and its proof are gone.

⚠️ **Unresolved cost item:** `i-0a2983ee73397aa6d` (c5.4xlarge, `solnix-x1desktop`) was running in `bene`
when the credentials died. It cannot be terminated from `lava`. If `bene` billing is still live this is
accruing ~$0.68/h. **Only the maintainer can settle this**, via the console or restored credentials.

## Lesson: an account with a known expiry is not asset storage

The standing rule is "AWS accounts = EC2 compute ONLY, never asset storage". An AMI *is* an asset, and
these three were treated as durable infrastructure across many sessions. The rule was already right; it
was not applied to AMIs.

For `lava`, and any successor:

1. **Snapshot the recipe, not the result** — `oi-make-ami.sh` is committed and is the real asset.
2. **Record the expiry when the account is issued**, and treat an AMI as a cache with that TTL.
3. **Re-derive early** rather than discovering the loss under time pressure.

## Guard fix that fell out of this

Setting `lava` up exposed that `scripts/sg-guard.sh` had **never been auditing anything** — it sets no
profile, so `describe-security-groups` failed with `NoCredentials`, and `2>/dev/null || true` turned that
into "no violations". It reported CLEAN with a genuine `0.0.0.0/0` rule in place. Fixed with a
reachability probe that refuses to report CLEAN on an unreadable account, plus a printed count of visible
SGs. Every prior "sg-guard CLEAN" in this project's records is **vacuous**; the no-world-open rule was
held by hand discipline, not by the guard.
