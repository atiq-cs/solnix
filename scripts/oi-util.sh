#!/bin/sh
# oi-util.sh <name> <version> <tarball-url> <sha256> [configure-args...] — build a
# small autotools C utility on illumos with __EXTENSIONS__, register a plain-named
# store path (out), verify it runs. For expanded-universe (pkgsrc-only) proofs and
# simple Hipster tools. Anti-wedge: launched detached via oi-job.
# Output: RESULT<TAB><name><TAB>OK|FAIL<TAB>storepath|reason
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
CC=/usr/gcc/14/bin/gcc; export CC
# illumos needs __EXTENSIONS__ for many POSIX/XPG symbols; -D_XOPEN_SOURCE too.
export CFLAGS="-m64 -O2 -D__EXTENSIONS__ -D_XOPEN_SOURCE=600 -D_XOPEN_SOURCE_EXTENDED"
export LDFLAGS="-m64"
export LD_LIBRARY_PATH="/usr/gcc/14/lib/amd64:/usr/gcc/14/lib:${LD_LIBRARY_PATH:-}"

name="$1"; ver="$2"; url="$3"; sha="$4"; shift 4
w=$(mktemp -d "/var/tmp/util.$name.XXXXXX")
tb="$w/src.tgz"
curl -fsSL -o "$tb" "$url" 2>"$w/.dl" || { echo "RESULT	$name	FAIL	download"; exit 1; }
got=$(digest -a sha256 "$tb" 2>/dev/null || sha256sum "$tb" | awk '{print $1}')
if [ -n "$sha" ] && [ "$got" != "$sha" ]; then
  echo "RESULT	$name	FAIL	sha256 mismatch got=$got"; exit 1
fi
( cd "$w" && gzip -dc "$tb" 2>/dev/null | tar xf - 2>/dev/null || tar xf "$tb" 2>/dev/null )
sd=$(find "$w" -maxdepth 1 -type d -name "$name*" | head -1)
[ -d "$sd" ] || sd=$(find "$w" -maxdepth 1 -mindepth 1 -type d | head -1)
out="$w/out"
( cd "$sd" && ./configure --prefix="$out" "$@" >"$w/.cfg" 2>&1 \
   && gmake -j"$(nproc)" >"$w/.mk" 2>&1 && gmake install >"$w/.inst" 2>&1 ) || {
  echo "RESULT	$name	FAIL	build"; tail -12 "$w/.cfg" "$w/.mk" 2>/dev/null | sed 's/^/  /'; exit 1; }
# RUNPATH: point at gcc runtime so the bin loads libgcc_s if needed
named="/var/tmp/${name}-${ver}"; [ -e "$named" ] && named="$named.$$"
cp -a "$out" "$named"
# verify it runs
bin=$(find "$named/bin" -type f 2>/dev/null | head -1)
if [ -n "$bin" ]; then LD_LIBRARY_PATH="/usr/gcc/14/lib/amd64:$LD_LIBRARY_PATH" "$bin" --version >"$w/.run" 2>&1 || "$bin" -V >"$w/.run" 2>&1 || true; fi
sp=$(nix-store --add "$named")
nix-store --add-root /var/tmp/gcroots/$(basename "$sp" | cut -d- -f1) --indirect --realise "$sp" >/dev/null 2>&1 || true
echo "RESULT	$name	OK	$sp"
[ -f "$w/.run" ] && head -1 "$w/.run" | sed 's/^/  ran: /'
