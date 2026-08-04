# scratch/current-system.nix — REDUCED solnix current-system for Gate A.
#
# WHY reduced: the full system.build.toplevel symlinks pkgs.solnix.systemPath
# (kernel/libc/svc.startd from the gate proto). That proto is NOT on this OI
# host (it lived on dead accounts), and the TARGET instance already IS a
# complete bootable illumos OS — so baking the kernel into /nix would duplicate
# the running world AND is unbuildable here. Gate A only needs the DECLARATIVE
# userland layer: sw (starter pkgs) + nix + /etc wiring, laid over the already-
# bootable BE. This composes exactly that, reusing buildEnv + starter + nix.
#
# NOTE: this drops systemPath from the closure; switch-to-configuration /
# solnix-rebuild (which need the kernel-carrying toplevel) are NOT wired here.
# Restore the full toplevel once the gate proto is rebuilt on beef.

let
  solnix = import ../pkgs/illumos;
  buildEnv = import ../lib/build-env.nix { };
  starter = solnix.starter;
  nix = solnix.nix;

  # sw: the composed userland profile == modules/config/system-path.nix's
  # system.path (same buildEnv, same pathsToLink defaults, + nix so nix-store
  # etc. land on PATH via sw/bin).
  sw = buildEnv {
    name = "solnix-system-path";
    paths = [
      starter.coreutils starter.file starter.gnugrep starter.gnused
      starter.bzip2 starter.xz starter.zlib starter.pcre2
      nix
    ];
    pathsToLink = [ "/bin" "/sbin" "/lib" "/lib/amd64" "/share/man" "/share/info" ];
    ignoreCollisions = true;
  };

  # /etc/profile.d/solnix-env.sh is written IN the builder (below), because it
  # must interpolate the store path of the nix slice (${nix}) into
  # LD_LIBRARY_PATH — toFile can't reference a derivation output. The ingested
  # nix (nix.nix) carries RUNPATH /nix-tools/lib + needs its curated runtime-lib
  # set; pointing LD_LIBRARY_PATH at the store nix's own lib + runtime-lib makes
  # it resolve with NO /nix-tools dependency (the store copy is self-contained).

  # /etc/nix/nix.conf — cache.solnix.io substituter + key, single-user, no sandbox.
  nixConf = builtins.toFile "nix.conf" ''
    substituters = https://cache.solnix.io
    trusted-public-keys = cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=
    sandbox = false
    build-users-group =
    max-jobs = auto
  '';
in
derivation {
  name = "solnix-current-system";
  system = builtins.currentSystem; # x86_64-solaris
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  inherit sw nix;
  nixConf = nixConf;
  args = [ "-c" ''
    set -eu
    mkdir -p "$out" "$out/etc/profile.d" "$out/etc/nix"
    ln -s "$sw"  "$out/sw"
    ln -s "$nix" "$out/nix"
    cat > "$out/etc/profile.d/solnix-env.sh" <<ENVEOF
# solnix login environment (Gate A). sw/bin first on PATH.
export PATH=/run/current-system/sw/bin:\$PATH
export NIX_PROFILES="/nix/var/nix/profiles/default"
export NIX_PATH="nixpkgs=/dev/null"
export LD_LIBRARY_PATH=$nix/runtime-lib:$nix/lib\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
ENVEOF
    cp "$nixConf" "$out/etc/nix/nix.conf"
    # sanity: the load-bearing bits must resolve.
    [ -e "$out/sw/bin/file" ]      || { echo "FATAL: no file in sw" >&2; exit 1; }
    [ -e "$out/sw/bin/nix-store" ] || { echo "FATAL: no nix-store in sw" >&2; exit 1; }
  '' ];
}
