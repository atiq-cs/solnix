#!/bin/sh
# oi-make.sh <pname> <ver> <url> <buildcmd> <installcmd> [dep ...] — for tools with
# a plain Makefile (no configure). $out is the install prefix. Freezes plain-named
# store root + splits debug, like oi-clib.sh. Runs ON a builder via oi-job.
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
pname="$1"; ver="$2"; url="$3"; bcmd="$4"; icmd="$5"; shift 5
deps="$*"
DEPI=""; DEPL=""; DEPR=""
for d in $deps; do
  [ -d "$d/include" ] && DEPI="$DEPI -I$d/include"
  [ -d "$d/lib" ] && { DEPL="$DEPL -L$d/lib"; DEPR="$DEPR -R$d/lib"; }
done
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ $DEPI ${EXTRA_CFLAGS:-}"
export LDFLAGS="-m64 $DEPL $DEPR ${EXTRA_LDFLAGS:-}"
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
w=$(mktemp -d "/var/tmp/mk.$pname.XXXXXX"); tb="$w/s.tar"
curl -fsSL -o "$tb" "$url" || { echo "RESULT	$pname	FAIL	download"; exit 1; }
( cd "$w" && (gzip -dc "$tb" 2>/dev/null||xz -dc "$tb" 2>/dev/null||cat "$tb")|tar xf - 2>/dev/null )
sd=$(find "$w" -maxdepth 1 -mindepth 1 -type d ! -name 'PaxHeader*' ! -name '@PaxHeader' ! -name out | head -1)
[ -d "$sd" ] || { echo "RESULT	$pname	FAIL	untar"; exit 1; }
out="$w/out"; mkdir -p "$out/bin" "$out/share/man/man1"
log="$w/.log"
( cd "$sd"; eval "CC=$CC CFLAGS=\"$CFLAGS\" LDFLAGS=\"$LDFLAGS\" prefix=$out PREFIX=$out DESTDIR= $bcmd" \
  && eval "prefix=$out PREFIX=$out DESTDIR= mandir=$out/share/man $icmd" ) >"$log" 2>&1
if [ $? -ne 0 ]; then echo "RESULT	$pname	FAIL	build"; tail -15 "$log"|sed 's/^/  /'; exit 1; fi
# rpath fix
RP="$out/lib:$GCC/lib/amd64:$GCC/lib"; for d in $deps; do [ -d "$d/lib" ] && RP="$RP:$d/lib"; [ -d "$d/lib/64" ] && RP="$RP:$d/lib/64"; done
find "$out" -type f 2>/dev/null | while read -r f; do /usr/bin/elfedit -e "dyn:runpath $RP" "$f" 2>/dev/null || true; done
mc=$(find "$out/share/man" "$out/man" -type f 2>/dev/null | wc -l | tr -d ' '); echo "$mc" > "$out/.manifest-man"
named="/var/tmp/${pname}-${ver}"; [ -e "$named" ] && named="$named.$$"; cp -a "$out" "$named"
dbg="/var/tmp/${pname}-${ver}-debug"; [ -e "$dbg" ] && dbg="$dbg.$$"; mkdir -p "$dbg/lib/debug/.build-id"
OBJCOPY=$(ls /usr/gnu/bin/gobjcopy /usr/gnu/bin/objcopy 2>/dev/null|head -1)
OBJDUMP=$(ls /usr/gnu/bin/gobjdump /usr/gnu/bin/objdump 2>/dev/null|head -1)
find "$named" -type f 2>/dev/null | while read -r f; do
  "$OBJDUMP" -h "$f" 2>/dev/null | grep -q '\.debug_info' || continue
  bid=$(/usr/bin/sha256sum "$f"|awk '{print $1}'); pre=$(echo "$bid"|cut -c1-2); rest=$(echo "$bid"|cut -c3-)
  mkdir -p "$dbg/lib/debug/.build-id/$pre"; chmod u+w "$f" 2>/dev/null
  "$OBJCOPY" --only-keep-debug "$f" "$dbg/lib/debug/.build-id/$pre/$rest.debug" 2>/dev/null || continue
  "$OBJCOPY" --strip-debug "$f" 2>/dev/null
done
[ -n "$(ls -A "$dbg/lib/debug/.build-id" 2>/dev/null)" ] || echo empty > "$dbg/lib/debug/.empty"
spo=$(nix-store --add "$named" 2>/dev/null); spd=$(nix-store --add "$dbg" 2>/dev/null)
[ -n "$spo" ] || { echo "RESULT	$pname	FAIL	nix-store-add"; exit 1; }
nix-store --add-root /var/tmp/gcroots/$(basename "$spo"|cut -d- -f1) --indirect --realise "$spo" >/dev/null 2>&1 || true
echo "RESULT	$pname	OK	$spo $spd (man=$mc)"
