# aarch64/a64r-pkgs.nix -- x86-served recipes that also build on aarch64 (a64r, 2026-11-03), from the SAME recipe files, called
# with the store-only aarch64 mkSrcPkg (per-recipe aarch64 fixes: ./default.nix perPkg). The plain data drvs (desktop/data.nix,
# desktop/cosmic-data.nix, cosmic-wallpapers, solnix-help) are x86 drvs: `retarget` builds the same text on aarch64 through
# ./tools.nix's plain (store PATH, seed bash, path gate). Final stage only. Not here: go and cargo (no aarch64-illumos target
# upstream), python3 and what needs it (cli/c-dev.nix links graphics.libffi/expat; next batch), the .zip data (python3 zipfile).
{ srcPkgs, homePkgs, a64, final, system, sshWorld, screenWorld }:
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
  # dbus links libbsm (ADT audit; x86: the whole world). aarch64's gate-libs-home lacks it, and adding it would move every row that
  # links world: its own gate-libs set instead (as ./src.nix's gateLibs for htop), passed to dbus alone.
  dbusWorld = srcPkgs.mkGateLibs "illumos-gate-libs-dbus" "libbsm.so.1";
  glibsD = import ../graphics/libs.nix { inherit mkSrcPkg zlib; tools = gtoolsS; inherit (base) pkgconf; world = dbusWorld; };
  # desktop/gtk/tools.nix (meson 1.10.2 on the store python3, gperf, nasm, ninja) and gtk/base.nix (libpng, pcre2, ...), as
  # desktop/gtk/default.nix wires them (its own mkSrcPkg wrapper adds gtkTools = x86 GNU binutils; aarch64's store set has none)
  # bash: meson's #! (wave6 96e489b: #!/usr/bin/bash is a gate B9 FAIL on any arch); the aarch64 store bash, as tools.nix's farm
  gtkTools = import ../desktop/gtk/tools.nix { mkSrcPkg = mkCores; inherit (cli) python3 gnupatch; inherit (gtools) samurai; inherit (base) pkgconf gettext;
    inherit (srcPkgs) bash; };
  # tools.path stays ':' (b1's libpng text interpolates it, so its row stays put); mesonBuild sets the meson PATH itself, and the farm has pkg-config
  gtkBase = import ../desktop/gtk/base.nix { mkSrcPkg = mkCores; inherit zlib; tools = gtkTools // { path = ":"; }; inherit (cli) python3 cmake;
    graphics = glibs; inherit (srcPkgs) nixChain; noto-sans = cosmicData'.noto-sans; };
  # graphics/input.nix's pixman, and desktop/gtk/gfx.nix's cairo/pango/gdk-pixbuf (graphics = pixman only; no mesa/wayland on aarch64)
  gtkGfx = import ../desktop/gtk/gfx.nix { mkSrcPkg = mkCores; tools = gtkTools; inherit zlib; base = gtkBase; inherit (srcPkgs) nixChain;
    inherit (base) libxml2; graphics = glibs // { inherit (ginputS) pixman; inherit (glibsD) dbus; inherit (glibsS) wayland wayland-protocols; }; };
  mesaSet = import ./mesa.nix { mkSrcPkg = mkCores; tools = gtkTools; inherit zlib; inherit (cli) python3; bison = final.bison; inherit (homePkgs) flex;
    inherit (glibs) expat libffi; inherit (glibsS) wayland wayland-protocols libdrm; };
  # gfx.nix again with mesa and libxkbcommon for libepoxy/gtk3 only: cairo/pango/... ignore both, so b3's rows (gtkGfx) do not move
  gtkGfxM = import ../desktop/gtk/gfx.nix { mkSrcPkg = mkCores; tools = gtkTools; inherit zlib; base = gtkBase; inherit (srcPkgs) nixChain;
    inherit (base) libxml2; graphics = glibs // { inherit (ginputS) pixman libxkbcommon; inherit (glibsD) dbus; inherit (glibsS) wayland wayland-protocols libdrm;
      inherit (mesaSet) mesa; }; };
  # solnix-torrent.nix's libtorrent-rasterbar (the community seeder's client library): the set's openssl, nixChain's boost (headers)
  torrent = import ../solnix-torrent.nix { inherit mkSrcPkg; inherit (srcPkgs) openssl gccWrapper; inherit (srcPkgs.nixChain) boost; inherit (cli) cmake;
    inherit (base) pkgconf; binutils = null; gcc = null; gate = null; libc = null; inherit system; };
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
  # batch 2 (a64r b2): python3 and the C tier that needs no meson. Not yet: bdwgc (gcconfig.h: __aarch64__ on a non-Linux/BSD OS is NOSYS, no UNIX_LIKE: a port, then w3m), screen (b7: its own gate libs),
  # whisper-cpp (x86 SIMD flags), lsof
  # (builds with ./default.nix's ARCH64B + zlib fixes, but its in-build `lsof -p $$` needs kvm_open of /dev/kmem, which nixbld on
  # dixa may not open: "kvm_open ... Permission denied". A host permission; held, not worked around)
  inherit (cli) python3 tcl groff texinfo hunspell pinentry-curses fmt catch2_3;
  # libdb1: libdb 2026.10.7.2 (Oracle Berkeley DB 5.3.28's replacement), from cli/c-libdb.nix, on the fixed tcl (its test suite)
  inherit (cli) libdb berkeleydb;
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
  inherit (glibsD) dbus; illumos-gate-libs-dbus = dbusWorld;
  inherit (gtkGfx) at-spi2-core;
  # batch 7 (a64r b7)
  inherit (gtkGfx) grim;
  inherit (torrent) libtorrent-rasterbar;
  inherit (cli) screen; illumos-gate-libs-screen = screenWorld;
  # a64s batch 2: bdwgc (ported: ./bdwgc-aarch64-illumos.patch, its suite in the build, ./default.nix perPkg), then w3m on it
  inherit (cli) bdwgc w3m;
  # a64s batch 3: mesa, software only (./mesa.nix: gallium swrast, EGL/GBM/GLES2), on b4's wayland/libdrm and gtk's meson
  inherit (mesaSet) mesa packaging mako markupsafe;   # the three python build tools get rows too (a fresh builder substitutes them)
  inherit (gtkGfxM) libepoxy gtk3;   # desktop/gtk/gfx.nix's, on ./mesa.nix (x86: graphics' iris mesa)
  # a64s batch 4: nspr (ported: ./default.nix perPkg, two patches, its own test suite in the build), then nss on it
  inherit (base) nspr nss;
  # batch 6 (a64r b6): more of the C tier (cli/, base-src)
  inherit (cli) lynx neomutt;
  inherit (base) openssh; illumos-gate-libs-ssh = sshWorld;
  # cli/c-recipes2.nix's dictionary is a plain x86 drv (store coreutils + python3 zipfile + hunspell's check): aarch64 builder and tools
  hunspell-dict-en-us = derivation (a64.plain (cli.hunspell-dict-en-us.drvAttrs // { inherit system; }));
  inherit (ginputS) xkeyboard-config libxkbcommon libdisplay-info seatd;
  inherit (base) smartmontools libxml2;   # libxml2: on the set's zlib (./default.nix perPkg)
  inherit (desk) xdg-utils xdg-user-dirs;
  solnix-help = derivation (a64.plain (desk.solnix-help.drvAttrs // { inherit system; }));
} // builtins.mapAttrs (_: retarget) {
  inherit (desk) sound-theme-freedesktop adwaita-icon-theme dejavu-fonts liberation-fonts noto-fonts-color-emoji cosmic-wallpapers;
  inherit (cosmicData) open-sans hicolor-icon-theme pop-icon-theme cosmic-icons;
}
