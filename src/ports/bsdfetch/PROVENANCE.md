# bsdfetch: FreeBSD fetch(1) + libfetch(3), vendored unmodified

- Source: https://github.com/freebsd/freebsd-src at e48eb1c5c47fa3e0814f161f17ccf5de98470fe5 (2026-10-20),
  `lib/libfetch/*` and `usr.bin/fetch/*` (Makefile.depend* omitted). Files under `upstream/` are byte-identical
  to that commit (checked against a sparse checkout of the same rev).
- License: BSD-3-Clause (SPDX headers in each file; Dag-Erling Smørgrav et al.). No GPL.
- Why vendored: the two directories are ~200 KB; the only upstream tarball is the whole tree (~1 GB).
- Build: pkgs/illumos/bsdfetch.nix compiles them with illumos shims (shims/) and three small patches
  (patches/: BSD sockaddr lengths, FreeBSD-only socket options, the system CA bundle); upstream/ is never edited.
