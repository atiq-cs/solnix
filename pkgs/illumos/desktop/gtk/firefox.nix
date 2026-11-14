# desktop/gtk/firefox.nix -- Firefox for COSMIC/Wayland, one recipe for two of nixpkgs' editions (its separate attrs):
# edition = "esr" (firefox-esr 153.6.0, OI's patch set as of its 153.0.4 commit, oi-userland 7d7fad4aa7: 40 of its 41 applied,
# measured 41/41 on 153.6.0esr by cosmic7) and "release" (firefox 159.0, the Release channel, solnix's default Firefox: OI's set
# as of its 159.0 commit c8a7cc7d71, firefox-oi-patches-159.nix says which 42 of 45). Our own four patches apply to both.
# cairo-gtk3-wayland-only (no X11 libs at all), gcc (OI 17-clang-not-work), sunaudio (cubeb's Solaris backend; the SunOS default).
# NixOS-shaped (build-mozilla-mach): MOZILLA_OFFICIAL, no updater, no crashreporter, no tests,
# no Google/Mozilla API keys, no EME (configure offers --enable-eme only on Linux/Windows/macOS: no Widevine possible). Telemetry: the
# empty env MOZ_TELEMETRY_REPORTING= turns it off at build time (MOZILLA_OFFICIAL defaults it ON: measured =1 in config.status
# until then); Normandy and health report are browser/moz.configure implies (not settable), so policies.json disables them. The wrapper is
# NixOS's MOZ_ENABLE_WAYLAND=1 (Wayland-only builds ignore it; kept so the env matches NixOS's).
{ mkSrcPkg, tools, gtk, cli, rust, cbindgen, nodejs, llvm-clang, zlib, nixChain, graphics, world, noto-sans, libffi ? graphics.libffi,
  edition ? "esr" }:
let
  inherit (gtk) glib gtk3 cairo pango harfbuzz fribidi fontconfig freetype gdk-pixbuf libepoxy at-spi2-core libpng libjpeg-turbo pcre2;
  inherit (graphics) pixman wayland wayland-protocols libxkbcommon mesa dbus libdrm expat;
  # tag: Mozilla's release dir and what `firefox --version` prints. sha256: ftp.mozilla.org's SHA256SUMS (159.0's = OI's Makefile).
  ed = {
    esr = { pname = "firefox-esr"; version = "153.6.0"; tag = "153.6.0esr"; oiRev = "7d7fad4aa7"; oiList = ./firefox-oi-patches.nix;
            triple = "x86_64-pc-solaris2.11"; bindgenPatch = ./patches/firefox-153-bindgen-illumos-using-size_t.patch;
            sha256 = "91cb675ddfc678255f57ecd7aad498501961577686d19c1947a82b14edea7f25"; };
    release = { pname = "firefox"; version = "159.0"; tag = "159.0"; oiRev = "c8a7cc7d71"; oiList = ./firefox-oi-patches-159.nix;
                # OI's GNU_ARCH: from 159 configure keeps config.guess's "pc" vendor when a rust target has it, so
                # x86_64-pc-solaris2.11 picked rustc's x86_64-pc-solaris, not our rustc's own x86_64-unknown-illumos, and
                # configure died ("rust compiler host ... is not suitable", measured); illumos maps to SunOS as solaris does
                triple = "x86_64-unknown-illumos";
                # 159 binds nsGkAtoms::kStaticAtomCount, a constexpr size_t that libclang spells "const size_t": the 153 patch
                # missed it (style: "expected usize, found u64", measured), so this one strips the const first
                bindgenPatch = ./patches/firefox-159-bindgen-illumos-using-size_t.patch;
                sha256 = "3d98df785894057fce60603e845828e758a5411ad79aaaaff2b8230597f500d9"; };
  }.${edition};
  oi = n: sha256: import <nix/fetchurl.nix> {
    url = "https://raw.githubusercontent.com/OpenIndiana/oi-userland/${ed.oiRev}/components/web/firefox/patches/${n}"; inherit sha256; };
  # OI's list minus 08-branding (points the welcome page at an OI path). sha256 = floki /scratch/solnix/browser1/ff/p153.sha256
  # (ESR), /scratch/solnix/ff2/p159.C.sha256 (Release).
  patches = import ed.oiList { inherit oi; };
