#!/bin/sh
# oi-cmeson.sh — build a meson-based C/C++ library on illumos with /usr/gcc/14,
# using the staged meson+ninja at /opt/solnix-buildtools/bin. Mirrors oi-clib.sh:
# dep include/lib/rpath/pkgconfig wiring, split debug, relocatable .pc, .la strip,
# RUNPATH relocation, nix-store add of a plain-named out + debug root.
#
#   oi-cmeson.sh <pname> <version> <tarball-url> <sha256|-> [dep-store-path ...] -- [meson -D flags...]
# Output: RESULT<TAB><pname><TAB>OK|FAIL<TAB><out> <debug>|reason
set -u
export PATH=/opt/solnix-buildtools/bin:/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
GCC=/usr/gcc/14
CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
MESON=/opt/solnix-buildtools/bin/meson
NINJA=/opt/solnix-buildtools/bin/ninja

# LDVERSCRIPT_STRIP=1: interpose a CC/CXX shim filtering GNU link options Solaris
# ld rejects (--version-script / -M / GNU --as-needed). meson defaults shared libs
# to -z defs and often adds a --version-script link_arg (libwnck, many GNOME libs);
# Solaris ld dies "unrecognized option '--version-script'". Dropping it keeps every
# symbol at default global scope (harmless) and lets the link complete. Mirrors
# oi-clib.sh's shim so the same knob works for both build systems.
if [ "${LDVERSCRIPT_STRIP:-}" = 1 ]; then
  _shim=/var/tmp/cmesonldshim.$$; mkdir -p "$_shim"
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
  esac
  _a="\$_a \$x"
done
exec $_real \$_a
LDSHIMEOF
    chmod +x "$_shim/$_nm"
  done
  CC="$_shim/cc"; CXX="$_shim/cxx"; export CC CXX
fi

pname="$1"; ver="$2"; url="$3"; sha="$4"; shift 4
deps=""; flags=""; sawdd=0
for a in "$@"; do
  if [ "$a" = "--" ]; then sawdd=1; continue; fi
  if [ "$sawdd" = 1 ]; then flags="$flags $a"; else deps="$deps $a"; fi
done

# Some cached deps were built before oi-clib's .pc relocation fix and bake a
# dead build-temp prefix (e.g. /var/tmp/clib.pcre2.XXXX/out) into their .pc,
# which downstream meson/gcc then feed as a nonexistent -I (fatal under
# -Werror=missing-include-dirs, e.g. glib). Root-cause fix that benefits every
# consumer: copy each dep's .pc into a writable shim dir with the stale prefix
# rewritten to the dep's REAL store path, and search that shim first.
PCSHIM=$(mktemp -d /var/tmp/pcshim.XXXXXX)
DEPI=""; DEPL=""; DEPR=""; PCP="$PCSHIM"
for d in $deps; do
  [ -d "$d/include" ] && DEPI="$DEPI -I$d/include"
  for L in "$d/lib" "$d/lib/64"; do
    [ -d "$L" ] && { DEPL="$DEPL -L$L"; DEPR="$DEPR -R$L"; }
    [ -d "$L/pkgconfig" ] && PCP="$PCP${PCP:+:}$L/pkgconfig"
  done
  [ -d "$d/share/pkgconfig" ] && PCP="$PCP${PCP:+:}$d/share/pkgconfig"
  for pcd in "$d/lib/pkgconfig" "$d/lib/64/pkgconfig" "$d/share/pkgconfig"; do
    [ -d "$pcd" ] || continue
    for pc in "$pcd"/*.pc; do
      [ -f "$pc" ] || continue
      # Rewrite EVERY dead build-temp absolute path (prefix/exec_prefix/libdir/
      # includedir/Libs/Cflags) to the dep's real store path. pd1-era .pc files
      # relocated only `prefix=` and left exec_prefix/libdir/includedir baking a
      # gone /var/tmp/clib.*/out (freetype2.pc), which meson/gcc then feed as a
      # dead -I (harfbuzz: ft2build.h not found). Also normalise a relocated
      # `prefix=${pcfiledir}/../..` to the real path (shim isn't 2 levels below).
      sed -e "s|/var/tmp/clib\.[^/]*/out|$d|g" \
          -e "s|/var/tmp/cmeson\.[^/]*/out|$d|g" \
          -e "s|^prefix=\${pcfiledir}/\.\./\.\.|prefix=$d|" \
          "$pc" > "$PCSHIM/$(basename "$pc")" 2>/dev/null || cp "$pc" "$PCSHIM/"
    done
  done
done
export PKG_CONFIG_PATH="$PCP${PKG_CONFIG_PATH:+:}${PKG_CONFIG_PATH:-}"
# __EXTENSIONS__ exposes illumos POSIX+SUS symbols; -lsocket -lnsl for gio/net.
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ $DEPI ${EXTRA_CFLAGS:-}"
export CXXFLAGS="$CFLAGS ${EXTRA_CXXFLAGS:-}"
export CPPFLAGS="$DEPI ${EXTRA_CPPFLAGS:-}"
export LDFLAGS="-m64 $DEPL $DEPR ${EXTRA_LDFLAGS:-}"
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"

