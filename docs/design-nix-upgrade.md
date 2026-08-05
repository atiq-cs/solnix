# Transition solnix to Nix 2.24+ (the first-release Nix)

**Directive (maintainer, 2026-08-04):** solnix must move off Nix 2.3.16 to the
latest Nix (2.24+). **The FIRST solnix release must be built on 2.24+ (or Lix
2.90+), not 2.3.16.** 2.3.16 was the bootstrap-only choice and has now shown all
its sharp edges (no `nix profile`, LD_LIBRARY_PATH-fragile relocatable install,
weak diagnostics, forced the `__structuredAttrs=false` workaround, old HTTP/TLS).

## Why upgrade (concrete pains hit on 2.3.16)
- `nix profile install` doesn't exist (2.4+ command) — users hit "not a recognised command".
- The bootstrap-tarball install depends on `LD_LIBRARY_PATH=runtime-lib`; breaks under
  `pfexec`/env-reset → nix silently won't launch (`libreadline.so.8: open failed`).
- HTTP substituter is the old libcurl path; no CA bundle handling → silent substitute
  failures against the Cloudflare cache (no diagnostics).
- Forced the `__structuredAttrs=false` stdenvAdapter across the whole overlay (Nix 2.3
  has no structuredAttrs) — removable on 2.24+, simplifying the fork.

## Candidates
- **Nix 2.24–2.29** (upstream stable line): `nix profile`, flakes, new CLI, robust
  HTTP/TLS + CA handling, proper installed store, good errors. C++20 + meson/ninja +
  newer boost/curl/nlohmann-json/lowdown/libgit2/toml11.
- **Lix 2.90+** (CppNix-compatible fork): actively maintained; some report cleaner/lighter
  deps → possibly easier to build on a new platform. CLI-compatible with upstream.
- **Decision gate:** a bounded SPIKE builds BOTH on x86_64-solaris, compares build
  friction, then we commit to whichever ports cleaner.

## Transition plan (dependency order)
1. **SPIKE (1 fleet host, ~1-2 days):** attempt to build Nix 2.24 (or a nearby 2.2x) AND
   Lix on x86_64-solaris using the seed toolchain + Phase-3-built deps (openssl/curl/sqlite/
   boost/etc.). Forward-port the illumos-specific patches from oi-nix-setup.sh (STREAMS
   ptem/ldterm, cfmakeraw, procfs bits) to the new codebase. Report: which builds, the
   dep gaps, the real port cost. THIS de-risks everything below.
2. **Build the chosen Nix** on x86_64-solaris as a REAL derivation (not just a tarball) —
   properly installed (no LD_LIBRARY_PATH fragility; RUNPATH-correct, CA bundle wired).
3. **Re-bank the account-proof bootstrap** with the new Nix (relocatable tarball for bare
   hosts, but a proper install, + a CA bundle baked/pointed via NIX_SSL_CERT_FILE).
4. **Rebuild the pure stdenv against the new Nix.** DROP the `__structuredAttrs=false`
   adapter (works natively on 2.24+) + the 2.3-era workarounds → simpler overlay. Re-verify
   GATE 1b-PURE (hermetic hello) on the new stdenv.
5. **Re-cut images** (AMI/ISO/IMG) on the new Nix + the complete minimal baseline
   (curl+ping+full PATH+build-host toolchain+no-core-files). `nix profile install htop`
   must work by NAME (channel/flake registry wired — the "workstation" gap).
