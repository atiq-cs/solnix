# Nix 2.24 vs Lix de-risking spike — working notes

Host: root@3.15.6.184 (i-055b73f48f49a02cc, m5.4xlarge, OI build AMI clone)
Target triple: x86_64-pc-solaris2.11 / x86_64-solaris
Toolchains present at start: gcc-10, gcc-14 (both under /usr/gcc). No nix yet.
rpool 1.62G with 298G EXPANDSZ pending -> needs zpool online -e.

## Known illumos hazards to re-forward-port (from 2.3.16 work)
1. `<sys/termios.h>` needed for `struct winsize`/`TIOCGWINSZ` (util.cc). Linux
   gets it transitively via `<sys/ioctl.h>`; illumos does not.
2. `cfmakeraw()` absent from illumos libc -> supply the BSD/glibc body.
3. PTY slaves are STREAMS devices -> must `I_PUSH` ptem + ldterm before
   tcgetattr/tcsetattr or they fail EINVAL. (build path pty setup)
4. boost.context: no fcontext asm on some arches -> `-DBOOST_USE_UCONTEXT`
   backend + drop-in fiber.cpp. (Was a sparc issue; x86_64 boost usually has
   fcontext, so likely N/A here — confirm.)
5. Linux-only: seccomp (libseccomp) must be disabled. sandbox uses Linux
   namespaces -> must be off (illumos has zones/privileges, not namespaces).
6. editline: illumos libedit lacks symbols nix REPL wants -> build against GNU
   readline or bundled editline.
7. CA certs: illumos ships individual PEMs in /etc/certs/CA/, no bundle ->
   `cat /etc/certs/CA/*.pem > bundle.crt`; point NIX_SSL_CERT_FILE at it.
8. SVR4 vs GNU tools: `install`, `ar`, `patch`, `sed` — need GNU variants
   (/usr/gnu/bin) for the build.

## Progress log

### Host bootstrap: DONE
- oi-fleet-bootstrap.sh succeeded: MTU 1400, rpool expanded to 300G
  (288G avail on rpool/nix), Nix 2.3.16 seed installed and working
  (`nix-store --version` = 2.3.16), cache.solnix.io reachable (HTTP 200).
- Host: 16 CPUs, 64GB RAM. Target: x86_64-solaris / x86_64-pc-solaris2.11.
- CA bundle: `cat /etc/certs/CA/*.pem > /var/tmp/ca-bundle.crt` works; curl
  with --cacert fetched both source tarballs over HTTPS cleanly.
- Compilers: fresh clone had ONLY gcc-{10,14}-runtime libs, no compilers.
  Installed developer/gcc-13 (10.5/14 dev pkgs not in OI catalog; 13.4.0 is
  newest full compiler available). gcc-13 supports -std=c++2a (C++20) fully.
  gcc-14 libstdc++.so.6.0.33 runtime present (for boost 1.78 ABI).

### Sources fetched
- Nix 2.24.15 (github NixOS/nix tag 2.24.15) — HAS BOTH autotools
  (configure.ac + Makefile) AND meson. Autotools path is the low-friction
  route (matches the 2.3.16 approach).
- Lix 2.90.0 (git.lix.systems archive) — meson-ONLY, no autotools.

### Nix 2.24.15 dependency analysis (from configure.ac)
Upstream is MORE solaris-aware than 2.3.16:
- `case host_os in solaris*)` already adds `-lsocket -lnsl`.
- seccomp gated behind `linux*` ONLY -> auto-disabled on solaris, no flag.
- statvfs/pipe2 feature-detected via AC_CHECK_FUNCS (graceful).
- xattr optional (AC_CHECK_HEADERS sys/xattr.h).
C++ standard: -std=c++2a (C++20). gcc-13 OK.

Required deps and OI availability:
- boost >=1.66      : OI 1.78 (installing)
- sqlite3 >=3.6.19  : OI 3.50.4 (installed)
- libcurl           : OI 8.16.0 (installed)
- editline/readline : OI libedit 3.1 + readline-8 (installed)
- libsodium         : OI 1.0.20 (installing)
- brotli enc/dec    : OI 1.1.0 (installed)
- nlohmann_json>=3.9: OI 3.12.0 (installing)
- bdw-gc (Boehm GC) : *** NOT IN OI *** (needed unless --disable-gc)
- libgit2           : *** NOT IN OI *** (required, no disable flag in .ac)
- toml11 (toml.hpp) : *** NOT IN OI *** (required, header-only, vendorable)
- lowdown           : NOT in OI, but OPTIONAL (--disable-markdown)
- aws-sdk-cpp S3    : NOT in OI, but OPTIONAL (auto-off if header absent)

