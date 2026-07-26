#!/usr/bin/env bash
# oi-pyrust.sh — build Rust-backed Python modules (cryptography, pydantic-core,
# rpds-py, orjson, tokenizers, maturin/pyo3 set) via pip against a cached solnix
# interpreter, with rust-1.84.0 + maturin + openssl3 wired in. Runs ON a builder.
# Anti-wedge: launched detached via oi-job. Same RESULT<TAB> output as oi-pymod.
#
#   oi-pyrust.sh <python-bin> <tag> <import-name>=<pip-spec> [more...]
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix

GCC=$(ls -d /nix/store/*illumos-gcc14 2>/dev/null | head -1)
RUST=$(ls -d /nix/store/*rust-1.84.0 2>/dev/null | head -1)
MATURIN=$(ls -d /nix/store/*maturin* 2>/dev/null | head -1)
OSSL=$(ls -d /nix/store/*openssl-3-3.4.0 2>/dev/null | head -1)
CCBIN="$GCC/usr/gcc/14/bin/gcc"; CXXBIN="$GCC/usr/gcc/14/bin/g++"

# rust + gcc runtime (rustc/cargo need libgcc_s at runtime); maturin bin on PATH
export PATH="$RUST/bin:${MATURIN:+$MATURIN/bin:}$PATH"
export LD_LIBRARY_PATH="$GCC/usr/gcc/14/lib/amd64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# openssl3 for the openssl-sys / cryptography build
export OPENSSL_DIR="$OSSL"
export OPENSSL_LIB_DIR="$OSSL/lib/64"
export OPENSSL_INCLUDE_DIR="$OSSL/include"
export PKG_CONFIG_PATH="$OSSL/lib/64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export OPENSSL_NO_VENDOR=1
# force real gcc for the C-ext parts
export CC="$CCBIN" CXX="$CXXBIN"
export LDSHARED="$CCBIN -shared -m64" LDCXXSHARED="$CXXBIN -shared -m64"
export CFLAGS="-m64 -fPIC -O2" LDFLAGS="-m64 -L$OSSL/lib/64 -R$OSSL/lib/64"
# cargo/rustc: use a writable home, target illumos, link gcc libs
export CARGO_HOME=/var/tmp/cargo-home CARGO_NET_RETRY=5
export RUSTFLAGS="-C link-arg=-L$GCC/usr/gcc/14/lib/amd64 -C link-arg=-R$GCC/usr/gcc/14/lib/amd64"
mkdir -p "$CARGO_HOME"

echo "rustc: $($RUST/bin/rustc --version 2>&1)  maturin: ${MATURIN:-none}  openssl: $OSSL"

PY="$1"; TAG="$2"; shift 2
PYMM=$("$PY" -c 'import sys;print("python%d.%d"%sys.version_info[:2])')

# Cached build backends (maturin 1.5.1, setuptools-rust) must be visible so pip
# does NOT try to build the latest maturin from source (needs rustc>=1.85 /
# edition-2024). Put every published py39 backend + this batch's outputs on
# PYTHONPATH and use --no-build-isolation.
BACKEND_PP=""
for bp in $(ls -d /nix/store/*py39-maturin*/lib/python3.9/site-packages \
                  /nix/store/*py39-setuptools-rust*/lib/python3.9/site-packages \
                  /nix/store/*py39-setuptools-scm*/lib/python3.9/site-packages \
                  /nix/store/*py39-semantic-version*/lib/python3.9/site-packages \
                  /nix/store/*py39-tomli-*/lib/python3.9/site-packages \
                  /nix/store/*py39-packaging-*/lib/python3.9/site-packages \
                  /nix/store/*py39-flit-core*/lib/python3.9/site-packages \
                  /nix/store/*py39-hatchling*/lib/python3.9/site-packages \
                  /nix/store/*py39-hatch-vcs*/lib/python3.9/site-packages \
                  /nix/store/*py39-editables*/lib/python3.9/site-packages \
                  /nix/store/*py39-pathspec*/lib/python3.9/site-packages \
                  /nix/store/*py39-pluggy*/lib/python3.9/site-packages \
                  /nix/store/*py39-calver*/lib/python3.9/site-packages \
                  /nix/store/*py39-trove-classifiers*/lib/python3.9/site-packages \
                  /nix/store/*py39-rpds-*/lib/python3.9/site-packages \
                  /nix/store/*py39-attrs*/lib/python3.9/site-packages \
                  /nix/store/*py39-typing-extensions*/lib/python3.9/site-packages \
                  /nix/store/*py39-cffi*/lib/python3.9/site-packages 2>/dev/null); do
  BACKEND_PP="$bp${BACKEND_PP:+:$BACKEND_PP}"
done
export PYTHONPATH="$BACKEND_PP${PYTHONPATH:+:$PYTHONPATH}"

for spec in "$@"; do
  name="${spec%%=*}"; pipspec="${spec#*=}"
  safe=$(printf '%s' "$name" | tr 'A-Z._' 'a-z--')
  d=$(mktemp -d "/var/tmp/pyrust.$safe.XXXXXX")
  if ! "$PY" -m pip install --no-cache-dir --no-warn-script-location \
        --no-build-isolation \
        --prefix="$d" "$pipspec" >"$d/.build.log" 2>&1; then
    echo "RESULT	$name	FAIL	pip-build (see log $d/.build.log)"
    tail -5 "$d/.build.log" | sed 's/^/  /'
    continue
  fi
  ver=$("$PY" - "$name" <<'EOF' 2>/dev/null || echo 0
import sys,importlib.metadata as m
try: print(m.version(sys.argv[1]))
except Exception: print("0")
EOF
)
  named="/var/tmp/${TAG}-${safe}-${ver:-0}"
  [ -e "$named" ] && named="$named.$$"
  cp -a "$d" "$named"
  SP_LIB="$named/lib/$PYMM/site-packages"
  "$PY" -m compileall -q -f "$SP_LIB" >/dev/null 2>&1 || true
  if PYTHONPATH="$SP_LIB" "$PY" -c "import $name" >/dev/null 2>&1; then ok=1
  else err=$(PYTHONPATH="$SP_LIB" "$PY" -c "import $name" 2>&1 | tail -1); ok=0; fi
  sp=$(nix-store --add "$named" 2>/dev/null)
  [ -n "$sp" ] || { echo "RESULT	$name	FAIL	nix-store-add"; continue; }
  if [ "$ok" = 1 ]; then echo "RESULT	$name	OK	$sp"
  else echo "RESULT	$name	FAIL	import: $err (built at $sp)"; fi
done
echo "=== oi-pyrust done ==="
