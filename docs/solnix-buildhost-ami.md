# solnix-buildhost AMI (the persistent build substrate)

Maintainer-approved (2026-10-11): one reusable AMI so every build/GPU stream skips
the ~1h OpenIndiana 2025->2026 pkg-update + toolchain-install tax.

## The AMI (CLEAN, boot-verified -- use THIS one)
- id: **ami-0aa1f6ac952e3408d**  (solnix-buildhost-x86-clean-20261012, us-east-2,
  kiwi 830118047484, x86_64/uefi, Project=solnix)
- snapshot: snap-05ac68deae082b989
- boot-verified: a FRESH launch gets a DHCP lease (ena0/dhcp ok), SSHes (key
  solnix-baked, root), has internet, re-runs the lavapipe proofs PASS.
- baked the RIGHT way (the fix for the broken predecessor): R2 networking-good
  base -> provision -> SCRUB instance state (devid/nodename/ssh-keys/dhcp/nwam) ->
  STOP -> image-from-stopped -> boot-verify a fresh launch networks. Recipe +
  provisioning in scripts/build-mesa-lavapipe-illumos.sh era + the infra report
  /tmp/solnix-io-buildhost-ami-report.md.

### DO NOT USE: ami-0e344991f2f44b11d (BROKEN)
The earlier solnix-buildhost-2026-20261011 was create-image'd from a RUNNING
MUTATED instance and baked a stale device identity: it boots illumos but ENA
NEVER attaches -> no network, SSH times out, "Hostname: unknown". Confirmed over
many launches by 3 independent streams (GPU, aarch64, RISC-V). Deregister it.
The LESSON: a build-host AMI must be clean-baked (scrub + image a STOPPED
instance + boot-verify a fresh launch networks) -- never create-image a running one.

### Legacy content (toolchain shape -- the clean AMI carries the same tools)
- base: OpenIndiana Hipster realigned to the 2026 catalog (via pkg update)
- toolchain: gcc 14.3.0 (/usr/gcc/14), gmake 4.4.1, cmake 4.4.4, gnu-tar/coreutils,
  onbld, gcc-10, autotools/bison/flex/git
- nix: 2.24.15 at /usr/local/bin/nix and /root/nix-tools/bin/nix
- /nix/store seeded: gate proto s7zkx8nx...-illumos-gate-proto + the from-source
  toolchain closures (store-optimised)
- /etc/nix/nix.conf: cache.solnix.io + cache.nixos.org (8UNr key), flakes +
  fetch-closure, sandbox=false
- ssh: root with the baked key (~/.ssh/solnix-lava.pem.AMI-BAKED-still-works on floki)

## Usage (zero provisioning)
    AWS_PROFILE=kiwi aws ec2 run-instances --region us-east-2 \
      --image-id ami-0aa1f6ac952e3408d --instance-type c5.4xlarge \
      --key-name solnix-baked --security-group-ids <operator-/24 SG> \
      --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=<stream>-<date>},{Key=Owner,Value=gregburd}]'
Then: ssh root@<ip> with the baked key -> `nix build` / `gmake` work immediately.

## First-use TODO for DRIVER compile gates (not needed for Nix package builds)
Add an illumos-gate source tree for ILLUMOS_SRC:
    curl -L github.com/illumos/illumos-gate/archive/master.tar.gz | gtar xz -C /root
(the nvidia-oss / i915 off-hardware `gmake objs` gates need -I usr/src/uts/{i86pc,intel,common})

## Rebake
When the toolchain/gate proto moves: launch from this AMI (or a bare OI), update,
nix store optimise, then create-image a new solnix-buildhost-2026-<date>; update this doc.

## Per-arch build-host AMIs (update 2026-10-13)

The build-host story has been corrected several times; the honest current state:

### aarch64 cross-build host -- READY (boot-verified both ways)
- id: **ami-06583907ca11a0ab1** (solnix-arm64-buildhost-20261013, us-east-2 kiwi,
  x86_64 host that CROSS-builds aarch64, key solnix-baked, Project=solnix)
- clean-baked (scrub instance state -> stop -> create-image) and BOOT-VERIFIED on a
  FRESH launch: networks (ena/dhcp) + SSHes + cross-compiles aarch64 ELF + `bldenv
  -T aarch64` drives a `unix` build. Carries the arm64-gate cross tree (gate
  @6cd2521c1e + a6 fixes + drain-drop + SError-vector), build/cross + build/sysroot
  + stamps, the banked proto/seed/braich-libs/driver-tables, and the assembly
  scripts. This is the durable arm64 cross-build substrate (ends the
  lost-to-closed-accounts problem for arm64).

### x86_64 flake-nix build host -- IN PROGRESS (being clean-baked)
- NEITHER prior x86 AMI is complete: ami-0e344991f2f44b11d has nix 2.24.15 + gate
  proto + toolchain but does NOT network; ami-0aa1f6ac952e3408d
  (solnix-buildhost-x86-clean-20261012) networks but is the Mesa/GPU host (only
  pre-flakes nix-2.3, empty store, no gate proto). A COMPLETE x86 build-host AMI
  (networks AND flake-`nix build` AND gate proto) is being clean-baked by the
  installer-rebuild work (combine the networking base + the baked toolchain store).
  Until it is boot-verified BOTH ways on a FRESH launch, treat x86 substrate as
  not-yet-solved; use the combine-recipe in the meantime.

RULE (learned the hard way, 3x): a build-host AMI is only "done" when a FRESH
launch is boot-verified to BOTH network AND build (nix/bldenv) -- never trust a
create-image of a running mutated instance, and never trust the filename.
