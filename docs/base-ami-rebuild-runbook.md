# solnix x86_64 base AMI — rebuild in the `bene` account (runbook + report)

## Deliverable

| | |
|---|---|
| **AMI** | `ami-014c4aaccd37b2356` |
| **Name** | `solnix-base-x86_64-hipster-20251026-20260904` |
| **Snapshot** | `snap-07983775244ce44fa` |
| **Account / region** | bene (<account-id>) / us-east-2 |
| **Arch / boot mode** | x86_64 / uefi, `--ena-support`, hvm |
| **Root** | `/dev/xvda`, gp3, 20 GiB (pool auto-expands to 19.6G at first boot) |
| **Login** | `root` + `~/.ssh/id_ed25519` (`solnix-key`), `PermitRootLogin yes` |
| **Source** | public OI cloudimage `hipster/20251026/OI-hipster-cloudimage.img.zst` |

## Measured cold-boot reliability

Fresh `run-instances` cold launches on **m5.4xlarge** (the type the prior base was
measured on), each probed for real SSH (`uname -s` = SunOS), then terminated.
No stop/start, no warm reboots — every launch is a cold boot from the AMI.

| batch | N | pass | evidence |
|-------|---|------|----------|
| b1 | 5 | **5/5** | `/tmp/base-ami-batch-b1.txt` |
| b2 | 5 | **5/5** | `/tmp/base-ami-batch-b2.txt` |
| b3 | 10 | **10/10** | `/tmp/base-ami-batch-b3.txt` |
| smoke | 1 | PASS | `/tmp/base-ami-progress.txt` |

**Headline: 10/10** — and in fact **20/20 across three independent batches** plus
the smoke boot (21 cold launches, 21 passes, 0 failures). b3 alone is a clean
single-shot 10/10. Time-to-SSH was ~20-40 s from `run-instances`; 3 of the 10 in
b3 answered on the very first 20 s poll.

Per-boot verification on a launched node:

```
pit_is_broken:  1          <- the PIT tunable is in effect
pit_tsc_hz:     0          <- the legacy PIT calibration NEVER ran (the fix works)
ena0/dhcp   dhcp   ok   <ip>/20   <- single addrobj, lease bound
rpool  19.6G  1.33G  18.3G              <- pool expanded to the whole slice
```

## ⚠️ BLOCKER FOR THE NEXT REBUILD: `scripts/metadata-shim.sh` IS CORRUPTED IN GIT

`git show HEAD:scripts/metadata-shim.sh` is **not a shell script**. It is 222 lines
of cargo/COSMIC build-log output:

```
    Updating git repository `https://github.com/pop-os//cosmic-protocols`
      Adding iced v0.14.0 (/root/libcosmic/iced)
