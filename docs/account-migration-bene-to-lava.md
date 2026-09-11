# Account migration: `bene` -> `lava`

`bene` expired **2026-09-11 12:03 UTC**. New burner: **`lava`**, account `769093516156`, `us-east-2`.

## Working substrate in `lava`

| item | value |
|---|---|
| profile | `lava` |
| region | `us-east-2` |
| keypair | **`solnix-lava`** (private key `~/.ssh/solnix-lava.pem`, mode 600) |
| SG | **`sg-0d7ce9a7390bfadfe`** — tcp/22 from `73.4.58.0/24` **only** |
| subnets | `subnet-0230d1c45d8a098a7` (2a), `subnet-01c9a1bb639c2f8ef` (2b), `subnet-0b90d606a743759f9` (2c) |
| x86_64 base AMI | **`ami-0cb14e40f9355bd0c`** (`snap-0f7750c410a727fec`), 21/21 cold launches |
| running instances | **none of ours** — the account is SHARED; `libdb-*`, `fts-*`, `a2abench*`, `xtc-*` etc. belong to other tenants and must never be touched |

The keypair arrives as a lone `.pem` with no `.pub`; derive the public half with
`ssh-keygen -y -f ~/.ssh/solnix-lava.pem` (the build recipe now does this itself).

## ⚠️ What is stranded in `bene`, and the honest cost

AMIs are account-scoped. All three were confirmed **invisible from `lava`** (`describe-images` returns
`[]`), and because `bene`'s credentials are dead they can no longer be shared or copied — an AMI share
requires a working call *in the owning account*.

| AMI | what it was |
|---|---|
| `ami-014c4aaccd37b2356` | x86_64 base, 21/21 cold launches — **the** build substrate. **REBUILT 2026-09-11 as `ami-0cb14e40f9355bd0c` in `lava` (21/21), and now banked in R2 — see below.** |
| `ami-054b0f50ccab2af88` | aarch64 toolchain + the 150 G tree |
| `ami-07bf2618a9405302e` | fast-console aarch64 |

**There is no public OpenIndiana/illumos AMI** to fall back on — checked. So the x86_64 substrate had to be
rebuilt with `scripts/make-base-ami.sh` from the public OI cloud image: the full bootstrap, which is the
same work as the original bring-up rather than a copy. **That rebuild is done, and the result is banked so
it does not have to happen again** (`s3://solnix-cache/ami/x86_64-20260911/`).

Note on "21/21": that figure is **21 cold launches, 21 passes** (per
`docs/session-record-substrate-and-verification.md`), not 21 build stages — the pipeline has six stages
(dd/seed/reg/boot/batch/reap). Earlier revisions of this file said "21/21 stages", which misread the
source; the rebuild re-measured 21/21 launches (10+10 batches plus a smoke boot).

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

### The sharper version: the response to each loss made the next loss just as expensive

This has now happened **at least three times before `bene`** — `beef`, `ouch`, and the accounts in
`docs/durability-account-loss.md`. The evidence is sitting in `scripts/`:

| script | size | account |
|---|---|---|
| `beef-make-base-ami.sh` | 13,182 B | dead |
| `ouch-make-base-ami.sh` | 12,379 B | dead |
| `bene-make-base-ami.sh` | 16,598 B | dead |

**One script per dead burner account** — three forks of a single procedure, each hardcoding its
own profile/SG/subnet/keypair, each stranded with its account, each drifted from the others.
So the recurring failure was never just "AMIs are account-scoped". It is that every loss was
answered with **a new per-account script instead of a durable recipe plus a banked artifact**.
Adding `lava-make-base-ami.sh` would have been the fourth repetition.

Done instead (2026-09-11):

1. **One recipe, parameterized.** `scripts/bene-make-base-ami.sh` -> `scripts/make-base-ami.sh`
   and `scripts/bene-base-seed.sh` -> `scripts/base-ami-seed.sh`, with every account specific
   an env var (`SOLNIX_PROFILE`, `REGION`, `SG_ID`, `SUBNET`, `AZ`, `KEY_NAME`, `KEY`,
   `HELPER_TYPE`, `BOOT_TYPE`, `BASE_IMG_URL`). **Do not fork it again.**
