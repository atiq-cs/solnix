# OpenIndiana Hipster — Master Package Inventory (x86_64)

**Task:** solnix T3.1 first step — the complete, machine-readable inventory of
the OpenIndiana Hipster package set that solnix must build + cache for x86_64.
This is enumeration + analysis only (no builds).

## Source & method

- **Publisher:** `openindiana.org` → `https://pkg.openindiana.org/hipster/`
- **Build host:** `solnix-oi-build` (OpenIndiana Hipster, `illumos-960edb1c89`, i86pc).
- **Enumeration:** `pkg list -Haf "*"` (all forms, every published version) →
  50 288 rows → deduped to newest-per-name (`pkg` lists newest first within a
  name). **10 607 unique package names.**
- **Metadata (summary/consolidation):** parsed from the host's on-disk publisher
  catalog `catalog.summary.C` (JSON) — pure local read, zero network, no build
  contention. 1:1 match with the `pkg list` name set (10 607 / 10 607).
- **Dependency graph:** parsed from `catalog.dependency.C` (`require` /
  `require-any` / `incorporate` depend actions). These are IPS runtime deps
  derived from ELF `NEEDED` by `pkgdepend` — exactly the RUNPATH-closure edges
  solnix needs for build ordering.

The full per-package data is in **`hipster-packages.tsv`** (columns: `name`,
`version`, `status`, `tier`, `consolidation`, `summary`).

## Totals

| Bucket | Count |
|---|---:|
| **Unique package names** | **10 607** |
| **Current / buildable content** | **5 920** |
| Obsolete (newest version is `pkg.obsolete`) | 4 194 |
| Renamed (newest version is `pkg.renamed`) | 485 |
| Incorporations / metapackages (version-lock manifests, no content) | 8 |

So the real **build target is ~5 920 packages**, not 10 607 — nearly half the
catalog is historical obsolete/renamed cruft (old SUNW*, superseded versions,
renamed FMRIs) that solnix must **not** rebuild. The obsolete/renamed rows are
kept in the TSV (marked `status=obsolete`/`renamed`) as an authoritative
"do-not-build + provides-rename-mapping" list.

## The 8 incorporations (metapackages, not content)

These are pure version-lock manifests (`incorporate` deps only, no files):

- `consolidation/userland/userland-incorporation` — pins **9 648** userland pkgs
  (the master userland version lock; the single most important metapackage)
- `consolidation/osnet/osnet-incorporation` — pins 494 ON/gate pkgs
- `consolidation/X/X-incorporation`, `consolidation/l10n/l10n-incorporation`,
  `consolidation/install/install-incorporation`,
  `consolidation/sunpro/sunpro-incorporation`,
  `consolidation/sic_team/sic_team-incorporation`,
  `consolidation/xvm/xvm-incorporation`

solnix replaces incorporations with pinned Nix inputs — do not build these, but
`userland-incorporation` is the canonical source of the exact version each
package should be pinned to.

## Category breakdown (current content, by top-level FMRI path)

| Count | Category | Notes |
|---:|---|---|
| **4 016** | `library/` | dominated by language modules (see below) |
| 371 | `system/` | ON/gate system libs, kernel bits, core-os |
| 201 | `x11/` | Xorg server, libs, fonts, apps |
| 180 | `driver/` | device drivers (network/storage/etc.) |
| 147 | `developer/` | compilers, build tools, debuggers, langs |
| 102 | `locale/` | locale data |
| 90 | `web/` | php, apache, browsers, web tooling |
| 89 | `desktop/` | MATE desktop + apps |
| 72 | `runtime/` | perl/python/ruby/tcl/lua/java/node interpreters |
| 66 | `image/` | image libs + tools (graphviz, tiff, webp…) |
| 65 | `network/` | ssh, routing, network tools |
| 64 | `database/` | postgres (×N), mariadb, mysql, sqlite, bdb |
| 57 | `service/` | SMF services |
| 39 | `text/` | gawk/grep/sed/gettext/texinfo… |
| 35 | `gnome/` | residual GNOME bits |
| 32 | `diagnostic/` | diag tools |
| — | (tail) | print, editor, mail, terminal, backup, compress, games, audio, codec, security, crypto, … |

