#!/usr/bin/bash
# ts-errno-gate.sh <dir> -- fail if any ELF under <dir> references the GLOBAL errno.
#
# illumos <errno.h> makes errno the data symbol `errno` unless _REENTRANT, _TS_ERRNO
# or _POSIX_C_SOURCE >= 199506 is defined, and that global is the MAIN thread's
# errno. A library built that way that writes errno on any other thread clobbers
# the main thread's value. Measured: openssl's sock_read (errno=0, on curl's worker
# thread) made libgit2's main-thread "lstat failed, errno == ENOENT?" read 0, and
# `nix build nixpkgs#jq` failed 2/13 with "cannot access component in path ...: "
# (empty strerror). A two-thread C repro: 19-23 per 2M with a non-TS writer,
# 0 with -D_TS_ERRNO. mk-src-pkg.nix passes -D_TS_ERRNO (illumos-gate's DTS_ERRNO;
# gcc patch 0032 does the same for libstdc++) and runs this on every output.
# Matches the UNDEF data symbol `errno` only, never the function ___errno.
IB=${ILLUMOS_BIN:-/usr/bin}   # illumos elfedit/elfdump/ldd: the world's usr/bin in a store-only build, /usr/bin when exempt
d=${1:?usage: ts-errno-gate.sh <dir>}
[ -d "$d" ] || { echo "ts-errno-gate: $d is not a directory" >&2; exit 2; }
bad=0
while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = 7f454c46 ] || continue
  if "$IB/elfdump" -s "$f" 2>/dev/null | grep -Eq ' UNDEF +errno$'; then
    echo "$f: references the global errno (built without _TS_ERRNO)" >&2; bad=1
  fi
done < <(find "$d" -type f)
exit $bad
