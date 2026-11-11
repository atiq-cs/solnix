# cli/c-recipes4.nix -- tools and libraries the x86 build queue has jobs for and solnix lacked (recipes4, 2026-11-09), picked by how many
# queued jobs each moves to buildable. A new file, so no served drv moves. Store-only builds (nativeTools), each with an in-build check
# that runs it on real input. Versions are the queue's targets; sources pinned by sha256 (equal to nixpkgs' flat hash where it has one).
{ base, mkSrcPkg, world, chk, scrub, check, hostTools, autoreconfTools, autoreconf, python3, gnupatch, gnum4, cmake, perl, tcl, vulkan-headers, libogg, libuv, fmt, bzip2-bin, libxau, libxdmcp, libpthread-stubs, utf8cpp, libdeflate, tzdata, gtkMeson ? null, graphics, ... }:
let
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  # a file of nixpkgs f4a03c0's pkgs/by-name (a package's own patch), by its sha256
  npPatch = p: sha256: fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/${p}" sha256;
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
  # A cmake find_package on main misses every dep: mk-src-pkg's env CMAKE_PREFIX_PATH is ';'-joined (cmake splits it on ':' on Unix:
  # one bogus dir), and 64-bit libs are in <dep>/lib/amd64, a suffix cmake never tries. What found OpenSSL for aws-c-cal on lixi
  # was the build host's /bin/pkg-config, through cmake's system prefix "/" (cmakeB ignores /usr;/usr/local;/opt only): woof has
  # none, so the same drv failed there (floki /scratch/solnix/recipes8/AWS-C-CAL-DIAGNOSIS.md). wave6 3d0006e's solnix-cmake.cmake
  # fixes all three for every cmake build; until it reaches main, a recipe that looks a package up passes the same answer.
  storePrefix = ''-DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH" -DCMAKE_LIBRARY_ARCHITECTURE=amd64 -DCMAKE_IGNORE_PREFIX_PATH="/;/usr;/usr/local;/opt"'';
  # nasm names each object's STT_FILE symbol after its input path as given (no prefix map), and cmake hands it absolute sources, so
  # a library's .SUNW_ldynsym named the build dir (gate B8): desktop/gtk/base.nix libjpeg-turbo's wrapper, which passes nasm the
  # path relative to its cwd. A recipe runs ${nasmRel} and names "$W/nasm" as its assembler.
  nasmRel = ''
    printf '%s\n' '#!/usr/bin/bash' \
      'rel() { local d=$PWD up=; while [ "''${1#"$d"/}" = "$1" ]; do d=''${d%/*}; up=../$up; done; printf %s "$up''${1#"$d"/}"; }' \
      "a=(); for x in \"\$@\"; do case \"\$x\" in $SRC/*) x=\$(rel \"\$x\");; esac; a+=(\"\$x\"); done" \
      'exec ${nasm}/bin/nasm "''${a[@]}"' > "$W/nasm"
    chmod +x "$W/nasm"
  '';
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
    pname = "dav1d"; version = "1.5.4";
    src = { url = "https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz";
            sha256 = "686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"; };
    deps = [ world ]; nativeTools = [ nasm ] ++ mesonTools;
    build = ''
      # -std=c99 hides clock_gettime in illumos' <time.h>; __EXTENSIONS__ shows it (as the graphics recipes build)
      ${mesonBuild "-Denable_tools=false -Denable_examples=false -Denable_tests=false -Denable_asm=true -Dc_args=-D__EXTENSIONS__"}
      grep -q '^#define HAVE_ASM 1$' _b/config.h || { echo "FATAL: dav1d built without its asm" >&2; exit 1; }
      ${tprog ''#include <dav1d/dav1d.h>
#include <stdio.h>
int main(void){ Dav1dSettings s; Dav1dContext *c; dav1d_default_settings(&s); s.n_threads = 1; if(dav1d_open(&c, &s)) return 1;
printf("dav1d %s\n", dav1d_version()); dav1d_close(&c); return 0; }'' "-ldav1d"}
      ${chk ''"$W/t"'' "^dav1d 1\\.5\\.4"}
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
  libxtst = xlib "libxtst" "1.2.6" "lib/libXtst-1.2.6.tar.xz" "f94f0b37c07d80d877f3eda2c2405cc7e62aa9842f6310354aa349e3d66a4fe5"
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
  # tkConfig.sh names the build dir in TK_SRC_DIR/TK_BUILD_* as every tkConfig.sh does (NixOS's: /build/tk8.6.16); here that was the
  # drv-keyed /var/tmp/srcpkg-<key>, which the gate now FAILs (B8, a recorded mk-src-pkg dir): mapped to /build, as tcl's.
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
      sed "s|$W/|/build/|g" "$out/lib/amd64/tkConfig.sh" > "$W/cfg" && cat "$W/cfg" > "$out/lib/amd64/tkConfig.sh"
      if grep -rlF "$W" "$out"; then echo "FATAL: tk names its build dir" >&2; exit 1; fi
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
      # FALLBACK_DATA_DIRS (read only when XDG_DATA_DIRS is unset): the system profile's share, not upstream's /usr/local/share, which
      # host-path-scan refuses in a store-only CMakeCache (wave7's stdenv)
      ${cmakeB "-DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE -DFALLBACK_DATA_DIRS=/run/current-system/sw/share:/usr/share -DCMAKE_C_FLAGS=-D__EXTENSIONS__ -DCMAKE_INSTALL_INCLUDEDIR=${vulkan-headers}/include -DBUILD_WSI_XCB_SUPPORT=ON -DBUILD_WSI_XLIB_SUPPORT=ON -DBUILD_WSI_WAYLAND_SUPPORT=ON -DBUILD_TESTS=OFF -DVULKAN_HEADERS_INSTALL_DIR=${vulkan-headers}"}
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

  # vulkan-tools (Apache-2.0): vulkaninfo, vkcube and vkcubepp (Khronos Vulkan-Tools) on the loader above, X11 (xcb, Xlib), Wayland and
  # display (VK_KHR_display) WSI, as nixpkgs: the mock ICD is not installed, and vulkaninfo/vkcube dlopen libvulkan.so.1 (and vkcube
  # libxcb/libX11/libwayland-client) by name, which their store RUNPATH resolves. Upstream has no illumos case; the port:
  # - cube/, vulkaninfo/, icd/ CMakeLists.txt: SunOS joins the "Linux|BSD|GNU" platform case (7 spots: the WSI options, the targets);
  # - cube.c, cube.cpp: __sun joins the Linux/BSD main() arm;
  # - cube.c, cube.cpp include <linux/input.h> for five Wayland key and button codes (KEY_ESC/LEFT/RIGHT/SPACE, BTN_LEFT): the BSD-2
  #   FreeBSD evdev input-event-codes.h solnix already ships (src/ports/touchpad/evdev, input-stack's libevdev), the same Linux evdev
  #   numbers wl_keyboard and wl_pointer carry.
  # The loader's -std=c99 note applies (clock_gettime, strtok_r): -D__EXTENSIONS__. The cube shaders ship as SPIR-V (cube.*.inc,
  # COMPILE_CUBE_SHADERS off), so no glslang. nixpkgs' wayland-scanner patch is not needed: one wayland out has both .pc files.
  vulkan-tools = let evdev = builtins.path { path = ../../../src/ports/touchpad/evdev; name = "solnix-evdev-headers"; }; in mkSrcPkg {
    pname = "vulkan-tools"; version = "1.4.363.0";
    src = { url = "https://codeload.github.com/KhronosGroup/Vulkan-Tools/tar.gz/refs/tags/vulkan-sdk-1.4.363.0";
            sha256 = "6cbeb83294434e636a0c78760f1a6dfe3e50c1bab0cffa154603ce73e70508f1"; };
    deps = [ world vulkan-loader libx11 libxcb graphics.wayland ];
    linkDeps = [ vulkan-headers graphics.wayland-protocols base.xorgproto libxau libxdmcp libpthread-stubs graphics.libffi libxrandr libxrender libxext ];   # Xrandr: the mock ICD (build check only) has XLIB_XRANDR_EXT
    nativeTools = [ cmake base.pkgconf ] ++ hostTools;
    build = ''
      [ "$(cat cube/CMakeLists.txt vulkaninfo/CMakeLists.txt icd/CMakeLists.txt | grep -c 'CMAKE_SYSTEM_NAME MATCHES "Linux|BSD|GNU")')" = 7 ] || { echo "FATAL: vulkan-tools platform anchors" >&2; exit 1; }
      sed -i 's/CMAKE_SYSTEM_NAME MATCHES "Linux|BSD|GNU")/CMAKE_SYSTEM_NAME MATCHES "Linux|BSD|GNU|SunOS")/' cube/CMakeLists.txt vulkaninfo/CMakeLists.txt icd/CMakeLists.txt
      for f in cube/cube.c cube/cube.cpp; do
        grep -q '^#elif defined(__linux__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__QNX__) || defined(__GNU__)' $f || { echo "FATAL: vulkan-tools $f main anchor" >&2; exit 1; }
        sed -i 's/^#elif defined(__linux__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__QNX__) || defined(__GNU__)/#elif defined(__sun) || defined(__linux__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__QNX__) || defined(__GNU__)/' $f
        [ "$(grep -c '^#include <linux/input.h>$' $f)" = 1 ] || { echo "FATAL: vulkan-tools $f input.h anchor" >&2; exit 1; }
        sed -i 's|^#include <linux/input.h>$|#include "input-event-codes.h"|' $f
      done
      cp ${evdev}/input-event-codes.h cube/
      ${cmakeB "-DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE -DCMAKE_C_FLAGS=-D__EXTENSIONS__ -DCMAKE_CXX_FLAGS=-D__EXTENSIONS__ -DVulkanHeaders_DIR=${vulkan-headers}/share/cmake/VulkanHeaders -DBUILD_WSI_XCB_SUPPORT=ON -DBUILD_WSI_XLIB_SUPPORT=ON -DBUILD_WSI_WAYLAND_SUPPORT=ON -DBUILD_WSI_DISPLAY_SUPPORT=ON -DBUILD_ICD=ON -DINSTALL_ICD=OFF -DBUILD_TESTS=OFF"}
      for b in vulkaninfo vkcube vkcubepp; do [ -x "$out/bin/$b" ] || { echo "FATAL: no $b" >&2; exit 1; }; done
      [ ! -e "$out/share/vulkan" ] || { echo "FATAL: the mock ICD was installed" >&2; exit 1; }
      /usr/bin/elfdump -d "$out/bin/vkcube" | grep -q "RUNPATH.*${vulkan-loader}/lib/amd64" || { echo "FATAL: vkcube RUNPATH lacks the loader" >&2; exit 1; }
      # no GPU here: the loader (found through vulkaninfo's RUNPATH, no LD_LIBRARY_PATH) drives the build tree's mock ICD; with no ICD,
      # vulkaninfo must fail (negative control: the device line comes from the ICD, not from vulkaninfo)
      E="XDG_CONFIG_HOME=$W XDG_DATA_HOME=$W XDG_DATA_DIRS=$W HOME=$W"
      ${chk ''env $E VK_DRIVER_FILES="$PWD/_b/icd/VkICD_mock_icd.json" "$out/bin/vulkaninfo" --summary | grep deviceName'' "deviceName += Vulkan Mock Device$"}
      ${chk ''env $E VK_DRIVER_FILES="$W/none.json" "$out/bin/vulkaninfo" --summary'' "ERROR_INCOMPATIBLE_DRIVER"}
      # vkcube on the display WSI (VK_KHR_display, no window system): 3 frames through the mock ICD's swapchain
      ${chk ''env $E VK_DRIVER_FILES="$PWD/_b/icd/VkICD_mock_icd.json" "$out/bin/vkcube" --wsi display --c 3 2>&1; echo "rc=$?"'' "Selected GPU 0: Vulkan Mock Device"}
      ${chk ''"$out/bin/vkcube" --solnix-usage'' "wsi <xcb.xlib.wayland.display>"}
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
  # -z now on its libraries: lazily bound, a gcc 15 consumer deadlocked at start. During libprotobuf's .init (AddDescriptors holds
  # DescriptorPool's mutex), libstdc++'s first call to std::string::_M_create binds to the consumer's own WEAK copy of it, so
  # ld.so.1 runs the consumer's .init early; its static descriptors re-enter the same mutex. Measured (wave7b, this recipe's own
  # check program): lazy 4/4 hang, libprotobuf marked NOW 4/4 ok; the same program linked by gcc 14 exports 18 such copies, not 47.
  protobuf = mkSrcPkg {
    pname = "protobuf"; version = "36.2";
    src = { url = "https://codeload.github.com/protocolbuffers/protobuf/tar.gz/refs/tags/v36.2";
            sha256 = "7e7eaf580ec77f1a392ff1ab1013c13d3b04a6716f002f697f67f3c1113f0530"; };
    deps = [ world zlib abseil-cpp ]; nativeTools = [ cmake base.pkgconf ] ++ hostTools;
    build = ''
      ${builtins.replaceStrings [ "cmake --build _b -j16" ] [ "cmake --build _b -j\${NIX_BUILD_CORES:-4}" ] (cmakeB "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,now -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=ON -Dprotobuf_ABSL_PROVIDER=package -Dabsl_DIR=${abseil-cpp}/lib/amd64/cmake/absl -DZLIB_ROOT=${zlib} -DZLIB_LIBRARY=${zlib}/lib/amd64/libz.so -DZLIB_INCLUDE_DIR=${zlib}/include")}
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

  # ---- recipes7 batch 15: small libraries and tools the queue's jobs wait on ----------------------------------------------------
  # libxcb-cursor (X11): the XCB port of libXcursor's theme loading (Qt's xcb platform, Xwayland compositors), on the xcb-util libs.
  libxcb-cursor = xlib "libxcb-cursor" "0.1.6" "lib/xcb-util-cursor-0.1.6.tar.xz" "fdeb8bd127873519be5cc70dcd0d3b5d33b667877200f9925a59fdcad8f7a933"
    [ libxcb libxcb-util libxcb-image libxcb-render-util ] (xcbT "#include <xcb/xcb_cursor.h>" "(void)xcb_cursor_context_new") "-lxcb-cursor -lxcb";

  # imath (BSD-3-Clause): OpenEXR's half type and vector/matrix math. cmake, shared, as nixpkgs (tests off).
  imath = mkSrcPkg {
    pname = "imath"; version = "3.2.3";
    src = { url = "https://codeload.github.com/AcademySoftwareFoundation/imath/tar.gz/refs/tags/v3.2.3";
            sha256 = "e10c12b3f21f45bf08e09d4215d9c7691368d747beebd840de0b6fefed2df9f8"; };
    deps = [ world ]; nativeTools = [ cmake base.pkgconf ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF"}
      cat > "$W/t.cc" <<'TPROG'
#include <ImathConfig.h>
#include <ImathVec.h>
#include <half.h>
#include <cstdio>
int main(){ Imath::V3f a(1, 2, 3), b(4, 5, 6); half h(0.333333f);
std::printf("ok %s %g %g %g\n", IMATH_VERSION_STRING, a.dot(b), (float)h, a.cross(b).length2()); }
TPROG
      "$CXX" -std=c++17 "$W/t.cc" $(PKG_CONFIG_PATH="$out/lib/amd64/pkgconfig" pkg-config --cflags --libs Imath) -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 3\\.2\\.3 32 0\\.3332[0-9]* 54$"}
    '';
  };

  # qhull (Qhull): convex hulls, Delaunay triangulations and Voronoi diagrams (libqhull_r and the q* programs). cmake; as nixpkgs,
  # upstream's CMake 4 minimum-version fix.
  qhull = mkSrcPkg {
    pname = "qhull"; version = "2020.2";
    src = { url = "https://codeload.github.com/qhull/qhull/tar.gz/refs/tags/2020.2";
            sha256 = "59356b229b768e6e2b09a701448bfa222c37b797a84f87f864f97462d8dbc7c5"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      grep -qx 'cmake_minimum_required(VERSION 3.0)' CMakeLists.txt || { echo "FATAL: qhull cmake_minimum anchor" >&2; exit 1; }
      sed -i 's/^cmake_minimum_required(VERSION 3.0)$/cmake_minimum_required(VERSION 3.5...4.0)/' CMakeLists.txt
      ${cmakeB "-DLIB_INSTALL_DIR=lib/amd64"}
      find "$out/share/doc" -delete 2>/dev/null || true
      # the corners of a cube: 8 points, 6 facets
      ${chk ''"$out/bin/rbox" c D3 | "$out/bin/qconvex" s'' "Convex hull of 8 points in 3-d"}
      ${chk ''"$out/bin/rbox" c D3 | "$out/bin/qconvex" s'' "Number of facets: 6$"}
    '';
  };

  # zopfli (Apache-2.0): Google's slow, dense deflate/zlib/gzip compressor (libzopfli, libzopflipng and the programs). cmake, shared;
  # as nixpkgs: the CMake 4 minimum version, and all of src/zopfli's headers installed.
  zopfli = mkSrcPkg {
    pname = "zopfli"; version = "1.0.3";
    src = { url = "https://codeload.github.com/google/zopfli/tar.gz/refs/tags/zopfli-1.0.3";
            sha256 = "e955a7739f71af37ef3349c4fa141c648e8775bceb2195be07e86f8e638814bd"; };
    deps = [ world ]; linkDeps = [ zlib ]; nativeTools = [ cmake ] ++ hostTools;   # zlib: the check's inflate only
    build = ''
      grep -qx 'cmake_minimum_required(VERSION 2.8.11)' CMakeLists.txt || { echo "FATAL: zopfli cmake_minimum anchor" >&2; exit 1; }
      sed -i 's/^cmake_minimum_required(VERSION 2.8.11)$/cmake_minimum_required(VERSION 3.10)/' CMakeLists.txt
      ${cmakeB "-DBUILD_SHARED_LIBS=ON"}
      cp src/zopfli/*.h "$out/include/"
      printf 'solnix solnix solnix solnix\n' > "$W/in"
      ${chk ''"$out/bin/zopfli" -c "$W/in" | od -An -tx1 -N3'' "1f 8b 08"}
      # zlib format through the library, inflated back by zlib
      ${tprog ''#include <zopfli.h>
#include <zlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void){ static unsigned char in[4096], out[4096]; for (int i = 0; i < 4096; i++) in[i] = "solnix "[i % 7];
ZopfliOptions o; ZopfliInitOptions(&o); unsigned char *z = NULL; size_t zn = 0; ZopfliCompress(&o, ZOPFLI_FORMAT_ZLIB, in, sizeof in, &z, &zn);
uLongf on = sizeof out; int r = uncompress(out, &on, z, zn);
printf("ok %d %d %d\n", r == Z_OK, (int)on, memcmp(in, out, sizeof in) == 0 && zn < 100); free(z); return 0; }'' "$out/lib/amd64/libzopfli.so ${zlib}/lib/amd64/libz.so -Wl,-R,${zlib}/lib/amd64"}
      ${chk ''"$W/t"'' "^ok 1 4096 1$"}
    '';
  };

  # utf8proc (MIT): Unicode normalisation, case folding and character widths (tmux, Julia, arrow). cmake, shared (its tests download
  # the Unicode data files at configure time, so they stay off).
  utf8proc = mkSrcPkg {
    pname = "utf8proc"; version = "2.12.0";
    src = { url = "https://codeload.github.com/JuliaStrings/utf8proc/tar.gz/refs/tags/v2.12.0";
            sha256 = "f564011d38b2888d583d510b08e69ffa15aa117155db1b9b49ef1dfe1fa25111"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DUTF8PROC_ENABLE_TESTING=OFF"}
      # e + COMBINING ACUTE composes to U+00E9; a CJK ideograph is two columns wide
      ${tprog ''#include <utf8proc.h>
#include <stdio.h>
#include <stdlib.h>
int main(void){ utf8proc_uint8_t *n = utf8proc_NFC((const utf8proc_uint8_t *)"e\xcc\x81"); if (!n) return 1;
printf("ok %s %02x%02x %d %d\n", utf8proc_version(), n[0], n[1], (int)n[2], utf8proc_charwidth(0x4e2d)); free(n); return 0; }'' "$out/lib/amd64/libutf8proc.so"}
      ${chk ''"$W/t"'' "^ok 2\\.12\\.0 c3a9 0 2$"}
    '';
  };

  # libmodplug (public domain): the ModPlug tracker-module renderer (MOD/S3M/XM/IT; gstreamer, ffmpeg's libmodplug demuxer).
  # autotools; as nixpkgs: the `register` storage class out of fastmix.cpp (C++17, gcc's default, rejects it).
  libmodplug = mkSrcPkg {
    pname = "libmodplug"; version = "0.8.9.0";
    src = { url = "https://downloads.sourceforge.net/project/modplug-xmms/libmodplug/0.8.9.0/libmodplug-0.8.9.0.tar.gz";
            sha256 = "457ca5a6c179656d66c01505c0d95fafaead4329b9dbaa0f997d00a3508ad9de"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      [ "$(grep -c 'register ' src/fastmix.cpp)" = 2 ] || { echo "FATAL: libmodplug register anchor" >&2; exit 1; }
      sed -i 's/register //g' src/fastmix.cpp
      # -L gcc.lib: a C++ library through libtool, which otherwise bakes libstdc++.la's dir in as -R (zimg's closure-gate failure)
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static LDFLAGS="-L$gccLib/amd64"
      gmake -j8; gmake install
      # a 4-channel ProTracker module built in memory (title, one 32-byte sample, one empty pattern) loads and renders; the loader
      # refuses a module with no sample data (measured)
      ${tprog ''#include <libmodplug/modplug.h>
#include <stdio.h>
#include <string.h>
static unsigned char m[1084 + 1024 + 32]; static char b[4096];
int main(void){ memcpy(m, "solnix", 6); m[43] = 16; m[45] = 64; m[950] = 1; m[951] = 127; memcpy(m + 1080, "M.K.", 4);
for (int i = 0; i < 32; i++) m[1084 + 1024 + i] = (unsigned char)(i * 8);
ModPlugFile *f = ModPlug_Load(m, sizeof m); if (!f) return 1; int n = ModPlug_Read(f, b, sizeof b);
printf("ok %s %u %d\n", ModPlug_GetName(f), ModPlug_NumPatterns(f), n > 0); ModPlug_Unload(f); return 0; }'' "$out/lib/amd64/libmodplug.so"}
      ${chk ''"$W/t"'' "^ok solnix 1 1$"}
    '';
  };

  # libmaxminddb (Apache-2.0): the MaxMind DB (GeoIP2 .mmdb) reader library and mmdblookup. autotools, as nixpkgs.
  libmaxminddb = mkSrcPkg {
    pname = "libmaxminddb"; version = "1.13.3";
    src = { url = "https://github.com/maxmind/libmaxminddb/releases/download/1.13.3/libmaxminddb-1.13.3.tar.gz";
            sha256 = "a66502ea76eadbe17f2cd6fd708946777253972d2ae8157dee1b23a2fb528171"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-tests
      gmake -j8; gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      # upstream's GeoIP2 test database (in the tarball): an address it lists, through the tool and through the library
      D=t/maxmind-db/test-data/GeoIP2-City-Test.mmdb
      ${chk ''"$out/bin/mmdblookup" --file "$D" --ip 81.2.69.160 country iso_code'' "\"GB\" <utf8_string>"}
      ${tprog ''#include <maxminddb.h>
#include <stdio.h>
int main(int c, char **v){ MMDB_s db; int ge = 0, me = 0; if (c < 2 || MMDB_open(v[1], MMDB_MODE_MMAP, &db) != MMDB_SUCCESS) return 1;
MMDB_lookup_result_s r = MMDB_lookup_string(&db, "81.2.69.160", &ge, &me); if (ge || me != MMDB_SUCCESS || !r.found_entry) return 2;
MMDB_entry_data_s d; if (MMDB_get_value(&r.entry, &d, "country", "iso_code", NULL) != MMDB_SUCCESS || !d.has_data) return 3;
printf("ok %s %.*s\n", MMDB_lib_version(), (int)d.data_size, d.utf8_string); MMDB_close(&db); return 0; }'' "$out/lib/amd64/libmaxminddb.so"}
      ${chk ''"$W/t" "$D"'' "^ok 1\\.13\\.3 GB$"}
    '';
  };

  # gsm (TU-Berlin, BSD-2-Clause-like): the GSM 06.10 full-rate speech codec (libgsm, toast; sox, ffmpeg). Its plain Makefile; as
  # nixpkgs: headers in include/gsm, a shared libgsm.so (soname libgsm.so) in place of the archive, built serially. Here also: -fPIC
  # (nixpkgs' cc wrapper adds it), and the install rules' inner `make` is the build's GNU make (illumos make is not GNU make).
  gsm = mkSrcPkg {
    pname = "gsm"; version = "1.0.24";
    src = { url = "https://www.quut.com/gsm/gsm-1.0.24.tar.gz";
            sha256 = "a3c40c6471928383f4abfcb2e8f24012a1f562be2f17b8d672145d5986681a92"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      grep -qF '$(AR) $(ARFLAGS) $(LIBGSM) $(GSM_OBJECTS)' Makefile && grep -qF '$(RANLIB) $(LIBGSM)' Makefile \
        && [ "$(grep -cE '^[[:space:]]+make \$\(' Makefile)" = 2 ] || { echo "FATAL: gsm Makefile anchors" >&2; exit 1; }
      sed -i -e 's,libgsm\.a,libgsm.so,g' \
        -e 's/\$(AR) \$(ARFLAGS) \$(LIBGSM) \$(GSM_OBJECTS)/$(LD) -shared -Wl,-h,libgsm.so -o $(LIBGSM) $(GSM_OBJECTS) -lc/' \
        -e '/\$(RANLIB) \$(LIBGSM)/d' -e 's/^\([[:space:]]*\)make \$(/\1$(MAKE) $(/' Makefile
      mkdir -p "$out/bin" "$out/lib/amd64" "$out/include/gsm" "$out/share/man/man1" "$out/share/man/man3"
      set -- SHELL="$BASH" CC="$CC" CCFLAGS="-c -O2 -fPIC -DNeedFunctionPrototypes=1 -Wall -Wno-comment" INSTALL_ROOT="$out" \
        GSM_INSTALL_LIB="$out/lib/amd64" GSM_INSTALL_INC="$out/include/gsm" GSM_INSTALL_MAN="$out/share/man/man3" TOAST_INSTALL_MAN="$out/share/man/man1"
      gmake "$@"; gmake "$@" install
      [ -x "$out/bin/toast" ] && [ -f "$out/lib/amd64/libgsm.so" ] || { echo "FATAL: gsm install" >&2; exit 1; }
      # one 20 ms frame of a tone encoded to its 33 bytes and decoded back
      ${tprog ''#include <gsm/gsm.h>
#include <stdio.h>
#include <math.h>
int main(void){ gsm g = gsm_create(); gsm_signal s[160], o[160]; gsm_frame f; if (!g) return 1;
for (int i = 0; i < 160; i++) s[i] = (gsm_signal)(8000 * sin(i * 0.2));
gsm_encode(g, s, f); gsm_destroy(g); g = gsm_create(); if (!g || gsm_decode(g, f, o)) return 2; gsm_destroy(g);
printf("ok %d %d.%d.%d\n", (int)sizeof(gsm_frame), GSM_MAJOR, GSM_MINOR, GSM_PATCHLEVEL); return 0; }'' "$out/lib/amd64/libgsm.so -lm"}
      ${chk ''"$W/t"'' "^ok 33 1\\.0\\.24$"}
    '';
  };

  # inih (BSD-3-Clause): the small .INI parser (libinih, libINIReader). meson, as nixpkgs.
  inih = mkSrcPkg {
    pname = "inih"; version = "62";
    src = { url = "https://codeload.github.com/benhoyt/inih/tar.gz/refs/tags/r62";
            sha256 = "9c15fa751bb8093d042dae1b9f125eb45198c32c6704cd5481ccde460d4f8151"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild ""}
      ${tprog ''#include <ini.h>
#include <stdio.h>
#include <string.h>
static int h(void *u, const char *s, const char *n, const char *v){ if (!strcmp(s, "a") && !strcmp(n, "k")) snprintf((char *)u, 32, "%s", v); return 1; }
int main(void){ char got[32] = ""; int r = ini_parse_string("[a]\nk = solnix ; note\n[b]\nk=x\n", h, got); printf("ok %d %s\n", r, got); return 0; }'' "$out/lib/amd64/libinih.so"}
      ${chk ''"$W/t"'' "^ok 0 solnix$"}
    '';
  };

  # hiredis (BSD-3-Clause): the Redis client library, with TLS (libhiredis_ssl), as nixpkgs (USE_SSL=1). Its Makefile has the SunOS
  # case upstream (-h soname, -lsocket -lnsl).
  hiredis = mkSrcPkg {
    pname = "hiredis"; version = "1.5.0";
    src = { url = "https://codeload.github.com/redis/hiredis/tar.gz/refs/tags/v1.5.0";
            sha256 = "eec7ef8641d221e144a58d5ef8d733c8c75c7fd487097a233aacb4fa33981cfb"; };
    deps = [ world base.openssl ]; nativeTools = hostTools;
    build = ''
      gmake -j8 USE_SSL=1 PREFIX="$out" LIBRARY_PATH=lib/amd64
      gmake USE_SSL=1 PREFIX="$out" LIBRARY_PATH=lib/amd64 install
      # a RESP array parsed by the reader (no server), and OpenSSL initialised through libhiredis_ssl
      ${tprog ''#include <hiredis/hiredis.h>
#include <hiredis/hiredis_ssl.h>
#include <stdio.h>
#include <string.h>
int main(void){ redisReader *r = redisReaderCreate(); void *rep = NULL; const char *m = "*2\r\n+solnix\r\n:42\r\n";
if (!r || redisReaderFeed(r, m, strlen(m)) != REDIS_OK || redisReaderGetReply(r, &rep) != REDIS_OK || !rep) return 1; redisReply *x = rep;
printf("ok %d.%d.%d %d %s %lld %d\n", HIREDIS_MAJOR, HIREDIS_MINOR, HIREDIS_PATCH, (int)x->elements, x->element[0]->str, x->element[1]->integer,
 redisInitOpenSSL() == REDIS_OK); freeReplyObject(rep); redisReaderFree(r); return 0; }'' "$out/lib/amd64/libhiredis.so $out/lib/amd64/libhiredis_ssl.so"}
      ${chk ''"$W/t"'' "^ok 1\\.5\\.0 2 solnix 42 1$"}
    '';
  };

  # aws-c-common (Apache-2.0): the AWS C SDK's base library (allocators, byte buffers, encodings, threads). cmake, shared, as nixpkgs
  # (its tests off). SunOS takes upstream's generic branch (the fallback system-info stubs). Its own -D_POSIX_C_SOURCE/-D_XOPEN_SOURCE
  # make illumos headers strict, which hides flock(3C) (cross_process_lock.c): -D__EXTENSIONS__, as glibc exposes it there.
  # cmake/AwsCFlags.cmake (installed, and used by every aws-c-* library) links with GNU ld's -Wl,--exclude-libs,libcrypto.a on any
  # non-Apple UNIX; illumos ld has no such option and nothing here links a static libcrypto: not on SunOS. Upstream's generic branch
  # (any OS it does not name) links no libm, so the library left round() unresolved for every consumer (the check's link failed):
  # SunOS gets the BSDs' platform libraries (dl m Threads) with the same fallback sources.
  aws-c-common = mkSrcPkg {
    pname = "aws-c-common"; version = "1.0.0";
    src = { url = "https://codeload.github.com/awslabs/aws-c-common/tar.gz/refs/tags/v1.0.0";
            sha256 = "94de89f65d4917dd7381679ea3297d7304c43338158fa7bec190fa53c218ce90"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      f=cmake/AwsCFlags.cmake
      [ "$(grep -c 'exclude-libs' $f)" = 1 ] && [ "$(grep -cx '        if (UNIX AND NOT APPLE)' $f)" = 1 ] || { echo "FATAL: aws-c-common exclude-libs anchor" >&2; exit 1; }
      sed -i 's/^        if (UNIX AND NOT APPLE)$/        if (UNIX AND NOT APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "SunOS")/' $f
      [ "$(grep -cx '    elseif(CMAKE_SYSTEM_NAME STREQUAL "Android")' CMakeLists.txt)" = 1 ] || { echo "FATAL: aws-c-common platform anchor" >&2; exit 1; }
      cat > "$W/sun.cmake" <<'SUN'
    elseif(CMAKE_SYSTEM_NAME STREQUAL "SunOS")
        list(APPEND PLATFORM_LIBS dl m Threads::Threads)
        list (APPEND AWS_COMMON_OS_SRC "source/platform_fallback_stubs/system_info.c")
        list (APPEND AWS_COMMON_OS_SRC "source/platform_fallback_stubs/file_direct_io.c")
SUN
      n=$(grep -nx '    elseif(CMAKE_SYSTEM_NAME STREQUAL "Android")' CMakeLists.txt | cut -d: -f1); sed -i "$((n - 1))r $W/sun.cmake" CMakeLists.txt
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DCMAKE_C_FLAGS=-D__EXTENSIONS__"}
      /usr/bin/elfdump -d "$out/lib/amd64/libaws-c-common.so" | grep -q 'NEEDED .*libm\.so' || { echo "FATAL: libaws-c-common does not need libm" >&2; exit 1; }
      grep -q 'NOT CMAKE_SYSTEM_NAME STREQUAL "SunOS")' "$out/lib/amd64/cmake/aws-c-common/modules/AwsCFlags.cmake" || { echo "FATAL: installed AwsCFlags.cmake unpatched" >&2; exit 1; }
      ${tprog ''#include <aws/common/common.h>
#include <aws/common/encoding.h>
#include <stdio.h>
int main(void){ struct aws_allocator *a = aws_default_allocator(); aws_common_library_init(a);
struct aws_byte_cursor in = aws_byte_cursor_from_c_str("solnix"); struct aws_byte_buf out; if (aws_byte_buf_init(&out, a, 16)) return 1;
if (aws_base64_encode(&in, &out)) return 2; printf("ok %.8s\n", (const char *)out.buffer); aws_byte_buf_clean_up(&out); aws_common_library_clean_up(); return 0; }'' "$out/lib/amd64/libaws-c-common.so"}
      ${chk ''"$W/t"'' "^ok c29sbml4$"}
    '';
  };

  # libvdpau (MIT): the VDPAU video-decode wrapper, which loads a vendor backend at run time. meson; as nixpkgs: drivers from
  # /run/opengl-driver/lib/vdpau, and its patch that loads libvdpau_trace.so.1 by name from the library's own lib dir.
  libvdpau = mkSrcPkg {
    pname = "libvdpau"; version = "1.5";
    src = { url = "https://gitlab.freedesktop.org/vdpau/libvdpau/-/archive/1.5/libvdpau-1.5.tar.bz2";
            sha256 = "a5d50a42b8c288febc07151ab643ac8de06a18446965c7241f89b4e810821913"; };
    deps = [ world libx11 libxext ]; linkDeps = [ base.xorgproto libxcb libxau libxdmcp ]; nativeTools = [ bzip2-bin gnupatch ] ++ mesonTools;
    build = ''
      patch -p1 < ${fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/li/libvdpau/tracing.patch" "30bb640ab9c2157cf9cc29c4a49755a689d6af2fd2368435b2b0ebb1b8ce35f5"}
      ${mesonBuild "-Dmoduledir=/run/opengl-driver/lib/vdpau"}
      [ -f "$out/lib/amd64/libvdpau_trace.so.1" ] || { echo "FATAL: libvdpau: no trace library in lib/amd64" >&2; exit 1; }
      # no backend named solnixnone exists: the wrapper must report NO_IMPLEMENTATION (the display is never touched on that path)
      ${tprog ''#include <vdpau/vdpau_x11.h>
#include <stdio.h>
int main(void){ VdpDevice d; VdpGetProcAddress *g; VdpStatus s = vdp_device_create_x11(NULL, 0, &d, &g); printf("ok %d\n", s == VDP_STATUS_NO_IMPLEMENTATION); return 0; }'' "$out/lib/amd64/libvdpau.so"}
      ${chk ''VDPAU_DRIVER=solnixnone VDPAU_DRIVER_PATH="$W" "$W/t"'' "^ok 1$"}
    '';
  };

  # rpcsvc-proto (MIT and BSD-3-Clause): rpcgen and the rpcsvc/*.x protocol files (with their generated headers) that glibc dropped.
  # Tag tarball: autoreconf. As nixpkgs: upstream's RPCGEN_CPP/CPP patch. Its po/ ships no catalogs and the served gettext has no
  # autopoint, so gettext is taken out of the build (rpcgen without NLS). The build runs the new rpcgen over rpcsvc/*.x: -Y names the
  # compiler's cpp, so a build host's /lib/cpp (which rpcgen tries first) is never used.
  rpcsvc-proto = mkSrcPkg {
    pname = "rpcsvc-proto"; version = "1.4.4";
    src = { url = "https://codeload.github.com/thkukuk/rpcsvc-proto/tar.gz/refs/tags/v1.4.4";
            sha256 = "7988641deae8463303b6273d7af98ece09111c385d4c9134a142a5fad3cdfef8"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ [ gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://github.com/thkukuk/rpcsvc-proto/commit/e772270774ff45172709e39f744cab875a816667.diff" "983e1857dce37812a854058e616db9abe3de7605c0c007702a8787cd977b80ac"}
      [ "$(grep -c '^AM_GNU_GETTEXT' configure.ac)" = 3 ] && grep -q ' po/Makefile.in\])$' configure.ac && grep -qx 'SUBDIRS = rpcgen rpcsvc po' Makefile.am \
        && grep -qF '$(top_builddir)/rpcgen/rpcgen -h -o $@ $<' rpcsvc/Makefile.am || { echo "FATAL: rpcsvc-proto anchors" >&2; exit 1; }
      sed -i -e '/^AM_GNU_GETTEXT/d' -e 's| po/Makefile.in\])$|])|' configure.ac
      sed -i 's/^SUBDIRS = rpcgen rpcsvc po$/SUBDIRS = rpcgen rpcsvc/' Makefile.am
      grep -qx 'rpcgen_LDADD = $(LIBINTL)' rpcgen/Makefile.am || { echo "FATAL: rpcsvc-proto LIBINTL anchor" >&2; exit 1; }
      sed -i '/^rpcgen_LDADD = \$(LIBINTL)$/d' rpcgen/Makefile.am
      # rindex(3C) is declared only in illumos <strings.h> (glibc: <string.h> too): its standard name
      [ "$(grep -c 'rindex (' rpcgen/rpc_main.c)" = 1 ] || { echo "FATAL: rpcsvc-proto rindex anchor" >&2; exit 1; }
      sed -i 's/rindex (/strrchr (/' rpcgen/rpc_main.c
      sed -i "s|\$(top_builddir)/rpcgen/rpcgen -h -o|\$(top_builddir)/rpcgen/rpcgen -Y $gcc/bin -h -o|" rpcsvc/Makefile.am
      mkdir -p m4
      ${autoreconf}
      ./configure --prefix="$out"
      gmake -j8; gmake install
      [ -f "$out/include/rpcsvc/rstat.h" ] && [ -f "$out/include/rpcsvc/rstat.x" ] || { echo "FATAL: rpcsvc-proto: no rpcsvc/rstat.{h,x}" >&2; exit 1; }
      printf 'struct solnix { int n; string s<>; };\nprogram P { version V { int F(solnix) = 1; } = 1; } = 0x20000001;\n' > "$W/t.x"
      ${chk ''cd "$W" && "$out/bin/rpcgen" -Y "$gcc/bin" -h t.x'' "^struct solnix \\{"}
    '';
  };

  # fast-float (Apache-2.0 / BSL-1.0 / MIT): header-only fast from_chars for floats. cmake install, the queue's 8.3.2.
  fast-float = mkSrcPkg {
    pname = "fast-float"; version = "8.3.2";
    src = { url = "https://codeload.github.com/fastfloat/fast_float/tar.gz/refs/tags/v8.3.2";
            sha256 = "71bb9e865b888df01351558db5a39586d13ea97ada162156b3a07784d8c1b26b"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DFASTFLOAT_TEST=OFF"}
      cat > "$W/t.cc" <<'TPROG'
#include <fast_float/fast_float.h>
#include <cstdio>
#include <cstring>
int main(){ const char *s = "3.14159 rest"; double d = 0; auto r = fast_float::from_chars(s, s + std::strlen(s), d);
std::printf("ok %s %.5f %d %c\n", FASTFLOAT_VERSION_STR, d, r.ec == std::errc(), *r.ptr == ' ' ? 's' : 'x'); }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 8\\.3\\.2 3\\.14159 1 s$"}
    '';
  };

  # simdjson (Apache-2.0): SIMD JSON parsing, shared, as nixpkgs (developer mode off), the queue's 4.6.11.
  simdjson = mkSrcPkg {
    pname = "simdjson"; version = "4.6.11";
    src = { url = "https://codeload.github.com/simdjson/simdjson/tar.gz/refs/tags/v4.6.11";
            sha256 = "61d948fc24f0d793829ad658058e7597d064988a89b4607ea02e401a82df98ff"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DSIMDJSON_DEVELOPER_MODE=OFF -DBUILD_SHARED_LIBS=ON"}
      cat > "$W/t.cc" <<'TPROG'
#include <simdjson.h>
#include <iostream>
int main(){ simdjson::dom::parser p; simdjson::padded_string j(std::string("{\"a\":[1,2,3],\"s\":\"solnix\"}"));
simdjson::dom::element e = p.parse(j); simdjson::dom::array a = e["a"]; std::string_view s = e["s"];
std::cout << "ok " << SIMDJSON_VERSION << " " << a.size() << " " << s << " " << int64_t(a.at(2)) << "\n"; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" "$out/lib/amd64/libsimdjson.so" -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 4\\.6\\.11 3 solnix 3$"}
    '';
  };

  # byacc (public domain): Berkeley yacc, as nixpkgs: installed as byacc (--program-transform-name), with yacc linked to it.
  byacc = mkSrcPkg {
    pname = "byacc"; version = "20260126";
    src = { url = "https://invisible-mirror.net/archives/byacc/byacc-20260126.tgz";
            sha256 = "b618c5fb44c2f5f048843db90f7d1b24f78f47b07913c8c7ba8c942d3eb24b00"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" "--program-transform-name=s,^,b,"
      gmake -j8; gmake install
      ln -s "$out/bin/byacc" "$out/bin/yacc"
      ${chk ''"$out/bin/byacc" -V'' "2\\.0 20260126"}
      # a precedence grammar through yacc, compiled and run: 2+3*4
      cat > "$W/t.y" <<'YACC'
%{
#include <stdio.h>
int yylex(void); void yyerror(const char *);
%}
%token D
%left '+'
%left '*'
%%
s : e { printf("ok %d\n", $1); } ;
e : e '+' e { $$ = $1 + $3; } | e '*' e { $$ = $1 * $3; } | D ;
%%
static const char *p = "2+3*4";
int yylex(void){ if (!*p) return 0; if (*p >= '0' && *p <= '9') { yylval = *p++ - '0'; return D; } return *p++; }
void yyerror(const char *m){ fprintf(stderr, "%s\n", m); }
int main(void){ return yyparse(); }
YACC
      ( cd "$W" && "$out/bin/yacc" t.y && "$CC" y.tab.c -o tcalc )
      ${chk ''"$W/tcalc"'' "^ok 14$"}
    '';
  };

  # woff2 (MIT): Google's WOFF2 font compression (libwoff2common/dec/enc and woff2_compress/decompress/info), on the nix chain's brotli.
  # cmake; as nixpkgs: the programs in a shared build too, and the CMake 4 minimum version.
  woff2 = mkSrcPkg {
    pname = "woff2"; version = "1.0.2";
    src = { url = "https://codeload.github.com/google/woff2/tar.gz/refs/tags/v1.0.2";
            sha256 = "add272bb09e6384a4833ffca4896350fdb16e0ca22df68c0384773c67a175594"; };
    deps = [ world base.nixChain.brotli ]; nativeTools = [ cmake base.pkgconf ] ++ hostTools;
    build = ''
      grep -qx 'if (NOT BUILD_SHARED_LIBS)' CMakeLists.txt && grep -qx 'cmake_minimum_required(VERSION 2.8.6)' CMakeLists.txt \
        || { echo "FATAL: woff2 CMakeLists anchors" >&2; exit 1; }
      sed -i -e 's/^if (NOT BUILD_SHARED_LIBS)$/if (TRUE)/' -e 's/^cmake_minimum_required(VERSION 2.8.6)$/cmake_minimum_required(VERSION 3.10)/' CMakeLists.txt
      ${cmakeB "-DCANONICAL_PREFIXES=ON -DBUILD_SHARED_LIBS=ON"}
      # a real font (Noto Sans) to WOFF2 and back to an sfnt
      cp ${noto-sans}/share/fonts/noto/NotoSans-Regular.ttf "$W/n.ttf"
      "$out/bin/woff2_compress" "$W/n.ttf" >&2
      ${chk ''od -An -c -N4 "$W/n.woff2"'' "w +O +F +2"}
      mkdir "$W/d"; cp "$W/n.woff2" "$W/d/"; "$out/bin/woff2_decompress" "$W/d/n.woff2" >&2
      ${chk ''od -An -tx1 -N4 "$W/d/n.ttf"'' "00 01 00 00"}
    '';
  };

  # hdf5-cpp (BSD-3-Clause): HDF5 1.14.6 with its C++ and high-level libraries, zlib and szip (libaec) filters, and the h5* tools;
  # nixpkgs' hdf5 with cppSupport (its cmake flags; the -shared suffix off the tools; Arch's reproducibility patch, which drops the
  # build host's uname from libhdf5.settings). Tests and examples are not built (neither is installed). ${scrub} turns the build's
  # compiler wrappers into plain gcc/g++ in libhdf5.settings and the h5cc scripts, as nixpkgs' remove-references-to does.
  hdf5-cpp = mkSrcPkg {
    pname = "hdf5-cpp"; version = "1.14.6";
    src = { url = "https://codeload.github.com/HDFGroup/hdf5/tar.gz/refs/tags/hdf5_1.14.6";
            sha256 = "09ee1c671a87401a5201c06106650f62badeea5a3b3941e9b1e2e1e08317357f"; };
    deps = [ world zlib libaec ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://gitlab.archlinux.org/archlinux/packaging/packages/hdf5/-/raw/721d33408db902ff738db18f1e977611d49b4ba8/hdf5-make-reproducible.patch" "37eb26bd2fab59299401c5702b8f0ad23a57e6368a257c426f7ef5ed0ef5c9ca"}
      # "Configured on" is SOURCE_DATE_EPOCH (1980-01-01T00:00Z) in the build host's local zone: lixi (US Eastern) wrote 1979-12-31 and
      # woof (UTC) 1980-01-01, in libhdf5.so and libhdf5.settings (cross-host compare, --check SAME on each). In UTC, as NixOS's sandbox is.
      grep -qx 'string (TIMESTAMP CONFIG_DATE "%Y-%m-%d")' CMakeLists.txt || { echo "FATAL: hdf5 CONFIG_DATE anchor" >&2; exit 1; }
      sed -i 's/^string (TIMESTAMP CONFIG_DATE "%Y-%m-%d")$/string (TIMESTAMP CONFIG_DATE "%Y-%m-%d" UTC)/' CMakeLists.txt
      ${builtins.replaceStrings [ "cmake --build _b -j16" ] [ "cmake --build _b -j\${NIX_BUILD_CORES:-4}" ] (cmakeB ("-DHDF5_INSTALL_LIB_DIR=lib/amd64 -DHDF5_INSTALL_CMAKE_DIR=lib/amd64/cmake "
        + "-DBUILD_STATIC_LIBS=OFF -DBUILD_SHARED_LIBS=ON -DHDF5_BUILD_CPP_LIB=ON -DHDF5_BUILD_FORTRAN=OFF -DHDF5_ENABLE_SZIP_SUPPORT=ON "
        + "-DHDF5_ENABLE_PARALLEL=OFF -DHDF5_BUILD_JAVA=OFF -DHDF5_ENABLE_THREADSAFE=OFF -DHDF5_BUILD_HL_LIB=ON -DHDF5_ENABLE_NONSTANDARD_FEATURE_FLOAT16=ON "
        + "-DBUILD_TESTING=OFF -DHDF5_BUILD_EXAMPLES=OFF -Dlibaec_DIR=${libaec}/lib/amd64/cmake/libaec "
        + "-DZLIB_ROOT=${zlib} -DZLIB_LIBRARY=${zlib}/lib/amd64/libz.so -DZLIB_INCLUDE_DIR=${zlib}/include"))}
      for f in "$out"/bin/*-shared; do [ -e "$f" ] || continue; mv "$f" "''${f%-shared}"; done
      ${scrub}
      ${chk ''"$out/bin/h5dump" --version'' "h5dump: Version 1\\.14\\.6"}
      # a chunked, deflated dataset written and read back through the C++ API; the szip filter is present
      cat > "$W/t.cc" <<'TPROG'
#include <H5Cpp.h>
#include <iostream>
int main(int c, char **v){ int a[4] = { 1, 2, 3, 42 }, b[4] = { 0 }; hsize_t d[1] = { 4 }, ch[1] = { 4 }; if (c < 2) return 1;
{ H5::H5File f(v[1], H5F_ACC_TRUNC); H5::DSetCreatPropList pl; pl.setChunk(1, ch); pl.setDeflate(6);
  H5::DataSet s = f.createDataSet("n", H5::PredType::NATIVE_INT, H5::DataSpace(1, d), pl); s.write(a, H5::PredType::NATIVE_INT); }
H5::H5File f(v[1], H5F_ACC_RDONLY); f.openDataSet("n").read(b, H5::PredType::NATIVE_INT);
unsigned ma, mi, re; H5get_libversion(&ma, &mi, &re); std::cout << "ok " << ma << "." << mi << "." << re << " " << b[3] << " " << (H5Zfilter_avail(H5Z_FILTER_SZIP) > 0) << "\n"; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" "$out/lib/amd64/libhdf5_cpp.so" "$out/lib/amd64/libhdf5.so" -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t" "$W/t.h5"'' "^ok 1\\.14\\.6 42 1$"}
      ${chk ''"$out/bin/h5dump" -d n "$W/t.h5"'' "1, 2, 3, 42"}
      grep -q 'Configured on: 1980-01-01$' "$out/lib/amd64/libhdf5.settings" || { echo "FATAL: hdf5 configure date not 1980-01-01" >&2; exit 1; }
    '';
  };

  # libmpdclient (BSD-3-Clause): the Music Player Daemon client library. meson, as nixpkgs (-Dtest=true); upstream's tests run here
  # (socketpair and in-memory parsing only), with main's check found at run time through LD_LIBRARY_PATH (a link dep, not a RUNPATH).
  # On non-Linux upstream links no version script, so every symbol is exported. Its -std=c99 hides strdup on illumos (glibc's
  # _GNU_SOURCE, which it sets, exposes it): -D__EXTENSIONS__. Its meson names no socket library outside Windows/Haiku: illumos'
  # sockets and gethostbyname are in libsocket and libnsl.
  libmpdclient = mkSrcPkg {
    pname = "libmpdclient"; version = "2.24";
    src = { url = "https://codeload.github.com/MusicPlayerDaemon/libmpdclient/tar.gz/refs/tags/v2.24";
            sha256 = "b19ec4c10314f5b55e1bca2a34c299effbbb2f1f9b5113b331b7ba789f0c17d1"; };
    deps = [ world ]; linkDeps = [ check ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild "-Dtest=true -Dc_args=-D__EXTENSIONS__ '-Dc_link_args=-lsocket -lnsl'"}
      mrc=0; LD_LIBRARY_PATH=${check}/lib/amd64 meson test -C _b --print-errorlogs > "$W/mt.log" 2>&1 || mrc=$?   # set -e: keep the rc
      grep -E '^ *[0-9]+/[0-9]+ ' "$W/mt.log" >&2 || true
      [ $mrc = 0 ] || { echo "FATAL: libmpdclient meson test rc=$mrc" >&2; tail -60 "$W/mt.log" >&2; exit 1; }
      ${tprog ''#include <mpd/client.h>
#include <mpd/parser.h>
#include <stdio.h>
int main(void){ struct mpd_parser *p = mpd_parser_new(); char l[] = "file: solnix.flac"; if (!p) return 1; enum mpd_parser_result r = mpd_parser_feed(p, l);
printf("ok %d.%d %d %s %s\n", LIBMPDCLIENT_MAJOR_VERSION, LIBMPDCLIENT_MINOR_VERSION, r == MPD_PARSER_PAIR, mpd_parser_get_name(p), mpd_parser_get_value(p));
mpd_parser_free(p); return 0; }'' "$out/lib/amd64/libmpdclient.so"}
      ${chk ''"$W/t"'' "^ok 2\\.24 1 file solnix\\.flac$"}
    '';
  };

  # cli11 (BSD-3-Clause): the header-only C++ command-line parser, the queue's 2.6.2. cmake install (tests, examples, docs off).
  cli11 = mkSrcPkg {
    pname = "cli11"; version = "2.6.2";
    src = { url = "https://codeload.github.com/CLIUtils/CLI11/tar.gz/refs/tags/v2.6.2";
            sha256 = "c6ea6b2e5608b3ea8617999bd5f47420c71b2ebdb8dc4767c1034d1da5785711"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DCLI11_BUILD_TESTS=OFF -DCLI11_BUILD_EXAMPLES=OFF -DCLI11_BUILD_DOCS=OFF"}
      cat > "$W/t.cc" <<'TPROG'
#include <CLI/CLI.hpp>
#include <iostream>
int main(int argc, char **argv){ CLI::App app{"t"}; int n = 0; std::string s; app.add_option("-n", n); app.add_option("--name", s);
CLI11_PARSE(app, argc, argv); std::cout << "ok " << CLI11_VERSION << " " << n << " " << s << "\n"; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t" -n 42 --name solnix'' "^ok 2\\.6\\.2 42 solnix$"}
    '';
  };

  # ---- recipes7 batch 16: the aws-c-* libraries and hdf5 users R15 made buildable, and small leaves --------------------------------
  # The aws-c-* libraries (Apache-2.0) on R15's aws-c-common, cmake, shared, as nixpkgs. Their standalone build looks for aws-c-common's
  # cmake modules under lib/cmake or lib64/cmake; here they are in lib/amd64/cmake: named directly (the module that it finds first).
  awsC = pname: sha256: extraDeps: flags: tsrc: libs: mkSrcPkg {
    inherit pname; version = "1.0.0";
    src = { url = "https://codeload.github.com/awslabs/${pname}/tar.gz/refs/tags/v1.0.0"; inherit sha256; };
    deps = [ world aws-c-common ] ++ extraDeps; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DAWS_GET_VERSION_MODULE=${aws-c-common}/lib/amd64/cmake/aws-c-common/modules/AwsGetVersion.cmake -Daws-c-common_DIR=${aws-c-common}/lib/amd64/cmake/aws-c-common ${flags}"}
      ${tprog tsrc "-I${aws-c-common}/include ${libs} ${aws-c-common}/lib/amd64/libaws-c-common.so -Wl,-R,${aws-c-common}/lib/amd64"}
      ${chk ''"$W/t"'' "^ok "}
      ${if pname == "aws-c-cal" then ''grep -q "^OpenSSL_DIR:PATH=${base.openssl}/lib/amd64/cmake/OpenSSL$" _b/CMakeCache.txt || { echo "FATAL: aws-c-cal: not the store openssl config" >&2; exit 1; }'' else ""}
    '';
  };
  # aws-checksums: CRC32/CRC32C/CRC64 (the SSE4.2/AVX-512 paths where the CPU has them). CRC32 of "123456789" is the standard 0xcbf43926.
  aws-checksums = awsC "aws-checksums" "6c058812f5b537ce58eac1e529f441ff387a652ea62cbe9b844f9188339221b1" [ ] "" ''#include <aws/checksums/crc.h>
#include <stdio.h>
int main(void){ printf("ok %08x %08x\n", aws_checksums_crc32((const uint8_t *)"123456789", 9, 0), aws_checksums_crc32c((const uint8_t *)"123456789", 9, 0)); return 0; }'' "$out/lib/amd64/libaws-checksums.so";
  # aws-c-compression: HPACK's Huffman coding (aws-c-http)
  aws-c-compression = awsC "aws-c-compression" "d8e934da2086bfec41f97a0cff749d926f66ccb90f2052f1d70841916c1bf4d7" [ ] "" ''#include <aws/compression/compression.h>
#include <aws/common/common.h>
#include <stdio.h>
int main(void){ struct aws_allocator *a = aws_default_allocator(); aws_compression_library_init(a);
printf("ok %s\n", aws_error_name(AWS_ERROR_COMPRESSION_UNKNOWN_SYMBOL)); aws_compression_library_clean_up(); return 0; }'' "$out/lib/amd64/libaws-c-compression.so";
  # aws-c-sdkutils: AWS profile (~/.aws/config) and endpoint-rule parsing; the check parses a profile from memory
  aws-c-sdkutils = awsC "aws-c-sdkutils" "ddf9d09ba137ad0697afe1c09f5d778d6b2f1aadb277dffd231ff615ae34bc82" [ ] "" ''#include <aws/sdkutils/sdkutils.h>
#include <aws/sdkutils/aws_profile.h>
#include <stdio.h>
int main(void){ struct aws_allocator *a = aws_default_allocator(); aws_sdkutils_library_init(a);
struct aws_byte_buf b = aws_byte_buf_from_c_str("[profile solnix]\nregion = us-west-2\n");
struct aws_profile_collection *c = aws_profile_collection_new_from_buffer(a, &b, AWS_PST_CONFIG); if (!c) return 1;
printf("ok %d\n", (int)aws_profile_collection_get_profile_count(c)); aws_profile_collection_release(c); aws_sdkutils_library_clean_up(); return 0; }'' "$out/lib/amd64/libaws-c-sdkutils.so";
  # aws-c-cal: hashes, HMAC and keys on OpenSSL's libcrypto (its unix backend, as nixpkgs: openssl); SHA-256 of "abc" is the FIPS vector
  aws-c-cal = awsC "aws-c-cal" "9c6d424d206dd7822aa44fa39ce31575dcbaa83133620abdac8e56e4cea9667c" [ base.openssl ] "-DUSE_OPENSSL=ON ${storePrefix}" ''#include <aws/cal/cal.h>
#include <aws/cal/hash.h>
#include <stdio.h>
int main(void){ struct aws_allocator *a = aws_default_allocator(); aws_cal_library_init(a); uint8_t d[32]; struct aws_byte_buf o = aws_byte_buf_from_empty_array(d, 32);
struct aws_byte_cursor in = aws_byte_cursor_from_c_str("abc"); if (aws_sha256_compute(a, &in, &o, 0)) return 1;
printf("ok %02x%02x%02x%02x\n", d[0], d[1], d[2], d[3]); aws_cal_library_clean_up(); return 0; }'' "$out/lib/amd64/libaws-c-cal.so";

  # matio (BSD-2-Clause): MATLAB .mat file I/O, with the v7.3 (HDF5) format on R15's hdf5-cpp, as nixpkgs (ac_cv_va_copy=1).
  matio = mkSrcPkg {
    pname = "matio"; version = "1.5.30";
    src = { url = "https://downloads.sourceforge.net/matio/matio-1.5.30.tar.gz";
            sha256 = "8bd3b9477042ecc00dd71c04762fa58468e14cccc32fd8c6826c2da1e8bc3107"; };
    deps = [ world zlib hdf5-cpp ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static ac_cv_va_copy=1 --with-hdf5="${hdf5-cpp}" --with-zlib="${zlib}"
      gmake -j8; gmake install
      find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true
      # a 2x2 double matrix written to a v7.3 (HDF5) .mat file and read back
      ${tprog ''#include <matio.h>
#include <stdio.h>
int main(int c, char **v){ double x[4] = { 1, 2, 3, 42 }; size_t d[2] = { 2, 2 }; if (c < 2) return 1;
mat_t *m = Mat_CreateVer(v[1], NULL, MAT_FT_MAT73); if (!m) return 2; matvar_t *s = Mat_VarCreate("a", MAT_C_DOUBLE, MAT_T_DOUBLE, 2, d, x, 0);
Mat_VarWrite(m, s, MAT_COMPRESSION_NONE); Mat_VarFree(s); Mat_Close(m);
m = Mat_Open(v[1], MAT_ACC_RDONLY); if (!m) return 3; matvar_t *r = Mat_VarRead(m, "a"); if (!r) return 4;
printf("ok %d %g %d\n", Mat_GetVersion(m) == MAT_FT_MAT73, ((double *)r->data)[3], (int)r->dims[0]); Mat_VarFree(r); Mat_Close(m); return 0; }'' "$out/lib/amd64/libmatio.so"}
      ${chk ''"$W/t" "$W/t.mat"'' "^ok 1 42 2$"}
    '';
  };

  # highfive (BSL-1.0): header-only C++ wrapper for HDF5, on R15's hdf5-cpp. cmake install, examples and tests off, as nixpkgs.
  highfive = mkSrcPkg {
    pname = "highfive"; version = "3.3.0";
    src = { url = "https://codeload.github.com/highfive-devs/highfive/tar.gz/refs/tags/v3.3.0";
            sha256 = "325cfbcf0c0296a6dd26f3b088801b7ebb8d6f109c0565c11d2d8c4af3253bff"; };
    deps = [ world hdf5-cpp ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DHIGHFIVE_EXAMPLES=OFF -DHIGHFIVE_UNIT_TESTS=OFF -DHIGHFIVE_BUILD_DOCS=OFF -DHDF5_DIR=${hdf5-cpp}/lib/amd64/cmake"}
      cat > "$W/t.cc" <<'TPROG'
#include <highfive/highfive.hpp>
#include <iostream>
#include <vector>
int main(int c, char **v){ if (c < 2) return 1; { HighFive::File f(v[1], HighFive::File::Truncate); f.createDataSet("v", std::vector<int>{ 1, 2, 42 }); }
HighFive::File f(v[1], HighFive::File::ReadOnly); auto r = f.getDataSet("v").read<std::vector<int>>(); std::cout << "ok " << r.size() << " " << r[2] << "\n"; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" -I${hdf5-cpp}/include "$W/t.cc" ${hdf5-cpp}/lib/amd64/libhdf5.so -Wl,-R,${hdf5-cpp}/lib/amd64 -o "$W/t"
      ${chk ''"$W/t" "$W/t.h5"'' "^ok 3 42$"}
    '';
  };

  # uthash (BSD-1-Clause-like): header-only hash tables, lists and strings for C structs; its headers, as nixpkgs (tests need perl).
  uthash = mkSrcPkg {
    pname = "uthash"; version = "2.4.0";
    src = { url = "https://codeload.github.com/troydhanson/uthash/tar.gz/refs/tags/v2.4.0";
            sha256 = "387ba027946d7c64e9aa19cc53b2edcd714f8f9dca9fa8e3aaef17e0e8e3d736"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      mkdir -p "$out/include"; cp src/*.h "$out/include/"
      ${tprog ''#include <uthash.h>
#include <stdio.h>
#include <stdlib.h>
struct e { int k; int v; UT_hash_handle hh; };
int main(void){ struct e *h = NULL, *f; for (int i = 0; i < 100; i++) { struct e *x = malloc(sizeof *x); x->k = i; x->v = i * i; HASH_ADD_INT(h, k, x); }
int k = 42; HASH_FIND_INT(h, &k, f); printf("ok %u %d\n", HASH_COUNT(h), f ? f->v : -1); return 0; }'' ""}
      ${chk ''"$W/t"'' "^ok 100 1764$"}
    '';
  };

  # msgpack-c (BSL-1.0): MessagePack for C, shared, as nixpkgs (examples off; its tests are gtest's, off).
  msgpack-c = mkSrcPkg {
    pname = "msgpack-c"; version = "7.0.2";
    src = { url = "https://codeload.github.com/msgpack/msgpack-c/tar.gz/refs/tags/c-7.0.2";
            sha256 = "f720af974b72cda874c2c347d4bafef5385c4e7942a27b3c87d6fa482412d08c"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DMSGPACK_BUILD_EXAMPLES=OFF -DMSGPACK_BUILD_TESTS=OFF"}
      ${tprog ''#include <msgpack.h>
#include <stdio.h>
int main(void){ msgpack_sbuffer b; msgpack_sbuffer_init(&b); msgpack_packer p; msgpack_packer_init(&p, &b, msgpack_sbuffer_write);
msgpack_pack_array(&p, 2); msgpack_pack_int(&p, 42); msgpack_pack_str(&p, 6); msgpack_pack_str_body(&p, "solnix", 6);
msgpack_unpacked u; msgpack_unpacked_init(&u); if (msgpack_unpack_next(&u, b.data, b.size, NULL) != MSGPACK_UNPACK_SUCCESS) return 1;
msgpack_object o = u.data; printf("ok %s %d %lld %.*s\n", msgpack_version(), (int)o.via.array.size, (long long)o.via.array.ptr[0].via.i64,
 (int)o.via.array.ptr[1].via.str.size, o.via.array.ptr[1].via.str.ptr); return 0; }'' "$out/lib/amd64/libmsgpack-c.so"}
      ${chk ''"$W/t"'' "^ok 7\\.0\\.2 2 42 solnix$"}
    '';
  };

  # msgpack-cxx (BSL-1.0): header-only MessagePack for C++ on the nix chain's boost, as nixpkgs (C++20 API on, docs and tests off).
  msgpack-cxx = mkSrcPkg {
    pname = "msgpack-cxx"; version = "8.0.0";
    src = { url = "https://codeload.github.com/msgpack/msgpack-c/tar.gz/refs/tags/cpp-8.0.0";
            sha256 = "f634fb7052da4478096f2a02dfb6d91174e5836b317afb006375249ccb086aa8"; };
    deps = [ world base.nixChain.boost ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DMSGPACK_BUILD_DOCS=OFF -DMSGPACK_CXX20=ON -DMSGPACK_BUILD_TESTS=OFF ${storePrefix}"}
      grep -q "^Boost_DIR:PATH=${base.nixChain.boost}/lib/amd64/cmake/Boost-" _b/CMakeCache.txt || { echo "FATAL: msgpack-cxx: not the store boost" >&2; exit 1; }
      cat > "$W/t.cc" <<'TPROG'
#include <msgpack.hpp>
#include <iostream>
#include <map>
#include <sstream>
int main(){ std::map<std::string, int> m{{"solnix", 42}}; std::stringstream s; msgpack::pack(s, m); std::string b = s.str();
auto h = msgpack::unpack(b.data(), b.size()); auto r = h.get().as<std::map<std::string, int>>(); std::cout << "ok " << MSGPACK_VERSION << " " << r["solnix"] << "\n"; }
TPROG
      "$CXX" -std=c++20 -I"$out/include" -I${base.nixChain.boost}/include "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 8\\.0\\.0 42$"}
    '';
  };

  # hdrhistogram_c (BSD-2-Clause / CC0): the HdrHistogram latency histogram in C, on zlib (its log format). cmake, as nixpkgs.
  hdrhistogram_c = mkSrcPkg {
    pname = "hdrhistogram_c"; version = "0.11.10";
    src = { url = "https://codeload.github.com/HdrHistogram/HdrHistogram_c/tar.gz/refs/tags/0.11.10";
            sha256 = "c3b06d077e680d112abf9f027d8a558f1176ee4a55a7c523577833391d8c2249"; };
    deps = [ world zlib ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      # illumos <endian.h> is glibc's (htobe64 and the rest are libc functions): the Linux branch. Its -std=c99 hides gmtime_r,
      # usleep and struct timespec on illumos: -D__EXTENSIONS__.
      [ "$(grep -cx '#if defined(__linux__) || defined(__CYGWIN__)' src/hdr_endian.h)" = 1 ] || { echo "FATAL: hdr_endian.h anchor" >&2; exit 1; }
      sed -i 's/^#if defined(__linux__) || defined(__CYGWIN__)$/#if defined(__linux__) || defined(__CYGWIN__) || defined(__sun)/' src/hdr_endian.h
      ${cmakeB "-DCMAKE_C_FLAGS=-D__EXTENSIONS__ -DHDR_HISTOGRAM_BUILD_PROGRAMS=OFF -DZLIB_ROOT=${zlib} -DZLIB_LIBRARY=${zlib}/lib/amd64/libz.so -DZLIB_INCLUDE_DIR=${zlib}/include"}
      ${tprog ''#include <hdr/hdr_histogram.h>
#include <stdio.h>
int main(void){ struct hdr_histogram *h; if (hdr_init(1, 3600000000LL, 3, &h)) return 1; for (int i = 1; i <= 1000; i++) hdr_record_value(h, i);
printf("ok %lld %lld %lld\n", (long long)h->total_count, (long long)hdr_max(h), (long long)hdr_value_at_percentile(h, 50.0)); hdr_close(h); return 0; }'' "$out/lib/amd64/libhdr_histogram.so"}
      ${chk ''"$W/t"'' "^ok 1000 1000 500$"}
    '';
  };

  # nghttp3 (MIT): the HTTP/3 (QPACK) library curl and ngtcp2 use. Release tarball (.tar.bz2), cmake, shared, as nixpkgs.
  nghttp3 = mkSrcPkg {
    pname = "nghttp3"; version = "1.18.0";
    src = { url = "https://github.com/ngtcp2/nghttp3/releases/download/v1.18.0/nghttp3-1.18.0.tar.bz2";
            sha256 = "ca232668b94a5e1fb54b41632cc56473ab48226483814410ef62a706294e6402"; };
    deps = [ world ]; nativeTools = [ bzip2-bin cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DENABLE_SHARED_LIB=ON -DENABLE_STATIC_LIB=OFF"}
      find "$out/share/doc" -delete 2>/dev/null || true
      ${tprog ''#include <nghttp3/nghttp3.h>
#include <stdio.h>
int main(void){ const nghttp3_info *i = nghttp3_version(0); nghttp3_qpack_encoder *e;
if (nghttp3_qpack_encoder_new(&e, 4096, nghttp3_mem_default())) return 1; nghttp3_qpack_encoder_del(e); printf("ok %s\n", i->version_str); return 0; }'' "$out/lib/amd64/libnghttp3.so"}
      ${chk ''"$W/t"'' "^ok 1\\.18\\.0$"}
    '';
  };

  # lerc (Apache-2.0): Esri's Limited Error Raster Compression (GDAL, libtiff). cmake, shared, as nixpkgs.
  lerc = mkSrcPkg {
    pname = "lerc"; version = "4.3.0";
    src = { url = "https://codeload.github.com/esri/lerc/tar.gz/refs/tags/v4.3.0";
            sha256 = "28d74992e0bc0f13ecdda1dd9ca3b40b1a87009369b9ec5a599853f6f311fee7"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON"}
      # a 16x16 float raster encoded within 0.01 and decoded back
      ${tprog ''#include <Lerc_c_api.h>
#include <stdio.h>
#include <math.h>
static float in[256], out[256]; static unsigned char blob[8192];
int main(void){ for (int i = 0; i < 256; i++) in[i] = (float)(i % 16) * 0.5f; unsigned int n = 0;
if (lerc_encode(in, 6, 1, 16, 16, 1, 0, NULL, 0.01, blob, sizeof blob, &n)) return 1;
if (lerc_decode(blob, n, 0, NULL, 1, 16, 16, 1, 6, out)) return 2; double m = 0; for (int i = 0; i < 256; i++) m = fmax(m, fabs(in[i] - out[i]));
printf("ok %d %d\n", n > 0, m <= 0.01); return 0; }'' "$out/lib/amd64/libLerc.so -lm"}
      ${chk ''"$W/t"'' "^ok 1 1$"}
    '';
  };

  # spice-protocol (BSD-3-Clause): the SPICE remote-display protocol headers (spice-gtk, qemu). meson; as nixpkgs, its pkg-config file
  # also under lib/.
  spice-protocol = mkSrcPkg {
    pname = "spice-protocol"; version = "0.14.5";
    src = { url = "https://www.spice-space.org/download/releases/spice-protocol-0.14.5.tar.xz";
            sha256 = "baf58449f6e89d19f475899ad5fb9196fdc46c03cc53233f4e39cf2978f9cff7"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild ""}
      mkdir -p "$out/lib"; ln -s ../share/pkgconfig "$out/lib/pkgconfig"
      ${tprog ''#include <spice/protocol.h>
#include <spice/macros.h>
#include <stdio.h>
int main(void){ printf("ok %d %d\n", SPICE_VERSION_MAJOR, SPICE_MAGIC == SPICE_MAGIC_CONST("REDQ")); return 0; }'' "-I$out/include/spice-1"}
      ${chk ''"$W/t"'' "^ok 2 1$"}
      ${chk ''PKG_CONFIG_PATH="$out/lib/pkgconfig" pkg-config --modversion spice-protocol'' "^0\\.14\\.5$"}
    '';
  };

  # opencore-amr (Apache-2.0): the AMR-NB/AMR-WB speech codecs from Android's OpenCORE (ffmpeg's libopencore-amr). autotools (C++).
  opencore-amr = mkSrcPkg {
    pname = "opencore-amr"; version = "0.1.6";
    src = { url = "https://downloads.sourceforge.net/opencore-amr/opencore-amr/opencore-amr-0.1.6.tar.gz";
            sha256 = "483eb4061088e2b34b358e47540b5d495a96cd468e361050fae615b1809dc4a1"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      # -L gcc.lib: libtool's C++ link would otherwise bake libstdc++.la's dir in as -R (as zimg, libmodplug)
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static LDFLAGS="-L$gccLib/amd64"
      gmake -j8; gmake install
      # one 20 ms frame of a tone encoded at 12.2 kbit/s (32 bytes) and decoded back
      ${tprog ''#include <opencore-amrnb/interf_enc.h>
#include <opencore-amrnb/interf_dec.h>
#include <stdio.h>
#include <math.h>
int main(void){ short s[160], o[160]; unsigned char f[64]; for (int i = 0; i < 160; i++) s[i] = (short)(8000 * sin(i * 0.2));
void *e = Encoder_Interface_init(0); int n = Encoder_Interface_Encode(e, MR122, s, f, 0); Encoder_Interface_exit(e);
void *d = Decoder_Interface_init(); Decoder_Interface_Decode(d, f, o, 0); Decoder_Interface_exit(d); printf("ok %d\n", n); return 0; }'' "$out/lib/amd64/libopencore-amrnb.so -lm"}
      ${chk ''"$W/t"'' "^ok 32$"}
    '';
  };

  # celt (BSD-2-Clause): the CELT low-latency audio codec 0.11 (mumble's celt-0.11 compatibility), on libogg, as nixpkgs.
  celt = mkSrcPkg {
    pname = "celt"; version = "0.11.3";
    src = { url = "https://downloads.xiph.org/releases/celt/celt-0.11.3.tar.gz";
            sha256 = "7e64815d4a8a009d0280ecd235ebd917da3abdcfd8f7d0812218c085f9480836"; };
    deps = [ world libogg ]; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j8; gmake install
      ${tprog ''#include <celt/celt.h>
#include <stdio.h>
#include <math.h>
int main(void){ int err = 0; CELTMode *m = celt_mode_create(48000, 960, &err); if (!m || err) return 1; CELTEncoder *e = celt_encoder_create_custom(m, 1, &err);
CELTDecoder *d = celt_decoder_create_custom(m, 1, &err); if (!e || !d) return 2; short s[960], o[960]; unsigned char p[128];
for (int i = 0; i < 960; i++) s[i] = (short)(8000 * sin(i * 0.1)); int n = celt_encode(e, s, 960, p, sizeof p); if (n <= 0) return 3;
printf("ok %d %d\n", n, celt_decode(d, p, n, o, 960)); celt_encoder_destroy(e); celt_decoder_destroy(d); celt_mode_destroy(m); return 0; }'' "-I$out/include $out/lib/amd64/libcelt0.so -lm"}
      ${chk ''"$W/t"'' "^ok 128 960$"}
    '';
  };

  # libcbor (MIT): CBOR (RFC 8949) encoding and decoding (libfido2). cmake, shared, as nixpkgs (its cmocka tests off; examples off).
  libcbor = mkSrcPkg {
    pname = "libcbor"; version = "0.14.0";
    src = { url = "https://codeload.github.com/PJK/libcbor/tar.gz/refs/tags/v0.14.0";
            sha256 = "a8c1516e741562cf95aa4479c64916c3d4d2623e24fdc35e414e2320e7300aae"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DWITH_TESTS=OFF -DWITH_EXAMPLES=OFF -DSANITIZE=OFF"}
      ${tprog ''#include <cbor.h>
#include <stdio.h>
#include <stdlib.h>
int main(void){ cbor_item_t *m = cbor_new_definite_map(1); cbor_map_add(m, (struct cbor_pair){ cbor_move(cbor_build_string("solnix")), cbor_move(cbor_build_uint8(42)) });
unsigned char *b; size_t bs, n = cbor_serialize_alloc(m, &b, &bs); struct cbor_load_result r; cbor_item_t *x = cbor_load(b, n, &r); if (!x) return 1;
printf("ok %d %d %d\n", (int)n, (int)cbor_map_size(x), cbor_get_uint8(cbor_map_handle(x)[0].value)); free(b); cbor_decref(&m); cbor_decref(&x); return 0; }'' "$out/lib/amd64/libcbor.so"}
      ${chk ''"$W/t"'' "^ok 10 1 42$"}
    '';
  };

  # exprtk (MIT): the header-only C++ mathematical expression parser; its one header, as nixpkgs.
  exprtk = mkSrcPkg {
    pname = "exprtk"; version = "0.0.3";
    src = { url = "https://codeload.github.com/ArashPartow/exprtk/tar.gz/refs/tags/0.0.3";
            sha256 = "f9dec6975e86c702033d6a65ba9a0368eba31a61b89d74f2b5d24457c02c8439"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      mkdir -p "$out/include"; cp exprtk.hpp "$out/include/"
      cat > "$W/t.cc" <<'TPROG'
#include <exprtk.hpp>
#include <iostream>
int main(){ double x = 3; exprtk::symbol_table<double> s; s.add_variable("x", x); exprtk::expression<double> e; e.register_symbol_table(s);
exprtk::parser<double> p; if (!p.compile("2*x^2 + 3*x - 1", e)) return 1; std::cout << "ok " << e.value() << "\n"; }
TPROG
      "$CXX" -std=c++17 -O1 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 26$"}
    '';
  };

  # ---- recipes8 batch 17: small leaves the x86 queue has jobs for ------------------------------------------------------------------
  # zip (Info-ZIP, BSD-4-Clause-like Info-ZIP license): zip, zipcloak, zipnote, zipsplit. As nixpkgs: unix/Makefile `generic` (its
  # unix/configure probes the compiler), nixpkgs' eleven patches (gentoo's build patch drops configure's /lib/cpp and -O3 picks and
  # passes LDFLAGS), no bzip2 (nixpkgs links none: its configure only finds a bzip2 dir in the source tree). BINDIR/MANDIR are
  # given on the make line, so configure's /usr/local probe does not reach the install.
  zip = let
    np = "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/zi/zip";
    ge = "https://gitweb.gentoo.org/repo/gentoo.git/plain/app-arch/zip/files"; gi = "id=d37d095fc7a2a9e4a8e904a7bf0f597fe99df85a";
    db = "https://sources.debian.org/data/main/z/zip/3.0-16/debian/patches";
    ps = [
      (fetch "${np}/fix-implicit-declarations.patch" "928a717cacc9fb89c7a9bf0bf6ebea12745c96e518555cfd5a9797f66b558e22")
      (fetch "${np}/fix-time.h-not-included.patch" "50dddb4a82b887f291540eaa1ac7a141fce2a2f169b9db2a7faf700787d93e8b")
      (fetch "${db}/fix-build-with-gcc-14.patch" "336049111eca935abea8a5e19078e48f1f6734b0f209af15545455f9fb5fee32")
      (fetch "${ge}/zip-3.0-pic.patch?${gi}" "afca923887828f6ccdcb98bcb1130f138d014614ca49c2a2526bd0fdc91dda6e")
      (fetch "${ge}/zip-3.0-no-crypt.patch?${gi}" "32d263c492dbc2b37b71d0aa80e566283422e8e6493d91f8aa12946d6d587a4a")
      (fetch "${ge}/zip-3.0-format-security.patch?${gi}" "62618a8af67488508598f8d562e3aff43f18d311b642758ea5ab3c80c8284373")
      (fetch "${ge}/zip-3.0-exec-stack.patch?${gi}" "5e46b247107c71f34e00c93d27d9f5cf0812d1c8ffc171fc71addee715308ff5")
      (fetch "${ge}/zip-3.0-build.patch?${gi}" "a66386c3a48019d8063a48c3610a28862412926f04a3b8f44662c6a87bb250f5")
      (fetch "${ge}/zip-3.0-zipnote-freeze.patch?${gi}" "c4eac1c60d8c71dd5242999255a30beda3925b628ff17a658bf1bfb2ef11cd3e")
      (fetch "${db}/buffer-overflow-cve-2018-13410.patch" "39461c3ffd5fbd2a377779855c9e3e87e30e0db235e41256c6547a752da1f388")
      (fetch "${db}/fix-command-injection.patch" "0905dd62604a4db8d7d9fb2bc228f355e90635fbc32208c21ed72bde1541bdc4")
    ];
  in mkSrcPkg {
    pname = "zip"; version = "3.0";
    src = { url = "https://downloads.sourceforge.net/infozip/zip30.tar.gz";
            sha256 = "f0e8bb1f9b7eb0b01285495a2699df3a4b766784c1765a8f1aeedf63c0806369"; };
    deps = [ world ]; nativeTools = [ gnupatch unzip ] ++ hostTools;   # unzip: zip -T's archive test runs it
    build = ''
      for p in ${builtins.concatStringsSep " " ps}; do patch -p1 < "$p"; done
      sed -i 's/^CC = cc$//' unix/Makefile; sed -i 's/O3/O2/' unix/configure
      gmake -f unix/Makefile generic CC="$CC"
      gmake -f unix/Makefile install prefix="$out" BINDIR="$out/bin" MANDIR="$out/share/man/man1" INSTALL=cp
      # a file deflated into an archive, the archive tested (zip -T runs its own unzip check), listed with zipnote
      printf 'solnix solnix solnix solnix\n' > "$W/a.txt"
      ${chk ''cd "$W" && "$out/bin/zip" -9 t.zip a.txt && "$out/bin/zip" -T t.zip && "$out/bin/zipnote" t.zip'' "^@ a\\.txt$"}
      ${chk ''unzip -p "$W/t.zip" a.txt'' "^solnix solnix solnix solnix$"}
      ${chk ''"$out/bin/zip" -v'' "This is Zip 3\\.0"}
    '';
  };

  # libz (Zlib): Sortix's libz, a cleaned-up zlib 1.2.8 fork with the zlib ABI (libz.so.1, the ZLIB_1.2.x version nodes), as nixpkgs.
  # Its hand-written configure; the link uses -Wl,-soname (illumos ld takes it) and --version-script libz.map. libz.map leaves zlib's
  # core API (inflate, deflate, crc32, ...) unlisted, which GNU ld keeps global in the base version; illumos ld refuses a global with
  # no version once any is versioned ("symbol has no version assigned", measured on woof). So: link once without the script, the
  # shim's convert for the ZLIB_* nodes, and a base node (named for the soname, as illumos' own libs) with every defined global the
  # script does not list, then `local: *` (libz.map's locals and _*). The shared shim stays as it is (it would move every vsMap drv).
  libz = mkSrcPkg {
    pname = "libz"; version = "1.2.8.2025.03.07";
    # gitlab's /-/archive/ URL (the API one's query string is no store name): the same tree, NAR-equal to nixpkgs' hash
    src = { url = "https://gitlab.com/sortix/libz/-/archive/libz-1.2.8.2025.03.07/libz-libz-1.2.8.2025.03.07.tar.gz";
            sha256 = "94aff5a8ec01431fbd94d944dc24b7745ab43eb307a556b3929713a1974360a1"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      grep -q -- '-Wl,-soname,libz.so.1,--version-script,$(srcdir)/libz.map ' Makefile.in || { echo "FATAL: libz link anchor" >&2; exit 1; }
      sed -i 's|-Wl,-soname,libz.so.1,--version-script,$(srcdir)/libz.map |-Wl,-soname,libz.so.1 |' Makefile.in
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static CC="$CC"
      gmake -j8
      nm -P -g libz.so.1.2.8 | awk '$2 !~ /^[Uwv]$/ { print $1 }' | sort > "$W/def"
      "$BASH" ${../version-script-mapfile.sh} convert libz.map "$W/def" > "$W/vers.map"
      tr -s ' \t;{}' '\n' < libz.map | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | grep -vE '^(global|local|ZLIB_[0-9._]+)$' | sort -u > "$W/listed"
      { echo '$mapfile_version 2'; echo 'SYMBOL_VERSION libz.so.1 {'; echo '  global:'; comm -23 "$W/def" "$W/listed" | grep -v '^_' | sed 's/.*/    &;/'
        echo '  local:'; echo '    *;'; echo '};'; tail -n +2 "$W/vers.map"; } > "$W/libz.mapfile"
      rm libz.so.1.2.8; gmake LDFLAGS="-Wl,-M,$W/libz.mapfile"; gmake install
      L="$out/lib/amd64/libz.so.1"
      ${hasVer "$L" "libz\\.so\\.1" "inflate"}
      ${hasVer "$L" "ZLIB_1.2.0" "compressBound"}
      ${hasVer "$L" "ZLIB_1.2.7.1" "inflateGetDictionary"}
      ${notExp "$L" "inflate_fast"}
      ${tprog ''#include <zlib.h>
#include <stdio.h>
#include <string.h>
int main(void){ const char *s = "solnix solnix solnix solnix"; unsigned char z[128], o[128]; uLongf zl = sizeof z, ol = sizeof o;
if (compress2(z, &zl, (const Bytef *)s, strlen(s), 9) != Z_OK || uncompress(o, &ol, z, zl) != Z_OK) return 1;
printf("ok %s %lu %.*s\n", zlibVersion(), crc32(0, (const Bytef *)"123456789", 9), (int)ol, o); return 0; }'' "$L"}
      ${chk ''"$W/t"'' "^ok 1\\.2\\.8\\.f-sortix-libz 3421780262 solnix"}
    '';
  };

  # linenoise (BSD-2-Clause): antirez's small readline replacement. Upstream ships no library build: as nixpkgs, one shared
  # liblinenoise.so (soname liblinenoise.so), its header and nixpkgs' linenoise.pc.
  linenoise = mkSrcPkg {
    pname = "linenoise"; version = "2.0";
    src = { url = "https://codeload.github.com/antirez/linenoise/tar.gz/refs/tags/2.0";
            sha256 = "97ad7d4041e11d7fa395819fd773c1892dea89e5292342378a8345692ce89c29"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      "$CC" -O2 -fPIC -c -o linenoise.o linenoise.c
      "$CC" -shared -Wl,-soname,liblinenoise.so -o liblinenoise.so linenoise.o
      mkdir -p "$out/include" "$out/lib/amd64/pkgconfig"; cp linenoise.h "$out/include/"; cp liblinenoise.so "$out/lib/amd64/"
      printf 'prefix=%s\nexec_prefix=${"$"}{prefix}\nlibdir=${"$"}{exec_prefix}/lib/amd64\nincludedir=${"$"}{prefix}/include\n\nName: linenoise\nDescription: A minimal, zero-config, BSD licensed, readline replacement.\nVersion: 2.0\nLibs: -L${"$"}{libdir} -llinenoise\nCflags: -I${"$"}{includedir}\n' "$out" > "$out/lib/amd64/pkgconfig/linenoise.pc"
      # with stdin not a terminal linenoise reads a plain line; the history API round-trips it
      ${tprog ''#include <linenoise.h>
#include <stdio.h>
#include <stdlib.h>
int main(void){ char *l = linenoise("> "); if (!l) return 1; linenoiseHistoryAdd(l); printf("ok %s %d\n", l, linenoiseHistorySetMaxLen(10)); free(l); return 0; }'' "$out/lib/amd64/liblinenoise.so"}
      ${chk ''echo solnix | "$W/t"'' "^ok solnix 1$"}
      ${chk ''PKG_CONFIG_PATH="$out/lib/amd64/pkgconfig" ${base.pkgconf}/bin/pkg-config --modversion --libs linenoise'' "^2\\.0$"}
    '';
  };

  # rhash (0BSD): the rhash tool and librhash (CRC32, MD5, SHA-1/2/3, BLAKE2/3, TTH, ED2K, ...), as nixpkgs: shared librhash, its
  # headers and .so link, no gettext, no OpenSSL. Its configure's --version-script probe passes through the mapfile shim.
  rhash = mkSrcPkg {
    pname = "rhash"; version = "1.4.6";
    src = { url = "https://codeload.github.com/rhash/RHash/tar.gz/refs/tags/v1.4.6";
            sha256 = "9f6019cfeeae8ace7067ad22da4e4f857bb2cfa6c2deaa2258f55b2227ec937a"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${vsMap}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --mandir="$out/share/man" --sysconfdir="$out/etc" --cc="$CC" --ar=gar \
        --disable-gettext --disable-openssl --disable-static --disable-lib-static --enable-lib-shared
      grep -q -- '--version-script,exports.sym' librhash/config.mak || { echo "FATAL: rhash: no version script (configure's probe)" >&2; exit 1; }
      gmake -j8; gmake install install-lib-headers install-lib-so-link
      L="$out/lib/amd64/librhash.so.1"
      ${notExp "$L" "rhash_sha256_init"}
      ${tprog ''#include <rhash.h>
#include <stdio.h>
int main(void){ unsigned char d[64]; char h[130]; rhash_library_init(); if (rhash_msg(RHASH_SHA256, "abc", 3, d) < 0) return 1;
rhash_print_bytes(h, d, 32, RHPR_HEX); printf("ok %.8s\n", h); return 0; }'' "$L"}
      ${chk ''"$W/t"'' "^ok ba7816bf$"}
      printf abc > "$W/abc"
      ${chk ''"$out/bin/rhash" --sha256 "$W/abc"'' "^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "}
    '';
  };

  # range-v3 (BSL-1.0): Eric Niebler's header-only ranges library for C++14/17. cmake install; tests, examples and docs off (nixpkgs
  # runs its test suite; here the check), and no -march=native (RANGES_NATIVE: a build-host CPU flag in its exported config).
  range-v3 = mkSrcPkg {
    pname = "range-v3"; version = "0.12.0";
    src = { url = "https://codeload.github.com/ericniebler/range-v3/tar.gz/refs/tags/0.12.0";
            sha256 = "015adb2300a98edfceaf0725beec3337f542af4915cec4d0b89fa0886f4ba9cb"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      # FindGit took the build host's /bin/git through cmake's "/" prefix (gate L5); only its release target runs git: off
      ${cmakeB "-DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE -DRANGES_ENABLE_WERROR=OFF -DRANGE_V3_TESTS=OFF -DRANGE_V3_EXAMPLES=OFF -DRANGE_V3_DOCS=OFF -DRANGES_NATIVE=OFF"}
      ! grep -rq 'march=native' "$out/lib" || { echo "FATAL: range-v3's cmake config exports -march=native" >&2; exit 1; }
      cat > "$W/t.cc" <<'TPROG'
#include <range/v3/all.hpp>
#include <iostream>
#include <vector>
int main(){ std::vector<int> v{ 1, 2, 3, 4, 5, 6 }; auto r = v | ranges::views::filter([](int x){ return x % 2 == 0; }) | ranges::views::transform([](int x){ return x * x; });
std::cout << "ok " << ranges::accumulate(r, 0) << " " << ranges::distance(r) << "\n"; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 56 3$"}
    '';
  };

  # plutovg (MIT): a tiny 2D vector graphics library (lunasvg, plutosvg). cmake, shared, examples off, as nixpkgs.
  plutovg = mkSrcPkg {
    pname = "plutovg"; version = "1.3.3";
    src = { url = "https://codeload.github.com/sammycage/plutovg/tar.gz/refs/tags/v1.3.3";
            sha256 = "2b0d17a6e016f47b86f9c00e2cb82600041b1ea1f7d2a00c2d46ae542cbfed3c"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DPLUTOVG_BUILD_EXAMPLES=OFF -DCMAKE_INSTALL_INCLUDEDIR=include"}
      # a red 8x8 rect filled on a 16x16 surface: the pixel inside is opaque red (ARGB32 premultiplied), the one outside clear
      ${tprog ''#include <plutovg/plutovg.h>
#include <stdio.h>
#include <stdint.h>
int main(void){ plutovg_surface_t *s = plutovg_surface_create(16, 16); plutovg_canvas_t *c = plutovg_canvas_create(s); if (!s || !c) return 1;
plutovg_canvas_set_rgb(c, 1, 0, 0); plutovg_canvas_rect(c, 0, 0, 8, 8); plutovg_canvas_fill(c);
const uint32_t *p = (const uint32_t *)plutovg_surface_get_data(s); int st = plutovg_surface_get_stride(s) / 4;
printf("ok %s %08x %08x\n", plutovg_version_string(), p[2 * st + 2], p[12 * st + 12]); plutovg_canvas_destroy(c); plutovg_surface_destroy(s); return 0; }'' "$out/lib/amd64/libplutovg.so"}
      ${chk ''"$W/t"'' "^ok 1\\.3\\.3 ffff0000 00000000$"}
    '';
  };

  # heatshrink (ISC): LZSS compression for embedded systems (prusa-slicer, libbgcode). As nixpkgs: upstream's CMake build commit (static
  # heatshrink + heatshrink_dynalloc libraries, the heatshrink command, a cmake package).
  heatshrink = mkSrcPkg {
    pname = "heatshrink"; version = "0.4.1";
    src = { url = "https://codeload.github.com/atomicobject/heatshrink/tar.gz/refs/tags/v0.4.1";
            sha256 = "7529a1c8ac501191ad470b166773364e66d9926aad632690c72c63a1dea7e9a6"; };
    deps = [ world ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://github.com/atomicobject/heatshrink/commit/0886e9ca76552b8e325841e2b820b4563e5d5aba.patch" "0c6153a1e0e6f4cfdfc68f91b9d8be7296e62b63b6b5688a32e0d68bd3b2e093"}
      ${cmakeB ""}
      printf 'Hello world solnix solnix solnix\n' > "$W/in"
      ${chk ''"$out/bin/heatshrink" -e "$W/in" "$W/in.hs" && "$out/bin/heatshrink" -d "$W/in.hs" "$W/out" && cat "$W/out"'' "^Hello world solnix solnix solnix$"}
      ls "$out/lib/amd64/libheatshrink.a" "$out/lib/amd64/libheatshrink_dynalloc.a" "$out/lib/amd64/cmake/heatshrink/heatshrinkConfig.cmake" > /dev/null
    '';
  };

  # yyjson (MIT): a fast JSON library in ANSI C. cmake, shared (nixpkgs' cmake default is static here: BUILD_SHARED_LIBS unset; the
  # queue's consumers link either), tests off.
  yyjson = mkSrcPkg {
    pname = "yyjson"; version = "0.13.0";
    src = { url = "https://codeload.github.com/ibireme/yyjson/tar.gz/refs/tags/0.13.0";
            sha256 = "34e0f62a2bc11ab20d601e8ca1cc2b2079503aa45119a19133d89d19b94a0fae"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DYYJSON_BUILD_TESTS=OFF"}
      ${tprog ''#include <yyjson.h>
#include <stdio.h>
#include <string.h>
int main(void){ const char *j = "{\"name\":\"solnix\",\"n\":42,\"a\":[1,2,3]}"; yyjson_doc *d = yyjson_read(j, strlen(j), 0); if (!d) return 1;
yyjson_val *r = yyjson_doc_get_root(d); printf("ok %s %s %d %d\n", yyjson_version() == YYJSON_VERSION_HEX ? "0.13.0" : "?", yyjson_get_str(yyjson_obj_get(r, "name")),
 yyjson_get_int(yyjson_obj_get(r, "n")), (int)yyjson_arr_size(yyjson_obj_get(r, "a"))); yyjson_doc_free(d); return 0; }'' "$out/lib/amd64/libyyjson.so"}
      ${chk ''"$W/t"'' "^ok 0\\.13\\.0 solnix 42 3$"}
    '';
  };

  # http-parser (MIT): Node's HTTP/1.x request/response parser in C, as nixpkgs: shared only (its static/shared patch), soname
  # libhttp_parser.so.2.9.
  http-parser = mkSrcPkg {
    pname = "http-parser"; version = "2.9.4";
    src = { url = "https://codeload.github.com/nodejs/http-parser/tar.gz/refs/tags/v2.9.4";
            sha256 = "467b9e30fd0979ee301065e70f637d525c28193449e1b13fbcb1b1fab3ad224f"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/ht/http-parser/enable-static-shared.patch" "3c7299dd7c5395834008dd382832eeead74852f826cde6ccb13be47409052fd1"}
      F="DESTDIR= PREFIX=$out LIBDIR=$out/lib/amd64 BINEXT= PLATFORM=sunos AEXT=a ENABLE_SHARED=1 ENABLE_STATIC=0 SOEXT=so CC=$CC CFLAGS=-Wno-error"
      gmake -j8 $F library; gmake $F install
      ${tprog ''#include <http_parser.h>
#include <stdio.h>
#include <string.h>
static int url(http_parser *p, const char *a, size_t n){ (void)p; printf("url %.*s\n", (int)n, a); return 0; }
int main(void){ const char *r = "GET /solnix?x=1 HTTP/1.1\r\nHost: a\r\n\r\n"; http_parser p; http_parser_settings s; http_parser_settings_init(&s); s.on_url = url;
http_parser_init(&p, HTTP_REQUEST); size_t n = http_parser_execute(&p, &s, r, strlen(r));
printf("ok %d %s %d.%d %lx\n", n == strlen(r), http_method_str(p.method), p.http_major, p.http_minor, http_parser_version()); return 0; }'' "$out/lib/amd64/libhttp_parser.so"}
      ${chk ''"$W/t"'' "^ok 1 GET 1\\.1 20904$"}
    '';
  };

  # re2c (public domain): the lexer generator (and its re2go/re2rust/... aliases), as nixpkgs: autotools from the tag (autoreconf),
  # its bootstrap lexers and parsers (no bison), no docs (the bootstrap man page), python3 for its configure's AM_PATH_PYTHON.
  re2c = mkSrcPkg {
    pname = "re2c"; version = "4.6";
    src = { url = "https://codeload.github.com/skvadrik/re2c/tar.gz/refs/tags/4.6";
            sha256 = "39af7f5ccaa0b7cf8105fa59a02566b52bc8844e59982133165487ffd1cfc6cc"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ [ python3 ] ++ hostTools;
    build = ''
      ${autoreconf}
      # -L gcc.lib: libtool's C++ link would otherwise bake libstdc++.la's dir in as -R (as zimg)
      ./configure --prefix="$out" --disable-docs --disable-benchmarks LDFLAGS="-L$gccLib/amd64"
      gmake -j8; gmake install
      printf '/*!re2c\n  re2c:yyfill:enable = 0; re2c:define:YYCTYPE = char;\n  [a-z]+ { return 1; }\n  * { return 0; }\n*/\n' > "$W/l.re"
      ${chk ''"$out/bin/re2c" --version && "$out/bin/re2c" -o "$W/l.c" "$W/l.re" && grep -c "yych" "$W/l.c"'' "^re2c 4\\.6$"}
      ${chk ''"$out/bin/re2go" --version'' "^re2c 4\\.6$"}
    '';
  };

  # asio (BSL-1.0): the standalone header-only Asio C++ networking library (no Boost), its headers and asio.pc, as nixpkgs (its
  # Boost 1.89 patch; nixpkgs' boost/openssl are check inputs only). Tag tarball: autoreconf. Examples and tests are not built.
  asio = mkSrcPkg {
    pname = "asio"; version = "1.38.0";
    src = { url = "https://codeload.github.com/chriskohlhoff/asio/tar.gz/refs/tags/asio-1-38-0";
            sha256 = "5cf78ede456fd13b95fe692711f4f689be26c826f1f5541c7a1df3aa32bd9dbd"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ [ gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/as/asio/boost-1.89.patch" "e92062b86cbbabb3021cd30e071accb68ec0567f143e6313a1652eaf8407ee3d"}
      ${autoreconf}
      ./configure --prefix="$out" --without-boost --without-openssl
      gmake -C include install; gmake install-data-am
      # a TCP echo over loopback: an acceptor on an ephemeral port, a client writes, the server reads it back
      cat > "$W/t.cc" <<'TPROG'
#include <asio.hpp>
#include <iostream>
#include <thread>
int main(){ asio::io_context io; asio::ip::tcp::acceptor a(io, { asio::ip::make_address("127.0.0.1"), 0 }); auto port = a.local_endpoint().port();
std::thread srv([&]{ auto s = a.accept(); char b[16]; size_t n = s.read_some(asio::buffer(b)); asio::write(s, asio::buffer(b, n)); });
asio::ip::tcp::socket c(io); c.connect({ asio::ip::make_address("127.0.0.1"), port }); asio::write(c, asio::buffer("solnix", 6));
char r[16]; size_t n = asio::read(c, asio::buffer(r, 6)); srv.join(); std::cout << "ok " << ASIO_VERSION << " " << std::string(r, n) << "\n"; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -lsocket -lnsl -o "$W/t"
      ${chk ''"$W/t"'' "^ok 103800 solnix$"}
      ${chk ''PKG_CONFIG_PATH="$out/share/pkgconfig" ${base.pkgconf}/bin/pkg-config --modversion asio'' "^1\\.38\\.0$"}
    '';
  };

  # ---- recipes9 batch 18: libraries and codecs the x86 queue has jobs for ---------------------------------------------------------
  # spirv-headers (MIT): the Khronos SPIR-V headers (spirv.h, spirv.hpp, the grammar JSON) SPIRV-Tools, glslang and Mesa build on, with
  # its cmake package and .pc (both under share/), as nixpkgs. Headers only.
  spirv-headers = mkSrcPkg {
    pname = "spirv-headers"; version = "1.4.363.0";
    src = { url = "https://codeload.github.com/KhronosGroup/SPIRV-Headers/tar.gz/refs/tags/vulkan-sdk-1.4.363.0";
            sha256 = "5b3a0d099f5c7649e29c0938476c462e71d66ad89a0bde42fa1ba3eb476956c9"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DSPIRV_HEADERS_ENABLE_TESTS=OFF"}
      ${tprog ''#include <spirv/unified1/spirv.h>
#include <stdio.h>
int main(void){ printf("ok %x %d %d\n", SPV_VERSION, (int)SpvOpCapability, SpvMagicNumber == 0x07230203u); return 0; }'' ""}
      ${chk ''"$W/t"'' "^ok 10600 17 1$"}
      ls "$out/share/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake" "$out/share/pkgconfig/SPIRV-Headers.pc" > /dev/null
    '';
  };

  # robin-map (MIT): Tessil's header-only open-addressing hash map and set (robin hood hashing), with its cmake package, as nixpkgs.
  robin-map = mkSrcPkg {
    pname = "robin-map"; version = "1.4.1";
    src = { url = "https://codeload.github.com/Tessil/robin-map/tar.gz/refs/tags/v1.4.1";
            sha256 = "0e3f53a377fdcdc5f9fed7a4c0d4f99e82bbb64175233bd13427fef9a771f4a1"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB ""}
      cat > "$W/t.cc" <<'TPROG'
#include <tsl/robin_map.h>
#include <tsl/robin_set.h>
#include <iostream>
int main(){ tsl::robin_map<int, int> m; for (int i = 0; i < 100; i++) m[i] = i * i; m.erase(7); tsl::robin_set<int> s{ 1, 2, 2, 3 };
std::cout << "ok " << m.size() << " " << m.at(42) << " " << m.count(7) << " " << s.size() << "\n"; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 99 1764 0 3$"}
      ls "$out/share/cmake/tsl-robin-map/tsl-robin-mapConfig.cmake" > /dev/null
    '';
  };

  # cmark (BSD-2-Clause): the CommonMark reference parser, libcmark (shared) and the cmark command, as nixpkgs (CMARK_STATIC=OFF).
  cmark = mkSrcPkg {
    pname = "cmark"; version = "0.31.2";
    src = { url = "https://codeload.github.com/commonmark/cmark/tar.gz/refs/tags/0.31.2";
            sha256 = "f9bc5ca38bcb0b727f0056100fac4d743e768872e3bacec7746de28f5700d697"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DCMARK_STATIC=OFF -DBUILD_TESTING=OFF"}
      ${tprog ''#include <cmark.h>
#include <stdio.h>
#include <string.h>
int main(void){ const char *m = "# Hi *solnix*\n"; char *h = cmark_markdown_to_html(m, strlen(m), CMARK_OPT_DEFAULT); printf("ok %s %s", cmark_version_string(), h); return 0; }'' "$out/lib/amd64/libcmark.so"}
      ${chk ''"$W/t"'' "^ok 0\\.31\\.2 <h1>Hi <em>solnix</em></h1>$"}
      ${chk ''printf '%s\n' '**solnix**' | "$out/bin/cmark"'' "^<p><strong>solnix</strong></p>$"}
    '';
  };

  # argtable (BSD-3-Clause): argtable3, ANSI C command-line parsing (getopt-style tables). cmake, shared, as nixpkgs; tests and examples off.
  argtable = mkSrcPkg {
    pname = "argtable"; version = "3.3.1";
    src = { url = "https://codeload.github.com/argtable/argtable3/tar.gz/refs/tags/v3.3.1";
            sha256 = "8b28a4fb2cd621d8d16f34e30e1956aa488077f6a6b902e7fc9f07883e1519c1"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DARGTABLE3_ENABLE_TESTS=OFF -DARGTABLE3_ENABLE_EXAMPLES=OFF"}
      ${tprog ''#include <argtable3.h>
#include <stdio.h>
int main(void){ arg_int_t *n = arg_int1("n", "num", "<n>", "a number"); arg_lit_t *v = arg_lit0("v", "verbose", "verbose"); arg_end_t *e = arg_end(5);
void *t[] = { n, v, e }; char *a[] = { "t", "-n", "42", "--verbose", NULL }; int err = arg_parse(4, a, t);
printf("ok %d %d %d\n", err, n->ival[0], v->count); arg_freetable(t, 3); return 0; }'' "$out/lib/amd64/libargtable3.so"}
      ${chk ''"$W/t"'' "^ok 0 42 1$"}
    '';
  };

  # nbytes (MIT): Node.js's byte-handling helpers (base64, hex, byte swaps) as a library. cmake, shared, as nixpkgs; its gtest tests off.
  nbytes = mkSrcPkg {
    pname = "nbytes"; version = "0.1.4";
    src = { url = "https://codeload.github.com/nodejs/nbytes/tar.gz/refs/tags/v0.1.4";
            sha256 = "67f4b8363f12abb64c07a0cecf2bf2dce7ab47b5f8b9fd2efdb852ea254c2d40"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DNBYTES_ENABLE_TESTING=OFF -DBUILD_TESTING=OFF"}
      cat > "$W/t.cc" <<'TPROG'
#include <nbytes.h>
#include <iostream>
#include <string>
int main(){ char d[16]; size_t n = nbytes::Base64Decode(d, sizeof d, "c29sbml4", 8); char s[4] = { 1, 2, 3, 4 }; bool ok = nbytes::SwapBytes16(s, 4);
std::cout << "ok " << n << " " << std::string(d, n) << " " << ok << int(s[0]) << int(s[1]) << "\n"; }
TPROG
      "$CXX" -std=c++20 -I"$out/include" "$W/t.cc" "$out/lib/amd64/libnbytes.so" -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 6 solnix 121$"}
    '';
  };

  # uvwasi (MIT): the WASI syscall layer on libuv (Node.js's wasi module), on c-recipes3's libuv, with nixpkgs' two upstream patches
  # (a shared-library switch and a pkg-config file that names libuv). Its FindLIBUV takes the store libuv (storePrefix; asserted), not
  # its FetchContent fallback.
  uvwasi = mkSrcPkg {
    pname = "uvwasi"; version = "0.0.23";
    src = { url = "https://codeload.github.com/nodejs/uvwasi/tar.gz/refs/tags/v0.0.23";
            sha256 = "cdb148aac298883b51da887657deca910c7c02f35435e24f125cef536fe8d5e1"; };
    deps = [ world libuv ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://github.com/nodejs/uvwasi/commit/0820128569533c855d60c0f6382acbb14aa62ad2.patch?full_index=1" "f2c75bc05e2fd450a51c51757c62dff25536acac7aecec89b261e74138da5505"}
      patch -p1 < ${fetch "https://github.com/nodejs/uvwasi/commit/fe602a6911207efd8dcfc070a752bcf76813c978.patch?full_index=1" "617d09903f04bc0d7f0fd31dfaaecefc822952ce950b088b3ffc79b773d48633"}
      ${cmakeB "-DUVWASI_BUILD_SHARED=ON -DBUILD_TESTING=OFF ${storePrefix}"}
      grep -q "^LIBUV_LIBRARIES:FILEPATH=${libuv}/lib/amd64/" _b/CMakeCache.txt || { echo "FATAL: uvwasi: not the store libuv" >&2; grep LIBUV _b/CMakeCache.txt >&2; exit 1; }
      ${tprog ''#include <uvwasi.h>
#include <stdio.h>
int main(void){ uvwasi_t u; uvwasi_options_t o; uvwasi_options_init(&o); const char *av[] = { "a", "solnix" }; o.argc = 2; o.argv = av;
if (uvwasi_init(&u, &o) != UVWASI_ESUCCESS) return 1; uvwasi_size_t c = 0, s = 0; uvwasi_args_sizes_get(&u, &c, &s);
printf("ok %s %u %u\n", UVWASI_VERSION_STRING, (unsigned)c, (unsigned)s); uvwasi_destroy(&u); return 0; }'' "$out/lib/amd64/libuvwasi.so"}
      ${chk ''"$W/t"'' "^ok 0\\.0\\.23 2 9$"}
    '';
  };

  # openapv (BSD-3-Clause): the Advanced Professional Video (APV) codec library and its oapv_app_enc/dec, as nixpkgs (its os-release
  # patch touches only the Linux CPack branch). A short encode and decode of upstream's own 10-bit 4:2:2 test sequence.
  openapv = mkSrcPkg {
    pname = "openapv"; version = "1.1.3.0";
    src = { url = "https://codeload.github.com/AcademySoftwareFoundation/openapv/tar.gz/refs/tags/v1.1.3.0";
            sha256 = "38f841ce44e80c40b682a5323b4f3ebc6e339b6071965bc1c705a17d46ab2fc8"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      # its apps' clock is gettimeofday on Linux/Cygwin/Apple and #error elsewhere: illumos has it too
      grep -qx '#elif __linux__ || __CYGWIN__ || __APPLE__' app/oapv_app_util.h || { echo "FATAL: openapv clock anchor" >&2; exit 1; }
      sed -i 's/^#elif __linux__ || __CYGWIN__ || __APPLE__$/#elif __linux__ || __CYGWIN__ || __APPLE__ || __sun/' app/oapv_app_util.h
      ${cmakeB "-DENABLE_TESTS=OFF"}
      ${tprog ''#include <oapv/oapv.h>
#include <stdio.h>
int main(void){ unsigned v = 0; printf("ok %s\n", oapv_version(&v)); return 0; }'' "$out/lib/amd64/liboapv.so"}
      ${chk ''"$W/t"'' "^ok 1\\.1\\.3\\.0$"}
      ${chk ''"$out/bin/oapv_app_enc" -i test/sequence/pattern1_yuv422p10le_320x240_25fps.y4m -w 320 -h 240 -z 25 --max-au 5 -o "$W/t.apv" && "$out/bin/oapv_app_dec" -i "$W/t.apv"'' "Decoded frame count += 5$"}
    '';
  };

  # uavs3d (BSD-3-Clause): the AVS3 video decoder library, 10-bit, shared, as nixpkgs (its cmake_minimum_required bump: cmake 4 refuses
  # < 3.5). Its version.sh counts git revisions into version.h; with no git and no repository (as a nixpkgs build) that is 0 and an
  # empty SHA: pinned to that. Its libdir is a literal "lib": lib/amd64.
  uavs3d = mkSrcPkg {
    pname = "uavs3d"; version = "1.2";
    src = { url = "https://codeload.github.com/uavs3/uavs3d/tar.gz/refs/tags/1.2";
            sha256 = "faa1f1f82badc0603d9944bb5af7b961dd42236e2c3a7aa8fcfc080bbeb5b157"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      grep -qx 'cmake_minimum_required(VERSION 3.1)' CMakeLists.txt && grep -qx 'set(libdir "lib")' source/CMakeLists.txt && grep -q '^VER_L=`git' version.sh \
        || { echo "FATAL: uavs3d anchors" >&2; exit 1; }
      sed -i 's/^cmake_minimum_required(VERSION 3.1)$/cmake_minimum_required(VERSION 3.10)/' CMakeLists.txt
      sed -i 's|^set(libdir "lib")$|set(libdir "lib/amd64")|' source/CMakeLists.txt
      sed -i -e 's/^VER_R=.*/VER_R=0/' -e 's/^VER_L=.*/VER_L=0/' -e 's/^VER_SHA1=.*/VER_SHA1=/' version.sh
      ${cmakeB "-DCOMPILE_10BIT=ON -DBUILD_SHARED_LIBS=ON"}
      ${tprog ''#include <uavs3d.h>
#include <stdio.h>
static void cb(uavs3d_io_frm_t *f){ (void)f; }
int main(void){ uavs3d_cfg_t c = { 0 }; c.frm_threads = 1; int err = 0; void *h = uavs3d_create(&c, cb, &err); printf("ok %d %d\n", h != NULL, err); if (h) uavs3d_delete(h); return 0; }'' "$out/lib/amd64/libuavs3d.so -lm"}
      ${chk ''"$W/t"'' "^ok 1 0$"}
      ${chk ''"$W/t"'' "^libuavs3d\\(10\\): 1\\.2\\.0_release, $"}
    '';
  };

  # vo-amrwbenc (Apache-2.0): VisualOn's AMR-WB speech encoder (ffmpeg's libvo-amrwbenc), as nixpkgs: autotools from the tag.
  vo-amrwbenc = mkSrcPkg {
    pname = "vo-amrwbenc"; version = "0.1.3";
    src = { url = "https://codeload.github.com/mstorsjo/vo-amrwbenc/tar.gz/refs/tags/v0.1.3";
            sha256 = "85c79997ba7ddb9c95b5ddbe9ea032e27595390f3cbd686ed46a69e485cc053c"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j8; gmake install
      # one 20 ms frame of a tone at 23.85 kbit/s (mode 8): an RFC 3267 frame of 61 bytes whose header byte is 0x44
      ${tprog ''#include <vo-amrwbenc/enc_if.h>
#include <stdio.h>
#include <math.h>
int main(void){ short s[320]; unsigned char f[128]; for (int i = 0; i < 320; i++) s[i] = (short)(8000 * sin(i * 0.2));
void *e = E_IF_init(); int n = E_IF_encode(e, 8, s, f, 0); E_IF_exit(e); printf("ok %d %02x\n", n, f[0]); return 0; }'' "$out/lib/amd64/libvo-amrwbenc.so -lm"}
      ${chk ''"$W/t"'' "^ok 61 44$"}
    '';
  };

  # libargon2 (Apache-2.0 / CC0-1.0): the Argon2 password hash (the PHC winner), its library and the argon2 command, nixpkgs' patch and
  # flags with lib/amd64. Upstream's SunOS branch forces CC := gcc and builds an unversioned libargon2.so with every symbol exported:
  # these give it Linux's (libargon2.so.1, its soname, the API alone exported). OPTTARGET=native would tune for the build host
  # (nixpkgs' cc-wrapper strips -march=native): the x86-64 baseline, so opt.c's SSE2 path, as there.
  libargon2 = mkSrcPkg {
    pname = "libargon2"; version = "20190702";
    src = { url = "https://codeload.github.com/P-H-C/phc-winner-argon2/tar.gz/refs/tags/20190702";
            sha256 = "daf972a89577f8772602bf2eb38b6a3dd3d922bf5724d45e7f9589b5e830442c"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://github.com/P-H-C/phc-winner-argon2/commit/cd1c1d8d204e4ec4557e358013567c097cb70562.patch" "b8ea6b730ae8f192d7c9160e1f5612d9844188fbf70807752cd73b70366e4222"}
      F=(CC="$CC" AR=ar PREFIX="$out" ARGON2_VERSION=20190702 LIBRARY_REL=lib/amd64 PKGCONFIG_REL=lib/amd64 OPTTARGET=x86-64
         LIB_EXT=so.1 LINKED_LIB_EXT=so "LIB_CFLAGS=-shared -fPIC -fvisibility=hidden -DA2_VISCTL=1" "SO_LDFLAGS=-Wl,-soname,libargon2.so.1")
      gmake -j8 "''${F[@]}"; gmake "''${F[@]}" install
      # the README's example (argon2i, t=2, m=2^16 KiB, p=4) through the command and through the shared library
      ${chk ''printf password | "$out/bin/argon2" somesalt -t 2 -m 16 -p 4 -l 24'' "^Hash:[[:space:]]+45d7ac72e76f242b20b77b9bf9bf9d5915894e669a24e6c6$"}
      ${tprog ''#include <argon2.h>
#include <stdio.h>
int main(void){ unsigned char h[24]; int r = argon2i_hash_raw(2, 1 << 16, 4, "password", 8, "somesalt", 8, h, 24); printf("ok %d ", r);
for (int i = 0; i < 24; i++) printf("%02x", h[i]); printf("\n"); return 0; }'' "$out/lib/amd64/libargon2.so"}
      ${chk ''"$W/t"'' "^ok 0 45d7ac72e76f242b20b77b9bf9bf9d5915894e669a24e6c6$"}
      ${notExp "$out/lib/amd64/libargon2.so.1" "fill_memory_blocks"}
    '';
  };

  # fstrm (Apache-2.0): Frame Streams, the framed data transport dnstap uses, libfstrm and its fstrm_capture/dump/replay tools (on the
  # base libevent), as nixpkgs: autotools from the tag. Its --version-script goes through the mapfile shim (LIBFSTRM_0.2.0/0.4.0 nodes).
  fstrm = mkSrcPkg {
    pname = "fstrm"; version = "0.6.1";
    src = { url = "https://codeload.github.com/farsightsec/fstrm/tar.gz/refs/tags/v0.6.1";
            sha256 = "4f0f7ad2b760119c441aba58271e84de683b3cc138530d02710896641866e2d2"; };
    deps = [ world base.libevent ]; nativeTools = autoreconfTools ++ [ base.pkgconf ] ++ hostTools;
    build = ''
      ${vsMap}
      ${autoreconf}
      # gnulib's probe links a program with two nodes naming one undefined `sym`: illumos ld (and the shim) refuse it, so it says no and
      # libtool exports by regex, unversioned. The library's own script converts: take it.
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-ld-version-script
      gmake -j8; gmake install
      L="$out/lib/amd64/libfstrm.so"
      ${hasVer "$L" "LIBFSTRM_0.2.0" "fstrm_writer_write"}
      ${hasVer "$L" "LIBFSTRM_0.4.0" "fstrm_tcp_writer_init"}
      ${notExp "$L" "my_queue_mb_init"}
      # three frames written to a file in the build dir and read back, then the same file through fstrm_dump
      ${tprog ''#include <fstrm.h>
#include <stdio.h>
int main(int c, char **v){ (void)c; struct fstrm_file_options *fo = fstrm_file_options_init(); fstrm_file_options_set_file_path(fo, v[1]);
struct fstrm_writer_options *wo = fstrm_writer_options_init(); fstrm_writer_options_add_content_type(wo, "solnix", 6);
struct fstrm_writer *w = fstrm_file_writer_init(fo, wo); if (!w) return 1;
for (int i = 0; i < 3; i++) if (fstrm_writer_write(w, "frame", 5) != fstrm_res_success) return 2; fstrm_writer_destroy(&w);
struct fstrm_reader *r = fstrm_file_reader_init(fo, NULL); const uint8_t *d; size_t n; int k = 0, t = 0; if (!r) return 3;
while (fstrm_reader_read(r, &d, &n) == fstrm_res_success) { k++; t += (int)n; } fstrm_reader_destroy(&r); printf("ok %d %d\n", k, t); return 0; }'' "$L"}
      ${chk ''"$W/t" "$W/t.fstrm"'' "^ok 3 15$"}
      ${chk ''"$out/bin/fstrm_dump" "$W/t.fstrm"'' "^Data frame \\(5\\) bytes\\.$"}
    '';
  };

  # libexttextcat (BSD-3-Clause): LibreOffice's N-gram text language classifier and its language fingerprints, as nixpkgs.
  libexttextcat = mkSrcPkg {
    pname = "libexttextcat"; version = "3.4.8";
    src = { url = "https://dev-www.libreoffice.org/src/libexttextcat/libexttextcat-3.4.8.tar.xz";
            sha256 = "93eb89fd4fc8f565806354e100e778b3ac9a24e5fc04c24e6a83fb1e9b6c9d59"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j8; gmake install
      # the shipped English sample text (the UDHR) against the installed fingerprints
      ${tprog ''#include <libexttextcat/textcat.h>
#include <stdio.h>
int main(int c, char **v){ (void)c; void *h = special_textcat_Init(v[1], v[2]); if (!h) return 1; static char b[4096]; FILE *f = fopen(v[3], "rb"); if (!f) return 2;
size_t n = fread(b, 1, sizeof b - 1, f); fclose(f); printf("ok %s %s\n", textcat_Version(), textcat_Classify(h, b, n)); textcat_Done(h); return 0; }'' "$out/lib/amd64/libexttextcat-2.0.so"}
      ${chk ''"$W/t" "$out/share/libexttextcat/fpdb.conf" "$out/share/libexttextcat/" "$SRC/langclass/ShortTexts/en.txt"'' "^ok 3\\.4\\.8 \\[en--utf8\\]"}
    '';
  };

  # libxshmfence (HPND-sell-variant): X.Org's shared-memory fences (Mesa's DRI3 and the X server). configure picks the first of
  # /run/shm /dev/shm /var/tmp /tmp that exists ON THE BUILD HOST as its fence-file directory, and illumos has no memfd_create or
  # O_TMPFILE, so every fence is a mkostemp file there: illumos' tmpfs, pinned. No futexes on illumos: its pthread fences.
  libxshmfence = mkSrcPkg {
    pname = "libxshmfence"; version = "1.3.3";
    src = { url = "https://xorg.freedesktop.org/releases/individual/lib/libxshmfence-1.3.3.tar.xz";
            sha256 = "d4a4df096aba96fea02c029ee3a44e11a47eb7f7213c1a729be83e85ec3fde10"; };
    deps = [ world ]; linkDeps = [ base.xorgproto ]; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --with-shared-memory-dir=/tmp
      grep -qx '#define SHMDIR "/tmp"' config.h && grep -qx '#define HAVE_PTHREAD 1' config.h || { echo "FATAL: libxshmfence config.h" >&2; exit 1; }
      gmake -j8; gmake install
      # the fence logic on a zero-filled file in the build dir (an all-zero mutex and condvar are the default ones on illumos), so the
      # check makes nothing in /tmp: query 0, trigger, query 1, reset, query 0
      ${tprog ''#include <X11/xshmfence.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
int main(int c, char **v){ (void)c; int fd = open(v[1], O_RDWR | O_CREAT | O_TRUNC, 0600); if (fd < 0 || ftruncate(fd, 4096)) return 1;
struct xshmfence *f = xshmfence_map_shm(fd); if (!f) return 2; int a = xshmfence_query(f); xshmfence_trigger(f); int b = xshmfence_query(f);
xshmfence_reset(f); printf("ok %d %d %d\n", a, b, xshmfence_query(f)); xshmfence_unmap_shm(f); return 0; }'' "$out/lib/amd64/libxshmfence.so"}
      ${chk ''"$W/t" "$W/fence"'' "^ok 0 1 0$"}
    '';
  };

  # cfitsio (CFITSIO, a permissive NASA license): the FITS file library and its fpack/funpack/fitscopy/fitsverify/imcopy tools, nixpkgs'
  # patch and flags (pthreads, bzip2, curl for remote files) on the nix chain's bzip2 and curl and the base zlib; as nixpkgs, the cookbook,
  # smem and speed programs are not shipped. The finds are pinned to the store (storePrefix, store pkg-config) and asserted.
  cfitsio = mkSrcPkg {
    pname = "cfitsio"; version = "4.7.0";
    src = { url = "https://codeload.github.com/HEASARC/cfitsio/tar.gz/refs/tags/cfitsio-4.7.0";
            sha256 = "f281ca292407d8682e83a37ea68fce6e1383d2449d923647ea62fa0570c59aee"; };
    deps = [ world zlib base.nixChain.bzip2 base.nixChain.curl ]; nativeTools = [ cmake gnupatch base.pkgconf ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://github.com/heasarc/cfitsio/commit/113781d8aa442cf8d3c27295d9084674b8b039f2.patch" "82e22f654309e7b752d39ead7a05e1fc59a2ac188b5c710a6d61c548be11892a"}
      ${cmakeB "-DUSE_PTHREADS=ON -DTESTS=ON -DUTILS=ON -DUSE_BZIP2=ON ${storePrefix}"}
      for p in ZLIB:${zlib} BZIP2:${base.nixChain.bzip2} CURL:${base.nixChain.curl}; do
        grep -q "^''${p%%:*}_[A-Z_]*:[A-Z]*=''${p#*:}/" _b/CMakeCache.txt || { echo "FATAL: cfitsio: ''${p%%:*} not from the store" >&2; grep -E '^(ZLIB|BZIP2|CURL)_' _b/CMakeCache.txt >&2; exit 1; }
      done
      # upstream's own test: TestProg writes testprog.fit and a listing, compared with the shipped testprog.out and testprog.std
      ${chk ''cd _b && ./TestProg > testprog.lis && diff testprog.lis ../testprog.out && cmp testprog.fit ../testprog.std && echo testprog-same'' "^testprog-same$"}
      ${chk ''"$out/bin/fitsverify" _b/testprog.fit'' "0 error"}
      find "$out/bin/cookbook" "$out/bin/smem" "$out/bin/speed" -delete
    '';
  };

  # verdict (BSD-3-Clause): Sandia's mesh element quality metrics (VTK, ParaView). The queue's 1.4.4 (nixpkgs is at 1.4.5), cmake,
  # static as nixpkgs' default; its gtest unit tests off.
  verdict = mkSrcPkg {
    pname = "verdict"; version = "1.4.4";
    src = { url = "https://codeload.github.com/sandialabs/verdict/tar.gz/refs/tags/1.4.4";
            sha256 = "d12d1cd41c6568997df348a72cc2973a662fae1b3634a068ea2201b5f7383186"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DVERDICT_ENABLE_TESTING=OFF"}
      cat > "$W/t.cc" <<'TPROG'
#include <verdict.h>
#include <cstdio>
int main(){ double t[4][3] = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }; double q[4][3] = { { 0, 0, 0 }, { 2, 0, 0 }, { 2, 3, 0 }, { 0, 3, 0 } };
std::printf("ok %.6f %.3f\n", verdict::tet_volume(4, t), verdict::quad_area(4, q)); }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" "$out/lib/amd64/libverdict.a" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 0\\.166667 6\\.000$"}
    '';
  };

  # liblc3 (Apache-2.0): Google's LC3 (Bluetooth LE Audio) codec. meson, as nixpkgs (tools and python off).
  liblc3 = mkSrcPkg {
    pname = "liblc3"; version = "1.1.3";
    src = { url = "https://codeload.github.com/google/liblc3/tar.gz/refs/tags/v1.1.3";
            sha256 = "276752ff54ce6a77d54ec133397b9d7e71f90caf3d9afa32d8b0e891b8ecb8af"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild ""}
      # one 10 ms 48 kHz frame of a tone at 64 kbit/s (480 samples, 80 bytes) encoded and decoded back
      ${tprog ''#include <lc3.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
int main(void){ int ns = lc3_frame_samples(10000, 48000), nb = lc3_frame_bytes(10000, 64000); int16_t p[480], o[480]; uint8_t f[400];
for (int i = 0; i < 480; i++) p[i] = (int16_t)(8000 * sin(i * 0.1));
lc3_encoder_t e = lc3_setup_encoder(10000, 48000, 0, malloc(lc3_encoder_size(10000, 48000))); lc3_decoder_t d = lc3_setup_decoder(10000, 48000, 0, malloc(lc3_decoder_size(10000, 48000)));
int re = lc3_encode(e, LC3_PCM_FORMAT_S16, p, 1, nb, f), rd = lc3_decode(d, f, nb, LC3_PCM_FORMAT_S16, o, 1); printf("ok %d %d %d %d\n", ns, nb, re, rd); return 0; }'' "$out/lib/amd64/liblc3.so -lm"}
      ${chk ''"$W/t"'' "^ok 480 80 0 0$"}
    '';
  };

  # libspnav (BSD-3-Clause): the spacenavd client library for 6-DoF input devices, with its X11 (Magellan) path on the X.Org libs, as
  # nixpkgs (--disable-debug). Its hand-written configure: lib/amd64 for its literal "lib", the version pinned (it asks git, then greps
  # the directory name), and the Makefile's /usr/local, /usr/X11R6 and /opt/homebrew -I/-L dirs dropped (host dirs). -std=c89 hides
  # the socket and select declarations on illumos: -D__EXTENSIONS__. The check stays off spnav_open (it reads /etc/spnavrc and connects
  # to /var/run/spnav.sock): the motion helpers and the protocol state.
  libspnav = mkSrcPkg {
    pname = "libspnav"; version = "1.2";
    src = { url = "https://codeload.github.com/FreeSpacenav/libspnav/tar.gz/refs/tags/v1.2";
            sha256 = "e675a2476bd407b8d97a33f93c6651ad3ecdfd422916f260bd620f2aec7ca45f"; };
    deps = [ world libx11 ]; linkDeps = [ base.xorgproto libxcb libxau libxdmcp ]; nativeTools = hostTools;
    build = ''
      grep -q '^VER=`git describe --tags 2>/dev/null`$' configure && grep -q '^incpaths = -I\. -I/usr/local/include' Makefile.in \
        && grep -q '^libpaths = -L/usr/local/lib' Makefile.in || { echo "FATAL: libspnav anchors" >&2; exit 1; }
      sed -i 's|^VER=`git describe --tags 2>/dev/null`$|VER=v1.2|' configure
      sed -i -e 's|^incpaths = .*|incpaths = -I.|' -e 's|^libpaths = .*|libpaths =|' Makefile.in
      CFLAGS=-D__EXTENSIONS__ ./configure --prefix="$out" --disable-debug
      # libdir on the make line (configure's .pc sed cannot take a slash in it), then the .pc's -L
      gmake -j8 CC="$CC" AR=ar libdir=lib/amd64; gmake install CC="$CC" AR=ar libdir=lib/amd64
      sed -i 's|^Libs: -L\''${PREFIX}/lib -lspnav$|Libs: -L\''${PREFIX}/lib/amd64 -lspnav|' "$out/share/pkgconfig/spnav.pc"
      grep -qx 'Version: 1.2' "$out/share/pkgconfig/spnav.pc" && grep -qx 'Libs: -L\''${PREFIX}/lib/amd64 -lspnav' "$out/share/pkgconfig/spnav.pc" \
        || { echo "FATAL: libspnav: spnav.pc" >&2; cat "$out/share/pkgconfig/spnav.pc" >&2; exit 1; }
      ${tprog ''#include <spnav.h>
#include <stdio.h>
int main(void){ struct spnav_posrot p; struct spnav_event_motion m = { 0 }; spnav_posrot_init(&p); m.type = SPNAV_EVENT_MOTION; m.x = 1000; m.z = 500;
spnav_posrot_moveobj(&p, &m); printf("ok %.3f %.3f %.3f %.3f %d\n", p.pos[0], p.pos[1], p.pos[2], p.rot[3], spnav_protocol()); return 0; }'' "$out/lib/amd64/libspnav.so"}
      ${chk ''"$W/t"'' "^ok 1\\.000 0\\.000 -0\\.500 1\\.000 0$"}
    '';
  };

  # libvpx (BSD-3-Clause): the VP8/VP9 codec library and vpxenc/vpxdec, nixpkgs' configure flags (vp8 + vp9, shared, high bit depth,
  # webm io, libyuv, yasm asm with run-time CPU detection) on its own x86_64-solaris-gcc target (configure only guesses Solaris 10).
  # Its Solaris branch names gcc and g-prefixed binutils: the build's compiler (also the linker) and GNU binutils by plain name. Its
  # shared link uses --version-script: the mapfile shim.
  libvpx = mkSrcPkg {
    pname = "libvpx"; version = "1.17.0";
    src = { url = "https://codeload.github.com/webmproject/libvpx/tar.gz/refs/tags/v1.17.0";
            sha256 = "1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a"; };
    deps = [ world ]; nativeTools = [ perl yasm base.diffutils gtkMeson.gtkTools ] ++ hostTools;   # configure insists on `diff --version`
    build = ''
      ${vsMap}
      AR=ar NM=nm STRIP=strip AS=yasm LD="$CC" CXX="$CXX" CC="$CC" "$BASH" ./configure --target=x86_64-solaris-gcc --prefix="$out" --libdir="$out/lib/amd64" \
        --enable-vp8 --enable-vp8-encoder --enable-vp8-decoder --enable-vp9 --enable-vp9-encoder --enable-vp9-decoder --disable-extra-warnings \
        --disable-werror --disable-install-docs --enable-install-bins --enable-install-libs --disable-install-srcs --disable-debug --disable-gprof \
        --disable-gcov --enable-pic --enable-optimizations --enable-runtime-cpu-detect --disable-thumb --enable-libs --enable-examples --disable-docs \
        --as=yasm --size-limit=5120x3200 --disable-codec-srcs --disable-debug-libs --disable-dequant-tokens --disable-dc-recon --enable-postproc \
        --enable-vp9-postproc --enable-multithread --disable-internal-stats --enable-spatial-resampling --disable-realtime-only \
        --disable-onthefly-bitpacking --disable-error-concealment --enable-shared --disable-small --disable-postproc-visualizer --disable-unit-tests \
        --enable-webm-io --enable-libyuv --disable-decode-perf-tests --disable-encode-perf-tests --disable-multi-res-encoding \
        --enable-temporal-denoising --enable-vp9-temporal-denoising --disable-coefficient-range-checking --enable-vp9-highbitdepth --disable-experimental
      gmake -j8; gmake install
      ${tprog ''#include <vpx/vpx_decoder.h>
#include <vpx/vp8dx.h>
#include <stdio.h>
int main(void){ vpx_codec_ctx_t c; int r = vpx_codec_dec_init(&c, vpx_codec_vp9_dx(), NULL, 0); printf("ok %s %d\n", vpx_codec_version_str(), r); vpx_codec_destroy(&c); return 0; }'' "$out/lib/amd64/libvpx.so"}
      ${chk ''"$W/t"'' "^ok v1\\.17\\.0 0$"}
      ${notExp "$out/lib/amd64/libvpx.so" "vp9_setup_past_independence"}
      # four flat 64x64 I420 frames through vpxenc (VP9, IVF) and back through vpxdec
      perl -e 'print chr(128) x (64 * 64 * 3 / 2 * 4)' > "$W/in.yuv"
      ${chk ''"$out/bin/vpxenc" --codec=vp9 -w 64 -h 64 --limit=4 --ivf -o "$W/t.ivf" "$W/in.yuv" && "$out/bin/vpxdec" --noblit --summary "$W/t.ivf"'' "4 decoded frames/4 showed frames"}
    '';
  };

  # svt-av1 (BSD-3-Clause + the AOM patent license): the Scalable Video Technology AV1 encoder library and SvtAv1EncApp, nasm asm, as
  # nixpkgs (LTO on). -fstack-protector-strong NEEDs libssp, which gcc.lib does not ship (as cjson): off. Its version header script
  # (cmake -P at build time) runs find_package(Git), which would take the build host's /bin/git through cmake's "/" prefix: off (with
  # no .git in the tarball the version is "v4.1.0" either way). Its EXE linker flags "-z noexecstack -z relro -z now" are GNU ld
  # spellings: illumos ld rejects the first two ("option -z has illegal argument"; illumos stacks are non-executable by default on
  # amd64), and every cmake compile probe links with them, so all failed (no -Wall, no Threads): -z now alone. Not EXCLUDE_HASH: it
  # adds -Wl,--build-id=none, also GNU only.
  svt-av1 = mkSrcPkg {
    pname = "svt-av1"; version = "4.1.0";
    src = { url = "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.1.0/SVT-AV1-v4.1.0.tar.gz";
            sha256 = "6c4c0c44ff0ba3d136d6f57f3a707f9de8e9c866f50f809c1d22a43f0d8c9583"; };
    deps = [ world ]; nativeTools = [ cmake nasm perl ] ++ hostTools;
    build = ''
      grep -qx '        check_both_flags_add(-fstack-protector-strong)' CMakeLists.txt || { echo "FATAL: svt-av1 ssp anchor" >&2; exit 1; }
      sed -i '/^        check_both_flags_add(-fstack-protector-strong)$/d' CMakeLists.txt
      grep -qx 'find_package(Git QUIET)' Source/Lib/Codec/ConfigureGitVersion.cmake || { echo "FATAL: svt-av1 git anchor" >&2; exit 1; }
      sed -i 's/^find_package(Git QUIET)$/set(Git_FOUND FALSE)/' Source/Lib/Codec/ConfigureGitVersion.cmake
      grep -q ' -z noexecstack -z relro -z now")$' CMakeLists.txt || { echo "FATAL: svt-av1 ld flags anchor" >&2; exit 1; }
      sed -i 's/ -z noexecstack -z relro -z now")$/ -z now")/' CMakeLists.txt
      # illumos <sys/file.h> (app_config.c includes it after app_config.h, for flock) defines FOPEN, a kernel file flag, over the app's
      # FOPEN(f, s, m) macro: the app's is renamed (the library's own FOPEN is in Source/Lib, which does not include sys/file.h)
      [ "$(grep -c 'FOPEN(' Source/App/app_config.c Source/App/app_config.h | tr '\n' ' ')" = "Source/App/app_config.c:5 Source/App/app_config.h:2 " ] \
        || { echo "FATAL: svt-av1 FOPEN anchor" >&2; exit 1; }
      sed -i 's/\bFOPEN(/SVT_APP_FOPEN(/g' Source/App/app_config.c Source/App/app_config.h
      # a size-0 EB_MALLOC_ALIGNED (pic_buffer_desc.c asks for one): illumos posix_memalign returns 0 and NULL for it (POSIX allows that;
      # glibc returns a unique pointer), which svt-av1 reports as a failed allocation, and the encoder then segfaults: at least 1 byte
      f=Source/Lib/Codec/svt_malloc.h
      [ "$(grep -c 'if (posix_memalign((void\*\*)&(pointer), ALVALUE, size) != 0) \\$' $f)" = 1 ] || { echo "FATAL: svt-av1 memalign anchor" >&2; exit 1; }
      sed -i 's/if (posix_memalign((void\*\*)&(pointer), ALVALUE, size) != 0) \\$/if (posix_memalign((void**)\&(pointer), ALVALUE, (size) ? (size) : 1) != 0) \\/' $f
      ${cmakeB "-DSVT_AV1_LTO=ON -DBUILD_TESTING=OFF"}
      grep -q '^Threads_FOUND:INTERNAL=TRUE$\|^CMAKE_HAVE_LIBC_PTHREAD:INTERNAL=1$' _b/CMakeCache.txt || { echo "FATAL: svt-av1: cmake probes failed" >&2; exit 1; }
      ${tprog ''#include <svt-av1/EbSvtAv1Enc.h>
#include <stdio.h>
int main(void){ printf("ok %s\n", svt_av1_get_version()); return 0; }'' "$out/lib/amd64/libSvtAv1Enc.so"}
      ${chk ''"$W/t"'' "^ok v4\\.1\\.0$"}
      # four flat 128x128 frames encoded (preset 12) to an IVF file
      perl -e 'print chr(128) x (128 * 128 * 3 / 2 * 4)' > "$W/in.yuv"
      ${chk ''"$out/bin/SvtAv1EncApp" -i "$W/in.yuv" -w 128 -h 128 -n 4 --preset 12 -b "$W/t.ivf" && od -An -c -N4 "$W/t.ivf"'' "D +K +I +F"}
    '';
  };

  # libcpuid (BSD-2-Clause): x86 CPU identification (vendor, features, caches) and cpuid_tool, as nixpkgs: autotools from the tag. On
  # illumos its affinity calls are processor_bind (upstream's __sun branch); MSR access is off there (upstream: unsupported OS).
  libcpuid = mkSrcPkg {
    pname = "libcpuid"; version = "0.8.1";
    src = { url = "https://codeload.github.com/anrieff/libcpuid/tar.gz/refs/tags/v0.8.1";
            sha256 = "81f2f40da5d66b8220476e116cb40bca4e6a62c0d22bdeeb8e3856cf14607007"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j8; gmake install
      ${tprog ''#include <libcpuid/libcpuid.h>
#include <stdio.h>
int main(void){ struct cpu_raw_data_t r; struct cpu_id_t d; if (!cpuid_present() || cpuid_get_raw_data(&r) || cpu_identify(&r, &d)) return 1;
printf("ok %s %d %s\n", cpuid_lib_version(), d.num_logical_cpus > 0, d.flags[CPU_FEATURE_SSE2] ? "sse2" : "-"); return 0; }'' "$out/lib/amd64/libcpuid.so"}
      ${chk ''"$W/t"'' "^ok 0\\.8\\.1 1 sse2$"}
    '';
  };

  # ---- recipes10 batch 19: libraries the x86 queue has jobs for, on wave7's store-only stdenv (main e7df981) ---------------------
  # The cmake recipes here take their packages through the merged solnix-cmake.cmake (store prefixes, lib/amd64, no host prefix) and
  # assert the CMakeCache entry instead of passing storePrefix.
  # libssh (LGPL-2.1+): the SSH protocol library (client and server, SFTP), on OpenSSL and zlib, as nixpkgs (no GSSAPI, no examples).
  # nixpkgs' NaCl -> sodium sed is moot: FindNaCl looks for nacl/*.h, which libsodium never installs, so its libssh names only
  # openssl (cache.nixos.org narinfo); WITH_NACL=OFF says so. Its cmake version-script probe is gnulib's two-node shape, which
  # illumos ld refuses: answered yes, and the link goes through the mapfile shim (libssh.map's LIBSSH_4_5_0 .. 4_11_0 nodes). Its
  # -fstack-protector probes are answered no: gcc.lib ships no libssp (cjson, svt-av1). _POSIX_PTHREAD_SEMANTICS: the POSIX
  # two-argument ctime_r (illumos' default is the old three-argument one).
  libssh = mkSrcPkg {
    pname = "libssh"; version = "0.12.2";
    src = { url = "https://www.libssh.org/files/0.12/libssh-0.12.2.tar.xz";
            sha256 = "49560f677d96e3706a904ac2de1116e25f3680937d51e5c92198fcba4a1c1e9f"; };
    deps = [ world zlib base.openssl ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${vsMap}
      ${cmakeB "-DWITH_EXAMPLES=OFF -DWITH_GSSAPI=OFF -DWITH_NACL=OFF -DHAVE_LD_VERSION_SCRIPT=1 -DWITH_STACK_PROTECTOR_STRONG=0 -DWITH_STACK_PROTECTOR=0 -DUNIT_TESTING=OFF -DCMAKE_C_FLAGS=-D_POSIX_PTHREAD_SEMANTICS"}
      grep -q "^OPENSSL_CRYPTO_LIBRARY:FILEPATH=${base.openssl}/" _b/CMakeCache.txt && grep -Eq "^ZLIB_LIBRARY(_RELEASE)?:FILEPATH=${zlib}/" _b/CMakeCache.txt \
        || { echo "FATAL: libssh: openssl/zlib not from the store" >&2; grep -E '^(OPENSSL|ZLIB)_' _b/CMakeCache.txt >&2; exit 1; }
      L="$out/lib/amd64/libssh.so.4"
      ${hasVer "$L" "LIBSSH_4_5_0" "ssh_new"}
      ${hasVer "$L" "LIBSSH_4_11_0" "ssh_get_supported_methods"}
      ${notExp "$L" "ssh_packet_send"}
      # an Ed25519 key made and exported: its public blob is 51 bytes, 68 in base64
      ${tprog ''#include <libssh/libssh.h>
#include <stdio.h>
#include <string.h>
int main(void){ ssh_key k; char *b = NULL; if (ssh_init() || ssh_pki_generate(SSH_KEYTYPE_ED25519, 0, &k) || ssh_pki_export_pubkey_base64(k, &b)) return 1;
printf("ok %s %s %d\n", ssh_version(0), ssh_key_type_to_char(ssh_key_type(k)), (int)strlen(b)); return 0; }'' "$L"}
      ${chk ''"$W/t"'' "^ok 0\\.12\\.2/openssl/zlib ssh-ed25519 68$"}
    '';
  };

  # soxr (LGPL-2.1+): the SoX resampler library (and its libsamplerate-like libsoxr-lsr), nixpkgs' patch and cmake bump. No OpenMP:
  # this gcc is built without libgomp (gcc-src.nix), so its threading is off (one thread per resampler).
  soxr = mkSrcPkg {
    pname = "soxr"; version = "0.1.3";
    src = { url = "https://downloads.sourceforge.net/soxr/soxr-0.1.3-Source.tar.xz";
            sha256 = "b111c15fdc8c029989330ff559184198c161100a59312f5dc19ddeb9b5a15889"; };
    deps = [ world ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/so/soxr/arm64-check.patch" "5702de2631ac27684125376c8366e207f4022f780181c1c758042129d8a8d634"}
      grep -qx 'cmake_minimum_required (VERSION 3.1 FATAL_ERROR)' CMakeLists.txt || { echo "FATAL: soxr cmake anchor" >&2; exit 1; }
      sed -i 's/^cmake_minimum_required (VERSION 3.1 FATAL_ERROR)$/cmake_minimum_required (VERSION 3.10 FATAL_ERROR)/' CMakeLists.txt
      ${cmakeB ''-DWITH_OPENMP=OFF -DBUILD_TESTS=OFF -DLIB_INSTALL_DIR="$out/lib/amd64" -DINCLUDE_INSTALL_DIR="$out/include"''}
      # 10 ms of a 48 kHz tone resampled to 44.1 kHz in one shot: 441 samples out
      ${tprog ''#include <soxr.h>
#include <stdio.h>
#include <math.h>
int main(void){ float in[480], out[1000]; size_t od = 0; for (int i = 0; i < 480; i++) in[i] = (float)sin(i * 0.1);
soxr_error_t e = soxr_oneshot(48000, 44100, 1, in, 480, NULL, out, 1000, &od, NULL, NULL, NULL); printf("ok %s %d %d\n", soxr_version(), e != NULL, od >= 440 && od <= 441); return 0; }'' "$out/lib/amd64/libsoxr.so -lm"}
      ${chk ''"$W/t"'' "^ok libsoxr-0\\.1\\.3 0 1$"}
      [ -e "$out/lib/amd64/libsoxr-lsr.so" ] || { echo "FATAL: soxr: no libsoxr-lsr" >&2; exit 1; }
    '';
  };

  # libass (ISC): the ASS/SSA subtitle renderer (mpv, ffmpeg), on freetype, fribidi, harfbuzz and fontconfig, nasm asm, as nixpkgs
  # (--enable-fontconfig --disable-large-tiles; libunibreak, which nixpkgs does not give it, off). The queue's 0.17.4 (nixpkgs 0.17.5).
  # harfbuzz.pc and fontconfig.pc's private requirements (glib, pcre2, expat, freetype's) are link-time inputs for pkg-config.
  # illumos iconv(3C) takes const char ** (SUSv2) unless _XPG6: gcc 14's incompatible-pointer-types error made a warning.
  libass = mkSrcPkg {
    pname = "libass"; version = "0.17.4";
    src = { url = "https://github.com/libass/libass/releases/download/0.17.4/libass-0.17.4.tar.xz";
            sha256 = "78f1179b838d025e9c26e8fef33f8092f65611444ffa1bfc0cfac6a33511a05a"; };
    deps = [ world freetype fontconfig gtkMeson.harfbuzz gtkMeson.fribidi ]; linkDeps = [ gtkMeson.glib gtkMeson.pcre2 expat ] ++ ftPriv;
    nativeTools = [ nasm base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-fontconfig --disable-large-tiles --disable-libunibreak \
        CFLAGS="-O2 -Wno-error=incompatible-pointer-types"
      grep -qx '#define CONFIG_ASM 1' config.h && grep -qx '#define CONFIG_FONTCONFIG 1' config.h || { echo "FATAL: libass config.h" >&2; grep CONFIG_ config.h >&2; exit 1; }
      gmake -j8; gmake install
      # one dialogue line rendered with Noto Sans (the font file, no font provider): the frame at 1 s has glyph images
      ${tprog ''#include <ass/ass.h>
#include <stdio.h>
#include <string.h>
int main(int c, char **v){ (void)c; ASS_Library *l = ass_library_init(); ASS_Renderer *r = l ? ass_renderer_init(l) : NULL; if (!r) return 1;
ass_set_frame_size(r, 320, 240); ass_set_fonts(r, v[1], "sans-serif", ASS_FONTPROVIDER_NONE, NULL, 0);
char s[] = "[Script Info]\nScriptType: v4.00+\nPlayResX: 320\nPlayResY: 240\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, Alignment\nStyle: Default,Noto Sans,24,&H00FFFFFF,2\n\n[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:00.00,0:00:05.00,Default,solnix\n";
ASS_Track *t = ass_read_memory(l, s, strlen(s), NULL); if (!t) return 2; int ch = 0, n = 0; for (ASS_Image *i = ass_render_frame(r, t, 1000, &ch); i; i = i->next) n++;
printf("ok %x %d %d\n", ass_library_version(), t->n_events, n > 0); ass_free_track(t); ass_renderer_done(r); ass_library_done(l); return 0; }'' "$out/lib/amd64/libass.so"}
      ${chk ''"$W/t" ${noto-sans}/share/fonts/noto/NotoSans-Regular.ttf'' "^ok 1704000 1 1$"}
    '';
  };

  # taglib (LGPL-2.1 / MPL-1.1): audio metadata (ID3, Vorbis comments, MP4 ...) and its C binding, shared, on zlib and the header-only
  # utf8cpp (its cmake package, asserted), as nixpkgs. The check retitles a copy of one of its own test MP3s and reads it back.
  taglib = mkSrcPkg {
    pname = "taglib"; version = "2.2.1";
    src = { url = "https://codeload.github.com/taglib/taglib/tar.gz/refs/tags/v2.2.1";
            sha256 = "8d920bfe302c943bab204ad5183fa0ea13cedee7f72f7256b665888de964d081"; };
    deps = [ world zlib ]; linkDeps = [ utf8cpp ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF"}
      grep -Eq "^utf8cpp_(DIR|INCLUDE_DIR):PATH=${utf8cpp}/" _b/CMakeCache.txt && grep -Eq "^ZLIB_LIBRARY(_RELEASE)?:FILEPATH=${zlib}/" _b/CMakeCache.txt \
        || { echo "FATAL: taglib: utf8cpp/zlib not from the store" >&2; grep -E '^(utf8cpp|ZLIB)_' _b/CMakeCache.txt >&2; exit 1; }
      cp tests/data/lame_cbr.mp3 "$W/t.mp3"
      ${tprog ''#include <taglib/tag_c.h>
#include <stdio.h>
int main(int c, char **v){ (void)c; TagLib_File *f = taglib_file_new(v[1]); if (!f || !taglib_file_is_valid(f)) return 1;
taglib_tag_set_title(taglib_file_tag(f), "solnix"); if (!taglib_file_save(f)) return 2; taglib_file_free(f);
f = taglib_file_new(v[1]); if (!f) return 3; printf("ok %s %d\n", taglib_tag_title(taglib_file_tag(f)), taglib_audioproperties_samplerate(taglib_file_audioproperties(f)) > 0);
taglib_tag_free_strings(); taglib_file_free(f); return 0; }'' "$out/lib/amd64/libtag_c.so"}
      ${chk ''"$W/t" "$W/t.mp3"'' "^ok solnix 1$"}
    '';
  };

  # geos (LGPL-2.1): the GEOS computational geometry library (JTS in C++) and its C API (PostGIS, GDAL, shapely), as nixpkgs.
  geos = mkSrcPkg {
    pname = "geos"; version = "3.14.1";
    src = { url = "https://codeload.github.com/libgeos/geos/tar.gz/refs/tags/3.14.1";
            sha256 = "512118b3be3ccefbca66b36b0f3e895576d08d6ff330ba1511a31a306abbb477"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_TESTING=OFF -DBUILD_BENCHMARKS=OFF"}
      ${tprog ''#include <geos_c.h>
#include <stdio.h>
int main(void){ GEOSContextHandle_t h = GEOS_init_r(); GEOSWKTReader *r = GEOSWKTReader_create_r(h);
GEOSGeometry *g = GEOSWKTReader_read_r(h, r, "POLYGON((0 0,4 0,4 3,0 3,0 0))"); double a = 0; if (!g || !GEOSArea_r(h, g, &a)) return 1;
printf("ok %s %.1f\n", GEOSversion(), a); GEOSGeom_destroy_r(h, g); GEOSWKTReader_destroy_r(h, r); GEOS_finish_r(h); return 0; }'' "$out/lib/amd64/libgeos_c.so"}
      ${chk ''"$W/t"'' "^ok 3\\.14\\.1-CAPI-[0-9.]+ 12\\.0$"}
    '';
  };

  # htslib (MIT/BSD): the SAM/BAM/CRAM/VCF library and bgzip, tabix, htsfile, ref-cache, as nixpkgs (--enable-libcurl, libdeflate), on
  # the nix chain's bzip2, xz and curl, the base zlib and openssl (S3/GCS signing). The queue's 1.22 (nixpkgs 1.24). Symbol versions:
  # htslib.map has no `local: *`, so GNU ld keeps the exports it does not list (hts_crc32, bcf_format_gt_v2, ...) in the base version,
  # and illumos ld refuses that ("symbol has no version assigned"; the libz case above): linked once unversioned, then with a mapfile
  # whose base node (the soname) holds the unlisted exports, followed by the shim's conversion of htslib.map (HTSLIB_1.0 .. 1.21).
  htslib = mkSrcPkg {
    pname = "htslib"; version = "1.22";
    src = { url = "https://github.com/samtools/htslib/releases/download/1.22/htslib-1.22.tar.bz2";
            sha256 = "6250c1df297db477516e60ac8df45ed75a652d1f25b0f37f12f5b17269eafde9"; };
    deps = [ world zlib base.nixChain.bzip2 base.nixChain.xz base.nixChain.curl libdeflate base.openssl ];
    nativeTools = [ bzip2-bin base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --enable-libcurl --with-libdeflate hts_cv_have_versioned_symbols=no
      gmake -j8 libhts.so
      nm -P -g libhts.so | awk '$2 !~ /^[Uwv]$/ { print $1 }' | sort > "$W/def"
      "$BASH" ${../version-script-mapfile.sh} convert htslib.map "$W/def" > "$W/vers.map"
      tr -s ' \t;{}' '\n' < htslib.map | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | grep -vE '^(global|local|HTSLIB_[0-9._]+)$' | sort -u > "$W/listed"
      { echo '$mapfile_version 2'; echo 'SYMBOL_VERSION libhts.so.3 {'; echo '  global:'
        comm -23 "$W/def" "$W/listed" | grep -vxE '_DYNAMIC|_GLOBAL_OFFSET_TABLE_|_PROCEDURE_LINKAGE_TABLE_|_edata|_end|_etext|_init|_fini|_START_|_END_' | sed 's/.*/    &;/'
        echo '  local:'; echo '    *;'; echo '};'; tail -n +2 "$W/vers.map"; } > "$W/hts.mapfile"
      rm libhts.so; gmake -j8 VERSION_SCRIPT_LDFLAGS="-Wl,-M,$W/hts.mapfile"; gmake install VERSION_SCRIPT_LDFLAGS="-Wl,-M,$W/hts.mapfile"
      L="$out/lib/amd64/libhts.so.3"
      ${hasVer "$L" "HTSLIB_1.0" "hts_open"}
      ${hasVer "$L" "HTSLIB_1.21" "cram_num_containers"}
      ${hasVer "$L" "libhts\\.so\\.3" "hts_crc32"}
      ${notExp "$L" "hts_tpool_process_attach_unlocked"}
      ${tprog ''#include <htslib/sam.h>
#include <stdio.h>
int main(int c, char **v){ (void)c; samFile *f = sam_open(v[1], "r"); sam_hdr_t *h = f ? sam_hdr_read(f) : NULL; if (!h) return 1; bam1_t *b = bam_init1(); int n = 0;
while (sam_read1(f, h, b) >= 0) n++; printf("ok %s %d %d\n", hts_version(), sam_hdr_nref(h), n); bam_destroy1(b); sam_hdr_destroy(h); sam_close(f); return 0; }'' "$L"}
      ${chk ''"$W/t" "test/xx#minimal.sam"'' "^ok 1\\.22 2 8$"}
      ${chk ''printf 'solnix\n' | "$out/bin/bgzip" -c | "$out/bin/bgzip" -dc'' "^solnix$"}
    '';
  };

  # codec2 (LGPL-2.1): the low-bitrate speech codec and FreeDV modems, shared, and nixpkgs' extra programs (c2enc, c2dec, the modem
  # tools) from the build dir. Its generate_codebook runs at build time (a native build). nixpkgs' pkg-config patch is for its split
  # outputs (absolute libdir), not taken; its freedv_api.h keyword swap (for SWIG) is.
  codec2 = mkSrcPkg {
    pname = "codec2"; version = "1.2.0";
    src = { url = "https://codeload.github.com/drowe67/codec2/tar.gz/refs/tags/1.2.0";
            sha256 = "cbccae52b2c2ecc5d2757e407da567eb681241ff8dadce39d779a7219dbcf449"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DUNITTEST=OFF"}
      mkdir -p "$out/bin"; ( cd _b/src && install -m 0755 c2enc c2dec c2sim freedv_rx freedv_tx cohpsk_* fdmdv_* fsk_* ldpc_* ofdm_* "$out/bin/" )
      sed -r -i 's/(\<_Complex)(\s+)(float|double)/\3\2\1/' "$out/include/codec2/freedv_api.h"
      ${tprog ''#include <codec2/codec2.h>
#include <stdio.h>
int main(void){ struct CODEC2 *c = codec2_create(CODEC2_MODE_3200); if (!c) return 1; printf("ok %d %d\n", codec2_samples_per_frame(c), codec2_bits_per_frame(c)); codec2_destroy(c); return 0; }'' "$out/lib/amd64/libcodec2.so"}
      ${chk ''"$W/t"'' "^ok 160 64$"}
      # upstream's 3 s sample (48000 bytes) at 3200 bit/s: 150 frames of 8 bytes, and back to 48000 bytes
      ${chk ''"$out/bin/c2enc" 3200 raw/hts1a.raw "$W/t.bit" && "$out/bin/c2dec" 3200 "$W/t.bit" "$W/t.raw" && echo "size $(wc -c < "$W/t.bit") $(wc -c < "$W/t.raw")"'' "^size 1200 48000$"}
    '';
  };

  # game-music-emu (LGPL-2.1+): libgme, emulators for video-game music formats (NSF, SPC, VGM, GBS ...), shared, on zlib, with
  # nixpkgs' CVE patch. YM2612: the default Nuked core (LGPL-2.1+; MAME's is the GPL one). The check plays upstream's test.nsf.
  game-music-emu = mkSrcPkg {
    pname = "game-music-emu"; version = "0.6.5";
    src = { url = "https://codeload.github.com/libgme/game-music-emu/tar.gz/refs/tags/0.6.5";
            sha256 = "8531678502451c2cf04248cda45c8b4645e19fcfb63e6a7ec2549641c47bb392"; };
    deps = [ world zlib ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://github.com/libgme/game-music-emu/commit/ae10a8f05479e3c8f80429e7a59759fed06f8c13.patch?full_index=1" "897de3bcb2cf00bbce4aa720b38e5f83d881aff0d36ca233c2960c8085a1050a"}
      ${cmakeB "-DGME_BUILD_SHARED=ON -DGME_BUILD_STATIC=OFF -DGME_BUILD_TESTING=OFF -DGME_BUILD_EXAMPLES=OFF -DGME_YM2612_EMU=Nuked"}
      grep -Eq "^ZLIB_LIBRARY(_RELEASE)?:FILEPATH=${zlib}/" _b/CMakeCache.txt || { echo "FATAL: game-music-emu: zlib not from the store" >&2; exit 1; }
      ${tprog ''#include <gme/gme.h>
#include <stdio.h>
int main(int c, char **v){ (void)c; Music_Emu *e; short b[4096]; long nz = 0; if (gme_open_file(v[1], &e, 44100) || gme_start_track(e, 0)) return 1;
for (int k = 0; k < 20; k++) { if (gme_play(e, 4096, b)) return 2; for (int i = 0; i < 4096; i++) nz += b[i] != 0; }
printf("ok %06x %d %d\n", GME_VERSION, gme_track_count(e), nz > 0); gme_delete(e); return 0; }'' "$out/lib/amd64/libgme.so"}
      ${chk ''"$W/t" test.nsf'' "^ok 000605 [1-9][0-9]* 1$"}
    '';
  };

  # ladspa-header (LGPL-2.0): the LADSPA plugin API header (ladspa.h) that audio hosts and plugins build against, as nixpkgs: the
  # header only.
  ladspa-header = mkSrcPkg {
    pname = "ladspa-header"; version = "1.17";
    src = { url = "https://www.ladspa.org/download/ladspa_sdk_1.17.tgz";
            sha256 = "27d24f279e4b81bd17ecbdcc38e4c42991bb388826c0b200067ce0eb59d3da5b"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      mkdir -p "$out/include"; cp src/ladspa.h "$out/include/ladspa.h"
      ${tprog ''#include <ladspa.h>
#include <stdio.h>
int main(void){ LADSPA_Descriptor d = { 0 }; printf("ok %s %d\n", LADSPA_VERSION, (int)sizeof d.UniqueID); return LADSPA_IS_PORT_INPUT(LADSPA_PORT_INPUT) ? 0 : 1; }'' ""}
      ${chk ''"$W/t"'' "^ok 1\\.1 [48]$"}
    '';
  };

  # libmpg123 (LGPL-2.1): mpg123's MPEG audio decoder library (with libout123/libsyn123) and its programs, as nixpkgs' libOnly
  # (which only drops the audio backends' inputs, so configure picks the platform's: illumos' sun /dev/audio module). Its own
  # sweep.mp3 test file decoded through the library. -D__EXTENSIONS__: its strict-POSIX defines hide <dlfcn.h>'s mmapobj_result_t.
  libmpg123 = mkSrcPkg {
    pname = "libmpg123"; version = "1.33.7";
    src = { url = "https://downloads.sourceforge.net/mpg123/mpg123-1.33.7.tar.bz2";
            sha256 = "31d0e35a4ca567ec9b5ebda6c3062bb4435d6d3eacd6ef0d95cadd7854dc03ee"; };
    deps = [ world ]; nativeTools = [ bzip2-bin ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static CPPFLAGS=-D__EXTENSIONS__
      gmake -j8; gmake install
      ${tprog ''#include <mpg123.h>
#include <stdio.h>
int main(int c, char **v){ (void)c; int err = 0, ch, enc; long rate; unsigned char b[8192]; size_t d = 0, tot = 0; mpg123_handle *m = mpg123_new(NULL, &err);
if (!m || mpg123_open(m, v[1]) != MPG123_OK || mpg123_getformat(m, &rate, &ch, &enc) != MPG123_OK) return 1;
int rc; while ((rc = mpg123_read(m, b, sizeof b, &d)) == MPG123_OK || rc == MPG123_NEW_FORMAT) tot += d; tot += d; printf("ok %ld %d %d\n", rate, ch, tot > 10000); mpg123_close(m); mpg123_delete(m); return 0; }'' "$out/lib/amd64/libmpg123.so"}
      ${chk ''"$W/t" src/tests/sweep.mp3'' "^ok 44100 2 1$"}
      ${chk ''"$out/bin/mpg123" --version'' "^mpg123 1\\.33\\.7"}
    '';
  };

  # libplist (LGPL-2.1+): Apple property lists (XML, binary, JSON, OpenStep) and plistutil, as nixpkgs (--enable-debug, no cython):
  # autotools from the tag, the version given as RELEASE_VERSION (git-version-gen has no .git), the C++ binding included.
  libplist = mkSrcPkg {
    pname = "libplist"; version = "2.7.0";
    src = { url = "https://codeload.github.com/libimobiledevice/libplist/tar.gz/refs/tags/2.7.0";
            sha256 = "66fa17a29270cb25ceaf189430ea38037c066652c2989b58d7ef6120b1a208d3"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ [ base.pkgconf ] ++ hostTools;
    build = ''
      echo 2.7.0 > .tarball-version
      export RELEASE_VERSION=2.7.0
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-debug --without-cython LDFLAGS="-L$gccLib/amd64"
      gmake -j8; gmake install
      ${tprog ''#include <plist/plist.h>
#include <stdio.h>
#include <string.h>
int main(void){ plist_t d = plist_new_dict(); plist_dict_set_item(d, "os", plist_new_string("solnix")); char *b = NULL; uint32_t n = 0; plist_to_bin(d, &b, &n);
plist_t r = NULL; plist_from_bin(b, n, &r); char *s = NULL; plist_get_string_val(plist_dict_get_item(r, "os"), &s);
printf("ok %s %.8s %s\n", libplist_version(), b, s); plist_mem_free(s); plist_mem_free(b); plist_free(r); plist_free(d); return 0; }'' "$out/lib/amd64/libplist-2.0.so"}
      ${chk ''"$W/t"'' "^ok 2\\.7\\.0 bplist00 solnix$"}
      printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>a</key><integer>42</integer></dict></plist>\n' > "$W/t.plist"
      ${chk ''"$out/bin/plistutil" -i "$W/t.plist" -f bin -o "$W/t.bin" && "$out/bin/plistutil" -i "$W/t.bin" -f xml'' "<integer>42</integer>"}
    '';
  };

  # fonttosfnt (MIT): X.Org's bitmap font to OpenType (bitmap-only sfnt) wrapper, on freetype and libfontenc. The release tarball.
  # Its UTC mktime is timegm on glibc only; elsewhere it sets TZ="" and calls mktime, which on illumos reads the BUILD HOST's zone
  # (/etc/default/init): a font's head timestamps moved by the host's UTC offset (cherry: woof vs lixi, 18000 s). timegm(3C) on __sun.
  fonttosfnt = mkSrcPkg {
    pname = "fonttosfnt"; version = "1.2.5";
    src = { url = "https://www.x.org/releases/individual/app/fonttosfnt-1.2.5.tar.xz";
            sha256 = "2e251e66e8753c08aa280b26fd4a10d0d88e7d9bba5c8aac3d3fb36705e5918e"; };
    deps = [ world freetype libfontenc ]; linkDeps = [ base.xorgproto zlib ] ++ ftPriv; nativeTools = [ base.pkgconf python3 ] ++ hostTools;
    build = ''
      grep -qx '#ifdef __GLIBC__' util.c || { echo "FATAL: fonttosfnt timegm anchor" >&2; exit 1; }
      sed -i 's/^#ifdef __GLIBC__$/#if defined(__GLIBC__) || defined(__sun)/' util.c
      ./configure --prefix="$out" ${manSections}
      gmake -j8; gmake install
      cat > "$W/t.bdf" <<'BDF'
STARTFONT 2.1
FONT -solnix-test-medium-r-normal--8-80-75-75-c-80-iso10646-1
SIZE 8 75 75
FONTBOUNDINGBOX 8 8 0 0
STARTPROPERTIES 3
FONT_ASCENT 8
FONT_DESCENT 0
PIXEL_SIZE 8
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
      # an OpenType file starts with the sfnt version 0x00010000 (fonttosfnt writes no 'OTTO' table set)
      ${chk ''"$out/bin/fonttosfnt" -o "$W/t.otb" "$W/t.bdf" && od -An -tx1 -N4 "$W/t.otb"'' "^ *00 01 00 00$"}
      # the head table's created time is SOURCE_DATE_EPOCH (315532800) counted from fonttosfnt's 1 February 1904 epoch (tm_mon=1 upstream),
      # so 312854400 read against the format's 1 January 1904, whatever zone the build host is in (the unfixed tool on lixi: 312836400)
      cat > "$W/ht.py" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read(); n = struct.unpack(">H", b[4:6])[0]
for i in range(n):
    t, c, o, l = struct.unpack(">4sIII", b[12 + 16 * i: 28 + 16 * i])
    if t == b"head": print("created", struct.unpack(">q", b[o + 20: o + 28])[0] - 2082844800)
PY
      ${chk ''TZ=Pacific/Kiritimati python3 "$W/ht.py" "$W/t.otb"'' "^created 312854400$"}
    '';
  };

  # libxfont_2 (MIT and others): libXfont2, the X server's font rasteriser and font-path library, on freetype, libfontenc, zlib and
  # xtrans, as nixpkgs (bzip2 off, its default). The release tarball.
  libxfont_2 = mkSrcPkg {
    pname = "libxfont_2"; version = "2.0.9";
    src = { url = "https://www.x.org/releases/individual/lib/libXfont2-2.0.9.tar.xz";
            sha256 = "f042a370666815e7b941e9b7019024755bd1c6c2954afbfa515af378251799e2"; };
    deps = [ world freetype libfontenc zlib ]; linkDeps = [ base.xorgproto xtrans ] ++ ftPriv; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static ${manSections}
      gmake -j8; gmake install
      ${tprog ''#include <X11/fonts/fontstruct.h>
#include <X11/fonts/libxfont2.h>
#include <stdio.h>
int main(void){ FontNamesPtr n = xfont2_make_font_names_record(4); if (!n) return 1; char a[] = "fixed", b[] = "cursor";
xfont2_add_font_names_name(n, a, 5); xfont2_add_font_names_name(n, b, 6); printf("ok %d %s %s\n", n->nnames, n->names[0], n->names[1]); xfont2_free_font_names(n); return 0; }'' "$out/lib/amd64/libXfont2.so"}
      ${chk ''"$W/t"'' "^ok 2 fixed cursor$"}
    '';
  };

  # isa-l (BSD-3-Clause): Intel's storage acceleration library (igzip deflate, CRC, erasure codes, RAID) with nasm asm, its igzip
  # program, as nixpkgs (ISAL_BUILD_IGZIP_CLI). cmake on illumos reports CMAKE_SYSTEM_PROCESSOR i386 (uname -p) for this 64-bit build,
  # which isa-l would build as an unknown CPU (no asm): a 64-bit SunOS is x86_64 there (as ggml). illumos has no <byteswap.h>: its
  # GNUC branch takes gcc's builtins on __sun. nasm's STT_FILE source names: relative paths (libjpeg-turbo's wrapper).
  isa-l = mkSrcPkg {
    pname = "isa-l"; version = "2.32.1";
    src = { url = "https://codeload.github.com/intel/isa-l/tar.gz/refs/tags/v2.32.1";
            sha256 = "d9f7179ab0e14a3db9b610fac22793854a1435e8423ec9ce07f4cbedc5f92f5e"; };
    deps = [ world ]; nativeTools = [ cmake nasm ] ++ hostTools;
    build = ''
      [ "$(grep -c '^if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "AMD64")$' CMakeLists.txt)" = 2 ] || { echo "FATAL: isa-l arch anchor" >&2; exit 1; }
      sed -i 's/^if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "AMD64")$/if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "AMD64" OR (CMAKE_SYSTEM_NAME STREQUAL "SunOS" AND CMAKE_SIZEOF_VOID_P EQUAL 8))/' CMakeLists.txt
      grep -qx '#elif defined(__GNUC__) && !defined(__MINGW32__)' include/unaligned.h || { echo "FATAL: isa-l byteswap anchor" >&2; exit 1; }
      sed -i 's|^#elif defined(__GNUC__) \&\& !defined(__MINGW32__)$|#elif defined(__sun)\n#define isal_bswap16(x) __builtin_bswap16(x)\n#define isal_bswap32(x) __builtin_bswap32(x)\n#define isal_bswap64(x) __builtin_bswap64(x)\n&|' include/unaligned.h
      ${nasmRel}
      ${cmakeB ''-DCMAKE_ASM_NASM_COMPILER="$W/nasm" -DISAL_BUILD_IGZIP_CLI=ON -DISAL_BUILD_TESTS=OFF -DISAL_BUILD_PERF_TESTS=OFF''}
      ls _b/CMakeFiles/isal.dir/crc/*.asm.o > /dev/null || { echo "FATAL: isa-l: no nasm objects" >&2; exit 1; }
      # the CRC-32 check value ("123456789" -> cbf43926) through the asm dispatcher, and a deflate round trip through igzip
      ${tprog ''#include <isa-l.h>
#include <stdio.h>
int main(void){ printf("ok %08x\n", crc32_gzip_refl(0, (const unsigned char *)"123456789", 9)); return 0; }'' "$out/lib/amd64/libisal.so"}
      ${chk ''"$W/t"'' "^ok cbf43926$"}
      ${chk ''printf 'solnix solnix solnix\n' | "$out/bin/igzip" -c | "$out/bin/igzip" -dc'' "^solnix solnix solnix$"}
    '';
  };

  # libhwy (Apache-2.0 / BSD-3-Clause): Google Highway, portable SIMD with run-time dispatch, shared, with contrib (vqsort, thread pool)
  # and its test-helper library, as nixpkgs (its contrib-output split not taken: one output; its gcc 16 patch is to the installed
  # test header). Its gtest tests are not built. The check sorts through vqsort and lists the CPU targets it can dispatch to.
  libhwy = mkSrcPkg {
    pname = "libhwy"; version = "1.4.0";
    src = { url = "https://codeload.github.com/google/highway/tar.gz/refs/tags/1.4.0";
            sha256 = "e72241ac9524bb653ae52ced768b508045d4438726a303f10181a38f764a453c"; };
    deps = [ world ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://github.com/google/highway/commit/8a0da774fe6b3f9ab02f5f33e763b8c2133f38fc.patch?full_index=1" "580b05eb88fec28e83c6587cd0dd6e141d4e451234a577a527ff19eed36103c1"}
      # hwy.version is extern "C++" globs, which illumos mapfiles cannot express (the shim refuses them); upstream skips it where the
      # linker lacks it ("safe to skip (we use DLLEXPORT annotations)": the libraries are built -fvisibility=hidden). SunOS too.
      [ "$(grep -c '^if(UNIX AND NOT APPLE)$' CMakeLists.txt)" = 3 ] || { echo "FATAL: libhwy version-script anchor" >&2; exit 1; }
      sed -i 's/^if(UNIX AND NOT APPLE)$/if(UNIX AND NOT APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "SunOS")/' CMakeLists.txt
      # at the build's core count, not cmakeB's -j16: vqsort's units are ~1 GB each (woof, 16 GB, swapped 19 GB at -j16)
      ${builtins.replaceStrings [ "cmake --build _b -j16" ] [ "cmake --build _b -j\${NIX_BUILD_CORES:-4}" ] (cmakeB "-DBUILD_SHARED_LIBS=ON -DHWY_ENABLE_TESTS=ON -DHWY_ENABLE_EXAMPLES=OFF -DBUILD_TESTING=OFF")}
      [ -e "$out/lib/amd64/libhwy_test.so" ] || { echo "FATAL: libhwy: no libhwy_test" >&2; exit 1; }
      cat > "$W/t.cc" <<'TPROG'
#include <hwy/contrib/sort/vqsort.h>
#include <hwy/targets.h>
#include <cstdio>
#include <vector>
int main(){ std::vector<uint32_t> v(1000); for (size_t i = 0; i < v.size(); i++) v[i] = (uint32_t)((i * 7919) % 1000);
hwy::VQSort(v.data(), v.size(), hwy::SortAscending()); bool ok = true; for (size_t i = 0; i < v.size(); i++) ok = ok && v[i] == i;
std::printf("ok %d %d\n", ok, (hwy::SupportedTargets() & HWY_SSE2) != 0); }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" "$out/lib/amd64/libhwy_contrib.so" "$out/lib/amd64/libhwy.so" -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 1 1$"}
    '';
  };

  # muparser (MIT): a fast math expression parser, shared, as nixpkgs' flags but without OpenMP (this gcc has no libgomp: its
  # bulk-evaluation mode runs single-threaded). Samples off.
  muparser = mkSrcPkg {
    pname = "muparser"; version = "2.3.5";
    src = { url = "https://codeload.github.com/beltoforion/muparser/tar.gz/refs/tags/v2.3.5";
            sha256 = "20b43cc68c655665db83711906f01b20c51909368973116dfc8d7b3c4ddb5dd4"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DENABLE_OPENMP=OFF -DENABLE_SAMPLES=OFF -DBUILD_TESTING=OFF"}
      ${tprog ''#include <muParserDLL.h>
#include <stdio.h>
int main(void){ muParserHandle_t p = mupCreate(muBASETYPE_FLOAT); mupSetExpr(p, "sin(_pi/2) + 2^10 * (3 - 1)"); double r = mupEval(p);
printf("ok %s %d %.1f\n", mupGetVersion(p), mupError(p), r); mupRelease(p); return 0; }'' "$out/lib/amd64/libmuparser.so"}
      ${chk ''"$W/t"'' "^ok 2\\.3\\.5.* 0 2049\\.0$"}
    '';
  };

  # primesieve (BSD-2-Clause): the segmented sieve of Eratosthenes library and its primesieve command, shared, as nixpkgs. Its x86
  # multiarch (POPCNT, AVX-512 dispatch on cpuid) is kept: cmake's i386 CMAKE_SYSTEM_PROCESSOR on illumos is not consulted there.
  primesieve = mkSrcPkg {
    pname = "primesieve"; version = "12.14";
    src = { url = "https://codeload.github.com/kimwalisch/primesieve/tar.gz/refs/tags/v12.14";
            sha256 = "65cf173e11bc9aff1b189f2cd19c6b6c502c30e966876b5c5ef71e138f49c8c9"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_STATIC_LIBS=OFF -DBUILD_TESTS=OFF"}
      ${tprog ''#include <primesieve.h>
#include <stdio.h>
int main(void){ printf("ok %s %llu %llu\n", primesieve_version(), (unsigned long long)primesieve_count_primes(0, 1000000), (unsigned long long)primesieve_nth_prime(1000, 0)); return 0; }'' "$out/lib/amd64/libprimesieve.so"}
      ${chk ''"$W/t"'' "^ok 12\\.14 78498 7919$"}
      ${chk ''"$out/bin/primesieve" 1e6'' "^Primes: 78498$"}
    '';
  };

  # howard-hinnant-date (MIT): the C++ date/time-zone library (std::chrono's calendar and tz before C++20), with libdate-tz on the
  # OS tz database, shared, as nixpkgs: its date.pc patch and fix-ups, and its zoneinfo patch pointing the default tz dir at the store
  # tzdata (illumos has /usr/share/lib/zoneinfo, not /usr/share/zoneinfo; nixpkgs pins the store one on every platform). The library
  # still stats upstream's /usr/share/zoneinfo/uclibc first, as on NixOS (absent on every solnix host).
  howard-hinnant-date = mkSrcPkg {
    pname = "howard-hinnant-date"; version = "3.0.3";
    src = { url = "https://codeload.github.com/HowardHinnant/date/tar.gz/refs/tags/v3.0.3";
            sha256 = "30de45a34a2605cca33a993a9ea54e8f140f23b1caf1acf3c2fd436c42c7d942"; };
    deps = [ world tzdata ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://git.alpinelinux.org/aports/plain/community/date/538-output-date-pc-for-pkg-config.patch?id=11f6b4d4206b0648182e7b41cd57dcc9ccea0728" "c881ae3ae08b46a2137b987e593469d030669c37c9423921a1fac7de512676f3"}
      sed 's|@tzdata@|${tzdata}|' ${fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/ho/howard-hinnant-date/make-zoneinfo-available.diff" "f06f0fe512721ac66e068f08602f7246b82a49d82ef67172abd6cbf7a6fcb563"} | patch -p1
      sed -i -e 's|@CMAKE_INSTALL_LIB@|@CMAKE_INSTALL_FULL_LIBDIR@|' -e 's|@CMAKE_INSTALL_INCLUDE@|@CMAKE_INSTALL_FULL_INCLUDEDIR@|' -e 's|@PACKAGE_VERSION@|3.0.3|' date.pc.in
      ${cmakeB "-DBUILD_TZ_LIB=true -DBUILD_SHARED_LIBS=true -DUSE_SYSTEM_TZ_DB=true"}
      grep -q "${tzdata}/share/zoneinfo" src/tz.cpp || { echo "FATAL: howard-hinnant-date: zoneinfo patch" >&2; exit 1; }
      cat > "$W/t.cc" <<'TPROG'
#include <date/tz.h>
#include <iostream>
int main(){ using namespace date; using namespace std::chrono; auto t = sys_days{2026_y/July/4} + 12h;
auto z = make_zoned("America/New_York", t); std::cout << "ok " << z << "\n"; }
TPROG
      "$CXX" -std=c++17 -DUSE_OS_TZDB=1 -I"$out/include" "$W/t.cc" "$out/lib/amd64/libdate-tz.so" -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 2026-07-04 08:00:00 EDT$"}
      grep -qx 'Version: 3.0.3' "$out/lib/amd64/pkgconfig/date.pc" || { echo "FATAL: howard-hinnant-date: date.pc" >&2; exit 1; }
    '';
  };

  # capnproto (MIT): Cap'n Proto serialisation and RPC, the capnp compiler and the kj libraries, shared, with fibers (getcontext and
  # friends are in illumos libc), on openssl and zlib, as nixpkgs (its libucontext patch only names a musl dependency in a .pc).
  # nixpkgs builds it with clang (gcc once miscompiled kj's coroutines, gcc PR 102051); gcc 15 here, C++20 as nixpkgs, and the check
  # runs a kj coroutine and a fiber besides a schema compiled by capnp and a message round trip. kj's event loop on illumos is poll(2).
  # illumos <setjmp.h> declares _setjmp/_longjmp (kj's fiber switch) only in namespace std for C++: brought in by name. kj-async's
  # sockets are in libsocket/libnsl on illumos (upstream links ws2_32 on Windows only): added for SunOS, as its PUBLIC link interface.
  capnproto = mkSrcPkg {
    pname = "capnproto"; version = "1.5.0";
    src = { url = "https://codeload.github.com/capnproto/capnproto/tar.gz/refs/tags/v1.5.0";
            sha256 = "d5ebdf858e9885c33d4b3f765006d68bd66e9b002bf4d607ff4317ef9c1aac6a"; };
    deps = [ world zlib base.openssl ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      grep -qx '#include <setjmp.h>    // for fibers' c++/src/kj/async.c++ || { echo "FATAL: capnproto setjmp anchor" >&2; exit 1; }
      sed -i 's|^#include <setjmp.h>    // for fibers$|&\n#if defined(__sun) \&\& defined(__cplusplus)\nusing std::_setjmp;\nusing std::_longjmp;\n#endif|' c++/src/kj/async.c++
      grep -qx '    target_link_libraries(kj-async PUBLIC ws2_32)' c++/src/kj/CMakeLists.txt || { echo "FATAL: capnproto ws2_32 anchor" >&2; exit 1; }
      sed -i 's|^    target_link_libraries(kj-async PUBLIC ws2_32)$|&\n  endif()\n  if(CMAKE_SYSTEM_NAME STREQUAL "SunOS")\n    target_link_libraries(kj-async PUBLIC socket nsl)|' c++/src/kj/CMakeLists.txt
      ${builtins.replaceStrings [ "cmake --build _b -j16" ] [ "cmake --build _b -j\${NIX_BUILD_CORES:-4}" ] (cmakeB "-DBUILD_SHARED_LIBS=ON -DWITH_FIBERS=ON -DBUILD_TESTING=OFF -DCMAKE_CXX_FLAGS=-std=c++20")}
      grep -q "^OPENSSL_CRYPTO_LIBRARY:FILEPATH=${base.openssl}/" _b/CMakeCache.txt && grep -Eq "^ZLIB_LIBRARY(_RELEASE)?:FILEPATH=${zlib}/" _b/CMakeCache.txt \
        || { echo "FATAL: capnproto: openssl/zlib not from the store" >&2; grep -E '^(OPENSSL|ZLIB)_' _b/CMakeCache.txt >&2; exit 1; }
      mkdir "$W/cp"; printf '@0xbf5147cbbecf40c1;\nstruct P { name @0 :Text; n @1 :UInt32; }\n' > "$W/cp/t.capnp"
      ( cd "$W/cp" && "$out/bin/capnp" compile -o"$out/bin/capnpc-c++" t.capnp )
      cat > "$W/cp/m.cc" <<'TPROG'
#include "t.capnp.h"
#include <capnp/message.h>
#include <capnp/serialize.h>
#include <kj/async.h>
#include <iostream>
kj::Promise<int> co(kj::Promise<int> p){ int x = co_await p; co_return x + 1; }
int main(){ capnp::MallocMessageBuilder b; auto p = b.initRoot<P>(); p.setName("solnix"); p.setN(42); auto w = capnp::messageToFlatArray(b);
capnp::FlatArrayMessageReader r(w); auto q = r.getRoot<P>(); kj::EventLoop loop; kj::WaitScope ws(loop); int c = co(kj::Promise<int>(41)).wait(ws);
int f = kj::startFiber(65536, [](kj::WaitScope&){ return 7; }).wait(ws); std::cout << "ok " << q.getName().cStr() << " " << q.getN() << " " << c << " " << f << "\n"; }
TPROG
      "$CXX" -std=c++20 -I"$out/include" -I"$W/cp" "$W/cp/m.cc" "$W/cp/t.capnp.c++" "$out/lib/amd64/libcapnp.so" "$out/lib/amd64/libkj-async.so" "$out/lib/amd64/libkj.so" -lsocket -lnsl -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t"'' "^ok solnix 42 42 7$"}
      ${chk ''"$out/bin/capnp" --version'' "^Cap.n Proto version 1\\.5\\.0$"}
    '';
  };

  # libsysprof-capture (BSD-2-Clause-Patent): sysprof's capture-file writer/reader, the static library and headers that GLib, GTK and
  # Mesa link to emit profiler marks (nixpkgs' package: everything else off). The queue's 50.0 (nixpkgs 51.0). Its Linux-only paths
  # (perf, memfd, sched_getcpu, gettid) are #ifdef'd with fallbacks; the non-Linux temp-file one needs <fcntl.h>, an O_BINARY (0
  # off Windows) and, under its strict -D_POSIX_C_SOURCE, __EXTENSIONS__ (mkostemp). illumos has no <byteswap.h>: gcc's builtins.
  libsysprof-capture = mkSrcPkg {
    pname = "libsysprof-capture"; version = "50.0";
    src = { url = "https://download.gnome.org/sources/sysprof/50/sysprof-50.0.tar.xz";
            sha256 = "aace44e90e90f6c34bb2fbec8ccb47b8f81103080978d65759287843c329d53a"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      grep -qx '# include <byteswap.h>' src/libsysprof-capture/sysprof-macros-internal.h && grep -qx '#ifndef __NR_memfd_create' src/libsysprof-capture/sysprof-platform.c \
        || { echo "FATAL: libsysprof-capture anchors" >&2; exit 1; }
      sed -i 's|^# include <byteswap.h>$|# ifdef __sun\n#  define bswap_16 __builtin_bswap16\n#  define bswap_32 __builtin_bswap32\n#  define bswap_64 __builtin_bswap64\n# else\n#  include <byteswap.h>\n# endif|' src/libsysprof-capture/sysprof-macros-internal.h
      sed -i '0,/^#ifndef __NR_memfd_create$/s||#include <fcntl.h>\n#ifndef O_BINARY\n# define O_BINARY 0\n#endif\n\n&|' src/libsysprof-capture/sysprof-platform.c
      ${mesonBuild "-Dc_args=-D__EXTENSIONS__ -Dinstall-static=true -Dsysprofd=none -Dgtk=false -Dlibsysprof=false -Dhelp=false -Dtools=false -Dtests=false -Dexamples=false -Dpolkit-agent=disabled -Ddebuginfod=disabled"}
      ${tprog ''#include <sysprof-capture.h>
#include <stdio.h>
#include <string.h>
int main(int c, char **v){ (void)c; SysprofCaptureWriter *w = sysprof_capture_writer_new(v[1], 0); if (!w) return 1;
sysprof_capture_writer_add_mark(w, SYSPROF_CAPTURE_CURRENT_TIME, -1, -1, 125, "solnix", "Draw", "hdmi-1"); sysprof_capture_writer_unref(w);
SysprofCaptureReader *r = sysprof_capture_reader_new(v[1]); if (!r) return 2; const SysprofCaptureMark *m = sysprof_capture_reader_read_mark(r); if (!m) return 3;
printf("ok %d.%d %s %s %d\n", SYSPROF_MAJOR_VERSION, SYSPROF_MINOR_VERSION, m->group, m->name, (int)m->duration); sysprof_capture_reader_unref(r); return 0; }'' ''-I"$out/include/sysprof-6" "$out/lib/amd64/libsysprof-capture-4.a" -lpthread -lsocket -lnsl''}
      ${chk ''"$W/t" "$W/t.syscap"'' "^ok 50\\.0 solnix Draw 125$"}
    '';
  };

  # ---- recipes10 batch 20: what R19 made buildable (lame on libmpg123, samtools/bcftools/seqtk on htslib/isa-l, primecount on
  # primesieve, xfs on libXfont2, sshping/rtrlib on libssh, libimobiledevice-glue on libplist) and small leaves -------------------
  # lame (LGPL-2.0): the MP3 encoder library and the lame command, nixpkgs' flags (nasm, cpml, the mpg123 decoder, analyzer hooks,
  # no mp3rtp) and its three upstream patches. illumos iconv(3C) takes const char ** unless _XPG6: gcc 14's incompatible-pointer-types
  # error made a warning (as libass).
  lame = mkSrcPkg {
    pname = "lame"; version = "4.0";
    src = { url = "https://downloads.sourceforge.net/lame/lame-4.0.tar.gz";
            sha256 = "3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb"; };
    deps = [ world libmpg123 ]; nativeTools = [ gnupatch nasm base.pkgconf perl ] ++ hostTools;   # perl: the check's tone generator
    build = ''
      for p in ${npPatch "la/lame/fix-utf8-id3-tag.patch" "cdddba0810826b03c857861025a65b62a3eef556b7bbedbd2c65cdc8f5c24ee6"} \
               ${npPatch "la/lame/fix-setlocale-without-iconv.patch" "bc31a53606477a33c875725611eb5f4a78e0a43162f50cb533e8a0f410a5a920"} \
               ${npPatch "la/lame/export-hip-pinfo-symbols.patch" "f2fa0ba5204fc406a7487ff561e2603891c6236ccde7c23b2089d4359abea54b"}; do patch -p1 < "$p"; done
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-nasm --enable-cpml --with-fileio=lame \
        --enable-analyzer-hooks --enable-decoder --enable-frontend --enable-dynamic-frontends --disable-mp3rtp \
        CFLAGS="-O2 -Wno-error=incompatible-pointer-types"
      gmake -j8; gmake install
      # one second of a 440 Hz tone (16-bit stereo raw) encoded to MP3 and decoded back through lame's mpg123 decoder
      perl -e 'for $i (0..44099) { $s = int(8000 * sin($i * 6.2832 * 440 / 44100)); print pack("s<s<", $s, $s) }' > "$W/t.raw"
      ${chk ''"$out/bin/lame" -r -s 44.1 --bitwidth 16 -b 128 --quiet "$W/t.raw" "$W/t.mp3" && "$out/bin/lame" --decode --quiet "$W/t.mp3" "$W/t.wav" && od -An -c -N4 "$W/t.wav"'' "R +I +F +F"}
      ${tprog ''#include <lame/lame.h>
#include <stdio.h>
int main(void){ lame_t l = lame_init(); lame_set_in_samplerate(l, 44100); int r = lame_init_params(l); printf("ok %s %d\n", get_lame_version(), r); lame_close(l); return 0; }'' "$out/lib/amd64/libmp3lame.so"}
      ${chk ''"$W/t"'' "^ok 4\\.0 0$"}
    '';
  };

  # libimobiledevice-glue (LGPL-2.1+): the shared helpers (sockets, threads, TLV, OPACK) of libimobiledevice, on libplist, as
  # nixpkgs: autotools from the tag, the version given as RELEASE_VERSION. illumos keeps socket() in libsocket.
  libimobiledevice-glue = mkSrcPkg {
    pname = "libimobiledevice-glue"; version = "1.3.3";
    src = { url = "https://codeload.github.com/libimobiledevice/libimobiledevice-glue/tar.gz/refs/tags/1.3.3";
            sha256 = "fbcc4a17363b9d048699d2445645be7dbe3d33b02c10f13d4f865c7d402ebdb3"; };
    deps = [ world libplist ]; nativeTools = autoreconfTools ++ [ base.pkgconf ] ++ hostTools;
    build = ''
      echo 1.3.3 > .tarball-version; export RELEASE_VERSION=1.3.3
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static LIBS="-lsocket -lnsl"
      gmake -j8; gmake install
      ${tprog ''#include <libimobiledevice-glue/utils.h>
#include <stdio.h>
#include <stdlib.h>
int main(void){ char *s = string_concat("sol", "nix", NULL); printf("ok %s\n", s); free(s); return 0; }'' "$out/lib/amd64/libimobiledevice-glue-1.0.so"}
      ${chk ''"$W/t"'' "^ok solnix$"}
    '';
  };

  # primecount (BSD-2-Clause): the fast prime-counting function library and command, on R19's primesieve (nixpkgs builds its bundled
  # copy, BUILD_LIBPRIMESIEVE; the served one here instead, as a separate package should be). No OpenMP (no libgomp): one thread.
  primecount = mkSrcPkg {
    pname = "primecount"; version = "8.5";
    src = { url = "https://codeload.github.com/kimwalisch/primecount/tar.gz/refs/tags/v8.5";
            sha256 = "a2dd9714e723388987183776d068d6845b82b2cf8ea44ecb6cea3fd9dde938ea"; };
    deps = [ world primesieve ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_LIBPRIMESIEVE=OFF -DBUILD_PRIMECOUNT=ON -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DWITH_OPENMP=OFF -DBUILD_TESTS=OFF"}
      grep -q "^primesieve_DIR:PATH=${primesieve}/" _b/CMakeCache.txt || { echo "FATAL: primecount: primesieve not from the store" >&2; grep primesieve _b/CMakeCache.txt >&2; exit 1; }
      ${tprog ''#include <primecount.h>
#include <stdio.h>
int main(void){ printf("ok %s %lld\n", primecount_version(), (long long)primecount_pi(1000000000)); return 0; }'' "$out/lib/amd64/libprimecount.so"}
      ${chk ''"$W/t"'' "^ok 8\\.5 50847534$"}
      ${chk ''"$out/bin/primecount" 1e10'' "^455052511$"}
    '';
  };

  # samtools (MIT): the SAM/BAM/CRAM tools, on R19's htslib (--with-htslib), zlib and ncurses (tview), as nixpkgs. The queue's 1.22.1.
  # Its misc/*.pl scripts name /usr/bin/env perl: kept (NixOS patchShebangs leaves env, and gate B9 accepts it). illumos
  # <iso/ctype_iso.h> #defines _P (a ctype class bit), which clobbers bam_consensus.c's local `double _P`: renamed.
  samtools = mkSrcPkg {
    pname = "samtools"; version = "1.22.1";
    src = { url = "https://github.com/samtools/samtools/releases/download/1.22.1/samtools-1.22.1.tar.bz2";
            sha256 = "02aa5cd0ba52e06c2080054e059d7d77a885dfe9717c31cd89dfe7a4047eda0e"; };
    deps = [ world htslib zlib base.ncurses ]; nativeTools = [ bzip2-bin perl ] ++ hostTools;
    build = ''
      [ "$(grep -c '\<_P\>' bam_consensus.c)" -gt 0 ] || { echo "FATAL: samtools _P anchor" >&2; exit 1; }
      sed -i -e 's/\<_P\>/cons_P/g' -e 's/\<_M\>/cons_M/g' bam_consensus.c
      ./configure --prefix="$out" --with-htslib=${htslib}
      gmake -j8; gmake install
      ${chk ''"$out/bin/samtools" --version'' "^samtools 1\\.22\\.1$"}
      # a sorted, indexed BAM from upstream's own test SAM, then its records counted from the BAM
      ${chk ''"$out/bin/samtools" sort -o "$W/t.bam" test/dat/mpileup.1.sam && "$out/bin/samtools" index "$W/t.bam" && "$out/bin/samtools" view -c "$W/t.bam" 17:100-200'' "^[0-9]+$"}
    '';
  };

  # bcftools (MIT): VCF/BCF calling and manipulation, with its plugins, on R19's htslib, as nixpkgs (no GSL, no perl filters).
  # The queue's 1.22. Its misc scripts keep #!/usr/bin/env (as samtools).
  bcftools = mkSrcPkg {
    pname = "bcftools"; version = "1.22";
    src = { url = "https://github.com/samtools/bcftools/releases/download/1.22/bcftools-1.22.tar.bz2";
            sha256 = "f2ab9e2f605b1203a7e9cbfb0a3eb7689322297f8c34b45dc5237fe57d98489f"; };
    deps = [ world htslib zlib base.nixChain.bzip2 base.nixChain.xz base.nixChain.curl ]; nativeTools = [ bzip2-bin perl python3 ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --with-htslib=${htslib}
      gmake -j8; gmake install
      ${chk ''"$out/bin/bcftools" --version'' "^bcftools 1\\.22$"}
      printf '##fileformat=VCFv4.2\n##contig=<ID=1,length=1000>\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n1\t10\t.\tA\tG\t50\tPASS\t.\n1\t20\t.\tC\tT\t50\tPASS\t.\n' > "$W/t.vcf"
      ${chk ''"$out/bin/bcftools" view -Ob -o "$W/t.bcf" "$W/t.vcf" && "$out/bin/bcftools" view -H "$W/t.bcf" | wc -l | tr -d " "'' "^2$"}
      ${chk ''BCFTOOLS_PLUGINS="$out/libexec/bcftools" "$out/bin/bcftools" +counts "$W/t.vcf"'' "Number of SNPs:[[:space:]]+2"}
    '';
  };

  # seqtk (MIT): FASTA/FASTQ sequence processing, on zlib, as nixpkgs (its Makefile; -Wno-format as nixpkgs' hardening).
  seqtk = mkSrcPkg {
    pname = "seqtk"; version = "1.5";
    src = { url = "https://codeload.github.com/lh3/seqtk/tar.gz/refs/tags/v1.5";
            sha256 = "384aa1e3cecf4f70403839d586cbb29d469b7c6f773a64bc5af48a6e4b8220a6"; };
    deps = [ world zlib ]; nativeTools = hostTools;
    build = ''
      mkdir -p "$out/bin"; gmake CC="$CC" BINDIR="$out/bin"; gmake install CC="$CC" BINDIR="$out/bin"
      printf '@r1\nACGTNacgt\n+\nIIIIIIIII\n' > "$W/t.fq"
      ${chk ''"$out/bin/seqtk" seq -A "$W/t.fq" && "$out/bin/seqtk" seq -r "$W/t.fq" | sed -n 2p'' "^acgtNACGT$"}
    '';
  };

  # sshping (MIT): ssh round-trip latency of a character echo, on R19's libssh, built as nixpkgs (one compile). The check runs its
  # usage text (a run needs a server). -O2, as nixpkgs' stdenv adds to that compile: at -O0 an uninlined libstdc++ assertion names
  # gcc's stl_vector.h path in .rodata (the closure gate refused the build-time gcc reference).
  sshping = mkSrcPkg {
    pname = "sshping"; version = "0.1.4";
    src = { url = "https://codeload.github.com/spook/sshping/tar.gz/refs/tags/v0.1.4";
            sha256 = "589623e3fbe88dc1d423829e821f9d57f09aef0d9a2f04b7740b50909217863a"; };
    deps = [ world libssh ]; nativeTools = hostTools;
    build = ''
      mkdir -p "$out/bin"; "$CXX" -O2 -Wall -I ext/ -o "$out/bin/sshping" src/sshping.cxx -lssh
      ${chk ''"$out/bin/sshping" --help'' "Usage: sshping \\[options\\]"}
    '';
  };

  # xfs (MIT and others): the X font server, on R19's libXfont2, as nixpkgs. Its config's default font path is X.Org's
  # share/fonts dirs under its own prefix (configure's default); the check validates the shipped config and prints the version.
  xfs = mkSrcPkg {
    pname = "xfs"; version = "1.2.2";
    src = { url = "https://www.x.org/releases/individual/app/xfs-1.2.2.tar.xz";
            sha256 = "b70bd46331e241b30e5e00dbdc2eabb7f3f8880cd44244acde13d7976d098ecc"; };
    deps = [ world libxfont_2 freetype libfontenc zlib ]; linkDeps = [ base.xorgproto xtrans ] ++ ftPriv; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" ${manSections}
      gmake -j8; gmake install
      ${chk ''"$out/bin/xfs" -version'' "^xfs 1\\.2\\.2$"}
    '';
  };

  # sparsehash (BSD-3-Clause): Google's sparse/dense hash maps (header-only, with its pkg-config file), as nixpkgs.
  sparsehash = mkSrcPkg {
    pname = "sparsehash"; version = "2.0.4";
    src = { url = "https://codeload.github.com/sparsehash/sparsehash/tar.gz/refs/tags/sparsehash-2.0.4";
            sha256 = "8cd1a95827dfd8270927894eb77f62b4087735cbede953884647f16c521c7e58"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64"
      gmake -j8; gmake install
      cat > "$W/t.cc" <<'TPROG'
#include <sparsehash/dense_hash_map>
#include <sparsehash/sparse_hash_set>
#include <iostream>
int main(){ google::dense_hash_map<int, int> m; m.set_empty_key(-1); for (int i = 0; i < 100; i++) m[i] = i * 2;
google::sparse_hash_set<int> s; s.insert(1); s.insert(1); s.insert(2); std::cout << "ok " << m.size() << " " << m[21] << " " << s.size() << "\n"; }
TPROG
      "$CXX" -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 100 42 2$"}
    '';
  };

  # libb64 (public domain): base64 encode/decode routines and the base64 command, nixpkgs' four upstream patches and layout (the
  # static library, its two objects, the headers).
  libb64 = mkSrcPkg {
    pname = "libb64"; version = "2.0.0.1";
    src = { url = "https://codeload.github.com/libb64/libb64/tar.gz/refs/tags/v2.0.0.1";
            sha256 = "ce8e578a953a591bd4a6f157eec310b9a4c2e6f10ade2fdda6ae6bafaf798b98"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      for p in ${fetch "https://github.com/libb64/libb64/commit/4fe47c052e9123da8f751545deb48be08c3411f6.patch?full_index=1" "3c91441434896a591a125c91de5a260b3ffc2d212bcfde300632f4a06f05033b"} \
               ${fetch "https://github.com/libb64/libb64/commit/819e43c8b34261ea3ee694bdc27865a033966083.patch?full_index=1" "7a718f124f8930bf85132a657d87ba8e309e0405f68d1fa98ec9cda096830def"} \
               ${fetch "https://github.com/libb64/libb64/commit/b5edeafc89853c48fa41a4c16393a1fdc8638ab6.patch?full_index=1" "388bdfcd4f153dfd1b6e6e10b34c3ab4c6bd84ef461aa1d34c545a514a8b79f3"} \
               ${fetch "https://github.com/libb64/libb64/commit/98eaf510f40e384b32c01ad4bd5c3a697fdd8560.patch?full_index=1" "283f46b6fbe7a9043b5902e57fad962a465b27ebb7c7d13f74e5915050e4b165"}; do patch -p1 < "$p"; done
      gmake -j8 CC="$CC" all_src all_base64
      mkdir -p "$out/lib" "$out/bin" "$out/include"; cp -r include/* "$out/include/"; cp base64/base64 "$out/bin/"; cp src/libb64.a src/cencode.o src/cdecode.o "$out/lib/"
      ${chk ''printf solnix > "$W/i"; "$out/bin/base64" -e "$W/i" "$W/o" && cat "$W/o"'' "^c29sbml4"}
    '';
  };

  # libyubikey (BSD-2-Clause): Yubico's low-level OTP token library (AES, CRC, modhex) and modhex/ykparse/ykgenerate, as nixpkgs. Its
  # gnulib version-script probe says no on illumos: --enable-ld-version-script and the mapfile shim (YUBIKEY_1.0 .. 1.6 nodes).
  libyubikey = mkSrcPkg {
    pname = "libyubikey"; version = "1.13";
    src = { url = "https://developers.yubico.com/yubico-c/Releases/libyubikey-1.13.tar.gz";
            sha256 = "04edd0eb09cb665a05d808c58e1985f25bb7c5254d2849f36a0658ffc51c3401"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${vsMap}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-ld-version-script
      gmake -j8; gmake install
      L="$out/lib/amd64/libyubikey.so.0"
      ${hasVer "$L" "YUBIKEY_1.0" "yubikey_modhex_encode"}
      ${hasVer "$L" "YUBIKEY_1.6" "yubikey_generate"}
      ${chk ''"$out/bin/modhex" -h 0123456789abcdef'' "^cbdefghijklnrtuv$"}
    '';
  };

  # libmpcdec (BSD-3-Clause): the Musepack SV7 decoder library, as nixpkgs (memcmp probe answered). Its 2006 config.guess predates
  # x86_64 Solaris naming checks: --build given.
  libmpcdec = mkSrcPkg {
    pname = "libmpcdec"; version = "1.2.6";
    src = { url = "https://files.musepack.net/source/libmpcdec-1.2.6.tar.bz2";
            sha256 = "4bd54929a80850754f27b568d7891e1e3e1b8d2f208d371f27d1fda09e6f12a8"; };
    deps = [ world ]; nativeTools = [ bzip2-bin ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --build=x86_64-pc-solaris2.11 ac_cv_func_memcmp_working=yes
      gmake -j8; gmake install
      # no stream: the stream-info reader rejects 16 zero bytes (ERROR_CODE_INVALIDSV), through a memory reader
      ${tprog ''#include <mpcdec/mpcdec.h>
#include <stdio.h>
#include <string.h>
static unsigned char buf[64]; static int pos;
static mpc_int32_t rd(void *t, void *p, mpc_int32_t n){ (void)t; if (pos + n > 64) n = 64 - pos; memcpy(p, buf + pos, n); pos += n; return n; }
static mpc_bool_t sk(void *t, mpc_int32_t o){ (void)t; pos = o; return 1; } static mpc_int32_t tl(void *t){ (void)t; return pos; }
static mpc_int32_t sz(void *t){ (void)t; return 64; } static mpc_bool_t cs(void *t){ (void)t; return 1; }
int main(void){ mpc_reader r = { rd, sk, tl, sz, cs, NULL }; mpc_streaminfo si; mpc_streaminfo_init(&si); printf("ok %d\n", mpc_streaminfo_read(&si, &r) != ERROR_CODE_OK); return 0; }'' "$out/lib/amd64/libmpcdec.so"}
      ${chk ''"$W/t"'' "^ok 1$"}
    '';
  };

  # pegtl (BSL-1.0): taocpp's header-only Parsing Expression Grammar Template Library, with its cmake package, as nixpkgs.
  pegtl = mkSrcPkg {
    pname = "pegtl"; version = "3.2.8";
    src = { url = "https://codeload.github.com/taocpp/PEGTL/tar.gz/refs/tags/3.2.8";
            sha256 = "319e8238daebc3a163f60c88c78922a8012772076fdd64a8dafaf5619cd64773"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DPEGTL_BUILD_TESTS=OFF -DPEGTL_BUILD_EXAMPLES=OFF"}
      cat > "$W/t.cc" <<'TPROG'
#include <tao/pegtl.hpp>
#include <iostream>
namespace pegtl = tao::pegtl;
struct num : pegtl::plus<pegtl::digit> {}; struct grammar : pegtl::seq<num, pegtl::star<pegtl::one<','>, num>, pegtl::eof> {};
int main(){ pegtl::memory_input in("1,22,333", "t"); pegtl::memory_input bad("1,,2", "t");
std::cout << "ok " << pegtl::parse<grammar>(in) << " " << pegtl::parse<grammar>(bad) << "\n"; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 1 0$"}
      ls "$out/share/pegtl/cmake/pegtl-config.cmake" > /dev/null
    '';
  };

  # protozero (BSD-2-Clause / Apache-2.0): Mapbox's minimal header-only protocol buffers encoder/decoder, as nixpkgs.
  protozero = mkSrcPkg {
    pname = "protozero"; version = "1.8.2";
    src = { url = "https://codeload.github.com/mapbox/protozero/tar.gz/refs/tags/v1.8.2";
            sha256 = "68d1df951b4d8397355c8fc9ffed40d9c06282a877fe847403feac6edcee3ef1"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_TESTING=OFF"}
      cat > "$W/t.cc" <<'TPROG'
#include <protozero/pbf_writer.hpp>
#include <protozero/pbf_reader.hpp>
#include <iostream>
#include <string>
int main(){ std::string b; { protozero::pbf_writer w{b}; w.add_string(1, "solnix"); w.add_uint32(2, 300); }
protozero::pbf_reader r{b}; std::string s; unsigned n = 0; while (r.next()) { if (r.tag() == 1) s = r.get_string(); else n = r.get_uint32(); }
std::cout << "ok " << s << " " << n << " " << b.size() << "\n"; }
TPROG
      "$CXX" -std=c++14 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok solnix 300 11$"}
    '';
  };

  # microsoft-gsl (MIT): the C++ Core Guidelines Support Library (gsl::span, not_null, narrow), header-only, as nixpkgs (tests off:
  # they fetch googletest).
  microsoft-gsl = mkSrcPkg {
    pname = "microsoft-gsl"; version = "4.2.2";
    src = { url = "https://codeload.github.com/Microsoft/GSL/tar.gz/refs/tags/v4.2.2";
            sha256 = "59e2a0a0ea22e8bcf9db2dc4d4bd21212ac6595748295fc27a7e02cf75eac4b5"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DGSL_TEST=OFF"}
      cat > "$W/t.cc" <<'TPROG'
#include <gsl/gsl>
#include <iostream>
int main(){ int a[] = { 1, 2, 3, 4 }; gsl::span<int> s{a}; gsl::not_null<int*> p{&a[2]}; int bad = 0;
try { (void)gsl::narrow<unsigned char>(300); } catch (const gsl::narrowing_error&) { bad = 1; }
std::cout << "ok " << s.size() << " " << *p << " " << bad << "\n"; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 4 3 1$"}
    '';
  };

  # libdivsufsort (MIT): suffix-array construction (32- and 64-bit libraries), shared, as nixpkgs (cmake policy floor bumped). Its
  # install dirs are a literal "lib": lib/amd64. Its VERSION file says 2.0.0 in the 2.0.1 tag, so divsufsort_version() does.
  libdivsufsort = mkSrcPkg {
    pname = "libdivsufsort"; version = "2.0.1";
    src = { url = "https://codeload.github.com/y-256/libdivsufsort/tar.gz/refs/tags/2.0.1";
            sha256 = "9164cb6044dcb6e430555721e3318d5a8f38871c2da9fd9256665746a69351e0"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      [ "$(grep -c 'DESTINATION lib$\|DESTINATION lib)$' lib/CMakeLists.txt)" = 4 ] && [ "$(grep -c 'DESTINATION lib/pkgconfig)$' pkgconfig/CMakeLists.txt)" = 2 ] \
        && grep -qx 'libdir=''${exec_prefix}/lib' pkgconfig/libdivsufsort.pc.cmake || { echo "FATAL: libdivsufsort libdir anchors" >&2; exit 1; }
      sed -i -e 's|DESTINATION lib$|DESTINATION lib/amd64|' -e 's|DESTINATION lib)$|DESTINATION lib/amd64)|' lib/CMakeLists.txt
      sed -i 's|DESTINATION lib/pkgconfig)$|DESTINATION lib/amd64/pkgconfig)|' pkgconfig/CMakeLists.txt
      sed -i 's|^libdir=''${exec_prefix}/lib$|libdir=''${exec_prefix}/lib/amd64|' pkgconfig/libdivsufsort.pc.cmake
      ${cmakeB "-DBUILD_DIVSUFSORT64=ON -DBUILD_EXAMPLES=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.10"}
      ${tprog ''#include <divsufsort.h>
#include <stdio.h>
int main(void){ const sauchar_t *t = (const sauchar_t *)"banana"; saidx_t sa[6]; if (divsufsort(t, sa, 6)) return 1;
printf("ok %s", divsufsort_version()); for (int i = 0; i < 6; i++) printf(" %d", (int)sa[i]); printf("\n"); return 0; }'' "$out/lib/amd64/libdivsufsort.so"}
      ${chk ''"$W/t"'' "^ok 2\\.0\\.0 5 3 1 0 4 2$"}
      [ -e "$out/lib/amd64/libdivsufsort64.so" ] || { echo "FATAL: no libdivsufsort64" >&2; exit 1; }
    '';
  };

  # strobealign (MIT): the strobemer-based short-read aligner, on zlib and R19's isa-l (pkg-config), nixpkgs' cstdint patch. The
  # check indexes a small reference and aligns a read taken from it.
  strobealign = mkSrcPkg {
    pname = "strobealign"; version = "0.17.0";
    src = { url = "https://codeload.github.com/ksahlin/strobealign/tar.gz/refs/tags/v0.17.0";
            sha256 = "d1797768bba3cfe1f4ac499ecc4654ac846dce5fade75f10abaad3b971eb1a3c"; };
    deps = [ world zlib isa-l ]; nativeTools = [ cmake gnupatch base.pkgconf python3 ] ++ hostTools;
    build = ''
      patch -p1 < ${npPatch "st/strobealign/include-cstdint.patch" "1d913047f5f9d9c71c193b76ea9542aa330ac3490976218a94af073e48520a15"}
      ${builtins.replaceStrings [ "cmake --build _b -j16" ] [ "cmake --build _b -j\${NIX_BUILD_CORES:-4}" ] (cmakeB "-DISAL=system")}
      grep -q "^ISAL_LIBDIR:INTERNAL=${isa-l}/" _b/CMakeCache.txt || { echo "FATAL: strobealign: isa-l not from the store" >&2; grep '^ISAL_' _b/CMakeCache.txt >&2; exit 1; }
      python3 -c 'import random; random.seed(7); s = "".join(random.choice("ACGT") for _ in range(5000)); open("'"$W"'/ref.fa", "w").write(">chr1\n" + s + "\n"); open("'"$W"'/r.fq", "w").write("@r1\n" + s[1000:1150] + "\n+\n" + "I" * 150 + "\n")'
      ${chk ''"$out/bin/strobealign" -t 1 "$W/ref.fa" "$W/r.fq" 2>/dev/null | grep -v "^@" | cut -f1-4'' "^r1	0	chr1	1001$"}
    '';
  };

  # cherry (MIT): a small bitmap font, built with R19's fonttosfnt into OpenType bitmap (.otb) files and indexed with mkfontdir, as
  # nixpkgs.
  cherry = mkSrcPkg {
    pname = "cherry"; version = "1.4";
    src = { url = "https://codeload.github.com/turquoise-hexagon/cherry/tar.gz/refs/tags/1.4";
            sha256 = "984191a0b305832b95bd3036cd8b7ab07cac8a0dd05ba440d6be9ffbdd8434df"; };
    deps = [ world ]; nativeTools = [ fonttosfnt mkfontscale ] ++ hostTools;
    build = ''
      "$BASH" ./make.sh
      mkdir -p "$out/share/fonts/misc"; cp *.otb "$out/share/fonts/misc/"; mkfontdir "$out/share/fonts/misc"
      ${chk ''ls "$out/share/fonts/misc"/*.otb | wc -l | tr -d " "; head -1 "$out/share/fonts/misc/fonts.dir"'' "^[1-9][0-9]*$"}
    '';
  };

  # rtrlib (MIT): the RPKI-RTR client library (route origin validation) and rtrclient/rpki-rov, with SSH transport on R19's libssh,
  # as nixpkgs (cmake policy floor). -fstack-protector-all needs libssp, which gcc.lib does not ship: dropped. bzero (its library and
  # its always-built tests) and its bundled mustach's alloca are declared only in <strings.h> / <alloca.h> on illumos: both included
  # for the whole build, so the library's own bzero needs no edit.
  rtrlib = mkSrcPkg {
    pname = "rtrlib"; version = "0.8.0";
    src = { url = "https://codeload.github.com/rtrlib/rtrlib/tar.gz/refs/tags/v0.8.0";
            sha256 = "8cc99343dc3ea8908cd9710ba1f72a1ddce591bf80bfd7d656dbc4568f560ada"; };
    deps = [ world libssh ]; nativeTools = [ cmake base.pkgconf ] ++ hostTools;
    build = ''
      grep -q '^set(CMAKE_C_FLAGS "''${CMAKE_C_FLAGS} -Wall -std=gnu99 -fstack-protector-all")$' CMakeLists.txt || { echo "FATAL: rtrlib ssp anchor" >&2; exit 1; }
      sed -i 's/ -fstack-protector-all")$/")/' CMakeLists.txt
      ${cmakeB "-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DRTRLIB_TRANSPORT_SSH=ON '-DCMAKE_C_FLAGS=-include strings.h -include alloca.h' -DCMAKE_EXE_LINKER_FLAGS='-lsocket -lnsl' -DCMAKE_SHARED_LINKER_FLAGS='-lsocket -lnsl'"}
      grep -q "^LIBSSH_LIBDIR:INTERNAL=${libssh}/" _b/CMakeCache.txt || { echo "FATAL: rtrlib: libssh not from the store" >&2; grep '^LIBSSH_' _b/CMakeCache.txt >&2; exit 1; }
      ${tprog ''#include <rtrlib/rtrlib.h>
#include <stdio.h>
int main(void){ struct lrtr_ip_addr a; char s[64]; if (lrtr_ip_str_to_addr("2001:db8::1", &a) || lrtr_ip_addr_to_str(&a, s, sizeof s)) return 1; printf("ok %s\n", s); return 0; }'' "$out/lib/amd64/librtr.so"}
      ${chk ''"$W/t"'' "^ok 2001:db8::1$"}
      ${chk ''"$out/bin/rtrclient" -h'' "^Usage:$"}
    '';
  };

  # libconfig (LGPL-2.1+ by its COPYING.LIB and headers; nixpkgs records LGPL-3.0; not GPL either way): structured configuration
  # files, C and C++ libraries, as nixpkgs (examples and tests off).
  libconfig = mkSrcPkg {
    pname = "libconfig"; version = "1.8.3";
    src = { url = "https://hyperrealm.github.io/libconfig/dist/libconfig-1.8.3.tar.gz";
            sha256 = "0ed3e37db12e38b6fd7ca85775283412043069da2edcdb0c0ddcf9160a5dcc71"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-examples --disable-tests LDFLAGS="-L$gccLib/amd64"
      gmake -j8; gmake install
      ${tprog ''#include <libconfig.h>
#include <stdio.h>
int main(void){ config_t c; int n = 0; const char *s = NULL; config_init(&c);
if (!config_read_string(&c, "os = \"solnix\"; cores = 16; list = (1, 2, 3);")) return 1; config_lookup_int(&c, "cores", &n); config_lookup_string(&c, "os", &s);
printf("ok %s %d %d\n", s, n, config_setting_length(config_lookup(&c, "list"))); config_destroy(&c); return 0; }'' "$out/lib/amd64/libconfig.so"}
      ${chk ''"$W/t"'' "^ok solnix 16 3$"}
    '';
  };

  # ---- recipes11 batch 21: small leaves the x86 queue has jobs for (every source = nixpkgs f4a03c0's, by hash) --------------------
  # mcpp (BSD-2-Clause): Matsui's C/C++ preprocessor, the mcpp command on its libmcpp, as nixpkgs (--enable-mcpplib; its upstream
  # readlink <unistd.h> fix; gcc 14's incompatible-pointer-types an error no more).
  mcpp = mkSrcPkg {
    pname = "mcpp"; version = "2.7.2.3";
    src = { url = "https://github.com/museoa/mcpp/archive/2.7.2.3.tar.gz";
            sha256 = "4f44a3f94abdaf9c31d1c7970b1480c730306034b4850bad963b6150860b8d7f"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${npPatch "mc/mcpp/readlink.patch" "faacc115bc0d50bf83c70dc6821c6122284d1f05933965e0cd6b9e397d859228"}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-mcpplib CFLAGS="-O2 -Wno-error=incompatible-pointer-types"
      gmake -j8; gmake install
      printf '#define SOL(x) x + nix\nSOL(sol)\n' > "$W/t.c"
      ${chk ''"$out/bin/mcpp" -P "$W/t.c"'' "^sol \\+ nix$"}
    '';
  };

  # libunibreak (Zlib): line, word and grapheme breaking per Unicode UAX #14/#29, autotools from the tag (autoreconf), as nixpkgs.
  libunibreak = mkSrcPkg {
    pname = "libunibreak"; version = "7.0";
    src = { url = "https://github.com/adah1972/libunibreak/archive/refs/tags/libunibreak_7_0.tar.gz";
            sha256 = "e4cb1a0d9aebb129c9856ec75e3d98e675997e385cce4e0106ef8f68e09afaa3"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j8; gmake install
      # "ab cd": no break inside "ab" (b[0] = LINEBREAK_NOBREAK 2), one allowed after the space (b[2] = ALLOWBREAK 1), and the text
      # ends on a non-EOL char (b[4] = LINEBREAK_INDETERMINATE 4)
      ${tprog ''#include <linebreak.h>
#include <stdio.h>
int main(void){ char b[5]; init_linebreak(); set_linebreaks_utf8((const utf8_t *)"ab cd", 5, "en", b); printf("ok %d %d %d\n", b[0], b[2], b[4]); return 0; }'' "$out/lib/amd64/libunibreak.so"}
      ${chk ''"$W/t"'' "^ok 2 1 4$"}
    '';
  };

  # cmark-gfm (BSD-2-Clause): GitHub's fork of the CommonMark reference parser with the GFM extensions (tables, strikethrough,
  # autolinks), cmake, shared, tests off, as nixpkgs. Its cmake_minimum_required(2.8.9) is refused by cmake 4: policy floor 3.5.
  # It builds -std=c99 -pedantic, and illumos <strings.h> then hides strncasecmp (XPG): -D__EXTENSIONS__ (extensions/autolink.c).
  cmark-gfm = mkSrcPkg {
    pname = "cmark-gfm"; version = "0.29.0.gfm.13";
    src = { url = "https://github.com/github/cmark-gfm/archive/0.29.0.gfm.13.tar.gz";
            sha256 = "5abc61798ebd9de5660bc076443c07abad2b8d15dbc11094a3a79644b8ad243a"; };
    deps = [ world ]; nativeTools = [ cmake python3 ] ++ hostTools;
    build = ''
      ${cmakeB "-DCMARK_TESTS=OFF -DCMARK_STATIC=OFF -DCMARK_SHARED=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_C_FLAGS=-D__EXTENSIONS__"}
      printf '| a | b |\n|---|---|\n| ~~x~~ | 2 |\n' > "$W/t.md"
      ${chk ''"$out/bin/cmark-gfm" -e table -e strikethrough "$W/t.md" | tr -d '\n' '' "<td><del>x</del></td><td>2</td>"}
    '';
  };

  # clipper2 (BSL-1.0): polygon clipping and offsetting, the C++ library (CPP/), shared, examples and tests off, as nixpkgs.
  clipper2 = mkSrcPkg {
    pname = "clipper2"; version = "2.0.1";
    src = { url = "https://github.com/AngusJohnson/Clipper2/archive/refs/tags/Clipper2_2.0.1.tar.gz";
            sha256 = "2a3693aceab4aed3e39b743e038d87701acc53cf05ed7b2013aab3e0aec5287e"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      cd CPP
      ${cmakeB "-DCLIPPER2_EXAMPLES=OFF -DCLIPPER2_TESTS=OFF -DCLIPPER2_UTILS=OFF -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_INCLUDEDIR=include"}
      # two overlapping 10x10 squares: their intersection is a 5x10 rectangle, area 50
      cat > "$W/t.cc" <<'TPROG'
#include <clipper2/clipper.h>
#include <cstdio>
using namespace Clipper2Lib;
int main(){ Paths64 a{MakePath({0,0, 10,0, 10,10, 0,10})}, b{MakePath({5,0, 15,0, 15,10, 5,10})};
Paths64 r = Intersect(a, b, FillRule::NonZero); std::printf("ok %zu %.0f\n", r.size(), Area(r)); return 0; }
TPROG
      "$CXX" -I"$out/include" "$W/t.cc" -L"$out/lib/amd64" -lClipper2 -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 1 50$"}
    '';
  };

  # libxcvt (MIT): the VESA CVT mode-line calculator (X servers, cvt), meson, as nixpkgs.
  libxcvt = mkSrcPkg {
    pname = "libxcvt"; version = "0.1.3";
    src = { url = "https://www.x.org/releases/individual/lib/libxcvt-0.1.3.tar.xz";
            sha256 = "a929998a8767de7dfa36d6da4751cdbeef34ed630714f2f4a767b351f2442e01"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild ""}
      ${chk ''"$out/bin/cvt" 1920 1080 60'' "^Modeline \"1920x1080_60\\.00\" +173\\.00 +1920 2048 2248 2576 +1080 1083 1088 1120 -hsync \\+vsync$"}
    '';
  };

  # libopusenc (BSD-3-Clause): the high-level Ogg Opus file encoder on the served libopus, autotools from the tag (its version file is
  # made by update_version from git, absent in an archive: given as package_version, as upstream's release tarballs carry it).
  libopusenc = mkSrcPkg {
    pname = "libopusenc"; version = "0.3";
    src = { url = "https://gitlab.xiph.org/xiph/libopusenc/-/archive/v0.3/libopusenc-v0.3.tar.gz";
            sha256 = "e4258441c1b5917656d8d9eba838499b55d09d7095ac4cf4fbc6c1afe03060d8"; };
    deps = [ world libopus ]; nativeTools = autoreconfTools ++ [ base.pkgconf ] ++ hostTools;
    build = ''
      echo 'PACKAGE_VERSION="0.3"' > package_version
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-doc --disable-examples
      gmake -j8; gmake install
      # one second of silence, 48 kHz stereo, into an Ogg Opus file: it starts with the Ogg page magic and its OpusHead
      ${tprog ''#include <opus/opusenc.h>
#include <stdio.h>
int main(void){ int e; static opus_int16 pcm[48000 * 2]; OggOpusComments *c = ope_comments_create();
OggOpusEnc *enc = ope_encoder_create_file("t.opus", c, 48000, 2, 0, &e); if (!enc) return 1;
ope_encoder_write(enc, pcm, 48000); ope_encoder_drain(enc); ope_encoder_destroy(enc); ope_comments_destroy(c);
printf("ok %s\n", ope_get_version_string()); return 0; }'' "-lopusenc -I${libopus}/include/opus -L${libopus}/lib/amd64 -lopus -Wl,-R,${libopus}/lib/amd64"}
      ${chk ''cd "$W" && ./t'' "^ok libopusenc 0\\.3$"}
      ${chk ''od -An -c -N4 "$W/t.opus"'' "O +g +g +S"}
    '';
  };

  # plutosvg (MIT): a tiny SVG renderer on plutovg (wave7 T6), cmake, shared, no FreeType, as nixpkgs.
  plutosvg = mkSrcPkg {
    pname = "plutosvg"; version = "0.0.8";
    src = { url = "https://github.com/sammycage/plutosvg/archive/refs/tags/v0.0.8.tar.gz";
            sha256 = "49d5cfe772d3aa10cd4879f2f6e189f5083c08e4c8ea01bf3d5b87c97dfca7d2"; };
    deps = [ world plutovg ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DPLUTOSVG_ENABLE_FREETYPE=OFF -DPLUTOSVG_BUILD_EXAMPLES=OFF -DCMAKE_INSTALL_INCLUDEDIR=include"}
      grep -q "^plutovg_DIR:PATH=${plutovg}/" _b/CMakeCache.txt || { echo "FATAL: plutosvg: plutovg not from the store" >&2; grep plutovg _b/CMakeCache.txt >&2; exit 1; }
      # a 16x16 SVG with a red 8x8 rect: rendered, the pixel inside is opaque red (ARGB32 premultiplied), outside clear
      ${tprog ''#include <plutosvg.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
static const char svg[] = "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect width='8' height='8' fill='red'/></svg>";
int main(void){ plutosvg_document_t *d = plutosvg_document_load_from_data(svg, strlen(svg), -1, -1, NULL, NULL); if (!d) return 1;
plutovg_surface_t *s = plutosvg_document_render_to_surface(d, NULL, -1, -1, NULL, NULL, NULL); if (!s) return 1;
const uint32_t *p = (const uint32_t *)plutovg_surface_get_data(s); int st = plutovg_surface_get_stride(s) / 4;
printf("ok %s %08x %08x\n", plutosvg_version_string(), p[2 * st + 2], p[12 * st + 12]); return 0; }'' "-I$out/include/plutosvg -I${plutovg}/include/plutovg -L${plutovg}/lib/amd64 -Wl,-R,${plutovg}/lib/amd64 $out/lib/amd64/libplutosvg.so -lplutovg"}
      ${chk ''"$W/t"'' "^ok 0\\.0\\.8 ffff0000 00000000$"}
    '';
  };

  # lunasvg (MIT): an SVG rendering library in C++ on the packaged plutovg (USE_SYSTEM_PLUTOVG), cmake, shared, as nixpkgs.
  lunasvg = mkSrcPkg {
    pname = "lunasvg"; version = "3.5.0";
    src = { url = "https://github.com/sammycage/lunasvg/archive/refs/tags/v3.5.0.tar.gz";
            sha256 = "1abf1472ee6c4d19797916e8cc3c2e4b628e0d81178ffac60bdb0d457e32c690"; };
    deps = [ world plutovg ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DUSE_SYSTEM_PLUTOVG=ON -DBUILD_SHARED_LIBS=ON -DLUNASVG_BUILD_EXAMPLES=OFF -DCMAKE_INSTALL_INCLUDEDIR=include"}
      grep -q "^plutovg_DIR:PATH=${plutovg}/" _b/CMakeCache.txt || { echo "FATAL: lunasvg: plutovg not from the store" >&2; grep plutovg _b/CMakeCache.txt >&2; exit 1; }
      cat > "$W/t.cc" <<'TPROG'
#include <lunasvg.h>
#include <cstdio>
int main(){ auto d = lunasvg::Document::loadFromData("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect width='8' height='8' fill='red'/></svg>");
if (!d) return 1; auto b = d->renderToBitmap(); if (b.isNull()) return 1; const unsigned *p = (const unsigned *)b.data(); int st = b.stride() / 4;
std::printf("ok %s %08x %08x\n", lunasvg_version_string(), p[2 * st + 2], p[12 * st + 12]); return 0; }
TPROG
      "$CXX" -I"$out/include/lunasvg" "$W/t.cc" -L"$out/lib/amd64" -llunasvg -Wl,-R,"$out/lib/amd64" -Wl,-R,${plutovg}/lib/amd64 -o "$W/t"
      ${chk ''"$W/t"'' "^ok 3\\.5\\.0 ffff0000 00000000$"}
    '';
  };

  # qrcodegen (MIT): Project Nayuki's QR Code generator, the C library (c/), as nixpkgs: the static libqrcodegen.a, its header and a .pc.
  # Upstream's own test runs in the build (nixpkgs' checkPhase).
  qrcodegen = mkSrcPkg {
    pname = "qrcodegen"; version = "1.8.0";
    src = { url = "https://github.com/nayuki/QR-Code-generator/archive/v1.8.0.tar.gz";
            sha256 = "2ec0a4d33d6f521c942eeaf473d42d5fe139abcfa57d2beffe10c5cf7d34ae60"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      cd c
      sed -i 's/$(AR) -crs $@ -- $^/$(AR) -crs $@ $^/' Makefile   # illumos ar(1) takes no "--" end-of-options marker
      gmake CC="$CC" AR=ar CFLAGS="-std=c99 -O2" libqrcodegen.a qrcodegen-test
      ${chk "./qrcodegen-test" "^All [0-9]+ test cases passed$"}
      mkdir -p "$out/lib/amd64/pkgconfig" "$out/include/qrcodegen"
      cp libqrcodegen.a "$out/lib/amd64/"; cp qrcodegen.h "$out/include/qrcodegen/"
      printf '%s\n' "prefix=$out" 'includedir=''${prefix}/include/qrcodegen' 'libdir=''${prefix}/lib/amd64' "" "Name: qrcodegen" \
        "Description: QR Code generator library" "Version: 1.8.0" 'Cflags: -I''${includedir}' 'Libs: -L''${libdir} -lqrcodegen' > "$out/lib/amd64/pkgconfig/qrcodegen.pc"
      ${tprog ''#include <qrcodegen.h>
#include <stdio.h>
int main(void){ uint8_t q[qrcodegen_BUFFER_LEN_MAX], t[qrcodegen_BUFFER_LEN_MAX];
if (!qrcodegen_encodeText("solnix", t, q, qrcodegen_Ecc_LOW, qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO, true)) return 1;
printf("ok %d\n", qrcodegen_getSize(q)); return 0; }'' "-I$out/include/qrcodegen $out/lib/amd64/libqrcodegen.a"}
      ${chk ''"$W/t"'' "^ok 21$"}
    '';
  };

  # enet (MIT): a reliable UDP networking library, autotools (its release tarball's configure), shared, as nixpkgs. illumos keeps socket()
  # in libsocket.
  enet = mkSrcPkg {
    pname = "enet"; version = "1.3.18";
    src = { url = "http://enet.bespin.org/download/enet-1.3.18.tar.gz";
            sha256 = "2a8a0c5360d68bb4fcd11f2e4c47c69976e8d2c85b109dd7d60b1181a4f85d36"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static LIBS="-lsocket -lnsl"
      gmake -j8; gmake install
      # a host bound to loopback (an ephemeral port), then a client connect queued to it: both created, no network needed beyond lo0
      ${tprog ''#include <enet/enet.h>
#include <stdio.h>
int main(void){ if (enet_initialize()) return 1; ENetAddress a; enet_address_set_host_ip(&a, "127.0.0.1"); a.port = ENET_PORT_ANY;
ENetHost *s = enet_host_create(&a, 2, 1, 0, 0), *c = enet_host_create(NULL, 1, 1, 0, 0); if (!s || !c) return 1;
printf("ok %u %d\n", enet_linked_version() == ENET_VERSION, enet_host_connect(c, &s->address, 1, 0) != NULL); enet_deinitialize(); return 0; }'' "$out/lib/amd64/libenet.so"}
      ${chk ''"$W/t"'' "^ok 1 1$"}
    '';
  };

  # immer (BSL-1.0): persistent immutable data structures for C++, header-only, cmake install of the headers and its cmake package; tests,
  # examples, docs and extras off, as nixpkgs.
  immer = mkSrcPkg {
    pname = "immer"; version = "0.9.1";
    src = { url = "https://github.com/arximboldi/immer/archive/refs/tags/v0.9.1.tar.gz";
            sha256 = "b18b92ba60ec3186dc36ef671d3c2ae542cbb63eb6dc0e258476c6111a67c971"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-Dimmer_BUILD_TESTS=OFF -Dimmer_BUILD_EXAMPLES=OFF -Dimmer_BUILD_DOCS=OFF -Dimmer_BUILD_EXTRAS=OFF -DCMAKE_INSTALL_INCLUDEDIR=include"}
      cat > "$W/t.cc" <<'TPROG'
#include <immer/vector.hpp>
#include <cstdio>
int main(){ const auto v0 = immer::vector<int>{}; const auto v1 = v0.push_back(13).push_back(29); std::printf("ok %zu %zu %d\n", v0.size(), v1.size(), v1[1]); return 0; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 0 2 29$"}
    '';
  };

  # jsoncons (BSL-1.0): a header-only C++ library for JSON and JSON-like formats (CBOR, MessagePack, ...), cmake install, as nixpkgs.
  jsoncons = mkSrcPkg {
    pname = "jsoncons"; version = "1.9.0";
    src = { url = "https://github.com/danielaparker/jsoncons/archive/refs/tags/v1.9.0.tar.gz";
            sha256 = "f1017b36e4e034acd5c0f5f616bacf5d7a161d6d3a43ff9ddb73fd8dca4d3cd9"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DJSONCONS_BUILD_TESTS=OFF -DCMAKE_INSTALL_INCLUDEDIR=include"}
      cat > "$W/t.cc" <<'TPROG'
#include <jsoncons/json.hpp>
#include <iostream>
int main(){ auto j = jsoncons::json::parse(R"({"os":"solnix","n":[1,2,3]})"); std::cout << "ok " << j["os"].as<std::string>() << " " << j["n"].size() << std::endl; return 0; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok solnix 3$"}
    '';
  };

  # small (BSL-1.0): C++ small-buffer containers (small::vector, small::string), header-only, cmake install, as nixpkgs.
  small = mkSrcPkg {
    pname = "small"; version = "0.2.2";
    src = { url = "https://github.com/alandefreitas/small/archive/refs/tags/v0.2.2.tar.gz";
            sha256 = "4b8bbc2f5879178a387a10c36619ea54ed2228cf33a9a38aa0534dbd95b6c41d"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DSMALL_BUILD_TESTS=OFF -DSMALL_BUILD_EXAMPLES=OFF -DSMALL_BUILD_INSTALLER=ON -DSMALL_BUILD_PACKAGE=OFF -DSMALL_BUILD_DOCS=OFF -DCMAKE_INSTALL_INCLUDEDIR=include"}
      cat > "$W/t.cc" <<'TPROG'
#include <small/vector.hpp>
#include <cstdio>
int main(){ small::vector<int, 5> v = {1, 2, 3}; v.push_back(4); std::printf("ok %zu %d\n", v.size(), v[3]); return 0; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 4 4$"}
    '';
  };


  # ---- recipes12 batch 22: small leaves the x86 queue has jobs for (every source = nixpkgs f4a03c0's, by hash) --------------------
  # libsixel (MIT): the DEC SIXEL codec and its img2sixel/sixel2png converters, meson with its own tests, as nixpkgs (gd, jpeg and png
  # off: stb_image loads the images). Its config.h sets _POSIX_C_SOURCE 199309L, under which illumos <sys/time.h> hides struct timeval
  # (tty.c): -D__EXTENSIONS__.
  libsixel = mkSrcPkg {
    pname = "libsixel"; version = "1.10.5";
    src = { url = "https://github.com/libsixel/libsixel/archive/v1.10.5.tar.gz";
            sha256 = "b6654928bd423f92e6da39eb1f40f10000ae2cc6247247fc1882dcff6acbdfc8"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild "-Dtests=enabled -Dimg2sixel=enabled -Dsixel2png=enabled -Dgd=disabled -Djpeg=disabled -Dpng=disabled -Dgdk-pixbuf2=disabled -Dlibcurl=disabled -Dpython=disabled -Dc_args=-D__EXTENSIONS__"}
      mrc=0; meson test -C _b --print-errorlogs > "$W/mt.log" 2>&1 || mrc=$?   # set -e: keep the rc
      [ $mrc = 0 ] || { echo "FATAL: libsixel meson test rc=$mrc" >&2; tail -60 "$W/mt.log" >&2; exit 1; }
      # a JPEG to SIXEL (it starts with the DCS introducer ESC P) and back to a PNG (its 8-byte signature)
      "$out/bin/img2sixel" -w 32 images/snake.jpg > "$W/s.six"
      ${chk ''head -c 2 "$W/s.six" | od -An -tx1'' "^ *1b 50 *$"}
      "$out/bin/sixel2png" < "$W/s.six" > "$W/s.png"
      ${chk ''head -c 4 "$W/s.png" | od -An -tx1'' "^ *89 50 4e 47 *$"}
    '';
  };

  # libzen (BSD-2-Clause): MediaArea's C++ utility library (libmediainfo's base), autotools in Project/GNU/Library, as nixpkgs.
  # Thread.cpp keeps the thread id in a void* (pthread_create((pthread_t*)&ThreadPointer, ...), after ThreadPointer = NULL) and casts it
  # back with (pthread_t)ThreadPointer: a 4-byte uint on illumos, so gcc refuses the narrowing cast. Through uintptr_t it is the id the
  # call stored (little-endian low bytes of a zeroed pointer). -L gcc.lib: libtool's C++ link would bake libstdc++.la's dir in as -R.
  libzen = mkSrcPkg {
    pname = "libzen"; version = "0.4.41";
    src = { url = "https://mediaarea.net/download/source/libzen/0.4.41/libzen_0.4.41.tar.bz2";
            sha256 = "eb237d7d3dca6dc6ba068719420a27de0934a783ccaeb2867562b35af3901e2d"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ [ bzip2-bin base.pkgconf ] ++ hostTools;
    build = ''
      [ "$(grep -c '(pthread_t)ThreadPointer' Source/ZenLib/Thread.cpp)" = 1 ] || { echo "FATAL: libzen pthread_t anchor" >&2; exit 1; }
      sed -i 's/(pthread_t)ThreadPointer/(pthread_t)(uintptr_t)ThreadPointer/' Source/ZenLib/Thread.cpp
      cd Project/GNU/Library
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-shared LDFLAGS="-L$gccLib/amd64"
      gmake -j8; gmake install
      cat > "$W/t.cc" <<'TPROG'
#include <ZenLib/Ztring.h>
#include <cstdio>
int main(){ ZenLib::Ztring z; z.From_Number(42); std::printf("ok %s %zu\n", z.To_UTF8().c_str(), z.size()); return 0; }
TPROG
      "$CXX" $(PKG_CONFIG_PATH="$out/lib/amd64/pkgconfig" pkg-config --cflags libzen) "$W/t.cc" "$out/lib/amd64/libzen.so" -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 42 2$"}
    '';
  };

  # mdds (MIT): multi-dimensional data structures (LibreOffice's), header-only, autotools from the tag, as nixpkgs (its pkg-config file
  # moved to lib/pkgconfig). Its headers include boost (a user supplies it): the check compiles against the served nix-chain boost, a
  # check input only, as in nixpkgs.
  mdds = mkSrcPkg {
    pname = "mdds"; version = "3.1.0";
    src = { url = "https://gitlab.com/mdds/mdds/-/archive/3.1.0/mdds-3.1.0.tar.gz";
            sha256 = "f19a1426ced40167faac97af366dc60d2b456ccf1d3ab56457a55749a57eecce"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out"
      gmake install
      mkdir -p "$out/lib"; mv "$out/share/pkgconfig" "$out/lib/"
      cat > "$W/t.cc" <<'TPROG'
#include <mdds/flat_segment_tree.hpp>
#include <cstdio>
int main(){ mdds::flat_segment_tree<int, int> t(0, 100, -1); t.insert_front(10, 20, 7); int v = 0; t.search(15, v); int w = 0; t.search(25, w);
std::printf("ok %d %d\n", v, w); return 0; }
TPROG
      "$CXX" -std=c++17 -I"$out/include/mdds-3.0" -I${base.nixChain.boost}/include "$W/t.cc" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 7 -1$"}
    '';
  };

  # tre (BSD-2-Clause): a POSIX regex library with approximate matching, and agrep, autotools from the tag. nixpkgs runs autopoint
  # (gettext); the served gettext ships no autopoint, so NLS is taken out of the build as in rpcsvc-proto (its 3 catalogs are not
  # installed; messages are English). It counts on glibc's <stdlib.h> declaring alloca(); illumos declares it in <alloca.h> only.
  tre = mkSrcPkg {
    pname = "tre"; version = "0.9.0";
    src = { url = "https://github.com/laurikari/tre/archive/refs/tags/v0.9.0.tar.gz";
            sha256 = "5b7e5a730f041c6b0dab8f66576cda917577ec06bb393f156b169c51bca170d1"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      [ "$(grep -c '^AM_GNU_GETTEXT' configure.ac)" = 2 ] && grep -qx 'po/Makefile.in' configure.ac \
        && grep -qx 'SUBDIRS = local_includes lib $(agrep_dirs) tests utils po m4' Makefile.am || { echo "FATAL: tre gettext anchors" >&2; exit 1; }
      sed -i -e '/^AM_GNU_GETTEXT/d' -e '/^po\/Makefile.in$/d' configure.ac
      sed -i 's/^SUBDIRS = local_includes lib $(agrep_dirs) tests utils po m4$/SUBDIRS = local_includes lib $(agrep_dirs) tests utils m4/' Makefile.am
      sed -i 's/ \$(LTLIBINTL)//' lib/Makefile.am src/Makefile.am tests/Makefile.am
      ! grep -q LTLIBINTL lib/Makefile.am src/Makefile.am tests/Makefile.am || { echo "FATAL: tre LTLIBINTL left" >&2; exit 1; }
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static CPPFLAGS="-include alloca.h"
      gmake -j8; gmake install
      # one error away: "solnux" finds "solnix", exact "solnux" finds nothing
      printf 'hello\nsolnix\n' > "$W/t.txt"
      ${chk ''"$out/bin/agrep" -1 solnux "$W/t.txt"; "$out/bin/agrep" solnux "$W/t.txt" || echo none'' "^solnix$"}
      grep -qx none "$W/chk.out" || { echo "FATAL: tre exact match should fail" >&2; exit 1; }
    '';
  };

  # discount (BSD-3-Clause): Orc's Markdown in C (markdown, mkd2html, makepage, theme) and libmarkdown, its own configure.sh, as nixpkgs:
  # its PATH patch, --shared --debian-glitch --pkg-config --h1-title, install.everything, `make test`. illumos ld names a soname with
  # -h (configure.inc writes GNU -soname); its probes write /tmp/a$$ and /tmp/b$$: the build's TMPDIR instead.
  discount = mkSrcPkg {
    pname = "discount"; version = "3.0.2.0";
    src = { url = "https://github.com/Orc/discount/archive/v3.0.2.0.tar.gz";
            sha256 = "99f6db36d3fff6c99acd21d4c6096176d4ac8785eab319d0faf77ad995b8b7c5"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${npPatch "di/discount/fix-configure-path.patch" "5a759a87dc555e38cf8b79d82956b02d6a4fb4139bad5c6879f8674f9defe906"}
      [ "$(grep -c -- '-Wl,-soname,' configure.inc)" = 2 ] && [ "$(grep -c '/tmp/' configure.inc)" = 9 ] || { echo "FATAL: discount configure.inc anchors" >&2; exit 1; }
      sed -i -e 's/-Wl,-soname,/-Wl,-h,/' -e "s|/tmp/|$TMPDIR/|g" configure.inc
      CC="$CC" ./configure.sh --prefix="$out" --libdir="$out/lib/amd64" --mandir="$out/share/man" --shared --debian-glitch --pkg-config --h1-title
      gmake -j8; gmake test; gmake install.everything
      ${chk ''elfdump -d "$out/lib/amd64/libmarkdown.so.3.0.2" | grep SONAME'' "SONAME +0x[0-9a-f]+ +libmarkdown\\.so\\.3$"}
      printf '# solnix\n\n*x*\n' > "$W/t.md"
      ${chk ''"$out/bin/markdown" "$W/t.md" | tr -d '\n' '' "<h1[^>]*>solnix</h1><p><em>x</em></p>"}
    '';
  };

  # libnet (BSD-3-Clause): the packet construction and injection library, autotools from the tag, as nixpkgs. illumos: DLPI, named so
  # configure does not probe the build host's /dev/bpf0 and /dev/nit; its /dev/dlpi probes are pinned to "absent" (libnet then opens
  # /dev/net/<link>, illumos' layout).
  libnet = mkSrcPkg {
    pname = "libnet"; version = "1.3";
    src = { url = "https://github.com/libnet/libnet/archive/v1.3.tar.gz";
            sha256 = "44e28a4e5a9256ce74d96fd1ad8ac2e3f300f55dc70c93bb81851183a21d7d3a"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      grep -q '^    AS_IF(\[test -c /dev/dlpi\], \[$' configure.ac && grep -q '^        AS_IF(\[test -d \$dir\], \[$' configure.ac || { echo "FATAL: libnet dlpi anchors" >&2; exit 1; }
      sed -i -e 's/^    AS_IF(\[test -c \/dev\/dlpi\], \[$/    AS_IF([false], [/' -e 's/^        AS_IF(\[test -d \$dir\], \[$/        AS_IF([false], [/' configure.ac
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --with-link-layer=dlpi
      gmake -j8; gmake install
      ${tprog ''#include <libnet.h>
#include <stdio.h>
int main(void){ char e[LIBNET_ERRBUF_SIZE]; libnet_t *l = libnet_init(LIBNET_NONE, NULL, e); if (!l) { printf("init %s\n", e); return 1; }
uint32_t a = libnet_name2addr4(l, "127.0.0.1", LIBNET_DONT_RESOLVE);
libnet_ptag_t t = libnet_build_udp(1234, 53, LIBNET_UDP_H, 0, NULL, 0, l, 0);
printf("ok %d %s %d\n", a == htonl(0x7f000001), libnet_addr2name4(a, LIBNET_DONT_RESOLVE), t > 0); libnet_destroy(l); return 0; }'' "$out/lib/amd64/libnet.so"}
      ${chk ''"$W/t"'' "^ok 1 127\\.0\\.0\\.1 1$"}
    '';
  };

  # fcgi (OML): the FastCGI developer's kit (libfcgi, libfcgi++, cgi-fcgi), autotools from the tag, as nixpkgs (include/fastcgi -> .).
  # -L gcc.lib: libtool's C++ link (libfcgi++) would bake libstdc++.la's dir in as -R (closure gate, measured; as zimg).
  fcgi = mkSrcPkg {
    pname = "fcgi"; version = "2.4.7";
    src = { url = "https://github.com/FastCGI-Archives/fcgi2/archive/2.4.7.tar.gz";
            sha256 = "e41ddc3a473b555bdc0cbd80703dcb1f4610c1a7700d3b9d3d0c14a416e1074b"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static LDFLAGS="-L$gccLib/amd64"
      gmake -j8; gmake install
      ln -s . "$out/include/fastcgi"
      # stdin is not a FastCGI listen socket, so the process is a plain CGI
      ${tprog ''#include <fcgiapp.h>
#include <stdio.h>
int main(void){ printf("ok %d %d\n", FCGX_IsCGI(), FCGX_Init()); return 0; }'' "$out/lib/amd64/libfcgi.so"}
      ${chk ''"$W/t" < /dev/null'' "^ok 1 0$"}
    '';
  };

  # xbitmaps (X11): the X.Org bitmap images (include/X11/bitmaps) and their pkg-config file, as nixpkgs.
  xbitmaps = mkSrcPkg {
    pname = "xbitmaps"; version = "1.1.3";
    src = { url = "https://www.x.org/releases/individual/data/xbitmaps-1.1.3.tar.xz";
            sha256 = "ad6cad54887832a17d86c2ccfc5e52a1dfab090f8307b152c78b0e1529cd0f7a"; };
    deps = [ world ]; nativeTools = [ base.pkgconf ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" ${manSections}
      gmake install
      grep -qx '#define gray_width 2' "$out/include/X11/bitmaps/gray" || { echo "FATAL: xbitmaps: no X11/bitmaps/gray" >&2; exit 1; }
      ${chk ''PKG_CONFIG_PATH="$out/share/pkgconfig" pkg-config --modversion xbitmaps'' "^1\\.1\\.3$"}
    '';
  };

  # libupnp (BSD-3-Clause): the portable UPnP SDK (pupnp: libupnp, libixml and the tv_* samples), cmake, as nixpkgs. Its Solaris
  # branch tests `if(Solaris)`, a variable cmake never sets, so socket(3SOCKET)'s libs are named by hand; and without
  # _POSIX_PTHREAD_SEMANTICS illumos <time.h> declares the POSIX.1c Draft 6 asctime_r (3 args; webserver.c). Shared only; tests off.
  libupnp = mkSrcPkg {
    pname = "libupnp"; version = "1.14.25";
    src = { url = "https://github.com/pupnp/pupnp/archive/refs/tags/release-1.14.25.tar.gz";
            sha256 = "30efaabf25b753f2c5baa3a6242869ffb81f47b9898004cac22a0f39057a36ac"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB ''-DUPNP_BUILD_STATIC=OFF -DBUILD_TESTING=OFF -DCMAKE_C_FLAGS=-D_POSIX_PTHREAD_SEMANTICS -DCMAKE_SHARED_LINKER_FLAGS="-lsocket -lnsl" -DCMAKE_EXE_LINKER_FLAGS="-lsocket -lnsl"''}
      ${tprog ''#include <upnp/ixml.h>
#include <upnp/upnp.h>
#include <upnp/upnptools.h>
#include <stdio.h>
int main(void){ IXML_Document *d = ixmlParseBuffer("<a><b>solnix</b></a>"); if (!d) return 1; DOMString s = ixmlPrintNode((IXML_Node *)d);
printf("ok %s %s\n", s, UpnpGetErrorMessage(UPNP_E_SUCCESS)); ixmlFreeDOMString(s); ixmlDocument_free(d); return 0; }'' "$out/lib/amd64/libupnp.so $out/lib/amd64/libixml.so"}
      # ixml prints the XML prolog and \r\n line ends
      ${chk ''"$W/t" | tr -d '\r\n' '' "^ok (<[?]xml[^>]*>)?<a><b>solnix</b></a> UPNP_E_SUCCESS$"}
    '';
  };

  # libwapcaplet (MIT): NetSurf's string internment library, a static library on the served netsurf-buildsystem, as nixpkgs. Its
  # CFLAGS come in the environment (nixpkgs' NIX_CFLAGS_COMPILE): on make's command line they would replace the Makefile's -I flags.
  libwapcaplet = mkSrcPkg {
    pname = "libwapcaplet"; version = "0.4.3";
    src = { url = "https://download.netsurf-browser.org/libs/releases/libwapcaplet-0.4.3-src.tar.gz";
            sha256 = "9b2aa1dd6d6645f8e992b3697fdbd87f0c0e1da5721fa54ed29b484d13160c5c"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      CFLAGS=-Wno-error=cast-function-type gmake install PREFIX="$out" NSSHARED="${netsurf-buildsystem}/share/netsurf-buildsystem" CC="$CC" BUILD_CC="$CC" Q=
      ${tprog ''#include <libwapcaplet/libwapcaplet.h>
#include <stdio.h>
int main(void){ lwc_string *a, *b; if (lwc_intern_string("solnix", 6, &a) || lwc_intern_string("solnix", 6, &b)) return 1;
printf("ok %zu %d %.6s\n", lwc_string_length(a), a == b, lwc_string_data(a)); lwc_string_unref(a); lwc_string_unref(b); return 0; }'' "$out/lib/libwapcaplet.a"}
      ${chk ''"$W/t"'' "^ok 6 1 solnix$"}
    '';
  };

  # mimalloc (MIT): Microsoft's general-purpose allocator; the shared library overrides malloc. cmake, nixpkgs' flags (top-level
  # install, not secure, no arch tuning). mimalloc-config.cmake derives its dirs by replacing "/lib/cmake", which lib/amd64/cmake
  # does not contain: named instead, as nixpkgs does for its split outputs. recipes7 held it as needing a port (every program
  # aborted at its first malloc); holds1 measured the cause: mimalloc assumes user addresses below 2^47, so upstream illumos's
  # layout (libraries and mmap at 0xFFFFFC7F...) fails its own tests (test-api, test-stress 0/3 SIGSEGV) and solnix's userLimit47
  # default passes them (3/3 each), unpatched. So the build runs test-api and, like firefox.nix, names a builder without it.
  mimalloc = mkSrcPkg {
    pname = "mimalloc"; version = "3.5.3";
    src = { url = "https://codeload.github.com/microsoft/mimalloc/tar.gz/refs/tags/v3.5.3";
            sha256 = "3b4a15153a59905995f7070296ed604bb5ccc00cabb8b93446931aff77224d47"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      f=cmake/mimalloc-config.cmake
      [ "$(grep -cE '^ *string\(REPLACE .* MIMALLOC_(LIBRARY|OBJECT|INCLUDE)_DIR ' $f)" = 4 ] || { echo "FATAL: mimalloc config anchors" >&2; exit 1; }
      sed -i -e 's|^\( *\)string(REPLACE .* MIMALLOC_LIBRARY_DIR .*|\1set(MIMALLOC_LIBRARY_DIR "'"$out"'/lib/amd64")|' \
        -e 's|^\( *\)string(REPLACE .* MIMALLOC_OBJECT_DIR .*|\1set(MIMALLOC_OBJECT_DIR "'"$out"'/lib/amd64")|' \
        -e 's|^\( *\)string(REPLACE .* MIMALLOC_INCLUDE_DIR .*|\1set(MIMALLOC_INCLUDE_DIR "'"$out"'/include")|' $f
      printf '#include <stdio.h>\n#include <sys/mman.h>\nint main(void){ void *p = mmap(0, 1 << 20, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0);\nprintf("%%p\\n", p); return (unsigned long)p >= (1UL << 47); }\n' > "$W/va.c"
      "$CC" "$W/va.c" -o "$W/va"
      a=$("$W/va") || { echo "FATAL: this build host lacks solnix's userLimit47 default (a fresh mmap at $a is not below 2^47): mimalloc cannot run here. Set solnix.kernel.userLimit47 (/etc/system.d: set _userlimit=0x7fffc0000000) and reboot." >&2; exit 1; }
      ${cmakeB "-DMI_INSTALL_TOPLEVEL=ON -DMI_SECURE=OFF -DMI_BUILD_SHARED=ON -DMI_BUILD_TESTS=ON -DMI_LIBC_MUSL=OFF -DMI_NO_OPT_ARCH=ON"}
      # mimalloc's own API test (53 cases), as nixpkgs' doCheck runs it
      ${chk ''_b/mimalloc-test-api 2>&1 | tail -3'' "^failed   : 0$"}
      # malloc itself must be mimalloc's (the override), and a program linked with it must not hang at load (jemalloc did: libgcc_s's
      # .init calls malloc first); the timeout turns a hang into a failure
      ${tprog ''#include <mimalloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void){ char *p = malloc(100); if (!p) return 1; strcpy(p, "solnix"); int in = mi_is_in_heap_region(p); free(p);
void *q = mi_malloc(64); if (!q) return 2; mi_free(q); printf("ok %d %d\n", mi_version(), in); return 0; }'' "$out/lib/amd64/libmimalloc.so"}
      ${chk ''timeout 60 "$W/t"'' "^ok 30503 1$"}
    '';
  };
}
