# x86_64-solaris COSMIC stack — Stage 3 (native)

Native x86_64-solaris (illumos) build. Goal: the foundation for a graphical
x86_64 COSMIC desktop ISO. Stage 1 unblocked cmake + the font leaf. Stage 2
wired python3/meson/ninja + built the first meson render leaves (pixman,
fribidi, wayland-protocols, libxkbcommon). Stage 3 CLEARS THE RENDER/TOOLKIT
GATE: glib native, the full harfbuzz/cairo/pango/gdk-pixbuf/graphene cascade,
and the wayland core — all as native ports of the proven aarch64 wave14/15
recipes.

## Headline: the glib libintl gate is CLEARED (wave14 native), and the whole render swath + wayland core build

Stage 2 stalled on the GNU-vs-native libintl linkage. Stage 3 took the report's
option (a) — make glib bind the NATIVE plain-name gettext family — and the fix
cascaded: glib -> graphene/harfbuzz/cairo/gdk-pixbuf/pango all build, and
wayland core builds via illumos's native epoll (EASIER than the anticipated
wave15 event-ports port).

### GAP 1 — glib (the render-lib gate): CLEARED

WHY stage 2 failed: glib/ggettext.c does an UNCONDITIONAL `#include <libintl.h>`
(outside the ENABLE_NLS guard) and calls bindtextdomain/bind_textdomain_codeset/
dgettext/textdomain/gettext. The GNU gettext nativeBuildInput put its
`<libintl.h>` on the include path, which `#define`s those -> `libintl_*` — names
the native `/lib/amd64/libintl.so.1` (plain SUNW ABI) does not export. Adding
`-L${gettext}/lib` did not flip resolution (native `/lib` search wins).

THE STAGE-3 FIX (native, wave14 class):
  - Drop the GNU `gettext` nativeBuildInput (its `<libintl.h>` leaves the path).
  - Prepend a native `libintl.h` shim (`/root/solnix-intl-include/libintl.h`,
    plain SUNW prototypes) via `-I` so glib's meson probe
    `cc.has_function('ngettext', prefix:'#include <libintl.h>')` compiles and
    glib takes the system-intl path (never the internal-proxy `assert` at
    meson.build:2353). illumos ships the whole family natively:
    `libintl.so.1` (gettext/dgettext/dcgettext/textdomain/bindtextdomain) +
    `libc.so.1` (bind_textdomain_codeset/ngettext/dngettext/dcngettext).
  - Link native `-L/lib/amd64 -lintl`; add `-D_XOPEN_SOURCE=600 -D__EXTENSIONS__
    -D_POSIX_PTHREAD_SEMANTICS` for the CMSG_* / getpwuid_r decls.
  - `-Dintrospection=disabled -Dtests=false -Dnls=disabled`, drop the `devdoc`
    output and the gi-docgen/gobject-introspection nativeBuildInputs (g-i's
    gi-docgen dies on the spliced build/host python3 hash mismatch; COSMIC/Rust
    needs no .gir typelibs).

VERIFIED: `libglib-2.0.so.0.8800.1` — ELF 64-bit AMD64, `NEEDED libintl.so.1`
(native plain names) + `libiconv.so.2` + `libc.so.1`; host-free (no /root or
/tmp refs). gio/gobject/gmodule all present.

### The render cascade (all wait only on glib): ALL BUILT

  - **graphene 1.10.8** — meson probes memalign/aligned_alloc/posix_memalign but
    illumos gates all three behind `__EXTENSIONS__`/`_XOPEN_SOURCE` in
    `<stdlib.h>` -> "No aligned malloc function could be found." Fix: expose the
    SUS decls. Dropped the `installedTests` output.
  - **harfbuzz 13.2.1** — introspection + docs off (drop gtk-doc/docbook, which
    pull the gi-docgen/sphinx chain).
  - **cairo 1.18.4** — `-Dgtk_doc=false`, drop the `devdoc` output.
  - **pango 1.57.1** — docs/introspection/man-pages off; same native-libintl fix
    as glib (pango uses the `_()` gettext macros); `FONTCONFIG_FILE` pointed at a
    plain system path so the makeFontsConf->dejavu->fontforge chain leaves.
  - **gdk-pixbuf 2.44.6** — docs/introspection off; same native-libintl fix
    (`gdk-pixbuf-util.c` emitted `libintl_bindtextdomain`); TIFF loader dropped
    (`libtiff = null`, `-Dtiff=disabled`); PNG (libpng/zlib) + JPEG (libjpeg,
    SIMD off) stay.

