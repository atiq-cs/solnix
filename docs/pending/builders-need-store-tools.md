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
