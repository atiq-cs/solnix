# solnix roadmap: fully Nix-ified illumos — x86_64 by crackers-expiry, then aarch64/sparcv9/RISC-V

North Star (maintainer directive, 2026-08-02): solnix is EXACTLY a Nix distribution
of illumos — every package a real derivation (`nix-build` works, `nix-store
--query --deriver` resolves, provenance is provable), not `nix-store --add`'d
binaries. x86_64 fully done + functional EC2 AMIs before the crackers account
expires (Sun Aug 09 14:33 UTC — 7 days). aarch64/sparcv9/RISC-V bootstrap toward
the SAME standard (fully-Nix, full Nix runtime experience), not an approximation.

## The honest prerequisite (why this is ordered the way it is)
Today the ~10k cached packages are hermetically correct at RUNTIME (RUNPATH pins
exact /nix/store/<hash> deps, References recorded) BUT were built with oi-clib.sh
(host gcc + `nix-store --add`) — so they have NO .drv, no deriver, not
`nix-build`able. The fork (solnix-pkgs) has a STAGE0 SEED (relocatable gcc-10 +
Solaris ld + libc + crt + headers) and cc/bintools wrapper scaffolding, but NOT a
completed from-source x86_64-solaris `stdenv.mkDerivation` (pkgs.buildEnv even
infinite-recurses). A real `nix-build` needs the stdenv bootstrap:
  seed(stage0) -> stage1 (binutils/gcc/coreutils/bash/make AS DERIVATIONS) ->
  stdenv -> then every package as `callPackage ... mkDerivation`.
Completing an stdenv for a new platform is the core of "porting nixpkgs to a
system" — the hard, multi-day-to-weeks part. The fleet-rebuild is the EASY last
step (pure compute; crackers can do it in days). So the ordering below puts the
stdenv first; the fleet rebuild follows and IS schedulable within the week.

## PHASE 0 — crackers migration (NOW, before ouch expires ~16:40 UTC today)
- crackers = AWS profile `cracker` (singular), acct 316742357190, us-east-2.
  IAM already has vmimport grant (unlike ouch). DONE: vmimport role + inline
  policy + import bucket solnix-vmimport-316742357190; verified raw uploading.
- The CACHE (cache.solnix.io, 10k pkgs) + signing keys + repo + verified raw are
  ALL ouch-independent -> nothing lost at ouch expiry.
- Finish: import-snapshot -> register the bootstrap solnix AMI on crackers ->
  launch a builder fleet on crackers -> repoint .infra/fleet.env. (see
  .infra/migration-ouch-to-crackers.md)

## PHASE 1 — x86_64-solaris STDENV BOOTSTRAP (the unlock; days 1-4)
Deliverable: a working `stdenv` for x86_64-solaris so `nix-build` produces real
derivations. Steps (in solnix-pkgs fork):
1. From the seed(stage0), build stage1 binutils(Solaris ld)/gcc/coreutils/bash/
   gnumake/gnused/gawk/gzip AS DERIVATIONS (fixed-output where needed). Mirror
   nixpkgs' stdenv bootstrap stages, substituting the Solaris ld + illumos libc.
2. Assemble `stdenv = stdenvNoCC + cc-wrapper(seed/stage1 gcc + Solaris ld)`.
   Fix the buildEnv infinite-recursion (it blocks system.path + any mkDerivation).
3. GATE 1: `nix-build` a trivial `hello` from source on x86_64-solaris ->
   a .drv, `nix-store -q --deriver result` resolves, the binary runs on the AMI.
   THIS is the proof the platform is real-Nix-capable.
This is the highest-value work; everything real-Nix depends on it. Dispatch as a
dedicated effort + design doc (docs/design-solaris-stdenv.md).

## PHASE 2 — x86_64 PACKAGE EXPRESSIONS (days 2-5, overlaps Phase 1 tail)
- REUSE nixpkgs: most of our ~7,771 x86_64 pnames already have nixpkgs
  expressions. With a working stdenv, `pkgs.<name>` for x86_64-solaris often
  builds with only per-package Solaris patches (the portability fixes we already
  discovered — GNULIBFIX, -zrelax, errno-shadow, struct-queue, u_int8_t, etc. —
  become overlay patches, not lost work).
- CODEGEN head start: our oi-clib.sh recipes (pname/version/url/sha/buildsys/
  deps/flags in cached-paths.tsv + wave fire.sh) map to callPackage/mkDerivation
  stubs for pkgs NOT in nixpkgs. Generate an overlay from them.
