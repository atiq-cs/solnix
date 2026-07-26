# Account migration: numa -> ouch (deadline 22:20:50 UTC 2026-07-26)

numa (713545428937) auto-terminates ALL EC2 at 22:20:50 UTC today. ouch
(266294231451, us-east-2, 1024 vCPU quota) is the successor. Cross-account AMI/
snapshot sharing is BLOCKED by an org SCP (explicit deny) — so migration is
data->solnix.io + cold-rebuild in ouch, NOT AMI copy.

## What SURVIVES automatically (no action)
- **Nix cache, 322 pkgs** — on solnix.io (s3.solnix.io/solnix-cache), NOT numa. Safe.
- **Seed tarball** — local ~/ws/solnix-seed-store/seed.tar.zst (113M, sha
  23d8c1206ac50b9b...). Safe.
- **All git repos** — local + Codeberg (solnix, solnix-pkgs). Safe.
- **sops age key** — 1Password + ~/.config/sops/age/keys.txt. Safe.

## What DIES with numa (must handle before 22:20)
- All EC2 instances (build host, wave-5 fleet, phase-1/2 keepers, installer envs).
- All AMIs (base OI, builder, phase-2 boot AMIs) — account-scoped, SCP blocks sharing.
- aarch64 proto+kernel (/aarch64/arm64-gate, 13G; proto 310M) — ONLY on build host.
- Any wave-5 output not yet PUBLISHED to solnix.io cache.

## Actions before deadline (priority)
1. **Harvest wave-5**: ensure agent publishes all built pkgs to solnix.io cache
   before 22:20 (cache = the survival vehicle). Collect ledger locally.
2. **Archive aarch64 proto** to solnix.io (proto/ tarball, ~310M) so A3 doesn't
   re-run the multi-hour gate build in ouch. -> solnix.io/solnix-archive/aarch64/.
3. **Snapshot the build-host root nothing** — reconstructible; skip. (Nix store
   content is in the cache; OS+scripts rebuild from git.)

## aarch64 proto archived (DONE 2026-07-26 ~18:24 UTC)
The irreplaceable aarch64 illumos build state is off the dying host and safe in
TWO places (solnix.io + local dev box). No re-run of the multi-hour gate build
needed in ouch — restore this tarball instead.

- **Gate rev**: `73466454e9892e23a7860b3bd591d90accb85bd4`
  (`/aarch64/arm64-gate/illumos-gate`, tag armv8 kernel: unix + genunix)
