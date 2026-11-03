#!/usr/bin/env bash
# test-boot-brand.sh -- the committed loader brand image is what src/boot-brand/art.nix makes, and the loader can draw it.
# pnglite (the loader's PNG reader) takes only 8-bit, non-interlaced, truecolour+alpha for term-putimage; the height must
# stay 528 (the stock illumos-brand.png's) and no tIME/tEXt chunk may make it depend on when it was built.
# Builds on x86_64-linux with the flake's nixpkgs-host pin (not on an illumos host, which has no rsvg).
# SOLNIX_BRAND_NOBUILD=1 skips the rebuild and checks only the file.
set -eu
cd "$(dirname "$0")/.."
PNG=src/boot-brand/boot/solnix-brand.png
python3 - "$PNG" <<'EOF' || exit 1
import struct, sys
d = open(sys.argv[1], 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
w, h, depth, ctype, _, _, il = struct.unpack('>IIBBBBB', d[16:29])
pos, chunks = 8, []
while pos < len(d):
    n, t = struct.unpack('>I4s', d[pos:pos+8]); chunks.append(t.decode()); pos += 12 + n
bad = [c for c in chunks if c not in ('IHDR', 'IDAT', 'IEND')]
ok = depth == 8 and ctype == 6 and il == 0 and h == 528 and not bad
print(f"{'PASS' if ok else 'FAIL'}  {sys.argv[1]}: {w}x{h} depth {depth} colour type {ctype} interlace {il} extra chunks {bad}")
sys.exit(0 if ok else 1)
EOF
[ -n "${SOLNIX_BRAND_NOBUILD:-}" ] && exit 0
rev=$(python3 -c 'import json; print(json.load(open("flake.lock"))["nodes"]["nixpkgs-host"]["locked"]["rev"])')
out=$(nix build --no-link --print-out-paths --impure --expr \
  "import ./src/boot-brand/art.nix { pkgs = (builtins.getFlake \"github:NixOS/nixpkgs/$rev\").legacyPackages.x86_64-linux; }")
if cmp -s "$out" "$PNG"; then echo "PASS  $PNG is byte-identical to art.nix's output ($out)"
else echo "FAIL  $PNG differs from art.nix's output $out: copy it in, or fix art.nix"; exit 1; fi
