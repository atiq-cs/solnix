#!/usr/bin/env bash
# oi-pymod.sh — build Python modules via pip against a cached solnix interpreter,
# register each result as a Nix store path, and verify it imports on illumos.
# Runs ON a builder (Nix 2.3.16). Anti-wedge: launched detached via oi-job.
#
#   oi-pymod.sh <python-bin> <tag> <import-name>=<pip-spec> [more...]
#     tag        e.g. py39 / py313 (store-name prefix)
#     import-name used for the post-build `python -c 'import <name>'` check
#     pip-spec   what pip installs (name or name==ver)
#
# Output lines (parseable): RESULT<TAB>module<TAB>OK|FAIL<TAB>storepath|reason
# The store paths are collected by the orchestrator for sign+publish.
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
# solnix toolchain: make the cc wrapper the compiler for C-ext builds
GCC=/nix/store/1sif429w2gpwzxcjqljb481anq0y7wh2-illumos-gcc14
CCBIN="$GCC/usr/gcc/14/bin/gcc"
CXXBIN="$GCC/usr/gcc/14/bin/g++"
# Force the REAL gcc onto every C-ext build. The cached interpreters' sysconfig
# CC points at an ephemeral build-time wrapper (/tmp/solnix-build.../ccw/...)
# that no longer exists, so setuptools would fail (cffi) or silently fall back
# to a pure-python build (markupsafe). Override CC + LDSHARED so real C-exts
# actually compile+link.
export CC="$CCBIN" CXX="$CXXBIN"
export LDSHARED="$CCBIN -shared -m64" LDCXXSHARED="$CXXBIN -shared -m64"
export CFLAGS="-m64 -fPIC -O2" LDFLAGS="-m64"

PY="$1"; TAG="$2"; shift 2
PYMM=$("$PY" -c 'import sys;print("python%d.%d"%sys.version_info[:2])')

for spec in "$@"; do
  name="${spec%%=*}"; pipspec="${spec#*=}"
  safe=$(printf '%s' "$name" | tr 'A-Z._' 'a-z--')
  d=$(mktemp -d "/var/tmp/pymod.$safe.XXXXXX")
  if ! "$PY" -m pip install --no-cache-dir --no-warn-script-location \
        --prefix="$d" "$pipspec" >"$d/.build.log" 2>&1; then
    echo "RESULT	$name	FAIL	pip-build (see log $d/.build.log)"
    tail -3 "$d/.build.log" | sed 's/^/  /'
    continue
  fi
  # rename to a meaningful store name
  ver=$("$PY" - "$name" "$d/lib/$PYMM/site-packages" <<'EOF' 2>/dev/null || echo 0
import sys,importlib.metadata as m
try: print(m.version(sys.argv[1]))
except Exception: print("0")
EOF
)
  named="/var/tmp/solnix-${TAG}-${safe}-${ver:-0}"
  [ -e "$named" ] && named="$named.$$"
  cp -a "$d" "$named"
  # Precompile .pyc IN the dir first, and verify import here — BEFORE nix-store
  # --add — so nothing mutates the registered store path afterward (wave-2 debt:
  # importing against a live store path dirties it via .pyc writes -> hash drift
  # -> export fails). Verify against the dir copy, add only after it's frozen.
  SP_LIB="$named/lib/$PYMM/site-packages"
  "$PY" -m compileall -q -f "$SP_LIB" >/dev/null 2>&1 || true
  if PYTHONPATH="$SP_LIB" "$PY" -c "import $name" >/dev/null 2>&1; then
    ok=1
  else
    err=$(PYTHONPATH="$SP_LIB" "$PY" -c "import $name" 2>&1 | tail -1); ok=0
  fi
  # freeze: add to store AFTER all writes (compile + verify) are done
  sp=$(nix-store --add "$named" 2>/dev/null)
  if [ -z "$sp" ]; then echo "RESULT	$name	FAIL	nix-store-add"; continue; fi
  if [ "$ok" = 1 ]; then
    echo "RESULT	$name	OK	$sp"
  else
    echo "RESULT	$name	FAIL	import: $err (built at $sp)"
  fi
done
echo "=== oi-pymod done ==="
