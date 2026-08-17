# x86_64-solaris COSMIC stack — Stage 2 (native)

Native x86_64-solaris (illumos) build. Goal: the foundation for a graphical
x86_64 COSMIC desktop ISO. Stage 1 unblocked cmake + the font leaf
(freetype/brotli/libuv). Stage 2 landed the WIRING FIX that unblocks the entire
meson desktop stack, then built the meson toolchain and the first tier of
meson-based render libraries.

## Headline: python3 + meson WORK natively on illumos x86_64

Stage 1 reported "python3/meson blocked" — but that was a **wiring gap**, not a
real block. The illumos CPython 3.14 fix set already existed (proven by the
pip-class wave that built requests/rich/flask); stage 1's tranche simply never
imported it. Stage 2 wired it in.

### The wiring fix (STEP 0 — verified)

`fixPy` applies the illumos CPython-3.14 fix set to BOTH `python3` and
`python314`, and aliases `python3 = python314` so python3Packages / meson's
build-platform python and the top-level python3 are the SAME derivation:

  - `--build=x86_64-pc-solaris2.11` (config.guess can't read UNAME_RELEASE in
    the sandbox; overwrite the regenerated config.guess post-autoreconf).
  - `LDSHARED='$CC -shared -Wl,-z,nodefs'` (extension modules leave CPython
    C-API symbols unresolved, bound at import; Solaris ld needs `-z nodefs`).
  - `sed Py_SUNOS_VERSION <= 510 -> 0` in socketmodule.c (empty macro ->
    `&& <empty> <= 510` cpp error).
  - `ac_cv_header_libintl_h=no` / `ac_cv_lib_intl_textdomain=no` (a GNU
    libintl.h leaks in and emits `libintl_*` calls that the native `-lintl`
    can't resolve on `_freeze_module`).
  - `withZstd = false`, `disallowedReferences = []`, `doCheck = false`.

Plus, for the meson backend:
  - **ninja** — patched `subprocess-posix.cc` to `fork()+execvp()` instead of
    `posix_spawn` (this illumos kernel lacks the SYS_spawn fast path and libc
    does not fall back -> `posix_spawn` traps SIGSYS "Bad System Call"). Applied
    after nixpkgs' spawn-sh patch so it rebases cleanly.
  - **libffi / asciidoc** — `doCheck = false` (dejagnu/expect need BSD ptys;
    asciidoc's pytest is fragile).
  - **meson** — `doCheck = false` (its build-time test suite runs Linux-only
    linker-script/ld-binary tests).

VERIFICATION (all confirmed on-node):
  - `python3.14 --version` -> `Python 3.14.6`, ELF 64-bit AMD64.
  - `import ctypes, ssl, _ssl, _ctypes` -> OK, `OpenSSL 3.6.3`.
  - `meson --version` -> `1.10.2`; its interpreter shebang is the FIXED
    `python3.14` (the meson-facing python attr resolves the fixed interpreter).
  - `ninja` -> AMD64 ELF, built with the fork-exec patch; drives real meson
    builds (pixman's meson test suite ran + passed under it).

## NEW x86_64-solaris packages this stage (7, ELF-verified where applicable)

| package             | store path                                                   | kind        |
|---------------------|--------------------------------------------------------------|-------------|
| python3 3.14.6      | 5d3rrvmhmr0jjzklzj51jk17plswypbd-python3-3.14.6              | AMD64 exe   |
| ninja 1.13.2        | 753yp8zgjyyylkn1mhmh7lla3vm9n7xx-ninja-1.13.2                | AMD64 exe   |
| meson 1.10.2        | irsw3akxzsazq6qj27lqgsm55bh0c9xj-meson-1.10.2                | py tool     |
| pixman 0.46.4       | 31kmbpsp7adc02cqqsrwzv2wg7jsbcy3-pixman-0.46.4               | AMD64 .so   |
| fribidi 1.0.16      | iy4vvxxq99hf2ac4wb0slb9f5bssqiqr-fribidi-1.0.16              | AMD64 .so   |
| wayland-protocols 1.49 | n351kx8kxlh84x1n9n1bnga1ggk8hhi5-wayland-protocols-1.49    | data        |
| libxkbcommon 1.13.2 | vzzlz9s5w8f67s8z5hw6a5lq7270w6z1-libxkbcommon-1.13.2         | AMD64 .so   |

Published: **31 store paths** (the 7 packages + their dev/lib splits + closure,
including libxcb / libX11 pulled by libxkbcommon) via `oi-publish-wave.sh` ->
s3.solnix.io/solnix-cache, all `200 OK`, `failed=0`.

Paths file: `/root/x86-cosmic-stage2-paths.txt`.
Wired tranche: `/root/tranche-stage2.nix` (`/root/tranche-224.nix` + fixPy +
ninja fork-exec + the desktop-libs overlay).

## The illumos fixes landed in the desktop-libs overlay (native, aarch64 recipe)

  1. **charset-normalizer withMypyc=false** (via `pythonPackagesExtensions`) —
     its mypyc/Rust speedup extension (`ast-serialize -> cargo ->
     cargo-bootstrap`, which has no illumos libc config -> `assert
     !(nativeLibc && noLibc)`) is the ROOT of the sphinx -> requests ->
     charset-normalizer -> rust chain that every docs-building meson lib drags
     in via gobject-introspection -> fontconfig docs. Turning it off unblocks
     cairo/harfbuzz/pango/gdk-pixbuf eval in one place.

  2. **harfbuzz / graphene withIntrospection=false** — g-i pulls the same doc
     chain; COSMIC (Rust) does not need the `.gir` typelibs.

  3. **wayland withDocumentation=false, withTests=false** — native host==build
     defaults docs on, pulling graphviz/doxygen -> the rust doc chain.

  4. **libxkbcommon** — `-Denable-docs=false`, drop doxygen (which pulls the
     unfixed full cmake -> rhash bootstrap), drop the empty `doc` output,
     `doCheck=false`. BUILDS.

## What is BLOCKED, and the honest reason (deferred to stage 3)

These are all **real illumos platform gaps** (not wiring), each needing a source
port. Each was tried and hit a hard portability wall; per the ">2 tries SKIP"
rule they are documented for stage 3.

  - **glib 2.88** — the render-lib gate (harfbuzz-gobject, cairo, pango,
    gdk-pixbuf all need it). Cleared four illumos breaks (gi-docgen python-hash
    mismatch -> dropped; `<byteswap.h>` in libsysprof-capture -> `-Dsysprof=
    disabled`; no `getxattr()` -> `-Dxattr=false`; sysprof wrap subproject ->
    disabled). The remaining wall is the **libintl linkage**: glib's ggettext.c
    includes GNU gettext's `libintl.h` (redefines `gettext -> libintl_gettext`),
    but `-lintl` resolves to illumos's native `/lib/libintl.so.1` (SONAME
    `libintl.so.1`, plain names only) instead of the store GNU gettext
    (`libintl.so.8`, which HAS `libintl_*`) -> `ld: fatal: symbol referencing
    errors`. Even `-Dnls=disabled` + `-L${gettext}/lib` did not flip the
    resolution (the illumos linker's default `/lib` search wins). The stage-3
    fix is either (a) the python approach — hide GNU libintl.h so glib uses
    libc's native plain-name gettext — or (b) force `-l:libintl.so.8` / an
    absolute-path link so the GNU lib binds.

  - **wayland (core lib)** — `event-loop.c` uses `<sys/epoll.h>`,
    `<sys/signalfd.h>`, `<sys/timerfd.h>`. illumos has NEITHER epoll NOR kqueue
    (nixpkgs pulls `epoll-shim`, which needs `<sys/event.h>` -> also fails).
    Needs a native illumos **event-ports** (`port_create`/`port_associate`)
    port of event-loop.c. The aarch64 wave15 did exactly this port; mirror it
    native.

  - **libinput** — pulls `udev-check-hook`; illumos has no udev (device
    enumeration is devfs/`di_*`). Needs an illumos device-discovery shim.

  - **seatd/libseat** — same `nativeLibc && noLibc` assert via a Linux-only dep.

  - **libepoxy** — its `libGL` (= libglvnd) dep fails: illumos ld rejects GNU
    `--version-script=...ver`; Solaris ld uses `-M mapfile`. Needs libglvnd's
    meson patched to emit Solaris mapfiles (multiple `.ver` files), or libepoxy
    built `x11Support=false` (loses GL, not useful for the render stack).

## Roadmap to the x86_64 COSMIC desktop ISO

Stage 1: **build toolchain** — cmake on illumos + freetype (font leaf). DONE.
Stage 2 (this): **python3/meson WIRED + working** + the meson toolchain
(ninja/meson) + the meson render leaves (pixman, fribidi, wayland-protocols,
libxkbcommon). DONE.

Next stages, in order:
1. **glib libintl port** — the render-lib gate. Fix the GNU-vs-native libintl
   linkage (see above). Unblocks harfbuzz-gobject, cairo, pango, gdk-pixbuf,
   graphene, gobject-introspection (the whole font/render meson swath, all of
   which now EVAL and only wait on glib).
2. **wayland event-ports port** — replace epoll/signalfd/timerfd in
   event-loop.c with illumos `port_*` (aarch64 wave15). Then wayland +
   wayland-scanner build; libxkbcommon (built) + wayland-protocols (built) are
   already the rest of the client-protocol base.
3. **libinput udev shim + seatd/libseat** — the input + seat-management base.
4. **libglvnd Solaris mapfiles -> libepoxy** — the GL dispatch base.
5. **GTK4 + libadwaita + appstream** — the aarch64 wave16/17 recipe
   (introspection/gstreamer/x11 off, wayland on), native. Waits on glib + the
   render swath.
6. **cross-rust / native-rust** + **COSMIC crates** (smithay + cosmic-*).
7. **compositor** (cosmic-comp) + **the ISO**.

## Honest gap: Firefox and Chrome (out of scope, roadmap only)

Unchanged from stage 1: Firefox has no illumos target (large port);
Chrome/Chromium is closed / has no illumos build target. A COSMIC install ships
without a mainstream browser until one is ported (a separate, large effort).