### The `library/` breakdown — this dominates the whole build

| Count | Sub-tree |
|---:|---|
| **1 837** | `library/perl-5/` — Perl CPAN modules |
| **1 662** | `library/python/` — Python packages |
| 72 | `library/desktop/` |
| 41 | `library/c++/` |
| tail | audio, security, java, common-lisp, math, gnome, ruby, ocaml, … |

**~3 500 of the 5 920 buildable packages (59%) are Perl or Python language
modules.** The Perl set is triplicated across interpreter versions
(`-538`/`-540`/`-542` suffixes: ~463 distinct modules × 3 + 464 unversioned).
The build fan-out is therefore *mostly* "build these N language modules against
each interpreter" — highly uniform, highly parallel, and the single biggest
lever for total throughput.

## Illumos-specific vs portable

- **Illumos-specific (from the ON gate, consolidation `osnet`):** `SUNWcs`,
  `SUNWcsd`, `system/library/*`, `system/kernel/*`, `driver/*`,
  `developer/build/onbld` (`nightly.sh`/`bldenv` tooling), `developer/build/make`
  (Sun dmake). These come from the **proto area** solnix already extracts (T2.x),
  not from a from-scratch userland build. Consolidation `osnet` = 494 pkgs.
- **Portable userland (consolidation `userland`):** the ~5 400 remaining current
  packages — standard open-source software with oi-userland build recipes. This
  is what the parallel build agents target. Each has a
  `oi-userland/components/<path>/` dir with `Makefile` + patches that document
  the exact source tarball, configure flags, and illumos-specific patches — the
  authoritative build recipe to cross-reference.

## Documentation & man pages

Docs and man pages are **in scope**: solnix must build + cache them, and a subset
must be **content-reviewed and patched** because they describe illumos mechanics
solnix replaces (IPS, beadm, svccfg, `/usr` paths).

### How man pages are delivered (the key fact)

Man coverage is **overwhelmingly bundled inside the tool packages**, not shipped
as separate man packages. IPS tags man-page files with the `facet.doc.man=true`
file action; e.g. **`SUNWcs` alone delivers 714 man pages** (verified via
`pkg contents -a facet.doc.man=true`). So:

