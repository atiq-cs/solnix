# desktop/gtk/firefox.nix -- Firefox ESR 153.6.0 for COSMIC/Wayland: cairo-gtk3-wayland-only (no X11 libs at all), OI's
# firefox patch set as of its 153.0.4 commit (oi-userland 7d7fad4aa7; 40 of its 41 patches applied, measured 41/41 on
# 153.6.0esr by cosmic7), gcc (OI 17-clang-not-work), sunaudio (cubeb's Solaris backend; ESR's SunOS default).
# NixOS-shaped (build-mozilla-mach): MOZILLA_OFFICIAL, no updater, no crashreporter, no tests,
# no Google/Mozilla API keys, no EME (configure offers --enable-eme only on Linux/Windows/macOS: no Widevine possible). Telemetry: the
# empty env MOZ_TELEMETRY_REPORTING= turns it off at build time (MOZILLA_OFFICIAL defaults it ON: measured =1 in config.status
# until then); Normandy and health report are browser/moz.configure implies (not settable), so policies.json disables them. The wrapper is
# NixOS's MOZ_ENABLE_WAYLAND=1 (Wayland-only builds ignore it; kept so the env matches NixOS's).
{ mkSrcPkg, tools, gtk, cli, rust, cbindgen, nodejs, llvm-clang, zlib, nixChain, graphics, world, noto-sans, libffi ? graphics.libffi }:
let
  inherit (gtk) glib gtk3 cairo pango harfbuzz fribidi fontconfig freetype gdk-pixbuf libepoxy at-spi2-core libpng libjpeg-turbo pcre2;
  inherit (graphics) pixman wayland wayland-protocols libxkbcommon mesa dbus libdrm expat;
  oi = n: sha256: import <nix/fetchurl.nix> {
    url = "https://raw.githubusercontent.com/OpenIndiana/oi-userland/7d7fad4aa7/components/web/firefox/patches/${n}"; inherit sha256; };
  # OI's list minus 08-branding (points the welcome page at an OI path). sha256 = floki /scratch/solnix/browser1/ff/p153.sha256.
  patches = import ./firefox-oi-patches.nix { inherit oi; };
