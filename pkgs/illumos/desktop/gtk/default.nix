# desktop/gtk/ -- the GTK 3 / Wayland stack NixOS builds Firefox on (glib .. gtk3), plus nasm, gperf, ninja and a newer
# meson, grim, then Firefox's build tools (devtools.nix: nodejs, cbindgen; llvm.nix: libclang for bindgen) and Firefox
# ESR (firefox.nix). Its own dir under desktop/ (NOT graphics/: graphics/cosmic.nix takes fixups = ./., so a file added
# there moves every COSMIC derivation). Reuses graphics' wayland/mesa/pixman/libffi/expat/dbus and cli's python3/cmake.
{ base, graphics, cli, noto-sans, cargoPkg, rust, world }:
let
  inherit (base) zlib libxml2 gettext nixChain;
  # Every recipe here is store-only (mk-src-pkg nativeTools, NixOS stdenv's PATH): built on chef with the OI host PATH, they
  # took tools a solnix host lacks (gdk-pixbuf's glib-compile-resources from OI's /usr/bin, GNU install/mkdir/nm/dd/ar from
  # /usr/gnu/bin, cmake/git/unzip from /usr/bin; gtkfix audit), so dixi could not rebuild them. The PATH is the recipe's
  # nativeTools, then gtkTools, then base.hostTools (coreutils, findutils, the world), and ../../path-gate.sh fails the build on any
  # non-store entry, before and after the recipe's own build. hostTools == [] (the buildTools=[] seed instance): unchanged.
  gtkTools = derivation {
    name = "solnix-gtk-build-tools"; system = "x86_64-solaris"; builder = "/usr/bin/bash";
    inherit (base) binutils bash coreutils;
    # unprefixed GNU binutils (configure/libtool/meson/mach probe ar, nm, ranlib, strip, objcopy, readelf by these names; the
    # OI host's /usr/gnu/bin gave GNU ones) and sh -> store bash (NixOS stdenv's /bin/sh; chef's /usr/gnu/bin/sh was bash)
    args = [ "-c" ''
      set -eu; export PATH=$coreutils/bin; mkdir -p "$out/bin"; cd "$out/bin"
      for t in ar nm ranlib strip objcopy objdump readelf; do ln -s "$binutils/bin/g$t" "$t"; done
      ln -s "$bash/bin/bash" bash; ln -s "$bash/bin/bash" sh
      for t in ar nm ranlib strip objcopy objdump readelf bash sh; do [ -x "$t" ] || { echo "FATAL: $t" >&2; exit 1; }; done
    '' ];
  };
  hermetic = base.hostTools != [ ];
  mkSrcPkg = a: if !hermetic then base.mkSrcPkg (removeAttrs a [ "nativeTools" ]) else base.mkSrcPkg (a // {
    nativeTools = (a.nativeTools or [ ]) ++ [ gtkTools ] ++ base.hostTools;
    build = "/usr/bin/bash ${../../path-gate.sh}\n" + a.build + "\n/usr/bin/bash ${../../path-gate.sh}\n";
  });
  tools = import ./tools.nix { inherit mkSrcPkg gettext; inherit (cli) python3 gnupatch; inherit (graphics) samurai; inherit (base) pkgconf; };
  b = import ./base.nix { inherit mkSrcPkg tools zlib graphics nixChain; inherit (cli) python3 cmake; inherit noto-sans; };
  g = import ./gfx.nix { inherit mkSrcPkg tools zlib graphics nixChain libxml2; base = b; };
  dev = import ./devtools.nix { inherit mkSrcPkg tools cargoPkg zlib nixChain world; inherit (base) openssl; inherit (cli) python3; };
  llvm-clang = import ./llvm.nix { inherit mkSrcPkg tools world; inherit (cli) cmake python3; };
  firefox-esr = import ./firefox.nix { inherit mkSrcPkg tools cli rust llvm-clang zlib nixChain graphics world noto-sans; inherit (dev) cbindgen nodejs;
    gtk = b // g; };
in removeAttrs b [ "ftPriv" ] // g // dev // { inherit llvm-clang firefox-esr; inherit (tools) gperf nasm ninja; meson_1_10 = tools.meson; }
