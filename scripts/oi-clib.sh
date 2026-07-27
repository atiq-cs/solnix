#!/bin/sh
# oi-clib.sh — build a native C library on illumos with /usr/gcc/14, split debug
# info into a SEPARATE plain-named store root (out + debug, both published), and
# count man pages (builder honors mandir). Runs ON a builder. Anti-wedge: via oi-job.
#
#   oi-clib.sh <pname> <version> <tarball-url> <sha256|-> <buildsys> [dep-prefix ...] -- [flags...]
#     buildsys = cmake | autotools | configure
#     dep-prefix = a store path (e.g. cached zlib) whose include+lib are added to
#                  CFLAGS/LDFLAGS/CMAKE_PREFIX_PATH; also added to RUNPATH.
#     flags after `--` are passed to configure or as extra -D to cmake.
# Output: RESULT<TAB><pname><TAB>OK|FAIL<TAB><out-path> <debug-path>|reason
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
GCC=/usr/gcc/14
CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
CMAKE=$(ls /nix/store/*cmake*/bin/cmake 2>/dev/null | head -1)

pname="$1"; ver="$2"; url="$3"; sha="$4"; bsys="$5"; shift 5
deps=""; flags=""
sawdd=0
for a in "$@"; do
  if [ "$a" = "--" ]; then sawdd=1; continue; fi
  if [ "$sawdd" = 1 ]; then flags="$flags $a"; else deps="$deps $a"; fi
done

# dep include/lib/rpath + cmake prefix
DEPI=""; DEPL=""; DEPR=""; CMPREFIX=""
for d in $deps; do
  [ -d "$d/include" ] && DEPI="$DEPI -I$d/include"
  for L in "$d/lib" "$d/lib/64"; do
    [ -d "$L" ] && { DEPL="$DEPL -L$L"; DEPR="$DEPR -R$L"; }
  done
  CMPREFIX="$CMPREFIX${CMPREFIX:+;}$d"
done
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ $DEPI ${EXTRA_CFLAGS:-}"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="$DEPI"
export LDFLAGS="-m64 $DEPL $DEPR"
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"

w=$(mktemp -d "/var/tmp/clib.$pname.XXXXXX")
tb="$w/src.tar"
curl -fsSL -o "$tb" "$url" 2>"$w/.dl" || { echo "RESULT	$pname	FAIL	download"; exit 1; }
if [ -n "$sha" ] && [ "$sha" != "-" ]; then
  got=$(digest -a sha256 "$tb" 2>/dev/null || sha256sum "$tb" | awk '{print $1}')
  [ "$got" = "$sha" ] || { echo "RESULT	$pname	FAIL	sha256 got=$got"; exit 1; }
fi
# python3 tarfile is pax-aware (illumos /usr/bin/tar mangles PAX 'x' headers into
# a stray @PaxHeader entry that confuses srcdir detection); fall back to tar.
( cd "$w" && python3 -c "import sys,tarfile; tarfile.open('$tb').extractall('.')" 2>/dev/null \
    || { gzip -dc "$tb" 2>/dev/null | tar xf - ; } 2>/dev/null \
    || { xz -dc "$tb" 2>/dev/null | tar xf - ; } 2>/dev/null \
    || tar xf "$tb" 2>/dev/null )
sd=$(find "$w" -maxdepth 1 -mindepth 1 -type d ! -name 'PaxHeaders*' ! -name '@PaxHeader' ! -name 'out' | head -1)
[ -d "$sd" ] || { echo "RESULT	$pname	FAIL	untar"; exit 1; }
out="$w/out"; mkdir -p "$out"

