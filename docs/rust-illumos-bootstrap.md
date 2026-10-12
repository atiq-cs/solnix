# Rust on illumos (solnix) — feasibility + first bootstrap

## Verdict: FEASIBLE AND DONE (first bootstrap achieved)

A native `x86_64-unknown-illumos` rustc **1.97.1** + cargo **1.97.1** run on the
solnix node, compile a trivial crate to a running illumos ELF, do a full
`cargo new` → `cargo build`, fetch+compile crates from crates.io, and build a
`pyo3` extension module that loads into the system CPython 3.9. Wrapped as a Nix
seed derivation and published to the durable cache.

---

## 1. Tier / host-target scoping

- illumos is a **Tier-2** Rust target: `x86_64-unknown-illumos`.
- Confirmed empirically: the OI rustc package ships a full
  `usr/lib/rustlib/x86_64-unknown-illumos/{bin,lib}` sysroot — i.e. it carries
  **host tools (rustc/cargo/rustdoc) AND std**, which is exactly what Tier 2
  means (Tier 3 would be std-only, no host rustc).
- Implication: a native rustc is not only buildable, it is already built and
  packaged by OpenIndiana. No cross-from-Linux bootstrap is needed. The
  chicken/egg (rustc needs a stage0 rustc) is solved by the OI-packaged binary.

## 2. Stage0 availability

| Source | Available? | Notes |
|---|---|---|
| OI Hipster pkg `developer/lang/rustc@1.97.1-2026.0.0.0` | **YES** | Native x86_64-illumos build. Ships `rustc`, `cargo`, `cargo-clippy`, `cargo-fmt`, `rustdoc`, `rust-analyzer`, `rust-gdb`, `rust-lldb`, and the illumos std. 1.67 GB installed. Source: rustc-1.97.1-src.tar.gz built on OI. |
| rustup dist channel for `x86_64-unknown-illumos` | Not pursued | Tier 2 does not guarantee rust-lang.org-hosted binaries; the OI pkg is the reliable stage0 and was sufficient. |
| Durable cache | Was empty of rust; **now seeded** (this run) | Published, see §5. |

The OI pkg IS the stage0. It self-hosts (it can build rustc-from-source later).

## 3. Bootstrap (what worked)

Extraction (no system mutation): created a scratch pkg image and installed
rustc into it:

```
pkg image-create -F -p openindiana.org=https://pkg.openindiana.org/hipster/ /root/rustimg
pkg -R /root/rustimg install --accept developer/lang/rustc
```

Runtime-lib analysis: the OI binaries have an absolute
`RUNPATH=/usr/gcc/14/lib/amd64:/usr/lib`. Against the base illumos system only
**two** libs are image-only:
- `libLLVM.so.22.1-rust-1.97.1-stable` (needed by `librustc_driver`, lives in the rust tree)
- `libgit2.so.1.9` (needed by cargo)

