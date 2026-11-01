#!/usr/bin/env bash
# build-kernels.sh -- tryit1: unix (default, the check/gate kernel) and unix-demo (-DSOLNIX_DEMO), no boot.
# Also the demo init (uts/user/init.c -DSOLNIX_DEMO) -> uts/user/init-demo.elf.
set -euo pipefail
U="$(cd "$(dirname "$0")/../uts" && pwd)"; cd "$U"
R="$(cd ../../.. && pwd)"
build() {	# build-unix.sh minus its qemu boot: compile + link only
	sed '/^echo "== image info ==/,$d' build-unix.sh > .bu-tryit.sh
	OUT="$1" EXTRA_CFLAGS="$2" bash .bu-tryit.sh > "/tmp/build-$1.log" 2>&1 || { tail -30 "/tmp/build-$1.log"; exit 1; }
	echo "$1 warnings: $(grep -c 'warning:' "/tmp/build-$1.log")"
	rm -f .bu-tryit.sh
}
build unix ""
build unix-demo "-DSOLNIX_DEMO"
cd user
CF="-march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany -ffreestanding -nostdlib -fno-stack-protector -fno-pic \
	-ffile-prefix-map=$R=. -Wall -Wextra -Os -g"
riscv64-none-elf-gcc $CF -c libc.c -o /tmp/libc-demo.o && riscv64-none-elf-ar rcs /tmp/libc-demo.a /tmp/libc-demo.o
riscv64-none-elf-gcc $CF -DSOLNIX_DEMO -c init.c -o /tmp/init-demo.o
riscv64-none-elf-ld -T init.ld -o init-demo.elf /tmp/init-demo.o /tmp/libc-demo.a
riscv64-none-elf-strip --strip-debug init-demo.elf
ls -l "$U/unix" "$U/unix-demo" "$U/user/init-demo.elf" | awk '{print $5, $9}'
sha256sum "$U/unix" "$U/unix-demo" "$U/user/init-demo.elf"
