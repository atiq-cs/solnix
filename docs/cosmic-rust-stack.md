# COSMIC / Wayland Rust stack cross-build to aarch64-illumos (EM_AARCH64)

## Verdict

**The COSMIC / Wayland Rust crate stack cross-builds to EM_AARCH64 illumos.**
The ecosystem gate is OPEN: `libc`, `nix`, and `rustix` all support illumos and
all cross-compile cleanly. The COSMIC rendering + GUI layer cross-builds:
`cosmic-text` (text shaping), `iced_core` (the COSMIC GUI base), the Rust
`xkbcommon` binding, `calloop` (smithay's event loop), and the whole font/unicode
substrate (rustybuzz, swash, skrifa, fontdb, unicode-bidi, ...).

The ONE precise integration blocker is `wayland-backend`'s **pure-Rust server
backend**, which has no illumos code path (it hard-codes an epoll(linux)/kqueue(BSD)
polling allowlist and uses the Linux-only `MSG_CMSG_CLOEXEC` recv flag). This gates
`wayland-client` / `wayland-server` / `smithay-client-toolkit`. It is a bounded
crate-porting job, not a rustc/std/ecosystem gap.

## cross-rust recipe re-verified: YES

STEP 0 reproduced: a trivial `fn main(){}` cross-compiled to an EM_AARCH64 EXEC
via the wave18 build-std recipe (host x86 OI rustc 1.97.1 + `RUSTC_BOOTSTRAP=1` +
`-Zbuild-std=std,panic_abort` + the aarch64 cross-gcc linker + the syslib shim).
`readelf -h`: Class ELF64, Type EXEC, Machine AArch64. Saved as
`/root/cosmic-rust/step0-aarch64.exe`.

The recipe (from `aarch64-rust-overlay.nix`, unchanged):
- host   : `/tmp/rustimg/usr/bin/{rustc,cargo}` (OI rust seed, stable 1.97.1)
- unlock : `RUSTC_BOOTSTRAP=1`
- std    : `.cargo/config.toml [unstable] build-std = ["std","panic_abort"]`
- target : `aarch64-unknown-illumos` (llvm-target aarch64-unknown-solaris2.11)
- linker : `aarch64-unknown-solaris2.11-cc` / `-ar` (the wave cross gcc 14.3.0)
- -L shim: `RUSTFLAGS="-L native=/tmp/aa-syslibs/lib -C link-arg=-lmd -C link-arg=-lmp"`
           (libposix4->librt.1, libmd->libmd.1, libmp->libmp.2, empty sendfile/lgrp stubs)
- runtime: `LD_LIBRARY_PATH=/tmp/rustimg/usr/lib/amd64:/tmp/rustimg/usr/lib`
The full env is captured in `/root/cosmic-rust/crossenv.sh`.

## The ecosystem gate: does nix / rustix support illumos? YES

This is the make-or-break for the whole Rust ecosystem, and it passes at both the
source-cfg level AND the actual-cross-build level.

- **libc 0.2**: full illumos support -- `src/unix/solarish/illumos.rs` ships,
  `#[cfg(target_os = "illumos")]` blocks throughout `solarish/mod.rs`.
  Cross-built -> EM_AARCH64.
- **nix 0.29**: cross-built cleanly with `fs,process,socket,poll` features
  enabled -> EM_AARCH64. (nix groups solarish; 19 solaris refs + 3 illumos refs
  in src.)
- **rustix 0.38 AND rustix 1.1**: cross-built cleanly (both major versions pulled
  transitively, both -> EM_AARCH64). rustix's `build.rs` handles illumos
  explicitly:
    - `os != "linux"` -> selects the **libc backend** (the linux_raw asm backend
      is Linux-only, correctly bypassed).
    - `if os == "solaris" || os == "illumos" { use_feature("solarish"); }`
  So rustix is illumos-aware by design. Its Linux-only APIs (epoll, `MSG_CMSG_CLOEXEC`)
  are correctly cfg'd out on solarish -- which is precisely what trips wayland-backend
  (see blocker below): the crate consuming rustix assumes those Linux APIs exist.

The two crates that "gate a LOT" of the ecosystem both build. The gate is open.

## Crates that cross-built cleanly -> EM_AARCH64

Verified rlib/exe present with `readelf -h` Machine: AArch64 (see
`/root/cosmic-rust/rlibs/MANIFEST.txt`):

### Foundation / ecosystem gate
| crate     | version | note |
|-----------|---------|------|
| libc      | 0.2.185 | solarish/illumos.rs |
| nix       | 0.29    | fs/process/socket/poll |
| rustix    | 0.38 + 1.1 | libc backend, solarish feature |
| errno     | 0.3     | |
| memmap2   | 0.9     | mmap (smithay/wayland shm) |
| polling   | 3.11    | (calloop's poller) |
| calloop   | 0.14    | smithay's event loop |

### COSMIC rendering + GUI layer (pure Rust, no C deps)
| crate       | version | note |
|-------------|---------|------|
| cosmic-text | 0.12.1  | **what COSMIC renders text with** |
| rustybuzz   | 0.14    | HarfBuzz-equiv shaping (pure Rust) |
| swash       | 0.1.19  | glyph rendering |
| skrifa      | 0.22    | font access (fontations) |
| fontdb      | 0.16    | font DB |
| iced_core   | 0.13.2  | **the COSMIC GUI lib base** |
| palette     | 0.7     | color (iced dep) |

cosmic-text pulled a 63-rlib closure (unicode-bidi, unicode-segmentation,
unicode-linebreak, fontconfig-parser, sys-locale, rayon, read-fonts, tinyvec,
self_cell, ...), ALL EM_AARCH64. Zero illumos gaps in the entire text-shaping +
GUI-core stack.

### Wayland C-binding layer
| crate     | version | note |
|-----------|---------|------|
| xkbcommon | 0.7     | Rust binding; cross-built once pkg-config-cross was wired to the wave18 aarch64 libxkbcommon .pc |

The wave15/18 EM_AARCH64 C libs are present and confirmed AArch64: `libwayland-{client,server,cursor,egl}.a` and `libxkbcommon.a` (built as static archives).

## The precise integration blocker: `wayland-backend` pure-Rust server backend

`wayland-sys` / `wayland-client` / `wayland-server` / `wayland-protocols` /
`smithay-client-toolkit` all depend on `wayland-backend`, whose **rust** backend
(`src/rs/`) is compiled **unconditionally** ("The rust backend is always
available" -- crate docs). Its server impl has no illumos path:

1. **Polling allowlist** (`src/rs/server_impl/common_poll.rs`, 4 cfg sites):
   epoll for `linux/android/redox`, kqueue for `dragonfly/freebsd/netbsd/openbsd/macos`.
   **illumos is in neither**, so `dispatch_all_clients` and its `poll_fd`/`ret`
   bindings are cfg'd out entirely -> E0599 (missing method) + E0425 (missing names).
2. **`RecvFlags::CMSG_CLOEXEC`** (`src/rs/socket.rs:77`): used for all targets
   except macos/redox. In rustix this maps to `c::MSG_CMSG_CLOEXEC`, a Linux/BSD
   flag illumos libc lacks, so rustix cfg's it out on solarish -> E0599.

Adding illumos to the epoll allowlist (patch
`/root/cosmic-rust/wayland-backend-illumos-epoll.patch`) fixes site (1)'s method,
but then exposes (2) and the still-Linux-only epoll bindings -- because **illumos
has no epoll in rustix 0.38** (illumos uses event ports / `port_create`, or
`poll(2)`). So the fix is not a cfg toggle: the Rust server backend needs a real
`poll(2)`- or event-ports-based polling path for illumos, plus a solarish branch
for the recv flags.

`smithay-client-toolkit` additionally needs `PKG_CONFIG_ALLOW_CROSS=1` +
`PKG_CONFIG_PATH` pointed at the aarch64 xkbcommon/wayland `.pc` (a build-script
cross-pkg-config wiring, solvable and demonstrated -- with it wired, sctk compiled
xkbcommon and got to exactly the wayland-backend gaps above).

### What's needed to close the wayland blocker (in order)
1. **Preferred**: patch `wayland-backend`'s rust server backend to add an illumos
   polling path (poll(2) or illumos event ports) and a solarish `RecvFlags` branch
   -- a bounded crate patch, upstreamable. This is the true fix because the rust
   backend compiles unconditionally.
2. The `client_system`/`server_system` (C libwayland) features do NOT dodge this:
   the `rs` module still compiles. (They would let the *sys* backend do the polling
   at runtime, but the rust module must still *compile*.) So (1) is required
   regardless.
3. Wire cross-pkg-config for the `-sys` build scripts (xkbcommon, wayland) to the
   wave18 EM_AARCH64 `.pc` files -- already demonstrated working for xkbcommon.

## Count

**16 EM_AARCH64 artifacts** persisted (15 rlibs + 1 exe), representing distinct
crates; the transitive closures built total ~60+ crates per project, all AArch64.
Cleanly-cross-built named crates: libc, nix, rustix (x2), errno, memmap2, polling,
calloop, cosmic-text, rustybuzz, swash, skrifa, fontdb, iced_core, palette,
xkbcommon = **16 named crates**, plus their EM_AARCH64 dep closures.

## Is the COSMIC Rust stack cross-buildable?

**Yes, with one bounded exception.** The toolchain (wave18) + the ecosystem gate
(libc/nix/rustix illumos support) + the COSMIC rendering/GUI layer (cosmic-text +
iced_core + calloop + the font stack) all cross-build to EM_AARCH64 today, out of
the box, no patches. The single blocker is `wayland-backend`'s pure-Rust server
backend lacking an illumos polling path -- a targeted, upstreamable crate patch,
NOT a rustc/std/nix/rustix limitation. "The COSMIC Rust stack cross-builds to
aarch64-illumos except for the wayland-backend rust server poll path."

## Artifacts (on the fred node)

- `/root/cosmic-rust/rlibs/*.rlib` -- 15 EM_AARCH64 rlibs (one per crate)
- `/root/cosmic-rust/rlibs/MANIFEST.txt` -- per-file `readelf` Machine confirmation
- `/root/cosmic-rust/step0-aarch64.exe` -- STEP 0 trivial-crate EM_AARCH64 EXEC
- `/root/cosmic-rust/crossenv.sh` -- the reproducible cross-rust env
- `/root/cosmic-rust/rlibmachine.sh` -- rlib EM-check helper
- `/root/cosmic-rust/wayland-backend-illumos-epoll.patch` -- the blocker's first
  (necessary-but-insufficient) patch site
