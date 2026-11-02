# lib/host-pkgs.nix — the minimal `pkgs` the solnix modules need, assembled on
# the illumos build host WITHOUT a nixpkgs stdenv.
#
# EVAL-SPLIT (T2.8): the module system (lib.evalModules) needs nixpkgs' `lib`,
# and the solnix derivations (pkgs.solnix.*) only BUILD on x86_64-solaris. Both
# live on the host: nixpkgs `lib/` is copied there (pure Nix, no ELF) and the
# gate proto is a host-local `builtins.path`. So eval AND build run on the host —
# no .drv transfer, no cross-nix-version drift. See docs/design-make-be.md §7.
#
# The writers are plain-`derivation` stand-ins (bash builder, currentSystem =
# x86_64-solaris), exactly like pkgs/illumos/*.nix and lib/smf/tests.nix. They
# are the SAME contract as pkgs.writeText/writeScript/runCommand, minus the
# nixpkgs stdenv (which does not exist on the host). buildPackages.libxml2 is a
# no-op marker: the host ships xmllint at /usr/bin, put on PATH by runCommand.

# gateProto: an ALREADY-BUILT gate proto to hand to pkgs/illumos. On the illumos
# host this is the real 491 MB tree ingested as a store path. pkgs/illumos takes
# it as an argument because pkgs/illumos/gate.nix asserts srcDir-or-srcHash (an
# unpinned network fetch is not reproducible), so a no-argument import throws the
# moment anything forces gate/libc/systemPath.
{ solnixDir ? ../pkgs/illumos
, gateProto ? null
, gateArgs ? { }
  # a literal, not builtins.currentSystem: that does not exist in a pure (flake)
  # eval, and the flake evaluates solnix systems with this same shim.
, system ? "x86_64-solaris"
}:

let
  # Two-phase import so a solnix SYSTEM builds its from-source packages with the
  # store build-tools on PATH (the NixOS stdenv model), while the gate/bhost
  # build -- which imports pkgs/illumos directly with the buildTools=[] default
  # -- stays byte-identical.
  #
  #   seedPkgs : buildTools=[] (default). Realises `seedBuildTools`, the seed
  #              build-tool farm, bootstrapped the OI/bhost way (no self-cycle).
  #   solnix   : buildTools=seedBuildTools. Its srcPkgs (and nixChain) build with
  #              store gmake/tar/grep/sed/gstrip/gzip/xz on PATH, so a bare system
  #              (dixi, EC2; no /usr/gnu) can realise them. See
  #              docs/pending/builders-need-store-tools.md.
  seedPkgs = import solnixDir { gate = gateProto; inherit gateArgs; };
  # aarch64-solaris: the native aarch64 set (pkgs/illumos/aarch64, nix + gcc + the home tools), built on
  # an aarch64 illumos host with its stage0 tools (mk-src-pkg's aarch64 path). No world, so no seed farm.
  solnix = if system == "aarch64-solaris"
    then import (solnixDir + "/aarch64") ({ inherit system; } // (if gateProto == null then { } else { gate = gateProto; }))
    else import solnixDir {
    gate = gateProto; inherit gateArgs;
    buildTools = [ seedPkgs.seedBuildTools ];
    seedTools = [ seedPkgs.perl seedPkgs.coreutils seedPkgs.findutils seedPkgs.world ];   # world-free (nss): the seed instance's
  };

  # writeText / writeScript: write $text to $out (executable if asked). Matches
  # nixpkgs' writeText/writeScript surface (name -> text -> store path).
  mkWriter = executable: name: text: derivation {
    inherit name text;
    inherit system;
    builder = "/usr/bin/bash";
    PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
    args = [ "-c" (
      ''printf '%s' "$text" > "$out"''
      + (if executable then ''; chmod +x "$out"'' else "")
    ) ];
  };

  # writeTextFile — the ATTRSET form of writeText, which several modules use instead
  # of the curried one. modules/config/mtu.nix:18 calls
  #   pkgs.writeTextFile { name = ...; text = ...; executable = true; }
  # and this shim did not have it, so the host eval died with
  # `error: attribute 'writeTextFile' missing`. Same contract as nixpkgs':
  # `executable` chmods +x, and `destination` (when set) places the file at that
  # path INSIDE $out rather than at $out itself.
  writeTextFileImpl =
    { name, text, executable ? false, destination ? "" }:
    derivation {
      inherit name text;
      inherit system;
      builder = "/usr/bin/bash";
      PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
      exe = if executable then "1" else "";
      dest = destination;
      args = [ "-c" ''
        set -eu
        if [ -n "$dest" ]; then
          # destination is $out-relative (nixpkgs passes it with a leading /)
          target="$out$dest"
          mkdir -p "$(dirname "$target")"
        else
          target="$out"
        fi
        printf '%s' "$text" > "$target"
        [ -n "$exe" ] && chmod +x "$target"
        exit 0
      '' ];
    };

  # runCommand name env script -> store path. Runs `script` under bash with $out
  # set. nativeBuildInputs is ACCEPTED and IGNORED (host tools are on PATH); the
  # smf.nix DTD check calls xmllint, which lives at /usr/bin on the host. env
  # attrs are threaded through as derivation attrs (so e.g. inputs are refs).
  runCommand = name: env: script: derivation ({
    inherit name;
    inherit system;
    builder = "/usr/bin/bash";
    PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
    args = [ "-c" script ];
  } // builtins.removeAttrs env [ "nativeBuildInputs" "buildInputs" ]);
in
{
  # Canonical namespace is pkgs.solnix.*; `illumos` kept as a one-cycle alias.
  inherit solnix runCommand;
  illumos = solnix;
  writeText = mkWriter false;
  writeScript = mkWriter true;
  writeTextFile = writeTextFileImpl;
  # writeShellScript / writeScriptBin: the other two writer spellings modules reach
  # for. Same mechanism, so they are aliases rather than new machinery.
  writeShellScript = name: text: mkWriter true name text;
  runtimeShell = "/sbin/sh"; # the shell method scripts run under on-target

  # buildEnv — the symlink-farm merge (lib/build-env.nix). The declarative
  # userland (modules/config/system-path.nix) composes environment.systemPackages
  # into system.path with it, the same merge pkgs.solnix.systemPath uses. Matches
  # nixpkgs' pkgs.buildEnv surface for the args solnix passes (design §B).
  buildEnv = args: import ./build-env.nix { } ({ inherit system; } // args);

  # buildPackages.libxml2 marker: smf.nix lists it as a nativeBuildInput for the
  # xmllint DTD gate. runCommand ignores nativeBuildInputs and puts /usr/bin
  # (host xmllint) on PATH, so this only needs to EXIST as an attr.
  buildPackages.libxml2 = "/usr"; # host xmllint prefix; unused except as a ref
}
