# The build toolchain in the dixi closure and the installer image

What the "build host in the image" capability ships, what it deliberately does
not, the closure-size cost, and the two blockers (Rust, Mesa) that are infra /
follow-on work rather than something this wiring can resolve.

Measured on dixi (`SunOS 5.11 solnix`, native x86_64-illumos, Nix 2.24.15),
2026-10-11, by stream DEVTOOLS, as a client of cache.solnix.io.

## Why solnix ships a compiler at all (unlike NixOS)

NixOS's base system and minimal ISO carry no compiler — a NixOS box substitutes
binaries from cache.nixos.org, and if it builds, `nix` pulls `stdenv` (a store
compiler) on demand. A solnix system cannot fall back that way: the historic
builders assumed an OpenIndiana build host with `/usr/gnu` and `/usr/gcc`, and an
installed solnix system has neither (`docs/pending/builders-need-store-tools.md`:
`sha256sum`/`gmake`/`gcc` are all absent, so `nix build .#…` dies in seconds).
Until a store-tool stdenv lands, the only way an installed solnix system can
build its own packages is to carry the toolchain explicitly. The maintainer
directive is therefore to ship it on the image.

## What is included — `pkgs.solnix.solnix-dev-full`

A `buildEnv` symlink-farm (`pkgs/illumos/default.nix`) over four from-source
derivations, all built by solnix from source (`pkgs/illumos/base-src.nix`), so
the media stays reproducible-from-source:

| tool | provides | source pkg |
|---|---|---|
| gcc wrapper 14.3.0 | `cc`, `gcc`, `g++`, `cpp` (sysroot = the gate proto) | `gccWrapper` (over `gcc-src.nix`) |
| binutils 2.46.1 | `as`/`gas` (the assembler the gate lacks), `gar`/`gnm`/`gstrip`/`gobjdump`/`greadelf` | `binutils` |
| GNU make 4.4.1 | `make`, `gmake` | `gnumake` |
| pkgconf 2.3.0 | `pkgconf`, `pkg-config` (library-flag resolution) | `pkgconf` (NEW this change) |

The link-editor (`ld`), `ar`/`nm`/`strip` are the gate's, already in every system
profile; headers, crt objects and libc come from gcc's sysroot (the gate proto).
This is the solnix analog of nixpkgs' `stdenv.cc`.

`pkgs.solnix.solnix-dev` (gcc + binutils + make, no pkg-config) stays as the
smaller toolchain; `solnix-dev-full` is the superset wired into images.

## Where it is wired

- **dixi** (`~/ws/nix-config/nixos/solnix/dixi.nix`): added to
  `environment.systemPackages`, so after a `switch` the maintainer's workstation
  has `cc`/`gcc`/`g++`/`as`/`make`/`gmake`/`pkg-config` on PATH.
- **installer media** (`configurations/installer.nix`): added to the installer's
  `systemPackages`, so the booted installer/live system can rebuild solnix
  packages on the image. All four are real from-source derivations, so this does
  **not** break the installer's "every package reproducible from source, no
  cache-only paths" invariant.

## Closure-size cost (measured on dixi)

`solnix-dev` closure = **~1168 MB** (`nix path-info -S`). The breakdown
(`nix path-info -rS`, largest first):

| path | bytes |
|---|---|
| gcc-14.3.0 | 1 158 176 320 (~1.08 GB) |
| illumos-gate-proto | 679 840 760 (~648 MB — **shared** with the base system, not new) |
| binutils-2.46.1 | 65 364 296 (~62 MB) |
| gnumake-4.4.1 | 46 847 024 (~45 MB) |
| gcc-14.3.0-lib | 45 882 080 (~44 MB) |
| libc | 38 381 384 (~37 MB — shared) |

`solnix-dev-full` adds **pkgconf (~1–2 MB)** on top. The gate proto and libc are
already in every solnix closure, so the *new* bytes a system pays for the
toolchain are dominated by **gcc (~1.1 GB) + binutils + make (~110 MB)** — roughly
**1.2 GB new** per image. The maintainer accepted this: a build host is large by
nature, and gcc is the irreducible core of "rebuild everything on the image."

## Proof (dixi, 2026-10-11)

Runtime, from the installed `solnix-dev` store path (PATH = `$DEV/bin:/usr/bin:/usr/sbin`):

```
$ gcc --version   → gcc (solnix 14.3.0) 14.3.0
$ make --version  → GNU Make 4.4.1
$ gas --version   → GNU assembler (GNU Binutils) 2.46.1
$ gcc -O2 -o hello hello.c && ./hello
hello from gcc on illumos
$ file hello
hello: ELF 64-bit LSB executable AMD64 Version 1, dynamically linked
$ make           → make-works
```

Eval (dixi, against the real gate store path `s7zkx8nx…-illumos-gate-proto`):

```
solnix-dev-full → /nix/store/b6nknp8b8dhrpr512z8mmbxdxvj7a37p-solnix-dev-full.drv
pkgconf         → /nix/store/xlar05w4pjiyvzshizp6py6ar4x1qa00-pkgconf-2.3.0.drv
```

