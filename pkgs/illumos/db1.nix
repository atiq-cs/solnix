# pkgs/illumos/db1.nix -- real BSD DB 1.85 (the classic dbopen/hash/btree/recno
# access-method library), built from source with mk-src-pkg (base-src.nix calls it).
#
# nvi (nvi2) calls the 1.85 dbopen() API: an in-memory RECNO tree with a `bfname`
# backing file, 0-based append (R_IAFTER on record 0 folds to R_IBEFORE at the
# front). Berkeley DB 5.x with --enable-compat185 is NOT a drop-in: its RECNO is
# 1-based and rejects record 0 ("illegal record number of 0"), and it does not
# honour the 1.85 `bfname` field. This packages the genuine 1.85 sources.
#
# Source: Debian's db1-compat (a standalone extraction of the BSD DB 1.85
# hash/btree/recno/mpool tree with a glibc `compat.h`). Its Makefile is glibc-tree
# only (includes ../Makeconfig), so the access-method .c files are compiled
# directly into a shared lib.
#
# illumos port: illumos has no <sys/cdefs.h> (db.h includes it for __P/__PMT/
# __BEGIN_DECLS/__signed) and no BSD u_int8_t/u_int16_t/u_int32_t aliases or
# BYTE_ORDER/LITTLE_ENDIAN macros. patches/db1-cdefs.h supplies them and sets
# __BIT_TYPES_DEFINED__ so db.h skips its own int8_t.. typedefs (illumos has them).
#
# Installs (64-bit, lib/amd64 as every mk-src-pkg library):
#   lib/amd64/libdb-1.85.so.1  (SONAME libdb-1.85.so.1)
#   lib/amd64/libdb1.so        (-> libdb-1.85.so.1, for -ldb1)
#   include/db.h mpool.h ndbm.h, include/db_185.h (-> db.h), include/sys/cdefs.h
{ mkSrcPkg }:

mkSrcPkg {
  pname = "db1"; version = "1.85";
  src = { url = "http://deb.debian.org/debian/pool/main/d/db1-compat/db1-compat_2.1.3.orig.tar.gz";
          sha256 = "b01f560f00a67f921e678586d903969015b0c9cec6c18b1679b7e9fd6d27394e"; };
  build = ''
    mkdir -p sysinc/sys
    cp ${./patches/db1-cdefs.h} sysinc/sys/cdefs.h
    for f in btree/*.c hash/*.c recno/*.c db/*.c mpool/*.c; do
      $CC -fPIC -O2 -w -D__DBINTERFACE_PRIVATE -I. -Ibtree -Ihash -Irecno -Isysinc -c "$f" -o "$(basename "$f" .c).o"
    done
    $CC -shared -Wl,-h,libdb-1.85.so.1 -o libdb-1.85.so.1 *.o
    mkdir -p "$out/$LIBSUB" "$out/include/sys"
    cp libdb-1.85.so.1 "$out/$LIBSUB/"
    ln -s libdb-1.85.so.1 "$out/$LIBSUB/libdb1.so"
    ln -s libdb-1.85.so.1 "$out/$LIBSUB/libdb-1.85.so"
    cp db.h mpool.h ndbm.h "$out/include/"
    ln -s db.h "$out/include/db_185.h"
    # db.h includes <sys/cdefs.h> unconditionally; consumers compiling against
    # $out/include resolve it to the same port header.
    cp sysinc/sys/cdefs.h "$out/include/sys/cdefs.h"

    # Self-check, linked against the INSTALLED lib (no LD_LIBRARY_PATH): the exact
    # 1.85 usage nvi relies on -- a RECNO db with a bfname backing file, append at
    # record 0, read back. db5-compat fails this operation.
    cat > recno_test.c <<'TEST'
    #include <sys/types.h>
    #include <fcntl.h>
    #include <stdio.h>
    #include <string.h>
    #include <stdlib.h>
    #include <unistd.h>
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
        printf("db1 RECNO OK: append at record 0 + read back\n");
        return 0;
    }
    TEST
    $CC -O2 -I"$out/include" recno_test.c -o recno_test -L"$out/$LIBSUB" -ldb1
    ./recno_test || { echo "FATAL: db1 RECNO self-check" >&2; exit 1; }
  '';
}
