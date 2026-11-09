# cli/c-recipes4.nix -- tools and libraries the x86 build queue has jobs for and solnix lacked (recipes4, 2026-11-09), picked by how many
# queued jobs each moves to buildable. A new file, so no served drv moves. Store-only builds (nativeTools), each with an in-build check
# that runs it on real input. Versions are the queue's targets; sources pinned by sha256 (equal to nixpkgs' flat hash where it has one).
{ base, mkSrcPkg, world, chk, hostTools, python3, gnupatch, gnum4, bzip2-bin, libxau, libxdmcp, libpthread-stubs, gtkMeson ? null, graphics, ... }:
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
}
