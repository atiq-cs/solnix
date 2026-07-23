# modules/nixos-compat.nix — systemd.* accept-and-ignore stubs.
#
# Upstream nixpkgs modules pulled by reference (roadmap T1.10, extPath) reference
# systemd.* and friends. Those options must EXIST and TYPE-CHECK so evaluation
# succeeds — without pulling any systemd semantics. This is Tier 1 from
# docs/design-smf-init.md §4.1: declare the option, do nothing with the value.
#
# Grow lazily (design note D4, T1.9): stub only what an actually-evaluated module
# touches. The list below is the minimum Tier-1 set. Add a leaf here only when a
# newly-pulled module hard-fails on it — ponytail, no speculative stubs.

{ lib, ... }:

let
  inherit (lib) mkOption types;

  # A submodule that swallows any attrs assigned to it without modelling the
  # fields. This is the load-bearing idiom: `systemd.services.foo.bar = ...` for
  # any bar must not throw. types.attrs is fully permissive on values; wrapping
  # each service in a freeform submodule lets a name-keyed attrset accept
  # arbitrary sub-options. §4.1.
  ignoredUnit = types.submodule {
    freeformType = types.attrs;
  };
in
{
  options.systemd = {
    # The big one: swallow whole systemd.services.* without modelling it.
    services = mkOption {
      type = types.attrsOf ignoredUnit;
      default = { };
      description = "IGNORED compat stub (solnix uses SMF). See nixos-compat.nix.";
    };

    # Other common unit maps upstream modules populate. Same treatment.
    sockets = mkOption {
      type = types.attrsOf ignoredUnit;
      default = { };
      description = "IGNORED compat stub. See nixos-compat.nix.";
    };
    timers = mkOption {
      type = types.attrsOf ignoredUnit;
      default = { };
      description = "IGNORED compat stub. See nixos-compat.nix.";
    };
    targets = mkOption {
      type = types.attrsOf ignoredUnit;
      default = { };
      description = "IGNORED compat stub. See nixos-compat.nix.";
    };
    mounts = mkOption {
      type = types.listOf ignoredUnit;
      default = [ ];
      description = "IGNORED compat stub. See nixos-compat.nix.";
    };

    # Frequently-referenced scalar/leaf options.
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "IGNORED compat stub. See nixos-compat.nix.";
    };
    tmpfiles.rules = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "IGNORED compat stub. See nixos-compat.nix.";
    };
    packages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "IGNORED compat stub. See nixos-compat.nix.";
    };
    globalEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "IGNORED compat stub. See nixos-compat.nix.";
    };
  };

  # ponytail: Tier-2 (translate systemd.services -> smf.services) is deferred and
  # opt-in by design (docs/design-smf-init.md §4.1). The honest path for a
  # nontrivial service is a hand-port to smf.services.*, not auto-translation.
}
