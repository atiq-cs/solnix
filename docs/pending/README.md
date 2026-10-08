# Changes held for the next world rebuild

Each of these changes the builder text of mk-src-pkg (or another base builder),
so it changes every package hash and needs one full chain rebuild. They are
batched so that rebuild happens once.

- mk-src-pkg-guardfix.diff: the build-time-path guard fails the build when grep
  exits 2, instead of reading it as no hits. Measured on dixi: with illumos grep
  (no --binary-files) the old guard reported 0 hits on an ELF that names the gate
  proto; the new one fails it, and passes a clean output.
