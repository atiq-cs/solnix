#!/usr/bin/env bash
# package.sh <date> <bundle parent dir> <out dir> -- tryit1: MANIFEST.txt + inner SHA256SUMS into the bundle, then a
# reproducible tarball (sorted, owner 0, fixed mtime, gzip -n) and its SHA256SUMS + MANIFEST.txt beside it.
# Env: SRC_COMMIT (base commit + diff description), KERNEL_ELF, ROOT_IMG.
set -euo pipefail
D=$1; P=$2; O=$3; B=$P/solnix-wasm-demo; mkdir -p $O
sha() { sha256sum "$1" | cut -d' ' -f1; }
cat > $B/MANIFEST.txt <<M
Solnix riscv64 browser demo bundle $D, built by the solnix build team from source.
source   ${SRC_COMMIT:?}
         build: src/riscv/tryit (README.md; all.sh $D on an x86_64 Linux host with nixpkgs 08d3a975)
login    root, no password
kernel   uts/unix-demo (built -DSOLNIX_DEMO), ELF sha256 $(sha "${KERNEL_ELF:?}")
         in images/$D/fw_payload.bin at 0x200000 as objcopy -O binary, sha256 $(sha $HOME/w/img/kernel.bin)
opensbi  v1.8.1 fw_jump (PLATFORM=generic; nixpkgs 08d3a975 source, riscv64-unknown-linux-gnu gcc 15.3.0),
         the first 2 MiB of fw_payload.bin, sha256 of fw_jump.bin $(sha $HOME/w/opensbi/build/platform/generic/firmware/fw_jump.bin)
root     ustar, $(tar tf "${ROOT_IMG:?}" | wc -l) names: dash 0.5.12, sbase c546c3a, less 668, minigzip (zlib 1.3.2); newlib 4.5.0;
         riscv64-none-elf gcc 14.4.0. root.img sha256 $(sha "$ROOT_IMG"), split into images/$D/disk/ (128 KiB blocks)
emulator TinyEMU 2019-12-21 + tinyemu-solnix-20260818.patch + tinyemu-solnix-20261031.patch (build.sh here),
         emscripten $(emcc --version | head -1 | sed 's/.*) //') (nixpkgs 08d3a975): emu/tinyemu-solnix-$D.{js,wasm}
page     index.html and vendor/xterm.{js,css} (xterm.js 5.3.0) as in the 2026-10-31 bundle, file names and the
         status line updated.
M
( cd $P && find solnix-wasm-demo -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs sha256sum > solnix-wasm-demo/SHA256SUMS )
( cd $P && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="${D:0:4}-${D:4:2}-${D:6:2} 00:00Z" -cf - solnix-wasm-demo ) \
	| gzip -9 -n > $O/solnix-riscv64-wasm-demo.tar.gz
cp $B/MANIFEST.txt $O/MANIFEST.txt
( cd $O && sha256sum solnix-riscv64-wasm-demo.tar.gz > SHA256SUMS && cat SHA256SUMS )
