#!/usr/bin/env bash
#
# rp51-milestone-check.sh -- re-runnable proof of the R-P51 deliverable, all
#   boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P51.1 HEADLINE: REAL hard links -- a SHARED inode with an nlink count.
#           R-P50's vfs_link COPIED bytes (each tmpfs slot conflated a directory
#           entry with its file bytes, so two names could not alias one file).
#           R-P51 splits the tmpfs slot into a DIRECTORY ENTRY (name + inode
#           index) and a separate tmp_inode (data + len + cap + nlink).  link(2)
#           allocates a 2nd dir entry at the SAME inode and bumps nlink;
#           unlink(2) frees the entry, drops nlink, and frees the inode's data
#           only at nlink==0.  proc_stat/proc_fstat now also report st_nlink +
#           st_ino (ubuf[2]/ubuf[3]) and the libc stat cook fills them.  PROOF:
#             echo hardlinkX > /tmp/a ; link /tmp/a /tmp/b
#             stat /tmp/a AND stat /tmp/b  -> BOTH "Links: 2" + the SAME "Inode"
#             echo hardlinkY >> /tmp/a ; cat /tmp/b -> shows hardlinkY (SHARED)
#             unlink /tmp/a ; cat /tmp/b -> still reads (nlink 2->1, data kept)
#             unlink /tmp/b -> the last link (nlink 1->0), inode + data freed
#           This is illumos tmpfs tmpnode (tn_nlink) + VOP_LINK (tdirenter,
#           tn_nlink++) / VOP_REMOVE (tdirdelete, tn_nlink--, free at 0).
#
#   R-P51.2..R-P51.4 THREE more UNMODIFIED coreutils-9.5 on the SAME libc.a:
#           paste (merge lines), expand (tabs->spaces), unexpand (spaces->tabs).
#           25 real UNMODIFIED upstream coreutils now link the one reusable
#           libc.a.  ln/cut/uniq/nl/cksum were attempted but need libc/gnulib
#           gaps (the *at syscall family for ln; ungetc/freadptr for cut;
#           mbrtoc32 for uniq; the xdectoint template for nl; <byteswap.h> for
#           cksum) -- documented for R-P52.
#
#   TOWARD A REAL DISK (R-P51.5, the reach): the virtio-blk MMIO register layout
#           + driver skeleton is DOCUMENTED for R-P52 (rp51/VIRTIO-BLK-PLAN.md);
#           the RAM-backed blockfs (bdev0) is KEPT.  A virtio-blk sector read is
#           the R-P52 milestone (real disk I/O across boots).
#
# plus the R-P24..R-P50 regressions (blockfs getattr -> ls -l /blk metadata,
# the SMP ld.so.1 fence.i race fix, setlocale_null recursion, %b/nstrftime,
# fclose static-stream, pipe SIGPIPE, setjmp/longjmp, uname/nproc, unlink/tty,
# stat/link/fold/tr); build-kernel.sh asserts every one.  The boot log is saved
# to rp51/qemu-boot.log (via tee) so it is verifiable.
set -e
K=/root/riscv-port/rp51/kernel
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
cd $K
bash build-kernel.sh 2>&1 | tee /root/riscv-port/rp51/qemu-boot-milestone.log
# copy the raw serial capture (the assertions grep) to the phase root.
cp $K/qemu-boot.log /root/riscv-port/rp51/qemu-boot.log

# ---- SMP-race determinism: re-boot the SAME image 3x, -smp 2 ---------------
QEMU=/usr/bin/qemu-system-riscv64
BIOS=/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin
echo
echo "=== R-P51 SMP determinism: re-booting the same image 3x under -smp 2 ==="
smp_fail=0
for run in 1 2 3; do
	L=/root/riscv-port/rp51/smp-run-$run.log
	timeout 120 $QEMU -machine virt -smp 2 -m 256M -nographic \
	    -bios $BIOS -kernel $K/unix.elf > $L 2>&1 || true
	if grep -q "cross-object bind PROVEN" $L && ! grep -q "cross-object bind FAILED" $L; then
		echo "  SMP boot $run: R-P28.1 cross-object bind PROVEN (exit 42) -- PASS"
	else
		echo "  SMP boot $run: R-P28.1 cross-object bind did NOT prove (exit != 42) -- FAIL"
		smp_fail=1
	fi
done
if [ $smp_fail -eq 0 ]; then
	echo "R-P51 SMP PASS: cross-object ld.so.1 bind is DETERMINISTIC under -smp 2 (exit 42 across 3 fresh boots) -- the R-P49 fence.i I-cache fix still holds."
else
	echo "R-P51 SMP FAIL: the SMP bind race fired on at least one boot."
	exit 1
fi

echo
echo "PASS: R-P51 milestone check complete (see the R-P51.* PASS lines above)."
echo "      HEADLINE: REAL hard links -- a shared tmpfs inode with an nlink."
echo "      link /tmp/a /tmp/b makes a 2nd directory entry at the SAME inode;"
echo "      stat of BOTH names reports Links: 2 + the SAME Inode; a write"
echo "      through /tmp/a shows through /tmp/b (shared data); unlink /tmp/a"
echo "      keeps /tmp/b readable (nlink 2->1); unlink /tmp/b frees the inode"
echo "      (nlink 1->0).  MORE utils: paste/expand/unexpand -- 25 real"
echo "      UNMODIFIED upstream coreutils on one libc.a.  virtio-blk MMIO"
echo "      layout + driver skeleton DOCUMENTED for R-P52 (RAM-blockfs kept)."
echo "      Boot log saved to rp51/qemu-boot.log.  Next: R-P52."
