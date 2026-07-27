# Design: mining NetBSD pkgsrc for illumos build patches

**Purpose.** NetBSD's pkgsrc has decades of per-package illumos/SunOS/Solaris
build fixes. For solnix's hard-tail packages — the ones plain upstream tarballs
can't compile on illumos (alloca, struct/macro redefinitions, missing headers,
feature-test-macro gates, GNU-libtool link quirks) — pkgsrc is a ready-made
patch source. This is the reusable workflow so every future wave can turn a
"stuck on illumos" package into a cached build without re-discovering the fix.

It generalises the wave-8 pattern (heavy tools unblocked by inline illumos
patches) into: **harvest → filter → apply → build → publish**.

---

## 1. Where the fixes live in pkgsrc

A pkgsrc package is a directory `<category>/<name>/` (e.g. `textproc/oniguruma`,
`security/libgcrypt`). The illumos-relevant content is in **two** places:

1. **`patches/patch-*`** — unified diffs against the *unpacked upstream source*.
   Each carries a `$NetBSD$ …` header line (GNU `patch` skips it cleanly) and a
   one-line rationale. They are **`-p0`** diffs: the paths are
   `--- foo/bar.c.orig` / `+++ foo/bar.c` relative to the source root. A patch
   named `patch-<mangled-path>` (dots/slashes → underscores) or the older
   `patch-aa`, `patch-ab`, … alphabetic scheme.

2. **`Makefile`** — the build recipe. The illumos knobs are in
   `.if ${OPSYS} == "SunOS"` blocks:
   `CONFIGURE_ARGS.SunOS+=`, `CFLAGS.SunOS+=`, `LDFLAGS.SunOS+=`,
   `CONFIGURE_ENV+=`. **Many packages need NO patch — just a configure/CFLAGS
   knob** the Makefile sets for SunOS. Read the Makefile even when `patches/` is
   empty or absent.

`distinfo` records the exact `DISTNAME` + upstream checksums (BLAKE2s/SHA512) —
use it to pin the version, then compute our own SHA-256 of the tarball.

### Not every patch is for us
pkgsrc patches target *all* platforms pkgsrc supports. A `patch-configure`
touching autoconf boilerplate, or a NetBSD-kernel dialect patch (e.g. lsof's
`dialects/n+obsd/…`), is irrelevant to illumos. **Filter for illumos markers**
(§3). Kernel-coupled tools whose per-OS source lives in their *own* tree (lsof,
htop) get their illumos support upstream, not from a pkgsrc patch — skip those;
the leverage is in portable libraries + userland tools.

---

## 2. Harvest — `scripts/pkgsrc-harvest.sh`

No full clone (~1 GB). Sparse-fetch a package's `Makefile`, `distinfo`, and
`patches/*` via the GitHub **raw** + **contents API** off `NetBSD/pkgsrc@trunk`:

```sh
scripts/pkgsrc-harvest.sh security/libgcrypt devel/libffi shells/bash …
```

Writes `artifacts/pkgsrc-patches/<name>/{Makefile,distinfo,patches/}` and flags
each patch that matches an illumos marker. `MANIFEST.tsv` summarises
`pkgdir  npatches  illumos_relevant_patches` across a harvest run.

**Finding a package's pkgsrc path.** The category is not always obvious
(`oniguruma` is `textproc/`, not `devel/`). Probe the contents API:
`curl .../contents/<cat>/<name>` → HTTP 200 confirms. Common cats: `devel`,
`textproc`, `security`, `net`, `www`, `mail`, `shells`, `sysutils`,
`converters`, `archivers`, `databases`, `editors`.

**Rate limits.** Unauthenticated GitHub API is ~60 req/hr; a big harvest run
will start returning HTTP 403. Batch the harvest, or space runs out. The `raw`
host (`raw.githubusercontent.com`) is not API-rate-limited — fetch known file
paths directly when you already know them.

---

## 3. Filter — which patch is an illumos fix

Grep the harvested patch for these markers (the harvester does this
automatically):

```
SunOS  Solaris  illumos  __sun  __illumos__  sun4
__EXTENSIONS__  _XOPEN_SOURCE            # feature-test-macro gate
alloca  <alloca.h>                       # the classic illumos alloca wall
u_int  sys/types  <strings.h> <stdint.h> # missing-typedef / missing-header
byteorder  endian                        # endianness
/proc  procfs                            # illumos /proc differs from Linux/BSD
__SUNPRO_C                               # Sun Studio only — gcc usually skips these
```