Gap = 3 unpackaged deps: Boehm GC (disable or build), libgit2 (build),
toml11 (header-only, vendor). All buildable/vendorable, none illumos-hostile.

### Nix 2.24.15 illumos-hazard re-check (vs the 2.3.16 patches) — BIG WIN
- platform.mk ALREADY has first-class `HOST_SOLARIS` -> sets HOST_UNIX=1,
  NOT HOST_LINUX. So it compiles `src/*/unix/*.cc` and SKIPS `src/*/linux/*.cc`
  (which is where seccomp/namespaces/personality live). No patch needed to
  dodge Linux sandbox code — upstream already partitions it.
- The whole PTY/STREAMS build hazard is GONE: 2.24 has NO cfmakeraw / I_PUSH /
  ptem / ldterm / TIOCGWINSZ / struct winsize anywhere in src/. The 2.3.16
  build.cc pty setup was rewritten. -> patches 0001 + 0002 are OBSOLETE.
  [CORRECTION after building: this grep-level claim was WRONG. The pty code
  moved to local-derivation-goal.cc and terminal.cc; cfmakeraw + the STREAMS
  ptem/ldterm push + winsize/termios ALL recur at compile/run time. Patch 0001
  and BOTH halves of patch 0002 must be re-forward-ported. See findings 8-10.]
