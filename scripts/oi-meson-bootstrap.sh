#!/bin/sh
# oi-meson-bootstrap.sh — stage meson + ninja onto an illumos builder that has
# g++/python3 but no pip/meson/ninja. ninja: single C++ bootstrap compile.
# meson: pure-python, runs straight from its release tree (no install needed).
# Installs to /opt/solnix-buildtools/bin (meson wrapper + ninja). Idempotent.
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
GCC=/usr/gcc/14; export CXX="$GCC/bin/g++" CC="$GCC/bin/gcc"
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
DEST=/opt/solnix-buildtools; BIN=$DEST/bin
mkdir -p "$BIN"
[ -s /var/tmp/ca-bundle.crt ] || cat /etc/certs/CA/*.pem > /var/tmp/ca-bundle.crt 2>/dev/null || true
DL="curl -fsSLk --cacert /var/tmp/ca-bundle.crt"

NINJA_VER=1.12.1
MESON_VER=1.4.2   # last series comfortable on py3.9; 1.5+ wants newer py

w=$(mktemp -d /var/tmp/mesonboot.XXXXXX); cd "$w"

# ---- ninja ----
if [ ! -x "$BIN/ninja" ]; then
  $DL -o ninja.tar.gz "https://github.com/ninja-build/ninja/archive/refs/tags/v$NINJA_VER.tar.gz" || { echo "FAIL ninja dl"; exit 1; }
  gzip -dc ninja.tar.gz | tar xf -
  cd "ninja-$NINJA_VER"
  # configure.py --bootstrap compiles ninja with $CXX; illumos needs the flag env
  CXXFLAGS="-m64 -O2 -D__EXTENSIONS__" LDFLAGS="-m64" python3 configure.py --bootstrap || { echo "FAIL ninja build"; exit 1; }
  cp ninja "$BIN/ninja"; chmod +x "$BIN/ninja"
  cd "$w"
fi
"$BIN/ninja" --version || { echo "FAIL ninja run"; exit 1; }

# ---- meson (pure python, run from tree) ----
if [ ! -x "$BIN/meson" ]; then
  $DL -o meson.tar.gz "https://github.com/mesonbuild/meson/releases/download/$MESON_VER/meson-$MESON_VER.tar.gz" || { echo "FAIL meson dl"; exit 1; }
  gzip -dc meson.tar.gz | tar xf -
  rm -rf "$DEST/meson-src"; mv "meson-$MESON_VER" "$DEST/meson-src"
  cat > "$BIN/meson" <<EOF
#!/bin/sh
exec /usr/bin/python3 $DEST/meson-src/meson.py "\$@"
EOF
  chmod +x "$BIN/meson"
fi
"$BIN/meson" --version || { echo "FAIL meson run"; exit 1; }
echo "STAGED ninja=$($BIN/ninja --version) meson=$($BIN/meson --version) at $BIN"
