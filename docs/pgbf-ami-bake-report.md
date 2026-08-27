# solnix x86_64 PostgreSQL build-farm-animal AMI — bake report

## Deliverables

| Item | Status |
|------|--------|
| Pre-install (pgbf user, client-code, build-farm.conf, ccache+ipc-run) | **DONE + PROVEN** |
| First-boot build-pool hook (bfpool/pgbf on an attached volume) | **DONE + PROVEN** (created bfpool on the test volume at boot) |
| nix-by-name (`nix profile install nixpkgs#<pkg>`) | **DONE + PROVEN** (pure eval resolves; coreutils installed+ran) |
| run_build.pl --test drives a PG build | **PROVEN** (checkout -> configure PASS (318 checks) -> build, on /pgbf/buildroot) |
| Baked AMI `solnix-pgbf-animal-20260827` | **REGISTERED** `ami-05b9358e0aacc7bc3` |
| Cold-launch boot to login + full stack present | **YES** (boots, login prompt, pgbf/client/conf/by-name all baked) |
| Cold-launch SSH reachable (first-boot DHCP) | **NO — unresolved bake regression** (see below) |

## AMI

- **`ami-05b9358e0aacc7bc3`** — name `solnix-pgbf-animal-20260827`, snapshot `snap-0c8e45ae98da6ec25`,
  root 8 GiB (small ZFS root slice — build_root goes on a SEPARATE pool, never grow root).
- Built IN-PLACE (`create-image --no-reboot`, NOT a ZFS-import edit — per ena-rx-coldboot-fix.md) from a
  cold-launch-verified 10/10 base (`ami-0f5ab5fac82d7cd1f` solnix-ena-1010-v15).

## What is baked (all verified on the running build node)

1. **Unprivileged `pgbf` user** (`useradd -m -d /export/home/pgbf`). PG initdb/run_build refuse root.
2. **PGBuildFarm client** at `/opt/pgbf/client-code` (github.com/PGBuildFarm/client-code, run_build.pl).
3. **build-farm.conf** (proven knobs; only these changed from the sample):
   - `make => 'gmake'`
   - `build_root => '/pgbf/buildroot'` (persistent pool the first-boot hook makes)
   - `config_opts => [ --enable-cassert --enable-debug --enable-tap-tests --without-icu ]`
     (`--without-icu` because IPS ICU is v4.6 < the required 55; wire modern ICU later to drop it)
   - `config_env.CC => 'ccache gcc'`, `use_accache => 1` (defaults)
   - `animal => "CHANGEME"`, `secret => "CHANGEME"` — a REAL animal needs a name+secret from
     buildfarm.postgresql.org (a human step; see runbook).
4. **Extra deps** (the only ones beyond the base toolchain+core-perl): `pkg install developer/ccache
   library/perl-5/ipc-run-542`. ccache 4.13.6, IPC::Run 20260402. The client itself needs no CPAN installs
   (LWP present; DBD::Pg only for real DB reporting, and dummylib covers `--test`).
5. **First-boot build-pool hook** (see below) — makes `bfpool/pgbf` at `/pgbf` when a second volume is
   attached.
6. **nix-by-name** — `/etc/nix/registry.json` maps `nixpkgs` -> a re-locked pure by-name flake at
   `/root/by-name-flake-repo`; the fork nixpkgs + gnu-config FODs + solnix-pkgs inputs are all in the store.
   `nix profile install nixpkgs#<pkg>` resolves+builds by name (proven: coreutils 9.11 installed and ran).

## First-boot build-pool hook (the storage gotcha)

