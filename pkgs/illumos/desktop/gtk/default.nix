# desktop/gtk/ -- the GTK 3 / Wayland stack NixOS builds Firefox on (glib .. gtk3), plus nasm, gperf, ninja and a newer
# meson. Its own dir under desktop/ (NOT graphics/: graphics/cosmic.nix takes fixups = ./., so a file added there
# moves every COSMIC derivation). Reuses graphics' wayland/mesa/pixman/libffi/expat/dbus and cli's python3/cmake.
{ base, graphics, cli, noto-sans }:
let
  inherit (base) mkSrcPkg zlib libxml2 gettext nixChain;
  tools = import ./tools.nix { inherit mkSrcPkg gettext; inherit (cli) python3 gnupatch; inherit (graphics) samurai; inherit (base) pkgconf; };
  b = import ./base.nix { inherit mkSrcPkg tools zlib graphics nixChain; inherit (cli) python3 cmake; inherit noto-sans; };
  g = import ./gfx.nix { inherit mkSrcPkg tools zlib graphics nixChain libxml2; base = b; };
in removeAttrs b [ "ftPriv" ] // g // { inherit (tools) gperf nasm ninja; meson_1_10 = tools.meson; }
