#!/usr/bin/env bash
#
# build-kernel.sh -- R-P28: grow the R-P27 preemptive-multiprocess kernel with
# (1) REAL CROSS-OBJECT DYNAMIC LINKING -- ld.so.1 maps + binds the app's
# DT_NEEDED object (libgcc_s.so.1) and a dynamic hello CALLS a libgcc_s routine
# (__multf3) across the object boundary; (2) PRIORITY DISPATCH QUEUES +
# thread_create -- kernel threads run in priority order; and (3) SMP
# SECONDARIES via the SBI HSM hart_start extension -- a second hart drains a
# shared runq.  Compiles the native EM_RISCV kernel (riscv64-unknown-solaris2.11
# gcc + R-P17 binutils), embeds the userland programs + the initramfs archive
# (now including the cross-object hellodyn + libgcc_s.so.1), and boots under
# qemu-system-riscv64 -machine virt -smp 2 via OpenSBI, verifying each R-P28
# sub-task from the boot log, plus re-asserting the R-P24 + R-P26 + R-P27
# subsystems.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
K=/root/riscv-port/rp30/kernel
U=/root/riscv-port/rp30/user
GCC=/root/riscv-port/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=/root/riscv-port/toolchain/bin
LD=$TB/riscv64-unknown-elf-ld
READELF=$TB/riscv64-unknown-elf-readelf
QEMU=/usr/bin/qemu-system-riscv64
BIOS=/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wno-unused -I$K"
cd $K

echo "=== building the userland programs (static EM_RISCV) ==="
bash $U/build-user.sh

echo "=== building the userland ld.so.1 (the DYNAMIC hello's INTERP) ==="
bash /root/riscv-port/rp30/ldso/build-ldso.sh

# embed the static ELFs; exec_image maps their PT_LOAD segments.
cp $U/forker $K/forker.bin
cp $U/execee $K/execee.bin
cp $U/preempt $K/preempt.bin
cp $U/fsexec $K/fsexec.bin
cp $U/dynexec $K/dynexec.bin
cp $U/dynexec2 $K/dynexec2.bin
cp $U/fptest $K/fptest.bin

echo "=== building the initramfs (ramfs seed: fs-backed exec by path) ==="
# the DYNAMIC hellos + interpreter/lib come from the R-P21/R-P28 pieces.
HELLO=/root/riscv-port/rp21/hello/hello.dyn
HELLODYN=/root/riscv-port/rp30/user/hellodyn.dyn
LDSO=/root/riscv-port/rp30/ldso/ld.so.1
LIBGCC=/root/riscv-port/rp21/libgcc_s/libgcc_s.so.1
RAMFS_ARGS="/bin/execee $U/execee /bin/fsexec $U/fsexec"
[ -f "$HELLO" ]     && RAMFS_ARGS="$RAMFS_ARGS /bin/hello $HELLO"
[ -f "$HELLODYN" ]  && RAMFS_ARGS="$RAMFS_ARGS /bin/hellodyn $HELLODYN"
[ -f "$LDSO" ]      && RAMFS_ARGS="$RAMFS_ARGS /usr/lib/ld.so.1 $LDSO"
[ -f "$LIBGCC" ]    && RAMFS_ARGS="$RAMFS_ARGS /lib/libgcc_s.so.1 $LIBGCC"
python3 $U/mkinitramfs.py $K/initramfs.bin $RAMFS_ARGS

