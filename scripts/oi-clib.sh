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
# Also on success: RECIPE<TAB>pname<TAB>version<TAB>url<TAB>sha256<TAB>buildsys<TAB>deps<TAB>flags<TAB>system<TAB>out<TAB>debug
#   plus a matching TSV row written to $out/.solnix-recipe (travels in the nar),
#   so every published package records the exact args to replay it as a real
#   mkDerivation. See docs/registry/recipes.tsv.
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
GCC=/usr/gcc/14
CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
# portable core count: illumos has no nproc; psrinfo -p / kstat give CPU count.
# empty $(nproc) made `gmake -j` spawn unbounded compilers -> thrash/OOM ->
# compilers die with no diagnostic ("Error 1"). Cap at a sane number.
nproc() { n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || psrinfo 2>/dev/null | wc -l); n=${n:-4}; [ "$n" -gt 16 ] && n=16; echo "$n"; }
CMAKE=$(ls /nix/store/*cmake*/bin/cmake 2>/dev/null | head -1)

pname="$1"; ver="$2"; url="$3"; sha="$4"; bsys="$5"; shift 5
deps=""; flags=""
sawdd=0
for a in "$@"; do
  if [ "$a" = "--" ]; then sawdd=1; continue; fi
  if [ "$sawdd" = 1 ]; then flags="$flags $a"; else deps="$deps $a"; fi
done

# dep include/lib/rpath + cmake prefix + pkg-config path (deps ship .pc files;
# autotools/cmake/meson all consult pkg-config, so point it at the dep libdirs).
DEPI=""; DEPL=""; DEPR=""; CMPREFIX=""; PCP=""
# sanitized pkgconfig overlay: some cached deps were frozen with a stale
# /var/tmp/clib.*/out prefix baked into their .pc (includedir/libdir written
# absolute, so the ${pcfiledir} relocation missed them). Copy each dep .pc into
# an overlay and rewrite any dead /var/tmp/clib.*/out root to the real dep path.
_pcovl=$(mktemp -d /var/tmp/pcovl.XXXXXX)
for d in $deps; do
  [ -d "$d/include" ] && DEPI="$DEPI -I$d/include"
  # nested include dirs (freetype2, glib-2.0, glib arch-include, etc.)
  for sub in "$d/include"/* "$d/lib"/*/include; do
    [ -d "$sub" ] && DEPI="$DEPI -I$sub"
  done
  for L in "$d/lib" "$d/lib/64"; do
    [ -d "$L" ] && { DEPL="$DEPL -L$L"; DEPR="$DEPR -R$L"; }
  done
  for P in "$d/lib/pkgconfig" "$d/lib/64/pkgconfig" "$d/share/pkgconfig"; do
    [ -d "$P" ] || continue
    for pc in "$P"/*.pc; do
      [ -f "$pc" ] || continue
      sed "s|/var/tmp/clib\.[^/]*/out|$d|g; s|/var/tmp/mk\.[^/]*/out|$d|g" "$pc" > "$_pcovl/$(basename "$pc")"
    done
  done
  CMPREFIX="$CMPREFIX${CMPREFIX:+;}$d"
done
PCP="$_pcovl"
export PKG_CONFIG_PATH="$PCP${PKG_CONFIG_PATH:+:}${PKG_CONFIG_PATH:-}"
export CFLAGS="-m64 -fPIC -O2 -g -D__EXTENSIONS__ $DEPI ${EXTRA_CFLAGS:-}"
export CXXFLAGS="$CFLAGS ${EXTRA_CXXFLAGS:-}"
export CPPFLAGS="$DEPI ${EXTRA_CPPFLAGS:-}"
export LDFLAGS="-m64 $DEPL $DEPR ${EXTRA_LDFLAGS:-}"
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"

# --- wave22 reusable family-fix knobs (see pkgs/illumos/packages.nix) ---
# CXXMATHNS=1: bring C math names into the global ns for C++ that assumes
#   ::isnan/::isinf/::signbit (illumos libstdc++ only exposes them in std::).
if [ "${CXXMATHNS:-}" = 1 ]; then
  cat > /var/tmp/cxx_mathns_illumos.$$.h <<'MATHNSEOF'
#ifndef SOLNIX_CXX_MATHNS_ILLUMOS_H
#define SOLNIX_CXX_MATHNS_ILLUMOS_H
#ifdef __cplusplus
#include <cmath>
using std::isnan; using std::isinf; using std::signbit;
using std::isfinite; using std::isnormal; using std::fpclassify;
#endif
#endif
MATHNSEOF
  export CXXFLAGS="$CXXFLAGS -include /var/tmp/cxx_mathns_illumos.$$.h"
fi
# LDVERSCRIPT_STRIP=1: interpose a CC/CXX shim that filters GNU link options
#   Solaris ld rejects out of the link. Handles --version-script (symbols keep
#   default global scope) AND GNU --as-needed/--no-as-needed (Solaris ld links
#   needed-only by default, so dropping them is harmless). Python's libpython3.so
#   compat rule and many autotools libtool links pass --no-as-needed.
if [ "${LDVERSCRIPT_STRIP:-}" = 1 ]; then
  _shim=/var/tmp/ldshim.$$; mkdir -p "$_shim"
  for _pair in "cc:$CC" "cxx:$CXX"; do
    _nm="${_pair%%:*}"; _real="${_pair#*:}"
    cat > "$_shim/$_nm" <<LDSHIMEOF
