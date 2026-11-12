# haskell-pkg.nix -- nixpkgs' haskell-modules/generic-builder.nix reduced for solnix: one hackage package built with
# ./Setup (configure/build/copy/register) on ghc, against ghc's global package db plus hsDeps' (transitively). Same layout as
# nixpkgs (lib/ghc-9.10.3/lib/<abi>/<libname>, a package.conf.d per out), shared + vanilla libraries, no profiling, no haddock.
# ./haskell-pkg-build.sh does the work; `check` runs after the closure gate.
{ ghc, gccWrapper, binutils, world, tools, storeGate, tsErrnoGate, zeroChecksum, pathGate, illumosBin, outHostRefs }:
{ pname, version, sha256, revision ? null, hsDeps ? [ ], toolDeps ? [ ], configureFlags ? [ ], check }:
let fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; }; in
(a: derivation (a // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON a)); })) {
  name = "${pname}-${version}"; inherit pname version;
  system = "x86_64-solaris"; builder = "/usr/bin/bash"; args = [ ./haskell-pkg-build.sh ];
  src = fetch "https://hackage.haskell.org/package/${pname}-${version}/${pname}-${version}.tar.gz" sha256;
  # nixpkgs' editedCabalFile: hackage's metadata revision replaces the tarball's .cabal
  cabalRev = if revision == null then "" else fetch "https://hackage.haskell.org/package/${pname}-${version}/revision/${toString revision.r}.cabal" revision.sha256;
  hsDeps = builtins.concatStringsSep " " (map toString hsDeps);
  toolPath = builtins.concatStringsSep ":" (map (p: "${p}/bin") toolDeps);
  configureFlags = builtins.concatStringsSep " " configureFlags;
  inherit ghc gccWrapper binutils world tools check storeGate tsErrnoGate zeroChecksum pathGate illumosBin outHostRefs;
}