echo "=== compiling the native EM_RISCV kernel (R-P27) ==="
$XGCC $CFLAGS -c locore.S     -o locore.o
$XGCC $CFLAGS -c mach_trap.S  -o mach_trap.o
$XGCC $CFLAGS -c mach_clock.S -o mach_clock.o
$XGCC $CFLAGS -c mach_mmu.S   -o mach_mmu.o
$XGCC $CFLAGS -c mach_swtch.S -o mach_swtch.o
$XGCC $CFLAGS -c mach_uentry.S -o mach_uentry.o
$XGCC $CFLAGS -c user_elf.S   -o user_elf.o
$XGCC $CFLAGS -c sbi.c        -o sbi.o
$XGCC $CFLAGS -c hat_boot.c   -o hat_boot.o
$XGCC $CFLAGS -c hat.c        -o hat.o
$XGCC $CFLAGS -c kmem_cache.c -o kmem_cache.o
$XGCC $CFLAGS -c hat_user.c   -o hat_user.o
$XGCC $CFLAGS -c exec_elf.c   -o exec_elf.o
$XGCC $CFLAGS -c ramfs.c      -o ramfs.o
$XGCC $CFLAGS -c proc.c       -o proc.o
$XGCC $CFLAGS -c clock_riscv.c -o clock_riscv.o
$XGCC $CFLAGS -c plic.c       -o plic.o
$XGCC $CFLAGS -c smp.c        -o smp.o
$XGCC $CFLAGS -c disp.c       -o disp.o
$XGCC $CFLAGS -c sched_class.c -o sched_class.o
$XGCC $CFLAGS -c startup.c    -o startup.o
$XGCC $CFLAGS -c main.c       -o main.o

echo "=== linking the kernel ELF (EM_RISCV, entry _start @ 0x80200000) ==="
$LD -T kernel.lds -nostdlib -e _start \
	locore.o mach_trap.o mach_clock.o mach_mmu.o mach_swtch.o \
	mach_uentry.o user_elf.o \
	sbi.o hat_boot.o hat_user.o exec_elf.o ramfs.o proc.o clock_riscv.o plic.o \
	hat.o kmem_cache.o disp.o \
	sched_class.o \
	smp.o startup.o main.o \
	-o unix.elf 2>&1

MACH=$($READELF -h unix.elf | awk -F: '/Machine/{print $2}' | tr -d ' ')
ENTRY=$($READELF -h unix.elf | awk -F: '/Entry point/{print $2}' | tr -d ' ')
echo "  Machine=$MACH  Entry=$ENTRY"
[ "$MACH" = "RISC-V" ] || { echo "FAIL: not EM_RISCV"; exit 1; }
if $READELF -rW unix.elf 2>/dev/null | grep -qE "R_RISCV_(CALL|PCREL|JUMP|HI20|BRANCH)"; then
	echo "FAIL: unresolved relocs in the kernel image"; exit 1
fi
echo "  OK: zero residual relocs (self-contained kernel image)"

echo "=== booting the kernel under qemu-system-riscv64 -machine virt (-smp 2) ==="
timeout 70 $QEMU -machine virt -smp 2 -m 256M -nographic \
	-bios $BIOS -kernel unix.elf > $K/qemu-boot.log 2>&1 || true
echo "--- qemu-boot.log ---"
cat $K/qemu-boot.log
echo "--- end log ---"

FAIL=0
# R-P24 regression: the four subsystems still reached.
grep -q "paging enabled (Sv39)" $K/qemu-boot.log \
	&& echo "R-P24.1 (regress) PASS: Sv39 paging enabled" \
	|| { echo "R-P24.1 FAIL"; FAIL=1; }
grep -q "clock tick 10" $K/qemu-boot.log \
	&& echo "R-P24.2 (regress) PASS: clock ticks counted" \
	|| { echo "R-P24.2 FAIL"; FAIL=1; }
grep -qE "claimed \+ completed" $K/qemu-boot.log \
	&& echo "R-P24.3 (regress) PASS: PLIC claim" \
	|| { echo "R-P24.3 FAIL"; FAIL=1; }
grep -q "on-ramp proven" $K/qemu-boot.log \
	&& echo "R-P24.4 (regress) PASS: dispatcher idle loop" \
	|| { echo "R-P24.4 FAIL"; FAIL=1; }
# R-P26.1 proc/lwp table: the first process was built.
grep -q "building the first process" $K/qemu-boot.log \
	&& echo "R-P26.1 PASS: proc/lwp table + first process built" \
	|| { echo "R-P26.1 FAIL: proc table not built"; FAIL=1; }
