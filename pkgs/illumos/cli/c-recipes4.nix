# cli/c-recipes4.nix -- tools and libraries the x86 build queue has jobs for and solnix lacked (recipes4, 2026-11-09), picked by how many
# queued jobs each moves to buildable. A new file, so no served drv moves. Store-only builds (nativeTools), each with an in-build check
# that runs it on real input. Versions are the queue's targets; sources pinned by sha256 (equal to nixpkgs' flat hash where it has one).
{ base, mkSrcPkg, world, chk, hostTools, autoreconfTools, autoreconf, python3, gnupatch, gnum4, cmake, perl, tcl, vulkan-headers, libogg, fmt, bzip2-bin, libxau, libxdmcp, libpthread-stubs, gtkMeson ? null, graphics, ... }:
let
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  # a C test program against the just-installed library: <src> <link flags>
  tprog = src: libs: ''
    cat > "$W/t.c" <<'TPROG'
${src}
TPROG
    "$CC" -I"$out/include" "$W/t.c" -L"$out/lib/amd64" ${libs} -Wl,-R,"$out/lib/amd64" -o "$W/t"
  '';
  inherit (base) zlib;
  inherit (gtkMeson) fontconfig;
  # cmake projects: the store cmake, store prefixes only (as c-recipes3.nix)
  cmakeB = extra: ''
    cmake -S . -B _b -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON -DCMAKE_IGNORE_PREFIX_PATH="/usr;/usr/local;/opt" \
      -DCMAKE_IGNORE_PATH="/usr/lib/64;/usr/lib/amd64;/lib/64" ${extra} >&2
    cmake --build _b -j16 >&2; cmake --install _b >&2
  '';
  # meson recipes: desktop/gtk's served store meson 1.10.2, samurai, nasm and its build-tool env (GNU binutils by name, sh -> bash);
  # null on aarch64 (no desktop/gtk set there), which then has none of them
  inherit (gtkMeson) meson samurai nasm freetype noto-sans ftPriv;
  inherit (graphics) expat;
  mesonTools = [ meson samurai python3 base.pkgconf gtkMeson.gtkTools ] ++ hostTools;
  mesonBuild = flags: ''
    export PYTHONDONTWRITEBYTECODE=1
    meson setup _b --prefix="$out" --libdir=lib/amd64 --buildtype=release --wrap-mode=nodownload -Db_ndebug=true ${flags}
    samu -C _b -j''${NIX_BUILD_CORES:-8}
    samu -C _b install
  '';
  # X.Org's XORG_MANPAGE_SECTIONS picks SysV (file formats in 4, misc in 5) or traditional man sections by whether the BUILD HOST has
  # /usr/share/man/man7/attributes.7: lixi does (the world's man pages), woof does not, so libX11/mkfontscale/bdftopcf differed across
  # hosts in their man pages only (--check SAME on each). illumos uses traditional sections: pin that answer. xcb-proto/xtrans/libxcb/
  # libxext/libfontenc/font-util run the same probe but install no page whose section it changes (NarHash equal on both hosts).
  manSections = "ac_cv_file__usr_share_man_man7_attributes_7=yes";
