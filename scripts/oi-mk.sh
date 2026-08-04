#!/bin/sh
# oi-mk.sh — build a Makefile-only C project (no ./configure) on illumos, freeze
# plain <pname>-<version> out+debug roots, nix-store add both. Mirrors oi-clib.sh
# tail. Runs ON a builder via oi-job.
#   oi-mk.sh <pname> <ver> <url> <install-cmd> [make-args...]
# install-cmd: shell run inside srcdir AFTER `gmake <make-args>`, must install
#   into $out (env var provided). e.g. 'gmake PREFIX=$out install'
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ ${EXTRA_CFLAGS:-}"
export CXXFLAGS="$CFLAGS ${EXTRA_CXXFLAGS:-}"
export LDFLAGS="-m64"
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
pname="$1"; ver="$2"; url="$3"; instcmd="$4"; shift 4
mkargs="$*"
w=$(mktemp -d "/var/tmp/mk.$pname.XXXXXX")
tb="$w/src.tar"
curl -fsSL -o "$tb" "$url" || { echo "RESULT	$pname	FAIL	download"; exit 1; }
( cd "$w" && python3 -c "import tarfile;tarfile.open('$tb').extractall('.')" 2>/dev/null \
    || { gzip -dc "$tb" 2>/dev/null|tar xf -; } 2>/dev/null \
    || { xz -dc "$tb" 2>/dev/null|tar xf -; } 2>/dev/null \
    || { bzip2 -dc "$tb" 2>/dev/null|tar xf -; } 2>/dev/null || tar xf "$tb" 2>/dev/null )
sd=$(find "$w" -maxdepth 1 -mindepth 1 -type d ! -name 'PaxHeaders*' ! -name '@PaxHeader' ! -name out|head -1)
[ -d "$sd" ] || { echo "RESULT	$pname	FAIL	untar"; exit 1; }
out="$w/out"; mkdir -p "$out"
log="$w/.log"
( cd "$sd"; export out; eval "gmake -j$(nproc) $mkargs" && eval "$instcmd" ) >"$log" 2>&1
if [ $? -ne 0 ]; then echo "RESULT	$pname	FAIL	build"; tail -15 "$log"|sed 's/^/  /'; exit 1; fi
RP="$out/lib:$out/lib/64:$GCC/lib/amd64:$GCC/lib"
find "$out" -type f 2>/dev/null|while read -r f; do
  /usr/bin/elfedit -e "dyn:runpath $RP" "$f" 2>/dev/null||/usr/bin/elfedit -e "dyn:rpath $RP" "$f" 2>/dev/null||true
done
mc=$(find "$out/share/man" "$out/man" -type f 2>/dev/null|wc -l|tr -d ' '); echo "$mc">"$out/.manifest-man"
named="/var/tmp/${pname}-${ver}"; [ -e "$named" ]&&named="$named.$$"; cp -a "$out" "$named"
dbg="/var/tmp/${pname}-${ver}-debug"; [ -e "$dbg" ]&&dbg="$dbg.$$"; mkdir -p "$dbg/lib/debug/.build-id"
OBJCOPY=$(ls /usr/gnu/bin/gobjcopy /usr/gnu/bin/objcopy 2>/dev/null|head -1)
OBJDUMP=$(ls /usr/gnu/bin/gobjdump /usr/gnu/bin/objdump 2>/dev/null|head -1)
find "$named" -type f 2>/dev/null|while read -r f; do
  "$OBJDUMP" -h "$f" 2>/dev/null|grep -q '\.debug_info'||continue
  bid=$(/usr/bin/sha256sum "$f"|awk '{print $1}')
  pre=$(printf '%s' "$bid"|cut -c1-2); rest=$(printf '%s' "$bid"|cut -c3-)
  dst="$dbg/lib/debug/.build-id/$pre"; mkdir -p "$dst"; chmod u+w "$f" 2>/dev/null
  "$OBJCOPY" --only-keep-debug "$f" "$dst/$rest.debug" 2>/dev/null||continue
  "$OBJCOPY" --strip-debug "$f" 2>/dev/null; "$OBJCOPY" --add-gnu-debuglink="$dst/$rest.debug" "$f" 2>/dev/null
done
[ -n "$(ls -A "$dbg/lib/debug/.build-id" 2>/dev/null)" ]||echo "none">"$dbg/lib/debug/.empty"
spo=$(nix-store --add "$named" 2>/dev/null); spd=$(nix-store --add "$dbg" 2>/dev/null)
[ -n "$spo" ]||{ echo "RESULT	$pname	FAIL	nix-store-add"; exit 1; }
nix-store --add-root /var/tmp/gcroots/$(basename "$spo"|cut -d- -f1) --indirect --realise "$spo" >/dev/null 2>&1||true
nix-store --add-root /var/tmp/gcroots/$(basename "$spd"|cut -d- -f1)d --indirect --realise "$spd" >/dev/null 2>&1||true
echo "RESULT	$pname	OK	$spo $spd (man=$mc)"