Eval (floki, `--override-input solnix ~/ws/solnix`): both
`solnixConfigurations.dixi` and `.installer` list `solnix-dev-full` in
`config.environment.systemPackages`.

## Deliberately NOT included — and why

### autoconf / automake / libtool — need a from-source perl first

autoconf and automake are perl programs. An installed solnix system has **no
`/usr/bin/perl`** (measured on dixi), and `base-src.nix` has no perl package, so
even if the autotools built they could not run. m4 *is* present (illumos ships
`/usr/bin/m4`), so once a from-source perl lands, adding
autoconf/automake/libtool is straightforward.

In practice this is a smaller gap than it looks: almost every release tarball
ships a **pre-generated `./configure`**, so `gcc` + `make` + `pkg-config`
(the set above) already build the common autotools-packaged source *without*
autoconf/automake/libtool present. Those are only needed to regenerate a build
system from `configure.ac`/`Makefile.am` or to build straight from a VCS
checkout. pkgconf itself proves this: its tarball carries a generated
`./configure` and builds with only the cc + make.

**Follow-on work item:** add `perl` + `m4` + `autoconf` + `automake` + `libtool`
as from-source `mkSrcPkg` derivations in `base-src.nix`, then extend
`solnix-dev-full`'s `paths`.

### Rust (cargo / rustc) — the cached seed is a retired-payload stub (infra P1)

The seed documented as cached,
`/nix/store/8daydacsqmkzi72zfa3dmi9pp98d6hmj-rust-illumos-1.97.1`
(`real-derivations-224.tsv`, `published`), realises from cache.solnix.io
(narinfo 200) but is a **2.1 KiB wrapper only**. Its `rustc`/`cargo` `exec` into
`/nix/store/q3r5dh1m5ylwkpd9w6jk6ivqd3m3ic05-rust-seed-stage` (the 288 MB payload),
which is:

- **not a declared Nix reference** of the wrapper (bare string in the shell
  script; the wrapper's narinfo `References:` lists only itself), so Nix never
  fetches it; and
- **404 on cache.solnix.io** — it was retired on 2026-10-05
  (`docs/registry/CACHE-RETIRE-20261005.tsv`: `not-installable`, RUNPATH outside
  `/nix/store` + unresolved NEEDED) and never re-published.

So on dixi `rustc --version` → `exec: …/rust-seed-stage/bin/rustc: not found`, and
`nix-store --realise` of the payload → `don't know how to build these paths`.
Full measured evidence + the fix infra must apply:
`/tmp/solnix-io-rust-seed-retired-report.md`.

**Can we build Rust from source instead?** No — not on dixi, and not this round:

- Rust on illumos is bootstrapped *entirely* from a stage0 rustc binary. There is
  no rustc on illumos outside (a) the retired `rust-seed-stage`, and (b) the
  OpenIndiana IPS package `developer/lang/rustc@1.97.1` that the original
  bootstrap extracted via `pkg image-create` on an **OpenIndiana** host
  (`docs/rust-illumos-bootstrap.md` §2–3). Even the aarch64 cross path
  (`docs/aarch64-cross-rust.md`) hosts off that same x86 OI seed.
- dixi is a solnix system, not OpenIndiana: it has no IPS/`pkg` access to the OI
  Hipster repo, so it cannot re-extract the stage0. A from-source `x.py build`
  rustc still needs that stage0 rustc to start.

**Therefore the real fix is one of:**
1. (infra, fastest) re-publish a `/nix/store`-correct `rust-seed-stage` and
   rebuild the wrapper so the payload is a declared reference — then
   `solnix-dev-full` can gain a `rust` member that realises from cache; **or**
2. re-run the OI stage0 extraction on an OpenIndiana host and re-seed the cache
   (what `docs/rust-illumos-bootstrap.md` did originally); **or**
3. a full from-source `x.py` rustc build seeded by (1) or (2) — a multi-day
   effort, only worth it for reproducibility once a working stage0 is back.

None of these is in scope for a dixi-only, no-rebuild stream. Rust is **not in
`solnix-dev-full`** until a working seed exists; the wiring is ready to add a
`rust` member the moment it does.

### Mesa (meson + ninja + python3) — a separate blocker

A full build host for Mesa/graphics needs meson + ninja + python3. nixpkgs
**excludes x86_64-solaris for python3**, so Mesa's build is deferred as a
separate blocker. Rust does **not** need python/meson, so it is not gated on
this — the Rust blocker above is independent.

## Summary

| component | state | where |
|---|---|---|
| gcc 14.3.0 + gas + GNU make | **shipped, proven** (compile+link+run on dixi) | `solnix-dev` / `solnix-dev-full` |
| pkg-config (pkgconf 2.3.0) | **added**, eval+drv proven, build in progress | `solnix-dev-full` |
| autoconf/automake/libtool | deferred — needs from-source perl | follow-on `base-src.nix` |
| Rust (cargo/rustc) | **blocked** — cached seed payload retired (infra P1) | `/tmp/solnix-io-rust-seed-retired-report.md` |
| Mesa (meson/ninja/python3) | deferred — nixpkgs has no x86_64-solaris python3 | separate blocker |
