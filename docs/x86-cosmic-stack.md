# x86_64-solaris COSMIC stack — Stage 4 (native): the toolkit gate

Native x86_64-solaris (illumos) build. Stage 3 cleared the render/toolkit
foundation (glib + harfbuzz/cairo/pango/gdk-pixbuf/graphene + wayland core).
Stage 4 lands **GTK4 4.22.4 with the full Wayland+EGL backend** — the toolkit
gate — plus **libepoxy** (the wave10 mapfile wall, solved), and the appstream
support chain up to libxmlb. libadwaita is blocked one dep short (xapian's
libtool/libuuid link).

Wired tranche: `/root/tranche-stage4.nix` (extends `/root/tranche-stage3.nix`).
Paths file: `/root/x86-cosmic-stage4-paths.txt`.
New shim: `/root/solnix-linux-input/linux/input.h` (the BTN_* codes).

## Headline: GTK4 4.22.4 built native, Wayland + EGL backend, ELF-verified

`libgtk-4.so.1.2200.4` — ELF 64-bit AMD64, host-free. NEEDED shows the full
render stack (glib/gobject/gio/pango/harfbuzz/cairo/gdk-pixbuf/graphene),
`libepoxy.so.0`, `libwayland-client.so.0`, `libwayland-egl.so.1`,
`libxkbcommon.so.0`, native `libintl.so.1` + `libc.so.1`. Also produced
`gtk4-wayland.pc` (the Wayland backend is compiled in).

