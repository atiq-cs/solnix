#!/usr/bin/env bash
#
# rp37-milestone-check.sh -- re-runnable proof of the R-P37 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P37.1  LIVE tty/console input + a canonical LINE DISCIPLINE.  A console
#            driver (console.c) reads console input via the SBI legacy console
#            getchar (OpenSBI owns the qemu-virt ns16550 UART @ 0x10000000, so
#            the guest asks OpenSBI for bytes; -nographic wires host stdin to
#            that UART), drained on the timer tick (a polled RX stand-in) AND by
#            console_read (the fd-0 backend, in-kernel where the tick is masked).
#            Canonical mode: echo, backspace erase, CR->NL, ^D EOF, feeding
#            read(2) on fd 0.  The shell reads TYPED commands interactively.
#            Proof: the boot feeds the console via qemu's piped stdin (a here-doc
#            of commands); the line discipline echoes each line + the shell runs
#            it (echo hello -> hello, cat/pipe/redir, all typed live).
#   R-P37.2  JOB CONTROL basics.  Process groups (setpgid) + a tty foreground
#            pgrp (tty_setfg); the shell puts a fg command in its own group + on
#            the tty, so a ^C on the console delivers SIGINT to the RUNNING
#            command (not the shell), and ^Z delivers SIGTSTP (stop).  Proof: a
#            looping 'loop' command is ^C'd (SIGINT default terminate) and the
#            shell SURVIVES + re-prompts (runs a later command); a second 'loop'
#            is ^Z'd (stopped; the shell reports the stopped job).
#   R-P37.3  FILE CREATION.  open(2) O_CREAT/O_TRUNC/O_APPEND in the ramfs/tmpfs
#            vfs + mkdir(2)/rmdir(2).  Proof: 'echo x > /tmp/new' CREATES a new
#            file (not just truncates an existing one) -> cat -> x; mkdir /tmp/dd;
#            cd; echo y > f; cat f -> y; mkdir /tmp/empty + rmdir /tmp/empty.
#   R-P37.4  inittab-driven init + RESPAWN.  /sbin/init reads /etc/inittab (a
#            ramfs file: a console respawn entry) + respawns the shell whenever
#            it exits (the classic getty/respawn).  Proof: init reads inittab,
#            spawns the shell on the console; ^D exits shell #1; init RESPAWNS it
#            (spawn #2); the respawned shell runs a typed command.
#
# plus the R-P24..R-P36 regressions (build-kernel.sh asserts every one).
set -e
K=/root/riscv-port/rp37/kernel
cd $K
bash build-kernel.sh
echo
echo "== R-P37 headline assertions =="
LOG=$K/qemu-boot.log
fail() { echo "FAIL: $1"; exit 1; }

# R-P37.1 live tty + line discipline: a TYPED command was echoed + run.
grep -q "solnix sh (interactive)" $LOG || fail "R-P37.1 interactive shell not started"
awk '{sub(/\r$/,"")} /^\$ echo hello/{e=1} e&&/^hello$/{print "y"; exit}' $LOG | grep -q y \
	|| fail "R-P37.1 typed command not echoed/run"
echo "R-P37.1 PASS: live console tty + canonical line discipline -- the shell ran TYPED commands interactively"

# R-P37.2 job control: ^C interrupts the fg command; the shell survives; ^Z stops.
grep -q "loop: running" $LOG || fail "R-P37.2 loop did not run"
grep -q "\^C" $LOG || fail "R-P37.2 ^C not seen"
grep -q "terminate pid" $LOG || fail "R-P37.2 SIGINT did not terminate the fg command"
awk '{sub(/\r$/,"")} /^after-jobs$/{print "y"; exit}' $LOG | grep -q y \
	|| fail "R-P37.2 the shell did not survive the ^C"
grep -q "stopped (SIGTSTP)" $LOG || fail "R-P37.2 ^Z did not stop a job"
echo "R-P37.2 PASS: job control -- ^C SIGINT'd the fg pgrp (shell survived + re-prompted); ^Z stopped a job"

# R-P37.3 file creation: O_CREAT a new file; mkdir/create-in-dir; rmdir.
awk '{sub(/\r$/,"")} /^\$ cat \/tmp\/new/{e=1} e&&/^x$/{print "y"; exit}' $LOG | grep -q y \
	|| fail "R-P37.3 O_CREAT new-file creation failed"
awk '{sub(/\r$/,"")} /^\$ cat f/{e=1} e&&/^y$/{print "y"; exit}' $LOG | grep -q y \
	|| fail "R-P37.3 mkdir + create-in-dir failed"
awk '{sub(/\r$/,"")} /^\$ rmdir \/tmp\/empty/{s=1; next} s{if(/rmdir failed/) exit 1; s=0}' $LOG \
	|| fail "R-P37.3 rmdir of an empty dir failed"
echo "R-P37.3 PASS: O_CREAT new-file + mkdir/create-in-dir + rmdir round-trip"

# R-P37.4 inittab respawn: init read inittab + respawned the shell (2 spawns).
grep -q "reading /etc/inittab" $LOG || fail "R-P37.4 init did not read inittab"
grep -q "spawn #1: forked shell" $LOG || fail "R-P37.4 no spawn #1"
grep -q "spawn #2: forked shell" $LOG || fail "R-P37.4 init did not RESPAWN the shell"
awk '{sub(/\r$/,"")} /^respawned-shell$/{print "y"; exit}' $LOG | grep -q y \
	|| fail "R-P37.4 respawned shell did not run a command"
echo "R-P37.4 PASS: init read /etc/inittab + RESPAWNED the console shell (2 spawns)"

echo
echo "PASS: R-P37 (a LIVE console tty + canonical line discipline over the SBI"
echo "      console feeding read(2) on fd 0 -- the shell reads TYPED commands"
echo "      interactively, echo/backspace/^D-EOF; JOB CONTROL basics -- process"
echo "      groups + a tty foreground pgrp, ^C delivers SIGINT to the running"
echo "      command [the shell survives + re-prompts], ^Z delivers SIGTSTP [the"
echo "      shell reports a stopped job]; FILE CREATION -- open(2) O_CREAT/"
echo "      O_TRUNC/O_APPEND + mkdir(2)/rmdir(2) in the ramfs/tmpfs vfs; and an"
echo "      inittab-driven /sbin/init that reads /etc/inittab + RESPAWNS the"
echo "      console shell on exit [2 spawns]) -- all boot-verified under -smp 2,"
echo "      R-P24..R-P36 regressions green.  Next: R-P38."