```

`git show HEAD:scripts/metadata-shim.sh | grep -c 'solnix shim'` -> **0**. It was
clobbered by commit `3ee3c7f5e7` (a COSMIC-era commit that evidently redirected a
cargo log over the file).

This did NOT affect this AMI: the working tree held a good 139-line shim, which is
what was installed and measured. But **a rebuild from a clean checkout would
install a cargo log as `/usr/lib/metadata`** — no DHCP recovery, no sshd enable,
no pool expand — and produce a 0/N AMI with a very confusing failure mode.

Recovery (the good content survives in git under two other names):
- `scripts/metadata-shim.sh.1010` — intact, and identical to the shipped shim
  except for the pool-expand block added here.
- `scripts/metadata-shim.sh.clean-single-addrobj` — the earlier single-addrobj
  variant, also intact.

The working-tree `scripts/metadata-shim.sh` is correct and should be committed as
the restored file. Its 361-line diff stat against HEAD is **the corruption being
undone, not churn** — the only real change is one additive 16-line block at the
end (`/tmp/metadata-shim.pool-expand-only.patch`).

## Which of the three fixes were applied

1. **Build method (the dominant factor) — APPLIED.** The boot_archive was edited
   OFFLINE as raw gzip'd `odc` cpio (extract -> replace -> repack in the original
   entry order -> re-gzip -9), from a Linux/OpenZFS helper doing exactly ONE
   import at an altroot and ONE clean export. No `zpool reguid`, no import of the
   target pool on a native illumos node (that GUID-collision path is what
   corrupted DHCP 0/6), and no `create-image` of a running instance.
2. **Single-DHCP-addrobj shim — APPLIED.** `scripts/metadata-shim.sh` installed
   over `/usr/lib/metadata`, plus `ena0/v4` stripped from `/etc/ipadm/ipadm.conf`
   and stale `.dhc`/`duid`/`iaid` lease state deleted so the first boot re-DHCPs
   clean. Result: exactly one `ena0/dhcp` addrobj, no lease race.
3. **`pit_is_broken=1` — APPLIED.** Written to BOTH `/etc/system` and
   `/etc/system.d/solnix-nitro-pit`, and both placed INSIDE the boot_archive (the
   kernel reads `/etc/system` in `mod_read_system_file()` from the ramdisk during
   `kmem_init()`, long before the ZFS root is mounted). Verified in effect on a
   booted node: `pit_is_broken=1`, `pit_tsc_hz=0`.
4. **ena MTU-1500 driver — NOT APPLIED, AND NOT NEEDED (finding).** See below.

## Finding: the MTU-1500 ena driver patch was NOT required in this account

`artifacts/ena/ena` in git is the **STOCK** jumbo-default driver, not the patched
one. (The `0x5dc` bytes an earlier check looked for are struct offsets —
`movl %eax,0x5dc(%r12)` — not the `min(max_mtu, ETHERMTU)` immediate. The real
verification is `dis -F ena_attach_device_init | grep 'cmpl.*0x5dc'`.) The
prebuilt patched module lived at a node-local `/root/solnix-assets/ena-mtu-fix`
that died with the old account, so shipping it would mean rebuilding from
`pkgs/illumos/patches/ena-default-mtu-1500.patch`.

The AMI therefore boots with `ena0` at **MTU 9216** (jumbo), and still measured
10/10 cold boots with clean DHCP. This is consistent with
`docs/ena-rx-coldboot-fix.md`, which proved by kernel instrumentation that the Rx
path receives the DHCP OFFER+ACK correctly and that the MTU default was never the
cause: the wins came from the build method and the addrobj fix. **The driver
rebuild can be dropped from the recipe** unless a future measurement regresses.

Caveat worth keeping: `dladm set-linkprop -p mtu` returns `operation not
supported` on this stock driver, so the MTU is not runtime-tunable here. If jumbo
ever needs to be turned OFF (or made settable), that is when to rebuild the
module — the patch is in git and buildable.

## Reproduce (mechanical)

```sh
cd ~/ws/solnix
scripts/make-base-ami.sh dd          # AL2023 helper dd's the public OI image to a blank vol
scripts/make-base-ami.sh dd-poll     # until DD_DONE (~4 min)
scripts/make-base-ami.sh seed        # Ubuntu24.04+OpenZFS helper applies all fixes offline
scripts/make-base-ami.sh seed-poll   # until SEED_DONE (~3 min); seed-log for the full trace
scripts/make-base-ami.sh reg         # snapshot + register-image -> prints the AMI id
scripts/make-base-ami.sh boot        # one cold launch
scripts/make-base-ami.sh boot-poll   # ssh probe + pit/mtu/dhcp verification
BATCH_TAG=b1 scripts/make-base-ami.sh batch 10   # N cold launches -> N/10, auto-terminates
scripts/make-base-ami.sh reap        # terminate helpers + boot test
```

Files:
- `scripts/make-base-ami.sh` — the orchestrator (dd/seed/reg/boot/batch/reap).
- `scripts/base-ami-seed.sh` — the payload that runs ON the Ubuntu helper.
- `scripts/metadata-shim.sh` — the single-addrobj shim (+ the new pool-expand step).
- `modules/config/solnix-nitro-pit.system.d` — the PIT tunable fragment.

## Gaps hit that are NOT in the docs (fixed here; carry them forward)

1. **sgdisk cannot repartition the OI cloud image.** The image's GPT holds only 9
   entries and its partition table is smaller than the GPT spec minimum, so
   sgdisk refuses EVERY create ("Could not create partition N ... not saving
   changes") while still performing deletes — i.e. it can only destroy the table.
   The image also puts the 8 MiB Solaris reserved partition (BF07, number 9)
   IMMEDIATELY after the ZFS partition, so `growpart` has no adjacent free space
   to claim. **Fix:** rewrite the whole table declaratively with `sfdisk -d` ->
   edit -> `sfdisk --force`, extending the ZFS partition to the tail and moving
   the reserved partition behind it, preserving each partition's start, type code,
   UUID and name. Done with the pool NOT imported, so no live pool is touched.
   (Implemented in `scripts/base-ami-seed.sh` step 1.)
2. **The root pool cannot be expanded from Linux.** The vdev is `whole_disk=1`, so
   `zpool online -e` needs to relabel the slice, and OpenZFS-on-Linux refuses:
   `cannot relabel '/dev/nvme1n1p2': unable to read disk capacity` (with
   `autoexpand=on` too). Only illumos' ZFS/EFI label code does it. **Fix:** the
   expand runs on the target, from `metadata-shim.sh`, on the first boot that
   reaches the shim — placed LAST in the shim so network bring-up never waits on
   it, and idempotent (`online -e` is a no-op once the vdev covers its device).
   Without this the image has ~188 MB free and is useless for Nix.
3. **`bootstrap-register.sh` assumes `/etc/profile.d` exists.** The OI cloud image
   has no such directory, so the Nix bootstrap dies at its last step with
   `/etc/profile.d/nix-illumos.sh: No such file or directory` AFTER having
   installed a working nix. `mkdir -p /etc/profile.d` first (or patch the script
   to create it).
4. **The binary cache is missing NARs.** `cache.solnix.io` serves the `.narinfo`
   for `…-coreutils` but the referenced `nar/0bag7…nar.xz` is **404** on both
   `cache.solnix.io` and `s3.solnix.io/solnix-cache`, so
   `nix-store --realise` of a cached path fails. This is a CACHE-side gap, not an
   AMI defect — worth a separate look at whether the NAR objects survived.
5. **`dd-poll` needs sudo.** `/root/oi-import.log` is root-only on AL2023.

## Nix status on the AMI

- The prebuilt native illumos Nix tarball is **staged in the image** at
  `/root/nix-illumos-2.3.16.tar.zst` (+ `.sha256`, verified), so a fresh instance
  needs no network fetch and no compiler to get Nix.
- Install: `mkdir -p /etc/profile.d; cd /root && mkdir nixboot && cd nixboot &&
  zstd -d < ../nix-illumos-2.3.16.tar.zst | tar -xf - && ./bootstrap-register.sh`
- **`nix --version` -> `nix (Nix) 2.3.16`** (works).
- **A real derivation builds and realises on the node:**
  `nix-build` of a trivial `system = "x86_64-solaris"` derivation produced
  `/nix/store/p9jazmvwgxahp8bng0p5y8q4y4vqcnyp-solnix-nix-selftest`.
- `nix profile install nixpkgs#coreutils` by NAME is **not** exercisable on this
  base as shipped: that flow needs Nix **2.24** (`nix profile` + flakes) plus the
  `solnix-pkgs` by-name flake on the node and `nix registry add nixpkgs
  path:<by-name-flake>` (per `docs/nix-upgrade-verified.md`). The base carries the
  2.3.16 bootstrap only; 2.24 is built on top by `scripts/oi-nix224-setup.sh`, and
  the by-name flake tree (`solnix-pkgs`) is a provisioning-time addition. Both are
  provisioning ON this base, which is the documented order — do NOT re-bake a
  derivative AMI from a running instance.

