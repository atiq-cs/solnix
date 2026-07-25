# solnix T3.1 — Dependency-ordered build plan (OpenIndiana Hipster, x86_64)

Drives the parallel fan-out. Derived from the Hipster publisher dependency
catalog (`catalog.dependency.C`, `require`/`require-any` edges = IPS/ELF-`NEEDED`
runtime deps = solnix RUNPATH-closure edges). Tiers below are SCC-condensed
longest-path depth over the **5 920 current/buildable** packages (obsolete,
renamed, and the 8 incorporations excluded). Cross-reference each package's
`oi-userland/components/<path>/` dir for the exact source tarball, configure
flags, and illumos patches.

## The two headline facts for scheduling

1. **Almost everything in a tier is independent.** For each tier, nearly all
   members depend *only* on lower tiers (see the per-tier "independent" counts).
   So within a tier you fan out with no ordering between jobs — the tier boundary
   is the only barrier. Parallelism is limited by build-host cores, not by the
   graph.
2. **~59% of the work is Perl/Python modules** (1 837 Perl + 1 662 Python).
   Uniform recipes, mostly `perl Makefile.PL` / `pip`/`setup.py`. The single
   biggest throughput lever. But they form **mega-cycles** (below) — build each
   interpreter's module set as one bootstrap group, not strictly topologically.

## Tiers

Tier 0 = the illumos base (from the proto area solnix already extracts, T2.x —
**already in progress / done**, not rebuilt from userland recipes). Tiers 1+ are
the userland build fan-out.

| Tier | Packages | Independent (deps only in lower tiers) | What lives here |
|---:|---:|---:|---|
| **0** | 347 | 347 | base/roots: `SUNWcs` cluster, `runtime/perl(-542)`, `runtime/python-39`, `library/zlib`/`glib2`/`ncurses`/`libffi`/`pcre2`/`expat`/`gmp`/`openssl-3`, base -common subpkgs |
| **1** | 300 | 23 | base libs layer 2 (readline, mpfr, lz4, libidn, libtasn1, json-c, libyaml, sqlite, gdbm, bdb, nspr) + first tools |
| **2** | 1 542 | 1 214 | **biggest tier** — pkg-config/pkgconf/ninja/scons/flex, gnu-m4/grep/sed/diffutils, gzip/unzip, most Python-39 & Perl-542 modules |
| **3** | 1 020 | 1 012 | autoconf/automake, python-313, luajit, golang, tcl/tk, gawk, zsh, ssh, tmux, texinfo |
| **4** | 643 | 629 | gnu-make/make, libtool, libxslt, ruby, python-314, gnu-tar, gdb, vim, rsync, libssh2 |
| **5** | 651 | 642 | **gcc-10/13/14, clang-16..21**, mesa, curl/wget, docutils, sphinx |
| **6** | 596 | 588 | cmake, rustc, gettext, gtk3, xorg server, php-cli |
| **7** | 362 | 356 | meson, bison-38, git, gtk-doc, php |
| **8** | 216 | 216 | firefox, nut, bison-runtime-consumers |
| **9** | 88 | 88 | onbld, devhelp, mkdocs |
| **10** | 55 | 55 | |
| **11** | 30 | 28 | |
| **12** | 26 | 26 | mate-user-guide |
| **13** | 24 | 20 | nut-monitor-gui deps |
| **14** | 15 | 15 | nut-monitor-gui |
| **15** | 3 | 3 | |
| **16** | 2 | 2 | deepest leaves |

Note: tiers here are *runtime*-dep depth. **Build**-time deps push a few tools
higher (a package needs its build deps present, e.g. anything using cmake needs
tier-6 cmake staged first). The build scheduler must union runtime-tier with
"build deps present": treat the build-tool tiers (pkg-config T2, autoconf/
automake T3, make/libtool T4, gcc/clang T5, cmake T6, meson/bison T7) as
**staged gates** — once a build tool is cached, everything that needs it unblocks
regardless of its own runtime tier.

## Recommended fan-out order (coarse phases)

- **Phase T0 (done/in progress):** toolchain seed + proto-area base (gcc-14 +
  clang from T2.x; the 347 tier-0 base pkgs come from the extracted proto area).
- **Phase T1 — build deps:** the ~21 core build tools from the inventory's
  core-100 (make, autoconf, automake, libtool, pkg-config/pkgconf, cmake, ninja,
  meson, flex, bison, m4, gettext, git). Small set, unblocks everything. Build
  serially-ish (they have a short internal chain) then cache.
- **Phase T2 — base libs:** the ~35 core base libs (zlib, bzip2, xz, zstd, lz4,
  openssl-3, libffi, ncurses, readline, pcre2, libxml2, expat, gmp/mpfr/mpc,
  glib2, sqlite, …). Highly parallel once T1 tools exist.
