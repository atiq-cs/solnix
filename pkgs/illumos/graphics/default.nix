# graphics/ -- the Wayland + Mesa userland as from-source derivations
# (mk-src-pkg.nix), the userland half of the X1 GPU work. Exposed as
# pkgs.solnix.{wayland,wayland-protocols,libdrm,mesa,...} and
# packages.x86_64-solaris.*. See docs/x1-desktop-userland.md.
{ mkSrcPkg, pkgconf, zlib }:
let
  tools = import ./tools.nix { inherit mkSrcPkg; };
  libs = import ./libs.nix { inherit mkSrcPkg tools pkgconf zlib; };
  input = import ./input.nix { inherit mkSrcPkg tools pkgconf; };
in
libs // input // {
  inherit (tools) meson samurai;
  mesa = import ./mesa.nix ({ inherit mkSrcPkg tools pkgconf zlib; } // {
    inherit (libs) expat libffi wayland wayland-protocols libdrm;
  });
}