- Curate the TARGET SET = (cache's 7,771 x86_64 pnames) ∪ (TODO list in
  docs/package-universe.md). Prioritize the base/default set + common libs first.

## PHASE 3 — x86_64 FLEET REBUILD as real Nix (days 4-7; crackers fleet)
- Moderately-sized crackers fleet of illumos builders (m5d/m6i.*xlarge), each
  running `nix-build` against the Phase-1 stdenv + Phase-2 overlay, publishing
  the REAL derivation outputs (with deriver/references) to cache.solnix.io
  (same signing key). This REPLACES the nix-store --add artifacts with proper
  derivations at (usually) different hashes.
- Verify per package: `nix-store -q --deriver` resolves + `nix build` reproduces.
- GATE 3: the x86_64 cache is fully-Nix; a fresh AMI's environment.systemPackages
  realises entirely from real derivations; `nix-build`/`nix develop` work on the
  running AMI.

## PHASE 4 — x86_64 FUNCTIONAL AMIs (day 7)
- Declarative Stage A (environment.systemPackages -> buildEnv -> /run/current-
  system/sw + login env + /etc/nix/nix.conf + nix-on-image + store-DB register),
  now backed by REAL derivations. Build minimal + graphical AMIs. Gate A boot
  test (scott login, nix-build works, htop/vim/git in PATH). Publish AMIs.

## PHASE 5 — aarch64 / sparcv9 / RISC-V (continue, to the SAME standard)
- Each arch gets its OWN stdenv bootstrap from its seed (seed-aarch64,
  seed-sparc exist in the fork; RISC-V is the from-scratch port). Same ordering:
  stdenv -> package expressions (reuse nixpkgs cross + our recorded recipes) ->
  fleet rebuild as real derivations -> functional media.
- aarch64 cross-build fleet + sparcv9 (native on `sun` host + Klaus's SPARC Rust
  toolchain path) + RISC-V (Jupiter2/K1). The existing cross-built cache for
  these seeds substitution + testing while their stdenvs come up.
- Rust: OI ships rustc 1.97.1 via IPS (x86_64); Klaus's native SPARC Rust 1.95.
  Once stdenv+rustc are wired, uutils + the Rust CLU ecosystem become buildable.

## HONEST timing note
"Rebuild everything as real Nix by end of week" hinges on Phase 1 (stdenv). If
the stdenv bootstrap lands in ~3-4 days, the x86_64 fleet-rebuild (Phase 3) fits
the remaining crackers window. If stdenv proves harder (new-platform bootstraps
often do), x86_64 real-Nix completion may spill past crackers-expiry — in which
case we re-up compute (next burner) and the cache+keys+recipes persist. The
current nix-store --add cache remains the working BOOTSTRAP throughout (usable,
hermetic linkage), so AMIs are testable at every phase.

## What is NOT lost / already banked (survives account rotation)
- 10k hermetic cache artifacts (RUNPATH-correct) — the bootstrap + a substitution
  source + a verification oracle (rebuilt-derivation output should match).
- Every portability fix discovered (become overlay patches).
- All oi-clib.sh recipes (codegen input for Phase 2).
- The verified booting AMI raw + the declarative Stage-A modules + this roadmap.

## BLOCKER (2026-08-02): bootstrap chicken-and-egg + account churn
The pure stdenv build is BLOCKED by a circular dependency, exposed when ouch+crackers died:
  pure hello -> needs GNU userland IN the seed -> needs a full-toolchain host to grow it
  -> needs a runnable illumos Nix -> only ever produced by compiling Nix on a full OI host
  -> that host died with ouch/crackers and is unreopenable.
Two artifacts were NEVER banked to the surviving cache, so churn stranded us:
  (1) a runnable illumos Nix CLOSURE (there is NO prebuilt Nix for illumos; only ever
      compiled on a full OI host). cache.solnix.io has NONE.
  (2) a seed WITH GNU userland (the x86_64 seed has only the Solaris toolchain; the
      pure stdenv slices bash/coreutils/findutils/... from seed/usr/gnu/bin which is EMPTY;
      oi-extract-seed.sh has no userland-grow code).
