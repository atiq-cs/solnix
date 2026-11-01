# desktop/data.nix -- data-only desktop packages NixOS's cosmic module and a NixOS desktop install (sound theme, icons,
# fonts) that solnix lacked (cosmic8 gap table). Each is unpacked and copied, nothing compiled; hashes are nixpkgs 26.05's
# where nixpkgs fetches the same file. A guard fails a build that installs nothing.
{ }:
let
  fetchurl = import <nix/fetchurl.nix>;
  data = name: url: sha256: script: derivation {
    inherit name; system = "x86_64-solaris"; builder = "/usr/bin/bash";
    src = fetchurl { inherit url sha256; };
    PATH = "/usr/gnu/bin:/usr/bin";
    args = [ "-c" ''
      set -eu; mkdir w; cd w
      case "$src" in *.ttf) cp "$src" ./"''${src##*-}" ;; *.tar.bz2) bzip2 -dc "$src" | tar xf - ;; *.tar.xz) xz -dc "$src" | tar xf - ;; *) gzip -dc "$src" | tar xf - ;; esac
      ${script}
      n=$(find "$out" -type f | wc -l); [ "$n" -gt 0 ] || { echo "FATAL: ${name}: empty" >&2; exit 1; }
      echo "${name}: $n files" >&2
    '' ];
  };
  fonts = dir: ''mkdir -p "$out/share/fonts/${dir}"; install -m0444 -t "$out/share/fonts/${dir}" '';
in {
  # NixOS xdg.sounds (the cosmic module: "Required for cosmic-osd"): the freedesktop sound theme, share/sounds/freedesktop.
  sound-theme-freedesktop = data "sound-theme-freedesktop-0.8"
    "https://people.freedesktop.org/~mccann/dist/sound-theme-freedesktop-0.8.tar.bz2"
    "cb518b20eef05ec2e82dda1fa89a292c1760dc023aba91b8aa69bafac85e8a14" ''
      cd */; d="$out/share/sounds/freedesktop"; mkdir -p "$d/stereo"
      sed -e 's/^_Name=/Name=/' index.theme.in > "$d/index.theme"; install -m0444 stereo/*.oga "$d/stereo/"
      [ "$(ls "$d/stereo" | wc -l)" -ge 20 ] || { echo "FATAL: sound files missing" >&2; exit 1; }
    '';
  # adwaita-icon-theme 50 (the cosmic module installs it; GTK/most apps fall back to it): meson's install = copy Adwaita/
  # (cursors too, as non-Windows meson does) + index.theme, and the one link meson adds.
  adwaita-icon-theme = data "adwaita-icon-theme-50.0"
    "https://download.gnome.org/sources/adwaita-icon-theme/50/adwaita-icon-theme-50.0.tar.xz"
    "fac6e0401fca714780561a081b8f7e27c3bc1db34ebda4da175081f26b24d460" ''
      cd */; d="$out/share/icons/Adwaita"; mkdir -p "$d"
      cp -R Adwaita/. "$d/"; install -m0644 index.theme "$d/index.theme"
      ln -s ../places/folder.svg "$d/scalable/status/folder-open.svg"
      [ -f "$d/scalable/places/folder.svg" ] && [ -d "$d/cursors" ] || { echo "FATAL: Adwaita tree incomplete" >&2; exit 1; }
    '';
  # NixOS fonts.enableDefaultPackages (graphical-desktop): dejavu, liberation, the emoji font (+ the Noto/Open Sans set).
  dejavu-fonts = data "dejavu-fonts-2.37"
    "https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.tar.bz2"
    "fa9ca4d13871dd122f61258a80d01751d603b4d3ee14095d65453b4e846e17d7" "${fonts "truetype"} */ttf/*.ttf";
  liberation-fonts = data "liberation-fonts-2.1.5"
    "https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz"
    "7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0" "${fonts "truetype"} */*.ttf";
  # the CBDT colour font itself, as built by the release (nixpkgs rebuilds it from the same tag's PNGs).
  noto-fonts-color-emoji = data "noto-fonts-color-emoji-2.051"
    "https://github.com/googlefonts/noto-emoji/raw/v2.051/fonts/NotoColorEmoji.ttf"
    "72a635cb3d2f3524c51620cdde406b217204e8a6a06c6a096ff8ed4b5fd6e27b" "${fonts "noto"} *.ttf";
}