# R-P26.2 fork: BOTH parent and child ran + printed their pid.
grep -q "\[child\]  running; my pid=" $K/qemu-boot.log \
	&& grep -q "\[parent\] forked child pid=" $K/qemu-boot.log \
	&& echo "R-P26.2 PASS: fork(2) -- parent + child both run + print pid" \
	|| { echo "R-P26.2 FAIL: fork two-procs-run not seen"; FAIL=1; }
# R-P26.4 wait/exit reap: the parent reaped the child + printed status.
grep -q "reaped pid=" $K/qemu-boot.log \
	&& echo "R-P26.4 PASS: wait(2)/exit rendezvous -- parent reaped child" \
	|| { echo "R-P26.4 FAIL: wait/reap not seen"; FAIL=1; }
# R-P26.3 exec: a DIFFERENT program image ran after exec(2).
grep -q "NEW program image running after exec" $K/qemu-boot.log \
	&& echo "R-P26.3 PASS: exec(2) -- a different program image ran" \
	|| { echo "R-P26.3 FAIL: exec new-image not seen"; FAIL=1; }
# R-P27.1 preemption: two CPU-bound children INTERLEAVE via the timer tick.
grep -q "worker B pid=" $K/qemu-boot.log && \
awk '/preemption proof output/{s=1} /end preemption proof/{s=0}
     s && /\[worker A /{a++} s && /\[worker B /{b++}
     s && /\[worker /{seq=seq $0 "\n"}
     END{
       # interleave test: the A/B tags must not be fully grouped -- count
       # transitions between A-runs and B-runs in the worker output order.
       n=split(seq, L, "\n"); prev=""; tr=0;
       for(i=1;i<=n;i++){ if(L[i]~/worker A/)c="A"; else if(L[i]~/worker B/)c="B"; else continue;
         if(prev!="" && c!=prev) tr++; prev=c }
       exit (tr>=2)?0:1
     }' $K/qemu-boot.log \
	&& echo "R-P27.1 PASS: timer preemption -- two CPU-bound procs interleave" \
	|| { echo "R-P27.1 FAIL: no interleave (cooperative, not preemptive)"; FAIL=1; }
# R-P27.2 fs-backed exec: exec resolved a program BY PATH from the ramfs.
grep -q "exec by absolute path: /bin/execee" $K/qemu-boot.log && \
grep -q "/bin/execee  (" $K/qemu-boot.log \
	&& echo "R-P27.2 PASS: fs-backed exec + ramfs -- exec(/bin/execee) via path lookup" \
	|| { echo "R-P27.2 FAIL: fs-backed exec not seen"; FAIL=1; }
# R-P27.3 ld.so.1 hosts the DYNAMIC hello (checked only if ld.so.1 was built).
if grep -q "R-P27.3" $K/qemu-boot.log; then
	grep -q "dynamic hello ran via ld.so.1" $K/qemu-boot.log \
		&& echo "R-P27.3 PASS: ld.so.1 hosted the DYNAMIC hello" \
		|| { echo "R-P27.3 FAIL: ld.so.1 dynamic hello not proven"; FAIL=1; }
fi
# R-P28.1 REAL cross-object dynamic linking: ld.so.1 maps + binds DT_NEEDED
# (libgcc_s.so.1), the app CALLS __multf3 across the object boundary + exits 42.
grep -q "cross-object bind PROVEN" $K/qemu-boot.log \
	&& grep -q "bound __multf3 ->" $K/qemu-boot.log \
	&& grep -q "cross-object hello _start ran + called a libgcc_s routine via ld.so.1; exit status=42" $K/qemu-boot.log \
	&& echo "R-P28.1 PASS: ld.so.1 maps+binds DT_NEEDED; cross-object __multf3 call works (exit 42)" \
	|| { echo "R-P28.1 FAIL: cross-object dynamic linking not proven"; FAIL=1; }
# R-P28.2 priority dispatch: kernel threads run HIGH->MID->LOW by priority.
awk '/priority-dispatch proof output/{s=1} /end priority-dispatch proof/{s=0}
     s && /kthread\] HIGH/{h=NR} s && /kthread\] MID/{m=NR} s && /kthread\] LOW/{l=NR}
     END{ exit (h>0 && m>0 && l>0 && h<m && m<l)?0:1 }' $K/qemu-boot.log \
	&& echo "R-P28.2 PASS: priority disp queues + thread_create -- threads run HIGH->LOW" \
	|| { echo "R-P28.2 FAIL: priority dispatch order not observed"; FAIL=1; }
