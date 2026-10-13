# solnix-buildhost AMI (the persistent build substrate)

Maintainer-approved (2026-10-11): one reusable AMI so every build/GPU stream skips
the ~1h OpenIndiana 2025->2026 pkg-update + toolchain-install tax.

## The AMI (COMPLETE: networks AND nix-builds -- use THIS one)
- id: **ami-0bd0fa73200305fd1**  (solnix-buildhost-x86-COMPLETE-20261013, us-east-2,
  kiwi 830118047484, x86_64/uefi, Project=solnix)
- boot-verified (2026-10-13, the completeness gate): a FRESH c5.2xlarge launch
  (1) NETWORKS -- ena0 up inside illumos, SSHes (key solnix-baked, root), internet
  reaches cache.solnix.io (200); AND (2) NIX-BUILDS A FLAKE -- nix 2.24.15 with
  flakes, gate proto s7zkx8nx...-illumos-gate-proto in the store, `nix build` of a
  flake output succeeds (BUILD_RC=0). This is the networking + full-toolchain host
  every x86 stream actually needs, in one AMI.
- carries: nix 2.24.15 (/usr/local/bin/nix) + gate proto + from-source gcc-14
  toolchain + a warm /nix/store with the HEAD solnix installer closures.
- clean-baked the RIGHT way: start from the ami-0e34 lineage (which DOES carry
  nix+gate+toolchain), prove it networks AND nix-builds on a fresh launch, then
  SCRUB instance state (ssh host keys / nodename / dladm+ipadm persistent conf /
  devid caches / zpool.cache / logs+history) -> export any scratch pool + detach
  its volume -> STOP -> image-from-STOPPED -> boot-verify a fresh launch networks
  AND nix-builds. (Built by the streamREBUILD installer-image run, 2026-10-13.)

### PARTIAL AMIs -- each is missing half; do NOT reach for them directly
- **ami-0aa1f6ac952e3408d** (solnix-buildhost-x86-clean-20261012): NETWORKS + has
  gcc/clang/meson, but it is the **Mesa/lavapipe GPU build host** -- it has NO
  flake-capable nix (only a pre-flakes nix-2.3.16 tarball at /root), an EMPTY
  /nix store, and NO gate proto. `nix build .#solnixConfigurations...` CANNOT run
  on it as-is. (This doc previously listed it as THE build host with "nix 2.24.15
  + gate proto" -- that was wrong; those are not baked here. Use it for GPU work.)
- **ami-0e344991f2f44b11d** (solnix-buildhost-2026-20261011): has nix 2.24.15 +
  gate proto + from-source gcc-14 toolchain, and -- CONTRARY to this doc's earlier
  "ENA never attaches" claim -- it DID network on a fresh c5.4xlarge launch
  (2026-10-13): ena0 up, DHCP, internet. The networking defect reported by the
  GPU/aarch64/RISC-V streams was not reproduced this launch (possibly
  instance-type or AZ specific). It remains the toolchain source the COMPLETE AMI
  above was baked from; prefer the COMPLETE AMI, which is boot-verified for BOTH
  networking and nix-build.
The LESSON stands: a build-host AMI must be clean-baked (scrub + image a STOPPED
instance + boot-verify a fresh launch) -- and the verify must prove BOTH networking
AND a flake nix-build, not just one of them. An AMI that networks but cannot
nix-build (the GPU host) is as unusable for package work as one that cannot network.

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
      --image-id ami-0bd0fa73200305fd1 --instance-type c5.4xlarge \
      --key-name solnix-baked --security-group-ids <operator-/24 SG> \
      --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=<stream>-<date>},{Key=Owner,Value=gregburd}]'
Then: ssh root@<ip> with the baked key -> `nix build` of a solnix flake works
immediately (nix 2.24.15 + gate proto baked; set SOLNIX_GATE_PROTO=/nix/store/
s7zkx8nx5sfxixmyqmlnrybrrh14jkmb-illumos-gate-proto and build --impure).

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

### x86_64 flake-nix build host -- DONE (clean-baked + boot-verified 2026-10-13)
- **ami-0bd0fa73200305fd1** (solnix-buildhost-x86-COMPLETE-20261013) is the
  complete x86 build host: a FRESH launch is boot-verified to BOTH network (ena0
  up, internet) AND flake-`nix build` (nix 2.24.15 + gate proto s7zkx8nx in store,
  BUILD_RC=0). See "The AMI" at the top. Use this; do not reach for either partial.
- Why neither prior x86 AMI was complete: ami-0e344991f2f44b11d has nix 2.24.15 +
  gate proto + toolchain (and DID network on a fresh c5.4xlarge launch 2026-10-13,
  contrary to the old "never networks" claim), it is the lineage the COMPLETE AMI
  was baked from; ami-0aa1f6ac952e3408d (solnix-buildhost-x86-clean-20261012)
  networks but is the Mesa/GPU host (only pre-flakes nix-2.3, empty store, no gate
  proto -- cannot nix-build solnix flakes).

RULE (learned the hard way, 3x): a build-host AMI is only "done" when a FRESH
launch is boot-verified to BOTH network AND build (nix/bldenv) -- never trust a
create-image of a running mutated instance, and never trust the filename.