Then **read the rationale line** at the top of the patch (`$NetBSD$` is followed
by a human comment). A `__SUNPRO_C`-guarded patch is for Sun Studio and is
usually a no-op under our gcc-14; a `printf`/`vprintf` `#undef` after
`<libintl.h>` is a real gcc break too. When in doubt, apply it — pkgsrc patches
are conservative and `#if`-guarded to the platform.

### The recurring illumos-fix classes (what you will actually see)
- **feature-test macros** — Solaris libc hides POSIX/XPG symbols behind
  `__EXTENSIONS__` / `_XOPEN_SOURCE`. Fix = add the defines (we have
  `illumosExt` in `packages.nix`). *Most common; usually no patch, a CFLAGS knob.*
- **alloca** — `alloca()` needs `<alloca.h>` on illumos, not `<stdlib.h>`.
  Fix = `-Dalloca=__builtin_alloca` or include `<alloca.h>` (see `oniguruma`).
- **macro/struct/redefinition collisions** — a system header (`libintl.h`,
  a system `struct comment`) collides with the package's own name. Fix = `#undef`
  the macro or rename the struct (see `aspell`, wave-8 `tree`).
- **missing device macros** — `major`/`minor`/`makedev` live in `<sys/mkdev.h>`
  on illumos (`MAJOR_IN_MKDEV`); guard with `|| defined(__illumos__)`.
- **GNU-libtool link quirks** — Solaris ld rejects two `libfoo.so` on one link
  line (`libiconv`); the fix drops the redundant `../lib/libfoo.la`.
