# modules/config/assertions.nix -- the `assertions` / `warnings` option surface,
# and the enforcement that makes them real.
#
# WHY THIS EXISTS: modules/config/cosmic-desktop.nix:100 and
# modules/config/wireless-iwx.nix:44 both DEFINE `assertions`, and nothing in
# solnix's module set DECLARED it. Every toplevel therefore failed to evaluate
# with `error: The option 'assertions' does not exist` -- base, pgfarm, and any
# new configuration alike. This is not a dixi-specific problem; it predates it.
#
# The declaration is the same shape as nixpkgs' nixos/modules/misc/assertions.nix
# (listOf unspecified + listOf str, both internal). Upstream splits declaration
# from ENFORCEMENT: the throw-on-failure lives in
# nixos/modules/system/activation/top-level.nix, wrapping system.build.toplevel.
# solnix does the same in modules/system/activation/default.nix, which reads
# system.assertionsChecked below.
#
# ⚠️ A DECLARATION ALONE WOULD BE WORSE THAN THE ERROR IT FIXES. Declaring the
# option without enforcing it makes every `assertions = [{ assertion = false; }]`
# in the tree silently inert -- the "guard that cannot fail" failure mode. So the
# check is wired into the toplevel, and it has a negative control: set any
# assertion's `assertion` to false and `nix eval .#<x>Toplevel` must fail with
# "Failed assertions:".

{ config, lib, ... }:

let
  inherit (lib) mkOption types filter concatStringsSep;

  failed = map (a: a.message) (filter (a: !a.assertion) config.assertions);
in
{
  options = {
    assertions = mkOption {
      type = types.listOf types.unspecified;
      internal = true;
      default = [ ];
      example = [{ assertion = false; message = "you can't enable this for that reason"; }];
      description = ''
        Conditions that must hold for this configuration to evaluate. A false
        assertion aborts evaluation of system.build.toplevel with its message.
      '';
    };

    warnings = mkOption {
      type = types.listOf types.str;
      internal = true;
      default = [ ];
      description = "Warnings shown while evaluating the configuration.";
    };

    # The value the toplevel forces to make the assertions load-bearing. It is
    # either `true` or a throw; nothing else. Kept as an option rather than a
    # let-binding inside activation/default.nix so any other build product can
    # depend on it too.
    system.assertionsChecked = mkOption {
      type = types.bool;
      internal = true;
      description = "Forced by system.build.toplevel; throws if any assertion failed.";
    };
  };

  config.system.assertionsChecked =
    if failed == [ ] then true
    else throw "\nFailed assertions:\n${concatStringsSep "\n" (map (m: "- ${m}") failed)}";
}
