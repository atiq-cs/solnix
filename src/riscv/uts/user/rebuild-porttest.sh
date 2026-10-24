#!/usr/bin/env bash
# rebuild-porttest.sh -- rebuild ONLY /bin/porttest (build-user.sh's flags) and splice it into
# ../user_elfs.h (porttest_elf[]) and ../rootfs.img (tar --delete + -r, as build-newlibtest.sh does).
# rvsrv: porttest's MAXCPU bound moved 16 -> 64; the other embedded ELFs are left byte-identical.
set -euo pipefail
cd "$(dirname "$0")"
CC="${CC:-riscv64-none-elf-gcc}"; LD="${LD:-riscv64-none-elf-ld}"
CFLAGS="-march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany -ffreestanding -nostdlib -fno-stack-protector -fno-pic -Wall -Wextra -Os -g"
"$CC" $CFLAGS -c porttest.c -o porttest.o
"$LD" -T init.ld -o porttest.elf porttest.o libc-riscv.a
python3 - porttest.elf ../user_elfs.h <<'PY'
import sys
b = open(sys.argv[1], 'rb').read(); h = open(sys.argv[2]).read()
a = h.index('static const unsigned char porttest_elf[] = {\n'); z = h.index('};\n', a) + 3
body = ''.join(','.join(str(x) for x in b[i:i+16]) + ',\n' for i in range(0, len(b), 16))
open(sys.argv[2], 'w').write(h[:a] + 'static const unsigned char porttest_elf[] = {\n' + body + '};\n' + h[z:])
PY
IMG="$(cd .. && pwd)/rootfs.img"; ST="$(mktemp -d)"; mkdir -p "$ST/bin"; cp porttest.elf "$ST/bin/porttest"
tar --delete -f "$IMG" bin/porttest
( cd "$ST" && tar --format=ustar -rf "$IMG" bin/porttest )
find "$ST" -delete
echo "porttest.elf $(wc -c < porttest.elf) B; rootfs.img $(tar -tf "$IMG" | wc -l) members, $(wc -c < "$IMG") B"
