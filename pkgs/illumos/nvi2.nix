# pkgs/illumos/nvi2.nix — nvi2 (github.com/lichray/nvi2): the modernized nvi editor.
#
# solnix's default `vi`. A small, wide-char nvi fork (C) — a clean, illumos-friendly
# vi with no vim dependency. Packaged as `nvi`; `vi`/`ex`/`view` link to it.
#
# Build: cmake, C. Deps: ncurses (curses UI) + Berkeley DB (the BSD 1.85 dbopen
# API nvi uses for its file backing + recovery logs). On BSD, dbopen lives in
# libc; illumos has no dbopen, so we link Berkeley DB's 1.85 compat (db_185.h,
# built with --enable-compat185, the nixpkgs default). Installs bin/{nvi,vi,ex,
# view} + share/vi.
#
# Usage (in the fork overlay / a callPackage site):
#   nvi = pkgs.callPackage ./nvi2.nix { };
{ lib, stdenv, fetchFromGitHub, cmake, ncurses, pkg-config, db }:

stdenv.mkDerivation (finalAttrs: {
  pname = "nvi";
  version = "2.2.1-unstable"; # nvi2 is versioned loosely; pin the rev below.

  src = fetchFromGitHub {
    owner = "lichray";
    repo = "nvi2";
    # Pin an explicit rev for reproducibility (a recent lichray/nvi2 commit).
    # NOTE: the build agent resolves + fills the real rev + hash from the repo HEAD
    # at build time and reports them back for this pin.
    rev = "eea5df8b71205df101f05125281c67be33e24a53";
    hash = "sha256-ijxBpfFDSyxCxl9vz8aDC9J2HlUTfZQpFFLsrRPy5H0=";
  };

  nativeBuildInputs = [ cmake pkg-config ];
  buildInputs = [ ncurses db ];

  # illumos has no BSD dbopen() in libc (BSD does), so nvi2's CMakeLists links a
  # `db1` lib and includes <db.h> for the 1.85 API. Point both at Berkeley DB's
  # 1.85 compat: link the db lib (named `db`, not `db1`) and include <db_185.h>
  # (where BDB declares dbopen/DBT/RECNO). The db.h that find_path resolves lives
  # next to db_185.h in the same include dir, so DB_INCLUDE_DIR is correct.
  #
  # nvi2 probes openpty/__b64_ntop (BSD/glibc-isms absent from illumos libc) and,
  # when missing, links libutil/libresolv -- but neither symbol is used anywhere
  # in nvi2's sources and neither lib exists on illumos, so find_library returns
  # NOTFOUND and aborts the configure. Guard those two links so an empty result
  # is skipped rather than fatal.
  #
  # nvi2 includes <bitstring.h> (BSD bit-array macros) and <util.h> (openpty for
  # :script mode) -- both are BSD/macOS system headers absent on illumos. Vendor
  # the canonical CSRG bitstring.h and an illumos openpty() shim into the source
  # tree (its own dir is on the include path) so the compile finds them.
  postPatch = ''
    cp ${./patches/bitstring.h} bitstring.h
    cp ${./patches/util.h} util.h
    sed -i 's/PRIVATE db1)/PRIVATE db)/' CMakeLists.txt
    sed -i 's,include_directories(''${CMAKE_CURRENT_BINARY_DIR}),include_directories(''${CMAKE_CURRENT_BINARY_DIR} ''${CMAKE_CURRENT_SOURCE_DIR}),' CMakeLists.txt
    sed -i 's,#include <db.h>,#include <db_185.h>,' common/common.h
    sed -i 's/target_link_libraries(nvi PRIVATE ''${UTIL_LIBRARY})/if(UTIL_LIBRARY)\n        target_link_libraries(nvi PRIVATE ''${UTIL_LIBRARY})\n    endif()/' CMakeLists.txt
    sed -i 's/target_link_libraries(nvi PRIVATE ''${RESOLV_LIBRARY})/if(RESOLV_LIBRARY)\n        target_link_libraries(nvi PRIVATE ''${RESOLV_LIBRARY})\n    endif()/' CMakeLists.txt
  '';

  # nvi2 is a straightforward cmake build. On illumos: ensure the curses lib is
  # ncurses (wide, from the store), and link -lsocket -lnsl if the DB/recovery
  # code pulls them. The gawkReal hermeticity pattern applies (store -L before
  # any host lib dir) so ncurses resolves from /nix/store, not /usr/lib/64.
  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
  ];
  env.NIX_CFLAGS_COMPILE_BEFORE = "-L${lib.getLib ncurses}/lib";
  # -lsocket -lnsl: illumos split socket/name-service libs. -lresolv: recover.c
  # uses b64_ntop/b64_pton (illumos puts them in libresolv, not libc). nvi2's own
  # find_library(resolv) probes __b64_ntop (underscored, absent) and misses this.
  env.NIX_LDFLAGS = "-lsocket -lnsl -lresolv";

  # nvi2 installs `nvi`; provide the classic vi/ex/view names as links to it.
  postInstall = ''
    if [ -x "$out/bin/nvi" ]; then
      for n in vi ex view; do
        [ -e "$out/bin/$n" ] || ln -s nvi "$out/bin/$n"
      done
    fi
  '';

  meta = with lib; {
    description = "nvi2 — modernized Berkeley nvi (solnix default vi)";
    homepage = "https://github.com/lichray/nvi2";
    license = licenses.bsd3; # nvi is BSD (CSRG); nvi2 keeps the BSD license
    mainProgram = "nvi";
    platforms = platforms.illumos or [ "x86_64-solaris" ];
  };
})