- **`-lnsl` / `-lsocket` / `-lresolv`** — network symbols are split into
  separate libs on illumos (git's `NEEDS_SOCKET`/`NEEDS_NSL`; python `_socket`).

---

## 4. Apply — thread the patch into a `packages.nix` spec

`mk-userland-pkg.nix` now takes a `patches` list (+ `patchFlags`, default
`-p0` for pkgsrc). Patches are copied into the store and applied with GNU
`patch` in the source dir *before* configure:

```nix
aspell = pkg {
  pname = "aspell"; version = "0.60.8.2";
  src = { url = "…/aspell-0.60.8.2.tar.gz"; sha256 = "…"; };
  deps = [ self.ncurses.gcc ];
  patches = [ ./patches/pkgsrc/aspell-libintl-macros.patch
              ./patches/pkgsrc/aspell-errors-hpp-order.patch ];
  preConfigure = illumosExt;              # feature-test macros
  configureFlags = [ "--disable-static" ];
};
```

Save the harvested patch under `pkgs/illumos/patches/pkgsrc/<pkg>-<what>.patch`
(rename from `patch-aa` to something readable; the content is unchanged so the
`$NetBSD$` header + `--- a.orig / +++ a` paths stay `-p0`). If the fix is a pure
Makefile knob (no patch), just set `preConfigure`/`configureFlags`/`env` to the
SunOS values from the pkgsrc Makefile — no patch file needed.

**`-p0` vs `-p1`.** pkgsrc patches are `-p0` (`--- src/foo.c.orig`). Patches
harvested from a GNU/`git` source (or hand-written `a/…`→`b/…`) are `-p1`; set
`patchFlags = "-p1"` on the spec.

---

## 5. Build → run → sign → publish → ledger (the standard wave gate)

Same as every wave (docs/cache.md, docs/progress.md):

1. Build detached via `scripts/oi-job.sh` (never block on SSH):
   `oi-job.sh start <name> 'sh /var/tmp/solnix-repo/scripts/oi-tool.sh <attr>'`
   `oi-tool.sh` pulls the dep closure from the cache (Nix-2.3.16 S3 flake
   worked around by `oi-pull.sh`), then `nix-store --realise`s the drv and emits
   `RESULT<TAB>tool<TAB>OK|FAIL<TAB>out debug`.
2. **Run it** on illumos (a real smoke: `aspell --version`, `socat -V`,
   `file --version`) to prove the fix produced a working binary, not just a link.
3. **Sign + publish** both `out` and the split `debug` output to
   `https://s3.solnix.io/solnix-cache` via `scripts/oi-cache-publish.sh`
   (signs `cache.solnix.io-1`, bridges through the dev box for the S3 write).
   Plain names only — `<pname>-<version>`, no `solnix-`/`illumos-` prefix.
4. **Fetch-verify** a sample into a fresh store with `require-sigs=true` + only
   `cache.solnix.io-1` trusted (a wrong key must be *rejected*).
5. Update `docs/registry/build-ledger.tsv` (`cached=yes`, note the pkgsrc fix)
   and `docs/registry/cached-paths.tsv` (+ the new store paths).

---

## 6. Quick reference — one package, start to finish

```sh
# 1. find + harvest
curl -s .../contents/textproc/aspell         # confirm the path
scripts/pkgsrc-harvest.sh text/aspell         # -> artifacts/pkgsrc-patches/aspell/
# 2. read the flagged patches + the Makefile SunOS block; pick the illumos ones
# 3. stage: cp artifacts/pkgsrc-patches/aspell/patches/patch-an \
#           pkgs/illumos/patches/pkgsrc/aspell-libintl-macros.patch
# 4. add a spec to packages.nix (patches=[…], preConfigure=illumosExt, deps=[…])
nix-instantiate pkgs/illumos/packages.nix -A aspell.gcc   # eval check locally
# 5. sync repo to an idle builder, dispatch detached, poll:
BIP=<host> scripts/oi-job.sh start aspell 'sh /var/tmp/solnix-repo/scripts/oi-tool.sh aspell'
BIP=<host> scripts/oi-job.sh poll aspell
# 6. run + oi-cache-publish.sh <out> <debug> + fetch-verify + ledger rows
```

## 7. Findings from the first mining pass (what to expect)

- **Modern packages increasingly build clean on illumos** — the illumos work
  landed upstream, so `patches/` is empty and only a feature-test-macro knob is
  needed (`socat`, `file`, `the_silver_searcher`, `mc`, `htop-solaris`). Still a
  win: pkgsrc *confirms* the knob and the exact version that builds.
- **The real patch gold is in crusty/older packages** (`aspell` from 2019-era
  sources, `bash` loadables, `libiconv` GNU-libtool, `git`'s `config.mak.uname`).
- **oniguruma needs no patch** (6.9.10 fixed alloca upstream; ours is cached).
  The tokenizers wall is the Rust `onig_sys` crate vendoring an *old* oniguruma
  copy — a Rust-build problem, not a library-patch one; out of this scope.
- **lsof/htop-class tools** carry their illumos support in their own per-OS
  source tree; pkgsrc patches for them are NetBSD-dialect, not illumos — skip.

---

## 8. Wave-19 recurring-FAMILY fixes (reusable — future waves inherit these)

Four failure FAMILIES recurred across waves 14-18, each blocking MANY packages.
ONE fix per family unblocks the whole set. All are shared helpers in
`pkgs/illumos/packages.nix` (top of the `let`), applied via `preConfigure` /
`env` / `customBuild` — NO per-package patch file needed. Reach for these before
harvesting a pkgsrc patch; they are the illumos-specific fixes pkgsrc itself
does not carry (they are newer-illumos-libc / gcc-14-default regressions).

### Family 1 — gnulib `getlocalename_l` redeclaration  (`gnulibFix`)
- **Symptom:** `error: conflicting types for 'getlocalename_l'` when a GNU tarball
  bundles gnulib. illumos `/usr/include/locale.h` declares
  `extern const char *getlocalename_l(int, locale_t);` but gnulib's
  `#if defined __sun && HAVE_GETLOCALENAME_L` block redeclares it `char *`.
- **Fix:** const-qualify gnulib's prototype to match libc. gnulib moved this decl
  across vintages (`localename.c` → `localename-unsafe.c` →
  `getlocalename_l-unsafe.c`, plus the matching `*.h`), so `gnulibFix` sweeps
  ALL of `lib/` (`localename*.{c,h}`, `getlocalename_l*.{c,h}`,
  `setlocale_null*.c`) with an idempotent, safe-if-absent sed. Vintage-proof.
- **Companion knobs** for gnulib-bundling tools:
  - `--disable-gcc-warnings` — old gnulib `manywarnings` defaults
    `gl_gcc_warnings=yes` → a `-Werror` wall on illumos (recode, sharutils,
    coreutils). This, NOT the const decl, is what actually blocked recode.
  - `FORCE_UNSAFE_CONFIGURE=1` — coreutils' gnulib mknod/fifo probe refuses to
    run as root; our builder is root. Bypass it.
  - `-fcommon` (CFLAGS) — gcc-10+ `-fno-common` default makes gnulib's tentative
    `program_name` def multiply-defined at link (sharutils uuencode/uudecode).
  - `MAKEINFO=true` / build only `src`+`man` — no texinfo in the toolchain, so
    the `doc/*.info|*.html` rules 127-fail; stub or skip them.
- **Unblocked (wave 19):** recode 3.7.14, datamash 1.9, coreutils 9.7 (106 bins),
  sharutils 4.15.2, dwdiff 2.1.4, GNU units 2.24, indent 2.2.13 — plus the
  already-cached m4/libunistring confirm the same fix. The whole gnulib-using
  GNU-tool tail now has a known recipe.

### Family 2 — `tputs` prototype mismatch  (`tputsFix`)
- **Symptom:** `error: passing argument 3 of 'tputs' from incompatible pointer
  type` (gcc-14 promotes it to a hard error). illumos `<term.h>` declares
  `tputs(char *, int, int (*)(char))` — the putc callback takes `char`; ncurses/
  portable code passes `int(*)(int)`.
- **Fix:** `tputsFix = "-Wno-error=incompatible-pointer-types -fcommon"` in CFLAGS.
  Downgrades the mismatch to a warning; `-fcommon` also placates the
  `ospeed`/`UP`/`BC`/`PC` multiple-def that terminfo tools carry.
- **Unblocked (wave 19):** hwloc 2.11.2 (lstopo + all hwloc-* tools), wdiff 1.2.2.
  (texinfo 7.1 already used this in an earlier wave.)

### Family 3 — Linux `<endian.h>` `htobe64`/`htole64`  (`endianShimStage`)
- **Symptom:** `htobe16/htobe32/htobe64/be16toh/be64toh` undeclared; a source does
  `#include <endian.h>` (only under `#ifdef __linux__`, so on illumos the include
  is skipped AND the macros are never defined — no illumos `#else` branch).
- **Fix:** `endianShimStage` writes a compat `endian_illumos.h` into the build
  root mapping every glibc name onto illumos `<sys/byteorder.h>` `BE_*/LE_*`, and
  force-includes it via `-include $PWD/endian_illumos.h` in CFLAGS/CPPFLAGS so the
  macros exist regardless of the source's `#ifdef` guards.
- **Unblocked (wave 19):** paho-mqtt-c 1.3.13 (libpaho-mqtt3c/3a.so built from the
  plain Makefile — CMake unavailable — deriving the sync/async source sets the
  same way the Makefile's `filter-out` does, linking `-lsocket -lnsl`).

### Family 4 — `__sun_attr__` / `_MAX_`/`_ULTRA_` namespace clashes  (deferred)
- lrzip 0.651 (`extern int errno;` where illumos `errno` is a macro; libzpaq C++
  + lzma + `autogen.sh`) and libcpuid 0.7.1 (enum members `_MAX_`/`_ULTRA_`) —
  **only 2 packages, low leverage**, and the wave-17 diagnoses did not reproduce
  cleanly (no illumos header defines `_MAX_`/`_ULTRA_` as macros; the real lrzip
  wall is `errno` + a complex multi-language build). Deferred as NOT a
  high-leverage recurring family. If revisited: guard lrzip's `extern int errno;`
  behind `#ifndef errno`, and rename libcpuid's enum tokens if a real collision
  surfaces on a specific header include order.

**Takeaway for future waves:** the gnulib GNU-tool tail is now mechanical — add a
spec with `preConfigure = gnulibFix` (+ `--disable-gcc-warnings` if it bundles
old gnulib, `FORCE_UNSAFE_CONFIGURE=1` for coreutils-family, `-fcommon` for
`program_name`, `MAKEINFO=true` if it builds .info/.html docs). Terminfo tools →
`env = { CFLAGS = tputsFix; }`. Linux endian users → `endianShimStage` in a
`customBuild`.

## 9. Wave-22 recurring-FAMILY fixes (reusable — future waves inherit these)

Wave 21 diagnosed three new recurring illumos-portability classes while retrying
the GNU-tool tail + probing modern C/C++ libs. Wave 22 turned each into a
reusable helper (top of the `let` in `pkgs/illumos/packages.nix`) with a matching
opt-in env knob in `scripts/oi-clib.sh` (the native-build path most breadth pkgs
use). Each fix was validated end-to-end on the fleet (build + cache + signed).

### Family 5 — GNU linker `--version-script`  (`ldVersionScriptFix`, `LDVERSCRIPT_STRIP=1`)
- **Symptom:** `ld: fatal: unrecognized option '--version-script'`. Many libs
  doing GNU symbol versioning pass `-Wl,--version-script,<file>` on EVERY
  platform (zlib-ng's CMake links `libz.so` with `-Wl,--version-script,zlib.map`).
  Solaris `ld` does NOT accept `--version-script`; it uses a different `-M
  <mapfile>` syntax with an incompatible grammar.
- **Fix:** translating the `.map`/`.sym` to a Solaris mapfile is per-file and
  fragile, so the reusable fix DROPS the version script on illumos. Interpose a
  tiny CC/CXX shim that filters `-Wl,--version-script,*` and `--version-script
  <f>` out of the link line, then execs the real compiler. Consequence: symbols
  keep their default global scope (no per-version symbol tags) — harmless for a
  userland library on illumos where nothing consumes the GNU version nodes.
  `packages.nix`: `preConfigure = ldVersionScriptFix` (installs `.ldshim/{cc,c++}`
  and points CC/CXX at them). `oi-clib.sh`: set env `LDVERSCRIPT_STRIP=1`.
- **Unblocked (wave 22):** zlib-ng 2.2.2 (`-DZLIB_COMPAT=ON` links libz.so via
  the version script). Any future lib using a GNU version script is now one env
  knob away.

### Family 6 — C++ global-namespace C-math names  (`cxxMathNsStage`, `CXXMATHNS=1`)
- **Symptom:** `'isnan' is not a member of 'Catch'` / `'::isnan' has not been
  declared`. Modern C++ (catch2, and any lib that `#include <math.h>` then calls
  bare `isnan`/`isinf`/`signbit`) assumes the C math names are ALSO visible in
  the GLOBAL namespace. illumos libstdc++ (`<cmath>`) only exposes them in
  `std::`, NOT `::` — the classic BSD/Solaris libstdc++ difference from glibc.
- **Fix:** force-include a compat header that does `#include <cmath>` then
  `using std::isnan; using std::isinf; using std::signbit;` (plus isfinite/
  isnormal/fpclassify) at global scope, so `::isnan` etc. resolve and unqualified
  lookups inside other namespaces find them. Applied via CXXFLAGS `-include`;
  harmless when the names are already global. `packages.nix`: `preConfigure =
  cxxMathNsStage`. `oi-clib.sh`: set env `CXXMATHNS=1`.
- **Unblocked (wave 22):** catch2 3.7.1 (`Catch::isnan` shim now resolves).
  Applies to any modern C++ header lib assuming C math in the global ns.

### Family 7 — pre-C99 GNU libc-fallback `.c` files  (`libcFallbackFix`)
- **Symptom:** bundled K&R replacement `compat/memcpy.c`/`memmove.c`/`strcasecmp.c`
  (`char *memcpy (destaddr, srcaddr, len) char *destaddr; ...`) conflict with
  `<string.h>` (or gcc-14 rejects the pre-C99 defs) once we force-include
  `<string.h>` to fix a sibling file's implicit str*() decls. The bundled `.c`
  is guarded by `#ifndef HAVE_MEMCPY` etc. — illumos libc HAS all of these, so
  configure should DETECT them and compile the fallbacks out.
- **Fix:** pre-seed the autoconf cache so configure records the libc functions as
  present: `export ac_cv_func_memcpy=yes ac_cv_func_memmove=yes
  ac_cv_func_strcasecmp=yes ...` (memset/strchr/strrchr/strdup/strstr/strerror/
  bcopy too). The `@LIBOBJS@` list then omits the bundled `.c`. `packages.nix`:
  `preConfigure = ... + libcFallbackFix`. `oi-clib.sh`: pass the `ac_cv_func_*=yes`
  vars in the env (they are read by the pkg's own `./configure`).
- **Unblocked (wave 22):** enscript 1.6.6 (its bundled getopt.c needed
  `-include string.h`, which then tripped the K&R `compat/memcpy.c`; the ac_cv
  seed makes configure skip the fallback). Feeds a2ps (needs enscript-class
  fixes). Reusable across pre-C99 GNU tools shipping libc-fallback `.c` files.

**Takeaway (wave 22):** GNU-version-script libs → `ldVersionScriptFix` /
`LDVERSCRIPT_STRIP=1`. C++ that calls bare `isnan`/`isinf`/`signbit` →
`cxxMathNsStage` / `CXXMATHNS=1`. Pre-C99 GNU tools with bundled `memcpy.c`-style
fallbacks → `libcFallbackFix` (seed `ac_cv_func_*=yes`). Still deferred as
low-leverage: libcpuid (`_BRONZE_`/`_MAX_` enum-token clash, still only itself),
Linux-only libs (libmnl "Linux only, dude!", libunwind x86_64 backend), and libs
requiring Python 2 to generate sources (libgraphqlparser).
