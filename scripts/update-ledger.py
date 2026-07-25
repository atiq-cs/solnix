#!/usr/bin/env python3
# update-ledger.py — mark tier-0/1/2 core packages built this wave in build-ledger.tsv.
# Sets gcc_status/clang_status/cached/has_manpages/notes for the exact fmri rows.
import sys, csv

LEDGER = "docs/registry/build-ledger.tsv"

# fmri -> (gcc, clang, has_man, note)
#   gcc/clang: "ok"/"fail"
#   has_man:   "y"/"n"
UPDATES = {
    "library/zlib":                 ("ok", "ok", "y", "solnix-built zlib-1.3.1 (both cc), ldd-clean, cached+fetch-verified"),
    "compress/bzip2":               ("ok", "ok", "y", "bzip2-1.0.8 (both cc), static bin clean; dyn bzip2 bin NEEDs host libbz2.so.1 (version-tag)"),
    "compress/xz":                  ("ok", "ok", "y", "xz-5.6.3 (both cc), ldd-clean, cached+fetch-verified"),
    "compress/zstd":                ("ok", "ok", "y", "zstd-1.5.6 (both cc), ldd-clean, cached"),
    "library/gmp":                  ("ok", "ok", "n", "gmp-6.3.0 --enable-cxx (both cc), ldd-clean, cached"),
    "library/libffi":               ("ok", "ok", "y", "libffi-3.4.6 (both cc), ldd-clean, cached"),
    "library/pcre2":                ("ok", "fail", "y", "pcre2-10.47 gcc clean+cached; clang fails linking pcre2-16/32 shared libs (solaris-ld)"),
    "library/expat":                ("ok", "ok", "y", "expat-2.6.4 (both cc), ldd-clean, cached"),
    "library/ncurses":              ("ok", "ok", "n", "ncurses-6.5 widec (both cc); form/menu/panel widget libs NEED host libncurses.so.5 (termlib split)"),
    "library/readline":             ("ok", "fail", "y", "readline-8.2 gcc clean+cached (termcap const patch); clang fails building shlib .so"),
    "library/libxml2":              ("ok", "ok", "y", "libxml2-2.12.9 (both cc); tools NEED libz SUNW_1.3 version-tag our zlib lacks (loads, tag warn)"),
    "library/security/openssl-3":   ("ok", "fail", "n", "openssl-3.4.0 gcc clean+cached (own libssl/libcrypto, RUNPATH lib/64); clang fails linking engine DSOs"),
    "developer/build/pkgconf":      ("ok", "ok", "y", "pkgconf-2.3.0 (both cc) + pkg-config compat symlink, ldd-clean, cached"),
    "developer/build/ninja":        ("ok", "ok", "n", "ninja-1.12.1 (both cc), C++ libstdc++ from store gcc14, ldd-clean, cached"),
    "developer/build/gnu-make":     ("ok", "ok", "y", "make-4.4.1 (both cc), ldd-clean, cached"),
    "developer/build/libtool":      ("ok", "ok", "y", "libtool-2.4.7 (both cc), cached"),
    "developer/build/autoconf":     ("ok", "ok", "y", "autoconf-2.72 (both cc), cached"),
    "developer/build/automake":     ("ok", "ok", "y", "automake-1.16.5 (both cc), cached"),
    "developer/lexer/flex":         ("ok", "ok", "y", "flex-2.6.4 (both cc), ldd-clean, cached"),
    "developer/macro/gnu-m4":       ("ok", "ok", "y", "m4-1.4.19 (both cc), gnulib getlocalename_l const patch, ldd-clean, cached"),
    "developer/parser/bison-38":    ("ok", "ok", "y", "bison-3.8.2 (both cc), gnulib patch, ldd-clean, cached"),
    "text/gnu-diffutils":           ("ok", "ok", "y", "diffutils-3.10 (both cc), gnulib patch, cached"),
    "text/gnu-grep":                ("ok", "ok", "y", "grep-3.11 + pcre2-10.47 (both cc), ldd-clean, cached"),
    "text/less":                    ("ok", "ok", "y", "less-668 gcc clean; NEEDs host libncurses.so.5 (built vs host term), cached"),
    "database/sqlite-3":            ("ok", "ok", "y", "sqlite-3.47.2 (both cc); libsqlite3.so clean; sqlite3 shell NEEDs host libtermcap/libcurses, cached"),
    "library/libyaml":              ("ok", "ok", "n", "libyaml-0.2.5 (both cc), ldd-clean, cached"),
    "library/lz4":                  ("ok", "ok", "y", "lz4-1.10.0 (both cc), ldd-clean, runs, cached"),
    "library/libtasn1":             ("ok", "ok", "y", "libtasn1-4.19.0 (both cc), gnulib patch, ldd-clean, cached"),
    "library/security/libgpg-error":("ok", "ok", "n", "libgpg-error-1.50 (both cc), illumos environ extern patch, ldd-clean, cached"),
}

rows = []
with open(LEDGER, newline="") as f:
    r = csv.reader(f, delimiter="\t")
    header = next(r)
    rows = list(r)

hit = 0
for row in rows:
    fmri = row[0]
    if fmri in UPDATES:
        gcc, clang, man, note = UPDATES[fmri]
        row[3] = gcc      # gcc_status
        row[4] = clang    # clang_status
        row[5] = "yes"    # cached
        row[6] = man      # has_manpages
        # row[7] doc_review unchanged
        row[8] = note     # notes
        hit += 1

with open(LEDGER, "w", newline="") as f:
    w = csv.writer(f, delimiter="\t", lineterminator="\n")
    w.writerow(header)
    w.writerows(rows)

print(f"updated {hit} ledger rows (of {len(UPDATES)} targets)")
