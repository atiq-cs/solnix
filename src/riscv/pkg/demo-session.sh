#!/usr/bin/env bash
# demo-session.sh <kernel> <log> -- one boot of the session root: log in on the console as root,
# run a pipeline of external programs into a file, page it with less, edit it with ed, ls/rm it.
# Input is fed only after "login:" appears (bytes sent during boot are lost: rvpkg step 22).
# ed writes with an explicit name: sbase ed's bare `w` does strcpy(savfname, savfname) (overlapping,
# UB), which newlib's _FORTIFY_SOURCE=3 __strcpy_chk aborts on (measured, demo-1); glibc's host
# build has no fortify and passes. A package bug, not a kernel one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; K="$1"; LOG="$2"; TMO="${TMO:-400}"
QEMU="${QEMU:-$HOME/scratch/rvpkg/bin/qemu-system-riscv64}"
W="$(mktemp -d)"; trap 'find "$W" -delete' EXIT
bash "$HERE/stage-session.sh" "$W/s"
( cd "$W/s" && find . -mindepth 1 \( -type f -o -type d \) | sed 's|^\./||' | sort > "$W/list" &&
  tar --format=ustar --owner=0 --group=0 --no-recursion -cf "$W/root.img" -T "$W/list" )
cp "$W/root.img" "${SESSION_IMG:-/dev/null}" 2>/dev/null || true
truncate -s $(( ( $(wc -c < "$W/root.img") + 511) / 512 * 512 )) "$W/root.img"
echo "session root: $(wc -l < "$W/list") names, $(wc -c < "$W/root.img") bytes"
dd if=/dev/zero of="$W/disk.img" bs=512 count=2048 status=none; printf '\x55\xaa' | dd of="$W/disk.img" bs=1 seek=510 conv=notrunc status=none
dd if=/dev/zero of="$W/data.img" bs=1M count=1 status=none
cat > "$W/in.txt" <<'IN'
root
export TERM=vt100
cd /tmp
pwd
grep an /etc/words | sort | uniq -c | sort -rn > report.txt
cat report.txt
wc -l report.txt
less -X report.txt
q
ed report.txt
1p
$a
added by ed
.
w report.txt
q
cat report.txt
ls -l /tmp
minigzip < report.txt | minigzip -d | head -n 1
rm report.txt
ls /tmp
ls report.txt
echo DEMO-END rc=$?
IN
mkfifo "$W/in.fifo"
( exec 3> "$W/in.fifo"
  for _ in $(seq 1 "$TMO"); do grep -q 'login: $\|login: *$' "$LOG" 2>/dev/null && break; grep -q 'solnix-riscv login' "$LOG" 2>/dev/null && break; sleep 1; done
  sleep 2
  while IFS= read -r l; do printf '%s\n' "$l" >&3; sleep "${LINE_PACE:-2}"; done < "$W/in.txt"
  sleep "$TMO" ) &
FEEDER=$!
timeout -s KILL "$TMO" "$QEMU" -machine virt -smp 4 -m 512M -nographic -bios default -kernel "$K" \
	-global virtio-mmio.force-legacy=false \
	-drive file="$W/disk.img",if=none,id=hd0,format=raw -device virtio-blk-device,drive=hd0 \
	-drive file="$W/root.img",if=none,id=fs0,format=raw -device virtio-blk-device,drive=fs0 \
	-drive file="$W/data.img",if=none,id=data0,format=raw -device virtio-blk-device,drive=data0 \
	-netdev user,id=n0 -device virtio-net-device,netdev=n0 -device virtio-gpu-device \
	< "$W/in.fifo" > "$LOG" 2>&1 &
QP=$!
for _ in $(seq 1 "$TMO"); do grep -q 'DEMO-END rc=' "$LOG" 2>/dev/null && { sleep 3; break; }; kill -0 $QP 2>/dev/null || break; sleep 1; done
kill -9 $QP 2>/dev/null; wait $QP 2>/dev/null; pkill -P $FEEDER 2>/dev/null; kill $FEEDER 2>/dev/null
tr -d '\r' < "$LOG" > "$LOG.txt"
grep -q 'DEMO-END rc=1' "$LOG.txt" && echo "DEMO: reached the end (ls of the removed file failed, rc=1)" || echo "DEMO: did NOT reach DEMO-END rc=1"
