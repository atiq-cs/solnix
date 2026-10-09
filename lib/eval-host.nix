# lib/eval-host.nix — classic-Nix (2.3.16) entrypoint to evaluate a solnix system
# ON the illumos build host, producing config.system.build.toplevel.
#
# WHY this exists (the eval-split, docs/design-make-be.md §7): flake.nix +
# lib/eval-config.nix are the flake-shaped entrypoints, but the host runs Nix
# 2.3.16 (classic, no flakes) and has no nixpkgs. This driver:
#   1. imports the nixpkgs `lib/` copied to the host (for lib.evalModules), and
#   2. builds the pkgs shim (lib/host-pkgs.nix: solnix.* + writers), then
#   3. calls lib/eval-config.nix with that lib + pkgs.
# So EVALUATE and BUILD both happen here (the only machine x86_64-solaris builds).
#
# Usage on the host (from /var/tmp/solnix-nix, with nixpkgs-lib/ + the repo tree):
#   nix-build lib/eval-host.nix -A toplevel
#   nix-instantiate lib/eval-host.nix -A toplevel   # just the .drv
#
# libDir / solnixDir / configModule are overridable so the same driver works
# from an in-repo checkout (defaults) or the flattened /var/tmp/solnix-nix layout.

{
  # path to the nixpkgs `lib` tree copied to the host (pure Nix; no ELF).
  libDir ? ./nixpkgs-lib/lib,
  # path to the standalone solnix world slices (pkgs/illumos).
  solnixDir ? ../pkgs/illumos,
  # An ALREADY-BUILT gate proto, as a store path. pkgs/illumos/gate.nix asserts
  # srcDir-or-srcHash, so without this every attr that touches the gate (libc,
  # rtld, base-tools, systemPath, the slices) throws when forced. On the host:
  #   nix store add-path /var/tmp/proto-unpack/<hash>-illumos-gate-proto
  # and pass the resulting store path here.
  gateProto ? null,
  # Alternatively, gate.nix's own args (srcDir/srcHash/rev) to BUILD the gate.
  gateArgs ? { },
  # the config to evaluate.
  configModule ? ../configurations/base.nix,
  system ? "x86_64-solaris",
  # the solnix git revision (the flake passes self.rev): with it the host eval
  # gives the same toplevel as `nix build .#solnixConfigurations.<x>...`, whose
  # /etc/os-release carries BUILD_ID. Without it os-release has no BUILD_ID.
  revision ? null,
}:

let
  lib = import libDir;
  pkgs = import ./host-pkgs.nix { inherit solnixDir gateProto gateArgs; };
  evalConfig = import ./eval-config.nix { inherit lib; };
  sys = evalConfig {
    inherit system pkgs;
    modules = [ configModule ] ++ lib.optional (revision != null) { solnix.revision = revision; };
  };
  makeBe = import ./make-be.nix {
    inherit pkgs;
    toplevel = sys.config.system.build.toplevel;
  };
in
{
  inherit (sys) config options;
  toplevel = sys.config.system.build.toplevel;
  activate = sys.config.system.build.activate;
  smfManifests = sys.config.system.build.smfManifests;
  etc = sys.config.system.build.etc;
  # T2.6: the root-run image assembly script (consumes the toplevel closure).
  makeBeScript = makeBe.script;
}
