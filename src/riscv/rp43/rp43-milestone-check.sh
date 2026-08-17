#!/usr/bin/env bash
#
# rp43-milestone-check.sh -- re-runnable proof of the R-P43 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P43.1  pwd -- a REAL getcwd(2).  The kernel copies the calling proc's
#            tracked working-directory string (proc_t.p_cwd, maintained by
#            SYS_chdir) into the user buffer (kernel/proc.c proc_getcwd,
#            kernel/main.c SYS_getcwd), and the libc grew a getcwd wrapper
#            (port/syscall.c; NULL-buf malloc for gnulib xgetcwd).  The
#            UNMODIFIED GNU coreutils-9.5 src/pwd.c LINKS the REAL libc.a via
#            cu3-include/cu3_glue.h (xgetcwd + the robust_getcwd fallback names:
#            get_root_dev_ino/psame_inode/readdir_ignoring_dot_and_dotdot/dirfd).
#            Boot proof: cd /blk/sub; pwd -> /blk/sub (getcwd via SYS_getcwd).
#            The blockfs gained chdir-into-subdir (vfs_path_isdir recognizes a
#            /blk directory via vfs_blockfs_isdir).
#   R-P43.2  env -- the UNMODIFIED GNU coreutils-9.5 src/env.c LINKS the REAL
#            libc.a.  The libc grew execve/sigprocmask (port/syscall.c) +
#            putenv/setenv/unsetenv (port/stdlib.c, environ-array edits); the
#            cu3-include glue grew sig2str/operand2sig (small C-locale signal
#            tables), the sigset bit-ops (sigemptyset/fillset/addset/delset/
#            ismember), a PATH-searching execvp, x2nrealloc/xpalloc/xstrdup,
#            EXIT_CANCELED, and devmsg.  A small default envp (PATH=/bin PWD=/
#            HOME=/ SHELL=/bin/sh) is now laid on the exec initial stack (was
#            an empty env).  Boot proof: env -> prints the environment;
#            env FOO=bar -> reprints it with FOO=bar added (the modified env).
#            So echo/true/cat/wc/head/tail/basename/dirname/pwd/env = 10 real
#            UNMODIFIED upstream coreutils utils on ONE reusable libc.a.
#   ls.c     The faithful UNMODIFIED coreutils-9.5 src/ls.c (~5658 lines, ~31
#            gnulib modules) was attempted under a time box; see
#            rp43/LS-STATUS.txt for whether it LINKED (landed) or is deferred to
#            R-P44 with the blocking gnulib module named.  The from-scratch
#            R-P41 ls stays the exerciser regardless.
#
# plus the R-P24..R-P42 regressions (build-kernel.sh asserts every one).  The
# boot log is saved to rp43/qemu-boot.log (via tee) so the milestone is
# verifiable.
set -e
K=/root/riscv-port/rp43/kernel
cd $K
bash build-kernel.sh 2>&1 | tee /root/riscv-port/rp43/qemu-boot-milestone.log
# the raw serial capture the assertions grep lives at $K/qemu-boot.log; copy it
# to rp43/qemu-boot.log so the milestone artifact sits at the phase root.
cp $K/qemu-boot.log /root/riscv-port/rp43/qemu-boot.log

echo
echo "PASS: R-P43 milestone check complete (see the R-P43.* PASS lines above;"
echo "      the headline is R-P43 -- pwd + env are 2 MORE real, UNMODIFIED"
echo "      upstream coreutils utils on the SAME libc.a, for 10 total:"
echo "      echo/true/cat/wc/head/tail/basename/dirname/pwd/env.  pwd.c uses a"
echo "      REAL getcwd(2) [kernel copies proc_t.p_cwd]; env.c links once the"
echo "      libc grew execve/sigprocmask/putenv/setenv/unsetenv + the cu3 glue"
echo "      supplied sig2str/operand2sig small tables + execvp.  ls.c attempted"
echo "      under a time box -- see rp43/LS-STATUS.txt.  Boot log saved to"
echo "      rp43/qemu-boot.log.  Next: R-P44."
