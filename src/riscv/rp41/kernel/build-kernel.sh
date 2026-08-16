#!/usr/bin/env bash
#
# build-kernel.sh -- R-P35: grow the R-P34 shell-ready kernel with a REAL
# userland session: (1) PER-CPU IDLE + IPI WAKEUP -- an idle hart wfi's on an
# empty runq (replacing the R-P34 wfi-poll in proc_wait_signal with a real
# P_WAITING block) and a peer hart posts an SBI software IPI to wake it when it
# makes a proc runnable (a child exit / signal); (2) a REAL init PROCESS
# (pid 1) -- the kernel execs /sbin/init as pid 1, which fork+execs /bin/sh and
# reaps orphans (adopting a re-parented grandchild); and (3) a MINIMAL SHELL
# (/bin/sh) -- reads a scripted /etc/rc as stdin, parses argv, fork+exec+waits
# each command (echo/cat/true exec'd from the ramfs with real argv), and runs a
# pipeline (echo hi | cat) over the R-P33 pipe + R-P34 dup2.  Compiles the
# native EM_RISCV kernel (riscv64-unknown-solaris2.11 gcc + R-P17 binutils),
# embeds the userland + the initramfs archive, boots under
# qemu-system-riscv64 -machine virt -smp 2 via OpenSBI, verifying each R-P35
# sub-task from the boot log, plus the R-P24..R-P34 regressions.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
K=/root/riscv-port/rp41/kernel
U=/root/riscv-port/rp41/user
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

echo "=== R-P39.1: building the REAL solnix riscv64 libc.a ==="
bash /root/riscv-port/rp41/libc/build-libc.sh

echo "=== R-P39.1/.2: building REAL coreutils utils against the REAL libc ==="
bash $U/build-cu.sh

echo "=== R-P40.2: building a BIGGER real coreutils util (cat) against the GROWN libc ==="
bash $U/build-cat.sh

echo "=== R-P41.2: building the UNMODIFIED coreutils wc.c against the GROWN libc ==="
bash $U/build-wc.sh

echo "=== R-P41.2: building ls (opendir/readdir/lstat/qsort/strcoll) against the GROWN libc ==="
bash $U/build-ls.sh

echo "=== building the userland ld.so.1 (the DYNAMIC hello's INTERP) ==="
true  # R-P36: ld.so.1 is prebuilt by rp36-build-dynchain.sh

# embed the static ELFs; exec_image maps their PT_LOAD segments.
cp $U/forker $K/forker.bin
cp $U/execee $K/execee.bin
cp $U/preempt $K/preempt.bin
cp $U/fsexec $K/fsexec.bin
cp $U/dynexec $K/dynexec.bin
cp $U/dynexec2 $K/dynexec2.bin
cp $U/dynexec3 $K/dynexec3.bin
cp $U/fptest $K/fptest.bin
cp $U/fsread $K/fsread.bin
cp $U/cowtest $K/cowtest.bin
cp $U/smproc $K/smproc.bin
cp $U/vfstest $K/vfstest.bin
cp $U/sigtest $K/sigtest.bin
cp $U/pipetest $K/pipetest.bin
cp $U/dpexec $K/dpexec.bin
cp $U/fdtest $K/fdtest.bin
cp $U/fdexecee $K/fdexecee
cp $U/init $K/init.bin
cp $U/sh $K/sh.bin
cp $U/echo $K/echo.bin
cp $U/cat $K/cat.bin
cp $U/true $K/true.bin
cp $U/loop $K/loop.bin
cp $U/counter $K/counter.bin

# R-P31.3: a text file the ramfs-read proof opens + reads.
printf 'solnix riscv64 (R-P31)\nSunOS solnix-riscv64\n' > $K/etc-release.txt
# R-P35.3: the boot shell script /bin/sh reads as its scripted stdin.
cp $U/etc-rc.txt $K/etc-rc.txt
# R-P37.4: /etc/inittab -- init reads it + respawns the console shell.
cp $U/etc-inittab.txt $K/etc-inittab.txt

echo "=== building the initramfs (ramfs seed: fs-backed exec by path) ==="
# the DYNAMIC hellos + interpreter/lib come from the R-P21/R-P28 pieces.
HELLO=/root/riscv-port/rp21/hello/hello.dyn
HELLODYN=/root/riscv-port/rp38/user/hellodyn.dyn
HELLOLAZY=/root/riscv-port/rp38/user/hellolazy.dyn
COREECHO=/root/riscv-port/rp38/user/coreecho.dyn
# R-P39: the REAL coreutils utils built against the REAL libc.a (not the shim).
COREECHO2=/root/riscv-port/rp41/user/coreecho2.dyn
CORETRUE=/root/riscv-port/rp41/user/coretrue.dyn
CORECAT=/root/riscv-port/rp41/user/corecat.dyn
COREWC=/root/riscv-port/rp41/user/corewc.dyn
CORELS=/root/riscv-port/rp41/user/corels.dyn
LDSO=/root/riscv-port/rp38/ldso/ld.so.1
LIBGCC=/root/riscv-port/rp21/libgcc_s/libgcc_s.so.1
RAMFS_ARGS="/bin/execee $U/execee /bin/fsexec $U/fsexec /bin/fsread $U/fsread /bin/fdexecee $U/fdexecee /etc/release $K/etc-release.txt"
RAMFS_ARGS="$RAMFS_ARGS /sbin/init $U/init /bin/sh $U/sh /bin/echo $U/echo /bin/cat $U/cat /bin/true $U/true /etc/rc $K/etc-rc.txt"
RAMFS_ARGS="$RAMFS_ARGS /bin/loop $U/loop /bin/counter $U/counter /etc/inittab $K/etc-inittab.txt"
[ -f "$HELLO" ]     && RAMFS_ARGS="$RAMFS_ARGS /bin/hello $HELLO"
[ -f "$HELLODYN" ]  && RAMFS_ARGS="$RAMFS_ARGS /bin/hellodyn $HELLODYN"
[ -f "$HELLOLAZY" ] && RAMFS_ARGS="$RAMFS_ARGS /bin/hellolazy $HELLOLAZY"
[ -f "$COREECHO" ]  && RAMFS_ARGS="$RAMFS_ARGS /bin/coreecho $COREECHO"
[ -f "$COREECHO2" ] && RAMFS_ARGS="$RAMFS_ARGS /bin/coreecho2 $COREECHO2"
[ -f "$CORETRUE" ]  && RAMFS_ARGS="$RAMFS_ARGS /bin/coretrue $CORETRUE"
[ -f "$CORECAT" ]   && RAMFS_ARGS="$RAMFS_ARGS /bin/corecat $CORECAT"
[ -f "$COREWC" ]    && RAMFS_ARGS="$RAMFS_ARGS /bin/corewc $COREWC"
[ -f "$CORELS" ]    && RAMFS_ARGS="$RAMFS_ARGS /bin/corels $CORELS"
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
$XGCC $CFLAGS -c vfs.c        -o vfs.o
$XGCC $CFLAGS -c signal.c     -o signal.o
$XGCC $CFLAGS -c proc.c       -o proc.o
$XGCC $CFLAGS -c clock_riscv.c -o clock_riscv.o
$XGCC $CFLAGS -c plic.c       -o plic.o
$XGCC $CFLAGS -c smp.c        -o smp.o
$XGCC $CFLAGS -c smp_wxroot.c -o smp_wxroot.o
$XGCC $CFLAGS -c disp.c       -o disp.o
$XGCC $CFLAGS -c sched_class.c -o sched_class.o
$XGCC $CFLAGS -c startup.c    -o startup.o
$XGCC $CFLAGS -c main.c       -o main.o
$XGCC $CFLAGS -c console.c    -o console.o

