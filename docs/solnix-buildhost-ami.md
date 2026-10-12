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
