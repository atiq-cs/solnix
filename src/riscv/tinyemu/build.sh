#!/usr/bin/env bash
# build.sh [native|wasm|both] -- TinyEMU for the solnix riscv64 browser demo, from Bellard's 2019-12-21
# release plus our two patches, on a Linux host. Output in $BUILD (default ./build):
#   native: temu + splitimg (the boot-test proxy and the disk splitter)
#   wasm:   js/$OUT.{js,wasm} via build-wasm.sh with emcc (nixpkgs emscripten 5.0.6 is what we ship)
# Patches: tinyemu-solnix-20260818.patch (qemu-virt map: ns16550 UART, PLIC/CLINT/virtio addresses, FDT,
# the CSRs OpenSBI v1.8.1 reads, the browser glue) and tinyemu-solnix-20261031.patch (from solnix.io infra:
# PLIC enable/priority/threshold per context, virtio-blk IOERR past the end of the disk, build-wasm.sh OUT=).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; WHAT="${1:-both}"
URL=https://bellard.org/tinyemu/tinyemu-2019-12-21.tar.gz
SHA=be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555
BUILD="${BUILD:-$PWD/build}"; mkdir -p "$BUILD"; cd "$BUILD"
[ -f tinyemu-2019-12-21.tar.gz ] || curl -sSfL -o tinyemu-2019-12-21.tar.gz "$URL"
echo "$SHA  tinyemu-2019-12-21.tar.gz" | sha256sum -c -
[ ! -d tinyemu-solnix ] || find tinyemu-solnix -depth -delete
tar xzf tinyemu-2019-12-21.tar.gz && mv tinyemu-2019-12-21 tinyemu-solnix && cd tinyemu-solnix
for p in "$HERE"/tinyemu-solnix-20260818.patch "$HERE"/tinyemu-solnix-20261031.patch; do patch -s -p1 < "$p"; done
if [ "$WHAT" != wasm ]; then
	make -j"$(nproc)" CC="${CC:-gcc}" temu splitimg >/dev/null
	ls -l temu splitimg
fi
if [ "$WHAT" != native ]; then
	echo "emcc: $(emcc --version | head -1)"
	OUT="${OUT:-riscvemu64-wasm}" sh build-wasm.sh >/dev/null
	ls -l js/"${OUT:-riscvemu64-wasm}".*
fi
