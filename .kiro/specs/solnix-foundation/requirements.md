# Foundation Spec — Requirements (Phase 0–1)

Scope: everything needed to reach the Phase 1 gate — a cross-built amd64 solnix
image that boots in QEMU to the SMF `multi-user-server` milestone. amd64 only.
Governed by `.kiro/steering/`.

## R1 — Stage0 illumos build host
- **R1.1** A reproducible illumos build environment (OmniOS or OpenIndiana, VM or
  zone) is documented and scripted.
- **R1.2** illumos-gate builds via `nightly.sh` on that host, producing a proto
  area and the native toolchain (illumos-gcc, Solaris `ld`, CTF tools).
- **R1.3** The seed artifacts Nix needs (libc, headers, compiler, linker) are
  identified and extractable.

## R2 — Nix on illumos
- **R2.1** The Nix daemon + client build and run on the illumos host (fork if
  required; document the fork and its patches).
- **R2.2** A trivial derivation builds and its output lands in `/nix/store`.

## R3 — RUNPATH / linking model
- **R3.1** A build hook bakes `/nix/store` paths into ELF RUNPATH using the
  Solaris linker (`-R`), verified with `elfdump` — no `crle`, no GNU tooling.
- **R3.2** A binary so linked resolves its shared libs from the store at runtime
  via `ld.so.1`.

## R4 — nixpkgs fork: amd64 platform + world
- **R4.1** `x86_64-illumos` platform added to the nixpkgs fork's stdenv bootstrap
  (canonical tuple decided and documented).
- **R4.2** `pkgs.illumos.*` fine-grained derivations: `libc`, `sys` (kernel +
  genunix), `ld`, `ld.so.1`, and the minimum base tools to reach multi-user.
- **R4.3** stdenv on `x86_64-illumos` compiles a C program against store libc.

## R5 — Evaluator & module system
- **R5.1** NixOS `eval-config.nix` forked/adapted; `lib.evalModules` drives a
  solnix config.
- **R5.2** `nixos-compat.nix` stubs `systemd.*` (and other Linux-isms) so
  unmodified nixpkgs modules evaluate without error.
- **R5.3** Unmodified nixos modules can be pulled by reference (`extPath` style);
  forking is the exception, documented per-module.

## R6 — SMF init module
- **R6.1** `smf.services.<name>` module generates valid SMF manifests + method
  scripts.
- **R6.2** Activation imports manifests (`svccfg import`) and the system reaches
  the `multi-user`/`multi-user-server` milestone.
- **R6.3** `svcs` shows no services in maintenance/degraded on a base config.

## R7 — Image + boot
- **R7.1** An image builder produces a ZFS-root image with a boot environment
  under `rpool/ROOT/<gen>` and the illumos `loader`.
- **R7.2** The image boots in QEMU (UEFI) to multi-user.
- **R7.3** `/nix/store` lives inside the boot environment.

## R8 — Cross-build from Linux
- **R8.1** After stage0 seeds the toolchain, everyday image builds run on a Linux
  (NixOS) builder via `config.nixpkgs.buildPlatform`.
- **R8.2** The Phase 1 gate image is produced by the Linux cross path.

## R9 — Smoke test
- **R9.1** One runnable smoke test asserts the booted VM reached
  `multi-user-server`, `svcs` is clean, and a store-linked binary runs. This is
  the Phase 1 gate check.

## Out of scope (this spec)
Installer/live media, generation rollback UX, networking breadth, package
breadth, and all non-amd64 architectures — those are Phase 2+.
