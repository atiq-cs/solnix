# Design: Modern compiler toolchains for solnix (GCC-14 + Clang-21 + GDB)

Status: DONE + gated on the illumos build host (`illumos-960edb1c89`). Packages
the latest illumos GCC **and** Clang/LLVM as relocatable `pkgs.illumos.*` store
toolchains so the package registry can be built with **both** compilers (the
maintainer's rule: "build packages with at least GCC and Clang, preferably
latest versions"). This is the foundation the package-batch work depends on, and
pulls forward backlog **PS-1** (clang), **PS-4** (latest GCC/GDB), partially
**PS-5** (lldb — see status).

TL;DR: **SLICE, don't build-from-source.** OpenIndiana already ships gcc-14
(14.3.0) and clang-21 (21.1.8) as IPS packages, both already configured for
`x86_64-pc-solaris2.11` and both proven to build the illumos world. We
re-express the OI binaries as `/nix/store` toolchains with RUNPATH relocated by
`elfedit` — exactly the mechanism used for the world slices
(`docs/design-gate-derivation.md` §2, `mk-illumos-component.nix`). Building a
compiler from source is a huge, redundant effort; it's a documented follow-on
only if a newer-than-OI or differently-configured compiler is wanted.

---

## What OI ships (verified on the host, `pkg list -af`)

| tool | IPS package | version | prefix | status |
|---|---|---|---|---|
| **GCC** | `developer/gcc-14` | 14.3.0-2026.0.0.2 | `/usr/gcc/14` | installed, sliced |
| GCC (older) | `developer/gcc-13` | 13.4.0 | (runtime only installed) | available |
| **Clang/LLVM** | `developer/clang-21` | 21.1.8-2025.0.0.0 | `/usr/clang/21` | installed, sliced |
| Clang (older) | `developer/clang-{16,18,19,20}` | … | | available |
| **GDB** | `developer/debug/gdb` | 16.3-2025.0.0.0 | `/usr/bin/gdb` | was sliced; since 2026-11-02 `pkgs.solnix.gdb` is GDB 18.1 from source (cli/c-dev.nix) |
| **LLDB** | — | — | — | **not shipped by OI at all** |

Both gcc-14 and clang-21 default-target `x86_64-pc-solaris2.11` (confirmed:
`gcc -dumpmachine`, `clang -dumpmachine`). clang's version string names the OI
build: `clang version 21.1.8 (github.com/OpenIndiana/oi-userland ...)`. This is
the illumos "shadow compiler" (steering `illumos-domain.md`) promoted to a
**primary** here.

---

## What was sliced vs built-from-source

Everything is **sliced** (from the OI host IPS install, `srcRoot="/"`), none
built from source. `pkgs/illumos/toolchains.nix`:

- `pkgs.illumos.gcc14` — the whole `/usr/gcc/14` prefix (driver + `cc1`/`cc1plus`
  + gcc runtime + full C/C++ headers + gcc-internal headers + crt objects), plus
  `libz`/`libzstd` (which `cc1` NEEDs and which are NOT under `/usr/gcc/14`).
- `pkgs.illumos.clang` — the whole `/usr/clang/21` prefix (clang driver + all
  llvm tools + `libLLVM.so.21.1` (211 MB) + `libclang-cpp.so.21.1` + clang
  resource headers), plus its third-party deps (gcc-14's libstdc++/libgcc_s +
  libedit/libncurses/libz/libzstd/libxml2.so.2/libicu*) bundled into a
  `lib-extra/` dir.
- `pkgs.illumos.gdb` — `/usr/bin/gdb`(+`gdb-add-index`,`gdbtui`), plus gdb's full
  ~40-lib NEEDED closure (python3.9, glib, babeltrace, mpfr/gmp, the dladm/scf/
  nvpair chain, …) bundled into `lib-extra/`.

**From-source follow-ons (noted, not done):**
- A newer GCC than OI's 14.3.0, or a bespoke `--with-rpath`/`-fuse-ld`
  configuration (see the ld gotcha below), would be a from-source build via the
  gate's own gcc build or a standalone Nix derivation. gcc-13 is also available
  from OI if a second GCC is wanted for shadow-compiling.
- **LLDB is not packaged: OI ships no lldb.** To provide it (backlog PS-5) it
  must be built from the LLVM source tree (`-DLLVM_ENABLE_PROJECTS=lldb`) on
  illumos, or a future OI `developer/lldb-*` package sliced when it appears. The
  clang slice DOES ship the rest of the LLVM debug toolchain (`llvm-dwarfdump`,
  `llvm-symbolizer`, `llvm-objdump`, …), so PS-5's non-lldb pieces are covered.

---

## RUNPATH / relocation gotchas (the load-bearing detail)

The slices reuse `mkIllumosComponent` + host `elfedit dyn:runpath` (rewrites
DT_RUNPATH+DT_RPATH). Three toolchain-specific findings:

1. **`elfedit` grows RUNPATH even on a 211 MB library.** `libLLVM.so.21.1` (211
   MB) and `libclang-cpp.so.21.1` (110 MB) both take a longer store RUNPATH
   in-place — no relink needed. This de-risks design risk #2 (grow-in-place on
   the biggest offenders) for the toolchains.

