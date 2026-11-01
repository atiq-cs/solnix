#!/usr/bin/env bash
# build-opensbi.sh -- tryit1: OpenSBI fw_jump.bin (PLATFORM=generic), from nixpkgs 08d3a975's opensbi 1.8.1 source,
# with that rev's riscv64-unknown-linux-gnu cross gcc (the one the package uses; OpenSBI needs a PIE-capable
# ld, which riscv64-none-elf's is not), run outside a nix derivation. Why not the nixpkgs package itself: its
# stdenv adds `-rpath $out/lib`, which lands in the PIE firmware as a /nix/store path (no-PII policy).
set -euo pipefail
N=github:NixOS/nixpkgs/08d3a97586f6b6343b3b5e799980773629432610
S=$(nix build --no-link --print-out-paths $N#pkgsCross.riscv64.opensbi.src)
X=$(nix build --no-link --print-out-paths $N#pkgsCross.riscv64.buildPackages.gcc | grep -v -- -man$)
B=${BUILD:-$HOME/w/opensbi}; [ ! -d $B ] || find $B -depth -delete; cp -r $S $B; chmod -R u+w $B; cd $B
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}	# a fixed build stamp, so rebuilds match
make -s PLATFORM=generic CROSS_COMPILE=$X/bin/riscv64-unknown-linux-gnu- PLATFORM_RISCV_XLEN=64 -j"$(nproc)" >/dev/null
ls -l build/platform/generic/firmware/fw_jump.bin