- No /proc/self, MADV_*, pipe2, sendfile, SOCK_CLOEXEC, sys/statfs, prctl,
  linux/* at grep level in libstore/libutil core. statvfs/pipe2 are
  feature-detected (AC_CHECK_FUNCS), xattr optional.
- Net: of the 8 known 2.3.16 illumos hazards, modern-Nix-autotools removes
  ~5 outright (PTY x2, seccomp-partition, statvfs graceful, procfs). Remaining
  concern is only the toolchain (GNU ar/install/sed/patch) + the 3 missing deps.

### Lix 2.90.0 dependency analysis (meson-only) — HEAVIER than Nix-autotools
- meson-ONLY, no autotools fallback (must bootstrap meson+ninja/samurai).
- Requires a RUST TOOLCHAIN: lix-doc/ is a cargo staticlib (rnix crate).
  *** No rust/cargo in OI *** -> extra bootstrap of the whole Rust stack.
- boost context+coroutine+container COMPILED libs (not header-only).
- libarchive REQUIRED (*** not in OI ***; Nix-autotools does not need it).
- lowdown >=0.9.0 REQUIRED, no disable (*** not in OI ***; Nix makes it optional).
- toml11 >=3.7.0 via cmake (required).
- libcpuid (disable-able via `cpuid` feature).
- seccomp gated `is_linux` (good), gc a feature (disable-able).
- Net: Lix mandatory-extra bootstrap vs Nix-autotools = Rust + libarchive +
  lowdown + meson/ninja + compiled boost. Materially more friction on solaris.

### Host toolchain snag (reproducible, important for the port runbook)
- The fresh OI-build-AMI clone ships gcc-{10,14}-RUNTIME libs but NO compiler,
  and its `userland-incorporation` is pinned at 0.5.11-2025.0.0.31598.
- EVERY `developer/gcc-N` (10..13) `require`s developer/gnu-binutils, but the
  only binutils in the catalog are 2.46.x @2026.*, which the 2025 incorporation
  EXCLUDES. So `pkg install developer/gcc-13` fails: "No version matching
  'require' dependency developer/gnu-binutils can be installed".
- Installing gcc-13 + the 2026 incorporation together cascades into core
  packages (ksh93, SUNWcs, beadm, svr4) -> it pulls the whole 2026 userland.
- FIX: full `pkg update --accept` (415 pkgs, ~2GB, new boot environment,
  reboot to activate). On this AMI vintage a from-scratch compiler needs the
  userland bumped to the 2026 baseline first. (Runbook: bake gcc-13 into the
  build AMI, or `pkg update` before the spike.)
- OI mirror is Hetzner/EU behind the MTU-1400 link -> downloads are slow
  (boost alone ~10 min). Budget accordingly.

### Post-update host state (2026 userland, reboot done)
- gcc-13.4.0 (OpenIndiana 13.4.0-oi-2) works: `-std=c++2a` compiles+runs.
  Host triple = x86_64-pc-solaris2.11.
- cmake3 3.31.11, autoconf/automake-1.16/libtool, gmake (/usr/bin/gmake),
  flex, bison, jq, pkg-config all present after the update + targeted installs.
- Nix seed (2.3.16) and /nix/store survived the BE switch.
- Dep pkg-config versions (post-update, all newer): sqlite 3.53.4, curl 8.21.0,
  libsodium 1.0.22, brotli 1.2.0 (enc+dec), nlohmann_json 3.12.0,
  libcrypto 1.0.2u (openssl-1.0 still the default .pc; openssl-3 also present).
  editline (libedit 0.0.78) + readline-8 libs present.
- GOTCHA: `pkg install -v <pkg>` can exit 0 as a NO-OP when the pkg is blocked
  by the incorporation (gcc-13, gnu-make, flex, bison all silently "rc=0" but
  installed nothing pre-update / when catalog stale). ALWAYS verify with
  `pkg contents` / `which`, not the exit code.

### Nix 2.24.15 BUILD ATTEMPT (autotools path)
- toml11 3.8.1: vendored as header-only (toml.hpp + toml/) onto -I path. OK.
- libgit2 1.7.2: BUILT from source with cmake3 + gmake, installed to
  /var/tmp/libgit2-inst (libgit2.so.1.7.2 + libgit2.pc). Clean, no illumos
  patches needed. ~2 min build.
- autoreconf: needed ACLOCAL_PATH=/usr/share/aclocal (for pkg.m4) + copying
  config.guess/config.sub/install-sh from /usr/share/automake-1.16 into config/.
  2.24 tarball ships NO ./configure (unlike 2.3.16 release tarballs).
- `--with-boost` flag REMOVED in 2.24 (boost auto-detected). Dropped it.
- CONFIGURE reached deep and PASSED illumos feature checks:
  statvfs=yes, pipe2=yes, lutimes=yes, utimensat=yes, pubsetbuf=yes,
  large-file=none-needed, ar/gcc-13 OK. No illumos-ism tripped configure.
  Required build tools: jq, flex, bison, lsof (all now installed).
- Configure options that make it portable: --disable-gc (skip Boehm, not in OI),
  --disable-markdown (skip lowdown, not in OI), --disable-unit-tests
  (skip gtest/rapidcheck), --disable-doc-gen. host=x86_64-pc-solaris2.11.

### Configure blockers hit + fixes (all mechanical, none illumos-fatal)
1. Tarball ships NO ./configure -> autoreconf. Needed ACLOCAL_PATH + copied
   config.guess/config.sub/install-sh from automake-1.16.
2. m4/ax_boost_base.m4 MISSING from the GitHub archive tarball (it is a repo
   file not in the archive) -> literal `AX_BOOST_BASE(1.66,...)` = configure
   syntax error. FIX: install developer/build/autoconf-archive (provides
   ax_boost_base.m4), re-autoreconf.
3. libcrypto: default /usr .pc is openssl-1.0 (1.0.2u) but Nix wants >=1.1.1.
   FIX: prepend /usr/openssl/3/lib/amd64/pkgconfig to PKG_CONFIG_PATH + -L/-R
   the openssl-3 libdir.
4. libcpuid (x86_64 microarch detection) not in OI. FIX: --disable-cpuid
   (configure.ac has the flag; x86_64-only, non-essential).
5. AC_CONFIG_FILES([]) is empty -> Makefile.config never instantiated. FIX:
   `config.status --file=Makefile.config:Makefile.config.in` (same as 2.3.16).
6. Build tools jq, flex, bison, lsof, gnu-make required (all installed).
7. libarchive 3.8.9 IS in OI (post-update) -> Nix 2.24 needs it too (`-larchive`).

FINAL CONFIGURE: SUCCEEDED. Makefile.config correct:
  HOST_OS=solaris2.11, HAVE_SECCOMP=(empty), HAVE_LIBCPUID=(empty),
  LDFLAGS has -lsocket -lnsl, all deps (boost/curl/git2/openssl3/sodium/
  sqlite/archive/brotli/editline) wired. NO illumos source patch was needed
  to reach a clean configure. config.h + Makefile.config generated.

### COMPILE phase blockers (illumos source-level, the real re-forward-port)
1. src/libutil/terminal.cc: `struct winsize` / `TIOCGWINSZ` incomplete/undeclared
   -> EXACTLY the 2.3.16 patch-0001 hazard, moved to a new file. FIX: inject
   `#ifdef __sun #include <sys/termios.h> #endif` after <sys/ioctl.h>. (1-line)
2. toml11 3.8.1 trips per-file -Werror=switch-enum (Nix pins a matching toml11).
   FIX: `gmake ERROR_SWITCH_ENUM=` (Nix's own documented override for
   dependency-header cases). Cleaner alt: use the exact toml11 Nix pins.
3. src/libutil/unix/signals.cc: `sigorset` not declared. illumos sigorset()
   takes the kernel k_sigset_t, not glibc's 3-arg sigset_t form; Nix's
   `#if _POSIX_C_SOURCE...` guard wrongly assumes glibc semantics. FIX: add
   `&& !defined(__sun)` to force Nix's own direct-assignment fallback. (1-line)

Note: patch 0002 (cfmakeraw/ptem/ldterm STREAMS) has NO analog in 2.24 (the
build PTY code is gone) -> that whole class of hazard is retired. Net source
churn so far = 2 one-line guards + 1 make-var, vs the 2.3.16 patch set.

### FULL BUILD RESULT: NIX 2.24.15 BUILDS + RUNS ON illumos x86_64
After the mechanical fixes above, `gmake -j16 ERROR_SWITCH_ENUM=` compiled and
linked EVERYTHING: all libnix*.so + the 153MB `src/nix/nix` ELF64 AMD64 binary.

RUNTIME illumos-isms found by actually running it (the valuable part):
8. src/libstore/unix/build/local-derivation-goal.cc: `cfmakeraw` undeclared
   (illumos libc lacks it) -> inject the BSD/glibc body (patch-0002 half). +
   the pty slave is a STREAMS device -> tcgetattr fails EINVAL until you
   `I_PUSH` ptem+ldterm on the slave fd (the OTHER patch-0002 half). BOTH the
   2.3.16 pty hazards recur here, just relocated. FIX = re-forward-port patch 0002.
9. src/libstore/unix/pathlocks.cc: `~FdLock()` unlocks via
   `lockFile(desc, ltNone, wait=false)` -> `flock(fd, LOCK_UN | LOCK_NB)`.
   illumos REJECTS LOCK_UN|LOCK_NB with EINVAL (Linux ignores LOCK_NB on
   unlock). The SysError thrown in the destructor during unwinding =
   terminate/abort on EVERY build. Root cause verified with a 12-line C repro:
   `flock(fd, LOCK_UN|LOCK_NB)` = -1/EINVAL; `flock(fd, LOCK_UN)` = 0. FIX =
   drop LOCK_NB when type==LOCK_UN (1-line). NEW hazard, not in the 2.3.16 set.
10. src/libutil/current-process.cc getSelfExe(): the `#else` returns nullopt on
    non-Linux -> Nix can't find its own binary -> build fails
    "not an absolute path: 'nix'". FIX: add `#elif __sun` returning
    readLink("/proc/self/path/a.out") (illumos's self-exe symlink). 1-line.
11. Minor/cosmetic: `nix store delete` + GC scans /proc/1/fd/0 and hits
    read_symlink EINVAL; GC under-collects. Non-fatal; build/substitute/profile
    all unaffected. A procfs-path shim would tidy it (low priority).

PROOFS (all on the host, Nix 2.24.15):
- `nix (Nix) 2.24.15` runs.
- `nix profile --help`, `nix profile install/list/remove` WORK (the whole point).
- `nix eval --expr '1 + 2'` = 3.
- `nix build` of a trivial derivation -> /nix/store/...-hi224 containing
  "hi-from-2.24" (full sandbox-less build via the pty path, post-fixes).
- `nix store info --store https://cache.solnix.io` + nix-cache-info over HTTPS
  with NIX_SSL_CERT_FILE=/var/tmp/ca-bundle.crt (CA bundle =
  `cat /etc/certs/CA/*.pem > bundle.crt`) SUCCEED -> TLS + CA handling work.
- `nix copy --to file://cache` then `nix copy --from file://cache --to a FRESH
  empty store` -> path "SUBSTITUTED-OK" materialised = full narinfo+nar
  download/unpack/import substitute path WORKS.

Total source churn to get a WORKING nix: 4 illumos edits
(terminal.cc include, signals.cc guard, pathlocks.cc unlock, current-process.cc
getSelfExe) + the cfmakeraw/STREAMS re-port of patch 0002 into the new file +
1 make-var (ERROR_SWITCH_ENUM=) + config/build-env plumbing. NO deep rewrites.

`gmake install` to /nix-tools224 hit ONE minor packaging snag (a config.h
install rule + illumos `find` symlink-cycle noise) -> the real port ships the
relocatable tarball (like 2.3.16) instead; in-tree binaries build+run fine.
Binary links BOTH libcrypto.so.1.0.0 (transitive, likely via libssh2/curl) and
libcrypto.so.3 -> a dual-openssl cleanup for the real port. RUNPATH currently
points at build dirs -> fix with install-tree RUNPATH + bundled lib dir.

### LIX 2.90.0 ASSESSMENT (timeboxed)
Lix is a CppNix fork and SHARES the exact illumos source hazards:
- src/libstore/pathlocks.cc: identical `flock(fd, type | LOCK_NB)` unlock bug.
- local-derivation-goal.cc: same cfmakeraw/pty STREAMS code.
- current-process.cc: same getSelfExe (#else nullopt) issue.
So Lix needs the SAME 4 source fixes as Nix. ON TOP OF THAT, Lix adds a
heavier BUILD-SYSTEM bootstrap that Nix-autotools avoids:
- meson-ONLY (no autotools). The OI `library/python/meson-314` pkg does NOT
  yield a working meson (no /usr/bin/meson, `import mesonbuild` fails); meson
  would need a proper (pip/venv) install first.
- RUST toolchain REQUIRED to build lix-doc (cargo staticlib, rnix crate).
  rustc 1.97.1 IS in the 2026 OI catalog, but it is a whole extra toolchain
  to install+drive, and cargo needs network crate fetches (offline-vendoring
  or a crates mirror on illumos).
- lowdown >=0.9.0 REQUIRED with NO disable flag, and lowdown is NOT in OI at
  all -> must build lowdown from source too. (Nix makes lowdown optional.)
- libarchive required (present, 3.8.9) + compiled boost context/coroutine.
Lix was NOT taken to a build: the dep-bootstrap wall (meson+rust+lowdown) is
strictly a superset of Nix-autotools, and Nix already fully works, so per the
spike's anti-wedge rule the budget went to finishing the clear winner.

### COMPARISON + RECOMMENDATION
| Axis                        | Nix 2.24.15 (autotools) | Lix 2.90 (meson)        |
|-----------------------------|-------------------------|--------------------------|
| Build system on illumos     | autotools (works today) | meson-only (needs boot)  |
| Extra toolchain to bootstrap| none beyond gcc-13      | + working meson + Rust   |
| Deps not in OI              | libgit2, toml11 (built) | + lowdown(reqd), meson,  |
|                             | GC/lowdown disablable   |   rust, (same git2/toml) |
| illumos SOURCE fixes needed | 4 (all small) + patch02 | SAME 4 (shared lineage)  |
| Reached a running binary    | YES                     | not attempted (superset) |
| nix profile / eval / build  | YES / YES / YES         | (CLI-compatible, likely) |
| substitute from cache (TLS) | YES                     | (same libstore code)     |

RECOMMENDATION: adopt **upstream Nix 2.24.x via the autotools build**.
Rationale: it is the SMALLER porting surface on illumos (autotools already
has first-class HOST_SOLARIS + a solaris case; lowdown/GC/cpuid all have
disable flags; only libgit2+toml11 must be built/vendored), it REACHED a
fully working binary in this spike (profile+build+substitute all proven),
and Lix's only differentiators here are strictly MORE bootstrap deps
(meson+rust+mandatory-lowdown) for the same illumos source work.

### CA-bundle recipe (the 2.3.16 pain point, now solved cleanly)
  cat /etc/certs/CA/*.pem > /var/tmp/ca-bundle.crt
  export NIX_SSL_CERT_FILE=/var/tmp/ca-bundle.crt
With that set, 2.24's libcurl/openssl-3 path talks to https://cache.solnix.io
with no TLS errors (verified: nix store info, nix-cache-info, copy over TLS).

### REALISTIC FULL-PORT COST ESTIMATE
- Spike already did the hard de-risking: found + fixed every illumos blocker to
  a WORKING binary. What remains is productionizing, not discovery.
- Package libgit2 + toml11 (or vendor toml11 header + build libgit2 as a
  Phase-3 derivation): ~1 day.
- Turn the 4 source fixes + patch-0002 re-port into clean patches in
  scripts/nix-illumos-patches/ (2.24 series) + a from-source build script
  paralleling oi-nix-setup.sh: ~1 day.
- Proper install/relocatable tarball (fix the config.h install rule, RUNPATH to
  a bundled lib dir, dual-openssl cleanup, bake CA bundle + NIX_SSL_CERT_FILE):
  ~1-2 days.
- Re-bank the account-proof bootstrap on 2.24 + drop the __structuredAttrs=false
  adapter + re-verify GATE 1b-PURE on the new stdenv: ~1-2 days.
- Contingency (daemon/SMF, GC procfs shim, edge deps): ~1 day.
Total: ~1 working week (5-7 days) for one engineer, LOW risk now that the
spike proved the binary runs and the dep tree is fully mapped. The scary
unknowns (does it even build/run on illumos? seccomp/sandbox? deps?) are
RESOLVED: it builds, runs, profiles, builds, and substitutes.







</content>
</invoke>
