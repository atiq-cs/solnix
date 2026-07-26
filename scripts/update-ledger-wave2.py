#!/usr/bin/env python3
# update-ledger-wave2.py — mark wave-2 packages in build-ledger.tsv.
# Sets gcc_status/clang_status/cached/has_manpages/notes for the exact fmri rows.
import csv

LEDGER = "docs/registry/build-ledger.tsv"

# fmri -> (gcc, clang, cached, has_man, note)
UPDATES = {
    # interpreters (highest leverage)
    "runtime/perl":        ("ok", "fail", "yes", "y", "solnix perl-5.42.0 gcc: runs (perl -v, List::Util), ldd-clean, cached+fetch-verified; clang fails (Configure 64-bit probe)"),
    "runtime/perl-542":    ("ok", "fail", "yes", "y", "same build as runtime/perl (perl-5.42.0), gcc cached; clang 64-bit probe issue"),
    "runtime/python":      ("ok", "todo", "yes", "y", "solnix python-3.9.20 gcc: runs, imports ssl/sqlite3/zlib/ctypes/lzma; cached+fetch-verified; leaks host libintl/libsendfile (base libs)"),
    "runtime/python-39":   ("ok", "todo", "yes", "y", "solnix python-3.9.20 gcc: runs (--version, C-ext imports OK), cached+fetch-verified"),
    "runtime/python-313":  ("fail", "todo", "no", "?", "3.13.1 gcc WIP: fixed _socket(-lresolv) + compileall forkserver(-j1); rebuilding"),
    # tier-2 libs layer 2
    "library/mpfr":        ("ok", "todo", "yes", "n", "mpfr-4.2.1 gcc (--with-gmp store), cached"),
    "library/mpc":         ("ok", "todo", "yes", "n", "mpc-1.3.1 gcc (gmp+mpfr store), cached"),
    "library/libunistring":("ok", "todo", "no",  "n", "libunistring-1.2 gcc, gnulib getlocalename_l patch"),
    "library/nspr":        ("ok", "todo", "yes", "n", "nspr-4.35 gcc --enable-64bit, cached"),
    "database/berkeleydb-5":("ok","todo", "yes", "n", "db-5.3.28 gcc --with-mutex=POSIX/pthreads --enable-cxx, cached"),
    # tier-2/3 tools
    "runtime/tcl-8":       ("ok", "todo", "yes", "y", "tcl-8.6.14 gcc core (tclsh+libtcl); bundled pkgs/ skipped (alloca on illumos), cached"),
    "developer/luajit":    ("ok", "todo", "yes", "y", "luajit-2.1 gcc (amalg), cached"),
    "text/gawk":           ("ok", "todo", "yes", "y", "gawk-5.3.1 gcc, cached"),
    "text/gnu-sed":        ("ok", "todo", "yes", "y", "sed-4.9 gcc (gnulib patch), cached"),
    "archiver/gnu-tar":    ("ok", "todo", "yes", "y", "tar-1.35 gcc (FORCE_UNSAFE_CONFIGURE), cached"),
    "compress/gzip":       ("ok", "todo", "yes", "y", "gzip-1.14 gcc, cached"),
    "developer/build/help2man":("ok","todo","yes","y", "help2man-1.49.3 gcc, cached"),
    "developer/build/scons":("ok","todo","yes","y",   "scons-4.8.1 gcc (python launcher), cached"),
    # texinfo fmri check
    "developer/documentation-tool/texinfo": ("ok","todo","yes","y","texinfo-7.1 gcc (tputs incompatible-ptr downgraded), cached"),
    # gdbm as dep
    "database/gdbm":       ("ok", "todo", "yes", "y", "gdbm-1.24 gcc (readline+ncurses), cached"),
}

with open(LEDGER, newline="") as f:
    r = csv.reader(f, delimiter="\t")
    header = next(r)
    rows = list(r)

hit = set()
for row in rows:
    fmri = row[0]
    if fmri in UPDATES:
        gcc, clang, cached, man, note = UPDATES[fmri]
        row[3], row[4], row[5], row[6], row[8] = gcc, clang, cached, man, note
        hit.add(fmri)

with open(LEDGER, "w", newline="") as f:
    w = csv.writer(f, delimiter="\t", lineterminator="\n")
    w.writerow(header)
    w.writerows(rows)

missing = set(UPDATES) - hit
print(f"updated {len(hit)} rows; missing fmris (not in ledger): {sorted(missing)}")
