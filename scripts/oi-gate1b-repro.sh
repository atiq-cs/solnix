#!/usr/bin/env bash
# gate1b-repro.sh — reproduce GATE 1b (from-source hello on x86_64-solaris) on a
# crackers illumos build host. Run FROM the dev box; it drives the host over ssh.
#
# GATE 1b: nix-build a from-source hello for x86_64-solaris -> it REALISES, the
# output bin/hello RUNS (prints Hello), and `nix-store -q --deriver <out>`
# resolves. Proved on SunOS 5.11 / Nix 2.3.16 (classic, at /nix-tools/bin/nix).
#
# Prereqs on the host (see docs/design-solaris-stdenv.md §7.1):
#   - /nix-tools/bin/nix (classic 2.3.16), /nix store+var
#   - python3 (for the tar shim), curl, gcc 14.3.0, ld, gmake, /usr/gnu coreutils
#
# What this does:
#   1. copies the tar shim + solnix-pkgs fork to the host
#   2. fetches pinned nixpkgs, applies the 4 fork patches + the minfeatures
#      >=2.18 bypass, nix-store --add the tree
#   3. builds a native-cc stdenv, then a from-source GNU hello, and prints proof
set -euo pipefail

IP="${1:?usage: gate1b-repro.sh <host-ip>}"
KEY="${CRACKER_KEY:-$HOME/.ssh/osv-ec2.pem}"
REV=7f81d69cbd67048635c5d30cd2649e4d018976bc
SSH="ssh -o StrictHostKeyChecking=no -i $KEY root@$IP"
HERE="$(cd "$(dirname "$0")/.." && pwd)"          # solnix repo root
FORK="${SOLNIX_PKGS:-$HOME/ws/solnix-pkgs}"

echo "== copy shim + fork =="
scp -o StrictHostKeyChecking=no -i "$KEY" "$HERE/scripts/oi-nix-tar-shim.py" "root@$IP:/root/tar-shim.py"
tar czf /tmp/solnix-pkgs.tgz -C "$FORK" --exclude=.git .
scp -o StrictHostKeyChecking=no -i "$KEY" /tmp/solnix-pkgs.tgz "root@$IP:/root/"

$SSH bash -s "$REV" <<'REMOTE'
set -euo pipefail
REV="$1"
export PATH=/root/shim/bin:/nix-tools/bin:/usr/gnu/bin:$PATH
export NIX_STORE_DIR=/nix/store NIX_STATE_DIR=/nix/var/nix

mkdir -p /root/shim/bin && cp /root/tar-shim.py /root/shim/bin/tar && chmod +x /root/shim/bin/tar
mkdir -p /root/solnix-pkgs && (cd /root/solnix-pkgs && tar xzf /root/solnix-pkgs.tgz)

echo "== fetch pinned nixpkgs =="
SRC=$(nix-prefetch-url --unpack --name nixpkgs-src --print-path "https://github.com/NixOS/nixpkgs/archive/$REV.tar.gz" | tail -1)
DST=/root/nixpkgs-patched
[ -e "$DST" ] && chmod -R u+w "$DST" && trash "$DST" 2>/dev/null || true
mkdir -p "$DST" && cp -a "$SRC"/. "$DST"/ && chmod -R u+w "$DST"
cd "$DST"
for p in /root/solnix-pkgs/patches/000[1-4]-*.patch; do patch -p1 --no-backup-if-mismatch < "$p"; done
# host Nix is 2.3.16; drop the nixpkgs >=2.18 abort (see design §7.1)
cat > lib/minfeatures.nix <<'MF'
let features = [ { description = "the `nixVersion` builtin"; condition = builtins ? nixVersion; } ];
    evaluated = builtins.partition ({ condition, ... }: condition) features;
in { all = features; supported = evaluated.right; missing = evaluated.wrong; }
MF
NPKGS=$(nix-store --add "$DST")
echo "NPKGS=$NPKGS"

cat > /root/entry.nix <<'ENTRY'
{ system ? "x86_64-solaris" }:
let overlay = final: prev: {
      solnix = final.callPackage /root/solnix-pkgs/pkgs/os-specific/illumos { };
      illumos = final.solnix;
    };
in import /root/nixpkgs-patched { inherit system; overlays = [ overlay ]; config = { allowUnsupportedSystem = true; }; }
ENTRY

cat > /root/hello-gnu.nix <<'HELLO'
{ system ? "x86_64-solaris" }:
let
  pkgs = import /root/entry.nix { inherit system; };
  cc = pkgs.stdenv.cc;
  helloTar = import <nix/fetchurl.nix> {
    url = "https://ftpmirror.gnu.org/hello/hello-2.12.1.tar.gz";
    sha256 = "086vqwk2wl8zfs47sq2xpjc9k066ilmb8z6dn0q6ymwjzlm196cd";
  };
in derivation {
  name = "hello-2.12.1";
  inherit system;
  builder = "/usr/bin/bash";
  PATH = "${cc}/bin:/root/shim/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:/sbin";
  args = [ "-c" ''
    set -e
    export PATH="$PATH"
    mkdir -p build && cd build
    tar -xzf "$src"
    cd hello-2.12.1
    ./configure --prefix="$out" --host=x86_64-pc-solaris2.11 --build=x86_64-pc-solaris2.11 CC=cc
    /usr/bin/gmake
    /usr/bin/gmake install
  '' ];
  src = helloTar;
}
HELLO

echo "== build stdenv cc =="
nix-build -E 'let p = import /root/entry.nix { system = "x86_64-solaris"; }; in p.stdenv.cc' --no-out-link
echo "== build GNU hello from source =="
OUT=$(nix-build /root/hello-gnu.nix --no-out-link | tail -1)
echo "######## GATE 1b PROOF ########"
echo "out:     $OUT"
echo "deriver: $(nix-store -q --deriver "$OUT")"
echo -n "stdout:  "; "$OUT/bin/hello"
REMOTE