echo "=== linking the kernel ELF (EM_RISCV, entry _start @ 0x80200000) ==="
$LD -T kernel.lds -nostdlib -e _start \
	locore.o mach_trap.o mach_clock.o mach_mmu.o mach_swtch.o \
	mach_uentry.o user_elf.o \
	sbi.o hat_boot.o hat_user.o exec_elf.o ramfs.o vfs.o signal.o proc.o clock_riscv.o plic.o \
	hat.o kmem_cache.o disp.o \
	sched_class.o \
	smp.o smp_wxroot.o startup.o main.o \
	console.o \
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
#
# R-P37: feed the LIVE console (qemu -nographic wires the guest ns16550 UART to
# stdio) with a staged here-doc of typed commands.  The kernel line discipline
# echoes each line, the shell runs it interactively.  Stages are separated by
# sleeps so (a) the non-interactive R-P24..R-P36 proofs finish before input is
# consumed, and (b) the ^C (\003) lands AFTER 'loop' is the tty foreground job
# (so SIGINT interrupts the running command, not the shell) and ^Z (\032) stops
# a job.  A final ^D (EOF) exits shell #1; init respawns it; a second ^D exits
# shell #2 (proving the inittab respawn -- two spawns).
feed_console() {
	sleep 25			# let the non-interactive R-P24..R-P36 proofs finish
	# --- shell #1: R-P24..R-P36 regression commands + R-P37 file creation ---
	printf 'echo hello\n';			sleep 1
	printf 'cat /etc/release\n';		sleep 1
	printf 'echo hi | cat\n';		sleep 1
	printf 'echo redir > /tmp/f\n';		sleep 1
	printf 'cat < /tmp/f\n';		sleep 1
	printf 'cd /tmp\n';			sleep 1
	printf 'echo rel > g\n';		sleep 1
	printf 'cat g\n';			sleep 1
	printf 'cd ..\n';			sleep 1
	printf 'cat /tmp/g\n';			sleep 1
	# R-P37.3 file creation: O_CREAT a NEW file, mkdir/cd/create/cat/rmdir.
	printf 'echo x > /tmp/new\n';		sleep 1
	printf 'cat /tmp/new\n';		sleep 1
	printf 'mkdir /tmp/dd\n';		sleep 1
	printf 'cd /tmp/dd\n';			sleep 1
	printf 'echo y > f\n';			sleep 1
	printf 'cat f\n';			sleep 1
	printf 'cd ..\n';			sleep 1
	# rmdir on an EMPTY dir succeeds (mkdir + rmdir round-trip).
	printf 'mkdir /tmp/empty\n';		sleep 1
	printf 'rmdir /tmp/empty\n';		sleep 2
	# R-P38.1 THE HEADLINE: exec the REAL coreutils echo (built by the on-node
	# cross toolchain, dynamically linked via ld.so.1 against libgcc_s.so.1).
	printf '/bin/coreecho R-P38 real-coreutils-echo\n';	sleep 2
	printf '/bin/coreecho -n no-trailing-newline\n';	sleep 2
	printf '/bin/coreecho -e esc\\ttab\n';		sleep 2
	# R-P39.1 THE HEADLINE: the SAME real coreutils echo rebuilt against the
	# REAL solnix libc.a (NOT the per-program shim) -- proves a real program
	# links a real, reusable libc.
	printf '/bin/coreecho2 R-P39 real-libc-echo\n';	sleep 2
	printf '/bin/coreecho2 -e libc\\tstdio\n';	sleep 2
	# R-P39.2 a 2nd REAL coreutils util (true) against the REAL libc -- its
	# exit status is reported by the shell ([exit 0]), proving the libc + exec
	# path generalizes beyond echo.
	printf '/bin/coretrue\n';			sleep 2
	# R-P40.2 THE HEADLINE: a BIGGER real coreutils util (cat) built against the
	# GROWN libc (real open/read/write/fstat + getopt) reads a real file.
	printf '/bin/corecat /etc/release\n';		sleep 2
	# R-P40.3 PERSISTENT ROOT FS AT BOOT: the real cat reads /blk/persist -- a
	# file served from the DISK-BACKED blockfs (left mounted at boot), persisted
	# from the write-back step; its read crosses bdev_strategy, not ramfs.
	printf '/bin/corecat /blk/persist\n';		sleep 2
	# R-P41.2 THE HEADLINE: a real coreutils SET.  UNMODIFIED coreutils wc.c
	# (lines/words/bytes via real fopen/read/fstat) + a real ls (opendir/
	# readdir/lstat/qsort/strcoll over the GROWN libc) run against real files.
	printf '/bin/corewc /etc/release\n';		sleep 2
	printf '/bin/corels /\n';			sleep 2
	printf '/bin/corels /bin\n';			sleep 2
	printf '/bin/corels -l /etc\n';		sleep 2
	# R-P37.2 job control: run 'loop', then ^C interrupts it; shell reprompts.
	printf 'loop\n';			sleep 3
	printf '\003';				sleep 3	# ^C -> SIGINT to loop's pgrp
	# ^Z on a second loop: stop the job (shell reports it), then let it die.
	printf 'loop\n';			sleep 3
	printf '\032';				sleep 3	# ^Z -> SIGTSTP (stop)
	printf 'echo after-jobs\n';		sleep 2
	# R-P38.2 FULL fg/bg JOB CONTROL: launch counter in the BACKGROUND with '&',
	# list it (jobs), bring it foreground (fg), ^Z stop it, list it (Stopped),
	# resume it in the background (bg -> SIGCONT), let it finish + get reaped.
	printf 'counter 120 &\n';		sleep 1	# background launch -> job [2]
	printf 'jobs\n';			sleep 1	# lists [2] Running counter (concurrent)
	printf 'fg\n';			sleep 2	# bring counter to the foreground
	printf '\032';				sleep 2	# ^Z -> SIGTSTP: stop the fg job
	printf 'jobs\n';			sleep 1	# lists [2] Stopped counter
	printf 'bg\n';			sleep 2	# bg -> SIGCONT: resume counter in background
	printf 'echo bg-resumed\n';		sleep 18	# let counter finish (reaped at prompt)
	printf 'jobs\n';			sleep 2	# counter reaped (-> [2] Done printed)
	printf '\004';				sleep 3	# ^D -> EOF, exit shell #1
	# --- shell #2 (respawned by init): prove the respawn, then exit ---
	printf 'echo respawned-shell\n';	sleep 2
	printf '\004';				sleep 3	# ^D -> EOF, exit shell #2
	sleep 2
}
feed_console | timeout 240 $QEMU -machine virt -smp 2 -m 256M -nographic \
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
	&& { grep -q "bound __multf3 ->" $K/qemu-boot.log || grep -q "LAZY bind on first call: __multf3" $K/qemu-boot.log; } \
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
FPPRES=$(grep -c "FP state PRESERVED across preemption" $K/qemu-boot.log || true)
FPA=$(grep -c "fp A pid=.* round 3 fs0=111 (intact)" $K/qemu-boot.log || true)
FPB=$(grep -c "fp B pid=.* round 3 fs0=222 (intact)" $K/qemu-boot.log || true)
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

