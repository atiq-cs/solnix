# graphics/ -- the Wayland + Mesa userland as from-source derivations
# (mk-src-pkg.nix), the userland half of the X1 GPU work. Exposed as
# pkgs.solnix.{wayland,wayland-protocols,libdrm,mesa,...} and
# packages.x86_64-solaris.*. See docs/x1-desktop-userland.md.
{ mkSrcPkg, pkgconf, zlib, world, perl ? null, hostTools ? [ ], python3 ? null, gnupatch ? null, bash ? null, cmake ? null, bison ? null }:
let
  tools = import ./tools.nix { inherit mkSrcPkg python3 gnupatch bash; };
  libs = import ./libs.nix { inherit mkSrcPkg tools pkgconf zlib world perl hostTools gnupatch python3; };
  input = import ./input.nix { inherit mkSrcPkg tools pkgconf python3 gnupatch perl bison; };
in
libs // input // {
  inherit (tools) meson samurai;
  mesa = import ./mesa.nix ({ inherit mkSrcPkg tools pkgconf zlib cmake hostTools gnupatch python3; } // {
    inherit (libs) expat libffi wayland wayland-protocols libdrm;
  });
}
