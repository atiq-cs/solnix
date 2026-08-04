# pkgs/illumos/db1.nix — real BSD DB 1.85 (the classic dbopen/hash/btree/recno
# access-method library) as a solnix derivation.
#
# nvi2 (and other CSRG-lineage tools) call the 1.85 dbopen() API: an in-memory
# RECNO tree with a `bfname` backing file, 0-based append (R_IAFTER on record 0
# folds to R_IBEFORE at the front). Berkeley DB 5.x with --enable-compat185 is
# NOT a drop-in: its RECNO is 1-based and rejects record 0 ("illegal record
# number of 0"), and it does not honour the 1.85 `bfname` field. This packages
# the genuine 1.85 sources so the API behaves exactly as those tools expect.
#
# Source: Debian's db1-compat (a maintained standalone extraction of the BSD
# DB 1.85 hash/btree/recno/mpool tree with a glibc `compat.h` shim). Its own
# Makefile is glibc-tree-only (includes ../Makeconfig, ../Rules); we compile the
# access-method .c files directly into a shared lib instead.
#
# illumos port: illumos has no <sys/cdefs.h> (which db.h includes for __P/__PMT/
# __BEGIN_DECLS/__signed) and no BSD u_int8_t/u_int16_t/u_int32_t aliases or
# BYTE_ORDER/LITTLE_ENDIAN macros. A vendored sys/cdefs.h supplies all of these
# and sets __BIT_TYPES_DEFINED__ so db.h skips its own int8_t/int16_t/int32_t
# typedefs (illumos already defines those via <sys/int_types.h>, which would
# otherwise collide).
#
# Installs:
#   lib/libdb-1.85.so.1  (real file, SONAME libdb-1.85.so.1)
#   lib/libdb1.so        (-> libdb-1.85.so.1; the name find_library(db1) wants)
#   include/db.h         (the 1.85 API header)
#   include/db_185.h     (-> db.h; the name BDB-compat consumers expect)
{ lib, stdenv, fetchurl }:

stdenv.mkDerivation (finalAttrs: {
  pname = "db1";
  version = "1.85";

  src = fetchurl {
    # Debian db1-compat orig tarball: verbatim BSD DB 1.85 access methods.
    url = "http://deb.debian.org/debian/pool/main/d/db1-compat/db1-compat_2.1.3.orig.tar.gz";
    hash = "sha256-sB9WDwCmf5IeZ4WG2QOWkBWwyc7GwYsWebfp/W0nOU4=";
  };

  # The tarball unpacks to a top-level db/ dir.
  sourceRoot = "db";

  # No configure/cmake: a direct compile of the access-method sources.
  dontConfigure = true;

  # Vendor the illumos port header onto the include path as <sys/cdefs.h>.
  postPatch = ''
    mkdir -p sysinc/sys
    cp ${./patches/db1-cdefs.h} sysinc/sys/cdefs.h
  '';

  buildPhase = ''
    runHook preBuild
    INC="-I. -Ibtree -Ihash -Irecno -Isysinc"
    DEF="-D__DBINTERFACE_PRIVATE"
    for f in btree/*.c hash/*.c recno/*.c db/*.c mpool/*.c; do
      $CC -fPIC -O2 -w $DEF $INC -c "$f" -o "$(basename "$f" .c).o"
    done
    $CC -shared -Wl,-soname,libdb-1.85.so.1 -o libdb-1.85.so.1 *.o
    runHook postBuild
  '';

  # Link the RECNO self-check: replicate a tool's exact 1.85 usage (open a RECNO
  # db with a bfname backing file, append at record 0, read it back). This is
  # the operation db5-compat rejects; it must succeed here.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    cat > recno_test.c <<'TEST'
    #include <sys/types.h>
    #include <fcntl.h>
    #include <stdio.h>
    #include <string.h>
    #include <stdlib.h>
    #include <db.h>
    int main(void) {
        RECNOINFO oinfo; DB *db; DBT key, data; recno_t lno;
        char bf[] = "/tmp/db1_recno_bf.XXXXXX";
        int fd = mkstemp(bf); if (fd >= 0) close(fd);
        memset(&oinfo, 0, sizeof(oinfo));
        oinfo.bval = '\n'; oinfo.bfname = bf;
        db = dbopen(NULL, O_CREAT | O_RDWR, 0600, DB_RECNO, &oinfo);
        if (db == NULL) { perror("dbopen"); return 2; }
        lno = 0; key.data = &lno; key.size = sizeof(lno);
        data.data = "hello world"; data.size = 11;
        if (db->put(db, &key, &data, R_IAFTER) != 0) { perror("put"); return 3; }
        lno = 1; key.data = &lno; key.size = sizeof(lno); memset(&data, 0, sizeof(data));
        if (db->get(db, &key, &data, 0) != 0) { perror("get"); return 4; }
        if (data.size != 11 || memcmp(data.data, "hello world", 11) != 0) return 5;
        db->close(db); unlink(bf);
        printf("db1 RECNO OK: append at record 0 + read back 'hello world'\n");
        return 0;
    }
    TEST
    $CC -O2 -I. -Isysinc -D__DBINTERFACE_PRIVATE recno_test.c -o recno_test \
      libdb-1.85.so.1
    LD_LIBRARY_PATH=$PWD ./recno_test
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib" "$out/include/sys"
    cp libdb-1.85.so.1 "$out/lib/"
    ln -s libdb-1.85.so.1 "$out/lib/libdb1.so"
    ln -s libdb-1.85.so.1 "$out/lib/libdb-1.85.so"
    cp db.h mpool.h ndbm.h "$out/include/"
    ln -s db.h "$out/include/db_185.h"
    # db.h does `#include <sys/cdefs.h>` unconditionally; illumos has none. Ship
    # the same port shim so consumers (nvi et al.) compiling against $out/include
    # resolve it via -I$out/include.
    cp sysinc/sys/cdefs.h "$out/include/sys/cdefs.h"
    runHook postInstall
  '';

  meta = with lib; {
    description = "Berkeley DB 1.85 (BSD dbopen/hash/btree/recno access methods)";
    homepage = "https://tracker.debian.org/pkg/db1-compat";
    license = licenses.bsd3;
    platforms = platforms.illumos or [ "x86_64-solaris" ];
  };
})