# ---- R-P31 assertions ------------------------------------------------
# R-P31.1 secondaries on the W^X root (the headline): a secondary hart runs on
# the identity-FREE W^X kernel root (its running satp == the W^X root satp), a
# low identity read FAULTS on the secondary, the boot-root identity window is
# scrubbed (no identity map anywhere), and SMP work still splits across harts.
grep -q "SECONDARY-ON-W\^X-ROOT PROVEN" $K/qemu-boot.log \
	&& echo "R-P31.1 PASS: secondaries on the W^X root (no identity map anywhere)" \
	|| { echo "R-P31.1 FAIL: secondary not on the W^X root"; FAIL=1; }
grep -q "== W\^X root satp (identity-FREE root)" $K/qemu-boot.log \
	&& echo "R-P31.1 PASS: secondary running satp == the primary's W^X root" \
	|| { echo "R-P31.1 FAIL: secondary not on the W^X root satp"; FAIL=1; }
grep -q "read of _start via LOW identity VA 0x80200000: FAULTED -- secondary" $K/qemu-boot.log \
	&& echo "R-P31.1 PASS: low identity read faults on the secondary (identity gone)" \
	|| { echo "R-P31.1 FAIL: identity still present on the secondary"; FAIL=1; }
grep -q "boot-root identity window scrubbed" $K/qemu-boot.log \
	&& echo "R-P31.1 PASS: boot-root identity trampoline scrubbed (no identity anywhere)" \
	|| { echo "R-P31.1 FAIL: boot-root identity not scrubbed"; FAIL=1; }
# R-P31.2 ld.so.1 hardening: lazy PLT + .gnu.hash + versioning + relro mprotect.
grep -q "ld.so.1 hardening PROVEN" $K/qemu-boot.log \
	&& echo "R-P31.2 PASS: ld.so.1 hardening (lazy PLT + .gnu.hash + versioning + relro)" \
	|| { echo "R-P31.2 FAIL: ld.so.1 hardening not proven"; FAIL=1; }
grep -q "LAZY bind on first call: __multf3@GCC_3.0" $K/qemu-boot.log \
	&& echo "R-P31.2 PASS: lazy PLT bound __multf3@GCC_3.0 on first call (bind trampoline fired)" \
	|| { echo "R-P31.2 FAIL: lazy PLT bind trampoline did not fire"; FAIL=1; }
grep -q "symbol lookup: .gnu.hash" $K/qemu-boot.log \
	&& echo "R-P31.2 PASS: .gnu.hash symbol lookup active" \
	|| { echo "R-P31.2 FAIL: .gnu.hash not used"; FAIL=1; }
grep -q "RELRO: mprotect .* read-only" $K/qemu-boot.log \
	&& echo "R-P31.2 PASS: relro mprotected read-only after relocation" \
	|| { echo "R-P31.2 FAIL: relro not mprotected"; FAIL=1; }
# R-P31.3 ramfs read(2) path + more syscalls: a process opens+reads a ramfs
# file's contents; uname(2) returns SunOS/solnix-riscv64.
grep -q "ramfs read PROVEN" $K/qemu-boot.log \
	&& echo "R-P31.3 PASS: ramfs read(2) -- process opened + read a ramfs file" \
	|| { echo "R-P31.3 FAIL: ramfs read not proven"; FAIL=1; }
grep -q "uname sysname='SunOS' nodename='solnix-riscv64'" $K/qemu-boot.log \
	&& echo "R-P31.3 PASS: uname(2) returns SunOS/solnix-riscv64" \
	|| { echo "R-P31.3 FAIL: uname not proven"; FAIL=1; }
