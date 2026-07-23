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

Design multi-arch from day one; wire only amd64 to a real toolchain in Phase 1.

**Decided (see `docs/design-nixpkgs-illumos.md`):** the canonical Nix system is
**`x86_64-solaris`** (GNU triple `x86_64-unknown-solaris2.11`), NOT a new
`x86_64-illumos` kernel. Rationale: nixpkgs *already* ships `kernels.solaris`,
`isSunOS`, the `x86_64-solaris` double, an `illumos` doubles group, and
`ld-solaris-wrapper.sh` — so this is a small diff, and autotools/gcc demand the
`solaris2.11` triple. We brand "illumos" only at the Nix-attribute layer
(`pkgs.illumos.*`, and an `examples.x86_64-illumos` alias with the same config).
Future arches follow the same pattern: `aarch64-solaris`, `sparcv9-solaris`,
`riscv64-solaris` (wired in Phase 3/4/5).

## Build & test

- **Cross-build from a Linux (NixOS) builder** for everyday image builds
  (`config.nixpkgs.buildPlatform`), same as nixbsd — **once stage0 has produced
  the seed toolchain**. Stage0 itself must run on an illumos host (see
  `illumos-domain.md`). Do not conflate the two.
- Expect brutal build times and huge closures (nixbsd: minimal VM >8h, base
  closure >30 GiB). Keep `closureInfo` GC roots; use `--max-jobs`.
- Formatter: `nixfmt` (match nix-config's `nix-formatter-pack`/`nixfmt-tree`).
- Boot testing: QEMU for amd64/aarch64; SPARC needs an emulator or real T-series.

## Reuse discipline

- Before writing a module, check whether an unmodified nixos module can be pulled
  by reference (nixbsd's `extPath`). Fork only the delta.
- Copy nixbsd files directly where the logic is OS-agnostic (image builders,
  eval-config, activation). Attribute per their MIT license.
- No speculative abstraction. One arch, one init backend, one image type working
  end-to-end beats four half-wired ones.

## Comment style

- Do **not** use `ponytail:`-prefixed comments (or the word "ponytail") anywhere
  in the repo — code, docs, steering, or commit messages. Write deferrals as
  plain `TODO(<phase>):` notes or ordinary prose explaining what's deferred and
  why. Keep the substance, drop the label.

## Commit / PR conventions

- Match the maintainer's house style (see nix-config `AGENTS.md`): present-tense
  imperative subject ≤72 chars; body explains *why*.
- Releases: date-based tags per the `release-tagging` skill when we get there.
- Keep changes to the nixpkgs fork on a clearly named branch; document the pin in
  `flake.nix` and here.
