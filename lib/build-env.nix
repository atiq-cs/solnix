# lib/build-env.nix — the symlink-farm merge, factored out of the systemPath
# derivation in pkgs/illumos/default.nix so BOTH the base illumos world and the
# declarative userland (modules/config/system-path.nix) build their profile the
# same way. The solnix analog of nixpkgs' pkgs.buildEnv (design §B).
#
# It is a plain `derivation` (bash builder, no nixpkgs stdenv) so it works on the
# illumos build host's classic Nix 2.3.16, exactly like the rest of pkgs/illumos.
# Each leaf in $out is a symlink INTO a component's store path, so the composed
# tree stays a thin farm over the real slices (a broken package can't drop the
# kernel — sw and systemPath are separate profiles, design §B).
#
# Arguments (a subset of nixpkgs buildEnv, only what solnix uses):
#   name                    store name of the merged profile.
#   paths                   list of store paths (derivations) to merge.
#   pathsToLink   (null)    if non-null, ONLY subtrees whose path starts with one
#                           of these prefixes ("/bin", "/lib", ...) are linked.
#                           null = link everything (the systemPath behaviour).
#   extraOutputsToInstall   accepted for nixpkgs-compat; the solnix slices are
#                           single-output plain derivations, so it is a no-op
#                           here (documented; add multi-output handling if a
#                           multi-output package ever lands). NOTE: no-op today.
#   ignoreCollisions (true) later path wins on a name clash (the slices are
#                           disjoint by design; false makes a collision FATAL).

{ mkDerivation ? null }:

# Return a function so callers do `buildEnv { name = ...; paths = ...; }`.
{
  name,
  paths,
  pathsToLink ? null,
  extraOutputsToInstall ? [ ],
  ignoreCollisions ? true,
}:

let
  # pathsToLink -> a space-separated prefix list the builder greps against the
  # leading directory of each relative path. Empty string = link everything.
  pathsToLinkArg =
    if pathsToLink == null then "" else builtins.concatStringsSep " " pathsToLink;
in
derivation {
  inherit name;
  system = builtins.currentSystem; # x86_64-solaris on the host.
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  paths = paths;
  pathsToLinkArg = pathsToLinkArg;
  ignoreCollisions = if ignoreCollisions then "1" else "";
  args = [
    "-c"
    ''
      set -eu
      mkdir -p "$out"

      # match_prefix REL : succeed if REL (a path like "bin/ls" or "lib/amd64/x")
      # is under one of the pathsToLink prefixes. Prefixes are given WITHOUT the
      # leading slash of the target (nixpkgs uses "/bin"); we compare against
      # "/REL" so "/bin" matches "bin/ls" and "/lib/amd64" matches "lib/amd64/x".
      match_prefix() {
        [ -z "$pathsToLinkArg" ] && return 0   # null -> link everything
        _rel="/$1"
        for _p in $pathsToLinkArg; do
          case "$_rel" in "$_p"|"$_p"/*) return 0 ;; esac
        done
        return 1
      }

      # symlink-merge each component into $out, preserving its subtree layout.
      # Directories are created; files/symlinks are linked to the real object in
      # the component's store path. A later component wins on a collision when
      # ignoreCollisions is set; otherwise a collision is FATAL.
      for p in $paths; do
        # create the directory skeleton first (only for dirs that will hold a
        # linked leaf; cheap to just mkdir all matching dirs).
        (cd "$p" && find . -type d) | while read -r d; do
          rel="''${d#./}"
          [ "$rel" = "." ] && continue
          match_prefix "$rel" || continue
          mkdir -p "$out/$rel"
        done
        (cd "$p" && find . \( -type f -o -type l \)) | while read -r f; do
          rel="''${f#./}"
          match_prefix "$rel" || continue
          mkdir -p "$out/$(dirname "$rel")"
          if [ -e "$out/$rel" ] || [ -L "$out/$rel" ]; then
            if [ -n "$ignoreCollisions" ]; then
              ln -sf "$p/$rel" "$out/$rel"   # later path wins
            else
              echo "FATAL: buildEnv collision at $rel ($p)" >&2
              touch "$out/.collision"
            fi
          else
            ln -s "$p/$rel" "$out/$rel"
          fi
        done
      done
      # collisions in a while-pipe subshell can't `exit` the builder; check the
      # marker after the loop (mirrors mk-illumos-component's relocfail pattern).
      [ -e "$out/.collision" ] && { echo "FATAL: buildEnv collisions (ignoreCollisions=false)" >&2; exit 1; }
      true
    ''
  ];
}