# R-P28.3 SMP via SBI HSM: secondary hart started + work ran on 2 distinct harts.
grep -q "SMP PROVEN: work ran on BOTH harts" $K/qemu-boot.log \
	&& grep -q "SECONDARY hart online: hartid=1" $K/qemu-boot.log \
	&& grep -q "\[hart 0\] ran work item" $K/qemu-boot.log \
	&& grep -q "\[hart 1\] ran work item" $K/qemu-boot.log \
	&& echo "R-P28.3 PASS: SMP via SBI HSM -- secondary hart + work on 2 distinct hartids" \
	|| { echo "R-P28.3 FAIL: SMP not proven"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "=== R-P28 (regress) ALL PASS ===" || { echo "=== R-P29 FAIL (R-P28 regression) ==="; exit 1; }

# ---- R-P29 assertions ------------------------------------------------
# R-P29.1 full high-VA R^X HAT: per-segment map installed, high-VA execution,
# W^X enforced (a store to .text faults), vmem/kmem_cache recycle, TLB shootdown.
grep -q "executed at high VA" $K/qemu-boot.log \
	&& echo "R-P29.1 PASS: high-VA execution via direct-map alias" \
	|| { echo "R-P29.1 FAIL: high-VA probe did not execute"; FAIL=1; }
grep -q "W^X enforced" $K/qemu-boot.log \
	&& echo "R-P29.1 PASS: W^X enforced -- store to .text faulted" \
	|| { echo "R-P29.1 FAIL: W^X not enforced (.text writable)"; FAIL=1; }
grep -q "recycle OK)" $K/qemu-boot.log \
	&& echo "R-P29.1 PASS: vmem arena + slab kmem_cache alloc/free recycle" \
	|| { echo "R-P29.1 FAIL: kmem_cache slab recycle not proven"; FAIL=1; }
grep -q "TLB shootdown PROVEN" $K/qemu-boot.log \
	&& echo "R-P29.1 PASS: cross-hart TLB shootdown (remote sfence.vma)" \
	|| { echo "R-P29.1 FAIL: TLB shootdown not proven"; FAIL=1; }
# R-P29.2 per-CPU dispatch + kpreempt: procs balanced across 2 harts' per-CPU
# queues; a kpreempt point fired.
grep -q "percpu disp PROVEN" $K/qemu-boot.log \
	&& echo "R-P29.2 PASS: per-CPU disp queues -- work balanced across 2 harts" \
	|| { echo "R-P29.2 FAIL: per-CPU dispatch not proven"; FAIL=1; }
grep -q "kpreempt PROVEN" $K/qemu-boot.log \
	&& echo "R-P29.2 PASS: kpreempt -- kernel preemption point fired" \
	|| { echo "R-P29.2 FAIL: kpreempt not proven"; FAIL=1; }
# R-P29.3 FP context switch + more syscalls: two FP procs preempt without
# corrupting FP state; a proc uses getpid/brk.  The two FP children preempt on
# one hart and print concurrently, so the "FP state PRESERVED" summary lines can
# be split by an interleaving print; the timing-INDEPENDENT invariant is that
# BOTH children reach their final round with fs0 still intact and FP state is
# NEVER reported corrupted.  Accept either the summary lines (>=2) OR both
# children's round-3 intact evidence.
FPPRES=$(grep -c "FP state PRESERVED across preemption" $K/qemu-boot.log)
FPA=$(grep -c "fp A pid=.* round 3 fs0=111 (intact)" $K/qemu-boot.log)
FPB=$(grep -c "fp B pid=.* round 3 fs0=222 (intact)" $K/qemu-boot.log)
if ! grep -q "FP state CORRUPTED" $K/qemu-boot.log && \
   { [ "$FPPRES" -ge 2 ] || { [ "$FPA" -ge 1 ] && [ "$FPB" -ge 1 ]; }; }; then
	echo "R-P29.3 PASS: FP context switch -- two FP procs keep distinct FP state"
else
	echo "R-P29.3 FAIL: FP context switch not proven ($FPPRES summary; A=$FPA B=$FPB)"; FAIL=1
fi
grep -q "parent getpid()=" $K/qemu-boot.log \
	&& grep -q "brk grew heap to" $K/qemu-boot.log \
	&& grep -q "heap\[0\]=41 (OK)" $K/qemu-boot.log \
	&& echo "R-P29.3 PASS: more syscalls -- getpid/brk + errno ABI" \
	|| { echo "R-P29.3 FAIL: new syscalls not proven"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "=== R-P29 ALL PASS ===" || { echo "=== R-P29 FAIL ==="; exit 1; }

# ---- R-P30 assertions ------------------------------------------------
# R-P30.1 high-VA relink + drop the identity map: the kernel is LINKED +
# EXECUTES at high VA and the low identity map is DROPPED (a read of _start via
# the low identity VA faults).
grep -q "identity map dropped; running purely high-VA" $K/qemu-boot.log \
	&& echo "R-P30.1 PASS: high-VA relink -- identity map dropped, true high-half kernel" \
	|| { echo "R-P30.1 FAIL: identity map not dropped"; FAIL=1; }
grep -q "read of _start via LOW identity VA 0x80200000: FAULTED" $K/qemu-boot.log \
	&& echo "R-P30.1 PASS: low identity VA read faults (identity truly gone)" \
	|| { echo "R-P30.1 FAIL: low identity VA still readable"; FAIL=1; }
# ELF: entry is the HIGH VA, LOAD p_paddr is the physical 0x80200000.
ENTRY=$($READELF -h $K/unix.elf | awk -F: '/Entry point/{print $2}' | tr -d ' ')
case "$ENTRY" in
0xffffffc080200000) echo "R-P30.1 PASS: ELF entry is the HIGH VA ($ENTRY)";;
*) echo "R-P30.1 FAIL: ELF entry not high VA ($ENTRY)"; FAIL=1;;
esac
$READELF -lW $K/unix.elf 2>/dev/null | grep -q "0xffffffc080200000 0x0000000080200000" \
	&& echo "R-P30.1 PASS: LOAD VirtAddr=high, PhysAddr=0x80200000 (VMA!=LMA)" \
	|| { echo "R-P30.1 FAIL: LOAD segment VMA/LMA split not as expected"; FAIL=1; }
# R-P30.2 TS/RT scheduling classes on both harts.
grep -q "TS/RT sched PROVEN" $K/qemu-boot.log \
	&& echo "R-P30.2 PASS: TS/RT sched -- RT preempts TS, TS round-robin, PI-lite, both harts" \
	|| { echo "R-P30.2 FAIL: TS/RT scheduler not proven"; FAIL=1; }
grep -q "\[PI\] TS proc .* released the lock" $K/qemu-boot.log \
	&& echo "R-P30.2 PASS: priority-inheritance-lite unblocked the RT waiter" \
	|| { echo "R-P30.2 FAIL: priority inheritance not observed"; FAIL=1; }
# R-P30.3 as_free: fork+exec+exit an AS N times, frames reclaimed (no leak).
grep -q "as_free PROVEN" $K/qemu-boot.log \
	&& echo "R-P30.3 PASS: as_free -- frame count returns to baseline (no leak)" \
	|| { echo "R-P30.3 FAIL: as_free not proven (AS leaked)"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "=== R-P30 ALL PASS ===" || { echo "=== R-P30 FAIL ==="; exit 1; }
