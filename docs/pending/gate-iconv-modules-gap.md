# illumos iconv on solnix has no UTF-8 converters (gate proto / world gap)

Found by stream B, 2026-10-08, while building home-manager on dixi.

## Observed (REAL)
- dixi: `echo é | iconv -f UTF-8 -t UTF-16` => "Not supported UTF-8 to UTF-16"; `-t ISO8859-1` likewise.
- /run/current-system/world/usr/lib/iconv (world 73687v4y) == gate proto
  /nix/store/s7zkx8nx5sfxixmyqmlnrybrrh14jkmb-illumos-gate-proto/usr/lib/iconv: 201 entries, 17 named UTF-8%*,
  NO amd64/ subdirectory (so every 64-bit iconv_open() consumer finds no module at all), no geniconvtbl/,
  and none of UTF-8%UTF-16.so, UTF-8%8859-1.so, UTF-8%646.so.
- The gate's own manifest usr/src/pkg/manifests/system-library-iconv-utf-8.p5m (gate source vsnxlmf0...) ships
  usr/lib/iconv/$(ARCH64)/UTF-8%UTF-16.so (+BE/LE) and the rest; OpenIndiana (bhost, pkg
  system/library/iconv/utf-8) has 1317 entries incl. amd64/ and UTF-8%UTF-16.so, and there the same msgfmt binary
  converts fine.
- Effect: a 64-bit GNU msgfmt linked to libc iconv fails on any UTF-8 .po ("invalid multibyte sequence");
  anything else using iconv(3) on solnix (git i18n, glib, python codecs that defer to iconv) is equally affected.
## Hypothesis (not verified)
The gate proto tarball (protoUrl x86_64-gate-ac45d71fc2-20260914) was built or packed without the
usr/src/lib/iconv_modules output (or only its 32-bit, non-utf-8 part). Check the nightly log for iconv_modules
and whether proto/root_i386/usr/lib/iconv/amd64 existed before packing.
## Workaround used
pkgs.solnix.gettext links GNU libiconv (pkgs.solnix.libiconv), as nixpkgs does on non-glibc platforms.
