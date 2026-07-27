# pkgs.illumos.sparc.gate — the Tribblix m34 sparc proto (userland + sun4u
# kernel) as a store path. MIRRORS pkgs/illumos/aarch64/gate.nix (the aarch64
# proto ingest), which in turn mirrors pkgs/illumos/gate.nix (x86_64).
#
# GATE A of docs/design-gate-derivation.md §1, PROTO-INGEST variant, sparc.
#
# The sparc proto is the sparcv9 userland extracted from the Tribblix m34
# sun4v_boot_archive (a BIG-ENDIAN SPARC UFS ramdisk — Linux's `ufs` driver reads
# it via `-o ufstype=sun`) plus the sun4u kernel, staged onto an ouch builder at:
#   /sparc/proto/root_sparc
# from the archived boot_archive
#   https://s3.solnix.io/solnix-cache/archive/sparc/sparc-m34-kernels.tar.zst
#   (kernels) + the boot_archive userland (local ~/ws/solnix-archive/sparc/).
# We INGEST that existing proto into the store (builtins.path) to feed the sparc
# world slices, exactly like the aarch64/x86_64 ingest.
#
# SPARC IS BIG-ENDIAN. All ELF under this proto is ELF64 MSB SPARC V9
# (EM_SPARCV9), unlike the little-endian x86/aarch64 protos. The slicing +
# RUNPATH relocation still runs on the amd64 illumos host (cross — the host
# elfedit edits the SPARC ELF's DT_RUNPATH cross-arch), same as aarch64.
#
# TODO(S3+): re-slice from the maintainer's Ultra 45 (OpenIndiana Hipster on
# sparc) — the authoritative shipping source — once its native gate build is
# reachable. This Tribblix m34 userland is the same illumos-gate lineage and is
# what we can slice today (docs/design-sparc-riscv-qemu.md S2).

{ protoDir ? /sparc/proto/root_sparc }:

let
  proto = builtins.path {
    path = protoDir;
    name = "illumos-sparc-gate-proto-src";
  };
in
derivation {
  name = "illumos-sparc-gate-proto";
  system = builtins.currentSystem; # x86_64-solaris host; slices SPARC V9 ELF.
  builder = "/usr/bin/bash";
  # cp -a preserves symlinks (platform/sun4u/kernel/unix -> sparcv9/unix, the
  # lib/sparcv9 .so -> .so.N links), perms, and CTF sections in the sparc kernel
  # objects (no strip/fixup).
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  args = [ "-c" ''
    set -eu
    mkdir -p "$out"
    cp -a "${proto}/." "$out/"
    # sanity: sparcv9 (64-bit) libc, headers, sun4u unix + genunix.
    [ -f "$out/lib/sparcv9/libc.so.1" ]                     || { echo "FATAL: no sparcv9 proto libc" >&2; exit 1; }
    [ -f "$out/platform/sun4u/kernel/sparcv9/unix" ]        || { echo "FATAL: no sun4u unix" >&2; exit 1; }
    [ -f "$out/platform/sun4u/kernel/sparcv9/genunix" ]     || { echo "WARN: genunix not at platform/sun4u/kernel/sparcv9/genunix" >&2; }
  '' ];
}
