# Native (build-platform) openssl-3.6.3 fix — aarch64 cross wave12

## The leverage point

The aarch64 cross entry's `buildPackages` (native x86_64-solaris) openssl-3.6.3
FAILED to link. This native openssl is the one that meson/ninja/python3/protoc
(build-time tools that RUN on the x86 host) need — NOT the aarch64 target
openssl (already cracked in wave4 via the Perl-target trick). A broken native
openssl blocked native python3 (its `_ssl` links libssl), and therefore the
whole `meson -> ninja -> python3` font stack plus native `protoc`.

## Exact failure (reproduced)

    nix-build .../buildPackages.openssl   # the NATIVE one

    ...
    apps/libapps.a -lssl -lcrypto -lsocket -lnsl -ldl
    ld: warning: file libmp.so.2: required by .../bootstrapLibs/usr/lib/amd64/libnsl.so, not found
    ld: warning: file libmd.so.1: required by .../bootstrapLibs/usr/lib/amd64/libnsl.so, not found
    Undefined                       first referenced
     symbol                             in file
    MD5Init                             .../bootstrapLibs/usr/lib/amd64/libnsl.so
    mp_itom                             .../bootstrapLibs/usr/lib/amd64/libnsl.so
    mp_madd                             .../libnsl.so
    mp_mdiv / _mp_move / mp_mtox / mp_mult / mp_sdiv / mp_xtom / mp_mfree / mp_pow
    MD5Final / MD5Update
    ld: fatal: symbol referencing errors. No output written to apps/openssl

### Root cause (the H6 native-syslib -L gap on the BUILD platform)

The `openssl` binary links `-lsocket -lnsl -ldl`. On illumos the seed's
`libnsl.so` transitively NEEDs:
  - `libmd.so.1`  (MD5Init / MD5Update / MD5Final)
  - `libmp.so.2`  (mp_itom / mp_madd / mp_mtox / mp_mult / ... — multi-precision)

Those two libs ship versioned-only in the seed (`libmd.so.1`, `libmp.so.2`)
with NO bare `lib<n>.so` link, and the native link had NO `-L` pointing at a
directory that carries the bare links. So the link-editor could not resolve the
transitive symbols -> "symbol referencing errors".

The canonical x86 fixed tranche's native stdenv already carries the fix (its
python3 `_ssl` proves a working native openssl exists there): an `extraSyslibs`
FOD slice (`/nix/store/ylyfkm6xwp60gg8yqcpj4g481l1fm1qq-illumos-extra-syslibs`)
that materialises `libmd.so`/`libmp.so` bare links in `lib/amd64`, wired via
`-L${extraSyslibs}/lib/amd64` on the native cc-wrapper. The cross entry's
`buildPackages` cc-wrapper predates that H6 fix, so its native openssl link
missed the `-L`.

## The fix (nativeOpensslWireOverlay — analogous to cmakeWireOverlay)

A NATIVE overlay (goes into the non-cross `overlays` list, so `buildPackages`
picks it up) that mirrors the x86 tranche's H6 crack on the native openssl:

    nativeOpensslWireOverlay = final: prev:
      let
        extraSyslibs = builtins.storePath /nix/store/ylyfkm6xwp60gg8yqcpj4g481l1fm1qq-illumos-extra-syslibs;
        seedL = "-L${extraSyslibs}/lib/amd64";
      in {
        openssl = prev.openssl.overrideAttrs (o: {
          NIX_LDFLAGS = (o.NIX_LDFLAGS or "") + " " + seedL + " -lmd -lmp";
          NIX_CFLAGS_COMPILE = (o.NIX_CFLAGS_COMPILE or "") + " " + seedL;
        });
        # ... plus zstd/libffi/tcl/python3 native-tool fixes below
      };

`extraSyslibs` is the SAME seed-sourced FOD the x86 tranche uses (already
in-store, hash-hermetic), carrying `libmd.so`/`libmp.so` bare links.

### Result — NATIVE openssl now builds

    /nix/store/pmlabdy9jnxss7b6g8jjg9wmxp6sd9v3-openssl-3.6.3        (out)
    /nix/store/aswq3gxz8p9csjbk8i9fr0jly25aqxqc-openssl-3.6.3-bin    (bin)

    $ file .../openssl-3.6.3/lib/libssl.so.3
      ELF 64-bit LSB dynamic lib AMD64 Version 1, dynamically linked
    $ .../openssl-3.6.3-bin/bin/openssl version
      OpenSSL 3.6.3 9 Jun 2026

The headline leverage point is fixed: a real x86_64 (AMD64) ELF libssl that
links and whose `openssl` binary runs.

## Downstream (native python3 chain) — additional native-tool fixes applied

With native openssl fixed, native python3 (the meson/protoc gate) advanced
through several further, ORTHOGONAL native-toolchain issues. Each was fixed in
the same native overlay:

  1. native `zstd`: `buildContrib` defaults ON (build==host) -> builds a C++
     `gen_html` doc tool that dies at build time `ld.so.1: gen_html:
     libstdc++.so.6: open failed`. Fix: `zstd.override { buildContrib = false; }`
     (also drops the `cp contrib/pzstd/pzstd` install step).
  2. native `libffi`: its testsuite pulls dejagnu -> expect -> native tcl whose
     `compat/fake-rfc2553.c` re-declares `strlcpy` (gcc14 conflicting-types vs
     illumos <string.h>). Fix: `libffi doCheck=false` (drops the test chain).
  3. native `tcl` (dep of python3 via sqlite): tclsh link `ld: fatal: symbol
     referencing errors` — same H6 libmd/libmp gap. Fix: add the extraSyslibs
     -L + -lmd -lmp to native tcl NIX_LDFLAGS. tcl now builds.
  4. native `python3` configure `cannot guess build type`: autoreconf
     regenerates config.guess/config.sub from autoconf-2.73's OLD bundled copies
     which don't know x86_64-*-solaris2.11. Fix: pass
     `--build=x86_64-pc-solaris2.11 --host=x86_64-pc-solaris2.11` explicitly.
     python3 now configures (picks up the fixed openssl via
     `--with-openssl=.../openssl-3.6.3-dev`) and compiles ~all C modules.

## Remaining blocker (native python3 -> font stack / protobuf)

native python3-3.14.6 now fails ONLY at:

    ./Modules/socketmodule.c:5928:77: error: operator '&&' has no right operand

A CPython-3.14 socketmodule illumos preprocessor-portability bug (a feature-test
macro expands empty inside an `#if ... && ...`, leaving `&&` dangling). This is a
CPython source bug, unrelated to openssl. It needs a one-line source patch to
`socketmodule.c` (guard/define the missing macro).

Because BOTH the meson font stack (fribidi/harfbuzz/pixman -> ninja -> python3)
AND protobuf 35.1 (its cmake build pulls a native python3 for code-gen) route
through native python3, they stay blocked on this CPython socketmodule bug.
Fixing that one preprocessor conditional is the next unlock; the native openssl
leverage point itself is done.

## What landed instead (breadth on the open C/C++ classes)

6 NEW aarch64 (EM_AARCH64) packages that need NEITHER native python3 NOR meson:
lz4, snappy, utf8proc, simdjson, cereal, brotli (compression + JSON + unicode +
serialization; cmake C/C++ on the cxxNomapCc C++ class). See
aarch64-wave12-paths.txt.