in
mkSrcPkg {
  pname = "firefox-esr"; version = "153.6.0";
  src = { url = "https://ftp.mozilla.org/pub/firefox/releases/153.6.0esr/source/firefox-153.6.0esr.source.tar.xz";
          sha256 = "91cb675ddfc678255f57ecd7aad498501961577686d19c1947a82b14edea7f25"; };
  # world: rust's std NEEDs libumem.so.1, which the libc slice lacks; without world in RUNPATH it resolved to the host's
  # /lib/64 copy, whose host libc.so.1 then loaded beside the slice's, and every cargo build script SEGVed in libgcc's
  # __register_frame_info (measured: 2 libc.so.1 in the core; nodejs.nix has the same fix for libkstat)
  deps = [ gtk3 glib cairo pango harfbuzz fribidi fontconfig freetype gdk-pixbuf libepoxy at-spi2-core pixman wayland
           libxkbcommon mesa dbus libdrm zlib libffi libpng libjpeg-turbo world ];
  linkDeps = [ wayland-protocols pcre2 expat nixChain.bzip2 nixChain.brotli ];
  build = ''
    ${tools.path}
    for p in ${builtins.concatStringsSep " " patches}; do patch -p1 < "$p"; done
    patch -p1 < ${./patches/firefox-153-wayland-proxy-filio.patch}   # FIONREAD (patch says why)
    # nixpkgs build-mozilla-mach's 136-no-buildconfig.patch (byte-identical): about:buildconfig lists the full compiler
    # command lines, i.e. every build-input store path, which would make the whole toolchain a runtime reference
    patch -p1 < ${./patches/firefox-136-no-buildconfig.patch}
    # vendored bindgen: illumos' `using std::size_t` reached Rust as c_ulong, not usize (patch says why); re-stamps the checksum
    bash ${./vendor-fix.sh} "$PWD" ${./patches/firefox-153-bindgen-illumos-using-size_t.patch}
    # mk-src-pkg's cc/c++ wrappers put every dep's include dir FIRST (-I), ahead of the tree's own -I: mesa's EGL/eglext.h
    # shadowed ANGLE's gfx/angle/checkout/include (PackedEnums.cpp: EGL_TEXTURE_RECTANGLE_ANGLE undeclared; gcc -H shows
    # mesa's egl.h), and the system harfbuzz/cairo headers shadowed the bundled ones in dist/include. -isystem is NixOS's
    # NIX_CFLAGS_COMPILE order: the target's -I, then deps, then the system dirs. Firefox-local: other recipes keep -I.
    for w in "$CC" "$CXX"; do sed -i 's@ -I/nix/store/@ -isystem /nix/store/@g' "$w"; done
    ! grep -q -- ' -I/nix/store/' "$CXX" && grep -q -- ' -isystem /nix/store/' "$CXX" || { echo "FATAL: c++ wrapper rewrite" >&2; exit 1; }
    # mach adds -fstack-protector-strong at link, so gcc's link_ssp spec NEEDs libssp.so.0, which gcc.lib does not ship
    # (firefox: "libssp.so.0: open failed", measured). illumos libc has __stack_chk_fail/__stack_chk_guard: keep the
    # protector, drop the -lssp (measured: an overflow still aborts, NEEDED = libgcc_s libc). $W: a fixed path.
    printf '*link_ssp:\n%%{fstack-protector*:}\n\n' > "$W/nossp.specs"
    for w in "$CC" "$CXX"; do sed -i "s@ -D_TS_ERRNO @ -D_TS_ERRNO -specs=$W/nossp.specs @" "$w"; done
    grep -q -- '-specs=' "$CC" || { echo "FATAL: cc wrapper specs" >&2; exit 1; }
    # libxul.so and the bundled NSS NEED their siblings in lib/firefox (nixpkgs' musl LDFLAGS adds it for the same reason),
    # and it must come FIRST: world's lib-64 has OI's libnss3/libnssutil3/libnspr4, and with lib/firefox last the bundled
    # libnss3 bound world's libnssutil3 ("NSSUTIL_3.101 version not found", measured). ld joins -R in order, so it goes
    # at the head of the wrapper's own -R, not in LDFLAGS (which lands after it).
    # -z nodefaultlib: a bare dlopen("libpulse.so.0") (xpcom nsSystemInfo, for a version string) otherwise fell through to
    # ld.so.1's default /usr/lib, loaded the host's libpulse and its host libc.so.1 beside the store's, and Firefox SEGVed
    # (measured: 2 libc.so.1 in the core). NixOS has no /usr/lib, so there the dlopen just fails; NODEFLIB makes it fail here.
    for w in "$CC" "$CXX"; do sed -i "s@ -Wl,-R,@ -Wl,-z,nodefaultlib -Wl,-R,$out/lib/firefox:@" "$w"; done
    grep -q -- "-Wl,-z,nodefaultlib -Wl,-R,$out/lib/firefox:" "$CXX" || { echo "FATAL: c++ wrapper RUNPATH" >&2; exit 1; }
    # llvm-clang bin: llvm-objdump/llvm-ar that mach requires (nixpkgs: llvmPackages.bintools); CC/CXX stay gcc (mozconfig)
    export PATH=${llvm-clang}/bin:${rust}/bin:${cbindgen}/bin:${nodejs}/bin:${tools.nasm}/bin:${cli.perl}/bin:${cli.gnum4}/bin:$PATH
    export HOME="$TMPDIR/home" MOZBUILD_STATE_PATH="$TMPDIR/mozbuild" MOZ_OBJDIR="$PWD/objdir" MOZ_NOSPAM=1
    export MACH_BUILD_PYTHON_NATIVE_PACKAGE_SOURCE=none MOZ_BUILD_DATE=$(head -n1 sourcestamp.txt) MOZILLA_OFFICIAL=1
    export MOZ_APP_REMOTINGNAME=firefox CARGO_HOME="$TMPDIR/cargo" RUSTFLAGS="--remap-path-prefix=$W=/build"
    # bindgen: the from-source libclang parses Gecko's C++ with gcc's libstdc++ headers, in g++'s own search order, then
    # the gate's (as nixpkgs' bindgenHook passes the cc's include dirs; without them: "'version' file not found", measured)
    X=$gcc/include/c++/14.3.0
    export LIBCLANG_PATH=${llvm-clang}/lib BINDGEN_CFLAGS="--sysroot=$gate -isystem $X -isystem $X/x86_64-pc-solaris2.11 -isystem $X/backward -isystem $gate/usr/include"
    cat > mozconfig <<EOF
    ac_add_options --prefix=$out
    ac_add_options --enable-application=browser
    ac_add_options --enable-default-toolkit=cairo-gtk3-wayland-only
    ac_add_options --with-app-name=firefox
    ac_add_options --with-distribution-id=io.solnix
    ac_add_options --enable-release --enable-optimize --disable-debug --disable-debug-symbols
    ac_add_options --disable-tests --disable-updater --disable-crashreporter --disable-webrtc
    ac_add_options --disable-jemalloc --enable-audio-backends=sunaudio --without-wasm-sandboxed-libraries
    ac_add_options --enable-system-pixman --with-system-zlib --with-system-ffi --with-system-png --with-system-jpeg
    # bundled NSS 3.125 / NSPR 4.39 (as OI's recipe): 153 needs nss >= 3.125 and solnix's base nss is OI's 3.98 (measured);
    # NixOS links nss_latest. A system nss_latest would let the base move independently: later.
    ac_add_options --with-libclang-path=${llvm-clang}/lib --with-clang-path=${llvm-clang}/bin/clang
    ac_add_options --host=x86_64-pc-solaris2.11 --target=x86_64-pc-solaris2.11
    ac_add_options --disable-install-strip --disable-strip
    ac_add_options CC=$CC CXX=$CXX
    mk_add_options MOZ_OBJDIR=$MOZ_OBJDIR
    EOF
    export MOZCONFIG="$PWD/mozconfig"
    export MOZ_TELEMETRY_REPORTING=   # exported: a configure re-run inside `mach build` sees it too
    python3 ./mach configure
    grep -q '"MOZ_TELEMETRY_REPORTING"' "$MOZ_OBJDIR/config.status.json" && { echo "FATAL: telemetry reporting on" >&2; exit 1; }
    python3 ./mach build -j''${NIX_BUILD_CORES:-8}
    python3 ./mach install
    # the NixOS wrapper (wrapFirefox): Wayland on, the store GTK modules dir, no telemetry upload by policy
    mv "$out/bin/firefox" "$out/bin/.firefox-unwrapped"
    printf '#!/usr/bin/bash\nexport MOZ_ENABLE_WAYLAND=1\nexec %s/lib/firefox/firefox "$@"\n' "$out" > "$out/bin/firefox"
    chmod +x "$out/bin/firefox"
    mkdir -p "$out/lib/firefox/distribution"
    printf '{"policies":{"DisableTelemetry":true,"DisableFirefoxStudies":true,"DisableAppUpdate":true}}\n' > "$out/lib/firefox/distribution/policies.json"
    "$out/lib/firefox/firefox" --version | grep -q 'Mozilla Firefox 153.6.0esr' || { echo "FATAL: firefox --version" >&2; exit 1; }
    # every shipped ELF that links libc must carry NODEFLIB (a stray link without the wrapper would reopen the host-lib hole)
    for f in "$out"/lib/firefox/*.so "$out"/lib/firefox/firefox; do
      /usr/bin/elfdump -d "$f" | grep -q 'NODEFLIB' || { echo "FATAL: $f lacks -z nodefaultlib" >&2; exit 1; }
    done
    # headless start: loads libxul, the profile, Gecko, a local page, and writes a PNG (no display needed). Gecko aborts with no
    # font at all (MOZ_RELEASE_ASSERT in gfxPlatformFontList, measured on a fontless builder), so a build-only fonts.conf in
    # $TMPDIR names noto-sans; nothing in $out refers to it.
    mkdir -p "$TMPDIR/ffhome" "$TMPDIR/ffprof"; printf '<html><body><h1>solnix</h1></body></html>\n' > "$TMPDIR/t.html"
    printf '<?xml version="1.0"?><fontconfig><dir>%s/share/fonts</dir><cachedir>%s/fc</cachedir></fontconfig>\n' ${noto-sans} "$TMPDIR" > "$TMPDIR/fonts.conf"
    env -i HOME="$TMPDIR/ffhome" PATH=/usr/bin FONTCONFIG_FILE="$TMPDIR/fonts.conf" MOZ_HEADLESS=1 "$out/lib/firefox/firefox" --no-remote --profile "$TMPDIR/ffprof" \
      --screenshot "$TMPDIR/shot.png" "file://$TMPDIR/t.html" > "$TMPDIR/shot.log" 2>&1 || true
    [ -s "$TMPDIR/shot.png" ] || { echo "FATAL: headless screenshot" >&2; tail -20 "$TMPDIR/shot.log" >&2; exit 1; }
  '';
}