log="$w/.build.log"
(
  cd "$sd"
  case "$bsys" in
    cmake)
      [ -n "$CMAKE" ] || { echo "no cmake found"; exit 1; }
      mkdir -p _b && cd _b
      "$CMAKE" .. -DCMAKE_INSTALL_PREFIX="$out" \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
        -DCMAKE_PREFIX_PATH="$CMPREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_MANDIR="$out/share/man" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        $flags \
      && gmake -j"$(nproc)" && gmake install
      ;;
    autotools|configure)
      MANF=""
      ./configure --help 2>&1 | grep -q -- '--mandir' && MANF="--mandir=$out/share/man"
      ./configure --prefix="$out" $MANF $flags \
      && gmake -j"$(nproc)" && gmake install
      ;;
    *) echo "unknown buildsys $bsys"; exit 1;;
  esac
) >"$log" 2>&1
if [ $? -ne 0 ]; then
  echo "RESULT	$pname	FAIL	build"; tail -15 "$log" | sed 's/^/  /'; exit 1
fi

# --- relocate RUNPATH of every ELF to gcc runtime + own libdirs + dep libdirs
RP="$out/lib:$out/lib/64:$GCC/lib/amd64:$GCC/lib"
for d in $deps; do
  [ -d "$d/lib" ] && RP="$RP:$d/lib"; [ -d "$d/lib/64" ] && RP="$RP:$d/lib/64"
done
find "$out" -type f 2>/dev/null | while read -r f; do
  /usr/bin/elfedit -e "dyn:runpath $RP" "$f" 2>/dev/null || \
  /usr/bin/elfedit -e "dyn:rpath $RP" "$f" 2>/dev/null || true
done

# --- man count (systematic; write .manifest-man like the builder does) ---
mc=$(find "$out/share/man" "$out/man" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "$mc" > "$out/.manifest-man"

# --- freeze OUT root (plain <pname>-<version>) ---
named="/var/tmp/${pname}-${ver}"; [ -e "$named" ] && named="$named.$$"
cp -a "$out" "$named"

# --- split debug info into a SEPARATE plain-named root <pname>-<version>-debug
dbg="/var/tmp/${pname}-${ver}-debug"; [ -e "$dbg" ] && dbg="$dbg.$$"
mkdir -p "$dbg/lib/debug/.build-id"
OBJCOPY=$(ls /usr/gnu/bin/gobjcopy /usr/gnu/bin/objcopy 2>/dev/null | head -1)
OBJDUMP=$(ls /usr/gnu/bin/gobjdump /usr/gnu/bin/objdump 2>/dev/null | head -1)
set +e
find "$named" -type f 2>/dev/null | while read -r f; do
  "$OBJDUMP" -h "$f" 2>/dev/null | grep -q '\.debug_info' || continue
  bid=$("$OBJDUMP" -s -j .note.gnu.build-id "$f" 2>/dev/null | awk '/^ /{for(i=2;i<=5;i++)printf $i}' | tail -c +33 2>/dev/null)
  [ -z "$bid" ] && bid=$(/usr/bin/sha256sum "$f" | awk '{print $1}')
  pre=$(printf '%s' "$bid" | cut -c1-2); rest=$(printf '%s' "$bid" | cut -c3-)
  dst="$dbg/lib/debug/.build-id/$pre"; mkdir -p "$dst"
  chmod u+w "$f" 2>/dev/null
  "$OBJCOPY" --only-keep-debug "$f" "$dst/$rest.debug" 2>/dev/null || continue
  "$OBJCOPY" --strip-debug "$f" 2>/dev/null
  "$OBJCOPY" --add-gnu-debuglink="$dst/$rest.debug" "$f" 2>/dev/null
done
[ -n "$(ls -A "$dbg/lib/debug/.build-id" 2>/dev/null)" ] || \
  { echo "no split debug info for $pname-$ver" > "$dbg/lib/debug/.empty"; }
set -e

spo=$(nix-store --add "$named" 2>/dev/null)
spd=$(nix-store --add "$dbg" 2>/dev/null)
[ -n "$spo" ] || { echo "RESULT	$pname	FAIL	nix-store-add"; exit 1; }
nix-store --add-root /var/tmp/gcroots/$(basename "$spo"|cut -d- -f1) --indirect --realise "$spo" >/dev/null 2>&1 || true
nix-store --add-root /var/tmp/gcroots/$(basename "$spd"|cut -d- -f1)d --indirect --realise "$spd" >/dev/null 2>&1 || true
echo "RESULT	$pname	OK	$spo $spd (man=$mc)"
