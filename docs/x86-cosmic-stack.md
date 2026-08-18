# x86_64-solaris COSMIC stack — Stage 5 (native): toolkit complete + seatd

Native x86_64-solaris (illumos) build. Stage 5 lands the **headline milestone**:
**libadwaita-1.9.2 built native** (the GTK4 widget layer COSMIC/GNOME apps use),
by clearing the last blocker — xapian's libtool/libuuid link — and the entire
appstream chain behind it. Bonus: **seatd/libseat 0.9.3 built** (GAP 4 cleared)
with illumos DRM/peer-cred/VT arms. The x86_64 COSMIC **toolkit is complete**.

Wired tranche: `/root/tranche-stage4.nix` (stage-4 file, extended in place).
Paths file: `/root/x86-cosmic-stage5-paths.txt`.

## HEADLINE: libadwaita-1.9.2 built native — toolkit complete

`libadwaita-1.so.0` (2.9 MB) — ELF 64-bit AMD64, host-free. NEEDED shows the
full widget stack: `libgtk-4.so.1`, `libappstream.so.5`, `libpango-1.0.so.0`,
`libgraphene-1.0.so.0`, `libglib/gio/gobject-2.0.so.0`, `libfribidi.so.0`,
native `libintl.so.1` + `libm.so.2` + `libc.so.1`. Store path:
`/nix/store/a64hrv0xfpn5949418j15d114yarbqcy-libadwaita-1.9.2`.

