#!/usr/bin/env bash
# run-checks.sh -- boot the solnix riscv64 kernel under qemu with a package root
# and judge each check. Runs ON lixr (qemu unpacked by fetch-qemu.sh).
#
#   run-checks.sh <stage-dir> <checks-file> <log>
#
# <stage-dir>   files for the ustar root (sbin/init must be pkginit). The kernel
#               reads at most 16 regular files / 2 MiB (uts/rootfs.c NDISKFILE,
#               ROOTFS_MAX_BYTES): this script refuses a root over either limit,
#               because the kernel silently drops what does not fit.
# <checks-file> lines "name|want_exit|path|argv0|...": copied to etc/rvpkg.tests.
#               Optional expectation lines "@name|ERE": the ERE must match a line
#               between "RVPKG BEGIN name" and "RVPKG END name".
#               Optional "!name|ERE": the ERE must NOT match there.
#               Optional "%name|host-cmd": DIFFERENTIAL ORACLE. host-cmd runs on the
#               build host with cwd=<stage-dir> (so write paths relative: etc/x), and
#               the guest's block (kernel [fork]/[exec]/[elf]/[exit] lines and blank
#               lines dropped) must equal its stdout exactly.
#               A check named xfail-* is a NEGATIVE CONTROL of the harness itself:
#               it must FAIL, and is reported XFAIL-OK when it does.
#               A check named kernel-hang-* documents a kernel defect whose symptom
#               is a hang: its @ expectations must match and it must NOT reach END.
# STDIN_FILE    if set, its bytes are fed to the guest console UART.
set -euo pipefail
STAGE="$1"; CHECKS="$2"; LOG="$3"
UNIX="${UNIX:-$HOME/ws/rvpkg/src/riscv/uts/unix}"
QEMU="${QEMU:-$HOME/scratch/rvpkg/bin/qemu-system-riscv64}"
TMO="${TMO:-240}"
WORK="$(mktemp -d)"
trap 'find "$WORK" -delete' EXIT

grep -v '^[@!%]' "$CHECKS" > "$STAGE/etc/rvpkg.tests"
( cd "$STAGE" && find . -type f | sed 's|^\./||' | sort > "$WORK/list" )
nf=$(wc -l < "$WORK/list")
( cd "$STAGE" && tar --format=ustar --owner=0 --group=0 -cf "$WORK/root.img" -T "$WORK/list" )
sz=$(wc -c < "$WORK/root.img")
echo "root: $nf files, $sz bytes"
[ "$nf" -le 16 ] || { echo "REFUSE: $nf files > NDISKFILE 16"; exit 2; }
[ "$sz" -le $((2*1024*1024)) ] || { echo "REFUSE: $sz bytes > ROOTFS_MAX_BYTES 2 MiB"; exit 2; }
truncate -s $(( (sz + 511) / 512 * 512 )) "$WORK/root.img"
dd if=/dev/zero of="$WORK/disk.img" bs=512 count=2048 status=none
printf '\x55\xaa' | dd of="$WORK/disk.img" bs=1 seek=510 conv=notrunc status=none
dd if=/dev/zero of="$WORK/data.img" bs=1M count=1 status=none

# Console input: the file's bytes, then stdin held OPEN (no EOF). Measured: when
# qemu's -serial stdio hits EOF early, input already queued in the file can be
# lost; a FIFO kept open by a sleeper avoids that.
IN=/dev/null
if [ -n "${STDIN_FILE:-}" ]; then
	mkfifo "$WORK/in.fifo"
	# Input is sent only once the guest prints "RVPKG INIT": bytes that arrive
	# during kernel boot are lost (measured: 0/4 vs 8/8). Pacing is optional
	# (PACE=0 measured 6/6); default 0.02 s/byte keeps a margin.
	( exec 3> "$WORK/in.fifo"
	  for _ in $(seq 1 "$TMO"); do grep -q 'RVPKG INIT' "$LOG" 2>/dev/null && break; sleep 1; done
	  od -An -v -tx1 "$STDIN_FILE" | tr -s ' \n' '\n\n' | while read -r h; do
		[ -n "$h" ] || continue
		printf "\\x$h" >&3; sleep "${PACE:-0.02}"
	  done
	  sleep "$TMO" ) &
	FEEDER=$!
	IN="$WORK/in.fifo"
