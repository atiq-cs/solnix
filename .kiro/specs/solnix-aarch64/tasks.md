# solnix aarch64 bootstrap

Bring up solnix on aarch64, mirroring the x86_64 path. Per the architecture
steering: aarch64 illumos is a REAL but OUT-OF-TREE port (Rich Lowe's richlowe/arm64-gate, backed by illumos IPD 24), not
in illumos-gate. So this is fundamentally harder than x86_64 — it's not just a
rebuild, it's integrating an unmerged illumos fork. Start the bootstrap now,
in parallel with x86_64 breadth; expect it to be a long track.

## Reality (from .kiro/steering/architectures.md)

- aarch64 illumos = Rich Lowe's richlowe/arm64-gate (+ illumos-gate@arm64-gate), actively maintained (IPD 24); QEMU virt/RPi4/Odroid-C2,
  cross-built from an amd64 illumos host. NOT upstream. Real code, not
  production, not merged.
- So the x86_64 recipe (build OI gate → seed → Nix world) does NOT directly
  apply: there is no OI aarch64 cloud image and no in-gate aarch64.

## A1 — Assess the aarch64 illumos port (research)

- DONE (A1): the port is richlowe/arm64-gate + richlowe/illumos-gate@arm64-gate. Build
  method (cross from amd64 illumos per the port's docs), what boots (QEMU virt?
  RPi?), toolchain (its gcc), how complete the userland/world is, license/state.
- Decide the solnix substrate: an aarch64 EC2 instance (Graviton, ARM Nitro) as
  the build/test host — but can illumos-aarch64 even boot on Graviton, or only
  QEMU? Likely QEMU-on-an-ARM-EC2-host first (Graviton runs Linux; QEMU aarch64
  guest runs the illumos-aarch64 port). Establish the substrate.

## A2 — Build the aarch64 illumos port

- Stand up the port's build (cross from an amd64 illumos host — reuse our x86_64
  build host, or a dedicated one). Produce an aarch64 illumos-gate proto +
  toolchain, analogous to our x86_64 gate build. Capture as a reproducible
  recipe (like oi-gate-build.sh).
- Gate: an aarch64 illumos proto area exists; the aarch64 gcc compiles a hello.

## A3 — aarch64 seed + Nix world

- Extract an aarch64 seed toolchain (like oi-extract-seed.sh) from the port's
  proto. Add `aarch64-solaris` (triple `aarch64-unknown-solaris2.11`) to the
  nixpkgs fork's lib.systems (mirror the x86_64-solaris wiring, agent-verified
  pattern). Bootstrap an aarch64 stdenv from the seed; slice the world
  (pkgs.illumos.* for aarch64) with RUNPATH relocation.
- Gate: a hello compiled by the aarch64 Nix toolchain runs on the aarch64
  illumos guest (QEMU), resolving libc from /nix/store.

## A4 — aarch64 boot + image

- make-be for aarch64: the port's boot path (u-boot/UEFI + the aarch64 loader/
  kernel), boot_archive, SMF. Produce a bootable aarch64 solnix image.
- Gate: aarch64 solnix boots to multi-user in QEMU (RPi/Graviton later).

## Method

- Contribute fixes upstream to the aarch64 port where we hit bugs.
- This track runs in parallel with x86_64 Phase 3 breadth but is expected to be
  much slower (unmerged fork, QEMU-only boot initially). Honest milestones:
  proto builds → seed → hello runs → boots in QEMU. Do NOT claim "aarch64
  supported" until it boots to multi-user (per the architecture steering's
  supported-means-boots rule).
