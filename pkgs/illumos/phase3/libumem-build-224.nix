# libumem-build-224.nix — standalone driver: build pkgs/illumos/libumem.nix
# against the 2.24 tranche's x86_64-solaris stdenv + autotools + fetchers.
# No fork by-name surgery needed; mirrors how the standalone world builds.
{ tranche ? /root/tranche-224.nix
, libumemNix ? /root/libumem.nix
}:
let
  pkgs = import tranche { };
in
pkgs.callPackage libumemNix { }
