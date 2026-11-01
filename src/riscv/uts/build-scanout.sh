#!/usr/bin/env bash
# build-scanout.sh -- build the illumos riscv64 `unix` kernel WITH the R-P64
# scanout seam linked in (virtio_gpu.c + fb.c, the /dev/fb node), boot it under
# QEMU with a virtio-gpu device, and capture a QMP screendump of the host
# scanout as the verifiable evidence.
#
# This is the reproducible entry point for steps 1-2 of
# docs/riscv64-scanout-seam.md section 7 (first-light order): finish the kernel
# side, then prove it with a C test that mmaps and paints, under QEMU.
#
# WHY this is separate from build-unix.sh: build-unix.sh is the R-P2..R-P12 gate
# and links a fixed object list. This script adds the two scanout objects from
# src/riscv-port/rp64/kernel/ (which live outside uts/ because they are also
# built standalone by the R-P64 harness) and adds the -device virtio-gpu-device
# + QMP socket the screendump needs.
#
# ANTI-WEDGE: every qemu run is `timeout`-bounded and captures the console to a
# log rather than foreground-waiting on an interactive prompt.
set -euo pipefail
cd "$(dirname "$0")"

TC="${TC:-riscv64-none-elf}"
CC="${CC:-${TC}-gcc}"
LD="${LD:-${TC}-ld}"
OBJDUMP="${OBJDUMP:-${TC}-objdump}"
QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-unix-scanout}"
LOG="${LOG:-scanout-qemu-boot.log}"
# Where the screendump PPM/PNG land. Overridable so a CI job can collect them.
ARTDIR="${ARTDIR:-/tmp/scanout}"
RP64="${RP64:-../../riscv-port/rp64/kernel}"

CFLAGS="-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany \
	-ffreestanding -nostdlib -fno-stack-protector -fno-pic -Iriscv64 \
	-Wall -Wextra -O2 -g"

# GPU_IDENTITY_MAP: the kernel's boot HAT identity-maps the 0x80000000 RAM
# gigabyte, so KVTOP(va) == va for the rings and the framebuffer -- the same
# assumption virtio.c/vioblk.c already make for their DMA rings.
GPUFLAGS="-DGPU_IDENTITY_MAP -I. -I$RP64"

mkdir -p "$ARTDIR"

echo "== compile kernel (freestanding, $TC) =="
KOBJS=""
# fpsave.S does the f0-f31 + fcsr moves for fp.c. It is the ONE file that needs
# the F and D extensions: the kernel proper is soft-float and must stay that way
# (that is what makes lazy FP handling safe), so the extensions are enabled via
# `.option arch, +f, +d` inside the file rather than by widening the kernel's
# -march. Listed separately so the ${src%.S} loop below stays simple.
"$CC" $CFLAGS -c fpsave.S -o fpsave.o
KOBJS="$KOBJS fpsave.o"
# image_header.S emits the Linux RISC-V Image header as byte 0 of .text so the
# same kernel can also be booted by U-Boot `booti` on real K1 silicon. It is
# INERT here (OpenSBI/qemu enter at the ELF e_entry = _start, past the header),
# and building it into the gate kernel is deliberate: the gates then prove it
# does not perturb the qemu-virt boot.
"$CC" $CFLAGS -c image_header.S -o image_header.o
KOBJS="$KOBJS image_header.o"
for src in locore.S trap.S swtch.S copy.S; do
	o="${src%.S}.o"
	[ "$src" = trap.S ] && o=trap_asm.o
	"$CC" $CFLAGS -c "$src" -o "$o"
	KOBJS="$KOBJS $o"
done
for src in sbi trap hat_riscv timer plic aia fdt cmo vm_page kmem proc as elf \
	   syscall uart sdhci uproc unixsock virtio vioblk blkfs vionet viornd rootfs \
	   fp port startup main; do
	"$CC" $CFLAGS -c "$src.c" -o "$src.o"
	KOBJS="$KOBJS $src.o"
done

echo "== compile the R-P64 scanout seam (virtio_gpu.c + fb.c) =="
"$CC" $CFLAGS $GPUFLAGS -c "$RP64/virtio_gpu.c" -o virtio_gpu.o
"$CC" $CFLAGS $GPUFLAGS -c "$RP64/fb.c"         -o fb.o
KOBJS="$KOBJS virtio_gpu.o fb.o"

