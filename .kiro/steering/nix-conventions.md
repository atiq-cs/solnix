# Nix & Repo Conventions

How solnix is structured and built. Mirrors nixbsd's proven layout so its
patterns (and, where possible, its code) transfer directly.

## Three-repo split (same as nixbsd)

solnix, like nixbsd, cannot live in one repo:

1. **`nixpkgs` fork** — adds the `*-illumos` platform(s) to the stdenv bootstrap
   and the `pkgs.solnix.*` fine-grained world (kernel, libc, Solaris `ld`, base
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
`solaris2.11` triple. The distro-level Nix package namespace is **`pkgs.solnix.*`**
(see "Package namespace" below), and an `examples.x86_64-illumos` alias carries
the same config. Future arches follow the same pattern: `aarch64-solaris`,
`sparcv9-solaris`, `riscv64-solaris` (wired in Phase 3/4/5).

## Package namespace (canonical)

- **All solnix packages live under `pkgs.solnix.<name>`** — both the OS "world"
  (`pkgs.solnix.libc`, `.sys`, `.ld`, `.rtld`, `.systemPath`, `.gcc14`, `.clang`)
  and userland (`pkgs.solnix.perl`, `.python313`, `.zlib`, `.cmake`, …). One
  namespace = the distro's name. Do NOT use `pkgs.illumos.*` (it conflates the
  OS internals with the distro; the *platform* is `x86_64-solaris`, but the
  *packages* are solnix's).
- **Store-path names are plain `<pname>-<version>`** (e.g. `perl-5.42.0`,
  `libc-...`) — NO `solnix-`/`illumos-` prefix. The store hash already
  disambiguates; prefixes are noise (nixpkgs doesn't prefix `nixos-`). `pname`
  stays the upstream name.
- Optional sub-grouping is fine (`pkgs.solnix.world.libc`) if the set grows, but
  the top namespace is always `solnix`.
- (Historical note: early work used `pkgs.illumos.*` + `solnix-`/`illumos-` store
  prefixes — renamed to this convention; a cache republish followed.)

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

## Debug symbols (separate output, cached)

Every userland package (mk-userland-pkg.nix) splits DWARF into a separate
`debug` output (separateDebugInfo default true): objcopy --only-keep-debug ->
$debug/lib/debug/.build-id/<xx>/<rest>.debug, --strip-debug the binary (KEEP CTF
for mdb/dtrace), --add-gnu-debuglink. The `debug` output is a distinct store
path, cached+signed alongside `out`; consumers pull it only when debugging.
This is the "separate packages that combine to debug" requirement. Toolchain:
GNU binutils objcopy from gcc14 (Solaris objcopy lacks the flags).

## Package metadata index (EDN / pg_mentat) — OWNED BY THE solnix.io TEAM

Package metadata + relationships (deps, arch coverage, build provenance) are the
solnix.io team's domain: pg_mentat (a Datomic-compatible Datalog engine in
Postgres on the solnix.io hub) ingests facts from the narinfos the build farm
pushes. See ~/ws/solnix.io/infra/docs/package-facts-edn.md (their canonical
schema) — do NOT generate EDN in this repo.

Build team's only responsibility: ensure the cache narinfos are complete and,
if the provenance handoff is adopted (~/ws/solnix.io/infra/docs/handoff/
build-provenance-facts.md), stamp compiler/compilerVer/libcVer/debugPath at
publish time in the sidecar format their ingester wants. No per-package EDN
files here.
