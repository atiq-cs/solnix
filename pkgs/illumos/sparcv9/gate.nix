# pkgs/illumos/sparcv9/gate.nix -- the sparcv9 gate proto: headers, crt objects and the lib/sparcv9 + usr/lib/sparcv9 libraries of
# the illumos-gate packages of OpenIndiana Hipster 2026.04 on sun (sun4u), the bootstrap set's sparcv9 analogue of x86's proto.
# Made once with ./mk-proto-tarball.sh on sun: the 218 packages at SUNWcs's version (0.5.11-2025.0.0.21764), 1997 paths, one top
# dir, sorted, owner 0, mtime 315532800, gzip -n (two runs byte-identical). Banked floki /scratch/solnix-bank/lixu2-sparcv9/.
# 2026-11-12: lib/sparcv9/libc.so.1 replaced by OI's own libc rebuilt with the memset_s fix (src/sparcv9-gate-patches/
# libc-respin-20261112/: same tree, compiler and flags as OI's build, the one source change; every other member byte-identical).
# Unlike x86's fetch-tarball.nix (a recursive FOD copying with host cp) the tree is Nix's own builtin:unpack-channel output, so no
# host tool touches it (drv-gate A1-A4 pass without an exemption).
# shortcut: until infra hosts the URL, add the banked tarball to the store first (`nix-store --add-fixed sha256 proto-root_sparcv9.tar.gz`
# gives this FOD's path: a fixed output depends only on name + hash); after that nothing changes.
{ }:
let
  tarball = import <nix/fetchurl.nix> {
    url = "https://s3.solnix.io/solnix-cache/ami/sparcv9-proto-oi202604-21764-memset_s/proto-root_sparcv9.tar.gz";
    sha256 = "a05663c2e5bd0747379a14d5b3dbdea6d637b8d7956dba1de89a883e25ad26f1";
  };
  tree = derivation {
    name = "illumos-sparcv9-gate-proto";
    system = "builtin";
    builder = "builtin:unpack-channel";
    src = tarball;
    channelName = "proto";
  };
in "${tree}/proto"
