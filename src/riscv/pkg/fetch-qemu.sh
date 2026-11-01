#!/usr/bin/env bash
# fetch-qemu.sh -- unpack qemu-system-riscv64 + OpenSBI into ~/scratch/rvpkg/qroot WITHOUT
# installing anything on the board. The Bianbu archive is unreachable from lixr
# (archive.spacemit.com:443 refuses), so pull the same-version Ubuntu ports debs
# (Bianbu 4.0.7 is Ubuntu "resolute"-based; apt-cache shows qemu 1:10.2.1+ds-1ubuntu3).
set -euo pipefail
B=http://ports.ubuntu.com/ubuntu-ports/pool
D=~/scratch/rvpkg/debs; R=~/scratch/rvpkg/qroot
mkdir -p "$D" "$R"; cd "$D"
get() { # pool-dir package arch-suffix
	local v; v=$(apt-cache policy "$2" | awk '/Candidate:/{print $2}' | sed 's/^[0-9]*://; s/+/%2b/g')
	local f="${2}_${v}_$3.deb"
	[ -s "$f" ] || curl -fsS -m 300 -o "$f" "$B/$1/$f" || { echo "FAIL $f"; return 1; }
	echo "ok $f"
}
get main/q/qemu qemu-system-misc riscv64
get main/q/qemu qemu-system-common riscv64
get main/q/qemu qemu-system-data all
get main/o/opensbi opensbi all || get main/o/opensbi opensbi riscv64
get main/libs/libslirp libslirp0 riscv64
get main/liba/libaio libaio1t64 riscv64
get main/libu/liburing liburing2 riscv64
get main/libc/libcacard libcacard0 riscv64
get main/u/usbredir libusbredirparser1t64 riscv64
get main/r/rdma-core librdmacm1t64 riscv64
get main/m/multipath-tools libmpathpersist0 riscv64
get main/m/multipath-tools libmultipath0 riscv64
get main/m/multipath-tools libmpathcmd0 riscv64
for d in *.deb; do dpkg-deb -x "$d" "$R"; done
echo FETCH_DONE