Shared cuts that unblocked the cascade (all documented in the tranche):
  - **fontconfig** — `dejavu_fonts` stubbed to an empty dir + `--with-default-
    fonts=/usr/share/fonts`, so the dejavu -> fontforge -> libtiff + sphinx ->
    pystemmer (non-PIC libstemmer.a -> Solaris ld "relocations remain against
    allocatable but non-writable sections") chain leaves the graph.
  - **libtiff** — drop sphinx docs + the `doc` output.
  - **libjpeg-turbo** — `-DWITH_SIMD=0` + drop nasm (nasm fails on illumos:
    htole64/htole32 -> no `<endian.h>`; zlib.h not found).
  - **time-machine / fonttools** (python) — `doCheck=false` (illumos tz + rmtree
    test-harness quirks, not lib defects).

VERIFIED: cairo/pango/harfbuzz/graphene/gdk-pixbuf libs all ELF 64-bit AMD64.

### GAP 2 — wayland core: BUILT (native epoll, NOT the wave15 event-ports port)

The report anticipated porting event-loop.c to illumos event-ports. But illumos
ALREADY provides native `epoll_create/epoll_ctl/epoll_wait`, `signalfd`,
`timerfd_create`, `eventfd`, `getpeerucred`, `port_*` in libc + `<sys/*.h>` —
EASIER than the aarch64 cross. wayland's meson only pulls `epoll-shim` on
freebsd/openbsd; on solaris it assumes native epoll. So:
  - Drop nixpkgs' `epoll-shim` buildInput (it needs `<sys/event.h>`/kqueue,
    absent on illumos).
  - Inject an illumos `getpeerucred(3C)` arm into `wayland-os.c` (which otherwise
    `#error`s — it has neither FreeBSD LOCAL_PEERCRED nor Linux SO_PEERCRED). The
    arm uses getpeerucred + ucred_geteuid/getegid/getpid/free.
  - Re-enable the scanner (`wayland-scanner` — COSMIC needs the codegen tool);
    add `expat` + `libxml2` buildInputs the scanner needs.
  - Link `-lsocket -lnsl` (`_XPG4_2`/`__EXTENSIONS__` maps socket()/connect()/
    accept()/listen() to `__xnet_*` in libsocket).
  - `-D_XOPEN_SOURCE=600 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS`.

VERIFIED: `libwayland-client.so`, `libwayland-server.so` — ELF 64-bit AMD64;
`libwayland-server` NEEDs `libsocket.so.1` + `libc.so.1` (getpeerucred).
`wayland-scanner` — AMD64 executable.

## NEW x86_64-solaris packages this stage (7, ELF-verified)

| package          | store path                                                 | kind      |
|------------------|------------------------------------------------------------|-----------|
| glib 2.88.1      | zz4lki88mzzyzym0nnsjysc3hk6q1421-glib-2.88.1               | AMD64 .so |
| graphene 1.10.8  | gma9mhrs8hg97ig2xgg74w9jlkjkdvz6-graphene-1.10.8           | AMD64 .so |
| harfbuzz 13.2.1  | f4k5hmygik04m58njmr7jyf24vrr5y6d-harfbuzz-13.2.1           | AMD64 .so |
| cairo 1.18.4     | wry1dv5l9dr5pbm6n06gd1zwqnbvv2i0-cairo-1.18.4              | AMD64 .so |
| gdk-pixbuf 2.44.6| 87iq1x8mavy9dbdwldrwiin59lr8703b-gdk-pixbuf-2.44.6         | AMD64 .so |
| pango 1.57.1     | lk5mi7rk9dc4bdh66214dndagh5hpqw8-pango-1.57.1              | AMD64 .so |
| wayland 1.26.0   | wbs749x2qhivx35sl75r443gadh8hn3d-wayland-1.26.0            | AMD64 .so + scanner |

