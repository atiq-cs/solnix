# The builders assume an OpenIndiana build host; a solnix system cannot build solnix packages

Measured on the X1 (dixi, solnix-3), 2026-10-09, by stream I1:
`nix build .#packages.x86_64-solaris.gzip` fails in 13 s with
`bash: line 5: sha256sum: command not found`.

## Why

mk-src-pkg.nix (and mk-userland-pkg.nix, toolchains.nix, gcc-src.nix, base-src.nix,
nix224.nix, host-pkgs.nix' writers, ...) run `builder = "/usr/bin/bash"` with
`PATH=/usr/gnu/bin:/usr/bin:/usr/sbin` and call GNU tools by those paths:
sha256sum, gmake, GNU sed/tar/grep, gcc from /usr/gcc/14. On the OpenIndiana build
host (bhost) those come from IPS packages. A solnix system has no /usr/gnu and no
/usr/gcc, and its /usr/bin is the system profile, so none of them exists there. The
paths in dixi's store that came from these builders were copied in from bhost, not
built on dixi.

So "nix-build works" holds only on an OpenIndiana host: the north star (solnix is
exactly Nix: every package a real derivation that builds where Nix runs) is not met on
solnix itself. NixOS's answer is stdenv: the builder and every tool on its PATH are
store paths (bootstrap-tools, then the stages), and nothing outside /nix/store is
read during a build.

## What the fix is

A solnix stdenv: builder = a store bash; PATH = store coreutils, findutils, gnugrep,
gnused, gnutar, gzip, xz, gnumake, diffutils, gawk, patch, bzip2 (all already
from-source packages here, pkgs/illumos/base-src.nix) plus the gcc wrapper
(solnix-dev's gccWrapper) and binutils from the store, and the illumos
headers/crt/libc from the gate proto (already a store path). The bootstrap is the
chain that already exists (bhost built gcc 14.3.0 and binutils 2.46.1 from source);
what changes is that every builder names store tools instead of /usr/gnu and
/usr/gcc. The illumos tools a build legitimately needs (elfdump, ldd, mcs) come from
the world's store path, not /usr/bin.

This changes every derivation's hash, so it belongs in the same planned full
rebuild as mk-src-pkg-guardfix.diff and gate-iconv-modules-gap.md, after which the
world, the kernel and every package are rebuilt by the new builders, and bhost
stops being special: any solnix system (dixi, an EC2 solnix instance) can build.
A gate check for it: build one package on dixi (no /usr/gnu) and require the build
to succeed; a negative control is the current builder, which fails there.

## Status 2026-10-11 (stream STDENV): the sha256sum + decompressor + guard-grep walls are DOWN; proven on dixi

mk-src-pkg can now build on a solnix system. Changes (one coherent set; changes
every mk-src-pkg output hash, the batched full rebuild this doc anticipated):

* **sha256sum -> /usr/bin/digest -a sha256** in mk-src-pkg.nix, mk-userland-pkg.nix,
  nix224.nix. illumos has no sha256sum; `digest -a sha256` is always present and
  emits lowercase hex, matching the plain-hex `src.sha256` (verified on dixi:
  `printf abc | /usr/bin/digest -a sha256` = ba7816bf..., and the real pkgconf
  tarball's digest == its pinned sha). A store coreutils' sha256sum would be
  circular (coreutils is itself built by mk-src-pkg), so digest is the right
  non-circular, illumos-native choice.
* **buildTools ? [ ]** arg on mk-src-pkg.nix / base-src.nix / default.nix: store
  paths whose bin/ go FIRST on the builder PATH (store gmake/gnutar/xz/gzip/
  bzip2/gnugrep/gnused + binutils' gstrip). Each is a real Nix reference, so it
  is pulled into the build-time closure (not a bare name on a PATH that may lack
  it). **Default [] is byte-identical to the old /usr/gnu/bin:/usr/bin:/usr/sbin**
  at builder runtime, so the OI buildhost path is behaviourally unchanged; a
  solnix system passes the store set. gstrip resolves from a buildTools bin/ else
  /usr/bin/gstrip, and FATALs if neither exists (illumos SVR4 /usr/bin/strip
  silently ignores --strip-debug, so it is never a fallback).
* **guard-grep fix** (mk-src-pkg-guardfix.diff folded in): the build-time-path
  guard now runs POSIX `grep -rl` with its exit status CHECKED (rc>1 => FATAL),
  not `grep -rl --binary-files=binary ... 2>/dev/null | while` which, on a system
  without GNU grep, exits 2 (illumos grep rejects --binary-files) and was read as
  "no hits" -- a blind guard.

Proof (dixi 192.168.1.124, repo subset, gate + from-source gcc from the store):
`nix build` of pkgconf-2.3.0 with buildTools=[] FAILS at the decompressor wall
(`tar: Could not stat /usr/bin/xzcat` -> `./configure: No such file`), having
already cleared the sha256 check; with buildTools set it REALIZES
(/nix/store/gyi6bh6q203vc4z0frm9k72wpxic6i1r-pkgconf-2.3.0; `pkgconf --version`
=> 2.3.0; closure gate "every ELF resolves inside /nix/store" passed).

### gcc path -- NON-ISSUE for mk-src-pkg; follow-up only on the OI-host builders

mk-src-pkg's `gcc ? "/usr/gcc/14"` default never applies on a solnix build:
base-src.nix passes the from-source gcc DERIVATION (gcc-src.nix), so
`builtins.isAttrs gcc` is true and the builder uses `$gcc/bin/gcc` from the
store (proven: pkgconf linked its libstdc++/libgcc_s via gcc.lib and passed the
closure gate on dixi). `stage0`/`/usr/gcc/14` are the host-gcc (toolchain-seed)
branch only. gcc-src.nix itself still uses the IPS `stage0 = /usr/gcc/14` seed
to COMPILE the from-source gcc -- that is the documented NixOS-style bootstrap
(bootstrap-tools seed), and the gcc binary is already a store path, so a solnix
system never re-runs it. No change needed for the core deliverable.

### Still deferred (the larger self-hosting items)

* **Default-wiring buildTools for a solnix system.** default.nix accepts
  buildTools but the shipped configs still default to []. Fully self-hosting a
  solnix system means a *seed* buildEnv (store gmake/gnutar/gzip/xz/bzip2/
  gnugrep/gnused/binutils, each referenced as a pinned storePath so there is no
  mk-src-pkg->mk-src-pkg cycle) wired as the default buildTools on-system. dixi's
  store already has every one of these (bhost-built); gzip and bzip2 were absent
  from dixi's store during this proof (only .tar.xz paths were needed) -- a seed
  must include them for the .tar.gz/.tar.bz2 packages.
* **mk-userland-pkg.nix / nix224.nix** still assume the OI host: PATH has
  /usr/gnu/bin, they `/usr/bin/curl` + `/usr/gnu/bin/tar` + `gmake` + the
  `/usr/gnu/bin/objdump` objcopy fallback, and nix224 links the host IPS libs.
  These are the OI-host userland/classic-nix path, superseded on the hermetic
  route by mk-src-pkg + nix-src.nix. Only their sha256sum was fixed here; a full
  store-tool port of them is a separate item (they need the same buildTools
  treatment, or retirement in favour of the from-source chain).
