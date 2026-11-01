#!/usr/bin/env bash
# mk-bundle.sh <date YYYYMMDD> <images dir> <wasm js dir> <dest> -- tryit1: the solnix.io/tryit bundle with new
# file names (the site caches /tryit/emu and /tryit/images for a week): emu/tinyemu-solnix-<date>.{js,wasm},
# images/<date>/. index.html + vendor/xterm.* (xterm.js 5.3.0, MIT) come from the 2026-10-31 bundle (VENDOR=).
set -euo pipefail
D=$1; I=$2; J=$3; B=$4/solnix-wasm-demo; R="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$B/emu" "$B/images/$D/disk" "$B/vendor"
cp "$J/tinyemu-solnix-$D.js" "$J/tinyemu-solnix-$D.wasm" "$B/emu/"
cp "$I/fw_payload.bin" "$I/solnix.cfg" "$B/images/$D/"; cp "$I"/disk/blk* "$B/images/$D/disk/"
cp "${VENDOR:?}"/vendor/xterm.js "${VENDOR}"/vendor/xterm.css "$B/vendor/"
sed -e "s|images/[0-9]\{8\}/solnix.cfg|images/$D/solnix.cfg|; s|emu/tinyemu-solnix-[0-9]\{8\}.js|emu/tinyemu-solnix-$D.js|" \
    -e 's|"Booting Solnix (the kernel runs its self-tests first; the login: "|"Booting Solnix: log in as root, no password. "|' \
    -e 's|+ "prompt appears after the boot log)."|+ "(the login: prompt appears in a few seconds)."|' \
    -e 's|" and disk; the login: prompt appears after the kernel self-test log)"|" and disk; then log in as root, no password)"|' \
    "$VENDOR/index.html" > "$B/index.html"
cp "$R/tinyemu/tinyemu-solnix-20260818.patch" "$R/tinyemu/tinyemu-solnix-20261031.patch" "$R/tinyemu/build.sh" "$B/"
echo "bundle: $B"