in rec {
  # unzip (Info-ZIP): extracts .zip archives. 195 queued jobs list it as a build tool (nixpkgs' unpackPhase for .zip sources).
  # nixpkgs' patch set (security fixes and gcc 14 build fixes), fetched from nixpkgs f4a03c0 and the upstreams it names, and its bzip2.
  unzip = let
    np = f: sha256: fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/un/unzip/${f}" sha256;
    patches = [
      (np "CVE-2014-8139.diff" "29c88d94e0dbd829b2712ac038e5af97a15dcb2e3cd62de0a3b43173e0a5d115")
      (np "CVE-2014-8140.diff" "0b3573a4c633c84c7ca4030c7110b6f2a4bcf94891a9928459d04974e0485c4f")
      (np "CVE-2014-8141.diff" "af0235ac2fe308540068eb7747ab2afc7cc42e75108738c398999dfc0d949b6a")
      (np "CVE-2014-9636.diff" "332fd1ff79cac03d1cf93ea80538e6478242ed29e8b35010719a473385123d8d")
      (np "CVE-2015-7696.diff" "fc6d36383ba9ca35e888912e5f8fd5178ae7e987c78a25816c2c0b60c3b377ba")
      (np "CVE-2015-7697.diff" "949c05868c47e737f0acd3904287631b5876c0500fa82a4abc334c646356b3f5")
      (np "CVE-2014-9913.patch" "1872ffdd4d82edd7b1e62c469642bf16a1ca12dd26d41bd3f0b44f0f7602eb63")
      (np "CVE-2016-9844.patch" "60840ea8f5d11a276972fb5b43652cdd49a9ed93b2cc0586ad309bf52104b012")
      (np "CVE-2018-18384.patch" "bacf33a0ef6352e44c33ac5aed6a40f9a6b41aeeae34f119a90dd8bf99b83621")
      (np "dont-hardcode-cc.patch" "bc4263b56133aef83f041a04b3dbe14b16c15c9f625b467cf89cf0efe31ba27b")
      (fetch "https://sources.debian.org/data/main/u/unzip/6.0-31/debian/patches/cve-2018-1000035-unzip-buffer-overflow.patch" "4eabc3faeddd56ebc3d5053486b61f8758d840902725fd555d3472cffb094437")
      (fetch "https://github.com/madler/unzip/commit/41beb477c5744bc396fa1162ee0c14218ec12213.patch" "24582ff3dcd926d1a46caf8506f76999d2525dd66e36f50b25dca50799695f12")
      (fetch "https://github.com/madler/unzip/commit/47b3ceae397d21bf822bc2ac73052a4b1daf8e1c.patch" "6268e9c9565f731fdbd631adbd82ee72ba82de65fceb28c09499ffed25e3c247")
      (fetch "https://github.com/madler/unzip/commit/6d351831be705cc26d897db44f878a978f4138fc.patch" "ee9e26018190a515572b66a26118916843aa1002131a86b5c52769dc663b7acb")
      (np "06-initialize-the-symlink-flag.patch" "f2878c1caac445dbe884821a8e83b56b69e757cf98500ecc721ccab79b6c00c0")
      (np "28-cve-2022-0529-and-cve-2022-0530.patch" "a27efd8c4950fb3d942d602ad7846996e02aafd77a8ad1e26700e42ae6c1cd37")
      (np "implicit-declarations-fix.patch" "928a717cacc9fb89c7a9bf0bf6ebea12745c96e518555cfd5a9797f66b558e22")
      (np "CVE-2021-4217.patch" "60a1388d535296b1cb6eccd7358611b4042cd25cb802ca1d133ead69d30856a1")
      # not in nixpkgs: upstream's fix for the CVE-2019-13232 bomb check, which miscounts a short bzip2 buffer, so every small
      # bzip2-compressed member fails ("not enough memory for bomb detection", exit 4; the check here caught it). Debian carries it.
      (fetch "https://sources.debian.org/data/main/u/unzip/6.0-31/debian/patches/cve-2019-13232-fix-bug-in-uzbunzip2.patch" "c25fdc17e946e091ec801ad69a56e25c0b73b38c606da95bc602b7d48a46ac3f")
    ];
  in mkSrcPkg {
    pname = "unzip"; version = "6.0";
    src = { url = "https://downloads.sourceforge.net/infozip/unzip60.tar.gz";
            sha256 = "036d96991646d0449ed0aa952e4fbe21b476ce994abc276e49d30e686708bd37"; };
    deps = [ world base.nixChain.bzip2 ]; nativeTools = [ gnupatch python3 ] ++ hostTools;
    build = ''
      for p in ${toString patches}; do patch -p1 -F3 < "$p"; done
      # unix/configure takes the build HOST's /usr/ccs/lib/cpp, /usr/lib/cpp, /lib/cpp or /usr/bin/cpp when one exists, so its asm-CRC
      # answer would follow the host: the compiler's own -E, on every host.
      [ "$(grep -c '^\[ -f /[a-z/]*cpp \] && CPP=' unix/configure)" = 4 ] || { echo "FATAL: unzip cpp probe anchor" >&2; exit 1; }
      sed -i '/^\[ -f \/[a-z\/]*cpp \] && CPP=/d' unix/configure
      # the memset probe calls it undeclared, which gcc 14 rejects, so configure picks ZMEM (bcopy/bzero, which illumos declares only in
      # <strings.h>, so the build then fails): declare it, and memset is found, as it is on every host
      grep -qx 'echo "int main(){ char k; memset(&k,0,0); return 0; }" > conftest.c' unix/configure || { echo "FATAL: unzip memset probe anchor" >&2; exit 1; }
      # unxcfg.h includes <utime.h> on SYSV only for __hpux and Sun's own compiler: gcc on illumos gets utime() undeclared. Add __sun.
      grep -q '^#  if (!defined(GOT_UTIMBUF) && (defined(__hpux) || defined(__SUNPRO_C)))$' unix/unxcfg.h || { echo "FATAL: unzip utime.h anchor" >&2; exit 1; }
      sed -i 's/^#  if (!defined(GOT_UTIMBUF) \&\& (defined(__hpux) || defined(__SUNPRO_C)))$/#  if (!defined(GOT_UTIMBUF) \&\& (defined(__hpux) || defined(__SUNPRO_C) || defined(__sun)))/' unix/unxcfg.h
      sed -i 's|^echo "int main(){ char k; memset(&k,0,0); return 0; }" > conftest.c$|echo "#include <string.h>\nint main(){ char k; memset(\&k,0,0); return 0; }" > conftest.c|' unix/configure
      # the generic target, as nixpkgs: configure writes the flags, bzip2 (method 12) from the store library
      gmake -f unix/Makefile flags CC="$CC" D_USE_BZ2=-DUSE_BZIP2
      grep -q 'D_USE_BZ2=""' flags && grep -q 'L_BZ2=""' flags || { echo "FATAL: unzip flags anchor" >&2; exit 1; }
      sed -i 's/D_USE_BZ2=""/D_USE_BZ2="-DUSE_BZIP2"/; s/L_BZ2=""/L_BZ2="-lbz2"/' flags
      eval gmake -f unix/Makefile unzips ACONF_DEP=flags "$(cat flags)"
      gmake -f unix/Makefile install prefix="$out" MANDIR="$out/share/man/man1"
      cat > "$W/mk.py" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr(zipfile.ZipInfo("a.txt"), "solnix-deflate\n" * 64, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr(zipfile.ZipInfo("b.txt"), "solnix-bzip2\n" * 64, compress_type=zipfile.ZIP_BZIP2)
PY
      python3 "$W/mk.py" "$W/t.zip"
      ${chk ''"$out/bin/unzip" -p "$W/t.zip" a.txt | uniq'' "^solnix-deflate$"}
      ${chk ''"$out/bin/unzip" -p "$W/t.zip" b.txt | uniq'' "^solnix-bzip2$"}
      ${chk ''"$out/bin/unzip" -tq "$W/t.zip"; echo "rc=$?"'' "^rc=0$"}
    '';
  };

  # jemalloc (BSD-2-Clause): the general-purpose malloc (redis, rust programs, ...). autotools; nixpkgs' flags (no symbol prefix,
  # profiling on, 4 KiB pages, the version string a tarball build cannot get from git) and its -O3 -> -O2.
  jemalloc = mkSrcPkg {
    pname = "jemalloc"; version = "5.4.0";
    src = { url = "https://github.com/jemalloc/jemalloc/releases/download/5.4.0/jemalloc-5.4.0.tar.bz2";
            sha256 = "200776fac271093e7c2f21edd6d62657ecd2be578d9328633f2a86bfa6ef4f1d"; };
    deps = [ world ]; nativeTools = [ bzip2-bin ] ++ hostTools;   # bzip2-bin: GNU tar unpacks the .tar.bz2 with it
    build = ''
      [ "$(grep -c '^T_APPEND_V=-O3$' configure)" = 2 ] || { echo "FATAL: jemalloc -O3 anchor" >&2; exit 1; }
      sed -i 's/^T_APPEND_V=-O3$/T_APPEND_V=-O2/' configure
      # configure adds -herror_on_warning (a Sun cc flag) when a compile accepts it; gcc hands -h to the illumos ld as the SONAME, so every
      # later link probe fails ("cannot determine return type of strerror_r"). As cli/rust-extra.nix does for tikv-jemalloc-sys.
      [ "$(grep -c '^T_APPEND_V=-herror_on_warning$' configure)" = 7 ] || { echo "FATAL: jemalloc -herror_on_warning anchor" >&2; exit 1; }
      sed -i 's/^T_APPEND_V=-herror_on_warning$/T_APPEND_V=/' configure
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static \
        --with-version=5.4.0-0-g0000000000000000000000000000000000000000 --with-lg-vaddr=64 --enable-prof --with-lg-page=12
      # the library replaces malloc, and libgcc_s's .init (frame registration) calls malloc: run before jemalloc's own .init, it takes
      # libgcc's frame lock and parks in jemalloc's first-use init, so every program linked with -ljemalloc hangs at load (pstack:
      # __register_frame_info_bases -> version_lock_lock_exclusive; the check below timed out). -z initfirst runs jemalloc's .init first.
      gmake -j8 EXTRA_LDFLAGS=-Wl,-z,initfirst; gmake install
      /usr/bin/elfdump -d "$out/lib/amd64/libjemalloc.so.2" | grep -q 'FLAGS_1.*INITFIRST' || { echo "FATAL: libjemalloc without INITFIRST" >&2; exit 1; }
      ${tprog ''#include <jemalloc/jemalloc.h>
#include <stdio.h>
#include <stdlib.h>
int main(void){ const char *v; size_t n = sizeof v; void *p = malloc(4096); if(!p || mallctl("version", &v, &n, NULL, 0)) return 1;
free(p); printf("jemalloc %s\n", v); return 0; }'' "-ljemalloc"}
      ${chk ''timeout 60 "$W/t"'' "^jemalloc 5\\.4\\.0-0-g0{40}$"}
    '';
  };

  # netsurf-buildsystem (MIT): the shared makefiles every NetSurf library builds with (libcss, libdom, libhubbub, ...).
  netsurf-buildsystem = mkSrcPkg {
    pname = "netsurf-buildsystem"; version = "1.10";
    src = { url = "https://download.netsurf-browser.org/libs/releases/buildsystem-1.10.tar.gz";
            sha256 = "3d3e39d569e44677c4b179129bde614c65798e2b3e6253160239d1fd6eae4d79"; };
    deps = [ base.bash ]; nativeTools = hostTools;   # bash: citools/jenkins-build.sh's interpreter (a runtime reference)
    build = ''
      gmake install PREFIX="$out"
      # citools/jenkins-build.sh is #!/bin/bash (no such file on solnix; gate B9): the store bash, as NixOS' patchShebangs
      f="$out/share/netsurf-buildsystem/citools/jenkins-build.sh"; head -1 "$f" | grep -qx '#!/bin/bash' || { echo "FATAL: jenkins-build.sh shebang anchor" >&2; exit 1; }
      sed -i "1s|^#!/bin/bash$|#!${base.bash}/bin/bash|" "$f"
      # the check: the bundled example library builds with the installed makefiles
      ${chk ''gmake -C example PREFIX="$out" NSSHARED="$out/share/netsurf-buildsystem" CC="$CC" BUILD_CC="$CC" Q= && find example -name libfoo.a'' "libfoo\\.a$"}
    '';
  };

  # ---- X11: xcb-proto -> libxcb -> libx11 -> libxext (71 queued jobs need the chain), on libxau/libxdmcp/libpthread-stubs/util-macros
  # (c-recipes3.nix) and the served xorgproto. Client libraries only (no server). autotools, nixpkgs' flags.
  # xcb-proto (X11): the XCB protocol XML and its python generator (libxcb's build input).
  xcb-proto = mkSrcPkg {
    pname = "xcb-proto"; version = "1.17.0";
    src = { url = "https://xorg.freedesktop.org/releases/individual/proto/xcb-proto-1.17.0.tar.xz";
            sha256 = "2c1bacd2110f4799f74de6ebb714b94cf6f80fb112316b1219480fd22562148c"; };
    deps = [ world ]; nativeTools = [ python3 ] ++ hostTools;
    build = ''
      PYTHONDONTWRITEBYTECODE=1 ./configure --prefix="$out"
      PYTHONDONTWRITEBYTECODE=1 gmake install
      ${chk ''PKG_CONFIG_LIBDIR="$out/share/pkgconfig" ${base.pkgconf}/bin/pkg-config --modversion xcb-proto && ls "$out/share/xcb/xproto.xml"'' "^1\\.17\\.0$"}
    '';
  };

  # xtrans (MIT-open-group and others): X transport sources (headers + .c compiled into libX11), and nixpkgs' socket-reopen fix.
  xtrans = mkSrcPkg {
    pname = "xtrans"; version = "1.6.0";
    src = { url = "https://xorg.freedesktop.org/releases/individual/lib/xtrans-1.6.0.tar.xz";
            sha256 = "faafea166bf2451a173d9d593352940ec6404145c5d1da5c213423ce4d359e92"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://gitlab.freedesktop.org/xorg/lib/libxtrans/-/commit/79f6b0bfe2170496e8c37626043d009f4cd3f1e1.patch" "a9f79d1edde220924d14be197826f719b4d4588a9229fd462ec12a62a8de59ca"}
      ./configure --prefix="$out" --disable-docs --without-xmlto --without-fop --without-xsltproc
      gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      ${chk ''ls "$out/include/X11/Xtrans/Xtranssock.c" "$out/share/pkgconfig/xtrans.pc"'' "xtrans\\.pc$"}
    '';
  };

  # libxcb (X11): the X protocol C binding (libxcb.so + every extension library).
  libxcb = mkSrcPkg {
    pname = "libxcb"; version = "1.17.0";
    src = { url = "https://xorg.freedesktop.org/releases/individual/lib/libxcb-1.17.0.tar.xz";
            sha256 = "599ebf9996710fea71622e6e184f3a8ad5b43d0e5fa8c4e407123c88a59a6d55"; };
    deps = [ world libxau libxdmcp ]; linkDeps = [ xcb-proto libpthread-stubs base.xorgproto ];
    nativeTools = [ python3 base.pkgconf ] ++ hostTools;
    build = ''
      PYTHONDONTWRITEBYTECODE=1 ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-devel-docs --without-doxygen
      PYTHONDONTWRITEBYTECODE=1 gmake -j8; gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      ${tprog ''#include <xcb/xcb.h>
#include <stdio.h>
int main(void){ int s; xcb_connection_t *c = xcb_connect(":solnix-none", &s); printf("xcb err %d\n", xcb_connection_has_error(c) != 0);
xcb_disconnect(c); return 0; }'' "-lxcb"}
      ${chk ''"$W/t"'' "^xcb err 1$"}
    '';
  };

  # libX11 (MIT and others): Xlib. nixpkgs' build (no docs); -D_REENTRANT -D_POSIX_PTHREAD_SEMANTICS from its own solaris arm.
  libx11 = mkSrcPkg {
    pname = "libx11"; version = "1.8.14";
    src = { url = "https://xorg.freedesktop.org/releases/individual/lib/libX11-1.8.14.tar.xz";
            sha256 = "bbc78c46217174655c2b32b138ad119f3ac15f50808b4d0b3a2677a4b1afc950"; };
    deps = [ world libxcb base.xorgproto ]; linkDeps = [ xtrans libxau libxdmcp libpthread-stubs ];
    nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      # XORG_PROG_RAWCPP pipes the nls/ sources into a cpp read from stdin; with no cpp on PATH it takes "$CC -E", which reads none (and
      # then reports that it "defines unix with or without -undef"): the compiler's own cpp, as nixpkgs points it at one (ac_cv_path_RAWCPP)
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-specs --without-xmlto --without-fop --without-xsltproc \
        --without-perl ac_cv_path_RAWCPP="$gcc/bin/cpp" ${manSections}
      gmake -j8; gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      ${tprog ''#include <X11/Xlib.h>
#include <stdio.h>
int main(void){ printf("xlib %d %s\n", XOpenDisplay(":solnix-none") == NULL, XKeysymToString(XStringToKeysym("Return"))); return 0; }'' "-lX11"}
      ${chk ''"$W/t"'' "^xlib 1 Return$"}
    '';
  };

  # libXext (MIT-open-group and others): common X11 extensions on Xlib.
  libxext = mkSrcPkg {
    pname = "libxext"; version = "1.3.7";
    src = { url = "https://xorg.freedesktop.org/releases/individual/lib/libXext-1.3.7.tar.xz";
            sha256 = "6c643c7035cdacf67afd68f25d01b90ef889d546c9fcd7c0adf7c2cf91e3a32d"; };
    deps = [ world libx11 base.xorgproto libxau ]; linkDeps = [ libxcb libxdmcp ];
    nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-specs --without-xmlto --without-fop --without-xsltproc
      gmake -j8; gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      ${tprog ''#include <X11/Xlib.h>
#include <X11/extensions/shape.h>
#include <stdio.h>
int main(void){ printf("xext %d\n", XOpenDisplay(":solnix-none") == NULL); return XShapeQueryExtension == 0; }'' "-lXext -lX11"}
      ${chk ''"$W/t"'' "^xext 1$"}
    '';
  };

  # ---- X.Org font tools (libfontenc, mkfontscale, bdftopcf, font-util: 40 queued jobs, every font package's build) ---------------
  # libfontenc (MIT): font encoding tables (mkfontscale, xorg-server).
  libfontenc = mkSrcPkg {
    pname = "libfontenc"; version = "1.1.9";
    src = { url = "https://xorg.freedesktop.org/releases/individual/lib/libfontenc-1.1.9.tar.xz";
            sha256 = "9d8392705cb10803d5fe1d27d236cbab3f664e26841ce01916bbbe430cf273e2"; };
    deps = [ world base.zlib ]; linkDeps = [ base.xorgproto ]; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j8; gmake install
      ${tprog ''#include <X11/fonts/fontenc.h>
#include <stdio.h>
int main(void){ FontEncPtr e = FontEncFind("iso8859-1", NULL); printf("fontenc %s %d\n", e ? e->name : "none", e ? e->size : 0); return !e; }'' "-lfontenc"}
      ${chk ''"$W/t"'' "^fontenc iso8859-1 256$"}
    '';
  };

  # mkfontscale (MIT and others): writes fonts.scale/fonts.dir (and mkfontdir) for X font directories.
  mkfontscale = mkSrcPkg {
    pname = "mkfontscale"; version = "1.2.4";
    src = { url = "https://xorg.freedesktop.org/releases/individual/app/mkfontscale-1.2.4.tar.xz";
            sha256 = "a01492a17a9b6c0ee3f92ee578850e305315b9f298da5f006a1cd4b51db01a5e"; };
    deps = [ world libfontenc freetype base.zlib ]; linkDeps = [ base.xorgproto ] ++ ftPriv; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" ${manSections}
      gmake -j8; gmake install
      mkdir -p "$W/fd"; cp ${noto-sans}/share/fonts/noto/NotoSans-Regular.ttf "$W/fd/"
      ${chk ''"$out/bin/mkfontscale" "$W/fd" && head -2 "$W/fd/fonts.scale"'' "^NotoSans-Regular\\.ttf -[a-z]+-noto sans-medium-r-normal--0-0-0-0-p-0-iso10646-1$"}
    '';
  };

  # bdftopcf (MIT-open-group): converts BDF fonts to PCF (every X bitmap font package's build).
  bdftopcf = mkSrcPkg {
    pname = "bdftopcf"; version = "1.1.2";
    src = { url = "https://xorg.freedesktop.org/releases/individual/util/bdftopcf-1.1.2.tar.xz";
            sha256 = "bc60be5904330faaa3ddd2aed7874bee2f29e4387c245d6787552f067eb0523a"; };
    deps = [ world ]; linkDeps = [ base.xorgproto ]; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" ${manSections}
      gmake -j8; gmake install
      cat > "$W/t.bdf" <<'BDF'
STARTFONT 2.1
FONT -solnix-test-medium-r-normal--8-80-75-75-c-80-iso10646-1
SIZE 8 75 75
FONTBOUNDINGBOX 8 8 0 0
STARTPROPERTIES 2
FONT_ASCENT 8
FONT_DESCENT 0
ENDPROPERTIES
CHARS 1
STARTCHAR A
ENCODING 65
SWIDTH 500 0
DWIDTH 8 0
BBX 8 8 0 0
BITMAP
18
24
42
42
7E
42
42
00
ENDCHAR
ENDFONT
BDF
      ${chk ''"$out/bin/bdftopcf" -o "$W/t.pcf" "$W/t.bdf" && od -An -c -N4 "$W/t.pcf"'' "001 +f +c +p"}
    '';
  };

  # font-util (MIT and others): bdftruncate, ucs2any, the font encoding maps and fontutil.pc (X.Org font packages' build).
  font-util = mkSrcPkg {
    pname = "font-util"; version = "1.4.2";
    src = { url = "https://xorg.freedesktop.org/releases/individual/font/font-util-1.4.2.tar.xz";
            sha256 = "02e4f8afdcf03cc8372ca9c37aa104b1e36b47722dbc79531be08f0a4c622999"; };
    deps = [ world ]; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j8; gmake install
      ${chk ''ls "$out/share/fonts/X11/util/map-ISO8859-1" "$out/lib/pkgconfig/fontutil.pc" && "$out/bin/bdftruncate" -h 2>&1'' "Usage: bdftruncate"}
    '';
  };

  # ---- meson recipes: the served store meson 1.10.2 (on the store python3), samurai and nasm (desktop/gtk/tools.nix) -------------
  # wayland-scanner (MIT): the protocol XML -> C generator alone (nixpkgs' split of wayland 1.26), no libraries.
  wayland-scanner = mkSrcPkg {
    pname = "wayland-scanner"; version = "1.26.0";
    src = { url = "https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.26.0/downloads/wayland-1.26.0.tar.xz";
            sha256 = "64176eaa46e4969903e286f8e5ef8331affc17fdf03ac9b58381d2b23162b7a3"; };
    deps = [ world expat ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild "-Ddocumentation=false -Dlibraries=false -Dtests=false -Ddtd_validation=false"}
      ${chk ''"$out/bin/wayland-scanner" client-header protocol/wayland.xml "$W/wl.h" && cat "$W/wl.h"'' "struct wl_display_listener"}
    '';
  };

  # dav1d (BSD-2-Clause): the AV1 decoder (libavif, ffmpeg, gstreamer; AVIF for cosmic-bg). nasm x86-64 asm on, tools off, as nixpkgs.
  dav1d = mkSrcPkg {
    pname = "dav1d"; version = "1.5.3";
    src = { url = "https://downloads.videolan.org/pub/videolan/dav1d/1.5.3/dav1d-1.5.3.tar.xz";
            sha256 = "732010aa5ef461fa93355ed2c6c5fedb48ddc4b74e697eaabe8907eaeb943011"; };
    deps = [ world ]; nativeTools = [ nasm ] ++ mesonTools;
    build = ''
      # -std=c99 hides clock_gettime in illumos' <time.h>; __EXTENSIONS__ shows it (as the graphics recipes build)
      ${mesonBuild "-Denable_tools=false -Denable_examples=false -Denable_tests=false -Denable_asm=true -Dc_args=-D__EXTENSIONS__"}
      grep -q '^#define HAVE_ASM 1$' _b/config.h || { echo "FATAL: dav1d built without its asm" >&2; exit 1; }
      ${tprog ''#include <dav1d/dav1d.h>
#include <stdio.h>
int main(void){ Dav1dSettings s; Dav1dContext *c; dav1d_default_settings(&s); s.n_threads = 1; if(dav1d_open(&c, &s)) return 1;
printf("dav1d %s\n", dav1d_version()); dav1d_close(&c); return 0; }'' "-ldav1d"}
      ${chk ''"$W/t"'' "^dav1d 1\\.5\\.3"}
    '';
  };

  # libopus (BSD-3-Clause): the Opus audio codec. nixpkgs' flags (float, custom modes, x86 intrinsics with run-time detection);
  # no deep-PLC/DRED/OSCE (off by default), so the dnn model tarball nixpkgs links in is not needed.
  libopus = mkSrcPkg {
    pname = "libopus"; version = "1.6.1";
    src = { url = "https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz";
            sha256 = "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild "-Dfixed-point=false -Dcustom-modes=true -Dintrinsics=enabled -Drtcd=enabled -Dasm=disabled -Ddocs=disabled -Dtests=disabled -Dextra-programs=disabled"}
      ${tprog ''#include <opus/opus.h>
#include <stdio.h>
int main(void){ int e; unsigned char pkt[400]; opus_int16 pcm[960] = {0}; OpusEncoder *enc = opus_encoder_create(48000, 1, OPUS_APPLICATION_AUDIO, &e);
if(e != OPUS_OK) return 1; int n = opus_encode(enc, pcm, 960, pkt, sizeof pkt); OpusDecoder *dec = opus_decoder_create(48000, 1, &e);
int m = opus_decode(dec, pkt, n, pcm, 960, 0); printf("%s %d\n", opus_get_version_string(), m); return n <= 0; }'' "-lopus"}
      ${chk ''"$W/t"'' "^libopus 1\\.6\\.1 960$"}
    '';
  };

  # lv2 (ISC): the LV2 audio plugin standard's headers and spec bundles (lib/lv2), no plugins, as nixpkgs.
  lv2 = mkSrcPkg {
    pname = "lv2"; version = "1.18.10";
    src = { url = "https://lv2plug.in/spec/lv2-1.18.10.tar.xz";
            sha256 = "78c51bcf21b54e58bb6329accbb4dae03b2ed79b520f9a01e734bd9de530953f"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild "-Dplugins=disabled -Dtests=disabled -Ddocs=disabled -Donline_docs=false"}
      ${tprog ''#include <lv2/core/lv2.h>
#include <stdio.h>
int main(void){ puts(LV2_CORE_URI); return 0; }'' ""}
      ${chk ''"$W/t" && ls "$out/lib/amd64/lv2/core.lv2/lv2core.ttl"'' "^http://lv2plug\\.in/ns/lv2core$"}
    '';
  };

  # ---- recipes4 batch 9: X11 client libraries the R8 chain made buildable (each the sole missing input of queued jobs) -----------
  # xlib: one X.Org autotools client library: <pname> <version> <tarball path under releases/individual> <sha256> <deps> <check C> <-l..>
  # (nixpkgs builds each with plain configure; no docs, manSections as above, a test program that links and runs the library)
  xlib = pname: version: path: sha256: d: tsrc: libs: mkSrcPkg {
    inherit pname version;
    src = { url = "https://xorg.freedesktop.org/releases/individual/${path}"; inherit sha256; };
    deps = [ world ] ++ d; linkDeps = [ base.xorgproto libxau libxdmcp libxcb ]; nativeTools = [ base.pkgconf gnum4 ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-specs --disable-devel-docs \
        --without-xmlto --without-fop --without-xsltproc --without-doxygen ${manSections}
      gmake -j8; gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      ${tprog tsrc libs}
      ${chk ''"$W/t"'' "^ok "}
    '';
  };
  # a test body: the library's own call, and whether it reports "no display" the way Xlib does without a server
  noDpy = inc: call: ''#include <X11/Xlib.h>
${inc}
#include <stdio.h>
int main(void){ Display *d = XOpenDisplay(":solnix-none"); ${call}; printf("ok %d\n", d == NULL); return 0; }'';
  xcbT = inc: call: ''#include <xcb/xcb.h>
${inc}
#include <stdio.h>
int main(void){ int s; xcb_connection_t *c = xcb_connect(":solnix-none", &s); ${call}; printf("ok %d\n", xcb_connection_has_error(c) != 0);
xcb_disconnect(c); return 0; }'';

  libxrender = xlib "libxrender" "0.9.13" "lib/libXrender-0.9.13.tar.xz" "3fe88c609df6782e1e7af2e4de36b2563d70cd70ff7dcb1cda561ad64912bb64"
    [ libx11 ] (noDpy "#include <X11/extensions/Xrender.h>" "(void)XRenderFindStandardFormat") "-lXrender -lX11";
  libxfixes = xlib "libxfixes" "6.0.2" "lib/libXfixes-6.0.2.tar.xz" "39f115d72d9c5f8111e4684164d3d68cc1fd21f9b27ff2401b08fddfc0f409ba"
    [ libx11 ] (noDpy "#include <X11/extensions/Xfixes.h>" "(void)XFixesQueryExtension") "-lXfixes -lX11";
  libxinerama = xlib "libxinerama" "1.1.6" "lib/libXinerama-1.1.6.tar.xz" "d00fc1599c303dc5cbc122b8068bdc7405d6fcb19060f4597fc51bd3a8be51d7"
    [ libx11 libxext ] (noDpy "#include <X11/extensions/Xinerama.h>" "(void)XineramaIsActive") "-lXinerama -lXext -lX11";
  libxxf86vm = xlib "libxxf86vm" "1.1.7" "lib/libXxf86vm-1.1.7.tar.xz" "ae50c0f669e0af5a67cc4cd0f54f21d64a64d2660af883e80e95d3fe51b945d8"
    [ libx11 libxext ] (noDpy "#include <X11/extensions/xf86vmode.h>" "(void)XF86VidModeQueryExtension") "-lXxf86vm -lXext -lX11";
  libxv = xlib "libxv" "1.0.13" "lib/libXv-1.0.13.tar.xz" "7d34910958e1c1f8d193d828fea1b7da192297280a35437af0692f003ba03755"
    [ libx11 libxext ] (noDpy "#include <X11/extensions/Xvlib.h>" "(void)XvQueryExtension") "-lXv -lXext -lX11";
  libxscrnsaver = xlib "libxscrnsaver" "1.2.5" "lib/libXScrnSaver-1.2.5.tar.xz" "5057365f847253e0e275871441e10ff7846c8322a5d88e1e187d326de1cd8d00"
    [ libx11 libxext ] (noDpy "#include <X11/extensions/scrnsaver.h>" "(void)XScreenSaverQueryExtension") "-lXss -lXext -lX11";
  libxres = xlib "libxres" "1.2.3" "lib/libXres-1.2.3.tar.xz" "d2de8f5401d6c86a8992791654547eb8def585dfdc0c08cc16e24ef6aeeb69dc"
    [ libx11 libxext ] (noDpy "#include <X11/extensions/XRes.h>" "(void)XResQueryExtension") "-lXRes -lXext -lX11";
  libxrandr = xlib "libxrandr" "1.5.5" "lib/libXrandr-1.5.5.tar.xz" "72b922c2e765434e9e9f0960148070bd4504b288263e2868a4ccce1b7cf2767a"
    [ libx11 libxext libxrender ] (noDpy "#include <X11/extensions/Xrandr.h>" "(void)XRRQueryExtension") "-lXrandr -lXrender -lXext -lX11";
  libxi = xlib "libxi" "1.8.4" "lib/libXi-1.8.4.tar.xz" "ddd6057b89a91903bc2f884d55c8467440906945e482c36547260dff28661afc"
    [ libx11 libxext libxfixes ] (noDpy "#include <X11/extensions/XInput2.h>" "(void)XIQueryVersion") "-lXi -lXfixes -lXext -lX11";
  libxcursor = xlib "libxcursor" "1.2.3" "lib/libXcursor-1.2.3.tar.xz" "fde9402dd4cfe79da71e2d96bb980afc5e6ff4f8a7d74c159e1966afb2b2c2c0"
    [ libx11 libxfixes libxrender ] (noDpy "#include <X11/Xcursor/Xcursor.h>" "XcursorImage *i = XcursorImageCreate(2, 2); if (!i) return 1; XcursorImageDestroy(i)") "-lXcursor -lXrender -lXfixes -lX11";
  libxdamage = xlib "libxdamage" "1.1.7" "lib/libXdamage-1.1.7.tar.xz" "127067f521d3ee467b97bcb145aeba1078e2454d448e8748eb984d5b397bde24"
    [ libx11 libxfixes ] (noDpy "#include <X11/extensions/Xdamage.h>" "(void)XDamageQueryExtension") "-lXdamage -lXfixes -lX11";
  libxcomposite = xlib "libxcomposite" "0.4.7" "lib/libXcomposite-0.4.7.tar.xz" "8bdf310967f484503fa51714cf97bff0723d9b673e0eecbf92b3f97c060c8ccb"
    [ libx11 libxfixes ] (noDpy "#include <X11/extensions/Xcomposite.h>" "(void)XCompositeQueryExtension") "-lXcomposite -lXfixes -lX11";
  libxtst = xlib "libxtst" "1.2.5" "lib/libXtst-1.2.5.tar.xz" "b50d4c25b97009a744706c1039c598f4d8e64910c9fde381994e1cae235d9242"
    [ libx11 libxext libxi libxfixes ] (noDpy "#include <X11/extensions/XTest.h>" "(void)XTestQueryExtension") "-lXtst -lXi -lXext -lX11";
  # (the check registers a protocol in memory: IceListenForConnections would create the HOST's /tmp/.ICE-unix, outside the build dir)
  libice = xlib "libice" "1.1.2" "lib/libICE-1.1.2.tar.xz" "974e4ed414225eb3c716985df9709f4da8d22a67a2890066bc6dfc89ad298625"
    [ xtrans ] ''#include <X11/ICE/ICElib.h>
#include <stdio.h>
static void pm(IceConn c, IcePointer d, int o, unsigned long l, Bool s, IceReplyWaitInfo *r, Bool *h) { (void)c; (void)d; (void)o; (void)l; (void)s; (void)r; (void)h; }
int main(void){ IcePoVersionRec v = { 1, 0, pm }; int op = IceRegisterForProtocolSetup("solnix", "solnix", "1.0", 1, &v, 0, NULL, NULL, NULL);
printf("ok %d\n", op > 0); return op <= 0; }'' "-lICE";
  libxcb-util = xlib "libxcb-util" "0.4.1" "xcb/xcb-util-0.4.1.tar.xz" "5abe3bbbd8e54f0fa3ec945291b7e8fa8cfd3cccc43718f8758430f94126e512"
    [ libxcb ] (xcbT "#include <xcb/xcb_aux.h>" "(void)xcb_aux_get_depth") "-lxcb-util -lxcb";
  libxcb-keysyms = xlib "libxcb-keysyms" "0.4.1" "xcb/xcb-util-keysyms-0.4.1.tar.xz" "7c260a5294412aed429df1da2f8afd3bd07b7cba3fec772fba15a613a6d5c638"
    [ libxcb ] (xcbT "#include <xcb/xcb_keysyms.h>" "if (!xcb_is_keypad_key(0xff8d)) return 1") "-lxcb-keysyms -lxcb";
  libxcb-render-util = xlib "libxcb-render-util" "0.3.10" "xcb/xcb-util-renderutil-0.3.10.tar.xz" "3e15d4f0e22d8ddbfbb9f5d77db43eacd7a304029bf25a6166cc63caa96d04ba"
    [ libxcb ] (xcbT "#include <xcb/xcb_renderutil.h>" "(void)xcb_render_util_find_standard_format") "-lxcb-render-util -lxcb-render -lxcb";
  libxcb-wm = xlib "libxcb-wm" "0.4.2" "xcb/xcb-util-wm-0.4.2.tar.xz" "62c34e21d06264687faea7edbf63632c9f04d55e72114aa4a57bb95e4f888a0b"
    [ libxcb ] (xcbT "#include <xcb/xcb_icccm.h>" "(void)xcb_icccm_get_wm_name") "-lxcb-icccm -lxcb";

  # libxkbfile (HPND, MIT-open-group): XKB keymap file routines (xkbcomp, xorg-server). meson, as nixpkgs.
  libxkbfile = mkSrcPkg {
    pname = "libxkbfile"; version = "1.2.0";
    src = { url = "https://xorg.freedesktop.org/releases/individual/lib/libxkbfile-1.2.0.tar.xz";
            sha256 = "7f71884e5faf56fb0e823f3848599cf9b5a9afce51c90982baeb64f635233ebf"; };
    deps = [ world libx11 ]; linkDeps = [ base.xorgproto libxcb libxau libxdmcp ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild ""}
      ${tprog (noDpy "#include <stdio.h>\n#include <string.h>\n#include <X11/XKBlib.h>\n#include <X11/extensions/XKBfile.h>" ''char *t = XkbKeysymText(0xff0d, 0); if (!t || strcmp(t, "Return")) return 1'') "-lxkbfile -lX11"}
      ${chk ''"$W/t"'' "^ok "}
    '';
  };

  # ---- recipes4 batch 10: what R9 made buildable, and small leaves the queue's other jobs wait on ---------------------------------
  # libXft (HPND-sell-variant): client-side fonts for X (freetype + fontconfig); freetype2.pc's private requirements as link inputs
  libxft = mkSrcPkg {
    pname = "libxft"; version = "2.3.9";
    src = { url = "https://xorg.freedesktop.org/releases/individual/lib/libXft-2.3.9.tar.xz";
            sha256 = "60a25b78945ed6932635b3bb1899a517d31df7456e69867ffba27f89ff3976f5"; };
    deps = [ world libx11 libxrender fontconfig freetype ]; linkDeps = [ base.xorgproto libxcb libxau libxdmcp graphics.expat ] ++ ftPriv;
    nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static ${manSections}
      gmake -j8; gmake install
      # Xft.h includes <ft2build.h>: freetype's include dir, from the installed xft.pc (as a consumer gets it)
      ${tprog (noDpy "#include <X11/Xft/Xft.h>" "if (XftGetVersion() != 20309) return 1") ''$(PKG_CONFIG_PATH="$out/lib/amd64/pkgconfig:$PKG_CONFIG_LIBDIR" pkg-config --cflags xft) -lXft -lXrender -lX11''}
      ${chk ''"$W/t"'' "^ok "}
    '';
  };
  libxpresent = xlib "libxpresent" "1.0.2" "lib/libXpresent-1.0.2.tar.xz" "4e5b21b4812206a4b223013606ae31170502c1043038777a1ef8f70c09d37602"
    [ libx11 libxext libxfixes libxrandr libxrender ] (noDpy "#include <X11/extensions/Xpresent.h>" "(void)XPresentQueryExtension") "-lXpresent -lX11";
  libxvmc = xlib "libxvmc" "1.0.15" "lib/libXvMC-1.0.15.tar.xz" "4f518afde3d7fd435346af7b368d2f73517f3d5f82647c962caf3f7bb8ff7078"
    [ libx11 libxext libxv ] (noDpy "#include <X11/extensions/XvMClib.h>" "(void)XvMCQueryExtension") "-lXvMC -lXv -lXext -lX11";
  libxcb-image = xlib "libxcb-image" "0.4.1" "xcb/xcb-util-image-0.4.1.tar.xz" "ccad8ee5dadb1271fd4727ad14d9bd77a64e505608766c4e98267d9aede40d3d"
    [ libxcb libxcb-util ] (xcbT "#include <xcb/xcb_image.h>" ''xcb_image_t *i = xcb_image_create_native(c, 4, 4, XCB_IMAGE_FORMAT_Z_PIXMAP, 24, NULL, ~0, NULL); (void)i'') "-lxcb-image -lxcb-util -lxcb";
  # yasm (BSD-2-Clause): the x86 assembler (ffmpeg, libvpx, x264 build with it). nixpkgs' gcc 15 patch.
  yasm = mkSrcPkg {
    pname = "yasm"; version = "1.3.0";
    src = { url = "https://www.tortall.net/projects/yasm/releases/yasm-1.3.0.tar.gz";
            sha256 = "3dce6601b495f5b3d45b59f7d2492a340ee7e84b5beca17e48f862502bd5603f"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/ya/yasm/gcc-15.patch" "c0d34f6aa9706b78bf734a19b6ea344c232f636e28980398e3ab13227881b923"}
      ./configure --prefix="$out" --disable-python --disable-python-bindings
      gmake -j8; gmake install
      printf 'bits 64\nmov eax, 42\nret\n' > "$W/t.asm"
      ${chk ''"$out/bin/yasm" -f elf64 -o "$W/t.o" "$W/t.asm" && od -An -tx1 -N4 "$W/t.o"'' "7f 45 4c 46"}
    '';
  };
  # abseil-cpp (Apache-2.0): Google's C++ common libraries (protobuf, grpc, re2). cmake, shared, as nixpkgs (test helpers off:
  # nixpkgs builds them into a separate output against gtest; no queued job needs them).
  abseil-cpp = mkSrcPkg {
    pname = "abseil-cpp"; version = "20260817.0";
    src = { url = "https://codeload.github.com/abseil/abseil-cpp/tar.gz/refs/tags/20260817.0";
            sha256 = "f7e05179df39c45434cad433f5783840bb3788ef322976f9138bc6b72b3a107d"; };
    deps = [ world ]; nativeTools = [ cmake base.pkgconf ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DABSL_BUILD_TEST_HELPERS=OFF -DABSL_BUILD_TESTING=OFF -DABSL_PROPAGATE_CXX_STD=ON"}
      cat > "$W/t.cc" <<'TPROG'
#include <absl/strings/str_cat.h>
#include <absl/strings/str_split.h>
#include <iostream>
#include <vector>
int main(){ std::vector<std::string> v = absl::StrSplit("a,b,c", ','); std::cout << absl::StrCat("ok ", v.size(), " ", v[2]) << "\n"; }
TPROG
      # the link line from abseil's own pkg-config files (which libraries absl_strings pulls in changes between LTS releases)
      "$CXX" -std=c++17 "$W/t.cc" $(PKG_CONFIG_PATH="$out/lib/amd64/pkgconfig" pkg-config --cflags --libs absl_strings) -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 3 c$"}
    '';
  };

  # ---- recipes5 batch 11: GNU ld version scripts on illumos (../version-script-mapfile.sh) -----------------------------------------
  # Each of these links its shared library with -Wl,--version-script, which illumos ld rejects (or, with configure's probe, drops and
  # exports nothing or everything). vsMap puts the shim in front of $CC/$CXX: it links once, reads the defined names, and links again
  # with the equivalent v2 mapfile, so the library exports exactly the script's symbols, in its version nodes. Each check below links
  # the installed library BY PATH: the cc wrapper's -L order puts the gate's own libmd/libcrypt ahead of $out (R10's libmd "exports
  # nothing" was that, the test linking the gate's libmd), and pvs/elfdump assert the version nodes and that internals stay local.
  vsMap = ''"$BASH" ${../version-script-mapfile.sh} wrap'';
  # <lib> <version node> <symbol>: the library defines <symbol> in <version node>, exported (pvs prints "NODE: sym;")
  hasVer = lib: node: sym: ''/usr/bin/pvs -dos "${lib}" | grep -q "[[:space:]]${node}: ${sym};$" || { echo "FATAL: ${lib} lacks ${node}: ${sym}" >&2; /usr/bin/pvs -do "${lib}" >&2; exit 1; }'';
  # <lib> <symbol>: <symbol> is not exported (the script made it local)
  notExp = lib: sym: ''! /usr/bin/elfdump -s -N .dynsym "${lib}" | grep -qE " ${sym}$" || { echo "FATAL: ${lib} exports ${sym}" >&2; exit 1; }'';

  # zlib-ng (Zlib): the zlib replacement with SIMD paths, native API (libz-ng), as nixpkgs (no compat, no utils, no tests).
  zlib-ng = mkSrcPkg {
    pname = "zlib-ng"; version = "2.3.3";
    src = { url = "https://codeload.github.com/zlib-ng/zlib-ng/tar.gz/refs/tags/2.3.3";
            sha256 = "f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${vsMap}
      # HAVE_SYMVER turns on gas .symver aliases (zng_* @ZLIB_NG_x), which illumos ld does not version: the plain names, in the map
      grep -q 'add_definitions(-DHAVE_SYMVER)' CMakeLists.txt || { echo "FATAL: zlib-ng HAVE_SYMVER anchor" >&2; exit 1; }
      sed -i 's/add_definitions(-DHAVE_SYMVER)/# illumos: no .symver (solnix)/' CMakeLists.txt
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DINSTALL_UTILS=OFF -DBUILD_TESTING=OFF"}
      L="$out/lib/amd64/libz-ng.so.2"
      ${hasVer "$L" "ZLIB_NG_2.0.0" "zng_compress"}
      ${hasVer "$L" "ZLIB_NG_2.1.0" "zlibng_version"}
      ${hasVer "$L" "ZLIB_NG_GZ_2.0.0" "zng_gzopen"}
      ${tprog ''#include <zlib-ng.h>
#include <stdio.h>
#include <string.h>
int main(void){ const char *s = "solnix solnix solnix solnix"; uint8_t z[128], o[128]; size_t zl = sizeof z, ol = sizeof o;
if (zng_compress(z, &zl, (const uint8_t *)s, strlen(s)) != Z_OK || zng_uncompress(o, &ol, z, zl) != Z_OK) return 1;
printf("ok %s %.*s\n", zlibng_version(), (int)ol, o); return 0; }'' "$L"}
      ${chk ''"$W/t"'' "^ok 2\\.3\\.3 solnix solnix"}
    '';
  };

  # libmd (BSD-3-Clause and others): message digest functions from BSD (libbsd's dependency). configure's --version-script probe
  # fails on illumos, so upstream falls back to libtool -export-symbols; the shim makes the probe pass and gives it its LIBMD_0.x nodes.
  libmd = mkSrcPkg {
    pname = "libmd"; version = "1.3.0";
    src = { url = "https://archive.hadrons.org/software/libmd/libmd-1.3.0.tar.xz";
            sha256 = "fc0f1eb6b6766470326f2c014693809190e67dba84274a6fbae9d4912d066706"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${vsMap}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      grep -q '^HAVE_LINKER_VERSION_SCRIPT_TRUE=$' config.status 2>/dev/null || grep -q 'libmd_cv_version_script=yes' config.log || { echo "FATAL: libmd did not take the version script" >&2; exit 1; }
      gmake -j8; gmake install
      L="$out/lib/amd64/libmd.so.0"
      ${hasVer "$L" "LIBMD_0.0" "SHA256Data"}
      ${hasVer "$L" "LIBMD_0.1" "SHA224Data"}
      ${hasVer "$L" "LIBMD_0.3" "SHA512_224Data"}
      ${tprog ''#include <sha2.h>
#include <md5.h>
#include <stdio.h>
int main(void){ char b[SHA256_DIGEST_STRING_LENGTH], m[MD5_DIGEST_STRING_LENGTH];
printf("%s %s\n", SHA256Data((const unsigned char *)"abc", 3, b), MD5Data((const unsigned char *)"abc", 3, m)); return 0; }'' "$L"}
      ${chk ''"$W/t"'' "^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 900150983cd24fb0d6963f7d28e17f72$"}
    '';
  };

  # libbsd (BSD-3-Clause, ISC, MIT, beerware and others): BSD utility functions (strlcpy, humanize_number, vis, setproctitle...).
  # Its libbsd.map has LIBBSD_0.x nodes; local-link.h already turns .symver off on __sun (plain aliases), so the shim's mapfile is all.
  libbsd = mkSrcPkg {
    pname = "libbsd"; version = "0.12.2";
    src = { url = "https://libbsd.freedesktop.org/releases/libbsd-0.12.2.tar.xz";
            sha256 = "b88cc9163d0c652aaf39a99991d974ddba1c3a9711db8f1b5838af2a14731014"; };
    deps = [ world libmd ]; nativeTools = hostTools;
    build = ''
      ${vsMap}
      grep -q '#if defined(__ELF__) && !defined(__sun)' src/local-link.h || { echo "FATAL: libbsd __sun symver anchor" >&2; exit 1; }
      # the 0.12.2 tarball lacks two pages man/Makefile.am installs when api_time_macros is on, which only its solaris2* case sets
      # ("No rule to make target 'TIMESPEC_TO_TIMEVAL.3bsd'"): the files at the 0.12.2 tag
      [ ! -e man/TIMESPEC_TO_TIMEVAL.3bsd ] || { echo "FATAL: libbsd man page anchor" >&2; exit 1; }
      cp ${fetch "https://gitlab.freedesktop.org/libbsd/libbsd/-/raw/0.12.2/man/TIMESPEC_TO_TIMEVAL.3bsd" "504b636281bea0b11865cac41cbaf96bbc44e077780f840d098091756dce9650"} man/TIMESPEC_TO_TIMEVAL.3bsd
      cp ${fetch "https://gitlab.freedesktop.org/libbsd/libbsd/-/raw/0.12.2/man/TIMEVAL_TO_TIMESPEC.3bsd" "df53343e36c43c64f109621e9f554e05dc7d7606e34cfad91c74697f4db2aabf"} man/TIMEVAL_TO_TIMESPEC.3bsd
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      grep -q 'libbsd_cv_version_script=yes' config.log || { echo "FATAL: libbsd did not take the version script" >&2; exit 1; }
      gmake -j8; gmake install
      L="$out/lib/amd64/libbsd.so.0"
      ${hasVer "$L" "LIBBSD_0.0" "humanize_number"}
      ${hasVer "$L" "LIBBSD_0.5" "setproctitle"}
      ${tprog ''#include <bsd/libutil.h>
#include <bsd/vis.h>
#include <stdio.h>
int main(void){ char h[16], v[32]; if (humanize_number(h, sizeof h, 1536, "B", HN_AUTOSCALE, HN_DECIMAL) < 0) return 1;
strvis(v, "a\tb", VIS_TAB); printf("ok %s %s\n", h, v); return 0; }'' "-I$out/include $L ${libmd}/lib/amd64/libmd.so.0"}
      ${chk ''"$W/t"'' "^ok 1536 B a\\\\011b$"}
    '';
  };

  # libxcrypt (LGPL-2.1+): crypt(3) with the modern hashes (yescrypt, bcrypt, sha512crypt), as nixpkgs: strong hashes plus the glibc
  # API names. Installed under its own prefix; nothing here replaces the gate's crypt. configure's AX_CHECK_VSCRIPT takes
  # --version-script through the shim; its .symver aliases (GLIBC_2.x compat) are off: illumos has no glibc binaries to keep working.
  libxcrypt = mkSrcPkg {
    pname = "libxcrypt"; version = "4.5.2";
    src = { url = "https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz";
            sha256 = "71513a31c01a428bccd5367a32fd95f115d6dac50fb5b60c779d5c7942aec071"; };
    deps = [ world ]; nativeTools = [ perl ] ++ hostTools;
    build = ''
      ${vsMap}
      # --enable-obsolete-api=glibc asks for glibc's compat versions, and compute-symver-floor has no row for solaris (ERROR); the
      # library itself is the same with the API names, so: no obsolete compat ABI, the XCRYPT_x.y nodes only (soname libcrypt.so.2)
      # configure finds the gate's memset_s (explicit_bzero's mapping), which <string.h> declares only under __STDC_WANT_LIB_EXT1__
      # with the version script on, crypt-symbol-vers.h defines each public name as _crypt_<name> plus a gas .symver alias, which the
      # shim refuses (illumos ld keeps crypt@@XCRYPT_2.0 as a literal name): the plain names, which the mapfile puts in the same nodes.
      # In Makefile.in: config.status's depfiles step already runs make, which writes the header, so a make-line override comes too late.
      grep -q '^@HAVE_VSCRIPT_TRUE@APPLY_SYMVERS = yes$' Makefile.in || { echo "FATAL: libxcrypt APPLY_SYMVERS anchor" >&2; exit 1; }
      sed -i 's/^@HAVE_VSCRIPT_TRUE@APPLY_SYMVERS = yes$/@HAVE_VSCRIPT_TRUE@APPLY_SYMVERS = no/' Makefile.in
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-hashes=strong --enable-obsolete-api=no \
        --disable-failure-tokens --disable-werror CPPFLAGS="-D__STDC_WANT_LIB_EXT1__=1"
      grep -q '^ax_cv_check_vscript_flag=--version-script$' config.log || { echo "FATAL: libxcrypt did not take the version script" >&2; exit 1; }
      gmake -j8; gmake install
      L="$out/lib/amd64/libcrypt.so.2"
      ${hasVer "$L" "XCRYPT_2.0" "crypt"}
      ${hasVer "$L" "XCRYPT_4.4" "crypt_preferred_method"}
      ${notExp "$L" "_crypt_SHA512_Init"}
      ${tprog ''#include <crypt.h>
#include <stdio.h>
#include <string.h>
int main(void){ const char *h = crypt("solnix", "$6$saltsalt$"); if(!h) return 1;
printf("%s %s\n", h, strcmp(crypt("solnix", h), h) == 0 ? "ok" : "mismatch"); return 0; }'' "$L"}
      ${chk ''"$W/t"'' "^\\$6\\$saltsalt\\$33\\.Cb4hCnPicks6gFCE/YYdT3qzit5vGSFkrdDqfvSYcPet7EW2D26kjMFg42rnWB1DE0rb9cotvnIw9eVZQh/ ok$"}
    '';
  };

  # libglvnd (MIT-style, BSD; its GPL-3 parts are the autotools ax_pthread macro only, not built with meson): the vendor-neutral GL
  # dispatch layer (libGL, libEGL, libGLX, libOpenGL, libGLES* over libGLdispatch), Mesa's front end when several vendors coexist.
  # meson, as upstream builds it; GLdispatch's export list is a version script, the others link -Bsymbolic (illumos ld has it).
  # x86-64 has no illumos case in its asm table, so the pure C dispatch (nixpkgs uses the same on every non-listed system).
  libglvnd = mkSrcPkg {
    pname = "libglvnd"; version = "1.7.0";
    src = { url = "https://gitlab.freedesktop.org/glvnd/libglvnd/-/archive/v1.7.0/libglvnd-v1.7.0.tar.gz";
            sha256 = "2b6e15b06aafb4c0b6e2348124808cbd9b291c647299eaaba2e3202f51ff2f3d"; };
    deps = [ world libx11 libxext ]; linkDeps = [ base.xorgproto libxcb libxau libxdmcp ]; nativeTools = mesonTools;
    build = ''
      ${vsMap}
      ${mesonBuild "-Dasm=disabled -Dx11=enabled -Dglx=enabled -Degl=true -Dgles1=true -Dgles2=true -Dheaders=true"}
      L="$out/lib/amd64/libGLdispatch.so.0"
      ${hasVer "$L" "libGLdispatch.so.0" "__glDispatchInit"}
      ${notExp "$L" "mt_create"}
      for l in libGL.so.1 libEGL.so.1 libGLX.so.0 libOpenGL.so.0 libGLESv2.so.2; do
        [ -f "$out/lib/amd64/$l" ] || { echo "FATAL: libglvnd: no $l" >&2; exit 1; }
      done
      /usr/bin/elfdump -d "$out/lib/amd64/libEGL.so.1" | grep -q 'FLAGS .*SYMBOLIC' || { echo "FATAL: libEGL not -Bsymbolic" >&2; exit 1; }
      # upstream's own dispatch and EGL tests (dummy vendors from the build tree, no display, no GPU, nothing outside the build dir)
      # bin/symbols-check.py drops the link-editor's own names only on Linux/GNU/Haiku; illumos ld adds _DYNAMIC, _GLOBAL_OFFSET_TABLE_,
      # _PROCEDURE_LINKAGE_TABLE_ and _etext to every shared object (_edata/_end/_init/_fini are listed already): add SunOS and those 4
      grep -q "if platform_name in \['Linux', 'GNU', 'Haiku'\]" bin/symbols-check.py && grep -q "^    '__bss_end__',$" bin/symbols-check.py \
        || { echo "FATAL: libglvnd symbols-check anchor" >&2; exit 1; }
      sed -i -e "s/if platform_name in \['Linux', 'GNU', 'Haiku'\]/if platform_name in ['Linux', 'GNU', 'Haiku', 'SunOS']/" \
        -e "s/^    '__bss_end__',$/    '__bss_end__', '_DYNAMIC', '_GLOBAL_OFFSET_TABLE_', '_PROCEDURE_LINKAGE_TABLE_', '_etext',/" bin/symbols-check.py
      # every library's exports against upstream's lists (the symbols suite), and the dispatch and EGL tests; the 8 generated/patched
      # dispatch tests skip (77): they need asm entrypoints, which x86-64 illumos does not get (pure C dispatch)
      mrc=0; meson test -C _b --suite gldispatch --suite egl --suite symbols --print-errorlogs > "$W/mt.log" 2>&1 || mrc=$?   # set -e: keep the rc
      grep -E '^ *[0-9]+/[0-9]+ ' "$W/mt.log" >&2 || true
      [ $mrc = 0 ] || { echo "FATAL: libglvnd meson test rc=$mrc" >&2; tail -80 "$W/mt.log" >&2; exit 1; }
      ${tprog ''#include <EGL/egl.h>
#include <stdio.h>
int main(void){ const char *e = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS); printf("ok %d\n", e != NULL); return 0; }'' "$out/lib/amd64/libEGL.so.1"}
      ${chk ''__EGL_VENDOR_LIBRARY_DIRS="$W/none" "$W/t"'' "^ok 1$"}
    '';
  };

  # ---- recipes5 batch 12: tk on main's tcl; the Vulkan loader on illumos -----------------------------------------------------------
  # tk (TCL): the Tk toolkit (wish, Tkinter's library), on main's served tcl 8.6.16 and the R9/R10 X11 libraries (Xft fonts, XScrnSaver
  # idle time). As nixpkgs: threads, 64-bit, man symlinks, its find-library patch (tk_library compiled in), the wish -> wish8.6 link.
  # tkConfig.sh names the build dir in TK_SRC_DIR/TK_BUILD_* as every tkConfig.sh does (NixOS's: /build/tk8.6.16); here that is the
  # drv-keyed /var/tmp/srcpkg-<key>, which the gate counts as WARN B8, the same as main's served tcl's tclConfig.sh.
  tk = mkSrcPkg {
    pname = "tk"; version = "8.6.16";
    src = { url = "https://downloads.sourceforge.net/tcl/tk8.6.16-src.tar.gz";
            sha256 = "be9f94d3575d4b3099d84bc3c10de8994df2d7aa405208173c709cc404a7e5fe"; };
    deps = [ world tcl libx11 libxft libxext libxscrnsaver fontconfig freetype ];
    linkDeps = [ base.xorgproto libxcb libxau libxdmcp libxrender graphics.expat ] ++ ftPriv;
    nativeTools = [ base.pkgconf gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/development/libraries/tk/tk-8_6_13-find-library.patch" "a77b8da4dbcf7ad224ce065ae392d610efa279ba781d1cc81cbc14893c3ab9d6"}
      cd unix
      # X headers and libraries from the store deps (AC_PATH_X would also try the host's /usr/X11/include, /usr/openwin/include)
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --with-tcl=${tcl}/lib/amd64 --with-tclinclude=${tcl}/include \
        --enable-threads --enable-64bit --enable-man-symlinks \
        --x-includes=${libx11}/include --x-libraries=${libx11}/lib/amd64
      grep -q '^AC_FLAGS.*-DHAVE_XFT=1' Makefile || { echo "FATAL: tk configured without Xft" >&2; exit 1; }
      grep -q '^AC_FLAGS.*-DHAVE_XSS=1' Makefile || { echo "FATAL: tk configured without XScrnSaver" >&2; exit 1; }
      gmake -j8; gmake install
      ln -s wish8.6 "$out/bin/wish"
      ln -s libtk8.6.so "$out/lib/amd64/libtk.so"
      cp ../generic/*.h ../unix/*.h "$out/include/"
      find "$out/share/doc" -delete 2>/dev/null || true
      # no X server in a build: load Tk's library and its C API through tclsh, then a widget call that needs no display
      printf '%s\n' 'if {[catch {package require Tk} e]} { puts "load: $e" }' 'puts "tk [package provide Tk] [info exists tk_library]"' > "$W/t.tcl"
      ${chk ''DISPLAY=:solnix-none TCLLIBPATH="$out/lib/amd64" ${tcl}/bin/tclsh "$W/t.tcl"'' "couldn.t connect to display"}
      ${tprog ''#include <tk.h>
#include <stdio.h>
int main(void){ Tcl_Interp *i = Tcl_CreateInterp(); if (Tcl_Init(i) != TCL_OK) return 1;
printf("ok %s %d\n", TK_PATCH_LEVEL, Tk_GetNumMainWindows()); return 0; }'' "-I${tcl}/include $out/lib/amd64/libtk8.6.so ${tcl}/lib/amd64/libtcl8.6.so -Wl,-R,${tcl}/lib/amd64"}
      ${chk ''"$W/t"'' "^ok 8\\.6\\.16 0$"}
    '';
  };

  # vulkan-loader (Apache-2.0): the Khronos Vulkan ICD loader (libvulkan.so.1), on the served vulkan-headers 1.4.363.0, X11 (xcb,
  # Xlib, Xrandr) and wayland WSI, as nixpkgs. Upstream has no illumos case; the port is three spots, each a plain POSIX path:
  # - CMakeLists.txt: SunOS joins the Linux|BSD platform case (the WSI options and loader_linux.c's device sort);
  # - vk_loader_platform.h: __sun joins COMMON_UNIX_PLATFORMS (dlopen, pthreads, getenv, the XDG search paths);
  # - its executable path: getexecname(3C) (the others read /proc/self/exe or sysctl).
  # The loader is C99 (CMAKE_C_STANDARD 99), and -std=c99 hides getexecname and strtok_r in illumos' headers: -D__EXTENSIONS__, as
  # dav1d. illumos has secure_getenv (found), so the loader uses it. The gas trampolines for unknown extension functions build on
  # x86-64; nixpkgs' pkg-config patch (its libdir/includedir absolute).
  vulkan-loader = mkSrcPkg {
    pname = "vulkan-loader"; version = "1.4.363.0";
    src = { url = "https://codeload.github.com/KhronosGroup/Vulkan-Loader/tar.gz/refs/tags/vulkan-sdk-1.4.363.0";
            sha256 = "941eff558fc74f248745fb7df367640cf89a8457f216dae498a74ae14b6ba6f7"; };
    deps = [ world vulkan-headers libx11 libxcb libxrandr graphics.wayland ];
    linkDeps = [ base.xorgproto libxau libxdmcp libxext libxrender graphics.libffi ];
    nativeTools = [ cmake base.pkgconf gnupatch python3 ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/vu/vulkan-loader/fix-pkgconfig.patch" "cf3abea999f6da860d172cafc5e632da62673935d73178a09c99221d88866091"}
      [ "$(grep -c 'CMAKE_SYSTEM_NAME MATCHES "Linux|BSD|DragonFly|GNU' CMakeLists.txt loader/CMakeLists.txt | awk -F: '{s+=$2} END{print s}')" = 2 ] || { echo "FATAL: vulkan-loader platform anchor" >&2; exit 1; }
      sed -i 's/CMAKE_SYSTEM_NAME MATCHES "Linux|BSD|DragonFly|GNU/CMAKE_SYSTEM_NAME MATCHES "Linux|BSD|DragonFly|GNU|SunOS/' CMakeLists.txt loader/CMakeLists.txt
      grep -q 'defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__) || defined(__GNU__) || defined(__CYGWIN__)$' loader/vk_loader_platform.h || { echo "FATAL: vulkan-loader COMMON_UNIX anchor" >&2; exit 1; }
      sed -i 's/defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__) || defined(__GNU__) || defined(__CYGWIN__)$/defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__) || defined(__GNU__) || defined(__CYGWIN__) || defined(__sun)/' loader/vk_loader_platform.h
      grep -q '^#elif defined(__Fuchsia__) || defined(__OpenBSD__)$' loader/vk_loader_platform.h || { echo "FATAL: vulkan-loader executable_path anchor" >&2; exit 1; }
      sed -i 's|^#elif defined(__Fuchsia__) \|\| defined(__OpenBSD__)$|#elif defined(__sun)\n#include <stdlib.h>\nstatic inline char *loader_platform_executable_path(char *buffer, size_t size) {\n    const char *p = getexecname();\n    if (p == NULL \|\| strlen(p) >= size) return NULL;\n    strcpy(buffer, p);\n    return buffer;\n}\n#elif defined(__Fuchsia__) \|\| defined(__OpenBSD__)|' loader/vk_loader_platform.h
      # FindGit took the build host's /bin/git (gate L5); it only reads a .git/HEAD, which a tarball has not: off, as cli/c-recipes2.nix
      ${cmakeB "-DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE -DCMAKE_C_FLAGS=-D__EXTENSIONS__ -DCMAKE_INSTALL_INCLUDEDIR=${vulkan-headers}/include -DBUILD_WSI_XCB_SUPPORT=ON -DBUILD_WSI_XLIB_SUPPORT=ON -DBUILD_WSI_WAYLAND_SUPPORT=ON -DBUILD_TESTS=OFF -DVULKAN_HEADERS_INSTALL_DIR=${vulkan-headers}"}
      L="$out/lib/amd64/libvulkan.so.1"
      [ -f "$L" ] || { echo "FATAL: no libvulkan.so.1" >&2; exit 1; }
      /usr/bin/elfdump -s -N .dynsym "$L" | grep -qE ' vkCreateXcbSurfaceKHR$' || { echo "FATAL: libvulkan without XCB WSI" >&2; exit 1; }
      /usr/bin/elfdump -s -N .dynsym "$L" | grep -qE ' vkCreateWaylandSurfaceKHR$' || { echo "FATAL: libvulkan without Wayland WSI" >&2; exit 1; }
      grep -q "^includedir=${vulkan-headers}/include$" "$out/lib/amd64/pkgconfig/vulkan.pc" || { echo "FATAL: vulkan.pc includedir" >&2; exit 1; }
      # no GPU and no ICD here: the loader must start, read the (empty) driver search path, and report the API version and no device
      ${tprog ''#include <vulkan/vulkan.h>
#include <stdio.h>
int main(void){ uint32_t v = 0; if (vkEnumerateInstanceVersion(&v) != VK_SUCCESS) return 1;
VkApplicationInfo a = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "solnix", 1, NULL, 0, VK_API_VERSION_1_0 };
VkInstanceCreateInfo c = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &a, 0, NULL, 0, NULL }; VkInstance i;
VkResult r = vkCreateInstance(&c, NULL, &i);
printf("ok %u.%u.%u %d\n", VK_API_VERSION_MAJOR(v), VK_API_VERSION_MINOR(v), VK_API_VERSION_PATCH(v), r); return 0; }'' "-I${vulkan-headers}/include $L"}
      ${chk ''VK_DRIVER_FILES="$W/none.json" XDG_CONFIG_HOME="$W" XDG_DATA_HOME="$W" HOME="$W" "$W/t"'' "^ok 1\\.4\\.363 -9$"}
    '';
  };

  # ---- recipes5 batch 13: leaves the queue's audio, logging and networking jobs wait on --------------------------------------------
  # libvorbis (BSD-3-Clause): the Vorbis audio codec (libvorbis, vorbisenc, vorbisfile) on R1's libogg. autotools, as nixpkgs.
  libvorbis = mkSrcPkg {
    pname = "libvorbis"; version = "1.3.7";
    src = { url = "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz";
            sha256 = "b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b"; };
    deps = [ world libogg ]; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-docs
      gmake -j8; gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      # encode a short tone to Ogg Vorbis in memory, then decode it back: both directions of the codec
      ${tprog ''#include <vorbis/vorbisenc.h>
#include <stdio.h>
#include <math.h>
int main(void){ vorbis_info vi; vorbis_info_init(&vi); if (vorbis_encode_init_vbr(&vi, 1, 44100, 0.4f)) return 1;
vorbis_comment vc; vorbis_comment_init(&vc); vorbis_dsp_state vd; vorbis_block vb; vorbis_analysis_init(&vd, &vi); vorbis_block_init(&vd, &vb);
ogg_packet h, hc, hcode; vorbis_analysis_headerout(&vd, &vc, &h, &hc, &hcode);
float **b = vorbis_analysis_buffer(&vd, 4096); for (int i = 0; i < 4096; i++) b[0][i] = 0.5f * sinf(i * 0.05f);
vorbis_analysis_wrote(&vd, 4096); vorbis_analysis_wrote(&vd, 0); long n = 0; ogg_packet op;
while (vorbis_analysis_blockout(&vd, &vb) == 1) { vorbis_analysis(&vb, NULL); vorbis_bitrate_addblock(&vb); while (vorbis_bitrate_flushpacket(&vd, &op)) n += op.bytes; }
printf("ok %s %d\n", vorbis_version_string(), n > 100); return 0; }'' "-I${libogg}/include $out/lib/amd64/libvorbisenc.so $out/lib/amd64/libvorbis.so ${libogg}/lib/amd64/libogg.so -lm -Wl,-R,${libogg}/lib/amd64"}
      ${chk ''"$W/t"'' "^ok Xiph.Org libVorbis 1\\.3\\.7 1$"}
    '';
  };

  # opusfile (BSD-3-Clause): reading Ogg Opus files (libopusfile, libopusurl with OpenSSL), on libogg, libopus and openssl.
  opusfile = mkSrcPkg {
    pname = "opusfile"; version = "0.12";
    src = { url = "https://downloads.xiph.org/releases/opus/opusfile-0.12.tar.gz";
            sha256 = "118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b"; };
    deps = [ world libogg libopus base.openssl ]; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-examples --disable-doc
      gmake -j8; gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      # a bad stream must be refused with OP_ENOTFORMAT (the parser runs), and the URL library must link
      ${tprog ''#include <opusfile.h>
#include <stdio.h>
int main(void){ static const unsigned char junk[64] = "not an ogg stream at all"; int e = 0;
OggOpusFile *f = op_open_memory(junk, sizeof junk, &e); printf("ok %d %d\n", f == NULL, e == OP_ENOTFORMAT); return 0; }'' "-I${libogg}/include -I${libopus}/include/opus -I$out/include/opus $out/lib/amd64/libopusfile.so $out/lib/amd64/libopusurl.so ${libogg}/lib/amd64/libogg.so ${libopus}/lib/amd64/libopus.so -Wl,-R,${libogg}/lib/amd64:${libopus}/lib/amd64"}
      ${chk ''"$W/t"'' "^ok 1 1$"}
    '';
  };

  # spdlog (MIT): the fast C++ logging library, on main's fmt (SPDLOG_FMT_EXTERNAL), shared, as nixpkgs (tests off: no queued job runs them).
  spdlog = mkSrcPkg {
    pname = "spdlog"; version = "1.17.0";
    src = { url = "https://codeload.github.com/gabime/spdlog/tar.gz/refs/tags/v1.17.0";
            sha256 = "d8862955c6d74e5846b3f580b1605d2428b11d97a410d86e2fb13e857cd3a744"; };
    deps = [ world fmt ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      # illumos' struct tm has no tm_gmtoff (spdlog's unix utc_minutes_offset reads it): on __sun, its Windows method, the local time
      # through timegm(3C) minus mktime, the same offset the field holds
      f=include/spdlog/details/os-inl.h
      n=$(grep -n '^// On unix simply use tm_gmtoff$' $f | cut -d: -f1)
      [ -n "$n" ] && [ "$(sed -n "$((n - 1))p" $f)" = "#else" ] || { echo "FATAL: spdlog tm_gmtoff anchor" >&2; exit 1; }
      cat > "$W/tz.inc" <<'TZ'
#elif defined(__sun)
SPDLOG_INLINE int utc_minutes_offset(const std::tm &tm) {
    std::tm l = tm; std::time_t t = std::mktime(&l); if (t == -1) return 0;
    return static_cast<int>((::timegm(&l) - t) / 60);
}
TZ
      sed -i "$((n - 2))r $W/tz.inc" $f
      grep -q '^#elif defined(__sun)$' $f || { echo "FATAL: spdlog tz insert" >&2; exit 1; }
      ${cmakeB "-DSPDLOG_BUILD_SHARED=ON -DSPDLOG_BUILD_STATIC=OFF -DSPDLOG_BUILD_EXAMPLE=OFF -DSPDLOG_BUILD_BENCH=OFF -DSPDLOG_BUILD_TESTS=OFF -DSPDLOG_FMT_EXTERNAL=ON -Dfmt_DIR=${fmt}/lib/amd64/cmake/fmt"}
      cat > "$W/t.cc" <<'TPROG'
#include <spdlog/spdlog.h>
#include <spdlog/sinks/ostream_sink.h>
#include <iostream>
#include <sstream>
int main(){ std::ostringstream o; auto s = std::make_shared<spdlog::sinks::ostream_sink_mt>(o); spdlog::logger l("t", s);
l.set_pattern("%l %z %v"); l.info("solnix {} {:.2f}", 42, 3.14159); l.flush(); std::cout << "ok " << o.str(); }
TPROG
      "$CXX" -std=c++17 -DSPDLOG_COMPILED_LIB -DSPDLOG_SHARED_LIB -DSPDLOG_FMT_EXTERNAL -I"$out/include" -I${fmt}/include "$W/t.cc" \
        "$out/lib/amd64/libspdlog.so" ${fmt}/lib/amd64/libfmt.so -Wl,-R,"$out/lib/amd64:${fmt}/lib/amd64" -o "$W/t"
      ${chk ''TZ=EST5EDT "$W/t"; TZ=UTC "$W/t"'' "^ok info -0[45]:00 solnix 42 3\\.14$"}
      ${chk ''TZ=UTC "$W/t"'' "^ok info \\+00:00 solnix 42 3\\.14$"}
    '';
  };

  # loguru (Unlicense): a small C++ logging library, shared, with streams (nixpkgs' LOGURU_WITH_STREAMS=1).
  loguru = mkSrcPkg {
    pname = "loguru"; version = "2.2.0";
    src = { url = "https://codeload.github.com/emilk/loguru/tar.gz/refs/tags/v2.2.0";
            sha256 = "519731aa253566048e89523343c39c46efa1c86b2ca1fb9df20343f8744b11ee"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DLOGURU_WITH_STREAMS=1 -DLOGURU_BUILD_EXAMPLES=OFF -DLOGURU_BUILD_TESTS=OFF"}
      cat > "$W/t.cc" <<'TPROG'
#include <loguru.hpp>
#include <cstdio>
int main(int argc, char **argv){ loguru::g_stderr_verbosity = loguru::Verbosity_OFF; loguru::init(argc, argv);
LOG_S(INFO) << "x"; std::printf("ok %d %s\n", LOGURU_WITH_STREAMS, loguru::filename("/a/b/c.cc")); return 0; }
TPROG
      "$CXX" -std=c++17 -DLOGURU_WITH_STREAMS=1 -I"$out/include/loguru" "$W/t.cc" "$out/lib/amd64/libloguru.so" -lpthread -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 1 c\\.cc$"}
    '';
  };

  # miniupnpc (BSD-3-Clause): the UPnP IGD client library and upnpc (port mapping for p2p programs). cmake; its CMakeLists has the
  # SunOS case already. nixpkgs' include fix and its tool names (upnpc, upnp-listdevices, external-ip; the shared builds).
  miniupnpc = mkSrcPkg {
    pname = "miniupnpc"; version = "2.3.3";
    src = { url = "https://codeload.github.com/miniupnp/miniupnp/tar.gz/refs/tags/miniupnpc_2_3_3";
            sha256 = "8cf2c833b3e76fc4893ff29c2a376e3394962449e5970e373c0a91421724d222"; };
    deps = [ world base.bash ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p2 < ${fetch "https://github.com/miniupnp/miniupnp/commit/e263ab6f56c382e10fed31347ec68095d691a0e8.patch" "ba42ba93ef0c0c7dae9b6098a2bc0facccc547f9ae286778dd741f84dbbfe5ec"} -d miniupnpc
      cd miniupnpc
      ${cmakeB "-DUPNPC_BUILD_SHARED=ON -DUPNPC_BUILD_STATIC=OFF -DUPNPC_BUILD_TESTS=OFF"}
      mv "$out"/bin/upnpc-* "$out/bin/upnpc"; mv "$out"/bin/upnp-listdevices-* "$out/bin/upnp-listdevices"
      mv "$out/bin/external-ip.sh" "$out/bin/external-ip"; chmod +x "$out/bin/external-ip"
      # its #!/bin/sh and bare upnpc: the store bash and this upnpc (as nixpkgs' patchShebangs + substituteInPlace)
      head -1 "$out/bin/external-ip" | grep -qx '#!/bin/sh' && grep -q 'upnpc' "$out/bin/external-ip" || { echo "FATAL: external-ip anchors" >&2; exit 1; }
      sed -i "1s|^#!/bin/sh$|#!${base.bash}/bin/bash|; s|upnpc |$out/bin/upnpc |" "$out/bin/external-ip"
      # no network: upnpc prints its usage and version; the library parses a canned IGD description
      ${chk ''"$out/bin/upnpc" 2>/dev/null | head -1'' "^upnpc: miniupnpc library test client, version 2\\.3\\.3\\.$"}
      ${tprog ''#include <miniupnpc/miniupnpc.h>
#include <miniupnpc/upnpcommands.h>
#include <miniupnpc/upnperrors.h>
#include <stdio.h>
int main(void){ printf("ok %d %s\n", MINIUPNPC_API_VERSION, strupnperror(UPNPCOMMAND_INVALID_ARGS)); return 0; }'' "$out/lib/amd64/libminiupnpc.so"}
      ${chk ''"$W/t"'' "^ok 21 Miniupnpc Invalid Arguments$"}
    '';
  };

  # lmdb (OLDAP-2.8): the Lightning memory-mapped key-value store (liblmdb + mdb_* tools). Its plain Makefile, as nixpkgs (its two
  # patches are gcc -> $(CC) in coverage rules and a Windows BINEXT: neither matters here), lmdb.pc as nixpkgs writes it.
  lmdb = mkSrcPkg {
    pname = "lmdb"; version = "0.9.36";
    src = { url = "https://git.openldap.org/openldap/openldap/-/archive/LMDB_0.9.36/openldap-LMDB_0.9.36.tar.gz";
            sha256 = "90a595ea500074af61b213464452d8d212405261094667a686357467ae7b57b9"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      cd libraries/liblmdb
      # its tools link liblmdb.a (built, not installed); the shared library is what nixpkgs ships
      gmake -j8 CC="$CC" AR=ar liblmdb.so liblmdb.a mdb_stat mdb_copy mdb_dump mdb_load
      gmake install CC="$CC" prefix="$out" libdir="$out/lib/amd64" ILIBS=liblmdb.so
      mkdir -p "$out/lib/amd64/pkgconfig"
      printf 'Name: lmdb\nDescription: Lightning memory-mapped database\nVersion: 0.9.36\n\nCflags: -I%s/include\nLibs: -L%s/lib/amd64 -llmdb\n' "$out" "$out" > "$out/lib/amd64/pkgconfig/lmdb.pc"
      # a database in the build dir: put, commit, get, then mdb_stat reads it
      ${tprog ''#include <lmdb.h>
#include <stdio.h>
#include <string.h>
int main(int c, char **v){ MDB_env *e; MDB_txn *t; MDB_dbi d; MDB_val k = { 3, "key" }, x = { 6, "solnix" }, g;
if (mdb_env_create(&e) || mdb_env_open(e, v[1], 0, 0644) || mdb_txn_begin(e, NULL, 0, &t) || mdb_dbi_open(t, NULL, 0, &d)
 || mdb_put(t, d, &k, &x, 0) || mdb_txn_commit(t) || mdb_txn_begin(e, NULL, MDB_RDONLY, &t) || mdb_get(t, d, &k, &g)) return 1;
printf("ok %.*s %s\n", (int)g.mv_size, (char *)g.mv_data, mdb_version(NULL, NULL, NULL)); mdb_txn_abort(t); mdb_env_close(e); return 0; }'' "$out/lib/amd64/liblmdb.so"}
      mkdir "$W/db"
      ${chk ''"$W/t" "$W/db"'' "^ok solnix LMDB 0\\.9\\.36"}
      ${chk ''"$out/bin/mdb_stat" "$W/db"'' "Entries: 1$"}
    '';
  };

  # ---- recipes6 batch 14: protobuf, the media/codec headers and libraries, and small cmake libraries the queue's jobs wait on --------
  # zimg (WTFPL): scaling, colorspace conversion and dithering (ffmpeg's zscale, mpv, vapoursynth). Its tag tarball has no configure:
  # autoreconf (the store autotools, as nixpkgs' autoreconfHook).
  zimg = mkSrcPkg {
    pname = "zimg"; version = "3.0.6";
    src = { url = "https://codeload.github.com/sekrit-twc/zimg/tar.gz/refs/tags/release-3.0.6";
            sha256 = "be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      # -L gcc.lib: libtool found libstdc++.la in the compiler out and baked that libdir into libzimg as -R (closure gate, measured; as
      # libdb and gmp6). A plain .so found first adds no rpath.
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static LDFLAGS="-L$gccLib/amd64"
      gmake -j8; gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      # a flat grey 64x64 byte image scaled to 32x32 (bilinear) through a filter graph: every pixel stays 200
      ${tprog ''#include <zimg.h>
#include <stdio.h>
static unsigned char in[64 * 64] __attribute__((aligned(64))), out[32 * 32] __attribute__((aligned(64))), tmp[1 << 20] __attribute__((aligned(64)));
int main(void){ unsigned ma = 0, mi = 0; zimg_get_api_version(&ma, &mi); zimg_image_format s, d; zimg_image_format_default(&s, ZIMG_API_VERSION);
s.width = 64; s.height = 64; s.pixel_type = ZIMG_PIXEL_BYTE; s.color_family = ZIMG_COLOR_GREY; s.pixel_range = ZIMG_RANGE_FULL; s.depth = 8;
d = s; d.width = 32; d.height = 32; zimg_graph_builder_params p; zimg_graph_builder_params_default(&p, ZIMG_API_VERSION); p.resample_filter = ZIMG_RESIZE_BILINEAR;
zimg_filter_graph *g = zimg_filter_graph_build(&s, &d, &p); size_t t = 0; if (!g || zimg_filter_graph_get_tmp_size(g, &t) || t > sizeof tmp) return 1;
for (int i = 0; i < 64 * 64; i++) in[i] = 200;
zimg_image_buffer_const sb = { ZIMG_API_VERSION }; sb.plane[0].data = in; sb.plane[0].stride = 64; sb.plane[0].mask = ZIMG_BUFFER_MAX;
zimg_image_buffer db = { ZIMG_API_VERSION }; db.plane[0].data = out; db.plane[0].stride = 32; db.plane[0].mask = ZIMG_BUFFER_MAX;
if (zimg_filter_graph_process(g, &sb, &db, tmp, 0, 0, 0, 0)) return 2;
printf("ok %u.%u %d %d\n", ma, mi, out[0], out[32 * 32 - 1]); zimg_filter_graph_free(g); return 0; }'' "$out/lib/amd64/libzimg.so"}
      ${chk ''"$W/t"'' "^ok 2\\.4 200 200$"}
    '';
  };

  # minizip (Zlib): zlib's contrib/minizip (zip/unzip of .zip archives; qtwebengine, assimp). As nixpkgs: the zlib 1.3.2 tarball (base
  # zlib's own source), autoreconf in contrib/minizip, and upstream's fix that installs ints.h (ioapi.h includes it).
  minizip = mkSrcPkg {
    pname = "minizip"; version = "1.3.2";
    src = { url = "https://zlib.net/fossils/zlib-1.3.2.tar.gz";
            sha256 = "bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"; };
    deps = [ world zlib ]; nativeTools = autoreconfTools ++ [ gnupatch ] ++ hostTools;
    build = ''
      cd contrib/minizip
      patch -p3 < ${fetch "https://github.com/madler/zlib/commit/cb14dc9ade3759352417a300e6c2ed73268f1d97.patch" "0fdfd7ed5ce4825a66729853c72f2662b6c2e7be1df138d930a478ea772f7226"}
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j8; gmake install
      [ -f "$out/include/minizip/ints.h" ] || { echo "FATAL: minizip: ints.h not installed" >&2; exit 1; }
      # write a deflated member into a zip in the build dir, then find and read it back
      ${tprog ''#include <minizip/zip.h>
#include <minizip/unzip.h>
#include <stdio.h>
#include <string.h>
int main(int c, char **v){ const char *m = "solnix minizip"; char b[64] = { 0 }; zipFile z = zipOpen(v[1], APPEND_STATUS_CREATE); if (!z) return 1;
if (zipOpenNewFileInZip(z, "a.txt", NULL, NULL, 0, NULL, 0, NULL, Z_DEFLATED, 9) != ZIP_OK || zipWriteInFileInZip(z, m, strlen(m)) != ZIP_OK
 || zipCloseFileInZip(z) != ZIP_OK || zipClose(z, NULL) != ZIP_OK) return 2;
unzFile u = unzOpen(v[1]); if (!u || unzLocateFile(u, "a.txt", 0) != UNZ_OK || unzOpenCurrentFile(u) != UNZ_OK) return 3;
int n = unzReadCurrentFile(u, b, sizeof b - 1); unzCloseCurrentFile(u); unzClose(u); printf("ok %d %s\n", n, b); return 0; }'' "$out/lib/amd64/libminizip.so"}
      ${chk ''"$W/t" "$W/t.zip"'' "^ok 14 solnix minizip$"}
    '';
  };

  # libtheora (BSD-3-Clause): the Theora video codec on libogg (+ libvorbis, as nixpkgs propagates it). Tag tarball: autoreconf. Its
  # configure gives illumos ld no export list (GNU ld gets a version script, macOS an export list): every symbol is exported, upstream's
  # answer for any other linker.
  libtheora = mkSrcPkg {
    pname = "libtheora"; version = "1.2.0";
    src = { url = "https://codeload.github.com/xiph/theora/tar.gz/refs/tags/v1.2.0";
            sha256 = "e0c35771b425c32a052ffb358a2aed14219340ab850b48dc85b01939c0513a31"; };
    deps = [ world libogg libvorbis ]; nativeTools = autoreconfTools ++ [ base.pkgconf ] ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-examples --disable-doc --disable-spec
      gmake -j8; gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      # encode one flat 32x32 frame (headers + a key frame) in memory, decode it back: luma within the quantiser's reach of 120
      ${tprog ''#include <theora/theoraenc.h>
#include <theora/theoradec.h>
#include <stdio.h>
#include <string.h>
static unsigned char pk[4][65536], y[32 * 32], u[16 * 16], v[16 * 16]; static ogg_packet hp[3], fp;
static void keep(ogg_packet *d, const ogg_packet *s, unsigned char *b){ *d = *s; memcpy(b, s->packet, s->bytes); d->packet = b; }
int main(void){ th_info ti; th_info_init(&ti); ti.frame_width = ti.pic_width = 32; ti.frame_height = ti.pic_height = 32;
ti.fps_numerator = 25; ti.fps_denominator = 1; ti.aspect_numerator = ti.aspect_denominator = 1; ti.pixel_fmt = TH_PF_420; ti.quality = 48;
th_enc_ctx *e = th_encode_alloc(&ti); if (!e) return 1; th_comment tc; th_comment_init(&tc); ogg_packet op; int nh = 0;
while (nh < 3 && th_encode_flushheader(e, &tc, &op) > 0) { keep(&hp[nh], &op, pk[nh]); nh++; }
memset(y, 120, sizeof y); memset(u, 128, sizeof u); memset(v, 128, sizeof v);
th_ycbcr_buffer b = { { 32, 32, 32, y }, { 16, 16, 16, u }, { 16, 16, 16, v } };
if (th_encode_ycbcr_in(e, b) || th_encode_packetout(e, 1, &op) <= 0) return 2; keep(&fp, &op, pk[3]); th_encode_free(e);
th_info di; th_comment dc; th_setup_info *si = NULL; th_info_init(&di); th_comment_init(&dc);
for (int i = 0; i < nh; i++) if (th_decode_headerin(&di, &dc, &si, &hp[i]) < 0) return 3;
th_dec_ctx *d = th_decode_alloc(&di, si); th_setup_free(si); if (!d || th_decode_packetin(d, &fp, NULL)) return 4;
th_ycbcr_buffer o; th_decode_ycbcr_out(d, o); int p = o[0].data[0];
printf("ok %s %ux%u %d %d\n", th_version_string(), di.pic_width, di.pic_height, nh, p > 112 && p < 128); th_decode_free(d); return 0; }'' "$out/lib/amd64/libtheoraenc.so $out/lib/amd64/libtheoradec.so ${libogg}/lib/amd64/libogg.so -Wl,-R,${libogg}/lib/amd64"}
      ${chk ''"$W/t"'' "^ok Xiph\\.Org libtheora 1\\.2\\.0 [0-9]+ \\(Ptalarbvorm\\) 32x32 3 1$"}
    '';
  };

  # protobuf (BSD-3-Clause): Protocol Buffers (libprotobuf, libprotobuf-lite, libprotoc, libupb, protoc) on abseil-cpp and zlib, shared, as
  # nixpkgs (its tests off: no queued job runs them). Its version-script probe fails on illumos ld, so the libraries export everything
  # (as upstream's macOS build). upb's linker arrays need __start_/__stop_<section>, which illumos ld defines (protected), measured.
  # Built at the build's core count, not cmakeB's -j16: protobuf's translation units are large.
  protobuf = mkSrcPkg {
    pname = "protobuf"; version = "36.2";
    src = { url = "https://codeload.github.com/protocolbuffers/protobuf/tar.gz/refs/tags/v36.2";
            sha256 = "7e7eaf580ec77f1a392ff1ab1013c13d3b04a6716f002f697f67f3c1113f0530"; };
    deps = [ world zlib abseil-cpp ]; nativeTools = [ cmake base.pkgconf ] ++ hostTools;
    build = ''
      ${builtins.replaceStrings [ "cmake --build _b -j16" ] [ "cmake --build _b -j\${NIX_BUILD_CORES:-4}" ] (cmakeB "-Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=ON -Dprotobuf_ABSL_PROVIDER=package -Dabsl_DIR=${abseil-cpp}/lib/amd64/cmake/absl -DZLIB_ROOT=${zlib} -DZLIB_LIBRARY=${zlib}/lib/amd64/libz.so -DZLIB_INCLUDE_DIR=${zlib}/include")}
      ${chk ''"$out/bin/protoc" --version'' "^libprotoc 36\\.2$"}
      # protoc generates C++ for a message; that code, on the installed libprotobuf, serialises it and parses it back
      mkdir "$W/pb"; printf 'syntax = "proto3";\npackage t;\nmessage M { string s = 1; int32 n = 2; repeated int32 r = 3; }\n' > "$W/pb/t.proto"
      "$out/bin/protoc" -I"$W/pb" --cpp_out="$W/pb" "$W/pb/t.proto"
      cat > "$W/pb/m.cc" <<'TPROG'
#include "t.pb.h"
#include <iostream>
int main(){ t::M m; m.set_s("solnix"); m.set_n(42); m.add_r(7); std::string b; if (!m.SerializeToString(&b)) return 1;
t::M o; if (!o.ParseFromString(b)) return 2; std::cout << "ok " << o.s() << " " << o.n() << " " << o.r(0) << " " << b.size() << "\n"; }
TPROG
      "$CXX" -std=c++17 -I"$W/pb" "$W/pb/m.cc" "$W/pb/t.pb.cc" $(PKG_CONFIG_PATH="$out/lib/amd64/pkgconfig" pkg-config --cflags --libs protobuf) \
        -Wl,-R,"$out/lib/amd64:${abseil-cpp}/lib/amd64" -o "$W/pb/t"
      ${chk ''"$W/pb/t"'' "^ok solnix 42 7 13$"}
    '';
  };

  # libpciaccess (MIT): PCI device access for X.Org/Mesa/libdrm. meson; its Solaris backend is upstream (libdevinfo). The PCI ID database is
  # the world's hwdata (nixpkgs points -Dpci-ids at its store hwdata the same way), so names resolve without a host file.
  libpciaccess = mkSrcPkg {
    pname = "libpciaccess"; version = "0.19";
    src = { url = "https://www.x.org/releases/individual/lib/libpciaccess-0.19.tar.xz";
            sha256 = "3c55aa86c82e54a4e3109786f0463530d53b36b6d1cfd14616454f985dd2aa43"; };
    deps = [ world zlib ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild "-Dpci-ids=${world}/usr/share/hwdata -Dzlib=enabled"}
      # names from the ID database only (pci_system_init would read this host's devices)
      ${tprog ''#include <pciaccess.h>
#include <stdio.h>
int main(void){ struct pci_id_match m = { .vendor_id = 0x8086, .device_id = 0x1237, .subvendor_id = PCI_MATCH_ANY, .subdevice_id = PCI_MATCH_ANY };
const char *d = NULL, *v = NULL; pci_get_strings(&m, &d, &v, NULL, NULL); printf("ok %s | %s\n", v ? v : "-", d ? d : "-"); return 0; }'' "$out/lib/amd64/libpciaccess.so"}
      ${chk ''"$W/t"'' "^ok Intel Corporation \\| 440FX - 82441FX PMC \\[Natoma\\]$"}
    '';
  };

  # nv-codec-headers (MIT): FFmpeg's NVENC/NVDEC headers and dlopen loader (ffmpeg's nvenc/cuvid, loaded at run time), 9.x as the queue's
  # job. Its Makefile, PREFIX=$out (nixpkgs' layout, lib/pkgconfig). The GitHub mirror's tag, NAR-equal to nixpkgs' videolan git source.
  nv-codec-headers = mkSrcPkg {
    pname = "nv-codec-headers"; version = "9.1.23.1";
    src = { url = "https://codeload.github.com/FFmpeg/nv-codec-headers/tar.gz/refs/tags/n9.1.23.1";
            sha256 = "063f49838113c90504fd430377a6025478e2a454f812ce8a4da033e474727dc8"; };
    deps = [ world ]; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      gmake PREFIX="$out" install
      # the loader header compiles (no driver is loaded), and pkg-config sees the version
      ${tprog ''#include <ffnvcodec/dynlink_loader.h>
#include <stdio.h>
int main(void){ printf("ok %d.%d %d\n", NVENCAPI_MAJOR_VERSION, NVENCAPI_MINOR_VERSION, (int)(sizeof(CudaFunctions) > 0)); return 0; }'' ""}
      ${chk ''"$W/t"'' "^ok 9\\.1 1$"}
      ${chk ''PKG_CONFIG_PATH="$out/lib/pkgconfig" pkg-config --modversion ffnvcodec'' "^9\\.1\\.23\\.1$"}
    '';
  };

  # amf-headers (MIT): AMD's Advanced Media Framework headers (ffmpeg's amf encoders). The release's headers tarball: file for file equal
  # to the v1.5.3 tag's amf/public/include (all 57 files compared). nixpkgs' sparse-checkout source for "1.5.3" still has 1.5.2's content
  # (AMF_VERSION_RELEASE 2, 17 files differ): a stale hash in nixpkgs. Installed as nixpkgs does, include/AMF.
  amf-headers = mkSrcPkg {
    pname = "amf-headers"; version = "1.5.3";
    src = { url = "https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v1.5.3/AMF-headers-v1.5.3.tar.gz";
            sha256 = "0f521ad98041f8001147cded4a660127f18b1c27a801a5cd691bda1fa48381be"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      mkdir -p "$out/include/AMF"; cp -r AMF/. "$out/include/AMF/"
      ${tprog ''#include <AMF/core/Version.h>
#include <stdio.h>
int main(void){ printf("ok %d.%d.%d\n", (int)AMF_GET_MAJOR_VERSION(AMF_FULL_VERSION), (int)AMF_GET_MINOR_VERSION(AMF_FULL_VERSION), (int)AMF_GET_SUBMINOR_VERSION(AMF_FULL_VERSION)); return 0; }'' ""}
      ${chk ''"$W/t"'' "^ok 1\\.5\\.3$"}
    '';
  };

  # libaec (BSD-2-Clause): Adaptive Entropy Coding (CCSDS 121.0; libaec + the szip-compatible libsz) for HDF5/netCDF/GRIB. cmake, shared.
  libaec = mkSrcPkg {
    pname = "libaec"; version = "1.1.7";
    src = { url = "https://codeload.github.com/Deutsches-Klimarechenzentrum/libaec/tar.gz/refs/tags/v1.1.7";
            sha256 = "26661a569a7def45a2e97fbbd09e0dc5bbb2f8ab1b41250c19e795559eec6fb2"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DBUILD_TESTING=OFF"}
      # 1024 8-bit samples encoded (with preprocessing) and decoded back, byte for byte
      ${tprog ''#include <libaec.h>
#include <stdio.h>
#include <string.h>
static unsigned char in[1024], enc[4096], out[1024];
int main(void){ for (int i = 0; i < 1024; i++) in[i] = (i * 7) & 0xff;
struct aec_stream s; memset(&s, 0, sizeof s); s.bits_per_sample = 8; s.block_size = 16; s.rsi = 64; s.flags = AEC_DATA_PREPROCESS;
s.next_in = in; s.avail_in = sizeof in; s.next_out = enc; s.avail_out = sizeof enc; if (aec_buffer_encode(&s) != AEC_OK) return 1;
struct aec_stream r; memset(&r, 0, sizeof r); r.bits_per_sample = 8; r.block_size = 16; r.rsi = 64; r.flags = AEC_DATA_PREPROCESS;
r.next_in = enc; r.avail_in = s.total_out; r.next_out = out; r.avail_out = sizeof out; if (aec_buffer_decode(&r) != AEC_OK) return 2;
printf("ok %d %d\n", (int)r.total_out, memcmp(in, out, sizeof in) == 0); return 0; }'' "$out/lib/amd64/libaec.so"}
      ${chk ''"$W/t"'' "^ok 1024 1$"}
    '';
  };

  # cereal (BSD-3-Clause): header-only C++11 serialisation (binary, XML, JSON archives). cmake install only, as nixpkgs.
  cereal = mkSrcPkg {
    pname = "cereal"; version = "1.3.2";
    src = { url = "https://codeload.github.com/USCiLab/cereal/tar.gz/refs/tags/v1.3.2";
            sha256 = "16a7ad9b31ba5880dac55d62b5d6f243c3ebc8d46a3514149e56b5e7ea81f85f"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DJUST_INSTALL_CEREAL=ON"}
      # a struct through a JSON archive and back
      cat > "$W/t.cc" <<'TPROG'
#include <cereal/archives/json.hpp>
#include <cereal/types/vector.hpp>
#include <iostream>
#include <sstream>
struct P { int n; std::vector<int> v; template <class A> void serialize(A &a) { a(CEREAL_NVP(n), CEREAL_NVP(v)); } };
int main(){ std::stringstream ss; { cereal::JSONOutputArchive o(ss); P p{42, {1, 2}}; o(cereal::make_nvp("p", p)); }
P q{}; { cereal::JSONInputArchive i(ss); i(cereal::make_nvp("p", q)); } std::cout << "ok " << q.n << " " << q.v.size() << "\n"; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 42 2$"}
    '';
  };

  # llhttp (MIT): Node.js's HTTP parser as a C library (aiohttp, libgit2). cmake, shared, as nixpkgs.
  llhttp = mkSrcPkg {
    pname = "llhttp"; version = "9.4.3";
    src = { url = "https://codeload.github.com/nodejs/llhttp/tar.gz/refs/tags/release/v9.4.3";
            sha256 = "1eb813c7437b31a87496a1cd3ed79f00746720f5e7e29c79b42c02cb69f36c39"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DLLHTTP_BUILD_SHARED_LIBS=ON -DLLHTTP_BUILD_STATIC_LIBS=OFF"}
      ${tprog ''#include <llhttp.h>
#include <stdio.h>
#include <string.h>
static char url[64];
static int on_url(llhttp_t *p, const char *at, size_t n){ (void)p; strncat(url, at, n); return 0; }
int main(void){ llhttp_t p; llhttp_settings_t s; llhttp_settings_init(&s); s.on_url = on_url; llhttp_init(&p, HTTP_REQUEST, &s);
const char *r = "GET /solnix HTTP/1.1\r\nHost: a\r\n\r\n"; int e = llhttp_execute(&p, r, strlen(r));
printf("ok %d %s %s %d.%d\n", e, url, llhttp_method_name(llhttp_get_method(&p)), llhttp_get_http_major(&p), llhttp_get_http_minor(&p)); return 0; }'' "$out/lib/amd64/libllhttp.so"}
      ${chk ''"$W/t"'' "^ok 0 /solnix GET 1\\.1$"}
    '';
  };

  # capstone (BSD-3-Clause): the multi-architecture disassembly engine and cstool. cmake, shared, as nixpkgs (its tests off).
  capstone = mkSrcPkg {
    pname = "capstone"; version = "5.0.9";
    src = { url = "https://codeload.github.com/capstone-engine/capstone/tar.gz/refs/tags/5.0.9";
            sha256 = "0619da31af08152600af95c481527ef6d756c0a8404fca7544a4fdf6dfc2c0f9"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      # cstool's own getopt declares `const char *optarg`; illumos' <stdlib.h> and <stdio.h> declare `char *optarg` (glibc only in
      # <unistd.h>, which cstool does not include): the libc's type
      [ "$(grep -c '^extern const char \*optarg;' cstool/getopt.h)" = 1 ] && [ "$(grep -c '^const char \*optarg;' cstool/getopt.c)" = 1 ] \
        || { echo "FATAL: capstone optarg anchors" >&2; exit 1; }
      sed -i 's/^extern const char \*optarg;/extern char *optarg;/' cstool/getopt.h; sed -i 's/^const char \*optarg;/char *optarg;/' cstool/getopt.c
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DCAPSTONE_BUILD_TESTS=OFF"}
      ${chk ''"$out/bin/cstool" x64 554889e5'' "push[[:space:]]+rbp"}
      # the shared library itself: x86-64 bytes to mnemonics
      ${tprog ''#include <capstone/capstone.h>
#include <stdio.h>
int main(void){ csh h; cs_insn *i; static const unsigned char c[] = { 0x55, 0x48, 0x89, 0xe5, 0xc3 }; int ma, mi; cs_version(&ma, &mi);
if (cs_open(CS_ARCH_X86, CS_MODE_64, &h) != CS_ERR_OK) return 1; size_t n = cs_disasm(h, c, sizeof c, 0x1000, 0, &i); if (n < 2) return 2;
printf("ok %d.%d %zu %s %s %s\n", ma, mi, n, i[0].mnemonic, i[1].mnemonic, i[1].op_str); cs_free(i, n); cs_close(&h); return 0; }'' "$out/lib/amd64/libcapstone.so"}
      ${chk ''"$W/t"'' "^ok 5\\.0 3 push mov rbp, rsp$"}
    '';
  };
}