libadwaita needed one relaxed flag: native libintl's `dngettext`/`gettext` lack
glibc's `__format_arg__` attribute, so gcc flagged the (literal) `dngettext()`
printf format as non-literal under `-Werror=format-nonliteral`. The strings ARE
literals; `-Wno-error=format-nonliteral` in `NIX_CFLAGS_COMPILE` (appended AFTER
meson's `-Werror=...`) relaxes it. Everything else was appstream (below).

## GAP 1 CLEARED: xapian 1.4.31 — the libtool/libuuid link, solved

The stage-4 blocker was xapian's libtool link. This stage found the real shape:
not a dropped `-L`, but libuuid's **transitive dependency closure**. Linking
`-luuid` (illumos `/lib/amd64/libuuid.so.1`) pulls its DT_NEEDED chain
(libdladm/libscf/libvarpd), whose OWN indirect deps (libexacct/libpool/
libsmbios/libidspace/librename) live ONLY in `/usr/lib/amd64`, not `/lib/amd64`.
The Solaris ld resolves the full indirect closure at link and errors if any
member is unfindable. Fix: put BOTH lib dirs on `-L` at the build link
(`-L/lib/amd64 -L/usr/lib/amd64 -luuid -lsocket -lnsl` in `preBuild`, after
configure's uuid conftest passed via the pre-seeded cache var). `-lsocket`
covers `gai_strerror` in error.cc.

`libxapian.so.30.14.3` — ELF AMD64, NEEDED libuuid/libz/libstdc++/libm/librt/
libgcc_s/libc/libsocket/libnsl. Host-free.

## appstream 1.1.3 built — the whole chain, native

With xapian linking, appstream cascaded through several new illumos cuts:

  - **libblake3 — `useTBB=false`.** Its `useTBB` defaults to `availableOn
    onetbb`, dragging onetbb -> hwloc -> Solaris PICL (hwloc's `-lpicl` indirect
    lib unresolved on the hermetic path). TBB is optional (multi-threaded
    hashing only); off collapses the whole onetbb/hwloc chain.
  - **libfyaml 0.9.6 — endian + cfmakeraw.** Its `libfyaml-endian.h` only knew
    `__linux__`/`__APPLE__`/BSD/Windows and `#error`ed on illumos. illumos ships
    a glibc-compatible `<endian.h>` (`__BYTE_ORDER` + `htole*`/`le*toh`), so add
    `__sun` to the `<endian.h>` branch. Also injected the standard BSD raw-mode
    `cfmakeraw()` (illumos lacks it) as a `__sun`-guarded helper in fy-utils.c.
  - **libstemmer 2.2.0 — `-fPIC`.** Snowball's GNUmakefile builds `libstemmer.a`
    with no `-fPIC`, so linking the archive into `libappstream.so` tripped the
    Solaris ld "relocations remain against allocatable but non-writable
    sections" (text relocs in a shared object). `NIX_CFLAGS_COMPILE = -fPIC`.
  - **libzstd — added `final.zstd`.** appstream 1.1.3 hard-requires libzstd; not
    in its recipe inputs. Added the (host-free, already-cached) nixpkgs zstd.
  - **libxml2 (python variant, via itstool) — DROPPED.** Its 2.15 python binding
    generator now parses doxygen XML (doxygen -> spdlog -> catch2 fails gcc-10
    illumos `Catch::isnan`). A doxygen stub failed (generator needs real XML),
    so instead **itstool is removed entirely**: itstool only l10n-translates
    appstream's OWN cli metainfo XML (not needed by the library/libadwaita). A
    `postPatch` deletes the `i18n.itstool_join` target + its validate test, so
    itstool -> python-libxml2 -> doxygen leaves the graph.
  - **xmlto / man-db — DROPPED.** appstream hardcodes xmlto (doc gen), which
    pulls man-db -> libpipeline, whose Solaris libtool NM probe emits an empty
    global_symbol_pipe (`nm ... | | sed`) and dies. Docs are off; xmlto is never
    invoked, so it + its man chain are filtered from nativeBuildInputs.
  - **perl added.** appstream's patchPhase evals a string hook that shells to
    perl (the fix-paths substitute), not otherwise in its native inputs.
  - **`-Dcompose=false`** (drops the Rust librsvg), `-Dvapi=false`, introspection
    + systemd off — as before.

`libappstream.so.1.1.3` (soname `libappstream.so.5`) — ELF AMD64, host-free.
Store: `/nix/store/rh6q8411xp8r2z2m5rii47rvdh15g4c0-appstream-1.1.3`.

## GAP 4 CLEARED: seatd / libseat 0.9.3 — illumos arms wired

Stage-3 had seatd `systemdSupport=false` compiling but `#error`ing on the
missing `__sun` platform arms. This stage added them all:

  - **common/drm.c** — `path_is_drm()`: illumos DRM is `/dev/dri/` (same as
    Linux), so add `__sun` to the Linux branch. Also `#include <sys/ioccom.h>`
    for the `_IO()` macro (illumos `<sys/ioctl.h>` doesn't pull it; the DRM
    ioctl encoding `_IO('d', nr)` is identical to Linux).
  - **seatd/client.c** — `get_peer()`: illumos peer creds come from
    `getpeerucred(3C)` + `ucred_get{pid,euid,egid}()` (`<ucred.h>`), not Linux
    `SO_PEERCRED`.
  - **common/terminal.c** — the VT/KD layer. illumos `<sys/vt.h>` has the VT_*
    ioctls + `struct vt_mode`/`vt_stat` (`v_active`), `<sys/kd.h>` has
    KDSETMODE/KD_TEXT/KD_GRAPHICS. VT devices are `/dev/vt/N`. illumos has no
    KDSKBMODE keyboard-mode ioctl (K_XLATE/K_RAW); COSMIC/wlroots drives input
    via libinput/evdev, not the console keyboard, so `terminal_set_keyboard` is
    made inert on `__sun` (return 0).
  - **libseat.so link** — GNU `-Wl,--version-script` (the mapfile wall) dropped
    (`symbols_flag = []` in meson.build; symbol versioning is not required for
    correctness). Added `-lsocket -lnsl` (accept/shutdown/__xnet_* live there).

`libseat.so.1` — ELF AMD64, NEEDED librt/libsocket/libc. `seatd` daemon —
ELF AMD64 executable. Both host-free.
Store: `/nix/store/lkf84g6ifw25g84r6niig8zk685vxmrq-seatd-0.9.3`.

## Task 2 (native rust + a COSMIC crate) — DEFERRED, honest gap

The x86 rust seed described (`rust-illumos-seed.nix`, rust-illumos-1.97.1,
`rust-patches/`, the aarch64 cosmic-rust rlibs) is **not present on this host**
(fred v3). A filesystem search found only the fetched `rustc-1.97.0-src.tar.gz`
FOD — no built rustc/cargo, no illumos rust target JSON, no bootstrap. Building
rust natively from scratch on illumos requires a stage0 bootstrap rustc + the
compiler port, and even eval hits the bintools-wrapper `!(nativeLibc && noLibc)`
assert (`bintools-wrapper/default.nix:65`) — the known Rust-on-illumos wall.
This is a multi-hour stage of its own (the roadmap's own "cross-rust / native-
rust" item), well beyond a bounded budget, so it is deferred rather than ground
into a wedge. NEXT: transplant the aarch64 rust seed + rust-patches to fred v3,
realize `rust-illumos-1.97.1`, then a native COSMIC crate (cosmic-text /
iced_core / wayland-backend with the illumos patch) should compile to an
x86_64-illumos rlib (the aarch64 side already proved the crates cross-build).

## libinput / udev — UNCHANGED (lowest priority, deferred)

illumos has no udev (device enumeration is devfs/`di_*`); libinput needs a
device-discovery shim. Not attempted this stage (budget spent on the headline +
seatd). seatd now provides the seat-management half of the input story.

## NEW x86_64-solaris packages this stage (8, ELF-verified)

| package             | store path                                              | kind |
|---------------------|---------------------------------------------------------|------|
| libadwaita 1.9.2    | a64hrv0xfpn5949418j15d114yarbqcy-libadwaita-1.9.2       | AMD64 .so (libadwaita-1, the widget layer) |
| appstream 1.1.3     | rh6q8411xp8r2z2m5rii47rvdh15g4c0-appstream-1.1.3        | AMD64 .so (libappstream.so.5) |
| xapian 1.4.31       | v8cplbxqni4ampmf7d88s6k8cv9gbwpg-xapian-1.4.31          | AMD64 .so (libxapian.so.30) |
| libfyaml 0.9.6      | 44dhrx7s97lm1h4skpz7hbvzh0m4v6fh-libfyaml-0.9.6-bin     | AMD64 .so (YAML, endian+cfmakeraw) |
| libstemmer 2.2.0    | 4iiff3bcbfzaah3d9czhph3vzx54a0i1-libstemmer-2.2.0       | AMD64 .a (PIC) |
| libblake3 1.8.5     | jzwb3zvz4g20hnxxlnmhalbs48qj3xgj-libblake3-1.8.5        | AMD64 .so (TBB off) |
| zstd 1.5.7          | vmdzrg6q245vgyandcl05zx23xfcfmln-zstd-1.5.7-bin         | AMD64 .so |
| seatd/libseat 0.9.3 | lkf84g6ifw25g84r6niig8zk685vxmrq-seatd-0.9.3            | AMD64 .so + daemon (illumos DRM/ucred/VT arms) |

Published via `oi-publish-wave.sh` -> the cache: **88 new store paths** in the
libadwaita/appstream wave (`failed=0`), then **3 more** for the seatd closure
(`failed=0`). The full libadwaita closure (gtk4 + appstream + widget layer) is
on the cache.

## Roadmap to the x86_64 COSMIC desktop ISO

Stage 1: build toolchain (cmake + freetype). DONE.
Stage 2: python3/meson + the meson render leaves. DONE.
Stage 3: the render/toolkit gate — glib + render cascade + wayland core. DONE.
Stage 4: **GTK4 (Wayland+EGL) + libepoxy** + the appstream chain up to libxmlb.
DONE.
Stage 5 (this): **libadwaita-1.9.2 (toolkit complete)** via xapian + the full
appstream chain, plus **seatd/libseat (GAP 4 cleared)**. DONE.

Next stages, in order:
1. **native rust** — transplant the aarch64 rust seed + rust-patches, realize
   `rust-illumos-1.97.1`, prove a COSMIC crate compiles to an x86_64-illumos
   rlib. (Blocked here only by the seed material not being on fred v3.)
2. **libinput udev shim** — device discovery via devfs/`di_*`.
3. **COSMIC crates** (smithay + cosmic-*) + **cosmic-comp** (compositor).
4. **the ISO**.

## Honest gap: Firefox and Chrome (out of scope, roadmap only)

Unchanged: Firefox has no illumos target; Chrome/Chromium is closed / has no
illumos build target. A COSMIC install ships without a mainstream browser until
one is ported (a separate, large effort).

---

# (Stage 4 record — retained below)

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
