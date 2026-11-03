# go.nix -- Go from source for illumos/amd64: the go1.4 C bootstrap, then each release built
# by the previous one (Go's own bootstrap rule: 1.20+ needs 1.17.13, 1.22 needs 1.20,
# 1.24 needs 1.22, 1.26 needs 1.24). No binary seed. ./go-build.sh does one stage.
# Go binaries NEED libc.so/libsocket.so/libsendfile.so and carry no RUNPATH by default, so
# every stage after 1.4 links with -r <world lib dirs> (cmd/link -r = DT_RUNPATH).
{ gcc, gccLib, world, cacert, gate, tools ? null, bash ? null }:   # tools, bash: the hostfix store tools and bash, for goPkg storeOnly only
let
  rp = "${world}/lib/amd64:${world}/usr/lib/amd64";
  stage = { version, sha256, url ? "https://go.dev/dl/go${version}.src.tar.gz", boot ? null, final ? false }:
    (a: derivation (a // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON a)); })) {
    name = "go-${version}"; system = "x86_64-solaris"; builder = "/usr/bin/bash";
    src = import <nix/fetchurl.nix> { inherit url sha256; };
    inherit version gcc rp world gate; gccLibDir = "${gccLib}/lib";
    boot = if boot == null then "" else boot;
    final = if final then "1" else "";
    storeGate = ./store-gate.sh; tsErrnoGate = ./ts-errno-gate.sh; zeroChecksum = ./zero-checksum.sh;
    args = [ ./go-build.sh ];
  };
in rec {
  go_1_4 = stage { version = "1.4-bootstrap-20171003"; url = "https://go.dev/dl/go1.4-bootstrap-20171003.tar.gz";
    sha256 = "f4ff5b5eb3a3cae1c993723f3eab519c5bae18866b5e5f96fe1102f0cb5c3e52"; };
  go_1_17 = stage { version = "1.17.13"; boot = go_1_4;
    sha256 = "a1a48b23afb206f95e7bbaa9b898d965f90826f6f1d1fc0c1d784ada0cd300fd"; };
  go_1_20 = stage { version = "1.20.14"; boot = go_1_17;
    sha256 = "1aef321a0e3e38b7e91d2d7eb64040666cabdcc77d383de3c9522d0d69b67f4e"; };
  go_1_22 = stage { version = "1.22.12"; boot = go_1_20;
    sha256 = "012a7e1f37f362c0918c1dfa3334458ac2da1628c4b9cf4d9ca02db986e17d71"; };
  go_1_24 = stage { version = "1.24.13"; boot = go_1_22;
    sha256 = "639a6204c2486b137df1eb6e78ee3ed038f9877d0e4b5a465e796a2153f858d7"; };
  go_1_26 = stage { version = "1.26.8"; boot = go_1_24; final = true;
    sha256 = "4e39b98e42f946fa05ac8bc5b71877df97dbdb7cbb1a777b541667ad7117fd2e"; };
  # 1.27 for modules that require it (gh 2.103: "go.mod requires go >= 1.27.0", measured).
  go_1_27 = stage { version = "1.27.3"; boot = go_1_26; final = true;
    sha256 = "6e7749035cf360f06b2575d162ea79df9fda8ef671889e5c375f8e50777f26bb"; };
  go = go_1_26;
  goRunpath = rp;

  # goPkg { pname; version; src = { url; sha256; }; vendorHash; subPkgs; check; ldflags; man }:
  # nixpkgs' buildGoModule reduced -- `go mod vendor` as a fixed-output derivation, then an
  # offline -mod=vendor build on go_1_26 (./go-pkg-build.sh). vendorHash = null: no vendor dir.
  # storeOnly: build with ./go-pkg-build2.sh (store tools + the world on PATH, path-gated) so a solnix host rebuilds it. New
  # recipes set it; the served ones keep go-pkg-build.sh (host PATH), so their drvs don't move.
  goPkg = { pname, version, src, vendorHash, subPkgs ? ".", check, ldflags ? "", prep ? "", man ? "", goPkgs ? go_1_26, storeOnly ? false }:
    let
      srcTar = import <nix/fetchurl.nix> { inherit (src) url sha256; };
      # unpacked by Nix (libarchive, in the daemon), as fetch-tarball.nix does: host `tar xzf` on a solnix
      # system is illumos tar, which execs the absent /usr/bin/gzcat and exits 0 with nothing extracted.
      srcTree = derivation { name = "${pname}-${version}-src"; system = "builtin"; builder = "builtin:unpack-channel";
        src = srcTar; channelName = "tree"; };
      common = { system = "x86_64-solaris"; builder = "/usr/bin/bash"; src = srcTree; go = goPkgs;
        inherit rp; storeGate = ./store-gate.sh; tsErrnoGate = ./ts-errno-gate.sh; args = [ ./go-pkg-build.sh ]; }
        // (if storeOnly then { inherit tools world bash; pathGate = ./path-gate.sh; args = [ ./go-pkg-build2.sh ]; } else { });
      vend = derivation (common // { name = "${pname}-${version}-go-vendor"; vendorOnly = "1";
        goVendor = ""; subPkgs = ""; check = ""; ldflags = ""; prep = ""; man = "";
        SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
        outputHashMode = "recursive"; outputHashAlgo = "sha256"; outputHash = vendorHash; });
    in derivation (common // { name = "${pname}-${version}"; vendorOnly = "";
      goVendor = if vendorHash == null then "" else vend; inherit subPkgs check ldflags prep man; });
}