The recipe (native port of the aarch64 wave16 shape):
  - `waylandSupport = true` (COSMIC is Wayland); `x11Support / vulkanSupport /
    trackerSupport / cupsSupport / xineramaSupport / broadwaySupport` all OFF.
    On illumos these all default to `isLinux` = false, except we FORCE wayland
    ON (nixpkgs would leave it off).
  - `-Dintrospection=disabled` (g-i -> gi-docgen dies on the spliced python3
    hash mismatch; COSMIC/Rust needs no .gir), `-Dmedia-gstreamer=disabled`
    (gst-plugins-base pulls valgrind's sourceware fetchpatch + GL), docs off,
    demos/examples/testsuite off.
  - buildInputs filtered: drop `libGL` (= libglvnd, the version-script wall) and
    the gstreamer plugins. GTK4's GL renderer dispatches through libepoxy's
    dlopen layer, so it needs NO link-time libGL — keeping it would re-arm the
    libglvnd mapfile wall.
  - Native-libintl fix (as glib/pango): drop the GNU gettext nativeBuildInput,
    prepend the `/root/solnix-intl-include/libintl.h` shim, link `-L/lib/amd64
    -lintl`; `-lsocket -lnsl` for the Wayland client; the SUS/__EXTENSIONS__
    defines for CMSG_*/getpwuid_r.
  - `postFixup = ""` (the stock postFixup wrapProgram's the demos, which are off).

Two illumos-specific compile fixes GTK4 needed:
  - **`<linux/input.h>`** — `gdkseat-wayland.c` includes it for the BTN_* mouse/
    stylus button codes. illumos has no Linux input subsystem; a shim header
    (`/root/solnix-linux-input/linux/input.h`) carrying just those stable
    input-event ABI constants (BTN_LEFT/RIGHT/MIDDLE/BACK/FORWARD, BTN_STYLUS
    1-3) is on the include path.
  - **`epoxy/egl.h`** — see libepoxy below.

## GAP 3 CLEARED: libepoxy — the wave10 mapfile wall, solved (NOT worked around)

The prior blocker was libglvnd's GNU `--version-script=*.ver`, which the Solaris
ld rejects, and a PATH `ld` wrapper does not intercept (gcc/collect2 calls its
configured Solaris ld directly — confirmed again this stage). The wave10 fix
attempts all fought that wall.

The stage-4 insight: **libepoxy on illumos does not need libglvnd at all.** Build
epoxy with `-Dx11=false -Dglx=no` (drops the libGL/libx11 propagated inputs and
the `-DLIBGL_PATH` env, so libglvnd never enters the graph) but keep
`-Degl=yes` (GTK4's Wayland backend hard-includes `<epoxy/egl.h>`). epoxy's EGL
and GL entry points are dlopen'd at RUNTIME by soname, so `egl=yes` needs no
link-time libEGL/libGL — the version-script wall never appears.

`egl=yes` needs the Khronos `EGL/`+`KHR/` headers at compile. libglvnd's SOURCE
tarball ships them (`include/EGL/*`, `include/KHR/*`), so we copy them out of
`libglvnd.src` (a fetched FOD — no build, no ld wall) into a `runCommand`
include dir, made a **propagatedBuildInput** of epoxy so consumers (gtk4)
inherit the `-I` (epoxy/egl_generated.h includes `<EGL/eglplatform.h>`).

VERIFIED: `libepoxy.so.0.0.0` — ELF 64-bit AMD64, NEEDED only `libdl.so.1` +
`libc.so.1` (pure dlopen dispatch, no GL backend baked in — correct for illumos),
host-free. `epoxy/egl.h` + `egl_generated.h` installed.

## The appstream support chain (for libadwaita): mostly built

libadwaita hard-requires `appstream` (meson.build:43, `required:true`), so it
is not skippable. appstream pulls a deep chain; each layer needed an illumos
cut or shim:

  - **librsvg (Rust) — CUT via `-Dcompose=false`.** appstream's `compose`
    (icon rendering) pulls librsvg 2.62, which is a Rust crate -> cargo-bootstrap
    -> the `nativeLibc && noLibc` bintools assert (Rust is stage 5, not ported).
    The appstream metadata library libadwaita needs does not require compose;
    also dropped `-Dvapi` (vala), `withIntrospection`, `withSystemd`.
  - **doxygen/catch2/spdlog — CUT.** `itstool` -> a `libxml2` (pythonSupport)
    variant that pulls `doxygen` for the python-binding API docs; doxygen drags
    `spdlog` -> `catch2`, which fails to compile on gcc-10 illumos
    (`Catch::isnan` unqualified-lookup). Fix: strip `doxygen` from libxml2's
    nativeBuildInputs (only added under pythonSupport; docs aren't the
    deliverable). Also dropped g-i + gtk-doc on `libxmlb`.
  - **liblzma — SHIMMED (native).** `libxmlb` needs liblzma, but this stack's
    `xz` builds tool-only (`usr/gnu/bin/xz`, no lib/pkgconfig). illumos ships
    native `liblzma.so.5` + `<lzma.h>` in `/usr/lib/amd64` + `/usr/include`, so
    drop the tool-only xz buildInput and synthesize a `liblzma.pc` (on
    PKG_CONFIG_PATH) + explicit `-I/usr/include` pointing at the system lib.
    **libxmlb 0.3.27 built** (`libxmlb.so.2.0.0`, ELF AMD64).
  - **desktop-file-utils — native-libintl fix.** A libadwaita nativeBuildInput;
    a GNU `<libintl.h>` leaked in and it emitted `libintl_gettext` but linked
    native `-lintl` (plain names). Same fix as glib/pango. **Built.**

## What is BLOCKED, and the honest reason (deferred)

  - **libadwaita 1.9.2 — blocked one dep short.** It needs appstream, and
    appstream's last unbuilt dep is **xapian 1.4.31**. xapian needs
    `uuid_generate` (illumos has native `libuuid.so.1` + `<uuid/uuid.h>` in
    `/lib/amd64` + `/usr/include`). We got it configuring (pre-seed
    `ac_cv_search_uuid_generate=-luuid`, `--disable-backend-remote` for the
    misfiring fork() probe) and compiling, but the final **libtool** link drops
    the `-L/lib/amd64` from NIX_LDFLAGS (libtool filters `-L` its own way),
    leaving `ld: library -luuid: not found` / a truncated undefined-symbol
    error. NEXT: give xapian the uuid path in a form libtool preserves — either
    an `LDFLAGS`/`XAPIAN_LIBS` make override that survives libtool, or an
    `extraSyslibs`-style store dir with a bare `libuuid.so` + a proper
    `-L${that}` (the stage-3 cmake pattern), or point xapian at a native
    `uuid.pc`. Once xapian links, appstream -> libadwaita should cascade (all
    other appstream deps built this stage).

  - **GAP 4 — seatd / libseat** — unchanged from stage 3: `systemdSupport=false`
    makes it COMPILE, but `common/drm.c` + `seatd/client.c` `#error` on the
    missing `__sun` arm (DRM close ioctls + SCM_RIGHTS fd-pass). STAGE-5: add
    the illumos arms (illumos has DRM via `/dev/dri` + standard SCM_RIGHTS).

  - **libinput / udev** — unchanged: illumos has no udev (device enumeration is
    devfs/`di_*`); needs a device-discovery shim. Lowest priority.

## NEW x86_64-solaris packages this stage (6, ELF-verified)

| package                | store path                                              | kind      |
|------------------------|---------------------------------------------------------|-----------|
| gtk4 4.22.4            | 6yys6wn20fqysr66dpayyy0dli96gm4c-gtk4-4.22.4            | AMD64 .so (libgtk-4 + wayland) |
| libepoxy 1.5.10        | 7b434b2ill6bdar61p2j9fv5wwchgpam-libepoxy-1.5.10        | AMD64 .so (egl, dlopen dispatch) |
| libxmlb 0.3.27         | vcamha0m92qd00ln3bk6ysli2n9550d5-libxmlb-0.3.27-lib     | AMD64 .so |
| libtiff 4.7.1          | gmy96byf4mvb9hczs3bfi3336liv11ml-libtiff-4.7.1-dev      | AMD64 .so |
| libwebp 1.6.0          | cd7xfdydn5awdp1dws4xqp8izcb8xfvq-libwebp-1.6.0          | AMD64 .so (SIMD off) |
| desktop-file-utils 0.28| mznp23rbmgcdkkbddj54vwx6n1gahcxr-desktop-file-utils-0.28| AMD64 bin |

libtiff needed `-DCMath_HAVE_LIBC_POW=1` (illumos pow is in libc; FindCMath's
probe + find_library(m) both miss the hermetic path) and the `man` output
dropped. libwebp needed `-DWEBP_ENABLE_SIMD=OFF` (the AVX2
`_mm256_cvtsi256_si32` intrinsic is an undefined symbol on gcc-10 illumos).

Published: **54 store paths** (the 6 packages + their new closure) via
`oi-publish-wave.sh` -> the cache; `failed=0`. The full gtk4 closure
(533 already-cached + 54 new) is on the cache.

## Roadmap to the x86_64 COSMIC desktop ISO

Stage 1: build toolchain (cmake + freetype). DONE.
Stage 2: python3/meson + the meson render leaves. DONE.
Stage 3: the render/toolkit gate — glib + render cascade + wayland core. DONE.
Stage 4 (this): **GTK4 (Wayland+EGL) + libepoxy (mapfile wall solved)** + the
appstream chain up to libxmlb. DONE (libadwaita one dep short).

Next stages, in order:
1. **xapian libtool/libuuid link** (above) -> **appstream** -> **libadwaita-1**.
   The one remaining hop for the widget layer.
2. **seatd/libseat illumos arms** (`common/drm.c` + `seatd/client.c`).
3. **libinput udev shim** — device discovery via devfs/`di_*`.
4. **cross-rust / native-rust** + **COSMIC crates** (smithay + cosmic-*).
   Also unblocks librsvg (appstream compose) if wanted.
5. **compositor** (cosmic-comp) + **the ISO**.

## Honest gap: Firefox and Chrome (out of scope, roadmap only)

Unchanged: Firefox has no illumos target; Chrome/Chromium is closed / has no
illumos build target. A COSMIC install ships without a mainstream browser until
one is ported (a separate, large effort).
