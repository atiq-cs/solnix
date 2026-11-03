# graphics/cosmic.nix -- COSMIC rust programs (cosmic-comp, cosmic-term) as solnix
# derivations: rust199 + the from-source gcc + the graphics libs here. Same shape as
# solnix-pkgs cosmic-term.nix (a cargo-vendor FOD + an offline build), without the
# nixpkgs stdenv: the fork world it needs does not build (cosmic2/fork-world-blockers.md).
{ rust, gcc, gate, libc, world, gccLib, cacert, graphics, openssl }:
let
  rtLibs = [ libc world gcc.lib ];
  # cargo vendor needs the network; the output is pinned by its NAR hash (an FOD).
  vendorOf = { pname, src, narHash }: derivation {
    name = "${pname}-vendor"; system = "x86_64-solaris"; builder = "/usr/bin/bash";
    inherit src rust;
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt"; PATH = "/usr/gnu/bin:/usr/bin";
    outputHashMode = "recursive"; outputHashAlgo = "sha256"; outputHash = narHash;
    args = [ "-c" ''
      set -eu; export HOME=$PWD CARGO_HOME=$PWD/ch
      tar xzf "$src"; cd */
      export PATH="$rust/bin:$PATH"   # cargo vendor runs rustc -vV for some workspaces
      cargo vendor --locked "$out" > config.toml
      cp Cargo.lock "$out/.Cargo.lock"
      # cargo's own source-replacement config, with the vendor dir made relocatable
      sed "s|$out|vendor|" config.toml > "$out/.cargo-config.toml"
      grep -q 'directory = "vendor"' "$out/.cargo-config.toml" || { echo "FATAL: vendor config" >&2; exit 1; }
    '' ];
  };
  cargoApp = { pname, version, src, vendor, libs, required, stubs ? false, features ? "", prep ? "", bins, wrap ? "", NO_SOFTBUFFER_KMS ? "",
               cargoArgs ? "", install ? "", check ? "", appFixups ? "", env ? { } }: (a: derivation (a // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON a)); })) ({
    name = "${pname}-${version}"; system = "x86_64-solaris"; builder = "/usr/bin/bash";
    inherit src vendor rust gate;
    gcc = gcc; gccLibDir = "${gccLib}/lib";
    libDirs = builtins.concatStringsSep " " (map (d: "${d}") (libs ++ rtLibs));
    inherit features prep bins wrap NO_SOFTBUFFER_KMS cargoArgs install check appFixups; REQUIRED = required;
    stubsSh = if stubs then ./cosmic-comp-stubs.sh else "";
    tsErrnoGate = ../ts-errno-gate.sh; zeroChecksum = ../zero-checksum.sh;
    fixups = ./.;
    args = [ ./cosmic-build.sh ];
  } // env);
  src = repo: sha256: import <nix/fetchurl.nix> {
    name = "${repo}-epoch-1.5.0.tar.gz"; url = "https://codeload.github.com/pop-os/${repo}/tar.gz/refs/tags/epoch-1.5.0"; inherit sha256; };
  # cargo vendor NAR hashes (FODs). A new one: set it to lib.fakeHash, build, copy the "got:".
  vendorHashes = import ./cosmic-vendor-hashes.nix;
in import ./cosmic-apps.nix { inherit src vendorOf cargoApp graphics vendorHashes openssl; }
// rec {
  cosmic-comp-src = import <nix/fetchurl.nix> {
    url = "https://codeload.github.com/pop-os/cosmic-comp/tar.gz/refs/tags/epoch-1.5.0";
    sha256 = "ebdc79bd667b6ee167fcf5c4a616f56db7c24adfabc11ab3c3e572c5b2a52421"; };
  cosmic-comp-vendor = vendorOf { pname = "cosmic-comp-1.5.0"; src = cosmic-comp-src;
    narHash = "sha256-tOK+PNEh6/X15NsuRGvxrZMAXUGQlkzLjAPaa5N/ERg="; };
  cosmic-comp = cargoApp {
    pname = "cosmic-comp"; version = "1.5.0"; src = cosmic-comp-src; vendor = cosmic-comp-vendor;
    libs = with graphics; [ mesa libdrm wayland libffi expat seatd libxkbcommon pixman libdisplay-info ];
    stubs = true; bins = "cosmic-comp";
    required = "rustix rustix-0.38.44 wayland-backend reis winit smithay";
    prep = "python3 $fixups/cosmic-comp-src-fixup.py $PWD";
  };

  # The reference COSMIC client (solnix-pkgs cosmic-term.nix), built here instead of on the
  # nixpkgs fork. Same features: wayland + dbus-config, no wgpu (it panics with no backend).
  cosmic-term-src = import <nix/fetchurl.nix> {
    url = "https://codeload.github.com/pop-os/cosmic-term/tar.gz/refs/tags/epoch-1.5.0";
    sha256 = "ea942a519c33c6bc13dddfdd8c5addfc4307742c1f892fa67807646fc6db42bc"; };
  cosmic-term-vendor = vendorOf { pname = "cosmic-term-1.5.0"; src = cosmic-term-src;
    narHash = "sha256-9vBAV+2+LhVu0wJXz0k5damFgbp7geRkRQhX7/MURWw="; };
  cosmic-term = cargoApp {
    pname = "cosmic-term"; version = "1.5.0"; src = cosmic-term-src; vendor = cosmic-term-vendor;
    libs = with graphics; [ libxkbcommon wayland libffi ];
    features = "wayland,dbus-config"; bins = "cosmic-term";
    required = "rustix wayland-backend winit softbuffer";
    wrap = "ICED_BACKEND=tiny-skia UMEM_OPTIONS=backend=mmap"; NO_SOFTBUFFER_KMS = "1";
  };
}
