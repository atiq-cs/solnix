# The solnix package set, as nixpkgs' default.nix is nixpkgs'. On a solnix system
# NIX_PATH names this tree as both <solnix> and <nixpkgs> (modules/config/
# nix-channel.nix), and the root channel subscription unpacks the same tree:
#   nix-env -iA solnix.htop        nix-build '<solnix>' -A tmux
# The arguments nixpkgs takes (system, config, overlays) are accepted and ignored:
# these packages build only for x86_64-solaris, from solnix's own sources.
{ ... }: (import ./lib/host-pkgs.nix { }).solnix