#!/bin/sh
_a=""; _skip=0
for x in "\$@"; do
  if [ "\$_skip" = 1 ]; then _skip=0; continue; fi
  case "\$x" in
    -Wl,--version-script,*|-Wl,--version-script) continue ;;
    -Wl,--version-script=*) continue ;;
    -Wl,-M,*|-Wl,-M) continue ;;
    --version-script=*) continue ;;
    --version-script) _skip=1; continue ;;
    -Wl,--no-as-needed|-Wl,--as-needed) continue ;;
    --no-as-needed|--as-needed) continue ;;
    -Wl,--gc-sections|--gc-sections) continue ;;
    -Wl,--exclude-libs,*|-Wl,--exclude-libs) continue ;;
    -Wl,--exclude-libs=*|--exclude-libs=*) continue ;;
    --exclude-libs) _skip=1; continue ;;
    -Wl,--build-id|-Wl,--build-id=*) continue ;;
    -Wl,--export-dynamic|--export-dynamic|-rdynamic|-Wl,-E) continue ;;
    -Wl,-pie|-pie|-Wl,-z,relro,-z,now) continue ;;
    -Wl,-z,relro|-Wl,-z,now|-Wl,-z,relro,*|-Wl,-z,now,*|-z,relro|-z,now) continue ;;
    -fPIE) continue ;;
    -Wl,-z,noexecstack|-Wl,-z,noexecstack,*|-Wl,-z,execstack) continue ;;
  esac
  _a="\$_a \$x"
done
exec $_real \$_a
LDSHIMEOF
    chmod +x "$_shim/$_nm"
  done
  CC="$_shim/cc"; CXX="$_shim/cxx"; export CC CXX
fi

w=$(mktemp -d "/var/tmp/clib.$pname.XXXXXX")
tb="$w/src.tar"
# freedesktop.org's release-tarball leaf cert is chronically expired server-side
# (x.org 301-redirects there). We can't fix a remote expired leaf; integrity is
# instead enforced by the sha256 pin below, so fetch with -k. Prefer a CA bundle
# assembled from /etc/certs/CA when present.
[ -s /var/tmp/ca-bundle.crt ] || cat /etc/certs/CA/*.pem > /var/tmp/ca-bundle.crt 2>/dev/null || true
DLCA=""; [ -s /var/tmp/ca-bundle.crt ] && DLCA="--cacert /var/tmp/ca-bundle.crt"
curl -fsSLk $DLCA -o "$tb" "$url" 2>"$w/.dl" || { echo "RESULT	$pname	FAIL	download"; exit 1; }
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

# GNULIBFIX=1 (wave23): apply Family-1 gnulib getlocalename_l const-qualify sweep
#   to the native oi-clib path (mirrors packages.nix gnulibFix). illumos libc
#   declares `const char *getlocalename_l(...)`; gnulib redeclares it non-const.
#   Idempotent, safe-if-absent; sweeps every vintage of the file across lib/.
if [ "${GNULIBFIX:-}" = 1 ]; then
  find "$sd" -type f \( -name 'localename*.c' -o -name 'localename*.h' \
      -o -name 'getlocalename_l*.c' -o -name 'getlocalename_l*.h' \
      -o -name 'setlocale_null*.c' \) 2>/dev/null | while read -r gf; do
    # match `char *getlocalename_l` and `char * getlocalename_l`, with/without extern
    sed -i 's/\(char[[:space:]]*\*[[:space:]]*\)getlocalename_l/const \1getlocalename_l/g' "$gf" 2>/dev/null || true
    # collapse an accidental double-const from re-runs (idempotent)
    sed -i 's/const const /const /g' "$gf" 2>/dev/null || true
  done
fi

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
      # github archives often ship no ./configure; regenerate it (root-cause fix,
      # benefits every wave). autogen.sh/bootstrap preferred, else autoreconf -fi.
      if [ ! -x ./configure ]; then
        if [ -x ./autogen.sh ]; then NOCONFIGURE=1 ./autogen.sh || ./autogen.sh || true
        elif [ -x ./bootstrap ]; then ./bootstrap || true
        elif [ -x ./buildconf.sh ]; then ./buildconf.sh || true
        fi
        [ -x ./configure ] || autoreconf -fi 2>/dev/null || true
      fi
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

# --- make .pc files relocatable (root-cause fix, benefits every wave) ---
# oi-clib installs to a temp $out, then copies to the content-addressed store
# path whose hash we can't know in advance. autotools bakes prefix=$out into the
# .pc, so downstream pkg-config resolves includedir/libdir to a nonexistent temp
# dir (broke libX11's keysym check against xorgproto). Rewrite the absolute
# prefix to pkg-config's built-in ${pcfiledir} anchor: .pc files live two levels
# below prefix (lib/pkgconfig, lib/64/pkgconfig, or share/pkgconfig), so
# ${pcfiledir}/../.. is the prefix regardless of final store path.
find "$out" -name '*.pc' -type f 2>/dev/null | while read -r pc; do
  sed -i "s|^prefix=$out\b|prefix=\${pcfiledir}/../..|; s|^prefix=$out|prefix=\${pcfiledir}/../..|" "$pc" 2>/dev/null || true
done

# --- drop libtool .la archives (root-cause fix, benefits every wave) ---
# .la files bake libdir='<temp build $out>/lib' and absolute dependency_libs;
# downstream libtool follows them and dies ("not a valid libtool archive") since
# the temp path is gone after freeze. pkg-config .pc files (fixed above) carry the
# real link info, so .la files are redundant and actively harmful here. nixpkgs
# strips them for the same reason. This unblocked libXrender/libXi/libXt/libXpm.
find "$out" -name '*.la' -type f -delete 2>/dev/null || true

# --- record a replayable recipe (self-describing package + stdout harvest) ---
# sha may have been passed as `-`; pin the tarball's real digest now that it's
# verified/downloaded, so a future rebuild can reconstruct the mkDerivation.
rsha="$sha"
if [ -z "$rsha" ] || [ "$rsha" = "-" ]; then
  rsha=$(digest -a sha256 "$tb" 2>/dev/null || sha256sum "$tb" 2>/dev/null | awk '{print $1}')
fi
rsystem="$(uname -p 2>/dev/null || uname -m 2>/dev/null)-solaris"
rdeps=$(echo "$deps" | sed 's/^ *//; s/ *$//')
rflags=$(echo "$flags" | sed 's/^ *//; s/ *$//')
# .solnix-recipe carries out/debug as placeholders (real paths only known after
# nix-store --add below); the stdout RECIPE line carries the resolved paths.
printf 'RECIPE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$pname" "$ver" "$url" "$rsha" "$bsys" "$rdeps" "$rflags" "$rsystem" "" "" \
  > "$out/.solnix-recipe"

