# pkgs/illumos/nvi2.nix — nvi2 (github.com/lichray/nvi2): the modernized nvi editor.
#
# solnix's default `vi`. A small, wide-char nvi fork (C) — a clean, illumos-friendly
# vi with no vim dependency. Packaged as `nvi`; `vi`/`ex`/`view` link to it.
#
# Build: cmake, C. Deps: ncurses (curses UI) + real Berkeley DB 1.85 (db1). nvi
# uses the BSD 1.85 dbopen() API for its file backing (an in-memory RECNO tree
# with a `bfname` backing file, 0-based append). On BSD, dbopen lives in libc;
# illumos has no dbopen, so nvi2's CMakeLists links a `db1` lib and includes
# <db.h> for the 1.85 API. We supply both from the db1 package (real BSD DB
# 1.85 -- see db1.nix). Berkeley DB 5.x --enable-compat185 is NOT a drop-in:
# its RECNO is 1-based and rejects nvi's record-0 append. Installs bin/{nvi,vi,
# ex,view} + share/vi.
#
# Usage (in the fork overlay / a callPackage site):
#   nvi = pkgs.callPackage ./nvi2.nix { db1 = pkgs.callPackage ./db1.nix {}; };
{ lib, stdenv, fetchFromGitHub, cmake, ncurses, pkg-config, db1 }:

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
  buildInputs = [ ncurses db1 ];

  # nvi2's CMakeLists links a `db1` lib and includes <db.h> for the 1.85 API.
  # The db1 package provides exactly those names (lib/libdb1.so, include/db.h),
  # so no CMakeLists rewrite of the db link/include is needed -- unlike the old
  # db5-compat path, which had to rename the lib to `db` and the header to
  # <db_185.h>. The include/lib dirs come in via NIX_CFLAGS/NIX_LDFLAGS below.
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
    sed -i 's,include_directories(''${CMAKE_CURRENT_BINARY_DIR}),include_directories(''${CMAKE_CURRENT_BINARY_DIR} ''${CMAKE_CURRENT_SOURCE_DIR}),' CMakeLists.txt
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
  # Store -L before any host lib dir (hermeticity). Also expose db1's include so
  # find_path(db.h) and the compile resolve the real 1.85 header, and db1's lib
  # so find_library(db1) resolves libdb1.so from the store.
  env.NIX_CFLAGS_COMPILE_BEFORE = "-L${lib.getLib ncurses}/lib -L${db1}/lib -I${db1}/include";
  # -lsocket -lnsl: illumos split socket/name-service libs. -lresolv: recover.c
  # uses b64_ntop/b64_pton (illumos puts them in libresolv, not libc). nvi2's own
  # find_library(resolv) probes __b64_ntop (underscored, absent) and misses this.
  # -L${db1}/lib so the db1 link resolves; -R for the runtime search path.
  env.NIX_LDFLAGS = "-L${db1}/lib -R${db1}/lib -lsocket -lnsl -lresolv";

  # nvi2 installs `nvi`; provide the classic vi/ex/view names as links to it.
  # Then run nvi's own edit smoke test in-build (scripted ex session: append a
  # line, write, quit; verify the file content). This is the exact operation
  # that failed on db5-compat. On success, drop a `nvi-edits-ok` marker: the
  # media build (oi-make-livecd.sh) gates pointing the system vi/ex/view at nvi
  # on the presence of $out/bin/nvi-edits-ok, so vi becomes nvi only once nvi
  # can actually edit.
  postInstall = ''
    if [ -x "$out/bin/nvi" ]; then
      for n in vi ex view; do
        [ -e "$out/bin/$n" ] || ln -s nvi "$out/bin/$n"
      done
    fi

    export LD_LIBRARY_PATH="${db1}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    tf="$(mktemp)"
    printf 'a\nhello world\n.\nw\nq\n' | "$out/bin/ex" -s "$tf"
    if grep -q '^hello world$' "$tf"; then
      echo "nvi edit smoke test PASSED: $(cat "$tf")"
      touch "$out/bin/nvi-edits-ok"
    else
      echo "nvi edit smoke test FAILED; file was:" >&2
      cat "$tf" >&2
      exit 1
    fi
    rm -f "$tf"
  '';

  meta = with lib; {
    description = "nvi2 — modernized Berkeley nvi (solnix default vi)";
    homepage = "https://github.com/lichray/nvi2";
    license = licenses.bsd3; # nvi is BSD (CSRG); nvi2 keeps the BSD license
    mainProgram = "nvi";
    platforms = platforms.illumos or [ "x86_64-solaris" ];
  };
})
