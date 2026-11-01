#!/usr/bin/env bash
# qemu-system-riscv64 wrapper: runs the unpacked (not installed) qemu from
# ~/scratch/rvpkg/qroot, and maps "-bios default" to the unpacked OpenSBI fw_dynamic
# (the deb's /usr/share/qemu symlink is absolute, so it would dangle inside qroot).
R=$HOME/scratch/rvpkg/qroot
export QEMU_MODULE_DIR=$R/usr/lib/riscv64-linux-gnu/qemu
export LD_LIBRARY_PATH=$R/usr/lib/riscv64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
args=()
while [ $# -gt 0 ]; do
	if [ "$1" = -bios ] && [ "${2:-}" = default ]; then
		args+=(-bios "$R/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin"); shift 2; continue
	fi
	args+=("$1"); shift
done
exec "$R/usr/bin/qemu-system-riscv64" -L "$R/usr/share/qemu" "${args[@]}"