# --- freeze OUT root (plain <pname>-<version>) ---
named="/var/tmp/${pname}-${ver}"; [ -e "$named" ] && named="$named.$$"
cp -a "$out" "$named"

# --- split debug info into a SEPARATE plain-named root <pname>-<version>-debug
dbg="/var/tmp/${pname}-${ver}-debug"; [ -e "$dbg" ] && dbg="$dbg.$$"
mkdir -p "$dbg/lib/debug/.build-id"
OBJCOPY=$(ls /usr/gnu/bin/gobjcopy /usr/gnu/bin/objcopy 2>/dev/null | head -1)
OBJDUMP=$(ls /usr/gnu/bin/gobjdump /usr/gnu/bin/objdump 2>/dev/null | head -1)
ELFEDIT=/usr/bin/elfedit
set +e
find "$named" -type f 2>/dev/null | while read -r f; do
  "$OBJDUMP" -h "$f" 2>/dev/null | grep -q '\.debug_info' || continue
  chmod u+w "$f" 2>/dev/null
  # build-id: prefer an existing GNU note; else inject a REAL .note.gnu.build-id
  # (Solaris ld emits none). build-id = sha1 of the linked ELF (40 hex, unique per
  # build); objcopy --add-section builds a PROGBITS section, elfedit retypes it to
  # SHT_NOTE so readelf/gdb parse it. gdb then finds the split debug BY build-id
  # (proven: gdb resolves source-level symbols from lib/debug/.build-id/XX/YY.debug).
  bid=$("$OBJDUMP" -s -j .note.gnu.build-id "$f" 2>/dev/null | awk '/^ /{for(i=2;i<=5;i++)printf $i}' | tail -c +33 2>/dev/null)
  if [ ${#bid} -ne 40 ]; then
    bid=$(/usr/bin/sha1sum "$f" | awk '{print $1}')
    _note=$(mktemp)
    # note: namesz=4 "GNU\0", descsz=20, type=3, 20-byte sha1. Pure printf.
    printf '\004\000\000\000\024\000\000\000\003\000\000\000GNU\000'"$(echo "$bid" | sed 's/../\\x&/g')" > "$_note"
    "$OBJCOPY" --add-section .note.gnu.build-id="$_note" \
      --set-section-flags .note.gnu.build-id=alloc,readonly "$f" 2>/dev/null \
      && "$ELFEDIT" -e "shdr:sh_type .note.gnu.build-id SHT_NOTE" "$f" 2>/dev/null
    rm -f "$_note"
  fi
  pre=$(printf '%s' "$bid" | cut -c1-2); rest=$(printf '%s' "$bid" | cut -c3-)
  dst="$dbg/lib/debug/.build-id/$pre"; mkdir -p "$dst"
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
# machine-readable recipe with the resolved store paths, for immediate harvest
# into docs/registry/recipes.tsv by the wave driver / oi-fleet-publish.sh.
printf 'RECIPE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$pname" "$ver" "$url" "$rsha" "$bsys" "$rdeps" "$rflags" "$rsystem" "$spo" "$spd"
