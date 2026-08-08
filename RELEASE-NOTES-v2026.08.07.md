# solnix v2026.08.07 — first release

**solnix** is a Nix distribution of illumos: every package a real Nix derivation
(`nix-build` works, `nix-store --query --deriver` resolves), on a from-source
toolchain, booting on EC2 and installable on local hardware.

This is the **first solnix release** (edition: `unstable`, rolling). It is built
on **Nix 2.24.15** (not the bootstrap-only 2.3.16) — the maintainer directive for
the first release.

## What's in it

### Foundation — from source, no bootstrap artifacts
- **Nix 2.24.15** built from source as a real derivation (RUNPATH-correct, runs
  with no `LD_LIBRARY_PATH`), with 6 illumos patches. `nix` ships as a store
  package on `/run/current-system/sw/bin` (NixOS-style) — no versioned
  `/nix-tools<N>` on `PATH`.
- **GCC 14.4.0** from source; **Clang/LLVM 22.1.8** from source. Package builds
  use the illumos-gcc-10 stdenv (illumos-gate parity); gcc-14 and clang stdenvs
  available.
- Pure stdenv builds from the seed (stage0) natively on illumos.

### Packages — real hermetic derivations, host-free, in a signed cache
- **~509 distinct packages** (873+ store paths incl. dev/man/doc/debug splits):
  434 x86_64-solaris, 69 sparcv9-solaris, 6 aarch64-solaris.
- Core userland, C/C++ libraries, the **CMake** and **Meson** build graphs,
  the **python3 3.14.6 ecosystem** (on both x86_64 and real UltraSPARC),
  **gnutls** (real HTTPS), the self-hosting toolset (git/curl/openssh/vim/tmux/
  rsync), gdb 17.2, and more.
- All packages: real `.drv` (deriver resolves), host-free closure
  (`/nix/store` + the `/lib/64` libc-family ABI floor only), signed and served
  from `https://cache.solnix.io` (trusted key
  `cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=`).

### Images
- **EC2 AMI** `ami-0fdbde95dacf1fa04` (x86_64, identity-free) — verified to
  boot fresh from a cold launch to multi-user + SSH (the cold-boot loader
  `boot_archive` hash-verification loop is fixed).
- **ISO** (`solnix-x86_64-minimal.iso`, hybrid BIOS+UEFI, USB-dd-able) and
  **raw IMG** (ZFS-root) for local-hardware install — both QEMU-boot-tested,
  banked at `s3://solnix-cache/images/release-224-v2/`.

### Capabilities on a running system
- `nix profile install nixpkgs#<pkg>` works by name, no `--impure` (pure eval).
- **Non-root source builds** work (a non-root user can `nix build` from source,
  not just install prebuilt — Nix illumos patch #6, socketpair pty fallback).
- First-boot defaults: UTC + UTF-8, ipfilter firewall (default-deny + ssh),
  `sudo`→`pfexec`, coreadm no-core policy, NTP.
- Identity-free by default (no baked user); operator created at install.

## Architectures
- **x86_64-solaris** — primary; AMI + ISO + IMG; boots on EC2 (Nitro/ENA).
- **sparcv9-solaris** — self-hosting on real UltraSPARC hardware (69 packages
  incl. python3, gnutls, the dev toolset).
- **aarch64-solaris** — cross-built (GATE 1b-PURE cross); boots QEMU-virt +
  devicetree ARM boards. Graviton pending upstream illumos-aarch64 GICv3/ACPI.
- **riscv64-solaris** — port in progress.

## Known limitations
- The AMI ships the from-source nix; the non-root-build patch (#6) reaches the
  default `sw/bin/nix` in the next image rebuild (v3, in progress) — on this
  release it is available via the per-user profile.
- Graviton (aarch64 on EC2) is blocked on upstream illumos-aarch64 GICv3+ACPI.
- Some large subtrees (Rust/Go/Haskell toolchains, GTK) are not yet packaged.

## Using it
- Launch the AMI (x86_64, EC2 us-east-2), or `dd` the ISO to USB / write the raw
  IMG to a disk for local hardware.
- The system substitutes packages from `https://cache.solnix.io`.
- `nix profile install nixpkgs#<name>` to install; `nix build` to build from
  source.

Docs: https://solnix.io
