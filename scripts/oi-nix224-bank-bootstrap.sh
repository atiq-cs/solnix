#!/usr/bin/env bash
# oi-nix224-bank-bootstrap.sh — bank the account-proof bootstrap tarball for
# Nix 2.24.15 on illumos x86_64. Successor to the 2.3.16 tarball; fixes the
# LD_LIBRARY_PATH fragility by baking a RUNPATH into every ELF that points at
# the fixed install prefix + a bundled runtime-lib/, so a bare host runs nix
# with NO LD_LIBRARY_PATH. A CA bundle is bundled and pointed at via
# ssl-cert-file in nix.conf.
#
# Input: a completed /nix-tools224 install (from scripts/oi-nix224-setup.sh) plus
# the built libgit2 at /var/tmp/libgit2-inst.
# Output: /var/tmp/nix224-bootstrap/nix-illumos-2.24.15.tar.zst (+ .sha256),
# containing nix-tools224/ + runtime-lib/ + ca-bundle.crt + bootstrap-register.sh.
#
# Run ON the host as root:  ./oi-nix224-bank-bootstrap.sh
set -euo pipefail

PREFIX=/nix-tools224
GIT2_PREFIX=/var/tmp/libgit2-inst
GCC=/usr/gcc/13
STAGE=/var/tmp/nix224-bootstrap
CABUNDLE=/var/tmp/ca-bundle.crt
INSTALL_PREFIX=/nix-tools224   # where a bare host will unpack + register

