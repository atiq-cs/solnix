#!/bin/sh
# oi-pillow.sh <python-bin> <tag> — build Pillow against cached libjpeg-turbo /
# zlib / libpng / freetype / lcms2, register a plain-named store path, verify it
# imports AND has a working JPEG codec on illumos. Anti-wedge: via oi-job.
# Output: RESULT<TAB>pillow<TAB>OK|FAIL<TAB>storepath|reason
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
GCC=/usr/gcc/14
CCBIN="$GCC/bin/gcc"; export CC="$CCBIN"
export LDSHARED="$CCBIN -shared -m64"

# imaging libs (passed as store paths in args after py/tag)
PY="$1"; TAG="$2"; shift 2
JPEG="$1"; ZLIB="$2"; PNG="$3"; FT="$4"; LCMS="$5"
PYMM=$("$PY" -c 'import sys;print("python%d.%d"%sys.version_info[:2])')

INC="-I$JPEG/include -I$ZLIB/include -I$PNG/include -I$FT/include/freetype2 -I$FT/include -I$LCMS/include"
LIB="-L$JPEG/lib -L$ZLIB/lib -L$PNG/lib -L$FT/lib -L$LCMS/lib"
RP="-R$JPEG/lib -R$ZLIB/lib -R$PNG/lib -R$FT/lib -R$LCMS/lib -R$GCC/lib/amd64"
export CFLAGS="-m64 -fPIC -O2 $INC"
export LDFLAGS="-m64 $LIB $RP"
export CPATH="$JPEG/include:$ZLIB/include:$PNG/include:$FT/include/freetype2:$LCMS/include"
export LIBRARY_PATH="$JPEG/lib:$ZLIB/lib:$PNG/lib:$FT/lib:$LCMS/lib"
export LD_LIBRARY_PATH="$JPEG/lib:$ZLIB/lib:$PNG/lib:$FT/lib:$LCMS/lib:$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"

d=$(mktemp -d /var/tmp/pillow.XXXXXX)
# Pillow build backend needs setuptools+wheel; use --no-build-isolation so our
# CC/CFLAGS apply, and force-enable the codecs we provide so a missing one FAILS
# the build (rather than silently producing a no-JPEG Pillow like the old one).
# PILLOW_SPEC lets the caller pin a version compatible with the cached
# setuptools (58.x) + interpreter (older setuptools can't build Pillow 11's
# setuptools>=67 backend requirement); WHEEL_PP adds a cached wheel to the path.
PSPEC="${PILLOW_SPEC:-pillow}"
export PYTHONPATH="${WHEEL_PP:-}${PYTHONPATH:+:$PYTHONPATH}"
export MAX_CONCURRENCY="$(nproc)"
# NO_ISOLATION=0 lets pip fetch a modern setuptools+wheel into an isolated build
# env (needed when the interpreter has no cached setuptools, e.g. py313); the C
# compile still honors our CC/CFLAGS/LDFLAGS from the environment.
ISO="--no-build-isolation"
[ "${NO_ISOLATION:-1}" = 0 ] && ISO=""
# Pillow reads these to force-require features (build fails if lib not found):
if ! "$PY" -m pip install --no-cache-dir $ISO --no-warn-script-location \
      --prefix="$d" \
      --config-settings="-C=jpeg=enable" \
      --config-settings="-C=zlib=enable" \
      --config-settings="-C=freetype=enable" \
      --config-settings="-C=lcms=enable" \
      "$PSPEC" >"$d/.build.log" 2>&1; then
  # fallback: plain build (env CFLAGS/LDFLAGS still route the libs)
  if ! "$PY" -m pip install --no-cache-dir $ISO --no-warn-script-location \
        --prefix="$d" "$PSPEC" >>"$d/.build.log" 2>&1; then
    echo "RESULT	pillow	FAIL	pip-build"; tail -20 "$d/.build.log" | sed 's/^/  /'; exit 1
  fi
fi
ver=$("$PY" - <<'EOF' 2>/dev/null || echo 0
import importlib.metadata as m
try: print(m.version("pillow"))
except Exception: print("0")
EOF
)
named="/var/tmp/${TAG}-pillow-${ver:-0}"; [ -e "$named" ] && named="$named.$$"
cp -a "$d" "$named"
SP="$named/lib/$PYMM/site-packages"
"$PY" -m compileall -q -f "$SP" >/dev/null 2>&1 || true
# verify import AND a real JPEG round-trip (the whole point: prove the codec links)
if ! PYTHONPATH="$SP" "$PY" - <<EOF >"$named/.verify.log" 2>&1
from PIL import Image, features
import io
assert features.check("jpg"), "NO JPEG codec"
assert features.check("zlib"), "NO zlib"
im = Image.new("RGB",(8,8),(200,100,50))
b = io.BytesIO(); im.save(b,"JPEG"); b.seek(0)
im2 = Image.open(b); im2.load()
print("PILLOW-OK jpg=%s zlib=%s freetype=%s lcms=%s size=%s" % (
  features.check("jpg"), features.check("zlib"),
  features.check("freetype2"), features.check("littlecms2"), im2.size))
EOF
then
  echo "RESULT	pillow	FAIL	verify"; cat "$named/.verify.log" | sed 's/^/  /'; exit 1
fi
sp=$(nix-store --add "$named")
nix-store --add-root /var/tmp/gcroots/$(basename "$sp"|cut -d- -f1) --indirect --realise "$sp" >/dev/null 2>&1 || true
echo "RESULT	pillow	OK	$sp"
sed 's/^/  /' "$named/.verify.log"
