# ghc-9.10.3.nix -- GHC 9.10.3 for x86_64-solaris (illumos), built FROM SOURCE by a pinned binary seed, as nixpkgs bootstraps
# GHC from a bindist (pkgs/development/compilers/ghc/9.8.4-binary.nix) and solnix bootstrapped rust (docs/rust-illumos-bootstrap.md).
#
# Seed: pkgsrc's bootkit ghc-9.8.2-boot-x86_64-unknown-solaris2.tar.xz, the stage0 pkgsrc lang/ghc910 itself uses on SunOS-x86_64
# (lang/ghc910/bootstrap.mk; SHA512 82ea973c... in its distinfo, measured equal). No GHC release ships an illumos bindist, and
# OpenIndiana / OmniOS ship no GHC (measured 2026-11-11). GHC 9.10 needs a >= 9.6 boot compiler: one hop. The seed is installed
# inside this build (its own bindist configure), never shipped; its package db names pkgsrc's /opt/local, repointed at the store.
#
# The build is nixpkgs' common-hadrian.nix reduced: hadrian bootstrapped offline from the in-tree plan (hackage sources as FODs),
# configure with system libffi/gmp/iconv/curses, flavour release+split_sections, --bignum=gmp, --docs=no-sphinx, --hash-unit-ids,
# then the bindist's configure + make install into $out. Patches: 9 of pkgsrc lang/ghc910's (patches/, each says why), plus its
# two hadrian-bootstrap package patches, and 4 for reproducibility (ghc-pkg reads a db dir sorted; hadrian archives with ar
# D; backports of GHC a8aa1868 (#26838, link order) and b3f7fb80 (#25304, interface docs order)). ./ghc-build.sh does the work and the checks.
{ gccWrapper, binutils, world, tools, python3, autotools, gmp, libffi, libiconv, ncurses }:
let
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  # hadrian's bootstrap plan for a 9.8.2 boot compiler (hadrian/bootstrap/plan-bootstrap-9_8_2.json in the 9.10.3 tarball):
  # each hackage source tarball and the .cabal revision it pins, sha256 as in the plan (bootstrap.py checks them again).
  hackage = map (d: {
    tar = fetch "https://hackage.haskell.org/package/${d.p}-${d.v}/${d.p}-${d.v}.tar.gz" d.src;
    cabal = fetch "https://hackage.haskell.org/package/${d.p}-${d.v}/revision/${toString d.r}.cabal" d.cabal;
    inherit (d) p v;
  }) [
    { p = "base16-bytestring"; v = "1.0.2.0"; r = 1; src = "1d5a91143ef0e22157536093ec8e59d226a68220ec89378d5dcaeea86472c784"; cabal = "a694e88f9ec9fc79f0b03f233d3fea592b68f70a34aac2ddb5bcaecb6562e2fd"; }
    { p = "clock"; v = "0.8.4"; r = 0; src = "6ae9898afe788a5e334cd5fad5d18a3c2e8e59fa09aaf7b957dbb38a4767df2e"; cabal = "b938655b00cf204ce69abfff946021bed111d2609a9f7a9c22e28a1a202e9115"; }
    { p = "cryptohash-sha256"; v = "0.11.102.1"; r = 4; src = "73a7dc7163871a80837495039a099967b11f5c4fe70a118277842f7a713c6bf6"; cabal = "200d756a7b3bab7ca2bac6eb50ed8252f26de77ac8def490a3ad743f2933acbd"; }
    { p = "extra"; v = "1.7.14"; r = 0; src = "b6a909f8f0e4b8076a1653b4d34815a782f0a8c1e83d5267f4d00496471ef567"; cabal = "e3d3ce1dc7746b1132930e48c59fb5e8c51a09e92e0c031316be031067a273fb"; }
    { p = "filepattern"; v = "0.1.3"; r = 0; src = "cc445d439ea2f65cac7604d3578aa2c3a62e5a91dc989f4ce5b3390db9e59636"; cabal = "372c1733d83b90045eb29da9f010fed79bfef8771ce65eb126a1d83ecc54a9a2"; }
    { p = "hashable"; v = "1.4.3.0"; r = 1; src = "32efb16c2891786209b7cbe5c39df9b3a9ae51e836f1a54f646bc4602b7ab0f5"; cabal = "f3bf68acfa0df7a064a378ef2cdcfeb55e6fb96100675f4c593556dcbf3d7194"; }
    { p = "heaps"; v = "0.4"; r = 0; src = "89329df8b95ae99ef272e41e7a2d0fe2f1bb7eacfcc34bc01664414b33067cfd"; cabal = "66b19fcd813b0e4db3e0bac541bd46606c3b13d3d081d9f9666f4be0f5ff14b8"; }
    { p = "js-dgtable"; v = "0.5.2"; r = 0; src = "e28dd65bee8083b17210134e22e01c6349dc33c3b7bd17705973cd014e9f20ac"; cabal = "f75cb4fa53c88c65794becdd48eb0d3b2b8abd89a3d5c19e87af91f5225c15e4"; }
    { p = "js-flot"; v = "0.8.3"; r = 0; src = "1ba2f2a6b8d85da76c41f526c98903cbb107f8642e506c072c1e7e3c20fe5e7a"; cabal = "4c1c447a9a2fba0adba6d30678302a30c32b9dfde9e7aa9e9156483e1545096d"; }
    { p = "js-jquery"; v = "3.3.1"; r = 0; src = "e0e0681f0da1130ede4e03a051630ea439c458cb97216cdb01771ebdbe44069b"; cabal = "59ab6c79159549ef94b584abce8e6d3b336014c2cce1337b59a8f637e2856df5"; }
    { p = "primitive"; v = "0.8.0.0"; r = 1; src = "5553c21b4a789f9b591eed69e598cc58484c274af29250e517b5a8bcc62b995f"; cabal = "d0ff45fa6e61f92af23611ceb8b9a6a04c236b50fb70c60e2ed3bfa532703670"; }
    { p = "splitmix"; v = "0.1.0.5"; r = 1; src = "9df07a9611ef45f1b1258a0b412f4d02c920248f69d2e2ce8ccda328f7e13002"; cabal = "caa9b4a92abf1496c7f6a3c0f4e357426a54880077cb9f04e260a8bfa034b77b"; }
    { p = "random"; v = "1.2.1.1"; r = 1; src = "3e1272f7ed6a4d7bd1712b90143ec326fee9b225789222379fea20a9c90c9b76"; cabal = "e7c1f881159d5cc788619c9ee8b8f340ba2ff0db571cdf3d1a1968ebc5108789"; }
    { p = "unordered-containers"; v = "0.2.16.0"; r = 1; src = "bccf68bcf262a149e8cdb25bc4a87d59642faa772ec4db384e16ac8f4f3f49ef"; cabal = "21f9dd4be45897e487a98bfc152d900f1d69213d41dc0096d8adf9429349a164"; }
    { p = "utf8-string"; v = "1.0.2"; r = 0; src = "ee48deada7600370728c4156cb002441de770d0121ae33a68139a9ed9c19b09a"; cabal = "79416292186feeaf1f60e49ac5a1ffae9bf1b120e040a74bf0e81ca7f1d31d3f"; }
    { p = "shake"; v = "0.19.7"; r = 1; src = "352a56af12f70b50d564dcb61131555577281957ee196f1702a3723c0a3699d1"; cabal = "3cb5814cce210b9756fa9246ff1b2a1e1b86be46fdc4c5e2baacdc5bf83ce5c3"; }
  ];
