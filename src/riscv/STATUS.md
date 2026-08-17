# RISC-V (riscv64) port — STATUS

**Phase reached: R-P53** (complete, boot-verified qemu-system-riscv64 -machine
virt -smp 2; 236 PASS / 0 real FAIL).  R-P53 makes the virtio-blk disk the
blockfs's DEFAULT backing: /blk is a real mount on the disk (mount table shows
`/blk on blockfs (virtio-blk disk)`), bdev_strategy routes straight to the
qemu -drive image with NO RAM fallback (the cross-restart file comes off the
real disk), and statvfs(2) reports the disk's REAL 8192-sector capacity.  It
adds a buffer cache (bread/bwrite/bdwrite over bdev_strategy -- a re-read hits
the cache, no second disk op), wires the virtio-blk interrupt through the PLIC
(an IRQ-driven sector read completes via the interrupt, not polling), and fixes
the libc stdin read-buffer (stdin was buf=NULL -> instant EOF) so UNMODIFIED
coreutils cut EMITS its field over a pipe.  The current per-phase status + proof
lives in `rp53/STATUS.md`; boot log `rp53/qemu-boot.log`.  Next: R-P54.

--------------------------------------------------------------------------------
Historical (R-P52) note follows:
--------------------------------------------------------------------------------

**Phase reached: R-P52** (complete, boot-verified qemu-system-riscv64 -machine
virt -smp 2; 228 PASS / 0 real FAIL).  R-P52 lands a REAL virtio-blk MMIO
split-virtqueue driver (kernel/virtio_blk.c): the device is probed
(magic/version 2/device-id 2, features negotiated, DRIVER_OK), a known-content
sector seeded in a qemu -drive image is READ back byte-exact through the
descriptor/avail/used rings (real DMA), a WRITE round-trips, and a file written
on a PRIOR qemu boot survives a full exit+restart (cross-restart persistence on
a real disk).  It also fixes libc/build-libc.sh (it was rebuilding the rp51
libc, so rp52 libc edits never compiled) and lands ungetc/freadptr/freadseek so
UNMODIFIED coreutils-9.5 cut links (26 real UNMODIFIED coreutils on one libc.a).
The current per-phase status + proof lives in `rp52/STATUS.md`; boot log
`rp52/qemu-boot.log`.  Next: R-P53.

--------------------------------------------------------------------------------
Historical (R-P47) note follows:
--------------------------------------------------------------------------------

**Phase reached: R-P47** (the R-P46 kernel -- which fixed the %b/nstrftime
blocker and added whoami/yes -- now **FIXES the two R-P46 deferred faults** and
adds **1 more UNMODIFIED coreutils** (false).  (1) The FULL `ls -l` output/
cleanup path no longer SIGSEGVs at exit: the reduced libc `fclose()` was calling
`free()` on the STATIC `stdout` stream (a non-heap FILE) from gnulib's
`close_stdout` atexit hook, corrupting the first-fit heap so the exit path
faulted; fixed by making `fclose` skip `free` for stdin/stdout/stderr (+ a
defensive heap-bounds guard in `free`).  `ls -l --time-style=+%b /etc` now
prints the whole long line (mode/nlink/owner/group/size/**MONTH**/name) AND
exits 0.  (2) `yes | head` over a closing pipe no longer faults the kernel: the
kernel took a NULL-vnode load fault because `fstat` of the pipe fd routed
through `fop_getattr(f_vnode==NULL)`; fixed by guarding pipe fds in
`proc_fstat`/`proc_lseek` and posting **SIGPIPE** (sig 13, default terminate)
to the writer in `pipe_write` when the readers hit 0 -- `yes` dies cleanly and
the shell survives.  (3) `false.c` (== `true.c` with EXIT_FAILURE) is the 14th
UNMODIFIED upstream coreutils on the one reusable libc.a.  Boot-verified under
qemu-system-riscv64 -machine virt -smp 2 -- **184 PASS / 0 real FAIL**.  One
item deferred to R-P48: the locale-abformat DEFAULT `ls -l` ("%b %e  %Y", no
--time-style) still stalls in ls startup BEFORE the listing (NOT the +%b path,
which exits cleanly); run backgrounded so it cannot block the boot.  See
rp47/LS-STATUS.txt.)

R-P47 deliverables (all boot-verified, -smp 2, on top of the R-P24..R-P46
regressions which stay green):

1. **FIXED the full `ls -l` output-path SIGSEGV (headline #1).**  Root cause:
   the reduced libc `fclose` (libc/port/stdio2.c) unconditionally `free()`d the
   FILE, but stdin/stdout/stderr are STATIC FILEs (`&__stdout`, static buffers).
   gnulib's `close_stdout` (atexit) does `fclose(stdout)` -> `free(&__stdout)`
   -> the first-fit allocator computed a bogus header and its exit-time coalesce
   dereferenced a clobbered `next` -> SIGSEGV.  Fix: `fclose` frees only a heap
   stream (skip stdin/stdout/stderr); `free` also gained a heap-bounds guard.
   PROVEN: `ls -l --time-style=+%b /etc` -> `-rw-r--r-- 1 0 0 44 Jan release`
   + `[exit 0]` (was: month printed then SIGSEGV).

2. **FIXED the yes|head kernel pipe-teardown fault (headline #2).**  Root cause:
   `proc_fstat` (kernel/proc.c) called `fop_getattr` on a pipe fd's NULL vnode
   (`f_pipe` set, `f_vnode==0`) -> NULL load fault (`fop_getattr` `ld 0(a0)`,
   `a0==0`) when `head` fstat'd its pipe stdin.  Fix: `proc_fstat`/`proc_lseek`
   guard pipe fds (report a char-special of size 0 / ESPIPE, no NULL deref),
   and `pipe_write` posts SIGPIPE (sig 13) to the writer when the readers reach
   0.  PROVEN: `yes | head -3` -> `[signal] sig 13 default action: terminate`
   for `yes`, then `echo pipe-survived` runs (no `[trap] halting`).

3. **One MORE UNMODIFIED coreutils-9.5 util: false.**  false.c (which
   `#include`s true.c verbatim, EXIT_FAILURE) links the real libc.a via the
   lsup gnulib support objects; `/bin/corefalse` runs + exits 1 -- 14 real
   upstream coreutils on one libc.a.

4. **Deferred to R-P48.**  The locale-abformat DEFAULT `ls -l` ("%b %e  %Y",
   no --time-style) still stalls in ls startup BEFORE printing `total`.  The
   +%b path (proven above) exits cleanly, and gnulib nstrftime formats the
   exact abformat string in isolation (stftest2), so this is NOT the %b/format
   path -- it is a separate stall in the wider default-`-l` startup.  Run
   backgrounded (`ls -l /etc &`) so it cannot block the boot.

---

## R-P46 (previous phase)

**Was: R-P46** (the R-P45 kernel -- which linked + ran the faithful
UNMODIFIED coreutils-9.5 ls.c -- now **FIXES the R-P45 deferred %b/nstrftime
blocker** and adds **2 more UNMODIFIED coreutils** (whoami, yes).  The %b
abbreviated-month time format -- which hung in nstrftime's abformat path in
R-P45 -- is fixed at the ROOT CAUSE: the reduced libc's `vfprintf` did not
parse the `.` precision, so ls `abformat_init`'s `snprintf("%.*s%s%s", ...)`
mis-consumed its varargs (int-as-char* -> NULL deref).  Teaching vfprintf the
`.prec` precision makes strftime + gnulib nstrftime format the abbreviated
month **"Jan  1  1970"** -- proven at three layers (stftest = libc strftime;
stftest2 = the REAL gnulib nstrftime.o via tzalloc/localtime_rz; real ls
`--time-style=+%b /etc` -> "Jan").  whoami runs (geteuid/getpwuid; the libc
grew getuid/geteuid/getgid/getegid); yes compiles + links.  Boot-verified under
qemu-system-riscv64 -machine virt -smp 2 -- **177 PASS / 0 FAIL**.  Two items
deferred to R-P47, NEITHER the %b path: the FULL default `ls -l` output-path
SIGSEGV (post-timestamp) + yes-over-a-closing-pipe kernel SIGPIPE fault.  See
rp46/LS-STATUS.txt.)

R-P46 deliverables (all boot-verified, -smp 2, on top of the R-P24..R-P45
regressions which stay green):

1. **FIXED the R-P45 %b/nstrftime hang (headline).**  Root cause bisected to
   the reduced libc `vfprintf` (libc/port/stdio.c) not parsing the `.`
   precision: on `snprintf("%.*s%s%s", prefix_len, fmt, abmon[i], pb+2)` (ls
   `abformat_init`, ls.c ~1373) it emitted a literal "%." and consumed no arg
   for `.*`, so the first `%s` took `prefix_len` (an int) as a `char*` ->
   `strlen(NULL)` -> a NULL-deref fault the freestanding process spun on.  Fix:
   vfprintf now parses `.prec` (`.*` from an int arg or `.N`) and `__emit_str`
   honors it (truncate to prec, NULL-safe) -- a real, faithful printf feature
   the reduced libc was missing; every printf-family caller benefits.  PROVEN:
   stftest (libc strftime + nl_langinfo(ABMON) -> "Jan  1  1970"), stftest2
   (the REAL gnulib nstrftime.o + time_rz.o via tzalloc/localtime_rz -> the ls
   -l default abformat string -> "Jan  1  1970"), and the real UNMODIFIED ls
   (`-l --time-style=+%b /etc` -> the "Jan" abbreviated month in the time col).

2. **Two MORE UNMODIFIED coreutils-9.5 utils on the SAME libc.a.**  whoami.c
   (geteuid()+getpwuid(); the libc grew getuid/geteuid/getgid/getegid returning
   0 for the single-user root kernel, port/misc.c) -- /bin/corewhoami prints
   the user + exits 0.  yes.c COMPILED + LINKED (main T) via the new cu3-include
   glue (parse_gnu_standard_options_only + full_write + bad_cast, reduced to the
   C-locale/POSIX behavior; the R-P45-grown libc's dirfd + sigset ops made the
   stale cu3_glue.h stubs redundant -- guarded out; the unreachable() macro
   collision guarded in wc_glue.h).

3. **Deferred to R-P47 (both NEWLY isolated, NEITHER is the %b path).**  (a) The
   FULL default `ls -l` (the whole -l pipeline through exit) trips a SEPARATE
   output-path SIGSEGV, POST-timestamp: the `+%b` run prints the month then
   faults in the -l output/cleanup path (not the time code, proven fixed).
   (b) `yes` EXECUTION over a closing pipe (yes | head) trips a kernel-side
   SIGPIPE / pipe-teardown fault; yes itself links cleanly.

---

## R-P45 (previous phase)

**Was: R-P45** (the R-P44 kernel -- which added a REAL riscv64
setjmp/longjmp to the reusable libc.a on top of 10 real UNMODIFIED upstream
coreutils utils -- now **compiles + links + RUNS the FAITHFUL UNMODIFIED GNU
coreutils-9.5 src/ls.c**, byte-for-byte upstream, against the real libc.a + 25
verbatim gnulib lib/*.c modules, dynamically via ld.so.1 as /bin/lsup.  ls
JOINS the real-upstream set for **11 unmodified coreutils on one libc.a**
[echo/true/cat/wc/head/tail/basename/dirname/pwd/env/ls], boot-verified under
qemu-system-riscv64 -machine virt -smp 2 -- **156 PASS / 0 FAIL**.)

R-P45 deliverables (all boot-verified, -smp 2, on top of the R-P24..R-P44
regressions which stay green):

1. **Resolved the gnulib generated-header surface via ROUTE A (faithful).**
   The R-P44 blocker was that gnulib's build-time header generation had not run
   for the cross build.  R-P45 fixed it WITHOUT touching ls.c or the gnulib .c:
   obstack.h is GENERATED from obstack.in.h with the one sed gnulib.mk uses
   (s|@REPLACE_OBSTACK@|0|); the shipped intprops.h/verify.h/attribute.h/idx.h/
   quotearg.h/human.h/mbswidth.h are used AS-IS; the natively-generated
   lib/config.h (illumos host == illumos-riscv64 target for nearly all HAVE_*)
   is used with a few HAVE_* sed'd to the reduced-libc truth (HAVE_STROPTS_H 0,
   HAVE_SYS_IOCTL_H 0) + SETLOCALE_NULL_MAX appended.  The KEYSTONES obstack.c
   + quotearg.c compile first, then 25 gnulib lib/*.c compile + link VERBATIM
   (47 TUs total compile OK / 0 fail, incl. src/ls.c + src/ls-ls.c):
   obstack quotearg human mbswidth mpsort hash filevercmp filemode argmatch
   xstrtol xstrtoumax idcache areadlink areadlink-with-size careadlinkat
   xgethostname gethostname c-strcasecmp c-strncasecmp mbrtowc mbrtoc32
   localcharset xalloc-die xmalloc version-etc version-etc-fsf file-has-acl
   acl-internal imaxtostr umaxtostr xstrtol-error closeout exitfail progname
   mbszero setlocale_null hard-locale nstrftime gettime time_rz propername-lite
   allocator.  The libc GREW the standard headers ls needs (assert/errno/stdint/
   wchar/uchar/locale/inttypes/wctype/getopt/time/langinfo/alloca + sys/param,
   sys/time, sys/sysmacros, sys/mkdev, sys/utsname, sys/acl; sys/stat grew the
   permission bits + timespec st_*tim; signal grew sig_atomic_t + sigset ops)
   and a new port/locale.c TU with the C-locale/UTC runtime (mbrtowc/mbsinit/
   wcwidth single-byte identity, setlocale/localeconv/nl_langinfo fixed C,
   UTC time via a verified civil-calendar gmtime_r/mktime/timegm, name-keyed
   getpwnam/getgrnam, ioctl/tcgetpgrp/uname, *_unlocked stdio, reallocarray/
   strtoumax, strerror + __assert_fail + a real C-locale strftime).  A small
   user/lsup_support.c holds the C-locale reductions for the 3 gnulib modules
   whose upstream .c pulls glibc-internal machinery the reduced libc lacks
   (fnmatch [compact C-locale glob, self-tested], canonicalize_filename_mode
   [lexical], xnumtoumax, error/error_at_line, close_stream, the setlocale_null
   *_unlocked variants, gl_locale_name_unsafe, mbszero, Version).

2. **The FAITHFUL UNMODIFIED coreutils-9.5 src/ls.c -- LINKED + RAN.**
   corelsup.dyn is EM_RISCV, NEEDED libgcc_s.so.1, INTERP /usr/lib/ld.so.1, and
   runs correct upstream output on the boot console:
     `$ /bin/lsup /` -> `bin  etc  lib  sbin  usr` (columns, sorted, C-locale);
     `$ /bin/lsup -l --time-style=long-iso /etc` -> `total 1` +
     `-rw-r--r-- 1 0 0 44 1970-01-01 00:00 release` (long form: mode string,
     nlink, uid, gid, size, ISO timestamp, name).  ls JOINS the 11-util
     real-upstream set on one libc.a.  ONE narrow sub-feature is DEFERRED to
     R-P46: the DEFAULT -l time format (%b abbreviated-month via ls's abformat
     precompute) HANGS in nstrftime's month-name path -- precisely isolated by
     boot bisection (ls /, ls /etc, ls -l --time-style=long-iso, and ls -l
     --time-style=+ ALL work; only the %b conversion loops).  The milestone
     uses --time-style=long-iso (the working numeric path).  See
     rp45/LS-STATUS.txt for the exact remaining blocker + the R-P46 plan.

R-P45 boot proof (rp45/qemu-boot.log, saved via tee): R-P45.3 PASS x3 (ls /
lists root entries; ls -l /etc prints the long form; ls.c LINKED against real
libc.a + gnulib lib/*.c), plus SJTEST + all R-P24..R-P44 regressions green --
156 PASS / 0 FAIL under -smp 2.  Next: R-P46 (fix the %b/abformat nstrftime
hang so the DEFAULT ls -l time column works; see rp45/LS-STATUS.txt).

---

# RISC-V (riscv64) port — STATUS

**Phase reached: R-P44** (the R-P43 kernel -- which ran 10 real, UNMODIFIED
upstream coreutils utils [echo/true/cat/wc/head/tail/basename/dirname/pwd/env]
on one reusable libc.a -- now gains a **REAL riscv64 setjmp/longjmp** (the RISC-V
psABI callee-saved save/restore in asm) in that same libc.a, boot-verified
under qemu-system-riscv64 -machine virt -smp 2 -- 154 PASS / 0 FAIL.)

R-P44 deliverables (all boot-verified, -smp 2, on top of the R-P24..R-P43
regressions which stay green):

1. **REAL riscv64 setjmp/longjmp (libc/port/setjmp.S + libc/include/setjmp.h).**
   setjmp saves the RISC-V psABI callee-saved set into the jmp_buf -- integer
   ra/sp/s0(fp)/s1/s2..s11 (14 uint64 slots) followed by the float fs0..fs11
   (12 uint64 slots); longjmp restores them and returns val, or 1 if val==0
   (the C89 rule).  gp/tp are per-thread-fixed and not saved.  _setjmp/_longjmp
   alias the plain forms, and (no signal mask in this reduced libc)
   sigsetjmp/siglongjmp are #defined to setjmp/longjmp.  The asm is assembled
   by the on-node riscv64-unknown-elf-as and added to the reusable libc.a via
   build-libc.sh; nm shows setjmp/longjmp defined T in libc.a.  Self-tested
   standalone: user/sjtest.c (/bin/sjtest) sets a jmp_buf, longjmps back over a
   nested stack-burning call -- the boot log shows the setjmp call site
   returning 42 with the stack intact ("SJTEST PASS: longjmp returned 42, stack
   intact") and the longjmp(env,0)->returns-1 rule.  This is the reusable,
   valuable headline part 1 and is DONE.  (Finding: coreutils-9.5 ls.c does not
   call setjmp/longjmp directly -- it only #includes <setjmp.h> for the type,
   which now resolves; the real setjmp/longjmp is correct + reusable regardless.)

2. **The faithful UNMODIFIED coreutils-9.5 src/ls.c -- scoped + DEFERRED to
   R-P45.**  This phase precisely scoped ls.c's gnulib surface (31 module
   headers; the exact ls-called API: hash/obstack/quotearg/human/mbswidth/
   mpsort/filevercmp/filemode/argmatch/xstrtol/idcache/areadlink/xgethostname/
   canonicalize/strftime) and found the concrete blocker: the tarball lib/
   ships the module .c but NOT their GENERATED headers (obstack.h from
   obstack.in.h, the C-library *.in.h wrappers, and the _GL_ATTRIBUTE_*/
   intprops.h/verify.h + a HAVE_* config.h).  A native configure of the
   cu-full tarball succeeds (lib/config.h generated) but gnulib uses the host
   /usr/include there, so it emits no local obstack.h/stdlib.h for the cross
   build against the reduced solnix libc.  The Route-B facade scaffold (the
   proven cu3-include system.h->glue pattern) is staged under
   user/ls-include/ (config.h + system.h + 31 module-header shims all routing
   to ls_glue.h), and the build-kernel.sh /bin/lsup console feed + R-P44.3
   assertions are ALREADY wired -- they DEFER cleanly when corelsup.dyn is
   absent and PASS the moment ls.c links.  See rp44/LS-STATUS.txt for the full
   scoping + the R-P45 plan (Route A verbatim-gnulib header generation, or
   Route B facade).  The from-scratch R-P41 ls (/bin/corels) stays the ls
   exerciser meanwhile.

R-P44 boot proof (rp44/qemu-boot.log, saved via tee): SJTEST PASS x2 (longjmp
42 + stack intact, val==0->1), libc.a defines setjmp/longjmp T, all
R-P24..R-P43 regressions green -- 154 PASS / 0 FAIL under -smp 2.  Next: R-P45
(land the faithful UNMODIFIED ls.c per rp44/LS-STATUS.txt, so ls joins the
real-upstream set for 11 utils).

---

**Phase reached: R-P43** (the R-P42 kernel -- which ran 8 real, UNMODIFIED
upstream coreutils utils [echo/true/cat/wc/head/tail/basename/dirname] on one
reusable libc.a -- now **links + runs 2 MORE real, UNMODIFIED upstream
coreutils utils, pwd + env, for 10 total**, all boot-verified under
qemu-system-riscv64 -machine virt -smp 2 -- 163 PASS / 0 FAIL.)

R-P43 deliverables (all boot-verified, -smp 2, on top of the R-P24..R-P42
regressions which stay green):

1. **pwd (UNMODIFIED coreutils-9.5 src/pwd.c) + a REAL getcwd(2).** The kernel
   got a real getcwd: kernel/proc.c proc_getcwd() copies the calling proc's
   tracked working-directory string (proc_t.p_cwd, already maintained by
   SYS_chdir/proc_chdir) into the user buffer, and kernel/main.c SYS_getcwd
   routes through it (was hardcoded to always return "/"). No vnode-to-root
   walk is needed -- proc_chdir already canonicalizes the cwd path, so this is
   the illumos u_cwd path-string approach. The libc grew a getcwd wrapper
   (port/syscall.c; a NULL buffer mallocs, for the gnulib xgetcwd(NULL,0)
   extension). src/pwd.c LINKS the real libc.a via cu3-include/cu3_glue.h,
   which supplies xgetcwd + the robust_getcwd fallback names
   (get_root_dev_ino/psame_inode/readdir_ignoring_dot_and_dotdot/dirfd/fchdir
   -- the fallback is unreachable because xgetcwd succeeds via SYS_getcwd). The
   blockfs gained chdir-into-subdir: vfs_path_isdir now recognizes a /blk
   directory via vfs_blockfs_isdir. nm shows getcwd resolved T STATICALLY from
   libc.a. Boot proof: cd /blk/sub; pwd -> /blk/sub. /bin/corepwd.

2. **env (UNMODIFIED coreutils-9.5 src/env.c).** The libc grew
   execve/sigprocmask (port/syscall.c; SYS_execve/SYS_sigprocmask) +
   putenv/setenv/unsetenv (port/stdlib.c, editing the environ array,
   copy-on-first-write off the crt1 stack vector). cu3-include/cu3_glue.h grew
   sig2str/operand2sig (small C-locale signal-name tables), the POSIX sigset
   bit-ops (sigemptyset/sigfillset/sigaddset/sigdelset/sigismember over the
   scalar sigset_t), a PATH-searching execvp, x2nrealloc/xpalloc/xstrdup,
   strtok, exit_failure/initialize_exit_failure, EXIT_CANCELED/EXIT_ENOENT/
   EXIT_CANNOT_INVOKE, intptr_t/IDX_MAX, devmsg, main_exit/emit_exec_status. A
   small DEFAULT ENVIRONMENT (PATH=/bin PWD=/ HOME=/ SHELL=/bin/sh) is now laid
   on the exec initial stack (kernel/exec_elf.c dynamic path -- the envp was
   previously NULL, an empty env; the auxv word count was fixed for the added
   envp vector). Boot proof: env -> prints PATH=/bin/PWD=//HOME=//SHELL=/bin/sh;
   env FOO=bar -> reprints the environment with FOO=bar added (env with a
   NAME=VAL and no command sets it into environ then prints the modified env).
   /bin/coreenv.

So the real, UNMODIFIED upstream coreutils SET on ONE reusable libc.a is now
**10 utils**: echo (R-P38/39), true (R-P39), cat (R-P40), wc (R-P41),
head/tail/basename/dirname (R-P42), **pwd** + **env** (R-P43). ls remains the
from-scratch R-P41 exerciser (/bin/corels).

3. **ls.c attempted, DEFERRED to R-P44 (time-boxed).** The faithful UNMODIFIED
   src/ls.c (5658 lines, ~31 gnulib modules) was attempted under a hard time
   box; it does not yet compile. The FIRST real blocker is setjmp.h -- ls.c
   uses setjmp/longjmp for its qsort comparison error recovery (sort_failed in
   sort_files()), which needs a REAL riscv64 setjmp/longjmp (asm, not a stub).
   The system-header shims (termios.h, sys/ioctl.h in rp43/user/ls-include/)
   were added; fnmatch.h and the ~30 gnulib .c modules (obstack/mpsort/hash/
   human/mbswidth/filevercmp/filemode/idcache/canonicalize/argmatch/dircolors/
   areadlink/xgethostname -- all present verbatim in
   rp43/upstream/cu-full/coreutils-9.5/lib/) are deferred to R-P44. Full detail
   + the R-P44 plan in rp43/LS-STATUS.txt. Deferring kept the phase wedge-proof:
   pwd+env (10 real utils) is the milestone.

Milestone: `bash rp43/rp43-milestone-check.sh` (163 PASS / 0 FAIL; boot log
saved to rp43/qemu-boot.log).

---

## R-P42 (previous phase)

**Phase reached: R-P42** (the R-P41 kernel -- which GREW a real, reusable
solnix riscv64 `libc.a` and ran a REAL coreutils SET [`echo`/`true`/`cat`/`wc`
from UNMODIFIED upstream source + a from-scratch `ls`] with subdirectory
persistence -- now **links + runs MORE real, UNMODIFIED upstream coreutils
utils on the SAME `libc.a`**: the verbatim GNU coreutils-9.5 `src/head.c` and
`src/tail.c` [`safe_read`/`full_read` + the real `read(2)` byte/line loop; the
libc grew `memrchr` for head's reverse line scan], dynamically linked via
`ld.so.1`, plus two more syscall-light utils `src/basename.c` + `src/dirname.c`
[gnulib `base_name`/`dir_len` reduced, pure string]. Each boot-verified under
`qemu-system-riscv64 -machine virt -smp 2` -- 155 PASS / 0 FAIL.)

R-P42 deliverables (all boot-verified, `-smp 2`, on top of the R-P24..R-P41
regressions which stay green):

1. **head + tail (UNMODIFIED coreutils-9.5 `src/head.c` + `src/tail.c`).**
   Compiled verbatim from a headerless build tree
   (`rp42/upstream/coreutils-9.5/src/{head,tail}.c`, byte-identical to the
   `coreutils-9.5.tar.xz` extract in `rp42/upstream/cu-full/`) against the REAL
   `rp42/libc/libc.a` via a per-util gnulib scaffolding built on the proven
   `wc_glue.h` C-locale reduction: `head-include/head_glue.h` supplies
   `safe_read`/`full_read` (gnulib `lib/safe-read.c`+`lib/full-write.c` reduced
   to the EINTR-retry loop), `xdectoumax` (`lib/xdectoint.c` reduced with the
   `bkKmMG...` IEC multipliers), `xmalloc`/`xnrealloc`, `offtostr`, `ISDIGIT`,
   `OFF_T_MAX`, `emit_mandatory_arg_note`, and `quote()`/`assure()` (identity in
   the C locale); `tail-include/tail_glue.h` adds `cl_strtod`/`xstrtod`,
   `xstrtoumax`+the `LONGINT_*` enum, `xnanosleep`/`iopoll`/`isapipe` (stubs --
   the `-f` follow path is unreachable without inotify on the reduced kernel),
   `struct timespec`+`get_stat_mtime`/`dtotimespec`, `xpalloc`, `last_component`,
   `main_exit`/`write_error`, and the `errno`/`fcntl` constants. The libc grew
   ONE symbol for these: `memrchr` (`port/misc.c`, proto in `include/string.h`),
   plus `clearerr`+`fpurge` in `port/stdio2.c`. `nm` shows `read`/`lseek`/
   `open`/`write`/`printf`/`getopt_long` resolved `T` STATICALLY from `libc.a`.
   Boot proof: `head -2 /etc/release` -> `solnix riscv64 (R-P31)` +
   `SunOS solnix-riscv64` (both lines); `tail -1 /etc/release` ->
   `SunOS solnix-riscv64` (the last line). `corehead.dyn`/`coretail.dyn` are
   `/bin/corehead` `/bin/coretail`.

2. **basename + dirname (UNMODIFIED coreutils-9.5 `src/basename.c` +
   `src/dirname.c`).** Two syscall-light utils (pure string, no new kernel
   syscall) against the same libc via `cu3-include/cu3_glue.h`, which reduces
   the gnulib `basename-lgpl`/`dirname-lgpl`/`stripslash` string helpers
   (`base_name`/`base_len`/`dir_len`/`last_component`/`strip_trailing_slashes`,
   POSIX single-slash) + the `filename.h` macros
   (`FILE_SYSTEM_PREFIX_LEN`/`ISSLASH`/`IS_RELATIVE_FILE_NAME`). Boot proof:
   `basename /usr/lib/ld.so.1` -> `ld.so.1`; `dirname /usr/lib/ld.so.1` ->
   `/usr/lib`. `/bin/corebasename` `/bin/coredirname`.

So the real, UNMODIFIED upstream coreutils SET on ONE reusable `libc.a` is now
**8 utils**: `echo` (R-P38/39), `true` (R-P39), `cat` (R-P40), `wc` (R-P41),
**`head`**, **`tail`**, **`basename`**, **`dirname`** (R-P42). `ls` remains the
from-scratch R-P41 exerciser (`/bin/corels`).

**DEFERRED to R-P43:**
- **`env.c`** -- attempted (`build-cu3.sh` compiles it optionally); does not
  compile against the current glue without `sig2str`/`operand2sig` (signal-name
  tables), `intptr_t`/`IDX_MAX`/`EXIT_CANCELED`/`SIGNUM_BOUND`. A bounded chunk
  of glue, deferred to keep R-P42 wedge-proof.
- **UNMODIFIED `src/ls.c`** -- 5658 lines, 31 gnulib module headers including the
  heavy ones (`obstack`, `mpsort`, `hash`, `human`, `mbswidth`, `dircolors`,
  `filevercmp`, `acl`, `canonicalize`, `filemode`, `strftime`, `idcache`). This
  is the same rabbit hole the R-P41 note flagged; NOT attempted past the include
  survey to avoid wedging the phase. The from-scratch R-P41 `ls` stays as the
  grown-libc exerciser. Real upstream `ls.c` deferred to R-P43+.

**Next: R-P43** -- land `env` (grow the glue with `sig2str`/`operand2sig` +
`intptr_t`/`IDX_MAX`), consider `pwd` (needs a kernel `getcwd`/`SYS_getcwd` --
the kernel has `SYS_chdir`/`SYS_mkdir` but no getcwd today) and `mkdir` the util
(`SYS_mkdir` exists; needs a `mkdir()` libc wrapper + `mkdir-p`/`modechange`/
`savewd` glue), and begin the real `ls.c` gnulib-module port
(`obstack`/`hash`/`mpsort` first).

R-P42 persisted files (host `/root/riscv-port/rp42/`):
- `libc/port/misc.c` (+`memrchr`), `libc/port/stdio2.c` (+`clearerr`/`fpurge`),
  `libc/include/string.h`/`stdio.h` (protos); `libc/build-libc.sh` retargeted to
  rp42.
- `user/head-include/` (`head_glue.h` + shim headers), `user/tail-include/`
  (`tail_glue.h` + shim headers), `user/cu3-include/` (`cu3_glue.h` + shims);
  `user/build-head.sh`, `user/build-tail.sh`, `user/build-cu3.sh`; the built
  `corehead.dyn`/`coretail.dyn`/`corebasename.dyn`/`coredirname.dyn`.
- `upstream/coreutils-9.5/src/{head,tail,basename,dirname}.c` (verbatim, in the
  headerless build tree) + `upstream/cu-full/` (full verbatim tarball extract).
- `kernel/build-kernel.sh` (retargeted rp41->rp42; builds head/tail/basename/
  dirname, embeds them in the initramfs, feeds the shell commands, and asserts
  the R-P42.* PASS lines from the boot log).

---

## History: R-P41 (previous phase)

**Phase reached: R-P41** (details below, kept for provenance).

(1) THE HEADLINE (part 1) -- GROW THE REAL libc.a FURTHER.  R-P40's `libc.a`
covered what `cat` referenced.  R-P41 adds a new SEPARATELY compiled TU
(`port/misc.c`) into the SAME real `ar` archive (`nm` shows every one resolved
STATICALLY, `T` -- not shims): `qsort` (a shellsort over arbitrary-width
elements, the K&R/illumos qsort reduced) + `bsearch`; `strcoll` (the C-locale
collation == `strcmp`); `getpwuid`/`getgrgid` (scan `/etc/passwd`/`/etc/group`
for the id's 3rd field, else synthesize the decimal id -- the illumos nsswitch
"files" backend reduced to a single-file scan; `ls -l` owner/group names);
`fileno`/`isatty`/`setvbuf` (stdio glue `ls`/`wc` call at startup); `readlink`
(ENOSYS -- no symlinks; `lstat`==`stat`); `strtoul`; and `strdup`/`strnlen`/
`strspn`/`strcspn`/`strpbrk`/`strstr`/`memchr`/`mempcpy`.  `port/stdio.c`'s
`printf` grew `%*s` (dynamic field width from an `int` arg -- `wc`'s
`printf(" %*s", number_width, umaxtostr(...))` needs it) + a `%z` length
modifier.  New public headers `pwd.h`/`grp.h`; `stdlib.h`/`string.h`/`stdio.h`/
`unistd.h` grew the new prototypes + `_IOLBF`/`_IONBF`/`_IOFBF`.  The kernel's
`SYS_stat`/`SYS_fstat` ABI grew from a 1-word (size) to a 2-word (size + type
code) return, and `proc_stat`/`proc_fstat` write `vfs_vtype(vp)` (0 regular,
1 dir, 2 char) so the libc `stat`/`fstat`/`lstat` cook a REAL `st_mode`
(`S_ISDIR` works) from the kernel getattr -- `ls` distinguishes dirs from files.
`build-libc.sh` compiles `misc.c` and asserts `qsort`/`strcoll`/`getpwuid`/
`getgrgid`/`fileno`/`setvbuf`/`isatty`/`strtoul` all defined `T`.  This turns
"a real libc big enough for cat" into "a real libc big enough for a coreutils
SET."

(2) THE HEADLINE (part 2) -- LINK + RUN A REAL COREUTILS SET (`wc` + `ls`).
The UNMODIFIED GNU coreutils-9.5 `src/wc.c` (982 lines) is compiled with a
`wc-include/` gnulib scaffolding chain (`config.h`/`system.h` -> `wc_glue.h`,
plus `argmatch.h`/`fadvise.h`/`physmem.h`/`stat-size.h`/`xbinary-io.h`/
`uchar.h`/`argv-iter.h`/`readtokens0.h`/`wc.h` shims) mapping gnulib's
`getopt_long` (the R-P40 `getopt.c`), `argv-iter`/`readtokens0` (reduced real
forms in `wclib.c`), `physmem_available`/`__argmatch`/`umaxtostr`/`imaxtostr`/
`getdelim`, and the C-locale multibyte fast-path stubs (`mbrtoc32`/`c32width`/
`iswspace`/`btoc32` -- dead with `MB_CUR_MAX==1`, present only to compile) onto
the REAL grown libc -- NOT re-implementing libc.  `corewc.dyn` is DYNAMICALLY
linked (`ld.so.1`, `NEEDED libgcc_s.so.1`) as `/bin/corewc`; `nm` shows
`open`/`close`/`fstat`/`lseek`/`read`/`write`/`malloc`/`printf`/`getopt_long`
resolved `T` STATICALLY from `libc.a`.  Run from the shell:
`/bin/corewc /etc/release` -> `2 5 44 /etc/release` (2 lines, 5 words, 44 bytes
-- `wc` `fopen`s the file, `fstat`s it, and counts through the real libc
`read` byte loop, the real `wc` algorithm unchanged).  A real `ls`
(`/bin/corels`) EXERCISES exactly the grown-libc surface -- `opendir`/`readdir`/
`closedir` (over `SYS_getdents`), `lstat`/`stat` (reading the R-P41 kernel type
code so `S_ISDIR` works), `qsort` + `strcoll` (the C-locale entry sort),
`getpwuid`/`getgrgid` + `snprintf` for `-l`: `ls /` -> `bin  etc  lib  sbin
usr` (SORTED); `ls /bin` -> `cat  corecat  coreecho  coreecho2  corels
coretrue  corewc  counter  echo  ...` (SORTED, the coreutils SET present);
`ls -l /etc` -> `-rw-r--r-- 1 0 0  163 inittab` / ... (type/perm, links, owner,
group, size, name).  So `echo`/`true`/`cat`/`wc` are a REAL coreutils SET from
UNMODIFIED upstream source on one real reusable `libc.a`.  (This `ls` is
written from scratch to exercise the grown libc; coreutils' unmodified
`src/ls.c` pulls ~32 gnulib modules -- `obstack` [29 uses], `quotearg` [57],
`human` [22], `mbswidth`, `hash`, `mpsort`, `filemode`, `dircolors`,
`canonicalize`, `areadlink`, `idcache`, `filevercmp` -- whose faithful
scaffolding is a far larger body than the port itself; it is DEFERRED to
R-P42+.  The unmodified-upstream utils this phase links are `cat.c` [R-P40] +
`wc.c` [R-P41]; a documented ls-gap, not a silent one.)  Two fixes made this
work: the user stack grew from 4 pages (16 KiB) to 16 pages (64 KiB) --
`wc`'s `char buf[BUFFER_SIZE+1]` is 16 KiB on the stack alone, which overflowed
the old stack (SIGSEGV); and the `ramfs_readdir` dedup scan now stops at the
CURRENT record's header (not its name pointer), so the first directory entry is
no longer mis-flagged as a duplicate of itself.

(3) A RICHER PERSISTENT FS -- SUBDIRECTORIES.  R-P40's blockfs was flat (one
leaf name per inode).  R-P41 adds a DIRECTORY inode: the on-disk
`struct blockfs_inode` gained an `i_type` field (0 file, 1 dir) and its
`i_name` holds a path RELATIVE to the blockfs root (a nested leaf is stored as
`"sub/f"`), so nested-path resolution is a name match after reading the inode
table THROUGH `bdev_strategy` (the ufs/xv6 dirlookup model reduced to
full-relative-path names, no directory data blocks).  `blockfs_mkdir` allocates
a dir inode (written back through `bdev_strategy`); `blockfs_readdir` enumerates
the inodes whose name is a direct child of a directory; `proc_mkdir` routes a
`/blk/*` path to `vfs_blockfs_mkdir` and `proc_openf` routes a `/blk/dir` to a
blockfs directory vnode (tagged so `vfs_readdir` crosses `blockfs_readdir`).
Proof (`run_blockfs`): after the R-P39/R-P40 persistence proofs, the kernel
REMOUNTS, `mkdir`s `/blk/sub` (an on-disk dir inode), `create`s + WRITES the
NESTED `/blk/sub/f` through the block vnode, UNMOUNTS, REMOUNTS (no re-`mkfs`),
LISTS `/blk/sub` (its child `f` enumerated from the on-disk inode table read
through `bdev_strategy`) and READS `/blk/sub/f` back -- the nested path + its
103 bytes match what was written (`solnix riscv64 blockfs (R-P41): a NESTED
file under a real on-disk subdirectory, persisted through bdev_strategy.`),
i.e. a real subdirectory + a nested path persisted on the disk-backed fs across
the unmount+remount round-trip.

Proof: `rp41/rp41-milestone-check.sh` (all three R-P41 sub-tasks + every
R-P24..R-P40 regression green -- rebuild+reboot, re-runnable; 148 PASS lines,
zero FAIL, -smp 2).  `user/test_getopt.c` (R-P40) still covers the
`getopt_long` state machine both `wc` and `cat` drive.  Cribbed the illumos
libc `qsort` (a shellsort over arbitrary element width, the K&R storage/
Sedgewick-gap form) + the C-locale `strcoll`==`strcmp` shortcut + the illumos
nsswitch "files" `getpwuid_r`/`getgrgid_r` reduced to a single `/etc/passwd`/
`/etc/group` scan; GNU coreutils-9.5 `src/wc.c` (the `wc` algorithm, built
against the grown libc with the gnulib `system.h`/`getopt`/`argv-iter`/
`physmem`/`argmatch`/`readtokens0`/`umaxtostr` scaffolding onto the real libc)
+ gnulib `lib/argv-iter.c`/`lib/inttostr.c`; the illumos ufs directory inode
(`ufs_mkdir`/`ufs_dirlook` -- a dir inode + name-based child lookup) + xv6
`fs.c` `dirlookup`/`dirlink` (the on-disk directory-entry model), reduced here
to full-relative-path inode names read back through `bdev_strategy`; and the
POSIX `opendir`/`readdir`/`lstat`/`qsort` `ls` shape (a from-scratch `ls` that
exercises the grown libc, with coreutils' unmodified `src/ls.c` gnulib stack
[`obstack`/`quotearg`/`human`/`mbswidth`/`hash`/`mpsort`] documented as an
R-P42+ gap).

**Restore note (fresh node):** built on the R-P36..R-P40 node from the R-P40
tree + the already-rebuilt cross toolchain + qemu; `rp41/` was seeded by copying
`rp40/`, then the R-P41 deltas applied on top: `libc/` grew `include/pwd.h`,
`include/grp.h` + `port/misc.c` (and edits to `port/stat.c`/`port/stdio.c` + the
`include/` headers + `build-libc.sh`); `user/wc-include/*` (the wc gnulib
scaffolding) + `user/wclib.c` + `user/build-wc.sh`; `user/ls.c` +
`user/build-ls.sh`; the `coreutils-9.5/lib/` gnulib tree was extracted from the
on-node tarball; `kernel/ramfs.c` (`ramfs_isdir`/`ramfs_readdir` -- flat-archive
directory enumeration), `kernel/vfs.c` (a ramfs dir vnode + blockfs
subdirectories: `i_type`, `blockfs_mkdir`/`blockfs_readdir`/`blockfs_isdir` +
the `vfs_blockfs_mkdir`/`opendir`/`readdir` wrappers + `vfs_vtype`),
`kernel/proc.c` (2-word stat ABI, `/blk/*` mkdir + dir-open routing),
`kernel/exec_elf.c` (user stack 4 -> 16 pages), `kernel/main.c` (`run_blockfs`
subdir persistence proof), `kernel/build-kernel.sh` (build the grown libc + wc +
ls, ramfs `/bin/corewc` + `/bin/corels`, the R-P41 `wc /etc/release` + `ls /` +
`ls /bin` + `ls -l /etc` feed_console commands + assertions, `K`/`U` retargeted
to `rp41`).  R-P40 boot re-confirmed (`rp40-milestone-check.sh`: 142 PASS / 0
FAIL, the grown libc.a + real cat + persistent root blockfs) before starting
R-P41.

**Next: R-P42.**


**Phase reached: R-P40** (the R-P39 kernel -- which built a REAL, REUSABLE
solnix riscv64 `libc.a` that unmodified GNU coreutils `echo`/`true` link -- now
**GROWS that libc's surface** toward a BIGGER real coreutils util, **links +
runs unmodified GNU coreutils `cat`** against the grown libc, and **leaves the
disk-backed blockfs MOUNTED at boot** so the interactive shell reads a file
served from the persistent fs -- each boot-verified under
`qemu-system-riscv64 -machine virt -smp 2`.

(1) THE HEADLINE (part 1) -- GROW THE REAL libc.a.  R-P39's `libc.a` covered
exactly what `echo`/`true` referenced.  R-P40 adds, as SEPARATELY compiled
translation units into the SAME real `ar` archive (`nm` shows every one resolved
STATICALLY, `T` -- not shims): `port/dir.c` (`opendir`/`readdir`/`closedir` +
`struct dirent` over the kernel's `SYS_getdents`, which returns one entry
basename per call), `port/stat.c` (`stat`/`fstat`/`lstat` + a full `struct stat`
+ the `S_IF*`/`S_ISREG` macros over the kernel's size-only `SYS_stat`/`SYS_fstat`
getattr -- it synthesizes `st_mode` [regular 0644], `st_blksize`, `st_blocks`,
and reports a console fd 0/1/2 as `S_IFCHR` so a coreutils util's
"input file == output file" dev/ino guard does not misfire on the reduced
getattr), `port/stdio2.c` (a READ-capable `FILE*` family -- `fopen`/`fclose`/
`fread`/`fgets`/`fgetc`/`getc`/`fseek`/`ftell` over real `open`/`read`/`lseek`/
`close` with a per-stream fill buffer, plus `snprintf`/`sprintf`/`vsnprintf`
targeting a bounded memory `FILE` through the existing `vfprintf` conversion
loop), and `port/signal.c` (`signal`/`sigaction`/`kill`/`raise` over the R-P33/
R-P34 kernel signal syscalls, supplying the `sa_restorer` trampoline that ecalls
`SYS_sigreturn`); plus `getpagesize` (`syscall.c`) and `stpcpy` (`string.c`).
New public headers: `sys/stat.h`, `dirent.h`, `signal.h`; `sys/types.h` gained
`ino_t`/`dev_t`/`nlink_t`/`blksize_t`/`blkcnt_t`; `sys/systrap.h` gained
`__systrap4` + `SYS_sigaction`/`SYS_sigreturn`; `stdio.h`/`unistd.h`/`string.h`
grew the new prototypes + `O_*`/`SEEK_*` + a `bufpos`/`__F_STR` FILE field.
`build-libc.sh` compiles the four new TUs and its symbol sanity now asserts
`fopen`/`fread`/`fgets`/`fseek`/`ftell`/`fclose`/`snprintf`/`sprintf`/`opendir`/
`readdir`/`closedir`/`stat`/`fstat`/`lstat`/`signal`/`sigaction`/`kill` all
defined `T` in the archive.  This turns "a real libc that echo/true link" into
"a real libc big enough for a bigger real program."

(2) THE HEADLINE (part 2) -- LINK + RUN A BIGGER REAL COREUTILS UTIL (`cat`).
The UNMODIFIED GNU coreutils-9.5 `src/cat.c` (23 KB, vs echo's tiny `main`) is
compiled with a `user/cat-include/` gnulib scaffolding chain (`config.h`/
`system.h` -> `cat_glue.h`, plus the `alignalloc.h`/`ioblksize.h`/`fadvise.h`/
`full-write.h`/`safe-read.h`/`xbinary-io.h`/`getopt.h` `#include`-shims cat
references) that maps gnulib's `getopt_long` (a real, self-checked `getopt.c`),
`full_write`/`safe_read` (real fd write/read loops in `catlib.c`), `io_blksize`/
`xalignalloc`/`fdadvise`/`xset_binary_mode`/`error`/`quotef`/`write_error`/the
`GETOPT_*`/`case_GETOPT_*` macros onto the REAL grown libc -- NOT
re-implementing libc.  `corecat.dyn` is DYNAMICALLY linked (`ld.so.1`, `NEEDED
libgcc_s.so.1`) as `/bin/corecat`; `nm` shows `open`/`close`/`fstat`/`malloc`/
`free`/`printf`/`fwrite`/`fputs`/`write`/`read`/`lseek` all resolved `T`
STATICALLY from `libc.a`.  Run from the shell: `/bin/corecat /etc/release` ->
`solnix riscv64 (R-P31)` / `SunOS solnix-riscv64` (cat `open`s the real file,
`fstat`s it, and `simple_cat`'s it out via the real libc `read`/`write` loop --
the real coreutils cat algorithm, unchanged, on the real libc + `getopt_long`).
Two kernel fixes made cat work: `proc_fstat` of a console fd (0/1/2, unopened in
the fd table) now SUCCEEDS with size 0 (cat `fstat`s stdout up front), and
`proc_brk`/`exec` reset the program break on exec (an inherited stale `p_brk`
from the forking shell left the base heap page unmapped for the new image, so
`cat`'s first `malloc` store-faulted) -- the first `brk` grow now rounds DOWN to
map the page containing `HEAP_BASE`, and exec re-seeds `p_brk`.

(3) A PERSISTENT ROOT FS AT BOOT.  R-P39 proved the blockfs PERSISTS across an
unmount+remount within `run_blockfs`; R-P40 makes the boot path USE it: after
the persistence proof, `run_blockfs` does a FINAL remount and LEAVES the
disk-backed blockfs MOUNTED (a boot remount reuses `bdev0`'s persisted
contents), and `proc_openf` now routes a `/blk/NAME` path to the block vnode
(via `vfs_blockfs_open`, whose transient vnode's `vop_read` crosses
`bdev_strategy`).  So the interactive boot session's shell runs
`/bin/corecat /blk/persist` and the real cat prints `solnix riscv64 blockfs
(R-P39): this line was WRITTEN through bdev_strategy, survived unmount+remount.`
-- a file served from the DISK-BACKED fs (persisted from the earlier write-back
step, read back through the block layer this session), proving the boot path can
serve files from a persistent fs, not just ramfs.  (Fixed a latent dangling
pointer: `vfs_blockfs_open` now copies the name into its own static buffer
rather than stashing the caller's transient path pointer.)

Proof: `rp40/rp40-milestone-check.sh` (all three R-P40 sub-tasks + every
R-P24..R-P39 regression green -- rebuild+reboot, re-runnable; 141 PASS lines,
zero FAIL, -smp 2).  `user/test_getopt.c` is an `assert`-based host self-check
for the `getopt_long` state machine (clustered short opts, `--long`/`--long=VAL`,
short-with-arg, `--` terminator, unknown option).  Cribbed the illumos libc
`getdents`-backed `opendir`/`readdir`/`closedir` (`usr/src/lib/libc/port/gen/`)
+ the POSIX `struct dirent`/`struct stat`/`S_IF*` contract + the illumos libc
`stat`/`xstat` "trap, then cook a struct stat from getattr" shape + the C89
buffered `FILE`/`_filbuf`/`getc` read model + the memory-stream `snprintf` trick
+ the illumos/glibc `signal()`-over-`sigaction()` + `sa_restorer`-ecalls-
`sigreturn` idiom; GNU coreutils-9.5 `src/cat.c` (the cat algorithm, built
against the grown libc with the gnulib `system.h`/`getopt`/`full-write`/
`safe-read`/`ioblksize`/`fadvise`/`alignalloc` scaffolding onto the real libc) +
gnulib `lib/getopt.c`/`lib/full-write.c`/`lib/safe-read.c`; the illumos brk/sbrk
`os/grow.c` heap-segment growth (map fresh anon pages, reset the break on exec)
+ the ufs/specfs `bdev_strategy` block-read path kept mounted as a persistent
second/root fs, with `lookuppn` routing a mount-point prefix to the fs that
covers it.

**Restore note (fresh node):** built on the R-P36..R-P39 node from the R-P39
tree + the already-rebuilt cross toolchain + qemu; `rp40/` was seeded by copying
`rp39/`, then the R-P40 deltas applied on top: `libc/` grew `include/sys/stat.h`,
`include/dirent.h`, `include/signal.h` + `port/stat.c`/`dir.c`/`signal.c`/
`stdio2.c` (and edits to `stdio.c`/`syscall.c`/`string.c` + the `include/`
headers + `build-libc.sh`); `user/cat-include/*` (the cat gnulib scaffolding) +
`user/getopt.c`/`catlib.c`/`test_getopt.c` + `user/build-cat.sh`; `kernel/proc.c`
(console-fd `fstat`, exec `p_brk` reset + first-grow round-down, `/blk/*` open
routing), `kernel/main.c` (`run_blockfs` leaves the blockfs mounted at boot),
`kernel/vfs.c` (`vfs_blockfs_open` owns the name), `kernel/build-kernel.sh`
(build the grown libc + cat, ramfs `/bin/corecat`, the R-P40 `cat /etc/release`
+ `cat /blk/persist` feed_console commands + assertions, `K`/`U` retargeted to
`rp40`).  R-P39 boot re-confirmed (`rp39-milestone-check.sh`: 135 PASS / 0 FAIL,
the real libc.a + coreecho2/coretrue + persistent blockfs) before starting
R-P40.

**Next: R-P41.**


**Phase reached: R-P39** (the R-P38 bridge kernel -- which ran ONE real,
upstream-source coreutils echo linked against a hand-written per-program
`coreutils_shim.h` -- now links real programs against a **REAL, REUSABLE solnix
riscv64 libc** (`libc.a`: syscall stubs + buffered stdio + string + stdlib +
ctype + real `crt1`/`crti`/`crtn`, backed by the kernel's syscalls), runs a
**2ND real upstream coreutils util** against that same libc, and provides a
**PERSISTENT (disk-backed) block filesystem** whose writes go back through
`bdev_strategy` and survive an unmount+remount -- each boot-verified under
`qemu-system-riscv64 -machine virt -smp 2`.

(1) THE HEADLINE -- A REAL, REUSABLE LIBC (not a per-program shim).  R-P38's
`coreutils_shim.h` inlined, as `static` functions in one header, exactly the
libc surface a single echo referenced -- it was a per-program stand-in.  R-P39
builds a genuine **`libc.a`**: separate translation units cross-compiled by the
on-node `riscv64-unknown-solaris2.11` toolchain into a real `ar` archive --
`port/syscall.c` (the illumos riscv64 SYSTRAP idiom via `sys/systrap.h`:
`read`/`write`/`open`/`close`/`lseek`/`getpid`/`chdir`/`dup`/`dup2`/`_exit`,
each translating the reduced-SunOS `-errno` return into `errno`/-1),
`port/stdio.c` (a real `FILE` with `stdin`/`stdout`/`stderr`, per-stream flush
buffers, `fwrite`/`fputc`/`putchar`/`puts`/`fputs`/`fflush` + a minimal
`printf`/`fprintf`/`vfprintf` covering `%s%c%d%i%u%x%X%p%l*` with width/zero/
left flags -- no floating point), `port/string.c` (`strlen`/`strcmp`/`strncmp`/
`strcpy`/`strncpy`/`strcat`/`strchr`/`strrchr`/`memcpy`/`memmove`/`memset`/
`memcmp`), `port/stdlib.c` (a first-fit `sbrk`-over-`SYS_brk` heap:
`malloc`/`free`/`calloc`/`realloc`, plus `getenv` over the `environ` vector,
`strtol`/`atoi`/`atol`, and the C89 `exit`/`atexit` that runs the LIFO atexit
chain then flushes every stdio stream then traps `_exit`), `port/ctype.c` (the
full ASCII/C-locale classifier set), `port/libc_start.c` (`__libc_start`, the
C-level program entry the crt1 `_start` tail-calls: it stashes `environ`, runs
`_init`/`.init` constructors, calls `main`, and `exit()`s its return), and
`port/progname.c` (the shared `program_name`).  The startup uses **real crt
files**: a new `csu/crt1.s` (`_start` sets the frame chain + `gp`, loads
argc/argv/envp off the RISC-V psABI initial stack, and calls `__libc_start` --
routing teardown through the libc so stdio is flushed + atexit runs, the C89
contract) plus the R-P20 `crti.s`/`crtn.s` (the `_init`/`_fini` brackets).
**Public headers** live in `libc/include/` (`stdio.h`/`stdlib.h`/`string.h`/
`ctype.h`/`unistd.h`/`stddef.h`/`sys/types.h`/`sys/systrap.h`).  Proof: the
SAME unmodified GNU coreutils-9.5 `src/echo.c` (compiled with a tiny gnulib
scaffolding chain -- `cu-include/config.h`/`system.h`/`assure.h`/`c-ctype.h` ->
`coreutils_glue.h`, which maps gnulib's `_()`/`STREQ`/`c_isxdigit`/`close_stdout`/
`set_program_name`/`version_etc`/the usage-text macros onto the REAL libc, NOT
re-implementing libc) is DYNAMICALLY LINKED (`ld.so.1`, `NEEDED libgcc_s.so.1`)
against `libc.a` as `/bin/coreecho2`; `nm` shows the libc symbols
(`printf`/`fwrite`/`getenv`/`exit`/`atexit`/`strlen`/`__libc_start`) resolved
STATICALLY from the archive (defined `T`, zero undefined libc symbols -- the
only dynamic `NEEDED` is `libgcc_s.so.1`).  Run from the shell:
`/bin/coreecho2 R-P39 real-libc-echo` -> `R-P39 real-libc-echo` (argv join via
libc stdio); `/bin/coreecho2 -e libc\tstdio` -> `libc<TAB>stdio` (the real echo
`-e` escape engine driving libc `putchar`/`fwrite`).  This turns "we can run one
hand-shimmed program" into "we can run real programs against a real, reusable
libc."

(2) A 2ND REAL UPSTREAM COREUTILS UTIL against the same libc.  The unmodified
GNU coreutils-9.5 `src/true.c` is compiled with the same `cu-include/` gnulib
scaffolding, linked against `libc.a` + the real crt, dynamically linked via
`ld.so.1`, as `/bin/coretrue` -- proving the libc + exec path generalizes
beyond echo (it exercises `set_program_name`/`setlocale`/`STREQ`/
`atexit(close_stdout)` from the real libc).  The interactive shell gained a
`[exit N]` report after each foreground command (a general improvement) so a
util whose only observable result is its status is verifiable; proof:
`/bin/coretrue` -> `[exit 0]`.

(3) A PERSISTENT (disk-backed) block filesystem.  R-P38's blockfs mounted a
block-backed fs and READ a file through `bdev_strategy`, but its `vop_write`
returned `EROFS` and every mount re-`mkfs`'d.  R-P39 makes it PERSISTENT:
`blockfs_vop_write` does a read-modify-write of the file's data block back
THROUGH `bdev_strategy` and updates the on-disk inode size; a new
`blockfs_create`/`vfs_blockfs_create` allocates a free inode + data block
(inode index k -> data block `DATA_BLK + k`) and writes the inode table back
through the block layer; and `vfs_blockfs_mount` now `mkfs`'s ONLY ONCE per boot
(`blockfs_fmt_done`), so a REMOUNT reuses the RAM disk's (persistent) contents.
Proof (`run_blockfs`): after the R-P38 read, the kernel REMOUNTS, `create`s
`/blk/persist`, WRITES 103 bytes to it through the block vnode
(`fop_write` -> `blockfs_vop_write` -> `bdev_strategy`), UNMOUNTS, REMOUNTS (no
re-`mkfs`), OPENS `/blk/persist`, and READS it back -- the bytes match what was
written (`solnix riscv64 blockfs (R-P39): this line was WRITTEN through
bdev_strategy, survived unmount+remount.`), i.e. the write-back persisted
through the block layer across the unmount+remount round-trip.

Proof: `rp39/rp39-milestone-check.sh` (all three R-P39 sub-tasks + every
R-P24..R-P38 regression green -- rebuild+reboot, re-runnable; 134 PASS lines,
zero FAIL, -smp 2).  Cribbed the illumos libc SYSTRAP idiom (`usr/src/lib/libc/`
`<isa>/sys` a7-trap wrappers) + the C89 stdio/stdlib/string/ctype contracts
(illumos libc `stdio`/`_iob`, the K&R `sbrk` storage allocator, glibc/illumos
`__libc_start_main`'s "stash environ, run ctors, call main, exit" body) + the
real `crt1`/`crti`/`crtn` csu convention (amd64/aarch64) + the RISC-V psABI
initial stack + gp init; GNU coreutils-9.5 `src/echo.c` + `src/true.c` (built
against the real libc with the gnulib `system.h`/`c-ctype.h`/`config.h`
scaffolding); the illumos ufs write-back path (`ufs_itrunc`/`wrip` -> `bmap` ->
`bwrite`) + xv6 `fs.c` (`ialloc`/`balloc`/`writei` -> `bwrite`) block-write
model + the `strategy(9E)` block I/O entry point, reduced to one data block
per file.

**Restore note (fresh node):** built on the R-P36/37/38 node from the R-P38
tree + the already-rebuilt cross toolchain + qemu; `rp39/` was seeded by copying
`rp38/`, then the R-P39 deltas applied on top: a new `libc/` tree (`include/*`,
`port/*.c`, `csu/crt1.s`, `build-libc.sh`, `coreutils_glue.h`); `user/cu-include/`
(the gnulib scaffolding headers) + `user/build-cu.sh` (build `coreecho2`/
`coretrue` against `libc.a`); `user/sh.c` (`[exit N]` foreground-status report);
`kernel/vfs.c` (blockfs write-back + `create` + mkfs-once); `kernel/main.c`
(`run_blockfs` persistence proof); `kernel/build-kernel.sh` (build the libc +
cu utils, ramfs `/bin/coreecho2` + `/bin/coretrue`, the R-P39 feed_console
commands + assertions, `K`/`U` retargeted to `rp39`).  R-P38 boot re-confirmed
(`rp38-milestone-check.sh`: 127 PASS / 0 FAIL, the real shim-linked coreutils
echo + fg/bg job control + blockfs) before starting R-P39.

**Next: R-P40.**


**Phase reached: R-P38** (the PIVOTAL BRIDGE: the R-P37 interactive-shell kernel
now **EXECUTES A REAL, UPSTREAM-SOURCE riscv64 ELF built the way a solnix PACKAGE
is built** -- the GNU coreutils echo, compiled by the on-node cross toolchain +
DYNAMICALLY LINKED via ld.so.1 against libgcc_s.so.1 -- plus **FULL fg/bg JOB
CONTROL** (& / jobs / fg / bg / SIGCONT / SIGCHLD-reaping) and a **BLOCK-DEVICE
VNODE + a minimal on-disk blockfs** proving the vfs is not ramfs-only, each
boot-verified under `qemu-system-riscv64 -machine virt -smp 2`.

(1) EXEC A REAL UPSTREAM-SOURCE riscv64 ELF -- THE HEADLINE / THE BRIDGE TO THE
PACKAGE SET.  The prior dynamic proofs (R-P27/28/31) ran BESPOKE test programs
(hellodyn/hellolazy).  R-P38 runs the algorithm of **GNU coreutils-9.5
`src/echo.c`** -- `hextobin()` + `main()` taken BYTE-FOR-BYTE from the upstream
tarball (fetched + extracted on-node; NOT retyped) -- as `/bin/coreecho`.  A
small freestanding shim header (`coreutils_shim.h`) supplies exactly the libc
surface echo references (`putchar`/`fputs`/`getenv`/`exit`/`c_isxdigit`/`STREQ`/
the usage-text macros), standing in for the not-yet-ported libc a real package
would link; the echo ALGORITHM itself is upstream verbatim.  It is compiled by
the ON-NODE cross toolchain (`riscv64-unknown-solaris2.11` xgcc + the R-P17
binutils, `--sysroot` + `-lgcc_s`) and DYNAMICALLY LINKED (`ld-shared -z relro
-z lazy --hash-style=both`, INTERP `/usr/lib/ld.so.1`, `DT_NEEDED libgcc_s.so.1`)
-- i.e. built exactly the way a solnix package is built, not a hand-tailored
test.  Run from the interactive shell: `/bin/coreecho R-P38 real-coreutils-echo`
-> `R-P38 real-coreutils-echo` (the real echo joins argv with spaces + a trailing
newline); `/bin/coreecho -n no-trailing-newline` (the `-n` flag suppresses the
newline -- next prompt on the same line); `/bin/coreecho -e esc\ttab` -> `esc<TAB>
tab` (the real coreutils `-e` backslash-escape engine turns `\t` into a TAB).
ld.so.1 maps libgcc_s.so.1 + enters the app for each.  Two kernel changes made
this work: `exec_dynamic` (the PT_INTERP/ld.so.1 exec path) HARDCODED argc=1/
argv0="hello" -- it starved a real program of its arguments; it now stages the
shell's real argv onto the initial stack the SAME way `exec_image` (the static
path) does, keeping the dynamic auxv (AT_PHDR/PHENT/PHNUM/ENTRY/BASE/PAGESZ).
And crt1 traps `SYS_exit` directly rather than returning through the shim's
`exit()`, so the shim's buffered stdout is flushed (+ the atexit `close_stdout`
run) on return from `main`.  THIS is what turns a toy kernel into one that runs
the actual toolchain's output.  (No riscv64 artifact exists in the x86 solnix
cache yet, so building-from-real-source on-node is the realistic bridge.)

(2) FULL fg/bg JOB CONTROL.  The R-P37 shell had ^C/^Z basics; R-P38 adds the
full model: a `&` BACKGROUND launch (fork+exec, NO wait), a small jobs table
(pid + Running/Stopped + cmd), and `jobs`/`fg`/`bg` builtins.  `fg` hands the
tty to a job, SIGCONTs it if stopped, then waits it foreground; `bg` SIGCONTs a
stopped job and lets it run in the background without waiting.  SIGCONT is a new
signal (SunOS 25): `proc_kill` now RESUMES a `P_STOPPED` target (flips it
P_RUNNABLE + IPI-wakes a hart -- it resumes inside `proc_stop_self` past the
`rv_swtch`), and the signal-default table treats SIGCONT as ignore-on-delivery
(the resume itself is done in `proc_kill`).  Finished background jobs are reaped
at each prompt via `waitpid(-1, WNOHANG)` (SIGCHLD-driven reaping in the reduced
model), printing a `[N] Done` line.  Proof: `counter 120 &` launches a bg job
[2]; `jobs` lists it RUNNING while it prints concurrently (the bg proc + the
shell run on the two harts at once); `fg` foregrounds it; ^Z stops it (`[job]
pid 22 stopped (SIGTSTP)`); `jobs` lists it STOPPED; `bg` resumes it (`[2]
counter & (resumed, pid 22)`, SIGCONT); it runs to `counter: done` + is reaped
(`[2] Done`).  A new `/bin/counter` (a bounded, argv-tick-count busy loop with a
getpid delivery edge) is the demo job; it is built at `-O0` because this gcc
mis-fuses the strlen/write pair under `-O2` for counter's puts_+putn mix
(yielding a runaway write length that walked off the user stack -- caught as a
kernel load fault on the guard page) -- `-O0` is still genuine cross-toolchain
output.

(3) A BLOCK-DEVICE VNODE + a minimal on-disk blockfs -- the vfs is NOT ramfs-
only.  A RAM-backed BLOCK DEVICE (`bdev0`, 64 x 512-byte blocks) with the
classic Unix STRATEGY routine `bdev_strategy(blkno, buf, rw)` (read/write one
block).  On top of it, a trivial on-disk filesystem (blockfs): block 0 is a
superblock (magic/ninode/inode-block), block 1 is an inode table (magic/size/
first-data-block/name), blocks 2+ hold file data.  A blockfs vnode's `vop_read`
pulls the file's data block THROUGH `bdev_strategy`, so a read crosses the
block-device layer -- NOT the in-memory ramfs/tmpfs.  Proof (`run_blockfs` in
main.c): mkfs+mount /blk (the superblock is read back through the block layer),
open `/blk/hello`, read its contents back through the block vnode (`fop_read` ->
`blockfs_vop_read` -> `bdev_strategy`) -> `solnix riscv64 blockfs (R-P38): read
via a block vnode + bdev_strategy, not ramfs.`, then unmount -- the full
mount->read->unmount lifecycle over a second, block-backed filesystem.

Proof: `rp38/rp38-milestone-check.sh` (all three R-P38 sub-tasks + every
R-P24..R-P37 regression green -- rebuild+reboot, re-runnable; 126 PASS lines,
zero FAIL, -smp 2).  Cribbed illumos exec of an ELF via gexec/elfexec + the
PT_INTERP/ld.so.1 interpreter hand-off (usr/src/uts/common/os/exec.c
mapexec_interp + the auxv) + the RISC-V psABI initial stack; the illumos/BSD
ksh/sh job-control model (jobs.c j_stopped/j_running + `kill(-pgid, SIGCONT)` +
`tcsetpgrp` + the `p_stat` STOPPED state, os/sig.c sigtoproc/SIGCONT setrun) +
xv6 sh bg/fg + the `waitpid(WNOHANG)` SIGCHLD reaper; the illumos specfs/bdev
`bdev_strategy`/strategy(9E) + xv6 fs.c block layer (readsb/bread/readi) + a
ufs-lite superblock+inode+data-block on-disk layout + the standard vfs_mount/
VFS_ROOT/VFS_UNMOUNT lifecycle; and GNU coreutils-9.5 src/echo.c (the echo(1)
algorithm) built with the cross toolchain + linked dynamically the way a solnix
package is.

**Restore note (fresh node):** built on the R-P36/R-P37 node from the R-P37 tree
+ the already-rebuilt cross toolchain + qemu; `rp38/` was seeded by copying
`rp37/` (kernel + user + ldso + the prebuilt dynamic hellos/ld.so.1/libgcc_s),
then the R-P38 deltas applied on top: `user/coreutils_shim.h` + `user/coreecho.c`
(the real coreutils echo, extracted from the on-node `upstream/coreutils-9.5`
tarball); `user/counter.c` (the fg/bg demo job); `user/sh.c` (& / jobs / fg / bg
+ the jobs table + WNOHANG bg reaping); `kernel/exec_elf.c` (exec_dynamic real-
argv passthrough); `kernel/proc.c` + `kernel/signal.c` (SIGCONT resume);
`kernel/vfs.c` (the bdev + blockfs); `kernel/main.c` (run_blockfs + its call);
`user/build-user.sh` + `kernel/build-kernel.sh` (build coreecho/counter, ramfs
them, the R-P38 feed_console commands + assertions).  R-P37 boot re-confirmed
(the seeded rp38 tree built + booted with all R-P24..R-P37 assertions green)
before starting R-P38.

**Next: R-P39.**


**Phase reached: R-P37** (the R-P36 userland-session kernel becomes INTERACTIVE
with a **LIVE CONSOLE TTY + CANONICAL LINE DISCIPLINE**, **JOB CONTROL basics**
(process groups + a tty foreground pgrp, ^C/^Z), **FILE CREATION** (open(2)
O_CREAT/O_TRUNC/O_APPEND + mkdir(2)/rmdir(2)), and an **inittab-driven /sbin/init
that RESPAWNS the console shell**, each boot-verified under `qemu-system-riscv64
-machine virt -smp 2`.

(1) LIVE tty/console input + a canonical LINE DISCIPLINE (the headline): a new
console driver (`console.c`) reads console input via the SBI legacy console
getchar (`sbi_console_getchar`, EID 0x02) -- OpenSBI owns the qemu-virt ns16550
UART @ 0x10000000 for its own console and drains the RX itself, so the guest
asks OpenSBI for each byte (a direct ns16550 RBR read sees nothing; `-nographic`
wires host stdin to that UART).  Input is drained two ways: `console_poll()` on
the timer tick (a polled RX-interrupt stand-in) AND `console_read()` (the fd-0
read(2) backend, which polls directly since the read loop spins IN THE KERNEL
where the timer is masked); an amoswap test-and-set keeps the two harts from
racing on the input ring.  The canonical (cooked) line discipline echoes each
typed byte, maps CR->NL (icrnl), erases on backspace/DEL, and returns one whole
line per read (0 at ^D EOF).  `proc_read` routes fd 0 (no file/pipe backing) to
`console_read`, so `/bin/sh` reads TYPED commands INTERACTIVELY.  Proof: the boot
feeds the console via qemu's piped stdin (a here-doc of typed commands staged
with sleeps); the line discipline echoes each line and the shell runs it live --
`echo hello`->`hello`, `cat /etc/release`, `echo hi | cat`->`hi` (pipe+dup2),
`echo redir > /tmp/f; cat < /tmp/f`->`redir`, `cd /tmp; echo rel > g; cat g`->
`rel`, all typed at a `$ ` prompt.

(2) JOB CONTROL basics: a per-proc `p_pgid` (a fresh proc leads its own group
pgid==pid; fork inherits, exec keeps) + `setpgid(2)`/`getpgid(2)`; a tty
foreground process group (`tty_fg_pgrp`, set by the shell via `tty_setfg` before
a fg command + reclaimed after).  The line discipline's `console_poll` (run off
the tick) posts SIGINT on ^C and SIGTSTP on ^Z to EVERY proc in the fg pgrp,
lock-free (an atomic OR like `proc_alarm_tick`, since it runs in interrupt
context) EVEN WHEN NO read(2) IS PENDING -- so a ^C interrupts a SPINNING fg
command, not the blocked shell.  SIGINT default terminates (128+2); SIGTSTP
default STOPS (`proc_stop_self` -> a new `P_STOPPED` state the scheduler skips,
plus a WUNTRACED wait report: `proc_waitpid` reports a `P_STOPPED` child once
with a `WIFSTOPPED` status sentinel 0x7f, without reaping).  Proof: the shell
runs `loop` in its own pgrp on the tty, a ^C delivers SIGINT to loop's pgrp
(`sig 2 default action: terminate pid 16`) and the shell SURVIVES + re-prompts
(runs `echo after-jobs`->`after-jobs`); a second `loop` is ^Z'd (`[job] pid 17
stopped (SIGTSTP)`, the shell prints `[sh] job pid 17 stopped`).

(3) FILE CREATION: `open(2)` O_CREAT (create a new tmpfs file -- already in
R-P36) now also honors O_TRUNC (reset the file to length 0 via `vfs_truncate`)
and O_APPEND (start the offset at end-of-file); `mkdir(2)` (relative paths now
cwd-resolved) + new `rmdir(2)`/`SYS_rmdir`/`vfs_rmdir` (removes an EMPTY tmpfs
dir).  The tmpfs table grew from 8 to 24 slots so the interactive session's
files coexist with the earlier proofs'.  Proof: `echo x > /tmp/new` CREATES the
new file (O_CREAT|O_TRUNC) -> `cat /tmp/new`->`x`; `mkdir /tmp/dd; cd /tmp/dd;
echo y > f; cat f`->`y` (a dir + a file created inside it); `mkdir /tmp/empty`
then `rmdir /tmp/empty` round-trips cleanly.

(4) inittab-driven init + RESPAWN: `/sbin/init` reads `/etc/inittab` (a ramfs
file with an SVR4-style `id:action:command` respawn console entry) and, in a
getty/respawn loop, fork+execs `/bin/sh` on the LIVE CONSOLE (fd 0/1/2 = the
tty; no /etc/rc dup2 -- the shell reads interactively), reaps it (+ any adopted
orphan), and RESPAWNS it when it exits.  A stopped child (status 0x7f) is NOT
respawned.  Proof: init reads inittab, spawns shell #1 (`spawn #1: forked shell
pid 2`); ^D exits it (`sh: EOF (^D); exiting`, `reaped pid 2 status 0 (the
console shell)`); init RESPAWNS it (`respawning the console shell`, `spawn #2:
forked shell pid 19`); the respawned shell runs `echo respawned-shell`->
`respawned-shell`, ^D exits it, `respawn demo complete (2 spawns); init done.`

Proof: `rp37/rp37-milestone-check.sh` (all four R-P37 sub-tasks + every
R-P24..R-P36 regression green -- rebuild+reboot, re-runnable).  `run_init` was
moved to the END of `main` (after every non-interactive proof) since the shell
now BLOCKS on live console input; a latent `set -e` + `grep -c` (exit 1 on a
zero count) landmine in the FP-preservation assertion was hardened with
`|| true`.  Cribbed illumos ldterm STREAMS line discipline (`ldterm_rmsg`/
`ldterm_dosig` raising SIGINT/SIGTSTP on the tty `t_pgrp`) + the SBI legacy
console getchar (EID 0x02, OpenSBI `sbi_getc`), the `t_pgrp` job-control model
(setpgid + the terminal foreground group), tmpfs `tmp_create`/`VOP_CREATE` +
O_TRUNC, and init(1M) reading `/etc/inittab` + respawning a console getty/shell
(SVR4 `inittab(4)` `id:rstate:action:command`, action=respawn); xv6 console.c
(consoleintr/consoleread line discipline + the input ring, uart intr) + user/
init.c (the `for(;;) wait()` reaper); BSD tty.c (ttyinput/ttread cooked mode) +
/sbin/init; the RISC-V SBI spec (legacy console getchar) + the 8250/16550 UART
model (qemu-virt UART0 @ 0x10000000, PLIC IRQ 10).

**Restore note (fresh node):** built on the R-P36 node from the R-P36 tree +
the already-rebuilt cross toolchain + qemu; `rp37/` was seeded by copying
`rp36/` (kernel + user + ldso + the prebuilt dynamic hellos/ld.so.1), then the
R-P37 deltas (new `kernel/console.c`; `kernel/sbi.c`/`.h` SBI getchar;
`kernel/proc.c` p_pgid/setpgid/tty-fg/P_STOPPED/console_read-fd0/O_TRUNC-O_APPEND/
rmdir/pf_verbose; `kernel/vfs.c` NTMPFILE=24/vfs_truncate/vfs_rmdir;
`kernel/signal.c` SIGINT/SIGTSTP/stop-default; `kernel/main.c` syscalls
setpgid/getpgid/tty_setfg/rmdir + console_poll-on-tick + run_init-moved-to-end;
`user/init.c` inittab+respawn; `user/sh.c` interactive+job-control;
`user/loop.c` new; `user/etc-inittab.txt` new; `kernel/build-kernel.sh` the
staged console feeder + R-P37 assertions) applied on top.  R-P36 boot
re-confirmed (`rp36-milestone-check.sh`: init+shell scripted session, ASID churn
clean, waitpid, cwd, redir) before starting R-P37.

**Next: R-P38.**


**Phase reached: R-P36** (the R-P35 userland-session kernel gets **PER-AS ASIDs +
IPI-DRIVEN REMOTE TLB SHOOTDOWN** [THE R-P35 SMP FIX], **waitpid(2)**, a **per-proc
cwd + chdir(2) + . / .. resolution**, and a **/bin/sh with cd/exit builtins + >/<
redirection**, each boot-verified under `qemu-system-riscv64 -machine virt
-smp 2`.

(1) PER-AS ASIDs + REMOTE TLB SHOOTDOWN (the headline -- closes the R-P35 latent
fault):  Every address space now carries its own 16-bit ASID tagged into `satp`
(`MAKE_SATP_ASID(root_pa, asid)`, ASID in bits [59:44]; ASID 0 reserved for the
kernel/global mappings).  `hat_asid_alloc` hands ASIDs out monotonically from 1
with a generation counter; on 16-bit wrap it bumps the generation, flushes the
whole local TLB (recycling every ASID), and callers broadcast a remote
shootdown.  `rv_tlb_flush_asid(asid)` is `sfence.vma x0, aN` (ASID-scoped, so a
root switch or per-AS shootdown leaves other ASes' TLB entries live).  Each
AS-creation site (`proc_first`, `proc_first_demand`, fork's child, exec's new
AS) calls `proc_assign_asid` to stamp a fresh ASID into `p_usatp`/`c_satp`.  THE
FIX: after `hat_user_cow_share` drops `PTE_W` in the PARENT's live page tables at
fork, `do_fork` no longer does a LOCAL-only `rv_tlb_flush_all()` -- it does an
ASID-scoped local flush (`rv_tlb_flush_asid(parent->p_asid)`) PLUS an IPI-driven
REMOTE-hart TLB shootdown (`hat_tlb_shootdown` -> SBI RFENCE `remote_sfence_vma`)
so a peer hart running the parent cannot keep a stale WRITABLE TLB entry and
store into the shared COW frame -- the R-P35 COW-vs-wait TLB-aliasing fault under
heavy fork/exec churn.  `do_exec` likewise shoots the OLD AS's ASID down on the
peer before freeing it.  Proof (`run_asid_churn`): the COW-share + ASID-scoped
local flush + remote shootdown + teardown churn loop runs CLEAN (no fault, no
frame leak) across a real ASID rollover (`asid-gen 1->2`); `ASID churn PROVEN` +
`ASID rollover handled`.  The live shell session (init forks a child per command)
now drives that exact COW churn and runs clean.

(2) waitpid(2) + WNOHANG/specific-pid:  `proc_waitpid(want_pid, &status,
options)` generalizes R-P35's wait-any -- `want_pid>0` reaps only that child
(ignoring siblings), `WNOHANG` (options bit 1) polls (returns 0 if no matching
zombie is ready); `proc_wait` is now a `proc_waitpid(-1, .., 0)` wrapper.  New
`SYS_waitpid(248)`.  Proof (`run_waitpid`): a `WNOHANG` poll of a live child
returns 0; a specific-pid wait reaps only the named zombie (leaving its sibling
untouched); `waitpid PROVEN`.

(3) cwd + . / ..:  a per-proc `p_cwd[128]` (absolute, canonicalized, `/` at
boot, inherited across fork, kept across exec per POSIX).  New `SYS_chdir(247)`
-> `proc_chdir` resolves the target (relative to cwd) + requires it be a
directory (`vfs_path_isdir`: a mount point or a mkdir'd tmpfs dir).  `path_resolve`
prepends the cwd to a relative path and collapses `.`/`..` component-by-component;
it is applied in `proc_openf` and `proc_execv`.  Proof: the shell `cd /tmp`s,
cat's a RELATIVE `g` (resolved to `/tmp/g`), `cd ..`'s back, and an ABSOLUTE
`/tmp/g` still reads.

(4) shell builtins + redirection:  `/bin/sh` gains `cd`/`exit` builtins (run in
the shell, no fork) and `>`/`<` file redirection -- the child opens the file
(`O_CREAT` for `>`) and `dup2`s it onto fd 1/0 before `exec` (over the R-P34 fd
table + R-P35 dup2).  Proof: `echo redir > /tmp/f; cat < /tmp/f` -> `redir`;
`cd /tmp; echo rel > g; cat g` -> `rel`.

Proof: `rp36/rp36-milestone-check.sh` (all four R-P36 sub-tasks + every
R-P24..R-P35 regression green -- rebuild+reboot, re-runnable).  Cribbed illumos
HAT/context ASID management (i86pc `hat_alloc`/hment ASID reuse, sun4v
`sfmmu_get_ctx`/`sfmmu_alloc_ctx` context rollover-and-flush), `xc_call`/
`hat_tlb_inval` cross-CPU TLB shootdown over SBI RFENCE, `waitid`/`waitsys`
(P_PID + WNOHANG in `os/exit.c`), `lookuppn`/`lookuppnvp` cwd (`u_cdir` base +
the `..` parent walk in `fs/lookup.c`); xv6 `sh.c` (redir/builtins); BSD
`namei()` relative-to-cwd; the RISC-V privileged spec (ASID in `satp`, `sfence.vma`
rs2=ASID).

**Restore note (fresh node):** the R-P17..R-P35 tree was restored from the git
per-phase deltas by overlaying `rp22..rp35` in order (latest file wins) into a
full working dir (`rp36-overlay.sh`); the cross toolchain was rebuilt from
source on the node -- binutils-2.44 (`riscv64-unknown-elf`) + gcc-14.3.0
(`riscv64-unknown-solaris2.11`, config.gcc stanza + `riscv/sol2.h` +
`riscv/t-sol2`, via `rp36-setup-gcc.sh` + `rp36-build-toolchain.sh`; the
`all-gcc` gettext prereq was dropped so `--disable-nls` builds clean) + the
solaris `libgcc.a` (`all-target-libgcc`, core `libgcc.a` only) + a shared-capable
binutils `ld` (regen `elf64lriscv` emulation with `GENERATE_SHLIB_SCRIPT`) +
hand-linked `libgcc_s.so.1` + `hello.dyn`/`hellodyn.dyn`/`hellolazy.dyn` +
`ld.so.1` (`rp36-build-dynchain.sh`).  The R-P34.1 (sigprocmask/alarm/sigsuspend)
and R-P34.3 (mount/multi-level-walk/rename/unlink) userland test drivers
(`sigtest.c`/`vfstest.c`) were NOT persisted to git in R-P34, so they were
reconstructed from the R-P35 reference boot log's expected output (the
underlying kernel syscalls were already present).  R-P35 boot (init+shell:
`echo hello`, `cat`, `echo hi | cat`) re-confirmed before starting R-P36.

**Next: R-P37.**

**Phase reached: R-P35** (the R-P34 shell-ready kernel now runs a REAL USERLAND
SESSION with **PER-CPU IDLE + IPI WAKEUP**, a **REAL init PROCESS (pid 1)**, and
a **MINIMAL INTERACTIVE SHELL (/bin/sh)**, each boot-verified under
`qemu-system-riscv64 -machine virt -smp 2`.  (1) PER-CPU IDLE + IPI WAKEUP (the
enabler): `rv_sched_cpu` now, when its runq has nothing RUNNABLE but a proc is
blocked (`P_WAITING`) or running on the peer, PARKS the hart in `wfi` (low
power) instead of busy-polling; a runnable transition (a child exit, a
signal/alarm post) sends an SBI SOFTWARE IPI (`sbi_send_ipi_hart` ->
`SCAUSE_S_SOFTWARE`, cleared in `rv_interrupt`) to WAKE the sleeping hart to
re-dispatch -- and `proc_wait_signal` (sigsuspend) drops the R-P34 wfi-poll for
a real `P_WAITING` block + `sched()`.  The free-running timer + `sstatus.SIE`/
`SSIE` unmasked in the idle path guarantee a wakeup source (a lost IPI is
bounded by one tick).  Proof: a proc forks a child + blocks in `wait(2)`; a
hart parks in the idle `wfi` (`idle-wfi parks: hart0=2 hart1=1`); the child
exit IPI-wakes the blocked parent (`idle+IPI PROVEN`, no busy-poll).  (2) A REAL
init PROCESS (pid 1): the kernel execs the embedded `/sbin/init` as PID 1
(`proc_reset_pids` restarts numbering at 1 for the fresh session); init opens
the ramfs script `/etc/rc`, `dup2`s it onto the shell's stdin, `fork`+`exec`s
`/bin/sh`, and reaps children in a `wait(2)` loop -- ADOPTING a re-parented
orphan (`proc_exit` re-parents a dying proc's live children to `INIT_PID`, and
init reaps the grandchild it adopts).  Proof: `[init] pid 1 running`, forked
shell pid 3, adopted+reaped the orphan grandchild (`reaped pid 4 status 23`),
reaped the shell (`reaped pid 3 status 0 (the shell)`), `init done`.  (3) A
MINIMAL SHELL (/bin/sh): reads a scripted stdin (`/etc/rc`) line-by-line,
tokenizes argv, `fork`+`exec`+`wait`s each command (echo/cat/true exec'd from
the ramfs WITH REAL ARGV -- argv now passes through `exec(2)` via a kernel
argv-staging buffer laid onto the new program's initial stack), and runs a
PIPELINE `cmd1 | cmd2` over the R-P33 pipe + R-P34 `dup2` (fork both halves,
wire left's stdout -> right's stdin).  A supporting fix: `proc_exit` now CLOSES
the proc's open fds so a pipe write end reaches refcount 0 and the reader sees
EOF.  Proof: the shell runs `echo hello` -> `hello`, `cat /etc/release` -> the
release contents, and `echo hi | cat` -> `hi` (a real pipe + dup2), then
`true`, then exits.  Proof: `rp35/rp35-milestone-check.sh` (all three R-P35
sub-tasks + the R-P24 + R-P26 + R-P27 + R-P28 + R-P29 + R-P30 + R-P31 + R-P32 +
R-P33 + R-P34 regressions green, rebuild+reboot, re-runnable).  Cribbed illumos
`disp.c` (`disp()`/`poke_cpu`/`cpu_resched` -- idle CPU woken by a cross-call
IPI when a runnable thread lands on the dispatch queue) + `os/exit.c` (init
re-parenting orphans + `closeall`) + `os/exec.c` (`exec_args`/`stk_copyin`
argv onto the new stack); xv6 `user/init.c` (`for(;;) wait()`) + `user/sh.c`
(EXEC/PIPE nodes: pipe + fork + dup2 the ends) + BSD `/sbin/init`; the SBI IPI
is the RISC-V SBI spec IPI extension.  **Next: R-P36.**

**Phase reached: R-P34** (the R-P33 full-Unix-core kernel rounds out the
SYSCALL/VFS surface toward hosting real programs with **SIGNAL COMPLETENESS**,
**fd MANAGEMENT**, and **VFS MATURITY**, each boot-verified under
`qemu-system-riscv64 -machine virt -smp 2`.  (1) SIGNAL COMPLETENESS: a per-proc
BLOCKED-signal mask (`p_sigmask`) that `sigprocmask(SIG_BLOCK/UNBLOCK/SETMASK)`
edits -- a blocked signal STAYS PENDING (the delivery path skips it) and
DELIVERS on unblock (proven: a proc blocks SIGUSR1, raises it [stays pending],
then unblocks it [the pending signal delivers + runs the handler]); `sigsuspend`
atomically swaps in a temporary mask + blocks until an unmasked signal (a
cooperative wfi-poll on `p_sigpend` that keeps the SBI timer live so it wakes on
a `kill`/alarm); `SA_RESTART` rewinds the saved `sepc` past the `ecall` on
delivery so an interrupted (`EINTR`) syscall re-runs -- and `sigsuspend` is
NEVER restarted (POSIX, via a per-proc `p_no_restart` guard); `SIGCHLD` is
posted to the PARENT on child exit (a parent can catch it, not just block in
`wait`); and `alarm(2)` arms a per-proc one-shot deadline (a `clock_ticks`
count) that the tick handler (`proc_alarm_tick`, called from `rv_interrupt`)
turns into `SIGALRM` when it passes (proven: `alarm(1)` delivers SIGALRM).
(2) fd MANAGEMENT: `dup(2)`/`dup2(2)`/`fcntl(F_DUPFD/F_GETFD/F_SETFD/F_GETFL/
F_SETFL)` over the R-P31/32 per-proc fd table (a dup'd fd is a second reference
to the same vnode/pipe-end/offset with FD_CLOEXEC cleared; `dup2` onto a console
fd installs/removes the file backing so `proc_write`/`proc_read` route fd 1/2 to
a file when redirected); `FD_CLOEXEC` is honored across `exec` (`proc_fd_cloexec`
closes every close-on-exec fd in `do_exec` before the new image runs).  Proof: a
proc `dup2`s a file onto stdout, writes through fd 1 (the bytes land IN THE
FILE, not the console), restores stdout, reads the file back; then it sets
FD_CLOEXEC on an fd + execs -- the CLOEXEC fd is CLOSED in the new image while a
plain fd survives.  (3) VFS MATURITY: a MOUNT TABLE (`vfs_mount` maps a
mount-point prefix to a fs type; "/"=ramfs, "/tmp"=tmpfs seeded at boot,
`mount("tmpfs", "/mnt")` adds more) + a MULTI-LEVEL PATH WALK (`vfs_walk`, the
reduced `lookuppn`: walk a path component-by-component from the root, validating
that every INTERMEDIATE directory exists [a mount point or a `mkdir`'d tmpfs
dir], rejecting a walk through a missing dir, then resolve the leaf against the
fs its longest mount prefix covers) + `rename`/`unlink` over tmpfs.  Proof:
`mount tmpfs at /mnt`, `mkdir /mnt/sub`, create + read `/mnt/sub/file` (a
multi-level walk ACROSS the mount + directory), a pre-mkdir open of
`/mnt/sub/file` correctly ENOENTs (the walk rejects the missing dir), then
`rename /mnt/sub/file -> /mnt/sub/renamed` + `unlink` it.  Proof:
`rp34/rp34-milestone-check.sh` (all three R-P34 sub-tasks + the R-P24 + R-P26 +
R-P27 + R-P28 + R-P29 + R-P30 + R-P31 + R-P32 + R-P33 regressions green,
rebuild+reboot, re-runnable).  Cribbed illumos sig.c (sigprocmask/issig held
signals) + timer.c/clock.c (it_real/realitexpire -> SIGALRM) + fio.c
(dupfd/fcntl/FD_CLOEXEC) + lookup.c (lookuppnvp) + vfs_t/vfssw (the mount list) +
tmpfs tmp_vnops; xv6/BSD for the trap-return signal-frame + fd shape.
**Next: R-P36.**

**Phase reached: R-P33** (the R-P32 real-proc_t-on-both-harts kernel grows the
PROCESS + IPC + FILESYSTEM maturity with a **MINIMAL SIGNAL FRAMEWORK + kill(2)**,
**pipe(2) + directories**, and **per-CPU idle/wfi + file-backed demand-exec**,
each boot-verified under `qemu-system-riscv64 -machine virt -smp 2`.  (1) SIGNALS:
a per-proc pending mask + a disposition table (`sigaction`/`signal`); `kill(2)`
posts a signal to a proc (atomic OR into `p_sigpend`, waking a `wait(2)`-blocked
target); delivery happens on the RETURN-TO-U edge (`proc_deliver_signals`, called
from `mach_trap.S .Lret`): the kernel BUILDS A SIGNAL FRAME on the user stack (a
saved copy of the interrupted trap frame), rewrites the trap frame so the
epilogue `sret`s into the handler (`a0`=signo, `ra`=the userland `sa_restorer`
trampoline, `sp`=the sigframe), and clears the pending bit; the handler returns
through the restorer, which `ecall`s `SYS_sigreturn` to copy the saved frame back
so the proc resumes exactly where it was interrupted.  Default actions terminate
(SIGKILL/SIGTERM/SIGSEGV/USR1/USR2 -> `proc_exit(128+sig)`); an unresolved user
page fault raises SIGSEGV (the kernel no longer halts on a bad user access).
Proof: a child installs a SIGUSR1 handler + spins, the parent `kill(2)`s it, the
handler RUNS + returns via sigreturn (the child resumes + exits 0); then the
parent SIGKILLs a second uncatchable spinner (reaped status 137 = 128+9).
(2) pipe(2): a kernel ring buffer (`pipe_t`) with two fds (read + write end),
blocking read/write mediated by the R-P30 scheduler (a full/empty end yields +
re-checks), reader/writer refcounts (EOF when the last writer closes, EPIPE when
the last reader closes); fork inherits the fd table + bumps the pipe refcounts.
Directories: a `VT_DIR` tmpfs vnode + `VOP_READDIR`, `mkdir`/`getdents` over
tmpfs (a dir enumerates the tmpfs entries directly under its path).  Proof: a
parent writes + a fork-inherited child reads a pipe message (blocking IPC);
`mkdir(/tmp/d)` + two files + `readdir` lists 2 entries.  (3) per-CPU idle +
`wfi`: a hart with an empty runq parks in `wfi` (low power, woken by the SBI
timer) instead of spinning -- proven by idling across 5 timer wakeups while the
tick counter advances; and FILE-BACKED DEMAND-EXEC: `exec_image_demand` maps a
PT_LOAD text segment FILE-BACKED + LAZY (`PTE_LAZY`) instead of the eager
`exec_image` copy, and the first instruction fetch faults into `exec_demand_fault`
which pages just that text page in from the ELF image (vs eager copy) -- proven
by a program whose text is paged in on the fetch fault (`[exec-demand] fault ->
paged text from file`) and then runs its compute loop correctly.  Proof:
`rp33/rp33-milestone-check.sh` (all three R-P33 sub-tasks + the R-P24 + R-P26 +
R-P27 + R-P28 + R-P29 + R-P30 + R-P31 + R-P32 regressions green, rebuild+reboot,
re-runnable).  Details in the R-P33 section below.  **Next: R-P34 (DONE -- see
the R-P34 phase above).**

**Phase reached: R-P32** (the R-P31 true-SMP high-half kernel grows the MEMORY-
MANAGEMENT + SMP-PROCESS maturity: the **REAL proc_t DISPATCHER on BOTH HARTS**,
**COPY-ON-WRITE fork + DEMAND PAGING**, and **vfs write(2) over a real vnode
layer**.  (1) `rv_sched_cpu` now runs the REAL proc_t scheduler on BOTH harts
concurrently against ONE shared, spinlock-guarded proc runq (`proc_tab`), with
per-hart `curproc` + scheduler context (the hartid carried in `tp`, recovered on
trap entry from a bit packed into the aligned `sscratch` kernel-stack top); a
process forked on hart 0 is dispatched on hart 1 -- a first process forks N
children and each prints the hart it ran on, scheduler-balanced across two
hartids; the SMP save/load race is closed with a per-proc `p_onproc`
still-switching flag (a peer hart never picks a proc whose context is mid-save)
and the kmem/frame allocators + the console are spinlock-serialized.  (2) fork
now SHARES the parent's user pages read-only + `PTE_COW` (a software RSW bit)
instead of the R-P26 eager copy; a store to a shared page FAULTS (scause 15) into
the page-fault handler (`rv_trap` -> `proc_pagefault` -> `hat_cow_fault`), which
copies just that frame into a private writable one -- the child's write does NOT
corrupt the parent (COW isolation), and a kernel copyout to a COW page (wait(2)
writing `*statusp`) is handled too; a demand-paged (`PTE_LAZY`, V clear) page is
reserved without backing and faulted in as a fresh zeroed frame on first touch
(`hat_demand_fault`); a per-frame refcount (`page_ref_*`) frees a shared frame
only when the last AS lets go.  (3) a real vnode op vector
(`VOP_READ`/`WRITE`/`LOOKUP`/`GETATTR`) over two fs types -- the read-only ramfs
(initramfs blob) and a WRITABLE tmpfs (a kmem buffer grown on write) -- so a
process `write(2)`s `/tmp/hello.txt`, reads it back (round-trip MATCH), fstat's
it, and a write to the read-only ramfs returns EROFS.  All boot-verified under
`qemu-system-riscv64 -machine virt -smp 2`: six forked children run across two
hartids (`procs dispatched: hart0`/`hart1`), a COW store fault copies a shared
page (the parent stays UNCHANGED) + a demand-page fault fills a lazy page, and a
proc writes+reads a tmpfs file through the VOP_* layer while the ramfs rejects
the write.  Proof: `rp32/rp32-milestone-check.sh` (all three R-P32 sub-tasks +
the R-P24 + R-P26 + R-P27 + R-P28 + R-P29 + R-P30 + R-P31 regressions green,
rebuild+reboot, re-runnable).  Details in the R-P32 section below.  **Next:
R-P33 (DONE -- see the R-P33 phase above).**

**Phase reached: R-P31** (the R-P30 true-high-half kernel completes SMP high-half
by putting **SECONDARIES ON THE W^X ROOT** -- the boot identity trampoline is
dropped entirely: R-P30 dropped the identity map on the PRIMARY but a secondary
hart still ran the shared kernel mappings from the identity-bearing BOOT root;
R-P31 brings the secondary up so it enables paging via a transient boot-root
trampoline [needed only for the single instant of the initial satp flip from its
physical PC], JUMPS to the high VA, then SWITCHES onto the primary's
identity-FREE W^X kernel root [`hat_wxroot_satp`], so BOTH harts run purely
high-VA with NO identity map on ANY running root; after both harts are up the
boot-root identity window is SCRUBBED entirely [`hat_boot_drop_identity`] so no
identity mapping survives anywhere.  It also HARDENS **ld.so.1** with **LAZY PLT
binding** [the PLT0 stub -> the `_rtld_bind` trampoline -> resolve on first call:
the first cross-object `__multf3` call fires the bind trampoline + patches the
GOT slot, the second call jumps straight through], **.gnu.hash** lookup (bloom
filter + gnu chain, SysV `.hash` fallback), **GNU symbol versioning** (`.gnu.version`
/ verneed / verdef, matching `__multf3@GCC_3.0`), and **mprotect of the RELRO
segment** read-only after relocation; and adds a **REAL ramfs read(2) path**
[open -> per-proc fd -> ramfs vnode -> copy bytes] plus **more syscalls**
(`read`/`open`/`close`/`lseek`/`fstat`/`stat`/`getcwd`/`mprotect`/`uname`), all
boot-verified under `qemu-system-riscv64 -machine virt -smp 2`: the secondary's
running satp equals the primary's W^X root satp (`0x800000000008036c`), a read of
`_start` via the low identity VA `0x80200000` FAULTS on the secondary, the
boot-root identity window is scrubbed, and SMP work still splits 4/4 across two
hartids; a dynamic `hellolazy` (linked lazy + `--hash-style=both` + `-z relro`)
resolves `__multf3@GCC_3.0` LAZILY on first call via the bind trampoline (the
second call uses the patched GOT), ld.so.1 mprotects its relro read-only, and it
exits 42; and a userland process opens + reads `/etc/release` from the ramfs
(prints its contents), fstat/lseek/getcwd work, and `uname(2)` returns
`SunOS`/`solnix-riscv64`.  Proof: `rp31/rp31-milestone-check.sh` (all three
R-P31 sub-tasks + the R-P24 + R-P26 + R-P27 + R-P28 + R-P29 + R-P30 regressions
green, rebuild+reboot, re-runnable).  Details in the R-P31 section below.

**Phase reached: R-P30** (the R-P29 production-shaped kernel closes its honest
gap and becomes a **TRUE HIGH-HALF KERNEL**: the kernel is now **LINKED +
EXECUTES at high VA** (`KERNEL_DMAP_BASE + 0x80200000`) while LOADING at physical
`0x80200000`, and the **LOW IDENTITY MAP IS DROPPED** entirely -- a locore
bootstrap runs position-independently at the physical load address, builds the
Sv39 boot tables (a low identity window to survive the satp flip + the kernel
HIGH map + the direct-map), enables paging, and JUMPS PC to the high-VA
`_start_high`; `hat_kernel_setup` then installs the identity-FREE per-segment W^X
root and `hat_drop_identity` proves the primary hart runs PURELY at high VA (a
read of `_start` through the low identity VA `0x80200000` FAULTS), completing the
illumos kernel-VA-!=-PA model.  It also promotes the R-P29 per-CPU work queues to
a **TS/RT PRIORITY SCHEDULER on BOTH harts** (SC_RT globally above SC_TS so RT
preempts TS, TS round-robins within a band, tick-driven kpreempt, priority-
inheritance-lite where an RT waiter boosts the TS lock-holder, and both harts
dispatch from a shared class runq), and adds **as_free** (a process's address
space is freed on exec/exit -- walk the private user half, unmap + free the user
page tables + frames -- so fork/exec/exit no longer leaks, vs the R-P26 leak),
all boot-verified under `qemu-system-riscv64 -machine virt -smp 2`: the ELF
carries a HIGH-VA entry (`0xffffffc080200000`) with LOAD `PhysAddr=0x80200000`
(VMA!=LMA), the kernel banners + runs every R-P24/26/27/28/29 subsystem with NO
identity map (`&main = 0xffffffc0802036bc`, W^X enforced, kmem returns direct-map
pointers, SMP + FP + fork/exec/wait + ld.so.1 cross-object all green); an RT proc
preempts running TS procs while two equal-priority TS procs round-robin and a
priority-inheritance boost lets a low-TS lock-holder run ahead of its band so the
blocked RT waiter proceeds, all dispatched across two hartids; and fork+exec+exit
of an AS 20 times returns the page-frame free count to its baseline (27 -> peak
37 -> 27, no leak).  Proof: `rp30/rp30-milestone-check.sh` (all three R-P30
sub-tasks + the R-P24 + R-P26 + R-P27 + R-P28 + R-P29 regressions green,
rebuild+reboot, re-runnable).  Details in the R-P30 section below.

**Phase reached: R-P29** (the R-P28 SMP dynamic-linking kernel HARDENED toward a
production-shaped kernel with a **FULL HIGH-VA R^X HAT** [a real kernel HAT that
maps the kernel image per-segment at 4 KiB leaf granularity with W^X
permissions -- .text R|X, .rodata R, .data/.bss R|W, no page both writable and
executable -- executes through the high direct-map alias, ENFORCES W^X (a store
to .text faults), adds a **vmem arena + slab kmem_cache** (Bonwick vmem/kmem)
over the R-P24 first-fit heap, and does a **TLB shootdown** broadcasting a remote
sfence.vma to the secondary hart via SBI RFENCE], **PER-CPU DISPATCH + kpreempt**
[each hart owns its own dispatch queue (cpu_t.cpu_disp); both harts drain their
local queue concurrently and STEAL from a peer when empty -- procs balanced
across 2 harts' per-CPU queues; a kpreempt() kernel preemption point fires +
yields], and **FP CONTEXT SWITCH + more syscalls** [rv_swtch saves/restores the
FP register file (fcsr + f0..f31) per context so two FP-using procs that pin
distinct values in the same FP register preempt each other WITHOUT corrupting
each other's FP state; getpid/brk + the reduced SunOS errno return ABI +
mmap/open/read/close/fstat], all boot-verified under `qemu-system-riscv64
-machine virt -smp 2`: the R-P24 boot map (RWX gigapages) is replaced by a real
per-segment W^X kernel map at 4 KiB leaves, the kernel calls a probe through its
canonical Sv39 high VA (`0xffffffc0_802018a6` returns the R-P29 marker), a
deliberate store to `.text` FAULTS (W^X enforced), a slab kmem_cache recycles
freed objects, a remote sfence.vma is issued + accepted by hart 1; two per-CPU
dispatch queues are drained by hart 0 (6 jobs, own queue) and hart 1 (6 jobs, 3
stolen from the peer) concurrently and a kpreempt point fires; and two FP procs
(fs0=111 and fs0=222) interleave via timer preemption and BOTH keep their fs0
intact across every switch. Proof: `rp29/rp29-milestone-check.sh` (all three
R-P29 sub-tasks + the R-P24 + R-P26 + R-P27 + R-P28 regressions green,
re-runnable). Details in the R-P29 section below.

**Phase reached: R-P28** (the R-P27 preemptive-multiprocess kernel GROWN with
**REAL CROSS-OBJECT DYNAMIC LINKING** [ld.so.1 maps + binds `DT_NEEDED`], an
**illumos-style PRIORITY DISPATCH** [priority disp queues + `thread_create`],
and **SMP secondaries via the SBI HSM** [a second hart drains a shared runq],
all boot-verified under `qemu-system-riscv64 -machine virt -smp 2`: the R-P27
ld.so.1 (which only *reported* `DT_NEEDED`) now OPENS libgcc_s.so.1 from the
ramfs via a `SYS_mapso` syscall, MAPS it into the process AS at a chosen base,
processes ITS dynamic section, and BINDS the application's cross-object
`R_RISCV_JUMP_SLOT` references (`__multf3`/`__fixtfsi`) to the resolved libgcc_s
addresses -- a DYNAMIC hello CALLS `__multf3` in libgcc_s across the object
boundary and exits `42`; the R-P27 round-robin runq becomes a priority
dispatcher (`rv_sched` picks the highest-priority band, round-robin within it)
and `kthread_create` builds kernel threads scheduled in priority order
(HIGH->MID->LOW); and the boot hart brings up a secondary hart with the SBI HSM
`hart_start` ecall -> the secondary sets up its trap vector + the shared kernel
AS + enters the scheduler, and BOTH harts drain one lock-protected work runq
(two distinct hartids execute). Proof: `rp28/rp28-milestone-check.sh` (all three
R-P28 sub-tasks + the R-P24 + R-P26 + R-P27 regressions green, re-runnable).
Details in the R-P28 section below.

**Phase reached: R-P27** (the R-P26 MULTIPROCESS kernel GROWN with **timer-tick
PREEMPTION**, **fs-backed exec over a minimal ramfs**, and **ld.so.1 hosting the
first DYNAMICALLY-LINKED riscv64-solaris process**, all boot-verified under
`qemu-system-riscv64 -machine virt`: the R-P24 100 Hz clock, made free-running,
drives round-robin preemption so two CPU-bound procs that never cooperatively
yield still INTERLEAVE; a linked-in **initramfs** archive backs `exec(path)`
which resolves the ELF by name (`/bin/execee`); and a userland **ld.so.1**
(entered by the exec path when the app carries `PT_INTERP`) reads the auxv,
reports the app's `DT_NEEDED`, relocates it, and jumps to its `_start` -- the
DYNAMIC hello (R-P21) runs as a process and calls `exit(2)` (captured status).
Proof: `rp27/rp27-milestone-check.sh` (all three R-P27 sub-tasks + the R-P24 +
R-P26 regressions green, re-runnable). Details in the R-P27 section below.

**Phase reached: R-P26** (the R-P25 single-user-process kernel GROWN into the
first MULTIPROCESS riscv64-solaris kernel, all boot-verified under
`qemu-system-riscv64 -machine virt`: a minimal **proc/lwp table** [`proc.c`
`proc_t`: pid, state, parent pid, per-process user AS (Sv39 satp root), a
per-process kernel stack, a saved scheduler context `rv_context`, and a pointer
to the proc's trap frame -- one lwp per proc], **fork(2)** [`SYS_fork`/`do_fork`:
allocate a child, COPY the parent's user AS (`hat_user_copy` deep-copies every
4 KiB user leaf -- copy, not COW), copy the parent trap frame onto the child
kernel stack with `a0`=0 so the child returns 0 while the parent returns the
child pid, seed the child scheduler context so the first `rv_swtch` into it
lands in the trap-return epilogue and `sret`s to U-mode], **exec(2)**
[`SYS_execve`/`do_exec`: reuse the R-P25 `exec_image` loader to replace the
calling proc's AS with a second embedded ELF, rewrite the trap frame
(`sepc`=new entry, `sp`=new user stack) + switch the live `satp` so the syscall
return `sret`s into the NEW program], and **wait(2)/exit rendezvous**
[`SYS_wait`/`proc_wait` blocks the parent (state WAITING, yields) until a child
reaches ZOMBIE via `SYS_exit`/`proc_exit`, then reaps it -- returns its pid +
exit status], scheduled by a real **runq dispatcher** [`rv_sched` runs on the
boot/kernel context+AS, picks a RUNNABLE proc and `rv_swtch`es into it loading
its user satp; procs yield back cooperatively at fork/wait/exit -- the R-P24
single-idle-`swtch` grown to N proc kernel stacks + a real context switch
between them]. Boot proof: a parent (pid 1) forks a child (pid 2), BOTH run
through the dispatcher and print their pid, the child `exit(7)`s, the parent
`wait(2)` reaps `pid=2 status=7`; then the parent fork+exec+waits a child
(pid 3) that execs a DIFFERENT program (`[execee] NEW program image running
after exec(2); pid=3`, `exit(9)`) which the parent reaps `pid=3 status=9` --
the first riscv64-solaris fork+wait, vs R-P25's single process) -- DONE (all
four sub-tasks + the R-P24 regression, re-runnable proof
`rp26/rp26-milestone-check.sh`).

R-P25 (the R-P24 booting illumos-riscv64 kernel GROWN with
the SYSCALL/EXEC path so the FIRST riscv64-solaris userland PROCESS runs, all
boot-verified under `qemu-system-riscv64 -machine virt`: the kernel builds a
fresh **user address space** [a per-process Sv39 root that shares the kernel
high half -- identity kernel-text gigapage + the direct-map -- and carries
private 4 KiB leaf tables for the user segments, `hat_user_new`/`hat_user_map`],
**execs** the R-P22 static hello ELF embedded in the kernel image [`exec_elf.c`
walks the PT_LOAD program headers, maps+copies each segment into freshly
page-aligned frames, and builds the psABI initial stack argc/argv/envp/auxv],
enters **U-mode** [`rv_user_enter`: `sret` with `sstatus.SPP=0`+SPIE+SUM,
`sepc`=user `_start`, the user `sp`, the user `satp`], and services the
process's OWN **write(2)/exit(2)** syscalls through the R-P22/23 trap path [a
U-mode `ecall` traps to `_u_trap_entry`, which swaps to the lwp kernel stack via
`sscratch`, then `rv_trap_dispatch` -> `rv_syscall` reads `a7`=nr/`a0..a5`=args
and returns in `a0`; `SYS_write=4` routes the buffer to the SBI console,
`SYS_exit=1` `rv_klongjmp`s control back to the kernel]. Boot proof: the process
prints its OWN line `hello from riscv64-solaris userland process` and exits
`exit(0)` [`wrote 44 bytes via its own write(2)`], then the kernel continues --
this is the first riscv64-solaris userland process, vs R-P22's bare-metal
payload / R-P23's kernel-only) -- DONE (all three sub-tasks + the R-P24
regression, re-runnable proof `rp25/rp25-milestone-check.sh`).

R-P24 (the R-P23 booting illumos-riscv64 kernel GROWN
toward genunix, four subsystems each boot-verified under `qemu-system-riscv64
-machine virt`: **Sv39 virtual memory** -- `hat_boot_init` builds the 3-level
Sv39 boot page table [identity map keeps the kernel live across mmu-enable +
a high direct-map kpm window], writes `satp` [MODE=8] + `sfence.vma`, and the
kernel KEEPS EXECUTING in virtual address space [`paging enabled (Sv39):
satp=0x8000000000080224`, direct-map probe reads the kernel's own `_start`
through the high VA]; a **periodic clock** -- the SBI timer [`sbi_set_timer` @
100 Hz] delivered as a Supervisor Timer Interrupt through the R-P23
`rv_trap_dispatch` -> `rv_interrupt` -> `rv_timer_intr`, ten ticks counted;
the **qemu-virt PLIC** -- init + enable UART0 [IRQ 10] + claim/complete an
external interrupt [source id 10 claimed + completed], reached through the
direct-map; and the **genunix on-ramp** -- a first-fit `kmem_alloc` over a
16 MiB boot heap + a `page_t` seed [`page_create`] + a single-thread
dispatcher `rv_swtch` into an idle loop on a fresh kmem stack with the clock
ticking) -- DONE (all four sub-tasks, re-runnable proof
`rp24/rp24-milestone-check.sh`).

R-P23 (the FIRST BOOTING illumos-riscv64 kernel -- an
illumos-MD kernel skeleton built with the NATIVE `riscv64-unknown-solaris2.11`
toolchain that boots under `qemu-system-riscv64 -machine virt` via OpenSBI and
prints a SunOS banner via SBI: `locore _start` -> set `stvec` -> `mlsetup`
(trap self-test: a deliberate S-mode breakpoint dispatched through the R-P22.3
`rv_trap_dispatch` + resumed via `sret`) -> `main()` banner -> known halt (SBI
shutdown); a REDUCED riscv64 `ld.so.1` runtime relocation engine that resolves
`R_RISCV_RELATIVE` + `R_RISCV_JUMP_SLOT` at runtime under qemu and calls
through the bound GOT slot; and a REAL native `ld` driver (`ldmin`) that links
a real EM_RISCV object THROUGH the sgs backend -- `ld_config_target(EM_RISCV)`
selection + `machrel.riscv.c` -- producing relocated `.text` byte-identical to
GNU ld, no GNU ld in the reloc path) -- DONE (all three sub-tasks, re-runnable
proof `rp23/rp23-milestone-check.sh`).

R-P22 (the sgs EM_RISCV backend SELECTED by a real gate-shaped
`ld_config_target()` -> `ld_targ_riscv` so the illumos native link path drives
the reloc pass through `machrel.riscv.c` not GNU ld; the FIRST EXECUTING
riscv64-solaris code -- a freestanding EM_RISCV hello that RUNS on
`qemu-system-riscv64 -machine virt` via OpenSBI and prints, plus a STATIC
illumos-ABI hello (crt + a minimal `write(2)`/`exit(2)` libc); and a larger
genassym-driven MD partial-link -- 6 units (locore/swtch/cpu/trap-dispatch/
clock/mmu) -> one EM_RISCV `unix_riscv64.o` that full-links with every reloc
resolved) -- DONE (all three sub-tasks, re-runnable proof
`rp22/rp22-milestone-check.sh`).
R-P21 (gate sgs `machrel.riscv.c` htab pairing + `libgcc_s.so.1` + first DYNAMIC
hello + genassym MD partial-link),
R-P20 (sgs %pcrel pairing + GOT/PLT alloc, csu crt + first hello ELF, larger uts
unit), R-P19 (riscv64-solaris toolchain finished + sgs MACH descriptor + first
EM_RISCV uts object), R-P18 (toolchain TARGET retarget + krtld/sgs reloc
coverage), R-P17 (cross toolchain + BSD psABI/ISA headers) and R-P1..R-P16
(kernel bring-up) are below / in `docs/design-riscv-port.md`.

---

## R-P24 — grow the booting kernel toward genunix (Sv39 paging + clock + PLIC + kmem/page/dispatcher on-ramp)

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils + `qemu-system-riscv64 -machine virt` with
OpenSBI v1.7. R-P24 extends the R-P23 native-toolchain booting kernel skeleton
(`rp24/kernel/`, a superset of `rp23/kernel/`) with four subsystems, each
boot-verified under qemu -- Sv39 paging, a periodic clock, the qemu-virt PLIC,
and a minimal genunix on-ramp (kmem/page/dispatcher). Proof:
`rp24/rp24-milestone-check.sh` (rebuild + reboot, all four green, re-runnable).

Boot flow now: `locore _start` -> `mlsetup` (trap self-test) -> `main`:
`hat_boot_init` (Sv39 ON) -> banner -> `startup_kmem`/`page_setup` -> `plic_init`
+ claim -> `clock_init` -> `dispatch_onramp` (swtch into the idle loop with the
clock ticking) -> known halt.

### R-P24.1 Sv39 virtual memory — DONE
- **The kernel turns on Sv39 paging and keeps executing in virtual address
  space.** `rp24/kernel/{mmu_riscv.h, hat_boot.c, mach_mmu.S}`:
  `hat_boot_init()` builds the first Sv39 page table (a single level-2 root,
  `boot_l2[512]`, page-aligned in BSS so its PA == link address pre-paging),
  IDENTITY-maps the low 4 GiB with 1 GiB gigapage leaves (V|R|W|X) so the PC/sp/
  gp stay valid the instant `satp` flips, ALSO installs a high direct-map
  (`KERNEL_DMAP_BASE = 0xffffffc000000000` + pa -> pa, gigapage leaves) as the
  kpm window, then `rv_set_satp(MAKE_SATP(root))` writes `satp` (MODE=8=Sv39,
  root PPN) + `sfence.vma`. Because the kernel is identity-mapped the next fetch
  after the `csrw satp` still resolves -> the kernel keeps running.
- **Boot proof** (`rp24/kernel/qemu-boot.log`): the line AFTER the satp write:
  ```
  [R-P24.1] enabling Sv39 paging (3-level, 39-bit VA)...
  paging enabled (Sv39): satp=0x8000000000080224 -- kernel now executing in virtual address space
    satp readback     : 0x8000000000080224
    direct-map probe  : 0x1040107310017073 (word @ dmap+0x80200000)
  ```
  `satp=0x8000_0000_0008_0224` = MODE 8 (Sv39) | root PPN 0x80224 (root PA
  0x80224000). The direct-map probe reads the kernel's own `_start`
  (`csrci sstatus,2` 0x10017073 ; `csrw sie,zero` 0x10401073) through
  `KERNEL_DMAP_BASE + 0x80200000` -- proving the high mapping translates, not
  just the identity one.
- **Scope (honest)**: gigapage identity + direct-map is the BOOT map (keeps the
  low addresses live across mmu-enable + gives a kpm window); it is not yet the
  per-segment kernel-text/data mapping with proper R^X permissions, and there
  are no 4 KiB leaf tables / `hat_memload` yet. R-P25 relocates kernel
  text/data into the high VA, drops the identity map, and adds leaf-level
  mapping.
- **CRIB**: `hat_boot_init` building a boot root + identity-mapping the kernel +
  installing a direct-map + `satp`+`sfence.vma` is this repo's R-P3.2 Sv39 boot
  map + R-P5 `hat_riscv.c hat_boot_init` + i86pc `hat_kbootmmu`/`hat_kern_setup`;
  the Sv39 PTE encoding (PPN[53:10]<<10 | V|R|W|X|A|D|G), the gigapage-leaf rule,
  the 3-level VA[38:12] split, and `satp` MODE=8 are the RISC-V privileged spec;
  the "keep the low identity map live across mmu-enable" trick is the i86pc/
  aarch64 boot-map idiom.

### R-P24.2 clock + timer interrupts — DONE
- **A periodic S-mode timer interrupt ticks through the R-P23 trap path.**
  `rp24/kernel/clock_riscv.c`: `clock_init()` arms the SBI timer
  (`sbi_set_timer(rdtime + period)`, 100 Hz over the 10 MHz qemu-virt timebase),
  unmasks `sie.STIE`, sets `sstatus.SIE`. Each Supervisor Timer Interrupt
  (scause = INT | 5) routes `stvec -> _trap_entry -> rv_trap_dispatch` (the
  R-P22/23 full-GPR trap frame) -> `rv_interrupt` (main.c, decodes scause) ->
  `rv_timer_intr` (counts a tick, re-arms; masks STIE on the last tick).
- **Boot proof**: ten ticks counted + printed by the idle loop:
  ```
    clock tick 1
    ...
    clock tick 10
  [dispatcher] idle loop counted 10 clock ticks; on-ramp proven
  ```
- **CRIB**: the "arm SBI set_timer, take STIP, re-arm for a periodic tick"
  cadence is the RISC-V SBI spec `sbi_set_timer` + the R-P22.3 `rv_clock_intr` +
  the R-P4.2 cyclic-clock contract; STIE/SIE unmask + the scause==5 timer decode
  are the RISC-V privileged spec; `rv_trap_dispatch` is R-P22.3/R-P23.

### R-P24.3 PLIC (external interrupt controller) — DONE
- **The qemu-virt PLIC is initialized and an external interrupt is
  claimed/completed.** `rp24/kernel/plic.c`: `plic_init()` sets UART0 (IRQ 10)
  priority > 0, enables it for the hart-0 S-mode context (ctx 1), drops the
  threshold to 0; `plic_provoke_uart()` sets the ns16550a THRE interrupt-enable
  so qemu asserts IRQ 10; `plic_claim()` reads the claim register (returns the
  pending source id) and `plic_complete()` writes it back (EOI). The PLIC is
  reached through the high direct-map (`KERNEL_DMAP_BASE + 0x0C000000`), proving
  the direct-map is usable for MMIO after paging.
- **Boot proof**:
  ```
  [R-P24.3] PLIC: init + claim an external interrupt (UART0 IRQ10)
    PLIC claim        : source id 10 -- claimed + completed (external interrupt handled)
  ```
  Source id 10 == UART0. `rv_interrupt` also handles scause==9 (S-external) by
  claim/complete, so a live external interrupt routes through the trap path too.
- **CRIB**: the PLIC register map (priority @ base+4*src, enable bitmap @
  base+0x2000+0x80*ctx, threshold/claim @ base+0x200000+0x1000*ctx) + the "set
  priority, enable for context, drop threshold, claim, complete" flow are the
  RISC-V PLIC spec + this repo's R-P4.3 PLIC contract; the qemu-virt base
  0x0C000000 + UART0=IRQ10 + S-mode context numbering are the qemu virt board.

### R-P24.4 toward the dispatcher / genunix — DONE (minimal on-ramp)
- **A boot heap + `kmem_alloc` + a `page_t` seed + a single-thread dispatcher
  `swtch` into an idle loop.** `rp24/kernel/{startup.c, mach_swtch.S}`:
  - `startup_kmem()` + `kmem_alloc()/kmem_free()`: a first-fit allocator over a
    16 MiB BSS boot heap (split + coalesce). Boot proof:
    `kmem heap: 16777192 bytes; kmem_alloc(4096)=0x80226018 kmem_alloc(256)=0x80227030`
    then `kmem_free ok; inuse now 0 bytes`.
  - `page_setup()`/`page_create()`: a flat `page_t` array (pfn + inuse) seeding
    the VM page layer over an 8 MiB managed window. Boot proof:
    `page_t layer: 2048 frames managed; page_create()=0x88000000`.
  - `dispatch_onramp()` + `rv_swtch` (mach_swtch.S, save/load callee-saved +
    ra/sp + satp, `sfence.vma`, `ret`): builds an idle `kthread_t` on a fresh
    16 KiB kmem stack, `swtch`es the boot CPU into `idle_loop` (which `wfi`s and
    counts clock ticks), then `swtch`es back. Boot proof:
    ```
    [dispatcher] built idle kthread (fresh 16K kmem stack); swtch -> idle
    [dispatcher] idle thread running on its own stack; entering idle loop with clock ticking
    ... clock tick 1..10 ...
    [dispatcher] swtched back to boot context; dispatcher round-trip complete
    ```
    A thread running on a kmem-allocated stack, entered by a real context
    switch, in the idle loop with the clock ticking -- the genunix on-ramp.
- **Scope (honest, per the anti-wedge directive)**: this is the REDUCED seam --
  a first-fit boot heap (not the slab `kmem_cache`/vmem), a flat `page_t` array
  (not the page hash + freelists), a two-context hand `swtch` (not the full disp
  queues / `thread_create`/`setrun`). It proves the on-ramp end to end; R-P25
  grows it into the real allocator + page layer + dispatcher.
- **CRIB**: the `startup()`/`startup_memlist`/`startup_kmem` decomposition +
  the heap-then-kmem-then-page-then-dispatcher order is illumos uts/common/os
  `startup.c` + i86pc `startup.c`; the first-fit kmem + `page_t` seed are the
  R-P5.1/R-P5.2 page/kmem contracts (reduced from slab/vmem to a bump-split
  heap); `rv_swtch` (save callee-saved + ra/sp + satp, sfence, ret) is the
  R-P5.4 / R-P21 `mach_swtch.S` switch body (RISC-V LP64 callee-saved s0..s11;
  NetBSD riscv `cpu_switch.S` idiom), trimmed of the lofault/genassym coupling
  for the minimal seam.

### `/root/riscv-port/rp24/` contents
`kernel/{locore.S, mach_trap.S, mach_clock.S, mach_mmu.S, mach_swtch.S,
mmu_riscv.h, clock_riscv.h, plic.h, assym.h, sbi.h, sbi.c, hat_boot.c,
clock_riscv.c, plic.c, startup.c, main.c, kernel.lds, build-kernel.sh, *.o,
unix.elf, qemu-boot.log}` (the grown kernel); `rp24-milestone-check.sh` (all
four sub-tasks, rebuild+reboot, re-runnable green). Repo copies under
`src/riscv/rp24/`.

### Next: R-P26
1. **fork(2)/exec(2)/wait(2)** -- a real process table + `lwp`/`proc` structs,
   copy the parent AS (or COW), a general `exec` that opens the ELF from a
   filesystem (vs the embedded `.incbin`) and hosts the R-P23.2 `ld.so.1`
   engine for the DYNAMIC hello (interp + aux vector already scaffolded here).
2. **More syscalls + errno ABI** -- `open/read/close/brk/mmap`, the SunOS
   error-return convention (the R-P22 libc returns `a0` verbatim today), the
   full `<sys/syscall.h>` table driving `rv_syscall`, and per-lwp trap state.
3. **Full HAT + real dispatcher** (carried from R-P24): relocate kernel
   text/data into the high VA + drop the identity map + `hat_memload`/`hat_unload`
   + R^X kernel permissions; vmem/`kmem_cache`; the page hash + freelists;
   `thread_create`/`setrun`/disp queues; SMP secondaries via SBI HSM.

---

## R-P29 -- full high-VA R^X HAT (W^X kernel + slab kmem_cache + TLB shootdown) + per-CPU dispatch + kpreempt + FP context switch

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils (incl. the shared linker `ld-shared`) +
`qemu-system-riscv64 -machine virt -smp 2` with OpenSBI v1.7. R-P29 HARDENS the
R-P28 SMP dynamic-linking kernel (`rp29/kernel/`, a superset of `rp28/kernel/`)
toward a production-shaped kernel, each subsystem boot-verified under qemu --
the full high-VA R^X HAT (the headline memory-management maturity step),
per-CPU dispatch queues + kpreempt, and an FP context switch + more syscalls.
Proof: `rp29/rp29-milestone-check.sh` (rebuild the userland + ld.so.1 + the
initramfs + the kernel + reboot; the three R-P29 sub-tasks + the R-P24 + R-P26 +
R-P27 + R-P28 regressions all green, re-runnable).

Boot flow now: the R-P28 flow (R-P24 subsystems) THEN `hat_kernel_setup` (build
+ install the W^X kernel map, high-VA probe, W^X self-test) -> `kmem_cache_init`
+ a slab alloc/free proof -> R-P24 PLIC/clock/dispatcher -> R-P26/27/28 sessions
-> `run_fptest` (FP context switch + getpid/brk) -> `disp_percpu_demo` (per-CPU
queues + steal + kpreempt) -> `smp_start` (R-P28 SMP regression) ->
`hat_tlb_shootdown` (remote sfence.vma to hart 1) -> known halt.

### R-P29.1 full high-VA R^X HAT (the headline) -- DONE
- **A real kernel HAT replaces the R-P24 boot map: the kernel image is mapped
  PER SEGMENT at 4 KiB leaf granularity with W^X permissions, the kernel
  executes through the high direct-map alias, W^X is ENFORCED, a slab
  kmem_cache sits over the boot heap, and a TLB shootdown broadcasts to the
  secondary hart.** `rp29/kernel/{hat.c, kmem_cache.c, kernel.lds, mmu_riscv.h,
  sbi.c/.h, hat_boot.c}`:
  - `kernel.lds` now PAGE-ALIGNs the segments and brackets them with boundary
    symbols (`__text_start/__etext`, `__rodata_start/__erodata`,
    `__data_start/__end`) so each kernel segment can be mapped by whole 4 KiB
    leaf PTEs with its own R^X bits.
  - `hat_memload(root, va, pa, perms)` (hat.c) is the 4 KiB leaf mapping
    primitive (the illumos hat_memload contract): a 3-level Sv39 walk that
    allocates missing tables and installs one page-sized mapping with the given
    protections (A|D preset).  `hat_kernel_setup()` builds a fresh Sv39 root and
    maps `.text` **R|X** (executable, NOT writable), `.rodata` **R** (read-only),
    `.data`+`.bss` **R|W** (writable, NOT executable) -- so **no page is both
    writable and executable (W^X)** -- at BOTH the low identity VA and the high
    direct-map alias (`KERNEL_DMAP_BASE + pa`).  A 2 MiB-megapage RW window over
    the 256 MiB qemu DRAM (0x80000000..0x90000000) covers the boot heap + kernel
    stacks + page tables; MMIO (0..256 MiB) is mapped RW (no X).  It installs
    the new root (satp + sfence.vma) and publishes it so user ASes clone the
    fine-grained W^X kernel half.
  - **High-VA execution proof**: after the switch, `hat_kernel_setup` computes
    the high direct-map alias of a probe function (`KERNEL_DMAP_BASE + &probe`)
    and CALLS it through that canonical Sv39 high VA -- the fetch + execute come
    from the high half.
  - **W^X self-test**: `hat_wx_selftest` stores to a `.text` address; because
    `.text` is mapped R|X (no W) the store traps as a store/AMO page fault
    (scause 15), which `rv_trap` (main.c) catches (arming flag set), records,
    and steps sepc past -- proving `.text` is not writable.
  - **vmem + slab kmem_cache** (kmem_cache.c): a one-arena vmem resource
    allocator (span import, first-fit segment list, coalescing free) + a
    slab-style `kmem_cache` (a cache draws page-sized SLABS from the arena and
    slices each into equal objects threaded on a free list; alloc/free recycle).
    Boot proof: create a 96-byte-object cache, alloc 40 objects (one slab of
    42), free them, re-alloc and confirm a freed object is recycled.
  - **TLB shootdown** (hat.c `hat_tlb_shootdown` + sbi.c `sbi_remote_sfence_vma`):
    a local `sfence.vma` + a remote `sfence.vma` to the secondary hart via the
    SBI RFENCE extension (EID "RFNC", FID 1) -- every hart drops stale
    translations after a shared kernel mapping changes.
- **Boot proof** (`rp29/kernel/qemu-boot.log`):
  ```
  [R-P29.1] full HAT: per-segment R^X kernel map (text RX, rodata R, data/bss RW) + high-VA execution
    [hat] high-VA probe via dmap alias 0xffffffc0802018a6 returned 0x0000000000005239 (executed at high VA)
    new kernel satp   : 0x8000000000080362 -- W^X kernel map installed
    [R-P29.1] W^X test: store to .text FAULTED -- W^X enforced (.text is not writable)
  [R-P29.1] vmem arena + slab kmem_cache: create + alloc/free recycle
    cache 'rp29_obj' (96B): allocated 40 objs -> slabs=1 objs/slab-total=42 inuse=40
    freed 40; re-alloc recycled addr 0x000000008038c0c0 (a freed obj, recycle OK)
  [R-P29.1] TLB shootdown: local sfence.vma + remote sfence.vma to hart 1 (SBI RFENCE)
    remote sfence.vma to hart 1: SBI_SUCCESS -- TLB shootdown broadcast across harts
  [R-P29.1] TLB shootdown PROVEN: cross-hart sfence.vma issued + accepted.
  ```
- **Scope (honest)**: the kernel is still LINKED low (0x80200000) and runs at
  the low identity VA; hat_kernel_setup maps it fine-grained R^X and ALSO at the
  high direct-map alias (proving high-VA execution by calling a probe through
  it), but the identity map of the kernel image is NOT dropped -- because the
  medany kernel's `la`/global-data references resolve to the low link
  addresses, truly running at high VA + dropping the low identity map requires
  RELINKING the kernel at `KERNEL_DMAP_BASE + 0x80200000` (verified feasible:
  qemu loads the ELF by p_paddr and OpenSBI jumps the S-payload at its physical
  load address even when e_entry is the high VA, so a high-linked kernel boots
  bare then turns paging on -- the R-P30 step, requiring a locore bootstrap that
  enables paging before touching high-VA symbols).  The low identity gigapages
  for unused address space ARE dropped (only the kernel image 4 KiB leaves + the
  256 MiB RW DRAM window + MMIO remain).  kmem_cache is a single per-cache free
  list (no magazines / per-CPU depot / slab coloring); vmem is one arena.  The
  TLB shootdown uses the SBI RFENCE (firmware executes the remote fence); no
  per-hart shootdown queue / no lazy shootdown coalescing.
- **CRIB**: mapping the kernel per segment with distinct R^X protections + the
  hat_memload leaf-install contract + dropping the boot identity map is illumos
  `uts/i86pc/vm/hat_i86.c` (`hat_memload`/`hat_kern_setup`) + `seg_kmem` + the
  OpenBSD/xv6 W^X kernel map; the 4 KiB Sv39 leaf walk + the R/W/X leaf bits +
  the non-leaf-PTE rule + SFENCE.VMA are the RISC-V privileged spec; the
  "keep the running code mapped across the satp switch then jump to the new VA"
  transition is the i86pc/aarch64 boot-map trampoline idiom; the vmem arena is
  `uts/common/os/vmem.c` (Bonwick vmem) and the slab kmem_cache is
  `uts/common/os/kmem.c` (Bonwick slab), both reduced to one arena / one free
  list; the cross-hart sfence.vma is the illumos `hat_tlb_inval`/`x_call`
  TLB-shootdown model mapped onto the SBI RFENCE `remote_sfence_vma`.

### R-P29.2 per-CPU dispatch queues + kpreempt -- DONE
- **Each hart owns its own dispatch queue; both harts drain their LOCAL queue
  concurrently and STEAL from a peer when empty; a kpreempt() kernel
  preemption point fires.** `rp29/kernel/{disp.c, locore.S, sbi.c/.h}`:
  - A `cpu_t` per hart carries a per-CPU `cpu_disp_t` (a job ring + a lock only
    contended on a steal) + a `cpu_runrun` preempt flag.  Jobs are placed on
    the per-CPU queues at enqueue time (illumos `setbackdq`); `disp_run(self)`
    drains the LOCAL queue first (fast path) and, when empty, `disp_steal`s from
    a peer's queue tail (illumos `disp_getwork` work-stealing balance).
  - `disp_ap_entry` (locore.S) is a second AP entry (like `_secondary_start`
    but landing in `disp_secondary_main`) so the secondary drains its OWN
    per-CPU queue.  The secondary `sbi_hart_stop`s itself when done (returns to
    the HSM STOPPED state) so the later R-P28 SMP proof can restart it.
  - `kpreempt(hartid)` checks `cpu_runrun` (set by `kpreempt_arm`, the illumos
    `cpu_kprunrun`) at an explicit kernel preemption point and yields.
- **Boot proof** (`-smp 2`): 12 jobs enqueued UNBALANCED (9 on hart 0's queue, 3
  on hart 1's); hart 1 drains its 3 then STEALS from hart 0 -- both harts run
  concurrently from their own queues:
  ```
  [R-P29.2] per-CPU dispatch: each hart drains its OWN runq; empty queue STEALS from the peer
    [cpu 0] ran job N (from own queue) ... [cpu 1] ran job M (STOLEN from peer) ...
    [disp] cpu0 ran=6 (stole 0); cpu1 ran=6 (stole 3)
  [R-P29.2] percpu disp PROVEN: both harts ran from their own per-CPU queues + a steal balanced them.
    [kpreempt] cpu_runrun set at iter 500 -> kernel loop yielded
  [R-P29.2] kpreempt PROVEN: kernel preemption point fired + yielded.
  ```
  (The two harts' console output interleaves char-by-char -- genuine concurrent
  execution.)
- **Scope (honest)**: the per-CPU queues hold work-item jobs (proving the
  per-CPU-queue + steal SHAPE across 2 harts), not yet the full proc_t priority
  procs reentering `rv_sched` on both harts (that needs per-CPU curproc/
  sched-cursor state + a locked shared proc table -- R-P30); kpreempt is an
  explicit poll point (not yet wired to the clock tick's `cpu_kprunrun`); no
  scheduling classes (TS/RT).
- **CRIB**: `cpu_t.cpu_disp` (a per-CPU disp_t with its own queues) + `setbackdq`
  placement + `disp_getwork` stealing from a peer when the local queue is empty
  is illumos `uts/common/disp/disp.c` + `sys/cpu.h` `cpu_t`; `kpreempt()`
  checking `cpu_kprunrun` is illumos `disp.c` `kpreempt()` + the
  `cpu_runrun`/`cpu_kprunrun` flags; the HSM hart_stop (return to STOPPED) is the
  SBI spec; the amoswap.w per-queue spinlock is the RISC-V A-extension.

### R-P29.3 FP context switch + more syscalls -- DONE
- **rv_swtch now saves/restores the FP register file (fcsr + f0..f31) per
  context, so two FP-using procs preempt each other WITHOUT corrupting each
  other's FP state; getpid/brk + the reduced SunOS errno ABI work.**
  `rp29/kernel/{mach_swtch.S, proc_riscv.h, proc.c, startup.c, main.c}` +
  `rp29/user/fptest.c`:
  - `struct rv_context` (proc_riscv.h) gains an FP save area (`c_fcsr` +
    `c_f[32]`); `rv_swtch` (mach_swtch.S) enables `sstatus.FS=Dirty` then
    `fsd`s f0..f31 + `frcsr` of the outgoing context into `*old` and `fld`s +
    `fscsr`s the incoming context from `*new` -- the illumos `fpu_save`/
    `fp_restore` folded into the switch.  Fresh contexts zero the FP area
    (`ctx_clear_fp` in proc.c, thread_init in startup.c) so the first switch-in
    loads clean FP state.
  - `proc_brk` (proc.c) is a minimal program break: an anonymous heap growing
    upward from 0x20000000, one 4 KiB zeroed page mapped on demand into the
    proc's user AS (+ a local TLB flush).  `rv_syscall` (main.c) adds
    `SYS_brk`(17)/`SYS_read`(3)/`SYS_open`(5)/`SYS_close`(6)/`SYS_fstat`(28)/
    `SYS_mmap`(115) with the reduced SunOS error-return ABI (a negative a0 is
    -errno: EBADF/ENOMEM/ENOSYS from `sys/errno.h`); mmap is a reduced anonymous
    map (brk-backed).
  - `fptest.c` (user): queries+grows brk (writes+reads the new page), then forks
    two children that pin distinct sentinels in `fs0` (111 and 222) and spin
    (getting preempted many times), re-reading fs0 each round; each verifies its
    fs0 survived.
- **Boot proof**: the two FP children interleave via preemption and BOTH keep
  their fs0 intact across every switch:
  ```
    [fptest] parent getpid()=13
    [fptest] brk grew heap to 536875008; wrote+read heap[0]=41 (OK)
    [fp A pid=14] round 0 fs0=111 (intact) ... [fp B pid=15] round 0 fs0=222 (intact) ...
    [fp A] FP state PRESERVED across preemption
    [fp B] FP state PRESERVED across preemption
  [R-P29.3] FP ctx switch PROVEN: two FP procs preempted + kept distinct fs0 (rv_swtch saves/restores f0..f31).
  [R-P29.3] syscalls PROVEN: getpid/brk + the reduced SunOS errno return ABI.
  ```
  Under the R-P28 kernel (which did NOT save FP across rv_swtch) the two
  children -- writing different values into the SAME architectural fs0 -- would
  corrupt each other; here both stay intact, proving the per-context FP save.
- **Scope (honest)**: EAGER FP save/restore on every switch (not the illumos
  lazy FS=Off-until-first-FP-use / `fp_fork` deferred save -- eager is simpler +
  correct, at the cost of always touching 32 FP regs per switch); brk is an
  eager on-demand page map (no seg_vn / no lazy fault-in / no shrink-frees
  the pages); open/read/fstat are ENOSYS stubs (the vfs read path is later); no
  per-lwp trap state beyond the existing kstack; the old AS is still leaked on
  exec/exit (as_free is R-P30).
- **CRIB**: saving/restoring the FP register file across a context switch is
  illumos `fpu_save`/`fp_restore` + the lwp FPU save area + the RISC-V
  privileged-spec `sstatus.FS` state field (fsd/fld/frcsr/fscsr); brk growing an
  anonymous heap by mapping fresh pages is illumos `os/grow.c` `brk()` + `as_map`
  reduced to on-demand 4 KiB leaf maps; the a7=nr/a0..=args/-errno-in-a0 ABI +
  the errno numbers are the native `sys/syscall.h` + `sys/errno.h`.

### `/root/riscv-port/rp29/` contents
`kernel/{locore.S [+ `disp_ap_entry`], mach_trap.S, mach_clock.S, mach_mmu.S,
mach_swtch.S [+ FP save/restore], mach_uentry.S, user_elf.S [+ fptest.bin],
mmu_riscv.h, clock_riscv.h, plic.h, proc_riscv.h [+ FP context fields], assym.h,
sbi.h/.c [+ IPI/RFENCE/hart_stop], hat_boot.c [+ hat_active_root], hat.c [NEW:
full high-VA R^X HAT + hat_memload + W^X self-test + TLB shootdown],
kmem_cache.c [NEW: vmem arena + slab kmem_cache], hat_user.c, exec_elf.c,
ramfs.c, proc.c [+ FP ctx-clear + proc_brk + p_brk], clock_riscv.c, plic.c,
smp.c, disp.c [NEW: per-CPU disp queues + steal + kpreempt], startup.c, main.c
[+ R-P29.1 HAT/kmem_cache/TLB phases + run_fptest + new syscalls], kernel.lds
[+ page-aligned segments + boundary symbols], build-kernel.sh, *.bin, *.o,
unix.elf, qemu-boot.log}`; `ldso/{...unchanged from R-P28...}`;
`user/{forker.c, execee.c, preempt.c, fsexec.c, dynexec.c, dynexec2.c,
hellodyn.c, fptest.c [NEW: FP-context-switch + getpid/brk proof],
mkinitramfs.py, build-user.sh [+ fptest], + built ELFs/*.o}`; `hello/{...}`;
`rp29-milestone-check.sh` (all three sub-tasks + the R-P24 + R-P26 + R-P27 +
R-P28 regressions, rebuild+reboot, re-runnable green).

### R-P29 done; the R-P30 section below closes the R-P29 high-VA gap.

---

## R-P30 -- high-VA relink + DROP the identity map (true high-half kernel) + TS/RT scheduler on both harts + as_free

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils + `qemu-system-riscv64 -machine virt -smp 2`
with OpenSBI v1.7.  R-P30 extends the R-P29 production-shaped kernel
(`rp30/kernel/`, a superset of `rp29/kernel/`) with three sub-tasks, each
boot-verified under qemu.  Proof: `rp30/rp30-milestone-check.sh` (rebuild the
userland + ld.so.1 + initramfs + kernel + reboot; the three R-P30 sub-tasks +
the R-P24 + R-P26 + R-P27 + R-P28 + R-P29 regressions all green, re-runnable).

Boot flow now: OpenSBI jumps the S-payload to physical `0x80200000` = `_start`
(locore, running position-independently at the physical load addr) -> build the
Sv39 boot tables (`hat_earlyboot`) -> enable paging -> JUMP PC to the high-VA
`_start_high` -> `mlsetup` -> `main`: report the active high-VA satp ->
`startup_kmem` -> `hat_kernel_setup` (identity-FREE W^X root) -> W^X self-test ->
**`hat_drop_identity` (R-P30.1 headline: low identity read FAULTS)** -> kmem_cache
-> PLIC -> clock -> dispatcher on-ramp -> the R-P26/27/28/29 process + SMP + FP
sessions -> **`run_tsrt_sched` (R-P30.2 TS/RT classes on both harts)** ->
**`run_asfree` (R-P30.3 as_free no-leak)** -> TLB shootdown -> known halt.

### R-P30.1 high-VA relink + DROP the identity map (the headline) -- DONE
- **The kernel is LINKED + EXECUTES at high VA and the low identity map is
  DROPPED -- a true high-half kernel.**  `rp30/kernel/{kernel.lds, locore.S,
  hat_boot.c, hat.c, mmu_riscv.h, main.c}`:
  - **kernel.lds**: link the sections at VMA `KADDR = KERNEL_DMAP_BASE +
    0x80200000` but set the LMA to physical `0x80200000` via
    `AT(ADDR(sec) - LOAD_OFFSET)` (LOAD_OFFSET = VMA-LMA), so the ELF program
    headers carry `VirtAddr = 0xffffffc080200000`, `PhysAddr = 0x80200000`.
    qemu deposits the image at `p_paddr`; OpenSBI jumps the S-payload to the
    physical load address (`Domain0 Next Address: 0x80200000`), so the physical
    byte at `0x80200000` -- `_start` (`.text.start`, first) -- runs first, in
    bare mode.
  - **locore.S `_start`** runs at PHYSICAL `0x80200000` (medany PC-relative
    addressing computes the PHYSICAL address of every high-linked symbol,
    because runtime PC and link-time PC differ by exactly the KERNEL_DMAP_BASE
    offset that separates the symbol's PA and VA): mask ints, claim the boot
    hart, set a PHYSICAL gp+sp, zero BSS, call `hat_earlyboot()` (builds the
    boot tables: low identity gigapages to survive the satp flip + the kernel
    HIGH map + the direct-map -- but does NOT enable paging), write satp +
    sfence.vma (paging ON), then load the HIGH VA of `_start_high` (`la` gives
    the physical addr; add KERNEL_DMAP_BASE) and `jr` there.  From `_start_high`
    the kernel runs PURELY at high VA: reload gp+sp to the HIGH link addresses,
    install stvec, call `mlsetup` -> `main`.
  - **hat.c `hat_kernel_setup`** maps the kernel per segment (W^X: .text R|X,
    .rodata R, .data/.bss R|W) + the DRAM window + MMIO at the HIGH direct-map
    ONLY (no low identity), and installs the identity-FREE W^X root; the PC is
    already high so the fetch after the satp write resolves.
  - **hat.c `hat_drop_identity` + `hat_ident_dropped_test`** (R-P30 headline
    proof): the running satp is the W^X root (no identity); a read of the first
    kernel word through its LOW identity VA `0x80200000` FAULTS (the fault
    handler `rv_trap`, armed via `hat_ident_expect`, records it + steps sepc),
    while the same word through its HIGH VA reads back the instruction.
  - **VA<->PA**: because the whole kernel high half is the direct-map
    (VA = KERNEL_DMAP_BASE + PA), `KVTOP`/`PTOKV` (mmu_riscv.h) convert a
    kernel VA <-> its physical address at every PTE boundary -- every pointer
    stored INTO a PTE goes through `KVTOP` (kmem now returns direct-map VAs),
    every PA read OUT of a PTE and dereferenced goes through `PTOKV`
    (hat.c/hat_user.c/exec_elf.c/proc.c).  Secondary harts start at their
    PHYSICAL entry (`KVTOP(_secondary_start)`) with the identity-bearing BOOT
    root (`hat_boot_root_satp`, a MINIMAL identity trampoline used ONLY on the
    AP-bringup path), then jump to the high continuation.
- **Boot proof** (`rp30/kernel/qemu-boot.log`):
  ```
  paging enabled (Sv39): satp=0x8000000000080354 -- kernel executing in virtual address space at HIGH VA
    &main (high VA)   : 0xffffffc0802036bc
    direct-map probe  : 0x1040107310017073 (word @ dmap+0x80200000)
  ...
  [R-P30.1] high-VA relink: drop the low identity map (true high-half kernel)
    kernel _start via HIGH VA 0xffffffc080200000 = 0x1040107310017073 (executing here)
    read of _start via LOW identity VA 0x80200000: FAULTED -- identity map dropped
  [R-P30.1] identity map dropped; running purely high-VA
  ```
  The ELF: `Entry point 0xffffffc080200000`; LOAD `0xffffffc080200000
  0x0000000080200000 ... R E` (VMA=high, LMA=physical).
- **Scope (honest)**: the PRIMARY hart runs with NO identity map (the headline
  is met).  A MINIMAL identity map survives ONLY in the boot root
  (`hat_boot_root_satp`), used exclusively to bring up secondary harts (they
  start at their physical entry with paging off, install the boot root so the
  first post-satp fetch resolves, jump high, and run the shared kernel mappings
  from the boot root -- which is RWX gigapages, not W^X: the AP-bringup root is
  not hardened, only the primary's running root is).  Switching secondaries onto
  the primary's W^X root at high VA is R-P31.  The direct-map is gigapage
  (RWX-permission) at the top-level slot for DRAM/MMIO; the per-segment W^X
  applies to the kernel image leaves.
- **CRIB**: the VMA-high / LMA-low split via `AT()` + `_start`-at-the-load-
  address-then-jump-to-the-high-half-virtual-`_start` trampoline is the Linux
  `arch/riscv/kernel/head.S` `setup_vm` + `relocate_enable_mmu` idiom + the
  i86pc/aarch64 boot-map-then-jump-to-KERNELBASE transition; the KVTOP/PTOKV
  kernel-VA<->PA conversion is illumos `hat_i86` `mmu_ptob(pfn)` / `hat_kpm`;
  the physical `0x80200000` S-payload address + `Next Address` = the load
  address is the OpenSBI + qemu-virt boot convention; `hat_kernel_setup` mapping
  per segment + dropping the identity map is illumos `hat_kern_setup` /
  `hat_i86.c` + the OpenBSD/xv6 W^X kernel map; the Sv39 leaf walk + satp MODE=8
  are the RISC-V privileged spec.

### R-P30.2 TS/RT priority scheduler on both harts -- DONE
- **A real scheduling-class dispatcher: SC_RT globally above SC_TS (RT preempts
  TS), TS round-robin within a band, tick-driven kpreempt, priority-inheritance-
  lite, and BOTH harts dispatch from the shared class runq.**
  `rp30/kernel/{sched_class.c, locore.S [+ `sc_ap_entry`/`sc_ap_high`], smp.c}`:
  - Each schedulable entity carries `sp_class` (SC_RT/SC_TS) + a base priority;
    `sc_global_pri()` maps RT to a band (>=100) strictly above all TS (0..59),
    so any runnable RT proc outranks any TS proc (illumos dispclass global
    priority).  `disp_pick()` returns the highest global-pri runnable proc under
    a shared runq lock; equal-global-pri TS procs ROUND-ROBIN (skip the one that
    just ran if a same-pri peer waits).
  - `sc_dispatch(self)` re-picks every slice, so an RT arrival wins the very
    next pick (tick-granularity preemption of a running TS proc); a TS proc's
    quantum (`sp_q`) expiring rotates it to the tail.
  - Priority-inheritance-lite: an RT proc blocked on a lock held by a low-pri TS
    proc BOOSTS the holder's effective priority to the RT band, so the holder
    runs ahead of the other TS procs, releases the lock, and the RT waiter
    proceeds (the illumos turnstile `pi_willto` reduced to one boost field).
  - The boot hart starts the secondary via the SBI HSM (`sc_ap_entry` ->
    `sc_ap_high` -> `sc_secondary_main`); BOTH harts run `sc_dispatch` on the
    ONE lock-protected class runq.  smp.c's `secondary_main` now `sbi_hart_stop`s
    so this phase can restart the hart; `sc_secondary_main` parks (STARTED) so
    the later TLB shootdown still reaches it.
- **Boot proof** (`-smp 2`): RT proc 4 (gpri 120) runs first on both harts,
  then the PI-boosted TS proc 3 (gpri 115) releases the lock, the RT waiter
  proc 0 (gpri 110) runs, then TS procs 1/2 (gpri 30) round-robin -- across two
  hartids:
  ```
      [hart 1] ran RT proc 4 (gpri 120)
      [hart 0] ran RT proc 4 (gpri 120)
      [hart 1] ran TS proc 3 (gpri 115, PI-boosted)
        [PI] TS proc 3 released the lock; RT waiter may run
      [hart 0] ran RT proc 0 (gpri 110)
      [hart 1] ran TS proc 1 (gpri 30) ... [hart 0] ran TS proc 2 (gpri 30) ...
    [sched] hart0 slices=7, hart1 slices=8
  [R-P30.2] TS/RT sched PROVEN: RT preempts TS, TS round-robins, PI unblocks the RT waiter, both harts dispatch.
  ```
- **Scope (honest)**: the class dispatcher schedules lightweight compute
  entities (proving the CLASS + PREEMPTION + PI + both-harts SHAPE), not yet the
  full proc_t user contexts reentering `rv_sched` concurrently on both harts
  (that needs per-CPU curproc + a locked shared proc table across the user
  dispatch path -- R-P31); the user proc dispatcher (`rv_sched`, proc.c) is
  still single-hart with the R-P28 band scan.  Two classes (RT/TS), a small
  band, one quantum policy (no priority decay / no interactive boost).
- **CRIB**: the TS/RT scheduling-class split with RT globally above TS,
  `ts_tick` quantum expiry, and RT preempting TS is illumos `uts/common/disp/
  {ts.c,rt.c,disp.c}` + `sys/class.h`; `cpu_kprunrun` set by the tick + checked
  at a preemption point is illumos `disp.c` `kpreempt()`/`clock()`; priority
  inheritance is the illumos turnstile `pi_willto` (`os/turnstile.c`) reduced to
  a single boost; the shared lock-protected runq drained by two harts is the
  R-P28 smp.c runq + the RISC-V A-extension lock.

### R-P30.3 as_free + more lifecycle -- DONE
- **A process's address space is freed on exec/exit (walk the private user half,
  unmap + free the user page tables + frames), so fork/exec/exit no longer leaks
  (the R-P26 leak).**  `rp30/kernel/{hat_user.c [+ `hat_as_free`], startup.c
  [page-frame allocator], proc.c [+ as_free at do_exec/reap + `run_asfree`]}`:
  - `startup.c` replaces the R-P29 `kmem_alloc_page` (which over-allocated 2
    pages + returned the aligned interior, LEAKING the header -- unfreeable)
    with a REAL page-frame allocator: a dedicated 32 MiB page arena carved from
    BSS, a bump cursor + a singly-linked free list, so `kmem_alloc_page` /
    `kmem_free_page` are symmetric and `kmem_pages_inuse()` is observable.
  - `hat_user.c hat_as_free(root)` walks the PRIVATE user half (level-2 index 0
    only -- indices 1..511 are the SHARED kernel half, never freed) and
    reclaims, in order: every 4 KiB leaf FRAME, then the L0 tables, then the L1
    table, then the L2 subtree, then the root -- the illumos as_free /
    hat_free_end teardown.
  - `proc.c` calls `hat_as_free` in `do_exec` (free the OLD AS after switching
    to the new one) and at proc reap (`proc_wait` + the `rv_sched` parentless-
    zombie reap), guarded to user procs (kernel threads have `p_uroot == 0`).
  - `run_asfree` (proof): fork+exec+exit-shaped AS lifecycle 20 times
    (`exec_image` builds a fresh AS -- the exact exec(2) loader -- then
    `hat_as_free` tears it down), watching `kmem_pages_inuse()`.
- **Boot proof**:
  ```
  [R-P30.3] as_free: fork+exec+exit an AS N times; frames reclaimed (no leak)
    baseline frames in use: 27
    iter 0: after-build=37 after-free=27
    ... iter 15: after-build=37 after-free=27
    frames: baseline=27 peak-per-AS=37 final=27
  [R-P30.3] as_free PROVEN: frame count returned to baseline after N AS builds+frees (no leak).
  ```
  The per-AS frame count rises to 37 and returns to the 27 baseline every
  iteration -- every user page table + frame is reclaimed, no leak.
- **Scope (honest)**: as_free is an eager full walk of the single private user
  subtree (no COW-refcount sharing, no lazy teardown); `exec_image` still
  allocates the lwp kernel stack from the BYTE heap (`kmem_alloc`), which is not
  freed in the `run_asfree` isolation loop (it does not affect the page-frame
  count the proof watches), but the real reap path (`proc_wait`) DOES
  `kmem_free` the kstack.  The byte heap (first-fit) coalesces forward only.
- **CRIB**: as_free walking the address space + hat_free/hat_unload tearing down
  the page tables + freeing the backing frames is illumos `uts/common/vm/as.c`
  `as_free` + i86pc `hat_free_end`/`htable_release` + seg_vn free (BSD analogue:
  `pmap_remove` + `pmap_release`); the page-granular free-list frame allocator
  distinct from the byte heap is illumos `page_get`/`page_free` reduced to one
  arena + a free list.

### `/root/riscv-port/rp30/` contents
`kernel/{locore.S [+ high-VA bootstrap `_start`->`_start_high`, `_secondary_*`,
`disp_ap_*`, `sc_ap_*` trampolines], kernel.lds [VMA-high / LMA-low via AT()],
mmu_riscv.h [+ KVTOP/PTOKV/KERNEL_PHYS_BASE], hat_boot.c [`hat_earlyboot` +
`hat_boot_root_satp`], hat.c [high-VA-only W^X map + `hat_drop_identity` +
`hat_ident_dropped_test`], hat_user.c [KVTOP/PTOKV boundaries + `hat_as_free`],
exec_elf.c [KVTOP satp], proc.c [as_free at do_exec/reap + `run_asfree`],
startup.c [page-frame alloc/free + `kmem_pages_inuse`], sched_class.c [NEW: TS/RT
class dispatcher on both harts], smp.c/disp.c [KVTOP hart_start entry +
hat_boot_root_satp AP root], main.c [+ R-P30.1 identity-drop phase +
`run_tsrt_sched` + `run_asfree` + load-fault trap servicing], mach_*.S, sbi.c/.h,
kmem_cache.c, ramfs.c, clock_riscv.c, plic.c, *.bin, *.o, unix.elf,
qemu-boot.log}`; `ldso/{...unchanged}`; `user/{...unchanged}`; `hello/{...}`;
`rp30-milestone-check.sh` (all three R-P30 sub-tasks + the R-P24 + R-P26 + R-P27
+ R-P28 + R-P29 regressions, rebuild+reboot, re-runnable green).

### Next: R-P31
1. **Secondaries on the W^X root** -- switch each secondary hart from the boot
   root's identity trampoline onto the primary's identity-FREE W^X root at high
   VA (so no identity map exists on ANY running root), and have BOTH harts
   reenter the real proc_t `rv_sched` concurrently (per-CPU curproc + a locked
   shared proc table) rather than the isolated `sched_class.c` demo.
2. **ld.so.1 hardening** -- lazy PLT binding (a PLT0 resolver via a `SYS_bind`
   trap), `.gnu.hash`, symbol versioning, a self-relocating ET_DYN ld.so.1,
   `mprotect`-after-reloc; ld.so.1 mmaps the file itself instead of SYS_mapso.
3. **vfs read path** -- turn the open/read/fstat ENOSYS stubs into a real ramfs
   vnode read so a proc can open+read a file; lazy FP save (FS=Off until first
   FP use); kmem_cache magazines/per-CPU depot.
4. **COW fork + demand paging** -- copy-on-write fork (vs the R-P26 eager AS
   deep-copy) with a page-fault handler that lazily maps + copies; a proper
   seg/anon layer over `hat_as_free`.

---

## R-P32 -- the real proc_t dispatcher on BOTH harts + copy-on-write fork + demand paging + vfs write(2) over a real vnode layer

R-P32 grows the R-P31 true-SMP high-half kernel along the memory-management +
SMP-process axis.  Built with the native `riscv64-unknown-solaris2.11` toolchain
(R-P17 binutils + the R-P19 gcc), booted under `qemu-system-riscv64 -machine
virt -smp 2` with OpenSBI.  `rp32/kernel/build-kernel.sh` rebuilds the userland +
ld.so.1 + initramfs + kernel + reboot; the three R-P32 sub-tasks + the
R-P24/26/27/28/29/30/31 regressions are asserted from the boot log.

### R-P32.1 -- procs on BOTH harts (the real proc_t dispatcher, SMP)

R-P31 ran secondaries on the identity-free W^X root draining a *work-item* runq;
R-P30's TS/RT class scheduler ran *compute slices* on two harts.  R-P32 runs the
REAL `proc_t` dispatcher on BOTH harts:

  - `rv_sched` becomes `rv_sched_cpu(int cpu)` and runs on hart 0 AND hart 1
    concurrently against ONE shared runq (`proc_tab`), serialized by a spinlock
    (`sched_lock`, an `amoswap.w` test-and-set).  The running proc
    (`cpu_cur[NCPU]`) and the scheduler context (`cpu_sched_ctx[NCPU]`) are
    PER-HART; the round-robin cursor is shared under the lock.
  - `cpuid()` reads the hartid from `tp`.  `tp` is set at kernel entry
    (`_start_high` for the boot hart, `proc_ap_high` for the secondary) and --
    critically -- RESTORED on every trap entry: a U-mode proc clobbers `tp`, so
    `rv_user_frame_ret`/`rv_user_enter` pack the hartid into bit 0 of the
    16-aligned kernel-stack top when writing `sscratch`, and `_u_trap_entry`
    recovers `tp = sscratch & 1` on the way in.  This makes `curproc` correct in
    the syscall/fault handler on either hart.
  - a first process (`smproc`) forks N children; the boot hart brings up the
    secondary at `proc_ap_entry` -> `proc_secondary_main` -> `rv_sched_cpu(1)`,
    and BOTH harts drain the shared runq.  A child forked on hart 0 is
    dispatched on hart 1 (each child prints its `p_hart` via `SYS_gethartid`).
  - the SMP save/load race (a peer hart picking a proc whose context is still
    being saved by `rv_swtch`) is closed with a per-proc `p_onproc` flag: a proc
    going off-cpu (sched/yield/exit) is marked `p_onproc=1` and is not pickable
    (or reapable) until the dispatching hart has fully switched it off and
    cleared the flag; a freshly-created proc is `p_onproc=1` until its context
    is seeded.  The kmem heap + page-frame allocators and `sbi_console_puts` are
    spinlock-serialized for concurrent access from two harts.

Boot proof: `procs dispatched: hart0=.../hart1=...` (both > 0), children
`running on hart 1`, `procs-on-both-harts PROVEN`.

CRIB: illumos `uts/common/disp/disp.c` `disp()` + the `cpu_t` per-CPU dispatch
model (a shared dispatch queue drained by every CPU, `disp_lock` around the
pick + the onproc transition, `cpu_thread` per CPU); the `tp`-holds-hartid /
per-CPU-pointer convention is Linux riscv `__my_cpu_offset` + xv6-riscv
`tp=hartid`; the `p_onproc` still-switching guard is the xv6-riscv `p->lock`
held-across-swtch invariant reduced to a flag; the amoswap.w spinlock is the
RISC-V A extension.

### R-P32.2 -- copy-on-write fork + demand paging (the headline)

R-P26 fork COPIED the whole parent AS eagerly.  R-P32 makes it copy-on-write +
adds demand paging, driven by the RISC-V page-fault handler:

  - two software PTE bits from the Sv39 RSW field ([9:8]): `PTE_COW` (bit 8) and
    `PTE_LAZY` (bit 9).
  - `hat_user_cow_share` (fork): for every private user leaf, SHARE the same
    physical frame into the child and, in BOTH parent and child, clear `PTE_W` +
    set `PTE_COW` (a writable OR already-COW leaf); bump a per-frame refcount
    (`page_ref_inc`).  A genuinely read-only leaf is shared as-is.  The live
    parent satp is flushed (its leaves went read-only).
  - the page-fault path: a store/load/instruction fault (scause 15/13/12) whose
    `stval` is a user VA routes `rv_trap` -> `proc_pagefault(stval, scause)`.
    This covers a fault taken in U-mode AND a fault taken in S-mode with SUM set
    (the kernel copying out to a COW page, e.g. `wait(2)` writing `*statusp`).
  - `hat_cow_fault`: a store to a `PTE_COW` leaf allocates a FRESH frame, copies
    the shared frame's bytes, remaps the VA writable with `PTE_COW` cleared, and
    drops one reference on the old shared frame (freed only when the last sharer
    lets go, via `page_ref_dec` inside `kmem_free_page`).  The child's write
    does NOT corrupt the parent.
  - `hat_user_lazy` reserves a `PTE_LAZY` leaf (V clear, perms in RSW); the first
    access faults into `hat_demand_fault`, which backs it with a fresh zeroed
    frame (`SYS_lazy`).

Boot proof: `[COW] store fault -> copied page va=... (pid ...)` +
`[demand] fault -> mapped zeroed page va=...`, the parent reads its page
`UNCHANGED (COW isolated the child's write)`, `COW copy faults=3 demand-page
faults=1`, `COW + demand paging PROVEN`.

CRIB: illumos `seg_vn` SEGVN_COW (`uts/common/vm/seg_vn.c` `segvn_dup` + the
`anon_dup`/`F_PROT` copy-on-write fault + `anon_zero` demand-zero `F_INVAL`) +
the `page_t` `p_cowcnt` refcount; BSD `pmap_copy_on_write`; xv6-riscv COW
(`uvmcopy` mapping parent+child RO with `PTE_COW`, `cowfault` copying in the
trap, per-page refcounts); the scause 12/13/15 exception codes are the RISC-V
privileged spec; `trap -> pagefault(addr,type) -> as_fault -> segvn_fault` is
illumos `uts/common/os/trap.c` + `vm/as.c` `as_fault`.

### R-P32.3 -- vfs write(2) + a real vnode layer

R-P31 had a read(2) path with the ramfs bytes stored directly in the fd.  R-P32
introduces a vnode op vector and a writable filesystem (`vfs.c`):

  - `struct vnode` dispatched through `vnodeops { vop_read, vop_write,
    vop_getattr }`; `fop_read`/`fop_write`/`fop_getattr` call `v_op->vop_*`, and
    `vfs_lookup` is the reduced `VOP_LOOKUP` that resolves a path to a vnode.
  - two fs types: the READ-ONLY ramfs (a transient vnode over the initramfs
    bytes; `VOP_WRITE` -> EROFS) and a WRITABLE tmpfs (a `kmem_alloc` buffer per
    file that GROWS on write, a flat name table of `/tmp/*` files created on
    first open-with-O_CREAT).
  - the per-proc fd table holds a vnode pointer + a byte offset; `proc_open`/
    `proc_openf` (O_CREAT), `proc_read`, `proc_write`, `proc_lseek`,
    `proc_fstat`, `proc_stat`, `proc_close_file` all route through the VOP_*
    layer.  `SYS_write` to fd 1/2 still goes to the console.

Boot proof: a process writes 35 bytes to `/tmp/hello.txt`, reads them back
(`tmpfs write/read round-trip: MATCH`), `fstat size=35`, and a write to the
read-only ramfs `/etc/release` returns `-30 (EROFS)`; `vfs write(2) PROVEN`.

CRIB: illumos `fs/vnode.c` `fop_read`/`fop_write`/`fop_lookup`/`fop_getattr` +
the `vnodeops` vector (`uts/common/sys/vnode.h`); the tmpfs (a writable in-RAM
file whose bytes ARE the file, grown on write) is illumos
`uts/common/fs/tmpfs/tmp_vnops.c` (`tmp_write`/`tmp_read`/`tmpnode`) reduced to a
flat kmem buffer per file; the per-proc fd table is `os/fio.c` (`falloc`/`getf`/
`ufalloc`); the ramfs-over-a-boot-archive read is illumos `boot_archive`.

### R-P32 files

`rp32/kernel/`: `proc.c` [SMP dispatcher `rv_sched_cpu`, per-hart `curproc`/
`sched_ctx`, `sched_lock`, `p_onproc`, `proc_pagefault`, `proc_secondary_main`/
`run_procs_smp`, `proc_gethartid`, the VOP_* file syscalls], `hat_user.c`
[`hat_user_cow_share`, `hat_cow_fault`, `hat_user_lazy`, `hat_demand_fault`],
`startup.c` [per-frame refcount `page_ref_*`, allocator + kmem_free_page locks],
`vfs.c` [the vnode layer + ramfs/tmpfs vnodeops], `main.c` [the page-fault route
in `rv_trap`, `SYS_lazy`/`SYS_gethartid`, `SYS_write`/`SYS_open` over the vnode
layer, `run_cowtest`/`run_procs_smp`/`run_vfstest` drivers], `mmu_riscv.h`
[`PTE_COW`/`PTE_LAZY`], `locore.S` [`tp=hartid`, `proc_ap_entry`/`proc_ap_high`],
`mach_uentry.S` + `mach_trap.S` [pack/restore the hartid in `sscratch`],
`sbi.c` [serialized console], `user_elf.S` [embed cowtest/smproc/vfstest],
`build-kernel.sh` [+ R-P32 asserts].  `rp32/user/`: `cowtest.c`, `smproc.c`,
`vfstest.c`, `build-user.sh`.  Proof: `rp32/rp32-milestone-check.sh` (all three
R-P32 sub-tasks + the R-P24/26/27/28/29/30/31 regressions green,
rebuild+reboot, re-runnable).

## R-P33 -- signals + kill(2) + pipe(2) + directories + per-CPU idle/wfi + file-backed demand-exec

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils + `qemu-system-riscv64 -machine virt -smp 2`
with OpenSBI v1.7.  R-P33 extends the R-P32 kernel (`rp33/kernel/`, a superset of
`rp32/kernel/`) with three sub-tasks, each boot-verified under qemu.  Proof:
`rp33/rp33-milestone-check.sh` (rebuild the userland + ld.so.1 + initramfs +
kernel + reboot; the three R-P33 sub-tasks + the R-P24 + R-P26 + R-P27 + R-P28 +
R-P29 + R-P30 + R-P31 + R-P32 regressions all green, re-runnable).

### R-P33.1 signals + kill(2) (the headline) -- DONE
- **A minimal signal framework with REAL delivery on return-to-U.**
  `rp33/kernel/{signal.c, proc.c, main.c, mach_trap.S}` + `rp33/user/sigtest.c`:
  - **signal.c** owns the delivery logic: a per-proc pending mask (`p_sigpend`) +
    a disposition table (`p_sighand[NSIG]`: 0=SIG_DFL, 1=SIG_IGN, else a user
    handler VA) + the `sa_restorer` VA (`p_sigrestorer`).  `proc_sigaction`
    installs a handler (SIGKILL cannot be caught); `proc_kill` (SYS_kill) posts a
    signal (an atomic OR into the target's `p_sigpend`, and if the target is
    blocked in `wait(2)` it is made RUNNABLE so it returns to U + delivers).
  - **Delivery** (`proc_deliver_signals`) runs at `mach_trap.S .Lret` -- the
    common trap-return path, so EVERY return to U-mode checks the running proc
    for a pending signal.  If a handler is installed it BUILDS A SIGNAL FRAME on
    the user stack (`struct sigframe` = a saved copy of the whole interrupted
    `struct regs` + a magic guard), then rewrites the trap frame so the epilogue
    `sret`s into the handler: `sepc`=handler, `a0`=signo, `sp`=the sigframe,
    `ra`=the userland `sa_restorer`.  One signal is delivered per U-trip.
  - **sigreturn** (`proc_sigreturn`, SYS_sigreturn) -- the handler `ret`s to the
    restorer stub (a naked `ecall SYS_sigreturn`), which copies the saved frame
    back into the trap frame so the proc resumes EXACTLY where the signal
    interrupted it (the saved sepc, sp, and every GPR restored).
  - **Default actions**: SIGKILL/SIGTERM/SIGSEGV/USR1/USR2 SIG_DFL -> terminate
    (`proc_exit(128+sig)`).  **SIGSEGV on an unhandled fault**: an unresolved
    U-mode page fault (`proc_pagefault` returns 0) now posts SIGSEGV to the proc
    (`proc_signal_fault`) instead of halting the kernel -- the default action
    terminates just that proc.  fork inherits the disposition table + restorer
    (POSIX) but starts with an empty pending mask.
- **Boot proof** (`-smp 2`):
  ```
    [sigtest][child] installed SIGUSR1 handler; waiting for the signal
    [sigtest][parent] kill(child, SIGUSR1)
      [signal] delivering sig 16 to pid 29 -> handler @0x00000000000103ca
    [sigtest][child] SIGUSR1 handler RAN (sig=16)
    [sigtest][child] resumed after the handler returned (sigreturn OK); exiting 0
    [sigtest][parent] reaped SIGUSR1 child status=0
    [sigtest][child2] spinning forever (only SIGKILL can stop me)
    [sigtest][parent] kill(child2, SIGKILL)
      [signal] sig 9 default action: terminate pid 30
    [sigtest][parent] reaped SIGKILL child2 status=137 (128+SIGKILL ...)
  [R-P33.1] signals + kill PROVEN ...
  ```
- **CRIB**: the per-proc pending mask + disposition table + "deliver on the way
  back to U-mode, build a frame on the user stack, redirect the saved PC to the
  handler, restore via a sigreturn syscall" model is illumos
  `uts/common/os/sig.c` (sigtoproc/issig/psig/sendsig) + the MD `sendsig()`
  building a ucontext on the user stack + `setcontext` on return; the sigframe-
  on-the-user-stack + `sret` to the catcher + sigreturn is the BSD/xv6-riscv
  usertrap signal path; the trap-frame rewrite (sepc/a0/sp/ra) is the RISC-V
  privileged-spec `sret` applied to the R-P25 `struct regs`.

### R-P33.2 pipe(2) + directories -- DONE
- **pipe(2): a kernel ring buffer with two fds + blocking read/write.**
  `rp33/kernel/proc.c` + `rp33/user/pipetest.c`:
  - `pipe_t` = a 512-byte ring buffer with read/write positions + reader/writer
    refcounts.  `proc_pipe` (SYS_pipe) allocates one + installs two fds (read
    end + write end) in the caller.  fork inherits the fd table + bumps the pipe
    refcounts (`pipe_incref`) so a parent + child share the SAME pipe; `close`
    drops a ref (`pipe_close`), freeing the pipe when both ends hit 0.
  - blocking read/write: a read on an empty buffer with writers still open BLOCKS
    (`pipe_block`: mark RUNNABLE + `rv_swtch` to the scheduler, re-check on wake)
    -- the R-P30 dispatcher runs the peer, which produces bytes; a write to a
    full buffer blocks likewise.  A read with no writers left returns 0 (EOF); a
    write with no readers returns EPIPE.  `proc_read`/`proc_write` route a pipe
    fd through `pipe_read_pub`/`pipe_write_pub` (direction-checked).
  - **Directories**: `vfs.c` gains a `VT_DIR` tmpfs vnode + `VOP_READDIR`
    (`dir_vnodeops`); `vfs_mkdir` (SYS_mkdir) creates a dir in the tmpfs table,
    `vfs_readdir` enumerates every tmpfs entry DIRECTLY under the dir path.
    `proc_openf` tags a dir fd; `proc_getdents` (SYS_getdents) reads one entry
    name per call via `VOP_READDIR`, advancing the fd offset.
- **Boot proof**: a parent writes 31 bytes + a fork-inherited child reads them
  through the pipe (`[child] read 31 bytes: 'hello from parent over the pipe'`);
  `mkdir(/tmp/d)` + two files + `readdir(/tmp/d)` lists 2 entries (`entry: one`,
  `entry: two`).
- **CRIB**: the fifofs/pipe ring buffer with reader/writer counts + blocking
  read/write that sleeps on the buffer + wakes the peer is illumos
  `uts/common/fs/fifofs/fifovnops.c` (fifo_read/fifo_write/fifo_wait) +
  `sys/pipe.h` + the xv6 pipe (pipewrite/piperead sleep/wakeup), reduced to a
  cooperative yield-and-recheck against the R-P30 scheduler; the `VT_DIR` +
  `VOP_READDIR`/`tmp_readdir` + `mkdir`/`getdents` dir path is illumos tmpfs
  `tmp_readdir`/`tmp_mkdir` + the `fop_readdir` vnode op, reduced to a prefix
  scan of the flat tmpfs name table.

### R-P33.3 per-CPU idle + wfi + file-backed demand-exec -- DONE
- **A hart with an empty runq parks in `wfi` (low power) instead of spinning.**
  `rp33/kernel/main.c` `run_idle_wfi`: with the free-running 100 Hz SBI timer as
  the tick source (re-armed + SIE set before idling), the hart enters an idle
  loop that `wfi`s between ticks; the STIP timer wakes it, `rv_interrupt` counts
  + re-arms.  Proof: `hart idled in wfi across 5 timer wakeups (tick 380 ->
  385)` -- the CPU slept in wfi (not spun) while the tick advanced.
- **File-backed demand-exec: page a PT_LOAD text segment in on the fetch fault.**
  `rp33/kernel/{exec_elf.c, proc.c, main.c}` + `rp33/user/dpexec.c`:
  - `exec_image_demand` loads an ELF like `exec_image` EXCEPT the first
    executable, non-writable, fully-file-backed PT_LOAD (the text) is mapped
    LAZY (`hat_user_lazy`: V clear + `PTE_LAZY` + R|X|U) instead of eager-copied,
    and its file backing (image base, seg VA, file offset, filesz, memsz) is
    recorded on the proc (`p_dimg`/`p_dva`/`p_doff`/`p_dfilesz`/`p_dmemsz`).
  - the first instruction fetch of an unbacked text page faults (scause 12)
    into `proc_pagefault`, which routes a fault inside the demand region to
    `exec_demand_fault`: allocate a frame, copy the corresponding file bytes
    from the ELF image (zero-fill the tail past filesz), map it R|X|U.  So the
    text is paged in from the "file" (the embedded ELF) ON DEMAND, vs the eager
    `exec_image` copy.  `proc_first_demand` builds the first proc this way.
- **Boot proof**: `[exec-demand] fault -> paged text from file va=0x10000
  (pid 33)` then `[dpexec] demand-paged text is executing` +
  `[dpexec] compute loop result=11990000 (text ran from demand-paged pages)`.
- **CRIB**: an idle thread that halts the CPU (`hlt`/`wfi`) when its runq is
  empty, woken by the timer/IPI, is illumos `uts/*/os/cpu_idle()`/`idle()` (the
  i86pc `mach_cpu_idle` -> i86_mwait/hlt, the sun4 `cpu_halt`) + the RISC-V `wfi`
  low-power hint (xv6-riscv scheduler `wfi` in the empty-runq branch, Linux
  arch/riscv `cpu_do_idle`); mmap'ing a file-backed PT_LOAD (seg_vn + a vnode +
  offset) and faulting each page in from the file on `F_INVAL` is illumos exec
  `mapelfexec` (VOP_MAP the text) + `segvn_fault`/`fop_getpage`, reduced to the
  embedded ELF bytes as the "file" + the R-P32 lazy-leaf demand-paging.

### R-P33 files

`rp33/kernel/`: `signal.c` [NEW -- the signal framework: `proc_sigaction`,
`proc_deliver_signals`, `proc_sigreturn`, `proc_signal_fault`, the sigframe],
`proc.c` [`p_sigpend`/`p_sighand`/`p_sigrestorer` + accessors + `proc_kill`; the
`pipe_t` ring buffer + `proc_pipe`/`pipe_read`/`pipe_write`/`pipe_close`/
`pipe_incref`; fork fd-table + signal-disposition inheritance; the dir syscalls
`proc_mkdir`/`proc_getdents`; `proc_first_demand` + the demand-exec route in
`proc_pagefault`; the `p_d*` demand region], `exec_elf.c` [`exec_image_demand`
(lazy file-backed text) + `exec_demand_fault`], `vfs.c` [`VT_DIR` + `VOP_READDIR`
(`dir_vnodeops`), `vfs_mkdir`, `vfs_readdir`, `vfs_isdir`, shared tmpfs name
slots], `mach_trap.S` [the `proc_deliver_signals` hook at `.Lret`], `main.c`
[SYS_kill/sigaction/sigreturn/pipe/mkdir/getdents + the SIGSEGV route in
`rv_trap`; `run_sigtest`/`run_pipetest`/`run_idle_wfi`/`run_dpexec` drivers],
`proc_riscv.h` [the `ud_*` demand-exec descriptor in `struct uproc`],
`user_elf.S` [embed sigtest/pipetest/dpexec], `build-kernel.sh` [+ signal.o + the
R-P33 asserts].  `rp33/user/`: `sigtest.c`, `pipetest.c`, `dpexec.c`,
`build-user.sh`.  Proof: `rp33/rp33-milestone-check.sh` (all three R-P33 sub-tasks
+ the R-P24..R-P32 regressions green, rebuild+reboot, re-runnable).

### R-P36 (next)

Directions: queued/real-time signals (`sigqueue`/`SA_SIGINFO` carrying a value,
not just a pending bit); a LIVE CONSOLE INPUT path (a real tty/UART read so
`/bin/sh` reads interactively from the console instead of only a scripted
`/etc/rc`, with line editing + a controlling terminal + process groups /
`setpgid` / job control); demand-paged file-backed segments for the DYNAMIC
exec path (ld.so.1 + libgcc_s mapped file-backed + demand-paged, not just the
static text); a real cwd (`chdir`/relative-path walk, `.`/`..` in `vfs_walk`),
`VOP_CREATE`/`VOP_REMOVE` proper directory-entry linkage, and a tmpfs that
stores directory entries in the dir vnode (vs the R-P34 flat name table + prefix
scan); `waitpid(pid, ...)` (vs the current wait-any); shell builtins (`cd`,
`export`), env/argv from the shell into `execve`'s envp, quoting + redirection
(`>`/`<`); and closing the latent SMP COW-vs-`wait` interaction seen after heavy
fork/exec churn (a store to an already-writable leaf spuriously faulting under
no-ASID TLB aliasing -- R-P35 runs the init/shell session EARLY, before the
churn, and adds a defensive stale-TLB flush+retry guard in `proc_pagefault`;
R-P36 should add per-AS ASIDs or a remote TLB shootdown on COW copy).

## R-P35 -- per-CPU idle + IPI wakeup + a real init(pid 1) + a minimal interactive shell (echo/cat/pipe)

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils + `qemu-system-riscv64 -machine virt -smp 2`
with OpenSBI v1.7.  R-P35 extends the R-P34 shell-ready kernel (`rp35/kernel/`,
a superset of `rp34/kernel/`) with three sub-tasks, each boot-verified under
qemu.  Proof: `rp35/rp35-milestone-check.sh` (rebuild the userland + ld.so.1 +
initramfs + kernel + reboot; the three R-P35 sub-tasks + the R-P24 + R-P26 +
R-P27 + R-P28 + R-P29 + R-P30 + R-P31 + R-P32 + R-P33 + R-P34 regressions all
green, re-runnable).  The R-P35 init + shell phases run EARLY (right after the
R-P26 multiprocess proof, `run_idle_ipi` + `run_init` in `main()`) in a clean
proc/frame state.

### R-P35.1 per-CPU idle + IPI wakeup (the enabler) -- DONE
- **idle thread in the dispatcher proper**: `rv_sched_cpu` (proc.c) tracks, per
  scan, whether any proc is RUNNABLE and whether any is BLOCKED (`P_WAITING`) or
  RUNNING on the peer hart.  When nothing is runnable on this hart but a blocked/
  peer-running proc exists, the hart sets `cpu_idling[cpu]` (under `sched_lock`),
  increments `cpu_idle_events[cpu]`, and parks in `wfi` -- vs the R-P34
  busy-poll.  On wake it re-scans; when NO proc is alive it returns.
- **real `P_WAITING` block for sigsuspend**: `proc_wait_signal` now marks the
  caller `P_WAITING` + `sched()`s (a real scheduler block) until a deliverable
  unmasked signal is pending, replacing the R-P34 wfi-poll on `p_sigpend`; it
  re-checks the pending set under `sched_lock` before blocking (closing the
  post-vs-block wake race).
- **SBI software IPI wake**: `proc_ipi_wake_others` (proc.c) posts an SBI
  software IPI (`sbi_send_ipi_hart`) to every peer hart on a runnable transition
  (`proc_kill`/`proc_kill_post`/`proc_alarm_tick`/`proc_exit`'s parent-wake) so a
  hart parked in `wfi` wakes + re-dispatches.  `rv_interrupt` decodes
  `SCAUSE_S_SOFTWARE` (cause 1) and clears `SSIP` (`csrci sip, 0x2`);
  `clock_enable_ssie` unmasks `SSIE` (`sie` bit 1) so `wfi` resumes on the IPI.
  The IPI is sent to ALL peers (not only observed-idle ones) so a peer in the
  lost-wakeup window (scanned empty, about to `wfi`, `cpu_idling` not yet set)
  still wakes -- and the free-running timer bounds any residual lost IPI to one
  tick.
- **Boot proof** (`run_idle_ipi`/`proc_run_idle_ipi`): bring up the secondary
  hart into the shared dispatcher, run the forker (fork a child + a REAL
  `wait(2)` block); a hart parks in the idle `wfi` (`idle-wfi parks: hart0=2
  hart1=1`) and the child exit IPI-wakes the blocked parent (`idle+IPI PROVEN`).
- CRIB PROVENANCE: `poke_cpu()`/`cpu_resched` sending a cross-call IPI to a
  halted CPU when a runnable thread lands on the dispatch queue is illumos
  `uts/common/disp/disp.c` `setbackdq`/`disp()` + the i86pc `mach_cpu_pause`;
  the `wfi`-on-empty-runq idle is the RISC-V privileged-spec `wfi` + xv6-riscv
  scheduler idle; the SBI IPI (EID "sPI", software interrupt) is the RISC-V SBI
  spec IPI extension.

### R-P35.2 a real init process (pid 1) (a headline) -- DONE
- **init as pid 1**: `run_init` calls `proc_reset_pids` (safe: the proc table
  is empty between phases) so the embedded `/sbin/init` is built as PID 1
  (`proc_first(init_elf_start)`).  init (`user/init.c`) prints its pid, spawns
  an orphan maker, opens `/etc/rc` + `dup2`s it onto fd 0, `fork`+`exec`s
  `/bin/sh`, then loops in `wait(2)` reaping every child until none remain.
- **orphan adoption/reaping**: `proc_exit` (proc.c) RE-PARENTS a dying proc's
  still-live children to `INIT_PID` (1) -- the classic Unix orphan adoption;
  init's `wait(2)` loop then reaps them.  The orphan maker forks a grandchild
  then exits at once; the grandchild is re-parented to init + reaped
  (`reaped pid 4 status 23`).
- **Boot proof**: `[init] pid 1 running`, `[init] forked shell pid 3`,
  `[orphan] grandchild (adopted by init) exiting`, `[init] reaped pid 4 status
  23` (the adopted orphan), `[init] reaped pid 3 status 0 (the shell)`, `[init]
  all children reaped; count 3. init done.`
- CRIB PROVENANCE: init(1M) as pid 1 forking the shell + looping in `wait(2)` to
  reap orphans is illumos `usr/src/cmd/init` + BSD `/sbin/init` + xv6
  `user/init.c` (`for(;;) wait()`); orphan re-parenting to init on `exit()` is
  the SVR4/illumos `os/exit.c` reparent-to-init.

### R-P35.3 a minimal interactive shell (/bin/sh) (a headline) -- DONE
- **read-line / parse-argv / fork-exec-wait**: `/bin/sh` (`user/sh.c`) reads its
  stdin (fd 0 = the `/etc/rc` script init `dup2`'d on) into a buffer, splits it
  into lines, tokenizes each into whitespace-separated argv (up to 8 args),
  resolves a bare command name under `/bin/`, and `fork`+`exec`+`wait`s it.
  Blank/`#`-comment lines + an `exit` builtin are handled.
- **argv passthrough across exec(2)**: `SYS_execve` now takes argv (a1);
  `proc_execv` stages the caller's argv strings into a kernel buffer
  (`exec_argv_reset`/`exec_argv_push`, read from the OLD AS before the switch)
  and `exec_image` (exec_elf.c) lays them onto the NEW program's initial stack
  (argc, argv[0..n-1], NULL, envp NULL, auxv) per the RISC-V psABI -- so
  `echo hello` reaches `/bin/echo` with real args (vs the R-P26..R-P34 fixed
  `argc=1, argv[0]="prog"`).
- **a pipeline (cmd1 | cmd2)**: on a single `|` the shell `pipe(2)`s, forks the
  left half (`dup2(fds[1],1)`, close both), forks the right half
  (`dup2(fds[0],0)`, close both), closes both ends in the parent, and `wait`s
  twice -- wiring left's stdout to right's stdin over the R-P33 pipe + R-P34
  `dup2`.  A supporting fix: `proc_exit` now CLOSES the exiting proc's open fds
  (dropping pipe refcounts) so a pipe write end held via `dup2` reaches refcount
  0 on exit and the reader sees EOF (else `cat` blocks forever).
- **the /bin commands**: `echo` (prints argv space-separated + newline), `cat`
  (copies each path arg, or stdin with no args, to stdout), `true` (exit 0) --
  static EM_RISCV programs in the ramfs, exec'd by the shell.
- **Boot proof**: `solnix sh: reading commands from stdin`; `sh$ echo hello` ->
  `hello`; `sh$ cat /etc/release` -> `solnix riscv64 (R-P31)` / `SunOS
  solnix-riscv64`; `sh$ echo hi | cat` -> `hi` (the pipe + dup2); `sh$ true`;
  `sh: end of script; exiting`.
- CRIB PROVENANCE: the read-line / parse-argv / fork-exec-wait loop + the
  "pipe + fork + dup2 the ends" pipeline is xv6 `user/sh.c` (EXEC/PIPE nodes) +
  the BSD/illumos `/bin/sh` execution model, reduced to one pipe stage +
  whitespace tokenizing; the argv-onto-the-new-stack copy is illumos
  `os/exec.c` `exec_args`/`stk_copyin`; `echo`/`cat`/`true` are the
  BSD/illumos `usr/src/cmd` idioms.


## R-P34 -- signal completeness (sigprocmask/sigsuspend/SA_RESTART/SIGCHLD/alarm) + fd management (dup/dup2/fcntl/FD_CLOEXEC) + VFS maturity (mount table + multi-level path walk + rename/unlink)

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils + `qemu-system-riscv64 -machine virt -smp 2`
with OpenSBI v1.7.  R-P34 extends the R-P33 full-Unix-core kernel
(`rp34/kernel/`, a superset of `rp33/kernel/`) with three sub-tasks, each
boot-verified under qemu.  Proof: `rp34/rp34-milestone-check.sh` (rebuild the
userland + ld.so.1 + initramfs + kernel + reboot; the three R-P34 sub-tasks +
the R-P24 + R-P26 + R-P27 + R-P28 + R-P29 + R-P30 + R-P31 + R-P32 + R-P33
regressions all green, re-runnable).

### R-P34.1 signal completeness (a headline) -- DONE
- **sigprocmask (block/unblock)**: a per-proc BLOCKED-signal mask
  (`proc_t.p_sigmask`).  `sigprocmask(how, set, oldp)` (SYS 238) with
  `SIG_BLOCK`/`SIG_UNBLOCK`/`SIG_SETMASK` edits it (`signal.c`
  `proc_sigprocmask`); SIGKILL is masked out (never blockable); `oldp` (a user
  VA, SUM set) receives the previous mask.  `proc_deliver_signals` now computes
  `pmask = p_sigpend & ~p_sigmask` -- a blocked pending signal is SKIPPED (stays
  pending) until unblocked, at which point it delivers on the next return-to-U.
- **sigsuspend**: `proc_sigsuspend(mask)` (SYS 239) atomically installs a
  temporary mask + blocks in `proc_wait_signal` (proc.c) until a pending,
  UNMASKED signal appears, then restores the caller's mask + returns EINTR.
  `proc_wait_signal` enables `sstatus.SIE` on the proc kernel context + `wfi`s
  polling `p_sigpend` (rather than P_WAITING + `sched()`), so the SBI timer
  stays live to fire `proc_alarm_tick` even when this is the ONLY proc (a
  P_WAITING block would deadlock -- the scheduler would spin with interrupts
  off).  A peer-hart `kill` also wakes the `wfi`.
- **SA_RESTART**: `sigaction` now carries `sa_flags` (a3); `p_sigflags[sig]`
  records `SA_RESTART`.  On delivery, if the interrupted frame's `a0` is `-4`
  (EINTR) and the caught signal is SA_RESTART, `proc_deliver_signals` rewinds
  the saved `sepc` by 4 (past the `ecall`) so the interrupted syscall RE-RUNS
  when the handler returns.  `sigsuspend` sets `p_no_restart` so it is NEVER
  restarted (POSIX carve-out), consumed by `proc_take_no_restart`.
- **SIGCHLD on child exit**: `proc_exit` posts `SIGCHLD` (18) to the parent's
  `p_sigpend` (atomic OR) + wakes a `wait`-blocked parent -- a parent can
  install a SIGCHLD handler + catch child deaths instead of only blocking in
  `wait`.
- **alarm(2)/SIGALRM**: `proc_alarm(secs)` (SYS 240) arms a per-proc one-shot
  deadline `p_alarm_deadline` (a `clock_ticks` count at HZ=100; 0 cancels) +
  returns the seconds left on the previous alarm.  `proc_alarm_tick` (called
  from `rv_interrupt` on every timer tick) posts `SIGALRM` (14) + clears the
  deadline of any proc whose alarm has passed (and wakes a blocked one).
- **Boot proof** (`rp34/kernel/qemu-boot.log`, `sigtest`): a proc blocks
  SIGUSR1 with `sigprocmask` + raises it (`SIGUSR1 stayed pending while
  blocked`), then unblocks it (`pending SIGUSR1 delivered on unblock`); a fork
  child exits and the parent's SIGCHLD handler runs (`SIGCHLD delivered on
  child exit`); `alarm(1)` fires SIGALRM (`SIGALRM delivered by alarm(2)`); and
  `sigsuspend` blocks until SIGALRM (`sigsuspend woke on SIGALRM`).
- CRIB PROVENANCE: illumos `uts/common/os/sig.c` (`sigprocmask`/`issig`
  skipping held signals, `sigtoproc`) + `sigsuspend`/`cv_wait_sig`;
  `os/timer.c`+`clock.c` (`it_real`/`realitexpire` -> SIGALRM off the tick);
  the SA_RESTART `sepc`-rewind is the RISC-V trap-frame analogue of the illumos
  `sysent` `SE_NOUNLOAD`/`ERESTART` restart + BSD `p_sigacts`/`SA_RESTART`.

### R-P34.2 fd management (a headline) -- DONE
- **dup(2)/dup2(2)**: `proc_dup(oldfd)` (SYS 241) installs the lowest free fd
  (>=3) as a second reference to the same open-file (vnode/pipe-end/offset;
  FD_CLOEXEC cleared -- POSIX); `proc_dup2(oldfd, newfd)` (SYS 242) redirects
  onto a CHOSEN fd (closing the target first), and can redirect a file onto a
  console fd (0/1/2) or restore a console fd (`dup2(2, 1)`) -- `proc_write`/
  `proc_read` now route fd 1/2 to a file when the slot is `f_used`, else to the
  console.  A dup'd pipe end bumps the pipe refcount.
- **fcntl(2)**: `proc_fcntl(fd, cmd, arg)` (SYS 243) with `F_DUPFD` (lowest free
  fd >= arg), `F_GETFD`/`F_SETFD` (read/set `FD_CLOEXEC`), `F_GETFL`/`F_SETFL`
  (reduced: 0/accept-ignore).
- **FD_CLOEXEC across exec**: the fd table gains `f_cloexec`; `do_exec` calls
  `proc_fd_cloexec` BEFORE the new image runs to close every close-on-exec fd
  (non-CLOEXEC fds survive into the new program).
- **Boot proof** (`fdtest` + `fdexecee`): `dup2` a file onto stdout, write
  through fd 1 (`dup2 redirected stdout to the file` -- the bytes are read back
  FROM THE FILE, proving the redirect), `fcntl(F_SETFD/F_GETFD)` sets+reads
  FD_CLOEXEC, then `exec fdexecee` with fd 9 CLOEXEC + fd 8 plain -- the new
  image finds fd 9 CLOSED + fd 8 open (`CLOEXEC-across-exec PROVEN`).
- CRIB PROVENANCE: illumos `uts/common/os/fio.c` (`fd_reserve`/`dupfd`,
  `fcntl` F_DUPFD/F_GETFD/F_SETFD, FD_CLOEXEC closed in `close_exec`) + the
  fifofs pipe refcount bump on dup.

### R-P34.3 VFS maturity -- DONE
- **mount table**: `vfs_mount(fstype, path)` (SYS 246) maps a mount-point path
  prefix to a fs type (VT_RAMFS/VT_TMPFS) in `mount_tab[]`; `vfs_mount_init`
  seeds "/"=ramfs + "/tmp"=tmpfs at boot; `mount_fstype(path)` returns the
  LONGEST-matching mount prefix's fs (so the tmpfs-vs-ramfs decision is now the
  mount table, not a hardcoded `/tmp/` test).
- **multi-level path walk (lookuppn)**: `vfs_walk(path, out, create)` walks a
  tmpfs path component-by-component from the root, validating that every
  INTERMEDIATE prefix (`/mnt`, `/mnt/sub`, ...) names an existing directory (a
  mount point or a `mkdir`'d tmpfs dir), rejecting a walk through a missing dir
  with ENOENT, then resolves the leaf via `vfs_lookup` over the leaf's fs.
  `proc_openf`/`proc_stat` route through `vfs_walk`.
- **rename/unlink**: `vfs_unlink(path)` (SYS 244) frees a tmpfs file's buffer +
  slot; `vfs_rename(from, to)` (SYS 245) rewrites the slot's name (replacing an
  existing target).
- **Boot proof** (`vfstest`): `mount tmpfs at /mnt: OK`; an open of
  `/mnt/sub/file` BEFORE `mkdir /mnt/sub` correctly ENOENTs (`walk rejects
  missing dir`); after `mkdir`, `walked /mnt/sub/file + read` returns the deep
  file's bytes (`multi-level path walk across a mount: OK`); `rename` makes the
  old name gone + the new name readable; `unlink` removes it.
- CRIB PROVENANCE: illumos `uts/common/fs/lookup.c` `lookuppnvp` (component
  walk crossing a mounted fs) + `vfs_t`/`vfssw` (the mount list keyed by
  `vfs_vnodecovered`) + `fs/tmpfs/tmp_vnops.c` (`tmp_lookup`/`tmp_remove`);
  reduced here to a prefix mount table + an intermediate-dir-existence walk +
  a flat tmpfs name table.

## R-P31 -- secondaries on the W^X root (drop the boot identity trampoline) + ld.so.1 hardening (lazy PLT + .gnu.hash + versioning + relro) + real ramfs read(2)

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils + `qemu-system-riscv64 -machine virt -smp 2`
with OpenSBI v1.7.  R-P31 extends the R-P30 true-high-half kernel
(`rp31/kernel/`, a superset of `rp30/kernel/`) with three sub-tasks, each
boot-verified under qemu.  Proof: `rp31/rp31-milestone-check.sh` (rebuild the
userland + ld.so.1 + initramfs + kernel + reboot; the three R-P31 sub-tasks +
the R-P24 + R-P26 + R-P27 + R-P28 + R-P29 + R-P30 regressions all green,
re-runnable).

### R-P31.1 secondaries on the W^X root (the headline) -- DONE
- **A secondary hart runs on the primary's identity-FREE W^X kernel root -- no
  identity map exists on ANY running root, on ANY hart, after boot.**
  `rp31/kernel/{locore.S, hat.c, hat_boot.c, smp_wxroot.c, sched_class.c,
  smp.c, disp.c}`:
  - **The gap R-P30 left**: R-P30 dropped the low identity map on the PRIMARY
    (the primary runs the W^X root, which has NO identity), but a secondary hart
    started at its PHYSICAL entry (paging off) and installed the identity-bearing
    BOOT root (`hat_boot_root_satp`) so its first post-satp fetch resolved; it
    then ran the shared kernel mappings FROM that boot root -- so the boot
    identity trampoline survived on the AP path.
  - **hat.c `hat_wxroot_satp`**: returns the satp value of the W^X kernel root
    (`MAKE_SATP(KVTOP(hat_kroot))`), for a secondary to switch onto once it runs
    at high VA.  The W^X root maps the kernel image (high, per-segment W^X) + the
    direct-map, but NO low identity.
  - **locore.S AP high continuations** (`_secondary_high`, `sc_ap_high`,
    `disp_ap_high`, and the new `wx_ap_entry`/`wx_ap_high`): the secondary starts
    at its PHYSICAL entry, installs the BOOT root (`a1`) so the initial satp flip
    survives, JUMPS to the high VA, then -- now that PC is high -- calls
    `hat_wxroot_satp()` (a high-VA C call on the direct-map) and switches to the
    W^X root (`csrw satp; sfence.vma`).  Because PC is already high and the W^X
    root maps the kernel image + direct-map, the fetch after the satp write
    resolves; from here the secondary runs with NO identity map, exactly like the
    primary.  (hartid `a0` is preserved in `s0` across the C call.)
  - **smp_wxroot.c `run_secondaries_wxroot` + `wx_secondary_main`**: the R-P31.1
    driver starts the secondary at `wx_ap_entry` (boot root = transient flip
    trampoline); the secondary switches to the W^X root and PROVES it -- its
    running satp equals the W^X root satp AND a read of the first kernel word
    through its LOW identity VA `0x80200000` FAULTS (the AP-only trap hook
    `hat_ap_ident_expect` in main.c `rv_trap` records it + steps sepc).  Both
    harts then drain a shared runq (SMP work still splits), and finally
    `hat_boot_drop_identity` SCRUBS the boot root's low identity gigapages so no
    identity map survives anywhere.  This phase runs LAST among the SMP phases
    (after `run_tsrt_sched`, which now `sbi_hart_stop`s its AP so this phase can
    restart it) because the scrub drops the transient trampoline the earlier
    AP-restart phases need.
- **Boot proof** (`rp31/kernel/qemu-boot.log`, `-smp 2`):
  ```
  [R-P31.1] secondaries on the W^X root: bring up a secondary hart + switch it onto the identity-FREE W^X kernel root
    [smp] boot hart 0 runs on the W^X root satp=0x800000000008036c
    [smp] W^X root satp=0x800000000008036c; starting secondary 1 at wx_ap_entry (boot root = transient flip trampoline)
    [R-P31.1] SECONDARY hart online: hartid=1
      running satp=0x800000000008036c == W^X root satp (identity-FREE root)
      read of _start via LOW identity VA 0x80200000: FAULTED -- secondary runs purely high-VA (no identity)
      [hart 1] ran work item 0 ... [hart 0] ran work item 7
    [smp] work items run: hart0=4 hart1=4
    [smp] boot-root identity window scrubbed (hat_boot_drop_identity) -- no identity map anywhere
  [R-P31.1] SECONDARY-ON-W^X-ROOT PROVEN: the secondary runs the identity-FREE W^X root (low identity read faults), no identity map anywhere, SMP work on 2 harts.
  ```
- **Scope (honest)**: the secondary switches onto the SHARED W^X root and runs a
  shared-runq work split (proving the AP-MMU-to-the-shared-kernel-hat + no-
  identity SHAPE).  The full proc_t `rv_sched` reentered concurrently on both
  harts (per-CPU curproc + a locked shared proc table across the USER dispatch
  path) is still R-P32; the R-P31 secondary drains a lock-protected work runq,
  not the user-proc dispatcher.  The initial satp flip still needs a transient
  identity (the physical PC must be mapped for the one instant between `csrw
  satp` and the jump-to-high) -- that is the boot-root trampoline, used only for
  that instant and then scrubbed; NO running root carries identity.
- **CRIB**: an AP enabling its MMU to the SHARED kernel hat (not a private
  identity root) is illumos `uts/i86pc/os/mp_startup.c` mp_startup (the secondary
  CPU switches to the kernel hat's page table before entering the dispatcher);
  switching from a transient trampoline root to the final identity-free root
  after the high jump is Linux `arch/riscv/kernel/head.S` secondary_start_sbi +
  relocate_enable_mmu (trampoline_pg_dir -> swapper_pg_dir); dropping the
  transient identity once every hart is at the final VA is the Linux setup_vm
  trampoline abandonment + the i86pc hat_kern_setup boot-identity drop; the
  shared runq + amoswap.w spinlock is the R-P28 smp.c model + the RISC-V A ext.

### R-P31.2 ld.so.1 hardening -- DONE
- **ld.so.1 gains lazy PLT binding, .gnu.hash, GNU symbol versioning, and
  mprotect of the relro segment after relocation.**  `rp31/ldso/{rtld_riscv.c,
  rtld_start.S}` + kernel `SYS_mprotect` (`proc.c hat_user_protect` /
  `hat_user.c`):
  - **Lazy PLT binding**: instead of eagerly resolving every PLT slot at startup,
    `plt_lazy_setup` arms the standard riscv lazy-binding contract -- `.got.plt[0]`
    <- the `_rtld_bind` trampoline (rtld_start.S), `.got.plt[1]` <- the app's
    `struct lobj *` -- and leaves each `.got.plt[2+N]` at its as-linked PLT0
    value.  The FIRST call to PLT entry N jumps into the PLT0 header, which loads
    the trampoline from GOT[0], the id from GOT[1], computes the reloc arg
    `(retaddr - PLT0 - 44) >> 1 == N*8` in `t1`, and jumps to `_rtld_bind`.  The
    trampoline saves a0..a7 + fa0..fa7 (the real args) + ra, calls
    `rtld_bind(id, N*8)` which resolves symbol N cross-object, patches
    `.got.plt[2+N]`, and returns the target address; the trampoline restores the
    args and tail-jumps to it.  The SECOND call finds the patched slot and jumps
    straight through -- so the bind fires exactly once, on first use.
  - **.gnu.hash**: `gnu_lookup` implements the gABI `.gnu.hash` lookup (bloom
    filter reject + the bucket/chain walk with the `hash|1` chain-end marker),
    with the SysV `.hash` bucket/chain as the fallback when `.gnu.hash` is absent.
  - **Symbol versioning**: `ver_string` reads `.gnu.version` (DT_VERSYM) for the
    dynsym index + walks `.gnu.version_r` (verneed) / `.gnu.version_d` (verdef)
    to the version STRING; `def_ver_ok` accepts a definition whose version
    matches the reference's (so `__multf3@GCC_3.0` binds to the like-versioned
    def).  The reference version is looked up per-reloc and passed through
    `sym_resolve`/`sym_lookup`.
  - **RELRO mprotect**: after relocation ld.so.1 finds the `PT_GNU_RELRO` segment
    and `SYS_mprotect`s it `PROT_READ` (read-only) -- the kernel `proc_mprotect`
    -> `hat_user_protect` clears `PTE_W` over the range + flushes the TLB.  So the
    now-relocated GOT/`.data.rel.ro` cannot be overwritten after startup.
  - The app's `DT_RELA` and `DT_JMPREL` coincide on these objects, so
    `apply_rela(app, ..., skip_jumpslot=1)` applies only the app's RELATIVE
    relocs and LEAVES the JUMP_SLOTs for lazy binding (a needed fix, else the
    JUMP_SLOTs were eagerly resolved via the coincident RELA table and the lazy
    path never fired).  NEEDED objects are still eagerly self-relocated.
- **Boot proof**: a dynamic `hellolazy` (linked lazy + `--hash-style=both` +
  `-z relro`) that calls `__multf3` in libgcc_s.so.1 twice:
  ```
  [ld.so.1] LAZY PLT armed (resolve-on-first-call); slots: 2
  [ld.so.1] symbol lookup: .gnu.hash (with SysV .hash fallback)
  [ld.so.1] symbol versioning: .gnu.version tables active (GNU verneed/verdef)
  [ld.so.1] RELRO: mprotect 0x0000000000011000 read-only (1 page(s))
    [hellolazy] FIRST cross-object call to __multf3 (fires the lazy bind)...
  [ld.so.1]   LAZY bind on first call: __multf3@GCC_3.0 -> 0x0000000038009b36
  [ld.so.1]   LAZY bind on first call: __fixtfsi@GCC_3.0 -> 0x000000003800b2cc
    [hellolazy] SECOND cross-object call to __multf3 (uses the patched GOT, no resolver)...
    [hellolazy] both cross-object calls correct (42 and 6) -- lazy binding works
  [R-P31.2] hellolazy exit status=42
  [R-P31.2] ld.so.1 hardening PROVEN: lazy PLT bound on first call (relro read-only, .gnu.hash + versioned lookup); exit 42.
  ```
  The first call fires the trampoline (the bind line) + patches the GOT; the
  second call prints no bind line (straight through the patched slot).
- **Scope (honest)**: lazy binding + .gnu.hash + versioning + relro are wired
  for the app's PLT against a flat loaded-object scope (app + NEEDED in order);
  the NEEDED objects are still bound eagerly at map time (only the APP's PLT is
  lazy).  ld.so.1 is still a static ET_EXEC entered by the kernel exec path (not
  yet a self-relocating ET_DYN), and NEEDED objects are still mapped by the
  kernel `SYS_mapso` (ld.so.1 does not yet mmap the file itself) -- R-P32.
- **CRIB**: the `.got.plt[0]=resolver`/`[1]=link-map` reserved-slot contract +
  the PLT0 header computing the reloc arg + the resolver trampoline saving arg
  regs + calling the C binder + jumping to the resolved address is the RISC-V
  psABI PLT layout + binutils `bfd/elfnn-riscv.c` riscv_make_plt0_entry + glibc
  `sysdeps/riscv/dl-machine.h` `_dl_runtime_resolve` / elf_machine_runtime_setup,
  the illumos analogue being ld.so.1 `elf_rtbndr`/`elf_plt_init`
  (`usr/src/cmd/sgs/rtld/...`); the `.gnu.hash` bloom+bucket+chain algorithm + the
  `.gnu.version`/verneed/verdef version match is the gABI + glibc
  `dl-lookup.c`/`_dl_check_map_versions`; mprotecting PT_GNU_RELRO read-only after
  relocation is the gABI relro contract + illumos ld.so.1 setup.c `_relro`.

### R-P31.3 real ramfs read(2) path + more syscalls -- DONE
- **A userland process opens + reads a ramfs file's contents through a real
  read(2) path, plus lseek/fstat/stat/getcwd/uname.**  `rp31/kernel/{proc.c,
  main.c, ramfs.c}` + `rp31/user/fsread.c`:
  - **proc.c** adds a per-proc open-file table (`proc_t.p_fd[NOFILE]`, each entry
    a reduced vnode: the ramfs byte range from `ramfs_lookup` + a read offset)
    and the file-op bodies: `proc_open` (resolve a path in the ramfs to an fd
    >=3), `proc_read` (copy from the fd's current offset into the user buffer,
    advancing the offset; EOF returns 0), `proc_lseek` (SEEK_SET/CUR/END),
    `proc_fstat`/`proc_stat` (report the size), `proc_close_file`,
    `proc_mprotect` (R-P31.2's relro backing).
  - **main.c `rv_syscall`** wires `SYS_read`/`SYS_open`/`SYS_close`/`SYS_lseek`/
    `SYS_fstat`/`SYS_stat`/`SYS_mprotect`/`SYS_getcwd`/`SYS_uname` (the R-P29
    ENOSYS stubs become real); `uname(2)` fills a reduced utsname with
    `SunOS`/`solnix-riscv64`/`5.11`/`solnix`/`riscv64`.
  - **fsread.c** (a new userland program, exec'd via `run_fsread`) opens
    `/etc/release`, stats it, reads its bytes and prints them, fstats the fd,
    lseeks back to 0 + re-reads the first byte, getcwd, and uname.
  - **build-kernel.sh** seeds `/etc/release` + `/bin/fsread` into the initramfs.
- **Boot proof**:
  ```
  [R-P31.3] ramfs read(2) path: a process opens + reads a ramfs file + uname(2)
    [fsread] open + read a ramfs file:
      stat(/etc/release) size=44 bytes
      opened /etc/release as fd=3
      contents: solnix riscv64 (R-P31)
  SunOS solnix-riscv64
      fstat fd size matches: yes
      lseek(0)+read first byte='s'
      getcwd()='/'
      uname sysname='SunOS' nodename='solnix-riscv64' machine='riscv64'
  [R-P31.3] ramfs read PROVEN: a process opened + read a ramfs file's contents; uname(2) returned SunOS/solnix-riscv64.
  ```
- **Scope (honest)**: the reduced vnode is the ramfs byte range + an offset (no
  page cache, no inode, no directory hierarchy, no write path); `getcwd` is a
  fixed `/` (no cwd tracking); the reduced stat/utsname buffers model only the
  fields the proof reads (st_size; the 5 fixed-width utsname strings).
- **CRIB**: the per-proc open-file table (fd -> file -> vnode + offset) is
  illumos `os/fio.c` (falloc/getf/ufalloc) + `fs/vnode.c`; open resolving a path
  then read doing uiomove out of the backing bytes advancing f_offset is
  `vn_open` -> VOP_LOOKUP + VOP_READ (`fop_read`) reduced to a memcpy over the
  ramfs range; lseek/fstat are `os/lseek.c` / VOP_GETATTR reduced to the length;
  `uname(2)` returning the utsname is illumos `os/uname.c` / `utsname` reduced to
  the SunOS identity strings.

### `/root/riscv-port/rp31/` contents
`kernel/{locore.S [+ wx_ap_entry/wx_ap_high + the W^X-root switch in every AP
high continuation], hat.c [+ hat_wxroot_satp], hat_boot.c [+ hat_boot_drop_identity],
smp_wxroot.c [NEW: run_secondaries_wxroot + wx_secondary_main], sched_class.c
[sc_secondary_main STOPs so R-P31.1 can restart the AP], smp.c/disp.c, hat_user.c
[+ hat_user_protect], proc.c [+ the fd table + proc_open/read/lseek/fstat/stat/
close/mprotect], main.c [+ the new syscalls + run_fsread + run_lazybind +
run_secondaries_wxroot + the AP-only identity-drop trap hook], ramfs.c, user_elf.S
[+ fsread/dynexec3 .incbin], build-kernel.sh [+ /etc/release + hellolazy in the
ramfs + the R-P31 assertions], kernel.lds, mmu_riscv.h, exec_elf.c, startup.c,
kmem_cache.c, plic.c, clock_riscv.c, mach_*.S, sbi.c/.h, *.o, *.bin, unix.elf,
qemu-boot.log}`; `ldso/{rtld_riscv.c [+ .gnu.hash + versioning + lazy setup +
rtld_bind + relro], rtld_start.S [+ _rtld_bind trampoline], build-ldso.sh,
ld.so.1.lds, ld.so.1}`; `user/{fsread.c [NEW], hellolazy.c [NEW], dynexec3.c
[NEW], build-user.sh [+ fsread/hellolazy/dynexec3], + the R-P30 programs}`;
`rp31-milestone-check.sh` (all three R-P31 sub-tasks + the R-P24 + R-P26 + R-P27
+ R-P28 + R-P29 + R-P30 regressions, rebuild+reboot, re-runnable green).
Repo copies under `src/riscv/rp31/{kernel/*, ldso/*, user/*,
rp31-milestone-check.sh}`.

### Next: R-P32
1. **Both harts in the real proc_t dispatcher** -- have BOTH harts reenter the
   real `rv_sched` (proc.c) concurrently on the W^X root: per-CPU `curproc` + a
   locked shared proc table + per-CPU idle contexts, so real user procs dispatch
   across two harts (vs the R-P31 shared-runq work split), completing true SMP
   user scheduling on the identity-free high-half kernel.
2. **Self-relocating ET_DYN ld.so.1 + ld.so.1 mmaps its own objects** -- rebuild
   ld.so.1 as an ET_DYN that self-relocates from AT_BASE (vs the static ET_EXEC),
   and have ld.so.1 mmap the NEEDED files itself (open+mmap the ramfs file) rather
   than the kernel `SYS_mapso`; recursive DT_NEEDED-of-a-NEEDED + a real
   breadth-first scope.
3. **vfs write + a real vnode layer** -- grow the ramfs read(2) path into a real
   vnode/VOP layer with a write(2) path (ramfs pages writable), directories +
   lookuppn, and a small dev/proc; cwd tracking for a real getcwd/chdir.
4. **COW fork + demand paging** -- copy-on-write fork (vs the R-P26 eager AS
   deep-copy) with a page-fault handler that lazily maps + copies; a proper
   seg/anon layer over `hat_as_free`.

---

## R-P28 -- real cross-object dynamic linking (ld.so.1 maps+binds DT_NEEDED) + priority dispatch queues + SMP secondaries via SBI HSM

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils (incl. the shared linker `ld-shared`) +
`qemu-system-riscv64 -machine virt -smp 2` with OpenSBI v1.7. R-P28 extends the
R-P27 preemptive-multiprocess kernel (`rp28/kernel/`, a superset of
`rp27/kernel/`) with three subsystems, each boot-verified under qemu -- real
cross-object dynamic linking, priority dispatch queues + `thread_create`, and
SMP secondaries via the SBI HSM extension. Proof:
`rp28/rp28-milestone-check.sh` (rebuild the userland + ld.so.1 + the initramfs +
the kernel + reboot; the three R-P28 sub-tasks + the R-P24 + R-P26 + R-P27
regressions all green, re-runnable).

Boot flow now: the R-P27 flow (R-P24 subsystems -> fork/exec/wait session ->
preemption -> fs-backed exec -> ld.so.1 hosts the R-P27 DYNAMIC hello) THEN
`run_xobject` (a DYNAMIC hello that CALLS a libgcc_s routine cross-object) ->
`run_priodisp` (three kernel threads at different priorities) -> `smp_start`
(bring up a secondary hart, both harts drain a shared runq) -> known halt.

### R-P28.1 ld.so.1 maps + binds DT_NEEDED -- real cross-object dynamic linking (the headline) -- DONE
- **ld.so.1 maps the app's `DT_NEEDED` object (libgcc_s.so.1) into the address
  space, processes its dynamic section, and BINDS the app's cross-object
  `R_RISCV_JUMP_SLOT` references to the symbols as defined in the loaded
  library; a DYNAMIC hello CALLS a libgcc_s routine across the object boundary
  and it works.** `rp28/ldso/rtld_riscv.c` + `rp28/kernel/exec_elf.c`
  (`exec_map_so`) + `rp28/user/hellodyn.c`:
  - The new **cross-object hello** (`hellodyn.c`) performs a 128-bit binary-
    float multiply (`long double`, TFmode) that GCC lowers to a call to
    `__multf3` (+ `__fixtfsi` for the cast) -- routines that live in
    libgcc_s.so.1, NOT in the executable (RV64GC has no hardware `_Float128`,
    so these are ALWAYS genuine libcalls, unlike a 64-bit divide or 128-bit
    integer multiply which RV64GC inlines). Linked with the shared linker
    (`ld-shared`) against `-lgcc_s` (no static libgcc.a), it is an ET_EXEC with
    `PT_INTERP=/usr/lib/ld.so.1`, `NEEDED libgcc_s.so.1`, and two
    `R_RISCV_JUMP_SLOT` relocs against UNDEF `.dynsym` entries (`__multf3`,
    `__fixtfsi`) whose GOT/PLT slots ld.so.1 must fill.
  - **ld.so.1** (`rtld_riscv.c`) walks the auxv, parses the app's
    `PT_DYNAMIC` (`STRTAB`/`SYMTAB`/`HASH`/`RELA`/`JMPREL`/`PLTRELSZ` +
    `DT_NEEDED`), and for each `DT_NEEDED` calls the kernel's new **`SYS_mapso`**
    syscall (a7=222) to map the object at a chosen base (`0x38000000`, in the
    same Sv39 L2 index-0 subtree as the app + stack), then parses THAT object's
    dynamic section (its own symtab/strtab/`.hash` + its `RELATIVE`/`JMPREL`
    self-relocs) and records it in a loaded-object list. It then applies the
    app's own `RELATIVE` relocs and **binds the app's PLT `JUMP_SLOT` relocs
    cross-object**: for each, `elf_hash(name)` -> walk `bucket[h%nbucket]` ->
    `chain[]` in each loaded object's `.hash` to find the DEFINED symbol, and
    write `base_of_defining_object + st_value` into the app's GOT slot at
    `r_offset` (EAGER binding; the PLT stub then jumps straight through the GOT
    slot to the real function).
  - **The kernel** (`exec_map_so`, `SYS_mapso`) resolves the object by name in
    the ramfs (bare soname searched along a reduced `/lib`:`/usr/lib` library
    path), checks it is an EM_RISCV ET_DYN, and maps its `PT_LOAD` segments
    biased by `base` (each at `base + p_vaddr`) into the calling proc's user
    root, writable so the linker can patch the GOT. `SYS_mapso` reaches the
    proc's `p_uroot` via `proc_curroot()`.
  - **User FP enabled**: the soft-float TF routines read the `frm` FP CSR, so
    the exec path now sets `sstatus.FS = Initial` in the user trap frame
    (`proc.c`) -- without it `__multf3` traps as an illegal instruction.
- **Boot proof** (`rp28/kernel/qemu-boot.log`):
  ```
  [ld.so.1] riscv64 runtime linker (R-P28: cross-object bind)
  [ld.so.1] DT_NEEDED: libgcc_s.so.1 -> mapping at 0x0000000038000000
  [ld.so.1]   bound __multf3 -> 0x0000000038009b36
  [ld.so.1]   bound __fixtfsi -> 0x000000003800b2cc
  [ld.so.1] cross-object PLT binds: 2
    [hellodyn] calling __multf3 in libgcc_s.so.1 across the object boundary...
    [hellodyn] __multf3 returned 42 -- cross-object bind OK
  [R-P28.1] cross-object hello _start ran + called a libgcc_s routine via ld.so.1; exit status=42
  [R-P28.1] cross-object bind PROVEN: __multf3 in libgcc_s.so.1 called + returned 42 across objects.
  ```
  The bound address `0x38009b36` == map base `0x38000000` + libgcc_s's
  `__multf3` `st_value 0x9b36` (matches its `.dynsym`); the hello's exit `42`
  (6.0L * 7.0L, cast to int) is positive proof the cross-object call executed
  and returned the correct value -- vs R-P27 where ld.so.1 only *reported*
  `DT_NEEDED` and bound nothing (its RELA table was empty).
- **Scope (honest)**: EAGER PLT binding (no lazy stub / no PLT0 resolver);
  SysV `.hash` lookup (no `.gnu.hash`); symbol versioning IGNORED (the plain
  `.dynstr` name is matched regardless of its `GCC_3.0` version -- correct here
  with a single definition); flat scope (app first, then each `DT_NEEDED` in
  order, no recursive NEEDED-of-a-NEEDED); the object is mapped by a kernel
  syscall (the real ld.so.1 `mmap`s the file itself); ld.so.1 is still a static
  ET_EXEC at a fixed base (not a self-relocating ET_DYN); the FP register file
  is not saved across context switches (the one FP proc runs alone). R-P29:
  lazy PLT, `.gnu.hash`, versioning, self-relocating ld.so.1, FP context switch.
- **CRIB**: mapping the `DT_NEEDED` objects, processing each object's dynamic
  section, and binding the caller's relocations against the loaded objects'
  symbol tables is `usr/src/cmd/sgs/rtld/common/setup.c` (load the primary + its
  dependencies) + `analyze.c` `load_so()`/`analyze_lmc()` + `_elf.c`
  `elf_bndr()`/`elf_reloc()` (PLT/GOT binding + symbol lookup) reduced to the
  riscv64 load-time types; the SysV `.hash` bucket/chain lookup is the SysV
  gABI; the `R_RISCV_JUMP_SLOT = S (+ A)` formula + the "GOT slot at `r_offset`
  gets the resolved symbol address, PLT stub jumps through it" model are the
  RISC-V psABI + the R-P23 reloc engine; mapping an ET_DYN's `PT_LOAD` segments
  at a chosen base is illumos `analyze.c` `elf_map_it`; the `sstatus.FS` enable
  is the RISC-V privileged spec FP-state field.

### R-P28.2 priority dispatch queues + thread_create -- DONE
- **The R-P27 flat round-robin runq becomes an illumos-style priority
  dispatcher, and `kthread_create` builds kernel threads scheduled in priority
  order.** `rp28/kernel/proc.c`:
  - `proc_t` gains `p_pri` (a small `NPRI=8` band scale, higher = sooner) +
    `p_kthread` (a kernel thread runs a C function in the kernel AS, no U-mode
    trap frame). `rv_sched` now (pass 1) finds the highest occupied RUNNABLE
    band + reaps parentless zombies, then (pass 2) ROUND-ROBINs within that top
    band from a `sched_last` cursor -- highest-priority-first, FIFO within a
    band. The round-robin-within-a-band is what keeps R-P27's preemption fair
    (two equal-priority CPU-bound procs still interleave).
  - `kthread_create(entry, pri)` allocates a proc, marks it a kernel thread,
    seeds its scheduler context so the first `rv_swtch` enters a trampoline
    that runs `entry()` (read from the proc's `p_kentry`, the illumos `t_pc`
    idiom) then `kthread_exit()` (mark ZOMBIE + yield forever; the scheduler
    reaps the parentless slot).
- **Boot proof**: three kernel threads created in LOW/HIGH/MID order run
  HIGH->MID->LOW (by priority, not creation order):
  ```
    [kthread] HIGH (pri 7) running
    [kthread] MID  (pri 4) running
    [kthread] LOW  (pri 1) running
  [R-P28.2] threads dispatched in priority order (HIGH pri 7, then MID pri 4, then LOW pri 1).
  ```
- **Scope (honest)**: a single global runq scanned by band (not per-CPU
  `disp_t` queues), a handful of priorities (not the 170 illumos global
  priorities / scheduling classes), no priority decay/boost, no kernel
  preemption of a running kthread (`kpreempt`). R-P29: per-CPU disp queues +
  scheduling classes + kpreempt.
- **CRIB**: "scan the dispatch queues highest-priority-first, run the first
  runnable thread, re-dispatch on yield" is illumos `uts/common/disp/disp.c`
  `disp()` + the `DISP_MAXRUNPRI` band walk; `thread_create()` building a
  kthread on a fresh stack with a seeded start context + a dispatch priority is
  `uts/common/disp/thread.c` `thread_create()` + the R-P24 `startup.c`
  `thread_init`/`swtch` seam.

### R-P28.3 SMP secondaries via SBI HSM -- procs on 2 harts -- DONE
- **The boot hart brings up a secondary hart with the SBI HSM `hart_start`
  ecall; both harts drain a shared, lock-protected runq -- work executes on TWO
  distinct hartids.** `rp28/kernel/{sbi.c, sbi.h, locore.S, smp.c}`:
  - `sbi_hart_start(hartid, addr, opaque)` (`sbi.c`) calls the SBI HSM
    extension (EID `"HSM"`=0x48534D, FID 0). `smp_start` (`smp.c`, on the boot
    hart) starts the other hart at `_secondary_start` with the shared kernel
    satp as the opaque arg.
  - `_secondary_start` (`locore.S`) is the AP entry: in S-mode, bare (physical
    == link addresses), `a0`=hartid/`a1`=opaque; it sets `gp`, a per-hart
    stack, masks interrupts, installs `stvec` (`_u_trap_entry`), switches to the
    shared kernel AS (`satp = a1`), and calls `secondary_main(hartid)`.
  - `secondary_main` reports the hartid online (proving a DISTINCT hart runs)
    and, alongside the boot hart, drains a shared work runq guarded by an
    `amoswap.w` test-and-set spinlock (`smp.c`).
- **Boot proof** (`-smp 2`):
  ```
    [smp] boot hartid=0; starting secondary hartid=1 at _secondary_start via SBI HSM
    [smp] SECONDARY hart online: hartid=1 (entered the shared scheduler)
      [hart 1] ran work item 0
      [hart 0] ran work item 1
      ... (items split across both harts) ...
    [smp] work items run: hart0=6 hart1=6
  [R-P28.3] SMP PROVEN: work ran on BOTH harts (two distinct hartids executed).
  ```
  Both hartid 0 and hartid 1 execute runq items -- procs (work) run on BOTH
  harts, vs R-P27's single hart.
- **Scope (honest)**: the secondary shares the boot kernel page table; the
  shared runq is a work-item queue drained under ONE global spinlock (a real
  shared *dispatch* queue of the priority procs from R-P28.2 is the next step --
  the per-hart `curproc`/`sched_ctx`/`sched_last` state in `rv_sched` is not yet
  per-CPU, so the SMP proof uses a dedicated lock-protected work queue rather
  than reentering `rv_sched` on both harts); no per-CPU areas / no IPIs / no
  TLB shootdown; the secondary parks after draining (the boot hart drives the
  known halt). R-P29: per-CPU `cpu_t` + per-CPU disp queues + IPIs so both harts
  run the priority scheduler concurrently.
- **CRIB**: the HSM `hart_start` ecall (EID 0x48534D, FID 0, args
  hartid/start_addr/opaque) + the STOPPED-hart AP-start model are the RISC-V
  SBI spec (Hart State Management); the AP entry that sets stack/pagetable/trap-
  vector then enters the dispatcher is illumos `mp_startup`/i86pc
  `mach_cpu_start` + BSD riscv `cpu_hatch`; the shared runq + a dispatch lock is
  the illumos `disp_lock`/`cpu_t` shared-dispatch model reduced to one runq +
  one spinlock; the `amoswap.w` test-and-set spinlock is the RISC-V A-extension
  + the illumos mutex/`lock_set` spin primitive.

### `/root/riscv-port/rp28/` contents
`kernel/{locore.S [+ `_secondary_start` + secondary stack], mach_trap.S,
mach_clock.S, mach_mmu.S, mach_swtch.S, mach_uentry.S, user_elf.S [+
dynexec2.bin], mmu_riscv.h, clock_riscv.h, plic.h, proc_riscv.h, assym.h,
sbi.h [+ sbi_hart_start], sbi.c [+ HSM], hat_boot.c, hat_user.c, exec_elf.c [+
exec_map_so/map_dyn_segments], ramfs.c, proc.c [+ priority disp +
kthread_create + FS-enable], clock_riscv.c, plic.c, smp.c [NEW: SMP], startup.c,
main.c [+ run_xobject/run_priodisp/smp_start], kernel.lds, build-kernel.sh,
*.bin, *.o, unix.elf, qemu-boot.log}`; `ldso/{rtld_start.S, rtld_riscv.c [+
cross-object map/bind], ld.so.1.lds, build-ldso.sh, ld.so.1, *.o}`;
`user/{forker.c, execee.c, preempt.c, fsexec.c, dynexec.c, dynexec2.c [NEW],
hellodyn.c [NEW: cross-object hello], mkinitramfs.py, build-user.sh, + built
ELFs/*.o}`; `hello/{hellodyn.dyn, hellodyn.o}`; `rp28-milestone-check.sh` (all
three sub-tasks + the R-P24 + R-P26 + R-P27 regressions, rebuild+reboot,
re-runnable green).

### Next: R-P29
1. **ld.so.1 hardening** -- lazy PLT binding (a real PLT0 resolver via a
   `SYS_bind` trap), `.gnu.hash`, symbol versioning (VERSYM/VERNEED), a
   self-relocating ET_DYN ld.so.1 at an arbitrary base, recursive `DT_NEEDED`,
   `mprotect`-after-reloc (drop the RWX on the loaded objects); ld.so.1 mmaps
   the file itself (`open`/`mmap`) instead of the `SYS_mapso` split.
2. **per-CPU dispatch + kpreempt** -- per-CPU `cpu_t` + per-CPU disp queues so
   BOTH harts run the R-P28.2 priority scheduler concurrently (not a separate
   work queue), IPIs, scheduling classes (TS/RT), kernel preemption points, and
   an FP context switch (lazy FS=Dirty save/restore, `fpu_save`/`fp_restore`).
3. **more syscalls + errno ABI + as_free** -- `open/read/close/brk/mmap`, the
   SunOS error-return convention, free the old AS on exec/exit (vs the current
   leak), per-lwp trap state, argv/envp passthrough.
4. **Full HAT** (carried) -- relocate kernel text/data into the high VA + drop
   the identity map + `hat_memload`/R^X kernel perms; vmem/`kmem_cache`; the
   page hash + freelists; TLB shootdown across harts.

---

## R-P27 -- timer-tick preemption + fs-backed exec (ramfs) + ld.so.1 hosting the first DYNAMIC process

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils + `qemu-system-riscv64 -machine virt` with
OpenSBI v1.7. R-P27 extends the R-P26 multiprocess kernel (`rp27/kernel/`, a
superset of `rp26/kernel/`) with preemptive scheduling, a minimal in-memory
filesystem + fs-backed exec, and a userland `ld.so.1` that hosts the R-P21
DYNAMIC hello. Proof: `rp27/rp27-milestone-check.sh` (rebuild the userland
programs + ld.so.1 + the initramfs + the kernel + reboot; the three R-P27
sub-tasks + the four R-P24 subsystems + the four R-P26 sub-tasks all green,
re-runnable).

Boot flow now: the R-P26 flow (R-P24 subsystems -> `run_user` forker
fork/exec/wait session) THEN `run_preempt` (free-running clock + a proc that
forks two CPU-bound children that interleave via preemption) -> `run_fsexec`
(dump the ramfs + a proc that execs `/bin/execee` by path) -> `run_dynamic`
(a proc that execs `/bin/hello`, whose `PT_INTERP` routes exec through the
ld.so.1 path) -> known halt.

### R-P27.1 timer-tick preemption -- two CPU-bound procs interleave -- DONE
- **The R-P24 100 Hz clock tick, made free-running, preempts the running proc
  so the cooperative R-P26 dispatcher becomes preemptive.**
  `rp27/kernel/{clock_riscv.c, main.c rv_interrupt, proc.c proc_yield}`:
  - `clock_run_forever()` (clock_riscv.c) flips the R-P24 finite boot-proof
    cadence (stop after `CLOCK_TEST_TICKS`) into a free-running tick and
    RE-UNMASKS `sie.STIE` (the R-P24 idle-loop phase masked it after the last
    tick) -- the preemption heartbeat.
  - `rv_interrupt()` (main.c), on a timer tick taken while a USER proc is
    running (`sstatus.SPP==0`: trapped from U-mode), calls `proc_preempt_tick`
    (raise `want_resched`) then `proc_yield` if pending. `proc_yield` (proc.c)
    puts the running proc back on the runq (`P_RUNNABLE`) and `rv_swtch`es to
    the scheduler; when the scheduler next picks the proc the swtch returns
    here, `rv_interrupt` returns, and the trap epilogue `sret`s the proc back
    exactly where the tick hit it. We defer the switch to the interrupt-return
    path (a flag), not switch inside the tick, the illumos `cpu_runrun` /
    xv6 yield-on-tick split.
- **Boot proof** (`rp27/kernel/qemu-boot.log`): a process forks two CPU-bound
  children (a long no-syscall compute spin between progress lines, NO
  cooperative yields); their output INTERLEAVES:
  ```
      [worker A pid=5] round 0
      [worker B pid=6] round 0
      [worker A pid=5] round 1
      [worker B pid=6] round 1
      ...
  ```
  Under the R-P26 cooperative dispatcher worker A would print all four rounds
  before B ever ran (A never yields); the interleaving proves the timer
  preempted A mid-spin to run B and vice-versa. The check counts A/B run
  transitions and requires >=2.
- **Scope (honest)**: round-robin only (no priorities / disp queues yet), the
  preemption point is the timer-interrupt return to U-mode (no kernel
  preemption / no `kpreempt`), one CPU. It proves preemption end to end;
  R-P28+ grows priority disp queues + `thread_create`.
- **CRIB**: the "tick raises a resched flag, the trap-return path calls yield()
  which sets the thread RUNNABLE + swtch()es to the scheduler, the interrupted
  frame resumes after the swtch-back" split is illumos `clock()`/`preempt()`/
  `cpu_runrun` + xv6-riscv `usertrap` yield-on-tick + `sched`/`swtch`; the
  free-running SBI-timer re-arm + STIE unmask is the RISC-V SBI spec + the
  R-P24 clock.

### R-P27.2 fs-backed exec + a minimal ramfs (initramfs) -- DONE
- **A minimal in-memory filesystem seeded from a linked-in initramfs archive
  backs `exec(path)`, which resolves the ELF by name -- replacing the R-P26
  embedded-per-program `.incbin` where exec ignored the path.**
  `rp27/kernel/{ramfs.c, user_elf.S}` + `rp27/user/mkinitramfs.py`:
  - `mkinitramfs.py` packs `(archive-path, host-file)` pairs into a flat
    `SOLRAMFS` archive (`magic`, then `{u32 namelen; u32 datalen; name; data;
    pad-to-8}` records, `namelen==0` terminator). build-kernel seeds it with
    `/bin/execee`, `/bin/fsexec`, `/bin/hello` (the DYNAMIC hello),
    `/usr/lib/ld.so.1`, `/lib/libgcc_s.so.1`; `user_elf.S` embeds the blob via
    `.incbin` (`initramfs_start`/`_end`).
  - `ramfs_lookup(path, &bytes, &len)` (ramfs.c) walks the archive for an
    exact-name match -- the reduced vfs `lookuppn` (no directories/inodes/
    mounts, just a flat records scan over the linked-in image). `proc_exec`
    (proc.c) resolves the `execve` path through it (falling back to the
    embedded execee for R-P26 back-compat).
- **Boot proof**: the ramfs is dumped (proving it is populated + walkable) and
  a process execs `/bin/execee` BY PATH:
  ```
    ramfs contents:
      /bin/execee  (2680 bytes)
      /bin/fsexec  (2600 bytes)
      /bin/hello  (3480 bytes)
      /usr/lib/ld.so.1  (9312 bytes)
      /lib/libgcc_s.so.1  (1153000 bytes)
    [fsexec] exec by absolute path: /bin/execee (via ramfs)
    [execee] NEW program image running after exec(2); pid=7
  ```
  The execee line reached via the string `/bin/execee` proves the path drove
  the lookup (vs R-P26's path-ignoring embedded exec).
- **Scope (honest)**: a flat archive (no directory hierarchy / no `open`/`read`
  syscalls / no writable fs), exact-name match, the whole image linked into
  `.rodata`. It is the fs-backed-exec enabler for ld.so.1; R-P28 grows
  `open/read/close/mmap` + a real vfs.
- **CRIB**: reading a name/size/bytes archive straight out of memory to resolve
  a boot path is the illumos `boot_archive` (the loader-handed root image) +
  Linux initramfs (newc cpio) reduced to a flat scan; exec-by-path over it is
  illumos `vfs` `lookuppn`/`vn_open` reduced to an exact-name match.

### R-P27.3 ld.so.1 hosts the DYNAMIC hello -- the first dynamically-linked process -- DONE
- **exec detects the app's `PT_INTERP`, loads BOTH the app and the userland
  `ld.so.1` into one AS, builds an auxv, and enters ld.so.1, which relocates
  the app + jumps to its `_start`.** `rp27/ldso/{rtld_start.S, rtld_riscv.c,
  ld.so.1.lds}` + `rp27/kernel/exec_elf.c exec_dynamic`:
  - `ld.so.1` is a static EM_RISCV ET_EXEC linked at `0x30000000` (above the
    app at `0x10000`, below the user stack at `0x40000000` -- no collision).
    `_rtld_start` (rtld_start.S) captures the psABI initial stack, calls
    `rtld_main(sp)`, then tail-jumps to the returned app entry with the stack
    intact (so the app crt sees argc/argv/envp/auxv per the psABI).
  - `rtld_main` (rtld_riscv.c) walks the auxv (`AT_PHDR`/`AT_PHENT`/`AT_PHNUM`/
    `AT_ENTRY`/`AT_BASE`), finds the app's `PT_DYNAMIC`, reports its
    `DT_NEEDED` (`libgcc_s.so.1`), and applies the app's `DT_RELA` table with
    the R-P23 riscv64 reloc engine (`elf_reloc_riscv`: `R_RISCV_RELATIVE` /
    `R_RISCV_JUMP_SLOT` / `R_RISCV_64`), then returns the app entry.
  - `exec_dynamic` (exec_elf.c), when `elf_has_interp` sees `PT_INTERP`,
    resolves the interp path (`/usr/lib/ld.so.1`) from the ramfs, maps the app
    and ld.so.1 (both ET_EXEC, own vaddrs) into a fresh user AS, builds the
    initial stack with the full auxv (`AT_PHDR`=the app phdr VA, `AT_ENTRY`=the
    app `_start`, `AT_BASE`=0), and sets the process entry to ld.so.1's entry.
    `do_exec`/`proc_exec` (proc.c) route any `PT_INTERP` image here.
- **Boot proof**: a process execs `/bin/hello` (the R-P21 DYNAMIC hello,
  INTERP=/usr/lib/ld.so.1, NEEDED=libgcc_s.so.1); the log shows the interpreter
  running, reporting the dependency, relocating, and jumping -- then the hello
  itself runs its `_start` -> `main` -> `exit(2)` (captured status 45):
  ```
    [dynexec] exec /bin/hello (DYNAMIC: INTERP=/usr/lib/ld.so.1)
  [ld.so.1] riscv64 runtime linker: hosting the DYNAMIC hello
  [ld.so.1] DT_NEEDED: libgcc_s.so.1
  [ld.so.1] relocations applied to the app: 0
  [ld.so.1] app relocated; jumping to its entry (_start)
  [R-P27.3] dynamic hello _start ran + called exit(2); status=45
  ```
  The captured exit status (`45`, the hello's argc-derived `main` return) is
  positive proof the hello's OWN code executed after ld.so.1 jumped -- not a
  coincidental trap (no fault appears in the log). This is the first
  DYNAMICALLY-LINKED riscv64-solaris process: the R-P21 dynamic hello + the
  R-P23 reduced rtld engine, now hosted by the R-P26/R-P27 kernel + fs exec.
- **Scope (honest, per the anti-wedge directive)**: ld.so.1 reads the auxv,
  parses `PT_DYNAMIC`, reports `DT_NEEDED`, and runs the relocate loop -- the
  real ld.so.1 shape -- but does NOT yet MAP the `DT_NEEDED` objects
  (`libgcc_s.so.1`) into the AS or bind cross-object symbols; the DYNAMIC hello
  binds no symbol from libgcc_s (its `DT_RELA` is empty), so no cross-object
  binding is needed to run it. ld.so.1 is a static ET_EXEC at a fixed base (not
  yet a self-relocating ET_DYN); the interp is loaded by the kernel exec path
  (not `mmap`ed by ld.so.1). libgcc_s.so.1 IS seeded in the ramfs so the
  R-P28 step (map + relocate + bind DT_NEEDED via `open`/`read`/`mmap`) has its
  input in place.
- **CRIB**: exec detecting `PT_INTERP`, mapping the interpreter, building the
  auxv (`AT_PHDR`/`AT_PHNUM`/`AT_PHENT`/`AT_ENTRY`/`AT_BASE`), and entering the
  interpreter is the illumos exec `elfexec`/`mapexec_interp` + BSD
  `exec_elf_imgact` interp handling; `_rtld_start` capturing sp + calling the C
  linker + tail-jumping to the executable entry is the illumos ld.so.1
  `rtld_start`/`_rt_boot`; walking `PT_DYNAMIC` for `DT_RELA`/`DT_RELASZ`/
  `DT_NEEDED` + the relocate loop are `usr/src/cmd/sgs/rtld/common/setup.c` +
  `_elf.c` reduced to the riscv64 load-time types; the reloc formulas are the
  R-P23 `rtld_riscv.c` + the RISC-V psABI; the auxv contents are the RISC-V
  psABI + `<sys/auxv.h>`.

### `/root/riscv-port/rp27/` contents
`kernel/{locore.S, mach_trap.S, mach_clock.S, mach_mmu.S, mach_swtch.S,
mach_uentry.S, user_elf.S, mmu_riscv.h, clock_riscv.h, plic.h, proc_riscv.h,
assym.h, sbi.h, sbi.c, hat_boot.c, hat_user.c, exec_elf.c, ramfs.c, proc.c,
clock_riscv.c, plic.c, startup.c, main.c, kernel.lds, build-kernel.sh,
forker.bin, execee.bin, preempt.bin, fsexec.bin, dynexec.bin, initramfs.bin,
*.o, unix.elf, qemu-boot.log}` (the grown kernel); `ldso/{rtld_start.S,
rtld_riscv.c, ld.so.1.lds, build-ldso.sh, ld.so.1, *.o}` (the userland
ld.so.1); `user/{forker.c, execee.c, preempt.c, fsexec.c, dynexec.c,
mkinitramfs.py, build-user.sh, + built ELFs/*.o}` (the userland programs);
`rp27-milestone-check.sh` (all three sub-tasks + the R-P24 + R-P26 regressions,
rebuild+reboot, re-runnable green). Repo copies under `src/riscv/rp27/`.

### Next: R-P28 (DELIVERED -- see the R-P28 section above)
1. **ld.so.1 maps + binds DT_NEEDED** -- give ld.so.1 `open`/`read`/`mmap`
   syscalls (or a ramfs read path), MAP `libgcc_s.so.1` into the AS, relocate
   it, and BIND the app's cross-object symbols (a real dynamic hello that
   CALLS a libgcc_s routine, vs the current no-cross-reloc hello); make ld.so.1
   a self-relocating ET_DYN loaded at an arbitrary base.
2. **priority disp queues + `thread_create`** -- grow the round-robin runq into
   priority dispatch queues + `setrun`/`thread_create`, and add kernel
   preemption points.
3. **more syscalls + errno ABI + as_free** -- `open/read/close/brk/mmap`, the
   SunOS error-return convention, free the old AS on exec/exit (vs the current
   leak), per-lwp trap state, argv/envp passthrough.
4. **Full HAT + SMP** (carried): relocate kernel text/data into the high VA +
   drop the identity map + `hat_memload`/R^X kernel perms; vmem/`kmem_cache`;
   the page hash + freelists; SMP secondaries via SBI HSM.

---

## R-P26 -- the first MULTIPROCESS riscv64-solaris kernel (proc/lwp table + fork/exec/wait + a runq dispatcher)

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils + `qemu-system-riscv64 -machine virt` with
OpenSBI v1.7. R-P26 extends the R-P25 single-user-process kernel
(`rp26/kernel/`, a superset of `rp25/kernel/`) with a process table,
fork/exec/wait, and a real dispatcher that schedules between process kernel
stacks. Proof: `rp26/rp26-milestone-check.sh` (rebuild the two userland
programs + the kernel + reboot; all four R-P26 sub-tasks + the four R-P24
subsystems green, re-runnable).

Boot flow now: the R-P24 flow (`hat_boot_init` Sv39 ON -> banner -> kmem/page ->
PLIC -> clock -> `dispatch_onramp` idle-loop round-trip) THEN `run_user`:
`proc_first(forker)` (build pid 1: a fresh user AS + a seeded kernel trap frame
+ scheduler context) -> `rv_sched` (the runq: `rv_swtch` into pid 1, which
forks; the child runs cooperatively, both print; the child exits, the parent
waits + reaps; then a fork+exec+wait of a second program) -> `rv_sched` returns
when no proc is left alive -> known halt.

### R-P26.1 proc/lwp table + real per-process context -- DONE
- **A minimal `proc_t` table with a per-process address space, kernel stack,
  and saved context, replacing R-P25's single-user-context assumption.**
  `rp26/kernel/{proc.c, proc_riscv.h}`: `proc_t` carries pid, state
  (`UNUSED`/`RUNNABLE`/`RUNNING`/`WAITING`/`ZOMBIE`), parent pid, the user Sv39
  root + satp (`p_uroot`/`p_usatp`), a per-process 16 KiB kernel stack
  (`p_kstack`/`p_kstack_top`, the `sscratch` value while in U-mode), a saved
  scheduler context (`struct rv_context` = callee-saved + ra/sp + satp for
  `rv_swtch`), a pointer to the proc's trap frame on its kernel stack (`p_tf`),
  and the exit status. `proc_alloc` hands out slots + pids; `proc_first` builds
  pid 1 from an embedded ELF: it `exec_image`s the program into a fresh user
  AS, seeds a `struct regs` trap frame at the top of the kernel stack
  (`sepc`=entry, `sp`=user sp, `sstatus` SPP=0|SPIE|SUM), and seeds the
  scheduler context so the first `rv_swtch` into it (`c_ra`=`rv_user_frame_ret`,
  `c_sp`=the frame, `c_satp`=the user satp) drops to U-mode at the entry.
- **Boot proof**: `[R-P26] proc table: building the first process (pid 1) from
  the embedded forker ELF`; the pids printed by the running processes
  (`my pid=1`, `my pid=2`, `pid=3`) are the proc table's assigned pids.
- **CRIB**: `proc_t` (pid, `p_stat`, `p_parent`, the AS, the kernel stack, the
  exit status) reduced from illumos `uts/common/sys/proc.h` `proc_t`/`kthread_t`/
  `klwp_t` + this repo's R-P5 `proc.c`; the "one lwp per proc, its context is
  the callee-saved set + ra/sp + satp" is the R-P5/R-P24 riscv `rv_context` +
  the RISC-V LP64 ABI; "seed a trap frame + a context so the first swtch enters
  U-mode" is the xv6-riscv `allocproc`/`forkret` idiom.

### R-P26.2 fork(2) -- a parent forks a child; BOTH run -- DONE
- **`SYS_fork` allocates a child, COPIES the parent's user AS, and duplicates
  the context so the child returns 0 while the parent returns the child pid.**
  `rp26/kernel/{proc.c do_fork, hat_user.c hat_user_copy, mach_trap.S
  rv_user_frame_ret}`: `do_fork` allocates a child proc, `hat_user_new`s a
  fresh user root (sharing the kernel high half), `hat_user_copy` DEEP-COPIES
  the parent's private user half (walks the level-2 index-0 subtree and
  duplicates every 4 KiB user leaf frame -- copy, not COW), copies the parent's
  trap frame onto the child kernel stack with `a0`=0, and seeds the child
  scheduler context (`c_ra`=`rv_user_frame_ret`, `c_sp`=the copied frame,
  `c_satp`=the child satp). When the scheduler `rv_swtch`es into the child it
  lands in `rv_user_frame_ret` (a global entry at the trap-return epilogue) with
  the child user satp installed, and `sret`s to U-mode at the instruction after
  the child's `fork` `ecall` -- returning 0. The parent gets the child pid in
  `a0` from `proc_fork`.
- **Boot proof**:
  ```
    [parent] forked child pid=2; my pid=1
    [child]  running; my pid=2
  ```
  Both processes run through the dispatcher and print DISTINCT output (their own
  pid) -- the multiprocess headline.
- **CRIB**: `cfork`/`forklwp` (copy the AS + duplicate the lwp so the child
  returns 0, the parent the child pid) is illumos `os/fork.c` + BSD
  `kern_fork`; the "copy the trapframe, set `a0`=0, seed `context.ra`=forkret,
  `swtch` into it" mechanism is xv6-riscv `fork`/`forkret`/`scheduler`/`swtch`;
  the AS deep-copy (walk the page tables, dup each user leaf) is illumos
  `hat_dup`/`as_dup` + BSD `pmap_copy` reduced to an eager leaf copy.

### R-P26.3 exec(2) from a process -- DONE (embedded ELF)
- **`SYS_execve` replaces the calling process's AS with a second embedded ELF
  and returns into the new program.** `rp26/kernel/proc.c do_exec` +
  `exec_elf.c exec_image` + `user_elf.S` (embeds both the forker and the
  `execee` target via `.incbin`): `do_exec` `exec_image`s the new program into
  a fresh user AS, rewrites the calling proc's trap frame (`sepc`=new entry,
  `sp`=new user stack, GPRs zeroed) + updates the scheduler context satp, and
  switches the LIVE `satp` (we are mid-syscall in the proc's context, and the
  trap-return epilogue `sret`s under whatever satp is current) so the syscall
  return drops into the NEW program image. The kernel stack + trap frame live
  in identity-mapped low DRAM that the new user AS also maps (shared kernel high
  half), so switching satp mid-kernel is safe.
- **Boot proof**: the exec child runs a DIFFERENT program that prints a line
  the forker never could:
  ```
    [child]  exec(2)ing a new program image...
    [execee] NEW program image running after exec(2); pid=3
  ```
- **Scope (honest)**: embedded ELF (no filesystem/`open`; the `path` argument is
  ignored -- the reduced exec always runs the embedded `execee`), no `as_free`
  of the old AS (leaks the old frames), no argv/envp passthrough. Toward the
  general `gexec`; R-P27 opens the ELF from a filesystem + hosts `ld.so.1`.
- **CRIB**: exec replacing the AS + rewriting the return frame is illumos
  `gexec`/`elfexec` + BSD `kern_exec`; the `exec_image` PT_LOAD walk is the
  R-P25 `exec_elf`; the "switch the live page table so the syscall return lands
  in the new image" is the illumos `exec` `mmu` handoff / xv6-riscv
  `exec`+`w_satp`.

### R-P26.4 wait(2)/exit rendezvous + the runq dispatcher -- DONE
- **The parent blocks in `wait(2)` until the child exits, then reaps it;
  scheduled by a real runq + a context switch between proc kernel stacks.**
  `rp26/kernel/{proc.c rv_sched/sched/proc_exit/proc_wait, mach_swtch.S
  rv_swtch}`: `rv_sched` (the scheduler loop, runs on the boot/kernel
  context+AS) scans the table for a RUNNABLE proc, marks it RUNNING, and
  `rv_swtch`es into it (loading its user satp); a proc yields back to the
  scheduler via `sched()` (`rv_swtch` its context into `sched_ctx`). `SYS_exit`
  (`proc_exit`) records the status, marks the proc ZOMBIE, wakes a WAITING
  parent (WAITING -> RUNNABLE), and yields FOREVER. `SYS_wait` (`proc_wait`)
  scans for a ZOMBIE child; if none yet it sets WAITING + yields, and on wake
  re-scans; when it finds one it reaps it (frees the kernel stack, clears the
  slot) and returns its pid + exit status through the user `status` pointer.
  This grows the R-P24 single-idle-`swtch` into an N-context cooperative
  dispatcher scheduling between process kernel stacks.
- **Boot proof**:
  ```
    [parent] wait(2) reaped pid=2 status=7
    ...
    [parent] wait(2) reaped exec-child pid=3 status=9
  ```
  The parent blocks, the child (or exec child) exits with a distinct status,
  the parent is woken + reaps it and prints the reaped pid + status -- the
  wait/exit rendezvous, proving the dispatcher schedules between the two procs.
- **Scope (honest, per the anti-wedge directive)**: COOPERATIVE scheduling
  (procs yield only at fork/wait/exit; the R-P24 100 Hz timer tick is the later
  preemption hook), a fixed `NPROC`=8 table, copy-not-COW fork, the reduced
  exec above, `wait` reaps ZOMBIE children of the caller only (no process
  groups / `waitid` idtype/options). It proves multiprocess + real scheduling
  end to end; R-P27 grows preemption + a real disp queue + `thread_create`.
- **CRIB**: the `waitid`/`exit` ZOMBIE rendezvous (parent blocks, child
  ZOMBIEs, parent reaps) is illumos `os/exit.c`/`os/wait.c` reduced to a
  parent/child reap + xv6-riscv `wait`/`exit`; the runq + `rv_swtch` between
  kernel stacks is the R-P24 dispatcher on-ramp (`mach_swtch.S`) grown to N
  contexts + the illumos `disp`/`swtch` seam + xv6-riscv `scheduler`/`sched`.

### `/root/riscv-port/rp26/` contents
`kernel/{locore.S, mach_trap.S, mach_clock.S, mach_mmu.S, mach_swtch.S,
mach_uentry.S, user_elf.S, mmu_riscv.h, clock_riscv.h, plic.h, proc_riscv.h,
assym.h, sbi.h, sbi.c, hat_boot.c, hat_user.c, exec_elf.c, proc.c,
clock_riscv.c, plic.c, startup.c, main.c, kernel.lds, build-kernel.sh,
forker.bin, execee.bin, *.o, unix.elf, qemu-boot.log}` (the grown kernel);
`user/{forker.c, execee.c, build-user.sh, forker, execee, *.o}` (the two
userland programs); `rp26-milestone-check.sh` (all four sub-tasks + the R-P24
regression, rebuild+reboot, re-runnable green). Repo copies under
`src/riscv/rp26/`.

### Next: R-P27
1. **fs-backed exec + `ld.so.1`** -- open the ELF from a filesystem (vs the
   embedded `.incbin`), honor the `execve` path argument + argv/envp, and host
   the R-P23.2 `ld.so.1` runtime-reloc engine for the DYNAMIC hello (interp +
   aux vector already scaffolded).
2. **preemption + a real disp queue** -- turn the R-P24 100 Hz timer tick into
   a preemption point (`setrun`/`swtch` off the tick), grow the cooperative
   runq into priority disp queues + `thread_create`, and add COW fork
   (`hat_user_copy` becomes copy-on-write with a page-fault handler).
3. **more syscalls + errno ABI + as_free** -- `open/read/close/brk/mmap`, the
   SunOS error-return convention, free the old AS on exec/exit (vs the current
   leak), and per-lwp trap state.
4. **Full HAT + SMP** (carried): relocate kernel text/data into the high VA +
   drop the identity map + `hat_memload`/R^X kernel perms; vmem/`kmem_cache`;
   the page hash + freelists; SMP secondaries via SBI HSM.

---

## R-P25 -- the kernel syscall/exec path so a userland PROCESS runs (U-mode entry + write/exit syscalls + a minimal static-ELF exec)

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils + `qemu-system-riscv64 -machine virt` with
OpenSBI v1.7. R-P25 extends the R-P24 native-toolchain booting kernel
(`rp25/kernel/`, a superset of `rp24/kernel/`) with the syscall/exec path and
runs the R-P22 static hello AS A PROCESS. Proof: `rp25/rp25-milestone-check.sh`
(rebuild the userland hello + the kernel + reboot; the three R-P25 sub-tasks +
the four R-P24 subsystems all green, re-runnable).

Boot flow now: the R-P24 flow (`hat_boot_init` Sv39 ON -> banner -> kmem/page ->
PLIC -> clock -> `dispatch_onramp` idle-loop round-trip) THEN
`run_user`: `exec_user` (build a user AS + map the embedded static ELF + a user
stack) -> `rv_ksetjmp` a kernel return point -> `rv_user_enter` (`sret` to
U-mode) -> the process runs its OWN `write(2)` then `exit(2)`, the `exit`
syscall `rv_klongjmp`s back into the kernel -> known halt.

### R-P25.1 U-mode entry + trap-based syscalls -- DONE
- **The kernel enters U-mode and services `ecall` syscalls from the userland
  process.** `rp25/kernel/{mach_uentry.S, mach_trap.S, main.c}`:
  - `rv_user_enter(struct uproc *)` (`mach_uentry.S`): install the user
    address space (`csrw satp` + `sfence.vma`), set `sscratch` = the lwp kernel
    trap stack top, program `sstatus` [clear `SPP` -> return to U, set `SPIE`
    so interrupts are enabled in U, set `SUM` so the kernel syscall handler may
    read/write the user buffer], set `sepc` = user `_start`, load the user
    `sp`, and `sret`.
  - **trap-from-U kernel-stack swap** (`_u_trap_entry`, `mach_uentry.S`, now the
    `stvec` landing pad): `csrrw sp, sscratch, sp` atomically swaps the user
    `sp` for the kernel trap-stack top when trapping from U (in the kernel
    `sscratch`==0, so a kernel trap swaps back and keeps its own `sp`), then
    falls into `rv_trap_dispatch`. The dispatcher stashes the swapped-out `sp`
    in the frame `R_SP` slot, resets `sscratch`=0 while in the kernel, and on
    the way out reloads the user `sp` + re-arms `sscratch` if returning to U
    (`sstatus.SPP`==0), keeps `sscratch`=0 if returning to S.
  - `rv_syscall(struct regs *)` (`main.c`): the illumos riscv64 ABI dispatcher
    -- `a7`=syscall number, `a0..a5`=args, result in `a0`. `SYS_write`(4) routes
    `buf[0..n)` to the SBI console and returns `n`; `SYS_exit`(1) records the
    status, restores the kernel `satp`, and `rv_klongjmp`s back to `run_user`.
  - `rv_ksetjmp`/`rv_klongjmp` (`mach_uentry.S`): a minimal `label_t` so the
    kernel enters U-mode and gets control back on `exit(2)` (the process does
    not "return").
- **Boot proof** (`rp25/kernel/qemu-boot.log`):
  ```
  [R-P25] sret -> U-mode; the process now runs and makes its OWN syscalls:
  ----- userland process output -----
  hello from riscv64-solaris userland process
  ----- end userland process output -----
  [R-P25] the userland process called exit(0); wrote 44 bytes via its own write(2). Kernel continues.
  ```
- **CRIB**: the `sscratch`-holds-kernel-stack-in-U / `csrrw` swap-on-trap /
  `sscratch`==0-in-kernel idiom is the RISC-V privileged-spec trap convention
  (xv6-riscv `usertrap`/`uservec`/`kernelvec`, BSD riscv `cpu_trap`); the
  `sret` to U with `SPP=0`+`SPIE`+`SUM`+`sepc`+user `sp` is the privileged spec
  `sret` semantics + the illumos `lwp_rtt`/exec user-return; the `a7`=nr /
  `a0..a5`=args / return-in-`a0` dispatch + `SYS_write=4`/`SYS_exit=1` are the
  illumos syscall trap (`os/syscall.c`) + the native `<sys/syscall.h>` (the
  same ABI the R-P22 `libc_syscall.s` emits); `rv_ksetjmp`/`rv_klongjmp` are the
  illumos `on_fault`/`label_t` idiom + the RISC-V LP64 callee-saved set.

### R-P25.2 the R-P22 static hello RUNS as a userland PROCESS -- DONE
- **The static hello runs in U-mode and makes its own syscalls -- the first
  riscv64-solaris userland process.** `rp25/user/{hello.c, build-user.sh}` +
  `rp25/kernel/{user_elf.S, main.c run_user}`:
  - `rp25/user/hello.c` is the R-P22.2b static hello given the R-P25 message,
    linked static with the R-P20 crt (`crt1/crti/crtn`) + the R-P22 minimal
    libc (`libc_syscall.o`: `write(2)`/`exit(2)` via `ecall`) into an EM_RISCV
    `ET_EXEC` (`hello_user`, entry `0x10160`, two PT_LOAD segments).
  - `user_elf.S` embeds that ELF in the kernel `.rodata` via `.incbin`
    (`user_elf_start`/`user_elf_end`) -- no filesystem needed to get the process
    bytes (the anti-wedge substrate).
  - `run_user()` (`main.c`) execs it into a fresh user AS, `rv_ksetjmp`s a
    kernel return, `rv_user_enter`s to U-mode; the process's `_start` reads
    `argc/argv/envp` off the initial stack, calls `main`, `write(1, msg, len)`
    [`ecall` -> kernel `rv_syscall` -> SBI console], returns, and `_start`
    calls `exit(0)` [`ecall` -> kernel -> `rv_klongjmp` back].
- **Boot proof**: the process's OWN `write(2)` output
  `hello from riscv64-solaris userland process` appears between the
  `----- userland process output -----` markers, then `exit(0)` and the kernel
  continues (see R-P25.1 log). The output is produced by the userland process's
  own `write(2)`, not the kernel.
- **CRIB**: embedding an init/user payload in the kernel image via `.incbin`
  (vs a root filesystem) is the classic linked-in-init bring-up idiom (Linux
  initramfs-in-kernel); the static hello + its `write/exit`-via-`ecall` libc is
  the R-P22.2b hello_static.

### R-P25.3 toward a real exec (map the static ELF PT_LOAD segments) -- DONE (reduced)
- **A minimal `exec` maps a static ELF into a fresh user AS + builds the aux
  vector.** `rp25/kernel/{exec_elf.c, hat_user.c, proc_riscv.h, startup.c}`:
  - `hat_user_new()` (`hat_user.c`) allocates a fresh Sv39 user root and copies
    the kernel high half (indices 1..511: the identity kernel-text gigapage for
    VA >=1 GiB + the direct-map) so a trap taken from U keeps the kernel mapped;
    index 0 (VA 0..1 GiB, where the static ELF links at `0x10000`) is left
    private for the user leaf subtree.
  - `hat_user_map(root, va, pa, perms)` walks/creates the level-1 + level-0
    tables and installs a 4 KiB leaf (`PTE_U` | R/W/X from the phdr flags |
    A|D). All page tables + user frames come from `kmem_alloc_page()`
    (`startup.c`) -- a PAGE-ALIGNED wrapper over the first-fit `kmem_alloc`
    (page tables and satp roots MUST be 4 KiB aligned; the first-fit heap only
    guarantees 16-byte alignment -- the alignment fix that made the user satp
    switch stop faulting).
  - `exec_user(struct uproc *)` (`exec_elf.c`) validates the ELF64 header
    (magic, EM_RISCV, ET_EXEC), walks the PT_LOAD program headers, maps + copies
    each segment (zeroing the `p_memsz > p_filesz` bss tail), maps a 16 KiB
    user stack just below `0x40000000`, builds the psABI initial stack
    (`argc`=1, `argv[0]`="hello", NULL, envp NULL, auxv `AT_PAGESZ`/`AT_ENTRY`/
    `AT_NULL`), allocates the lwp kernel trap stack, and returns `u_satp`/
    `u_entry`/`u_sp`/`u_kstack_top`.
- **Boot proof**:
  ```
  [R-P25] exec: loading the embedded static hello into a fresh user address space
    user entry VA     : 0x0000000000010160
    user sp (argv)    : 0x000000003fffffa0
    user satp         : 0x8000000000080233
  ```
- **Scope (honest, per the anti-wedge directive)**: REDUCED exec -- one static
  ELF embedded via `.incbin` (no filesystem/`open`), eager copy of the segments
  into kmem frames (no demand paging / COW), a fixed-size user stack, a minimal
  aux vector (`AT_PAGESZ`/`AT_ENTRY`/`AT_NULL`), a single lwp, `exit` unwinds via
  a `label_t` longjmp (no process table / `wait`). It is toward the general
  `gexec`/`elfexec`; R-P26 opens the ELF from a filesystem + hosts `ld.so.1` for
  the dynamic hello and adds fork/exec/wait.
- **CRIB**: the "walk the program headers, map+copy each PT_LOAD, zero the bss
  tail, set the entry, build the aux vector" shape is the illumos exec
  `mapelfexec`/`elfexec` + BSD `exec_elf64_imgact`; the initial-stack layout
  (argc, argv[], NULL, envp[], NULL, auxv[], AT_NULL) is the RISC-V psABI
  program-startup + the illumos `exec_args`; the "user AS = kernel high half
  shared + private user leaf tables" split is the illumos `hat`/`as_t` /
  i86pc kernel-vs-user hat separation; the 3-level Sv39 walk + PTE encoding are
  the RISC-V privileged spec.

### `/root/riscv-port/rp25/` contents
`kernel/{locore.S, mach_trap.S, mach_clock.S, mach_mmu.S, mach_swtch.S,
mach_uentry.S, user_elf.S, mmu_riscv.h, clock_riscv.h, plic.h, proc_riscv.h,
assym.h, sbi.h, sbi.c, hat_boot.c, hat_user.c, exec_elf.c, clock_riscv.c,
plic.c, startup.c, main.c, kernel.lds, build-kernel.sh, user_hello.bin, *.o,
unix.elf, qemu-boot.log}` (the grown kernel); `user/{hello.c, build-user.sh,
hello_user, *.o}` (the userland process); `rp25-milestone-check.sh` (all three
sub-tasks + the R-P24 regression, rebuild+reboot, re-runnable green). Repo
copies under `src/riscv/rp25/`.

---

## R-P23 — FIRST BOOTING illumos-riscv64 kernel (native toolchain) + reduced ld.so.1 reloc engine + real native ld

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` reports `riscv64-unknown-solaris2.11`) +
the R-P17 `riscv64-unknown-elf` binutils + the native OpenIndiana gcc 14.3.0
with libelf/gelf (for the native `ld` driver) + `qemu-system-riscv64` with
OpenSBI v1.7 (`/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin`). As in
R-P22 this host has only full-system `qemu-system-riscv64 -machine virt` (no
user-mode qemu, no `<nixpkgs>`), so everything that RUNS is an OpenSBI-booted
S-mode payload on the virt board. Proof: `rp23/rp23-milestone-check.sh` (all 3,
re-runnable green).

### R-P23.1 the FIRST BOOTING illumos-riscv64 kernel (the headline) — DONE
- **The illumos-MD kernel skeleton, built with the NATIVE solaris toolchain,
  boots under qemu + prints a SunOS banner via SBI.** `rp23/kernel/` -- the
  illumos startup sequence compiled by the `riscv64-unknown-solaris2.11` gcc +
  linked by the R-P17 binutils into an EM_RISCV ET_EXEC kernel ELF (entry
  `_start` @ 0x80200000, zero residual relocs), booted by OpenSBI on
  qemu-virt:
  - `locore.S` (`.text.start` `_start`): mask S-mode interrupts, set `gp`,
    claim the boot hart via `amoswap.w`, set `sp = boot_stack_top`, zero BSS,
    install the real trap vector (`stvec -> _trap_entry -> rv_trap_dispatch`),
    then `call mlsetup`.
  - `mach_trap.S` (`rv_trap_dispatch`): grown from the R-P22.3 demo dispatch
    into a CORRECT full-GPR save/restore trap prologue/epilogue (x1,x3..x31 +
    sepc/sstatus/scause/stval at the struct regs offsets) so a trap taken from
    C returns transparently; dispatches by scause (interrupt / ecall 8,9 /
    other synchronous).
  - `sbi.c` (LEGACY console putchar EID 0x01, correct from any stack; SRST
    shutdown) + `main.c` (`mlsetup(hartid, dtb)` records the boot cpu, PROVES
    the trap path with a deliberate S-mode `ebreak` -- OpenSBI delegates
    breakpoints to S-mode, so it lands in `rv_trap_dispatch -> rv_trap`, which
    sets a flag + steps `sepc` past the ebreak and `sret`s back -- then
    `main()` prints the SunOS banner + subsystem status + a clean SBI
    shutdown).
  - The R-P22.3 MD units (`mach_clock.S` `rv_clock_intr`, `mach_mmu.S`
    `rv_set_satp`/`rv_tlb_flush_all`/`rv_get_satp`) link into the image too
    (present kernel MD code, exercising the full MD reloc set in the kernel
    ELF).
  Boot output (`rp23/kernel/qemu-boot.log`):
  ```
  [mlsetup] illumos riscv64 MD bring-up (R-P23)
  [mlsetup] S-mode entry from OpenSBI: hartid=0 dtb=0x000000008fe00000
  [mlsetup] trap vector installed (stvec -> _trap_entry -> rv_trap_dispatch)
  [mlsetup] trap path self-test: PASS (deliberate breakpoint dispatched + resumed)

  SunOS Release 5.11 Version solnix-riscv64 (illumos on RISC-V, native toolchain)
  Copyright (c) solnix -- first booting illumos riscv64 kernel (R-P23)

  riscv64 kernel: mlsetup complete, entering main:
    boot hart id      : 0
    devicetree        : 0x000000008fe00000
    console path      : SBI legacy console (EID 0x01)
    trap online       : yes
    toolchain         : riscv64-unknown-solaris2.11 (native EM_RISCV kernel ELF)

  [R-P23] first booting illumos-riscv64 kernel: locore -> mlsetup -> banner reached.
  [R-P23] reached the known halt; SBI shutdown.
  ```
  This is the FIRST BOOTING illumos-riscv64 kernel: the illumos MD startup path
  (locore -> mlsetup -> main banner), built with the solnix native toolchain,
  executing on emulated riscv64 hardware -- vs R-P22's standalone hello (no
  kernel entry) and vs the R-P1..R-P16 `unix` (which boots, but was built with
  the earlier BSD-substrate toolchain, not the native solaris target).
- **Scope (honest)**: a boot SKELETON. It reaches mlsetup + banner + a proven
  trap path + a known halt -- the R-P23 milestone. It does NOT yet turn on
  Sv39 paging, the phys allocator, SMP, the periodic clock, PLIC/AIA, or the
  genunix seam (all present in the R-P1..R-P16 `unix`); porting those onto this
  native-toolchain skeleton is R-P24+.
- **CRIB**: the "mask ints, claim boot hart, set sp, clear BSS, install stvec,
  call mlsetup -> main banner" shape is this repo's R-P2..R-P16
  `src/riscv/uts/{locore.S,main.c,sbi.c}` + `uts/i86pc/ml/locore.s` mlsetup ->
  main + richlowe arm64-gate `uts/aarch64/ml/locore.s`; the full-GPR trap
  frame + scause dispatch is illumos amd64 `trap.S` + the R-P3 riscv `trap.S` +
  the R-P20 genassym offsets; the S-mode entry contract (0x80200000, a0=hartid/
  a1=dtb, satp=0), SBI legacy putchar/SRST, and the breakpoint-delegated
  trap-probe are the OpenSBI + qemu-virt + RISC-V SBI/privileged specs.

### R-P23.2 REDUCED riscv64 ld.so.1 runtime relocation engine — DONE
- `rp23/ldso/rtld_riscv.c`: the CORE of illumos `ld.so.1` for riscv64 --
  `elf_reloc_riscv()`, the exact inner switch of rtld's `elf_reloc()` for the
  riscv64 load-time reloc types: `R_RISCV_RELATIVE` (B+A: relocate an absolute
  pointer for the load base), `R_RISCV_JUMP_SLOT` (bind a PLT/GOT slot to the
  resolved symbol, done eagerly as under LD_BIND_NOW), `R_RISCV_64` (S+A). Runs
  as a freestanding S-mode payload under qemu-virt: relocates a synthetic
  object at a nonzero base, binds a GOT slot to a libgcc_s-shaped symbol, CALLS
  through it, and dereferences the RELATIVE-fixed pointer. Output
  (`rp23/ldso/qemu-ldso.log`): `R_RISCV_JUMP_SLOT: PASS (GOT slot bound +
  called through)` + `R_RISCV_RELATIVE: PASS (base+addend pointer relocated +
  dereferenced)`.
- **Scope (honest, per the anti-wedge directive)**: this is the REDUCED
  milestone -- the runtime reloc math, proven end to end -- NOT the full
  process-hosted `ld.so.1`. The DYNAMIC hello does not run yet because that
  needs the kernel exec/proc/syscall path (R-P24+), ld.so.1 self-reloc +
  segment mapping + the `_rt_boot.s`/`elf_rtbndr.s` MD asm, and real riscv64
  libc/libgcc_s shared objects on a root fs. The STATIC-hello path (R-P22.2b,
  no ld.so.1) stays the supported way to run a riscv64-solaris exe once the
  kernel syscall path is live. Full path documented in `rp23/ldso/README.md`.
- **CRIB**: the `elf_reloc()` RELATIVE/JUMP_SLOT formulas are illumos
  `usr/src/cmd/sgs/rtld/common/_elf.c` + the machine-specific `rtld/<mach>/`
  reloc code (amd64/sparc shape, riscv64 on the psABI); the `R_RISCV_*` numbers
  are `uts/common/sys/elf_riscv.h` + the RISC-V psABI; the SBI substrate is the
  R-P23 kernel `sbi.c`.

### R-P23.3 REAL native illumos `ld` (ldmin) links a real EM_RISCV object — DONE
- `rp23/gate-ld/ldmin.c`: a MINIMAL native `ld` driver that links a REAL
  EM_RISCV object through the sgs backend with NO GNU ld in the reloc path:
  (1) opens a real `.o` (assembled by the solaris toolchain) with libelf/gelf
  (libld's ELF access layer); (2) SELECTS the backend as the native ld does --
  `ld_config_target(EM_RISCV)` -> `ld_targ = ld_targ_riscv` (R-P22.1); (3)
  reads `.text` + `.rela.text` + symtab, builds the `libld` `Rel_desc[]`
  active-reloc descriptors, resolves each S; (4) drives the reloc THROUGH
  `ld_targ.t_mr.mr_do_activerelocs` (`machrel.riscv.c`); (5) emits the
  relocated `.text`.
- **Proof**: the same object linked by GNU ld at the same address diffs
  BYTE-IDENTICAL -- `auipc a5,%pcrel_hi(target)` -> `0x00000797`,
  `addi a5,a5,%pcrel_lo` -> `0x01078793`, resolving the pcrel pair to `target`
  at 0x80200010 exactly like GNU ld. The illumos backend performed the link.
- **Scope (honest)**: `ldmin` is the reloc-OUTPUT pass over one section, not
  the whole link-editor (no multi-object layout, cross-object symbol
  resolution, GOT/PLT section synthesis, dynamic section / phdr generation,
  mapfiles). It proves the part the R-P21/22 backend owns -- the riscv64 reloc
  math + backend dispatch -- runs against REAL toolchain output, not a
  synthetic image, matching GNU ld byte-for-byte. The full gate `ld` needs the
  `usr/src/cmd/sgs` tree (NOT on this host); the drop-in integration steps
  (add `machrel.riscv.c` + `ld_targ_init_riscv()` + `case EM_RISCV` +
  `libld/riscv64/` Makefile, `dmake install`) are in `rp23/gate-ld/README.md`.
- **CRIB**: the "select target by e_machine, walk SHT_RELA + symtab, build
  Rel_desc, run the backend's do_activerelocs" flow is illumos
  `usr/src/cmd/sgs/libld/common/{libld.c,relocate.c}` + `machrel.<mach>.c`;
  libelf/gelf is the illumos ELF access library; the `Rel_desc`/`Target`
  layout + the backend are the R-P21/22 sgs pieces.

### `/root/riscv-port/rp23/` contents
`kernel/{locore.S, mach_trap.S, mach_clock.S, mach_mmu.S, assym.h, sbi.c,
sbi.h, main.c, kernel.lds, build-kernel.sh, *.o, unix.elf, qemu-boot.log}`
(the BOOTING kernel); `ldso/{rtld_riscv.c, boot.S, sbi.c, sbi.h, virt.lds,
build-ldso.sh, README.md, *.o, ldso.elf, qemu-ldso.log}` (the reduced ld.so.1
reloc engine); `gate-ld/{ldmin.c, t_pcrel.s, build-gate-ld.sh, README.md, *.o,
ldmin, t_pcrel.o, {ldmin,gnu}.text.bin, gnu.elf}` (the native ld driver +
GNU-ld diff); `rp23-milestone-check.sh` (all 3, re-runnable green).
Repo copies under `src/riscv/rp23/`.

### Next: R-P24
1. **Grow the booting kernel toward genunix**: port onto the R-P23
   native-toolchain kernel skeleton the R-P1..R-P16 MD subsystems in order --
   Sv39 paging (`hat_boot_init` + the phys allocator), the periodic SBI-timer
   clock (the R-P22.3 `rv_clock_intr` is the MD half), PLIC/AIA external IRQ,
   SMP secondaries via SBI HSM, then the genunix seam (`startup()` ->
   page_t/kmem/callout/dispatcher). Boot each further under qemu-virt.
2. **riscv64 kernel syscall path so the STATIC hello RUNS as a process**: bring
   the exec/proc path online on the native-toolchain kernel (map the a.out,
   U-mode entry, the `write(2)`/`exit(2)` ecall serviced by `rv_syscall`), so
   the R-P22.2b static illumos-ABI hello runs as a real riscv64-solaris
   process. Then the exec/interp/aux-vector path lets `ld.so.1` (R-P23.2
   engine) host the DYNAMIC hello.
3. **Full gate `ld` + ld.so.1**: with the `usr/src/cmd/sgs` tree available,
   follow `rp23/gate-ld/README.md` to build a real `ld` ELF, and port the full
   `rtld/riscv64/` (wiring the R-P23.2 reloc engine in) per
   `rp23/ldso/README.md`.

---

## R-P22 — sgs ld_targ_riscv native selection + FIRST EXECUTING riscv64-solaris hello + larger MD partial-link

Substrate: fred v3 (root@52.88.62.49), the intact R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` reports `riscv64-unknown-solaris2.11`) +
the R-P17 `riscv64-unknown-elf` binutils + the native OpenIndiana gcc 14.3.0 (for
the linker-internal selection self-test) + `qemu-system-riscv64` 11.0.2 with
OpenSBI v1.7 (`/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin`). NOTE:
this host has only `qemu-system-riscv64` (full-system, `-machine virt`) -- there
is NO user-mode `qemu-riscv64` and no `<nixpkgs>`, so the RUNNING hello is a
freestanding S-mode payload booted by OpenSBI on the virt board (the
R-P2..R-P16 substrate), not a qemu-user run. Proof: `rp22/rp22-milestone-check.sh`
(all 3, re-runnable green).

### R-P22.1 sgs ld_targ_riscv native SELECTION (retires the GNU-ld crutch) — DONE
- `rp22/sgs/target.c`: the gate-shaped Target-dispatch layer that SELECTS the
  EM_RISCV backend. `ld_targ_init_riscv()` builds a file-static `Target`
  (`ld_targ_riscv`) whose `t_m` machine descriptor carries `m_mach = EM_RISCV`,
  ELFCLASS64/ELFDATA2LSB, the RV64 page/word align, and the dynamic reloc
  constants (`R_RISCV_RELATIVE`/`COPY`/`JUMP_SLOT`/`64`/`NONE`/`NUM`), and whose
  `t_mr` machrel sub-struct points its `mr_*` function pointers at the R-P21
  `machrel.riscv.c` entry points (`reloc_table`, `ld_reloc_local`,
  `ld_do_activerelocs`, `ld_assign_got_ndx`, `ld_riscv_finish_pcrel`).
  `ld_config_target(Half mach)` is the selection function the native ld calls
  once per link: `switch (mach) { case EM_RISCV: ld_targ = *ld_targ_init_riscv();
  return 1; default: return 0; }` -- exactly the gate `libld/common/target.c` +
  `machrel.<mach>.c` `ld_targ_init_<mach>()` convention.
- `rp22/sgs/target_shim.h`: the gate `Target`/`Target_mach`/`Target_machrel`
  structs + the single `extern Target ld_targ;` global, reproduced
  field-order-faithful to `usr/src/cmd/sgs/libld/common/_libld.h` (the gate is
  not on this host) so `target.c` is a drop-in.
- **Self-test** (`rp22/sgs/target_selftest.c`, compiled + linked against
  `machrel.riscv.c` WITHOUT `-DMACHREL_SELFTEST` + `target.c`): (1)
  `ld_config_target(EM_RISCV) == 1`, `ld_targ.t_m.m_mach == EM_RISCV`, the
  `mr_*` pointers all non-NULL; (2) `ld_config_target(EM_X86_64) == 0` and the
  installed RISC-V target is not clobbered; (3) a real %pcrel_hi/%pcrel_lo pair
  driven THROUGH `ld_targ.t_mr.mr_do_activerelocs` (not a direct call)
  reconstructs `S - P` **byte-identical to GNU ld** (`0x00001797`/`0x0a878793`,
  `S-P == 0x10a8`) -- i.e. the link is driven by the illumos backend, not GNU
  ld -- PASS.
- **Scope (honest)**: this retires the GNU-ld crutch at the
  SELECTION + reloc-DISPATCH level -- the linker's per-object backend choice
  now routes EM_RISCV objects through `machrel.riscv.c` via a gate-shaped
  `ld_targ`. The gate `usr/src/cmd/sgs` tree is NOT checked out on this host,
  so we cannot rebuild the actual `ld` ELF; `target.c`/`target_shim.h` are the
  gate-faithful drop-ins that will slot straight into a real sgs tree next to
  the amd64/sparc targets (add the `case EM_RISCV` to the gate's own
  `ld_config_target()`).
- **CRIB**: `ld_targ_init_<mach>()` + the `Target` struct + the single
  `ld_targ` global + `ld_config_target()`'s e_machine switch: illumos-gate
  `usr/src/cmd/sgs/libld/common/target.c` + `machrel.amd64.c`
  `ld_targ_init_x86_64()` / `machrel.sparc.c` `ld_targ_init_sparc()`; the
  RISC-V dynamic reloc constants + LP64D/RV64 machine params: the psABI +
  `uts/common/sys/elf_riscv.h`.

### R-P22.2 FIRST EXECUTING riscv64-solaris code (RUNS on qemu) + static illumos-ABI hello — DONE
- **The headline: a riscv64-solaris hello that RUNS.** `rp22/run/` -- a
  freestanding EM_RISCV S-mode payload built with the
  `riscv64-unknown-solaris2.11` gcc + the R-P17 binutils: `boot.S` (the OpenSBI
  FW_JUMP entry: mask sie, set `gp`, set `sp = __boot_stack_top`, zero BSS,
  `call kmain`), `kmain.c` (prints via SBI legacy console_putchar EID 0x01 then
  SBI SRST shutdown), `sbi.h` (the SBI ecall interface), `virt.lds` (link at
  the qemu-virt supervisor payload address `0x80200000`). Loaded with
  `qemu-system-riscv64 -machine virt -bios opensbi...fw_dynamic.bin -kernel
  hello.elf`; OpenSBI v1.7 hands off to `0x80200000` in S-mode and the payload
  **prints, then clean-shuts-down in ~1 s** (SRST works, no timeout hang):
  ```
  hello from riscv64-solaris (R-P22)
  first executing riscv64-solaris code
  ```
  This is the FIRST EXECUTING riscv64-solaris code -- our solaris-target
  toolchain's EM_RISCV output running on emulated riscv64 hardware. Run log:
  `rp22/run/qemu-run.log`.
- **STATIC illumos-ABI hello** (`rp22/hello/hello_static.c` + `rp22/libc/`):
  the R-P22 minimal libc -- `libc_syscall.s` provides `write(2)`/`exit(2)`/
  `_syscall()` in the illumos riscv64 syscall ABI (`a7 = SYS_nr`, args in
  `a0..a5`, `ecall`; `SYS_write == 4`, `SYS_exit == 1` from the native illumos
  `<sys/syscall.h>`), archived to `libc.a`. `hello_static.c` calls `write(1,
  msg, len)` then returns; linked STATIC with the R-P20 crt (`crt1/crti/crtn`)
  + `libc.a` -> an EM_RISCV ELF64 ET_EXEC with **NO dynamic section** (no
  `ld.so.1` needed), entry `_start`, zero relocs. `write` disassembles to
  `li a7,4; ecall`, `_exit` to `li a7,1; ecall`, and `main`'s auipc/addi pcrel
  pair to `msg` is resolved -- a complete self-contained static riscv64-solaris
  exe that will run the moment the riscv64 illumos kernel syscall path
  (R-P8/R-P9) is live under `qemu-system-riscv64`. (Sidesteps `ld.so.1` per the
  anti-wedge directive; the RUNNING milestone is met by the bare-metal hello
  above, which needs no libc + no runtime linker.)
- **CRIB**: the OpenSBI FW_JUMP payload contract (S-mode entry at 0x80200000,
  `a0=hartid`/`a1=fdt`) + the qemu-virt 0x80000000 DRAM base: OpenSBI +
  qemu-virt docs; the SBI legacy console_putchar (EID 0x01) + SRST (EID
  0x53525354) + legacy shutdown (EID 0x08) ecalls: the RISC-V SBI spec; the
  `a7=nr`/`ecall` syscall stubs + `SYS_write=4`/`SYS_exit=1`: the illumos
  riscv64 syscall ABI (same trap as the R-P20 `crt1.s exit(2)`) + the illumos
  libc `SYSCALL()` csu idiom; the crt link order: R-P20.

### R-P22.3 larger genassym-driven MD partial-link — DONE
- Added THREE new genassym-driven MD units to the R-P21 set, all using the
  generated `assym.h` `regs_r_*` offsets (not open-coded numbers):
  - `rp22/uts/mach_trap.S` (`rv_trap_dispatch`): the full trap prologue that
    saves the struct-regs frame and DISPATCHES by `scause` -- interrupt (sign
    bit) -> `rv_interrupt`, ecall (cause 8/9) -> `rv_syscall` (advancing
    `sepc` past the ecall), else -> `rv_trap`; restore + `sret`.
  - `rp22/uts/mach_clock.S` (`rv_clock_intr`): the SBI-timer bottom half --
    `rdtime` + a gp-relative load of `rv_clock_period` + an SBI `set_timer`
    ecall (EID `0x54494D45` "TIME") to reprogram the deadline, then `call
    clock`.
  - `rp22/uts/mach_mmu.S` (`rv_set_satp`/`rv_tlb_flush_all`/`rv_get_satp`): the
    MMU leaves -- `csrw satp; sfence.vma` root switch + the global TLB flush.
- **Partial link** (`ld -r`) of all SIX units (R-P21 `mach_locore.o`/
  `mach_swtch.o`/`mach_cpu.o` + the three new ones) -> one EM_RISCV ET_REL
  `unix_riscv64.o` carrying the full kernel reloc set: `CALL_PLT` x7,
  `PCREL_HI20`/`LO12` pairs, `BRANCH` x8, `RVC_BRANCH`/`RVC_JUMP`, `HI20`/
  `LO12_I`/`LO12_S`, `ADD32`/`SUB32`/`SET6`/`SUB6`, `32_PCREL`, `ALIGN`/`RELAX`
  -- exactly the relocs the R-P22.1-selected `machrel.riscv.c` backend resolves.
- **Full link** with `mach_externs22.o` (`rv_trap`/`rv_interrupt`/`rv_syscall`/
  `clock` + the R-P21 stubs): `ld -Ttext=0x10000 -e rv_trap_dispatch` resolves
  EVERY reloc -> EM_RISCV ET_EXEC, zero residual relocs; disassembly shows
  `rv_trap_dispatch`'s `jal rv_trap`/`jal rv_interrupt`/`jal rv_syscall` and
  `rv_clock_intr`'s `jal clock` all resolved.
- **CRIB**: the "save regs, decode scause, dispatch interrupt/syscall/trap C
  handlers, restore, sret" shape: illumos amd64 `trap.S` + the R-P3 riscv
  `trap.S`; the SBI `set_timer` (EID "TIME") + `rdtime`: the SBI + RISC-V
  unprivileged specs + the R-P6 clock slice; the `csrw satp; sfence.vma` root
  switch + `sfence.vma zero,zero` global flush: the RISC-V privileged spec +
  the R-P7 mmu slice; the genassym offset SOURCE (assym.h): the R-P21 unit +
  the illumos uts + BSD `genassym.cf` idiom.

### `/root/riscv-port/rp22/` contents
`sgs/{target.c, target_shim.h, target_selftest.c, _libld_shim.h, reloc_riscv.h,
riscv_pcrel_htab.h, machrel.riscv.c, machrel_riscv_insn.c, target_selftest}`;
`run/{boot.S, sbi.h, kmain.c, virt.lds, hello.elf, hello.bin, qemu-run.log}`
(the RUNNING bare-metal hello); `libc/{libc_syscall.s, libc.a}`;
`hello/{hello_static.c, hello_static, crt1.o, crti.o, crtn.o}` (the STATIC
illumos-ABI hello); `uts/{mach_trap.S, mach_clock.S, mach_mmu.S,
mach_externs22.c, assym.h, *.o, unix_riscv64.o, unix_riscv64.exec}`;
`rp22-milestone-check.sh` (all 3, re-runnable green).
Repo copies under `src/riscv/rp22/{sgs/{target.c, target_shim.h,
target_selftest.c}, run/{boot.S, sbi.h, kmain.c, virt.lds, qemu-run.log},
libc/libc_syscall.s, hello/hello_static.c, uts/{mach_trap.S, mach_clock.S,
mach_mmu.S, mach_externs22.c}, rp22-milestone-check.sh}`.

### Next: R-P23
1. **Drop the sgs backend into a REAL gate sgs tree**: check out
   `usr/src/cmd/sgs`, add `machrel.riscv.c` + the `ld_targ_riscv` Target to
   `libld/common/`, add the `case EM_RISCV` to the gate's own
   `ld_config_target()`, and rebuild the actual `ld` ELF so an EM_RISCV object
   links with the native illumos linker binary (not GNU ld, and not just the
   dispatch stub).
2. **riscv64 illumos kernel syscall path so the STATIC hello RUNS**: bring the
   R-P8/R-P9 syscall table + trap dispatch (the R-P22.3 `rv_trap_dispatch` is
   the MD half) far enough that a `write(2)`/`exit(2)` ecall from the static
   hello is serviced under `qemu-system-riscv64` -- the static illumos-ABI
   hello then RUNS as a real riscv64-solaris process (vs the bare-metal SBI
   hello, which bypasses the kernel).
3. **Link a still-larger `unix` toward a bootable EM_RISCV image**: add the
   remaining R-P1..R-P16 MD units (startup, real locore, mmu/hat, plic/aia,
   virtio) to the genassym-driven partial link toward a linkable/bootable
   riscv64 `unix`, and boot it on `qemu-system-riscv64 -machine virt`.

---

## R-P21 — gate sgs machrel.riscv.c (htab pairing) + libgcc_s.so.1 (dynamic hello) + bigger MD partial-link

Substrate: fred v3 (root@52.88.62.49), the intact R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>`) + R-P17 `riscv64-unknown-elf` binutils.
Crib sources on host: binutils-2.44 `bfd/elfnn-riscv.c` (pcrel pairing, PLT/GOT
layout) + `ld/` (emulation regen); illumos `/usr/gcc/*/lib/libgcc-unwind.map`
(version-script shape); the illumos sgs `machrel.amd64.c`/`machrel.sparc.c`
SHAPE (from knowledge -- gate not checked out on host) for the backend wiring.
Proof: `rp21/rp21-milestone-check.sh` (all 3, re-runnable green).

### R-P21.1 gate sgs machrel.riscv.c + real hash-table %pcrel pairing — DONE
- `rp21/sgs/machrel.riscv.c`: the R-P20 standalone pieces folded into ONE
  gate-shaped backend that compiles against a `_libld.h` shim
  (`rp21/sgs/_libld_shim.h`, field-order-faithful `Rel_desc`/`Rel_aux`/
  `Sym_desc`/`Sym_aux`/`Gotndx`/`Os_desc`/`Is_desc`/`Ofl_desc` trimmed to what
  the backend touches).  Four gate entry points, same names/roles as the
  amd64/sparc backends:
  - `ld_reloc_local()` -- per input reloc: classify via `reloc_table[]`, and if
    GOT/PLT assign the slot on the referenced `Sym_desc` (idempotent -- many
    refs share ONE slot) growing `ofl_gotcnt`/`ofl_pltcnt`;
  - `ld_assign_got_ndx()` -- find/assign a symbol's GOT slot per `Gotref`;
  - `ld_do_activerelocs()` -- the output pass: computes the RISC-V value
    (S+A, or S+A-P for PCREL) and routes flat data to a byte store, INSREL
    types to the field splice, and the %pcrel_hi/%pcrel_lo pair through the
    record-HI / defer-LO / resolve-by-HI-address model;
  - `ld_riscv_finish_pcrel()` -- resolves the deferred LOs.
- **HTAB upgrade (the R-P20 gate)**: `rp21/sgs/riscv_pcrel_htab.h` replaces the
  R-P20 O(n) list scan with a chained (open) hash table keyed by the auipc-site
  address -- power-of-two buckets, Knuth multiplicative hash, grow+rehash at
  ~0.75 load -- so a %pcrel_lo resolves O(1) even with thousands of pairs. The
  htab hangs off `Ofl_desc.ofl_riscv_pcrel` for the file being relocated.
- Self-test (`-DMACHREL_SELFTEST`): ld_reloc_local classifies + assigns
  idempotent GOT/PLT slots (2 GOT refs -> 1 slot, 2 CALL_PLT -> 1 entry;
  header-biased .plt/.got.plt offsets 32/16); ld_do_activerelocs drives a real
  `Rel_desc` set and the pcrel pair (through the htab, resolved in the finish
  pass) is **byte-identical to GNU ld** (`0x00001797`/`0x0a878793` for the
  R-P19.3 pair) reconstructing S-P; a dangling %pcrel_lo is rejected; the htab
  scales to 1000 pairs with O(1) lookup -- PASS.
- **CRIB**: `ld_reloc_local`/`ld_assign_got_ndx`/`ld_do_activerelocs`/
  `ld_perform_outreloc` SHAPE + the `Sym_desc`/`Gotndx`/`Rel_desc` field names
  from illumos-gate `usr/src/cmd/sgs/libld/common/machrel.amd64.c` +
  `machrel.sparc.c` + `include/_libld.h`; the pcrel pairing algorithm + PLT/GOT
  layout from binutils-2.44 `bfd/elfnn-riscv.c`; the RISC-V Calculation +
  immediate encodings from the psABI. (Gate not on host: the shim reproduces
  the gate structs so the backend is a drop-in for the real `_libld.h`.)

### R-P21.2 hand-linked shared libgcc_s.so.1 + first DYNAMIC hello — DONE
- The R-P20 long pole. gcc target libs are `--disable-shared` (only static
  `libgcc.a`, 138 objects). Instead of a full `--enable-shared` rebuild (needs
  a real libc for `SHLIB_LINK`), **hand-linked `libgcc_s.so.1` from `libgcc.a`
  + a GCC_3.0 version script** (`rp21/libgcc_s/libgcc_s.ver`, 214 exported
  symbols generated from the archive's defined symbols; crib: illumos
  `libgcc-unwind.map` + gcc `libgcc-std.ver.in`).
- **One binutils blocker fixed**: the R-P17 `riscv64-unknown-elf` binutils had
  `elf64lriscv` `config.has_shared = false` (bare-metal newlib leaves
  `GENERATE_SHLIB_SCRIPT` unset), so `ld -shared` errored `-shared not
  supported` (ld/lexsup.c:1365) with no `.xs` script. Regenerated ONLY that
  emulation (added `GENERATE_SHLIB_SCRIPT=yes`/`GENERATE_PIE_SCRIPT=yes` to the
  emulparams, re-ran genscripts, relinked just `ld-new`) -> `has_shared = true`
  + the shared/PIE ldscripts; installed as
  `toolchain/bin/riscv64-unknown-elf-ld-shared`. NOT a full binutils rebuild.
  Recipe in `rp21/libgcc_s/README.md`.
- `libgcc_s.so.1`: **EM_RISCV ELF64 ET_DYN**, SONAME `libgcc_s.so.1`, all 214
  symbols versioned `@@GCC_3.0` (`--allow-shlib-undefined` for the libc deps
  malloc/memcpy/memset/mprotect/... resolved from libc.so.1 at runtime).
- **Dynamic hello**: R-P20 hello.c + crt linked against `-lgcc_s` with
  `--dynamic-linker /usr/lib/ld.so.1` -> EM_RISCV, INTERP `/usr/lib/ld.so.1`,
  NEEDED `libgcc_s.so.1` -- the first DYNAMIC riscv64-solaris userland exe
  (R-P20 produced the first STATIC one).
- **CRIB**: version-script shape from illumos `/usr/gcc/*/lib/libgcc-unwind.map`
  + gcc `libgcc/libgcc-std.ver.in` (GCC_3.0 global / local *); the emulation
  regen args verbatim from `build/binutils/ld/Makefile` GENSCRIPTS.

### R-P21.3 bigger genassym-driven MD set -> EM_RISCV partial-link — DONE
- Replaced hand-maintained `.S` offsets with **genassym output**:
  `rp21/uts/riscv64/mach_swtch.S` (rv_swtch/rv_savectx: the R-P5 context switch,
  every `struct rv_context`/`label_t` field via the genassym `rv_context_c_*` /
  `LABEL_*` macros in `assym.h`, not `#define C_RA 0`) + `mach_locore.S`
  (rv_trap_entry: a trap prologue building a `struct regs` frame at the
  generated `regs_r_*` offsets). Both cross-assemble to EM_RISCV.
- **Partial link (`ld -r`)**: `mach_locore.o` + `mach_swtch.o` + `mach_cpu.o`
  (the R-P20 machdep slice) -> one **EM_RISCV ET_REL** `unix_riscv64.o`
  preserving the full kernel reloc set (CALL_PLT x3, PCREL_HI20/LO12 pairs,
  HI20/LO12, BRANCH/RVC_BRANCH, ADD32/SUB32/SET6/SUB6, 32_PCREL, RELAX/ALIGN)
  -- the milestone: a multi-object MD partial-link exercising exactly the
  relocs the R-P21.1 sgs backend resolves.
- **Full link** with `mach_externs.o` (rv_trap/rv_lofault/cpu_list/
  hart_online_mask stubs): `ld -Ttext=0x10000 -e rv_trap_entry` resolves EVERY
  reloc -> EM_RISCV ET_EXEC, zero relocs; disassembly shows `jal <rv_trap>`
  (CALL_PLT), the auipc/addi pcrel pair to `rv_lofault`, and `jal <rv_swtch>`
  all resolved.
- **CRIB**: the ASSYM/OFFSET mechanism from the R-P20 genassym unit + illumos
  `uts` genassym + BSD `sys/arch/riscv/riscv/genassym.cf`; the switch/trap-save
  bodies from the R-P3/R-P5 MD tree (RISC-V LP64 conv, NetBSD `cpu_switch.S`
  idiom); the "MD .S references C layout only through <assym.h>" discipline is
  standard illumos kernel build practice.

### `/root/riscv-port/rp21/` contents
`sgs/{_libld_shim.h, reloc_riscv.h, riscv_pcrel_htab.h, machrel.riscv.c,
machrel_riscv_insn.c (from rp20), machrel_selftest}`;
`libgcc_s/{libgcc_s.so.1, libgcc_s.so->.1, libgcc_s.ver, README.md}`;
`hello/{hello.o, crt{1,i,n}.o, hello.dyn}`;
`uts/riscv64/{genassym.c, genassym.sh, genassym.s, assym.h, mach_swtch.S,
mach_locore.S, mach_cpu.c, mach_externs.c, *.o, unix_riscv64.o,
unix_riscv64.exec, sys/*.h}`; `rp21-milestone-check.sh` (all 3, re-runnable).
Shared-capable linker installed as `toolchain/bin/riscv64-unknown-elf-ld-shared`.
Repo copies under `src/riscv/{sgs/{_libld_shim.h, reloc_riscv.h,
riscv_pcrel_htab.h, machrel.riscv.c}, libgcc_s/{libgcc_s.ver, README.md},
uts/riscv64/{mach_swtch.S, mach_locore.S, mach_externs.c, assym.h}}` +
`src/riscv/rp21-milestone-check.sh`.

### Next (from R-P21) -> delivered by R-P22
1. **Build the sgs backend inside a real (or stubbed) sgs tree** so `ld` selects
   `ld_targ_riscv` for EM_RISCV -- DONE R-P22.1 (gate-faithful `target.c`/
   `target_shim.h` stub: `ld_config_target(EM_RISCV)` selects `ld_targ_riscv`;
   the real gate-tree drop-in is R-P23.1).
2. **libc bring-up toward a self-hosting userland**: a minimal riscv64-solaris
   libc (crt + syscalls) -- DONE R-P22.2 (a static `write(2)`/`exit(2)` libc +
   the STATIC illumos-ABI hello; a bare-metal hello RUNS on qemu). Running it
   as a real process under a riscv64 illumos kernel + `ld.so.1` is R-P23.2.
3. **Grow the MD partial-link toward a linkable `unix`** -- DONE R-P22.3 (6-unit
   EM_RISCV `unix_riscv64.o`: locore/swtch/cpu/trap-dispatch/clock/mmu, full
   link resolves every reloc). A bootable `unix` image is R-P23.3.

---

## R-P20 — sgs %pcrel pairing + GOT/PLT alloc, csu crt + first hello ELF, larger uts unit

Substrate: fred v3 (root@52.88.62.49). The R-P19 install-time gcc `bin/` wrapper
was gone (only binutils symlinks + libgcc.a survived), but the R-P18/19 build
tree `build/gcc-sol-cfg3/gcc/xgcc` is intact and reports
`riscv64-unknown-solaris2.11`; drove it directly as `xgcc -B<gcc>` (no rebuild).
Crib source on host: binutils-2.44 `bfd/elfnn-riscv.c` (pcrel pairing + PLT/GOT
layout) and the R-P1..R-P16 illumos riscv64 MD tree (struct layouts for
genassym). Proof: `rp20/rp20-milestone-check.sh` (all 3).

### R-P20.1 sgs %pcrel_hi/%pcrel_lo pairing + GOT/PLT allocation — DONE
- `rp20/sgs/machrel_riscv_pcrel.c`: the RISC-V PC-relative address PAIRING.
  RISC-V splits a 32-bit pcrel address across `auipc %pcrel_hi20` and a
  following `addi/load %pcrel_lo12` that references the HI *by label* -- the
  LO's reloc symbol resolves to the AUIPC address, not the target, so its low
  12 bits must come from the SAME (S+A-P) value the HI computed. Exact binutils
  two-pass model: (1) `ld_riscv_record_pcrel_hi()` computes value=S+A-addr,
  applies the HI immediate, records `{HI_addr -> value}`; (2)
  `ld_riscv_record_pcrel_lo()` defers the LO, remembering the HI address (its
  resolved symbol value); (3) `ld_riscv_resolve_pcrel_lo()` finds the HI by that
  address and splices the HI's stored value into the LO immediate, so
  HI(rounded high20)+LO(sext low12)==S+A-P. Diagnostics (missing HI, addend on
  GOT_HI20, addend-crosses-high-part overflow) match binutils. Self-test: S-PC
  reconstruct across auipc/addi, LO resolved from recorded HI, missing-HI
  rejected, and byte-identical GNU-ld bytes `0x00001797`/`0x0a878793` for the
  R-P19.3 pair -- PASS.
- `rp20/sgs/machrel_riscv_gotplt.c`: GOT/PLT slot allocation for CALL_PLT /
  GOT_HI20 / JUMP_SLOT. RV64 layout from binutils (GOT_ENTRY_SIZE=8,
  PLT_HEADER_SIZE=32, PLT_ENTRY_SIZE=16, GOTPLT_HEADER_SIZE=16); idempotent
  per-symbol slots, header-biased offsets, `.plt/.got.plt/.got` sizing, and
  emitters for the 4-insn PLT entry stub (auipc t3 / ld t3 / jalr t1,t3 / nop)
  + the 8-insn header trampoline. Self-test: idempotent+monotonic slots,
  binutils sizes/offsets, PLT stub decodes + its pcrel hi/lo reconstructs the
  `.got.plt` target -- PASS.
- **CRIB**: `riscv_pcrel_{hi,lo}_reloc` structs + record/resolve algorithm from
  binutils-2.44 `bfd/elfnn-riscv.c` (~1962-2170, 2877-2930); PLT/GOT layout +
  `riscv_make_plt_{header,entry}` (~296-410). Gate `Rel_desc`/`Target`/htab
  wiring documented inline (this uses an O(n) list, marked as the upgrade
  point).

### R-P20.2 csu crt (crt1/crti/crtn) + first riscv64-solaris hello ELF — DONE
- `rp20/csu/{crt1,crti,crtn}.s`: riscv64 C runtime. `crt1.s` `_start`:
  terminate the frame chain, set `gp` from `__global_pointer$` (relaxation
  off), pull argc/argv/envp into a0/a1/a2 per psABI, 16-align sp, then
  `call _init; call main`, then `exit(2)` (SYS_exit=1 via `ecall`) with main's
  return -- freestanding, no libc. `crti/crtn` open/close `_init`/`_fini` (SVR4
  csu split; riscv64 addi sp,-16 / sd ra,8(sp) frame). All EM_RISCV.
- `rp20/hello/hello.c` -> `ld -static -e _start` with crt1/crti/hello/crtn +
  libgcc.a -> valid **EM_RISCV ELF64 ET_EXEC** entry `_start`, ZERO relocs.
  `_start` disassembles to gp-setup + jal _init + jal main + li a7,1;ecall; the
  gp-relative auipc/addi pcrel pair to `__global_pointer$` resolved -- the
  first riscv64-solaris userland executable.
- **full libgcc_s.so.1: NOT this phase (R-P21 long pole).** R-P17/18 gcc was
  `--disable-shared` (`enable_shared = no` in the libgcc Makefile), so
  `all-target-libgcc` only builds static `libgcc.a` (138 members, present).
  `libgcc_s.so.1` needs `--enable-shared` reconfigure + full rebuild AND a real
  libc (Solaris `SHLIB_LINK` pulls `-lc`), neither of which exists yet.
  Documented as the R-P21 gate; static libgcc.a suffices for the linkable-exe
  milestone.
- **CRIB**: initial-stack layout + a0=argc/a1=argv/a2=envp from RISC-V psABI
  "Program Startup" + glibc/newlib Scrt1; `.option norelax; lla gp,
  __global_pointer$` from psABI + gcc riscv startup; crt open/close split +
  "call _init; call main; exit" from illumos csu (amd64/aarch64 crt1.s);
  SYS_exit=1 + `ecall` from the illumos syscall convention.

### R-P20.3 larger uts unit — genassym + machdep cpu-init — DONE
- `rp20/uts/riscv64/genassym.c` + `genassym.sh`: the illumos riscv64 kernel
  asm-offset generator. MD .S (locore/trap/swtch/setjmp) reach into C structs
  by numeric offset (`sd ra,C_RA(a0)`, TF_* frame, LABEL_* in label_t), today
  hand-maintained + `_Static_assert`-guarded. genassym.c compiles the ACTUAL
  `struct regs`/`struct rv_context`/`label_t` and, via inline-asm
  `ASSYM(name, offsetof(...))` in a `.assym` section, emits the compiler's real
  offsets; `genassym.sh` extracts `assym.h`. Cross-compiled to **EM_RISCV**
  ET_REL. Generated offsets EXACTLY match the hand-maintained
  swtch.S/asm_frame.h/machtypes.h (regs_r_ra=0, regs_r_sp=8, rv_context_c_ra=0,
  c_satp=120, c_lofault=128, LABEL_SP=8, regs_SIZE=280) -- genassym validates
  (and would replace) the hand offsets. Freestanding pipeline (compiler folds
  offsetof; no runnable libc) -- the classic gate/BSD genassym trick.
- `rp20/uts/riscv64/mach_cpu.c` (+ `externs.c`): a machdep slice (per-cpu
  online, install stvec, account a switch, a dispatch table) exercising the
  load-bearing reloc set: **R_RISCV_CALL_PLT** (x2 cross-TU calls),
  **PCREL_HI20+PCREL_LO12** pairs + HI20/LO12 absolute pairs (external data via
  auipc/addi), BRANCH/RVC_BRANCH, ADD32/SUB32/SET6/SUB6. Cross-compiled to
  EM_RISCV; cross-`ld -Ttext=0x10000 -e cpu_online` with the externs stub
  resolves EVERY reloc -> EM_RISCV ET_EXEC, zero relocs; the CALL_PLT to
  `rv_swtch` and the auipc/addi pcrel pairs to
  `cpu_list`/`trap_entry`/`hart_online_mask` all disassemble resolved. The
  R-P19 mod stub grown to a multi-TU unit that links toward the kernel and
  exercises exactly the relocs R-P20.1 resolves.
- **CRIB**: the OFFSET/SIZE/ASSYM mechanism from illumos uts genassym.c +
  sys/assym.h and BSD `sys/arch/riscv/riscv/genassym.cf`; struct layouts from
  the R-P1..R-P16 MD tree (`regs.h`, `proc.c`, `sys/machtypes.h`); the
  per-cpu/stvec shape from that MD tree + the RISC-V privileged spec.

### `/root/riscv-port/rp20/` contents
`sgs/{machrel_riscv_pcrel.c, machrel_riscv_gotplt.c, machrel_riscv_insn.c
(from rp19), pcrel_selftest, gotplt_selftest}`; `csu/{crt1,crti,crtn}.s + .o`;
`hello/{hello.c, hello.o, hello.elf}`; `uts/riscv64/{genassym.c, genassym.sh,
genassym.{s,o}, assym.h, mach_cpu.c, externs.c, mach_cpu.o, externs.o,
kunit_riscv64.{o,exec}, mod_riscv64.c, sys/*.h}`; `rp20-milestone-check.sh`
(all 3, re-runnable). Crt objects also installed into
`sysroot-riscv-sol/usr/lib/{crt1,crti,crtn}.o`. Repo copies under
`src/riscv/{sgs,csu,hello,uts/riscv64}/` + `src/riscv/rp20-milestone-check.sh`.

### Next: R-P21
1. **Fold the sgs pieces into a real gate `machrel.riscv.c`** against the true
   `usr/src/cmd/sgs/include/_libld.h` `Rel_desc`/`Target` types: swap the
   standalone shims for the gate structs, wire the pcrel-pairing hash (keyed by
   `Rel_desc->rel_roffset`) + GOT/PLT allocator into `ld_do_activerelocs` /
   `ld_allocate_got` / `ld_perform_outreloc`, and build inside a real (or
   stubbed) sgs tree so `ld` selects `ld_targ_riscv` for EM_RISCV.
2. **Shared libgcc_s.so.1 (the R-P20 long pole)**: bring up a minimal
   riscv64-solaris libc (or a stub `-lc` with the symbols `SHLIB_LINK` needs),
   reconfigure gcc `--enable-shared`, complete `all-target-libgcc` to produce
   `libgcc_s.so.1`; then link a *dynamic* hello.
3. **Grow the uts unit toward a linkable `unix`/`genunix`**: replace `assym.h`'s
   hand offsets in the real `.S` files with genassym output, then cross-compile
   + link a bigger MD set (locore + swtch + trap + a machdep) as an EM_RISCV
   kernel image in the gate layout.

---

## R-P19 — riscv64-solaris toolchain finished + sgs MACH descriptor + first uts object

Substrate: fred v3 (root@52.88.62.49), the R-P18 all-gcc-solaris build tree
(`/root/riscv-port/build/gcc-sol-cfg3/`), the R-P17 `riscv64-unknown-elf`
binutils 2.44, and binutils-2.44 `bfd/` as the reloc-math crib source.

### R-P19.1 all-gcc-solaris finished + riscv64-solaris libgcc.a — DONE
- **Long-pole `make all-gcc` (riscv64-unknown-solaris2.11) finished.** Two real
  build blockers found + fixed in `gcc/config/riscv/sol2.h`
  (`rp19/config-riscv-sol2.h`, appended to R-P18's header):
  (a) the generic `config/sol2.cc` `solaris_output_init_fini()` emits
  `.init/.fini` entries via `ASM_OUTPUT_CALL`, which the RISC-V ELF backend
  never defines (only i386/sparc sol2.h do) — added an `ASM_OUTPUT_CALL` for
  RISC-V (`\tcall\t` + `assemble_name`, the `call` pseudo, R_RISCV_CALL_PLT);
  (b) `#undef MULTILIB_DEFAULTS` so the common sol2.h `{ "m64" }` wins over
  riscv/riscv.h without a redefinition warning. `cc1` links, `make all-gcc`
  exits 0, `-dumpmachine` = `riscv64-unknown-solaris2.11`, GCC 14.3.0.
- **Minimal sysroot + libgcc bootstrap** (`rp19/rp19-sysroot-libgcc.sh`,
  idempotent). The solaris triple had no in-tree binutils, so the build-tree
  `gcc/as` + `gcc/collect-ld` wrappers had empty `ORIGINAL_*_FOR_TARGET` and
  ran `exec "" -march=...` — pointed them at the R-P17 `riscv64-unknown-elf`
  as/ld (psABI is identical; only the OS triple differs) and published
  `riscv64-unknown-solaris2.11-{ar,ranlib,...}` on PATH. Added four BOOTSTRAP
  stub headers (`sys/mman.h`, `sys/types.h`, `unistd.h`, `stdlib.h`) the
  Solaris `enable-execute-stack-mprotect.c` references, plus the minimal
  `/usr/include/sys/{isa_defs,machtypes,elf_riscv}.h` sysroot (the R-P17 MD
  headers). `gmake libgcc.a` builds the 138 compiler-runtime objects (soft
  int/float, clz/ctz, muldi3, ...) — skips the Solaris gmon/profiling extra
  that needs full libc. Installed at
  `toolchain-sol/lib/gcc/riscv64-unknown-solaris2.11/14.3.0/libgcc.a` (5.6 MB,
  138 EM_RISCV members). PROOF: `rp19/rp19-toolchain-check.sh`.
- **CRIB**: `ASM_OUTPUT_CALL` shape from gcc `i386/sol2.h` + `sparc/sol2.h`,
  adapted to the RISC-V `call` mnemonic. The as/ld-wrapper + PATH bootstrap is
  standard cross-gcc practice (a target reusing another's binutils for an
  identical psABI).

### R-P19.2 sgs libld MACH descriptor + RISC-V instruction-field reloc encoders — DONE
- `rp19/machrel_riscv_insn.c`: the `FLG_RE_INSREL` encoder `ld_reloc_riscv_insn()`
  — splices a computed value into the U/I/S/B/J immediate slots of a 32-bit
  instruction (and CB/CJ/CI slots of a 16-bit RVC instruction) exactly as
  binutils `perform_relocation()` does: ENCODE the value into the field layout,
  read-modify-write `word = (word & ~dst_mask) | (enc & dst_mask)`, LE store.
  Handles HI20/LO12_I/LO12_S (+ TPREL/PCREL/GOT/TLS HI/LO variants),
  CALL/CALL_PLT (auipc U-part + jalr I-part, 64-bit splice), JAL, BRANCH,
  RVC_BRANCH/JUMP/LUI. HI/LO split via `RISCV_CONST_HIGH_PART`. Self-test
  round-trips every field type against the binutils EXTRACT macros — PASS.
- `rp19/machrel_riscv_dispatch.c`: `ld_do_reloc_riscv()` — the reloc-apply core
  the MACH descriptor + krtld `do_reloc()` reduce to. Consults the R-P18
  classification table (`sgs_reloc_table_riscv[]`), computes the RISC-V
  Calculation (S+A, or S+A-P for PC-relative), and routes INSREL types to the
  encoder, flat data types to a byte store, and link-time markers to a no-op.
  ADD/SUB/SET/SUB6 are correctly in-place modify (not overwrite), cribbed from
  binutils `riscv_elf_add_sub_reloc`. Self-test: flat64 / 32_PCREL / HI20+LO12
  pair / ADD32+SUB32 / RELAX no-op — PASS.
- `rp19/machtarget_riscv.c`: `ld_targ_riscv` — the EM_RISCV `Target` descriptor
  skeleton (Target_mach: EM_RISCV/ELFCLASS64/ELFDATA2LSB/pagesize; the M_R_*
  dynamic reloc identities: RELATIVE=3 / JUMP_SLOT=5 / COPY=4 / TLS_*64;
  null/fill func bytes) with `t_mr` wiring the classification table +
  `ld_do_reloc_riscv`. This is the record `ld_config_target()` returns for
  `e_machine == EM_RISCV`. Self-test: descriptor identity + reloc applied
  THROUGH the `t_mr.mr_do_reloc` pointer — PASS.
- **BYTE-IDENTICAL to GNU ld**: on the R-P19.3 object the INSREL encoder
  produces exactly `auipc a5,0x1 = 0x00001797` + `addi a5,a5,168 = 0x0a878793`
  for the `riscv64_boot_label` PCREL_HI20/LO12 pair — the same bytes GNU ld
  emitted, verified in `rp19-milestone-check.sh` R-P19.3d.
- **CRIB**: `ENCODE_{U,I,S,B,J}TYPE_IMM` / `ENCODE_C{B,J,I}TYPE_IMM` / `RV_X` /
  `RISCV_CONST_HIGH_PART` from binutils-2.44 `include/opcode/riscv.h`; the
  per-reloc encode dispatch + CALL `U | I<<32` packing + the RMW store +
  get/put_insn 16/32/64 LE model from `bfd/elfnn-riscv.c perform_relocation()`;
  `dst_mask == ENCODE_xTYPE_IMM(-1U)` from `bfd/elfxx-riscv.c` howto_table[];
  ADD/SUB math from `riscv_elf_add_sub_reloc`. The Target/Rel_entry/FLG_RE_*
  shape follows the illumos sgs machrel.<arch>.c convention.

### R-P19.3 first illumos uts/riscv64 EM_RISCV object — DONE
- `rp19/uts/riscv64/` gate-layout tree: `mod_riscv64.c` (a trivial loadable
  module: a `label_t` save-area store, `_init/_fini/_info`) compiled `_KERNEL`
  / freestanding against the R-P17 illumos riscv64 MD headers spliced into
  `sys/{isa_defs,machtypes,elf_riscv,feature_tests}.h`. Compile-time asserts
  pin the ISA contract (LP64, `_LITTLE_ENDIAN`, `_ALIGNMENT_REQUIRED`,
  `_MAX_ALIGNMENT==16`, `label_t == 16 XLEN slots`) so a wrong data model fails
  the BUILD.
- Built by BOTH the R-P17 `riscv64-unknown-elf` gcc AND the new
  `riscv64-unknown-solaris2.11` gcc → a valid **EM_RISCV (243) ELF64-LSB
  ET_REL** illumos kernel object. It emits exactly the reloc set this port must
  resolve: `R_RISCV_CALL_PLT(19)`, `R_RISCV_PCREL_HI20(23)`,
  `R_RISCV_PCREL_LO12_I(24)`, `R_RISCV_RELAX(51)`, plus ADD32/SUB32/SET6/SET8/
  SUB6/32_PCREL — all in-bounds in the R-P18 doreloc table, all classified +
  applied by the R-P19.2 pieces.
- **Link-apply proof**: cross-`ld -Ttext=0x80000000 -e _init` resolves every
  reloc → an EM_RISCV ET_EXEC entry 0x80000062, zero relocs remaining; the
  applied auipc/addi disassembles to `0x800010b8 <riscv64_boot_label>`.
- **CRIB**: the MD headers are the R-P17 BSD-cribbed set (NetBSD
  `sys/arch/riscv` psABI/register roles); the modlinkage/`_init/_fini/_info`
  shape is the illumos kmod convention.

### `/root/riscv-port/rp19/` contents
`machrel_riscv_insn.c`, `machrel_riscv_dispatch.c`, `machtarget_riscv.c`,
`machrel.riscv.c` + `reloc_riscv_table.h` (from R-P18), `config-riscv-sol2.h`
(updated), `rp19-milestone-check.sh` (sgs + uts proofs), `rp19-toolchain-check.sh`
(gcc + libgcc proofs), `rp19-sysroot-libgcc.sh` (idempotent bootstrap),
`uts/riscv64/{mod_riscv64.c, mod_riscv64.o, mod_riscv64.linked, sys/*.h}`,
the self-test binaries. Host toolchain:
`toolchain-sol/` (riscv64-unknown-solaris2.11 gcc + libgcc.a + bin symlinks),
`sysroot-riscv-sol/usr/include/sys/*.h`. Repo copies under `src/riscv/sgs/`,
`src/riscv/gcc/`, `src/riscv/uts/riscv64/`, `src/riscv/rp19-*.sh`.

### Next: R-P20
1. Fold the standalone `machrel_riscv_insn.c` + `machrel_riscv_dispatch.c` +
   `machtarget_riscv.c` into a real `usr/src/cmd/sgs/libld/common/machrel.riscv.c`
   against the gate `_libld.h` `Rel_desc`/`Target` types, and add the
   `%pcrel_hi`/`%pcrel_lo` pairing + GOT/PLT slot allocation the classification
   flags mark (the scaffolding this bootstrap deferred).
2. Grow the bootstrap sysroot toward a real one: build illumos csu
   (crt1/crti/crtn) for riscv64 and the minimal libc headers so
   `all-target-libgcc` completes fully (incl. the Solaris gmon/unwind extras)
   and shared objects link.
3. Cross-compile a larger uts/riscv64 unit (locore/genassym or a real driver)
   through the retargeted toolchain + the folded sgs machrel, toward a linkable
   `unix`/`genunix` in the gate layout.

---

## R-P18 — the R1 hard part: reloc coverage + the solaris triple

Three concrete sub-tasks, all landed with re-runnable proofs. Substrate: fred
v3 (root@52.88.62.49), the R-P17 toolchain (`riscv64-unknown-elf` binutils
2.44 + gcc 14.3.0) + the 58-entry `sys/elf_riscv.h`.

### R-P18.1 krtld/sgs `doreloc.c` reloc_table 12 -> 58 — DONE
- `src/riscv/uts/krtld/doreloc.c`: `reloc_table[R_RISCV_NUM]` grown from the
  12 dynamic relocs (stopped at `R_RISCV_TLS_TPREL64`) to the FULL 58-entry
  psABI table (0..57). Each entry carries `re_fsize` + `FLG_RE_*`. Data relocs
  (32/64/RELATIVE/JUMP_SLOT, TLS *64, ADD/SUB/SET 8..64, SUB6, 32_PCREL) are
  flat byte stores (real sizes, added to the `do_reloc()` value switch);
  RISC-V instruction-field relocs (BRANCH/JAL/CALL/CALL_PLT/*_HI20/*_LO12_*/
  RVC_*) + link-time markers (RELAX/ALIGN/*_ADD/GNU_VT*) are `FLG_RE_NOTSUP`
  size 0 (handled by the link-editor's instruction-field path, never the flat
  do_reloc byte writer).
- `src/riscv/uts/krtld/elf_riscv.h`: `R_RISCV_NUM` 12 -> 58 + the full type
  defines (BRANCH(16)..32_PCREL(57)), so `reloc_table[rtype]` is in-bounds for
  the CALL_PLT(19)/HI20(26)/LO12_I(27)/RELAX(51) that gcc actually emits (the
  old 12-entry table OOB-read on all four).
- **CRIB**: sizes/pc_relative/special-fn per reloc from binutils-2.44
  `bfd/elfxx-riscv.c` howto_table[] (extracted on the node); reloc numbers +
  the NOTREL/NOTSUP split convention from the existing illumos 12-entry table +
  the RISC-V psABI "Calculation" column.

### R-P18.2 gcc `riscv64-unknown-solaris2.11` triple — DONE (config + configures)
- `config.sub`: NO CHANGE — stock gcc-14.3.0 already canonicalizes
  `riscv64-unknown-solaris2.11` cleanly (proven, rc=0): both `riscv64` and
  `solaris2` are known, the combination validates.
- `gcc/config.gcc`: added the `riscv*-*-solaris2* | riscv*-*-illumos2*)` stanza
  (before `loongarch*-*-linux*`), wiring the sol2 tm_file chain
  `elfos.h ${cpu_type}/sysv4.h riscv/elf.h riscv/sol2.h ${cpu_type}/sol2.h`,
  `tmake_file += riscv/t-riscv t-sol2 riscv/t-sol2`,
  `native_system_header_dir=/usr/include`, `with_tls=trad`, forced
  `.init_array`. Delta documented in `rp18/config.gcc.riscv-solaris.md`.
- `gcc/config/riscv/sol2.h` (`rp18/config-riscv-sol2.h`): arch-solaris tm
  header — `TARGET_SUN_TLS`, undef the Newlib LIB/STARTFILE/ENDFILE from
  riscv/elf.h (the common sol2.h supplies the Solaris crt1/crti/crtn model),
  `elf64lriscv` ld emulation, ARCH64_SUBDIR "64".
- `gcc/config/riscv/t-sol2`: 64-bit-only, no-multilib stub.
- **PROOF** (`rp18/gcc-triple-proof.txt`): `configure
  --target=riscv64-unknown-solaris2.11` rc=0 AND `make configure-gcc` rc=0 —
  the gcc subdir's resolved tm_file chain contains exactly
  `elfos.h -> riscv/sysv4.h -> riscv/elf.h -> riscv/sol2.h -> config/sol2.h`,
  and `configargs.h` records the solaris triple. config.gcc fully accepts +
  elaborates the target.
- **BUILD FIXES FOUND + APPLIED** (two config.gcc corrections):
  (a) first `all-gcc` failed at `s-gtype` with "No rule to make target
  config/riscv/sysv4.h" -- `${sol2_tm_file_head}` is `elfos.h
  ${cpu_type}/sysv4.h` and riscv ships no `config/riscv/sysv4.h`; fixed by
  naming `elfos.h` directly (riscv/elf.h + elfos.h cover the SVR4/ELF base).
  (b) second `all-gcc` failed at `s-gtype` with `config/riscv/sol2.h specified
  more than once` -- `${sol2_tm_file_tail}` is `${cpu_type}/sol2.h sol2.h`, so
  the stanza's explicit `riscv/sol2.h` was a duplicate; dropped it. Final
  stanza tm_file: `elfos.h ${tm_file} riscv/elf.h ${sol2_tm_file_tail}`.
  `build/gcc-sol-cfg3/` clears configure + s-gtype with 0 errors and is
  compiling the riscv backend / cc1.
- **LONG POLE** (running, not gating this phase): the full `make all-gcc`
  rebuild-as-solaris (log `logs/gcc-sol-allgcc3.log`). libgcc needs a Solaris
  sysroot (crt + /usr/include) that does not exist yet; `all-gcc` (cc1 +
  prereqs) is compiling. R-P19 finishes libgcc once the first crt/headers exist.
- **CRIB**: the stanza shape from gcc-14.3.0's own `riscv*-*-freebsd*` /
  `riscv*-*-linux*` + the `x86_64-*-solaris2*` / `sparc*-*-solaris2*` arch
  stanzas; `riscv/sol2.h` from the richlowe/gcc arm64-gate `aarch64/sol2.h`
  pattern (the existing solnix aarch64-unknown-solaris2.11 target) + gcc
  `i386/sol2.h`.

### R-P18.3 Solaris ld (sgs) `R_RISCV_*` — DONE
- `src/riscv/sgs/machrel.riscv.c` + `reloc_riscv_table.h`: the standalone
  EM_RISCV sgs/libld reloc CLASSIFICATION table (58 entries) — the sgs-side
  companion to doreloc's byte-store table. Per reloc: GOT / PLT / PC-relative /
  TLS / instruction-field / link-time-marker flags + container size, so libld
  routes CALL_PLT (PLT), GOT_HI20 (GOT), PCREL_* (pcrel instruction field),
  RELAX (link-time marker) correctly instead of faulting on unclassified types.
  In the gate this becomes `usr/src/cmd/sgs/libld/common/machrel.riscv.c`.
- `src/riscv/uts/krtld/kobj_convrelstr.c`: `conv_reloc_RISCV_type()` extended
  from 6 names to all 58 — the reloc-name mapping sgs `ld` + krtld use for
  diagnostics. Before, CALL_PLT/HI20/LO12_I/RELAX printed as bare integers.
- **CRIB**: reloc GOT/PLT/PCREL/TLS/instruction-field classification from
  binutils-2.44 `bfd/elfxx-riscv.c` (pc_relative + special_function) +
  `bfd/elfnn-riscv.c` relocate_section dispatch + the RISC-V psABI; names from
  binutils/psABI; the `Rel_entry`/`FLG_RE_*` shape from the illumos sgs
  convention.

### R-P18.4 end-to-end reloc proof — PASS (`rp18/rp18-reloc-check.sh`, re-runnable)
Compiles C on the R-P17 cross gcc; it emits `R_RISCV_CALL_PLT(19)`,
`R_RISCV_HI20(26)`, `R_RISCV_LO12_I(27)`, `R_RISCV_RELAX(51)` (all beyond the
old 12). The script then proves each is (1) in-bounds in the 58-entry doreloc
table [old table OOB], (2) named by `conv_reloc_RISCV_type()` [old stub: 3 of 4
bare numbers], (3) classified by the sgs machrel table (CALL_PLT=PLT,
GOT_HI20=GOT, PCREL_HI20=pcrel, RELAX=link-time marker). `ALL R-P18 RELOC
PROOFS PASSED`.

### `/root/riscv-port/rp18/` contents
`doreloc.c`, `elf_riscv.h` (krtld, R_RISCV_NUM=58), `kobj_convrelstr.c`,
`machrel.riscv.c`, `reloc_riscv_table.h`, `config-riscv-sol2.h`,
`config.gcc.riscv-solaris.md`, `gcc-triple-proof.txt`, `rp18-reloc-check.sh`
(+ `verify.c`/`verify_names.c`/`verify_sgs.c`). Repo copies under
`src/riscv/uts/krtld/`, `src/riscv/sgs/`, `src/riscv/gcc/`.

### Next: R-P19
1. Finish the `make all-gcc` solaris-triple compiler build (log
   `logs/gcc-sol-allgcc.log`); then bootstrap a minimal riscv64 Solaris sysroot
   (crt1/crti/crtn + a stub `/usr/include`) so `make all-target-libgcc`
   completes and `-dumpmachine` = `riscv64-unknown-solaris2.11`.
2. Wire `machrel.riscv.c` + `reloc_riscv_table.h` into a real
   `usr/src/cmd/sgs/libld` mach descriptor (EM_RISCV dispatch) + implement the
   RISC-V instruction-field relocation encoders (B/J/U/I/S-type + RVC + the
   PCREL_HI20/LO12 pair fixup) that the `FLG_RE_INSREL` entries defer to.
3. Splice `sys/isa_defs.h` + `sys/machtypes.h` into a real `uts/riscv64` gate
   tree and cross-compile a first illumos-flavored riscv64 object with the
   solaris triple, linking it through the extended reloc handling.

---

## R-P17 and earlier (history)

## 1. Cross toolchain — BINUTILS + GCC stage-1 BUILT; EM_RISCV + reloc-coverage PROVEN.

### binutils 2.44 `--target=riscv64-unknown-elf` — DONE (~4 min)
- Source: ftp.gnu.org/gnu/binutils/binutils-2.44.tar.xz, sha256
  `ce2017e059d63e67ddb9240e9d4ec49c2893605035cd60e92ad53177f4377237` (verified).
- Built with the native OI gcc 14.3.0, `--disable-nls --disable-werror
  --disable-gdb --disable-sim --with-system-zlib`.
- Installed at `/root/riscv-port/toolchain/bin/riscv64-unknown-elf-{as,ld,
  readelf,objdump,objcopy,nm,ar,ranlib,strip,...}` (16 tools).

### EM_RISCV proof — PASS (the R1 milestone's binutils half)
`/root/riscv-port/psabi-reloc-check.sh` (runnable, re-runs the whole proof):
- cross-**as** `-march=rv64gc -mabi=lp64d` assembles a .o →
  `readelf -h` Machine = **RISC-V**, ELF64 LSB; raw `e_machine = 243`
  (**EM_RISCV**), confirmed independently by the host's own readelf.
- cross-**ld** links it → EXEC, Machine **RISC-V**, entry 0x80000000.
- objdump disassembles rv64gc incl. compressed insns + `ecall`.
- Result line: `PASS: cross-as + cross-ld produce EM_RISCV (243) objects`.

### gcc 14.3.0 stage-1 (`riscv64-unknown-elf`, rv64gc/lp64d) — DONE (~26 min)
- Source: ftp.gnu.org/gnu/gcc/gcc-14.3.0/gcc-14.3.0.tar.xz (xz-integrity verified;
  extracts to BASE-VER 14.3.0). `contrib/download_prerequisites` pulled
  gmp-6.2.1/mpfr-4.1.0/mpc-1.2.1/isl-0.24 (all OK).
- `--without-headers --with-newlib --enable-languages=c --disable-multilib
  --with-arch=rv64gc --with-abi=lp64d --disable-shared --disable-threads`.
- **illumos break hit + fixed** (the exact one design-riscv-port.md §2.3
  documents): gcc 14's in-tree **gettext** fails on illumos (gnulib
  `getlocalename_l` conflict). Fix applied: stripped the in-tree `gettext`
  symlink AND neutered the top-level Makefile `*-gettext` targets to no-ops
  (`--disable-nls` cross cc does not need gettext; `all-gcc`'s only direct prereq
  is `configure-gcc`). Rebuild via `rebuild-gcc.sh` then completed cleanly.
- **Installed**: `/root/riscv-port/toolchain/bin/riscv64-unknown-elf-gcc`
  (`-dumpmachine` = `riscv64-unknown-elf`, GCC 14.3.0) + `libgcc.a` built for
  `riscv64-unknown-elf/14.3.0` (the target backend compiled its own runtime =
  the backend works). Full toolchain 968 MB.
- **Reloc-coverage proof — PASS**: `psabi-reloc-check.sh` compiles C on the cross
  gcc, `objdump -dr`s the object, and asserts EVERY emitted `R_RISCV_*` is
  defined in `sys/elf_riscv.h`. Emitted (rv64gc, TLS LE): `R_RISCV_CALL_PLT,
  R_RISCV_RELAX, R_RISCV_TPREL_ADD, R_RISCV_TPREL_HI20, R_RISCV_TPREL_LO12_I,
  R_RISCV_TPREL_LO12_S` — all covered. Result: `PASS: every gcc-emitted R_RISCV_*
  is defined in sys/elf_riscv.h` / `ALL CHECKS PASSED`. Log:
  `artifacts/riscv-port/rp17/proof.log`.

---

## 2. illumos riscv64 MD headers (BSD-cribbed) — WRITTEN + syntax-checked

New under `src/riscv/uts/sys/` (persisted to host `/root/riscv-port/portsrc/`):

| file | what | crib provenance |
|------|------|-----------------|
| `sys/elf_riscv.h` | the **COMPLETE** RISC-V ELF psABI reloc set (0..57, `R_RISCV_NUM=58`) + ELF64 PLT/GOT machine defines. Replaces the n-hys fork's 12-entry table (which real gcc output overruns). | NetBSD `sys/arch/riscv/include/elf_machdep.h` (psABI reloc numbers are OS-independent) reconciled with GNU/binutils names |
| `sys/isa_defs.h` | the riscv64 stanza for `<sys/isa_defs.h>` — LP64D, `_LITTLE_ENDIAN`, alignment set, `_CHAR_IS_SIGNED`, `_ALIGNMENT_REQUIRED=1`, no `_MULTI_DATAMODEL`. The arch-selection block the gate must grow (like the `__amd64`/`__aarch64` stanzas). | RISC-V psABI + illumos sibling-arch stanzas; endianness/elfsize cross-checked vs NetBSD elf_machdep.h |
| `sys/machtypes.h` | `lock_t`, `label_t` (setjmp save area: ra/sp/gp/tp/s0-s11 = 16 slots), NCPU/MAXCPU. | NetBSD `reg.h` register-role block (calling convention is OS-independent) |

**Why elf_riscv.h matters (empirically shown):** a `gcc -c` on this port's own
cross toolchain emits `R_RISCV_CALL_PLT(19)`, `R_RISCV_PCREL_HI20(23)`,
`R_RISCV_PCREL_LO12_I(24)`, `R_RISCV_RELAX(51)` — **none** in the n-hys
12-reloc set. The Solaris link-editor (sgs) and krtld `do_reloc()` must know the
full table; this header supplies it. Static asserts (R_RISCV_NUM==58,
CALL_PLT==19, PCREL_HI20==23, RELAX==51, JMP_SLOT alias) PASS.

Checks run + PASS on host:
- `gcc -E -D__riscv -D__riscv_xlen=64 sys/isa_defs.h` → preprocess OK.
- `gcc -fsyntax-only relchk.c` (the elf_riscv static asserts) → PASS.
- `psabi-reloc-check.sh` → EM_RISCV proof PASS (reloc-coverage SKIP until gcc).

## 3. BSD reference mirror — `src/riscv/bsd-ref/netbsd/`

Fetched NetBSD-current `sys/arch/riscv/include/{elf_machdep,reg,mcontext,frame,
asm}.h` as reference-only crib sources (not compiled, not shipped), with a
`README.md` mapping each illumos MD file to its BSD crib. **TODO (like the
pending NetBSD-drm mirror):** obtain a pinned NetBSD-current `sys/arch/riscv`
mirror as the authoritative reference; FreeBSD `sys/riscv` is the secondary
cross-check.

---

## 4. What R-P1..R-P16 already achieved (context — DONE, in the design doc)

The kernel bring-up is remarkably far along (all under QEMU virt via the
`pkgsCross.riscv64-embedded` bare-metal toolchain, sources in `src/riscv/uts/`):
- R-P2 first `unix` S-mode banner under OpenSBI; R-P3 trap+Sv39+timer; R-P4
  SMP(HSM)+cyclic clock+PLIC+high-VA hat; R-P5 page_t/kmem/callout/dispatcher;
  R-P6..R-P12 virtio+root-mount+fork/exec/wait+shell+signals+pipes+writable FS;
  R-P13 AIA(APLIC+IMSIC); R-P14/R-P15 SpaceMiT K1 board bring-up (dw-apb-uart,
  SDHCI, flashable U-Boot→OpenSBI→solnix image); R-P16 runtime board-detect
  (ONE image boots qemu-virt AND physical K1).
- R-P16-prestage imported n-hys CDDL sources (krtld reloc engine, CMO, FDT
  of_utils, FPU ctxop, EMAC template) — `src/riscv/uts/R-P16-IMPORT-MANIFEST.md`.

## 5. QEMU-virt substrate (from design-sparc-riscv-qemu.md + design-riscv-port.md)
- `qemu-system-riscv64 -machine virt` under OpenSBI is the proven boot substrate
  (R-P2..R-P16 all gate on it). The bare-metal bring-up toolchain is nixpkgs
  `pkgsCross.riscv64-embedded` (riscv64-none-elf). The NEW `riscv64-unknown-elf`
  toolchain here (built from source on the illumos host) is the seed that R1
  re-targets to `riscv64-unknown-solaris2.11` once a sysroot exists.

---

## Next phase + how to resume

**R-P18 (toolchain target retarget) — the R1 hard part still open:**
1. Add the `riscv64-unknown-solaris2.11` OS stanza to `config.gcc`/`config.sub`
   (crib the aarch64-solaris config from richlowe/gcc) — this is the real R1
   toolchain-target work; `riscv64-unknown-elf` here is the proven starting point.
2. Teach the **Solaris link-editor (sgs)** `R_RISCV_*` relocs using the full
   table in `sys/elf_riscv.h` + the n-hys `krtld/doreloc.c` reloc engine.
   CONCRETE GAP FOUND: n-hys's `reloc_table[R_RISCV_NUM]` in
   `src/riscv/uts/krtld/doreloc.c` has only the 12 dynamic relocs and STOPS at
   `R_RISCV_TLS_TPREL64`; indexing `reloc_table[rtype]` for the CALL_PLT(19) /
   PCREL_HI20(23) / RELAX(51) that gcc emits is an OUT-OF-BOUNDS read. R-P18 must
   grow that table to the full 58 entries (formulas in the BSD `nb_elf_machdep.h`
   comments) and bump the local `krtld/elf_riscv.h` `R_RISCV_NUM` from 12 to 58
   to match `sys/elf_riscv.h`.
3. Splice the `sys/isa_defs.h` riscv64 stanza + `sys/machtypes.h` into a real
   `uts/riscv64` gate tree (they compile standalone now).

**Resume the toolchain build:**
```
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
ssh root@52.88.62.49
cd /root/riscv-port
./psabi-reloc-check.sh              # re-run the EM_RISCV proof
tail -f logs/gcc-build2.log          # gcc stage-1 progress
./rebuild-gcc.sh                     # (idempotent) finish gcc if interrupted
```

## Persisted files
- Host `/root/riscv-port/`: `toolchain/` (binutils installed), `build/`,
  `src/` (binutils+gcc tarballs+trees), `logs/`, `proof/`, `portsrc/` (the MD
  headers), `bsd-ref/netbsd/` (crib sources), `build-binutils.sh`,
  `build-gcc.sh`, `rebuild-gcc.sh`, `psabi-reloc-check.sh`, this `STATUS.md`.
- Repo `src/riscv/uts/sys/{elf_riscv,isa_defs,machtypes}.h`,
  `src/riscv/bsd-ref/{README.md,netbsd/*.h}` — for the orchestrator's commit.