The AMI root zpool `spool` is a SMALL ~7.5 GiB slice (the fdisk/VTOC don't span the disk). **NEVER live-grow
the mounted root.** Instead the operator attaches a large second EBS volume; the animal auto-builds a
whole-disk build pool.

Implemented as an append to the proven metadata boot shim (`/usr/lib/metadata`), idempotent:
```
if no bfpool: find the first whole disk that is NOT the root disk and NOT in a pool ->
  zpool create -f bfpool <disk>;  zfs create -o mountpoint=/pgbf bfpool/pgbf;  chown pgbf /pgbf
else: ensure bfpool/pgbf dataset + mount + owner
```
PROVEN: on the build node, attaching a 100 GiB volume + rebooting created `bfpool` (99.5 G) with
`bfpool/pgbf` at `/pgbf` owned by pgbf, on the first boot after attach. (illumos enumerates new disks at
boot; if the attach races the boot-time hook, the hook re-runs every boot and also runs on the next reboot.)

NOTE: an earlier version used a standalone SMF service (`site/solnix-bfpool-setup`); it also worked, but was
moved into the metadata shim to avoid perturbing the SMF repository at bake time.

## THE UNRESOLVED ISSUE — cold-boot DHCP on the derived AMI

**The baked AMI boots to a login prompt with the entire stack present, but a cold-launched instance does not
acquire a DHCP lease** (console: `Hostname: unknown`, then `in.routed: route 0.0.0.0/8 nexthop is not
directly connected`), so SSH never comes up. This reproduced 10/10 across every derived AMI in this session,
on m5.large and m5.4xlarge, in the same subnet/SG where:

- the **10/10 base** (`ami-0f5ab5fac82d7cd1f`) cold-launches + DHCPs + SSHs in ~105–135 s (verified 3x), and
- the **build node itself reboots + DHCPs reliably** (~105 s, verified 3x) with the full animal stack.

So the regression is introduced by the `create-image` capture of the modified node, NOT by the base, the
animal software, the pool hook, or the subnet. Ruled out this session (each re-baked + re-verified):
- Root-pool space pressure (a near-full root DID separately wedge one node's *loader* with an OOM
  boot_archive — fixed by keeping ~630 MB free; but the DHCP miss persists at 630 MB free).
- Wrong base — rebuilt on the confirmed 10/10 base; still misses.
- A stale cached DHCP lease `/etc/dhcp/ena0.dhc` (baked the build-node's dead IP) — removed; still misses.
- The added SMF service — removed (hook moved into the metadata shim); still misses.

Strongest remaining hypothesis (not confirmed within budget): the metadata boot shim is
`svc:/system/illumos/metadata` = **transient**, and the live snapshot captures it `online`/complete, so on a
fresh boot SMF does not re-execute the shim's DHCP bring-up/recovery — while the 10/10 base was captured by
the ena-rx-coldboot-fix.md IN-PLACE boot_archive procedure whose snapshot state re-runs it. This matches that
doc's central finding: **the AMI-build METHOD dominates cold-boot DHCP reliability** (in-place = 8/10,
anything else = 0/10), and it required a very specific procedure that was not reproduced here.

Per the anti-wedge rule (the AMI fight exceeded 60 tool-uses), the bake was STOPPED with the pre-install and
runbook complete. The capability is fully proven on the live build node; the operator finishes via the
runbook below.

## OPERATOR RUNBOOK (durable account)

The reliable, proven path is to **launch the 10/10 base and apply the pre-install** (a few scripted minutes),
rather than depend on the DHCP-regressed baked AMI.

### A. Provision the animal
1. Copy the 10/10 base AMI to the durable account (`aws ec2 register-image` from a copied snapshot, or
   CopyImage): `ami-0f5ab5fac82d7cd1f` (solnix-ena-1010-v15) — cold-launch-verified reliable.
   (`solnix-builder-ena-verified-20260824-inplace` `ami-0978836610527a836` is the doc's canonical 8/10; the
   1010-v15 measured better here.)
2. Cold-launch it (`run-instances`, NOT stop/start — warm reboots can re-roll the cold-boot hang):
   `m5.4xlarge`+; it DHCPs + SSHs in ~2 min.
3. **Attach a large build volume at launch** (`--block-device-mappings` or `attach-volume --device
   /dev/xvdf`, 100 GiB+). Do NOT grow the mounted root.
4. Apply the pre-install on the box (all steps below are what this session ran + verified):
   ```
   pkg install developer/ccache library/perl-5/ipc-run-542
   useradd -m -d /export/home/pgbf -s /bin/bash pgbf
   mkdir -p /opt/pgbf && chown pgbf:staff /opt/pgbf
   su - pgbf -c 'cd /opt/pgbf && git clone --depth 1 https://github.com/PGBuildFarm/client-code.git'
   # build-farm.conf: cp the sample, set make=>gmake, build_root=>/pgbf/buildroot,
   #   config_opts=>[--enable-cassert --enable-debug --enable-tap-tests --without-icu]
   ```
   (If baking your own AMI from this box, use `create-image --no-reboot`; before you trust it for cold boot,
   cold-launch-verify SSH — and if it DHCP-misses, this is the open issue above; run the animal on the
   directly-provisioned box instead of a re-bake.)
5. Build pool: attach the volume + reboot; the first-boot hook makes `bfpool/pgbf` at `/pgbf`. Or manually:
   `zpool create -f bfpool <cNtMd0>; zfs create -o mountpoint=/pgbf bfpool/pgbf; chown pgbf /pgbf`.
   (`diskinfo` lists disks; the root pool disk is in `zpool status spool`.)

### B. Register a REAL animal (human step)
1. Register at https://buildfarm.postgresql.org -> get an animal NAME + SECRET.
2. Put them in `/opt/pgbf/client-code/build-farm.conf` (`animal`, `secret`).
3. Install `DBD::Pg` only if the server run needs it (`--test` does not).
4. Drop `--test`/`--nosend` so run_build.pl reports to
   `https://buildfarm.postgresql.org/cgi-bin/pgstatus.pl`.

### C. Run
```
su - pgbf -c 'cd /opt/pgbf/client-code && perl run_build.pl --test --verbose --config=build-farm.conf HEAD'
```
`--test` == `--nosend --nostatus --verbose --force` (local, no reporting). Proven: All stages succeeded
(docs/postgresql-buildfarm-client-on-solnix-verified.md); this session re-verified checkout->configure->build
on `/pgbf/buildroot`.

### D. nix-by-name upgrades (Goal 2)
`nix profile install nixpkgs#<pkg>` works by name (registry -> pure by-name flake). If a fresh image's
registry points at a missing `solnix-flake-pure` path, re-lock: copy
`pkgs/illumos/phase3/by-name-flake/{flake.nix,pkgs.nix}` to a writable dir, `nix flake lock`, and point
`/etc/nix/registry.json` `nixpkgs` -> that dir (the fork + gnu-config FODs + /root/solnix-pkgs must be in the
store; they are on the base). Verified this session: `nix eval nixpkgs#...coreutils.drvPath` resolves pure.

## Session artifacts

- Build node (LEFT RUNNING, full proven stack): `i-05cfec51676cd73c9` (solnix-pgbf-buildnode) @ 3.133.145.191.
- AMI (boots+stack, DHCP-regressed): `ami-05b9358e0aacc7bc3`.
- Progress log: /tmp/pgbf-ami-progress.txt.
