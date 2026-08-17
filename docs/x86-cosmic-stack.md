# x86_64-solaris COSMIC stack — Stage 1 (native)

Native x86_64-solaris (illumos) build. Goal: the foundation for a graphical
x86_64 COSMIC desktop ISO. This stage builds the cross-cutting build toolchain
that every later desktop wave needs, and the leaf of the font stack.

## Headline: cmake is UNBLOCKED on illumos x86_64

`cmake` was previously documented as **blocked** on illumos (solaris-overlay
note H26: `-lkstat`/`-lsendfile`, avoided by building git/curl cmake-free).
This stage broke that wall. cmake gates brotli, and brotli gates freetype; it
also gates every future package that shells out to cmake for `find_package`.

## NEW x86_64-solaris packages this stage (6, all ELF-verified AMD64)

| package        | store path                                                        | kind        |
|----------------|-------------------------------------------------------------------|-------------|
| cmake 4.3.4    | rxn8ir7k7vpqmwdmrrj4g9lh1dp1c8f7-cmake-4.3.4                       | AMD64 exe   |
| freetype 2.14.3| ivl2s65d3i7q9yljdkvvapmqj2hd8cr1-freetype-2.14.3                   | AMD64 .so   |
| brotli 1.2.0   | c6d79nf4qnghpxwx1cmdqglhfbzl3905-brotli-1.2.0                      | AMD64 exe   |
| libuv 1.52.1   | ph37gkna0lqn9qq58byffwj7rpxd0gmp-libuv-1.52.1                      | AMD64 .so   |
| libarchive 3.8.8| py4w0587qnkj584spd9zg7awc3331375-libarchive-3.8.8                 | AMD64 .so   |
| rhash 1.4.6    | xf5f17iqz67n6siks479rpmnd307wmxw-rhash-1.4.6                       | AMD64 .so   |

Published: 20 store paths (the 6 packages + dev/lib splits + closure) via
`oi-publish-wave.sh` → s3.solnix.io/solnix-cache, all `200 OK`, failed=0.
(cache.solnix.io is the CDN read path; propagation lags s3 by a few minutes.)

## The illumos fixes landed in solaris-overlay.nix (native, not cross)

These are additive overrides on the upstream nixpkgs expressions. The aarch64
waves used the same *classes* of fix; here they are applied natively (no
cross-compiler, no cross-python hacks — just the illumos portability layer).

1. **rhash** — nixpkgs passes `--target=x86_64-unknown-solaris`; rhash's
   configure only matched `sunos|solaris2.*`, so the bare `solaris` OS token
   yielded `UNKNOWN` and aborted. Broadened the case to add `solaris`.
   (`doCheck = false` — the ni-test binary is irrelevant.)

2. **libuv** — the test binary `run-tests` failed to link (kstat/openpty
   symbols) during `make check`. Library itself builds fine → `doCheck = false`.

3. **libarchive** — test-suite fails on illumos; the library builds → `doCheck = false`.

4. **cmake** — three distinct illumos breaks, all fixed:
   - bootstrap links bundled libuv against `-lkstat -lsendfile` (illumos
     syslibs) → wired `extraSyslibs` `lib/amd64` into the link.
   - `gcc -print-prog-name=ranlib`/`strip` resolve to `/usr/ccs/bin/*`
     (host-only, absent in the sandbox), and the illumos binutils ships `ar`
     but its `bin/ranlib` and `bin/strip` are **dangling symlinks** (never
     built). nixpkgs hard-passes `-DCMAKE_RANLIB=<binutils>/bin/ranlib`, so
     every static-archive link failed `no such file or directory`. Fix: drop
     working shims (`ranlib = ar s`; `strip = no-op`, the store fixup strips)
     and rewrite the assembled `$configureFlags` to point at them.
   - final `bin/cmake` link left `kstat_close`/`sendfile` unresolved (from
     `libuv.so`) → added `-lkstat -lsendfile` to `NIX_LDFLAGS`; `BUILD_TESTING=OFF`.

5. **extra-syslibs FOD** — regenerated the host-illumos syslib tarball
   (`libkstat`/`libsendfile` + closure, `lib/amd64` with `.so` links) and
   repointed the overlay at it (the old store path was gone on this fresh node).

