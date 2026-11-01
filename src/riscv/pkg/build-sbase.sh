#!/usr/bin/env bash
# build-sbase.sh -- suckless sbase as ONE multi-call binary (sbase-box), built natively on
# the board. One binary because the kernel's ustar root holds at most 16 regular files
# and has no link entries (uts/rootfs.c NDISKFILE); argv[0] selects the utility.
# Utilities needing a kernel facility that does not exist are dropped (EXCLUDE).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HOME/ws/rvpkg/dl/sbase}"
OUT="${OUT:-$HOME/scratch/rvpkg/out}"
# cron logger: syslog;  nice renice: setpriority;  touch: utimensat/tm_gmtoff;  tftp: no IP stack
EXCLUDE="cron logger nice renice touch tftp"
CF="-O2 -std=c99 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 -D_DEFAULT_SOURCE -D_BSD_SOURCE"
B="$(mktemp -d)"
cp -r "$SRC/." "$B/"
cd "$B"
for x in $EXCLUDE; do mv "$x.c" "$x.c.excluded"; done
make clean >/dev/null 2>&1 || true
make -j8 CC="$HERE/solnix-cc" CFLAGS="$CF" libutf.a libutil.a getconf.h
sh scripts/mkbox
cp getconf.h build/
"$HERE/solnix-cc" $CF -o sbase-box build/*.c libutil.a libutf.a
mkdir -p "$OUT"; cp sbase-box build/sbase-box.c "$OUT/"	# sbase-box.c: the applet table (stage-demo.sh)
echo "applets: $(grep -c '_main},' build/sbase-box.c)"
echo SBASE_DONE "$OUT/sbase-box" "$(wc -c < sbase-box)"
