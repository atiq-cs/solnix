# graphics/cosmic.nix -- COSMIC rust programs (cosmic-comp, cosmic-term) as solnix
# derivations: rust199 + the from-source gcc + the graphics libs here. Same shape as
# solnix-pkgs cosmic-term.nix (a cargo-vendor FOD + an offline build), without the
# nixpkgs stdenv: the fork world it needs does not build (cosmic2/fork-world-blockers.md).
{ rust, gcc, gate, libc, world, gccLib, cacert, graphics, openssl, tools, python3, libclang ? null, inputStack ? null }:
let
  rtLibs = [ libc world gcc.lib ];
  # the source tarball unpacked by Nix (libarchive), as cargo.nix's unpack: a solnix host's tar execs the absent gzcat.
  unpack = srcTar: derivation { name = "${srcTar.name}-unpacked"; system = "builtin"; builder = "builtin:unpack-channel";
    src = srcTar; channelName = "tree"; };
  # cargo vendor needs the network; the output is pinned by its NAR hash (an FOD). Store tools only
  # (cargo.nix pattern): Nix unpacks the tarball, PATH is the store set, no host tar/gzcat.
  vendorOf = { pname, src, narHash }: derivation {
    name = "${pname}-vendor"; system = "x86_64-solaris"; builder = "/usr/bin/bash";
    src = unpack src; inherit rust;
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    PATH = "${rust}/bin:${tools}/bin:${world}/bin:${world}/usr/bin";   # rust on PATH: cargo vendor runs rustc -vV for some workspaces
    outputHashMode = "recursive"; outputHashAlgo = "sha256"; outputHash = narHash;
    args = [ "-c" ''
      set -eu; export HOME=$PWD CARGO_HOME=$PWD/ch
      cp -RP "$src/tree" s; find s ! -type l -exec chmod u+w {} +; cd s   # unpacked by Nix (no host tar/gzcat)
      cargo vendor --locked "$out" > config.toml
      cp Cargo.lock "$out/.Cargo.lock"
      # cargo's own source-replacement config, with the vendor dir made relocatable
      sed "s|$out|vendor|" config.toml > "$out/.cargo-config.toml"
      grep -q 'directory = "vendor"' "$out/.cargo-config.toml" || { echo "FATAL: vendor config" >&2; exit 1; }
    '' ];
  };
  # realInput: solnix's libudev (+ libinput for cosmic-comp) linked for real instead of the link-only STUBs (tpad4).
  realUdev = if inputStack == null then [ ] else [ inputStack.libudev-solnix ];
  realLibinput = if inputStack == null then [ ] else [ inputStack.libudev-solnix inputStack.libinput inputStack.libevdev inputStack.mtdev ];
  cargoApp = { pname, version, src, vendor, libs, required, stubs ? false, realInput ? (if stubs then realUdev else [ ]), features ? "", prep ? "", bins, wrap ? "", NO_SOFTBUFFER_KMS ? "",
               cargoArgs ? "", install ? "", check ? "", appFixups ? "", env ? { } }: (a: derivation (a // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON a)); })) ({
    name = "${pname}-${version}"; system = "x86_64-solaris"; builder = "/usr/bin/bash";
    src = unpack src; inherit vendor rust gate tools python3 world;
    gcc = gcc; gccLibDir = "${gccLib}/lib";
    libDirs = builtins.concatStringsSep " " (map (d: "${d}") (libs ++ realInput ++ rtLibs));
    REAL_INPUT_LIBS = (if realInput != [ ] then "libudev.so.1" else "") + (if builtins.length realInput > 1 then " libinput.so.10" else "");
    inherit features prep bins wrap NO_SOFTBUFFER_KMS cargoArgs install check appFixups; REQUIRED = required;
    stubsSh = if stubs then ./cosmic-comp-stubs.sh else "";
    tsErrnoGate = ../ts-errno-gate.sh; zeroChecksum = ../zero-checksum.sh;
    fixups = ./.;
    args = [ ./cosmic-build.sh ];
  } // env);
  src = repo: sha256: import <nix/fetchurl.nix> {
    name = "${repo}-epoch-1.11.0.tar.gz"; url = "https://codeload.github.com/pop-os/${repo}/tar.gz/refs/tags/epoch-1.11.0"; inherit sha256; };
  # cargo vendor NAR hashes (FODs). A new one: set it to lib.fakeHash, build, copy the "got:".
  vendorHashes = import ./cosmic-vendor-hashes.nix;
in import ./cosmic-apps.nix { inherit src vendorOf cargoApp graphics vendorHashes openssl libclang; }
// rec {
  cosmic-comp-src = import <nix/fetchurl.nix> {
    url = "https://codeload.github.com/pop-os/cosmic-comp/tar.gz/refs/tags/epoch-1.11.0";
    sha256 = "c07778440f25e909358a37f293ddf403a28a153b02eedb30b61b846a7142ba60"; };
  cosmic-comp-vendor = vendorOf { pname = "cosmic-comp-1.11.0"; src = cosmic-comp-src;
    narHash = "sha256-QwUZzAcdHCDDyqJrd1+iFJ86PNg4FUXSeHPkuuTSJwA="; };
  cosmic-comp = cargoApp {
    pname = "cosmic-comp"; version = "1.11.0"; src = cosmic-comp-src; vendor = cosmic-comp-vendor;
    libs = with graphics; [ mesa libdrm wayland libffi expat seatd libxkbcommon pixman libdisplay-info ];
    stubs = true; bins = "cosmic-comp"; realInput = realLibinput;
    required = "rustix rustix-0.38.44 wayland-backend reis winit smithay";
    prep = "python3 $fixups/cosmic-comp-src-fixup.py $PWD";
  };

  # The reference COSMIC client (solnix-pkgs cosmic-term.nix), built here instead of on the
  # nixpkgs fork. Same features: wayland + dbus-config, no wgpu (it panics with no backend).
  cosmic-term-src = import <nix/fetchurl.nix> {
    url = "https://codeload.github.com/pop-os/cosmic-term/tar.gz/refs/tags/epoch-1.11.0";
    sha256 = "455cdc42e8f4a5a00a033a38f65341bf1b1af621cc7d01a78da0ee2f9177a09c"; };
  cosmic-term-vendor = vendorOf { pname = "cosmic-term-1.11.0"; src = cosmic-term-src;
    narHash = "sha256-5G1J76m13BBzgcwNLQKNslutHXHm+9ai9KSfV0EPLk8="; };
  cosmic-term = cargoApp {
    pname = "cosmic-term"; version = "1.11.0"; src = cosmic-term-src; vendor = cosmic-term-vendor;
    libs = with graphics; [ libxkbcommon wayland libffi ];
    features = "wayland,dbus-config"; bins = "cosmic-term";
    required = "rustix wayland-backend winit softbuffer";
    wrap = "ICED_BACKEND=tiny-skia UMEM_OPTIONS=backend=mmap"; NO_SOFTBUFFER_KMS = "1";
  };
}