- **Man coverage rides along with the tool build.** When an agent builds
  `shell/bash`, `network/ssh`, `SUNWcs`, etc., the tool's own man pages come with
  it into the cache — no separate man job needed. The build must **preserve the
  `facet.doc.man` files** (don't strip `share/man` in the RUNPATH-relocate hook).
- The ledger's **`has_manpages`** column flags which packages carry man content
  (so review + coverage can be tracked per tool).

### Dedicated documentation-content packages (build + cache as content)

Separate, buildable doc-content FMRIs (bundled manuals/handbooks, not generators):

| Tier | FMRI | Notes |
|---|---|---|
| T0 | `database/postgres-14/documentation` · `-15/documentation` · `-16/documentation` | PostgreSQL manuals + man pages |
| T0 | `x11/documentation/xorg-docs` · `x11/documentation/xorg-sgml-doctools` | X.Org docs + stylesheets |
| T0 | `web/server/apache-24/documentation` | Apache 2.4 manual |
| T0 | `library/apr-util/documentation` · `library/fastcgi/documentation` · `library/security/openssl-11/documentation` | library manuals |
| T0 | `documentation/tuntap` | tuntap/brdg/tunctl docs |
| T0 | `desktop/gnucash-docs` | GnuCash help |
| T12 | `desktop/mate/mate-user-guide` | MATE desktop docs |

### Man-page / doc-build infrastructure (must build to render/index man)

| Tier | FMRI | Role |
|---|---|---|
| T3 | `system/man` | Reference Manual Pages **tools** (`man`/`apropos`/`update-man-index`) |
| T4 | `text/doctools` | Documentation tools |
| T3 | `text/texinfo` | GNU Texinfo (info/makeinfo) |
| T3 | `text/rarian` | Documentation meta-data library (scrollkeeper successor) |
| T7 | `x11/xman` | X manual-page viewer |

(Doc *generators* — `doxygen`, `sphinx`, `docutils`, `mkdocs`, `gtk-doc`, POD
tools — are ordinary tool packages, not doc content; they build with their tiers.)

Obsolete/renamed man-ish FMRIs to **not** build (rename map only): `SUNWxwman`,
`system/manual/locale/*`, `library/java/manual*`, `SUNWphp524man`, etc.

### Doc review: pages that will be WRONG for solnix (`doc_review=needed`)

The man/doc content that describes illumos mechanics solnix **replaces** must be
reviewed and patched when the owning package is built. Trigger subjects and their
verified owning packages:

| Divergent subject (WRONG on solnix as-shipped) | solnix reality | Owning package(s) |
|---|---|---|
| `pkg`, `pkgrepo`, `pkgsend`, `pkgrecv`, `pkg.depotd`, publishers, IPS actions/FMRIs | **No IPS on solnix** — Nix store + binary cache | `package/pkg`, `package/svr4` |
| `beadm`, boot environments, BE clone/activate upgrade model | BEs → **Nix generations** (`beadm activate` ≡ rollback) | `install/beadm` |
| `svccfg`, manifest import, `restart_fmri`/`refresh_fmri`, manifest delivery | SMF manifests **generated by `smf.nix`** (`smf.services.*`) | `SUNWcs` |
| `svcadm`, `svcs` workflows (still valid, but managed declaratively) | `smf.services.*` module owns enable/disable | `SUNWcs` |
| `bootadm`, boot-archive update, loader menu edits | driven by generation switch / `make-be` | `SUNWcs` |
| package install/upgrade/update workflows (`pkg install/update/uninstall`) | `solnix-rebuild switch` | `package/pkg` |
| `/usr`, `/opt`, `/var/pkg`, `crle`/`/var/ld` path assumptions | **`/nix/store`** RUNPATH; `crle` bypassed | any tool man page hard-coding `/usr` paths |

Everything else defaults to `doc_review=done` (no patch needed — stock upstream
man page is correct on solnix). The `doc_review` column in the ledger tracks this
per package; agents building the packages above set `needed` and file the patch.

### New solnix man pages we owe (write + cache; not in the OI set)

solnix introduces commands/subjects with no upstream man page — these are new
deliverables (illumos section 8 for admin commands):

- **`solnix-rebuild(8)`** — build/switch/boot/test a configuration (the
  `nixos-rebuild` analog; wraps generation build + `beadm` activate).
- **`solnix-install(8)`** — install solnix to disk (rpool/ZFS root + first BE).
- **`switch-to-configuration(8)`** — activate a built generation within a BE
  (the low-level activation the rebuild wraps).
- **`solnix.conf(5)` / solnix configuration manual** — the module-option
  reference for `smf.services.*`, the `networking` (Crossbow: dladm/ipadm/vnics)
  module, and the `users`/`groups` module options (the NixOS-`configuration.nix`
  analog for illumos surfaces).
- (stretch) **`solnix-generation(8)` / `beadm`-vs-generations note** — map the BE
  model to Nix generations so admins coming from illumos aren't misled by the
  stock `beadm(8)` page.

These live in the solnix source (not the OI mirror) and are cached like any
other package's man pages.

## The ~100 highest-value "core" packages (build FIRST)

Rationale: these unblock the widest fan-out — the build toolchain, then the base
C libraries every other package links, then the compilers/interpreters, then the
headline user-facing tools. Tier (`Tn`) is the SCC-condensed dependency depth
(see `build-order.md`). Build tier 1 (build deps) and tier 2 (base libs) first;
they are what everything else needs.

### Tier 1 build deps

1. `developer/build/gnu-make` (T4) — A utility for directing compilation
2. `developer/build/make` (T4) — Parallel make(1) build tool
3. `developer/build/autoconf` (T3) — GNU autoconf utility
4. `developer/build/autoconf-archive` (T0) — GNU Autoconf Archive
5. `developer/build/automake` (T3) — A Makefile generator
6. `developer/build/libtool` (T4) — GNU libtool
7. `library/libtool/libltdl` (T1) — GNU libtool dlopen wrapper
8. `developer/build/pkg-config` (T2) — A tool to query library build-time information
9. `developer/build/pkgconf` (T2) — Package compiler and linker metadata toolkit
10. `developer/build/cmake` (T6) — A cross-platform, open-source make system
11. `developer/build/ninja` (T2) — Ninja - a small build system with a focus on speed
12. `developer/build/meson` (T7) — A high performance build system
13. `developer/build/scons` (T2) — Open Source next-generation build tool.
14. `developer/build/samurai` (T2) — samurai is a ninja-compatible build tool written in C99
15. `developer/lexer/flex` (T3) — Flex Lexer
16. `developer/parser/bison-38` (T7) — bison - A YACC Replacement
17. `developer/build/help2man` (T2) — help2man is a tool for automatically generating simple manual pages from program output
18. `developer/build/makedepend` (T2) — makedepend - makefile dependency generation utility
19. `developer/build/autoconf/xorg-macros` (T0) — GNU autoconf macros for X.Org software packages
20. `text/gnu-gettext` (T6) — GNU gettext - message handling utilities
21. `developer/versioning/git` (T7) — git - Fast Version Control System

### Tier 2 base libs (compression/crypto/text)

22. `library/zlib` (T1) — The Zip compression library
23. `compress/bzip2` (T1) — high-quality block-sorting file compressor
24. `compress/xz` (T1) — XZ Utils - loss-less file compression application and library
25. `compress/zstd` (T3) — Zstandard, or zstd for short, is a fast lossless compression algorithm, targeting real-time compression scenarios
26. `library/lz4` (T2) — Extremely Fast Compression algorithm
27. `library/security/openssl-3` (T1) — OpenSSL software library is a robust, commercial-grade, full-featured toolkit for general-purpose cryptography and secure communication
28. `library/security/openssl` (T1) — OpenSSL - a Toolkit for Secure Sockets Layer (SSL v2/v3) and Transport Layer (TLS v1) protocols and general purpose cryptographic library
29. `library/libffi` (T1) — Foreign Function Interface Library
30. `library/ncurses` (T1) — A CRT screen handling and optimization package.
31. `library/readline` (T2) — GNU readline provides interactive line-editing and history
32. `library/pcre2` (T1) — Version 2 of Perl-Compatible Regular Expressions
33. `library/pcre` (T2) — Perl-Compatible Regular Expressions
34. `library/libxml2` (T1) — Libxml2 is the XML C parser and toolkit developed for the Gnome project
35. `library/libxslt` (T4) — XSLT support for libxml2 (XML toolkit from the GNOME project)
36. `library/expat` (T1) — libexpat - XML parser library
37. `library/gmp` (T1) — GNU Multiple Precision Bignum Library
38. `library/mpfr` (T2) — The GNU Multiple Precision with IEEE Rounding Floating-Point Library
39. `library/mpc` (T3) — Multiprecision complex data type evaluation library
40. `library/libidn` (T2) — IDN - The Internationalized Domains Library
41. `library/nghttp2` (T3) — HTTP/2 C Library
42. `library/security/libgpg-error` (T2) — GnuPG Error Library
43. `system/library/security/libgcrypt` (T3) — GnuPG libgcrypt library
44. `library/glib2` (T1) — GNOME core libraries
45. `library/libedit` (T2) — Libedit - Command line editor library
46. `library/json-c` (T2) — A JSON implementation in C
47. `library/libyaml` (T2) — LibYAML is a YAML parser and emitter written in C
48. `database/sqlite-3` (T1) — in-process SQL database engine library
49. `library/database/gdbm` (T1) — gdbm is a set of database routines that use extensible hashing. It works similar to the standard UNIX dbm routines
50. `database/berkeleydb-5` (T1) — Berkeley DB is a computer software library that provides a high-performance embedded database for key/value data
51. `library/nspr` (T1) — Netscape Portable Runtime
52. `library/libtasn1` (T2) — Tiny ASN.1 library
53. `library/libssh2` (T4) — libssh2 - client-side C library implementing the SSH2 protocol
54. `developer/macro/gnu-m4` (T2) — GNU m4
55. `text/gnu-diffutils` (T2) — GNU Diffutils is a package of several programs related to finding differences between files
56. `text/texinfo` (T3) — Documentation system for on-line information and printed output

### Tier 3-5 compilers/interpreters

57. `developer/gcc-14` (T5) — GNU Compiler Collection
58. `developer/gcc-13` (T5) — GNU Compiler Collection
59. `developer/clang-20` (T5) — LLVM tools and Clang compiler
60. `developer/clang-21` (T5) — LLVM tools and Clang compiler
61. `runtime/perl` (T1) — Perl - Highly capable, feature-rich programming language
62. `runtime/perl-542` (T1) — Perl 5.42
63. `runtime/python-313` (T3) — The Python interpreter, libraries and utilities
64. `runtime/python-314` (T4) — The Python interpreter, libraries and utilities
65. `runtime/python-39` (T1) — The Python interpreter, libraries and utilities
66. `runtime/ruby` (T4) — Ruby, RubyGems, and Rake
67. `runtime/lua-54` (T2) — Lua is a powerful, fast, lightweight, embeddable scripting language.
68. `developer/luajit` (T3) — LuaJIT - Just-In-Time Compiler (JIT) for the Lua programming language
69. `runtime/tcl-8` (T2) — Tcl - portable scripting environment
70. `runtime/tk-8` (T3) — Tk - TCL GUI Toolkit
71. `developer/golang` (T3) — The Go Programming Language
72. `developer/lang/rustc` (T6) — Rust - Safe, concurrent, practical language
73. `runtime/java/openjdk17` (T3) — OpenJDK 17.0.17 Runtime Environment
74. `runtime/nodejs-22` (T2) — Evented I/O for V8 JavaScript version 22.

### Headline tools & shells

75. `shell/bash` (T1) — GNU Bourne-Again shell (bash)
76. `shell/zsh` (T3) — Z Shell (zsh)
77. `shell/ksh93` (T1) — ksh - Shell, the standard command language interpreter
78. `shell/which` (T2) — GNU which - Utility to show the full path of (shell) commands
79. `text/gawk` (T3) — GNU awk, a program that you can use to select particular records in a file and perform operations upon them.
80. `text/gnu-grep` (T2) — GNU grep utilities
81. `text/gnu-sed` (T2) — GNU implementation of sed, the Unix stream editor
82. `archiver/gnu-tar` (T4) — GNU version of the tar archiving utility
83. `compress/gzip` (T2) — The GNU Zip (gzip) compression utility
84. `compress/unzip` (T2) — Info-Zip (unzip)
85. `compress/zip` (T2) — The Info-Zip (zip) compression utility
86. `file/gnu-coreutils` (T2) — GNU Core Utilities are the basic file, shell and text manipulation utilities
87. `file/gnu-findutils` (T2) — GNU findutils
88. `developer/debug/gdb` (T4) — GDB: The GNU Project Debugger
89. `editor/vim` (T4) — Vi IMproved
90. `editor/nano` (T2) — GNU implementation of nano, a text editor emulating pico
91. `network/ssh` (T3) — OpenSSH client and associated utilities
92. `network/rsync` (T4) — Utility that provides fast incremental file transfer and copy
93. `web/curl` (T5) — The CURL Network Utility and Library
94. `web/wget` (T5) — GNU wget - a utility to retrieve files from the World Wide Web
95. `text/less` (T2) — Pager program similar to more
96. `terminal/tmux` (T3) — tmux terminal multiplexer
97. `developer/build/onbld` (T9) — OS-Net Build Tools
98. `library/tree-sitter` (T2) — Tree-sitter is a parser generator tool and an incremental parsing library

## Notable packages & surprises

**Present and buildable (good news):**
- **Compilers:** `gcc-14` (14.3.0), `gcc-13`, `gcc-10/7/3`; `clang-16/18/19/20/21`.
  Latest gcc-14 + clang-21 both shipped → the dual-toolchain T3 requirement is met.
- **Rust:** `developer/lang/rustc` is in-set (T6) — the T3.6 "big one" already
  has an oi-userland recipe; the crustc fallback may be unnecessary. Verify the
  bootstrap path against `oi-userland/components/developer/rust/`.
- **Go:** `developer/golang` (+ `-125`, `-126`).
- **Node:** `runtime/nodejs-20/22/24`. **Java:** OpenJDK 8/11/17/21.
- **Databases:** PostgreSQL **14/15/16/17** (each with contrib + many FDW/extension
  subpkgs — 46 postgres-* FMRIs), MariaDB 10.6, MySQL common, SQLite 3, BerkeleyDB.
- **Desktop:** full **MATE** (`desktop/mate/*`, 23+ pkgs) + Xorg (50 xorg-* FMRIs,
  `x11/server/xorg` T6, `x11/library/mesa` T5), GTK3 (T7).
- **Big apps:** `web/browser/firefox` (T8), `mail/thunderbird`,
  `desktop/office/libreoffice`, PHP 8.3/8.4/8.5.

**Known-hard / gaps (honesty, matches Phase-3 caveats):**
- **AI/ML stack is thin.** `library/python/numpy` is present, but **no scipy, no
  torch/pytorch, no tensorflow** in Hipster. T3.3's "CPU inference first" is the
  right call — llama.cpp/bitnet.cpp are not in the OI set either and will be new
  ports, not package rebuilds.
- **Wayland is essentially absent.** Only `wayland/freeway` exists — no
  wlroots/sway/labwc/compositor. T3.7's "start with Xorg, Wayland is real work"
  is confirmed by the catalog.
- **Mesa/GLU/OpenGL form a dependency cycle** (`x11/library/mesa` ↔
  `x11/library/glu` ↔ `service/opengl/ogl-select`) and illumos GPU/DRM support is
  llvmpipe-software-first — the graphical stack is a hard tier.
- **Huge subpackage fan-outs:** PostgreSQL, ClamAV, Bacula, LibreOffice, GCC, and
  the browsers each explode into many sub-FMRIs (client/library/tests/contrib
  splits). Count-wise cheap to *list*, expensive to *build* (Firefox/LibreOffice
  are multi-hour single builds — schedule as their own long-pole jobs, don't
  block a batch on them).
- **Perl/Python module mega-cycles:** the Perl module set forms one ~460-node
  strongly-connected component per interpreter version (mutual `require` deps).
  These must be built as a bootstrap group, not strictly topologically — see
  `build-order.md`.

- **`build-ledger.tsv`** — the per-package tracking sheet the build agents fill
  in (incl. `has_manpages` + `doc_review` for the documentation work above).

## Files in this directory

- **`hipster-packages.tsv`** — master inventory, 10 607 rows (all names incl.
  obsolete/renamed, marked by `status`). The registry target as data.
- **`hipster-inventory.md`** — this file (analysis + core-100).
- **`build-order.md`** — dependency-ordered build plan (tiers, parallelism, cycles).
- **`build-ledger.tsv`** — the per-package tracking sheet the build agents fill
  in (incl. `has_manpages` + `doc_review`).