echo "== link (riscv.ld @ 0x80200000) =="
. ./lwip-objs.sh		# rvsrv: inet.c needs lwIP; startup_root calls inet_init
KOBJS="$KOBJS $LWIPOBJS"
"$LD" -T riscv.ld -o "$OUT" $KOBJS
echo "  $OUT: $(wc -c < "$OUT") bytes"
"$OBJDUMP" -h "$OUT" | awk '/\.bss|\.text|\.data/ {print "   " $2, $3}'

# --- boot with a virtio-gpu device + a QMP socket for the screendump ---------
#
# qemu populates virtio-mmio slots in REVERSE (first -device -> highest slot),
# and virtio_gpu.c probes for DeviceID 16 across all 8 slots, so the ordering
# relative to blk/net does not matter.
#
# -display none keeps the run headless (no X11/Wayland needed); the scanout is
# still fully emulated, which is why a screendump captures real pixels.
DISK="${DISK:-disk.img}"
DATA="${DATA:-data.img}"
QMP="$ARTDIR/qmp.sock"
rm -f "$QMP"

[ -f "$DISK" ] || { echo "no $DISK; run build-unix.sh once to create it"; exit 1; }

echo "== boot under OpenSBI with -device virtio-gpu-device (headless) =="
: > "$LOG"
timeout 180 "$QEMU" -machine virt -smp "${SMP:-4}" -m "${MEM:-512M}" \
	-bios default -kernel "$OUT" \
	-global virtio-mmio.force-legacy=false \
	-drive file="$DISK",if=none,id=hd0,format=raw \
	-device virtio-blk-device,drive=hd0 \
	$( [ -f "$DATA" ] && echo "-drive file=$DATA,if=none,id=hd1,format=raw -device virtio-blk-device,drive=hd1" ) \
	-netdev user,id=n0 -device virtio-net-device,netdev=n0 \
	-device virtio-gpu-device \
	-display none -qmp unix:"$QMP",server,nowait \
	-serial file:"$LOG" &
QPID=$!

# Poll the log for the userland gate rather than sleeping a fixed time: the
# screendump must be taken AFTER fbtest's final flush, or it captures a blank
# or half-painted frame.
echo "== waiting for the fbtest final flush =="
for _ in $(seq 1 120); do
	grep -q "final whole-screen flush\|FBTEST" "$LOG" 2>/dev/null && break
	kill -0 $QPID 2>/dev/null || break
	sleep 1
done
sleep 2		# let the last RESOURCE_FLUSH land in the host console surface

echo "== QMP screendump =="
python3 ./qmp-screendump.py "$QMP" \
	"$ARTDIR/scanout-fb.ppm" || echo "  screendump failed (see above)"

kill $QPID 2>/dev/null || true
wait $QPID 2>/dev/null || true

# Verify the dump CONTAINS the painted pattern. Without this the screendump is
# just a file: a guest that never presented, or presented with a wrong stride,
# still produces a plausible-looking PPM.
echo "== verify the screendump pixels =="
if python3 ./verify-scanout.py "$ARTDIR/scanout-fb.ppm" \
	--png "$ARTDIR/scanout-fb.png"; then PIXOK=1; else PIXOK=0; fi

echo "== verdict =="
rc=0
grep -q "\[fb\] /dev/fb online" "$LOG" || { echo "FAIL: /dev/fb not created"; rc=1; }
grep -q "\[fb\] selftest OK"    "$LOG" || { echo "FAIL: in-kernel fb selftest"; rc=1; }
grep -q "FBTEST PASS"           "$LOG" || { echo "FAIL: userland fbtest"; rc=1; }
[ -s "$ARTDIR/scanout-fb.ppm" ]        || { echo "FAIL: no screendump"; rc=1; }
[ "$PIXOK" = 1 ] || { echo "FAIL: screendump pixels do not match the pattern"; rc=1; }
if [ $rc -eq 0 ]; then
	echo "R-P64 SCANOUT PASS: /dev/fb node + mmap + damage flush verified,"
	echo "  and the host scanout contains the guest-painted pattern."
	echo "  screendump: $ARTDIR/scanout-fb.ppm (+ .png)"
fi
echo "  console log: $LOG"
exit $rc