- **Contents**: `illumos-gate/proto` (421 MiB uncompressed, 310M du) tar+zstd -3.
- **Tarball**: `aarch64-proto-73466454.tar.zst`, 99914184 bytes (~95 MiB)
- **sha256**: `b4c89fadde66db90936b98f403cb293358551590b2a9afbd61a75a684b23e3db`
- **solnix.io object**: `s3://solnix-cache/archive/aarch64/aarch64-proto-73466454.tar.zst`
  (URL: `https://s3.solnix.io/solnix-cache/archive/aarch64/aarch64-proto-73466454.tar.zst`)
  — creds are scoped to the `solnix-cache` bucket only, so it lives under a
  clearly-non-nar `archive/` prefix (NOT the `solnix-archive` bucket the plan
  above hypothesized; that bucket isn't reachable with builder creds).
- **build env**: `s3://solnix-cache/archive/aarch64/env-aarch64-73466454` (13634 B)
- **local copy**: `~/ws/solnix-archive/aarch64/aarch64-proto-73466454.tar.zst`
  (sha verified identical) + `~/ws/solnix-archive/aarch64/env-aarch64`.

Restore in ouch: `aws s3 cp s3://solnix-cache/archive/aarch64/aarch64-proto-73466454.tar.zst -
--endpoint-url https://s3.solnix.io | zstd -d | tar -x -C /aarch64/arm64-gate/illumos-gate`
(check gate is at rev 73466454 first). OPTIONAL build-proof `log/*/mail_msg` was
NOT archived (proto + env are sufficient to resume; deadline priority).

## ouch COLD-START runbook (after deadline / when migrating)
Everything rebuilds from PUBLIC resources + our git + the surviving cache:
1. `export AWS_PROFILE=ouch REGION=us-east-2`. Create key-pair solnix-oi + SG
   solnix-ssh (scripts/aws setup, one-time — mirror numa).
2. **Base OI AMI**: run `scripts/oi-make-ami.sh` — it dd's the PUBLIC OI cloud
   image (dlc.openindiana.org/isos/hipster/.../OI-hipster-cloudimage.img.zst)
   onto a blank vol via an Amazon Linux helper -> registers AMI. No numa dep.
3. **Builder AMI**: launch base OI -> scripts/oi-build-host-setup.sh (installs
   Nix from git-built store or rebuild; pulls toolchains from the surviving
   cache) -> scripts/oi-gate-build.sh if a fresh gate is needed. Seed restored
   from local ~/ws/solnix-seed-store/seed.tar.zst.
4. **Resume waves**: launch fleet (m6i.4xlarge x N), point at surviving cache
   (322 pkgs already there), continue wave 5+ / aarch64 A3 (restore proto from
   solnix.io archive) / SPARC / RISC-V.

## Key facts for ouch
- numa=713545428937, ouch=266294231451, both us-east-2, 1024 vCPU.
- IMDSv2 org-enforced (same as numa) -> metadata-shim workaround applies.
- Builder AMI recipe: base OI -> oi-build-host-setup.sh. Fleet: m6i.4xlarge
  (16 vCPU), NOT 32-vCPU (boot-hang), NOT c6id/Nitro-v5+.
- Cache pubkey cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=
  Creds: sops -d secrets/{s3-cache,cache-signing}.yaml.

## ouch cold-start DONE (2026-07-26 ~20:30 UTC — well before the 22:20 deadline)

ouch is WARM: a working illumos builder AMI exists, built entirely from public
resources + git + the surviving solnix.io cache (no numa AMI copy, no AWS S3).

### AMI ids (record these)

| what | id | notes |
|---|---|---|
| **BUILDER AMI (fleet launches from THIS)** | **`ami-0c005f030cc010b43`** | `solnix-builder-ouch-20260726`. OI hipster + Nix 2.3.16 + gcc10/14 + onbld + git + world closure + seed. ena, uefi. |
| base OI AMI (cold-start root) | `ami-097beb4de83dc9129` | `openindiana-hipster-20251026-ouch-20260726`. Stock OI + ena driver + metadata-shim + root key. ena, uefi. |
| snapshots | builder `snap-0a26d4247c8092aa9`, base `snap-013a6a443fa133f30` | |

### Fleet launch (uses the builder AMI)

```sh
aws ec2 run-instances --profile ouch --region us-east-2 \
  --image-id ami-0c005f030cc010b43 --instance-type m6i.4xlarge \
  --key-name solnix-oi --security-group-ids sg-0da52f6d0000cb9c7 \
  --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=solnix-build-ouch},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Expiry,Value=2026-08-02}]'
```
Boots in ~45s (ena0 up, shim DHCPs + enables ssh). ssh as `root` with the
ed25519 key (scripts/oi-ssh.sh). m6i.4xlarge (16 vCPU) ONLY — the AMI runs the
STOCK OI kernel (no pit_is_broken fix), so 32-vCPU still boot-hangs.

### Smoke test (PASSED on a fresh instance from the builder AMI)
- `nix --version` -> 2.3.16.
- cache reachable from ouch: `nix path-info --store https://s3.solnix.io/solnix-cache
  --option trusted-public-keys <pubkey> /nix/store/b1q9...-system-path` resolves.
- gcc-14 (`/usr/gcc/14/bin/gcc`) compiles + runs a hello.c.

### Pull from cache on the builder (the working recipe)
`scripts/oi-pull.sh <store-path> ...` — NOT `nix copy` / `nix-store -r` on the
whole closure. Nix 2.3.16 on illumos flakes with `getting status of '...':
Error 0` on whole-closure http substitution; oi-pull BFS's the closure via
narinfo and realises ONE path at a time with retries. (Same class of bug the
cache.md publish note describes.)

### Gotchas hit during the ouch cold-start (all handled)
1. **oi-make-ami.sh had a hard `:user/numa` guard** — relaxed to accept ouch.
   It also only does the dd stage; the full base-AMI build (dd -> ubuntu-zfs
   seed -> register) is now one non-blocking orchestrator: `scripts/ouch-make-base-ami.sh`.
2. **OI mirror throttles the dd-helper to ~0.5-1 MB/s** (930 MB compressed ->
   2 GB image = hopeless in-line). FIX: download the .img.zst to the dev box
   (~6 MB/s), scp it to the helper, then dd from the LOCAL file (network out of
   the dd path). The dd itself is seconds.
3. **Base image incorporations lag the catalog** — `pkg install ... git` rejected
   by `userland-incorporation@0.5.11-2025...`. FIX (as the setup script's own
   comment warns): `pkg update` FIRST (new BE `openindiana-2026:07:26`), REBOOT,
   then oi-build-host-setup.sh. The reboot's boot_archive rebuild also picks up
   the injected ena driver.
4. **rpool didn't auto-grow to the 120 GB root vol** (stuck at 1.6 GB, 220 MB
   free). FIX on first boot: `zpool set autoexpand=on rpool; zpool online -e
   rpool c1t1d0` -> 115 GB free. Bake this into the builder-host setup or do it
   once per fresh launch before installing Nix.
5. **Nix 2.3.16 configure never instantiates Makefile.config** — stock
   `configure.ac` has `AC_CONFIG_FILES([])`, so `oi-nix-setup.sh`'s post-configure
   grep/gsed on Makefile.config aborted. FIX (added to oi-nix-setup.sh):
   `./config.status --file=Makefile.config:Makefile.config.in` (config.status has
   the full subst table even though the file isn't in AC_CONFIG_FILES). Do NOT
   `autoreconf` — it needs autoconf-archive (AX_BOOST_BASE) and produces a broken
   configure; the shipped configure is correct, only the instantiation was missing.

### Execution hygiene
Every long host op (dd, pkg update/install, Nix compile, cache pull) ran DETACHED
via scripts/oi-job.sh (or a nohup runner on the linux helpers) with short
non-blocking polls — no SSH held across a multi-minute op. Assets: solnix.io
cache + local seed only; no AWS S3/ouch used for storage. Helpers reaped; only
the builder AMI + one smoke-test instance (solnix-smoke-ouch,
i-03907222e00ec4d04) left running.