6. **Phase-3 packages carry over** — they're store paths; the newer Nix reads the store
   format fine. It's the TOOLCHAIN (nix + stdenv) that changes, not the ~71 built packages.
   (Some may want rebuild if a stdenv change alters their hash, but functionally they're reusable.)

## Cost / risk (honest)
- Biggest single porting task since the original stdenv. Modern Nix is a meatier C++20 build
  on a non-Linux platform. Days, possibly ~a week, with real risk of dependency friction
  (boost/curl/meson on illumos). The spike bounds it.
- Payoff: fixes `nix profile`, the fragile install, diagnostics, CA handling; drops 2.3-era
  workarounds; makes Nix "properly integrated." Prerequisite for the first release.

## Sequencing vs other work
- Phase-3 breadth on the OLD toolchain continues in parallel (packages carry over), BUT
  don't scale to thousands on 2.3.16 — land the upgrade first, then fan out on 2.24+.
- The first release is GATED on this upgrade (maintainer directive).

## Fleet-scaling prerequisites (status, for the post-2.24 fan-out)
- **Option B (locked flake.lock) — ALREADY SATISFIED:** solnix-pkgs/flake.lock pins nixpkgs to
  7f81d69c (matches flake.nix). Any host evaluating the flake gets identical nixpkgs-patched.
  The per-host "rebuild nixpkgs-patched" waste on the CURRENT fleet was the 2.3.16 NON-flake path
  (manual nix-store --add). On Nix 2.24 (proper flakes) the fleet evals the locked flake + then
  SUBSTITUTES the built patched-nixpkgs closure from cache.solnix.io (Unblock #1) => no per-host
  rebuild. So the fleet-rebuild fan-out on 2.24 is clean: build closure once, push, N hosts fetch.
- **Cache-as-substituter (Unblock #1) — READY:** every host nix.conf points at cache.solnix.io
  + builders-use-substitutes=true (baked into oi-fleet-bootstrap.sh). H28 fixed site-side.
- **Subnet routing (fleet<->OI-host/Codeberg) — our LAN, non-blocking** (cache reaches fine).

## Productionization results (Nix 2.24.15, autotools, x86_64-solaris)
Produced on a fresh OI-build-AMI clone (pkg update -> 2026 userland -> gcc-13):
- **Clean patch series** `pkgs/illumos/nix-illumos-patches/224/*.patch` (5 numbered
  patches, each what/why-commented, all apply `-p1` in sequence): 0001 winsize/termios
  include, 0002 sigorset fallback guard, 0003 cfmakeraw + STREAMS ptem/ldterm re-port,
  0004 flock LOCK_UN|LOCK_NB EINVAL fix, 0005 getSelfExe /proc/self/path/a.out. Build-env
  tweaks (empty AC_CONFIG_FILES, openssl-3 .pc, ax_boost_base, vendored toml11,
  ERROR_SWITCH_ENUM=, GNU-readline REPL, --disable-gc/markdown/cpuid) live in the
  driver/derivation, documented in the series README.
- **From-source derivation** `pkgs/illumos/nix224.nix` (standalone `derivation`, sandbox=false,
  sha256-verified fetch, patch series applied, autotools build, RUNPATH relocate via
  `/usr/bin/elfedit`, libgit2 bundled into `$out/lib`, CA baked into `$out/etc/ssl/certs`
  + `ssl-cert-file` in `$out/etc/nix/nix.conf`). Realised to a real store path; deriver
  resolves; `nix --version`=2.24.15 runs with **NO LD_LIBRARY_PATH** (ldd clean, RUNPATH =
  store+system dirs only, no build-temp); TLS substitute + copy roundtrip + `nix profile`
  install/list all proven. Driver: `scripts/oi-nix224-setup.sh`.
- **Bootstrap tarball** `bootstrap/nix-illumos-2.24.15.tar.zst` re-banked
  (`scripts/oi-nix224-bank-bootstrap.sh`): RUNPATH baked to the fixed install prefix
  `/nix-tools224/{lib,lib/amd64,runtime-lib}` + a 39-lib runtime-lib closure (real .so
  files, no dangling symlinks) + bundled CA. **Proven relocatable**: `env -i` (empty env)
  `nix --version`=2.24.15, ldd all resolve — fixes the 2.3.16 LD_LIBRARY_PATH fragility.
  Uploaded to `s3://solnix-cache/bootstrap/` (durable at the s3.solnix.io origin;
  cache.solnix.io CDN heals as the H28 negative-cache TTL expires).
- **`__structuredAttrs=false` adapter DROPPED**: proven a `__structuredAttrs=true`
  derivation builds on the 2.24 nix (`.attrs.sh` written, list materialises as a bash
  array) — the exact thing 2.3.16 could not do. `pkgs/illumos/phase3/tranche-entry-224.nix`
  is the successor overlay entry with the adapter (and the H3 fetchurlBoot re-assert it
  forced) removed. The pure `stagesNix` stdenv itself carries no adapter dependency.
- **Remaining for full cutover:** run the GATE 1b-PURE hermetic-hello REALISE on 2.24 (needs
  the seed-wired illumos build host, not a fresh clone — a multi-hour stdenv bootstrap);
  point `oi-fleet-bootstrap.sh` at the 2.24 tarball; re-validate the 79 carry-over store
  paths; re-cut images on 2.24.

## Sequencing to the first release (post-port)
1. Nix 2.24 port lands (patches + from-source drv + bootstrap tarball + new pure stdenv, GATE
   1b-PURE re-verified) — IN FLIGHT (a41ef8b5).
2. Re-bank the 2.24 bootstrap tarball -> update oi-fleet-bootstrap.sh to install 2.24 (not 2.3.16).
3. Fan out the fleet on 2.24: rebuild the package set as real derivations against the new stdenv
   (the 79 existing carry over as store paths; re-validate + grow breadth). Cache-substituter means
   build-once-fetch-many. Scale to ~12 hosts (quota headroom ~460).
4. Re-cut COMPLETE images (AMI/ISO/IMG) on 2.24 + the full minimal-build-host baseline
   (curl+ping+nvi+gdb+toolchain+full-PATH+no-core-files) where `nix profile install <name>` works.
5. Freeze the first dated release (26.11) once x86_64 hits the release criteria.

## Image install-experience fixes (found via live testing)
1. **gcroots/auto not user-writable** -> non-root `nix profile install` failed ("Permission denied
   [/nix/var/nix/gcroots/auto/...]"). FIX: oi-make-declarative-be.sh makes gcroots/auto + temproots
   1777 (sticky-writable, like /tmp). A normal user now installs WITHOUT pfexec.
2. **~/.nix-profile pointed at the root-owned system default** (not the per-user profile) + the login
   PATH did NOT include $HOME/.nix-profile/bin -> user-installed pkgs invisible (sqlite3 installed to
   its /nix/store hash path but not on PATH). FIX: ~/.nix-profile -> per-user profile; PATH prepends
   $HOME/.nix-profile/bin (shell-environment.nix + the .profile fallback). User installs now on PATH.
   (Packages ARE pure + hash-addressed in /nix/store — the gap was purely the profile->PATH link.)
3. **`nix profile install` used to require --impure** because the baked solnix-flake used
   builtins.storePath (nixpkgs ? builtins.storePath /nix/store/qmvln...-nixpkgs-patched; the
   fetchurl-shim mirrors.nix; the gnu-config config.guess/config.sub FODs) -> "not allowed in pure
   evaluation mode". On Nix 2.24, pure eval ALSO rejects a plain absolute path literal ("access to
   absolute path '/nix' is forbidden in pure evaluation mode"), so a bare path swap does not work.
   FIXED: pkgs/illumos/phase3/by-name-flake is a proper flake.nix whose fork nixpkgs + the two
   gnu-config FODs are `flake = false` path INPUTS pinned in flake.lock; pkgs.nix threads them into
   the existing tranche-entry-224.nix overlay (single source of truth) via new forkPath/gnuConfigGuess/
   gnuConfigSub params (defaults preserve the classic/impure `nix-build` path unchanged). Proven on
   the 2.24 host: `nix registry add nixpkgs path:<flake>` then `nix profile install nixpkgs#hello`
   with NO --impure -> installs + runs (Hello, world!). The AMI bakes this pure flake as solnix-flake
   (oi-make-declarative-be.sh step 5c/5d updated). classic nix-env shim resolves by name too.
   ALSO fix: 'which' is missing from the base toolset (add it); nix profile install is the verb (not 'add').