2. **The artifact is banked off-account.** `scripts/ami-bank.sh` puts the raw disk image in R2
   at `s3://solnix-cache/ami/x86_64-<date>/` with read-back-sha256 verification, so the next
   expiry costs a ~10 minute restore rather than a full rebuild.
3. **The restore path is tested, not assumed** — see below.

For `lava`, and any successor:

1. **Snapshot the recipe, not the result** — `make-base-ami.sh` is committed and is the real asset.
2. **Bank the artifact too**, off-account, verified by read-back — a recipe that takes an hour
   is still a bad day if it is the only copy.
3. **Record the expiry when the account is issued**, and treat an AMI as a cache with that TTL.
4. **Re-derive early** rather than discovering the loss under time pressure.

## Recovery: registering a working AMI in a fresh account

The x86_64 base is banked, so recovery no longer requires the 21-stage rebuild. Full detail
and the measured evidence are in `docs/base-ami-rebuild-runbook.md`.

| | |
|---|---|
| banked image | `https://s3.solnix.io/solnix-cache/ami/x86_64-20260911/solnix-base-raw.img.gz` |
| size / sha256 | 1268766279 B / `2f6e1f9e11b2bae5dd455ea8464ba035294ededa2d542a2b47e10f8222dfa558` |
| beside it | `MANIFEST.txt` (provenance + all fixes) and `SHA256SUMS` |

```sh
# 1. sanity-check the bank BEFORE trusting it (reads only the object store)
scripts/ami-bank.sh verify ami/x86_64-20260911

# 2. restore into the new account: helper curls the image over plain HTTPS,
#    gunzips it onto a blank 20 GiB volume, and verifies the WRITTEN bytes' sha256
SOLNIX_PROFILE=<new> REGION=<region> SG_ID=<sg> SUBNET=<subnet> AZ=<az> \
  KEY_NAME=<keypair> scripts/ami-bank.sh restore ami/x86_64-20260911
scripts/ami-bank.sh restore-poll    # until RESTORE_OK
scripts/ami-bank.sh restore-reg     # snapshot + register-image -> the new AMI id

# 3. prove it, do not assume it
AMI_OVERRIDE=<new-ami> BATCH_TAG=restore scripts/make-base-ami.sh batch 5
```

No VM Import/Export and no `vmimport` IAM role is needed. (`aws ec2 export-image` would not
have worked anyway — it only exports AMIs that were themselves VM-Imported.) The banked image
is the same raw form the build path already writes to a blank volume, so restore is the proven
`dd -> snapshot -> register-image` path and **skips the seed stage entirely**.

**Verified end-to-end in `lava` on 2026-09-11**, not merely written down: restore reported
`RESTORE_SHA_OK` (written bytes identical to the banked image), produced
`ami-062d017ec6cd47b16`, and that AMI passed **5/5 cold launches** with real SSH probes, with
`rpool 19.6G / 17.7G avail`, `pit_is_broken=1`, `pit_tsc_hz=0` and a bound DHCP lease —
functionally identical to the freshly built base.

⚠️ **The one thing the bank cannot carry: the ssh key.** `/root/.ssh/authorized_keys` is baked
into the image, so a restored AMI still trusts the OLD keypair. Either keep that private key
with the bank, or re-seed `authorized_keys` on the restore helper before `restore-reg`.

⚠️ **`images/` is not writable with the repo's credential.** The credential in
`secrets/s3-cache.yaml` gets 403 on PutObject for that exact prefix, though it can write every
other prefix including the bucket root. The existing `images/release-224-*` blobs were uploaded
with a more privileged key that is **not** in `secrets/`. Hence `ami/`.

## Guard fix that fell out of this

Setting `lava` up exposed that `scripts/sg-guard.sh` had **never been auditing anything** — it sets no
profile, so `describe-security-groups` failed with `NoCredentials`, and `2>/dev/null || true` turned that
into "no violations". It reported CLEAN with a genuine `0.0.0.0/0` rule in place. Fixed with a
reachability probe that refuses to report CLEAN on an unreadable account, plus a printed count of visible
SGs. Every prior "sg-guard CLEAN" in this project's records is **vacuous**; the no-world-open rule was
held by hand discipline, not by the guard.