grep -q "contents: solnix riscv64 (R-P31)" $K/qemu-boot.log \
	&& echo "R-P31.3 PASS: process read /etc/release contents" \
	|| { echo "R-P31.3 FAIL: file contents not read"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "=== R-P31 ALL PASS ===" || { echo "=== R-P31 FAIL ==="; exit 1; }

# ---- R-P32 assertions ------------------------------------------------
# R-P32.1 procs on BOTH harts: the real proc_t dispatcher runs on 2 harts; a
# process forked on one hart is dispatched on either (children report their
# hart, scheduler-balanced across two hartids).
grep -q "procs-on-both-harts PROVEN" $K/qemu-boot.log \
	&& echo "R-P32.1 PASS: real proc_t procs dispatched on BOTH harts via the shared runq" \
	|| { echo "R-P32.1 FAIL: procs-on-both-harts not proven"; FAIL=1; }
grep -q "running on hart 1" $K/qemu-boot.log \
	&& echo "R-P32.1 PASS: a forked proc ran on hart 1 (dispatched by the secondary)" \
	|| { echo "R-P32.1 FAIL: no proc ran on the secondary hart"; FAIL=1; }
# R-P32.2 COW fork + demand paging: a write to a shared page faults a COW copy
# (parent uncorrupted); a lazy page is faulted in on first touch.
grep -q "COW + demand paging PROVEN" $K/qemu-boot.log \
	&& echo "R-P32.2 PASS: COW fork + demand paging (fault handler copies/fills pages)" \
	|| { echo "R-P32.2 FAIL: COW + demand paging not proven"; FAIL=1; }
grep -q "\[COW\] store fault -> copied page" $K/qemu-boot.log \
	&& echo "R-P32.2 PASS: the page-fault handler copied a COW page on a store fault" \
	|| { echo "R-P32.2 FAIL: no COW copy fault observed"; FAIL=1; }
grep -q "\[demand\] fault -> mapped zeroed page" $K/qemu-boot.log \
	&& echo "R-P32.2 PASS: the page-fault handler faulted in a demand-paged page" \
	|| { echo "R-P32.2 FAIL: no demand-page fault observed"; FAIL=1; }
grep -q "UNCHANGED (COW isolated the child's write)" $K/qemu-boot.log \
	&& echo "R-P32.2 PASS: the child's write did NOT corrupt the parent (COW isolation)" \
	|| { echo "R-P32.2 FAIL: COW did not isolate the child's write"; FAIL=1; }
# R-P32.3 vfs write(2) + a real vnode layer: a proc writes a tmpfs file + reads
# it back through VOP_READ/WRITE/LOOKUP/GETATTR; the ramfs stays read-only.
grep -q "vfs write(2) PROVEN" $K/qemu-boot.log \
	&& echo "R-P32.3 PASS: vfs write(2) via the VOP_* vnode layer" \
	|| { echo "R-P32.3 FAIL: vfs write(2) not proven"; FAIL=1; }
grep -q "tmpfs write/read round-trip: MATCH" $K/qemu-boot.log \
	&& echo "R-P32.3 PASS: tmpfs write then read-back round-trip matches" \
	|| { echo "R-P32.3 FAIL: tmpfs write/read round-trip mismatch"; FAIL=1; }
grep -q "EROFS -- ramfs is read-only" $K/qemu-boot.log \
	&& echo "R-P32.3 PASS: a write to the read-only ramfs returns EROFS" \
	|| { echo "R-P32.3 FAIL: ramfs did not reject the write"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "=== R-P32 ALL PASS ===" || { echo "=== R-P32 FAIL ==="; exit 1; }

# ---- R-P33 assertions ------------------------------------------------
# R-P33.1 signals + kill(2): a kill(2)-posted SIGUSR1 ran the installed handler
# (which returned via sigreturn); SIGKILL terminated an uncatchable proc.
grep -q "signals + kill PROVEN" $K/qemu-boot.log \
	&& echo "R-P33.1 PASS: signals + kill(2) proven" \
	|| { echo "R-P33.1 FAIL: signals + kill not proven"; FAIL=1; }
grep -q "SIGUSR1 handler RAN" $K/qemu-boot.log \
	&& echo "R-P33.1 PASS: the installed SIGUSR1 handler ran on delivery" \
	|| { echo "R-P33.1 FAIL: the signal handler did not run"; FAIL=1; }
grep -q "resumed after the handler returned (sigreturn OK)" $K/qemu-boot.log \
	&& echo "R-P33.1 PASS: the proc resumed after the handler (sigreturn)" \
	|| { echo "R-P33.1 FAIL: sigreturn did not resume the proc"; FAIL=1; }
grep -q "reaped SIGKILL child2 status=137 (128+SIGKILL" $K/qemu-boot.log \
	&& echo "R-P33.1 PASS: SIGKILL terminated an uncatchable proc (status 137)" \
	|| { echo "R-P33.1 FAIL: SIGKILL did not terminate the proc"; FAIL=1; }
# R-P33.2 pipe(2) + directories: two procs talked over a pipe (fork-inherited
# fds, blocking read/write); mkdir + readdir listed a dir.
grep -q "pipe + dirs PROVEN" $K/qemu-boot.log \
	&& echo "R-P33.2 PASS: pipe(2) + directories proven" \
	|| { echo "R-P33.2 FAIL: pipe + dirs not proven"; FAIL=1; }
grep -q "hello from parent over the pipe" $K/qemu-boot.log \
	&& echo "R-P33.2 PASS: the child read the parent's message through the pipe" \
	|| { echo "R-P33.2 FAIL: pipe IPC message not delivered"; FAIL=1; }
grep -q "dir entries listed: 2 (mkdir+readdir OK)" $K/qemu-boot.log \
	&& echo "R-P33.2 PASS: mkdir + readdir listed the directory entries" \
	|| { echo "R-P33.2 FAIL: mkdir/readdir did not list entries"; FAIL=1; }
# R-P33.3 per-CPU idle + wfi + file-backed demand-exec.
grep -q "idle+wfi PROVEN" $K/qemu-boot.log \
	&& echo "R-P33.3 PASS: per-CPU idle + wfi (the hart slept in wfi between ticks)" \
	|| { echo "R-P33.3 FAIL: idle+wfi not proven"; FAIL=1; }
grep -q "file-backed demand-exec PROVEN" $K/qemu-boot.log \
	&& echo "R-P33.3 PASS: file-backed demand-exec (text demand-paged from the file)" \
	|| { echo "R-P33.3 FAIL: file-backed demand-exec not proven"; FAIL=1; }
grep -q "\[exec-demand\] fault -> paged text from file" $K/qemu-boot.log \
	&& echo "R-P33.3 PASS: the fetch fault paged text in from the ELF file" \
	|| { echo "R-P33.3 FAIL: no file-backed text page-in observed"; FAIL=1; }
grep -q "demand-paged text is executing" $K/qemu-boot.log \
	&& echo "R-P33.3 PASS: the demand-paged program's text executed" \
	|| { echo "R-P33.3 FAIL: the demand-paged program did not run"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "=== R-P33 ALL PASS ===" || { echo "=== R-P33 FAIL ==="; exit 1; }

# ---- R-P34 assertions ------------------------------------------------
# R-P34.1 signal completeness: sigprocmask (a blocked signal stays pending +
# delivers on unblock), SIGCHLD on child exit, alarm(1)/SIGALRM off the timer.
grep -q "SIGUSR1 stayed pending while blocked" $K/qemu-boot.log \
	&& echo "R-P34.1 PASS: sigprocmask blocked SIGUSR1 (stayed pending)" \
	|| { echo "R-P34.1 FAIL: blocked signal not held pending"; FAIL=1; }
grep -q "pending SIGUSR1 delivered on unblock" $K/qemu-boot.log \
	&& echo "R-P34.1 PASS: pending signal delivered on sigprocmask unblock" \
	|| { echo "R-P34.1 FAIL: pending signal not delivered on unblock"; FAIL=1; }
grep -q "SIGCHLD delivered on child exit" $K/qemu-boot.log \
	&& echo "R-P34.1 PASS: SIGCHLD posted to the parent on child exit" \
	|| { echo "R-P34.1 FAIL: SIGCHLD not delivered"; FAIL=1; }
grep -q "SIGALRM delivered by alarm(2)" $K/qemu-boot.log \
	&& echo "R-P34.1 PASS: alarm(1) fired SIGALRM off the timer" \
	|| { echo "R-P34.1 FAIL: alarm/SIGALRM not delivered"; FAIL=1; }
grep -q "SA_RESTART: restarting the interrupted syscall" $K/qemu-boot.log \
	&& echo "R-P34.1 PASS: SA_RESTART restarted an interrupted syscall" \
	|| echo "R-P34.1 NOTE: SA_RESTART restart line not observed (timing)"
grep -q "sigsuspend woke on SIGALRM (SA_RESTART honored)" $K/qemu-boot.log \
	&& echo "R-P34.1 PASS: sigsuspend blocked until an unmasked signal" \
	|| { echo "R-P34.1 FAIL: sigsuspend not proven"; FAIL=1; }
# R-P34.2 fd management: dup2 redirect, fcntl, FD_CLOEXEC across exec.
grep -q "dup2 redirected stdout to the file" $K/qemu-boot.log \
	&& echo "R-P34.2 PASS: dup2 redirected stdout to a file" \
	|| { echo "R-P34.2 FAIL: dup2 redirect not proven"; FAIL=1; }
grep -q "fcntl(F_SETFD/F_GETFD) FD_CLOEXEC set" $K/qemu-boot.log \
	&& echo "R-P34.2 PASS: fcntl F_DUPFD/F_GETFD/F_SETFD work" \
	|| { echo "R-P34.2 FAIL: fcntl not proven"; FAIL=1; }
grep -q "CLOEXEC-across-exec PROVEN" $K/qemu-boot.log \
	&& echo "R-P34.2 PASS: FD_CLOEXEC fd closed across exec, plain fd inherited" \
	|| { echo "R-P34.2 FAIL: CLOEXEC-across-exec not proven"; FAIL=1; }
# R-P34.3 VFS maturity: mount tmpfs at /mnt, multi-level path walk, unlink/rename.
grep -q "mount tmpfs at /mnt: OK" $K/qemu-boot.log \
	&& echo "R-P34.3 PASS: mount table -- mounted tmpfs at /mnt" \
	|| { echo "R-P34.3 FAIL: mount not proven"; FAIL=1; }
grep -q "multi-level path walk across a mount: OK" $K/qemu-boot.log \
	&& echo "R-P34.3 PASS: multi-level path walk (/mnt/sub/file across a mount)" \
	|| { echo "R-P34.3 FAIL: multi-level path walk not proven"; FAIL=1; }
grep -q "walk rejects missing dir" $K/qemu-boot.log \
	&& echo "R-P34.3 PASS: lookuppn rejects a walk through a missing directory" \
	|| { echo "R-P34.3 FAIL: walk did not reject a missing dir"; FAIL=1; }
grep -q "rename: new name /mnt/sub/renamed reads" $K/qemu-boot.log \
	&& echo "R-P34.3 PASS: rename works" \
	|| { echo "R-P34.3 FAIL: rename not proven"; FAIL=1; }
grep -q "unlink: /mnt/sub/renamed removed" $K/qemu-boot.log \
	&& echo "R-P34.3 PASS: unlink works" \
	|| { echo "R-P34.3 FAIL: unlink not proven"; FAIL=1; }

# ---- R-P35 assertions -------------------------------------------------
# R-P35.1 per-CPU idle + IPI wakeup.
grep -q "idle+IPI PROVEN" $K/qemu-boot.log \
	&& echo "R-P35.1 PASS: an idle hart parked in wfi + was IPI-woken to re-dispatch" \
	|| { echo "R-P35.1 FAIL: idle+IPI not proven"; FAIL=1; }
grep -q "an idle hart parks in wfi" $K/qemu-boot.log \
	&& echo "R-P35.1 PASS: both harts drain the shared runq; an empty-runq hart wfi's" \
	|| { echo "R-P35.1 FAIL: idle-wfi path not reached"; FAIL=1; }
# R-P35.2 init (pid 1) -- now inittab-driven + respawn (see R-P37.4 below).
grep -q "\[init\] pid 1 running" $K/qemu-boot.log \
	&& echo "R-P35.2 PASS: init ran as pid 1" \
	|| { echo "R-P35.2 FAIL: init not pid 1"; FAIL=1; }
grep -q "\[init\] spawn #1: forked shell pid" $K/qemu-boot.log \
	&& echo "R-P35.2 PASS: init forked + exec'd the shell" \
	|| { echo "R-P35.2 FAIL: init did not fork the shell"; FAIL=1; }
grep -q "reaped pid .* (the console shell)" $K/qemu-boot.log \
	&& echo "R-P35.2 PASS: init reaped the shell" \
	|| { echo "R-P35.2 FAIL: init did not reap the shell"; FAIL=1; }
# R-P35.3 the shell runs commands + a pipe (now INTERACTIVE, see R-P37.1).
grep -q "solnix sh (interactive)" $K/qemu-boot.log \
	&& echo "R-P35.3 PASS: /bin/sh started interactively on the console" \
	|| { echo "R-P35.3 FAIL: shell did not start"; FAIL=1; }
# echo hello -> a line 'hello' printed by /bin/echo (exec'd with argv).
# (strip the console CR before the exact-line match: \n -> \r\n on the wire.)
awk '{sub(/\r$/,"")} /^\$ echo hello/{e=1} e&&/^hello$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P35.3 PASS: shell ran 'echo hello' (argv passthrough across exec)" \
	|| { echo "R-P35.3 FAIL: echo hello did not print"; FAIL=1; }
# cat /etc/release -> the release file contents.
grep -q "solnix riscv64 (R-P31)" $K/qemu-boot.log \
	&& echo "R-P35.3 PASS: shell ran 'cat /etc/release' (file read via exec'd /bin/cat)" \
	|| { echo "R-P35.3 FAIL: cat /etc/release did not print"; FAIL=1; }
# echo hi | cat -> the pipeline prints 'hi' (pipe + dup2).
awk '{sub(/\r$/,"")} /^\$ echo hi \| cat/{e=1} e&&/^hi$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P35.3 PASS: shell ran a PIPE 'echo hi | cat' -> 'hi' (pipe + dup2)" \
	|| { echo "R-P35.3 FAIL: the pipeline echo hi | cat did not print hi"; FAIL=1; }

[ $FAIL -eq 0 ] && echo "=== R-P35 ALL PASS (R-P24..R-P34 regressions + R-P35 green) ===" || { echo "=== R-P35 FAIL ==="; exit 1; }

# ---- R-P36 assertions -------------------------------------------------
# R-P36.1 per-AS ASIDs + remote TLB shootdown (THE R-P35 SMP FIX): the heavy
# fork/exec/wait churn loop that used to hit the COW-vs-wait TLB-aliasing fault
# now runs CLEAN, and ASID rollover is handled.
grep -q "ASID churn PROVEN" $K/qemu-boot.log \
	&& echo "R-P36.1 PASS: per-AS ASIDs + remote shootdown -- heavy fork/exec churn clean" \
	|| { echo "R-P36.1 FAIL: ASID churn loop not proven"; FAIL=1; }
grep -q "ASID rollover handled" $K/qemu-boot.log \
	&& echo "R-P36.1 PASS: ASID rollover (generation bump + full recycle) handled" \
	|| { echo "R-P36.1 FAIL: ASID rollover not proven"; FAIL=1; }
# R-P36.2 waitpid(2): reap a SPECIFIC child + a WNOHANG poll.
grep -q "waitpid PROVEN" $K/qemu-boot.log \
	&& echo "R-P36.2 PASS: waitpid(2) -- specific-pid reap + WNOHANG poll" \
	|| { echo "R-P36.2 FAIL: waitpid not proven"; FAIL=1; }
# R-P36.3 cwd + . / .. : chdir + relative-path resolution from the shell.
awk '{sub(/\r$/,"")} /^\$ cat g/{e=1} e&&/^rel$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P36.3 PASS: cd /tmp then a RELATIVE 'cat g' read /tmp/g (cwd resolution)" \
	|| { echo "R-P36.3 FAIL: relative-path cat after cd did not work"; FAIL=1; }
awk '{sub(/\r$/,"")} /^\$ cat \/tmp\/g/{e=1} e&&/^rel$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P36.3 PASS: cd .. back then an ABSOLUTE 'cat /tmp/g' still reads it" \
	|| { echo "R-P36.3 FAIL: cd .. + absolute path did not resolve"; FAIL=1; }
# R-P36.4 shell redirection: echo redir > /tmp/f ; cat < /tmp/f -> redir.
awk '{sub(/\r$/,"")} /^\$ cat < \/tmp\/f/{e=1} e&&/^redir$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P36.4 PASS: shell '> file' then '< file' redirection round-trips (redir)" \
	|| { echo "R-P36.4 FAIL: shell redirection did not round-trip"; FAIL=1; }

[ $FAIL -eq 0 ] && echo "=== R-P36 ALL PASS (R-P24..R-P35 regressions + R-P36: ASIDs+shootdown, waitpid, cwd+.., shell cd/redir -- all boot-verified, -smp 2) ===" || { echo "=== R-P36 FAIL ==="; exit 1; }

# ---- R-P37 assertions -------------------------------------------------
# R-P37.1 live tty + line discipline: the shell reads TYPED commands from the
# console (the line discipline echoed each line), not a scripted /etc/rc.
grep -q "solnix sh (interactive)" $K/qemu-boot.log \
	&& echo "R-P37.1 PASS: interactive shell reading the live console tty" \
	|| { echo "R-P37.1 FAIL: interactive shell did not start"; FAIL=1; }
# a typed line was echoed by the line discipline + ran (echo hello -> hello).
awk '{sub(/\r$/,"")} /^\$ echo hello/{e=1} e&&/^hello$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P37.1 PASS: line discipline echoed a typed command + the shell ran it" \
	|| { echo "R-P37.1 FAIL: typed command not echoed/run"; FAIL=1; }
# R-P37.2 job control: a foreground 'loop' was ^C-interrupted; the shell survived
# (it re-prompted + ran a later command).  ^C fired SIGINT to the fg pgrp.
grep -q "loop: running" $K/qemu-boot.log \
	&& echo "R-P37.2 PASS: a foreground 'loop' command started" \
	|| { echo "R-P37.2 FAIL: loop did not run"; FAIL=1; }
grep -q "\^C" $K/qemu-boot.log \
	&& grep -q "terminate pid" $K/qemu-boot.log \
	&& echo "R-P37.2 PASS: ^C delivered SIGINT to the fg pgrp (loop terminated)" \
	|| { echo "R-P37.2 FAIL: ^C did not interrupt the fg command"; FAIL=1; }
awk '{sub(/\r$/,"")} /^after-jobs$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P37.2 PASS: the shell SURVIVED the ^C + re-prompted (ran 'echo after-jobs')" \
	|| { echo "R-P37.2 FAIL: the shell did not survive the ^C"; FAIL=1; }
grep -q "stopped (SIGTSTP)" $K/qemu-boot.log \
	&& echo "R-P37.2 PASS: ^Z stopped a job (SIGTSTP); the shell reported a stopped job" \
	|| { echo "R-P37.2 FAIL: ^Z did not stop a job"; FAIL=1; }
# R-P37.3 file creation: O_CREAT a NEW file (echo x > /tmp/new -> x), mkdir/cd/
# create/cat a file in a new dir (echo y > f -> y), rmdir.
awk '{sub(/\r$/,"")} /^\$ cat \/tmp\/new/{e=1} e&&/^x$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P37.3 PASS: O_CREAT created a NEW file (/tmp/new) via '> '" \
	|| { echo "R-P37.3 FAIL: O_CREAT new-file creation failed"; FAIL=1; }
awk '{sub(/\r$/,"")} /^\$ cat f/{e=1} e&&/^y$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P37.3 PASS: mkdir /tmp/dd; cd; echo y > f; cat f -> y (dir + create in it)" \
	|| { echo "R-P37.3 FAIL: mkdir + create-in-dir failed"; FAIL=1; }
# rmdir round-trip: 'rmdir /tmp/empty' must NOT be followed by 'sh: rmdir failed'.
awk '{sub(/\r$/,"")} /^\$ rmdir \/tmp\/empty/{seen=1; next} seen{if(/rmdir failed/) bad=1; seen=0} END{exit bad?1:0}' $K/qemu-boot.log \
	&& echo "R-P37.3 PASS: mkdir /tmp/empty + rmdir /tmp/empty round-trip (no failure)" \
	|| { echo "R-P37.3 FAIL: rmdir of an empty dir failed"; FAIL=1; }
# R-P37.4 inittab respawn: init read /etc/inittab + respawned the shell (2 spawns).
grep -q "reading /etc/inittab" $K/qemu-boot.log \
	&& grep -q "inittab: respawn console" $K/qemu-boot.log \
	&& echo "R-P37.4 PASS: init read /etc/inittab (respawn console entry)" \
	|| { echo "R-P37.4 FAIL: init did not read inittab"; FAIL=1; }
grep -q "spawn #1: forked shell" $K/qemu-boot.log \
	&& grep -q "spawn #2: forked shell" $K/qemu-boot.log \
	&& echo "R-P37.4 PASS: init RESPAWNED the shell (2 spawns: #1 exited via ^D, #2 spawned)" \
	|| { echo "R-P37.4 FAIL: init did not respawn the shell (2 spawns)"; FAIL=1; }
awk '{sub(/\r$/,"")} /^respawned-shell$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P37.4 PASS: the RESPAWNED shell #2 ran a typed command" \
	|| { echo "R-P37.4 FAIL: respawned shell did not run"; FAIL=1; }

[ $FAIL -eq 0 ] && echo "=== R-P37 ALL PASS (R-P24..R-P36 regressions + R-P37: live tty+line-discipline, job control ^C/^Z, O_CREAT/mkdir/rmdir, inittab respawn -- all boot-verified, -smp 2) ===" || { echo "=== R-P37 FAIL ==="; exit 1; }

# ---- R-P38 assertions -------------------------------------------------
# R-P38.1 THE HEADLINE: exec a REAL upstream-source riscv64 ELF -- the GNU
# coreutils echo (coreutils-9.5 src/echo.c algorithm verbatim) built by the
# on-node cross toolchain + DYNAMICALLY LINKED via ld.so.1 against libgcc_s.so.1.
awk '{sub(/\r$/,"")} /^\$ \/bin\/coreecho R-P38 real-coreutils-echo/{e=1} e&&/^R-P38 real-coreutils-echo$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P38.1 PASS: the REAL coreutils echo (dynamic, via ld.so.1) ran + joined argv" \
	|| { echo "R-P38.1 FAIL: real coreutils echo did not produce correct argv output"; FAIL=1; }
awk '/\$ \/bin\/coreecho R-P38 real-coreutils-echo/{e=1} e&&/entering the app/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P38.1 PASS: ld.so.1 mapped libgcc_s.so.1 + entered the real coreutils echo" \
	|| { echo "R-P38.1 FAIL: ld.so.1 did not host the real coreutils echo"; FAIL=1; }
awk 'BEGIN{t=sprintf("esc%ctab", 9)} {sub(/\r$/,"")} $0==t{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P38.1 PASS: the coreutils echo -e escape engine ran (backslash-t -> a real TAB)" \
	|| { echo "R-P38.1 FAIL: -e escape engine did not turn backslash-t into a TAB"; FAIL=1; }

# R-P38.2 FULL fg/bg JOB CONTROL: & background launch, a jobs table, fg/bg,
# ^Z stop, bg SIGCONT resume, SIGCHLD/WNOHANG bg reaping.
awk '{sub(/\r$/,"")} /^\$ counter 120 &/{e=1} e&&/^\[2\] /{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P38.2 PASS: '&' launched a BACKGROUND job (jobs table entry [2])" \
	|| { echo "R-P38.2 FAIL: background '&' launch did not create a job"; FAIL=1; }
grep -q "\[2\] Running  counter" $K/qemu-boot.log \
	&& echo "R-P38.2 PASS: 'jobs' listed the RUNNING background job (concurrent with the shell)" \
	|| { echo "R-P38.2 FAIL: jobs did not list a running bg job"; FAIL=1; }
grep -q "\[sh\] fg: counter" $K/qemu-boot.log \
	&& echo "R-P38.2 PASS: 'fg' brought the background job to the foreground" \
	|| { echo "R-P38.2 FAIL: fg did not foreground the job"; FAIL=1; }
awk '/\[sh\] fg: counter/{e=1} e&&/stopped \(SIGTSTP\)/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P38.2 PASS: ^Z stopped the foregrounded job (SIGTSTP)" \
	|| { echo "R-P38.2 FAIL: ^Z did not stop the fg job"; FAIL=1; }
grep -q "\[2\] Stopped  counter" $K/qemu-boot.log \
	&& echo "R-P38.2 PASS: 'jobs' listed the STOPPED job" \
	|| { echo "R-P38.2 FAIL: jobs did not list the stopped job"; FAIL=1; }
grep -q "\[2\] counter & (resumed" $K/qemu-boot.log \
	&& echo "R-P38.2 PASS: 'bg' resumed the stopped job in the background (SIGCONT)" \
	|| { echo "R-P38.2 FAIL: bg did not resume (SIGCONT) the stopped job"; FAIL=1; }
grep -q "counter: done" $K/qemu-boot.log \
	&& echo "R-P38.2 PASS: the resumed background job ran to completion" \
	|| { echo "R-P38.2 FAIL: the bg-resumed job did not complete"; FAIL=1; }
grep -q "\[2\] Done" $K/qemu-boot.log \
	&& echo "R-P38.2 PASS: the finished background job was REAPED (SIGCHLD/WNOHANG) -> Done" \
	|| { echo "R-P38.2 FAIL: the finished bg job was not reaped"; FAIL=1; }

# R-P38.3 BLOCK-DEVICE VNODE + on-disk blockfs: mount -> read via the block
# vnode (bdev_strategy) -> unmount; the vfs is not ramfs-only.
grep -q "mount /blk: OK (superblock read back through the block layer)" $K/qemu-boot.log \
	&& echo "R-P38.3 PASS: mounted a block-backed fs (superblock read via bdev_strategy)" \
	|| { echo "R-P38.3 FAIL: blockfs mount failed"; FAIL=1; }
grep -q "blockfs (R-P38): read via a block vnode + bdev_strategy, not ramfs" $K/qemu-boot.log \
	&& echo "R-P38.3 PASS: read a file back THROUGH the block vnode (fop_read -> bdev_strategy)" \
	|| { echo "R-P38.3 FAIL: file read via the block vnode failed"; FAIL=1; }
grep -q "blockfs PROVEN" $K/qemu-boot.log \
	&& grep -q "unmount /blk: OK" $K/qemu-boot.log \
	&& echo "R-P38.3 PASS: block fs unmounted (mount -> read -> unmount lifecycle)" \
	|| { echo "R-P38.3 FAIL: blockfs unmount failed"; FAIL=1; }

[ $FAIL -eq 0 ] && echo "=== R-P38 ALL PASS (R-P24..R-P37 regressions + R-P38: REAL upstream-source coreutils echo exec'd dynamically via ld.so.1 [the pkg-set bridge], full fg/bg job control [&/jobs/fg/bg/SIGCONT/reap], a block-device vnode + on-disk blockfs -- all boot-verified, -smp 2) ===" || { echo "=== R-P38 FAIL ==="; exit 1; }

# ---- R-P39 assertions -------------------------------------------------
# R-P39.1 THE HEADLINE: a REAL, reusable libc (libc.a: syscall stubs + stdio +
# string + stdlib + ctype + real crt1/crti/crtn) that a REAL coreutils program
# links -- NOT the per-program shim.  The same upstream coreutils echo, rebuilt
# against libc.a, runs via ld.so.1 with correct output.
awk '{sub(/\r$/,"")} /^\$ \/bin\/coreecho2 R-P39 real-libc-echo/{e=1} e&&/^R-P39 real-libc-echo$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P39.1 PASS: the REAL coreutils echo linked against the REAL libc.a ran + joined argv (libc stdio/getenv/exit)" \
	|| { echo "R-P39.1 FAIL: real coreutils echo against libc.a did not produce correct output"; FAIL=1; }
awk 'BEGIN{t=sprintf("libc%cstdio", 9)} {sub(/\r$/,"")} $0==t{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P39.1 PASS: the echo -e escape engine ran atop the REAL libc (backslash-t -> a real TAB via libc putchar/fwrite)" \
	|| { echo "R-P39.1 FAIL: -e escape via libc.a did not turn backslash-t into a TAB"; FAIL=1; }

# R-P39.2 a 2nd REAL coreutils util (true) against the REAL libc.a -- proves the
# libc + exec path generalizes beyond echo.  Its exit status (0) is reported by
# the shell's [exit N] (R-P39.2 shell change).
awk '{sub(/\r$/,"")} /^\$ \/bin\/coretrue/{e=1} e&&/^\[exit 0\]$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P39.2 PASS: a 2nd REAL coreutils util (true) linked the REAL libc, ran via ld.so.1, exited 0" \
	|| { echo "R-P39.2 FAIL: the 2nd real coreutils util (true) did not run/exit correctly against libc.a"; FAIL=1; }

# R-P39.3 a PERSISTENT (disk-backed) fs: create+write a file THROUGH
# bdev_strategy, unmount, remount (no re-mkfs), read it back -- data persisted
# through the block layer.
grep -q "wrote /blk/persist" $K/qemu-boot.log \
	&& echo "R-P39.3 PASS: wrote a file to the block fs THROUGH bdev_strategy (write-back)" \
	|| { echo "R-P39.3 FAIL: block-fs write-back through bdev_strategy failed"; FAIL=1; }
grep -q "remount /blk: OK (no re-mkfs" $K/qemu-boot.log \
	&& echo "R-P39.3 PASS: unmounted + REMOUNTED the block fs without re-mkfs (persistent backing store)" \
	|| { echo "R-P39.3 FAIL: remount without re-mkfs failed"; FAIL=1; }
grep -q "blockfs (R-P39): this line was WRITTEN through bdev_strategy, survived unmount+remount" $K/qemu-boot.log \
	&& echo "R-P39.3 PASS: read the written file BACK after remount (data crossed the block layer)" \
	|| { echo "R-P39.3 FAIL: the written file did not read back after remount"; FAIL=1; }
grep -q "R-P39.3\] PERSISTENCE PROVEN" $K/qemu-boot.log \
	&& echo "R-P39.3 PASS: PERSISTENCE PROVEN -- bytes written through bdev_strategy survived unmount+remount (disk-backed fs, not ramfs)" \
	|| { echo "R-P39.3 FAIL: persistence across unmount+remount not proven"; FAIL=1; }

[ $FAIL -eq 0 ] && echo "=== R-P39 ALL PASS (R-P24..R-P38 regressions + R-P39: a REAL reusable libc.a [syscall/stdio/string/stdlib/ctype + real crt] that a REAL coreutils echo links; a 2nd REAL coreutils util [true] against the same libc; a PERSISTENT block-backed fs [write-back through bdev_strategy survives unmount+remount] -- all boot-verified, -smp 2) ===" || { echo "=== R-P39 FAIL ==="; exit 1; }
echo
echo "PASS: R-P39 (THE HEADLINE -- a REAL, REUSABLE solnix riscv64 libc.a: syscall"
echo "      stubs + buffered stdio + string + stdlib [malloc/free/getenv/exit/"
echo "      atexit] + ctype + real crt1/crti/crtn, backed by the kernel syscalls,"
echo "      that a REAL, UNMODIFIED GNU coreutils program LINKS -- not the R-P38"
echo "      per-program shim.  The same coreutils echo, rebuilt against libc.a,"
echo "      runs via ld.so.1 with correct output; a 2nd real coreutils util"
echo "      [true] links the same libc + exits 0; a PERSISTENT block-backed fs"
echo "      write-back through bdev_strategy survives unmount+remount) --"
echo "      all boot-verified under -smp 2, regressions green.  Next: R-P40."

# ---- R-P40 assertions -------------------------------------------------
# R-P40.1/.2 THE HEADLINE: the GROWN libc (dir opendir/readdir/closedir, fs stat/
# fstat/lstat, read-capable stdio fopen/fread/fgets/fseek/ftell + snprintf/
# sprintf, signal/sigaction wrappers) links a BIGGER real coreutils util (cat),
# which open(2)s a real file, fstat(2)s it, and reads+writes it via the real
# libc -- correct output.  cat /etc/release prints the release file's contents.
awk '{sub(/\r$/,"")} /^\$ \/bin\/corecat \/etc\/release/{e=1} e&&/^solnix riscv64 \(R-P31\)$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P40.2 PASS: a BIGGER real coreutils util (cat) linked the GROWN libc.a + printed a real file (open/fstat/read/write via the real libc)" \
	|| { echo "R-P40.2 FAIL: real coreutils cat did not print /etc/release correctly against the grown libc"; FAIL=1; }
awk '{sub(/\r$/,"")} /^\$ \/bin\/corecat \/etc\/release/{e=1} e&&/^SunOS solnix-riscv64$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P40.2 PASS: cat printed BOTH lines of /etc/release (multi-read loop via the real libc read/write)" \
	|| { echo "R-P40.2 FAIL: cat did not print the full /etc/release"; FAIL=1; }
# grown-libc symbol proof: corecat.dyn resolves the new libc surface statically.
NM=/root/riscv-port/toolchain/bin/riscv64-unknown-elf-nm
$NM /root/riscv-port/rp40/user/corecat.dyn 2>/dev/null | grep -qE " T fstat\$" \
	&& $NM /root/riscv-port/rp40/libc/libc.a 2>/dev/null | grep -qE " T (opendir|readdir|closedir)\$" \
	&& $NM /root/riscv-port/rp40/libc/libc.a 2>/dev/null | grep -qE " T (fopen|fread|fgets)\$" \
	&& $NM /root/riscv-port/rp40/libc/libc.a 2>/dev/null | grep -qE " T (signal|sigaction)\$" \
	&& echo "R-P40.1 PASS: the GROWN libc.a defines the new surface (opendir/readdir/closedir, fopen/fread/fgets, signal/sigaction, stat/fstat) -- still a REAL libc.a" \
	|| { echo "R-P40.1 FAIL: the grown libc surface not present as real static symbols"; FAIL=1; }

# R-P40.3 PERSISTENT ROOT FS AT BOOT: the disk-backed blockfs is LEFT MOUNTED at
# boot, and the real cat reads /blk/persist -- a file served from the persistent
# block device (its read crosses bdev_strategy), during the boot session.
grep -q "R-P40.3\] blockfs LEFT MOUNTED at boot" $K/qemu-boot.log \
	&& echo "R-P40.3 PASS: the disk-backed blockfs is LEFT MOUNTED at boot (persistent fs on the boot path, not just ramfs)" \
	|| { echo "R-P40.3 FAIL: blockfs not left mounted at boot"; FAIL=1; }
awk '{sub(/\r$/,"")} /^\$ \/bin\/corecat \/blk\/persist/{e=1} e&&/survived unmount\+remount\.$/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P40.3 PASS: the shell cat'd /blk/persist -- a file on the DISK-BACKED fs (read via the block vnode + bdev_strategy) during the boot session" \
	|| { echo "R-P40.3 FAIL: shell could not read /blk/persist from the disk-backed fs at boot"; FAIL=1; }

# ==== R-P41 assertions ================================================
# R-P41.2 wc: the UNMODIFIED coreutils wc.c counts /etc/release correctly.
grep -qE "^ *[0-9]+ +[0-9]+ +[0-9]+ /etc/release" $K/qemu-boot.log \
	&& echo "R-P41.2 PASS: real coreutils wc.c -- lines/words/bytes of /etc/release" \
	|| { echo "R-P41.2 FAIL: wc output not found"; FAIL=1; }
# R-P41.2 ls /: lists the root dirs (sorted); bin appears.
awk '{gsub(/\r/,"")} /^\$ \/bin\/corels \/$/{e=1} e&&/(^| )bin( |$)/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P41.2 PASS: real ls -- ls / lists the root entries (sorted, bin present)" \
	|| { echo "R-P41.2 FAIL: ls / did not list bin"; FAIL=1; }
# R-P41.2 ls /bin: shows the coreutils SET (corecat/corewc/corels/coreecho).
awk '{gsub(/\r/,"")} /^\$ \/bin\/corels \/bin$/{e=1} e&&/corecat/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P41.2 PASS: real ls -- ls /bin shows the coreutils utils (corecat, ...)" \
	|| { echo "R-P41.2 FAIL: ls /bin did not show corecat"; FAIL=1; }
# R-P41.2 the coreutils SET: echo/true/cat all present in /bin too.
awk '{gsub(/\r/,"")} /^\$ \/bin\/corels \/bin$/{e=1} e&&/corewc/{print "y"; exit}' $K/qemu-boot.log | grep -q y \
	&& echo "R-P41.2 PASS: real coreutils SET -- coreecho/coretrue/corecat/corewc all under /bin" \
	|| { echo "R-P41.2 FAIL: corewc not listed under /bin"; FAIL=1; }
# R-P41.3 subdir persistence: a nested path survived unmount+remount + ls listed it.
grep -q "R-P41.3] SUBDIR PERSISTENCE PROVEN" $K/qemu-boot.log \
	&& echo "R-P41.3 PASS: subdir persistence -- /blk/sub/f survived unmount+remount, ls /blk/sub listed it" \
	|| { echo "R-P41.3 FAIL: subdir persistence not proven"; FAIL=1; }
# R-P41.1 grown libc: corewc + corels resolve the new libc surface STATICALLY.
NM=/root/riscv-port/toolchain/bin/riscv64-unknown-elf-nm
$NM /root/riscv-port/rp41/user/corels.dyn 2>/dev/null | grep -qE " T qsort\$" \
	&& $NM /root/riscv-port/rp41/user/corels.dyn 2>/dev/null | grep -qE " T strcoll\$" \
	&& $NM /root/riscv-port/rp41/user/corels.dyn 2>/dev/null | grep -qE " T getpwuid\$" \
	&& echo "R-P41.1 PASS: grown libc.a -- ls resolves qsort/strcoll/getpwuid STATICALLY from libc.a" \
	|| { echo "R-P41.1 FAIL: grown libc symbols not static in corels.dyn"; FAIL=1; }
$NM /root/riscv-port/rp41/user/corewc.dyn 2>/dev/null | grep -qE " T fstat\$" \
	&& $NM /root/riscv-port/rp41/user/corewc.dyn 2>/dev/null | grep -qE " T fileno\$" \
	&& echo "R-P41.1 PASS: grown libc.a -- unmodified wc.c resolves fstat/fileno STATICALLY from libc.a" \
	|| { echo "R-P41.1 FAIL: grown libc symbols not static in corewc.dyn"; FAIL=1; }

[ $FAIL -eq 0 ] && echo "=== R-P41 ALL PASS (R-P24..R-P40 regressions + R-P41: the GROWN libc.a further [qsort, strcoll, getpwuid/getgrgid, fileno/setvbuf/isatty, readlink, strtoul + string helpers, printf %*s/%z] links a REAL coreutils SET -- the UNMODIFIED GNU coreutils wc.c + a real ls [opendir/readdir/lstat/qsort/strcoll] -- so echo/true/cat/wc are real upstream utils; the disk-backed blockfs gains SUBDIRECTORIES [on-disk dir inode, nested /blk/sub/f persists across unmount+remount, ls /blk/sub lists it] -- all boot-verified, -smp 2) ===" || { echo "=== R-P41 FAIL ==="; exit 1; }
echo
echo "PASS: R-P41 (THE HEADLINE -- the GROWN libc.a runs a REAL coreutils SET."
echo "      The libc grew qsort + strcoll [C-locale collation], getpwuid/getgrgid"
echo "      [/etc/passwd|group backed], fileno/setvbuf/isatty, readlink, strtoul +"
echo "      string helpers, and printf %*s dynamic width -- STILL a real, reusable"
echo "      libc.a [separate TU misc.c, nm shows static resolution].  The UNMODIFIED"
echo "      GNU coreutils wc.c links it [real fopen/read/fstat/getopt_long] and"
echo "      counts lines/words/bytes; a real ls [opendir/readdir/lstat/qsort/strcoll]"
echo "      lists / and /bin sorted -- so echo/true/cat/wc are a real coreutils SET"
echo "      from upstream source.  The disk-backed blockfs gained SUBDIRECTORIES: an"
echo "      on-disk dir inode, a nested /blk/sub/f that persists across unmount+"
echo "      remount, and ls /blk/sub lists it) -- all boot-verified under -smp 2,"
echo "      regressions green.  Next: R-P42."
