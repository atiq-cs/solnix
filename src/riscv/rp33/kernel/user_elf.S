/*
 * user_elf.S -- R-P26: embed the two static riscv64-solaris userland ELFs
 * (the forker + the exec target execee) into the kernel image via .incbin,
 * exposing user_elf_start/user_elf_end (forker) and execee_elf_start/
 * execee_elf_end (execee) so exec_image() can map either program's PT_LOAD
 * segments into a fresh user address space.  This is the anti-wedge substrate:
 * no filesystem / boot loader needed to get the process bytes -- they ride in
 * the kernel .rodata.
 *
 * CRIB PROVENANCE: embedding an init/user payload in the kernel image via
 * .incbin (rather than a root filesystem) is the classic "linked-in init"
 * bring-up idiom (Linux initramfs-in-kernel, illumos boot_archive-less bring-up).
 */
	.section .rodata
	.balign 16
	.globl	user_elf_start
user_elf_start:
	.incbin	"forker.bin"
	.globl	user_elf_end
user_elf_end:

	.balign 16
	.globl	execee_elf_start
execee_elf_start:
	.incbin	"execee.bin"
	.globl	execee_elf_end
execee_elf_end:

	.balign 16
	.globl	preempt_elf_start
preempt_elf_start:
	.incbin	"preempt.bin"
	.globl	preempt_elf_end
preempt_elf_end:

	.balign 16
	.globl	fsexec_elf_start
fsexec_elf_start:
	.incbin	"fsexec.bin"
	.globl	fsexec_elf_end
fsexec_elf_end:

	.balign 16
	.globl	dynexec_elf_start
dynexec_elf_start:
	.incbin	"dynexec.bin"
	.globl	dynexec_elf_end
dynexec_elf_end:

	/*
	 * R-P28: the cross-object-linking proof driver -- execs /bin/hellodyn,
	 * a DYNAMIC hello that calls __multf3/__fixtfsi in libgcc_s.so.1 (real
	 * cross-object JUMP_SLOT relocs bound by ld.so.1 at runtime).
	 */
	.balign 16
	.globl	dynexec2_elf_start
dynexec2_elf_start:
	.incbin	"dynexec2.bin"
	.globl	dynexec2_elf_end
dynexec2_elf_end:

	/*
	 * R-P31.2: the ld.so.1-hardening proof driver -- execs /bin/hellolazy,
	 * a DYNAMIC hello linked lazy + --hash-style=both + -z relro that calls
	 * __multf3 in libgcc_s.so.1 twice (lazy bind on first call, patched GOT
	 * on the second).
	 */
	.balign 16
	.globl	dynexec3_elf_start
dynexec3_elf_start:
	.incbin	"dynexec3.bin"
	.globl	dynexec3_elf_end
dynexec3_elf_end:

	/*
	 * R-P29: the FP-context-switch proof driver -- forks two children that
	 * pin distinct FP values in fs0 across preemption + exercises getpid/brk.
	 */
	.balign 16
	.globl	fptest_elf_start
fptest_elf_start:
	.incbin	"fptest.bin"
	.globl	fptest_elf_end
fptest_elf_end:

	/*
	 * R-P31.3: the ramfs-read proof driver -- opens + reads /etc/release out
	 * of the ramfs (the real read(2) path) and prints it, then calls uname(2)
	 * (returns SunOS/solnix-riscv64) + lseek/fstat/stat/getcwd.
	 */
	.balign 16
	.globl	fsread_elf_start
fsread_elf_start:
	.incbin	"fsread.bin"
	.globl	fsread_elf_end
fsread_elf_end:

	/*
	 * R-P32.2: the COW-fork + demand-paging proof driver -- forks a child
	 * that writes a COW-shared page (a store fault copies the page; the
	 * parent's copy stays intact) and touches a demand-paged (lazy) page
	 * that is faulted in on first access.
	 */
	.balign 16
	.globl	cowtest_elf_start
cowtest_elf_start:
	.incbin	"cowtest.bin"
	.globl	cowtest_elf_end
cowtest_elf_end:

	/*
	 * R-P32.1: the procs-on-both-harts proof driver -- forks N children,
	 * each printing which hart it was dispatched on; the shared runq lets a
	 * forked proc run on either hart.
	 */
	.balign 16
	.globl	smproc_elf_start
smproc_elf_start:
	.incbin	"smproc.bin"
	.globl	smproc_elf_end
smproc_elf_end:

	/*
	 * R-P32.3: the vnode-layer write(2) proof driver -- creates + writes a
	 * tmpfs file through VOP_WRITE, reads it back through VOP_READ, and
	 * confirms the read-only ramfs rejects a write (EROFS).
	 */
	.balign 16
	.globl	vfstest_elf_start
vfstest_elf_start:
	.incbin	"vfstest.bin"
	.globl	vfstest_elf_end
vfstest_elf_end:

	/*
	 * R-P33.1: the signals+kill proof driver -- a child installs a SIGUSR1
	 * handler + spins, the parent kill(2)s it (the handler runs + returns
	 * via sigreturn); then the parent SIGKILLs a second spinning child (the
	 * default action terminates it).
	 */
	.balign 16
	.globl	sigtest_elf_start
sigtest_elf_start:
	.incbin	"sigtest.bin"
	.globl	sigtest_elf_end
sigtest_elf_end:

	/*
	 * R-P33.2: the pipe(2) proof driver -- a parent creates a pipe, forks a
	 * child (fds inherited), the parent writes + the child reads (blocking
	 * IPC through the kernel ring buffer), then mkdir + getdents list a dir.
	 */
	.balign 16
	.globl	pipetest_elf_start
pipetest_elf_start:
	.incbin	"pipetest.bin"
	.globl	pipetest_elf_end
pipetest_elf_end:

	/*
	 * R-P33.3: the file-backed demand-exec proof driver -- execs a program
	 * whose PT_LOAD text is demand-paged in from the ramfs on the exec fault
	 * (mmap-file-backed), not eager-copied.
	 */
	.balign 16
	.globl	dpexec_elf_start
dpexec_elf_start:
	.incbin	"dpexec.bin"
	.globl	dpexec_elf_end
dpexec_elf_end:

	/*
	 * R-P27: the initramfs blob -- a name+size+bytes archive (built by
	 * user/mkinitramfs.py) that ramfs.c walks to resolve exec(path).  This
	 * is the fs-backed-exec substrate: the process bytes ride in the kernel
	 * .rodata as a walkable archive, not a per-program .incbin.
	 */
	.balign 16
	.globl	initramfs_start
initramfs_start:
	.incbin	"initramfs.bin"
	.globl	initramfs_end
initramfs_end:
