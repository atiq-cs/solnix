# solnix — Product Steering

Always-on context for any work in this repo. Read once per session.

## What solnix is

solnix is a distribution of **illumos** (the open-source Solaris/OpenSolaris
descendant) whose entire system — kernel, userland, services, packages — is
built, installed, configured, and upgraded with the **Nix** package manager and
the **NixOS module system**, exactly as NixOS does for Linux.

It is the illumos analog of **nixbsd** (Nix distribution of FreeBSD/OpenBSD by
rhelmot). solnix deliberately copies nixbsd's proven architecture and diverges
only where illumos forces it (SMF instead of rc, the Solaris link-editor instead
of GNU ld, `beadm`/ZFS boot environments instead of a plain rootfs).

## Goal (end state)

Everything that runs on illumos-gate — and the notable features added by its
forks (bhyve, LX-branded zones, zones, OpenZFS feature flags) — is available and
declaratively configurable on solnix. A user describes a machine in a Nix module
and gets a bootable, upgradeable, rollback-capable illumos system.

## Non-negotiable design pillars

1. **Reuse NixOS, don't reinvent it.** Copy `lib/eval-config.nix` and the module
   system verbatim; pull unmodified nixos modules by reference; fork only what
   illumos changes. (Same as nixbsd's `extPath` approach.)
2. **Fine-grained world.** The illumos "world" is many small per-component
   derivations (`pkgs.illumos.libc`, `.sys`, `.ld`, individual base tools), not
   one monolith. Compose them into `system-path`.
3. **SMF is the init system.** Services are defined via a `smf.services.<name>`
   module that generates SMF manifests + method scripts; `systemd.*` options are
   stubbed so unmodified nixpkgs modules still evaluate.
4. **RUNPATH, not `crle`.** Store paths are baked into ELF RUNPATH via the
   Solaris linker's `-R`. Do not depend on `crle`/`/var/ld` or GNU tooling
   (patchelf/readelf won't work — use `elfedit`/`elfdump`).
5. **ZFS boot environments are the generation mechanism.** A solnix "generation"
   maps onto a ZFS BE under `rpool/ROOT/<gen>`; the illumos `loader` menu lists
   them; rollback = boot the previous BE. `/nix/store` lives inside the BE.

## Honesty rules for this project

- Do not claim an architecture works before it boots. See `architectures.md`.
- Do not claim cross-from-Linux works for stage0 — it does not today. See
  `illumos-domain.md`.
- When a plan step depends on an unmerged upstream (aarch64 port, SPARC revival),
  say so and cite it. No hand-waving over multi-year kernel work.
