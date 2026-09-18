# Account migration: lava -> hotdog (2026-09-17)

`lava` expired 2026-09-17 12:20 UTC. `hotdog` replaces it as the EC2 build account. Same rules as every burner
account before it.

## hotdog facts (verified, not assumed)

* Profile: `hotdog` (`~/.aws/credentials`), account **`585335547908`**, IAM user `hotdog`.
  (lava was `769093516156`; bene was earlier and expired 2026-09-11.)
* `sts get-caller-identity` authenticates. ✅
* `us-east-2` reachable; `describe-instances` returns (empty = no load right now).
* ⚠️ **sg-guard CAN READ hotdog** — audit shows "8 security group(s) visible", not the silent
  `NoCredentials -> CLEAN` blindness that hid a world-open rule for the whole project once. The
  `SG_GUARD_SELFTEST=1` synthetic hit fires (`VIOLATION ... 0.0.0.0/0 ... DIRTY`), proving the detector works on
  this account without creating a real rule. Re-verify both directions on any new region before trusting a pass.
* **Fresh account — almost nothing exists yet:**
  * keypairs: **none** (must create one, or bake a public key into the restored AMI).
  * self AMIs: **none** (must restore from R2 — see below).
  * SGs: only `default` (`sg-006881ca53b06f42d`). A tcp/22-from-operator-/24 SG must be created per the
    NEVER-0.0.0.0/0 rule (`SG_GUARD_SELFTEST=1` proves the guard; never a world-open rule even to test).

## What changed in-repo

* `scripts/sg-guard.sh` default profile `lava` -> `hotdog`.
* Other scripts read `$AWS_PROFILE` or take the profile as an argument, so they need no edit — set
  `AWS_PROFILE=hotdog` (or pass `--profile hotdog`) when invoking them.

## Restoring the x86_64 build AMI on hotdog (the first thing a build needs)

lava's `ami-0cb14e40f9355bd0c` is GONE with lava. The AMI is banked in R2 as a raw disk image (banking the OUTPUT,
per the "AWS accounts are compute only, R2 is the asset store" rule):

* `s3://solnix-cache/ami/x86_64-20260911/solnix-base-raw.img.gz` — 1,268,766,279 B gzip of a 21,474,836,480 B raw
  whole-disk image (GPT: ESP + rpool + Solaris reserved). Decompressed sha256
  `b0f98e3c1660953281e9cba784b17626aa496cf57df9ab5087d026bd4023d956`; gz sha256 `2f6e1f9e…`.
* `MANIFEST.txt` is the full recipe + read-back verification. Fixes baked in: offline boot_archive rebuild,
  IMDSv2 metadata-shim, single ena0 DHCP addrobj, `pit_is_broken=1` (Nitro PIT wedge).

**Restore procedure** (needs a Linux helper instance on hotdog with an extra EBS volume, OR AWS VM Import):
1. Launch a small Linux instance on hotdog; attach a fresh ≥21 GiB gp3 volume.
2. Download + decompress + verify: `curl … solnix-base-raw.img.gz | gzip -dc > /dev/xvdX`, confirm the written
   volume's sha256 == `b0f98e3c…` (verify by READ-BACK, never `dd` exit status).
3. Snapshot the volume; `register-image` with boot-mode uefi + ENA + root `/dev/xvda`.
4. ⚠️ **Keypair caveat inherited from lava**: the banked image logs in as `root + the account keypair's private
   key`. lava's working key was `~/.ssh/solnix-lava.pem.AMI-BAKED-still-works` because the AMI baked the OLD key's
   PUBLIC half; deleting the AWS keypair can't reach inside an image. For hotdog, either (a) create a hotdog
   keypair and inject its public key into the raw image before snapshot, or (b) reuse the baked lava public key and
   the matching `solnix-lava.pem.AMI-BAKED-still-works` private key — the private key still works regardless of
   account, since auth is by the baked public key, not an AWS keypair record. Verify SSH with
   `-o ControlMaster=no -o ControlPath=none` (an ssh mux master made every key look valid once).
5. Bank the resulting hotdog AMI id here; treat it as a cache with hotdog's TTL, not an asset.

## aarch64

`s3://solnix-cache/ami/aarch64-proto-20260912/` has the aarch64 proto AMI, same restore shape.

## Standing rules unchanged

Shared account, 512 vCPU ceiling, re-check `describe-instances` before every launch. Tag `solnix-*`. NEVER a
`0.0.0.0/0`/`::/0` rule. TERMINATE instances AND delete orphaned volumes; check the API, don't trust the report.
The cache (`cache.solnix.io` / `s3.solnix.io`) is on R2, independent of any EC2 account — it survives every expiry.

## ⚠️ Shared-account hazard on hotdog (observed 2026-09-17)

A FOREIGN tenant's SG `sg-0a0fec26afe57cd43` (`osv-bench`) has a **world-open tcp/22 from `0.0.0.0/0`** ingress
rule. This is NOT ours and must NOT be touched (it belongs to the `osv-*` tenant), but it is the exact
T&C-violation-kills-the-shared-account hazard the project guards against — so `sg-guard audit` correctly reads
**DIRTY** on hotdog entirely because of it.

* It is currently **dormant** (not attached to any running instance — verified), so no live box is exposed through
  it, but the rule's mere existence is the account-level risk.
* **Action: ping the osv owner** to remove it. Until then, `sg-guard` will report DIRTY on hotdog even though every
  solnix SG is clean.
* Our SG `sg-0ee29b5cff1de2cd0` (`solnix-ssh-operator`) is correctly scoped: tcp/22 from `73.4.58.0/24` ONLY.
* The guard is NOT blind on hotdog (3 SGs visible; `SG_GUARD_SELFTEST=1` flips it DIRTY) — the DIRTY reading is a
  REAL foreign rule, not the silent-unreadable-account failure.
