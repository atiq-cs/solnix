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
