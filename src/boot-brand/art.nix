# The loader brand image, boot/solnix-brand.png: "Solnix" in Jost Light (a Futura-like geometric sans, the closest store
# font to the stock wordmark's face) in the stock illumos-brand.png's colour (#e2e0e3) and height (528 px; ascender top at
# y=17, glyphs 493 px tall like the stock "l"), then the solnix logo (favicon.svg) to its right, at the same height.
# brand-solnix.4th draws it 7 text rows tall, width by aspect, as the stock brand is drawn, so the menu does not move.
# Built on x86_64-linux from the nixpkgs-host pin (no rsvg on illumos) by scripts/test-boot-brand.sh. The output is
# committed as boot/solnix-brand.png, because the toplevel is x86_64-solaris and cannot depend on a linux build;
# scripts/test-boot-brand.sh checks the committed file against this derivation.
{ pkgs }:
pkgs.runCommand "solnix-boot-brand-png" { nativeBuildInputs = [ pkgs.imagemagick pkgs.librsvg ]; } ''
  set -eu
  magick -background none -fill '#e2e0e3' -font ${pkgs.jost}/share/fonts/truetype/Jost-300-Light.ttf -pointsize 632 \
    label:Solnix -trim +repage text.png
  th=$(magick identify -format %h text.png); tw=$(magick identify -format %w text.png)
  rsvg-convert -h "$th" ${./favicon.svg} -o logo.png
  lw=$(magick identify -format %w logo.png); gap=$((th / 5))
  # all ancillary chunks out (no tIME/tEXt/gAMA), PNG32 = 8-bit RGBA non-interlaced: pnglite's only truecolour form.
  magick -size $((17 + tw + gap + lw + 17))x528 xc:none text.png -geometry +17+17 -composite \
    logo.png -geometry +$((17 + tw + gap))+17 -composite -define png:exclude-chunks=all PNG32:$out
''
