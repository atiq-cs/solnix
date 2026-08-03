#!/usr/bin/env bash
# sparc-gate-setup.sh — prepare the patched nixpkgs + entry/hello nix on sun,
# then leave the long stdenv+hello nix-build to a separate detached step.
# Mirrors scripts/oi-gate1b-repro.sh (x86) for sparcv9-solaris.
set -euo pipefail

REV=7f81d69cbd67048635c5d30cd2649e4d018976bc
ROOT=/scratch/gburd-nixbuild
FORK=$ROOT/solnix-pkgs
PREFIX=/nix/nix-tools

export PATH="$PREFIX/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH"
export NIX_CONF_DIR="$PREFIX/etc/nix"
# GNU tar first on PATH (Solaris tar chokes on GitHub pax global headers).
# /usr/gnu/bin is already ahead of /usr/bin above.

echo "== fetch pinned nixpkgs (rev $REV) =="
SRC=$(nix-prefetch-url --unpack --name nixpkgs-src --print-path \
        "https://github.com/NixOS/nixpkgs/archive/$REV.tar.gz" | tail -1)
echo "SRC=$SRC"

DST=$ROOT/nixpkgs-patched
[ -e "$DST" ] && chmod -R u+w "$DST" && rm -rf "$DST"
mkdir -p "$DST" && cp -a "$SRC"/. "$DST"/ && chmod -R u+w "$DST"
cd "$DST"
# The sparc gate needs patches 0001,0002,0003,0004-stdenv,0005,0006 (NOT the
# 0004 riscv DRAFT). Apply in order.
for p in 0001-lib-systems-x86_64-solaris 0002-bintools-wrapper-solaris \
         0003-all-packages-illumos 0004-stdenv-illumos-bootstrap-stage \
         0005-cc-wrapper-solaris-runpath 0006-stdenv-illumos-sparc; do
  echo "-- patch $p"
  patch -p1 --no-backup-if-mismatch < "$FORK/patches/$p.patch"
done

# host Nix is 2.3.16; drop the nixpkgs >=2.18 abort (design §7.1).
cat > lib/minfeatures.nix <<'MF'
let features = [ { description = "the `nixVersion` builtin"; condition = builtins ? nixVersion; } ];
    evaluated = builtins.partition ({ condition, ... }: condition) features;
in { all = features; supported = evaluated.right; missing = evaluated.wrong; }
MF

NPKGS=$(nix-store --add "$DST")
echo "NPKGS=$NPKGS"

cat > $ROOT/entry.nix <<ENTRY
{ system ? "sparc64-solaris" }:
let overlay = final: prev: {
      solnix = final.callPackage $FORK/pkgs/os-specific/illumos { };
      illumos = final.solnix;
    };
in import $DST { inherit system; overlays = [ overlay ]; config = { allowUnsupportedSystem = true; }; }
ENTRY

cat > $ROOT/hello-sparc.nix <<HELLO
{ system ? "sparc64-solaris" }:
let
  pkgs = import $ROOT/entry.nix { inherit system; };
  cc = pkgs.stdenv.cc;
  helloTar = import <nix/fetchurl.nix> {
    url = "https://ftpmirror.gnu.org/hello/hello-2.12.1.tar.gz";
    sha256 = "086vqwk2wl8zfs47sq2xpjc9k066ilmb8z6dn0q6ymwjzlm196cd";
  };
in derivation {
  name = "hello-2.12.1-sparc";
  inherit system;
  builder = "\${pkgs.stdenv.shell}";
  PATH = "\${cc}/bin:\${pkgs.stdenv}/bin";
  args = [ "-c" ''
    set -e
    export PATH="\$PATH:/usr/gnu/bin:/usr/bin:/usr/sbin"
    mkdir -p build && cd build
    tar -xzf "\$src"
    cd hello-2.12.1
    ./configure --prefix="\$out" --host=sparcv9-sun-solaris2.11 --build=sparcv9-sun-solaris2.11 CC=cc
    make
    make install
  '' ];
  src = helloTar;
}
HELLO

echo "GATE-SETUP-OK"
