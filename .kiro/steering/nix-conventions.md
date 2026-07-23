# Nix & Repo Conventions

How solnix is structured and built. Mirrors nixbsd's proven layout so its
patterns (and, where possible, its code) transfer directly.

## Three-repo split (same as nixbsd)

solnix, like nixbsd, cannot live in one repo:

1. **`nixpkgs` fork** — adds the `*-illumos` platform(s) to the stdenv bootstrap
   and the `pkgs.illumos.*` fine-grained world (kernel, libc, Solaris `ld`, base
   tools). Based on a `staging`-like branch (stdenv changes force a full rebuild).
2. **`nix` fork (if needed)** — fixes to the Nix daemon/build for running natively
   on illumos (nixbsd needed a `cppnix` fork for FreeBSD; assume we will too).
3. **solnix** (this repo) — the NixOS-analog layer: forked evaluator, module tree,
   SMF init, image builders, sample configurations. Pulls the nixpkgs fork via an
   overlay/input.

Track upstream nixpkgs where possible; carry illumos changes as `patches/` +
inline build tweaks rather than forking illumos-gate itself (nixbsd does not fork
freebsd-src). illumos source is consumed upstream.

## Repo layout (target)

```
solnix/
  flake.nix              # entry; nixosConfigurations-equiv + image outputs
  lib/                   # forked NixOS evaluator + image builders
    eval-config.nix      #   near-verbatim copy of NixOS's
    make-disk-image.nix  #   raw/qcow2/vdi + GPT/UEFI
    make-be.nix          #   ZFS boot-environment image (illumos-specific)
    ...
  modules/
    system/boot/init/smf.nix     # THE init module (analog of freebsd-rc.nix)
    system/{activation,etc,service}/
    services/                    # solnix service modules
    nixos-compat.nix             # stub systemd.* so upstream modules eval
    module-list.nix
  pkgs/                  # solnix-only pkgs (world lives in the nixpkgs fork)
  overlays/              # wires in the nixpkgs fork + illumos overlay
  configurations/        # sample systems (base, server, zone-host, ...)
  docs/
  .kiro/steering/        # this dir
  .kiro/specs/           # per-milestone requirements/design/tasks
```

## Platform tuples

Design multi-arch from day one; wire only amd64 to a real toolchain in Phase 1:
`x86_64-illumos`, `aarch64-illumos`, `sparcv9-illumos`, `riscv64-illumos`.
(Confirm the canonical tuple spelling against the nixpkgs `lib.systems` parser —
illumos may want `-solaris` kernel + `illumos` variant; decide once, in the
nixpkgs fork, and document it here.)

## Build & test

- **Cross-build from a Linux (NixOS) builder** for everyday image builds
  (`config.nixpkgs.buildPlatform`), same as nixbsd — **once stage0 has produced
  the seed toolchain**. Stage0 itself must run on an illumos host (see
  `illumos-domain.md`). Do not conflate the two.
- Expect brutal build times and huge closures (nixbsd: minimal VM >8h, base
  closure >30 GiB). Keep `closureInfo` GC roots; use `--max-jobs`.
- Formatter: `nixfmt` (match nix-config's `nix-formatter-pack`/`nixfmt-tree`).
- Boot testing: QEMU for amd64/aarch64; SPARC needs an emulator or real T-series.

## Reuse discipline (ponytail)

- Before writing a module, check whether an unmodified nixos module can be pulled
  by reference (nixbsd's `extPath`). Fork only the delta.
- Copy nixbsd files directly where the logic is OS-agnostic (image builders,
  eval-config, activation). Attribute per their MIT license.
- No speculative abstraction. One arch, one init backend, one image type working
  end-to-end beats four half-wired ones.

## Commit / PR conventions

- Match the maintainer's house style (see nix-config `AGENTS.md`): present-tense
  imperative subject ≤72 chars; body explains *why*.
- Releases: date-based tags per the `release-tagging` skill when we get there.
- Keep changes to the nixpkgs fork on a clearly named branch; document the pin in
  `flake.nix` and here.