Everything else (libssl/libcrypto/libcurl/libssh2/libc/libgcc_s/...) resolves
from the base system. `libgcc_s` comes from the system `/usr/gcc/14` (also
provides `cc` for cargo's linker step).

Self-contained tree staged (767 MB): `bin/{rustc,cargo,rustdoc}` +
`lib/rustlib` (the sysroot) + top-level rust `.so` (librustc_driver, libLLVM) +
`libgit2.so.1.9`. The `bin/../lib/rustlib` layout preserves rustc's sysroot
auto-detection. Imported to the store via `nix-store --add`.

Results (all PASS):

```
$ rustc --version   → rustc 1.97.1 (8bab26f4f 2026-07-14) (built from a source tarball)
$ cargo --version   → cargo 1.97.1 (c980f4866 2026-06-30) (built from a source tarball)

$ rustc -o hello hello.rs && ./hello
hello from rust on illumos            # ELF 64-bit LSB executable AMD64

$ cargo new ct && cd ct && cargo build && ./target/debug/ct
Hello, world!

$ cargo add itoa && cargo build       # crates.io fetch + external-crate compile: PASS
```

## 4. Rust-gated python unlock (proof)

Built `pyo3 0.22.6` — the exact rust backend used by `cryptography`,
`rpds-py`, `pydantic-core` — as an extension module against the system CPython
3.9. The full proc-macro toolchain (`syn`, `proc-macro2`, `quote`,
`pyo3-macros`, `pyo3-build-config` which probes the interpreter, `pyo3-ffi`) all
compiled on illumos:

```
$ PYO3_PYTHON=/usr/bin/python3 cargo build     # 22 crates, Finished dev in 14.88s
$ python3 -c "import pyo3test; print(pyo3test.add(2,40))"
42
```

A rust-built cdylib loaded into illumos CPython and executed across the FFI
boundary. This confirms the unlock for the rust-gated python pool is real: cargo
is invoked, the rust backend compiles, and the resulting module runs.

Note: system python has no pip/maturin, so a full `pip install cryptography`
wheel build was not run; the pyo3 module build+import proves the identical
mechanism (cargo + pyo3 + system python) that those wheels use.

## 5. Nix seed + published paths

`/root/rust-illumos-seed.nix` — a pure-shell derivation
(`system = "x86_64-solaris"`) that wraps the raw store tree with wrappers
setting `LD_LIBRARY_PATH` (seed libs + system libgcc) and `PATH`
(`$out/bin` first so cargo finds the wrapped rustc, then system gcc for `cc`).
A legitimate binary stage0 seed in the same spirit as the gcc/nix seeds.

Published to the durable cache (see `/root/rust-paths.txt`):
- `rust-illumos-1.97.1` (the wrapped seed) — the toolchain entry point
- `rust-seed-stage` (the raw 767 MB rust tree the seed references)

## 6. Exact next steps

1. **Integrate into the stdenv/overlay**: expose the seed as
   `rustc`/`cargo`/`rustPlatform.rust.*` in the solaris-overlay so
   `buildRustPackage`-style derivations resolve. The seed's wrappers already
   give working binaries; the overlay just needs to point rustPlatform at them.
2. **De-reference the two absolute host paths**: the wrappers currently rely on
   `/usr/gcc/14` at runtime (for `cc` + `libgcc_s`). For a fully hermetic
   closure, point `systemGcc`/`systemLib` at the nixpkgs gcc-14 (tranche-224
   already builds gcc-14.4) instead of `/usr/gcc/14`.
3. **Self-host rustc-from-source** (optional, removes the OI binary dependency):
   use this seed as the stage0 to `./x.py build` rustc from the 1.97.1 source
   tarball, producing a pure-nix rustc. Only worth it if the binary seed proves
   insufficient for reproducibility.
4. **Land the python unlock**: bootstrap pip/maturin into a python env, then
   build `cryptography`/`rpds-py`/`pydantic-core` wheels — all should now work
   since cargo+pyo3 are confirmed functional.

## Artifacts on node
- `/root/rust-illumos-report.md` (this file)
- `/root/rust-illumos-seed.nix` (the seed derivation)
- `/root/rust-paths.txt` (published store paths)
- `/root/rust-seed-stage` (staged tree), `/root/rustimg` (scratch pkg image, can be trashed)

---

# Advancing Rust: the from-source bootstrap chain (how solnix gets latest Rust)

## Status: 1.99.0 built FROM SOURCE and banked (2026-10-12)

The 1.97.1 OI seed self-hosted exactly as predicted ("Once this seed can build
rustc-from-source, the source build supersedes it"). We now ship native
`x86_64-unknown-illumos` **rustc/cargo 1.99.0 (b940084d7 2026-09-28)** built from
the rust-lang.org source tarball, seed-independent, for GENERAL Rust use. The
intermediate **1.98.0** is banked too (it is a legitimate stage0 for any future
1.99.x/2.00 build).

Verified general-purpose (not COSMIC-shaped): `cargo new`+build+run → native
illumos ELF; `cargo add serde --features derive` + `itoa` (crates.io fetch) +
`cargo build` → 9 crates incl. the `serde_derive` **proc-macro** → runs.

## The N-1 rule (why you cannot jump straight to latest)

Rust bootstrap enforces (`src/bootstrap/src/core/config/config.rs`
`check_stage0_version`): the stage0 compiler's minor must equal the source
minor, OR be exactly one less (`source.minor == stage0.minor` or `+ 1`). So a
1.97.1 stage0 **cannot** build 1.99.0 — it is rejected with
`Unexpected rustc version: 1.97.1, we should use 1.98.x/1.99.0 ...`.
**Do NOT patch this gate** (the newer compiler source uses language/std features
the older rustc cannot parse; patching produces a broken toolchain). Instead
**chain, one minor at a time:**

```
1.97.1 OI seed  --build-->  1.98.0  --build-->  1.99.0   (each hop N-1)
```

Each hop's output becomes the next hop's stage0. Verify each hop WORKS before
using it as the next stage0 (a broken intermediate silently corrupts the chain).

## The next hop (1.99.0 → 2.00/next-stable), mechanically

Substrate: a native illumos build host with gcc-14 (`/usr/gcc/14`), python3,
cmake, OpenSSL 3 (`/usr/openssl/3`), and nix. The persistent build AMI
`ami-0e344991f2f44b11d` (us-east-2) has all of it; use a big instance
(c5.9xlarge, ~1.5 h/hop, mostly LLVM) and **terminate it when done**.

1. **Fetch + verify** `rustc-<next>-src.tar.xz` from `https://static.rust-lang.org/dist/`
   (check the `.sha256`). Extract pristine; do NOT run a manual `cargo` in the tree.
2. **Stage0 wrappers** pointing at the PREVIOUS hop's `x.py install` prefix
   (`$prefix/bin/{rustc,cargo,rustdoc}`), with a wrapper that exports
   `LD_LIBRARY_PATH=$prefix/lib:/usr/gcc/14/lib/amd64:/usr/openssl/3/lib/amd64`
   and prepends `/usr/gcc/14/bin` to PATH. (For the FIRST hop off the OI seed
   only, use the PRUNED seed — see "Seed hazard" below.)
3. **bootstrap.toml** (the modern flat-key form; `profile = "dist"`):
   ```toml
   [build]
   build  = "x86_64-unknown-illumos"
   host   = ["x86_64-unknown-illumos"]
   target = ["x86_64-unknown-illumos"]
   rustc   = "<stage0-wrap>/bin/rustc"
   cargo   = "<stage0-wrap>/bin/cargo"
   rustdoc = "<stage0-wrap>/bin/rustdoc"
   docs = false
   extended = true
   tools = ["cargo"]
   submodules = false           # release tarball already vendors LLVM + crates
   [install]
   prefix = "/root/rust199/install-<next>"
   [llvm]
   download-ci-llvm = false     # no illumos CI LLVM; build bundled LLVM in-tree
   [rust]
   channel = "stable"
   download-rustc = false
   compress-debuginfo = "off"   # illumos ld rejects --compress-debug-sections=zlib
   ```
4. **Build+install** (one invocation):
   ```sh
   export CC=/usr/gcc/14/bin/gcc CXX=/usr/gcc/14/bin/g++ \
          CC_x86_64_unknown_illumos=/usr/gcc/14/bin/gcc \
          CXX_x86_64_unknown_illumos=/usr/gcc/14/bin/g++ AR_x86_64_unknown_illumos=/usr/bin/ar \
          OPENSSL_DIR=/usr/openssl/3 OPENSSL_LIB_DIR=/usr/openssl/3/lib/amd64 \
          OPENSSL_INCLUDE_DIR=/usr/openssl/3/include \
          PKG_CONFIG_PATH=/usr/openssl/3/lib/amd64/pkgconfig
   python3 x.py install rustc cargo std
   ```
5. **Verify the hop** (before using as next stage0): `rustc --version`,
   `cargo new`+`cargo build`+run → native ELF, and (final hop) an external
   crates.io crate (`cargo add serde --features derive`; CA bundle
   `/etc/certs/ca-certificates.crt`).
6. **Stage reproducibly + bank**: `stage-rust-fromsrc.sh <install-prefix> <staged-dir>`
   (pins file set + perms), then `nix-store --add <staged-dir>`. Record the store
   path + NarHash + the `--manifest` inventory (committed) — do NOT repeat the
   lost-layout mistake. Point a new `rust-illumos-<next>.nix` (import
   `rust-illumos-fromsrc.nix` with `version` + `rustRaw`) at it; repoint
   `rust-overlay.nix` `seedRust`/`seedRustRaw` to the new wrapper/stage.

## Four Tier-2 / seed blockers each hop can hit (all solved here)

1. **Stage0 cargo lockfile drift** (only when the stage0 cargo is OLDER than N-1,
   e.g. the 1.97.1 seed building 1.98.0): `error: cannot update the lock file ...
   because --frozen was passed`. The old resolver re-resolves to versions the
   vendor dir actually carries. Fix (no network): regenerate both locks offline
   against vendor with the stage0 cargo, then `--frozen` passes —
   `RUSTC_BOOTSTRAP=1 cargo generate-lockfile --offline --manifest-path Cargo.toml`
   and the same for `library/Cargo.toml`. With a correct N-1 stage0 (1.98.0 →
   1.99.0) the lock is respected as-is and this step is unnecessary.
2. **Seed hazard — `rustc-src` collision** (first hop off the OI seed ONLY): the
   OI seed sysroot ships `lib/rustlib/{rustc-src,src}` (the 1.97.1 compiler
   source, OLD module layout). Bootstrap's sysroot `rustc-src` wiring
   (`compile.rs` ~2075) collides with it and HARDLINKS the seed's 1.97.1
   compiler sources over the new tree's `compiler/` (shared inodes), producing
   `error[E0761]: file for module ... found at both X.rs and X/mod.rs`. A normal
   rustup stage0 does not ship rustc-src, so upstream never hits it. Fix: build a
   PRUNED stage0 — copy the seed tree without `lib/rustlib/{rustc-src,src}`,
   `nix-store --add` it, point the wrappers' bin + LD_LIBRARY_PATH at the pruned
   store path (so `rustc --print sysroot` reports a tree with no rustc-src). Our
   from-source installs do NOT include rustc-src, so later hops are immune.
3. **illumos ld rejects GNU debug compression**: `ld: fatal: unrecognized option
   '--compress-debug-sections=zlib'`. The `dist` profile defaults
   `rust.compress-debuginfo="zlib"`. Fix: `rust.compress-debuginfo = "off"`.
4. **stage2 cargo wants OpenSSL 3**: `openssl-sys 0.9.x` build fails because the
   illumos default `/usr/lib/amd64/libssl.so` is 1.0.x. The host has OpenSSL
   3.5.9 at `/usr/openssl/3`. Fix: the `OPENSSL_DIR`/`OPENSSL_LIB_DIR`/
   `OPENSSL_INCLUDE_DIR`/`PKG_CONFIG_PATH` env above.

## Banking the chain — files + hashes (2026-10-12)

Reusable staging script: `stage-rust-fromsrc.sh` (same spirit as
`stage-rust-seed.sh`; pins file set + 0755/0644 perms from an `x.py install`
prefix). Each toolchain's `rust-<ver>-stage.MANIFEST.txt` is committed.

| toolchain | raw staged store path | NarHash |
|---|---|---|
| rust-1.98.0-stage | `/nix/store/pngbrvmx7kf79n0sq5bv1hkmw8ad05wa-rust-1.98.0-stage` | `sha256-dHaIdbW3sztaCWc/qgqVopy7RemA9Rq2py96qZpnBrs=` |
| rust-1.99.0-stage | `/nix/store/xp2sv9n9zpi2bm1w1rc7djx6d8akifbd-rust-1.99.0-stage` | `sha256-JH3xRNk/Ht9ntagBvOsSXWXnmz93rxFkTSE06i6WZOI=` |

Wrapper toplevels (`rust-illumos-fromsrc.nix` + a per-version file):
- `rust-illumos-1.98.0` → `/nix/store/ygnypz368rmf5nz4fgzq1540vbr58124-rust-illumos-1.98.0`
- `rust-illumos-1.99.0` → `/nix/store/mxn53s79f118a50af3jx68aswdlcgkw5-rust-illumos-1.99.0`

`rust-overlay.nix` now prefers 1.99.0 (`seedRust`/`seedRustRaw` → the 1.99.0
wrapper/stage). The 1.97.1 OI seed stays banked as the bootstrap stage0 of record
and the working fallback; it is no longer the runtime toolchain.
