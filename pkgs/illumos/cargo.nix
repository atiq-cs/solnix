# cargo.nix -- a generic Rust package on rust199, factored from graphics/cosmic.nix:
#   vendorOf  : `cargo vendor --locked` as a fixed-output derivation (the network step),
#               the same text as cosmic.nix's (so the same src + narHash is the same drv);
#   cargoPkg  : an offline `cargo build --release --locked` with the from-source gcc as the
#               linker, the store RUNPATH baked at link time, then the mk-src-pkg closure gate
#               (./cargo-build.sh). nixpkgs' rustPlatform.buildRustPackage, reduced.
# cosmic.nix keeps its own copy: its fixups = ./. makes every byte of graphics/ an input, so
# moving its helpers here would move cosmic-comp/cosmic-term (measured, hlcli progress.txt).
{ rust, gcc, gate, libc, world, gccLib, cacert, tools, python3 }:
let
  rtLibs = [ libc world gcc.lib ];
  # the source tarball unpacked by Nix (libarchive), as go.nix's srcTree: host tar on a solnix system execs the absent gzcat.
  unpack = srcTar: derivation { name = "${srcTar.name}-unpacked"; system = "builtin"; builder = "builtin:unpack-channel";
    src = srcTar; channelName = "tree"; };
in rec {
  # rustOnPath: put rust199's rustc on PATH (crates whose lockfile load runs `rustc -vV`, e.g. a
  # rust-version/rust-toolchain pin). Off by default: the text stays cosmic.nix's byte for byte.
  vendorOf = { pname, src, narHash, rustOnPath ? false }: derivation {
    name = "${pname}-vendor"; system = "x86_64-solaris"; builder = "/usr/bin/bash";
    src = unpack src; inherit rust;
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    PATH = (if rustOnPath then "${rust}/bin:" else "") + "${tools}/bin:${world}/bin:${world}/usr/bin";
    outputHashMode = "recursive"; outputHashAlgo = "sha256"; outputHash = narHash;
    args = [ "-c" ''
      set -eu; export HOME=$PWD CARGO_HOME=$PWD/ch
      cp -RP "$src/tree" s; find s ! -type l -exec chmod u+w {} +; cd s   # unpacked by Nix (no host tar/gzcat)
      "$rust/bin/cargo" vendor --locked "$out" > config.toml
      cp Cargo.lock "$out/.Cargo.lock"
      # cargo's own source-replacement config, with the vendor dir made relocatable
      sed "s|$out|vendor|" config.toml > "$out/.cargo-config.toml"
      grep -q 'directory = "vendor"' "$out/.cargo-config.toml" || { echo "FATAL: vendor config" >&2; exit 1; }
    '' ];
  };

  # cargoPkg { pname; version; src = { url; sha256; }; vendorHash; bins; check; ... }
  #   bins     : "rg" -- target/release names copied to $out/bin
  #   check    : shell run after install with $out set (the brief's in-build --version check)
  #   features / noDefault / pkgDir (-p <crate> for a workspace) / libs (store C libs) / prep
  #   man      : shell to install man pages (from the source tree, cwd = the crate root)
  cargoPkg = { pname, version, src, vendorHash, bins, check, features ? "", noDefault ? false,
               pkg ? "", libs ? [ ], prep ? "", man ? "", env ? "" }:
    let srcTar = import <nix/fetchurl.nix> { inherit (src) url sha256; };
        withKey = a: derivation (a // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON a)); }); in
    withKey {
      name = "${pname}-${version}"; system = "x86_64-solaris"; builder = "/usr/bin/bash";
      src = unpack srcTar; inherit tools python3; vendor = vendorOf { pname = "${pname}-${version}"; src = srcTar; narHash = vendorHash; rustOnPath = true; };
      inherit rust gate world; gcc = gcc; gccLibDir = "${gccLib}/lib";
      libDirs = builtins.concatStringsSep " " (map (d: "${d}") (libs ++ rtLibs));
      inherit features prep bins check man pkg env;
      noDefault = if noDefault then "1" else "";
      tsErrnoGate = ./ts-errno-gate.sh; zeroChecksum = ./zero-checksum.sh;
      args = [ ./cargo-build.sh ];
    };
}