2. **gcc's driver bakes an ABSOLUTE host `-R /usr/gcc/14/lib/amd64` into every
   C++ link** (configured `--with-rpath=/usr/gcc/14/lib`). Because ld.so.1 uses
   the *first* matching RUNPATH entry and that host path exists on the build
   host, a C++ binary linked by the store g++ resolves `libstdc++`/`libgcc_s`
   from **host** `/usr/gcc/14`, not the store — a leak. Fix: a **cc-wrapper**
   (`scripts/oi-cc-wrapper.sh`) that, after link, scrubs any leading
   `/usr/gcc*` field out of the output binary's RUNPATH with `elfedit`. The C
   hello never leaked (no libstdc++), and **clang does NOT have this problem**
   because its runtime-lib `-R` follows `--gcc-toolchain=<store>` — point that at
   the store gcc14 and clang emits store-only RUNPATHs. The wrapper scrubs
   uniformly so both are clean.

3. **gcc's `collect2` calls `ld` via a configure-baked absolute
   `--with-ld=/usr/bin/ld`**, so a store-`ld`-slice PATH prefix does NOT change
   which linker gcc invokes — gcc always uses host `/usr/bin/ld`. That host `ld`
   IS the illumos Solaris link-editor (identical bytes; `ld -V` →
   `Solaris Link Editors: 5.11-1.1791 (illumos)`), so links work and binaries
   run. For a fully-hermetic store-ld under gcc, pass `-B <ld-slice>/usr/bin`
   (verified: collect2 then finds the store ld and the binary runs) OR reconfigure
   gcc. **Clang respects PATH/`-B` for `ld`**, so the wrapper's store-ld PATH
   prefix is honoured by clang directly. This is a documented refinement, not a
   gate blocker — the linker is the same illumos ld either way.

---

## How to select gcc-vs-clang for a package build

`scripts/oi-cc-wrapper.sh <outdir> <gcc14-store> <clang-store> <libc-store>
[ld-store]` emits four wrappers:

```
solnix-gcc  solnix-g++      # -> store gcc14, sliced libc, Solaris ld, RUNPATH scrubbed
solnix-clang  solnix-clang++ # -> store clang21, --gcc-toolchain=<store gcc14>, sliced libc
```

A package build picks its compiler by pointing `CC`/`CXX` at the wanted pair:

```sh
# build with GCC-14:
CC=$OUT/solnix-gcc  CXX=$OUT/solnix-g++      ./configure && make
# build the SAME package with Clang-21:
CC=$OUT/solnix-clang CXX=$OUT/solnix-clang++ ./configure && make
```

