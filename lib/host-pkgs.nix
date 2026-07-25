# lib/host-pkgs.nix — the minimal `pkgs` the solnix modules need, assembled on
# the illumos build host WITHOUT a nixpkgs stdenv.
#
# EVAL-SPLIT (T2.8): the module system (lib.evalModules) needs nixpkgs' `lib`,
# and the illumos derivations (pkgs.illumos.*) only BUILD on x86_64-solaris. Both
# live on the host: nixpkgs `lib/` is copied there (pure Nix, no ELF) and the
# gate proto is a host-local `builtins.path`. So eval AND build run on the host —
# no .drv transfer, no cross-nix-version drift. See docs/design-make-be.md §7.
#
# The writers are plain-`derivation` stand-ins (bash builder, currentSystem =
# x86_64-solaris), exactly like pkgs/illumos/*.nix and lib/smf/tests.nix. They
# are the SAME contract as pkgs.writeText/writeScript/runCommand, minus the
# nixpkgs stdenv (which does not exist on the host). buildPackages.libxml2 is a
# no-op marker: the host ships xmllint at /usr/bin, put on PATH by runCommand.

{ illumosDir ? ../pkgs/illumos }:

let
  illumos = import illumosDir;

  # writeText / writeScript: write $text to $out (executable if asked). Matches
  # nixpkgs' writeText/writeScript surface (name -> text -> store path).
  mkWriter = executable: name: text: derivation {
    inherit name text;
    system = builtins.currentSystem; # x86_64-solaris on the host
    builder = "/usr/bin/bash";
    PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
    args = [ "-c" (
      ''printf '%s' "$text" > "$out"''
      + (if executable then ''; chmod +x "$out"'' else "")
    ) ];
  };

  # runCommand name env script -> store path. Runs `script` under bash with $out
  # set. nativeBuildInputs is ACCEPTED and IGNORED (host tools are on PATH); the
  # smf.nix DTD check calls xmllint, which lives at /usr/bin on the host. env
  # attrs are threaded through as derivation attrs (so e.g. inputs are refs).
  runCommand = name: env: script: derivation ({
    inherit name;
    system = builtins.currentSystem;
    builder = "/usr/bin/bash";
    PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
    args = [ "-c" script ];
  } // builtins.removeAttrs env [ "nativeBuildInputs" "buildInputs" ]);
in
{
  inherit illumos runCommand;
  writeText = mkWriter false;
  writeScript = mkWriter true;
  runtimeShell = "/sbin/sh"; # the shell method scripts run under on-target

  # buildPackages.libxml2 marker: smf.nix lists it as a nativeBuildInput for the
  # xmllint DTD gate. runCommand ignores nativeBuildInputs and puts /usr/bin
  # (host xmllint) on PATH, so this only needs to EXIST as an attr.
  buildPackages.libxml2 = "/usr"; # host xmllint prefix; unused except as a ref
}