- **Phase T3 — compilers/interpreters + headline tools:** gcc/clang variants,
  perl/python/ruby/lua/tcl/go/rust/node/java, bash/zsh/coreutils/vim/git/ssh/etc.
- **Phase T4+ — the long tail (bulk):** the ~3 500 Perl/Python modules (fan out
  per interpreter, see cycle note), then desktop (MATE/Xorg/GTK), databases
  (postgres ×N, mariadb), web (php/apache), and the long-pole single builds.

## Dependency cycles (must build as a group, not topologically)

27 strongly-connected components have size > 1 in the require graph. These
cannot be strictly topologically ordered — build each SCC as one unit (stage
sources, build all members, then let the linker resolve them together), or
bootstrap (build a minimal member first, then the rest against it).

| Size | Members (sample) | Handling |
|---:|---|---|
| **277** | `SUNWcs`, `SUNWcsd`, `compress/bzip2`, `compress/xz`, `database/berkeleydb-5`, `library/lmdb`, … | The deeply-interlinked **base userland** — comes from the **proto area** solnix extracts (not a from-scratch userland cycle-break); treat as a single tier-0 unit. |
| **167** | `library/perl-5/*-540` (archive-tar, archive-zip, autodie, …) | **Perl-5.40 module SCC** — build the whole `-540` module set as one bootstrap group against perl-540. |
| **155** | `library/perl-5/*-538` | **Perl-5.38 module SCC** — same, against perl-538. |
| 8 | `audio/lame`, `audio/mpg123`, gstreamer-base, openal, pulseaudio, libvisual, … | audio stack — build together. |
| 4 | `editor/gnu-emacs` + gtk/no-x11/x11 variants | emacs variant split — one build, multiple outputs. |
| 3 | `x11/library/mesa` ↔ `x11/library/glu` ↔ `service/opengl/ogl-select` | **OpenGL/Mesa cycle** — GPU stack, llvmpipe-software first (hard tier). |
| 2 (×many) | libdbus/32, libtiff↔libwebp, gdk-pixbuf/32, libsecret/32, driver fcp↔fp, graphviz↔graphviz-python, php-cli↔php-common (×4 php versions), and ~10 Perl `X` ↔ `X-xs`/`X-gmp` pairs (math-prime-util, date-calc, math-random-isaac, html-formatter↔html-tree) | small mutual pairs — build the pair together. |

The base Perl module set (`library/perl-5/*` **without** version suffix) sits in
its own large interdependent block too; the version-suffixed sets (`-538/-540/
-542`) are the per-interpreter copies. **Build strategy for Perl/Python modules:**
per interpreter, stage all module sources, then run a fixpoint build loop
(build what's buildable, repeat until the SCC closes) — this is how CPAN/pip
bootstrap mutually-dependent modules anyway.

## Parallelization contract for the build agents

- **Barrier = tier boundary + build-tool availability.** Don't start tier N until
  tier N-1 is cached AND the build tools tier-N packages declare are cached.
- **Within a tier: no ordering.** Fan out freely; ~95%+ of each tier is
  independent. Batch by category to keep recipes similar per agent
  (all `library/perl-5/*-542` to one pool, all `library/python/*-313` to another).
- **Cycles = atomic units.** Assign a whole SCC to one agent (or one pool with a
  fixpoint loop); never split a cycle across agents expecting topological order.
- **Long poles** (firefox, libreoffice, thunderbird, gcc, llvm/clang, xorg,
  postgres-all) get **dedicated jobs** — multi-hour single builds; don't let a
  batch block on them.
- **Every output signed → the cache** (`scripts/oi-cache-publish.sh`), ledger row
  updated (`build-ledger.tsv`).

## `build-ledger.tsv` columns (what agents fill in)

| Column | Values | Filled by |
|---|---|---|
| `fmri` | package name | seeded (5 920 current pkgs) |
| `version` | Hipster version | seeded |
| `tier` | 0–16 | seeded |
| `gcc_status` | `todo`/`ok`/`fail` | build agent (gcc-14) |
| `clang_status` | `todo`/`ok`/`fail` | build agent (clang, latest) |
| `cached` | `no`/`yes` | publish step |
| `has_manpages` | `?`/`y`/`n` | build agent — set from the built package's `facet.doc.man` files (man rides along with the tool) |
| `doc_review` | `done`/`needed` | seeded `needed` for the 8 IPS/BE/SMF-divergent packages (`package/pkg*`, `package/svr4`, `install/beadm`, `SUNWcs`, `SUNWcsd`); agent patches those man pages and flips to `done` |
| `notes` | free text | agent |

See `hipster-inventory.md` → "Documentation & man pages" for the doc-review
trigger subjects and the new solnix man pages we owe.
