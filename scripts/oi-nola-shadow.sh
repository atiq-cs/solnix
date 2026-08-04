#!/bin/sh
# oi-nola-shadow.sh <src-store-path> — make a .la-free shadow of a cached lib
# whose libtool .la files reference dead build-temp paths (e.g. cached gnutls
# baking /var/tmp/clib.gmp.*/out/lib/libgmp.la). Symlinks .so/.a, copies headers,
# rewrites .pc prefix to the shadow, and drops the poison .la. Prints shadow dir.
set -u
src="$1"
sh=$(mktemp -d /var/tmp/nola.XXXXXX)
mkdir -p "$sh/lib/pkgconfig" "$sh/include"
for f in "$src"/lib/*.so* "$src"/lib/*.a; do
  [ -e "$f" ] && ln -sf "$f" "$sh/lib/"
done
cp -aL "$src"/include/* "$sh/include/" 2>/dev/null
for pc in "$src"/lib/pkgconfig/*.pc; do
  [ -e "$pc" ] || continue
  sed "s|^prefix=.*|prefix=$sh|" "$pc" > "$sh/lib/pkgconfig/$(basename "$pc")"
done
echo "$sh"
