#!/usr/bin/bash
# go-pkg-build.sh -- builder for go.nix goPkg: `go build` offline from the vendor FOD
# (GOFLAGS=-mod=vendor), store RUNPATH via -ldflags -r, then the closure gate + the check.
# Vendor mode (vendorOnly): `go mod vendor` with the network, output pinned by its NAR hash.
set -eu
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
W=$NIX_BUILD_TOP; cd "$W"
export HOME=$W GOCACHE=$W/cache GOPATH=$W/gopath CGO_ENABLED=0 GOTOOLCHAIN=local GOPROXY=${GOPROXY:-off}
# $src is the tree go.nix unpacked (builtin:unpack-channel puts the single top-level dir at tree/).
# illumos cp lchowns copied symlinks to root and warns EPERM as nixbld (exit 0); drop just that line.
mkdir -p "$W/src"; cp -RP "$src/tree" "$W/src/s" 2> "$W/cp.err" || { cat "$W/cp.err" >&2; exit 1; }
grep -v 'cannot change owner and group of' "$W/cp.err" >&2 || :; chmod -R u+w "$W/src/s"; cd "$W/src/s"
[ -f go.mod ] || { echo "FATAL: no go.mod at the top of the unpacked source" >&2; exit 1; }
if [ -n "$vendorOnly" ]; then
  export GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org SSL_CERT_FILE
  "$go/bin/go" mod vendor
  cp -a vendor "$out"; cp go.sum "$out/.go.sum" 2>/dev/null || : > "$out/.go.sum"
  exit 0
fi
# a module that commits its own vendor/ (lazygit) builds from it; the FOD is then unused.
if [ -d vendor ] && [ -f vendor/modules.txt ]; then export GOFLAGS=-mod=vendor
elif [ -d "$goVendor" ]; then cp -a "$goVendor" vendor; chmod -R u+w vendor
  cmp -s go.sum vendor/.go.sum || [ ! -f go.sum ] || { echo "FATAL: vendor FOD is for another go.sum" >&2; exit 1; }
  rm -f vendor/.go.sum; export GOFLAGS=-mod=vendor; fi
eval "$prep"
mkdir -p "$out/bin"
for p in $subPkgs; do
  "$go/bin/go" build -trimpath -ldflags "-r $rp $ldflags" -o "$out/bin/" "$p"
done
eval "$man"
bash "$storeGate" "$out" "$tsErrnoGate" "$go"
cd "$W"; eval "$check"
echo "=== $name: check passed ===" >&2
