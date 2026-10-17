#!/usr/bin/env bash
# gnu-mirror-prefetch.sh -- on an EC2 build host, put every ftp.gnu.org source the
# tree names into the Nix store from a GNU mirror first.
#
# ftp.gnu.org times out from EC2 us-east-2 (measured 2026-10-17; floki reaches it),
# and the GNU sources in pkgs/ point there. nix-prefetch-url from a mirror stores
# the same bytes under the same name, so the fixed-output store paths are the ones
# the derivations expect and the build never contacts ftp.gnu.org.
#
# Run on the build host, from the root of a solnix source tree:
#   . /etc/profile.d/nix-illumos.sh; scripts/gnu-mirror-prefetch.sh
# Prints "<sha256> <name>" per tarball, FAIL for one no mirror served.
set -u
GREP=$(command -v ggrep || echo /usr/gnu/bin/grep)
[ -x "$GREP" ] || GREP=grep
urls=$("$GREP" -rhoE 'https?://ftp\.gnu\.org/gnu/[^"[:space:]]+' pkgs lib modules configurations 2>/dev/null \
  | "$GREP" -v '\$' | sort -u)
# gcc-src.nix builds the URL from a version string, so the grep cannot see it.
urls="$urls
https://ftp.gnu.org/gnu/gcc/gcc-14.3.0/gcc-14.3.0.tar.xz"
fail=0
for u in $urls; do
  p=${u#*ftp.gnu.org/gnu/}; n=$(basename "$p")
  h=$(nix-prefetch-url --name "$n" "https://mirrors.kernel.org/gnu/$p" 2>/dev/null) \
    || h=$(nix-prefetch-url --name "$n" "https://ftpmirror.gnu.org/gnu/$p" 2>/dev/null) \
    || { h=FAIL; fail=$((fail + 1)); }
  echo "$h $n"
done
echo "PREFETCH_DONE failures=$fail"
[ "$fail" -eq 0 ]
