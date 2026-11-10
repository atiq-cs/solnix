# cli/c-dev.nix -- python3, cmake, ccache, quilt, pkg-config (pkgconf), gdbm, expat, libffi.
{ base, mkSrcPkg, world, zlib, openssl, ncurses, readline, pkgconf, nixChain, graphics, chk, scrub,
  dropDocs, gnulibFix, perl, sqlite, hostTools, gnum4, libiconv, ... }:
rec {
  gdbm = mkSrcPkg {
    pname = "gdbm"; version = "1.24";
    src = { url = "https://mirrors.kernel.org/gnu/gdbm/gdbm-1.24.tar.gz";
            sha256 = "695e9827fdf763513f133910bc7e6cfdb9187943a4fec943e57449723d2b8dbf"; };
    deps = [ readline ncurses ];
    build = ''
      MAKEINFO=true ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-libgdbm-compat --disable-nls
      gmake -j8 MAKEINFO=true; gmake install MAKEINFO=true
      ${dropDocs}
      ${chk ''"$out/bin/gdbmtool" --version'' "1\\.24"}
      ${chk ''echo "store k v" | "$out/bin/gdbmtool" -n "$W/t.db" && echo "fetch k" | "$out/bin/gdbmtool" "$W/t.db"'' "^v$"}
    '';
  };

  # python3: shared libpython, the stdlib C modules that need only libs in this set (ssl, zlib,
  # sqlite3, readline, ctypes/libffi, expat, dbm.gnu, curses, bz2, lzma). No tkinter, no uuid.
  python3 = mkSrcPkg {
    pname = "python3"; version = "3.13.9";
    src = { url = "https://www.python.org/ftp/python/3.13.9/Python-3.13.9.tar.xz";
            sha256 = "ed5ef34cda36cfa2f3a340f07cac7e7814f91c7f3c411f6d3562323a866c5c66"; };
    deps = [ world zlib openssl readline ncurses sqlite gdbm graphics.libffi graphics.expat nixChain.xz nixChain.bzip2 ];
    build = ''
      # libpython in lib/amd64 (the RUNPATH the wrapper bakes), stdlib in lib/python3.13: with
      # --libdir=lib/amd64 alone python installs lib-dynload under lib/amd64/python3.13 and then
      # looks in lib/python3.13 ("No module named _ssl", measured), so --with-platlibdir=lib.
      L="$out/lib/amd64"
      # No extra -Wl,-R: the wrapper already bakes $out/lib/amd64 + every dep; a second -R on
      # the line made the module RUNPATH lose the deps (_sqlite3: sqlite3_blob_close not found,
      # measured). -lresolv: hstrerror (socketmodule) is in illumos libresolv.
      ./configure --prefix="$out" --libdir="$L" --with-platlibdir=lib --enable-shared --with-openssl=${openssl} \
        --with-system-expat --with-ensurepip=no --without-static-libpython --disable-test-modules \
        LIBS="-lresolv" ac_cv_lib_uuid_uuid_generate_time=no ac_cv_header_uuid_h=no
      gmake -j16; gmake install
      ${scrub}
      find "$out" -name '__pycache__' -prune -o -name '*.pyc' -print | head -1 >/dev/null
      ln -sf python3 "$out/bin/python"
      ${chk ''"$out/bin/python3" --version'' "^Python 3\\.13\\.9"}
      for m in ssl zlib sqlite3 readline ctypes pyexpat dbm.gnu curses bz2 lzma hashlib json; do
        "$out/bin/python3" -c "import $m" || { echo "FATAL: python3 cannot import $m" >&2; exit 1; }
      done
      ${chk ''"$out/bin/python3" -c "import ssl,sqlite3; print(ssl.OPENSSL_VERSION, sqlite3.sqlite_version)"'' "^OpenSSL 3\\.4\\.0 .* 3\\.50\\.4$"}
      [ -f "$out/share/man/man1/python3.13.1" ] || { echo "FATAL: no python3 man page" >&2; exit 1; }
    '';
  };

  # cmake: its bootstrap builds a minimal cmake with the C++ compiler, then cmake builds itself.
  # Bundled third-party libs (curl, libarchive, zlib, ...) except OpenSSL off: no network module needed.
  cmake = mkSrcPkg {
    pname = "cmake"; version = "4.1.2";
    src = { url = "https://cmake.org/files/v4.1/cmake-4.1.2.tar.gz";
            sha256 = "643f04182b7ba323ab31f526f785134fb79cba3188a852206ef0473fee282a15"; };
    deps = [ world ];
    build = ''
      ./bootstrap --prefix="$out" --parallel=16 --no-qt-gui --no-debugger -- \
        -DCMAKE_USE_OPENSSL=OFF -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON
      gmake -j16; gmake install
      ${scrub}
      find "$out/doc" -delete 2>/dev/null || true
      ${chk ''"$out/bin/cmake" --version'' "^cmake version 4\\.1\\.2"}
      T=$(mktemp -d /var/tmp/cm.XXXXXX); printf 'cmake_minimum_required(VERSION 3.10)\nproject(t C)\nadd_executable(t t.c)\n' > "$T/CMakeLists.txt"
      printf 'int main(void){return 0;}\n' > "$T/t.c"
      (cd "$T" && "$out/bin/cmake" -S . -B b -DCMAKE_C_COMPILER="$CC" >/dev/null && "$out/bin/cmake" --build b >/dev/null && ./b/t) \
        || { echo "FATAL: cmake functional" >&2; exit 1; }
    '';
  };

  # quilt: a bash/perl script set. Its tool paths are baked as absolute store paths (NixOS'
  # quilt does the same), so it runs the GNU tools it was written for, not the SVR4 ones.
  quilt = mkSrcPkg {
    pname = "quilt"; version = "0.69";
    src = { url = "https://download.savannah.gnu.org/releases/quilt/quilt-0.69.tar.gz";
            sha256 = "555ddffde22da3c86d1caf5a9c1fb8a152ac2b84730437bd39cc08849c9f4852"; };
    deps = [ perl base.bash base.coreutils base.gnused base.gnugrep base.diffutils base.findutils gnupatch getopt world ];
    nativeTools = hostTools;   # store-only PATH + config.site (recipes1); every tool quilt runs is baked by store path below
    build = ''
      C=${base.coreutils}/bin
      ./configure --prefix="$out" --with-perl=${perl}/bin/perl --with-bash=${base.bash}/bin/bash \
        --with-getopt=${getopt}/bin/getopt --with-sed=${base.gnused}/bin/sed --with-awk=${world}/usr/bin/nawk \
        --with-diff=${base.diffutils}/bin/diff --with-patch=${gnupatch}/bin/patch \
        --with-find=${base.findutils}/bin/find --with-xargs=${base.findutils}/bin/xargs \
        --with-date=$C/date --with-cp=$C/cp --with-stat=$C/stat --with-column=$C/true \
        --with-pod2man=${perl}/bin/pod2man --without-rpmbuild --without-7z --without-sendmail --disable-nls
      gmake -j8; gmake install BUILD_ROOT=
      ${chk ''"$out/bin/quilt" --version'' "^0\\.69$"}
      # functional: new patch, add a file, refresh, and the patch names the change
      T=$(mktemp -d /var/tmp/qu.XXXXXX); cd "$T"; echo a > f
      "$out/bin/quilt" new p.diff >/dev/null; "$out/bin/quilt" add f >/dev/null; echo b > f; "$out/bin/quilt" refresh >/dev/null
      ${chk ''cat "$T/patches/p.diff"'' "^\\+b$"}
    '';
  };

  # GNU patch (quilt needs it; illumos patch is not GNU patch).
  gnupatch = mkSrcPkg {
    pname = "gnupatch"; version = "2.8";
    src = { url = "https://mirrors.kernel.org/gnu/patch/patch-2.8.tar.xz";
            sha256 = "f87cee69eec2b4fcbf60a396b030ad6aa3415f192aa5f7ee84cad5e11f7f5ae3"; };
    deps = [ world ];
    build = ''
      ${gnulibFix}
      ./configure --prefix="$out" --disable-gcc-warnings
      gmake -j8; gmake install
      ${chk ''"$out/bin/patch" --version'' "^GNU patch 2\\.8"}
    '';
  };

  # util-linux's getopt, standalone (GNU getopt --long), for quilt and scripts that want it.
  getopt = mkSrcPkg {
    pname = "getopt"; version = "1.1.6";
    src = { url = "http://frodo.looijaard.name/system/files/software/getopt/getopt-1.1.6.tar.gz";
            sha256 = "d0bf1dc642a993e7388a1cddfb9409bed375c21d5278056ccca3a0acd09dc5fe"; };
    # GNU install from the store: the world's SysV /usr/sbin/install took `install -m 755 getopt $out/bin` as "copy to /bin/getopt",
    # which only root can write (it did on the build host, as root). Store-only PATH (wave4).
    nativeTools = hostTools;
    build = ''
      sed -i '1i #include <string.h>' gnu/getopt.c
      gmake CC="$CC" prefix="$out" WITHOUT_GETTEXT=1 LIBCGETOPT=0 mandir="$out/share/man"
      gmake install CC="$CC" prefix="$out" WITHOUT_GETTEXT=1 LIBCGETOPT=0 mandir="$out/share/man"
      ${chk ''"$out/bin/getopt" -o a --long all -- --all x'' "^ --all -- .x.$"}
    '';
  };

  xxhash = mkSrcPkg {
    pname = "xxhash"; version = "0.8.3";
    src = { url = "https://github.com/Cyan4973/xxHash/archive/refs/tags/v0.8.3.tar.gz";
            sha256 = "aae608dfe8213dfd05d909a57718ef82f30722c392344583d3f39050c7f29a80"; };
    build = ''
      gmake -j8 CC="$CC" PREFIX="$out" LIBDIR="$out/lib/amd64" lib xxhsum
      gmake install CC="$CC" PREFIX="$out" LIBDIR="$out/lib/amd64" INSTALL=ginstall
      ${chk ''printf abc | "$out/bin/xxh64sum"'' "^44bc2cf5ad770999 "}
    '';
  };

  # ccache 4: cmake + C++17; zstd (nixChain) + xxhash from the store, no redis/http backends.
  # cmake's find_library searches the host /usr/lib/64 by default (it found the OI host's
  # libxxhash/libzstd, measured): the store prefixes go first and the host dirs are ignored.
  ccache = mkSrcPkg {
    pname = "ccache"; version = "4.11.3";
    src = { url = "https://github.com/ccache/ccache/releases/download/v4.11.3/ccache-4.11.3.tar.xz";
            sha256 = "d5a340e199977b7b1e89c0add794132c977fdc2ecc7ca5451e03d43627a1b1be"; };
    deps = [ world nixChain.zstd xxhash ];
    build = ''
      export PATH=${cmake}/bin:$PATH
      mkdir b; cd b
      cmake .. -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON -DREDIS_STORAGE_BACKEND=OFF -DHTTP_STORAGE_BACKEND=OFF \
        -DCMAKE_EXE_LINKER_FLAGS=-lsendfile \
        -DENABLE_TESTING=OFF -DENABLE_DOCUMENTATION=OFF -DDEPS=LOCAL \
        -DCMAKE_PREFIX_PATH="${nixChain.zstd};${xxhash}" -DCMAKE_LIBRARY_ARCHITECTURE=amd64 \
        -DCMAKE_IGNORE_PREFIX_PATH="/usr;/usr/local;/opt" -DCMAKE_IGNORE_PATH="/usr/lib/64;/usr/lib/amd64;/lib/64" >&2
      grep -q "${xxhash}" CMakeCache.txt || { echo "FATAL: ccache did not take the store xxhash" >&2; grep -i xxhash CMakeCache.txt >&2; exit 1; }
      gmake -j16; gmake install
      ${chk ''"$out/bin/ccache" --version'' "^ccache version 4\\.11\\.3"}
      # functional: a miss then a hit through the store compiler
      export CCACHE_DIR=$W/ccd; printf 'int main(void){return 0;}\n' > t.c
      "$out/bin/ccache" "$CC" -c t.c -o t1.o; "$out/bin/ccache" "$CC" -c t.c -o t2.o
      ${chk ''"$out/bin/ccache" -s'' "[Hh]its: +1 "}
    '';
  };

  pkg-config = base.pkgconf;

  # GNU GDB, from source, as nixpkgs builds it (pkgs/by-name/gd/gdb): out-of-tree, every bfd target, TUI, system
  # readline/zlib/expat, Python, static bfd/opcodes, no sim, system gdbinit in /etc/gdb, NIX_DEBUG_INFO_DIRS patch.
  # 18.1 keeps the native Solaris target (configure.nat sol2: procfs + sol-thread via libthread_db.so.1, which is
  # the world's, hence world in deps). gmp + mpfr (18.1 needs both: target-float.c) in-tree and static, as
  # gcc-src.nix. Departures from nixpkgs: no source-highlight/libipt/debuginfod (no solnix packages; nixpkgs gates
  # debuginfod on elfutils, Linux only), no NLS, and no gcore: the world's native gcore(1) stays first.
  gdb = let fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; }; in mkSrcPkg {
    pname = "gdb"; version = "18.1";
    src = { url = "https://mirrors.kernel.org/gnu/gdb/gdb-18.1.tar.xz";
            sha256 = "cd9fc3fe2b47743840e42c1592d3d87f8302eb18639c0b8b4ba0898002e2348f"; };
    # libiconv: gdb converts every string it prints from the host charset to UTF-32 with iconv(3); the world's iconv
    # modules have no 646/UTF-8 -> UTF-32 (dixi: `print "abc"` gave "Unable to find a valid charset", the OI build host
    # with 1395 modules printed it). nixpkgs links GNU libiconv off glibc too (as gettext here, base-src.nix).
    deps = [ world ncurses readline zlib graphics.expat nixChain.xz nixChain.zstd xxhash python3 libiconv ];
    nativeTools = [ perl gnupatch pkgconf gnum4 ] ++ hostTools;   # perl: pod2man for the man pages; m4: in-tree gmp's configure
    build = ''
      patch -p1 < ${../patches/gdb/debug-info-from-env.patch}
      patch -p1 < ${../patches/gdb/ignore-core-note0-segment.patch}   # OI/OmniOS: without it every illumos core aborts gdb
      # catch syscall: the procfs target + sol2 tdep parts, and the name table generated from the gate's header (tracks the gate)
      patch -p1 < ${../patches/gdb/catch-syscall-procfs.patch}
      sh ${../patches/gdb/gen-syscalls-xml.sh} "$gate/usr/include/sys/syscall.h" > gdb/syscalls/illumos.xml
      tar xf ${fetch "https://mirrors.kernel.org/gnu/gmp/gmp-6.3.0.tar.xz" "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"}; mv gmp-6.3.0 gmp
      tar xf ${fetch "https://mirrors.kernel.org/gnu/mpfr/mpfr-4.2.1.tar.xz" "277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2"}; mv mpfr-4.2.1 mpfr
      # nixpkgs: regenerate the man pages so gdbinit(5) names the system gdbinit (the shipped ones say "not enabled")
      rm gdb/doc/*.1 gdb/doc/*.5 gdb/doc/GDBvn.texi
      mkdir _build; cd _build
      T=x86_64-pc-solaris2.11
      # ABI unset: mk-src-pkg exports ABI=64, and the in-tree gmp (configured from gmake, host none-*) rejects it.
      # (GNU libiconv's iconv.h declares const char ** in C and C++ alike, so configure's iconv-prototype probe, run in C,
      # holds for gdb's C++; against the gate's <iconv.h> it did not: g++ predefines _XPG6, which switches it to char **.)
      ( unset ABI
      # -L gcc.lib first: gdb links through libtool, which found -latomic as the COMPILER's libatomic.la and added its
      # libdir (gcc out, build-time only) as -R (closure gate, measured); a plain .so found first adds no rpath.
      CFLAGS=-O2 CXXFLAGS=-O2 LDFLAGS="-L$gccLib/amd64" MAKEINFO=true ../configure --prefix="$out" \
        --build=$T --host=$T --target=$T --enable-targets=all --enable-64-bit-bfd --disable-werror \
        --disable-install-libbfd --disable-shared --enable-static --enable-tui --with-curses \
        --with-system-readline --with-system-zlib --with-expat --with-lzma --with-zstd --with-xxhash \
        --with-python=${python3}/bin/python3 --without-guile --disable-sim --without-debuginfod \
        --disable-source-highlight --disable-nls --with-static-standard-libraries=no \
        --with-libiconv-prefix=${libiconv} --with-system-gdbinit=/etc/gdb/gdbinit --with-system-gdbinit-dir=/etc/gdb/gdbinit.d \
        --with-auto-load-safe-path='$debugdir:$datadir/auto-load'
      gmake -j16 MAKEINFO=true; gmake install MAKEINFO=true )
      rm -f "$out/bin/gcore" "$out/share/man/man1/gcore.1"
      # `info gdb`: keep the shipped gdb/annotate manuals (dropDocs deleted them); bfd.info is binutils', as nixpkgs
      # removes it. The profile's info dir is built by documentation.nix, so no per-package dir file.
      rm -rf "$out/share/doc" "$out/share/info/bfd.info" "$out/share/info/dir"
      # gdb-add-index: solnix ships binutils' objcopy/readelf only as gobjcopy/greadelf (OI layout), so pin them, and
      # this gdb, by store path (nixpkgs pins its scripts' tools the same way).
      sed -i -e 's@^GDB=.*@GDB=''${GDB:="'"$out"'/bin/gdb"}@' \
        -e 's@^OBJCOPY=.*@OBJCOPY=''${OBJCOPY:=${base.binutils}/bin/gobjcopy}@' \
        -e 's@^READELF=.*@READELF=''${READELF:=${base.binutils}/bin/greadelf}@' "$out/bin/gdb-add-index"
      grep -q "^OBJCOPY=.*${base.binutils}/bin/gobjcopy" "$out/bin/gdb-add-index" || { echo "FATAL: gdb-add-index not pinned" >&2; exit 1; }
      # libstdc++ pretty printers. gcc installs them in its compiler out (share/gcc-*/python and lib/libstdc++*-gdb.py),
      # not in gcc.lib, which is what a C++ program loads; nixpkgs' gcc moves both into lib. Moving them here moves every
      # C++ package, so gdb carries a copy: the printers in $out/share, and an auto-load script per libstdc++ under
      # $datadir/auto-load/<realpath of the .so> (already in the safe path; Fedora's layout). gcc's own -gdb.py names the
      # compiler out, so the stub here names only $out.
      # shortcut: printers match the gcc these drvs build with; upgrade by moving them into gcc.lib at the next gcc rebuild.
      gv=$(basename "$(ls -d "$gcc"/share/gcc-*)")
      mkdir -p "$out/share/$gv"; cp -R "$gcc/share/$gv/python" "$out/share/$gv/"
      for so in "$gccLib"/libstdc++.so.6.*[0-9] "$gccLib"/amd64/libstdc++.so.6.*[0-9]; do
        mkdir -p "$out/share/gdb/auto-load$(dirname "$so")"
        printf 'import sys, gdb\nsys.path.insert(0, "%s")\nfrom libstdcxx.v6 import register_libstdcxx_printers\nregister_libstdcxx_printers(gdb.current_objfile())\n' \
          "$out/share/$gv/python" > "$out/share/gdb/auto-load$so-gdb.py"
      done
      [ -f "$out/share/$gv/python/libstdcxx/v6/printers.py" ] && ls "$out"/share/gdb/auto-load/nix/store/*/lib/amd64/libstdc++.so.6.*-gdb.py >/dev/null \
        || { echo "FATAL: libstdc++ printers not installed" >&2; exit 1; }
      # the checks below run gdb's Python: without this they write __pycache__/*.pyc into $out, stamped with the .py
      # mtimes of this build, so `nix-store --check` differed in those 2 bytes per file (measured, v4)
      export PYTHONDONTWRITEBYTECODE=1
      ${chk ''"$out/bin/gdb" --version'' "^GNU gdb \\(GDB\\) 18\\.1$"}
      ${chk ''"$out/bin/gdb" -nx -batch -ex "python print(1+1)"'' "^2$"}
      ${chk ''NIX_DEBUG_INFO_DIRS=/nix-debug-probe "$out/bin/gdb" -nx -batch -ex "show debug-file-directory"'' "/nix-debug-probe"}
      ${chk ''"$out/bin/gdb" --configuration'' "with-system-gdbinit=/etc/gdb/gdbinit"}
      n=$(/usr/bin/elfdump -d "$out/bin/gdb" | awk '$2=="NEEDED"{print $4}')
      # (the OI build host's own iconv modules would mask a missing libiconv here; the NEEDED check below does not)
      ${chk ''"$out/bin/gdb" -nx -batch -ex 'print "abc"' '' "^\\$1 = .abc.$"}
      ${chk ''"$out/bin/gdb" -nx -batch -ex 'set host-charset UTF-8' -ex 'print "abc"' '' "^\\$1 = .abc.$"}
      for l in libreadline libncursesw libpython3 libexpat liblzma libzstd libxxhash libz.so libstdc++ libiconv; do
        echo "$n" | grep -q "^$l" || { echo "FATAL: gdb does not NEED $l: $n" >&2; exit 1; }
      done
      if echo "$n" | grep -Eq '^lib(termcap|curses)\.'; then echo "FATAL: gdb NEEDs an SVR4 curses: $n" >&2; exit 1; fi
      ${chk ''"$out/bin/gdb" -nx -batch -ex 'python import gdb.types, gdb.printing; print("pymods-ok")' '' "^pymods-ok$"}
      grep -q 'name="write" number="4"' "$out/share/gdb/syscalls/illumos.xml" || { echo "FATAL: no illumos syscall table" >&2; exit 1; }
      ${chk ''"$out/bin/gdb" -nx -batch -ex 'set osabi Solaris' -ex 'catch syscall write' -ex 'catch syscall waitsys' '' "^Catchpoint 2 \\(syscall .waitid. \\[107\\]\\)$"}
      [ -f "$out/share/info/gdb.info" ] || { echo "FATAL: gdb.info missing" >&2; exit 1; }
      [ -z "$(find "$out" -name __pycache__)" ] || { echo "FATAL: __pycache__ in $out" >&2; exit 1; }
      [ -f "$out/share/man/man1/gdb.1" ] && grep -q /etc/gdb/gdbinit "$out/share/man/man5/gdbinit.5" \
        || { echo "FATAL: gdb man pages missing or not regenerated" >&2; exit 1; }
    '';
  };
}
