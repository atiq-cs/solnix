# aarch64/a64r-pkgs.nix -- x86-served recipes that also build on aarch64 (a64r, 2026-11-03), from the SAME recipe files, called
# with the store-only aarch64 mkSrcPkg (per-recipe aarch64 fixes: ./default.nix perPkg). The plain data drvs (desktop/data.nix,
# desktop/cosmic-data.nix, cosmic-wallpapers, solnix-help) are x86 drvs: `retarget` builds the same text on aarch64 through
# ./tools.nix's plain (store PATH, seed bash, path gate). Final stage only. Not here: go and cargo (no aarch64-illumos target
# upstream), python3 and what needs it (cli/c-dev.nix links graphics.libffi/expat; next batch), the .zip data (python3 zipfile).
{ srcPkgs, homePkgs, a64, final, system }:
let
  inherit (srcPkgs) mkSrcPkg zlib;
  cli = homePkgs.cliSet; base = homePkgs.baseSet;
  gtools = import ../graphics/tools.nix { inherit mkSrcPkg; };
  glibs = import ../graphics/libs.nix { inherit mkSrcPkg zlib; tools = gtools; inherit (base) pkgconf; inherit (homePkgs) world; };
  ginput = import ../graphics/input.nix { inherit mkSrcPkg; tools = gtools; inherit (base) pkgconf; };
  # gtk/base.nix's libpng: tools.path (meson, python3, ...: not on aarch64 yet) is unused by its configure build -> ':'
  gtkBase = import ../desktop/gtk/base.nix { inherit mkSrcPkg zlib; tools = { path = ":"; }; python3 = null; inherit (cli) cmake;
    graphics = glibs; inherit (srcPkgs) nixChain; noto-sans = null; };
  # desktop/ as pkgs/illumos/default.nix wires it (data, xdg, help, cosmic-wallpapers); cargoPkg null: pop-launcher is never forced
  desk = import ../desktop { cargoPkg = null; graphics = null; fd = null; inherit mkSrcPkg; inherit (srcPkgs) bash;
    inherit (base) coreutils gnugrep gnused hostname jq hostTools; inherit (cli) file; hostfixTools = a64.buildToolsFarm; world = null; python3 = null; };
  cosmicData = import ../desktop/cosmic-data.nix { fetchurl = import <nix/fetchurl.nix>; tools = a64.buildToolsFarm; world = null; python3 = null;
    src = repo: sha256: import <nix/fetchurl.nix> {   # = pkgs/illumos/default.nix's (same FOD)
      name = "${repo}-epoch-1.5.0.tar.gz"; url = "https://codeload.github.com/pop-os/${repo}/tar.gz/refs/tags/epoch-1.5.0"; inherit sha256; }; };
  rep1 = a: b: s: let r = builtins.replaceStrings [ a ] [ b ] s; in if r == s then throw "a64r retarget: anchor not found: ${a}" else r;
  # .tar.bz2: x86 decompresses through the store python3's bz2 module; aarch64 has bzip2-bin (no python3 yet)
  pyBz2 = ''"$python3/bin/python3" -c 'import bz2, shutil, sys; shutil.copyfileobj(bz2.open(sys.argv[1]), sys.stdout.buffer)' "$src" | tar xf -'';
  retarget = d: derivation (a64.plain (removeAttrs d.drvAttrs [ "world" "python3" ] // { inherit system; tools = a64.buildToolsFarm;
    # the recipe's PATH line -> the store tools + bzip2, gated (data.nix gates it already, cosmic-data.nix does not: one gate each)
    args = map (x: if x == "-c" then x else rep1 ''export PATH="$tools/bin:$world/bin:$world/usr/bin";'' ''export PATH="$tools/bin:${final.bzip2-bin}/bin"; /usr/bin/bash ${../path-gate.sh};''
      (builtins.replaceStrings [ pyBz2 ''export PATH="$tools/bin:$world/bin:$world/usr/bin"; /usr/bin/bash ${../path-gate.sh};'' ]
        [ ''bzip2 -dc "$src" | tar xf -'' ''export PATH="$tools/bin:$world/bin:$world/usr/bin";'' ] x)) d.drvAttrs.args; }));
in
{
  inherit (cli) iana-etc mailcap tzdata mpdecimal gmp6 mpfr libmpc giflib cpio;
  inherit (glibs) expat libffi;
  inherit (ginput) hwdata;
  inherit (gtkBase) libpng;
  inherit (desk) xdg-utils xdg-user-dirs;
  solnix-help = derivation (a64.plain (desk.solnix-help.drvAttrs // { inherit system; }));
} // builtins.mapAttrs (_: retarget) {
  inherit (desk) sound-theme-freedesktop adwaita-icon-theme dejavu-fonts liberation-fonts noto-fonts-color-emoji cosmic-wallpapers;
  inherit (cosmicData) open-sans hicolor-icon-theme pop-icon-theme cosmic-icons;
}
