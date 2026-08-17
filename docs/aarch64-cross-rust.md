# aarch64-cross-rust bring-up report (wave18)

## Verdict

**aarch64 rust cross-compile WORKS.** The x86 OI rust seed (rustc/cargo 1.97.1)
hosts a working cross to `aarch64-unknown-illumos` via `-Zbuild-std`. Proven:
a trivial `fn main(){}` AND a std-using `staticlib` crate both cross-compile to
**EM_AARCH64** illumos objects. The COSMIC Rust stack is now cross-buildable at
the toolchain level; the remaining librsvg work is nixpkgs *integration*, not a
rustc/std gap.

## Scope findings (the two gate questions)

### Is aarch64 a rustc target? What triple?
- **`aarch64-unknown-illumos` is a real rustc target.** Confirmed two ways:
  1. `rustc --print target-list` lists it.
  2. `RUSTC_BOOTSTRAP=1 rustc -Zunstable-options --print target-spec-json
     --target aarch64-unknown-illumos` resolves; `llvm-target =
     aarch64-unknown-solaris2.11` -- exactly the wave's cross triple.
- **`aarch64-unknown-solaris` does NOT exist.** The only solaris targets are
  `x86_64-pc-solaris` and `sparcv9-sun-solaris`. The aarch64 illumos target is
  `aarch64-unknown-illumos`.

### What tier? Does the OI rustc ship aarch64 std?
- **Tier 3.** The target spec ships in rustc-src
  (`compiler/rustc_target/src/spec/targets/aarch64_unknown_illumos.rs`,
  `base/illumos.rs`), but **NO prebuilt aarch64 std**. The OI rustc pkg ships
  std rlibs only for its native host `x86_64-unknown-illumos`
  (`usr/lib/rustlib/x86_64-unknown-illumos/lib/lib{std,core}-*.rlib`).
- **The x86 rustc is stable 1.97.1** -- bare `-Z` flags are rejected
  ("only accepted on the nightly compiler").
- **`rust-src` IS shipped** (`usr/lib/rustlib/src/rust/library/{std,core,alloc,
  panic_abort,unwind,...}` with Cargo.toml). This is exactly what `-Zbuild-std`
  needs, so build-std is tractable.

=> **Path B (build-std), unblocked by two facts:** rust-src ships, and
`RUSTC_BOOTSTRAP=1` unlocks the unstable `-Z`/`[unstable]` machinery on the
stable rustc. No nightly toolchain needed.

## The working cross recipe

```
host   : x86 OI rustc 1.97.1 (stable) + cargo (bundled in the same pkg)
unlock : RUSTC_BOOTSTRAP=1
std    : cargo build --target aarch64-unknown-illumos, with
         .cargo/config.toml [unstable] build-std = ["std","panic_abort"]
linker : the wave aarch64 cross gcc: aarch64-unknown-solaris2.11-cc / -ar
         (set in [target.aarch64-unknown-illumos] linker/ar)
runtime: cargo/rustc are x86 illumos binaries; their libs live in
         <rustSeed>/usr/lib/amd64 (libgit2.so.1.9 etc) + <>/usr/lib
         -> on LD_LIBRARY_PATH, plus the nix-tools224 runtime-lib.
```

### The aarch64 syslib shim (the one real gap cracked)
The vendored `libc-0.2.185` crate's illumos `#[link(name=...)]` attrs + the
target spec pull `-lposix4 -lsendfile -llgrp`, and the seed's
`libnsl`/`libresolv` transitively need `libmd`/`libmp` -- all missing from the
aarch64 seed's default link path. A tiny `-L` shim resolves them:

```
libposix4.so -> <aarch64Seed>/lib/librt.so.1   (posix4 IS a librt filter)
libmd.so     -> <aarch64Seed>/lib/libmd.so.1   (MD5Init@SUNW_1.1)
libmp.so     -> <aarch64Seed>/lib/libmp.so.2   (mp_mult@SUNW_1.1)
libsendfile.so, liblgrp.so  = empty aarch64 stubs (built with the cross cc;
                              their symbols are not called by rsvg/gtk)
```
Passed via `RUSTFLAGS="-L native=<shim>/lib -C link-arg=-lmd -C link-arg=-lmp"`.
(This is the exact wave `aaSeedL -lmd -lmp` class, applied to the rust link.)

## Proof artifacts (on the fred node)

- `/tmp/rustimg/usr/bin/{rustc,cargo}` -- the OI rust seed, staged via
  `pkg -R /tmp/rustimg install developer/lang/rustc`.
- `/tmp/aa-syslibs/` -- the syslib shim (posix4/md/mp symlinks + sendfile/lgrp
  stubs).
- `/tmp/hello/target/aarch64-unknown-illumos/release/hello`
  -- trivial crate, `readelf -h`: Machine AArch64, Type EXEC, interp /lib/ld.so.1.
- `/tmp/staticlib/target/aarch64-unknown-illumos/release/librsvgshape.a`
  -- a std-using C-ABI staticlib (the librsvg-c shape), exported symbol
  `rsvg_shape`, object Machine AArch64.

## librsvg: what is left (integration, not codegen)

librsvg 2.62.3 is a Rust workspace (`librsvg-c` emits a C-ABI staticlib/cdylib
for the GTK SVG loader). Its nixpkgs build in this pinned cross tree is blocked
BEFORE rust, at eval:

- `nix-instantiate -A librsvg` fails with a **fetchurl-shim zeroed-hash
  mismatch** (`got sha256:13z6...`) on the crate-vendor fetch -- the same
  eval-time fetch-shim trap the wave16/17 notes call out (gi-docgen/python-toml
  etc). The cargo vendor tarball must be provided out-of-band (a real FOD /
  prefetched vendor dir), not through the shim.

Follow-on wiring (the next step), in order:
1. Provide the librsvg cargo-vendor as a real FOD (bypass the fetch shim), or
   pin `cargoDeps`/`cargoVendorDir` to a prefetched dir.
2. Point `rustPlatform`/`buildRustPackage` at this cross toolchain: rustc/cargo
   = the OI seed, `CARGO_BUILD_TARGET=aarch64-unknown-illumos`,
   `RUSTC_BOOTSTRAP=1`, the `.cargo` build-std config, the cross-cc linker, and
   the syslib-shim RUSTFLAGS (all captured in aarch64-rust-overlay.nix's
   `crossRustEnv`).
3. Cross-link the `-sys` crate deps librsvg needs (cairo/pango/gdk-pixbuf/
   harfbuzz/freetype -- all already built EM_AARCH64 in waves 13-16); their
   pkg-config `.pc` must be on `PKG_CONFIG_PATH` for the build scripts.

None of these is a rustc or std limitation -- the codegen path is proven. This
is the same "nixpkgs package.nix carries unconditional deps / eval-time fetch
traps" class the whole aarch64 cross wave has been cracking, now for a Rust pkg.

## COSMIC stack implication

The COSMIC desktop is ~entirely Rust. With aarch64-cross-rust proven
(host rustc + build-std + cross-cc linker + syslib shim), the COSMIC crates are
cross-buildable **at the toolchain level**. Each crate still needs its native
lib deps present EM_AARCH64 (the wave has been banking exactly those) and the
same buildRustPackage cross-wiring librsvg needs. The gate is open.
