# 0011-libld-reloc-sort-symndx.patch: why it is in scripts/patches but in no `patches` list

The patch fixes illumos ld's output-relocation order. It is carried here, but NOT applied by any derivation yet:

- `kernel-nd.nix` builds only the kernel, which ld's sort does not touch.
- The userland link editor (`pkgs/illumos/default.nix` `ld`, gcc's `--with-ld`) comes from the PREBUILT gate proto
  FOD (`gate.nix` protoUrl). A patched libld means a new proto (or a libld-only replacement in the banked proto, the
  aarch64 static-TLS way: `src/aarch64-arm64-gate-patches/static-tls-20261029/bh-proto.sh`).

It changes `.SUNW_reloc` in nearly every dynamic object (measured: jq 2/2, harfbuzz 7/8, openssl 6/7,
librustc_driver), and moves every x86 drv through the proto -> slices -> gcc chain. Maintainer ruling 2026-11-05: it
lands together with the next full rebuild (the bootstrap-tools wave that rebuilds the gate proto), not alone.

When that wave builds the proto: apply this patch to the gate source with the same `patch -p1 --fuzz=0` loop
`kernel-nd.nix` uses (it applies at pin ac45d71 and at illumos master b5661487), then check
`elfdump -r` of any linked .so: the non-RELATIVE relocations are in output-symbol-index order within each NEEDED run.
Evidence and the upstream drafts: floki /scratch/solnix/libld1/ (HANDOFF.md, DESIGN.md, upstream/).
