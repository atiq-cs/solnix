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

## Notes
- The seed already supplies gcc/binutils/make to the *build stdenv*, so from-source
  builds WORK today. This directive additionally requires these as *profile packages*
  a user invokes directly (`cc`, `make`, `gdb` on PATH in a minimal install).
- Publishing a locally-built package to the PUBLIC cache remains a maintainer/CI
  privilege (needs the signing key); a minimal install can build + use locally and
  push to a private cache.
- Applies to all image types (AMI/ISO/IMG) and all arches as each reaches parity;
  x86_64 first.