Published: **17 store paths** (the 7 packages + their dev/bin splits) via
`oi-publish-wave.sh` -> s3.solnix.io/solnix-cache; the full render+wayland
closure (882 paths) is on the cache (`failed=0` on the settled run).

Paths file: `/root/x86-cosmic-stage3-paths.txt`.
Wired tranche: `/root/tranche-stage3.nix` (extends `/root/tranche-stage2.nix`).
Shim: `/root/solnix-intl-include/libintl.h`, `/root/wl-illumos-arm.c`,
`/root/solnix-ld-noverscript.sh`.

## What is BLOCKED, and the honest reason (deferred to stage 4)

  - **GAP 3 — libepoxy / libglvnd** — the Solaris link-editor rejects libglvnd's
    GNU `--version-script=*.ver` (wave10 mapfile wall): `ld: fatal: unrecognized
    option '--version-script='`. A PATH `ld` wrapper that strips the token does
    NOT intercept, because libglvnd links via `gcc`/`collect2`, which calls its
    configured (Solaris) ld directly, bypassing PATH. STAGE-4 FIX: strip
    `--version-script` at the cc-wrapper level (the flag only restricts symbol
    visibility, harmless to drop for GL dispatch), OR point gcc at the store GNU
    ld (`-B`/`-fuse-ld`; a GNU ld 2.46.1 exists at `/usr/gnu/bin/ld` and
    understands `--version-script`), OR translate the `.ver` files to Solaris
    `-M` mapfiles. libepoxy is a GL-dispatch dep, not the toolkit gate.

  - **GAP 4 — seatd / libseat** — the `nativeLibc && noLibc` assert is FIXED
    (`systemdSupport = false` drops the Linux-only systemd dep; the builtin
    backend stays). It now COMPILES but hits `#error Unsupported platform` in
    `common/drm.c` (DRM device-close `DRM_IOCTL_*` ioctls) and `seatd/client.c`
    (fd-passing) — they have `__linux__`/`__FreeBSD__`/`__NetBSD__` arms and no
    `__sun` arm. STAGE-4: add illumos arms (the DRM ioctl set + client fd-pass;
    illumos has DRM via `/dev/dri` + the standard SCM_RIGHTS fd-passing).

  - **libinput / udev** — unchanged: illumos has no udev (device enumeration is
    devfs/`di_*`); needs a device-discovery shim. Lowest priority (input can
    come after the render stack).

## Roadmap to the x86_64 COSMIC desktop ISO

Stage 1: build toolchain (cmake + freetype). DONE.
Stage 2: python3/meson WIRED + the meson render leaves. DONE.
Stage 3 (this): **the render/toolkit gate** — glib (wave14 native libintl) +
the harfbuzz/cairo/pango/gdk-pixbuf/graphene cascade + **wayland core** (native
epoll + getpeerucred, simpler than the wave15 event-ports port). DONE.

Next stages, in order:
1. **libepoxy** — strip `--version-script` at the cc-wrapper level (or use the
   store GNU ld). The GL dispatch base.
2. **seatd/libseat illumos arms** — port `common/drm.c` + `seatd/client.c` to
   `__sun` (DRM ioctls + SCM_RIGHTS fd-pass). The seat-management base.
3. **libinput udev shim** — device discovery via devfs/`di_*`.
4. **GTK4 + libadwaita + appstream** — the aarch64 wave16/17 recipe
   (introspection/gstreamer off, wayland on), native. Now unblocked on glib +
   the render swath + wayland.
5. **cross-rust / native-rust** + **COSMIC crates** (smithay + cosmic-*).
6. **compositor** (cosmic-comp) + **the ISO**.

## Honest gap: Firefox and Chrome (out of scope, roadmap only)

Unchanged: Firefox has no illumos target (large port); Chrome/Chromium is
closed / has no illumos build target. A COSMIC install ships without a
mainstream browser until one is ported (a separate, large effort).
