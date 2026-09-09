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
scripts/bene-make-base-ami.sh dd          # AL2023 helper dd's the public OI image to a blank vol
scripts/bene-make-base-ami.sh dd-poll     # until DD_DONE (~4 min)
scripts/bene-make-base-ami.sh seed        # Ubuntu24.04+OpenZFS helper applies all fixes offline
scripts/bene-make-base-ami.sh seed-poll   # until SEED_DONE (~3 min); seed-log for the full trace
scripts/bene-make-base-ami.sh reg         # snapshot + register-image -> prints the AMI id
scripts/bene-make-base-ami.sh boot        # one cold launch
scripts/bene-make-base-ami.sh boot-poll   # ssh probe + pit/mtu/dhcp verification
BATCH_TAG=b1 scripts/bene-make-base-ami.sh batch 10   # N cold launches -> N/10, auto-terminates
scripts/bene-make-base-ami.sh reap        # terminate helpers + boot test
```

Files:
- `scripts/bene-make-base-ami.sh` — the orchestrator (dd/seed/reg/boot/batch/reap).
- `scripts/bene-base-seed.sh` — the payload that runs ON the Ubuntu helper.
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
   (Implemented in `scripts/bene-base-seed.sh` step 1.)
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

| path | what |
|------|------|
| `/tmp/base-ami-report.md` | this runbook |
| `/tmp/base-ami-progress.txt` | milestone log written as the build ran |
| `/tmp/base-ami-batch-b1.txt` | batch b1 evidence (5/5, per-instance PASS + terminate) |
| `/tmp/base-ami-batch-b2.txt` | batch b2 evidence (5/5) |
| `/tmp/base-ami-batch-b3.txt` | batch b3 evidence (10/10) |
| `/tmp/bene-make-base-ami.sh` | copy of the orchestrator (also in-repo `scripts/`) |
| `/tmp/bene-base-seed.sh` | copy of the seed payload (also in-repo `scripts/`) |
| `/tmp/metadata-shim.pool-expand-only.patch` | **my actual shim change** (vs the intact `.1010` baseline) |
| `/tmp/metadata-shim.diff-vs-git.patch` | shim diff vs corrupted HEAD (mostly the corruption being undone) |
| `/tmp/seed1.log` | full seed trace incl. the boot_archive repack + verifications |

In-repo (new, uncommitted — orchestrator commits):
- `scripts/bene-make-base-ami.sh`
- `scripts/bene-base-seed.sh`
- `scripts/metadata-shim.sh` (restored + pool-expand block)

## Cost hygiene

Every instance launched by this work is terminated: the two helpers
(`<instance-id>` dd, `<instance-id>` seed), the smoke test, and every
batch instance (the batch stage terminates its own fleet as its last step).
`scripts/bene-make-base-ami.sh reap` also sweeps anything tagged
`Purpose=solnix-base-ami`, which cannot touch other tenants' resources.

## Security

No security group was created or modified. Ingress is the pre-existing
`<sg-id>` (:22 from the operator /24 only).
`bash scripts/sg-guard.sh audit` -> CLEAN.

## ⚠️ Disk sizing on `ami-014c4aaccd37b2356`: `--block-device-mappings` does NOT grow the root pool

Measured, and it has now cost two agents time:

* The base AMI's root pool is a **20 GiB `xvda`**. That is small for Rust/COSMIC work — the
  cosmic-term vendor FOD alone is 623 MB and the build trees are far larger.
* Launching with `--block-device-mappings /dev/sda1` and a larger size does **not** enlarge `rpool`.
  The extra capacity appears as a **SEPARATE, UNUSED disk**, and `zpool online -e rpool` does
  **nothing** — there is no free space adjacent to the existing vdev to expand into.
* You must `zpool create` a new pool on the extra disk and build there (or add it as a second vdev,
  accepting that it cannot then be removed).

⚠️ Do **NOT** try to grow the mounted root slice in place. The standing rule applies: never
live-`fdisk` or grow a MOUNTED zpool slice — doing so destroyed a node earlier in this project.
Attach a separate volume and make a whole-disk pool.

Practical consequence for briefs: asking for `root >=200 GiB` on this AMI does not give you a
200 GiB `/`. Say explicitly "create a pool on the second disk and set TMPDIR/build dirs there."
