# fetch-tarball.nix -- builtins.fetchTarball as fixed-output derivations, the
# nixpkgs fetchzip shape, so evaluation downloads nothing.
#
# builtins.fetchTarball fetches while EVALUATING, and builtin fetchers never ask
# a substituter (NixOS/nix#4313), so every eval needed the origin server and
# ~1 GB of writable store. Here the tarball is a flat FOD (builder
# builtin:fetchurl, via <nix/fetchurl.nix>) and the unpacked tree a recursive
# FOD built from it. Eval writes three .drv files; realising the tree is a
# substitution or a download + unpack at BUILD time.
#
# narHash is the NAR hash builtins.fetchTarball reported (nix-prefetch-url
# --unpack), and `name` defaults to its "source", so the tree's store path is
# the one fetchTarball gave: a FOD's path depends only on name + hash.
# `exclude` drops top-level entries (home-manager's tests/), replacing an
# eval-time builtins.path filter; narHash is then the filtered tree's hash.
#
# The unpack is Nix's own (builtin:unpack-channel: libarchive, in the daemon),
# the same unpacker fetchTarball and nix-prefetch-url --unpack use, so no host
# tar or gzip is read. The old builder ran host `tar -xzf`: on a solnix system
# (no /usr/gnu) that is illumos tar, which execs /usr/bin/gzcat, finds none,
# and EXITS 0 having extracted nothing -- an empty $out (NAR sha256-pQpattmS...,
# 96 bytes) and a hash mismatch on every host without the OI gzip package.
# unpack-channel puts the single top-level directory at $tree/tree (and fails
# unless there is exactly one); the FOD copies that up to $out with the base
# system's cp, the step fetchTarball does internally. Cost: the unpacked tree is
# in the store twice until GC collects $tree (a build-time-only input).
{ url
, sha256                   # flat sha256 of the tarball itself
, narHash                  # recursive sha256 of the unpacked tree
, name ? "source"
, exclude ? [ ]
, system ? "x86_64-solaris"
}:

let
  tarball = import <nix/fetchurl.nix> { inherit url sha256; };
  tree = derivation {
    name = "${name}-unpacked";
    system = "builtin";
    builder = "builtin:unpack-channel";
    src = tarball;
    channelName = "tree";
  };
in
derivation {
  inherit name system tree;
  builder = "/usr/bin/bash";
  PATH = "/usr/bin";
  exclude = builtins.concatStringsSep " " exclude;
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = narHash;
  args = [ "-c" ''
    set -eu
    shopt -s dotglob nullglob
    [ -d "$tree/tree" ] || { echo "FATAL: the tarball's single top-level entry is not a directory" >&2; exit 1; }
    for e in $exclude; do
      case $e in */*) echo "FATAL: exclude $e: only top-level entries can be excluded" >&2; exit 1 ;; esac
      [ -e "$tree/tree/$e" ] || [ -L "$tree/tree/$e" ] \
        || { echo "FATAL: exclude $e is not in the tarball" >&2; exit 1; }
    done
    mkdir "$out"
    for p in "$tree"/tree/*; do
      b=''${p##*/}
      case " $exclude " in *" $b "*) continue ;; esac
      cp -RP "$p" "$out/" 2>"$TMPDIR/cp.err" || { cat "$TMPDIR/cp.err" >&2; exit 1; }
      # illumos cp lchowns each copied symlink to its source owner (root) and warns
      # EPERM as nixbld (exit 0); ownership is not in a NAR, so drop just that line.
      grep -v 'cannot change owner and group of' "$TMPDIR/cp.err" >&2 || :
    done
  '' ];
}
