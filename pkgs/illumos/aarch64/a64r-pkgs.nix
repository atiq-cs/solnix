# aarch64/a64r-pkgs.nix -- x86-served recipes that also build on aarch64 (a64r, 2026-11-03), from the SAME recipe files, called
# with the store-only aarch64 mkSrcPkg (per-recipe aarch64 fixes: ./default.nix perPkg). The plain data drvs (desktop/data.nix,
# desktop/cosmic-data.nix, cosmic-wallpapers, solnix-help) are x86 drvs: `retarget` builds the same text on aarch64 through
# ./tools.nix's plain (store PATH, seed bash, path gate). Final stage only. Not here: go and cargo (no aarch64-illumos target
# upstream), python3 and what needs it (cli/c-dev.nix links graphics.libffi/expat; next batch), the .zip data (python3 zipfile).
{ srcPkgs, homePkgs, a64, final, system }:
let
  inherit (srcPkgs) mkSrcPkg zlib;
  # dixa's nix.conf has cores = 0, so NIX_BUILD_CORES=0 and `-j''${NIX_BUILD_CORES:-8}` is gmake -j0 (fails). nixpkgs' setup.sh
  # normalizes a non-positive NIX_BUILD_CORES to the CPU count; same here, for the recipes that read it (libpng: b1's own fix).
  mkCores = a: mkSrcPkg (if a.pname == "libpng" || builtins.match ".*NIX_BUILD_CORES.*" a.build == null then a
    else a // { build = ''[ "''${NIX_BUILD_CORES:-0}" -gt 0 ] 2>/dev/null || NIX_BUILD_CORES=24'' + "\n" + a.build; });
  cli = homePkgs.cliSet; base = homePkgs.baseSet;
  gtools = import ../graphics/tools.nix { inherit mkSrcPkg; };
  glibs = homePkgs.graphicsSet;
  ginput = import ../graphics/input.nix { inherit mkSrcPkg; tools = gtools; inherit (base) pkgconf; };
  # pixman with gtk's meson 1.10.2 on the store python3 (graphics/tools.nix's meson 1.4.2 runs the host /usr/bin/python3.9), mesonBuild's -j16
  gtoolsS = gtools // { mesonBuild = f: builtins.replaceStrings [ ("-j$" + "{NIX_BUILD_CORES:-8}") ] [ "-j16" ] (gtkTools.mesonBuild f); };
  ginputS = import ../graphics/input.nix { inherit mkSrcPkg; tools = gtoolsS; inherit (base) pkgconf; };
  # graphics/libs.nix the same way (wayland, libdrm); its expat/libffi do not use mesonBuild, so they are b1's drvs
  glibsS = import ../graphics/libs.nix { inherit mkSrcPkg zlib; tools = gtoolsS; inherit (base) pkgconf; inherit (homePkgs) world; };
  # desktop/gtk/tools.nix (meson 1.10.2 on the store python3, gperf, nasm, ninja) and gtk/base.nix (libpng, pcre2, ...), as
  # desktop/gtk/default.nix wires them (its own mkSrcPkg wrapper adds gtkTools = x86 GNU binutils; aarch64's store set has none)
  gtkTools = import ../desktop/gtk/tools.nix { mkSrcPkg = mkCores; inherit (cli) python3 gnupatch; inherit (gtools) samurai; inherit (base) pkgconf gettext; };
  # tools.path stays ':' (b1's libpng text interpolates it, so its row stays put); mesonBuild sets the meson PATH itself, and the farm has pkg-config
  gtkBase = import ../desktop/gtk/base.nix { mkSrcPkg = mkCores; inherit zlib; tools = gtkTools // { path = ":"; }; inherit (cli) python3 cmake;
    graphics = glibs; inherit (srcPkgs) nixChain; noto-sans = cosmicData'.noto-sans; };
  # graphics/input.nix's pixman, and desktop/gtk/gfx.nix's cairo/pango/gdk-pixbuf (graphics = pixman only; no mesa/wayland on aarch64)
  gtkGfx = import ../desktop/gtk/gfx.nix { mkSrcPkg = mkCores; tools = gtkTools; inherit zlib; base = gtkBase; inherit (srcPkgs) nixChain;
    libxml2 = null; graphics = glibs // { inherit (ginputS) pixman; }; };
  # desktop/ as pkgs/illumos/default.nix wires it (data, xdg, help, cosmic-wallpapers); cargoPkg null: pop-launcher is never forced
  desk = import ../desktop { cargoPkg = null; graphics = null; fd = null; inherit mkSrcPkg; inherit (srcPkgs) bash;
    inherit (base) coreutils gnugrep gnused hostname jq hostTools; inherit (cli) file; hostfixTools = a64.buildToolsFarm; world = null; python3 = null; };
  cosmicData = import ../desktop/cosmic-data.nix { fetchurl = import <nix/fetchurl.nix>; tools = a64.buildToolsFarm; world = null; python3 = null;
    src = repo: sha256: import <nix/fetchurl.nix> {   # = pkgs/illumos/default.nix's (same FOD)
      name = "${repo}-epoch-1.5.0.tar.gz"; url = "https://codeload.github.com/pop-os/${repo}/tar.gz/refs/tags/epoch-1.5.0"; inherit sha256; }; };
  # the .zip fonts (cosmic-data.nix unzips with the store python3's zipfile): the same retarget, with the aarch64 python3 (b2)
  cosmicData' = builtins.mapAttrs (_: d: retarget' d (removeAttrs d.drvAttrs [ "world" ] // { inherit (cli) python3; }))
    { inherit (cosmicData) noto-sans noto-sans-mono fira-mono; };
  rep1 = a: b: s: let r = builtins.replaceStrings [ a ] [ b ] s; in if r == s then throw "a64r retarget: anchor not found: ${a}" else r;
  # .tar.bz2: x86 decompresses through the store python3's bz2 module; aarch64 uses bzip2-bin (b1's rows were built so, before python3)
  pyBz2 = ''"$python3/bin/python3" -c 'import bz2, shutil, sys; shutil.copyfileobj(bz2.open(sys.argv[1]), sys.stdout.buffer)' "$src" | tar xf -'';
  retarget = d: retarget' d (removeAttrs d.drvAttrs [ "world" "python3" ]);
  retarget' = d: attrs: derivation (a64.plain (attrs // { inherit system; tools = a64.buildToolsFarm;
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
  # batch 2 (a64r b2): python3 and the C tier that needs no meson. Not yet: bdwgc (gcconfig.h: __aarch64__ on a non-Linux/BSD OS is NOSYS, no UNIX_LIKE: a port, then w3m), screen (links the proto's
  # libcrypt/libutempter, which aarch64's gate libs lack: ldd resolved them to the host /usr/lib), whisper-cpp (x86 SIMD flags), lsof
  # (builds with ./default.nix's ARCH64B + zlib fixes, but its in-build `lsof -p $$` needs kvm_open of /dev/kmem, which nixbld on
  # dixa may not open: "kvm_open ... Permission denied". A host permission; held, not worked around)
  inherit (cli) python3 tcl groff texinfo hunspell pinentry-curses fmt catch2_3;
  inherit (gtkTools) gperf nasm; inherit (gtools) samurai;
  inherit (gtkBase) pcre2 libjpeg-turbo;
  # batch 3 (a64r b3): meson and the glib/freetype/harfbuzz tier (desktop/gtk/), on the store python3
  inherit (gtkTools) meson ninja;
  inherit (gtkBase) glib fribidi freetype harfbuzz;
  # batch 3, then: the three .zip fonts (b2's python3 unzips them), pixman, fontconfig (default fonts: noto-sans), cairo, pango, gdk-pixbuf
  inherit (cosmicData') noto-sans noto-sans-mono fira-mono;
  inherit (ginputS) pixman;
  inherit (gtkBase) fontconfig;
  inherit (gtkGfx) cairo pango gdk-pixbuf;
  # batch 4 (a64r b4): the Wayland client libraries and seat/input data (graphics/), on gtk's meson
  inherit (glibsS) wayland wayland-protocols libdrm;
  inherit (ginputS) xkeyboard-config libxkbcommon libdisplay-info seatd;
  inherit (base) smartmontools;   # not libxml2: base-src's links base-src's own zlib (abis 64+32), a 2nd zlib drv_for cannot reach
  inherit (desk) xdg-utils xdg-user-dirs;
  solnix-help = derivation (a64.plain (desk.solnix-help.drvAttrs // { inherit system; }));
} // builtins.mapAttrs (_: retarget) {
  inherit (desk) sound-theme-freedesktop adwaita-icon-theme dejavu-fonts liberation-fonts noto-fonts-color-emoji cosmic-wallpapers;
  inherit (cosmicData) open-sans hicolor-icon-theme pop-icon-theme cosmic-icons;
}
