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
