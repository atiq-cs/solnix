#!/usr/bin/env bash
# mk-images.sh <outdir> -- tryit1: the demo images from built parts.
#   fw_payload.bin = OpenSBI 1.8.1 fw_jump (build-opensbi.sh), padded to 2 MiB, + the kernel
#                    (objcopy -O binary of uts/unix-demo; OpenSBI jumps to 0x80200000)
#   root.img       = the ustar demo root (stage-demo.sh), padded to 128 KiB; disk/ = splitimg's blocks
# Env: OPENSBI (fw_jump.bin), SPLITIMG, KERNEL (default uts/unix-demo), OUT, SBASE_BOX_C, INIT.
set -euo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"; O="$1"; mkdir -p "$O/disk"
K="${KERNEL:-$R/uts/unix-demo}"
riscv64-none-elf-objcopy -O binary "$K" "$O/kernel.bin"
cp "$OPENSBI" "$O/fw_payload.bin"; chmod u+w "$O/fw_payload.bin"
[ "$(wc -c < "$O/fw_payload.bin")" -le 2097152 ]
truncate -s 2097152 "$O/fw_payload.bin"
cat "$O/kernel.bin" >> "$O/fw_payload.bin"
S="$(mktemp -d)"; bash "$R/tryit/stage-demo.sh" "$S"
( cd "$S" && find . -mindepth 1 \( -type f -o -type d \) | sed 's|^\./||' | sort > ../list.$$ &&
  tar --format=ustar --owner=0 --group=0 --numeric-owner --mtime=@0 --no-recursion -cf "$O/root.img" -T ../list.$$ &&
  rm ../list.$$ )
n=$(tar tf "$O/root.img" | wc -l); sz=$(wc -c < "$O/root.img")
[ "$n" -le 256 ] && [ "$sz" -le $((8 * 1024 * 1024)) ] || { echo "root too big: $n names $sz bytes"; exit 1; }
truncate -s $(( (sz + 131071) / 131072 * 131072 )) "$O/root.img"
find "$O/disk" -name 'blk*' -delete
find "$O/disk" -name blk.txt -delete
"$SPLITIMG" "$O/root.img" "$O/disk" 128 >/dev/null	# writes disk/blk*.bin + disk/blk.txt
printf '%s\n' '/* solnix riscv64 -- TinyEMU (qemu-virt map) in the browser */' '{' '    version: 1,' \
	'    machine: "riscv64",' '    memory_size: 256,' '    bios: "fw_payload.bin",' '    drive0: { file: "disk/blk.txt" },' '}' > "$O/solnix.cfg"
find "$S" -depth -delete
echo "images: $n names in root ($sz bytes), $(cat "$O/disk/blk.txt" | grep n_block), fw_payload $(wc -c < "$O/fw_payload.bin") bytes"