Each wrapper already carries the sliced-libc `-isystem`/`-B`/`-L`/`-R` flags and
the RUNPATH scrub, so the produced binaries are `/nix/store`-clean (ldd shows
zero host `/lib`/`/usr/lib`/`/usr/gcc` refs). The exact raw flags each wrapper
uses are in the wrapper bodies (and in `scripts/gate-{gcc14,clang}.sh`).

C++ standard library: **libstdc++ (gcc-14's), not libc++** — OI's clang is built
against gcc-14's libstdc++, so `clang++ -stdlib=libstdc++` is the working config;
`-stdlib=libc++` is not provided by OI.

---

## GATES (real compile+link+run on illumos, host `illumos-960edb1c89`)

**GATE GCC — PASS.**
- `pkgs.illumos.gcc14` realises → `/nix/store/1sif429w2gpwzxcjqljb481anq0y7wh2-illumos-gcc14`.
- `gcc --version` → `gcc (OpenIndiana 14.3.0-oi-2) 14.3.0`; `-dumpmachine` →
  `x86_64-pc-solaris2.11`.
- Store gcc driver + `cc1plus` are **ldd-clean** (libc from the sliced libc
  store, `libz`/`libzstd` from the gcc14 store, zero host leak).
- A `hello.c` compiled+linked with the store gcc14 (sliced libc, Solaris ld)
  **RUNS** and resolves libc from `/nix/store/…-illumos-libc/lib/amd64`.
- A C++ `hello.cc` (libstdc++) **RUNS**; after the wrapper scrub its RUNPATH is
  pure `/nix/store` (host `/usr/gcc/14` removed).
- **GDB present + PASS** — `pkgs.illumos.gdb` realises →
  `/nix/store/lv49gydird6mh1488hd2wdm9i20imrl1-illumos-gdb`; `gdb --version` →
  `GNU gdb (GDB) 16.3`; ldd-clean; **debugs a real binary** (breakpoints,
  `run`, thread list, `backtrace` — even unwinds libc frames back to the sliced
  store libc path) on both a gcc14- and a clang-built threaded program.

**GATE CLANG — PASS.**
- `pkgs.illumos.clang` realises → `/nix/store/b824mvhkdd4hh0vdi828x1nppkpqwm1y-illumos-clang`.
- `clang --version` → `clang version 21.1.8 (…OpenIndiana…)`; `-dumpmachine` →
  `x86_64-pc-solaris2.11`.
- Store clang driver + the 211 MB `libLLVM.so.21.1` are **ldd-clean**.
- A `hello.c` compiled+linked with store clang **RUNS**; its RUNPATH is 100%
  store paths (clang doesn't bake the host `-R` gcc does).
- A C++ `hello.cc` (`--gcc-toolchain=<store gcc14>`, libstdc++) **RUNS** and
  resolves libstdc++/libgcc_s from the **store** gcc14.

**BONUS — dual-compile — PASS.** The SAME nontrivial program (4-thread
`pthread_create`/`join` + `printf`, checks the sum of squares) compiled with
BOTH `gcc14` and `clang` (sliced libc, Solaris ld); **both run** (workers print,
sum=30, exit 0), **both ldd-clean**. This is the direct proof of dual-toolchain
capability the registry needs.

---

## Store paths + NAR hashes (published to solnix.io cache)

| slice | store path | NAR (sha256, base32) | NAR size | xz size |
|---|---|---|---:|---:|
| gcc14 | `/nix/store/1sif429w2gpwzxcjqljb481anq0y7wh2-illumos-gcc14` | `0zrsgpwwa7q8dcxi5qzfhb0nspq36nmhd8agx0d87wb98ql0dlvq` | 921.8 MB | 141.8 MB |
| clang | `/nix/store/b824mvhkdd4hh0vdi828x1nppkpqwm1y-illumos-clang` | `1w5qg50jwwqks85a7smhcdddr14zv3qw21h9vwav1vycjcvxw7ga` | 1399.1 MB | 240.4 MB |
| gdb | `/nix/store/lv49gydird6mh1488hd2wdm9i20imrl1-illumos-gdb` | `1gj58rrjzkpc8cq66wc5lq285nzq6gwds5wjzk89vbwj85zl6ivx` | 79.5 MB | 20.5 MB |

All three published + signed to `https://s3.solnix.io/solnix-cache` (via
`scripts/oi-cache-publish.sh`; they depend on the already-cached
`illumos-libc`). Store-path prefixes move when a dep hash or the builder text
changes; the NAR content hash is what to pin.

---

## What's needed to make these the DEFAULT world compiler

The gates prove the toolchains compile/link/run individual programs. Making
gcc-14 (or clang-21) the compiler that rebuilds the **whole illumos world** is a
larger, separate effort (a full-world rebuild = later, per the backlog):

1. **Re-pin the gate build to gcc-14.** The current world is sliced from a gate
   proto built with gcc-10 (the seed). The gate's `nightly`/`bldenv` env
   (`scripts/oi-gate-build.sh`) selects the primary compiler via `GNUC_ROOT`/
   `PRIMARY_CC`. Point those at `/usr/gcc/14` (and optionally set the shadow to
   clang-21 or gcc-13), rebuild the proto, and re-slice libc/sys/ld/rtld/
   base-tools from the gcc-14 proto.
2. **Re-verify the world slices' ABI + RUNPATH** against the gcc-14 proto (the
   `externalLibs` slice already ships the gcc-14 runtime, so it's aligned).
3. **Optionally a full clang world rebuild (PS-1):** set the gate primary to
   clang-21 and rebuild; illumos supports clang as primary for most of the gate
   (some pieces still assume gcc — verify per-component, keep the better default).
4. **Cache both.** Publish the gcc-14 world and (if built) the clang world so
   consumers substitute rather than rebuild.

None of that is needed for the package-batch work, which links against the
sliced libc + these store toolchains directly via the cc-wrappers.

---

## Files

| file | role |
|---|---|
| `pkgs/illumos/toolchains.nix` | the `gcc14`/`clang`/`gdb` slices (imported by `default.nix`) |
| `pkgs/illumos/default.nix` | wires `inherit (toolchains) gcc14 clang gdb;` into the output |
| `scripts/oi-cc-wrapper.sh` | emits `solnix-{gcc,g++,clang,clang++}` wrappers (RUNPATH scrub) |
| `scripts/gate-gcc14.sh` | GATE GCC driver (version, ldd-clean, C+C++ hello compile/link/run) |
| `scripts/gate-clang.sh` | GATE CLANG driver (version, ldd-clean, C+C++ hello) |
| `scripts/gate-dual.sh` | BONUS: same pthreads program via both compilers, both run |

## Fork mapping (`~/ws/nixpkgs-solnix/pkgs/os-specific/illumos/`)

- `toolchains.nix` → `pkgs/toolchains.nix`; each `mkIllumosComponent` call →
  `stdenvNoCC.mkDerivation` (same map as the world slices in the README's "Fork
  mapping"). Expose `passthru = { isClang = …; cc = …/bin/{gcc,clang}; }` so a
  `cc-wrapper` in the fork can select the compiler per package.
- Wire the cc-wrapper into the fork's `bintools`/`cc` (reuse the existing
  `bintools-wrapper/ld-solaris-wrapper.sh` solaris gating): add a `useClang`
  package attribute so `pkgs.illumos.stdenvClang` builds a package with clang-21
  and the default `stdenv` with gcc-14 — both against the sliced libc + Solaris
  ld. The RUNPATH scrub becomes a `postFixup`/`fixupPhase` hook.
- LLDB (PS-5): a from-source `pkgs/lldb.nix` building the LLVM tree with
  `-DLLVM_ENABLE_PROJECTS=lldb` on illumos, once scheduled.
