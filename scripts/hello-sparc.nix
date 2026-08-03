{ system ? "sparc64-solaris" }:
let
  pkgs = import /scratch/gburd-nixbuild/entry.nix { inherit system; };
  cc = pkgs.stdenv.cc;
  helloTar = import <nix/fetchurl.nix> {
    url = "https://ftpmirror.gnu.org/hello/hello-2.12.1.tar.gz";
    sha256 = "086vqwk2wl8zfs47sq2xpjc9k066ilmb8z6dn0q6ymwjzlm196cd";
  };
in derivation {
  name = "hello-2.12.1-sparc";
  inherit system;
  builder = "${pkgs.stdenv.shell}";
  PATH = "${cc}/bin:${pkgs.stdenv}/bin";
  args = [ "-c" ''
    set -e
    export PATH="$PATH:/usr/gnu/bin:/usr/bin:/usr/sbin"
    mkdir -p build && cd build
    tar -xzf "$src"
    cd hello-2.12.1
    ./configure --prefix="$out" --host=sparcv9-sun-solaris2.11 --build=sparcv9-sun-solaris2.11 CC=cc
    make
    make install
  '' ];
  src = helloTar;
}