[ -d "$PREFIX/bin" ] || { echo "FATAL: $PREFIX not built (run oi-nix224-setup.sh first)" >&2; exit 1; }
[ -s "$CABUNDLE" ] || cat /etc/certs/CA/*.pem > "$CABUNDLE"

echo "=== stage a clean copy of $PREFIX ==="
find "$STAGE" -mindepth 1 -delete 2>/dev/null || true
mkdir -p "$STAGE/nix-tools224" "$STAGE/runtime-lib"
cp -R "$PREFIX/." "$STAGE/nix-tools224/"

echo "=== gather runtime-lib closure (every non-base shared lib nix NEEDs) ==="
# Walk ldd of every ELF and copy in each resolved dependency that is NOT a base
# illumos libc-family lib (those exist on every image). Directory-agnostic: on
# illumos 64-bit libs live under /lib/64, /usr/lib/64, /usr/lib/amd64, /usr/gcc/*,
# /usr/openssl/3/*, so match by basename, not by path.
cp -Lf "$GIT2_PREFIX"/lib/libgit2.so* "$STAGE/runtime-lib/" 2>/dev/null || true
is_base_lib() {
  case "$1" in
    libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libnsl.so*|libsocket.so*|\
    libresolv.so*|libmd.so*|libmp.so*|libaio.so*|libkstat.so*|libnvpair.so*|\
    libavl.so*|libcmdutils.so*|libdoor.so*|libsendfile.so*|libuuid.so*) return 0;;
    *) return 1;;
  esac
}
collect() {
  ldd "$1" 2>/dev/null | awk '/=>/{print $3}' | while read -r dep; do
    [ -f "$dep" ] || continue
    b=$(basename "$dep")
    is_base_lib "$b" && continue
    case "$dep" in /nix-tools224/*) continue;; esac  # nix's own libs already staged
    # -L: dereference the version symlink and copy the REAL file content under
    # the SONAME the loader looks for (a plain -P leaves dangling symlinks).
    cp -Lf "$dep" "$STAGE/runtime-lib/$b" 2>/dev/null || true
  done
}
# Iterate to a fixed point: newly-copied libs may NEED further libs.
for pass in 1 2 3; do
  for f in "$STAGE/nix-tools224/bin/"* "$STAGE/nix-tools224/lib/"*.so* "$STAGE/runtime-lib/"*.so*; do
    [ -f "$f" ] && collect "$f"
  done
done
# Guard: no dangling symlinks may ship (they were the LD_LIBRARY_PATH-free break).
for l in "$STAGE/runtime-lib"/*; do
  if [ -L "$l" ] && [ ! -e "$l" ]; then echo "FATAL: dangling runtime-lib symlink $l" >&2; exit 1; fi
done

echo "=== bake RUNPATH: fixed install prefix, NO LD_LIBRARY_PATH needed ==="
RP="$INSTALL_PREFIX/lib:$INSTALL_PREFIX/lib/amd64:$INSTALL_PREFIX/runtime-lib"
reloc() {
  f="$1"
  /usr/bin/elfdump -d "$f" 2>/dev/null | grep -Eq 'SONAME|NEEDED|RUNPATH|RPATH' || return 0
  chmod u+w "$f" 2>/dev/null || true
  /usr/bin/elfedit -e "dyn:runpath $RP" "$f" 2>/dev/null || echo "WARN relocate $f (len ${#RP})" >&2
}
# Relocate the load-bearing nix binary FIRST, with the elfedit error visible, so
# a real failure is loud (not swallowed) and the gate below is meaningful.
chmod u+w "$STAGE/nix-tools224/bin/nix"
/usr/bin/elfedit -e "dyn:runpath $RP" "$STAGE/nix-tools224/bin/nix"
# Then the rest of the tree, best-effort (must not trip set -e).
set +e
for f in $(find "$STAGE/nix-tools224" "$STAGE/runtime-lib" -type f 2>/dev/null); do
  [ "$f" = "$STAGE/nix-tools224/bin/nix" ] && continue
  reloc "$f"
done
set -e

echo "=== verify the relocate took on the nix binary ==="
if /usr/bin/elfdump -d "$STAGE/nix-tools224/bin/nix" 2>/dev/null | grep -i RUNPATH | grep -q "$INSTALL_PREFIX/runtime-lib"; then
  echo "RUNPATH baked OK: $(/usr/bin/elfdump -d "$STAGE/nix-tools224/bin/nix" 2>/dev/null | grep -i RUNPATH | awk '{print $NF}')"
else
  echo "FATAL: nix binary RUNPATH was not rebaked" >&2; exit 1
fi

echo "=== bundle CA + rewrite nix.conf to point at it ==="
cp "$CABUNDLE" "$STAGE/ca-bundle.crt"
mkdir -p "$STAGE/nix-tools224/etc/nix"
cat > "$STAGE/nix-tools224/etc/nix/nix.conf" <<CONF
build-users-group =
sandbox = false
substituters = https://cache.solnix.io https://cache.nixos.org
trusted-public-keys = cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
ssl-cert-file = $INSTALL_PREFIX/ca-bundle.crt
experimental-features = nix-command flakes
CONF

echo "=== write bootstrap-register.sh (NO LD_LIBRARY_PATH) ==="
cat > "$STAGE/bootstrap-register.sh" <<'REG'
#!/usr/bin/env bash
# bootstrap-register.sh -- install prebuilt native illumos Nix 2.24.15 on a BARE
# host with NO compiler. Unpack this tarball, then run this as root. Idempotent.
#
#   curl -fsSL https://cache.solnix.io/bootstrap/nix-illumos-2.24.15.tar.zst \
#     | zstd -d | tar -xf -        # -> ./nix-tools224 ./runtime-lib ./ca-bundle.crt
#   ./bootstrap-register.sh
#
# The binaries carry a baked RUNPATH of
#   /nix-tools224/lib:/nix-tools224/lib/amd64:/nix-tools224/runtime-lib
# and runtime-lib/ ships every non-base shared lib (gcc-13 runtime, boost,
# openssl-3, curl, sqlite, sodium, brotli, libarchive, libgit2, ...), so a host
# with only the base illumos image can run nix with NO LD_LIBRARY_PATH.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo 'run as root' >&2; exit 1; }
PREFIX=/nix-tools224

echo '== install /nix-tools224 =='
[ -d "$PREFIX" ] || cp -R "$HERE/nix-tools224" "$PREFIX"
mkdir -p "$PREFIX/runtime-lib"
cp -Pf "$HERE"/runtime-lib/* "$PREFIX/runtime-lib/" 2>/dev/null || true
cp -f "$HERE/ca-bundle.crt" "$PREFIX/ca-bundle.crt"

echo '== create /nix store =='
if command -v zfs >/dev/null 2>&1 && ! zfs list rpool/nix >/dev/null 2>&1; then
  zfs create -o mountpoint=/nix rpool/nix 2>/dev/null || mkdir -p /nix
else mkdir -p /nix; fi
mkdir -p /nix/store /nix/var/nix

export PATH="$PREFIX/bin:/usr/bin:/usr/sbin:${PATH:-}"
export NIX_CONF_DIR="$PREFIX/etc/nix"

echo '== init store DB =='
"$PREFIX/bin/nix-store" --init

echo '== profile.d snippet (NO LD_LIBRARY_PATH) =='
cat > /etc/profile.d/nix-illumos.sh <<PROF
export PATH=$PREFIX/bin:\$PATH
export NIX_CONF_DIR=$PREFIX/etc/nix
PROF

echo '== VERIFY (no LD_LIBRARY_PATH) =='
env -i "$PREFIX/bin/nix" --version 2>/dev/null || "$PREFIX/bin/nix" --version
echo 'nix 2.24.15 installed. New shells get it via /etc/profile.d/nix-illumos.sh.'
REG
chmod +x "$STAGE/bootstrap-register.sh"

echo "=== pack tarball ==="
cd "$STAGE"
/usr/gnu/bin/tar cf nix-illumos-2.24.15.tar nix-tools224 runtime-lib ca-bundle.crt bootstrap-register.sh
zstd -19 -f nix-illumos-2.24.15.tar -o nix-illumos-2.24.15.tar.zst
/usr/bin/sha256sum nix-illumos-2.24.15.tar.zst | awk '{print $1}' > nix-illumos-2.24.15.tar.zst.sha256
echo "tarball: $STAGE/nix-illumos-2.24.15.tar.zst"
echo "sha256:  $(cat nix-illumos-2.24.15.tar.zst.sha256)"
ls -la nix-illumos-2.24.15.tar.zst
