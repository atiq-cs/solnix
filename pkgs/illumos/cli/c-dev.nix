# cli/c-dev.nix -- python3, cmake, ccache, quilt, pkg-config (pkgconf), gdbm, expat, libffi.
{ base, mkSrcPkg, world, zlib, openssl, ncurses, readline, pkgconf, nixChain, graphics, chk, scrub,
  dropDocs, gnulibFix, perl, sqlite, hostTools, ... }:
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
    nativeTools = hostTools;   # store-only PATH + config.site (wave4: OI /usr/gnu + /usr/bin probes); the .pyc half is hash B's nopyc
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
      find "$out" -type d -name '__pycache__' -prune -exec rm -r {} +   # timestamp pyc from install's failed compileall (wave3)
      ln -sf python3 "$out/bin/python"
      export PYTHONDONTWRITEBYTECODE=1   # the checks below must not write bytecode into $out
      ${chk ''"$out/bin/python3" --version'' "^Python 3\\.13\\.9"}
      for m in ssl zlib sqlite3 readline ctypes pyexpat dbm.gnu curses bz2 lzma hashlib json; do
        "$out/bin/python3" -c "import $m" || { echo "FATAL: python3 cannot import $m" >&2; exit 1; }
      done
      ${chk ''"$out/bin/python3" -c "import ssl,sqlite3; print(ssl.OPENSSL_VERSION, sqlite3.sqlite_version)"'' "^OpenSSL 3\\.4\\.0 .* 3\\.50\\.4$"}
      [ -f "$out/share/man/man1/python3.13.1" ] || { echo "FATAL: no python3 man page" >&2; exit 1; }
      # deterministic bytecode: SOURCE_DATE_EPOCH is set, so compileall writes checked-hash pyc; -j1 = no multiprocessing
      unset PYTHONDONTWRITEBYTECODE
      "$out/bin/python3" -E -m compileall -q -f -j1 -o 0 -o 1 -o 2 -x 'bad_coding|badsyntax|site-packages|test' "$out/lib/python3.13" >/dev/null || true
      # a source that names $out (_sysconfigdata, python-config): its checked-hash pyc hashes the SCRATCH out's text under an
      # unsandboxed --check, and Nix rewrites only the path string (wave3: 6 pyc differed). Ship those as source only.
      grep -rlF --include='*.py' "$out" "$out/lib/python3.13" | while read -r s; do
        b=$(basename "$s" .py); rm -f "$(dirname "$s")/__pycache__/$b".cpython-313*.pyc; done
      bad=$(find "$out" -name '*.pyc' | while read -r f; do [ "$(od -An -tx1 -j4 -N1 "$f" | tr -d ' \n')" = 03 ] || echo "$f"; done | head -3)
      [ -z "$bad" ] || { echo "FATAL: python3 ships non-checked-hash pyc: $bad" >&2; exit 1; }
      [ "$(find "$out" -name '*.pyc' | wc -l)" -gt 1000 ] || { echo "FATAL: python3 compileall wrote too few pyc" >&2; exit 1; }
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
    deps = [ perl base.bash base.coreutils base.gnused base.gnugrep base.diffutils base.findutils gnupatch getopt ];
    build = ''
      C=${base.coreutils}/bin
      ./configure --prefix="$out" --with-perl=${perl}/bin/perl --with-bash=${base.bash}/bin/bash \
        --with-getopt=${getopt}/bin/getopt --with-sed=${base.gnused}/bin/sed --with-awk=/usr/bin/nawk \
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
    deps = [ world ]; nativeTools = hostTools;   # store-only PATH + config.site: install/mkdir/locales/O_NOATIME differed by host (wave4 cfg/gnupatch-2.8.diff)
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
}
