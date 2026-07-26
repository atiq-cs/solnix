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
