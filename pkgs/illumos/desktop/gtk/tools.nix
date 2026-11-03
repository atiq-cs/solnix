# desktop/gtk/tools.nix -- build tools for the GTK3 stack: meson 1.10.2 (nixpkgs' version; gdk-pixbuf 2.44 needs
# >= 1.5, graphics/'s 1.4.2 is too old), gperf (fontconfig), nasm (libjpeg-turbo SIMD, Firefox). None ships at run
# time except as a build input. meson runs on the STORE python3 (cli/c-dev.nix), not /usr/bin/python3.9 as
# graphics/tools.nix does, so a solnix host with no host python (dixi) can rebuild everything here.
{ mkSrcPkg, python3, samurai, pkgconf, gnupatch, gettext }:
rec {
  meson = mkSrcPkg {
    pname = "meson"; version = "1.10.2";
    src = { url = "https://github.com/mesonbuild/meson/releases/download/1.10.2/meson-1.10.2.tar.gz";
            sha256 = "7890287d911dd4ee1ebd0efb61ed0321bfcd87c725df923a837cf90c6508f96b"; };
    build = ''
      # keep /nix/store RUNPATH entries on install (nixpkgs meson 001-fix-rpath; applies to 1.10.2 at an offset)
      ${gnupatch}/bin/patch -p1 < ${../../graphics/patches/meson-1.4.2-keep-store-rpath.patch}
      mkdir -p "$out/lib/meson" "$out/bin"
      cp -r mesonbuild meson.py "$out/lib/meson/"
      printf '#!/usr/bin/bash\nexport PYTHONDONTWRITEBYTECODE=1\nexec ${python3}/bin/python3 %s/lib/meson/meson.py "$@"\n' "$out" > "$out/bin/meson"
      chmod +x "$out/bin/meson"
      "$out/bin/meson" --version | grep -qx 1.10.2 || { echo "FATAL: meson --version" >&2; exit 1; }
    '';
  };

  gperf = mkSrcPkg {
    pname = "gperf"; version = "3.3";
    src = { url = "https://mirrors.kernel.org/gnu/gperf/gperf-3.3.tar.gz";
            sha256 = "fd87e0aba7e43ae054837afd6cd4db03a3f2693deb3619085e6ed9d8d9604ad8"; };
    build = ''
      ./configure --prefix="$out" CXX="$CXX"
      gmake -j''${NIX_BUILD_CORES:-8}; gmake install
      find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true
      printf 'a\nb\n' | "$out/bin/gperf" -L ANSI-C | grep -q 'in_word_set' || { echo "FATAL: gperf" >&2; exit 1; }
    '';
  };

  nasm = mkSrcPkg {
    pname = "nasm"; version = "3.02";
    src = { url = "https://www.nasm.us/pub/nasm/releasebuilds/3.02/nasm-3.02.tar.xz";
            sha256 = "87336eba53b4acfe917424ab5d500d2b0054d9f5148d35c2273ccf2cfb712f0d"; };
    build = ''
      # illumos has <stdbit.h>, so include/compiler.h takes its stdbit arm and never includes <endian.h>, yet configure
      # found htole32 there (HAVE_HTOLE32), so bytesex.h skips its fallback: "implicit declaration of htole32" (measured).
      ./configure --prefix="$out" ac_cv_header_stdbit_h=no
      gmake -j''${NIX_BUILD_CORES:-8}; gmake install
      printf 'bits 64\nmov eax, 1\nret\n' > "$TMPDIR/t.asm"
      "$out/bin/nasm" -f elf64 "$TMPDIR/t.asm" -o "$TMPDIR/t.o"
      [ "$(od -An -tx1 -N4 "$TMPDIR/t.o" | tr -d ' \n')" = 7f454c46 ] || { echo "FATAL: nasm made no ELF" >&2; exit 1; }
      [ -f "$out/share/man/man1/nasm.1" ] || { echo "FATAL: no nasm man page" >&2; exit 1; }
    '';
  };

  # ninja 1.13.2 (nixpkgs' version): gyp (nodejs) emits ninja files samurai rejects ("multiple rules generate
  # libv8_zlib.a", measured); ninja accepts them, as on NixOS. configure.py --bootstrap builds it with $CXX alone.
  ninja = mkSrcPkg {
    pname = "ninja"; version = "1.13.2";
    src = { url = "https://codeload.github.com/ninja-build/ninja/tar.gz/refs/tags/v1.13.2";
            sha256 = "974d6b2f4eeefa25625d34da3cb36bdcebe7fbce40f4c16ac0835fd1c0cbae17"; };
    build = ''
      CXX="$CXX" PYTHONDONTWRITEBYTECODE=1 ${python3}/bin/python3 configure.py --bootstrap --platform=solaris
      mkdir -p "$out/bin"; cp ninja "$out/bin/"
      "$out/bin/ninja" --version | grep -qx 1.13.2 || { echo "FATAL: ninja --version" >&2; exit 1; }
    '';
  };

  # For a recipe that runs glib's programs at build time (glib-compile-resources, gdbus-codegen, ...) or in its checks. glib converts
  # argv and file names from the locale codeset; in the C locale that is 646, and libc's iconv opens /usr/lib/iconv/646%UTF-8.so by
  # absolute path, i.e. the RUNNING host's modules, not the store's. dixi has none: "Conversion from character set 646 to UTF-8 is
  # not supported" (gtk3's glib-compile-resources, harfbuzz's hb-shape; measured). CHARSET=UTF-8 makes glib treat the codeset as
  # UTF-8 (gcharset.c), so it copies the bytes and reads no host file (LC_ALL=C.UTF-8 also works, but reads the host's /usr/lib/locale).
  charset = "export CHARSET=UTF-8";

  # The lines every meson recipe here runs; flags are the -D options. Store tools first on PATH: meson, samurai,
  # python3 (glib-mkenums & co. are `#!/usr/bin/env python3`), pkg-config, patch, msgfmt (po/).
  # PYTHONDONTWRITEBYTECODE: a root build on chef's writable store wrote __pycache__ into the store python3 and glib it
  # imported, after registration ("hash ... has changed", nix-store --verify-path, measured 2026-11-01; wave3 saw the same).
  path = "export PYTHONDONTWRITEBYTECODE=1 PATH=${meson}/bin:${samurai}/bin:${python3}/bin:${pkgconf}/bin:${gnupatch}/bin:${gettext}/bin:$PATH";
  mesonBuild = flags: ''
    ${path}
    meson setup _b --prefix="$out" --libdir=lib/amd64 --buildtype=release \
      --wrap-mode=nodownload -Db_ndebug=true -Dpython.bytecompile=-1 ${flags}
    samu -C _b -j''${NIX_BUILD_CORES:-8}
    samu -C _b install
  '';
}
