#!/bin/sh
# oi-libpq.sh <version> — build ONLY libpq (client lib) from a PostgreSQL source
# tarball on illumos, register a plain-named store path. Client-only: configure
# the tree, then make just src/interfaces/libpq + src/bin/pg_config + install
# headers/lib. No server, no readline/zlib/icu. Anti-wedge: via oi-job.
# Output: RESULT<TAB>libpq<TAB>OK|FAIL<TAB>storepath|reason
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
GCC=/usr/gcc/14
CCBIN="$GCC/bin/gcc"
export CC="$CCBIN"
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
# illumos needs __EXTENSIONS__/_XOPEN_SOURCE for many POSIX bits + -lsocket -lnsl
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_XOPEN_SOURCE=600 -D_XOPEN_SOURCE_EXTENDED=1"
export LDFLAGS="-m64"

VER="${1:-16.4}"
w=$(mktemp -d /var/tmp/libpq.XXXXXX)
url="https://ftp.postgresql.org/pub/source/v${VER}/postgresql-${VER}.tar.bz2"
if ! curl -fsSL -o "$w/src.tar.bz2" "$url" 2>"$w/.dl.log"; then
  echo "RESULT	libpq	FAIL	download"; exit 1
fi
( cd "$w" && bzip2 -dc src.tar.bz2 | tar xf - ) 2>"$w/.untar.log" || { echo "RESULT	libpq	FAIL	untar"; exit 1; }
src="$w/postgresql-${VER}"
[ -d "$src" ] || { echo "RESULT	libpq	FAIL	no-src-dir"; exit 1; }

pfx="$w/inst"; mkdir -p "$pfx"
log="$w/.build.log"
(
  cd "$src"
  # client-only: skip server-only checks. Solaris/illumos template exists.
  ./configure --prefix="$pfx" \
    --without-readline --without-zlib --without-icu --without-openssl \
    --without-ldap --without-pam --without-gssapi --disable-thread-safety \
    CC="$CCBIN" 2>&1
  cfg=$?
  [ $cfg -eq 0 ] || { echo "CONFIGURE FAILED ($cfg)"; exit 3; }
  # generated headers first (some live under src/include), then libpq + pg_config
  gmake -C src/backend generated-headers 2>&1 || true
  gmake -C src/common 2>&1 || true
  gmake -C src/port 2>&1 || true
  gmake -C src/interfaces/libpq 2>&1 || exit 4
  gmake -C src/interfaces/libpq install 2>&1 || exit 5
  gmake -C src/bin/pg_config install 2>&1 || true
  gmake -C src/include install 2>&1 || true
) >"$log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "RESULT	libpq	FAIL	build rc=$rc"; tail -25 "$log" | sed 's/^/  /'; exit 1
fi
# verify the .so exists + links
so=$(find "$pfx/lib" -name 'libpq.so*' 2>/dev/null | head -1)
[ -n "$so" ] || { echo "RESULT	libpq	FAIL	no-libpq.so"; tail -15 "$log" | sed 's/^/  /'; exit 1; }
named="/var/tmp/libpq-${VER}"; [ -e "$named" ] && named="$named.$$"
cp -a "$pfx" "$named"
sp=$(nix-store --add "$named")
[ -n "$sp" ] || { echo "RESULT	libpq	FAIL	nix-store-add"; exit 1; }
nix-store --add-root /var/tmp/gcroots/$(basename "$sp"|cut -d- -f1) --indirect --realise "$sp" >/dev/null 2>&1 || true
echo "RESULT	libpq	OK	$sp"
"$sp"/bin/pg_config --version 2>&1 | sed 's/^/  /'
/usr/bin/elfdump -d "$so" 2>/dev/null | grep -i soname | sed 's/^/  /'
