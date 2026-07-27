#!/bin/sh
# oi-lxml.sh <python-bin> <tag> — build lxml against the cached libxml2/libxslt.
# Registers a plain-named store path, verifies import on illumos. Anti-wedge:
# launched detached via oi-job. Output: RESULT<TAB>lxml<TAB>OK|FAIL<TAB>path.
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
GCC=""; [ -x /nix/store/1sif429w2gpwzxcjqljb481anq0y7wh2-illumos-gcc14/usr/gcc/14/bin/gcc ] \
  && GCC=/nix/store/1sif429w2gpwzxcjqljb481anq0y7wh2-illumos-gcc14
CCBIN="$GCC/usr/gcc/14/bin/gcc"
export CC="$CCBIN" LDSHARED="$CCBIN -shared -m64"
XML2=/nix/store/w0m0b7qianh3jq2h4mfky8xdjwk0237y-libxml2-2.12.9
XSLT=/nix/store/9vc94j1yklsjp74swndafxbbv24ij37d-libxslt-1.1.39
export CFLAGS="-m64 -fPIC -O2 -I$XML2/include/libxml2 -I$XSLT/include"
export LDFLAGS="-m64 -L$XML2/lib -L$XSLT/lib -R$XML2/lib -R$XSLT/lib"
export LD_LIBRARY_PATH="$XML2/lib:$XSLT/lib:$GCC/usr/gcc/14/lib/amd64:$GCC/usr/gcc/14/lib:${LD_LIBRARY_PATH:-}"
# Build backends (setuptools/wheel/Cython) come from the cache via BUILD_PYTHONPATH.
export PYTHONPATH="${BUILD_PYTHONPATH:-}:${PYTHONPATH:-}"

PY="$1"; TAG="$2"
PYMM=$("$PY" -c 'import sys;print("python%d.%d"%sys.version_info[:2])')
d=$(mktemp -d /var/tmp/lxml.XXXXXX)
# lxml's setup.py runs xml2-config/xslt-config from PATH to locate the libs.
# --global-option is ignored under PEP517, so expose the config scripts on PATH
# and disable build isolation so the probe sees our CFLAGS/LDFLAGS.
export PATH="$XML2/bin:$XSLT/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=
if ! "$PY" -m pip install --no-cache-dir --no-build-isolation --no-warn-script-location \
      --prefix="$d" \
      --config-settings="--build-option=build_ext" \
      --config-settings="--build-option=--with-xml2-config=$XML2/bin/xml2-config" \
      --config-settings="--build-option=--with-xslt-config=$XSLT/bin/xslt-config" \
      "lxml" >"$d/.build.log" 2>&1; then
  # fallback: plain build, config scripts on PATH + CFLAGS/LDFLAGS route
  if ! "$PY" -m pip install --no-cache-dir --no-build-isolation --no-warn-script-location \
        --prefix="$d" "lxml" >>"$d/.build.log" 2>&1; then
    echo "RESULT	lxml	FAIL	pip-build"; tail -8 "$d/.build.log" | sed 's/^/  /'; exit 1
  fi
fi
ver=$("$PY" - "$d/lib/$PYMM/site-packages" <<'EOF' 2>/dev/null || echo 0
import sys,importlib.metadata as m
try: print(m.version("lxml"))
except Exception: print("0")
EOF
)
named="/var/tmp/${TAG}-lxml-${ver:-0}"; [ -e "$named" ] && named="$named.$$"
cp -a "$d" "$named"
SP="$named/lib/$PYMM/site-packages"
"$PY" -m compileall -q -f "$SP" >/dev/null 2>&1 || true
# import-verify in the dir BEFORE freezing to a store path
if ! PYTHONPATH="$SP" "$PY" -c 'from lxml import etree; print(etree.LIBXML_VERSION)' >"$named/.import.log" 2>&1; then
  echo "RESULT	lxml	FAIL	import"; cat "$named/.import.log" | sed 's/^/  /'; exit 1
fi
sp=$(nix-store --add "$named")
nix-store --add-root /var/tmp/gcroots/$(basename "$sp" | cut -d- -f1) --indirect --realise "$sp" >/dev/null 2>&1 || true
echo "RESULT	lxml	OK	$sp"