## What was SKIPPED, and the honest reason

**python3-3.14.6 / the meson stack** — the whole modern desktop stack
(harfbuzz, fribidi, pixman, cairo, pango, wayland, wayland-protocols,
libxkbcommon, libinput, libseat/seatd, gdk-pixbuf, graphene, libepoxy, GTK4,
libadwaita) builds with **meson**, whose interpreter is nixpkgs' default
`python3` = **3.14.6**. That python fails to build natively on illumos with a
cluster of *new-in-3.14* portability regressions, hit in order:
   - config.guess can't read `uname -r` in the sandbox (fixed: pin
     `--build=x86_64-pc-solaris2.11`).
   - `Py_SUNOS_VERSION` emitted empty → `socketmodule.c` `#if ... &&
     Py_SUNOS_VERSION <= 510` loses its right operand (fixed: pin to 511).
   - `HAVE_RTPSPAWN` false-positive pulls VxWorks `RTP_ID`/`rtpSpawn`/
     `VX_FP_TASK` (fixed: force-undef).
   - Linux-only `lchmod`/`close_range`/`pthread_getattr_np` under
     `-Werror=implicit-function-declaration` (fixed: downgrade to warning).
   - **`_freeze_module` is `Killed` at runtime** during frozen-module codegen
     (the just-built interpreter crashes). This is the wall.
   - **And** even a fixed top-level `python3` does not reach meson: meson pulls
     python3 through a *different* attribute path that bypasses the overlay
     override (observed the original unpatched drv hash in the meson closure).

   Past the ">2 tries" threshold on a single package with a runtime crash and a
   plumbing mismatch → SKIPPED this stage. The five source-level fixes above are
   left in the overlay for the next attempt (which should target an older
   python — 3.11/3.12 predate the VxWorks/close_range regressions — or wire the
   overlay onto the meson-facing python attribute).

**fontconfig** — autotools (no python), but eval currently fails on a
bintools-wrapper assertion via a doc/gperf dep. Not chased this stage.

## Roadmap to the x86_64 COSMIC desktop ISO

Stage 1 (this): **build toolchain unblocked** — cmake on illumos + freetype
(font leaf). ✅

Next stages, in order:
1. **python3 + meson** — the gating blocker. Either (a) build an older python3
   (3.11/3.12) and point meson at it, or (b) fix python3-3.14's `_freeze_module`
   runtime crash and wire the overlay onto meson's python attribute. Everything
   below is meson and waits on this.
2. **font/render stack** — fontconfig, harfbuzz, fribidi, pixman, cairo, pango,
   gdk-pixbuf, graphene, libepoxy. Same illumos portability classes as the
   aarch64 waves 13–15, applied natively. Unblocks once meson works.
3. **Wayland base** — wayland (illumos getpeerucred + native-epoll port from
   aarch64 wave15), wayland-protocols, libxkbcommon, libinput, libseat/seatd.
   The COSMIC display/compositor base. All meson.
4. **GTK4 + libadwaita** — the aarch64 wave16/17 recipe (introspection/
   gstreamer/x11 off, wayland on) applied native. Native is easier than the
   aarch64 cross.
5. **cross-rust / native-rust** — the x86 rust seed works native (Tier-2
   x86_64-unknown-illumos); build-std for the COSMIC Rust crates.
6. **COSMIC crates** — smithay + the cosmic-* crate graph; per-crate illumos
   integration.
7. **compositor** — cosmic-comp on a Wayland session.
8. **the ISO** — hybrid BIOS+UEFI graphical installer with the COSMIC session.

The COSMIC ISO is several waves out; this stage lays the toolchain foundation.

## Honest gap: Firefox and Chrome (out of scope, roadmap only)

- **Firefox** — not ported to illumos (its build wants a Rust/clang/toolchain
  and platform glue that has no illumos target today). Would be a large port,
  not a wave.
- **Chrome/Chromium** — closed-source (Chrome) / no illumos target
  (Chromium's build assumes Linux/mac/win). Not buildable on illumos. Document
  only.

Neither is in scope for the COSMIC desktop stack. A COSMIC install would ship
without a mainstream browser until one is ported (a separate, large effort).