fi
set +e
# -serial stdio + stdin from a file: qemu's 16550 only pulls bytes when its FIFO
# has room, so a slow guest reader loses nothing.
timeout -s KILL "$TMO" "$QEMU" -machine virt -smp "${SMP:-4}" -m 512M -nographic \
	-bios default -kernel "$UNIX" -global virtio-mmio.force-legacy=false \
	-drive file="$WORK/disk.img",if=none,id=hd0,format=raw -device virtio-blk-device,drive=hd0 \
	-drive file="$WORK/root.img",if=none,id=fs0,format=raw -device virtio-blk-device,drive=fs0 \
	-drive file="$WORK/data.img",if=none,id=data0,format=raw -device virtio-blk-device,drive=data0 \
	-netdev user,id=n0 -device virtio-net-device,netdev=n0 \
	< "$IN" > "$LOG" 2>&1 &
QP=$!
for _ in $(seq 1 "$TMO"); do
	grep -q 'RVPKG DONE' "$LOG" 2>/dev/null && { sleep 1; break; }
	kill -0 $QP 2>/dev/null || break
	sleep 1
done
kill -9 $QP 2>/dev/null; wait $QP 2>/dev/null
[ -n "${FEEDER:-}" ] && { pkill -P "$FEEDER" 2>/dev/null; kill "$FEEDER" 2>/dev/null; wait "$FEEDER" 2>/dev/null; }
set -e
tr -d '\r' < "$LOG" > "$LOG.txt"

# Judging is not -e: one failing check must not stop the others being judged.
set +e
fails=0
while IFS='|' read -r name want rest; do
	case "$name" in ''|'#'*) continue;; esac
	blk="$(awk -v n="$name" '$0=="RVPKG BEGIN " n {f=1; next} f && index($0, "RVPKG END " n " ")==1 {print; f=0} f' "$LOG.txt")"
	endl="$(printf '%s\n' "$blk" | grep "^RVPKG END $name " || true)"
	verdict=PASS; why=""
	if [ -z "$endl" ]; then verdict=FAIL; why="no END line (hung or crashed)"
	elif ! printf '%s' "$endl" | grep -q ' PASS$'; then verdict=FAIL; why="$endl"; fi
	while IFS='|' read -r en ere; do
		if [ "$en" = "@$name" ] && ! printf '%s\n' "$blk" | grep -Eq -- "$ere"; then verdict=FAIL; why="$why; missing /$ere/"; fi
		if [ "$en" = "!$name" ] && printf '%s\n' "$blk" | grep -Eq -- "$ere"; then verdict=FAIL; why="$why; forbidden /$ere/"; fi
	done < <(grep '^[@!]' "$CHECKS")
	while IFS= read -r ol; do
		[ "${ol%%|*}" = "%$name" ] || continue
		( cd "$STAGE" && bash -c "${ol#*|}" ) > "$WORK/want" 2>&1 || true
		printf '%s\n' "$blk" | grep -Ev '^\[(fork|exec|elf|exit)\]|^sleepq: |^RVPKG (END|EXECFAIL)|^$' > "$WORK/got" || true
		grep -v '^$' "$WORK/want" > "$WORK/want2" || true
		if ! cmp -s "$WORK/want2" "$WORK/got"; then
			verdict=FAIL; why="$why; differs from host oracle: $(diff "$WORK/want2" "$WORK/got" | head -4 | tr '\n' ' ')"
		fi
	done < <(grep '^%' "$CHECKS")
	# kernel-hang-*: the documented kernel defect IS a hang. PASS iff the check's
	# expectations matched and it never reached END (the parent blocked forever).
	case "$name" in kernel-hang-*)
		if [ -z "$endl" ] && [ "$why" = "no END line (hung or crashed)" ]; then
			verdict=HANG-AS-DOCUMENTED
		elif [ -n "$endl" ]; then
			verdict=FAIL; why="expected the documented hang, but it completed: $endl"
		fi;;
	esac
	case "$name" in xfail-*)
		if [ "$verdict" = FAIL ]; then verdict=XFAIL-OK; else verdict=FAIL; why="negative control did not fail"; fi;;
	esac
	case "$verdict" in PASS|XFAIL-OK|HANG-AS-DOCUMENTED) ;; *) fails=$((fails+1));; esac
	echo "CHECK $verdict $name ${why}"
done < <(grep -v '^[@!%]' "$CHECKS")
grep -q 'RVPKG DONE' "$LOG.txt" && echo "guest: $(grep 'RVPKG DONE' "$LOG.txt")" || echo "guest: NO 'RVPKG DONE' (timeout ${TMO}s)"
echo "CHECKS FAILED: $fails"
exit $(( fails > 0 ))
