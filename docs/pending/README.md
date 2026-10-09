# Changes held for the next world rebuild

Each of these changes the builder text of mk-src-pkg (or another base builder),
so it changes every package hash and needs one full chain rebuild. They are
batched so that rebuild happens once.

- mk-src-pkg-guardfix.diff: the build-time-path guard fails the build when grep
  exits 2, instead of reading it as no hits. Measured on dixi: with illumos grep
  (no --binary-files) the old guard reported 0 hits on an ELF that names the gate
  proto; the new one fails it, and passes a clean output.
- gate-iconv-modules-gap.md: the gate proto (s7zkx8nx) carries 201 of the iconv
  modules (no amd64/, no UTF-8%UTF-16.so or UTF-8%8859-1.so); OpenIndiana's
  system/library/iconv/utf-8 has 1317 with amd64/. illumos-gate's lib/Makefile
  builds iconv_modules (common euro hi_IN ja ko th_TH zh utf-8 vi), so the proto
  build or its packing dropped them. Every 64-bit iconv(3) user on solnix gets
  "Not supported UTF-8 to UTF-16" (measured on dixi). Needs a gate proto rebuild
  (with the iconv_modules output kept) -- the same full rebuild as the item above.
  Until then gettext links GNU libiconv, as nixpkgs does off glibc.
- builders-need-store-tools.md: the builders run with PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
  and call GNU tools and /usr/gcc/14 from the OpenIndiana build host. A solnix system has
  none of them, so `nix build` of any solnix package fails there (measured on dixi:
  "sha256sum: command not found"). The fix is a store-tool stdenv; it changes every
  hash, so it joins the same rebuild.
