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

## === NATIVE-BOOT CAMPAIGN (multi-week, approved) ===
# The cross-build role (A1-A3) WORKS: 218 aarch64-solaris store paths, cross toolchain builds, EM_AARCH64
# verified. The NATIVE-boot track (a bootable aarch64 solnix instance) is the campaign. Verdict from the
# readiness assessment: native Graviton/EC2 = BLOCKED at the illumos port (GICv3/ACPI/Nitro, months
# upstream); QEMU-virt (GICv2/devicetree) is the port's real, feasible target. So the campaign boots QEMU
# FIRST, then tackles the Graviton platform gaps.

## A4 — Build the arm64-gate KERNEL (the missing artifact)  [DONE: unix/genunix AArch64 verified]
# The cross toolchain builds but `make illumos` (unix/genunix for aarch64) was never completed. Do the full
# arm64-gate build on a dedicated amd64-illumos host: fetch richlowe/illumos-gate@arm64-gate + the arm64-gate
# tooling, satisfy its build-env (Python 3.13 for sgs, the right nightly.sh/env), run `make illumos` to
# produce aarch64 unix/genunix + the base kmods + a proto. Gate: an aarch64 illumos kernel binary exists +
# nm-verifies as EM_AARCH64. (Big bootstrap: ~7GB tree, multi-hour build, its own toolchain reqs.)

## A5 — Boot solnix-aarch64 in QEMU-virt  [DONE: booted to a root shell; SunOS braich 5.11 aarch64. Recipe + osnet-incorporation fix in docs/aarch64-A5-qemu-boot-ACHIEVED.md]
# Assemble the arm64-gate boot artifacts (u-boot.bin + an illumos-disk.img/boot_archive with the A4 kernel +
# the A3 cross-built userland) and boot under qemu-system-aarch64 -M virt,gic-version=2 -cpu cortex-a72.
# Gate: solnix-aarch64 reaches multi-user + a shell in QEMU. This is the first BOOTABLE aarch64 solnix.

## A6 — The Graviton/Nitro platform port  [IN PROGRESS: GICv3 CLEARED (boots to shell); ACPI = a ~2-4wk handoff shim (NOT months -- port is already dual-mode FDT/ACPI, blocked on one spin-halt in dboot_machdep.c + an ACPI-fed prom_emul); ena/nvme aarch64 kmods BUILT; VERIFIED on real c6g.metal silicon: EDK2->illumos EFI loader->ZFS armpool root->Loading unix->the ACPI spin-halt. Revised scope ~2-4wk, not months.]
# Make arm64-gate illumos boot on real AWS Graviton (m7g/c7g). The three blockers (from the assessment):
#   1. GICv3 interrupt controller (Graviton) vs the port's GICv2 -> write/port a GICv3 driver.
#   2. ACPI platform enumeration (Nitro) vs the port's devicetree -> an ACPI bring-up path.
#   3. Nitro ena (net) + nvme (disk) drivers on aarch64 illumos (the x86 ena work is a partial crib; nvme
#      needs an aarch64 driver). Gated behind #1.
# Gate: solnix-aarch64 boots on a Graviton instance + networks (the aarch64 analog of the x86 10/10 boot).

## A7 — The aarch64 build-farm animal + AMI
# Once A6 boots: bake an aarch64 solnix AMI, wire the by-name nix channel (Goal 2, same mechanism as x86),
# prove PG builds on aarch64 (Goal 3), register the buildfarm animal. Also fix the ELFOSABI_NONE vs
# ELFOSABI_SOLARIS final-link flag (full ABI parity) noted in the assessment.