## Persisted artifacts (exact paths on the dev box)

2026-09-11 rebuild (lava):

| path | what |
|------|------|
| `/tmp/ami-rebuild-progress.txt` | milestone log + every finding, written as the build ran |
| `/tmp/ami-rebuild-stages.txt` | stage-by-stage note log |
| `/tmp/base-ami-batch-b1.txt` | batch b1 evidence (**10/10**, per-instance PASS + terminate) |
| `/tmp/base-ami-batch-b2.txt` | batch b2 evidence (**10/10**) |
| `/tmp/base-ami-batch-restore.txt` | **5/5** from the R2-restored AMI `ami-062d017ec6cd47b16` |
| `/tmp/seed1-lava.log` | seed run 1 — the grow SILENTLY no-op'd (the bug, as found) |
| `/tmp/seed3-lava.log` | seed run 3 — `GROW_VERIFIED`, all fixes applied (2959 lines) |
| `/tmp/ami-bank-progress.txt` | banking log incl. the read-back sha256 comparison |
| `/tmp/ami-bank-MANIFEST.txt` | the manifest uploaded beside the image |
| `/tmp/lava-base-ami.state` | build state (DDIID/SEEDIID/VOL/SNAP/AMI/BIID) |

Prior `bene` run (superseded, kept for provenance): `/tmp/base-ami-report.md`,
`/tmp/base-ami-progress.txt`, `/tmp/metadata-shim.pool-expand-only.patch`,
`/tmp/metadata-shim.diff-vs-git.patch`, `/tmp/seed1.log`.

