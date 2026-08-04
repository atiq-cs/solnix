# Minimal-install baseline: a self-sufficient build host

**Directive (maintainer, 2026-08-04):** the default MINIMAL install of solnix — in
AMIs, ISOs, and IMGs — MUST contain the build toolchain sufficient to build
packages, including supporting libraries and debugging tools. A minimal solnix
is a self-sufficient **build host / Nix workstation**, not a fetch-only appliance.

This raises the baseline: `configurations/base.nix` `environment.systemPackages`
(the minimal profile) must include the toolchain set below, all as real hermetic
x86_64-solaris derivations (fetchable from cache.solnix.io), so a freshly-booted
minimal solnix can `nix-build`/`cc`/`make`/`gdb` out of the box.

## Required baseline set

### Toolchain (compile + link)
- `gcc` (the C/C++ compiler as a profile package — not only the seed-embedded one)
- `binutils` (as, ld, ar, nm, objdump, strip, ...)
- `gnumake`
- `m4`
- the pure x86_64-solaris `stdenv` + its cc-wrapper (already the build stdenv)
- libc + headers (`/usr/include`-equivalent) — from the seed; ensure headers are
  present in the profile/sysroot so user compiles find them

### Build plumbing (autotools / common build deps)
- `pkg-config`, `autoconf`, `automake`, `libtool`, `bison`, `flex`, `patch`
- `gnutar`, `gzip`, `xz`, `bzip2` (unpack)
- `gnugrep`, `gnused`, `gawk`, `coreutils`, `findutils`, `diffutils` (build scripts)

### Supporting libraries (the common link deps)
- `zlib`, `openssl`, `ncurses`, `readline`, `pcre2`, `libiconv`, `libffi`,
  `gmp`, `mpfr`, `expat`

### Debugging tools
- `gdb` (the debugger — currently MISSING, must be built)
- debug-info: ship the `-debug` outputs / DWARF (solnix already splits debug;
  ensure the minimal profile can pull `-debug` outputs; `truss`/`mdb` are native
  illumos and present in the base OS)
- (later/optional: `valgrind` if it ports to illumos-x86_64; `strace`→`truss` native)

### Fetch / VCS (to obtain sources for building)
- `curl`, `git`

## Build status (2026-08-04) — gaps to close for the baseline
BUILT (real derivations): pkg-config, autoconf, automake, libtool, bison, flex,
  patch, gnutar, gzip, xz, bzip2, zlib, openssl, ncurses, readline, pcre2,
  libiconv, mpfr, expat, curl, git, htop, vim, openssh (+ many more).
**MISSING — must build for the baseline:**
- `gcc` (as a first-class profile package), `binutils`, `gnumake`, `m4` — currently
  only available as SEED slices for the stdenv; promote to real profile derivations.
- `libffi`, `gmp` — supporting libs (H4/known gaps).
- `gdb` — the debugger (not yet attempted on x86_64-solaris).

## Build status update (tranche 7) — toolchain baseline built as real profile derivations
PROMOTED to real hermetic x86_64-solaris profile derivations (deriver resolves,
host-free closure, run OK, no /usr/lib/64 leak, published + durable at cache.solnix.io):
- `m4` 1.4.21, `gnumake` 4.4.1, `binutils` 2.46.1 (GNU as/ar/nm; illumos Solaris ld),
  `libffi` 3.7.0 (+dev/info/man), `gmp` 6.3.0 (C-only, +dev/info).
- `gdb` 17.2 is already a published real derivation (real-derivations.tsv, tranche 6).
STILL OPEN:
- `gcc` as a from-source PROFILE package. The stdenv already exposes a seed-wrap
  gcc-unwrapped (the seed's gcc-10 in a store path) which makes from-source builds
  work today; a user-facing `cc`/`g++` profile package = the seed-wrap cc + cc-wrapper
  exposed as an installable (quick) OR a true from-source gcc build (large, separate
  effort). Recorded as the remaining toolchain follow-up.
Repro entry: pkgs/illumos/phase3/tranche7-toolchain.nix; gawkReal (H30) fix folded
into pkgs/illumos/solaris-overlay.nix so the durable gawk is the canonical build.

## Notes
- The seed already supplies gcc/binutils/make to the *build stdenv*, so from-source
  builds WORK today. This directive additionally requires these as *profile packages*
  a user invokes directly (`cc`, `make`, `gdb` on PATH in a minimal install).
- Publishing a locally-built package to the PUBLIC cache remains a maintainer/CI
  privilege (needs the signing key); a minimal install can build + use locally and
  push to a private cache.
- Applies to all image types (AMI/ISO/IMG) and all arches as each reaches parity;
  x86_64 first.

## ADDENDUM (maintainer, 2026-08-04): default-distro must-haves + PATH + Nix version
1. **curl AND ping in the DEFAULT distro** — every minimal image (AMI/ISO/IMG) ships curl
   (real derivation, built) + ping. NOTE: illumos `ping` is native in the base OS
   (/usr/sbin/ping) — ensure it's on PATH (see #2); curl must be in environment.systemPackages.
   (This session hit a bare image with neither curl nor a usable ping/getent — must not recur.)
2. **Default login PATH (bash AND ksh) must include the nix-ified paths + common defaults.**
   The shell-environment module must set, for root + all users, in BOTH bash and ksh profiles:
     PATH=/run/current-system/sw/bin:/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:/sbin:/usr/ccs/bin
   i.e. the declarative Nix profile FIRST, then the Nix tooling, then the illumos base OS dirs
   (so both `htop` from the Nix profile AND native `ping`/`getent`/`format` resolve). Applies to
   /etc/profile (ksh/sh login) + /etc/bashrc + /etc/profile.d — ksh93 is the illumos default shell
   so it MUST get the PATH too (this session: ksh93 login had no nix paths).
3. **Nix version: the FIRST solnix RELEASE must be built on Nix 2.24+ (or Lix 2.90+), NOT 2.3.16.**
   2.3.16 was the bootstrap-only choice; it lacks `nix profile`, has a fragile LD_LIBRARY_PATH
   relocatable install, weak diagnostics, and forced the __structuredAttrs=false workaround. The
   transition (build 2.24+/Lix on x86_64-solaris -> re-bank bootstrap -> rebuild pure stdenv ->
   re-cut images) is a prerequisite for the first release. See docs/design-nix-upgrade.md.
