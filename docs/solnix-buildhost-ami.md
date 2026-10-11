# solnix-buildhost AMI (the persistent build substrate)

Maintainer-approved (2026-10-11): one reusable AMI so every build/GPU stream skips
the ~1h OpenIndiana 2025->2026 pkg-update + toolchain-install tax.

## The AMI
- id: ami-0e344991f2f44b11d  (us-east-2, account kiwi 830118047484)
- name: solnix-buildhost-2026-20261011
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
      --image-id ami-0e344991f2f44b11d --instance-type c5.4xlarge \
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
