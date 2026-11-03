# desktop/gtk/base.nix -- glib and the font/image libraries under pango, cairo and gtk3, from source (nixpkgs 7f81d69
# versions and tarballs; illumos fixes from OI oi-userland where upstream still needs them).
{ mkSrcPkg, tools, zlib, python3, cmake, graphics, nixChain, noto-sans }:
let m = tools.mesonBuild; inherit (graphics) libffi expat; in
rec {
  # freetype2.pc Requires.private zlib/libpng/libbrotlidec: pkg-config needs them to answer at all (link time only)
  ftPriv = [ zlib libpng nixChain.brotli nixChain.bzip2 ];

  pcre2 = mkSrcPkg {
    pname = "pcre2"; version = "10.48";   # queue target (CVE-2026-89157/89161 fixed_in); .sig: Nicholas Wilson 2A98E77EB6F24CA8
    src = { url = "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.48/pcre2-10.48.tar.gz";
            sha256 = "ebcc25aadf2a51fa1fefa9b8bc9e7a79b3dae86870a0f1152a22e42befd46888"; };
    deps = [ zlib ];
    build = ''
      # nixpkgs: 16/32-bit libs + JIT (sealloc: Linux memfd only, so off here)
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static \
        --enable-pcre2-16 --enable-pcre2-32 --enable-jit
      gmake -j''${NIX_BUILD_CORES:-8}; gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      echo abc123 | "$out/bin/pcre2grep" -o '[0-9]+' | grep -qx 123 || { echo "FATAL: pcre2grep" >&2; exit 1; }
    '';
  };

  # glib 2.88 (glib, gobject, gio, gmodule + tools). No introspection (no gobject-introspection yet: nothing in the
  # browser path needs a typelib), no dtrace probes, no xattr (illumos has no getxattr), kqueue/inotify absent so
  # GFileMonitor uses its polling fallback. OI's patches that upstream still lacks: ipv6 getaddrinfo family check
  # and iconv_close(-1) (illumos 14937). libintl from the gate (libc), iconv = libc's (OI and NixOS both use the libc
  # iconv; GNU libiconv's iconv.h declares const char ** and glib's g_iconv fails -Wincompatible-pointer-types, measured).
  glib = mkSrcPkg {
    pname = "glib"; version = "2.88.1";
    src = { url = "https://download.gnome.org/sources/glib/2.88/glib-2.88.1.tar.xz";
            sha256 = "51ab804c56f6eab3e5045c774d1290ac5e4c923d4f9a3d8e33123bee45c1840e"; };
    deps = [ pcre2 libffi zlib ];
    build = ''
      ${tools.path}
      patch -p1 < ${./patches/glib-2.88.1-illumos-ipv6-check.patch}
      patch -p1 < ${./patches/glib-2.88.1-illumos-iconv-close.patch}
      ${m "-Dxattr=false -Dselinux=disabled -Dlibmount=disabled -Ddtrace=disabled -Dsystemtap=disabled -Dsysprof=disabled -Dintrospection=disabled -Dman-pages=disabled -Ddocumentation=false -Dtests=false -Dglib_debug=disabled -Dlibelf=disabled -Dnls=enabled -Dbsymbolic_functions=false '-Dc_link_args=-lsocket -lnsl'"}
      # the python tools (gdbus-codegen, glib-mkenums, glib-genmarshal) name the store python3, as nixpkgs' patchShebangs
      for f in "$out"/bin/*; do head -c 64 "$f" | grep -q '^#!/usr/bin/env python3' && sed -i "1s@.*@#!${python3}/bin/python3@" "$f"; done
      "$out/bin/glib-mkenums" --version | grep -q '2\.88' || { echo "FATAL: glib-mkenums (store python3 shebang)" >&2; exit 1; }
      # a GObject + GMainLoop + GIO round trip, compiled against the installed headers
      cat > "$TMPDIR/t.c" <<'EOF'
    #include <gio/gio.h>
    static gboolean q(gpointer l) { g_main_loop_quit(l); return G_SOURCE_REMOVE; }
    int main(void) { GMainLoop *l = g_main_loop_new(NULL, FALSE); g_timeout_add(10, q, l); g_main_loop_run(l);
      GFile *f = g_file_new_for_path("/etc/passwd"); char *c; gsize n;
      if (!g_file_load_contents(f, NULL, &c, &n, NULL, NULL) || n == 0) return 2;
      GRegex *r = g_regex_new("^root:", G_REGEX_MULTILINE, 0, NULL); if (!g_regex_match(r, c, 0, NULL)) return 3;
      g_print("glib-ok %s\n", g_uri_escape_string("a b", NULL, FALSE)); return 0; }
    EOF
      $CC -I"$out/include/glib-2.0" -I"$out/lib/amd64/glib-2.0/include" "$TMPDIR/t.c" -o "$TMPDIR/t" \
        -L"$out/lib/amd64" -Wl,-R,"$out/lib/amd64" -lgio-2.0 -lgobject-2.0 -lglib-2.0
      CHARSET=UTF-8 "$TMPDIR/t" | grep -qx 'glib-ok a%20b' || { echo "FATAL: glib round trip" >&2; exit 1; }
    '';
  };

  libpng = mkSrcPkg {
    pname = "libpng"; version = "1.6.58";
    src = { url = "https://downloads.sourceforge.net/libpng/libpng-1.6.58.tar.xz";
            sha256 = "28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775"; };
    deps = [ zlib ];
    build = ''
      ${tools.path}
      # nixpkgs' libpng-apng (Firefox's system libpng must have APNG)
      gzip -dc ${import <nix/fetchurl.nix> { url = "https://downloads.sourceforge.net/sourceforge/libpng-apng/libpng-1.6.58-apng.patch.gz";
        sha256 = "eee7dea22ed502868017971c86c63c4ed1e6085de0baebfdcc3d3322f00f3eb0"; }} | patch -Np1
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j''${NIX_BUILD_CORES:-8}; gmake pngtest; gmake install   # two goals in one -j run race on the same objects
      grep -q png_get_acTL "$out/include/libpng16/png.h" || { echo "FATAL: no APNG API" >&2; exit 1; }
      ./pngtest pngtest.png "$TMPDIR/o.png" | grep -q PASS || { echo "FATAL: pngtest" >&2; exit 1; }
    '';
  };

  libjpeg-turbo = mkSrcPkg {
    pname = "libjpeg-turbo"; version = "3.1.4.1";
    src = { url = "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.4.1/libjpeg-turbo-3.1.4.1.tar.gz";
            sha256 = "ecae8008e2cc9ade2f2c1bb9d5e6d4fb73e7c433866a056bd82980741571a022"; };
    linkDeps = [ tools.nasm ];
    build = ''
      ${cmake}/bin/cmake -S . -B _b -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CC" -DENABLE_STATIC=0 -DENABLE_SHARED=1 \
        -DCMAKE_ASM_NASM_COMPILER=${tools.nasm}/bin/nasm -DREQUIRE_SIMD=1 -DCMAKE_SKIP_RPATH=ON
      gmake -C _b -j''${NIX_BUILD_CORES:-8} install
      find "$out/share/doc" -delete 2>/dev/null || true
      "$out/bin/djpeg" -ppm testimages/testorig.jpg | head -c 2 | grep -qx P6 || { echo "FATAL: djpeg" >&2; exit 1; }
    '';
  };

  # freetype without harfbuzz (nixpkgs builds it so; harfbuzz depends on freetype, not the reverse). OI's GS fix:
  # <sys/regset.h> defines GS on x86 illumos, which clobbers TT_ExecContext's GS member.
  freetype = mkSrcPkg {
    pname = "freetype"; version = "2.14.3";
    src = { url = "https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz";
            sha256 = "36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f"; };
    deps = [ zlib libpng nixChain.bzip2 nixChain.brotli ];
    build = ''
      ${tools.path}
      patch -p1 < ${./patches/freetype-2.14.3-illumos-gs-conflict.patch}
      GNUMAKE=gmake ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-freetype-config \
        --with-zlib=yes --with-png=yes --with-bzip2=yes --with-brotli=yes --with-harfbuzz=no
      gmake -j''${NIX_BUILD_CORES:-8}; gmake install
      PKG_CONFIG_PATH="$out/lib/amd64/pkgconfig" pkg-config --modversion freetype2 | grep -q '^26\.' || { echo "FATAL: freetype2.pc" >&2; exit 1; }
    '';
  };

  # fontconfig, as nixpkgs: compiled-in sysconfdir /etc, so at run time it reads the system's /etc/fonts/fonts.conf
  # (written by the desktop module); `make install sysconfdir=$out/etc` keeps the default config in the store.
  # Default font dir when no config loads: the store noto-sans (nixpkgs uses dejavu.minimal).
  fontconfig = mkSrcPkg {
    pname = "fontconfig"; version = "2.18.1";
    src = { url = "https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/2.18.1/fontconfig-2.18.1.tar.xz";
            sha256 = "2300f3dbfa7253b3a44f4feecdbc8dfa45dde5dc2cfb71fceaf31f394cb41031"; };
    deps = [ freetype expat ];
    linkDeps = ftPriv;
    build = ''
      ${tools.path}
      export PATH=${tools.gperf}/bin:$PATH
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-docs \
        --sysconfdir=/etc --localstatedir=/var --with-cache-dir=/var/cache/fontconfig \
        --with-default-fonts=${noto-sans}/share/fonts PYTHON=${python3}/bin/python3
      gmake -j''${NIX_BUILD_CORES:-8}; gmake install fc_cachedir="$TMPDIR/dummy" RUN_FC_CACHE_TEST=false sysconfdir="$out/etc"
      mkdir -p "$out/share/man/man1" "$out/share/man/man5"   # no GNU install on a solnix host (pkgc1 host-tools audit)
      cp doc/fc-*.1 "$out/share/man/man1/"; cp doc/fonts-conf.5 "$out/share/man/man5/"
      FONTCONFIG_FILE="$out/etc/fonts/fonts.conf" "$out/bin/fc-list" : family | grep -q 'Noto Sans' \
        || { echo "FATAL: fc-list does not see the default fonts" >&2; exit 1; }
    '';
  };

  fribidi = mkSrcPkg {
    pname = "fribidi"; version = "1.0.16";
    src = { url = "https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz";
            sha256 = "1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c"; };
    build = ''
      ${m "-Ddocs=false -Dtests=false"}
      printf 'abc\n' | "$out/bin/fribidi" --nopad | grep -qx abc || { echo "FATAL: fribidi" >&2; exit 1; }
    '';
  };

  # harfbuzz with glib/gobject + freetype (nixpkgs' flags: no cairo, no icu, no graphite here as OI has none from source).
  harfbuzz = mkSrcPkg {
    pname = "harfbuzz"; version = "13.2.1";
    src = { url = "https://github.com/harfbuzz/harfbuzz/releases/download/13.2.1/harfbuzz-13.2.1.tar.xz";
            sha256 = "6695da3eb7e1be0aa3092fe4d81433a33b47f4519259c759d729e3a9a55c1429"; };
    deps = [ glib freetype ];
    linkDeps = [ pcre2 libffi ] ++ ftPriv;
    nativeTools = [ glib ];   # glib-mkenums & co. by name, as NixOS nativeBuildInputs (gdk-pixbuf says why)
    build = ''
      ${tools.charset}
      ${m "-Dcairo=disabled -Dchafa=disabled -Dicu=disabled -Dgraphite=disabled -Dgraphite2=disabled -Dintrospection=disabled -Ddocs=disabled -Dtests=disabled -Dbenchmark=disabled -Dglib=enabled -Dgobject=enabled -Dfreetype=enabled -Draster=disabled '-Dc_link_args=-lm' '-Dcpp_link_args=-lm'"}
      "$out/bin/hb-shape" test/api/fonts/OpenSans-Regular.ttf 'fi' | grep -q '^\[' || { echo "FATAL: hb-shape" >&2; exit 1; }
    '';
  };
}