BREAK-THE-CYCLE (account-proof, do ONCE): stand up a full OpenIndiana Hipster host
(from OI's own ISO/cloud image in EC2 — NOT account-bound), and on it:
  (a) build Nix + `nix-store --export` its closure -> publish to cache.solnix.io, so any
      bare illumos host bootstraps nix by unpack-over-ssh (no on-host compiler).
  (b) grow the seed GNU userland + republish the seed FOD (bump hash).
Then the pure stdenv builds on any host, forever, regardless of account churn.
The sun SPARC host cannot help (wrong arch). solnix.io cache/keys/code/seed(toolchain)
all survive; only the build SUBSTRATE + these 2 artifacts are the gap.

## CYCLE-BREAKER PATH FOUND + IN PROGRESS (2026-08-02)
The reproducible, account-independent way to a full OI build host is our OWN existing
recipe scripts/oi-make-ami.sh: a throwaway Amazon-Linux helper dd's OI's official raw
cloud image (https://dlc.openindiana.org/isos/hipster/20260430/OI-hipster-cloudimage.img.zst,
NEWER than the 20251026 the script pins) onto a blank EBS vol -> snapshot -> register AMI.
This is how the FIRST OI builder was made; OI's image is on OI's server (not account-bound).
Dispatched on beef (locked SG, no public access). Once the full OI host is up:
  1. build a runnable illumos Nix on it + `nix-store --export` -> publish to cache.solnix.io
     (THE missing account-proof artifact).
  2. grow the seed GNU userland (oi-build-host-setup gives gcc/pkg -> the source tools) +
     republish the seed FOD.
Then any bare illumos host bootstraps nix from the cache -> pure stdenv builds -> Phase-3.
NEW OI images publish periodically (20250402/20250606/20251026/20260430 seen) -> the OI-AMI
build is always reproducible from dlc.openindiana.org, immune to burner-account churn.

## DECISIONS (2026-08-03)
### Cache immutability — NEVER remove/mutate published artifacts (Nix invariant)
- Store paths are content-addressed + immutable by contract. Changing/removing a
  published /nix/store/<hash>-x path BREAKS every closure referencing it by hash
  (RUNPATH + References). So: cache.solnix.io is APPEND-ONLY.
- Phase-3 fully-Nix rebuild publishes NEW real-derivation artifacts at DIFFERENT
  hashes (real .drv provenance != nix-store--add content hash). Old + new COEXIST;
  configs choose via narinfo/attribute. Old nix-store--add artifacts become
  UNREFERENCED, not removed.
- Do NOT GC cache.solnix.io during the migration (a missing path an old closure
  needs = broken cache; an unreferenced path = harmless). Prune only far later,
  deliberately, once the fully-Nix set is stable + nothing depends on legacy.

### SPARC pure-stdenv build on `sun` (real UltraSPARC 45) — approved split
- SPARC seed gcc is a SPARC binary -> the SPARC stdenv bootstrap MUST run on SPARC
  (real or emulated). `sun` (sun4u SUNW,A70, gcc-13+pkg, 790G /scratch, ssh gburd) = real.
- SPLIT: build the ROOT objects (crt/csu + libc + stage0/stage1 toolchain — the
  ABI-critical, correctness-sensitive core) on REAL sun hardware (eliminates
  emulator-fidelity doubt — we already caught the %g4/-mcmodel bug that emulation
  masked). Fan out the BULK package rebuild on EMULATED sparc (throughput), consuming
  the already-verified native root.
- Treat `sun` as a build ORACLE not a fleet node: build under /scratch as gburd,
  timeout-wrapped, non-disruptive (it's the maintainer's box, used for other things).
- Sequencing: SPARC is Phase-5 (after x86_64 GATE 1b-PURE proves the pattern);
  the sun-root build can start in parallel then (different substrate, no contention).

## MILESTONE STATUS (2026-08-03)
### GATE A PASSED — declarative Nix-operational x86_64 AMI (edition=unstable)
First declarative solnix AMI boots on EC2 (see docs/gate-a.md): declarative profile on PATH,
nix operational (pulled+ran a cache pkg on the instance), deriver resolves, rpool ONLINE,
/etc/solnix-release EDITION=unstable. Reproducible via scripts/oi-make-declarative-be.sh
(stage->deploy) + scripts/oi-be-to-ami.sh. Default substituter = ORIGIN s3.solnix.io/solnix-cache
(CDN cache.solnix.io negative-caches 404 on fresh hashes; SUBSTITUTER= override once edge fixed).

### Phase-3 fully-Nix rebuild — IN PROGRESS, swath opening
Real .drv-backed hermetic x86_64-solaris derivations published (append-only), growing:
  tranche 1 (8): zlib bzip2 xz file gnugrep gnused coreutils pcre2
  tranche 2 (4, H1 cc-wrapper -R runpath fix): libiconv libunistring expat libatomic_ops
  tranche 3 (H2+H6+H7 fixes -> the pkg-config swath): gettext ncurses less libidn2 libgpg-error
    pkg-config + pkg-config-wrapper, gmp-with-cxx (H2 C++ runtime proof). ~52 real-derivation rows.
Shared stdenv gaps found+fixed as we go: H1 (runpath, cc-wrapper patch 0005) DONE; H2 (C++ runtime,
  same-class) DONE; H6 (seed system libs) + H7 (libtool gnm) DONE (tranche 3). pkg-config unblocks
  the large autotools-with-shared-lib-deps swath -> the rebuild broadens from here.

### Editions (release model) — see docs/design-editions.md
Everything above = the `unstable` edition (rolling). A dated `26.11` stable = freeze unstable
(nixpkgs release-26.11 pin + solnix-pkgs tag v26.11 + namespaced cache + solnix.edition="26.11")
once x86_64 hits the release criteria (Phase-3 core fully-Nix + GATE A + installer ISO).

### Per-arch GATE 1b-PURE status
x86_64: FULL (pattern + Phase-3 executing). sparcv9: PARTIAL->FULL in progress (stdenv wired, hello
  runs on real sun; nix-on-sparc building on the now-proper /nix). aarch64: cross stdenv wired,
  libcCross published; cross-gcc seed-grow in progress -> cross-realise. riscv: port maturation.

## HONEST CORRECTION (2026-08-04): a /usr/lib/64 impurity class affects some "real" derivations
The gawk hermetic fix exposed a systemic issue: some Phase-3 packages have real .drv + run, but
their closures are NOT fully hermetic — they link host libs from /usr/lib/64 that SHOULD come from
the store. Root cause (two-layer): (1) nixpkgs expr doesn't declare gmp/mpfr/ncurses/etc as
buildInputs so no store -L; (2) even with buildInputs, the seed-syslibs -L (host copies) wins the
H1 auto-RUNPATH order unless the store -L is in NIX_CFLAGS_COMPILE_BEFORE (extraBefore).
LEGIT boundary (NOT impurity): /lib/64 refs for libc/libm/libnsl/libmp/libmd = the illumos
platform ABI, present on every illumos host, shared by every package incl the seed (like NixOS
binaries referencing the kernel/loader). Only /usr/lib/64 refs for STORE-ownable libs are the bug.
AFFECTED (flagged, fix pattern known = gawkReal: store buildInputs + NIX_CFLAGS_COMPILE_BEFORE -L,
and build the REAL nixpkgs attr via callPackage not the stdenv-seed stub):
  coreutils(libgmp), bash(libncurses.so.5), bc, xz(liblzma), gnumake(guile/gc/ffi/gmp/unistring),
  gnugrep(libpcre2), binutils/gnm(libz/libzstd), nix-2.3.16(boost/openssl/curl/...).
gawk FIXED (gawkReal: all 4 libs -> /nix/store, closure has real deps, runs reporting store versions).
NEXT: a hermeticity-audit + fix pass over the accepted set (re-verify each real-derivation's ldd for
/usr/lib/64 store-ownable leaks; apply the gawkReal pattern). This is required for a TRUE exactly-Nix
claim. The AMIs still boot + run; this tightens the closure purity, not runtime function.

## H30 RESOLVED (tranche 7): broken-gawk RUNPATH wedge, durably fixed on cache
The published/wave gawk had a host-only RUNPATH (/usr/gcc/14/lib/amd64) and NO libmpfr.so.6 in its
closure, so on a FRESH clean host it crashed at load (`ld.so.1: awk: fatal: libmpfr.so.6: open
failed` / `symbol mpfr_get_version referenced symbol not found`). Because the stdenv setup.sh
`_allFlags` uses awk to enumerate env vars for substituteAll, a crashing gawk made substituteAll emit
NO --subst-var flags, leaving @wrapperName@/@suffixSalt@ literal in every cc-wrapper setup-hook
(`export NIX_@wrapperName@_TARGET_HOST_@suffixSalt@=1: not a valid identifier`) -> the whole toolchain
bootstrap died. FIX (gawkReal, now in pkgs/illumos/solaris-overlay.nix `gawk`): rebuild the real
nixpkgs gawk with gmp+mpfr as store buildInputs + their -L in NIX_CFLAGS_COMPILE_BEFORE so the H1
cc-wrapper auto-runpath bakes /nix/store -R (mpfr-4.2.2, gmp-6.3.0) into the RUNPATH. Built + verified
(deriver resolves, host-free closure, runs in `env -i` with NO host /usr/gcc/14 libs), published to
s3.solnix.io and DURABLE at cache.solnix.io (j7h3y8b2zr3294fg95wk10m3r0fd0xwn-gawk-5.4.1). A fresh host
now substitutes the fixed gawk (proven: deleted local + host hack, re-substituted via cbproxy, ran
clean). This unblocks fresh-host toolchain builds.

## Tranche 7 (toolchain baseline, real hermetic x86_64-solaris derivations, published+durable)
Built against a locally-reproduced nixpkgs-patched (patches 0001-0006 + minfeatures bypass, nix-store
--add = 00w7p2sg4svr8rqavapiqv34iwyr1anw) on a fresh Nix-ready fleet host; pure stdenv+seed substituted
from cache. All: deriver resolves to a .drv, host-free closure, run OK, no /usr/lib/64 store-ownable
leak, published to s3.solnix.io + durable at cache.solnix.io (cache-bust verified 200):
  m4 1.4.21 (98l63sff), gnumake 4.4.1 (13xdhnmn), gmp 6.3.0 C-only+dev+info (xvq75bi4/b7qj1122/ajyz028y),
  binutils 2.46.1 GNU as/ar/nm + Solaris ld (a6yl9zl8), libffi 3.7.0 +dev/info/man (kmdpv0gz/...),
  gawk 5.4.1 gawkReal +man (j7h3y8b2/pggw8z24). See pkgs/illumos/phase3/tranche7-toolchain.nix.
  NOTE: `binutils` provides GNU as/ar/nm; the linker is the native illumos Solaris ld (by design --
  gcc is --with-ld=/usr/bin/ld; GNU binutils ld is not the illumos linker).
  FOLLOW-UP (gcc as a from-source profile package): NOT attempted this tranche -- gcc-unwrapped is the
  seed-wrap (the seed's gcc-10 installed into a store path), which the stdenv already exposes; a true
  from-source gcc profile pkg is a separate large effort (see design-minimal-build-host.md).
  HOST NOTE (fresh-host bootstrap): the fresh host also needed libmpfr.so.6+libgmp.so.10 dropped into
  /usr/gcc/14/lib/amd64 to satisfy the pre-gawkReal seed-gawk RUNPATH ONCE (chicken-and-egg); after
  gawkReal is on the cache this host hack is unnecessary for subsequent fresh hosts (they substitute
  the fixed gawk). Also: nix 2.3.16 needed NIX_SSL_CERT_FILE pointed at a real CA bundle
  (/etc/certs/CA/*.pem concatenated) -- the default /etc/ssl/certs/ca-certificates.crt path was absent.

## Nix 2.24 cutover — status (release path)
DONE: Nix 2.24.15 productionized (from-source drv, 5-patch series, relocatable bootstrap tarball);
  GATE 1b-PURE re-verified on 2.24 (hermetic hello, __structuredAttrs adapter dropped); fleet on 2.24
  (3 hosts, build-once-fetch-many); 28 core pkgs rebuilt as real hermetic derivations on the 2.24
  stdenv (docs/registry/real-derivations-224.tsv). TRUSTED KEY corrected to 5HAV... (verified;
  8UNrVA from the handoff doc was wrong, reverted everywhere).
IN FLIGHT: rebuild the remaining release-critical set on 2.24 (curl/git/vim/htop/nvi/gdb/gettext/
  bashInteractive/rsync) — stage the newer qmvlnvf0 fork on the 2.24 builder (fetchFromGitHub/
  fetchpatch coverage) + fix gettext's hardcoded -l seed libs.
NEXT: re-cut release AMI/ISO/IMG on 2.24 (nix profile install by-name works; correct 5HAV key;
  full toolset incl build-host baseline; curl/ping/nvi-edits/gdb; no core files; full PATH) ->
  freeze 26.11.
