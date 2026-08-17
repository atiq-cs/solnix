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