In-repo:
- `scripts/make-base-ami.sh` (was `bene-make-base-ami.sh`; account-portable)
- `scripts/base-ami-seed.sh` (was `bene-base-seed.sh`; + the grow fix and assertion)
- `scripts/ami-bank.sh` (new — bank / verify / restore)
- `scripts/metadata-shim.sh` (restored + pool-expand block)

## Banking in R2, and restoring into a fresh account

The AMI is account-scoped and **will** die with the burner. The image is therefore banked in
R2, which is not account-scoped. `scripts/ami-bank.sh` does bank / verify / restore.

| | |
|---|---|
| banked object | `s3://solnix-cache/ami/x86_64-20260911/solnix-base-raw.img.gz` |
| plain HTTPS | `https://s3.solnix.io/solnix-cache/ami/x86_64-20260911/solnix-base-raw.img.gz` |
| size | 1268766279 B (1.2 GiB gz, from a 20 GiB raw image) |
| gz sha256 | `2f6e1f9e11b2bae5dd455ea8464ba035294ededa2d542a2b47e10f8222dfa558` |
| raw sha256 | `b0f98e3c1660953281e9cba784b17626aa496cf57df9ab5087d026bd4023d956` |
| beside it | `MANIFEST.txt`, `SHA256SUMS` |

### ⚠️ NOT under `images/` — that prefix is DENIED to the sops credential

The brief for this work assumed `images/`, matching the existing `images/release-224-*` blobs.
**Measured:** the credential in `secrets/s3-cache.yaml` gets **403 on PutObject for the exact
`images/` prefix**, while every other prefix in the bucket — including the root, `bootstrap/`,
`ami/`, `nar/`, and even `imagesx/` — accepts writes, and DeleteObject works. So the existing
`images/release-224-*` objects were uploaded with a **different, more privileged key that is
not in `secrets/`**. Banked under `ami/` instead. If a future task must write `images/`, it
needs a credential that is not currently in the repo.

### Why a raw image, and not `aws ec2 export-image`

`export-image` only works on AMIs that were themselves VM-Imported, so it would fail here —
and it is unnecessary. The build path already *writes* a raw image onto a blank EBS volume;
banking is just the inverse read. Restore is the same proven `dd -> snapshot -> register-image`
path with the banked image substituted for the public OI one, and it **skips the seed stage**
because the banked image already carries every fix.

### ⚠️ Zero the unwritten tail before imaging, or the blob is 16x too big

