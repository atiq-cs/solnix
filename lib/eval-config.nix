# lib/eval-config.nix — solnix's forked NixOS evaluator entrypoint.
#
# This is the solnix analog of NixOS's nixos/lib/eval-config.nix. In Phase 1
# (roadmap P1.3) this becomes a near-verbatim copy of that file. For now it is a
# minimal, honest evalModules call that fixes the calling convention so
# flake.nix and configurations/ have a stable entrypoint.
#
# What differs from NixOS:
#   * No systemd. The init system is SMF (modules/system/boot/init/smf.nix).
#     `systemd.*` options exist only as accept-and-ignore stubs
#     (modules/nixos-compat.nix) so unmodified upstream nixos modules evaluate.
#   * pkgs comes from the solnix nixpkgs fork (pkgs.illumos.*), not upstream.
#     Until that fork exists, evaluating a real config throws — expected.
#   * specialArgs threads the same way as NixOS (modulesPath, baseModules).
#
# Everything else (the evalModules call shape, specialArgs, the modules list)
# mirrors NixOS deliberately so its patterns transfer.

{ lib }:

{
  system ? "x86_64-solaris",
  # Extra modules the caller layers on top of the base module list.
  modules ? [ ],
  # Passed as specialArgs to every module (NixOS convention).
  specialArgs ? { },
  # pkgs is threaded in but not resolved here yet — the fork's
  # instantiated package set for `system` gets wired in P1.1/P1.3. Leaving it as
  # an arg keeps the signature stable so callers don't change when it lands.
  pkgs ? null,
}:

let
  baseModules = import ../modules/module-list.nix;

  # The set of modules evalModules sees: solnix base modules + caller modules +
  # a tiny module that pins the platform and (eventually) pkgs.
  allModules = baseModules ++ modules ++ [
    (
      { ... }:
      {
        # TODO(P1.3): expose the real option surface NixOS uses
        # (nixpkgs.system / nixpkgs.pkgs). For the skeleton we just record the
        # target system as a plain _module.args value so modules can read it.
        _module.args = {
          inherit pkgs;
          solnixSystem = system;
        };
      }
    )
  ];
in
lib.evalModules {
  modules = allModules;
  specialArgs = {
    # modulesPath lets modules import siblings by path, exactly as NixOS does.
    modulesPath = ../modules;
  } // specialArgs;
}
