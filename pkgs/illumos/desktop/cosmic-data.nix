# desktop/cosmic-data.nix -- the fonts and icon themes COSMIC defaults to (moved here from graphics/cosmic-data.nix, which
# graphics/cosmic.nix's fixups = ./. hashes into every COSMIC app), built with STORE tools only, so a solnix host (no /usr/gnu,
# no unzip, no GNU install, illumos tar that execs the absent /usr/bin/gzcat) rebuilds them bit for bit (NixOS: fetchurl +
# stdenv's store tools). The scripts are graphics/cosmic-data.nix's. Unpack: GNU tar from the seed tools (auto-decompresses
# through the seed gzip/xz), zip through the store python3's zipfile (NixOS uses store unzip; no from-source unzip here yet).
{ fetchurl, src, tools, world, python3 }:
let
  # data <name> <src> <script>: unpack $src into the build dir, run script, out = $out.
  data = name: s: script: derivation {
    inherit name tools world python3; system = "x86_64-solaris"; builder = "/usr/bin/bash"; src = s;
    args = [ "-c" ''
      set -eu; export PATH="$tools/bin:$world/bin:$world/usr/bin"; mkdir w; cd w
      case "$src" in *.zip) "$python3/bin/python3" -m zipfile -e "$src" . ;; *) tar xf "$src" ;; esac
      ${script}
      n=$(find "$out" -type f | wc -l); [ "$n" -gt 0 ] || { echo "FATAL: $name: empty" >&2; exit 1; }
      echo "$name: $n files" >&2
    '' ];
  };
  fonts = dir: ''mkdir -p "$out/share/fonts/${dir}"; install -m0444 -t "$out/share/fonts/${dir}" '';
in rec {
  open-sans = data "open-sans-1.11" (fetchurl {
    url = "https://salsa.debian.org/fonts-team/fonts-open-sans/-/archive/debian/1.11-1/fonts-open-sans-debian-1.11-1.tar.gz";
    sha256 = "46aead7e1615f162f08ed840c935f18dbb7a20168265665b0335d9299e831849"; })
    "${fonts "truetype"} */OpenSans-*.ttf";
  # noto-fonts: the Latin/Greek/Cyrillic Sans + Sans Mono families (NixOS ships all of Noto;
  # these two are what COSMIC names). Unhinted TTF, as nixpkgs picks.
  noto-sans = data "noto-sans-2.015" (fetchurl {
    url = "https://github.com/notofonts/latin-greek-cyrillic/releases/download/NotoSans-v2.015/NotoSans-v2.015.zip";
    sha256 = "0c34df072a3fa7efbb7cbf34950e1f971a4447cffe365d3a359e2d4089b958f5"; })
    "${fonts "noto"} NotoSans/unhinted/ttf/*.ttf";
  noto-sans-mono = data "noto-sans-mono-2.014" (fetchurl {
    url = "https://github.com/notofonts/latin-greek-cyrillic/releases/download/NotoSansMono-v2.014/NotoSansMono-v2.014.zip";
    sha256 = "090cf6c5e03f337a755630ca888b1fef463e64ae7b33ee134e9309c05f978732"; })
    "${fonts "noto"} NotoSansMono/unhinted/ttf/*.ttf";
  fira-mono = data "fira-mono-3.2" (fetchurl {
    url = "https://carrois.com/downloads/Fira/Fira_Mono_3_2.zip";
    sha256 = "77b83feda1f1c5b8e8da07498aff6fa0f9d2d16bbfa2095dd7e7696c887c6128"; })
    "${fonts "opentype"} Fira_Mono_3_2/Fonts/FiraMono_OTF_32/*.otf";

  hicolor-icon-theme = data "hicolor-icon-theme-0.18" (fetchurl {
    url = "https://icon-theme.freedesktop.org/releases/hicolor-icon-theme-0.18.tar.xz";
    sha256 = "db0e50a80aa3bf64bb45cbca5cf9f75efd9348cf2ac690b907435238c3cf81d7"; })
    ''install -Dm0644 */index.theme "$out/share/icons/hicolor/index.theme"'';
  pop-icon-theme = data "pop-icon-theme-3.5.0" (fetchurl {
    name = "pop-icon-theme-3.5.0.tar.gz"; url = "https://codeload.github.com/pop-os/icon-theme/tar.gz/refs/tags/v3.5.0";
    sha256 = "917f5e300e927fe2557355717793f3284aee869a6ae0b81cd31507f20090d796"; })
    ''mkdir -p "$out/share/icons"; cp -R */Pop "$out/share/icons/"'';
  # cosmic-icons (epoch-1.5.0): the COSMIC theme; its index.theme Inherits=Pop,hicolor.
  cosmic-icons = data "cosmic-icons-1.5.0" (src "cosmic-icons" "e6caffc4c93f5afdaae3fbda4f3cc14363d3539cda1b0c5f478d32a8bb141c4c") ''
    cd */; d="$out/share/icons/Cosmic"; mkdir -p "$d"
    cp -R freedesktop/scalable "$d/"; cp -R extra/scalable/. "$d/scalable/"; install -m0644 index.theme "$d/index.theme"
  '';
}