A whole-device `dd` of a 20 GiB volume gzipped to **20497119997 B (95%)**, not the ~10x
compression the `images/` precedent shows. Cause, measured: **never-written EBS regions read
back as deterministic incompressible garbage, not zeros.** Per-GiB 1 MiB samples gzipped to
1048754 B (i.e. gzip *overhead* on random data) from 2 GiB onward, while `/dev/zero` gzips
8 MiB to 36612 B and the helper's own unused root tail showed the same garbage — so it is an
EBS property, not something the build did. Reads are reproducible (identical sha256 twice),
so it is stored content.

The boundary is found generically — the last 1 MiB sample per 16 MiB that compresses below
90% — measured at **1984 MiB**, consistent with the 1.945 GiB authored image. Zeroing
2048..20463 MiB (leaving partition 9 and the backup GPT bit-exact) took the blob to
**1268766279 B (5.9%)**. Verified afterwards that the GPT and all three partitions were
unchanged and that 32 ZFS uberblocks were still present in labels L0 and L1.

### Verification is by READ-BACK, never exit status

`images/release-224-ena-mtufix/solnix-raw.img.gz` in this bucket is **20 bytes** — a silently
truncated upload that has sat there since August, produced by a command that exited 0. So
`bank-upload` re-downloads the object and compares sha256, and also asserts `head-object`
ContentLength. Both were confirmed able to FAIL:

| negative control | result |
|---|---|
| a 20-byte object with an otherwise-correct `SHA256SUMS` | `FAIL: implausibly small (20 bytes)`, rc=1 |
| a 150 MB object of the right magnitude but wrong bytes | `VERIFY_FAILED` on sha256, rc=1 |
| the real banked object | `VERIFY_OK` |

A third check runs on the helper: the gzip is decompressed and its sha256 compared to the raw
device's, so a truncated-but-valid-prefix stream cannot pass.

### Restore procedure (TESTED end-to-end, not merely described)

```sh
SOLNIX_PROFILE=<new-profile> REGION=<region> SG_ID=<sg> SUBNET=<subnet> AZ=<az> \
  KEY_NAME=<keypair> scripts/ami-bank.sh restore ami/x86_64-20260911
scripts/ami-bank.sh restore-poll     # until RESTORE_OK (sha256 of written bytes verified)
scripts/ami-bank.sh restore-reg      # snapshot + register-image -> prints the AMI id
```

The helper needs no credentials for the image: it `curl`s the object over plain HTTPS and
pipes it through `gunzip` straight onto a blank 20 GiB volume, then hashes the written bytes
and compares against `SHA256SUMS` from the bank.

**Proof it works** (run in `lava`, 2026-09-11):

1. `RESTORE_SHA_OK` — bytes on the restored disk hashed
   `b0f98e3c1660953281e9cba784b17626aa496cf57df9ab5087d026bd4023d956`, identical to the raw
   image that was banked.
2. Registered `ami-062d017ec6cd47b16` from that volume's snapshot.
3. **5/5 cold launches** of the restored AMI passed a real SSH probe
   (`/tmp/base-ami-batch-restore.txt`).
4. A restored instance is functionally identical to the original: `rpool 19.6G / 17.7G avail`,
   `pit_is_broken=1`, `pit_tsc_hz=0`, one `ena0/dhcp` addrobj with a lease, Nix tarball staged.

**The one caveat:** a restored AMI still trusts the **old** ssh key, because
`/root/.ssh/authorized_keys` is baked into the image. Either keep that private key alongside
the bank, or re-seed `authorized_keys` after restoring (the seed stage's `mypub` step, or a
single offline edit on the restore helper before `restore-reg`). This is the only per-account
step the bank cannot carry.

## Cost hygiene

Every instance launched by this work is terminated — verified by
`describe-instances --filters Name=tag:Owner,Values=gregburd`, which shows only `terminated`:

| instance | type | role |
|---|---|---|
| `i-0af11d9e403125af8` | c5.4xlarge | dd helper |
| `i-010e82037713d49f4` | c5.4xlarge | seed helper |
| `i-03ce5b752023f20aa` | m5.4xlarge | boot smoke test |
| `i-0210493047dec035a` | c5.4xlarge | bank helper |
| `i-05eaadc13c824aeff` | c5.4xlarge | restore helper |
| `i-051cce77e6abcdab3` | m5.4xlarge | restore verification |
| 25 batch instances | m5.4xlarge | b1 (10), b2 (10), restore (5) — each batch terminates its own fleet |