in
mkSrcPkg {
  inherit (ed) pname version;
  src = { url = "https://ftp.mozilla.org/pub/firefox/releases/${ed.tag}/source/firefox-${ed.tag}.source.tar.xz"; inherit (ed) sha256; };
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
    # RFPTargetConstants.sys.mjs (generated, shipped in omni.ja) named its three .inc inputs by absolute path, i.e. this build
    # dir (gate B8): name their basenames (patch says why)
    patch -p1 < ${./patches/firefox-153-rfp-targets-basenames.patch}
    # nasm names each object's STT_FILE after its input path as given, and mozbuild passes absolute sources (rules.mk relativizes
    # only under WINE), so libxul, libgkcodecs and libmozav* named this build dir (gate B8). The same wrapper as libjpeg-turbo's
    # (cli/c-recipes4.nix nasmRel): pass nasm the path relative to its cwd. toolkit/moz.configure takes NASM from the environment.
    printf '%s\n' '#!/usr/bin/bash' \
      'rel() { local d=$PWD up=; while [ "''${1#"$d"/}" = "$1" ]; do d=''${d%/*}; up=../$up; done; printf %s "$up''${1#"$d"/}"; }' \
      "a=(); for x in \"\$@\"; do case \"\$x\" in $SRC/*) x=\$(rel \"\$x\");; esac; a+=(\"\$x\"); done" \
      'exec ${tools.nasm}/bin/nasm "''${a[@]}"' > "$W/nasm"
    chmod +x "$W/nasm"; export NASM="$W/nasm"
    # vendored bindgen: illumos' `using std::size_t` reached Rust as c_ulong, not usize (patch says why); re-stamps the checksum
    bash ${./vendor-fix.sh} "$PWD" ${ed.bindgenPatch}
    # mk-src-pkg's cc/c++ wrappers put every dep's include dir FIRST (-I), ahead of the tree's own -I: mesa's EGL/eglext.h
    # shadowed ANGLE's gfx/angle/checkout/include (PackedEnums.cpp: EGL_TEXTURE_RECTANGLE_ANGLE undeclared; gcc -H shows
    # mesa's egl.h), and the system harfbuzz/cairo headers shadowed the bundled ones in dist/include. -isystem is NixOS's
    # NIX_CFLAGS_COMPILE order: the target's -I, then deps, then the system dirs. Firefox-local: other recipes keep -I.
    for w in "$(command -v $CC)" "$(command -v $CXX)"; do sed -i 's@ -I/nix/store/@ -isystem /nix/store/@g' "$w"; done
    ! grep -q -- ' -I/nix/store/' "$(command -v $CXX)" && grep -q -- ' -isystem /nix/store/' "$(command -v $CXX)" || { echo "FATAL: c++ wrapper rewrite" >&2; exit 1; }
    # mach adds -fstack-protector-strong at link, so gcc's link_ssp spec NEEDs libssp.so.0, which gcc.lib does not ship
    # (firefox: "libssp.so.0: open failed", measured). illumos libc has __stack_chk_fail/__stack_chk_guard: keep the
    # protector, drop the -lssp (measured: an overflow still aborts, NEEDED = libgcc_s libc). $W: a fixed path.
    printf '*link_ssp:\n%%{fstack-protector*:}\n\n' > "$W/nossp.specs"
    for w in "$(command -v $CC)" "$(command -v $CXX)"; do sed -i "s@ -D_TS_ERRNO @ -D_TS_ERRNO -specs=$W/nossp.specs @" "$w"; done
    grep -q -- '-specs=' "$(command -v $CC)" || { echo "FATAL: cc wrapper specs" >&2; exit 1; }
    # libxul.so and the bundled NSS NEED their siblings in lib/firefox (nixpkgs' musl LDFLAGS adds it for the same reason),
    # and it must come FIRST: world's lib-64 has OI's libnss3/libnssutil3/libnspr4, and with lib/firefox last the bundled
    # libnss3 bound world's libnssutil3 ("NSSUTIL_3.101 version not found", measured). ld joins -R in order, so it goes
    # at the head of the wrapper's own -R, not in LDFLAGS (which lands after it).
    # -z nodefaultlib: a bare dlopen("libpulse.so.0") (xpcom nsSystemInfo, for a version string) otherwise fell through to
    # ld.so.1's default /usr/lib, loaded the host's libpulse and its host libc.so.1 beside the store's, and Firefox SEGVed
    # (measured: 2 libc.so.1 in the core). NixOS has no /usr/lib, so there the dlopen just fails; NODEFLIB makes it fail here.
    # The store-only wrappers carry their -R in L=, set only for a call with a non-flag argument (mk-src-pkg 0734958); its L is
    # unquoted on the exec line, so the two flags reach gcc as two arguments.
    for w in "$(command -v $CC)" "$(command -v $CXX)"; do sed -i "s@ L=-Wl,-R,\([^;]*\);@ L=\"-Wl,-z,nodefaultlib -Wl,-R,$out/lib/firefox:\1\";@" "$w"; done
    grep -q -- "-Wl,-z,nodefaultlib -Wl,-R,$out/lib/firefox:" "$(command -v $CXX)" || { echo "FATAL: c++ wrapper RUNPATH" >&2; exit 1; }
    # llvm-clang bin: llvm-objdump/llvm-ar that mach requires (nixpkgs: llvmPackages.bintools); CC/CXX stay gcc (mozconfig)
    export PATH=${llvm-clang}/bin:${rust}/bin:${cbindgen}/bin:${nodejs}/bin:${tools.nasm}/bin:${cli.perl}/bin:${cli.gnum4}/bin:$PATH
    export HOME="$TMPDIR/home" MOZBUILD_STATE_PATH="$TMPDIR/mozbuild" MOZ_OBJDIR="$PWD/objdir" MOZ_NOSPAM=1
    export MACH_BUILD_PYTHON_NATIVE_PACKAGE_SOURCE=none MOZ_BUILD_DATE=$(head -n1 sourcestamp.txt) MOZILLA_OFFICIAL=1
    export MOZ_APP_REMOTINGNAME=firefox CARGO_HOME="$TMPDIR/cargo" RUSTFLAGS="--remap-path-prefix=$W=/build"
    # bindgen: the from-source libclang parses Gecko's C++ with gcc's libstdc++ headers, in g++'s own search order, then
    # the gate's (as nixpkgs' bindgenHook passes the cc's include dirs; without them: "'version' file not found", measured)
    X=$(ls -d $gcc/include/c++/[0-9]* | head -1)   # the stdenv gcc's libstdc++ headers (14.3.0 or 15.3.0)
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
    ac_add_options --host=${ed.triple} --target=${ed.triple}
    ac_add_options --disable-install-strip --disable-strip
    ac_add_options CC=$CC CXX=$CXX
    mk_add_options MOZ_OBJDIR=$MOZ_OBJDIR
    EOF
    export MOZCONFIG="$PWD/mozconfig"
    # configure requires an unzip (toolkit/moz.configure check_prog UNZIP); only packaging runs it (make_unzip.py), which this
    # build never does (0 unzip runs in chef's log). chef found OI's /usr/bin/unzip; a solnix host has none. NixOS puts unzip in
    # nativeBuildInputs; no from-source unzip here yet, so a stub that fails loudly if anything does run it.
    printf '#!/usr/bin/bash\necho "FATAL: unzip called: $*" >&2; exit 1\n' > "$W/unzip"; chmod +x "$W/unzip"; export UNZIP="$W/unzip"
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
    # The desktop entry and icons, as NixOS's wrapFirefox: COSMIC's dock and app library find an app only through a .desktop
    # file on XDG_DATA_DIRS (the dock's "firefox" favourite matched none: a placeholder icon, and a click did nothing; lixi,
    # BE solnix-51). wrapFirefox's makeDesktopItem for firefox-esr (nixpkgs all-packages: wmClass and icon "firefox-esr"), whose
    # launcher is firefox-esr; here the program is bin/firefox and the app id firefox (MOZ_APP_REMOTINGNAME), the id the dock pins.
    # Unbranded (no --enable-official-branding: docs/desktop-firefox.md says why), so no Mozilla name or logo: Name is the
    # build's own brandShortName (the unofficial branding's "Nightly", what its window and About dialog show), read from its
    # omni.ja, and the icons are the unofficial branding's globe that mach installs as default<N>.png.
    name=$(python3 -c 'import re, sys, zipfile; t = zipfile.ZipFile(sys.argv[1]).read("chrome/en-US/locale/branding/brand.properties").decode(); print(re.search(r"^brandShortName=(.+)$", t, re.M).group(1).strip())' "$out/lib/firefox/browser/omni.ja")
    [ -n "$name" ] || { echo "FATAL: no brandShortName in omni.ja" >&2; exit 1; }
    mkdir -p "$out/share/applications"
    printf '%s\n' '[Desktop Entry]' 'Actions=new-private-window;new-window;profile-manager-window' 'Categories=Network;WebBrowser' \
      'Exec=firefox --name firefox %U' 'GenericName=Web Browser' 'Icon=firefox' \
      'MimeType=text/html;text/xml;application/xhtml+xml;application/vnd.mozilla.xul+xml;x-scheme-handler/http;x-scheme-handler/https' \
      "Name=$name" 'StartupNotify=true' 'StartupWMClass=firefox' 'Terminal=false' 'Type=Application' 'Version=1.5' "" \
      '[Desktop Action new-private-window]' 'Exec=firefox --private-window %U' 'Name=New Private Window' "" \
      '[Desktop Action new-window]' 'Exec=firefox --new-window %U' 'Name=New Window' "" \
      '[Desktop Action profile-manager-window]' 'Exec=firefox --ProfileManager' 'Name=Profile Manager' > "$out/share/applications/firefox.desktop"
    # wrapFirefox's icons: lib/firefox's default<N>.png as hicolor <N>x<N>/apps/firefox.png (relative links, inside $out)
    for n in 16 32 48 64 128; do
      [ -f "$out/lib/firefox/browser/chrome/icons/default/default$n.png" ] || { echo "FATAL: no default$n.png" >&2; exit 1; }
      mkdir -p "$out/share/icons/hicolor/''${n}x$n/apps"
      ln -s "../../../../../lib/firefox/browser/chrome/icons/default/default$n.png" "$out/share/icons/hicolor/''${n}x$n/apps/firefox.png"
    done
    # desktop-file-validate's checks a launcher depends on (makeDesktopItem's checkPhase; no desktop-file-utils here yet), plus
    # what it cannot see: Exec's program is in $out/bin and Icon resolves in $out's hicolor at each size. Negative controls: an
    # entry naming a program and an icon $out lacks must fail.
    python3 ${./desktop-entry-check.py} "$out/share/applications/firefox.desktop" "$out/bin" "$out/share/icons/hicolor"
    sed -e 's/^Exec=firefox --name/Exec=firefox-nosuch --name/' -e 's/^Icon=firefox$/Icon=firefox-nosuch/' \
      "$out/share/applications/firefox.desktop" > "$TMPDIR/neg.desktop"
    n=$(python3 ${./desktop-entry-check.py} "$TMPDIR/neg.desktop" "$out/bin" "$out/share/icons/hicolor" 2>&1 | grep -c -e 'not in' -e 'is in no') || true
    [ "$n" -eq 2 ] || { echo "FATAL: desktop-entry-check negative control found $n of 2 problems" >&2; exit 1; }
    "$out/lib/firefox/firefox" --version | grep -q 'Mozilla Firefox ${ed.tag}' || { echo "FATAL: firefox --version" >&2; exit 1; }
    # every shipped ELF that links libc must carry NODEFLIB (a stray link without the wrapper would reopen the host-lib hole)
    for f in "$out"/lib/firefox/*.so "$out"/lib/firefox/firefox; do
      elfdump -d "$f" | grep -q 'NODEFLIB' || { echo "FATAL: $f lacks -z nodefaultlib" >&2; exit 1; }
    done
    # The shot needs every user address below 2^47 (SpiderMonkey's NaN-boxed JS::Value; solnix.kernel.userLimit47,
    # modules/config/user-limit.nix). On a builder with upstream illumos's layout (libraries at 0xFFFFFC7F...) Firefox SEGVs
    # creating its first JS global, so name the cause instead of crashing; no skip: such a host cannot vouch for Firefox.
    a=$(python3 -c 'import mmap,ctypes,sys; m=mmap.mmap(-1,1<<20); a=ctypes.addressof(ctypes.c_char.from_buffer(m)); print(hex(a)); sys.exit(a >= 1<<47)') \
      || { echo "FATAL: this build host lacks solnix's userLimit47 default (a fresh mmap at $a is not below 2^47): Firefox cannot run here. Set solnix.kernel.userLimit47 (/etc/system.d: set _userlimit=0x7fffc0000000) and reboot." >&2; exit 1; }
    # headless start: loads libxul, the profile, Gecko, a local page, and writes a PNG (no display needed). Gecko aborts with no
    # font at all (MOZ_RELEASE_ASSERT in gfxPlatformFontList, measured on a fontless builder), so a build-only fonts.conf in
    # $TMPDIR names noto-sans; nothing in $out refers to it.
    mkdir -p "$TMPDIR/ffhome" "$TMPDIR/ffprof"; printf '<html><body><h1>solnix</h1></body></html>\n' > "$TMPDIR/t.html"
    printf '<?xml version="1.0"?><fontconfig><dir>%s/share/fonts</dir><cachedir>%s/fc</cachedir></fontconfig>\n' ${noto-sans} "$TMPDIR" > "$TMPDIR/fonts.conf"
    env -i HOME="$TMPDIR/ffhome" PATH="$PATH" CHARSET=UTF-8 FONTCONFIG_FILE="$TMPDIR/fonts.conf" MOZ_HEADLESS=1 "$out/lib/firefox/firefox" --no-remote --profile "$TMPDIR/ffprof" \
      --screenshot "$TMPDIR/shot.png" "file://$TMPDIR/t.html" > "$TMPDIR/shot.log" 2>&1 || true
    [ -s "$TMPDIR/shot.png" ] || { echo "FATAL: headless screenshot" >&2; tail -20 "$TMPDIR/shot.log" >&2; exit 1; }
  '';
}
