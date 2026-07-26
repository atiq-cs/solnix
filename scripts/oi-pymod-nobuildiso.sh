#!/usr/bin/env bash
# oi-pymod-nobuildiso.sh — build Python modules with the PEP-517 backends
# (hatchling / flit-core / poetry-core / pdm-backend / setuptools-scm) already
# on PYTHONPATH and pip's build isolation OFF. Wave-4 pure-python fails were
# almost all "backend not found in the isolated build env"; installing them into
# the base env + --no-build-isolation fixes those without touching the recipe.
#
#   oi-pymod-nobuildiso.sh <python-bin> <tag> <backends-pythonpath> name=spec ...
# backends-pythonpath = colon-joined site-packages dirs of the cached backends.
# Output: RESULT<TAB>module<TAB>OK|FAIL<TAB>storepath|reason
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
GCC=/nix/store/1sif429w2gpwzxcjqljb481anq0y7wh2-illumos-gcc14
CCBIN="$GCC/usr/gcc/14/bin/gcc"; CXXBIN="$GCC/usr/gcc/14/bin/g++"
export CC="$CCBIN" CXX="$CXXBIN"
export LDSHARED="$CCBIN -shared -m64" LDCXXSHARED="$CXXBIN -shared -m64"
export CFLAGS="-m64 -fPIC -O2" LDFLAGS="-m64"

PY="$1"; TAG="$2"; BACKENDS="$3"; shift 3
PYMM=$("$PY" -c 'import sys;print("python%d.%d"%sys.version_info[:2])')
export PYTHONPATH="$BACKENDS"

for spec in "$@"; do
  name="${spec%%=*}"; pipspec="${spec#*=}"
  imp="${name}"
  safe=$(printf '%s' "$name" | tr 'A-Z._' 'a-z--')
  d=$(mktemp -d "/var/tmp/pymod.$safe.XXXXXX")
  # --no-build-isolation: use the backends we put on PYTHONPATH instead of pip
  # fetching them into a sandbox (which fails offline / with our odd env).
  if ! "$PY" -m pip install --no-cache-dir --no-build-isolation --no-warn-script-location \
        --prefix="$d" "$pipspec" >"$d/.build.log" 2>&1; then
    echo "RESULT	$name	FAIL	pip-build (see $d/.build.log)"
    tail -3 "$d/.build.log" | sed 's/^/  /'
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
  if PYTHONPATH="$SP_LIB:$BACKENDS" "$PY" -c "import $imp" >/dev/null 2>&1; then ok=1; else
    err=$(PYTHONPATH="$SP_LIB:$BACKENDS" "$PY" -c "import $imp" 2>&1 | tail -1); ok=0; fi
  sp=$(nix-store --add "$named" 2>/dev/null)
  [ -n "$sp" ] || { echo "RESULT	$name	FAIL	nix-store-add"; continue; }
  if [ "$ok" = 1 ]; then echo "RESULT	$name	OK	$sp"; else
    echo "RESULT	$name	FAIL	import: $err (built at $sp)"; fi
done
echo "=== oi-pymod-nobuildiso done ==="