in
(a: derivation (a // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON a)); })) {
  name = "ghc-9.10.3"; pname = "ghc"; version = "9.10.3";
  system = "x86_64-solaris"; builder = "/usr/bin/bash"; args = [ ./ghc-build.sh ];
  src = fetch "https://downloads.haskell.org/~ghc/9.10.3/ghc-9.10.3-src.tar.xz" "d266864b9e0b7b741abe8c9d6a790d7c01c21cf43a1419839119255878ebc59a";
  seed = fetch "https://us-central.manta.mnx.io/pkgsrc/public/pkg-bootstraps/ghc-9.8.2-boot-x86_64-unknown-solaris2.tar.xz"
    "4baa06f9b84ec5682b4d10643772394baa9320682f32209465cc46a1d88df9a7";
  # "<pkg>-<ver> <tarball> <cabal>" per line, for bootstrap.py's _build/tarballs
  hackage = builtins.concatStringsSep "\n" (map (h: "${h.p}-${h.v} ${h.tar} ${h.cabal}") hackage);
  patches = ./patches;
  inherit gccWrapper binutils world tools python3;
  autotools = builtins.concatStringsSep ":" (map (p: "${p}/bin") autotools);
  inherit gmp libffi libiconv ncurses;
  storeGate = ../store-gate.sh; tsErrnoGate = ../ts-errno-gate.sh; zeroChecksum = ../zero-checksum.sh; pathGate = ../path-gate.sh;
  illumosBin = ../illumos-bin.sh; outHostRefs = ../out-host-refs.sh;
}
