#!/usr/bin/env bash
# run-build.sh — build the R-P8 solnix riscv64 userland ELFs + kernel inside the
# riscv64 cross toolchain nix shell. Order matters: build-user.sh regenerates
# user_elfs.h (the embedded init/sh/hello/echo/cat ELFs) that the kernel embeds,
# then build-unix.sh builds + boots `unix`.
set -euo pipefail
cd "$(dirname "$0")"
exec nix shell \
  'nixpkgs#pkgsCross.riscv64-embedded.buildPackages.gcc' \
  'nixpkgs#pkgsCross.riscv64-embedded.buildPackages.binutils' \
  -c bash -c 'set -e; bash ./user/build-user.sh; bash ./build-unix.sh "$@"' _ "$@"
