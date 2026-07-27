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