Both `DeleteOnTermination=false` volumes were also deleted (`vol-0d97982c018e3334f`,
`vol-038369ab9459ab570`); `describe-volumes` for this owner now returns empty. Kept
deliberately: `ami-0cb14e40f9355bd0c` + `snap-0f7750c410a727fec` (the base) and
`ami-062d017ec6cd47b16` + `snap-0575f5577ccb20581` (the restore proof).

`scripts/make-base-ami.sh reap` sweeps anything tagged `Purpose=solnix-base-ami` and
`scripts/ami-bank.sh reap` sweeps `Purpose=solnix-amibuild`; neither can touch another
tenant's resources. This account is shared — `libdb-*`, `fts-*`, `a2abench*`, `xtc-*` and
others belong to other tenants and must never be touched.

## Security

No security group was created or modified. Ingress is the pre-existing
`sg-0d7ce9a7390bfadfe` (:22 from the operator /24 only).
`AWS_PROFILE=lava bash scripts/sg-guard.sh audit us-east-2` -> **CLEAN** (8 SGs visible),
and negative-controlled: `SG_GUARD_SELFTEST=1 ... audit` -> **DIRTY**, rc=1, proving the
detector can actually fail. (Every pre-2026-09-11 "sg-guard CLEAN" in this project is
vacuous — see `docs/account-migration-bene-to-lava.md`.)

## Disk sizing: what is and is not true

### ❌ WITHDRAWN: "the root pool is stuck at ~2 GiB"

This section previously claimed the base AMI's `rpool` could not be grown and that builds
must therefore live inside <2 GiB or use a second pool. **That was a bug, not a property.**
The seed stage's offline grow silently no-op'd (two defects, root-caused in the section
above), so the pool covered 1.7 GiB of a 20 GiB disk. Fixed and measured:
**`rpool 19.6G, 17.7G avail`** on a booted instance, same single 20 GiB `xvda`.
Both `ami-0cb14e40f9355bd0c` and the restored `ami-062d017ec6cd47b16` show this.

### ✅ FIXED 2026-10-29 for the solnix DP image (rootgrow): the root pool grows to the EBS size at first boot

The DP image built by `scripts/solnix-install` (`oi-make-raw-img.sh`) now makes the root pool with `zpool create -B`
(whole_disk=1, autoexpand=on), and `cloud-ec2.nix` sets `services.zfs.expandOnBoot = "all"` (NixOS amazon-image.nix).
Measured on kiwi, 6/6 cold launches: 32G volume -> spool 31.5G, 100G -> 99.5G, in one boot with no human step. The pool
was ONLINE, and `zpool history` shows the relabel at root import. The old layout (pool on a fmthard'd slice, whole_disk=0)
stayed at 7.5G on both sizes (control, 2/2): libzfs relabels only whole-disk vdevs. The section below still describes the
OLD OI base AMI and any image built before this change.

### ✅ STILL TRUE (old OI base AMI / pre-2026-10-29 images): `--block-device-mappings` beyond 20 GiB does not enlarge `rpool`

* Launching with a root **larger than the AMI's 20 GiB** does not enlarge `rpool`. The extra
  capacity is not adjacent to the vdev, so `zpool online -e rpool` has nothing to expand into
  and the space is simply unused.
* For more than ~19 GiB of build space, attach a **separate volume** and `zpool create` a
  whole-disk pool on it (or add it as a second vdev, accepting it cannot then be removed).
* ⚠️ Do **NOT** grow the mounted root slice in place. Never live-`fdisk` or grow a MOUNTED
  zpool slice — doing so destroyed a node earlier in this project.

Practical consequence for briefs: ~19 GiB of root pool is now available by default, which is
enough for most work. Only ask for a second pool when the job genuinely needs >19 GiB.