[ -s /var/tmp/ca-bundle.crt ] || cat /etc/certs/CA/*.pem > /var/tmp/ca-bundle.crt 2>/dev/null || true
DLCA=""; [ -s /var/tmp/ca-bundle.crt ] && DLCA="--cacert /var/tmp/ca-bundle.crt"

w=$(mktemp -d "/var/tmp/cmeson.$pname.XXXXXX"); tb="$w/src.tar"
curl -fsSLk $DLCA -o "$tb" "$url" 2>"$w/.dl" || { echo "RESULT	$pname	FAIL	download"; exit 1; }
if [ -n "$sha" ] && [ "$sha" != "-" ]; then
  got=$(digest -a sha256 "$tb" 2>/dev/null || sha256sum "$tb" | awk '{print $1}')
  [ "$got" = "$sha" ] || { echo "RESULT	$pname	FAIL	sha256 got=$got"; exit 1; }
fi
( cd "$w" && python3 -c "import tarfile; tarfile.open('$tb').extractall('.')" 2>/dev/null \
    || { xz -dc "$tb" 2>/dev/null | tar xf - ; } 2>/dev/null \
    || { gzip -dc "$tb" 2>/dev/null | tar xf - ; } 2>/dev/null \
    || tar xf "$tb" 2>/dev/null )
sd=$(find "$w" -maxdepth 1 -mindepth 1 -type d ! -name 'PaxHeaders*' ! -name '@PaxHeader' ! -name 'out' | head -1)
[ -d "$sd" ] || { echo "RESULT	$pname	FAIL	untar"; exit 1; }
out="$w/out"; mkdir -p "$out"

log="$w/.build.log"
(
  cd "$sd"
  # native-file: point meson at gcc14 + pkg-config so it doesn't autodetect cc.
  cat > /var/tmp/native-$pname.$$.ini <<NFEOF
[binaries]
c = '$CC'
cpp = '$CXX'
pkgconfig = '/usr/bin/pkg-config'
NFEOF
  "$MESON" setup _b --prefix="$out" --libdir=lib --buildtype=plain \
      --wrap-mode=nodownload -Ddebug=true -Doptimization=2 \
      --native-file /var/tmp/native-$pname.$$.ini $flags \
  && "$NINJA" -C _b -j"$(nproc)" \
  && "$NINJA" -C _b install
) >"$log" 2>&1
if [ $? -ne 0 ]; then
  echo "RESULT	$pname	FAIL	build"
  echo "  --- first errors ---"; grep -E "FAILED:| error:|undefined|No such|cannot" "$log" | head -20 | sed 's/^/  /'
  echo "  --- full log: $log ---"
  exit 1
fi

RP="$out/lib:$out/lib/64:$GCC/lib/amd64:$GCC/lib"
for d in $deps; do
  [ -d "$d/lib" ] && RP="$RP:$d/lib"; [ -d "$d/lib/64" ] && RP="$RP:$d/lib/64"
done
find "$out" -type f 2>/dev/null | while read -r f; do
  /usr/bin/elfedit -e "dyn:runpath $RP" "$f" 2>/dev/null || \
  /usr/bin/elfedit -e "dyn:rpath $RP" "$f" 2>/dev/null || true
done

mc=$(find "$out/share/man" "$out/man" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "$mc" > "$out/.manifest-man"

find "$out" -name '*.pc' -type f 2>/dev/null | while read -r pc; do
  sed -i "s|^prefix=$out\b|prefix=\${pcfiledir}/../..|; s|^prefix=$out|prefix=\${pcfiledir}/../..|" "$pc" 2>/dev/null || true
done
find "$out" -name '*.la' -type f -delete 2>/dev/null || true

named="/var/tmp/${pname}-${ver}"; [ -e "$named" ] && named="$named.$$"; cp -a "$out" "$named"
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
[ -n "$(ls -A "$dbg/lib/debug/.build-id" 2>/dev/null)" ] || echo "no split debug" > "$dbg/lib/debug/.empty"
set -e

spo=$(nix-store --add "$named" 2>/dev/null)
spd=$(nix-store --add "$dbg" 2>/dev/null)
[ -n "$spo" ] || { echo "RESULT	$pname	FAIL	nix-store-add"; exit 1; }
nix-store --add-root /var/tmp/gcroots/$(basename "$spo"|cut -d- -f1) --indirect --realise "$spo" >/dev/null 2>&1 || true
nix-store --add-root /var/tmp/gcroots/$(basename "$spd"|cut -d- -f1)d --indirect --realise "$spd" >/dev/null 2>&1 || true
echo "RESULT	$pname	OK	$spo $spd (man=$mc)"
