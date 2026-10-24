# fetch-tarball.nix -- builtins.fetchTarball as fixed-output derivations, the
# nixpkgs fetchzip shape, so evaluation downloads nothing.
#
# builtins.fetchTarball fetches while EVALUATING, and builtin fetchers never ask
# a substituter (NixOS/nix#4313), so every eval needed the origin server and
# ~1 GB of writable store. Here the tarball is a flat FOD (builder
# builtin:fetchurl, via <nix/fetchurl.nix>) and the unpacked tree a recursive
# FOD built from it. Eval writes two .drv files; realising either one is a
# substitution or a download at BUILD time.
#
# narHash is the NAR hash builtins.fetchTarball reported (nix-prefetch-url
# --unpack), and `name` defaults to its "source", so the tree's store path is
# the one fetchTarball gave: a FOD's path depends only on name + hash.
# `exclude` drops top-level entries (home-manager's tests/), replacing an
# eval-time builtins.path filter; narHash is then the filtered tree's hash.
{ url
, sha256                   # flat sha256 of the tarball itself
, narHash                  # recursive sha256 of the unpacked tree
, name ? "source"
, exclude ? [ ]
, system ? "x86_64-solaris"
}:

let
  tarball = import <nix/fetchurl.nix> { inherit url sha256; };
in
derivation {
  inherit name system tarball;
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin";
  exclude = builtins.concatStringsSep " " exclude;
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = narHash;
  args = [ "-c" ''
    set -eu
    # fetchTarball semantics: a single top-level directory becomes the root.
    tops=$(tar -tzf "$tarball" | grep -v '^pax_global_header$' | cut -d/ -f1 | sort -u)
    [ "$(printf '%s\n' "$tops" | wc -l)" -eq 1 ] \
      || { echo "FATAL: $tarball has more than one top-level entry" >&2; exit 1; }
    mkdir "$out"
    tar -xzf "$tarball" -C "$out" --strip-components=1 --no-same-owner
    for e in $exclude; do
      [ -e "$out/$e" ] || { echo "FATAL: exclude $e is not in the tarball" >&2; exit 1; }
      find "$out/$e" -depth -delete
    done
  '' ];
}
