# pkgs/illumos/sparcv9/gate.nix -- the sparcv9 gate proto: headers, crt objects and the lib/sparcv9 + usr/lib/sparcv9 libraries of
# the illumos-gate packages of OpenIndiana Hipster 2026.04 on sun (sun4u), the bootstrap set's sparcv9 analogue of x86's proto.
# Made once with ./mk-proto-tarball.sh on sun: the 218 packages at SUNWcs's version (0.5.11-2025.0.0.21764), 1997 paths, one top
# dir, sorted, owner 0, mtime 315532800, gzip -n (two runs byte-identical). Banked floki /scratch/solnix-bank/lixu2-sparcv9/.
# Unlike x86's fetch-tarball.nix (a recursive FOD copying with host cp) the tree is Nix's own builtin:unpack-channel output, so no
# host tool touches it (drv-gate A1-A4 pass without an exemption).
# shortcut: until infra hosts the URL, add the banked tarball to the store first (`nix-store --add-fixed sha256 proto-root_sparcv9.tar.gz`
# gives this FOD's path: a fixed output depends only on name + hash); after that nothing changes.
{ }:
let
  tarball = import <nix/fetchurl.nix> {
    url = "https://s3.solnix.io/solnix-cache/ami/sparcv9-proto-oi202604-21764/proto-root_sparcv9.tar.gz";
    sha256 = "b3eb6eebdb78a5ccf2f9ac1f3d55c140e563a84b809d609cca05abc779b4796c";
  };
  tree = derivation {
    name = "illumos-sparcv9-gate-proto";
    system = "builtin";
    builder = "builtin:unpack-channel";
    src = tarball;
    channelName = "proto";
  };
in "${tree}/proto"
