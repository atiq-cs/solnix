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

## No IPS/`pkg` in the end product (non-goal to keep it)

solnix **replaces** illumos's Image Packaging System (IPS — the `pkg` command,
`pkg.depotd`, publishers, FMRIs) with Nix. The finished solnix system has **no
`pkg`, no IPS, no `pkg.depotd`, no publishers** — every package is a Nix
derivation in `/nix/store`, resolved by the Nix dependency graph and served from
the solnix.io binary cache. What IPS does maps onto Nix:

| IPS does | solnix uses instead |
|----------|---------------------|
| `pkg install` into a live `/` | immutable `/nix/store` + symlink farms |
| IPS manifests + SAT solver | Nix derivations + dependency graph |
| publishers / `pkg.depotd` | solnix.io substituters (binary cache) |
| `pkgdepend` (ELF NEEDED scan) | RUNPATH closure |
| atomic upgrade + rollback | Nix generations ↔ ZFS boot environments |

**Bootstrap exception (fine, unavoidable):** we *use* the upstream OpenIndiana
host's `pkg` to install build prerequisites (gcc, onbld, headers) when standing
up a build host — exactly as NixOS uses a Debian/other builder's package manager
to bootstrap. That does not make IPS part of solnix, and it disappears entirely
once the nixpkgs fork can build the world.

**Consequences for the work:**
- We consume the illumos-gate **proto area** (staged filesystem), NOT IPS
  packages, to build `pkgs.illumos.*` and the seed. A failing IPS *packaging*
  step in the gate build is **out of scope / a non-goal to fix** — do not spend
  effort on it (e.g. the Perl per-arch-path / msgcc packaging failures).
- The IPS **`driver`/`user`/`group` "actions"** (device-driver registration via
  `name_to_major`/`driver_aliases`, account creation) are the one hard,
  least-NixOS-like thing IPS does. solnix must **reimplement** these as Nix
  modules (a driver-registration module, the users module) — this is replacing
  IPS, not keeping it.

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
